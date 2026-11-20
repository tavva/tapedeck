// ABOUTME: Verifies the Plaud 4.0 list and file-detail calls: request shape, paging,
// ABOUTME: field mapping onto Recording, source-id mapping and error handling.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient list")
struct SourceClientListTests {
    private func makeClient(_ session: URLSession) -> SourceClient {
        SourceClient(credentials: .test(token: "access-token"),
                     host: URL(string: "https://api-euc1.plaud.ai")!,
                     session: session)
    }

    private func respond(_ req: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        return (resp, Data(body.utf8))
    }

    @Test func listPageMapsItemsOntoRecordings() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "list", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page1.json")
        })
        let page = try await makeClient(session).listPage(cursor: nil)
        #expect(page.recordings.map(\.sourceId) == [
            "f_00000000000000000000000000000001",
            "831cd03902e3336766fbe551874ef6f7",
        ])
        let legacy = page.recordings[1]
        #expect(legacy.filename == "2026-11-10 13:16:53")
        #expect(legacy.startedAt == 1794316613000)
        #expect(legacy.durationMs == 10877000)
        #expect(legacy.filesize == 0)
        #expect(page.nextCursor == "Y3Vyc29yLXBhZ2UtMg==")
    }

    @Test func listPageSendsWorkspaceAuthAndPaging() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        let seen = RequestLog()
        URLProtocolStub.register(sessionId: sid, "list", matching: { _ in true }, handler: { req in
            seen.append(req)
            return URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page2.json")
        })
        _ = try await makeClient(session).listPage(cursor: "abc+/=", pageSize: 50)
        let req = try #require(seen.all.first)
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/file-app/v4/recordings/all")
        #expect(components.queryItems?.contains(.init(name: "page_size", value: "50")) == true)
        #expect(components.queryItems?.contains(.init(name: "cursor", value: "abc+/=")) == true)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(req.value(forHTTPHeaderField: "X-Scope-Type") == "workspace")
        #expect(req.value(forHTTPHeaderField: "X-Scope-Id") == "ws_test")
    }

    @Test func lastPageHasNoNextCursor() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "list", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page2.json")
        })
        let page = try await makeClient(session).listPage(cursor: nil)
        #expect(page.nextCursor == nil)
    }

    @Test func listAllFollowsCursorUntilTheLastPage() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "page2", matching: { req in
            req.url?.query?.contains("cursor=") == true
        }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page2.json")
        })
        URLProtocolStub.register(sessionId: sid, "page1", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/recordings_page1.json")
        })
        let all = try await makeClient(session).listAll()
        #expect(all.count == 3)
        #expect(all.last?.sourceId == "e9c006b1224fa7a17bd5ea862d4cb274")
    }

    @Test func nonZeroStatusThrowsAPIError() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "migrated", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/account_migrated.json")
        })
        await #expect(throws: SourceClientError.api(
            status: -1800907, message: "Account migrated to 4.0. Please update and reinitialize.")) {
            _ = try await makeClient(session).listPage(cursor: nil)
        }
    }

    @Test func http401ThrowsUnauthorised() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "401", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, status: 401, fixture: "source/unauthorised.json")
        })
        await #expect(throws: SourceClientError.unauthorised) {
            _ = try await makeClient(session).listPage(cursor: nil)
        }
    }

    @Test func fileDetailReturnsOriginalAudioURLAndSize() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "detail", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/file_detail.json")
        })
        let detail = try await makeClient(session).fileDetail(for: "831cd03902e3336766fbe551874ef6f7")
        #expect(detail.audioURL.host?.contains("amazonaws.com") == true)
        #expect(detail.audioURL.pathExtension == "ogg")
        #expect(detail.audioSize == 46412288)
    }

    @Test func fileDetailAsksForThePrefixedIdOfAMigratedRecording() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        let seen = RequestLog()
        URLProtocolStub.register(sessionId: sid, "detail", matching: { _ in true }, handler: { req in
            seen.append(req)
            return URLProtocolStub.jsonResponse(for: req, fixture: "source/file_detail.json")
        })
        let client = makeClient(session)
        _ = try await client.fileDetail(for: "831cd03902e3336766fbe551874ef6f7")
        _ = try await client.fileDetail(for: "f_00000000000000000000000000000001")
        #expect(seen.all.map { $0.url!.path } == [
            "/file-app/v4/files/detail/of_831cd03902e3336766fbe551874ef6f7",
            "/file-app/v4/files/detail/f_00000000000000000000000000000001",
        ])
        #expect(seen.all.first?.value(forHTTPHeaderField: "X-Scope-Id") == "ws_test")
    }

    @Test func fileDetailMetadataKeepsTheResponseButDropsPresignedURLs() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "detail", matching: { _ in true }, handler: { req in
            URLProtocolStub.jsonResponse(for: req, fixture: "source/file_detail.json")
        })
        let detail = try await makeClient(session).fileDetail(for: "831cd03902e3336766fbe551874ef6f7")
        let text = String(decoding: detail.metadata, as: UTF8.self)
        #expect(!text.contains("X-Amz-Signature"))
        let obj = try #require(try JSONSerialization.jsonObject(with: detail.metadata) as? [String: Any])
        let data = try #require(obj["data"] as? [String: Any])
        let meta = try #require(data["meta"] as? [String: Any])
        #expect(meta["file_id"] as? String == "of_831cd03902e3336766fbe551874ef6f7")
        let objects = try #require(data["objects"] as? [[String: Any]])
        #expect(objects.count == 2)
        #expect(objects.first?["object_size"] as? Int == 46412288)
    }

    @Test func fileDetailWithoutOriginalAudioIsMalformed() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "detail", matching: { _ in true }, handler: { req in
            self.respond(req, body: #"{"status":0,"data":{"objects":[]}}"#)
        })
        await #expect(throws: SourceClientError.malformedResponse("no AUDIO object")) {
            _ = try await makeClient(session).fileDetail(for: "f_1")
        }
    }

    @Test func fileDetailNotFoundThrowsAPIError() async throws {
        let (session, sid) = URLProtocolStub.makeSession()
        defer { URLProtocolStub.clear(sessionId: sid) }
        URLProtocolStub.register(sessionId: sid, "detail", matching: { _ in true }, handler: { req in
            self.respond(req, body: #"{"status":-1800311,"msg":"file not found"}"#)
        })
        await #expect(throws: SourceClientError.api(status: -1800311, message: "file not found")) {
            _ = try await makeClient(session).fileDetail(for: "f_1")
        }
    }

    @Test func sourceIdsMapToAndFromPlaudFileIds() {
        #expect(SourceClient.sourceId(fileId: "of_831cd039") == "831cd039")
        #expect(SourceClient.sourceId(fileId: "f_01a1") == "f_01a1")
        #expect(SourceClient.fileId(sourceId: "831cd039") == "of_831cd039")
        #expect(SourceClient.fileId(sourceId: "f_01a1") == "f_01a1")
    }
}

/// Collects requests seen by a stub handler, which runs off the test's task.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ req: URLRequest) { lock.lock(); requests.append(req); lock.unlock() }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
