import Foundation

public struct Topic: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// `Active` or `Disabled`.
    public var status: String
    public var subscriptions: [Subscription]

    public init(name: String, status: String = "Active", subscriptions: [Subscription] = []) {
        self.name = name
        self.status = status
        self.subscriptions = subscriptions
    }

    public var isDisabled: Bool { status == "Disabled" }

    public var deadLetterCount: Int { subscriptions.reduce(0) { $0 + $1.deadLetterCount } }
    public var transferDeadLetterCount: Int { subscriptions.reduce(0) { $0 + $1.transferDeadLetterCount } }
}

public struct Subscription: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(topic)/\(name)" }
    public let topic: String
    public let name: String
    public let status: String
    public let activeCount: Int
    public let deadLetterCount: Int
    public let transferDeadLetterCount: Int

    public init(topic: String, name: String, status: String = "Active", activeCount: Int = 0,
                deadLetterCount: Int = 0, transferDeadLetterCount: Int = 0) {
        self.topic = topic
        self.name = name
        self.status = status
        self.activeCount = activeCount
        self.deadLetterCount = deadLetterCount
        self.transferDeadLetterCount = transferDeadLetterCount
    }
}

/// A queue. Its dead-letter queue is read the same way as a subscription's.
public struct Queue: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let status: String
    public let activeCount: Int
    public let deadLetterCount: Int
    public let transferDeadLetterCount: Int

    public init(name: String, status: String = "Active", activeCount: Int = 0,
                deadLetterCount: Int = 0, transferDeadLetterCount: Int = 0) {
        self.name = name
        self.status = status
        self.activeCount = activeCount
        self.deadLetterCount = deadLetterCount
        self.transferDeadLetterCount = transferDeadLetterCount
    }

    public var isDisabled: Bool { status == "Disabled" }
}

/// Whether an entity accepts traffic. Disabling is reversible; it is what "Disable" in the UI sets.
public enum EntityStatus: String, Sendable {
    case active = "Active"
    case disabled = "Disabled"
}
