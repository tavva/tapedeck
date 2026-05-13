// ABOUTME: Unit tests for PlaybackController state machine. Uses a real silent WAV
// ABOUTME: written to a temp dir so AVAudioPlayer exercises real Core Audio code paths.

import XCTest
@testable import Tapedeck
import TapedeckCore

@MainActor
final class PlaybackControllerTests: XCTestCase {
    var fixtureURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureURL = try WAVFixture.writeSilent()
        PlaybackController.audioURL = { [fixtureURL] _ in fixtureURL! }
    }

    override func tearDownWithError() throws {
        if let url = fixtureURL { try? FileManager.default.removeItem(at: url) }
        PlaybackController.audioURL = PlaybackController.defaultAudioURL
        try super.tearDownWithError()
    }

    func testInitialState() {
        let controller = PlaybackController()
        XCTAssertNil(controller.currentRecording)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 0)
    }

    func testLoadSetsCurrentRecording() {
        let rec = Recording.test(sourceId: "src-1", audioURL: fixtureURL)
        let controller = PlaybackController()
        controller.load(rec)
        XCTAssertEqual(controller.currentRecording?.sourceId, "src-1")
        XCTAssertGreaterThan(controller.duration, 0)
    }

    func testLoadMissingFileLeavesCurrentRecordingNil() {
        PlaybackController.audioURL = { _ in
            URL(fileURLWithPath: "/nonexistent/playback-test-missing.wav")
        }
        let rec = Recording.test(sourceId: "src-missing", audioURL: fixtureURL)
        let controller = PlaybackController()
        controller.load(rec)
        XCTAssertNil(controller.currentRecording)
        XCTAssertEqual(controller.duration, 0)
    }
}
