import SwiftUI

extension FocusedValues {
    @Entry var deadLetterModel: DeadLetterModel?
    @Entry var focusSearch: (() -> Void)?
    @Entry var toggleActivityLog: (() -> Void)?
}

/// View-menu commands that act on whatever the front window is showing.
struct AppCommands: Commands {
    @FocusedValue(\.deadLetterModel) private var messages
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.toggleActivityLog) private var toggleActivityLog

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            // Same responder-chain action the toolbar button uses, so it works from any focus
            // (including the detail column) and can't drift out of sync with the real state.
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("b")
            Button("Toggle Activity Log") { toggleActivityLog?() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(toggleActivityLog == nil)
            Divider()
            Button("Show Active Messages") { messages?.queue = .active }
                .keyboardShortcut("1")
                .disabled(messages == nil)
            Button("Show Dead-letter Queue") { messages?.queue = .deadLetter }
                .keyboardShortcut("2")
                .disabled(messages == nil)
            Toggle("Group by Reason", isOn: Binding(get: { messages?.groupByReason ?? false },
                                                    set: { messages?.groupByReason = $0 }))
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(messages == nil || messages?.queue == .active)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Topics") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
    }
}
