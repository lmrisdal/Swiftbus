import Foundation

/// Fetches data for HTTP requests; abstracted so tests can supply saved responses.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request, delegate: nil)
        guard let http = response as? HTTPURLResponse else { throw ServiceBusError.invalidResponse }
        return (data, http)
    }
}

/// Lists queues, topics, subscriptions and message counts through the Service Bus REST management API.
public struct ManagementClient: Sendable {
    static let apiVersion = "2021-05"

    private let connection: ConnectionString
    private let tokens: SASTokenCache
    private let transport: any HTTPTransport
    private let pageSize: Int
    private let maxConcurrency: Int
    private let maxRetries: Int
    private let retryDelay: TimeInterval

    public init(connection: ConnectionString, transport: any HTTPTransport = URLSession.shared,
                pageSize: Int = 100, maxConcurrency: Int = 8, maxRetries: Int = 2, retryDelay: TimeInterval = 1) {
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.connection = connection
        self.tokens = SASTokenCache(provider: SASTokenProvider(connection: connection))
        self.transport = transport
        self.pageSize = pageSize
        self.maxConcurrency = maxConcurrency
    }

    /// Cheap check that the credentials work: fetches one topic.
    public func testConnection() async throws {
        _ = try await pagedEntries(path: "$Resources/Topics", top: 1, limit: 1)
    }

    public func listTopicNames() async throws -> [String] {
        try await listTopicEntries().map(\.title)
    }

    private func listTopicEntries() async throws -> [AtomEntry] {
        try await pagedEntries(path: "$Resources/Topics").sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Fetches one topic with its status and subscriptions.
    public func topic(name: String) async throws -> Topic {
        guard let entry = try AtomParser.parse(try await get(path: Self.encode(name), skip: nil, top: nil)).first else {
            throw ServiceBusError.notFound(name)
        }
        return Topic(name: entry.title, status: entry.fields["Status"] ?? "Active",
                     subscriptions: try await listSubscriptions(topic: name), details: TopicDetails(fields: entry.fields))
    }

    public func listSubscriptions(topic: String) async throws -> [Subscription] {
        try await pagedEntries(path: "\(Self.encode(topic))/Subscriptions").map { Self.subscription($0, topic: topic) }
    }

    /// Fetches the counts of one subscription without listing its siblings.
    public func subscription(topic: String, name: String) async throws -> Subscription {
        let path = "\(Self.encode(topic))/Subscriptions/\(Self.pathEncode(name))"
        guard let entry = try AtomParser.parse(try await get(path: path, skip: nil, top: nil)).first else {
            throw ServiceBusError.notFound("\(topic)/\(name)")
        }
        return Self.subscription(entry, topic: topic)
    }

    public func listQueues() async throws -> [Queue] {
        try await pagedEntries(path: "$Resources/Queues").map(Self.queue)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Fetches the counts of one queue.
    public func queue(name: String) async throws -> Queue {
        guard let entry = try AtomParser.parse(try await get(path: Self.encode(name), skip: nil, top: nil)).first else {
            throw ServiceBusError.notFound(name)
        }
        return Self.queue(entry)
    }

    private static func queue(_ entry: AtomEntry) -> Queue {
        func count(_ key: String) -> Int { Int(entry.fields[key] ?? "") ?? 0 }
        return Queue(name: entry.title, status: entry.fields["Status"] ?? "Active",
                     activeCount: count("ActiveMessageCount"),
                     deadLetterCount: count("DeadLetterMessageCount"),
                     transferDeadLetterCount: count("TransferDeadLetterMessageCount"))
    }

    private static func encode(_ topic: String) -> String {
        topic.split(separator: "/", omittingEmptySubsequences: false).map { pathEncode(String($0)) }.joined(separator: "/")
    }

    private static func subscription(_ entry: AtomEntry, topic: String) -> Subscription {
        func count(_ key: String) -> Int { Int(entry.fields[key] ?? "") ?? 0 }
        return Subscription(topic: topic, name: entry.title, status: entry.fields["Status"] ?? "Active",
                            activeCount: count("ActiveMessageCount"),
                            deadLetterCount: count("DeadLetterMessageCount"),
                            transferDeadLetterCount: count("TransferDeadLetterMessageCount"))
    }

    /// Lists every topic with its subscriptions, fetching topics concurrently.
    public func listTopics() async throws -> [Topic] {
        let entries = try await listTopicEntries()
        let names = entries.map(\.title)
        var results: [String: [Subscription]] = [:]
        try await withThrowingTaskGroup(of: (String, [Subscription]).self) { group in
            var iterator = names.makeIterator()
            func addNext() {
                if let name = iterator.next() {
                    group.addTask { (name, try await listSubscriptions(topic: name)) }
                }
            }
            for _ in 0..<maxConcurrency { addNext() }
            while let (name, subs) = try await group.next() {
                results[name] = subs
                addNext()
            }
        }
        return entries.map {
            Topic(name: $0.title, status: $0.fields["Status"] ?? "Active", subscriptions: results[$0.title] ?? [],
                  details: TopicDetails(fields: $0.fields))
        }
    }

    // MARK: - Changing entities

    public func deleteQueue(name: String) async throws {
        _ = try await request(method: "DELETE", path: Self.encode(name))
    }

    /// Deleting a topic also deletes its subscriptions and every message in them.
    public func deleteTopic(name: String) async throws {
        _ = try await request(method: "DELETE", path: Self.encode(name))
    }

    public func setQueueStatus(name: String, to status: EntityStatus) async throws {
        try await updateStatus(path: Self.encode(name), to: status)
    }

    public func setTopicStatus(name: String, to status: EntityStatus) async throws {
        try await updateStatus(path: Self.encode(name), to: status)
    }

    /// Creates a subscription with Service Bus's default settings (and its default match-all rule).
    public func createSubscription(topic: String, name: String) async throws {
        let body = """
        <entry xmlns="http://www.w3.org/2005/Atom"><content type="application/xml">\
        <SubscriptionDescription xmlns="http://schemas.microsoft.com/netservices/2010/10/servicebus/connect" />\
        </content></entry>
        """
        _ = try await request(method: "PUT", path: "\(Self.encode(topic))/Subscriptions/\(Self.pathEncode(name))",
                              body: Data(body.utf8))
    }

    /// The REST API has no "set status" call: an update replaces the whole description, so fetch it,
    /// flip `<Status>`, and put it back (`If-Match: *` marks it as an update, not a create).
    private func updateStatus(path: String, to status: EntityStatus) async throws {
        let current = String(decoding: try await get(path: path, skip: nil, top: nil), as: UTF8.self)
        guard let patched = Self.patchStatus(in: current, to: status) else { throw ServiceBusError.invalidResponse }
        _ = try await request(method: "PUT", path: path, body: Data(patched.utf8), headers: ["If-Match": "*"])
    }

    /// Replaces the text of the entity's `<Status>` element, or returns nil if there isn't one.
    static func patchStatus(in xml: String, to status: EntityStatus) -> String? {
        guard let range = xml.range(of: #"<((?:\w+:)?)Status>[^<]*</(?:\w+:)?Status>"#, options: .regularExpression) else { return nil }
        var result = xml
        let tag = xml[range].prefix { $0 != ">" }.dropFirst()   // "Status" or "ns:Status"
        result.replaceSubrange(range, with: "<\(tag)>\(status.rawValue)</\(tag)>")
        return result
    }

    // MARK: - Internals

    private func pagedEntries(path: String, top: Int? = nil, limit: Int? = nil) async throws -> [AtomEntry] {
        let top = top ?? pageSize
        var all: [AtomEntry] = []
        var skip = 0
        while true {
            let page = try AtomParser.parse(try await get(path: path, skip: skip, top: top))
            all += page
            if page.count < top || (limit.map { all.count >= $0 } ?? false) { break }
            skip += top
        }
        return all
    }

    private func get(path: String, skip: Int?, top: Int?) async throws -> Data {
        try await request(method: "GET", path: path, skip: skip, top: top)
    }

    private func request(method: String, path: String, skip: Int? = nil, top: Int? = nil,
                         body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = connection.host
        components.percentEncodedPath = "/" + path
        var query = "api-version=\(Self.apiVersion)"
        if let skip, let top { query += "&$skip=\(skip)&$top=\(top)" }
        components.percentEncodedQuery = query
        guard let url = components.url else { throw ServiceBusError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue(await tokens.token(), forHTTPHeaderField: "Authorization")
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/atom+xml;type=entry;charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        var attempt = 0
        while true {
            do { return try await perform(request, path: path) }
            catch ServiceBusError.throttled(let retryAfter) where attempt < maxRetries {
                attempt += 1
                // Honour Retry-After (capped), otherwise back off exponentially.
                let delay = min(retryAfter ?? retryDelay * pow(2, Double(attempt - 1)), 10)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func perform(_ request: URLRequest, path: String) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch let error as URLError { throw ServiceBusError.network(error.localizedDescription) }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ServiceBusError.unauthorized
        case 404: throw ServiceBusError.notFound(path)
        case 409: throw ServiceBusError.conflict(Self.errorDetail(data))
        case 429, 503:
            throw ServiceBusError.throttled(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default:
            throw ServiceBusError.http(status: response.statusCode, detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// Service Bus error bodies are XML with a `<Detail>`; show that rather than the markup.
    static func errorDetail(_ data: Data) -> String {
        let text = String(decoding: data.prefix(1000), as: UTF8.self)
        if let range = text.range(of: "<Detail>[^<]*</Detail>", options: .regularExpression) {
            return String(text[range].dropFirst(8).dropLast(9))
        }
        return text
    }

    static func pathEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }
}
