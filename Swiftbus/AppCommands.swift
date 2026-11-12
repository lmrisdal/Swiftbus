import SwiftUI

extension FocusedValues {
    @Entry var messageListModel: MessageListModel?
    @Entry var selectQueue: ((QueueKind) -> Void)?
    @Entry var focusSearch: (() -> Void)?
    @Entry var toggleActivityLog: (() -> Void)?
}

/// View-menu commands that act on whatever the front window is showing.
struct AppCommands: Commands {
    @FocusedValue(\.messageListModel) private var messages
    @FocusedValue(\.selectQueue) private var selectQueue
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
            Button("Show Active Messages") { selectQueue?(.active) }
                .keyboardShortcut("1")
                .disabled(selectQueue == nil)
            Button("Show Dead-letter Queue") { selectQueue?(.deadLetter) }
                .keyboardShortcut("2")
                .disabled(selectQueue == nil)
            Button("Show Transfer Dead-letter Queue") { selectQueue?(.transferDeadLetter) }
                .keyboardShortcut("3")
                .disabled(selectQueue == nil)
            Toggle("Group by Reason", isOn: Binding(get: { messages?.groupByReason ?? false },
                                                    set: { messages?.groupByReason = $0 }))
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(messages == nil || messages?.queue != .deadLetter)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Topics") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
    }
}
