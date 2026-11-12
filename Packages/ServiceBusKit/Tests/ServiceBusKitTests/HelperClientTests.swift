import Foundation
import Testing
@testable import ServiceBusKit

/// Writes a shell script that behaves like the helper: answers each request line, extracting its id.
private func fakeHelper(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-helper-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let echoLoop = """
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]*)".*/\\1/')
  case "$line" in
    *peekDeadLetters*|*peekTransferDeadLetters*|*peekActive*) printf '{"id":"%s","ok":true,"messages":[{"sequenceNumber":42,"messageId":"m1","enqueuedTime":"2026-11-12T10:15:30.1234567+00:00","deliveryCount":10,"deadLetterReason":"MaxDeliveryCountExceeded","body":"{\\\\"a\\\\":1}","bodyBase64":"eyJhIjoxfQ==","applicationProperties":{"k":"v","n":"7"},"applicationPropertyTypes":{"k":"String","n":"Int32"}}]}\\n' "$id" ;;
    *'"op":"purge"'*) printf '{"id":"%s","ok":true,"count":9}\\n' "$id" ;;
    *'"op":"send"'*) printf '{"id":"%s","ok":true,"count":3}\\n' "$id" ;;
    *resend*) printf '{"id":"%s","ok":true,"results":[{"sequenceNumber":42,"ok":true}]}\\n' "$id" ;;
    *) printf '{"id":"%s","ok":false,"error":"nope"}\\n' "$id" ;;
  esac
done
"""

@Suite struct HelperClientTests {
    @Test func sendsAndPurgesReturnTheHelpersCount() async throws {
        let client = HelperMessagingClient(executableURL: try fakeHelper(echoLoop), connectionString: "cs")
        try await client.send(topic: "t", message: OutgoingMessage(body: "hi", properties: [MessageProperty(key: "n", type: .int32, value: "1")]))
        #expect(try await client.purge(topic: "t", subscription: "s", deadLetter: true) == 9)
        await client.shutdown()
    }

    @Test func sendCarriesCorrelationIdToTheHelper() async throws {
        // Answers ok only if the send request includes the correlation ID.
        let script = """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]*)".*/\\1/')
          case "$line" in
            *'"correlationId":"corr-1"'*) printf '{"id":"%s","ok":true,"count":1}\\n' "$id" ;;
            *) printf '{"id":"%s","ok":false,"error":"missing correlationId"}\\n' "$id" ;;
          esac
        done
        """
        let client = HelperMessagingClient(executableURL: try fakeHelper(script), connectionString: "cs")
        try await client.send(topic: "t", message: OutgoingMessage(body: "hi", correlationId: "corr-1"))
        await client.shutdown()
    }

    @Test func decodesPeekedMessages() async throws {
        let client = HelperMessagingClient(executableURL: try fakeHelper(echoLoop), connectionString: "cs")
        let messages = try await client.peekDeadLetters(topic: "t", subscription: "s", max: 10, fromSequence: nil)
        await client.shutdown()
        let m = try #require(messages.first)
        #expect(m.sequenceNumber == 42)
        #expect(m.deadLetterReason == "MaxDeliveryCountExceeded")
        #expect(m.applicationProperties == ["k": "v", "n": "7"])
        #expect(m.typedProperties.map(\.type) == [.string, .int32])
        #expect(m.bodyData == Data(#"{"a":1}"#.utf8))
        #expect(abs(m.enqueuedTime.timeIntervalSince1970 - 1_794_478_530.123) < 0.01)
    }

    @Test func peekTransferDeadLettersUsesItsOwnOperation() async throws {
        let client = HelperMessagingClient(executableURL: try fakeHelper(echoLoop), connectionString: "cs")
        let messages = try await client.peekTransferDeadLetters(topic: "t", subscription: "s", max: 10, fromSequence: nil)
        await client.shutdown()
        #expect(messages.count == 1)
    }

    @Test func peekActiveUsesItsOwnOperation() async throws {
        let client = HelperMessagingClient(executableURL: try fakeHelper(echoLoop), connectionString: "cs")
        let messages = try await client.peekActive(topic: "t", subscription: "s", max: 10, fromSequence: nil)
        await client.shutdown()
        #expect(messages.count == 1)
    }

    @Test func resendReturnsPerMessageResults() async throws {
        let client = HelperMessagingClient(executableURL: try fakeHelper(echoLoop), connectionString: "cs")
        let results = try await client.resend(topic: "t", subscription: "s", sequenceNumbers: [42])
        await client.shutdown()
        #expect(results == [MessageResult(sequenceNumber: 42, ok: true, error: nil)])
    }

    @Test func helperErrorsSurface() async throws {
        let client = HelperMessagingClient(executableURL: try fakeHelper(echoLoop), connectionString: "cs")
        await #expect(throws: HelperError.failed("nope")) {
            try await client.delete(topic: "t", subscription: "s", deadLetter: true, sequenceNumbers: [1])
        }
        await client.shutdown()
    }

    @Test func restartsAfterHelperExits() async throws {
        // Exits after answering one request.
        let script = try fakeHelper("""
        IFS= read -r line
        id=$(printf '%s' "$line" | sed -E 's/.*"id":"([^"]*)".*/\\1/')
        printf '{"id":"%s","ok":true,"results":[]}\\n' "$id"
        """)
        let client = HelperMessagingClient(executableURL: script, connectionString: "cs")
        _ = try await client.resend(topic: "t", subscription: "s", sequenceNumbers: [])
        try await Task.sleep(for: .milliseconds(300))
        _ = try await client.resend(topic: "t", subscription: "s", sequenceNumbers: [])
        await client.shutdown()
    }

    @Test func missingExecutableFailsToLaunch() async {
        let client = HelperMessagingClient(executableURL: URL(fileURLWithPath: "/nonexistent/helper"), connectionString: "cs")
        await #expect(throws: (any Error).self) {
            try await client.peekDeadLetters(topic: "t", subscription: "s", max: 1, fromSequence: nil)
        }
    }
}
