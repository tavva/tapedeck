// ABOUTME: Verifies SourceClient refreshes the workspace token when it is close to
// ABOUTME: expiry, keeps values the server leaves out, and reports rejected refreshes.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient token refresh")
struct SourceClientRefreshTests {
    static let now: Int64 = 1_795_000_000_000
    static let fourMinutes: Int64 = 4 * 60 * 1000
    static let tenMinutes: Int64 = 10 * 60 * 1000

    private func makeClient(_ session: URLSession, expiresIn: Int64,
                            refreshExpiresIn: Int64 = 20 * 24 * 3600 * 1000) -> SourceClient {
        SourceClient(credentials: .test(token: "old-access", refreshToken: "old-refresh",
                                        expiresAt: Self.now + expiresIn,
                                        refreshExpiresAt: Self.now + refreshExpiresIn),
                     host: URL(string: "https://api-euc1.plaud.ai")!,
                     session: session)
    }

    private func respond(_ req: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (resp, Data(body.utf8))
    }

    @Test func doesNothingWhenTokenHasMoreThanFiveMinutesLeft() async throws {
        // No handlers: any request would fail the test.
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        let client = makeClient(session, expiresIn: Self.tenMinutes)
        #expect(try await client.refreshIfNeeded(now: Self.now) == nil)
        #expect(await client.credentials.token == "old-access")
    }

    @Test func refreshesWithinFiveMinutesOfExpiry() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        let seen = RequestLog()
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { _ in true }, handler: { req in
            seen.append(req)
            return URLProtocolStub.jsonResponse(for: req, fixture: "source/refresh_ok.json")
        })
        let client = makeClient(session, expiresIn: Self.fourMinutes)
        let refreshed = try #require(try await client.refreshIfNeeded(now: Self.now))

        #expect(refreshed == PlaudCredentials(
            workspaceId: "ws_test",
            token: "refreshed-access.eyJyZWdpb24iOiJhd3M6ZXUtY2VudHJhbC0xIn0.sig",
            refreshToken: "rotated-refresh.eyJyZWdpb24iOiJhd3M6ZXUtY2VudHJhbC0xIn0.sig",
            expiresAt: Self.now + 86_400_000,
            refreshExpiresAt: Self.now + 2_592_000_000))
        #expect(await client.credentials == refreshed)

        let req = try #require(seen.all.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString
                == "https://api-euc1.plaud.ai/user-app/auth/workspace/refresh/ws_test")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer old-refresh")
        #expect(req.value(forHTTPHeaderField: "X-Scope-Type") == "workspace")
        #expect(req.value(forHTTPHeaderField: "X-Scope-Id") == "ws_test")
    }

    @Test func refreshesAnAlreadyExpiredAccessToken() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/refresh_ok.json")
        })
        let client = makeClient(session, expiresIn: -Self.tenMinutes)
        #expect(try await client.refreshIfNeeded(now: Self.now) != nil)
    }

    @Test func keepsRefreshTokenWhenResponseOmitsIt() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/refresh_ok_access_only.json")
        })
        let client = makeClient(session, expiresIn: Self.fourMinutes, refreshExpiresIn: 1_000_000)
        let refreshed = try #require(try await client.refreshIfNeeded(now: Self.now))
        #expect(refreshed.token == "refreshed-access.eyJyZWdpb24iOiJhd3M6ZXUtY2VudHJhbC0xIn0.sig")
        #expect(refreshed.refreshToken == "old-refresh")
        #expect(refreshed.refreshExpiresAt == Self.now + 1_000_000)
    }

    @Test func laterRequestsUseTheRefreshedToken() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        let seen = RequestLog()
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { req in
            req.url?.path.hasPrefix("/user-app/auth/workspace/refresh/") == true
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/refresh_ok_access_only.json")
        })
        URLProtocolStub.register(sessionId: sid, "list", matching: { _ in true }, handler: { req in
            seen.append(req)
            return URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page2.json")
        })
        let client = makeClient(session, expiresIn: Self.fourMinutes)
        _ = try await client.refreshIfNeeded(now: Self.now)
        _ = try await client.listPage(cursor: nil)
        #expect(seen.all.first?.value(forHTTPHeaderField: "Authorization")
                == "Bearer refreshed-access.eyJyZWdpb24iOiJhd3M6ZXUtY2VudHJhbC0xIn0.sig")
    }

    @Test func expiredRefreshTokenThrowsUnauthorisedWithoutCallingPlaud() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        let client = makeClient(session, expiresIn: Self.fourMinutes, refreshExpiresIn: -1)
        await #expect(throws: SourceClientError.unauthorised) {
            _ = try await client.refreshIfNeeded(now: Self.now)
        }
    }

    @Test func http401FromRefreshThrowsUnauthorised() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, status: 401, fixture: "source/unauthorised.json")
        })
        let client = makeClient(session, expiresIn: Self.fourMinutes)
        await #expect(throws: SourceClientError.unauthorised) {
            _ = try await client.refreshIfNeeded(now: Self.now)
        }
    }

    @Test func rejectedRefreshStatusThrowsUnauthorised() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { _ in true }, handler: { req in
            self.respond(req, body: #"{"status":-1,"msg":"refresh token invalid"}"#)
        })
        let client = makeClient(session, expiresIn: Self.fourMinutes)
        await #expect(throws: SourceClientError.unauthorised) {
            _ = try await client.refreshIfNeeded(now: Self.now)
        }
        #expect(await client.credentials.token == "old-access")
    }

    @Test func refreshResponseWithoutATokenThrowsUnauthorised() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "refresh", matching: { _ in true }, handler: { req in
            self.respond(req, body: #"{"status":0,"data":{"expires_in":86400}}"#)
        })
        let client = makeClient(session, expiresIn: Self.fourMinutes)
        await #expect(throws: SourceClientError.unauthorised) {
            _ = try await client.refreshIfNeeded(now: Self.now)
        }
    }
}
