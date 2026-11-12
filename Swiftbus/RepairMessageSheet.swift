import ServiceBusKit
import SwiftUI

/// "Repair and resubmit": edit a received message's body and properties, then send the copy back to its
/// queue or topic, optionally removing the original from the dead-letter queue.
struct RepairMessageSheet: View {
    let model: MessageListModel
    let original: DeadLetterMessage
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OutgoingMessage
    @State private var removeOriginal = false
    @State private var newMessageId = false
    @State private var isWorking = false
    @State private var problem: String?

    init(model: MessageListModel, original: DeadLetterMessage) {
        self.model = model
        self.original = original
        _draft = State(initialValue: OutgoingMessage(repairing: original)
                       ?? OutgoingMessage(body: "", contentType: original.contentType, subject: original.subject))
    }

    private var isDeadLetter: Bool { model.queue == .deadLetter }
    private var format: EditorFormat { EditorFormat.detect(contentType: draft.contentType ?? "", body: draft.body) }

    /// What is actually sent: the message ID is cleared when a new one should be generated.
    private var outgoing: OutgoingMessage {
        var message = draft
        if newMessageId { message.messageId = nil }
        return message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Message #\(original.sequenceNumber)") {
                    TextField("Content type", text: text(\.contentType))
                    TextField("Subject", text: text(\.subject), prompt: Text("Optional"))
                    TextField("Message ID", text: newMessageId ? .constant("") : text(\.messageId),
                              prompt: Text(newMessageId ? "New ID generated on submit" : "Optional, generated if empty"))
                        .disabled(newMessageId)
                    Toggle("Generate new message ID", isOn: $newMessageId)
                    TextField("Correlation ID", text: text(\.correlationId), prompt: Text("Optional"))
                }
                Section {
                    PropertiesEditor(properties: $draft.properties)
                } header: {
                    Text("Application properties")
                } footer: {
                    Text("Dead-letter reason and description are not copied. Rows with no key are ignored.")
                }
                Section("Original") {
                    LabeledContent("Enqueued", value: original.enqueuedTime.formatted(.dateTime.year().month().day().hour().minute().second()))
                    LabeledContent("Delivery count", value: String(original.deliveryCount))
                    if let reason = original.deadLetterReason {
                        LabeledContent("Reason", value: reason)
                    }
                    if let description = original.deadLetterErrorDescription, !description.isEmpty {
                        LabeledContent("Error description", value: description)
                    }
                }
                Section {
                    if isDeadLetter {
                        Toggle("Remove original from the dead-letter queue", isOn: $removeOriginal)
                    }
                } footer: {
                    Text(destinationNote)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.deadLetter)
                }
            }
            .formStyle(.grouped)
            .frame(width: 440)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Body").font(.headline)
                    Spacer()
                    if format != .text {
                        if !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if format.isValid(draft.body) {
                                Label("Valid \(format.rawValue)", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            } else {
                                Label("Not valid \(format.rawValue)", systemImage: "info.circle").foregroundStyle(.secondary)
                            }
                        }
                        Button("Format") { if let f = format.pretty(draft.body) { draft.body = f } }
                            .disabled(format.pretty(draft.body) == nil)
                        Button("Minify") { if let f = format.minified(draft.body) { draft.body = f } }
                            .disabled(format.minified(draft.body) == nil)
                    }
                }
                .font(.callout)
                JSONEditor(text: $draft.body, format: format, autoFocus: true)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, idealWidth: 960, minHeight: 520, idealHeight: 600)
        .navigationTitle("Repair and Resubmit")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Save…") {
                    Task {
                        await MessageFiles.save([MessageExport(outgoing)], suggestedName: "message-\(original.sequenceNumber)-repaired.json",
                                                log: app.log)
                    }
                }
                .help("Save the edited message as a JSON file")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Submit", action: submit).disabled(isWorking)
            }
        }
    }

    private var destinationNote: String {
        if model.entity.isQueue {
            return "The edited copy is sent to the queue \(model.entity.path)."
        }
        return "The edited copy is sent to the topic \(model.entity.path), so every subscription whose filter matches receives it, not only \(model.entity.name)."
    }

    /// Binds an optional string field of the draft to a text field (empty text means nil).
    private func text(_ keyPath: WritableKeyPath<OutgoingMessage, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" },
                set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func submit() {
        guard !isWorking else { return }
        problem = nil
        isWorking = true
        Task {
            problem = await model.resubmit(outgoing, original: original, removeOriginal: isDeadLetter && removeOriginal)
            isWorking = false
            if problem == nil { dismiss() }
        }
    }
}
