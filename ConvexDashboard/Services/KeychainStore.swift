import Foundation
import Security

/// Stores secrets in the Keychain. Never use UserDefaults for secrets.
enum KeychainStore {
    enum Item: String {
        /// Convex team/project access token for the Management + Deployment APIs.
        case convexAccessToken
        /// Base URL of the user's self-hosted monitoring backend (backend/).
        case pulseURL
        /// APP_KEY of the user's monitoring backend.
        case pulseAppKey
    }

    private static let service = "com.dcantu.convexdashboard"
    /// Shared with the widget extension (`keychain-access-groups` in project.yml), so widgets can
    /// read the token without the app running.
    private static let accessGroup = Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String

    static func load(_ item: Item) -> String? {
        if let accessGroup, let value = read(item, group: accessGroup) { return value }
        // Saved before widgets existed: copy it into the shared group (best effort) and use it.
        guard let value = read(item, group: nil) else { return nil }
        if let accessGroup { add(value, for: item, group: accessGroup) }
        return value
    }

    @discardableResult
    static func save(_ value: String, for item: Item) -> Bool {
        delete(item)
        if let accessGroup, add(value, for: item, group: accessGroup) { return true }
        // Builds without the entitlement (e.g. unsigned) keep it app-only.
        return add(value, for: item, group: nil)
    }

    /// Removes the item from every group this process can access.
    static func delete(_ item: Item) {
        SecItemDelete(baseQuery(item) as CFDictionary)
    }

    private static func read(_ item: Item, group: String?) -> String? {
        var query = baseQuery(item)
        if let group { query[kSecAttrAccessGroup as String] = group }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func add(_ value: String, for item: Item, group: String?) -> Bool {
        var query = baseQuery(item)
        if let group { query[kSecAttrAccessGroup as String] = group }
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }
}
