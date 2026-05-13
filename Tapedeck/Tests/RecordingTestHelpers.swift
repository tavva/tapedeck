// ABOUTME: Test helpers for synthesising Recording instances pointing at temp audio.

import Foundation
import TapedeckCore

extension Recording {
    static func test(sourceId: String, audioURL: URL) -> Recording {
        Recording(
            sourceId: sourceId,
            filename: audioURL.lastPathComponent,
            startedAt: 0,
            durationMs: 100,
            filesize: 0,
            audioExtension: audioURL.pathExtension,
            lastSeenAt: 0
        )
    }
}
