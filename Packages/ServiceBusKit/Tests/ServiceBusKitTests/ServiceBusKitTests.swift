import Foundation
import Testing
@testable import ServiceBusKit

@Test func packageLoads() {
    #expect(!ServiceBusKit.version.isEmpty)
}

@Suite struct ConnectionStringTests {
    @Test func parsesFullString() throws {
        let cs = try ConnectionString("Endpoint=sb://my-ns.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=abc+def/ghi=;EntityPath=orders")
        #expect(cs.host == "my-ns.servicebus.windows.net")
        #expect(cs.namespace == "my-ns")
        #expect(cs.keyName == "RootManageSharedAccessKey")
        #expect(cs.key == "abc+def/ghi=")
        #expect(cs.entityPath == "orders")
    }

    @Test func missingFieldsThrow() {
        #expect(throws: ConnectionString.ParseError.missingField("SharedAccessKey")) {
            try ConnectionString("Endpoint=sb://x.servicebus.windows.net/;SharedAccessKeyName=n")
        }
        #expect(throws: ConnectionString.ParseError.missingField("Endpoint")) {
            try ConnectionString("SharedAccessKeyName=n;SharedAccessKey=k")
        }
    }
}

@Suite struct SASTests {
    @Test func matchesKnownSignature() throws {
        let cs = try ConnectionString("Endpoint=sb://my-ns.servicebus.windows.net/;SharedAccessKeyName=policy;SharedAccessKey=c2VjcmV0LWtleQ==")
        let token = SASTokenProvider(connection: cs).makeToken(expiry: Date(timeIntervalSince1970: 1_700_000_000))
        let sig = "N4bbkPLROMBovhPJbwh56Rs%2BBqSTOd5UOnH9VCf5KrI%3D"
        #expect(token.value == "SharedAccessSignature sr=https%3A%2F%2Fmy-ns.servicebus.windows.net%2F&sig=\(sig)&se=1700000000&skn=policy")
    }

    @Test func cacheReusesUntilNearExpiry() async throws {
        let cs = try ConnectionString("Endpoint=sb://a.servicebus.windows.net/;SharedAccessKeyName=p;SharedAccessKey=k")
        let clock = Clock(Date(timeIntervalSince1970: 1000))
        let cache = SASTokenCache(provider: SASTokenProvider(connection: cs, lifetime: 3600, now: { clock.now }),
                                  margin: 300, now: { clock.now })
        let first = await cache.token()
        clock.now = Date(timeIntervalSince1970: 1000 + 3000)
        #expect(await cache.token() == first)
        clock.now = Date(timeIntervalSince1970: 1000 + 3400)
        #expect(await cache.token() != first)
    }
}

final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var url: URL? { lock.withLock { stored } }
    func set(_ u: URL) { lock.withLock { stored = u } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

struct FakeTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Int, String)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

func feed(_ entries: String) -> String {
    "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title type=\"text\">x</title>\(entries)</feed>"
}

func subscriptionEntry(_ name: String, active: Int, dead: Int, transfer: Int) -> String {
    """
    <entry><id>x</id><title type="text">\(name)</title><content type="application/xml">
    <SubscriptionDescription xmlns="http://schemas.microsoft.com/netservices/2010/10/servicebus/connect" xmlns:i="http://www.w3.org/2001/XMLSchema-instance">
    <LockDuration>PT1M</LockDuration><Status>Active</Status>
    <CountDetails xmlns:d2p1="http://schemas.microsoft.com/netservices/2011/06/servicebus">
    <d2p1:ActiveMessageCount>\(active)</d2p1:ActiveMessageCount><d2p1:DeadLetterMessageCount>\(dead)</d2p1:DeadLetterMessageCount>
    <d2p1:ScheduledMessageCount>0</d2p1:ScheduledMessageCount><d2p1:TransferMessageCount>0</d2p1:TransferMessageCount>
    <d2p1:TransferDeadLetterMessageCount>\(transfer)</d2p1:TransferDeadLetterMessageCount></CountDetails>
    </SubscriptionDescription></content></entry>
    """
}

func topicEntry(_ name: String) -> String {
    "<entry><title type=\"text\">\(name)</title><content type=\"application/xml\"><TopicDescription xmlns=\"http://schemas.microsoft.com/netservices/2010/10/servicebus/connect\"><Status>Active</Status></TopicDescription></content></entry>"
}

@Suite struct ManagementClientTests {
    let cs = try! ConnectionString("Endpoint=sb://ns.servicebus.windows.net/;SharedAccessKeyName=p;SharedAccessKey=k")

    @Test func parsesSubscriptionCounts() async throws {
        let transport = FakeTransport { _ in (200, feed(subscriptionEntry("sub-a", active: 5, dead: 3, transfer: 1))) }
        let subs = try await ManagementClient(connection: cs, transport: transport).listSubscriptions(topic: "orders")
        #expect(subs == [Subscription(topic: "orders", name: "sub-a", status: "Active", activeCount: 5, deadLetterCount: 3, transferDeadLetterCount: 1)])
    }

    @Test func parsesQueueCounts() async throws {
        let entry = subscriptionEntry("q1", active: 2, dead: 4, transfer: 0)
        let transport = FakeTransport { _ in (200, feed(entry)) }
        let queues = try await ManagementClient(connection: cs, transport: transport).listQueues()
        #expect(queues == [Queue(name: "q1", status: "Active", activeCount: 2, deadLetterCount: 4, transferDeadLetterCount: 0)])
    }

    @Test func fetchesSingleSubscriptionByPath() async throws {
        let seen = URLRecorder()
        let transport = FakeTransport { req in
            seen.set(req.url!)
            // A single entity comes back as a bare <entry>, not a <feed>.
            let entry = subscriptionEntry("sub-a", active: 1, dead: 7, transfer: 0)
            return (200, entry.replacingOccurrences(of: "<entry>", with: "<entry xmlns=\"http://www.w3.org/2005/Atom\">"))
        }
        let sub = try await ManagementClient(connection: cs, transport: transport).subscription(topic: "orders", name: "sub-a")
        #expect(sub.deadLetterCount == 7 && sub.activeCount == 1)
        #expect(seen.url?.path == "/orders/Subscriptions/sub-a")
        #expect(seen.url?.query?.contains("$skip") == false)
    }

    @Test func pagesUntilShortPage() async throws {
        let transport = FakeTransport { req in
            let skip = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "$skip" }!.value!
            return (200, feed(skip == "0" ? topicEntry("a") + topicEntry("b") : topicEntry("c")))
        }
        let names = try await ManagementClient(connection: cs, transport: transport, pageSize: 2).listTopicNames()
        #expect(names == ["a", "b", "c"])
    }

    @Test func listTopicsCombinesSubscriptions() async throws {
        let transport = FakeTransport { req in
            let path = req.url!.path
            if path.hasSuffix("Topics") { return (200, feed(topicEntry("t1") + topicEntry("t2"))) }
            return (200, feed(subscriptionEntry("s-\(path)", active: 0, dead: path.contains("t1") ? 2 : 0, transfer: 0)))
        }
        let topics = try await ManagementClient(connection: cs, transport: transport).listTopics()
        #expect(topics.map(\.name) == ["t1", "t2"])
        #expect(topics.map(\.deadLetterCount) == [2, 0])
    }

    @Test func retriesThrottledRequestsThenSucceeds() async throws {
        let calls = Counter()
        let transport = FakeTransport { _ in calls.next() < 2 ? (503, "") : (200, feed(topicEntry("a"))) }
        let names = try await ManagementClient(connection: cs, transport: transport, retryDelay: 0).listTopicNames()
        #expect(names == ["a"])
        #expect(calls.value == 3)
    }

    @Test func mapsHTTPErrors() async {
        for (status, expected) in [(401, ServiceBusError.unauthorized), (403, .unauthorized)] {
            let client = ManagementClient(connection: cs, transport: FakeTransport { _ in (status, "") })
            await #expect(throws: expected) { try await client.testConnection() }
        }
        let client = ManagementClient(connection: cs, transport: FakeTransport { _ in (429, "") }, retryDelay: 0)
        await #expect(throws: ServiceBusError.throttled(retryAfter: nil)) { try await client.testConnection() }
    }

    @Test func disableFetchesPatchesAndPutsWithIfMatch() async throws {
        let log = RequestLog()
        let transport = FakeTransport { req in
            log.add(req)
            if req.httpMethod == "GET" { return (200, "<entry><title>q</title><content><QueueDescription xmlns=\"urn:x\"><Status>Active</Status><EntityAvailabilityStatus>Available</EntityAvailabilityStatus></QueueDescription></content></entry>") }
            return (200, "")
        }
        try await ManagementClient(connection: cs, transport: transport).setQueueStatus(name: "q", to: .disabled)
        let put = try #require(log.requests.last)
        #expect(put.httpMethod == "PUT" && put.url?.path == "/q")
        #expect(put.value(forHTTPHeaderField: "If-Match") == "*")
        let body = String(decoding: put.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("<Status>Disabled</Status>"))
        #expect(body.contains("<EntityAvailabilityStatus>Available</EntityAvailabilityStatus>"))
    }

    @Test func patchStatusKeepsNamespacePrefix() {
        #expect(ManagementClient.patchStatus(in: "<a><d:Status>Active</d:Status></a>", to: .disabled) == "<a><d:Status>Disabled</d:Status></a>")
        #expect(ManagementClient.patchStatus(in: "<a/>", to: .disabled) == nil)
    }

    @Test func deletesAndCreatesAtTheRightPaths() async throws {
        let log = RequestLog()
        let client = ManagementClient(connection: cs, transport: FakeTransport { log.add($0); return (201, "") })
        try await client.deleteTopic(name: "orders")
        try await client.deleteQueue(name: "jobs")
        try await client.createSubscription(topic: "orders", name: "billing")
        #expect(log.requests.map { "\($0.httpMethod!) \($0.url!.path)" } == ["DELETE /orders", "DELETE /jobs", "PUT /orders/Subscriptions/billing"])
        let body = String(decoding: log.requests[2].httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("<SubscriptionDescription"))
    }

    @Test func conflictShowsServiceBusDetail() async {
        let xml = "<Error><Code>409</Code><Detail>The messaging entity 'orders:Topic:x' already exists.</Detail></Error>"
        let client = ManagementClient(connection: cs, transport: FakeTransport { _ in (409, xml) })
        await #expect(throws: ServiceBusError.conflict("The messaging entity 'orders:Topic:x' already exists.")) {
            try await client.createSubscription(topic: "orders", name: "x")
        }
    }

    @Test func topicStatusIsParsed() async throws {
        let transport = FakeTransport { req in
            req.url!.path.hasSuffix("Topics") ? (200, feed(topicEntry("t1").replacingOccurrences(of: "Active", with: "Disabled"))) : (200, feed(""))
        }
        let topics = try await ManagementClient(connection: cs, transport: transport).listTopics()
        #expect(topics.first?.isDisabled == true)
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func add(_ r: URLRequest) { lock.withLock { stored.append(r) } }
}
