import AppKit
import SwiftUI

extension View {
    /// Runs `action` on a double-click without delaying single clicks. SwiftUI's
    /// `onTapGesture(count: 2)` makes `List` wait before selecting the row; this AppKit overlay only
    /// claims the second click, so the first still selects the row immediately.
    func onDoubleClick(_ action: @escaping () -> Void) -> some View {
        overlay(DoubleClickView(action: action))
    }
}

private struct DoubleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> TriggerView { TriggerView() }
    func updateNSView(_ view: TriggerView, context: Context) { view.action = action }

    /// Transparent overlay that only claims the second click of a double-click; everything else
    /// (single clicks, right-clicks) passes through to the row underneath.
    final class TriggerView: NSView {
        var action: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .leftMouseDown, event.clickCount == 2 else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { action() } else { super.mouseDown(with: event) }
        }
    }
}
