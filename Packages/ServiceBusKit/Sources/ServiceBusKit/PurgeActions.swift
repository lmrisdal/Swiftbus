import Foundation

/// Which messages a purge removes.
public enum PurgeScope: Sendable, Equatable, CaseIterable {
    case active, deadLetter, all
}

/// What a purge did across every queue/subscription it touched.
public struct PurgeReport: Sendable, Equatable {
    public var purged = 0
    /// One readable line per target that failed; the others still ran.
    public var failures: [String] = []
}

public enum PurgeActions {
    /// Purges `scope` from each of `subscriptions` of `topic` — pass `[nil]` when `topic` is a queue.
    /// A failure on one target is recorded and the rest still run, so a topic with one broken
    /// subscription is not left half-purged without saying so.
    public static func run(client: any MessagingClient, topic: String, subscriptions: [String?],
                           scope: PurgeScope) async -> PurgeReport {
        var report = PurgeReport()
        for subscription in subscriptions {
            let label = subscription.map { "\(topic)/\($0)" } ?? topic
            for deadLetter in [false, true] where scope == .all || (scope == .deadLetter) == deadLetter {
                do {
                    report.purged += try await client.purge(topic: topic, subscription: subscription, deadLetter: deadLetter)
                } catch {
                    report.failures.append("\(label)\(deadLetter ? " (dead-letter)" : ""): \(error.localizedDescription)")
                }
            }
        }
        return report
    }
}
