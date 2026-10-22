import Foundation
import Security

/// Somewhere to keep the Spotify tokens. The Keychain in the app, memory in tests.
protocol TokenStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
    func delete()
}

/// Generic-password Keychain item for the Spotify tokens.
final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    init(service: String = "CarPlayLyrics.Spotify", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func save(_ data: Data) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Readable while the phone is locked (CarPlay is mostly used that way),
            // never synced or restored to another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

final class InMemoryTokenStore: TokenStore {
    var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
    func delete() { data = nil }
}
