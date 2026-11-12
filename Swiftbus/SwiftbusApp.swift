import AppKit
import SwiftUI

@main
struct SwiftbusApp: App {
    @State private var model = AppModel()

    init() {
        NSTableRowView.alwaysEmphasizeSelection()
    }

    var body: some Scene {
        Window("Swiftbus", id: "welcome") {
            WelcomeView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Swiftbus", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 560)
        }
        .commands { AppCommands() }
    }
}
