import Foundation

/// Dead-letters that failed for the same reason and description.
///
/// `reason` and `errorDescription` are the normalized signatures (see
/// `DeadLetterAnalysis.signature(_:)`); each message keeps its original text.
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
    /// Groups messages by the signatures of their reason and error description, largest group first.
    public static func group(_ messages: [DeadLetterMessage]) -> [DeadLetterGroup] {
        struct Key: Hashable { let reason: String?; let description: String? }
        var order: [Key] = []
        var buckets: [Key: [DeadLetterMessage]] = [:]
        for message in messages {
            let key = Key(reason: signature(message.deadLetterReason),
                          description: signature(message.deadLetterErrorDescription))
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(message)
        }
        return order
            .map { DeadLetterGroup(reason: $0.reason, errorDescription: $0.description, messages: buckets[$0]!) }
            .sorted { $0.count > $1.count }   // stable for ties: first seen stays first
    }

    // MARK: Signatures

    /// Maximum length of a signature; longer ones are cut with an ellipsis.
    public static let signatureMaxLength = 160

    /// Phrases after which consumers typically append a response body or payload.
    private static let payloadMarkers = ["message from endpoint:", "response body:", "response:", "body:", "payload:", "details:"]

    nonisolated(unsafe) private static let volatilePatterns: [(Regex<AnyRegexOutput>, String)] = [
        // GUIDs, with or without braces.
        (try! Regex(#"\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?"#), "<id>"),
        // ISO-8601 timestamps.
        (try! Regex(#"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?"#), "<time>"),
        // Long hex strings (trace and span ids, hashes) that contain at least one digit.
        (try! Regex(#"\b(?=[0-9a-fA-F]*\d)[0-9a-fA-F]{16,}\b"#), "<id>"),
        // Long numbers. Short ones such as HTTP status codes are kept: they distinguish failures.
        (try! Regex(#"\b\d{5,}\b"#), "<n>"),
        (try! Regex(#"\s+"#), " "),
    ]

    /// A stable key for a dead-letter reason or description.
    ///
    /// Consumers often put a whole exception message into the reason, including a response
    /// body and per-request values like trace ids. Grouping by the raw text then puts every
    /// message in its own group. The signature drops any appended payload, replaces ids,
    /// timestamps and long numbers with placeholders, and caps the length, so messages that
    /// failed the same way share a key. Returns nil for nil or blank text.
    public static func signature(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }

        // Drop an appended payload: after a known marker, or from the first JSON object onward.
        var cut = text.endIndex
        for marker in payloadMarkers {
            if let range = text.range(of: marker, options: .caseInsensitive), range.lowerBound > text.startIndex {
                cut = min(cut, range.lowerBound)
            }
        }
        if let brace = text.firstIndex(of: "{"), brace > text.startIndex { cut = min(cut, brace) }
        let head = text[..<cut].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-–—")))
        if !head.isEmpty { text = head }

        for (pattern, replacement) in volatilePatterns {
            text = text.replacing(pattern, with: replacement)
        }
        if text.count > signatureMaxLength {
            text = String(text.prefix(signatureMaxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
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
