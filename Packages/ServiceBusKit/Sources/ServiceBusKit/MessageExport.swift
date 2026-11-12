import Foundation

/// A message written to disk by "Save message…": its body, system properties and typed application properties.
/// Text bodies are stored as `body`; binary ones as `bodyBase64`.
public struct MessageExport: Encodable, Sendable, Equatable {
    public struct Property: Encodable, Sendable, Equatable {
        public let name: String
        public let type: String
        public let value: String
    }

    public var sequenceNumber: Int64?
    public var messageId: String?
    public var enqueuedTime: Date?
    public var deliveryCount: Int?
    public var contentType: String?
    public var subject: String?
    public var correlationId: String?
    public var deadLetterReason: String?
    public var deadLetterErrorDescription: String?
    public var applicationProperties: [Property]
    public var body: String?
    public var bodyBase64: String?

    public init(_ m: DeadLetterMessage) {
        sequenceNumber = m.sequenceNumber
        messageId = m.messageId
        enqueuedTime = m.enqueuedTime
        deliveryCount = m.deliveryCount
        contentType = m.contentType
        subject = m.subject
        correlationId = m.correlationId
        deadLetterReason = m.deadLetterReason
        deadLetterErrorDescription = m.deadLetterErrorDescription
        applicationProperties = m.typedProperties.map { Property(name: $0.key, type: $0.type.rawValue, value: $0.value) }
        if let text = m.body { body = text } else { bodyBase64 = m.bodyBase64 }
    }

    /// An edited, not yet sent message (from the repair sheet). Blank property rows are left out.
    public init(_ m: OutgoingMessage) {
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        messageId = nonEmpty(m.messageId)
        contentType = nonEmpty(m.contentType)
        subject = nonEmpty(m.subject)
        correlationId = nonEmpty(m.correlationId)
        applicationProperties = m.properties.filter { !$0.isBlank }
            .map { Property(name: $0.key.trimmingCharacters(in: .whitespaces), type: $0.type.rawValue, value: $0.value) }
        body = m.body
    }

    /// Pretty-printed JSON: one object for a single message, an array for several.
    public static func json(_ messages: [MessageExport]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return messages.count == 1 ? try encoder.encode(messages[0]) : try encoder.encode(messages)
    }

    /// A file name like "message-42.json" or "messages-orders-billing.json".
    public static func suggestedFileName(for messages: [DeadLetterMessage], entity: String) -> String {
        let safe = entity.replacingOccurrences(of: "/", with: "-")
        if messages.count == 1 { return "message-\(messages[0].sequenceNumber).json" }
        return "messages-\(safe).json"
    }
}
