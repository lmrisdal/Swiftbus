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

/// The .NET value types a Service Bus application property can carry (the same list ServiceBusExplorer offers).
public enum PropertyType: String, Sendable, CaseIterable, Codable, Identifiable {
    case boolean = "Boolean", byte = "Byte", int16 = "Int16", int32 = "Int32", int64 = "Int64"
    case single = "Single", double = "Double", decimal = "Decimal", guid = "Guid", dateTime = "DateTime"
    case string = "String", char = "Char", uint64 = "UInt64", uint32 = "UInt32", uint16 = "UInt16", sbyte = "SByte"

    public var id: String { rawValue }

    /// Returns a user-readable reason if `text` cannot be parsed as this type, otherwise nil.
    public func validate(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let ok: Bool
        switch self {
        case .string: ok = true
        case .char: ok = text.count == 1
        case .boolean: ok = ["true", "false"].contains(t.lowercased())
        case .byte: ok = UInt8(t) != nil
        case .sbyte: ok = Int8(t) != nil
        case .int16: ok = Int16(t) != nil
        case .int32: ok = Int32(t) != nil
        case .int64: ok = Int64(t) != nil
        case .uint16: ok = UInt16(t) != nil
        case .uint32: ok = UInt32(t) != nil
        case .uint64: ok = UInt64(t) != nil
        case .single, .double, .decimal: ok = Double(t) != nil
        case .guid: ok = UUID(uuidString: t) != nil
        case .dateTime: ok = ISO8601DateFormatter().date(from: t) != nil || Self.looseDate(t)
        }
        return ok ? nil : "“\(text)” is not a valid \(rawValue)."
    }

    private static func looseDate(_ t: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"].contains { f.dateFormat = $0; return f.date(from: t) != nil }
    }
}

/// One typed application property of an outgoing message.
public struct MessageProperty: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var key: String
    public var type: PropertyType
    public var value: String

    public init(id: UUID = UUID(), key: String = "", type: PropertyType = .string, value: String = "") {
        self.id = id
        self.key = key
        self.type = type
        self.value = value
    }

    /// Rows with an empty key are ignored when sending (the table always keeps a blank row for adding).
    public var isBlank: Bool { key.trimmingCharacters(in: .whitespaces).isEmpty && value.isEmpty }

    /// Why this row cannot be sent, or nil when it is fine.
    public var problem: String? {
        if isBlank { return nil }
        if key.trimmingCharacters(in: .whitespaces).isEmpty { return "A property has a value but no key." }
        return type.validate(value).map { "\(key): \($0)" }
    }

    // Only name/type/value go over the wire to the helper.
    enum CodingKeys: String, CodingKey { case key = "name", type, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(String.self, forKey: .key), type: try c.decode(PropertyType.self, forKey: .type),
                  value: try c.decode(String.self, forKey: .value))
    }
}

/// A message composed by the user to send to a queue or topic.
public struct OutgoingMessage: Sendable, Equatable {
    public var body: String
    public var contentType: String?
    public var subject: String?
    public var messageId: String?
    public var properties: [MessageProperty]

    public init(body: String, contentType: String? = nil, subject: String? = nil, messageId: String? = nil,
                properties: [MessageProperty] = []) {
        self.body = body
        self.contentType = contentType
        self.subject = subject
        self.messageId = messageId
        self.properties = properties
    }

    /// The first problem with any property row (blank rows are skipped), or nil if all can be sent.
    public var propertyProblem: String? {
        let rows = properties.filter { !$0.isBlank }
        if let bad = rows.compactMap(\.problem).first { return bad }
        let keys = rows.map { $0.key.trimmingCharacters(in: .whitespaces) }
        if let dup = Dictionary(grouping: keys, by: { $0 }).first(where: { $0.value.count > 1 }) {
            return "The property “\(dup.key)” appears more than once."
        }
        return nil
    }
}

/// Reads and acts on dead-lettered messages. For every method, a nil `subscription` means `topic` is the name of a queue.
/// The UI talks only to this protocol, so the .NET helper
/// could later be replaced by a pure Swift AMQP client.
public protocol MessagingClient: Sendable {
    func peekDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage]
    /// Peeks the transfer dead-letter queue (messages that failed while being auto-forwarded).
    func peekTransferDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage]
    /// Peeks the subscription's active (not dead-lettered) messages without locking them.
    func peekActive(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage]
    /// Sends a copy of each message to the topic, then removes the original only if the send succeeded.
    func resend(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult]
    /// Permanently removes the given messages from the dead-letter queue (`deadLetter` true) or the active queue.
    /// Active messages are received under a lock, so skipped ones count a delivery attempt.
    func delete(topic: String, subscription: String?, deadLetter: Bool, sequenceNumbers: [Int64]) async throws -> [MessageResult]
    /// Sends `message` to the queue or topic named `topic`.
    func send(topic: String, message: OutgoingMessage) async throws
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
