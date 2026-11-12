import Foundation
import Testing
@testable import ServiceBusKit

private func message(_ seq: Int64, reason: String?, description: String? = nil, body: String? = "x", base64: String = "") -> DeadLetterMessage {
    let json = """
    {"sequenceNumber":\(seq),"enqueuedTime":"2026-11-12T10:00:0\(seq % 10).000+00:00","deliveryCount":1,
     "deadLetterReason":\(reason.map { "\"\($0)\"" } ?? "null"),
     "deadLetterErrorDescription":\(description.map { "\"\($0)\"" } ?? "null"),
     "body":\(body.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null"),
     "bodyBase64":"\(base64)","applicationProperties":{}}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(DeadLetterMessage.self, from: Data(json.utf8))
}

@Suite struct AnalysisTests {
    @Test func groupsByReasonAndDescriptionLargestFirst() {
        let groups = DeadLetterAnalysis.group([
            message(1, reason: "A", description: "x"),
            message(2, reason: "B"),
            message(3, reason: "B"),
            message(4, reason: "A", description: "y"),
            message(5, reason: "B"),
        ])
        #expect(groups.map(\.count) == [3, 1, 1])
        #expect(groups[0].reason == "B")
        #expect(groups[1].errorDescription == "x")   // ties keep first-seen order
        #expect(groups[0].messages.map(\.sequenceNumber) == [2, 3, 5])
    }

    @Test func groupsReasonsThatDifferOnlyInPayload() {
        let groups = DeadLetterAnalysis.group([
            message(1, reason: #"Endpoint returned 400. Message from endpoint: {'traceId':'00-aaa'}"#),
            message(2, reason: #"Endpoint returned 400. Message from endpoint: {'traceId':'00-bbb'}"#),
            message(3, reason: "Endpoint returned 500. Message from endpoint: oops"),
        ])
        #expect(groups.map(\.count) == [2, 1])
        #expect(groups[0].reason == "Endpoint returned 400.")
        #expect(groups[0].messages[0].deadLetterReason?.contains("traceId") == true)   // original kept
    }

    @Test func signatureDropsPayloadsAndVolatileValues() {
        #expect(DeadLetterAnalysis.signature(nil) == nil)
        #expect(DeadLetterAnalysis.signature("   ") == nil)
        #expect(DeadLetterAnalysis.signature("MaxDeliveryCountExceeded") == "MaxDeliveryCountExceeded")
        #expect(DeadLetterAnalysis.signature("Could not send. Message from endpoint: {\"a\":1}") == "Could not send.")
        #expect(DeadLetterAnalysis.signature("Failed with {\"a\":1}") == "Failed with")
        #expect(DeadLetterAnalysis.signature("Order 3f2504e0-4f89-11d3-9a0c-0305e82c3301 not found")
                == "Order <id> not found")
        #expect(DeadLetterAnalysis.signature("Trace 4bf92f3577b34da6a3ce929d0e0e4736 failed") == "Trace <id> failed")
        #expect(DeadLetterAnalysis.signature("Timed out at 2026-11-12T10:00:01.123Z") == "Timed out at <time>")
        #expect(DeadLetterAnalysis.signature("Customer 1234567 returned 404") == "Customer <n> returned 404")
        #expect(DeadLetterAnalysis.signature("a\n  b") == "a b")
        // Text that is only a payload is kept rather than emptied.
        #expect(DeadLetterAnalysis.signature("{\"error\":1}") == "{\"error\":1}")
        let long = DeadLetterAnalysis.signature(String(repeating: "x ", count: 200))!
        #expect(long.count == DeadLetterAnalysis.signatureMaxLength && long.hasSuffix("…"))
    }

    @Test func prettyPrintsJSON() {
        let result = BodyFormatter.format(message(1, reason: nil, body: #"{"b":1,"a":[1,2]}"#))
        #expect(result.format == .json)
        #expect(result.text.contains("\n"))
        #expect(result.text.range(of: "\"a\"")!.lowerBound < result.text.range(of: "\"b\"")!.lowerBound)
    }

    @Test func prettyPrintsXML() {
        let result = BodyFormatter.format(message(1, reason: nil, body: "<a><b>1</b></a>"))
        #expect(result.format == .xml)
        #expect(result.text.contains("\n"))
    }

    @Test func plainTextAndInvalidJSONPassThrough() {
        #expect(BodyFormatter.format(message(1, reason: nil, body: "hello")) == FormattedBody(format: .text, text: "hello"))
        #expect(BodyFormatter.format(message(1, reason: nil, body: "{not json")).format == .text)
    }

    @Test func binaryBodiesShowHex() {
        let result = BodyFormatter.format(message(1, reason: nil, body: nil, base64: "AP8="))
        #expect(result == FormattedBody(format: .binary, text: "00 ff"))
    }
}
