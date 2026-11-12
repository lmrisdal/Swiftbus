import Foundation
import Observation
import ServiceBusKit

enum SidebarSelection: Hashable {
    case allDeadLetters
    case topic(String)
    case queue(String)
}

/// A queue or topic, as the target of a context-menu action.
struct EntityRef: Hashable, Identifiable {
    enum Kind: Hashable { case queue, topic }
    let kind: Kind
    let name: String
    var id: String { "\(kind)/\(name)" }
    var kindName: String { kind == .queue ? "queue" : "topic" }
}

@MainActor @Observable
final class AppModel {
    private let store = ConnectionStore()
    let log = ActivityLog()

    var connections: [SavedConnection] = []
    var activeConnection: SavedConnection?
    /// Host of the active namespace, e.g. `contoso.servicebus.windows.net`. Not secret, so kept for display.
    private(set) var activeHost: String?
    var topics: [Topic] = []
    var queues: [Queue] = []
    var isLoading = false
    var errorMessage: String?
    var lastRefreshed: Date?

    var selection: SidebarSelection? {
        didSet {
            if selection != oldValue { entityFilter = "" }
            // A subscription from another topic must not keep scoping ⌘R after the sidebar moves on.
            switch selection {
            case .topic(let name)?:
                if case .subscription? = selectedEntityID, selectedEntity?.path != name { selectedEntityID = nil }
            case .queue(let name)?:
                // A queue shows an overview rather than a table to pick from (see SubscriptionTable), so it selects itself.
                selectedEntityID = .queue(name)
            default: break
            }
        }
    }
    /// Bumped by a scoped refresh so the open message list reloads too.
    private(set) var messageReloadToken = 0
    var selectedEntityID: EntityRow.ID?
    /// Filters the rows of the entity table (subscriptions/queues); reset when the sidebar selection changes.
    var entityFilter = ""

    /// Whether the activity log inspector is open, and how wide it is. Shared so the detail
    /// toolbar can make room for the log (see `ActivityLogToolbar`).
    var showingLog = false
    var logWidth: CGFloat = 320

    private var client: ManagementClient?
    /// Reads and resends dead-letters through the bundled .NET helper. Started lazily on first use.
    private(set) var messaging: (any MessagingClient)?

    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/swiftbus-helper")
    }

    init() {
        connections = store.load()
        backfillHosts()
    }

    // MARK: Connections

    /// Connections saved before the host was cached get it from their Keychain entry.
    private func backfillHosts() {
        var changed = false
        for i in connections.indices where connections[i].host == nil {
            if let secret = store.secret(for: connections[i]), let parsed = try? ConnectionString(secret) {
                connections[i].host = parsed.host
                changed = true
            }
        }
        if changed { store.save(connections) }
    }

    /// Saved connections, most recently opened first (never-opened ones keep their saved order).
    var connectionsByRecency: [SavedConnection] {
        connections.enumerated().sorted { a, b in
            switch (a.element.lastUsed, b.element.lastUsed) {
            case let (x?, y?): x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Validates and saves a connection, then connects to it.
    func add(name: String, connectionString: String) async throws {
        let parsed = try ConnectionString(connectionString)
        try await ManagementClient(connection: parsed).testConnection()
        let saved = SavedConnection(name: name.isEmpty ? parsed.namespace : name, host: parsed.host)
        store.setSecret(connectionString, for: saved)
        connections.append(saved)
        store.save(connections)
        await connect(saved)
    }

    func testConnection(_ connectionString: String) async throws {
        try await ManagementClient(connection: ConnectionString(connectionString)).testConnection()
    }

    func remove(_ connection: SavedConnection) {
        store.deleteSecret(for: connection)
        connections.removeAll { $0.id == connection.id }
        store.save(connections)
        if activeConnection?.id == connection.id { disconnect() }
    }

    private func disconnect() {
        let old = messaging
        Task { await old?.shutdown() }
        activeConnection = nil; activeHost = nil; client = nil; messaging = nil; topics = []; queues = []; selectedEntityID = nil
    }

    func connect(_ connection: SavedConnection) async {
        guard let secret = store.secret(for: connection) else {
            errorMessage = "The connection string for \(connection.name) is missing from the Keychain."
            log.add(errorMessage!, level: .error)
            return
        }
        do {
            let parsed = try ConnectionString(secret)
            disconnect()
            client = ManagementClient(connection: parsed)
            messaging = HelperMessagingClient(executableURL: Self.helperURL, connectionString: secret)
            var used = connection
            used.host = parsed.host
            used.lastUsed = Date()
            if let i = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[i] = used
                store.save(connections)
            }
            activeConnection = used
            activeHost = parsed.host
            log.add("Connected to \(connection.name) (\(parsed.host)).", level: .success)
            await refresh()
        } catch {
            fail(error, doing: "Connecting to \(connection.name)")
        }
    }

    // MARK: Data

    /// What ⌘R refreshes: the selected subscription, else the selected topic, else everything.
    var refreshScopeDescription: String {
        if let entity = selectedEntity { return "Refresh \(entity.fullName)" }
        if case .topic(let name)? = selection { return "Refresh topic \(name)" }
        if case .queue(let name)? = selection { return "Refresh queue \(name)" }
        return "Refresh all topics"
    }

    func refreshSelection() async {
        guard let client, !isLoading else { return }
        if let entity = selectedEntity {
            isLoading = true
            defer { isLoading = false }
            do {
                let fresh: EntityRow
                if let name = entity.subscription {
                    let sub = try await client.subscription(topic: entity.path, name: name)
                    replace(subscription: sub)
                    fresh = EntityRow(sub)
                } else {
                    let queue = try await client.queue(name: entity.path)
                    replace(queue: queue)
                    fresh = EntityRow(queue)
                }
                messageReloadToken += 1
                lastRefreshed = Date()
                log.add("Refreshed \(entity.fullName): \(fresh.deadLetterCount) dead-lettered, \(fresh.activeCount) active.")
            } catch { fail(error, doing: "Refreshing \(entity.fullName)") }
        } else if case .topic(let name)? = selection {
            await refresh(EntityRef(kind: .topic, name: name))
        } else if case .queue(let name)? = selection {
            await refresh(EntityRef(kind: .queue, name: name))
        } else {
            await refresh()
        }
    }

    // MARK: Queue and topic actions

    func queue(named name: String) -> Queue? { queues.first { $0.name == name } }
    func topic(named name: String) -> Topic? { topics.first { $0.name == name } }

    func isDisabled(_ ref: EntityRef) -> Bool {
        switch ref.kind {
        case .queue: queue(named: ref.name)?.isDisabled ?? false
        case .topic: topic(named: ref.name)?.isDisabled ?? false
        }
    }

    /// `sb://namespace.servicebus.windows.net/name`, the form Service Bus tools show for an entity.
    func url(for ref: EntityRef) -> String? {
        activeHost.map { "sb://\($0)/\(ref.name)" }
    }

    /// Reloads just this queue or topic (and a topic's subscriptions) and the open message list.
    func refresh(_ ref: EntityRef) async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch ref.kind {
            case .queue:
                replace(queue: try await client.queue(name: ref.name))
            case .topic:
                let fresh = try await client.topic(name: ref.name)
                if let i = topics.firstIndex(where: { $0.name == ref.name }) { topics[i] = fresh }
            }
            messageReloadToken += 1
            lastRefreshed = Date()
            log.add("Refreshed \(ref.kindName) \(ref.name).")
        } catch { fail(error, doing: "Refreshing \(ref.kindName) \(ref.name)") }
    }

    func setDisabled(_ disabled: Bool, _ ref: EntityRef) async {
        await perform("\(disabled ? "Disabling" : "Enabling") \(ref.kindName) \(ref.name)") { client in
            let status: EntityStatus = disabled ? .disabled : .active
            switch ref.kind {
            case .queue: try await client.setQueueStatus(name: ref.name, to: status)
            case .topic: try await client.setTopicStatus(name: ref.name, to: status)
            }
        }
        await refresh(ref)
    }

    func delete(_ ref: EntityRef) async {
        let ok = await perform("Deleting \(ref.kindName) \(ref.name)") { client in
            switch ref.kind {
            case .queue: try await client.deleteQueue(name: ref.name)
            case .topic: try await client.deleteTopic(name: ref.name)
            }
        }
        guard ok else { return }
        switch ref.kind {
        case .queue: if selection == .queue(ref.name) { selection = nil }
        case .topic: if selection == .topic(ref.name) { selection = nil }
        }
        await refresh()
    }

    func createSubscription(topic: String, name: String) async -> Bool {
        let ok = await perform("Creating subscription \(topic)/\(name)") { try await $0.createSubscription(topic: topic, name: name) }
        if ok { await refresh(EntityRef(kind: .topic, name: topic)) }
        return ok
    }

    func send(_ message: OutgoingMessage, count: Int, to ref: EntityRef) async -> Bool {
        guard let messaging else { return false }
        do {
            let sent = try await messaging.send(topic: ref.name, message: message, count: count)
            log.add("Sent \(sent) message\(sent == 1 ? "" : "s") to \(ref.kindName) \(ref.name).", level: .success)
            await refresh(ref)
            return true
        } catch { fail(error, doing: "Sending to \(ref.name)"); return false }
    }

    /// Deletes messages from a queue, or from every subscription of a topic.
    func purge(_ ref: EntityRef, scope: PurgeScope) async {
        guard let messaging else { return }
        let targets: [String?] = switch ref.kind {
        case .queue: [nil]
        case .topic: (topic(named: ref.name)?.subscriptions ?? []).map(\.name)
        }
        let what = switch scope { case .active: "messages"; case .deadLetter: "dead-letters"; case .all: "all messages" }
        let report = await PurgeActions.run(client: messaging, topic: ref.name, subscriptions: targets, scope: scope)
        log.add("Purged \(report.purged) \(what) from \(ref.kindName) \(ref.name).", level: report.failures.isEmpty ? .success : .error)
        for failure in report.failures { log.add("Purge failed: \(failure)", level: .error) }
        if !report.failures.isEmpty { errorMessage = "Some purges failed:\n" + report.failures.joined(separator: "\n") }
        await refresh(ref)
    }

    /// Runs a management call, logging success and surfacing failure. Returns whether it worked.
    @discardableResult
    private func perform(_ what: String, _ body: (ManagementClient) async throws -> Void) async -> Bool {
        guard let client else { return false }
        do {
            try await body(client)
            log.add("\(what) succeeded.", level: .success)
            return true
        } catch { fail(error, doing: what); return false }
    }

    private func replace(queue fresh: Queue) {
        if let i = queues.firstIndex(where: { $0.name == fresh.name }) { queues[i] = fresh }
    }

    private func replace(subscription fresh: Subscription) {
        guard let t = topics.firstIndex(where: { $0.name == fresh.topic }),
              let s = topics[t].subscriptions.firstIndex(where: { $0.name == fresh.name }) else { return }
        topics[t].subscriptions[s] = fresh
    }

    private func fail(_ error: Error, doing what: String) {
        errorMessage = error.localizedDescription
        log.add("\(what) failed: \(error.localizedDescription)", level: .error)
    }

    func refresh() async {
        guard let client, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedQueues = client.listQueues()
            async let loadedTopics = client.listTopics()
            (queues, topics) = try await (loadedQueues, loadedTopics)
            lastRefreshed = Date()
            errorMessage = nil
            let dead = topics.reduce(0) { $0 + $1.deadLetterCount } + queues.reduce(0) { $0 + $1.deadLetterCount }
            log.add("Loaded \(queues.count) queues, \(topics.count) topics, \(dead) dead-lettered messages.", level: .info)
        } catch {
            fail(error, doing: "Refresh")
        }
    }

    var selectedEntity: EntityRow? {
        guard let id = selectedEntityID else { return nil }
        return allEntities.first { $0.id == id }
    }

    private var allEntities: [EntityRow] {
        queues.map(EntityRow.init) + topics.flatMap(\.subscriptions).map(EntityRow.init)
    }

    var visibleQueues: [Queue] {
        queues
    }

    var visibleTopics: [Topic] {
        topics
    }

    /// Queues and subscriptions for the current sidebar selection, dead-letters first.
    var visibleEntities: [EntityRow] {
        let rows: [EntityRow]
        let requireDeadLetters: Bool
        switch selection {
        case .topic(let name):
            rows = (topics.first { $0.name == name }?.subscriptions ?? []).map(EntityRow.init)
            requireDeadLetters = false
        case .queue(let name):
            rows = queues.filter { $0.name == name }.map(EntityRow.init)
            requireDeadLetters = false
        case .allDeadLetters?:
            // "All dead-letters" only makes sense for entities that have some.
            rows = allEntities
            requireDeadLetters = true
        case nil:
            rows = []
            requireDeadLetters = false
        }
        return rows
            .filter { !requireDeadLetters || $0.deadLetterCount + $0.transferDeadLetterCount > 0 }
            .filter { entityFilter.isEmpty || $0.fullName.localizedCaseInsensitiveContains(entityFilter) }
            .sorted { ($0.deadLetterCount, $1.fullName) > ($1.deadLetterCount, $0.fullName) }
    }
}
