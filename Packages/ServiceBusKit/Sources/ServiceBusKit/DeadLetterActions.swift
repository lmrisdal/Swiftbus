import Foundation

public enum DeadLetterAction: Sendable, Equatable {
    case resend
    case delete
}

public enum DeadLetterActions {
    /// Runs `action` over `sequenceNumbers` in batches so callers can show progress.
    /// A batch that throws (e.g. the helper died) marks only its own messages as failed; later batches still run.
    /// `deadLetter: false` deletes from the active queue (only meaningful for `.delete`).
    /// `onBatch` receives each batch's results as soon as they are known.
    public static func run(
        _ action: DeadLetterAction,
        client: any MessagingClient,
        topic: String,
        subscription: String?,
        sequenceNumbers: [Int64],
        deadLetter: Bool = true,
        batchSize: Int = 25,
        onBatch: @Sendable ([MessageResult]) async -> Void = { _ in }
    ) async -> [MessageResult] {
        var all: [MessageResult] = []
        for start in stride(from: 0, to: sequenceNumbers.count, by: max(batchSize, 1)) {
            if Task.isCancelled {
                let rest = sequenceNumbers[start...].map { MessageResult(sequenceNumber: $0, ok: false, error: "Cancelled") }
                await onBatch(rest)
                all += rest
                break
            }
            let batch = Array(sequenceNumbers[start..<min(start + batchSize, sequenceNumbers.count)])
            let results: [MessageResult]
            do {
                switch action {
                case .resend: results = try await client.resend(topic: topic, subscription: subscription, sequenceNumbers: batch)
                case .delete: results = try await client.delete(topic: topic, subscription: subscription, deadLetter: deadLetter, sequenceNumbers: batch)
                }
            } catch {
                results = batch.map { MessageResult(sequenceNumber: $0, ok: false, error: error.localizedDescription) }
            }
            await onBatch(results)
            all += results
        }
        return all
    }
}
