import AppKit
import ServiceBusKit
import SwiftUI

/// JSON and XML syntax colouring, shared by the editable body editor and the read-only message inspector.
enum SyntaxHighlighter {
    struct Span { let range: NSRange; let color: NSColor }

    // `try!` is safe: the patterns are constants.
    private static let jsonToken = try! NSRegularExpression(
        pattern: #"("(?:\\.|[^"\\])*")(\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
    private static let xmlMarkup = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<[^>]*>"#)
    private static let xmlName = try! NSRegularExpression(pattern: #"^<[/?]?[\w:.\-]+"#)
    private static let xmlAttribute = try! NSRegularExpression(pattern: #"([\w:.\-]+)\s*=\s*("[^"]*"|'[^']*')"#)

    /// Colour spans for `text`, in order; later spans override earlier ones where they overlap.
    static func spans(for text: String, format: EditorFormat) -> [Span] {
        switch format {
        case .json: jsonSpans(text)
        case .xml: xmlSpans(text)
        case .text: []
        }
    }

    /// `text` as a SwiftUI attributed string with the colouring applied.
    static func attributed(_ text: String, format: EditorFormat) -> AttributedString {
        var result = AttributedString(text)
        for span in spans(for: text, format: format) {
            if let range = Range(span.range, in: result) { result[range].foregroundColor = Color(nsColor: span.color) }
        }
        return result
    }

    private static func jsonSpans(_ text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        jsonToken.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                let isKey = match.range(at: 2).location != NSNotFound
                spans.append(Span(range: match.range(at: 1), color: isKey ? .systemBlue : .systemRed))
                return
            }
            let word = string.substring(with: match.range)
            spans.append(Span(range: match.range, color: ["true", "false", "null"].contains(word) ? .systemPurple : .systemOrange))
        }
        return spans
    }

    private static func xmlSpans(_ text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        xmlMarkup.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { match, _, _ in
            guard let match else { return }
            let r = match.range
            let piece = string.substring(with: r)
            if piece.hasPrefix("<!--") {
                spans.append(Span(range: r, color: .secondaryLabelColor))
            } else if piece.hasPrefix("<?") || piece.hasPrefix("<![CDATA[") {
                spans.append(Span(range: r, color: .systemPurple))
            } else {
                let whole = NSRange(location: 0, length: (piece as NSString).length)
                spans.append(Span(range: r, color: .secondaryLabelColor))
                if let name = xmlName.firstMatch(in: piece, range: whole) {
                    spans.append(Span(range: NSRange(location: r.location + name.range.location, length: name.range.length), color: .systemBlue))
                }
                xmlAttribute.enumerateMatches(in: piece, range: whole) { a, _, _ in
                    guard let a else { return }
                    spans.append(Span(range: NSRange(location: r.location + a.range(at: 1).location, length: a.range(at: 1).length), color: .systemOrange))
                    spans.append(Span(range: NSRange(location: r.location + a.range(at: 2).location, length: a.range(at: 2).length), color: .systemRed))
                }
            }
        }
        return spans
    }
}
