@preconcurrency import Sparkle
import SwiftUI

/// Checks for and installs app updates with Sparkle, from the appcast attached to the latest
/// GitHub release (`SUFeedURL` in Info.plist). Updates are EdDSA-signed in CI and verified against
/// `SUPublicEDKey`; the sandboxed app installs them through Sparkle's installer XPC services.
///
/// The updater only starts in Release builds that carry a public key: Debug builds report build 1 and
/// would always be offered an update, and Sparkle refuses to run (with an alert) without a key.
@MainActor @Observable
final class AppUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// False while a check is running, and always false when the updater is not started.
    private(set) var canCheckForUpdates = false

    /// Whether this build updates itself at all; see the type's documentation.
    let isEnabled: Bool

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        #if DEBUG
        isEnabled = false
        #else
        isEnabled = !key.trimmingCharacters(in: .whitespaces).isEmpty
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: isEnabled,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            // Sparkle changes this on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    /// Shows Sparkle's "Check for Updates" window: the result, release notes and an Install button.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Daily background checks. Stored by Sparkle in the app's defaults.
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Download found updates in the background and install them when the app quits.
    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                controller.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}

// MARK: - Views

/// "Check for Updates…" for the app menu. A view (not a plain command button) so it tracks
/// `canCheckForUpdates`.
struct CheckForUpdatesButton: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// The Updates section of Settings › General.
struct UpdateSettingsSection: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section {
            if updater.isEnabled {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Automatically download and install updates", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                LabeledContent {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    Text("Version \(Self.version)")
                    if let last = updater.lastUpdateCheckDate {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                    }
                }
            } else {
                LabeledContent("Version \(Self.version)") {
                    Text("Updates are off in this build")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from GitHub releases and are verified before they are installed.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
