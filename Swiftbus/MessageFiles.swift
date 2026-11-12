import AppKit
import ServiceBusKit
import UniformTypeIdentifiers

/// Saves messages as JSON through a save panel ("Save message…").
@MainActor
enum MessageFiles {
    /// Asks where to save and writes `exports` there. Returns a user-readable error, or nil when saved or cancelled.
    @discardableResult
    static func save(_ exports: [MessageExport], suggestedName: String, log: ActivityLog?) async -> String? {
        guard !exports.isEmpty else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        let response = if let window = NSApp.keyWindow {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        do {
            try MessageExport.json(exports).write(to: url, options: .atomic)
            log?.add("Saved \(exports.count) message(s) to \(url.lastPathComponent).", level: .success)
            return nil
        } catch {
            log?.add("Saving to \(url.lastPathComponent) failed: \(error.localizedDescription)", level: .error)
            return error.localizedDescription
        }
    }
}
