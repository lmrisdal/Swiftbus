import Foundation

struct HelperRequest: Encodable {
    var id = UUID().uuidString
    var op: String
    var connectionString: String?
    var topic: String?
    var subscription: String?
    var max: Int?
    var fromSequence: Int64?
    var sequenceNumbers: [Int64]?
    var body: String?
    var contentType: String?
    var subject: String?
    var messageId: String?
    var properties: [MessageProperty]?
    var deadLetter: Bool?
}

struct HelperResponse: Decodable {
    let id: String
    let ok: Bool
    let error: String?
    let errorCode: String?
    let messages: [DeadLetterMessage]?
    let results: [MessageResult]?
    let count: Int?
}

/// Talks to the bundled `swiftbus-helper` process in line-delimited JSON over stdin/stdout.
/// The process is started lazily, receives the connection string over stdin (never on the command
/// line), and is restarted on the next request if it exits.
public actor HelperMessagingClient: MessagingClient {
    private let executableURL: URL
    private let connectionString: String

    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<HelperResponse, Error>] = [:]

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()

    /// .NET writes up to 7 fractional digits, which `ISO8601DateFormatter` rejects on some systems, so trim to 3.
    static func parseDate(_ string: String) -> Date? {
        var s = string
        if let dot = s.firstIndex(of: "."), let end = s.index(dot, offsetBy: 1, limitedBy: s.endIndex) {
            let digits = s[end...].prefix { $0.isNumber }
            let rest = s[s.index(end, offsetBy: digits.count)...]
            s = String(s[..<end]) + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: s) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    public init(executableURL: URL, connectionString: String) {
        self.executableURL = executableURL
        self.connectionString = connectionString
    }

    // MARK: MessagingClient

    public func peekDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] {
        try await send(HelperRequest(op: "peekDeadLetters", topic: topic, subscription: subscription,
                                     max: max, fromSequence: fromSequence)).messages ?? []
    }

    public func peekTransferDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] {
        try await send(HelperRequest(op: "peekTransferDeadLetters", topic: topic, subscription: subscription,
                                     max: max, fromSequence: fromSequence)).messages ?? []
    }

    public func peekActive(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] {
        try await send(HelperRequest(op: "peekActive", topic: topic, subscription: subscription,
                                     max: max, fromSequence: fromSequence)).messages ?? []
    }

    public func resend(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult] {
        try await send(HelperRequest(op: "resend", topic: topic, subscription: subscription,
                                     sequenceNumbers: sequenceNumbers)).results ?? []
    }

    public func delete(topic: String, subscription: String?, deadLetter: Bool, sequenceNumbers: [Int64]) async throws -> [MessageResult] {
        try await send(HelperRequest(op: "delete", topic: topic, subscription: subscription,
                                     sequenceNumbers: sequenceNumbers, deadLetter: deadLetter)).results ?? []
    }

    public func send(topic: String, message: OutgoingMessage) async throws {
        let properties = message.properties.filter { !$0.isBlank }
        _ = try await send(HelperRequest(op: "send", topic: topic, body: message.body, contentType: message.contentType,
                                         subject: message.subject, messageId: message.messageId, properties: properties))
    }

    public func purge(topic: String, subscription: String?, deadLetter: Bool) async throws -> Int {
        try await send(HelperRequest(op: "purge", topic: topic, subscription: subscription, deadLetter: deadLetter)).count ?? 0
    }

    public func shutdown() async {
        process?.terminate()
        teardown()
    }

    // MARK: Process handling

    private func send(_ request: HelperRequest) async throws -> HelperResponse {
        try startIfNeeded()
        // Every request carries the connection string (over stdin) so a restarted helper needs no handshake.
        var request = request
        request.connectionString = connectionString
        let response = try await roundTrip(request)
        guard response.ok else {
            switch response.errorCode {
            case "unauthorized": throw ServiceBusError.unauthorized
            case "notFound": throw ServiceBusError.notFound("\(request.topic ?? "")/\(request.subscription ?? "")")
            case "throttled": throw ServiceBusError.throttled(retryAfter: nil)
            default: throw HelperError.failed(response.error ?? "Unknown helper error")
            }
        }
        return response
    }

    private func startIfNeeded() throws {
        guard process == nil else { return }
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = executableURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HelperError.launchFailed(error.localizedDescription) }
        self.process = process
        self.input = stdin.fileHandleForWriting
        let reader = stdout.fileHandleForReading
        readTask = Task { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let response = try? Self.decoder.decode(HelperResponse.self, from: data) else { continue }
                    await self?.deliver(response)
                }
            } catch {}
            await self?.processEnded(process)
        }
    }

    private func roundTrip(_ request: HelperRequest) async throws -> HelperResponse {
        guard let input else { throw HelperError.exited }
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            do { try input.write(contentsOf: data) } catch {
                pending[request.id] = nil
                continuation.resume(throwing: HelperError.exited)
            }
        }
    }

    private func deliver(_ response: HelperResponse) {
        pending.removeValue(forKey: response.id)?.resume(returning: response)
    }

    private func processEnded(_ ended: Process) {
        guard process === ended else { return }
        teardown()
    }

    private func teardown() {
        readTask?.cancel()
        readTask = nil
        process = nil
        input = nil
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: HelperError.exited) }
    }
}
