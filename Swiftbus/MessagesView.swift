import AppKit
import ServiceBusKit
import SwiftUI

struct MessagesView: View {
    @State var model: DeadLetterModel
    @Environment(AppModel.self) private var app
    @State private var confirming: DeadLetterAction?
    @State private var inspectorFraction: CGFloat = 0.5
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        GeometryReader { geo in
            // VSplitView ignores ideal heights, so the split is driven by an explicit fraction:
            // the inspector takes half the height by default and the divider can be dragged.
            let total = geo.size.height
            let inspectorHeight = min(max(total * inspectorFraction, 200), max(total - 200, 200))
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    EntityHeader(model: model)
                    Divider()
                    messageTable
                }
                .frame(maxHeight: .infinity)
                if let message = model.inspected {
                    Divider()
                        .overlay {
                            Color.clear
                                .frame(height: 8)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let start = dragStartHeight ?? inspectorHeight
                                            dragStartHeight = start
                                            let proposed = start - value.translation.height
                                            inspectorFraction = min(max(proposed, 200), max(total - 200, 200)) / max(total, 1)
                                        }
                                        .onEnded { _ in dragStartHeight = nil }
                                )
                        }
                    MessageInspector(message: message).frame(height: inspectorHeight)
                }
            }
        }
        .navigationTitle(model.entity.name)
        .navigationSubtitle("\(model.entity.isQueue ? "Queue" : model.entity.path) · \(model.messages.count) \(model.queue.rawValue.lowercased()) loaded")
        .toolbar {
            ToolbarItem {
                Picker("Queue", selection: $model.queue) {
                    ForEach(QueueKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show active messages, the dead-letter queue or the transfer dead-letter queue")
            }
            ToolbarItemGroup {
                Button("Resend", systemImage: "arrow.uturn.forward") { confirming = .resend }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .help("Resend the selected messages and remove them from the dead-letter queue")
                    .disabled(!canAct || model.queue != .deadLetter)
                Button("Delete", systemImage: "trash") { confirming = .delete }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help(model.queue == .active ? "Permanently delete the selected active messages" : "Delete the selected messages without resending")
                    .disabled(!canAct)
            }
            ToolbarItem {
                Toggle("Group by reason", systemImage: "rectangle.3.group", isOn: $model.groupByReason)
                    .help("Group identical failures into one row")
                    .disabled(model.queue != .deadLetter)
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                    .disabled(model.isLoading)
            }
            ActivityLogToolbar(model: app)
        }
        .focusedSceneValue(\.deadLetterModel, model)
        .focusedSceneValue(\.selectQueue, { [model] kind in model.queue = kind })
        .onChange(of: app.messageReloadToken) { Task { await model.reload() } }
        .task(id: model.queue) { await model.reload() }
        .confirmationDialog(confirmTitle, isPresented: .init(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let action = confirming {
                Button(action == .resend ? "Resend" : "Delete", role: action == .delete ? .destructive : nil) {
                    model.start(action)
                }
            }
        } message: { Text(confirmMessage) }
        .sheet(isPresented: .init(get: { model.run != nil }, set: { if !$0 { model.dismissRun() } })) {
            RunProgressSheet(model: model)
        }
    }

    private var canAct: Bool {
        (model.queue == .deadLetter || model.queue == .active) && !model.selectedMessages.isEmpty && !model.isRunning
    }

    private var confirmTitle: String {
        let n = model.selectedMessages.count
        let noun = n == 1 ? "1 message" : "\(n) messages"
        return confirming == .delete ? "Delete \(noun)?" : "Resend \(noun)?"
    }

    private var confirmMessage: String {
        let topic = model.entity.path
        if confirming == .delete {
            if model.queue == .active {
                return "The messages are permanently removed from \(model.entity.name) without ever being processed. This cannot be undone.\n\nThey are received under a lock, so a consumer running at the same time may get them first, and any other message passed over to reach them counts one extra delivery attempt."
            }
            return "The messages are permanently removed from the dead-letter queue of \(model.entity.name) without being resent. This cannot be undone."
        }
        if model.entity.isQueue {
            return "A copy of each message is sent back to the queue \(topic), then the original is removed from the dead-letter queue. A message is only removed after its copy was sent."
        }
        var text = "A copy of each message is sent to the topic \(topic), then the original is removed from the dead-letter queue. A message is only removed after its copy was sent."
        if model.siblingSubscriptionCount > 0 {
            text += "\n\nService Bus can only send to a topic, so every other subscription on it (\(model.siblingSubscriptionCount)) whose filter matches will receive the message too, not just \(model.entity.name). That creates duplicates if their filters overlap."
        }
        return text
    }

    @ViewBuilder
    private var messageTable: some View {
        if model.messages.isEmpty && !model.isLoading {
            // No rows: show only the placeholder, not an empty striped table.
            if let error = model.errorMessage {
                EmptyState(title: "Could not read messages", systemImage: "exclamationmark.triangle",
                           message: error) {
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                }
            } else if model.queue == .deadLetter {
                EmptyState.allClear("Dead-letter queue is empty", message: "No failed messages in \(model.entity.name).")
            } else if model.queue == .transferDeadLetter {
                EmptyState.allClear("Transfer dead-letter queue is empty", message: "No messages failed to transfer in \(model.entity.name).")
            } else {
                EmptyState(title: "No active messages", systemImage: "tray", message: "Nothing is waiting to be received.")
            }
        } else {
            populatedTable
        }
    }

    @ViewBuilder
    private var populatedTable: some View {
        switch model.queue {
        case .active: activeTable
        case .deadLetter, .transferDeadLetter: deadLetterTable
        }
    }

    /// Active messages have no dead-letter reason or grouping, so they get their own, simpler columns.
    private var activeTable: some View {
        Table(model.messages.map(DeadLetterRow.single), selection: $model.selection) {
            TableColumn("Seq") { row in
                if let m = row.message { Text(m.sequenceNumber, format: .number.grouping(.never)).monospacedDigit().foregroundStyle(.secondary) }
            }.width(min: 36, ideal: 48, max: 72)
            TableColumn("Enqueued") { row in
                if let m = row.message {
                    Text(m.enqueuedTime, format: .dateTime.month().day().hour().minute().second())
                }
            }.width(min: 110, ideal: 140)
            TableColumn("Message ID") { row in Text(row.message?.messageId ?? "").lineLimit(1) }
            TableColumn("Subject") { row in Text(row.message?.subject ?? "").lineLimit(1) }
            TableColumn("Deliveries") { row in
                if let m = row.message { DeliveryCount(count: m.deliveryCount) }
            }.width(70)
            TableColumn("Size") { row in
                if let m = row.message { Text(Int64(m.bodySize), format: .byteCount(style: .file)).monospacedDigit() }
            }.width(min: 60, ideal: 80)
        }
        .tableChrome(model: model)
    }

    private var deadLetterTable: some View {
        Table(model.rows, children: \.children, selection: $model.selection) {
            TableColumn("Seq") { row in
                if let m = row.message { Text(m.sequenceNumber, format: .number.grouping(.never)).monospacedDigit().foregroundStyle(.secondary) }
            }.width(min: 36, ideal: 48, max: 72)
            TableColumn("Reason") { row in
                if let g = row.group {
                    ReasonTag(reason: g.reason, count: g.count)
                } else if let m = row.message {
                    ReasonTag(reason: m.deadLetterReason)
                }
            }.width(min: 120, ideal: 200)
            TableColumn("Error description") { row in
                Text(row.group?.errorDescription ?? row.message?.deadLetterErrorDescription ?? "")
                    .lineLimit(1).help(row.message?.deadLetterErrorDescription ?? "")
            }.width(min: 150, ideal: 300)
            TableColumn("Enqueued") { row in
                if let m = row.message {
                    Text(m.enqueuedTime, format: .dateTime.month().day().hour().minute().second())
                } else if let g = row.group, let first = g.firstEnqueued, let last = g.lastEnqueued {
                    Text("\(first.formatted(.dateTime.month().day().hour().minute())) – \(last.formatted(.dateTime.month().day().hour().minute()))")
                        .foregroundStyle(.secondary)
                }
            }.width(min: 110, ideal: 140)
            TableColumn("Message ID") { row in Text(row.message?.messageId ?? "").lineLimit(1) }
            TableColumn("Subject") { row in Text(row.message?.subject ?? "").lineLimit(1) }
            TableColumn("Deliveries") { row in
                if let m = row.message { DeliveryCount(count: m.deliveryCount) }
            }.width(70)
            TableColumn("Size") { row in
                if let m = row.message { Text(Int64(m.bodySize), format: .byteCount(style: .file)).monospacedDigit() }
            }.width(min: 60, ideal: 80)
        }
        .tableChrome(model: model)
    }
}

private extension View {
    /// The loading overlay and "Load more" button shared by both message tables.
    func tableChrome(model: DeadLetterModel) -> some View {
        // The button lives in a real footer below the table rather than a floating inset:
        // an inset overlaps the table's scroll bars and is easy to miss over busy rows.
        VStack(spacing: 0) {
            overlay {
                if model.isLoading && model.messages.isEmpty {
                    LoadingState(title: model.queue.loadingTitle)
                        .background(.background)
                }
            }
            if model.hasMore {
                Divider()
                HStack(spacing: 12) {
                    Text("\(model.messages.count) loaded")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await model.loadMore() } } label: {
                        Label(model.isLoading ? "Loading…" : "Load \(DeadLetterModel.pageSize) more",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isLoading)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

struct MessageInspector: View {
    let message: DeadLetterMessage

    var body: some View {
        let body = BodyFormatter.format(message)
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    IconTile(systemImage: "curlybraces", colors: [Theme.brandTop, Theme.brandBottom], size: 22)
                    Text("Body").font(.headline)
                    Text(label(for: body.format))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    Text(Int64(message.bodySize), format: .byteCount(style: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    CopyButton(title: "Copy body", text: body.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                ScrollView([.vertical, .horizontal]) {
                    Text(body.text)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .padding([.horizontal, .bottom], 10)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(minWidth: 250)

            Form {
                if message.deadLetterReason != nil || message.deadLetterErrorDescription != nil {
                    Section {
                        // Full text, wrapped: reasons are often long exception messages, so the
                        // single-line tag used in the table would truncate them here.
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Theme.color(forReason: message.deadLetterReason))
                                .frame(width: 3)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.deadLetterReason ?? "(no reason)")
                                    .font(.callout.weight(.semibold))
                                if let description = message.deadLetterErrorDescription, !description.isEmpty {
                                    Text(description).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let reason = message.deadLetterReason {
                                CopyButton(title: "Copy reason", text: reason, iconOnly: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("System") {
                    row("Sequence number", String(message.sequenceNumber))
                    row("Message ID", message.messageId)
                    row("Enqueued", message.enqueuedTime.formatted(.dateTime.year().month().day().hour().minute().second()))
                    row("Delivery count", String(message.deliveryCount))
                    row("Subject", message.subject)
                    row("Content type", message.contentType)
                    row("Correlation ID", message.correlationId)
                    row("Reason", message.deadLetterReason)
                    row("Error description", message.deadLetterErrorDescription)
                }
                Section("Application properties") {
                    if message.applicationProperties.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(message.applicationProperties.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        row(key, value)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(minWidth: 280)
        }
    }

    private func label(for format: BodyFormat) -> String {
        switch format {
        case .json: "JSON"
        case .xml: "XML"
        case .text: "Text"
        case .binary: "Binary (hex)"
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
                    CopyButton(title: "Copy \(title)", text: value, iconOnly: true)
                }
            }
        }
    }
}

struct CopyButton: View {
    let title: String
    let text: String
    var iconOnly = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            if iconOnly { Image(systemName: "doc.on.doc") } else { Label(title, systemImage: "doc.on.doc") }
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct RunProgressSheet: View {
    let model: DeadLetterModel

    var body: some View {
        if let run = model.run {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ProgressRing(progress: Double(run.completed) / Double(max(run.messages.count, 1)),
                                 colors: ringColors(run), isFinished: run.isFinished, failed: run.failed > 0)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(run)).font(.title3.weight(.semibold))
                        Text(summary(run)).font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            if run.succeeded > 0 { CountPill(count: run.succeeded, kind: .active) }
                            if run.failed > 0 { CountPill(count: run.failed, kind: .deadLetter) }
                        }
                    }
                }
                List(run.messages) { message in
                    HStack(alignment: .firstTextBaseline) {
                        icon(run.results[message.sequenceNumber])
                        VStack(alignment: .leading) {
                            Text("#\(message.sequenceNumber)  \(message.messageId ?? "")").monospacedDigit()
                            if let error = run.results[message.sequenceNumber]?.error {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .frame(minHeight: 160)
                HStack {
                    Spacer()
                    if run.isFinished {
                        if run.failed > 0 {
                            Button("Retry \(run.failed) failed") { model.retryFailed() }
                        }
                        Button("Done") { model.dismissRun() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel remaining") { model.cancelRun() }
                    }
                }
            }
            .padding(20)
            .frame(width: 520, height: 420)
            .interactiveDismissDisabled(!run.isFinished)
        }
    }

    private func ringColors(_ run: ActionRun) -> [Color] {
        if run.isFinished && run.failed > 0 { return Theme.alertTint }
        if run.isFinished { return [Theme.healthy, Theme.healthy.darkened(0.3)] }
        return run.action == .delete ? Theme.alertTint : [Theme.brandTop, Theme.brandBottom]
    }

    private func title(_ run: ActionRun) -> String {
        let verb = run.action == .resend ? "Resending" : "Deleting"
        return run.isFinished ? (run.action == .resend ? "Resend finished" : "Delete finished") : "\(verb) messages…"
    }

    private func summary(_ run: ActionRun) -> String {
        var text = "\(run.succeeded) of \(run.messages.count) done"
        if run.failed > 0 { text += ", \(run.failed) failed — failed messages stay in the queue" }
        return text
    }

    @ViewBuilder private func icon(_ result: MessageResult?) -> some View {
        switch result?.ok {
        case true: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.healthy)
        case false: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.deadLetter)
        default: ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Header

/// Sits above the message table: what this entity is.
private struct EntityHeader: View {
    let model: DeadLetterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                EntityIcon(isQueue: model.entity.isQueue, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.entity.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(model.entity.isQueue ? "Queue" : "Subscription on \(model.entity.path)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    MetricChip(label: "Active", count: model.entity.activeCount, kind: .active)
                    MetricChip(label: "DLQ", count: model.entity.deadLetterCount, kind: .deadLetter)
                }
            }
            .frame(height: Theme.paneHeaderHeight)
        }
        .padding(.horizontal, 14)
    }
}

struct MetricChip: View {
    let label: String
    let count: Int
    let kind: CountPill.Kind
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            CountPill(count: count, kind: kind)
        }
    }
}

/// Delivery count, highlighted once a message has been retried enough to look poisonous.
private struct DeliveryCount: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            if count >= 5 { Image(systemName: "flame.fill").font(.caption2) }
            Text(count, format: .number).monospacedDigit()
        }
        .foregroundStyle(count >= 5 ? Theme.transfer : .primary)
    }
}

/// A circular progress indicator with a gradient stroke for resend/delete runs.
private struct ProgressRing: View {
    let progress: Double
    let colors: [Color]
    let isFinished: Bool
    let failed: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isFinished {
                Image(systemName: failed ? "exclamationmark" : "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(colors[0])
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText(value: progress))
            }
        }
        .frame(width: 64, height: 64)
        .animation(.snappy, value: progress)
        .animation(.bouncy, value: isFinished)
    }
}
