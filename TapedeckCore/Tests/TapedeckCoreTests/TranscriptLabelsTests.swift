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

    @Test func parseLabels_returnsUniqueInFirstOccurrenceOrder() {
        let txt = """
        [speaker 0] hello there

        [speaker 1] hi

        [speaker 0] how are you

        [Ben] good thanks
        """
        #expect(parseLabels(txt) == ["speaker 0", "speaker 1", "Ben"])
    }

    @Test func parseLabels_ignoresBracketsMidParagraph() {
        let txt = """
        [speaker 0] he said [hello] to me

        [Alice] and she said [goodbye]
        """
        #expect(parseLabels(txt) == ["speaker 0", "Alice"])
    }

    @Test func parseLabels_returnsEmptyForEmptyOrUnlabelled() {
        #expect(parseLabels("") == [])
        #expect(parseLabels("no labels here\n\njust text") == [])
    }
}
