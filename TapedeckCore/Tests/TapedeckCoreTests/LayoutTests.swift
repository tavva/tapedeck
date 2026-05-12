// ABOUTME: Verifies path construction is locale-independent and sanitises titles.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("Layout")
struct LayoutTests {
    private static let tmpRoot: Layout = {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "tapedeck-layout-tests")
        return Layout(userRoot: tmp.appending(path: "user"),
                      supportRoot: tmp.appending(path: "support"),
                      logsRoot: tmp.appending(path: "logs"))
    }()

    @Test func audioDirIsUTCDateUnderUserRoot() {
        let date = Date(timeIntervalSince1970: 1_778_503_307)  // 2026-05-11T03:21:47Z
        let dir = Self.tmpRoot.audioDir(date: date)
        #expect(dir.lastPathComponent == "2026-05-11")
        #expect(dir.path.hasSuffix("user/audio/2026-05-11"))
    }

    @Test func stemSanitisesSlashesAndColons() {
        let stem = Self.tmpRoot.stem(sourceId: "abc", title: "Meeting 1: A/B test  ")
        #expect(stem == "abc_Meeting 1_ A_B test")
    }

    @Test func stemTruncatesAt80Chars() {
        let title = String(repeating: "x", count: 200)
        let stem = Self.tmpRoot.stem(sourceId: "id", title: title)
        let suffix = stem.dropFirst("id_".count)
        #expect(suffix.count == 80)
    }
}
