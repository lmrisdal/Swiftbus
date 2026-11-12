import Foundation
import Testing
@testable import ServiceBusKit

private func message(body: String?, types: String? = #"{"Count":"Int32","When":"DateTimeOffset","Odd":"TimeSpan"}"#) throws -> DeadLetterMessage {
    let bodyJSON = body.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null"
    let base64 = Data((body ?? "\u{01}\u{02}").utf8).base64EncodedString()
    let typesJSON = types.map { #","applicationPropertyTypes":\#($0)"# } ?? ""
    let json = """
    {"sequenceNumber":42,"messageId":"m1","enqueuedTime":"2026-11-12T10:15:30Z","deliveryCount":3,
     "contentType":"application/json","subject":"order","correlationId":"c1",
     "deadLetterReason":"Boom","deadLetterErrorDescription":"bad",
     "body":\(bodyJSON),"bodyBase64":"\(base64)",
     "applicationProperties":{"Count":"5","When":"2026-11-12T10:00:00Z","Odd":"00:01:00","DeadLetterReason":"Boom"}\(typesJSON)}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(DeadLetterMessage.self, from: Data(json.utf8))
}

@Suite struct RepairTests {
    @Test func repairCopiesSystemAndTypedPropertiesWithoutDeadLetterOnes() throws {
        let m = try message(body: #"{"foo":"bar"}"#)
        let draft = try #require(OutgoingMessage(repairing: m))
        #expect(draft.body == "{\n  \"foo\" : \"bar\"\n}")
        #expect(draft.contentType == "application/json")
        #expect(draft.subject == "order")
        #expect(draft.messageId == "m1")
        #expect(draft.correlationId == "c1")
        #expect(draft.properties.map(\.key) == ["Count", "Odd", "When"])
        #expect(draft.properties.map(\.type) == [.int32, .string, .dateTime])
        #expect(draft.propertyProblem == nil)
    }

    @Test func repairKeepsRawBodyWhenNotPretty() throws {
        let m = try message(body: #"{"foo":"bar"}"#)
        #expect(OutgoingMessage(repairing: m, prettyBody: false)?.body == #"{"foo":"bar"}"#)
    }

    @Test func binaryBodyCannotBeRepaired() throws {
        #expect(OutgoingMessage(repairing: try message(body: nil)) == nil)
    }

    @Test func missingTypesFallBackToString() throws {
        let m = try message(body: "x", types: nil)
        #expect(m.typedProperties.allSatisfy { $0.type == .string })
    }

    @Test func exportsOneMessageAsAnObjectAndSeveralAsAnArray() throws {
        let m = try message(body: "hello")
        let one = try JSONSerialization.jsonObject(with: MessageExport.json([MessageExport(m)])) as? [String: Any]
        #expect(one?["body"] as? String == "hello")
        #expect(one?["bodyBase64"] == nil)
        #expect(one?["sequenceNumber"] as? Int == 42)
        let props = one?["applicationProperties"] as? [[String: String]]
        #expect(props?.first { $0["name"] == "Count" }?["type"] == "Int32")

        let many = try JSONSerialization.jsonObject(with: MessageExport.json([MessageExport(m), MessageExport(m)])) as? [Any]
        #expect(many?.count == 2)
    }

    @Test func exportsBinaryBodyAsBase64() throws {
        let export = MessageExport(try message(body: nil))
        #expect(export.body == nil)
        #expect(export.bodyBase64 != nil)
    }

    @Test func exportsDraftWithoutBlankRows() throws {
        let draft = OutgoingMessage(body: "b", messageId: "", properties: [MessageProperty(key: "a", value: "1"), MessageProperty()])
        let export = MessageExport(draft)
        #expect(export.messageId == nil)
        #expect(export.applicationProperties.count == 1)
    }

    @Test func suggestsFileNames() throws {
        let m = try message(body: "x")
        #expect(MessageExport.suggestedFileName(for: [m], entity: "orders/billing") == "message-42.json")
        #expect(MessageExport.suggestedFileName(for: [m, m], entity: "orders/billing") == "messages-orders-billing.json")
    }
}
