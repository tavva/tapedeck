// ABOUTME: Tests for transcript speaker-label parsing and rewriting helpers.

import Testing
@testable import TapedeckCore

@Suite("TranscriptLabels")
struct TranscriptLabelsTests {
    @Test func isDefaultLabel_matchesSpeakerWithDigits() {
        #expect(isDefaultLabel("speaker 0"))
        #expect(isDefaultLabel("speaker 12"))
    }

    @Test func isDefaultLabel_rejectsOtherStrings() {
        #expect(!isDefaultLabel("speaker coach"))
        #expect(!isDefaultLabel("Speaker 0"))
        #expect(!isDefaultLabel(" speaker 0"))
        #expect(!isDefaultLabel("speaker 0x"))
        #expect(!isDefaultLabel("speaker"))
        #expect(!isDefaultLabel(""))
        #expect(!isDefaultLabel("Ben"))
    }
}
