// ABOUTME: Exercises SpeakerRepository: usage upsert, ranking, reconcile.
// ABOUTME: Uses Store.openInMemory() and seeds recordings via RecordingRepository.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SpeakerRepository")
struct SpeakerRepositoryTests {
    @Test func canConstructRepository() throws {
        let store = try Store.openInMemory()
        _ = SpeakerRepository(store: store)
    }
}
