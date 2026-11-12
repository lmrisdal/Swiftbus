import Foundation
import Observation
import ServiceBusKit

/// A table row: either one dead-letter, or a group of them that share a failure reason.
struct DeadLetterRow: Identifiable, Hashable {
    let id: String
    let message: DeadLetterMessage?
    let group: DeadLetterGroup?
    var children: [DeadLetterRow]?

    static func == (a: DeadLetterRow, b: DeadLetterRow) -> Bool { a.id == b.id && a.children?.count == b.children?.count }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func single(_ m: DeadLetterMessage) -> DeadLetterRow {
        DeadLetterRow(id: "m\(m.sequenceNumber)", message: m, group: nil, children: nil)
    }
    static func grouped(_ g: DeadLetterGroup) -> DeadLetterRow {
        DeadLetterRow(id: "g\(g.id)", message: nil, group: g, children: g.messages.map(single))
    }
}

enum QueueKind: String, CaseIterable, Identifiable {
    case active = "Active"
    case deadLetter = "Dead-letter"
    var id: String { rawValue }
}

/// A resend or delete in progress, or just finished.
struct ActionRun {
    let action: DeadLetterAction
    let messages: [DeadLetterMessage]
    var results: [Int64: MessageResult] = [:]
    var isFinished = false

    var succeeded: Int { results.values.filter(\.ok).count }
    var failed: Int { results.values.filter { !$0.ok }.count }
    var completed: Int { results.count }
}

/// A queue or a topic subscription: the thing whose messages are listed.
struct EntityRow: Identifiable, Hashable {
    enum ID: Hashable { case queue(String), subscription(Subscription.ID) }

    let id: ID
    /// The queue name, or the topic a subscription belongs to.
    let path: String
    /// nil for a queue.
    let subscription: String?
    let activeCount: Int
    let deadLetterCount: Int
    let transferDeadLetterCount: Int

    var isQueue: Bool { subscription == nil }
    var name: String { subscription ?? path }
    /// "orders/sub-a" or "orders-queue".
    var fullName: String { subscription.map { "\(path)/\($0)" } ?? path }
    var kindName: String { isQueue ? "queue" : "subscription" }

    init(_ s: Subscription) {
        id = .subscription(s.id); path = s.topic; subscription = s.name
        activeCount = s.activeCount; deadLetterCount = s.deadLetterCount; transferDeadLetterCount = s.transferDeadLetterCount
    }
    init(_ q: Queue) {
        id = .queue(q.name); path = q.name; subscription = nil
        activeCount = q.activeCount; deadLetterCount = q.deadLetterCount; transferDeadLetterCount = q.transferDeadLetterCount
    }
}

/// Loads and presents the dead-letter queue of one subscription or queue.
@MainActor @Observable
final class DeadLetterModel {
    static let pageSize = 200

    let entity: EntityRow
    private let client: any MessagingClient
    /// Other subscriptions on the same topic (0 for a queue); a resend is delivered to every one whose filter matches.
    let siblingSubscriptionCount: Int
    private let onFinished: @MainActor () async -> Void
    private let log: ActivityLog?
    private var runTask: Task<Void, Never>?

    private(set) var messages: [DeadLetterMessage] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    var errorMessage: String?

    /// Which queue of the subscription is shown. Resend and delete only apply to the dead-letter queue.
    var queue: QueueKind = .active
    var groupByReason = false
    var selection: Set<String> = []
    private(set) var run: ActionRun?

    init(entity: EntityRow, client: any MessagingClient, siblingSubscriptionCount: Int = 0,
         log: ActivityLog? = nil, onFinished: @escaping @MainActor () async -> Void = {}) {
        self.log = log
        self.entity = entity
        self.client = client
        self.siblingSubscriptionCount = siblingSubscriptionCount
        self.onFinished = onFinished
        // Nothing active but dead-lettered messages exist: start on the dead-letter tab.
        if entity.activeCount == 0 && entity.deadLetterCount > 0 { queue = .deadLetter }
    }

    // MARK: Resend / delete

    var isRunning: Bool { run.map { !$0.isFinished } ?? false }

    /// Resends or deletes the selected messages. Originals are only removed after a successful send (done by the helper).
    func start(_ action: DeadLetterAction) { begin(action, targets: selectedMessages) }

    /// Runs the previous action again on just the messages that failed.
    func retryFailed() {
        guard let run, run.isFinished else { return }
        let failed = run.messages.filter { run.results[$0.sequenceNumber]?.ok == false }
        begin(run.action, targets: failed)
    }

    private func begin(_ action: DeadLetterAction, targets: [DeadLetterMessage]) {
        guard queue == .deadLetter, !targets.isEmpty, !isRunning else { return }
        run = ActionRun(action: action, messages: targets)
        let verb = action == .resend ? "Resending" : "Deleting"
        log?.add("\(verb) \(targets.count) message(s) from \(entity.fullName).")
        let topic = entity.path, name = entity.subscription, client = client
        runTask = Task { [self] in
            _ = await DeadLetterActions.run(action, client: client, topic: topic, subscription: name,
                                            sequenceNumbers: targets.map(\.sequenceNumber)) { batch in
                await self.record(batch)
            }
            await self.finishRun()
        }
    }

    func cancelRun() { runTask?.cancel() }

    func dismissRun() { if !isRunning { run = nil } }

    private func record(_ batch: [MessageResult]) {
        for result in batch { run?.results[result.sequenceNumber] = result }
    }

    private func finishRun() async {
        run?.isFinished = true
        if let run, let log {
            let verb = run.action == .resend ? "Resent" : "Deleted"
            log.add("\(verb) \(run.succeeded) of \(run.messages.count) message(s) from \(entity.fullName).",
                    level: run.failed == 0 ? .success : .error)
            for r in run.results.values where !r.ok {
                log.add("#\(r.sequenceNumber): \(r.error ?? "failed")", level: .error)
            }
        }
        let removed = Set(run?.results.values.filter(\.ok).map(\.sequenceNumber) ?? [])
        messages.removeAll { removed.contains($0.sequenceNumber) }
        selection = []
        await onFinished()
    }

    func reload() async {
        messages = []
        selection = []
        await fetch(from: nil)
    }

    func loadMore() async {
        guard let last = messages.last else { return }
        await fetch(from: last.sequenceNumber + 1)
    }

    private func fetch(from sequence: Int64?) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let topic = entity.path, name = entity.subscription
            let page = switch queue {
            case .deadLetter: try await client.peekDeadLetters(topic: topic, subscription: name, max: Self.pageSize, fromSequence: sequence)
            case .active: try await client.peekActive(topic: topic, subscription: name, max: Self.pageSize, fromSequence: sequence)
            }
            messages += page
            hasMore = page.count == Self.pageSize
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            log?.add("Reading \(queue.rawValue.lowercased()) messages of \(entity.fullName) failed: \(error.localizedDescription)", level: .error)
        }
    }

    var rows: [DeadLetterRow] {
        groupByReason ? DeadLetterAnalysis.group(messages).map(DeadLetterRow.grouped) : messages.map(DeadLetterRow.single)
    }

    /// Every selected message, expanding selected groups.
    var selectedMessages: [DeadLetterMessage] {
        var seen = Set<Int64>()
        var result: [DeadLetterMessage] = []
        func visit(_ row: DeadLetterRow) {
            if selection.contains(row.id) {
                for m in row.message.map({ [$0] }) ?? row.group?.messages ?? [] where seen.insert(m.sequenceNumber).inserted {
                    result.append(m)
                }
            }
            row.children?.forEach(visit)
        }
        rows.forEach(visit)
        return result
    }

    /// The message shown in the inspector: the first selected one.
    var inspected: DeadLetterMessage? { selectedMessages.first }
}
