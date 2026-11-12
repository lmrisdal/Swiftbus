import AppKit
import ServiceBusKit
import SwiftUI

/// Small launch window, like Xcode's project picker: the user chooses which saved connection to open
/// instead of the app silently connecting to the first one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingAddConnection = false
    @State private var selection: SavedConnection.ID?

    private var connections: [SavedConnection] { model.connectionsByRecency }
    private var selected: SavedConnection? { connections.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                Text("Swiftbus").font(.title.weight(.semibold))
                Text("Version \(ServiceBusKit.version)").font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                WelcomeButton(title: "Add connection…", systemImage: "plus") { showingAddConnection = true }
                WelcomeButton(title: "Open", systemImage: "arrow.right.circle", prominent: true) {
                    if let selected { open(selected) }
                }
                .disabled(selected == nil)
            }

            Group {
                if connections.isEmpty {
                    Text("No saved connections yet.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(connections) { c in
                                ConnectionRow(connection: c, isSelected: selection == c.id)
                                    .onTapGesture { selection = c.id }
                                    // Simultaneous, so the single tap isn't delayed waiting to rule out a double tap.
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(c) })
                                    .contextMenu { Button("Remove", role: .destructive) { model.remove(c) } }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: 200)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                if let selected { open(selected); return .handled }
                return .ignored
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
        .frame(width: 380)
        .onAppear { if selection == nil { selection = connections.first?.id } }
        .sheet(isPresented: $showingAddConnection) { ConnectionSheet() }
        .onChange(of: model.activeConnection?.id) { _, id in
            if id != nil { showMain() }
        }
    }

    private func open(_ c: SavedConnection) {
        // The window switch happens in onChange once the connection is active.
        Task { await model.connect(c) }
    }

    private func showMain() {
        openWindow(id: "main")
        dismissWindow(id: "welcome")
    }
}

private struct WelcomeButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(prominent && isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule())
        .foregroundStyle(prominent && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct ConnectionRow: View {
    let connection: SavedConnection
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title2).frame(width: 32)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name).font(.body.weight(.medium))
                if let host = connection.host {
                    Text(host).font(.callout)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(isSelected ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0)),
                    in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
