import AppKit
import SwiftUI

struct ConnectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var connectionString = ""
    @State private var status: String?
    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connect a namespace").font(.title2.weight(.semibold))
                        Text("Use a connection string with Manage, Send and Listen rights. It's stored in your Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
            TextField("Name", text: $name, prompt: Text("Optional"))
            SecureField("Connection string", text: $connectionString,
                        prompt: Text("Endpoint=sb://…;SharedAccessKeyName=…;SharedAccessKey=…"))
            }
            if let status {
                Label {
                    Text(status).font(.callout)
                } icon: {
                    if isWorking { ProgressView().controlSize(.small) }
                    else if status == "Connection works." { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.healthy) }
                    else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.deadLetter) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem { Button("Test connection") { run(save: false) }.disabled(isWorking || connectionString.isEmpty) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { run(save: true) }.disabled(isWorking || connectionString.isEmpty)
            }
        }
    }

    private func run(save: Bool) {
        isWorking = true
        status = "Connecting…"
        Task {
            defer { isWorking = false }
            do {
                if save {
                    try await model.add(name: name, connectionString: connectionString)
                    dismiss()
                } else {
                    try await model.testConnection(connectionString)
                    status = "Connection works."
                }
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
