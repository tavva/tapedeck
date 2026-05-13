// ABOUTME: Round-trips a value through the file-backed (no-entitlement) KeychainStore path.
// ABOUTME: Cross-process verification via signed binaries lives in scripts/verify-keychain-sharing.sh.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("KeychainStore")
struct KeychainStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kc-test-\(UUID().uuidString).json")
    }

    @Test func roundTripWriteReadDelete() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KeychainStore(filePath: url)
        let service = "tapedeck.test.\(UUID().uuidString)"
        try store.set(service: service, account: "default", value: "hello")
        #expect(try store.get(service: service, account: "default") == "hello")
        try store.delete(service: service, account: "default")
        #expect(try store.get(service: service, account: "default") == nil)
    }

    @Test func fileBackedStorageWritesToDisk() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KeychainStore(filePath: url)
        try store.set(service: "svc", account: "acct", value: "secret")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("secret"))
    }

    @Test func twoInstancesShareSameFile() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = KeychainStore(filePath: url)
        let reader = KeychainStore(filePath: url)
        try writer.set(service: "svc", account: "acct", value: "v1")
        #expect(try reader.get(service: "svc", account: "acct") == "v1")
        try writer.set(service: "svc", account: "acct", value: "v2")
        #expect(try reader.get(service: "svc", account: "acct") == "v2")
    }

    @Test func filePermissionsAreUserOnly() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KeychainStore(filePath: url)
        try store.set(service: "svc", account: "acct", value: "secret")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
    }
}
