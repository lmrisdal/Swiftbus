import AppKit

// MARK: - Always-emphasized selection

extension NSTableRowView {
    /// SwiftUI's `List` and `Table` are backed by `NSTableView`, which draws a selected row in the
    /// strong accent blue only while that table has keyboard focus. Everywhere else (clicking into
    /// another pane, or the app going to the background) it fades to a gray that is easy to lose,
    /// and focus rarely returns to the sidebar on reactivation. SwiftUI has no hook for this, so
    /// the row view's `isEmphasized` getter is swapped once at launch to always answer `true`.
    /// Cell content follows automatically (white text/icons on the blue).
    @MainActor static func alwaysEmphasizeSelection() {
        guard let original = class_getInstanceMethod(NSTableRowView.self, #selector(getter: NSTableRowView.isEmphasized)),
              let replacement = class_getInstanceMethod(NSTableRowView.self, #selector(getter: NSTableRowView.swiftbus_isEmphasized))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    @objc private var swiftbus_isEmphasized: Bool { true }
}
