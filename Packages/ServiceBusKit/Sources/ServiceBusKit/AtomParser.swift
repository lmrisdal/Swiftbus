import Foundation

/// One `<entry>` of an Atom feed, flattened to element local-names.
struct AtomEntry: Equatable {
    var title: String = ""
    /// Text of every element inside `<content>`, keyed by local name (namespace prefixes dropped).
    var fields: [String: String] = [:]
}

/// Parses the Atom feeds returned by the Service Bus management API.
final class AtomParser: NSObject, XMLParserDelegate {
    private var entries: [AtomEntry] = []
    private var current: AtomEntry?
    private var path: [String] = []
    private var text = ""
    private var failure: Error?

    static func parse(_ data: Data) throws -> [AtomEntry] {
        let delegate = AtomParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw delegate.failure ?? parser.parserError ?? ServiceBusError.invalidResponse }
        return delegate.entries
    }

    private func localName(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        if name == "entry", path.isEmpty || path == ["feed"] { current = AtomEntry() }
        path.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = localName(elementName)
        defer { path.removeLast(); text = "" }
        guard current != nil else { return }
        if name == "entry" {
            entries.append(current!)
            current = nil
        } else if name == "title", path.last == "title", path.dropLast().last == "entry" {
            current?.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if path.contains("content") {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { current?.fields[name] = value }
        }
    }
}
