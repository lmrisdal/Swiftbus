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
            for span in SyntaxHighlighter.spans(for: storage.string, format: format) {
                storage.addAttribute(.foregroundColor, value: span.color, range: span.range)
            }
            storage.endEditing()
        }
    }
}
