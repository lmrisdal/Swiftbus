import ServiceBusKit
import SwiftUI

/// Asks for a name and creates a subscription with default settings.
struct CreateSubscriptionSheet: View {
    let topic: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isWorking = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    /// Service Bus allows up to 50 characters and no slashes in a subscription name.
    private var isValid: Bool { !trimmed.isEmpty && trimmed.count <= 50 && !trimmed.contains("/") }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. billing"))
                    .onSubmit(create)
            } header: {
                Text("New subscription on \(topic)").font(.headline)
            } footer: {
                Text("Created with default settings and a rule that matches every message. Add filters in the Azure portal.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Create", action: create).disabled(!isValid || isWorking) }
        }
    }

    private func create() {
        guard isValid, !isWorking else { return }
        isWorking = true
        Task {
            if await model.createSubscription(topic: topic, name: trimmed) { dismiss() }
            isWorking = false
        }
    }
}

/// Composes a text message and sends it to a queue or topic.
struct SendMessagesSheet: View {
    let target: EntityRef
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var messageBody = ""
    @State private var contentType = "application/json"
    @State private var subject = ""
    @State private var messageId = ""
    @State private var properties: [MessageProperty] = []
    @State private var isWorking = false
    @State private var problem: String?

    private var format: EditorFormat { EditorFormat.detect(contentType: contentType, body: messageBody) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Message to \(target.kindName) \(target.name)") {
                    TextField("Content type", text: $contentType)
                    TextField("Subject", text: $subject, prompt: Text("Optional"))
                    TextField("Message ID", text: $messageId, prompt: Text("Optional, generated if empty"))
                }
                Section {
                    PropertiesEditor(properties: $properties)
                } header: {
                    Text("Application properties")
                } footer: {
                    Text("Each value is sent as the chosen type. Rows with no key are ignored.")
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
                        if !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if format.isValid(messageBody) {
                                Label("Valid \(format.rawValue)", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            } else {
                                Label("Not valid \(format.rawValue)", systemImage: "info.circle").foregroundStyle(.secondary)
                            }
                        }
                        Button("Format") { if let f = format.pretty(messageBody) { messageBody = f } }
                            .disabled(format.pretty(messageBody) == nil)
                        Button("Minify") { if let f = format.minified(messageBody) { messageBody = f } }
                            .disabled(format.minified(messageBody) == nil)
                    }
                }
                .font(.callout)
                JSONEditor(text: $messageBody, format: format, autoFocus: true)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, idealWidth: 960, minHeight: 440, idealHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Send", action: send).disabled(isWorking) }
        }
    }

    private func send() {
        let message = OutgoingMessage(body: messageBody, contentType: contentType, subject: subject,
                                      messageId: messageId, properties: properties)
        if let issue = message.propertyProblem { problem = issue; return }
        problem = nil
        isWorking = true
        Task {
            if await model.send(message, to: target) { dismiss() }
            isWorking = false
        }
    }
}

/// A Key / Type / Value table like ServiceBusExplorer's, with add and remove buttons.
struct PropertiesEditor: View {
    @Binding var properties: [MessageProperty]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            if !properties.isEmpty {
                GridRow {
                    Text("Key"); Text("Type"); Text("Value"); Color.clear.frame(width: 20, height: 1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($properties) { $property in
                GridRow {
                    TextField("Key", text: $property.key).labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 100)
                    Picker("Type", selection: $property.type) {
                        ForEach(PropertyType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                    TextField("Value", text: $property.value).labelsHidden().textFieldStyle(.roundedBorder)
                        .foregroundStyle(property.problem == nil ? Color.primary : Theme.deadLetter)
                    Button {
                        properties.removeAll { $0.id == property.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove property")
                }
            }
            GridRow {
                Button { properties.append(MessageProperty()) } label: { Label("Add property", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .gridCellColumns(4)
            }
        }
    }
}
