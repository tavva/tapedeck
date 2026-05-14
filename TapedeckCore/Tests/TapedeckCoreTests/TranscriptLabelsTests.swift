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

    @Test func renameLabel_rewritesOnlyLeadingLabels() {
        let input = """
        [speaker 0] he said [speaker 0] earlier

        [speaker 1] noted
        """
        let expected = """
        [Ben] he said [speaker 0] earlier

        [speaker 1] noted
        """
        #expect(renameLabel(input, from: "speaker 0", to: "Ben") == expected)
    }

    @Test func renameLabel_isNoOpWhenOldNotPresent() {
        let txt = "[Alice] hello\n\n[Bob] hi"
        #expect(renameLabel(txt, from: "speaker 0", to: "Ben") == txt)
    }

    @Test func renameLabel_mergesIntoExistingLabel() {
        let input = """
        [speaker 0] alpha

        [Ben] beta

        [speaker 0] gamma
        """
        let expected = """
        [Ben] alpha

        [Ben] beta

        [Ben] gamma
        """
        #expect(renameLabel(input, from: "speaker 0", to: "Ben") == expected)
    }

    @Test func parseLabels_handlesCRLFParagraphBoundaries() {
        let txt = "[speaker 0] hi\r\n\r\n[Ben] hello"
        #expect(parseLabels(txt) == ["speaker 0", "Ben"])
    }

    @Test func parseLabels_handlesExtraBlankLines() {
        let txt = "[speaker 0] hi\n\n\n[Ben] hello"
        #expect(parseLabels(txt) == ["speaker 0", "Ben"])
    }

    @Test func renameLabel_handlesCRLFParagraphBoundaries() {
        let input = "[speaker 0] hi\r\n\r\n[speaker 0] bye"
        let result = renameLabel(input, from: "speaker 0", to: "Ben")
        // Both paragraphs should be rewritten; the CRLF separator stays intact.
        #expect(result == "[Ben] hi\r\n\r\n[Ben] bye")
    }

    @Test func validateSpeakerName_acceptsNormalNames() {
        #expect(validateSpeakerName("Ben") == nil)
        #expect(validateSpeakerName("Alice Smith") == nil)
        #expect(validateSpeakerName("  Ben  ") == nil)
        #expect(validateSpeakerName("speaker coach") == nil)
    }

    @Test func validateSpeakerName_rejectsEmpty() {
        #expect(validateSpeakerName("") != nil)
        #expect(validateSpeakerName("   ") != nil)
        #expect(validateSpeakerName("\t\n") != nil)
    }

    @Test func validateSpeakerName_rejectsBracketAndNewline() {
        #expect(validateSpeakerName("Ben]") != nil)
        #expect(validateSpeakerName("[Ben") != nil)
        #expect(validateSpeakerName("Ben\nSmith") != nil)
    }
}
