import SwiftUI

/// Lists saved connections with rename/replace-secret and remove actions.
struct ManageConnectionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SavedConnection?
    @State private var removing: SavedConnection?

    var body: some View {
        VStack(spacing: 0) {
            if model.connections.isEmpty {
                ContentUnavailableView("No connections", systemImage: "externaldrive.badge.xmark")
                    .frame(maxHeight: .infinity)
            } else {
                List(model.connectionsByRecency) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.name).font(.headline)
                                if c.id == model.activeConnection?.id {
                                    Text("Active").font(.caption2).foregroundStyle(.secondary)
                                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                                }
                            }
                            if let host = c.host { Text(host).font(.callout).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Edit…") { editing = c }
                        Button("Remove", systemImage: "trash", role: .destructive) { removing = c }
                            .labelStyle(.iconOnly)
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 340)
        .sheet(item: $editing) { EditConnectionSheet(connection: $0) }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("Remove", role: .destructive) { model.remove(c) }
        } message: { _ in Text("The saved connection string is deleted from your Keychain.") }
    }
}

private struct EditConnectionSheet: View {
    let connection: SavedConnection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var connectionString = ""
    @State private var status: String?
    @State private var isWorking = false

    init(connection: SavedConnection) {
        self.connection = connection
        _name = State(initialValue: connection.name)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            SecureField("Connection string", text: $connectionString,
                        prompt: Text("Leave empty to keep the current one"))
            if let status {
                Label {
                    Text(status).font(.callout)
                } icon: {
                    if isWorking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.deadLetter) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        isWorking = true
        status = connectionString.isEmpty ? nil : "Connecting…"
        Task {
            defer { isWorking = false }
            do {
                try await model.update(connection, name: name, connectionString: connectionString)
                dismiss()
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
