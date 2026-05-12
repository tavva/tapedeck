// ABOUTME: Verifies list-page parsing maps Plaud fields onto Recording.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient list", .serialized)
struct SourceClientListTests {
    @Test func parsesListResponseIntoRecordings() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.register("list", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/list_page1.json")
        })
        let client = SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: URLProtocolStub.ephemeralSession())
        let page = try await client.listPage(skip: 0, limit: 2)
        #expect(page.count == 2)
        #expect(page.first?.startedAt ?? 0 > 1_500_000_000_000)
    }

    @Test func parsesTempUrl() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.register("temp", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/temp_url.json")
        })
        let client = SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: URLProtocolStub.ephemeralSession())
        let url = try await client.tempURL(for: "any-id")
        #expect(url.host?.contains("amazonaws.com") == true)
    }

    @Test func rawMetadataReturnsBodyVerbatim() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.register("meta", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/raw_metadata.json")
        })
        let client = SourceClient(token: "t.eyJzdWIiOiJ4In0.sig",
                                  host: URL(string: "https://api-euc1.plaud.ai")!,
                                  session: URLProtocolStub.ephemeralSession())
        let data = try await client.rawMetadata(for: ["any-id"])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["status"] as? Int == 0)
    }
}
