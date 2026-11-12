import SwiftUI

/// The Connections page of Settings: saved connections with connect, edit and remove, plus adding
/// a new one. Secrets stay in the Keychain; only names and hosts are shown.
struct ConnectionsSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var editing: SavedConnection?
    @State private var removing: SavedConnection?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: SettingsPane.connections.systemImage, colors: SettingsPane.connections.colors, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Service Bus namespaces").font(.headline)
                        Text("Connection strings need Manage, Send and Listen rights. They're stored in your Keychain.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if model.connections.isEmpty {
                    Text("No saved connections yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.connectionsByRecency) { row($0) }
                }
            } header: {
                Text("Saved connections")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Connection…") { adding = true }
                }
            }
        }
        .sheet(isPresented: $adding) { ConnectionSheet(connectsAfterSaving: false) }
        .sheet(item: $editing) { EditConnectionSheet(connection: $0) }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("Remove", role: .destructive) { model.remove(c) }
        } message: { _ in Text("The saved connection string is deleted from your Keychain.") }
    }

    private func row(_ c: SavedConnection) -> some View {
        let isActive = c.id == model.activeConnection?.id
        return HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name)
                    if isActive {
                        Text("Connected")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.healthy)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Theme.healthy.opacity(0.15), in: Capsule())
                    }
                }
                if let host = c.host {
                    Text(host).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button("Edit…") { editing = c }
            Menu {
                if !isActive { Button("Connect") { Task { await model.connect(c) } } }
                Button("Edit…") { editing = c }
                Divider()
                Button("Remove…", role: .destructive) { removing = c }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
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
