import XCTest
@testable import SumraCore

final class TextSearchTests: XCTestCase {
    func testSearchPageRangesFollowTheUpstreamFindField() {
        XCTAssertEqual(TextSearchOptions.pages("3, 4–6, 18-", count: 20), IndexSet([2, 3, 4, 5, 17, 18, 19]))
        XCTAssertEqual(TextSearchOptions.pages("6-3", count: 20), IndexSet(2..<6))
        XCTAssertEqual(TextSearchOptions.pages("-2,19-30", count: 20), IndexSet([0, 1, 18, 19]))
        XCTAssertEqual(TextSearchOptions.pages("0-2, 2, ,", count: 20), IndexSet([0, 1]))
        for value in ["", " ", "-", "x", "3-x", "1-2-3", "21-30", "99999999999999999999999999999999"] {
            XCTAssertNil(TextSearchOptions.pages(value, count: 20), value)
        }
        XCTAssertNil(TextSearchOptions.pages("1", count: 0))
    }

    func testResultContextPreservesEmojiAndNormalizesWhitespace() {
        let text = String(repeating: "😀", count: 30) + " before\nneedle\t after " + String(repeating: "猫", count: 50)
        let range = (text as NSString).range(of: "needle")
        let context = TextSearchOptions.snippet(in: text as NSString, range: range)
        XCTAssertTrue(context.hasPrefix("…")); XCTAssertTrue(context.hasSuffix("…"))
        XCTAssertTrue(context.contains("before needle after"))
        XCTAssertFalse(context.contains("�")); XCTAssertFalse(context.contains("\n"))
        XCTAssertEqual(TextSearchOptions.snippet(in: "needle", range: NSRange(location: 0, length: 6)), "needle")
        XCTAssertTrue(TextSearchOptions.snippet(in: text as NSString, range: NSRange(location: NSNotFound, length: 1)).isEmpty)
    }

    func testCaseAndWholeWordsPreserveUTF16Offsets() throws {
        let text = "😀 Cat cat scatter cat_ cat2 (cat)"
        let exact = try TextSearchOptions(caseSensitive: true, wholeWord: true).ranges(in: text, query: "cat")
        let source = text as NSString
        XCTAssertEqual(exact.count, 2)
        XCTAssertEqual(exact.map { source.substring(with: $0) }, ["cat", "cat"])
        XCTAssertEqual(exact.first?.location, 7)
        XCTAssertEqual(try TextSearchOptions(wholeWord: true).ranges(in: text, query: "cat").count, 3)
        XCTAssertEqual(try TextSearchOptions().ranges(in: text, query: "cat").count, 6)
    }
    func testUnicodeWordBoundariesAndCombiningLetters() throws {
        let options = TextSearchOptions(wholeWord: true)
        XCTAssertEqual(try options.ranges(in: "猫 猫咪 小猫", query: "猫").count, 1)
        XCTAssertEqual(try options.ranges(in: "é e\u{301} tête", query: "e"),
                       [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)])
        XCTAssertTrue(try TextSearchOptions(caseSensitive: true, wholeWord: true).ranges(in: "é e\u{301} tête", query: "e").isEmpty)
        XCTAssertEqual(try options.ranges(in: "𐐀𐐨 𐐨", query: "𐐨").count, 1)
        XCTAssertTrue(try options.ranges(in: "text", query: "").isEmpty)
        XCTAssertFalse(options.accepts(NSRange(location: NSNotFound, length: 1), in: "text"))
    }

    func testUpstreamWhitespaceAndTypographyToleranceKeepsOriginalUTF16Ranges() throws {
        let text = "😀 hello  \r\nworld; well–known; don’t; “quoted”", source = text as NSString
        for (query, original) in [("hello world", "hello  \r\nworld"), ("well-known", "well–known"),
                                  ("don't", "don’t"), ("\"quoted\"", "“quoted”")] {
            let ranges = try TextSearchOptions().ranges(in: text, query: query)
            XCTAssertEqual(ranges, [source.range(of: original)], query)
            XCTAssertEqual(ranges.map { source.substring(with: $0) }, [original])
        }
        for dash in ["‐", "‑", "‒", "–", "—"] {
            XCTAssertEqual(try TextSearchOptions(caseSensitive: true).ranges(in: "well\(dash)known", query: "well-known"), [NSRange(location: 0, length: 10)])
            XCTAssertTrue(try TextSearchOptions().ranges(in: "well-known", query: "well\(dash)known").isEmpty,
                          "The upstream typography substitution is query-side ASCII only")
        }
        XCTAssertTrue(try TextSearchOptions(caseSensitive: true).ranges(in: "Don’t", query: "don't").isEmpty)
        XCTAssertEqual(try TextSearchOptions(wholeWord: true).ranges(in: "don’t don’tknow", query: "don't"), [NSRange(location: 0, length: 5)])
    }

    func testWhitespaceAfterCJKAndPunctuationDoesNotJoinLatinWordsOrReplacementCharacters() throws {
        let text = "猫 \n咪; x,   y; x?\n?; x??; ab cd", source = text as NSString
        for (query, original) in [("猫咪", "猫 \n咪"), ("x,y", "x,   y"), ("x??", "x??"), ("ab  cd", "ab cd")] {
            XCTAssertEqual(try TextSearchOptions().ranges(in: text, query: query), [source.range(of: original)])
        }
        XCTAssertTrue(try TextSearchOptions().ranges(in: text, query: "abcd").isEmpty)
        XCTAssertTrue(try TextSearchOptions().ranges(in: "x? ?", query: "x??").isEmpty)
        XCTAssertTrue(try TextSearchOptions().ranges(in: "hello world", query: "helloworld").isEmpty)
    }

    func testDirectionalContinuationUsesTheActualHitEndAndStopsAtTheLimit() throws {
        let options = TextSearchOptions(), text = "aaaaaaa"
        XCTAssertEqual(try options.ranges(in: text, query: "aaa").map(\.location), [0, 3])
        XCTAssertEqual(try options.ranges(in: text, query: "aaa", backwards: true).map(\.location), [4, 1])
        XCTAssertEqual(try options.ranges(in: text, query: "aaa", after: 1, maximum: 1), [NSRange(location: 4, length: 3)])
        XCTAssertEqual(try options.ranges(in: text, query: "aaa", after: 4, backwards: true, maximum: 1), [NSRange(location: 1, length: 3)])
        XCTAssertTrue(try options.ranges(in: text, query: "aaa", after: 2, backwards: true).isEmpty)
        XCTAssertEqual(try options.ranges(in: "xaaa", query: "aaa", after: 0, maximum: 1), [NSRange(location: 1, length: 3)],
                       "An offset that is not an old match excludes only that candidate start")
        XCTAssertTrue(try options.ranges(in: text, query: "aaa", maximum: 0).isEmpty)
        XCTAssertTrue(try options.ranges(in: text, query: "aaa", after: Int.max).isEmpty)
        XCTAssertTrue(try options.ranges(in: text, query: "aaa", after: 0, backwards: true).isEmpty)
    }

    func testReverseAnchorBoundaryAllowsTheUpstreamOverlappingPhrase() throws {
        let options = TextSearchOptions()
        XCTAssertEqual(try options.ranges(in: "ab ab ab", query: "ab ab", backwards: true),
                       [NSRange(location: 3, length: 5), NSRange(location: 0, length: 5)])
        XCTAssertEqual(try options.ranges(in: "ab ab ab", query: "ab ab", after: 3, backwards: true, maximum: 1),
                       [NSRange(location: 0, length: 5)], "Only the anchor must end before the previous start")
        XCTAssertEqual(try options.ranges(in: "😀 “猫” “猫”", query: "\"猫\"", backwards: true),
                       [NSRange(location: 7, length: 3), NSRange(location: 3, length: 3)])
        XCTAssertEqual(try options.ranges(in: "😀 𐐨 𐐨", query: "𐐨", after: 6, backwards: true, maximum: 1),
                       [NSRange(location: 3, length: 2)])
    }

    func testWholeWordRejectionsDoNotConsumeTheDirectionalLimit() throws {
        let options = TextSearchOptions(wholeWord: true), text = "cat scat cat2 cat"
        XCTAssertEqual(try options.ranges(in: text, query: "cat", after: 0, maximum: 1), [NSRange(location: 14, length: 3)])
        XCTAssertEqual(try options.ranges(in: text, query: "cat", after: 14, backwards: true, maximum: 1), [NSRange(location: 0, length: 3)])
        XCTAssertEqual(try options.ranges(in: text, query: "cat", backwards: true, maximum: 1), [NSRange(location: 14, length: 3)])
    }

    func testAccentFoldingAndSharpSKeepVariableLengthUTF16Ranges() throws {
        let options = TextSearchOptions(wholeWord: true), text = "😀 CAFÉ Cafe\u{301} café"
        XCTAssertEqual(try options.ranges(in: text, query: "cafe"),
                       [NSRange(location: 3, length: 4), NSRange(location: 8, length: 5), NSRange(location: 14, length: 4)])
        XCTAssertEqual(try options.ranges(in: text, query: "cafe", after: 8, maximum: 1), [NSRange(location: 14, length: 4)])
        XCTAssertEqual(try TextSearchOptions(caseSensitive: true, wholeWord: true).ranges(in: text, query: "CAFÉ"), [NSRange(location: 3, length: 4)])
        XCTAssertTrue(try TextSearchOptions(caseSensitive: true, wholeWord: true).ranges(in: text, query: "cafe").isEmpty)
        let sharpS = "ß ss ẞ SS s", folded = TextSearchOptions()
        let equivalent = [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2), NSRange(location: 5, length: 1), NSRange(location: 7, length: 2)]
        XCTAssertEqual(try folded.ranges(in: sharpS, query: "ss"), equivalent)
        XCTAssertEqual(try folded.ranges(in: sharpS, query: "ß"), equivalent)
        XCTAssertEqual(try folded.ranges(in: sharpS, query: "s").map(\.location), [2, 3, 7, 8, 10], "A single s must not match part of ß")
        XCTAssertEqual(try folded.ranges(in: "ßss", query: "ss", after: 0, maximum: 1), [NSRange(location: 1, length: 2)])
        XCTAssertEqual(try folded.ranges(in: "ßssß", query: "ss", backwards: true).map(\.location), [3, 1, 0])
    }

    func testSharpSDoesNotCrossAnUpstreamSearchUnitBoundary() throws {
        let options = TextSearchOptions()
        for backwards in [false, true] {
            XCTAssertTrue(try options.ranges(in: "Sß", query: "ßs", backwards: backwards).isEmpty,
                          "The initial ß requires two actual consecutive s characters")
            XCTAssertEqual(try options.ranges(in: "SßS", query: "ss", backwards: backwards), [NSRange(location: 1, length: 1)],
                           "Only the complete middle ß matches ss")
            XCTAssertTrue(try options.ranges(in: "ßß", query: "sss", backwards: backwards).isEmpty,
                          "A match cannot consume one and a half sharp-S units")
            XCTAssertEqual(try options.ranges(in: "ssss", query: "ßß", backwards: backwards), [NSRange(location: 0, length: 4)])
            let street = [NSRange(location: 0, length: 6), NSRange(location: 7, length: 7), NSRange(location: 15, length: 6)]
            XCTAssertEqual(try options.ranges(in: "Straße STRASSE straẞe", query: "Straße", backwards: backwards),
                           backwards ? Array(street.reversed()) : street)
        }
        XCTAssertEqual(try TextSearchOptions(caseSensitive: true).ranges(in: "Straße STRASSE straẞe", query: "Straße"),
                       [NSRange(location: 0, length: 6)])
        XCTAssertEqual(try options.ranges(in: "SßS", query: "ss", after: 0, maximum: 1), [NSRange(location: 1, length: 1)])
        XCTAssertTrue(try options.ranges(in: "SßS", query: "ss", after: 1, maximum: 1).isEmpty)
        XCTAssertEqual(try options.ranges(in: "SßS", query: "ss", after: 2, backwards: true, maximum: 1), [NSRange(location: 1, length: 1)])
    }

    func testCancelledSearchRetainsCancellation() async {
        let task = Task { () throws -> [NSRange] in
            return try TextSearchOptions().ranges(in: String(repeating: "a ", count: 100_000), query: "a")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
