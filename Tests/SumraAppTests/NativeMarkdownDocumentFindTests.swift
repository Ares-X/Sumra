#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeMarkdownDocumentFindTests: XCTestCase {
    private func open(_ name: String, html: String, in directory: TemporaryDirectory,
                      css: String = "") throws -> NativeFile {
        let input = directory.url.appendingPathComponent(name + ".md")
        try html.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        XCTAssertNotNil(try file.relayout(fontSize: 17, lineHeight: 1.6,
                                          font: "system", theme: "light", userCSS: css))
        return file
    }

    private func assertFragments(_ match: RasterMatch, pages: [Int], file: NativeFile,
                                 filePath: StaticString = #filePath, line: UInt = #line) throws {
        let fragments = try XCTUnwrap(match.fragments, file: filePath, line: line)
        XCTAssertEqual(fragments.map(\.page), pages, file: filePath, line: line)
        for fragment in fragments {
            let text = try XCTUnwrap(file.text(fragment.page), file: filePath, line: line) as NSString
            XCTAssertGreaterThan(fragment.length, 0, file: filePath, line: line)
            XCTAssertLessThanOrEqual(fragment.start + fragment.length, text.length, file: filePath, line: line)
            XCTAssertTrue(fragment.rects.contains { $0.width > 0 && $0.height > 0 },
                          file: filePath, line: line)
        }
    }

    func testChineseAndEnglishCrossPhysicalPagesAreOneLogicalMatch() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let cjkCapacity = try open("CJK-capacity", html: "<p>" + String(repeating: "甲", count: 1000) + "</p>", in: temporary)
        let cjkFirst = try XCTUnwrap(cjkCapacity.text(0))
        let cjkCount = cjkFirst.filter { $0 == "甲" }.count
        XCTAssertGreaterThan(cjkCount, 4)
        let cjk = try open("CJK-boundary", html: "<p>" + String(repeating: "甲", count: cjkCount - 2) +
                           "普通汉字" + String(repeating: "乙", count: 20) + "</p>", in: temporary)
        XCTAssertEqual(cjk.count, 2)
        XCTAssertTrue(try XCTUnwrap(cjk.text(0)).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("普通"))
        XCTAssertTrue(try XCTUnwrap(cjk.text(1)).hasPrefix("汉字"))
        let cjkHit = try XCTUnwrap(cjk.markdownDocumentMatches("普通汉字", options: .init(),
                                                               startPage: 0).first)
        try assertFragments(cjkHit, pages: [0, 1], file: cjk)
        XCTAssertTrue(try cjk.markdownDocumentMatches("普通 汉字", options: .init(), startPage: 0).isEmpty)
        XCTAssertEqual(try cjk.markdownDocumentMatches("普通汉字", options: .init(), startPage: 1,
                                                      backwards: true).first?.source, cjkHit.source)
        XCTAssertEqual(try cjk.markdownDocumentMatches("普通汉字", options: .init(), startPage: 1).first?.source,
                       cjkHit.source, "A match beginning on the preceding page remains a wrap hit")

        // The capacity oracle must use the same glyph advance for its filler
        // and the boundary marker; proportional x/ABCD widths move the seam.
        let css = "p{font-family:monospace !important;overflow-wrap:break-word !important;}"
        let englishCapacity = try open("English-capacity", html: "<p>" + String(repeating: "x", count: 2000) + "</p>",
                                       in: temporary, css: css)
        let englishCount = try XCTUnwrap(englishCapacity.text(0)).filter { $0 == "x" }.count
        XCTAssertGreaterThan(englishCount, 4)
        let english = try open("English-boundary", html: "<p>" + String(repeating: "x", count: englishCount - 2) +
                               "ABCD" + String(repeating: "y", count: 20) + "</p>", in: temporary, css: css)
        XCTAssertEqual(english.count, 2)
        XCTAssertTrue(try XCTUnwrap(english.text(0)).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("AB"))
        XCTAssertTrue(try XCTUnwrap(english.text(1)).hasPrefix("CD"))
        let englishHit = try XCTUnwrap(english.markdownDocumentMatches("ABCD", options: .init(), startPage: 0).first)
        try assertFragments(englishHit, pages: [0, 1], file: english)
    }

    func testLongWordCrossesThreePagesAndAllowedPagesCannotBridgeAHole() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let css = "p{overflow-wrap:break-word !important;}"
        let capacityFile = try open("Three-capacity", html: "<p>" + String(repeating: "w", count: 2000) + "</p>",
                                    in: temporary, css: css)
        XCTAssertGreaterThanOrEqual(capacityFile.count, 3)
        let firstCapacity = try XCTUnwrap(capacityFile.text(0)).filter { $0 == "w" }.count
        let secondCapacity = try XCTUnwrap(capacityFile.text(1)).filter { $0 == "w" }.count
        XCTAssertGreaterThan(firstCapacity, 4)
        XCTAssertGreaterThan(secondCapacity, 4)
        // The first page can have a different usable height from later pages.
        // Filling both measured pages plus slack makes the query span page 3.
        let token = "AB" + String(repeating: "w", count: firstCapacity + secondCapacity + 20) + "CD"
        let file = try open("Three-pages", html: "<p>" + token + "</p>", in: temporary, css: css)
        XCTAssertGreaterThanOrEqual(file.count, 3)
        let hit = try XCTUnwrap(file.markdownDocumentMatches(token, options: .init(), startPage: 0).first)
        let pages = try XCTUnwrap(hit.fragments).map(\.page)
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        try assertFragments(hit, pages: pages, file: file)
        let all = IndexSet(integersIn: 0..<file.count)
        XCTAssertEqual(try file.markdownDocumentMatches(token, options: .init(allowedPages: all),
                                                        startPage: 0).count, 1)
        var withHole = all
        withHole.remove(pages[1])
        XCTAssertTrue(try file.markdownDocumentMatches(token, options: .init(allowedPages: withHole),
                                                       startPage: 0).isEmpty)
    }

    func testNormalizedChunkSeamAndSourceCursorSurviveReflow() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let body = String(repeating: "x", count: 32_766) + "ABCD" + String(repeating: "y", count: 20)
        let file = try open("Chunk-seam", html: "<p>" + body + "</p>", in: temporary,
                            css: "p{overflow-wrap:break-word !important;}")
        let first = try XCTUnwrap(file.markdownDocumentMatches("xxABCD", options: .init(), startPage: 0).first)
        XCTAssertNotNil(first.source)
        XCTAssertEqual(try file.markdownDocumentMatches("xxABCD", options: .init(), startPage: 0,
                                                        after: first.source).first?.source, first.source,
                       "Find wraps when the source cursor passes the only hit")
        XCTAssertTrue(try file.markdownDocumentMatches("ABCD", options: .init(wholeWord: true),
                                                       startPage: 0).isEmpty)
        XCTAssertNotNil(try file.relayout(fontSize: 11, lineHeight: 1.6, font: "system", theme: "light",
                                              userCSS: "p{overflow-wrap:break-word !important;}"))
        let second = try XCTUnwrap(file.markdownDocumentMatches("xxABCD", options: .init(), startPage: 0).first)
        XCTAssertEqual(second.source, first.source)
        XCTAssertFalse(try XCTUnwrap(second.fragments).isEmpty)

        let two = try open("Two-cursors", html: "<p>ALPHA " + String(repeating: "x", count: 1000) +
                           " ALPHA</p>", in: temporary, css: "p{overflow-wrap:break-word !important;}")
        let firstAlpha = try XCTUnwrap(two.markdownDocumentMatches("ALPHA", options: .init(wholeWord: true),
                                                                   startPage: 0).first)
        let secondAlpha = try XCTUnwrap(two.markdownDocumentMatches("ALPHA", options: .init(wholeWord: true),
                                                                    startPage: 0, after: firstAlpha.source).first)
        XCTAssertNotEqual(firstAlpha.source, secondAlpha.source)
        XCTAssertGreaterThan(secondAlpha.page, firstAlpha.page)
        XCTAssertEqual(try two.markdownDocumentMatches("ALPHA", options: .init(wholeWord: true), startPage: 0,
                                                      after: secondAlpha.source, backwards: true).first?.source,
                       firstAlpha.source)
    }

    func testInclusiveSourceCursorRestoresTheSameOccurrenceThenExclusiveFindAdvances() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let file = try open("Inclusive-cursor", html: "<p>ALPHA ALPHA ALPHA</p>", in: temporary)
        let original = try file.markdownDocumentMatches("ALPHA", options: .init(wholeWord: true),
            startPage: 0, maximum: 3)
        XCTAssertEqual(original.count, 3)
        guard original.count == 3 else { return }
        XCTAssertEqual(original[0].page, original[1].page)
        XCTAssertNotNil(try file.relayout(fontSize: 30, lineHeight: 1.6, font: "system", theme: "light"))
        for backwards in [false, true] {
            let restored = try XCTUnwrap(file.markdownDocumentMatches("ALPHA", options: .init(wholeWord: true),
                startPage: 0, after: original[1].source, backwards: backwards, inclusive: true).first)
            XCTAssertEqual(restored.source, original[1].source)
            XCTAssertNotEqual(restored.rects, original[1].rects)
            XCTAssertTrue(restored.rects.contains { $0.width > 0 && $0.height > 0 })
            XCTAssertEqual(try file.markdownDocumentMatches("ALPHA", options: .init(wholeWord: true),
                startPage: restored.page, after: restored.source, backwards: backwards).first?.source,
                original[backwards ? 0 : 2].source)
        }
    }

    func testForwardStartPageChoosesTailPrimaryAndFreshEarlierWrap() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let body = "<p>EARLY833</p>" + String(repeating: "<p>MARK833 ordinary paragraph padding.</p>", count: 200) +
            "<p><span style=\"visibility:hidden\">HIDDEN833</span>MARK833 TAIL833</p>"
        let file = try open("Suffix-tail", html: body, in: temporary)
        XCTAssertGreaterThan(file.count, 2)
        let tailPage = file.count - 1
        let all = try file.markdownDocumentMatches("MARK833", options: .init(wholeWord: true),
                                                   startPage: 0, counting: true, maximum: 1000)
        let expected = try XCTUnwrap(all.first { $0.page >= tailPage })
        XCTAssertEqual(try file.markdownDocumentMatches("MARK833", options: .init(wholeWord: true),
                                                         startPage: tailPage).first?.source, expected.source)
        let early = try XCTUnwrap(file.markdownDocumentMatches("EARLY833", options: .init(), startPage: 0).first)
        XCTAssertEqual(try file.markdownDocumentMatches("EARLY833", options: .init(),
                                                         startPage: tailPage).first?.source, early.source)
        XCTAssertEqual(try file.markdownDocumentMatches(" TAIL833", options: .init(),
                                                         startPage: tailPage).count, 1)
        for query in ["TAIL833 EARLY833", "HIDDEN833", "padding.MARK833"] {
            XCTAssertTrue(try file.markdownDocumentMatches(query, options: .init(), startPage: tailPage).isEmpty)
        }
        XCTAssertTrue(try file.markdownDocumentMatches("AIL833", options: .init(wholeWord: true),
                                                       startPage: tailPage).isEmpty)
    }

    func testForwardSuffixPreservesWholeParagraphRTLAndConservativeSmallTree() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let rtl = "שלום עולם בדיקה עברית מילים מסמך קריאה חיפוש גבולות"
        // This small tree has no sibling draw index; suffix selection must
        // conservatively traverse it and keep the full authored paragraph.
        let file = try open("Suffix-small-RTL", html: "<p>" + String(repeating: "prefix ", count: 250) +
            "</p><p dir=\"rtl\" lang=\"he\">" + rtl + " ABC833 tail " + rtl + "</p>", in: temporary,
            css: "p{width:120px !important;overflow-wrap:break-word !important;}")
        let all = try file.markdownDocumentMatches("ABC833 tail", options: .init(wholeWord: true),
                                                    startPage: 0, counting: true, maximum: 10)
        let expected = try XCTUnwrap(all.first)
        XCTAssertGreaterThan(expected.page, 0)
        XCTAssertEqual(try file.markdownDocumentMatches("ABC833 tail", options: .init(wholeWord: true),
                                                         startPage: expected.page).first?.source, expected.source)
        XCTAssertTrue(try file.markdownDocumentMatches("ABC833tail", options: .init(),
                                                       startPage: expected.page).isEmpty)
        let rtlAll = try file.markdownDocumentMatches(rtl, options: .init(), startPage: 0,
                                                       counting: true, maximum: 10)
        let rtlExpected = try XCTUnwrap(rtlAll.first { $0.page >= expected.page } ?? rtlAll.first)
        XCTAssertEqual(try file.markdownDocumentMatches(rtl, options: .init(),
                                                         startPage: expected.page).first?.source, rtlExpected.source)
    }

    func testCancelledForwardSuffixDoesNotReturnAResult() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let file = try open("Cancelled-suffix", html: String(repeating: "<p>padding paragraph</p>", count: 200) +
                            "<p>TAIL833</p>", in: temporary)
        XCTAssertGreaterThan(file.count, 1)
        typealias Cancelled = @convention(c) () -> Int32
        typealias Search = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Int32, Int32,
            UInt32, UInt32, UInt32, Int64, UnsafePointer<UInt8>?, Int, Cancelled,
            UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let symbol = try XCTUnwrap(dlsym(file.library, "lf_markdown_document_search"))
        let search = unsafeBitCast(symbol, to: Search.self)
        let cancelled: Cancelled = { 1 }
        var error = [CChar](repeating: 0, count: 512)
        let result = "TAIL833".withCString {
            search(file.document, $0, 0, Int32(file.count - 1), 0, 0, 0, 1, nil, 0, cancelled, &error)
        }
        defer { if let result { free(result) } }
        XCTAssertNil(result)
        XCTAssertTrue(String(cString: error).contains("Search cancelled"))
    }

    func testSourcePartsKeepPaintableGeometryAndCountHasOneThousandthSentinel() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let file = try open("Ligature", html: "<p>😀 ﬁ ﬂ ffi office affine</p>", in: temporary)
        let hits = try file.markdownDocumentMatches("fi", options: .init(), startPage: 0,
                                                    counting: true, maximum: 10)
        XCTAssertEqual(hits.count, 4)
        XCTAssertEqual(hits.first?.index, 3)
        XCTAssertTrue(hits.allSatisfy { $0.rects.contains { $0.width > 0 && $0.height > 0 } })
        let many = try open("Many-hits", html: "<p>" + String(repeating: "hit ", count: 1006) + "</p>", in: temporary)
        let requested = try many.markdownDocumentMatches("hit", options: .init(wholeWord: true),
                                                         startPage: 0, counting: true, maximum: 1005)
        XCTAssertEqual(requested.count, 1005)
        XCTAssertEqual(Set(requested.compactMap(\.source)).count, 1005)
        let counted = try many.markdownDocumentMatches("hit", options: .init(wholeWord: true),
                                                       startPage: 0, counting: true, maximum: 1000)
        XCTAssertEqual(counted.count, 1000)
        XCTAssertEqual(Set(counted.compactMap(\.source)).count, 1000)
    }

    func testInvisibleSourceIsExcludedAndVisibleChildOverrideStillFinds() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let hidden = try open("Hidden-only", html: "<p style=\"visibility:hidden\">SECRET796</p>",
                              in: temporary)
        XCTAssertFalse(try XCTUnwrap(hidden.text(0)).contains("SECRET796"))
        XCTAssertTrue(try hidden.markdownDocumentMatches("SECRET796", options: .init(), startPage: 0).isEmpty)

        let mixed = try open("Hidden-visible", html:
            "<p>BEFORE796 <span style=\"visibility:hidden\">SECRET796 " +
            "<span style=\"visibility:visible\">SHOW796</span> HIDDEN796</span> AFTER796</p>",
            in: temporary)
        let pageText = try XCTUnwrap(mixed.text(0))
        XCTAssertTrue(pageText.contains("SHOW796"))
        XCTAssertFalse(pageText.contains("SECRET796"))
        XCTAssertFalse(pageText.contains("HIDDEN796"))
        for query in ["SECRET796", "HIDDEN796", "SECRET796 SHOW796", "SHOW796 HIDDEN796"] {
            XCTAssertTrue(try mixed.markdownDocumentMatches(query, options: .init(), startPage: 0).isEmpty,
                          query)
        }
        let visible = try XCTUnwrap(mixed.markdownDocumentMatches("SHOW796", options: .init(),
                                                                   startPage: 0).first)
        XCTAssertTrue(visible.rects.contains { $0.width > 0 && $0.height > 0 })
        XCTAssertEqual(try mixed.markdownDocumentMatches("SHOW796", options: .init(), startPage: 0,
                                                         backwards: true).first?.source, visible.source)

        let inline = try open("Hidden-inline-gap", html:
            "<p>BEFORE796<span style=\"visibility:hidden\">SECRET796" +
            "<span style=\"visibility:visible\">SHOW796</span>HIDDEN796</span>AFTER796</p>",
            in: temporary)
        for joined in ["BEFORE796SHOW796", "SHOW796AFTER796", "BEFORE796SECRET796"] {
            XCTAssertTrue(try inline.markdownDocumentMatches(joined, options: .init(), startPage: 0).isEmpty,
                          joined)
        }
        let separated = try XCTUnwrap(inline.markdownDocumentMatches("BEFORE796 SHOW796", options: .init(),
                                                                      startPage: 0).first)
        XCTAssertTrue(separated.rects.contains { $0.width > 0 && $0.height > 0 })
        XCTAssertEqual(try inline.markdownDocumentMatches("SHOW796", options: .init(), startPage: 0).count, 1)
    }

    func testUnpaintedBreakAndWrappedSpaceCannotConsumeOneHitBudget() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let onlyBreak = try open("Break-only", html: "<p>before<br>after</p>", in: temporary)
        XCTAssertTrue(try onlyBreak.markdownDocumentMatches(" ", options: .init(), startPage: 0,
                                                            maximum: 1).isEmpty)
        let paragraph = try open("Paragraph-only", html: "<p>before</p><p>after</p>", in: temporary)
        XCTAssertTrue(try paragraph.markdownDocumentMatches(" ", options: .init(), startPage: 0,
                                                            maximum: 1).isEmpty)
        let laterPainted = try open("Break-then-space", html: "<p>before<br>after painted</p>",
                                    in: temporary)
        let space = try XCTUnwrap(laterPainted.markdownDocumentMatches(" ", options: .init(), startPage: 0,
                                                                        maximum: 1).first)
        XCTAssertTrue(space.rects.contains { $0.width > 0 && $0.height > 0 })

        let wrap = try open("Wrap-space", html: "<p style=\"width:85px\">ordinary boundary</p>",
                            in: temporary)
        XCTAssertTrue(try XCTUnwrap(wrap.text(0)).contains("\n"))
        XCTAssertTrue(try wrap.markdownDocumentMatches(" ", options: .init(), startPage: 0,
                                                       maximum: 1).isEmpty)
    }
}
#endif
