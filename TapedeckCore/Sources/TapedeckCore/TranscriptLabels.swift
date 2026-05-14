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

/// Returns the unique speaker labels found at the start of each paragraph
/// (paragraphs separated by blank lines), in first-occurrence order.
/// A label is the text inside the leading `[...]` of a paragraph.
public func parseLabels(_ transcript: String) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for paragraph in transcript.components(separatedBy: "\n\n") {
        guard let label = leadingLabel(of: paragraph) else { continue }
        if seen.insert(label).inserted { ordered.append(label) }
    }
    return ordered
}

private func leadingLabel(of paragraph: String) -> String? {
    let trimmed = paragraph.drop(while: { $0 == " " || $0 == "\t" })
    guard trimmed.first == "[" else { return nil }
    let afterBracket = trimmed.dropFirst()
    guard let endIdx = afterBracket.firstIndex(of: "]") else { return nil }
    let label = String(afterBracket[..<endIdx])
    guard !label.isEmpty, !label.contains("\n") else { return nil }
    return label
}
