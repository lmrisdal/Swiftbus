import AppKit
import SwiftUI

/// Light, dark, or following the system. Stored in `UserDefaults` under `key`.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Sets the app-wide appearance. `NSApp.appearance` (rather than `preferredColorScheme`)
    /// applies to every window, sheet and menu, and `nil` reliably returns to the system setting.
    func apply() {
        NSApplication.shared.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppearanceSetting {
        UserDefaults.standard.string(forKey: key).flatMap(AppearanceSetting.init) ?? .system
    }
}

/// How the main window is laid out. Stored in `UserDefaults` under `key`.
enum LayoutSetting: String, CaseIterable, Identifiable {
    /// Sidebar tree of queues, topics and their subscriptions, plus the message pane.
    case tree
    /// Flat sidebar of queues and topics, a subscription table, then the message pane.
    case columns

    static let key = "layout"
    var id: Self { self }

    var title: String {
        switch self {
        case .tree: "Tree"
        case .columns: "Columns"
        }
    }

    var subtitle: String {
        switch self {
        case .tree: "Subscriptions nested under their topic, next to the messages."
        case .columns: "Topics, a subscription table, then the messages."
        }
    }

    static var current: LayoutSetting {
        UserDefaults.standard.string(forKey: key).flatMap(LayoutSetting.init) ?? .tree
    }
}

/// The pages of the Settings window. Stored so other windows can open a specific page
/// (e.g. "Manage connections…" opens Connections).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, connections

    static let key = "settingsPane"
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .connections: "Connections"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .connections: "externaldrive.connected.to.line.below.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .general: [Color(white: 0.62), Color(white: 0.42)]
        case .connections: [Theme.brandTop, Theme.brandBottom]
        }
    }
}

// MARK: - Window

/// Xcode-style settings: a sidebar of pages, each a grouped form.
struct SettingsView: View {
    @AppStorage(SettingsPane.key) private var pane = SettingsPane.general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { p in
                Label {
                    Text(p.title)
                } icon: {
                    IconTile(systemImage: p.systemImage, colors: p.colors)
                }
                .padding(.vertical, 2)
                .tag(p)
            }
            .toolbar(removing: .sidebarToggle)
            // Fixed, so the detail never squeezes it.
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettingsPane()
                case .connections: ConnectionsSettingsPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 700, height: 480)
    }
}

// MARK: - Panes

/// Appearance and layout, each a plain picker, and app updates.
private struct GeneralSettingsPane: View {
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(LayoutSetting.key) private var layout = LayoutSetting.tree

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
                Picker("Layout", selection: $layout) {
                    ForEach(LayoutSetting.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("\(layout.subtitle) Applies to the main window right away.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            UpdateSettingsSection()
        }
        .onChange(of: appearance) { _, new in new.apply() }
    }
}
