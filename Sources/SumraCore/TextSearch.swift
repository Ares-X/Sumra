import Foundation

/// Matching policy shared by the platform readers and DjVu's existing word zones.
/// Offsets are UTF-16, matching NSString, NSTextView and the native search boundary.
public struct TextSearchOptions: Hashable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var allowedPages: IndexSet?
    public init(caseSensitive: Bool = false, wholeWord: Bool = false, allowedPages: IndexSet? = nil) {
        self.caseSensitive = caseSensitive; self.wholeWord = wholeWord
        self.allowedPages = allowedPages
    }
    public var compareOptions: String.CompareOptions { caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive] }

    private static let pageRange = try! NSRegularExpression(pattern: #"^\s*([0-9]+)?\s*([-–])?\s*([0-9]+)?\s*$"#)

    /// Sumatra SearchAndDDE::ParseFindPageRange: one-based pages, open/reversed
    /// ranges and comma lists; empty, invalid or wholly out-of-range means all.
    public static func pages(_ specification: String, count: Int) -> IndexSet? {
        guard count > 0 else { return nil }
        var pages = IndexSet()
        for token in specification.split(separator: ",") {
            let text = String(token).trimmingCharacters(in: .whitespacesAndNewlines) as NSString
            if text.length == 0 { continue }
            guard let match = pageRange.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
            func number(_ group: Int) -> Int? {
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(text.substring(with: range))
            }
            let first = number(1), last = number(3), dash = match.range(at: 2).location != NSNotFound
            // A present number that does not fit Int is malformed input.
            if (match.range(at: 1).location != NSNotFound && first == nil)
                || (match.range(at: 3).location != NSNotFound && last == nil) { return nil }
            guard first != nil || last != nil else { return nil }
            let start = first ?? 1, end = last ?? (dash ? count : start)
            let lower = max(1, min(start, end)), upper = min(count, max(start, end))
            if lower <= upper { pages.insert(integersIn: (lower - 1)..<upper) }
        }
        return pages.isEmpty ? nil : pages
    }

    /// BuildSnippet-style context, preserving composed characters around forty
    /// UTF-16 units on either side and collapsing whitespace for list rows.
    /// Callers bridge once per text scan, not once for every result.
    public static func snippet(in source: NSString, range: NSRange) -> String {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location < source.length, range.length <= source.length - range.location else { return "" }
        let lower = max(0, range.location - 40), upper = min(source.length, NSMaxRange(range) + min(40, source.length - NSMaxRange(range)))
        let context = source.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
        let snippet = source.substring(with: context).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (context.location > 0 ? "…" : "") + snippet + (NSMaxRange(context) < source.length ? "…" : "")
    }

    public func accepts(_ range: NSRange, in text: String) -> Bool {
        accepts(range, in: text as NSString)
    }

    private static func scalar(at offset: Int, in source: NSString) -> (value: UInt32, length: Int) {
        let code = source.character(at: offset)
        if (0xD800...0xDBFF).contains(code), offset + 1 < source.length {
            let next = source.character(at: offset + 1)
            if (0xDC00...0xDFFF).contains(next) { return (0x10000 + (UInt32(code) - 0xD800) * 1024 + UInt32(next) - 0xDC00, 2) }
        } else if (0xDC00...0xDFFF).contains(code), offset > 0 {
            let previous = source.character(at: offset - 1)
            if (0xD800...0xDBFF).contains(previous) { return (0x10000 + (UInt32(previous) - 0xD800) * 1024 + UInt32(code) - 0xDC00, 1) }
        }
        return (UInt32(code), 1)
    }

    private static func isWord(_ value: UInt32) -> Bool {
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    private func accepts(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return false }
        guard wholeWord else { return true }
        // Sumatra TextSelection::isWordChar: letters, numbers and underscore.
        // Combining marks stay with their letter; supplementary scalars are
        // decoded together instead of splitting surrogate pairs.
        func word(_ offset: Int) -> Bool {
            guard offset >= 0, offset < source.length else { return false }
            return Self.isWord(Self.scalar(at: offset, in: source).value)
        }
        return !(word(range.location - 1) && word(range.location))
            && !(word(NSMaxRange(range) - 1) && word(NSMaxRange(range)))
    }

    public func ranges(in text: String, query: String, after: Int? = nil,
                       backwards: Bool = false, maximum: Int? = nil) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if let maximum, maximum <= 0 { return [] }
        let source = text as NSString, pattern = query as NSString
        // TextSearch.cpp::MatchEnd / isnoncjkwordchar (012d997f). Keep
        // offsets in the original UTF-16 text, never in a normalized copy.
        func whitespace(_ value: UInt32) -> Bool { value == 32 || (9...13).contains(value) }
        func nonCJKWord(_ value: UInt32) -> Bool { value < 0x2E80 && Self.isWord(value) }
        func sharpS(_ value: UInt32) -> Bool { !caseSensitive && (value == 0xDF || value == 0x1E9E) }
        // Foundation compares contiguous words together, retaining its Unicode
        // case/canonical-equivalence behavior and variable-length matches.
        // MatchSearchUnit consumes a complete ß or two original s characters;
        // isolate it so whole-word folding cannot match ßs against Sß.
        var units = [(text: String, first: UInt32, last: UInt32)](), offset = 0
        while offset < pattern.length {
            try Task.checkCancellation()
            let first = Self.scalar(at: offset, in: pattern)
            var end = offset + first.length, last = first.value
            if nonCJKWord(first.value) && !sharpS(first.value) {
                while end < pattern.length {
                    let next = Self.scalar(at: end, in: pattern)
                    guard nonCJKWord(next.value) && !sharpS(next.value) else { break }
                    last = next.value; end += next.length
                }
            }
            units.append((pattern.substring(with: NSRange(location: offset, length: end - offset)), first.value, last))
            offset = end
        }
        let first = units[0]
        // Keep the original first-word anchor and its reverse-search boundary
        // even when MatchEnd compares that word in several sharp-S units.
        let anchorText = nonCJKWord(first.first)
            ? units.prefix { nonCJKWord($0.first) }.map(\.text).joined() : first.text
        let anchor = whitespace(first.first) || [45, 39, 34].contains(first.first) ? nil : anchorText
        func matchEnd(_ start: Int) throws -> Int? {
            var end = start, unit = 0
            while unit < units.count {
                try Task.checkCancellation()
                guard end < source.length else { return nil }
                let expected = units[unit], actual = Self.scalar(at: end, in: source)
                let lookingAtWhitespace = whitespace(actual.value)
                if whitespace(expected.first) && lookingAtWhitespace
                    || expected.first == 45 && (0x2010...0x2014).contains(actual.value)
                    || expected.first == 39 && (0x2018...0x201B).contains(actual.value)
                    || expected.first == 34 && (0x201C...0x201F).contains(actual.value) {
                    end += actual.length
                } else {
                    let hit = source.range(of: expected.text, options: compareOptions.union(.anchored),
                        range: NSRange(location: end, length: source.length - end))
                    guard hit.location != NSNotFound, hit.length > 0 else { return nil }
                    end = NSMaxRange(hit)
                }
                unit += 1
                if unit < units.count && ((!nonCJKWord(expected.last) && (expected.last != 63 || units[unit].first != 63))
                    || lookingAtWhitespace && whitespace(expected.last)) {
                    while unit < units.count && whitespace(units[unit].first) { unit += 1 }
                    while end < source.length {
                        let next = Self.scalar(at: end, in: source)
                        guard whitespace(next.value) else { break }
                        end += next.length
                    }
                }
            }
            return end
        }
        var result = [NSRange]()
        if backwards {
            var boundary = min(max(after ?? source.length, 0), source.length)
            while boundary > 0 {
                try Task.checkCancellation()
                let start: Int
                if let anchor {
                    let hit = source.range(of: anchor, options: compareOptions.union(.backwards),
                                           range: NSRange(location: 0, length: boundary))
                    guard hit.location != NSNotFound, hit.length > 0 else { break }
                    start = hit.location
                } else {
                    // GetNextIndex: move one scalar, retaining UTF-16 offsets.
                    var previous = boundary - 1
                    if previous > 0, (0xDC00...0xDFFF).contains(source.character(at: previous)),
                       (0xD800...0xDBFF).contains(source.character(at: previous - 1)) { previous -= 1 }
                    start = previous
                }
                // StrRStr bounds the anchor, not the complete phrase. MatchEnd
                // may extend past this boundary ("ab ab ab" finds 3, then 0).
                boundary = start
                if let end = try matchEnd(start) {
                    let hit = NSRange(location: start, length: end - start)
                    if accepts(hit, in: source) {
                        result.append(hit)
                        if let maximum, result.count >= maximum { break }
                    }
                }
            }
            return result
        }
        var start = 0
        if let after, after >= 0 {
            guard after < source.length else { return [] }
            // FindNext resumes after MatchEnd, including variable-length
            // normalization. An arbitrary offset only excludes that start.
            if let end = try matchEnd(after), accepts(NSRange(location: after, length: end - after), in: source) { start = end }
            else { start = after + Self.scalar(at: after, in: source).length }
        }
        while start < source.length {
            try Task.checkCancellation()
            if let anchor {
                let hit = source.range(of: anchor, options: compareOptions, range: NSRange(location: start, length: source.length - start))
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                start = hit.location
            }
            if let end = try matchEnd(start) {
                let hit = NSRange(location: start, length: end - start)
                if accepts(hit, in: source) {
                    result.append(hit)
                    if let maximum, result.count >= maximum { break }
                    start = end; continue
                }
            }
            start += Self.scalar(at: start, in: source).length
        }
        return result
    }
}
