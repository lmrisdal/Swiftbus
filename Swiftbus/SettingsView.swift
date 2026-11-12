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
            // Fixed, and the window wide enough for the cards, so the detail never squeezes it.
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
        .frame(width: 820, height: 560)
    }
}

// MARK: - Panes

/// Appearance and layout, each picked from preview cards.
private struct GeneralSettingsPane: View {
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(LayoutSetting.key) private var layout = LayoutSetting.tree
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Appearance") {
                HStack(spacing: 16) {
                    ForEach(AppearanceSetting.allCases) { option in
                        OptionCard(title: option.title, isSelected: appearance == option) {
                            appearance = option
                        } preview: {
                            WindowSketch(appearance: option, layout: layout, scale: 0.7)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                HStack(spacing: 16) {
                    ForEach(LayoutSetting.allCases) { option in
                        OptionCard(title: option.title, subtitle: option.subtitle, isSelected: layout == option) {
                            layout = option
                        } preview: {
                            // Drawn in the look in use, so only the layout differs between the two.
                            WindowSketch(appearance: colorScheme == .dark ? .dark : .light, layout: option)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Layout")
            } footer: {
                Text("Applies to the main window right away.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: appearance) { _, new in new.apply() }
    }
}

// MARK: - Option cards

/// A selectable preview with a caption, like the appearance choices in System Settings.
private struct OptionCard<Preview: View>: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
                    }
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 170)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A miniature of the main window: sidebar, optional subscription table, and the message list,
/// drawn with the app's own symbols so each layout reads at a glance. Laid out at 200×124 and
/// scaled. "System" is drawn half light, half dark.
private struct WindowSketch: View {
    let appearance: AppearanceSetting
    let layout: LayoutSetting
    var scale: CGFloat = 1

    private static let size = CGSize(width: 200, height: 124)

    var body: some View {
        Group {
            switch appearance {
            case .light: window(Palette(dark: false))
            case .dark: window(Palette(dark: true))
            case .system:
                ZStack {
                    window(Palette(dark: false))
                    window(Palette(dark: true)).mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(scale)
        .frame(width: Self.size.width * scale, height: Self.size.height * scale)
    }

    private struct Palette {
        let dark: Bool
        var window: Color { dark ? Color(white: 0.15) : Color(white: 0.98) }
        var sidebar: Color { dark ? Color(white: 0.22) : Color(white: 0.90) }
        var text: Color { dark ? .white.opacity(0.55) : .black.opacity(0.35) }
        var faint: Color { dark ? .white.opacity(0.22) : .black.opacity(0.13) }
        var divider: Color { dark ? .white.opacity(0.10) : .black.opacity(0.10) }
    }

    private func window(_ p: Palette) -> some View {
        HStack(spacing: 0) {
            sidebar(p)
            if layout == .columns {
                subscriptionTable(p)
                Rectangle().fill(p.divider).frame(width: 1)
            }
            messages(p)
        }
        .background(p.window)
    }

    // MARK: Panes

    private struct SidebarItem {
        var chevron: String?
        var symbol: String
        var width: CGFloat
        var indent = false
        var selected = false
    }

    private var sidebarItems: [SidebarItem] {
        switch layout {
        case .tree:
            [SidebarItem(chevron: "chevron.right", symbol: "tray.2", width: 26),
             SidebarItem(chevron: "chevron.down", symbol: "tray.2", width: 22),
             SidebarItem(symbol: "envelope", width: 20, indent: true),
             SidebarItem(symbol: "envelope", width: 16, indent: true, selected: true),
             SidebarItem(symbol: "envelope", width: 22, indent: true),
             SidebarItem(chevron: "chevron.right", symbol: "tray.2", width: 24)]
        case .columns:
            [SidebarItem(symbol: "tray.2", width: 28),
             SidebarItem(symbol: "tray.2", width: 22, selected: true),
             SidebarItem(symbol: "tray.2", width: 26),
             SidebarItem(symbol: "tray.2", width: 20),
             SidebarItem(symbol: "tray.2", width: 24)]
        }
    }

    private func sidebar(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 5, height: 5) }
            }
            .padding(.bottom, 6)
            ForEach(Array(sidebarItems.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    if layout == .tree {
                        Image(systemName: item.chevron ?? "chevron.right")
                            .font(.system(size: 5, weight: .bold))
                            .frame(width: 5)
                            .opacity(item.chevron == nil ? 0 : 1)
                    }
                    Image(systemName: item.symbol)
                        .font(.system(size: 7))
                        .foregroundStyle(item.selected ? .white : Color.accentColor)
                    Capsule().fill(item.selected ? .white.opacity(0.9) : p.text).frame(width: item.width, height: 3)
                }
                .foregroundStyle(p.text)
                .padding(.leading, item.indent ? 9 : 0)
                .padding(.horizontal, 3).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 3).fill(item.selected ? Color.accentColor : .clear))
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(width: 64)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(p.sidebar)
    }

    /// The columns layout's middle pane: a table of subscriptions with count pills.
    private func subscriptionTable(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(p.text).frame(width: 24, height: 4).padding(.bottom, 4)
            ForEach(0..<6, id: \.self) { i in
                HStack(spacing: 3) {
                    Capsule().fill(i == 1 ? Color.accentColor : p.faint).frame(width: [22, 18, 24, 16, 20, 18][i], height: 3)
                    Spacer(minLength: 0)
                    Capsule().fill(Theme.active.opacity(i.isMultiple(of: 2) ? 0.8 : 0.25)).frame(width: 6, height: 4)
                    Capsule().fill(Theme.deadLetter.opacity(i == 1 || i == 4 ? 0.9 : 0.25)).frame(width: 6, height: 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 10)
        .frame(width: 54)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The message pane: a list of dead-letters with reasons, then a body preview.
    private func messages(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: "envelope").font(.system(size: 7)).foregroundStyle(Color.accentColor)
                Capsule().fill(p.text).frame(width: 26, height: 4)
            }
            .padding(.bottom, 3)
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 3) {
                    Capsule().fill(Theme.deadLetter.opacity(0.75)).frame(width: 12, height: 4)
                    Capsule().fill(p.faint).frame(width: [30, 22, 26, 18][i], height: 3)
                }
            }
            Rectangle().fill(p.divider).frame(height: 1).padding(.vertical, 2)
            RoundedRectangle(cornerRadius: 3)
                .fill(p.faint.opacity(0.6))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach([28, 20, 24], id: \.self) { Capsule().fill(p.faint).frame(width: CGFloat($0), height: 2) }
                    }
                    .padding(4)
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
