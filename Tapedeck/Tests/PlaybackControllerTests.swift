// ABOUTME: Unit tests for PlaybackController state machine. Uses a real silent WAV
// ABOUTME: written to a temp dir so AVAudioPlayer exercises real Core Audio code paths.

import XCTest
@testable import Tapedeck
import TapedeckCore

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testInitialState() {
        let controller = PlaybackController()
        XCTAssertNil(controller.currentRecording)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 0)
    }
}
