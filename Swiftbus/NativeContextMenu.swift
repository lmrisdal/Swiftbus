import AppKit
import SwiftUI

/// One row of a native context menu.
indirect enum MenuEntry {
    case item(String, enabled: Bool = true, action: () -> Void)
    case submenu(String, [MenuEntry])
    case separator
}

extension View {
    /// Right-click menu backed by a plain `NSMenu`. SwiftUI's `.contextMenu` makes macOS 26 append an
    /// "Ask Siri" item that apps can't remove; an AppKit menu (like Xcode's) doesn't get it.
    /// `entries` is evaluated on each right-click, so labels reflect current state.
    func nativeContextMenu(_ entries: @escaping () -> [MenuEntry]) -> some View {
        overlay(NativeContextMenuView(entries: entries))
    }
}

private struct NativeContextMenuView: NSViewRepresentable {
    let entries: () -> [MenuEntry]

    func makeNSView(context: Context) -> TriggerView { TriggerView() }
    func updateNSView(_ view: TriggerView, context: Context) { view.entries = entries }

    /// Transparent overlay that only claims right-clicks (and ctrl-clicks), so left clicks still
    /// reach the row underneath and selection keeps working.
    final class TriggerView: NSView, NSMenuDelegate {
        var entries: () -> [MenuEntry] = { [] }
        private var highlight: NSView?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isMenuClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isMenuClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = build(entries())
            menu.delegate = self
            return menu
        }

        // MARK: Clicked-row outline

        /// `NSTableView` outlines the right-clicked row only when it shows the menu itself. This menu
        /// bypasses that, so draw the same accent ring on the enclosing row while the menu is open.
        func menuWillOpen(_ menu: NSMenu) {
            guard highlight == nil, let row = enclosingRowView else { return }
            let ring = NSView(frame: row.bounds)
            ring.autoresizingMask = [.width, .height]
            ring.wantsLayer = true
            ring.layer?.cornerRadius = 6
            ring.layer?.cornerCurve = .continuous
            ring.layer?.borderWidth = 2
            ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
            row.addSubview(ring)
            highlight = ring
        }

        func menuDidClose(_ menu: NSMenu) {
            highlight?.removeFromSuperview()
            highlight = nil
        }

        private var enclosingRowView: NSTableRowView? {
            var view = superview
            while let v = view, !(v is NSTableRowView) { view = v.superview }
            return view as? NSTableRowView
        }

        private func build(_ entries: [MenuEntry]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case .item(let title, let enabled, let action):
                    let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
                    item.target = self
                    item.isEnabled = enabled
                    item.representedObject = ActionBox(action)
                    menu.addItem(item)
                case .submenu(let title, let children):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.submenu = build(children)
                    menu.addItem(item)
                }
            }
            return menu
        }

        @objc private func fire(_ sender: NSMenuItem) { (sender.representedObject as? ActionBox)?.action() }
    }

    private final class ActionBox {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
}
