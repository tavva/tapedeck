// ABOUTME: Builds PlaudCredentials for tests. Defaults expire far in the future so
// ABOUTME: a pipeline cycle never tries to refresh unless a test asks it to.

import Foundation
@testable import TapedeckCore

extension PlaudCredentials {
    static let farFuture: Int64 = 4_102_444_800_000  // 2100-01-01

    static func test(token: String = "t.eyJzdWIiOiJ4In0.sig",
                     refreshToken: String = "refresh-token",
                     expiresAt: Int64 = farFuture,
                     refreshExpiresAt: Int64 = farFuture) -> PlaudCredentials {
        PlaudCredentials(workspaceId: "ws_test", token: token, refreshToken: refreshToken,
                         expiresAt: expiresAt, refreshExpiresAt: refreshExpiresAt)
    }
}
