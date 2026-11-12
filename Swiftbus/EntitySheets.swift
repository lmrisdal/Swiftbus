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

/// Composes a text message and sends one or more copies to a queue or topic.
struct SendMessagesSheet: View {
    let target: EntityRef
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var messageBody = ""
    @State private var contentType = "application/json"
    @State private var subject = ""
    @State private var messageId = ""
    @State private var properties = ""
    @State private var count = 1
    @State private var isWorking = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Message to \(target.kindName) \(target.name)") {
                TextEditor(text: $messageBody)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                TextField("Content type", text: $contentType)
                TextField("Subject", text: $subject, prompt: Text("Optional"))
                TextField("Message ID", text: $messageId, prompt: Text("Optional, generated if empty"))
            }
            Section {
                TextEditor(text: $properties)
                    .font(.body.monospaced())
                    .frame(minHeight: 56)
            } header: {
                Text("Application properties")
            } footer: {
                Text("One key=value per line. Values are sent as text.")
            }
            Section {
                Stepper("Copies: \(count)", value: $count, in: 1...1000)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.deadLetter)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(count == 1 ? "Send" : "Send \(count)", action: send).disabled(isWorking)
            }
        }
    }

    private func send() {
        let parsed = OutgoingMessage.parseProperties(properties)
        guard case .success(let props) = parsed else {
            if case .failure(let error) = parsed { problem = error.localizedDescription }
            return
        }
        problem = nil
        isWorking = true
        let message = OutgoingMessage(body: messageBody, contentType: contentType, subject: subject,
                                      messageId: messageId, applicationProperties: props)
        Task {
            if await model.send(message, count: count, to: target) { dismiss() }
            isWorking = false
        }
    }
}
