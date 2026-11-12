import Foundation

public enum ServiceBusError: Error, Equatable, LocalizedError {
    case unauthorized
    case notFound(String)
    case throttled(retryAfter: TimeInterval?)
    case http(status: Int, detail: String)
    case network(String)
    case conflict(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Access denied. Check the shared access key and that its policy has the rights needed: Manage to list topics, Listen to read and delete dead-letters, Send to resend."
        case .notFound(let what): "Not found: \(what)."
        case .throttled(let retryAfter):
            "Service Bus is throttling requests" + (retryAfter.map { " (retry after \(Int($0)) s)" } ?? "") + ". Try again shortly."
        case .network(let detail): "Could not reach Service Bus: \(detail)"
        case .http(let status, let detail): "Service Bus returned HTTP \(status). \(detail)"
        case .conflict(let detail): "Service Bus rejected the change: \(detail)"
        case .invalidResponse: "Service Bus returned a response that could not be read."
        }
    }
}
