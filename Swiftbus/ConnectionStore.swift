import Foundation
import Security
import ServiceBusKit

struct SavedConnection: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
}

/// Saved connections: display names in UserDefaults, connection strings in the Keychain.
@MainActor
final class ConnectionStore {
    private let defaultsKey = "savedConnections"
    private let service = "com.risdal.Swiftbus.connection"

    func load() -> [SavedConnection] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
    }

    func save(_ connections: [SavedConnection]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(connections), forKey: defaultsKey)
    }

    func secret(for connection: SavedConnection) -> String? {
        var query = baseQuery(connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func setSecret(_ secret: String, for connection: SavedConnection) {
        let query = baseQuery(connection)
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func deleteSecret(for connection: SavedConnection) {
        SecItemDelete(baseQuery(connection) as CFDictionary)
    }

    private func baseQuery(_ connection: SavedConnection) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: connection.id.uuidString]
    }
}
