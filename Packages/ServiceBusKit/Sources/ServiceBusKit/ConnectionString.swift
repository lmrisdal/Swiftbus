import Foundation

/// A parsed Azure Service Bus connection string.
public struct ConnectionString: Sendable, Equatable {
    public enum ParseError: Error, Equatable, LocalizedError {
        case missingField(String)
        case invalidEndpoint(String)

        public var errorDescription: String? {
            switch self {
            case .missingField(let name): "The connection string has no \(name)."
            case .invalidEndpoint(let value): "'\(value)' is not a valid Service Bus endpoint."
            }
        }
    }

    /// Fully qualified namespace host, e.g. `my-ns.servicebus.windows.net`.
    public let host: String
    public let keyName: String
    public let key: String
    public let entityPath: String?

    public init(host: String, keyName: String, key: String, entityPath: String? = nil) {
        self.host = host
        self.keyName = keyName
        self.key = key
        self.entityPath = entityPath
    }

    public init(_ string: String) throws {
        var fields: [String: String] = [:]
        for part in string.split(separator: ";", omittingEmptySubsequences: true) {
            // Values (notably the base64 key) may contain '=', so split on the first one only.
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            fields[name] = value
        }
        guard let endpoint = fields["endpoint"], !endpoint.isEmpty else { throw ParseError.missingField("Endpoint") }
        guard let keyName = fields["sharedaccesskeyname"], !keyName.isEmpty else {
            throw ParseError.missingField("SharedAccessKeyName")
        }
        guard let key = fields["sharedaccesskey"], !key.isEmpty else {
            throw ParseError.missingField("SharedAccessKey")
        }
        let hostPart = endpoint.replacingOccurrences(of: "sb://", with: "", options: [.caseInsensitive, .anchored])
        let host = hostPart.split(separator: "/").first.map(String.init) ?? ""
        guard !host.isEmpty, !host.contains(" "), !host.contains(":") || host.hasSuffix(":443") else {
            throw ParseError.invalidEndpoint(endpoint)
        }
        self.init(host: host.replacingOccurrences(of: ":443", with: ""),
                  keyName: keyName, key: key,
                  entityPath: fields["entitypath"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The namespace name, i.e. the first label of the host.
    public var namespace: String { host.split(separator: ".").first.map(String.init) ?? host }
}
