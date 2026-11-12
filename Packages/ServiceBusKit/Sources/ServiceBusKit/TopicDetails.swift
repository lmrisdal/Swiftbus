import Foundation

/// The settings and metadata of a topic, as its `TopicDescription` reports them. Every field is
/// optional: older namespaces and tiers leave some out, and the UI shows only what is present.
public struct TopicDetails: Sendable, Equatable, Hashable {
    public var sizeInBytes: Int?
    public var maxSizeInMegabytes: Int?
    public var scheduledMessageCount: Int?
    /// `nil` when absent or effectively unlimited (`TimeSpan.MaxValue`).
    public var defaultMessageTimeToLive: TimeInterval?
    public var autoDeleteOnIdle: TimeInterval?
    public var duplicateDetectionWindow: TimeInterval?
    public var requiresDuplicateDetection: Bool?
    public var enableBatchedOperations: Bool?
    public var supportOrdering: Bool?
    public var enablePartitioning: Bool?
    public var createdAt: Date?
    public var updatedAt: Date?
    /// `nil` until the topic is first used (Service Bus reports year 1).
    public var accessedAt: Date?

    public init() {}

    /// Reads the flattened `<content>` fields of a topic's Atom entry.
    init(fields: [String: String]) {
        func int(_ key: String) -> Int? { fields[key].flatMap { Int($0) } }
        func bool(_ key: String) -> Bool? { fields[key].map { $0.lowercased() == "true" } }
        func duration(_ key: String) -> TimeInterval? { fields[key].flatMap(Self.parseDuration).flatMap(Self.limited) }
        func date(_ key: String) -> Date? { fields[key].flatMap(Self.parseDate) }
        sizeInBytes = int("SizeInBytes")
        maxSizeInMegabytes = int("MaxSizeInMegabytes")
        scheduledMessageCount = int("ScheduledMessageCount")
        defaultMessageTimeToLive = duration("DefaultMessageTimeToLive")
        autoDeleteOnIdle = duration("AutoDeleteOnIdle")
        duplicateDetectionWindow = duration("DuplicateDetectionHistoryTimeWindow")
        requiresDuplicateDetection = bool("RequiresDuplicateDetection")
        enableBatchedOperations = bool("EnableBatchedOperations")
        supportOrdering = bool("SupportOrdering")
        enablePartitioning = bool("EnablePartitioning")
        createdAt = date("CreatedAt")
        updatedAt = date("UpdatedAt")
        accessedAt = date("AccessedAt")
    }

    /// Durations of 100 years or more stand for "never" (Service Bus uses `TimeSpan.MaxValue`).
    private static func limited(_ interval: TimeInterval) -> TimeInterval? {
        interval >= 100 * 365 * 86_400 ? nil : interval
    }

    /// Parses an XML Schema duration such as `P14D`, `PT10M` or `P10675199DT2H48M5.4775807S`.
    /// Years and months are not used by Service Bus and are rejected.
    static func parseDuration(_ text: String) -> TimeInterval? {
        guard text.hasPrefix("P") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        var sawUnit = false
        for ch in text.dropFirst() {
            switch ch {
            case "T": inTime = true
            case "0"..."9", ".": number.append(ch)
            case "D", "H", "M", "S":
                guard let value = Double(number) else { return nil }
                switch (ch, inTime) {
                case ("D", false): total += value * 86_400
                case ("H", true): total += value * 3_600
                case ("M", true): total += value * 60
                case ("S", true): total += value
                default: return nil
                }
                number = ""
                sawUnit = true
            default: return nil
            }
        }
        return sawUnit && number.isEmpty ? total : nil
    }

    /// Parses `2025-01-27T13:45:12.1234567Z`. Fractions are dropped: Service Bus sends up to seven
    /// digits, which `ISO8601DateFormatter` rejects. Year-1 placeholders become `nil`.
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let date = ISO8601DateFormatter().date(from: trimmed),
              date > Date(timeIntervalSince1970: 0) else { return nil }
        return date
    }

    /// A short human form such as "14 days", "10 minutes" or "1 day, 2 hours"; "Never" for `nil`.
    public static func describe(_ interval: TimeInterval?) -> String {
        guard let interval else { return "Never" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "\(Int(interval)) s"
    }
}
