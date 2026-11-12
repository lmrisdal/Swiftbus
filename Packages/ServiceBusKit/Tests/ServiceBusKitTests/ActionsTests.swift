import Foundation
import Testing
@testable import ServiceBusKit

private actor Recorder {
    var batches: [[Int64]] = []
    var purges: [String] = []
    var deletes: [String] = []
    func addDelete(_ d: String) { deletes.append(d) }
    func add(_ b: [Int64]) { batches.append(b) }
    func addPurge(_ p: String) { purges.append(p) }
}

private struct MockClient: MessagingClient {
    let recorder = Recorder()
    var failingBatchStart: Int64? = nil
    var failMessage: Int64? = nil

    func peekDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] { [] }
    func peekTransferDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] { [] }
    func peekActive(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] { [] }
    func resend(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult] {
        await recorder.add(sequenceNumbers)
        if sequenceNumbers.first == failingBatchStart { throw HelperError.exited }
        return sequenceNumbers.map { MessageResult(sequenceNumber: $0, ok: $0 != failMessage, error: $0 == failMessage ? "send failed" : nil) }
    }
    func delete(topic: String, subscription: String?, deadLetter: Bool, sequenceNumbers: [Int64]) async throws -> [MessageResult] {
        await recorder.addDelete("\(deadLetter)")
        return sequenceNumbers.map { MessageResult(sequenceNumber: $0, ok: true, error: nil) }
    }
    func send(topic: String, message: OutgoingMessage) async throws {}
    func purge(topic: String, subscription: String?, deadLetter: Bool) async throws -> Int {
        await recorder.addPurge("\(subscription ?? "-")/\(deadLetter)")
        if subscription == "bad" { throw HelperError.exited }
        return deadLetter ? 2 : 5
    }
    func shutdown() async {}
}

@Suite struct ActionsTests {
    @Test func batchesAndReportsProgress() async {
        let client = MockClient()
        let progress = Recorder()
        let results = await DeadLetterActions.run(.resend, client: client, topic: "t", subscription: "s",
                                                  sequenceNumbers: Array(1...7), batchSize: 3) { await progress.add($0.map(\.sequenceNumber)) }
        #expect(await client.recorder.batches == [[1, 2, 3], [4, 5, 6], [7]])
        #expect(await progress.batches == [[1, 2, 3], [4, 5, 6], [7]])
        #expect(results.count == 7 && results.allSatisfy(\.ok))
    }

    @Test func failedBatchDoesNotAbortTheRest() async {
        let client = MockClient(failingBatchStart: 4)
        let results = await DeadLetterActions.run(.resend, client: client, topic: "t", subscription: "s",
                                                  sequenceNumbers: Array(1...7), batchSize: 3)
        #expect(results.filter { !$0.ok }.map(\.sequenceNumber) == [4, 5, 6])
        #expect(results.filter(\.ok).map(\.sequenceNumber) == [1, 2, 3, 7])
    }

    @Test func perMessageFailuresArePreserved() async {
        let client = MockClient(failMessage: 2)
        let results = await DeadLetterActions.run(.resend, client: client, topic: "t", subscription: "s", sequenceNumbers: [1, 2, 3])
        #expect(results.first { $0.sequenceNumber == 2 }?.error == "send failed")
    }

    @Test func deleteTargetsTheRequestedQueue() async {
        let client = MockClient()
        _ = await DeadLetterActions.run(.delete, client: client, topic: "t", subscription: "s", sequenceNumbers: [1])
        _ = await DeadLetterActions.run(.delete, client: client, topic: "t", subscription: "s", sequenceNumbers: [2], deadLetter: false)
        #expect(await client.recorder.deletes == ["true", "false"])
    }

    @Test func emptyInputDoesNothing() async {
        let client = MockClient()
        let results = await DeadLetterActions.run(.delete, client: client, topic: "t", subscription: "s", sequenceNumbers: [])
        #expect(results.isEmpty)
    }
}


@Suite struct PurgeTests {
    @Test func scopeSelectsActiveDeadLetterOrBoth() async {
        for (scope, expectedPurges, expectedTotal) in [(PurgeScope.active, ["a/false"], 5), (.deadLetter, ["a/true"], 2), (.all, ["a/false", "a/true"], 7)] {
            let client = MockClient()
            let report = await PurgeActions.run(client: client, topic: "t", subscriptions: ["a"], scope: scope)
            #expect(await client.recorder.purges == expectedPurges)
            #expect(report.purged == expectedTotal && report.failures.isEmpty)
        }
    }

    @Test func oneFailingSubscriptionDoesNotStopTheRest() async {
        let report = await PurgeActions.run(client: MockClient(), topic: "t", subscriptions: ["a", "bad", "c"], scope: .active)
        #expect(report.purged == 10)
        #expect(report.failures.count == 1 && report.failures[0].hasPrefix("t/bad"))
    }

    @Test func queueIsPurgedWithNilSubscription() async {
        let client = MockClient()
        _ = await PurgeActions.run(client: client, topic: "q", subscriptions: [nil], scope: .active)
        #expect(await client.recorder.purges == ["-/false"])
    }
}

@Suite struct OutgoingMessageTests {
    @Test func validatesPropertyValuesByType() {
        #expect(PropertyType.int32.validate("42") == nil)
        #expect(PropertyType.int32.validate("4.2") != nil)
        #expect(PropertyType.byte.validate("300") != nil)
        #expect(PropertyType.boolean.validate("True") == nil)
        #expect(PropertyType.guid.validate("c3c68394-bf05-4ac3-add1-834b1c8d1111") == nil)
        #expect(PropertyType.guid.validate("nope") != nil)
        #expect(PropertyType.dateTime.validate("2026-11-12T10:15:30Z") == nil)
        #expect(PropertyType.char.validate("ab") != nil)
        #expect(PropertyType.string.validate("anything") == nil)
    }

    @Test func reportsRowProblemsAndIgnoresBlankRows() {
        var m = OutgoingMessage(body: "", properties: [MessageProperty(), MessageProperty(key: "a", value: "x")])
        #expect(m.propertyProblem == nil)
        m.properties.append(MessageProperty(key: "n", type: .int16, value: "x"))
        #expect(m.propertyProblem != nil)
        m.properties = [MessageProperty(key: "a", value: "1"), MessageProperty(key: "a", value: "2")]
        #expect(m.propertyProblem?.contains("more than once") == true)
        m.properties = [MessageProperty(key: "", value: "1")]
        #expect(m.propertyProblem != nil)
    }
}

@Suite struct JSONFormatterTests {
    @Test func prettyPrintsKeepingKeyOrder() throws {
        let out = try #require(JSONFormatter.pretty(#"{"z":1,"a":[1,2],"e":{},"s":"a,{b}\"c"}"#))
        #expect(out == "{\n  \"z\": 1,\n  \"a\": [\n    1,\n    2\n  ],\n  \"e\": {},\n  \"s\": \"a,{b}\\\"c\"\n}")
    }

    @Test func minifiesAndRejectsInvalid() {
        #expect(JSONFormatter.minified("{ \"a\": [1, 2] }") == #"{"a":[1,2]}"#)
        #expect(JSONFormatter.pretty("{oops") == nil)
        #expect(!JSONFormatter.isValid(""))
        #expect(JSONFormatter.isValid("42"))
    }
}

@Suite struct EditorFormatTests {
    @Test func detectsFromContentType() {
        #expect(EditorFormat.detect(contentType: "application/json; charset=utf-8") == .json)
        #expect(EditorFormat.detect(contentType: "application/vnd.api+json") == .json)
        #expect(EditorFormat.detect(contentType: "text/xml") == .xml)
        #expect(EditorFormat.detect(contentType: "application/soap+xml") == .xml)
        #expect(EditorFormat.detect(contentType: "text/plain", body: "{}") == .text)
        #expect(EditorFormat.detect(contentType: "", body: " <a/>") == .xml)
        #expect(EditorFormat.detect(contentType: nil, body: "[1]") == .json)
        #expect(EditorFormat.detect(contentType: nil, body: "hello") == .text)
    }

    @Test func formatsXMLKeepingOrderAndOmittingAddedDeclaration() throws {
        let pretty = try #require(EditorFormat.xml.pretty("<r><b x=\"1\">t</b><a/></r>"))
        #expect(pretty == "<r>\n  <b x=\"1\">t</b>\n  <a/>\n</r>")
        #expect(EditorFormat.xml.minified("<r>\n  <b>t</b>\n  <a/>\n</r>") == "<r><b>t</b><a/></r>")
        #expect(EditorFormat.xml.pretty("<r><b></r>") == nil)
        #expect(!EditorFormat.xml.isValid(""))
    }

    @Test func plainTextIsAlwaysValidAndNeverFormatted() {
        #expect(EditorFormat.text.isValid("anything"))
        #expect(EditorFormat.text.pretty("anything") == nil)
    }
}
