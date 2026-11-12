import Foundation
import Observation
import ServiceBusKit

/// A table row: either one message, or a group of dead-letters that share a failure reason.
struct MessageRow: Identifiable, Hashable {
    let id: String
    let message: DeadLetterMessage?
    let group: DeadLetterGroup?
    var children: [MessageRow]?

    static func == (a: MessageRow, b: MessageRow) -> Bool { a.id == b.id && a.children?.count == b.children?.count }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func single(_ m: DeadLetterMessage) -> MessageRow {
        MessageRow(id: "m\(m.sequenceNumber)", message: m, group: nil, children: nil)
    }
    static func grouped(_ g: DeadLetterGroup) -> MessageRow {
        MessageRow(id: "g\(g.id)", message: nil, group: g, children: g.messages.map(single))
    }
}

enum QueueKind: String, CaseIterable, Identifiable {
    case active = "Active"
    case deadLetter = "Dead-letter"
    case transferDeadLetter = "Transfer DLQ"
    var id: String { rawValue }

    var loadingTitle: String {
        switch self {
        case .deadLetter: "Reading dead-letter queue…"
        case .transferDeadLetter: "Reading transfer dead-letter queue…"
        case .active: "Reading active messages…"
        }
    }
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

/// Loads and presents the messages (active, dead-letter or transfer dead-letter) of one subscription or queue.
@MainActor @Observable
final class MessageListModel {
    static let pageSize = 200

    /// Updated by the view when the app reloads the entity, so the header counts stay current.
    var entity: EntityRow
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

    /// Which queue of the subscription is shown. Resend only applies to the dead-letter queue; delete also to active messages.
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
        guard !targets.isEmpty, !isRunning else { return }
        // Resend only makes sense for dead-letters; transfer dead-letters are read-only.
        let deadLetter = queue == .deadLetter
        guard deadLetter || (queue == .active && action == .delete) else { return }
        run = ActionRun(action: action, messages: targets)
        let verb = action == .resend ? "Resending" : "Deleting"
        log?.add("\(verb) \(targets.count) \(queue == .active ? "active " : "")message(s) from \(entity.fullName).")
        let topic = entity.path, name = entity.subscription, client = client
        runTask = Task { [self] in
            _ = await DeadLetterActions.run(action, client: client, topic: topic, subscription: name,
                                            sequenceNumbers: targets.map(\.sequenceNumber),
                                            deadLetter: deadLetter) { batch in
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

    // MARK: Repair and resubmit

    /// Sends an edited copy of `original` to the queue or topic, then, if asked and the copy was sent, removes
    /// the original from the dead-letter queue. Returns a user-readable error, or nil on success.
    func resubmit(_ draft: OutgoingMessage, original: DeadLetterMessage, removeOriginal: Bool) async -> String? {
        if let issue = draft.propertyProblem { return issue }
        let topic = entity.path
        do {
            try await client.send(topic: topic, message: draft)
        } catch {
            log?.add("Resubmitting #\(original.sequenceNumber) to \(topic) failed: \(error.localizedDescription)", level: .error)
            return error.localizedDescription
        }
        log?.add("Resubmitted an edited copy of #\(original.sequenceNumber) to \(topic).", level: .success)
        if removeOriginal && queue == .deadLetter {
            let failure: String?
            do {
                let result = try await client.delete(topic: topic, subscription: entity.subscription, deadLetter: true,
                                                     sequenceNumbers: [original.sequenceNumber]).first
                failure = result?.ok == true ? nil : (result?.error ?? "The original was not found.")
            } catch {
                failure = error.localizedDescription
            }
            if let failure {
                log?.add("The copy was sent, but removing #\(original.sequenceNumber) from the dead-letter queue failed: \(failure)", level: .error)
                await onFinished()
                return "The copy was sent, but the original could not be removed from the dead-letter queue: \(failure)"
            }
            messages.removeAll { $0.sequenceNumber == original.sequenceNumber }
            selection = []
        }
        await onFinished()
        return nil
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
        // Service Bus answers a peek on an unused transfer dead-letter queue with a generic
        // "unable to process the request" error, so skip the call when the counts say it is empty.
        if queue == .transferDeadLetter && entity.transferDeadLetterCount == 0 {
            hasMore = false
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let topic = entity.path, name = entity.subscription
            let page = switch queue {
            case .deadLetter: try await client.peekDeadLetters(topic: topic, subscription: name, max: Self.pageSize, fromSequence: sequence)
            case .transferDeadLetter: try await client.peekTransferDeadLetters(topic: topic, subscription: name, max: Self.pageSize, fromSequence: sequence)
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

    var rows: [MessageRow] {
        groupByReason ? DeadLetterAnalysis.group(messages).map(MessageRow.grouped) : messages.map(MessageRow.single)
    }

    /// Every selected message, expanding selected groups.
    var selectedMessages: [DeadLetterMessage] { messages(for: selection) }

    /// The messages behind a set of row IDs (as a context menu passes them), expanding groups, in table order.
    func messages(for ids: Set<String>) -> [DeadLetterMessage] {
        var seen = Set<Int64>()
        var result: [DeadLetterMessage] = []
        func visit(_ row: MessageRow) {
            if ids.contains(row.id) {
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
