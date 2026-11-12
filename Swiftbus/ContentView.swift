import ServiceBusKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("All dead-letters", systemImage: "exclamationmark.triangle")
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            ContentUnavailableView("No namespace", systemImage: "network",
                                   description: Text("Connect with a connection string to list topics."))
        } detail: {
            ContentUnavailableView("No subscription selected", systemImage: "tray")
        }
        .navigationTitle("Swiftbus")
        .navigationSubtitle("ServiceBusKit \(ServiceBusKit.version)")
    }
}

#Preview {
    ContentView()
}
