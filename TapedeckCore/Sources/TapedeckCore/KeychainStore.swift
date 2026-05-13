// ABOUTME: Shared secret storage for the Tapedeck UI and helper binaries.
// ABOUTME: Signed builds use the data-protection keychain via access group; ad-hoc
// ABOUTME: local builds fall back to a 0600 JSON file under Application Support so
// ABOUTME: rebuilt binaries don't re-prompt for keychain ACL grants.

import Foundation
import Security

public struct KeychainStore: Sendable {
    /// Production wiring used by both binaries. Reads the team-prefixed access group
    /// from the embedded `keychain-access-groups` entitlement at runtime — codesign
    /// resolves `$(AppIdentifierPrefix)` to the actual team ID when signing, so the
    /// same source builds under any Apple Developer team. Probes once whether the
    /// data-protection keychain is reachable; falls back to the file-backed store
    /// for ad-hoc-signed local builds and unsigned test processes that lack the
    /// entitlement.
    public static let shared: KeychainStore = {
        guard let accessGroup = resolveAccessGroupFromEntitlements() else {
            return KeychainStore(accessGroup: nil)
        }
        let candidate = KeychainStore(accessGroup: accessGroup)
        let probeService = "tapedeck.entitlement.probe"
        do {
            _ = try candidate.get(service: probeService, account: "default")
            return candidate
        } catch KeychainError.osStatus(let status) where status == errSecMissingEntitlement {
            return KeychainStore(accessGroup: nil)
        } catch {
            return candidate
        }
    }()

    private static func resolveAccessGroupFromEntitlements() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String] else {
            return nil
        }
        return groups.first
    }

    /// nil means file-backed storage — both binaries (same user) share a JSON file
    /// at `Layout.standard.devSecretsURL()` with mode 0600. The legacy file-based
    /// login keychain is no longer used: its ACLs are bound to each binary's
    /// codesign hash, which changes on every ad-hoc rebuild, forcing repeat
    /// "Always Allow" prompts. The file-backed store sidesteps that entirely.
    public let accessGroup: String?
    private let fileURL: URL?

    public init(accessGroup: String?) {
        self.accessGroup = accessGroup
        self.fileURL = accessGroup == nil ? Layout.standard.devSecretsURL() : nil
    }

    public init(filePath: URL) {
        self.accessGroup = nil
        self.fileURL = filePath
    }

    public func set(service: String, account: String, value: String) throws {
        if let url = fileURL {
            var dict = Self.readFile(at: url)
            dict[Self.key(service: service, account: account)] = value
            try Self.writeFile(at: url, dict: dict)
            return
        }
        let base = baseQuery(service: service, account: account)
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    public func get(service: String, account: String) throws -> String? {
        if let url = fileURL {
            return Self.readFile(at: url)[Self.key(service: service, account: account)]
        }
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
        if let url = fileURL {
            var dict = Self.readFile(at: url)
            guard dict.removeValue(forKey: Self.key(service: service, account: account)) != nil else { return }
            try Self.writeFile(at: url, dict: dict)
            return
        }
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainError.osStatus(status) }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let ag = accessGroup {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrAccessGroup as String] = ag
        }
        return q
    }

    private static func key(service: String, account: String) -> String {
        "\(service)/\(account)"
    }

    private static func readFile(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeFile(at url: URL, dict: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(dict)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public enum KeychainError: Error { case osStatus(OSStatus) }
}
