import AppKit
import ServiceBusKit
import SwiftUI

// MARK: - Palette

/// The app's visual identity, taken from the icon: a deep blue gradient with an alert-red accent.
/// Everything here is presentation only; keep it free of model logic.
enum Theme {
    /// Height of the title band atop both the entity list and the detail pane, so they align.
    static let paneHeaderHeight: CGFloat = 56
    static let brandTop = Color(red: 0.24, green: 0.50, blue: 0.98)
    static let brandBottom = Color(red: 0.10, green: 0.22, blue: 0.60)
    static let brand = LinearGradient(colors: [brandTop, brandBottom], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let deadLetter = Color(red: 0.96, green: 0.27, blue: 0.30)
    static let deadLetterDeep = Color(red: 0.78, green: 0.12, blue: 0.28)
    static let active = Color(red: 0.16, green: 0.64, blue: 0.92)
    static let transfer = Color(red: 0.98, green: 0.62, blue: 0.16)
    static let healthy = Color(red: 0.20, green: 0.74, blue: 0.48)

    static let alertTint = [Color(red: 1.0, green: 0.48, blue: 0.36), deadLetterDeep]

    static func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// Hues for failure reasons. A reason always maps to the same hue, so the same failure is
    /// recognisable across subscriptions and sessions.
    private static let reasonHues: [Double] = [0.0, 0.07, 0.12, 0.55, 0.62, 0.75, 0.85, 0.93, 0.45, 0.30]

    /// Hashes the reason's signature, so a raw reason and its group share a colour.
    static func color(forReason reason: String?) -> Color {
        guard let reason = DeadLetterAnalysis.signature(reason) else { return .gray }
        // FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in reason.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Color(hue: reasonHues[Int(hash % UInt64(reasonHues.count))], saturation: 0.66, brightness: 0.90)
    }
}

// MARK: - Icon tile

/// A small rounded-square tile with a gradient and a white symbol, like System Settings rows.
struct IconTile: View {
    let systemImage: String
    let colors: [Color]
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.gradient(colors))
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: colors.last!.opacity(0.25), radius: 1.5, y: 1)
    }

}

/// Queues and topics/subscriptions are shown with a plain symbol, no tile.
struct EntityIcon: View {
    let isQueue: Bool
    var size: CGFloat = 13
    /// Overrides the queue/topic symbol, e.g. for a subscription in the sidebar tree.
    var systemName: String?
    /// `.increased` when the row sits on the selection highlight, where the accent color would vanish.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: systemName ?? (isQueue ? "tray" : "tray.2"))
            .font(.system(size: size))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            .frame(width: size * 1.5)
    }
}

// MARK: - Count pill

/// A count in a capsule. Zero is drawn quietly so the eye lands on the non-zero ones.
struct CountPill: View {
    enum Kind { case deadLetter, active, transfer }
    let count: Int
    var kind: Kind = .deadLetter
    /// True when drawn on a selected (accent-filled) row, where the kind tints would be unreadable.
    /// Callers pass it because List/Table rows on macOS don't report selection to their content.
    var onSelection = false

    private var tint: Color {
        switch kind {
        case .deadLetter: Theme.deadLetter
        case .active: Theme.active
        case .transfer: Theme.transfer
        }
    }

    private var foreground: AnyShapeStyle {
        if onSelection { return AnyShapeStyle(Color.white.opacity(count == 0 ? 0.6 : 1)) }
        return count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint)
    }

    var body: some View {
        Text(count, format: .number)
            .font(.system(.caption, design: .rounded).monospacedDigit().weight(.bold))
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background {
                if count > 0 {
                    Capsule().fill(onSelection ? Color.white.opacity(0.25) : tint.opacity(0.15))
                }
            }
            .animation(.snappy, value: count)
    }
}

// MARK: - Stat tile

/// One headline number with a label, used in the summary strip above the entity table.
struct StatTile: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color
    var emphasized = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(emphasized ? .white : tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(emphasized ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(tint.opacity(0.15))))
            VStack(alignment: .leading, spacing: 0) {
                Text(value, format: .number)
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(value)))
                    .foregroundStyle(emphasized ? .white : .primary)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(emphasized ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(emphasized
                      ? AnyShapeStyle(LinearGradient(colors: [tint, tint.darkened(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(.background.secondary))
                .shadow(color: emphasized ? tint.opacity(0.35) : .black.opacity(0.06), radius: emphasized ? 6 : 2, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(emphasized ? 0 : 0.6), lineWidth: 0.5)
        }
        .animation(.snappy, value: value)
    }
}

// MARK: - Reason tag

/// A dead-letter reason as a coloured tag; the colour is stable per reason.
struct ReasonTag: View {
    let reason: String?
    var count: Int?
    /// Caps the text width so a long reason doesn't push other tags away; the full text is in the tooltip.
    var maxTextWidth: CGFloat? = nil

    var body: some View {
        let tint = Theme.color(forReason: reason)
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(reason ?? "(no reason)")
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: maxTextWidth, alignment: .leading)
            if let count {
                Text(count, format: .number)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(tint.opacity(0.25)))
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .help(reason ?? "")
    }
}

// MARK: - Empty state

/// Like `ContentUnavailableView`: a plain symbol over the text, with optional actions.
struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 340)
                        .textSelection(.enabled)
                }
            }
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(title: String, systemImage: String, message: String? = nil) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// Shown when something has zero dead-letters.
extension EmptyState where Actions == EmptyView {
    static func allClear(_ title: String, message: String? = nil) -> Self {
        EmptyState(title: title, systemImage: "checkmark.circle", message: message)
    }
}

// MARK: - Loading

struct LoadingState: View {
    let title: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Panel

extension View {
    /// A rounded card surface for grouped content inside a pane.
    func card(padding: CGFloat = 12, cornerRadius: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

extension Color {
    /// Blends toward black; `Color.mix(with:by:)` needs macOS 15 and the app targets 14.
    func darkened(_ fraction: Double) -> Color {
        Color(nsColor: NSColor(self).usingColorSpace(.deviceRGB)?.blended(withFraction: fraction, of: .black) ?? NSColor(self))
    }
}
