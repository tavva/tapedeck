// ABOUTME: Verifies the pasted sign-in JSON parses into PlaudCredentials and that
// ABOUTME: the stored form round-trips.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("PlaudCredentials")
struct PlaudCredentialsTests {
    /// Exactly what the TokenWindow console snippet copies: the web app's token
    /// entry (including tokenType) plus the workspace id.
    static let pasted = """
    {"workspaceId":"ws_abc","token":"access.jwt","tokenType":"Bearer",\
    "expiresAt":1795265051715,"refreshToken":"refresh.jwt","refreshExpiresAt":1797770651715}
    """

    @Test func parsesConsoleSnippetOutput() throws {
        let creds = try PlaudCredentials(json: Self.pasted)
        #expect(creds == PlaudCredentials(workspaceId: "ws_abc", token: "access.jwt",
                                          refreshToken: "refresh.jwt",
                                          expiresAt: 1795265051715,
                                          refreshExpiresAt: 1797770651715))
    }

    @Test func ignoresSurroundingWhitespace() throws {
        let creds = try PlaudCredentials(json: "\n  \(Self.pasted)  \n")
        #expect(creds.workspaceId == "ws_abc")
    }

    @Test func rejectsABareToken() {
        #expect(throws: (any Error).self) {
            try PlaudCredentials(json: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig")
        }
    }

    @Test func rejectsJSONMissingTheRefreshToken() {
        #expect(throws: (any Error).self) {
            try PlaudCredentials(json: #"{"workspaceId":"ws_abc","token":"a","expiresAt":1}"#)
        }
    }

    @Test func storedFormRoundTrips() throws {
        let creds = PlaudCredentials.test()
        #expect(try PlaudCredentials(json: creds.json()) == creds)
    }
}
