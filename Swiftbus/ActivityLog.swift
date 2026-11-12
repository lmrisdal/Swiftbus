import Foundation
import Observation

struct ActivityEntry: Identifiable {
    enum Level { case info, success, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let text: String
}

/// In-memory record of what the app did, shown in the activity drawer.
@MainActor @Observable
final class ActivityLog {
    private(set) var entries: [ActivityEntry] = []
    private let limit = 500

    func add(_ text: String, level: ActivityEntry.Level = .info) {
        entries.append(ActivityEntry(level: level, text: text))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries = [] }
}
