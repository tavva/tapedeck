// ABOUTME: Verifies SourceClient.discoverHost follows the JSON -302 redirect.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient host discovery")
struct SourceClientDiscoveryTests {
    @Test func switchesHostOn302Response() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "default->redirect", matching: { req in
            req.url?.host == "api.plaud.ai" && req.url?.path == "/file-app/v4/recordings/all"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/redirect_302.json")
        })
        URLProtocolStub.register(sessionId: sid, "regional->list", matching: { req in
            req.url?.host == "api-euc1.plaud.ai"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page2.json")
        })

        let client = SourceClient(credentials: .test(token: "token-without-region.eyJzdWIiOiJ4In0.sig"),
                                  host: URL(string: "https://api.plaud.ai")!,
                                  session: session)
        try await client.discoverHost()
        let resolved = await client.currentHost()
        #expect(resolved.host == "api-euc1.plaud.ai")
    }

    @Test func keepsHostWhenItAlreadyServesRecordings() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "list", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page2.json")
        })
        let client = SourceClient(credentials: .test(),
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: session)
        try await client.discoverHost()
        #expect(await client.currentHost().host == "api-euc1.plaud.ai")
    }
}
