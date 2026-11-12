import Foundation

/// Dead-letters that failed for the same reason and description.
public struct DeadLetterGroup: Sendable, Equatable, Identifiable {
    public var id: String { "\(reason ?? "")\u{1F}\(errorDescription ?? "")" }
    public let reason: String?
    public let errorDescription: String?
    public let messages: [DeadLetterMessage]

    public var count: Int { messages.count }
    public var firstEnqueued: Date? { messages.map(\.enqueuedTime).min() }
    public var lastEnqueued: Date? { messages.map(\.enqueuedTime).max() }
}

public enum DeadLetterAnalysis {
    /// Groups messages by reason and error description, largest group first.
    public static func group(_ messages: [DeadLetterMessage]) -> [DeadLetterGroup] {
        struct Key: Hashable { let reason: String?; let description: String? }
        var order: [Key] = []
        var buckets: [Key: [DeadLetterMessage]] = [:]
        for message in messages {
            let key = Key(reason: message.deadLetterReason, description: message.deadLetterErrorDescription)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(message)
        }
        return order
            .map { DeadLetterGroup(reason: $0.reason, errorDescription: $0.description, messages: buckets[$0]!) }
            .sorted { $0.count > $1.count }   // stable for ties: first seen stays first
    }
}

public enum BodyFormat: Sendable, Equatable { case json, xml, text, binary }

public struct FormattedBody: Sendable, Equatable {
    public let format: BodyFormat
    public let text: String
}

public enum BodyFormatter {
    /// Pretty-prints JSON or XML bodies; other text is returned as is. Binary bodies show a hex dump summary.
    public static func format(_ message: DeadLetterMessage) -> FormattedBody {
        guard let text = message.body else {
            let data = message.bodyData
            let hex = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
            let more = data.count > 256 ? " … (\(data.count) bytes)" : ""
            return FormattedBody(format: .binary, text: hex + more)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[",
           let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]),
           let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return FormattedBody(format: .json, text: String(decoding: pretty, as: UTF8.self))
        }
        #if os(macOS)
        if trimmed.first == "<", let document = try? XMLDocument(xmlString: trimmed, options: []) {
            return FormattedBody(format: .xml, text: document.xmlString(options: [.nodePrettyPrint]))
        }
        #endif
        return FormattedBody(format: .text, text: text)
    }
}
