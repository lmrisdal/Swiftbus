import Foundation
import Testing
@testable import ServiceBusKit

private actor Recorder {
    var batches: [[Int64]] = []
    var purges: [String] = []
    func add(_ b: [Int64]) { batches.append(b) }
    func addPurge(_ p: String) { purges.append(p) }
}

private struct MockClient: MessagingClient {
    let recorder = Recorder()
    var failingBatchStart: Int64? = nil
    var failMessage: Int64? = nil

    func peekDeadLetters(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] { [] }
    func peekActive(topic: String, subscription: String?, max: Int, fromSequence: Int64?) async throws -> [DeadLetterMessage] { [] }
    func resend(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult] {
        await recorder.add(sequenceNumbers)
        if sequenceNumbers.first == failingBatchStart { throw HelperError.exited }
        return sequenceNumbers.map { MessageResult(sequenceNumber: $0, ok: $0 != failMessage, error: $0 == failMessage ? "send failed" : nil) }
    }
    func delete(topic: String, subscription: String?, sequenceNumbers: [Int64]) async throws -> [MessageResult] {
        sequenceNumbers.map { MessageResult(sequenceNumber: $0, ok: true, error: nil) }
    }
    func send(topic: String, message: OutgoingMessage, count: Int) async throws -> Int { count }
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
    @Test func parsesKeyValueLines() throws {
        let props = try OutgoingMessage.parseProperties("a=1\n\n b = two=2 \n").get()
        #expect(props == ["a": "1", "b": "two=2"])
    }

    @Test func rejectsLinesWithoutKey() {
        #expect(OutgoingMessage.parseProperties("nope") == .failure(.init(line: "nope")))
        #expect(OutgoingMessage.parseProperties("=x") == .failure(.init(line: "=x")))
    }
}
