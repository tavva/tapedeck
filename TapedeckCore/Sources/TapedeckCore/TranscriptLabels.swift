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
    for paragraph in splitParagraphs(transcript).paragraphs {
        guard let label = leadingLabel(of: paragraph) else { continue }
        if seen.insert(label).inserted { ordered.append(label) }
    }
    return ordered
}

private func leadingLabel(of paragraph: String) -> String? {
    let trimmed = paragraph.drop(while: { $0.isWhitespace })
    guard trimmed.first == "[" else { return nil }
    let afterBracket = trimmed.dropFirst()
    guard let endIdx = afterBracket.firstIndex(of: "]") else { return nil }
    let label = String(afterBracket[..<endIdx])
    guard !label.isEmpty, !label.contains("\n") else { return nil }
    return label
}

/// Splits `text` on blank-line paragraph boundaries, tolerating CRLF and
/// extra blank lines. Returns the paragraph fragments alongside the verbatim
/// separator that followed each fragment (the final entry's separator is
/// empty). Joining `paragraphs[i] + separators[i]` for all `i` reproduces
/// the input exactly.
private func splitParagraphs(_ text: String) -> (paragraphs: [String], separators: [String]) {
    // A blank-line boundary is a run of two or more consecutive line endings,
    // where each line ending is \n or \r\n (treated as a unit).
    let pattern = "(?:\\r?\\n){2,}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return ([text], [""])
    }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    if matches.isEmpty { return ([text], [""]) }
    var paragraphs: [String] = []
    var separators: [String] = []
    var cursor = 0
    for match in matches {
        let r = match.range
        paragraphs.append(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
        separators.append(ns.substring(with: r))
        cursor = r.location + r.length
    }
    paragraphs.append(ns.substring(from: cursor))
    separators.append("")
    return (paragraphs, separators)
}

/// Rewrites every paragraph whose leading label is `old` so its label becomes
/// `new`. Splits on blank-line paragraph boundaries; the `[old]` token must
/// be the very first non-whitespace content of the paragraph to match.
///
/// `new` is inserted verbatim — callers must validate that it is non-empty and
/// contains no `[`, `]`, or newline characters. Invalid names produce a
/// malformed transcript that `parseLabels` will silently drop.
public func renameLabel(_ transcript: String, from old: String, to new: String) -> String {
    let oldToken = "[\(old)]"
    let newToken = "[\(new)]"
    let (paragraphs, separators) = splitParagraphs(transcript)
    var result = ""
    for (paragraph, separator) in zip(paragraphs, separators) {
        if leadingLabel(of: paragraph) == old {
            let leadingWhitespace = paragraph.prefix(while: { $0.isWhitespace })
            let body = paragraph.dropFirst(leadingWhitespace.count).dropFirst(oldToken.count)
            result += leadingWhitespace + newToken + body
        } else {
            result += paragraph
        }
        result += separator
    }
    return result
}
