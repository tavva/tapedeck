// ABOUTME: Unit tests for StatusCounts — pure function over [Recording]
// ABOUTME: deriving the toolbar status display from pipeline-stage timestamps.

import XCTest
@testable import Tapedeck
import TapedeckCore

final class StatusCountsTests: XCTestCase {
    func testEmpty() {
        let counts = StatusCounts(recordings: [])
        XCTAssertEqual(counts.total, 0)
        XCTAssertEqual(counts.toTranscribe, 0)
        XCTAssertEqual(counts.toClassify, 0)
    }

    func testCountsByStage() {
        let recs: [Recording] = [
            make(sid: "a"),                                    // not downloaded
            make(sid: "b", downloaded: 1),                     // to transcribe
            make(sid: "c", downloaded: 1),                     // to transcribe
            make(sid: "d", downloaded: 1, transcribed: 1),     // to classify
            make(sid: "e", downloaded: 1, transcribed: 1, classified: 1), // done
        ]
        let counts = StatusCounts(recordings: recs)
        XCTAssertEqual(counts.total, 5)
        XCTAssertEqual(counts.toTranscribe, 2)
        XCTAssertEqual(counts.toClassify, 1)
    }

    func testTranscribedButNotDownloadedDoesNotCountAsToClassify() {
        // Defensive: shouldn't happen in practice, but transcribed without
        // download still satisfies the "to classify" rule (transcribed && !classified).
        let recs = [make(sid: "x", transcribed: 1)]
        let counts = StatusCounts(recordings: recs)
        XCTAssertEqual(counts.toTranscribe, 0)
        XCTAssertEqual(counts.toClassify, 1)
    }

    private func make(sid: String, downloaded: Int64? = nil,
                      transcribed: Int64? = nil, classified: Int64? = nil) -> Recording {
        Recording(sourceId: sid, filename: "\(sid).opus", startedAt: 0,
                  durationMs: 0, filesize: 0, audioExtension: nil,
                  audioDownloadedAt: downloaded, transcribedAt: transcribed,
                  classifiedAt: classified, lastSeenAt: 0)
    }
}
