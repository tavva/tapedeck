// ABOUTME: Round-trips a value through the file-scoped (nil-access-group) keychain.
// ABOUTME: Cross-process verification via signed binaries lives in scripts/verify-keychain-sharing.sh.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test func roundTripWriteReadDelete() throws {
        let store = KeychainStore(accessGroup: nil)
        let service = "tapedeck.test.\(UUID().uuidString)"
        try store.set(service: service, account: "default", value: "hello")
        #expect(try store.get(service: service, account: "default") == "hello")
        try store.delete(service: service, account: "default")
        #expect(try store.get(service: service, account: "default") == nil)
    }
}
