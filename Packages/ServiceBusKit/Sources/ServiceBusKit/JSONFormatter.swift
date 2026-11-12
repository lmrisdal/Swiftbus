import Foundation

/// Pretty-prints and minifies JSON text while keeping key order, which `JSONSerialization` would lose.
public enum JSONFormatter {
    /// True if `text` is a complete, valid JSON document (a bare string or number counts).
    public static func isValid(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Re-indents valid JSON, or returns nil if `text` is not valid JSON.
    public static func pretty(_ text: String, indent: Int = 2) -> String? {
        guard isValid(text) else { return nil }
        return rewrite(text, indent: indent)
    }

    /// Strips insignificant whitespace from valid JSON, or returns nil if `text` is not valid JSON.
    public static func minified(_ text: String) -> String? {
        guard isValid(text) else { return nil }
        return rewrite(text, indent: nil)
    }

    private static func rewrite(_ text: String, indent: Int?) -> String {
        let chars = Array(text)
        var out = ""
        var level = 0
        var inString = false
        var escaped = false
        func newline() {
            guard let indent else { return }
            out += "\n" + String(repeating: " ", count: level * indent)
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { i += 1 }
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[":
                out.append(c)
                // Keep empty containers on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(chars[j]); i = j
                } else { level += 1; newline() }
            case "}", "]": level -= 1; newline(); out.append(c)
            case ",": out.append(c); newline()
            case ":": out += indent == nil ? ":" : ": "
            default: if !c.isWhitespace { out.append(c) }
            }
        }
        return out
    }
}
