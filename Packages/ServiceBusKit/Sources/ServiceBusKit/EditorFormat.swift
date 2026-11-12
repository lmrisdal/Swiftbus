import Foundation

/// How a message body should be edited, validated and formatted. Chosen from the content type so
/// the UI treats `application/json` and `text/xml` bodies specially and everything else as plain text.
public enum EditorFormat: String, Sendable, CaseIterable {
    case json = "JSON", xml = "XML", text = "text"

    /// Detects the format from a content type such as `application/json; charset=utf-8` or
    /// `application/soap+xml`. With no content type, sniffs the body's first character instead.
    public static func detect(contentType: String?, body: String = "") -> EditorFormat {
        let type = (contentType ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if type.contains("json") { return .json }
        if type.contains("xml") { return .xml }
        if type.isEmpty {
            switch body.drop(while: \.isWhitespace).first {
            case "{", "[": return .json
            case "<": return .xml
            default: break
            }
        }
        return .text
    }

    /// True if `text` is well-formed in this format. Plain text is always valid.
    public func isValid(_ text: String) -> Bool {
        switch self {
        case .json: JSONFormatter.isValid(text)
        case .xml: Self.parseXML(text) != nil
        case .text: true
        }
    }

    /// Re-indents the body, or nil if it is not valid (or is plain text, which has nothing to format).
    public func pretty(_ text: String) -> String? {
        switch self {
        case .json: JSONFormatter.pretty(text)
        case .xml: Self.serializeXML(text, options: [.nodePrettyPrint])
        case .text: nil
        }
    }

    /// Strips insignificant whitespace, or nil if it is not valid (or is plain text).
    public func minified(_ text: String) -> String? {
        switch self {
        case .json: JSONFormatter.minified(text)
        case .xml: Self.serializeXML(text, options: [])
        case .text: nil
        }
    }

    private static func parseXML(_ text: String) -> XMLDocument? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? XMLDocument(xmlString: text, options: [.nodePreserveCDATA])
    }

    /// Serializes via `XMLDocument` (which keeps element order), dropping the XML declaration
    /// it adds when the input had none.
    private static func serializeXML(_ text: String, options: XMLNode.Options) -> String? {
        guard let doc = parseXML(text) else { return nil }
        var out = doc.xmlString(options: options.union([.nodePreserveCDATA, .nodeCompactEmptyElement]))
        let hadDeclaration = text.drop(while: \.isWhitespace).hasPrefix("<?xml")
        if !hadDeclaration, out.hasPrefix("<?xml"), let end = out.range(of: "?>") {
            out = String(out[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if options.contains(.nodePrettyPrint) { out = halveIndentation(out) }
        return out
    }

    /// `XMLDocument` indents by four spaces; use two, to match the JSON formatter.
    private static func halveIndentation(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let spaces = line.prefix(while: { $0 == " " }).count
            return String(repeating: " ", count: spaces / 2) + line.dropFirst(spaces)
        }.joined(separator: "\n")
    }
}
