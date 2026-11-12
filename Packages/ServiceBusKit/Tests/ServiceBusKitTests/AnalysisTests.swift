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
