// ABOUTME: Keychain access for shared items between Tapedeck UI and helper.
// ABOUTME: Uses kSecUseDataProtectionKeychain on macOS so kSecAttrAccessGroup applies.

import Foundation
import Security

public struct KeychainStore: Sendable {
    /// Resolved access group (team-prefixed) — must match both binaries' entitlements verbatim.
    public static let sharedAccessGroup = "C8Q84FVJHL.com.benphillips.tapedeck"

    /// Production wiring used by both binaries.
    public static let shared = KeychainStore(accessGroup: sharedAccessGroup)

    /// nil disables access-group scoping — only safe in unsigned test processes.
    public let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Data-protection keychain only works for signed binaries with a
        // keychain-access-groups entitlement. Tests run unsigned and use the
        // legacy file-backed login keychain instead.
        if let ag = accessGroup {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = ag
        }
        return q
    }

    public func set(service: String, account: String, value: String) throws {
        let base = baseQuery(service: service, account: account)
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func get(service: String, account: String) throws -> String? {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.osStatus(status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError.osStatus(status) }
    }

    public enum KeychainError: Error { case osStatus(OSStatus) }
}
