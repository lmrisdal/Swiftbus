import CryptoKit
import Foundation

/// Generates Shared Access Signature tokens for a connection string.
public struct SASTokenProvider: Sendable {
    public struct Token: Sendable, Equatable {
        public let value: String
        public let expiry: Date
    }

    private let connection: ConnectionString
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date

    public init(connection: ConnectionString, lifetime: TimeInterval = 3600,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.connection = connection
        self.lifetime = lifetime
        self.now = now
    }

    /// Creates a token valid for `resource` (a URL such as `https://ns.servicebus.windows.net/`).
    public func makeToken(resource: String? = nil, expiry: Date? = nil) -> Token {
        let resource = (resource ?? "https://\(connection.host)/").lowercased()
        let expiry = expiry ?? now().addingTimeInterval(lifetime)
        let seconds = Int(expiry.timeIntervalSince1970)
        let encodedResource = Self.urlEncode(resource)
        let signed = "\(encodedResource)\n\(seconds)"
        let keyData = SymmetricKey(data: Data(connection.key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signed.utf8), using: keyData)
        let signature = Self.urlEncode(Data(mac).base64EncodedString())
        let value = "SharedAccessSignature sr=\(encodedResource)&sig=\(signature)&se=\(seconds)&skn=\(connection.keyName)"
        return Token(value: value, expiry: expiry)
    }

    static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

/// Caches a namespace-wide token until shortly before it expires.
public actor SASTokenCache {
    private let provider: SASTokenProvider
    private let margin: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: SASTokenProvider.Token?

    public init(provider: SASTokenProvider, margin: TimeInterval = 300,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.margin = margin
        self.now = now
    }

    public func token() -> String {
        if let cached, cached.expiry.timeIntervalSince(now()) > margin { return cached.value }
        let fresh = provider.makeToken()
        cached = fresh
        return fresh.value
    }
}
