import AppKit
import ServiceBusKit
import SwiftUI

/// A destructive action waiting for the user's confirmation.
private enum PendingAction: Identifiable {
    case delete(EntityRef)
    case purge(EntityRef, PurgeScope)

    var id: String {
        switch self {
        case .delete(let ref): "delete/\(ref.id)"
        case .purge(let ref, let scope): "purge/\(ref.id)/\(scope)"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAddConnection = false
    @State private var queuesExpanded = true
    @State private var topicsExpanded = true
    @State private var hoveringFilter = false
    @State private var sendTarget: EntityRef?
    @State private var subscriptionTopic: EntityRef?
    @State private var pending: PendingAction?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        // One fixed three-column layout: swapping split views on selection would rebuild the
        // table and lose its sort and scroll position.
        NavigationSplitView {
            sidebar
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 320, ideal: 480)
        } detail: {
            detailColumn
        }
        .navigationTitle(model.activeConnection?.name ?? "Swiftbus")
        .navigationSubtitle(model.lastRefreshed.map { "Refreshed \($0.formatted(date: .omitted, time: .standard))" } ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu("Connections", systemImage: "externaldrive.connected.to.line.below") {
                    ForEach(model.connections) { c in
                        Button(c.name) { Task { await model.connect(c) } }
                    }
                    Divider()
                    Button("Add connection…") { showingAddConnection = true }
                    if let active = model.activeConnection {
                        Button("Remove \(active.name)", role: .destructive) { model.remove(active) }
                    }
                }
            }
            ToolbarItem(placement: .navigation) {
                Menu("Auto-refresh", systemImage: "timer") {
                    Picker("Auto-refresh", selection: $model.autoRefreshSeconds) {
                        Text("Off").tag(0)
                        Text("Every 30 seconds").tag(30)
                        Text("Every 60 seconds").tag(60)
                    }
                    .pickerStyle(.inline)
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
            if model.activeConnection != nil { NamespaceCard().padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4) }
            List(selection: $model.selection) {
                Section(isExpanded: $queuesExpanded) {
                    ForEach(model.visibleQueues) { queue in
                        SidebarRow(title: queue.name, isQueue: true, count: queue.deadLetterCount, isDisabled: queue.isDisabled,
                                   counts: "(\(queue.activeCount), \(queue.deadLetterCount), \(queue.transferDeadLetterCount))")
                            .tag(SidebarSelection.queue(queue.name))
                            .nativeContextMenu { entityMenu(EntityRef(kind: .queue, name: queue.name)) }
                    }
                } header: { SidebarHeader(title: "Queues", count: model.visibleQueues.count) }
                Section(isExpanded: $topicsExpanded) {
                    ForEach(model.visibleTopics) { topic in
                        SidebarRow(title: topic.name, isQueue: false, count: topic.deadLetterCount, isDisabled: topic.isDisabled)
                            .tag(SidebarSelection.topic(topic.name))
                            .nativeContextMenu { entityMenu(EntityRef(kind: .topic, name: topic.name)) }
                    }
                } header: { SidebarHeader(title: "Topics", count: model.visibleTopics.count) }
            }
            .scrollContentBackground(.hidden)
            customFilters
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
    }

    // MARK: Queue and topic context menu

    private func entityMenu(_ ref: EntityRef) -> [MenuEntry] {
        let kind = ref.kindName.capitalized
        let disabled = model.isDisabled(ref)
        var entries: [MenuEntry] = [
            .item(disabled ? "Enable \(kind)" : "Disable \(kind)") { Task { await model.setDisabled(!disabled, ref) } },
            .item("Delete \(kind)…") { pending = .delete(ref) },
            .item("Refresh \(kind)") { Task { await model.refresh(ref) } },
            .separator,
        ]
        if ref.kind == .topic {
            entries += [.item("Create Subscription…") { subscriptionTopic = ref }, .separator]
        }
        entries += [
            .item("Copy \(kind) URL") {
                guard let url = model.url(for: ref) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            },
            .separator,
            .item("Send Messages…") { sendTarget = ref },
            .submenu("Purge", [
                .item("Messages…") { pending = .purge(ref, .active) },
                .item("Dead-letter Queue Messages…") { pending = .purge(ref, .deadLetter) },
                .separator,
                .item("All Messages…") { pending = .purge(ref, .all) },
            ]),
        ]
        return entries
    }

    private func confirmationTitle(_ action: PendingAction) -> String {
        switch action {
        case .delete(let ref): "Delete \(ref.kindName) “\(ref.name)”?"
        case .purge(let ref, _): "Purge \(ref.kindName) “\(ref.name)”?"
        }
    }

    private func confirmationButton(_ action: PendingAction) -> String {
        switch action {
        case .delete: "Delete"
        case .purge: "Purge"
        }
    }

    private func confirmationMessage(_ action: PendingAction) -> String {
        switch action {
        case .delete(let ref):
            return ref.kind == .topic
                ? "This deletes the topic, all its subscriptions and every message in them. It can't be undone."
                : "This deletes the queue and every message in it, including its dead-letters. It can't be undone."
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
                    IconTile(systemImage: "exclamationmark.triangle.fill", colors: Theme.alertTint)
                    Text("All dead-letters").foregroundStyle(isSelected ? .white : .primary)
                    Spacer()
                    CountPill(count: total, solid: !isSelected)
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
                       message: "Add a Service Bus connection string to see your queues, topics and dead-letters.") {
                Button("Add connection…", systemImage: "plus") { showingAddConnection = true }
                    .buttonStyle(.borderedProminent).controlSize(.large)
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
            DeadLetterView(model: DeadLetterModel(
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

// MARK: - Sidebar pieces

/// The connected namespace's name and endpoint at the top of the sidebar.
private struct NamespaceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(model.activeConnection?.name ?? "").font(.headline)
            if let host = model.activeHost {
                Text("sb://\(host)").foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isLoading)
            }
    }
}

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
    /// Shown after the name, e.g. "(active, dead-letter, transfer)" for a queue.
    var counts: String?
    var body: some View {
        HStack(spacing: 8) {
            EntityIcon(isQueue: isQueue)
            Text(title).lineLimit(1).truncationMode(.middle).foregroundStyle(isDisabled ? .secondary : .primary)
            if let counts {
                Text(counts).font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help("Active, dead-letter, transfer dead-letter")
            }
            Spacer(minLength: 4)
            if isDisabled { Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Disabled") }
            if count > 0 { CountPill(count: count, solid: true) }
        }
        .padding(.vertical, 1)
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
                queueStatus(queue)
                Divider()
                queueOverview(queue)
            } else {
                filterField
                Divider()
                table
            }
        }
    }

    private var selectedQueue: Queue? {
        guard case .queue(let name)? = model.selection else { return nil }
        return model.queues.first { $0.name == name }
    }

    // MARK: Queue overview

    /// Same height as the filter band, so the divider lines up with the detail pane's. Only a
    /// disabled queue says anything here; the normal state needs no label.
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
        .padding(.top, 4)
        .frame(height: Theme.paneSubheaderHeight, alignment: .top)
    }

    private func queueOverview(_ queue: Queue) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                StatTile(title: "Dead-lettered", value: queue.deadLetterCount, systemImage: "exclamationmark.triangle.fill",
                         tint: Theme.deadLetter, emphasized: queue.deadLetterCount > 0)
                StatTile(title: "Active", value: queue.activeCount, systemImage: "bolt.fill", tint: Theme.active)
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
        case .topic(let name)?: (title, subtitle, isQueue) = (name, "Topic", false)
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

    /// Sits above the table so it reads as filtering these rows, not the detail column.
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .overlay(Capsule().strokeBorder(searchFocused.wrappedValue ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: searchFocused.wrappedValue)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(height: Theme.paneSubheaderHeight, alignment: .top)
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
        CountPill(count: e.activeCount, kind: .active)
    }
    private func deadLetterCell(_ e: EntityRow) -> some View {
        CountPill(count: e.deadLetterCount, kind: .deadLetter)
    }
    private func transferCell(_ e: EntityRow) -> some View {
        CountPill(count: e.transferDeadLetterCount, kind: .transfer)
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
