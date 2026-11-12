import AppKit
import ServiceBusKit
import SwiftUI

/// A destructive action waiting for the user's confirmation.
private enum PendingAction: Identifiable {
    case delete(EntityRef)
    case purge(EntityRef, PurgeScope)
    case deleteSubscription(Subscription)
    case purgeSubscription(Subscription, PurgeScope)

    var id: String {
        switch self {
        case .delete(let ref): "delete/\(ref.id)"
        case .purge(let ref, let scope): "purge/\(ref.id)/\(scope)"
        case .deleteSubscription(let sub): "delete/\(sub.id)"
        case .purgeSubscription(let sub, let scope): "purge/\(sub.id)/\(scope)"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showingAddConnection = false
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsPane.key) private var settingsPane = SettingsPane.general
    @State private var queuesExpanded = true
    @State private var topicsExpanded = true
    /// Topics opened in the sidebar tree to show their subscriptions.
    @State private var expandedTopics: Set<String> = []
    @State private var hoveringFilter = false
    @State private var sendTarget: EntityRef?
    @State private var subscriptionTopic: EntityRef?
    @State private var pending: PendingAction?
    @FocusState private var searchFocused: Bool
    @AppStorage(LayoutSetting.key) private var layout = LayoutSetting.tree

    /// Each layout keeps one fixed set of columns: swapping split views on selection would
    /// rebuild the table and lose its sort and scroll position.
    @ViewBuilder private var splitView: some View {
        switch layout {
        case .tree:
            NavigationSplitView {
                sidebar
            } detail: {
                treeDetail
            }
        case .columns:
            NavigationSplitView {
                sidebar
            } content: {
                contentColumn
                    .navigationSplitViewColumnWidth(min: 320, ideal: 480)
            } detail: {
                detailColumn
            }
        }
    }

    /// The tree layout's single pane: messages for a queue or subscription, a summary for a topic
    /// (its subscriptions are already in the tree), or the table of all dead-letters, whose rows
    /// open in the tree.
    @ViewBuilder private var treeDetail: some View {
        switch model.selection {
        case .topic(let name)?:
            Group {
                if let topic = model.topic(named: name) {
                    TopicOverview(topic: topic)
                } else {
                    contentColumn
                }
            }
            .toolbar { ActivityLogToolbar(model: model) }
        case .allDeadLetters?:
            if model.activeConnection != nil {
                SubscriptionTable(searchFocused: $searchFocused)
                    .toolbar { ActivityLogToolbar(model: model) }
            } else {
                contentColumn.toolbar { ActivityLogToolbar(model: model) }
            }
        case .queue?, .subscription?:
            detailColumn
        case nil:
            contentColumn.toolbar { ActivityLogToolbar(model: model) }
        }
    }

    var body: some View {
        @Bindable var model = model
        splitView
        .onChange(of: layout) { _, new in
            // The column layout's sidebar has no subscription rows: show the subscription's topic,
            // which keeps the subscription selected in its table.
            if new == .columns, case .subscription(let topic, _)? = model.selection { model.selection = .topic(topic) }
            // The tree layout opens the chosen row in place of the table, so go straight to it.
            if new == .tree, let entity = model.selectedEntity, model.selection != nil {
                model.selection = entity.isQueue ? .queue(entity.path) : .subscription(topic: entity.path, name: entity.name)
            }
        }
        .background(WindowCloser(shouldClose: model.activeConnection == nil) {
            // The system opens every Window scene at launch (or restores this one). Without a
            // chosen connection, hand over to the connection picker.
            openWindow(id: "welcome")
        })
        .navigationTitle(model.activeConnection?.name ?? "Swiftbus")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu("Connections", systemImage: "externaldrive.connected.to.line.below") {
                    ForEach(model.connections) { c in
                        Button(c.name) { Task { await model.connect(c) } }
                    }
                    Divider()
                    Button("Add connection…") { showingAddConnection = true }
                    Button("Manage connections…") {
                        settingsPane = .connections
                        openSettings()
                    }
                        .disabled(model.connections.isEmpty)
                }
            }
            ToolbarItem(placement: .navigation) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshSelection() } }
                    .help(model.refreshScopeDescription)
                    .keyboardShortcut("r")
                    .disabled(model.activeConnection == nil || model.isLoading)
            }
        }
        .focusedSceneValue(\.focusSearch, { searchFocused = true })
        .focusedSceneValue(\.toggleActivityLog, { [model] in model.showingLog.toggle() })
        .inspector(isPresented: $model.showingLog) {
            ActivityLogView(log: model.log)
                // Let the desktop show through the whole pane, like its toolbar strip.
                .scrollContentBackground(.hidden)
                .background { BehindWindowBlur().ignoresSafeArea() }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 500)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [model] in model.logWidth = $0 }
        }
        .sheet(isPresented: $showingAddConnection) { ConnectionSheet() }
        .sheet(item: $sendTarget) { SendMessagesSheet(target: $0) }
        .sheet(item: $subscriptionTopic) { CreateSubscriptionSheet(topic: $0.name) }
        .confirmationDialog(pending.map(confirmationTitle) ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { action in
            Button(confirmationButton(action), role: .destructive) {
                switch action {
                case .delete(let ref): Task { await model.delete(ref) }
                case .purge(let ref, let scope): Task { await model.purge(ref, scope: scope) }
                case .deleteSubscription(let sub): Task { await model.delete(sub) }
                case .purgeSubscription(let sub, let scope): Task { await model.purge(sub, scope: scope) }
                }
            }
        } message: { Text(confirmationMessage($0)) }
        .alert("Error", isPresented: .init(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var sidebar: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section(isExpanded: $queuesExpanded) {
                    ForEach(model.visibleQueues) { queue in
                        SidebarRow(title: queue.name, isQueue: true, count: queue.deadLetterCount, isDisabled: queue.isDisabled,
                                   counts: (queue.activeCount, queue.deadLetterCount, queue.transferDeadLetterCount),
                                   isSelected: model.selection == .queue(queue.name))
                            .tag(SidebarSelection.queue(queue.name))
                            .contextMenu { entityMenu(EntityRef(kind: .queue, name: queue.name)) }
                    }
                } header: { SidebarHeader(title: "Queues", count: model.visibleQueues.count) }
                Section(isExpanded: $topicsExpanded) {
                    ForEach(model.visibleTopics) { topic in
                        if layout == .columns {
                            SidebarRow(title: topic.name, isQueue: false, count: topic.deadLetterCount, isDisabled: topic.isDisabled)
                                .tag(SidebarSelection.topic(topic.name))
                                .contextMenu { entityMenu(EntityRef(kind: .topic, name: topic.name)) }
                        } else {
                            DisclosureGroup(isExpanded: expansion(of: topic.name)) {
                                ForEach(topic.subscriptions) { sub in
                                    SidebarRow(title: sub.name, isQueue: false, count: sub.deadLetterCount,
                                               isDisabled: sub.status == "Disabled",
                                               counts: (sub.activeCount, sub.deadLetterCount, sub.transferDeadLetterCount),
                                               isSelected: model.selection == .subscription(topic: topic.name, name: sub.name),
                                               systemImage: "envelope")
                                        .tag(SidebarSelection.subscription(topic: topic.name, name: sub.name))
                                        .contextMenu { subscriptionMenu(sub) }
                                }
                            } label: {
                                SidebarRow(title: topic.name, isQueue: false, count: topic.deadLetterCount, isDisabled: topic.isDisabled)
                                    .tag(SidebarSelection.topic(topic.name))
                                    .onDoubleClick { toggleExpansion(of: topic.name) }
                                    .contextMenu {
                                        Button(expandedTopics.contains(topic.name) ? "Collapse" : "Expand") {
                                            toggleExpansion(of: topic.name)
                                        }
                                        Divider()
                                        entityMenu(EntityRef(kind: .topic, name: topic.name))
                                    }
                            }
                        }
                    }
                } header: { SidebarHeader(title: "Topics", count: model.visibleTopics.count) }
            }
            .scrollContentBackground(.hidden)
            // Reveal a subscription picked elsewhere (e.g. in the table) in the tree.
            .onChange(of: model.selection) { _, new in
                if case .subscription(let topic, _)? = new { expandedTopics.insert(topic) }
            }
            customFilters
        }
        // Subscription names are often GUIDs with counts after them, so allow a wide tree.
        .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 700)
    }

    private func expansion(of topic: String) -> Binding<Bool> {
        Binding(get: { expandedTopics.contains(topic) },
                set: { if $0 { expandedTopics.insert(topic) } else { expandedTopics.remove(topic) } })
    }

    private func toggleExpansion(of topic: String) {
        withAnimation {
            if expandedTopics.contains(topic) { expandedTopics.remove(topic) } else { expandedTopics.insert(topic) }
        }
    }

    // MARK: Queue and topic context menu

    @ViewBuilder private func entityMenu(_ ref: EntityRef) -> some View {
        let kind = ref.kindName.capitalized
        let disabled = model.isDisabled(ref)
        Button(disabled ? "Enable \(kind)" : "Disable \(kind)") { Task { await model.setDisabled(!disabled, ref) } }
        Button("Delete \(kind)…") { pending = .delete(ref) }
        Button("Refresh \(kind)") { Task { await model.refresh(ref) } }
        Divider()
        if ref.kind == .topic {
            Button("Create Subscription…") { subscriptionTopic = ref }
            Divider()
        }
        Button("Copy \(kind) URL") { copyToPasteboard(model.url(for: ref)) }
        Divider()
        Button("Send Messages…") { sendTarget = ref }
        Menu("Purge") {
            Button("Messages…") { pending = .purge(ref, .active) }
            Button("Dead-letter Queue Messages…") { pending = .purge(ref, .deadLetter) }
            Divider()
            Button("All Messages…") { pending = .purge(ref, .all) }
        }
    }

    @ViewBuilder private func subscriptionMenu(_ sub: Subscription) -> some View {
        let disabled = sub.status == "Disabled"
        Button("Delete Subscription…") { pending = .deleteSubscription(sub) }
        Button(disabled ? "Enable Subscription" : "Disable Subscription") { Task { await model.setDisabled(!disabled, sub) } }
        Button("Refresh Subscription") { Task { await model.refresh(sub) } }
        Divider()
        Button("Copy Subscription URL") { copyToPasteboard(model.url(for: sub)) }
        Button("Copy Dead-letter Queue URL") { copyToPasteboard(model.url(for: sub, deadLetter: true)) }
        Divider()
        Menu("Purge") {
            Button("Messages…") { pending = .purgeSubscription(sub, .active) }
            Button("Dead-letter Queue Messages…") { pending = .purgeSubscription(sub, .deadLetter) }
            Divider()
            Button("All Messages…") { pending = .purgeSubscription(sub, .all) }
        }
    }

    private func copyToPasteboard(_ string: String?) {
        guard let string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func confirmationTitle(_ action: PendingAction) -> String {
        switch action {
        case .delete(let ref): "Delete \(ref.kindName) “\(ref.name)”?"
        case .purge(let ref, _): "Purge \(ref.kindName) “\(ref.name)”?"
        case .deleteSubscription(let sub): "Delete subscription “\(sub.name)”?"
        case .purgeSubscription(let sub, _): "Purge subscription “\(sub.name)”?"
        }
    }

    private func confirmationButton(_ action: PendingAction) -> String {
        switch action {
        case .delete, .deleteSubscription: "Delete"
        case .purge, .purgeSubscription: "Purge"
        }
    }

    private func confirmationMessage(_ action: PendingAction) -> String {
        switch action {
        case .delete(let ref):
            return ref.kind == .topic
                ? "This deletes the topic, all its subscriptions and every message in them. It can't be undone."
                : "This deletes the queue and every message in it, including its dead-letters. It can't be undone."
        case .deleteSubscription:
            return "This deletes the subscription, its rules and every message in it, including its dead-letters. It can't be undone."
        case .purgeSubscription(_, let scope):
            switch scope {
            case .active: return "Permanently deletes the active messages in this subscription. Dead-letters are kept."
            case .deadLetter: return "Permanently deletes the dead-lettered messages in this subscription."
            case .all: return "Permanently deletes all active and dead-lettered messages in this subscription."
            }
        case .purge(let ref, let scope):
            let where_ = ref.kind == .topic ? "every subscription of this topic" : "this queue"
            switch scope {
            case .active: return "Permanently deletes the active messages in \(where_). Dead-letters are kept."
            case .deadLetter: return "Permanently deletes the dead-lettered messages in \(where_)."
            case .all: return "Permanently deletes all active and dead-lettered messages in \(where_)."
            }
        }
    }

    /// Custom filters stay pinned to the bottom of the sidebar, outside the scrolling list.
    private var customFilters: some View {
        let isSelected = model.selection == .allDeadLetters
        let total = model.queues.reduce(0) { $0 + $1.deadLetterCount } + model.topics.reduce(0) { $0 + $1.deadLetterCount }
        return VStack(alignment: .leading, spacing: 6) {
            Text("SMART FILTERS")
                .font(.caption2.weight(.bold)).tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            Button {
                model.selection = isSelected ? nil : .allDeadLetters
            } label: {
                HStack(spacing: 8) {
                    Text("All dead-letters").foregroundStyle(isSelected ? .white : .primary)
                    Spacer()
                    CountPill(count: total)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(Theme.gradient(Theme.alertTint))
                              : hoveringFilter ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Unselected it looks like a plain sidebar row; a faint fill only on hover.
            .onHover { hoveringFilter = $0 }
        }
        .padding(10)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var contentColumn: some View {
        if model.activeConnection == nil {
            EmptyState(title: "Connect a namespace", systemImage: "network",
                       message: model.connections.isEmpty
                           ? "Add a Service Bus connection string to see your queues, topics and dead-letters."
                           : "Pick a saved connection, or add a new one.") {
                VStack(spacing: 8) {
                    ForEach(model.connections) { c in
                        Button(c.name) { Task { await model.connect(c) } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Button("Add connection…", systemImage: "plus") { showingAddConnection = true }
                        .controlSize(.large)
                }
            }
        } else if model.selection == nil {
            EmptyState(title: "Pick something to inspect", systemImage: "sidebar.left",
                       message: "Choose a queue, topic or smart filter in the sidebar.")
        } else {
            SubscriptionTable(searchFocused: $searchFocused)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        if let entity = model.selectedEntity, let messaging = model.messaging {
            MessagesView(model: DeadLetterModel(
                entity: entity, client: messaging,
                siblingSubscriptionCount: entity.isQueue ? 0 : max((model.topics.first { $0.name == entity.path }?.subscriptions.count ?? 1) - 1, 0),
                log: model.log,
                onFinished: { [model] in await model.refresh() }))
                .id(entity.id)
        } else {
            VStack {
                if model.activeConnection != nil && model.selection != nil {
                    EmptyState(title: "No subscription selected", systemImage: "tray.2",
                               message: "Choose a queue or subscription to browse its messages.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ActivityLogToolbar(model: model) }
        }
    }
}

/// The trailing end of the detail toolbar, like Xcode's inspector: while the log is open, a
/// blank item as wide as the log pushes the other items left so none sit above it, and the
/// toggle stays at the far right. It must come last in the same `.toolbar` as the detail
/// items: SwiftUI does not keep a stable order between separate `.toolbar` modifiers.
struct ActivityLogToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        if model.showingLog {
            if #available(macOS 26, *) {
                ToolbarItem { spacer }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem { spacer }
            }
        }
        // On macOS 26+ neighbouring items share one glass capsule; a fixed spacer gives the
        // toggle its own, like Xcode's inspector button.
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItem {
            Button("Activity log", systemImage: "sidebar.trailing") { model.showingLog.toggle() }
                .help("Show or hide the activity log")
        }
    }

    /// The log's width minus the toggle button that sits above it.
    private var spacer: some View {
        Color.clear.frame(width: max(model.logWidth - 52, 0), height: 1)
    }
}

// MARK: - Topic overview

/// What the tree layout shows for a selected topic: its message totals, then the settings and
/// dates from its description. Its subscriptions are picked from the tree.
private struct TopicOverview: View {
    let topic: Topic

    var body: some View {
        let d = topic.details
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                EntityIcon(isQueue: false, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(topic.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(topic.isDisabled ? "Topic · Disabled" : "Topic").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.paneHeaderHeight)
            Divider()
            Form {
                Section("Messages") {
                    LabeledContent("Subscriptions", value: topic.subscriptions.count, format: .number)
                    LabeledContent("Active") { CountPill(count: topic.subscriptions.reduce(0) { $0 + $1.activeCount }, kind: .active) }
                    LabeledContent("Dead-lettered") { CountPill(count: topic.deadLetterCount, kind: .deadLetter) }
                    LabeledContent("Transfer dead-lettered") { CountPill(count: topic.transferDeadLetterCount, kind: .transfer) }
                    if let scheduled = d.scheduledMessageCount {
                        LabeledContent("Scheduled", value: scheduled, format: .number)
                    }
                }
                Section("Settings") {
                    LabeledContent("Status", value: topic.isDisabled ? "Disabled" : "Active")
                    if let size = d.sizeInBytes {
                        LabeledContent("Size", value: sizeText(size, max: d.maxSizeInMegabytes))
                    }
                    LabeledContent("Default message time to live", value: TopicDetails.describe(d.defaultMessageTimeToLive))
                    LabeledContent("Auto-delete on idle", value: TopicDetails.describe(d.autoDeleteOnIdle))
                    if let dup = d.requiresDuplicateDetection {
                        LabeledContent("Duplicate detection",
                                       value: dup ? "On, \(TopicDetails.describe(d.duplicateDetectionWindow)) window" : "Off")
                    }
                    flag("Batched operations", d.enableBatchedOperations)
                    flag("Message ordering", d.supportOrdering)
                    flag("Partitioning", d.enablePartitioning)
                }
                Section("Dates") {
                    date("Created", d.createdAt)
                    date("Updated", d.updatedAt)
                    date("Last accessed", d.accessedAt)
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)
        }
    }

    private func sizeText(_ bytes: Int, max megabytes: Int?) -> String {
        let used = bytes.formatted(.byteCount(style: .file))
        guard let megabytes else { return used }
        return "\(used) of \((Int64(megabytes) * 1_048_576).formatted(.byteCount(style: .memory)))"
    }

    @ViewBuilder private func flag(_ title: String, _ value: Bool?) -> some View {
        if let value { LabeledContent(title, value: value ? "On" : "Off") }
    }

    private func date(_ title: String, _ value: Date?) -> some View {
        LabeledContent(title, value: value?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
    }
}

// MARK: - Sidebar pieces

private struct SidebarHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(count, format: .number)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let isQueue: Bool
    let count: Int
    var isDisabled = false
    /// Shown after the name as "(active, dead-letter, transfer)". Rows that have it skip the
    /// dead-letter pill, since the same number is already in the tuple.
    var counts: (active: Int, deadLetter: Int, transfer: Int)?
    /// The sidebar List does not report selection to its rows on macOS, so the caller passes it.
    var isSelected = false
    var systemImage: String?
    var body: some View {
        HStack(spacing: 8) {
            EntityIcon(isQueue: isQueue, systemName: systemImage)
            Text(title).lineLimit(1).truncationMode(.middle).foregroundStyle(isDisabled ? .secondary : .primary)
            if let counts {
                countsText(counts).font(.callout.monospacedDigit()).lineLimit(1).fixedSize()
                    .help("Active, dead-letter, transfer dead-letter")
            }
            Spacer(minLength: 4)
            if isDisabled { Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Disabled") }
            if counts == nil, count > 0 { CountPill(count: count) }
        }
        .padding(.vertical, 1)
    }

    /// Zeroes stay muted; non-zero numbers take their kind's colour so problems stand out.
    private func countsText(_ c: (active: Int, deadLetter: Int, transfer: Int)) -> Text {
        // On a selected row the accent background swallows the tints, so fall back to the
        // row's own (white) foreground and let weight carry the emphasis.
        let selected = isSelected
        func number(_ n: Int, _ tint: Color) -> Text {
            guard n > 0 else { return Text("\(n)").foregroundStyle(.secondary) }
            return selected ? Text("\(n)").fontWeight(.bold).foregroundStyle(.primary)
                            : Text("\(n)").fontWeight(.semibold).foregroundStyle(tint)
        }
        let sep = Text(", ").foregroundStyle(.secondary)
        return Text("(").foregroundStyle(.secondary)
            + number(c.active, Theme.active) + sep
            + number(c.deadLetter, Theme.deadLetter) + sep
            + number(c.transfer, Theme.transfer)
            + Text(")").foregroundStyle(.secondary)
    }
}

struct SubscriptionTable: View {
    var searchFocused: FocusState<Bool>.Binding
    @Environment(AppModel.self) private var model
    /// Dead-letters first by default; clicking a count column header replaces it.
    @State private var sortOrder = [KeyPathComparator(\EntityRow.deadLetterCount, order: .reverse)]

    /// The model's rows ordered by the chosen column, with the name as a stable tiebreaker.
    private var sortedEntities: [EntityRow] {
        model.visibleEntities.sorted(using: sortOrder + [KeyPathComparator(\EntityRow.fullName)])
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            if let queue = selectedQueue {
                // A queue is a single entity: a one-row table would only repeat the header, so
                // show its numbers instead. Its messages open in the detail column on selection.
                if queue.isDisabled {
                    queueStatus(queue)
                }
                Divider()
                queueOverview(queue)
            } else {
                Divider()
                table
                Divider()
                filterField
            }
        }
        // Picking a row moves focus to the table, so keyboard navigation works right away.
        .onChange(of: model.selectedEntityID) { searchFocused.wrappedValue = false }
    }

    private var selectedQueue: Queue? {
        guard case .queue(let name)? = model.selection else { return nil }
        return model.queues.first { $0.name == name }
    }

    // MARK: Queue overview

    /// Only shown for a disabled queue; the normal state needs no label.
    private func queueStatus(_ queue: Queue) -> some View {
        HStack(spacing: 6) {
            if queue.isDisabled {
                Image(systemName: "pause.circle")
                Text("Disabled: not accepting messages")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func queueOverview(_ queue: Queue) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                StatTile(title: "Active", value: queue.activeCount, systemImage: "bolt.fill", tint: Theme.active)
                StatTile(title: "Dead-lettered", value: queue.deadLetterCount, systemImage: "exclamationmark.triangle.fill",
                         tint: Theme.deadLetter, emphasized: queue.deadLetterCount > 0)
                StatTile(title: "Transfer dead-lettered", value: queue.transferDeadLetterCount,
                         systemImage: "arrow.left.arrow.right", tint: Theme.transfer)
            }
            .padding(12)
        }
    }

    /// The selected topic/queue and its totals, in the same fixed-height band as the detail
    /// pane's header so the two dividers line up.
    private var summary: some View {
        let rows = model.visibleEntities
        let dead = rows.reduce(0) { $0 + $1.deadLetterCount }
        let active = rows.reduce(0) { $0 + $1.activeCount }
        let title: String
        let subtitle: String
        let isQueue: Bool
        switch model.selection {
        case .topic(let name)?, .subscription(let name, _)?: (title, subtitle, isQueue) = (name, "Topic", false)
        case .queue(let name)?: (title, subtitle, isQueue) = (name, "Queue", true)
        default: (title, subtitle, isQueue) = ("All dead-letters", "Topics and queues", false)
        }
        return HStack(spacing: 10) {
            EntityIcon(isQueue: isQueue, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                MetricChip(label: "Active", count: active, kind: .active)
                MetricChip(label: "DLQ", count: dead, kind: .deadLetter)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.paneHeaderHeight)
    }

    /// Sits below the table so it reads as filtering these rows, not the detail column.
    private var filterField: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $model.entityFilter)
                .textFieldStyle(.plain)
                .focused(searchFocused)
                .onExitCommand { model.entityFilter = "" }
            if !model.entityFilter.isEmpty {
                Button("Clear filter", systemImage: "xmark.circle.fill") { model.entityFilter = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .overlay(Capsule().strokeBorder(searchFocused.wrappedValue ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: searchFocused.wrappedValue)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var table: some View {
        @Bindable var model = model
        // TableColumnBuilder has no `if` before macOS 14.4, so pick one of two column sets.
        return Group {
            if model.selection == .allDeadLetters {
                Table(sortedEntities, selection: $model.selectedEntityID, sortOrder: $sortOrder) {
                    TableColumn("Topic") { Text($0.isQueue ? "—" : $0.path).foregroundStyle($0.isQueue ? .secondary : .primary) }
                    TableColumn("Name") { nameCell($0) }
                    TableColumn("Active", value: \.activeCount) { activeCell($0) }
                        .width(min: 60, ideal: 90, max: 110)
                    TableColumn("Dead-letter", value: \.deadLetterCount) { deadLetterCell($0) }
                        .width(min: 60, ideal: 90, max: 110)
                    TableColumn("Transfer DL", value: \.transferDeadLetterCount) { transferCell($0) }
                        .width(min: 60, ideal: 90, max: 110)
                }
            } else {
                Table(sortedEntities, selection: $model.selectedEntityID, sortOrder: $sortOrder) {
                    TableColumn("Name") { nameCell($0) }
                    TableColumn("Active", value: \.activeCount) { activeCell($0) }
                        .width(min: 60, ideal: 90, max: 110)
                    TableColumn("Dead-letter", value: \.deadLetterCount) { deadLetterCell($0) }
                        .width(min: 60, ideal: 90, max: 110)
                    TableColumn("Transfer DL", value: \.transferDeadLetterCount) { transferCell($0) }
                        .width(min: 60, ideal: 90, max: 110)
                }
            }
        }
        .overlay {
            if model.isLoading && model.topics.isEmpty && model.queues.isEmpty {
                LoadingState(title: "Loading queues and topics…").background(.background)
            } else if model.visibleEntities.isEmpty {
                Group {
                    if model.entityFilter.isEmpty {
                        EmptyState.allClear("No dead-letters", message: "Everything here is flowing. Nice.")
                    } else {
                        EmptyState(title: "No matches", systemImage: "magnifyingglass",
                                   message: "Nothing matches “\(model.entityFilter)”.")
                    }
                }
                .background(.background)
            }
        }
    }

    private func nameCell(_ e: EntityRow) -> some View {
        HStack(spacing: 7) {
            EntityIcon(isQueue: e.isQueue)
            Text(e.name).fontWeight(e.deadLetterCount > 0 ? .semibold : .regular).lineLimit(1)
        }
    }
    private func activeCell(_ e: EntityRow) -> some View {
        CountPill(count: e.activeCount, kind: .active, onSelection: model.selectedEntityID == e.id)
    }
    private func deadLetterCell(_ e: EntityRow) -> some View {
        CountPill(count: e.deadLetterCount, kind: .deadLetter, onSelection: model.selectedEntityID == e.id)
    }
    private func transferCell(_ e: EntityRow) -> some View {
        CountPill(count: e.transferDeadLetterCount, kind: .transfer, onSelection: model.selectedEntityID == e.id)
    }
}

/// The translucent, behind-window blur macOS uses for sidebars and toolbars. SwiftUI's
/// `Material` only blends with content inside the window, so this wraps `NSVisualEffectView`.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Closes the hosting window once, on first appearance, when `shouldClose` is true.
private struct WindowCloser: NSViewRepresentable {
    let shouldClose: Bool
    let then: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        guard shouldClose else { return view }
        DispatchQueue.main.async {
            view.window?.close()
            then()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
