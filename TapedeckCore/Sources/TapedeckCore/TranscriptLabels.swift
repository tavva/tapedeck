// ABOUTME: Pure helpers for parsing and rewriting [speaker] labels in transcripts.
// ABOUTME: Used by SpeakerEditor (rename flow) and SpeakerRepository (filtering).

import Foundation

/// Returns true iff `name` matches Deepgram's default output format exactly:
/// `speaker` + single space + one or more digits, with nothing else.
public func isDefaultLabel(_ name: String) -> Bool {
    guard name.hasPrefix("speaker ") else { return false }
    let rest = name.dropFirst("speaker ".count)
    guard !rest.isEmpty else { return false }
    return rest.allSatisfy { $0.isASCII && $0.isNumber }
}
