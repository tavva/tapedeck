// ABOUTME: Verifies SourceClient.discoverHost follows the JSON -302 redirect.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient host discovery", .serialized)
struct SourceClientDiscoveryTests {
    @Test func switchesHostOn302Response() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.register("default->redirect", matching: { req in
            req.url?.host == "api.plaud.ai"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/redirect_302.json")
        })
        URLProtocolStub.register("regional->list", matching: { req in
            req.url?.host == "api-euc1.plaud.ai"
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/list_page1.json")
        })

        let client = SourceClient(token: "token-without-region.eyJzdWIiOiJ4In0.sig",
                                  host: URL(string: "https://api.plaud.ai")!,
                                  session: URLProtocolStub.ephemeralSession())
        try await client.discoverHost()
        let resolved = await client.currentHost()
        #expect(resolved.host == "api-euc1.plaud.ai")
    }
}
