import Foundation

public struct DeadLetterMessage: Sendable, Equatable, Hashable, Identifiable, Decodable {
    public var id: Int64 { sequenceNumber }
    public let sequenceNumber: Int64
    public let messageId: String?
    public let enqueuedTime: Date
    public let deliveryCount: Int
    public let subject: String?
    public let contentType: String?
    public let correlationId: String?
    public let deadLetterReason: String?
    public let deadLetterErrorDescription: String?
    /// Body as UTF-8 text, or nil when the body is binary.
    public let body: String?
    public let bodyBase64: String
    public let applicationProperties: [String: String]

    public var bodyData: Data { Data(base64Encoded: bodyBase64) ?? Data() }

    /// Body size in bytes, worked out from the base64 length so the body isn't decoded just to count it.
    public var bodySize: Int {
        let padding = bodyBase64.hasSuffix("==") ? 2 : (bodyBase64.hasSuffix("=") ? 1 : 0)
        return max(bodyBase64.utf8.count / 4 * 3 - padding, 0)
    }
}

/// Outcome of resending or deleting one message.
public struct MessageResult: Sendable, Equatable, Decodable {
    public let sequenceNumber: Int64
    public let ok: Bool
    public let error: String?
}

/// A message composed by the user to send to a queue or topic.
public struct OutgoingMessage: Sendable, Equatable {
    public var body: String
    public var contentType: String?
    public var subject: String?
    public var messageId: String?
    public var applicationProperties: [String: String]

    public init(body: String, contentType: String? = nil, subject: String? = nil, messageId: String? = nil,
                applicationProperties: [String: String] = [:]) {
        self.body = body
        self.contentType = contentType
        self.subject = subject
        self.messageId = messageId
        self.applicationProperties = applicationProperties
    }

    /// Parses `key=value` lines (blank lines ignored). Fails with the offending line if one has no `=` or an empty key.
    public static func parseProperties(_ text: String) -> Result<[String: String], PropertyParseError> {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { return .failure(.init(line: trimmed)) }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return .failure(.init(line: trimmed)) }
            result[key] = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return .success(result)
    }

    public struct PropertyParseError: Error, Equatable, LocalizedError {
        public let line: String
        public var errorDescription: String? { "“\(line)” is not in key=value form." }
    }
}

/// Reads and acts on dead-lettered messages. For every method, a nil `subscription` means `topic` is the name of a queue.
/// The UI talks only to this protocol, so the .NET helper
/// could later be replaced by a pure Swift AMQP client.
public protocol MessagingClient: Sendable {
    func peekDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage]
    /// Peeks the subscription's active (not dead-lettered) messages without locking them.
    func peekActive(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage]
    /// Sends a copy of each message to the topic, then removes the original only if the send succeeded.
    func resend(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult]
    func delete(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult]
    /// Sends `count` copies of `message` to the queue or topic named `topic`. Returns how many were sent.
    func send(topic: String, message: OutgoingMessage, count: Int) async throws -> Int
    /// Permanently deletes every message in the queue/subscription, or in its dead-letter queue. Returns how many were deleted.
    func purge(topic: String, subscription: String?, deadLetter: Bool) async throws -> Int
    func shutdown() async
}

public enum HelperError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case exited
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let why): "Could not start the messaging helper: \(why)"
        case .exited: "The messaging helper stopped unexpectedly."
        case .failed(let message): message
        }
    }
}
