import AppKit
import ServiceBusKit
import SwiftUI

/// A monospaced plain-text editor with JSON or XML syntax colouring (none for plain text). Smart quotes and dashes are off so
/// pasted or typed JSON is never silently corrupted.
struct JSONEditor: NSViewRepresentable {
    @Binding var text: String
    var format: EditorFormat
    /// Take keyboard focus as soon as the editor is on screen (e.g. when a sheet opens).
    var autoFocus = false

    /// The view isn't in a window yet when it is made, so retry briefly until it is.
    private static func focus(_ view: NSTextView, attempts: Int = 10) {
        DispatchQueue.main.async {
            if let window = view.window { window.makeFirstResponder(view) }
            else if attempts > 0 { focus(view, attempts: attempts - 1) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = Coordinator.font
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.drawsBackground = false
        view.string = text
        context.coordinator.format = format
        context.coordinator.highlight(view)
        if autoFocus { Self.focus(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if context.coordinator.format != format {
            context.coordinator.format = format
            context.coordinator.highlight(view)
        }
        guard view.string != text else { return }
        let selection = view.selectedRange()
        view.string = text
        context.coordinator.highlight(view)
        view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor
        var format: EditorFormat
        init(_ parent: JSONEditor) { self.parent = parent; format = parent.format }

        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // `try!` is safe: the patterns are constants.
        private static let jsonToken = try! NSRegularExpression(
            pattern: #"("(?:\\.|[^"\\])*")(\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
        private static let xmlMarkup = try! NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<[^>]*>"#)
        private static let xmlName = try! NSRegularExpression(pattern: #"^<[/?]?[\w:.\-]+"#)
        private static let xmlAttribute = try! NSRegularExpression(pattern: #"([\w:.\-]+)\s*=\s*("[^"]*"|'[^']*')"#)

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let full = NSRange(location: 0, length: (storage.string as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.labelColor], range: full)
            switch format {
            case .json: highlightJSON(storage, full)
            case .xml: highlightXML(storage, full)
            case .text: break
            }
            storage.endEditing()
        }

        private func highlightJSON(_ storage: NSTextStorage, _ full: NSRange) {
            let string = storage.string as NSString
            Self.jsonToken.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                guard let match else { return }
                if match.range(at: 1).location != NSNotFound {
                    let color: NSColor = match.range(at: 2).location != NSNotFound ? .systemBlue : .systemRed
                    storage.addAttribute(.foregroundColor, value: color, range: match.range(at: 1))
                    return
                }
                let word = string.substring(with: match.range)
                storage.addAttribute(.foregroundColor, value: ["true", "false", "null"].contains(word) ? NSColor.systemPurple : .systemOrange,
                                     range: match.range)
            }
        }

        private func highlightXML(_ storage: NSTextStorage, _ full: NSRange) {
            let string = storage.string as NSString
            Self.xmlMarkup.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                guard let match else { return }
                let r = match.range
                let piece = string.substring(with: r)
                if piece.hasPrefix("<!--") {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                } else if piece.hasPrefix("<?") || piece.hasPrefix("<![CDATA[") {
                    storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: r)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                    if let name = Self.xmlName.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) {
                        storage.addAttribute(.foregroundColor, value: NSColor.systemBlue,
                                             range: NSRange(location: r.location + name.range.location, length: name.range.length))
                    }
                    Self.xmlAttribute.enumerateMatches(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) { a, _, _ in
                        guard let a else { return }
                        storage.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                                             range: NSRange(location: r.location + a.range(at: 1).location, length: a.range(at: 1).length))
                        storage.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                             range: NSRange(location: r.location + a.range(at: 2).location, length: a.range(at: 2).length))
                    }
                }
            }
        }
    }
}
