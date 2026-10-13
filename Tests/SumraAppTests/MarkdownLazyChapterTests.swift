#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class MarkdownLazyChapterTests: XCTestCase {
    private func open(_ text: String, in directory: TemporaryDirectory) throws -> NativeFile {
        let input = directory.url.appendingPathComponent("Lazy.md")
        try text.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true, deferMarkdownMetadata: true)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 620, height: 0))
        return file
    }

    func testRecoveredHTMLSectionsKeepRawSpansAndTOCDoesNotWarmUnseenChapters() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try open("""
        # Opening **heading**

        Before <i>Italic begins

        and continues after the paragraph</i> without losing the ending.

        <table><tr><td>raw cell <b>bold</b></td></tr></table>

        ## Later section

        Final marker LAST77 remains visible.

        <div><h2 id="nested">Nested raw heading</h2><p>Nested content stays in its block.</p></div>

        ## Last section

        Last visible text.
        """, in: directory)
        XCTAssertEqual(file.chapterTable?.chapterCount, 3)
        XCTAssertEqual(file.chapterTable?.complete, false)
        let outline = try file.outline()
        XCTAssertEqual(outline.map(\.title), ["Opening heading", "Later section", "Nested raw heading", "Last section"])
        XCTAssertEqual(outline.map(\.chapter), [0, 1, 1, 2])
        XCTAssertEqual(file.chapterTable?.isLaidOut(1), false)
        XCTAssertEqual(file.chapterTable?.isLaidOut(2), false)
        let first = try XCTUnwrap(file.text(0))
        XCTAssertTrue(first.contains("Italic begins"))
        XCTAssertTrue(first.contains("continues after the paragraph"))
        XCTAssertTrue(first.contains("raw cell bold"))
        XCTAssertEqual(file.chapterTable?.isLaidOut(0), true)
        XCTAssertEqual(file.chapterTable?.isLaidOut(1), false)
        let destination = try XCTUnwrap(file.resolve("#later-section"))
        XCTAssertEqual(try file.location(destination.page).chapter, 1)
        XCTAssertTrue(try XCTUnwrap(file.text(destination.page)).contains("LAST77"))
        XCTAssertEqual(file.chapterTable?.isLaidOut(2), false)
    }

    func testSearchAndCopyKeepChapterIdentityAcrossTheHeadingBoundary() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try open("# First\n\nmarker boundaryword\n\n## Second\n\nmarker ending\n", in: directory)
        let crossing = try XCTUnwrap(file.markdownDocumentMatches("boundaryword Second", options: .init(), startPage: 0).first)
        XCTAssertEqual(crossing.fragments?.compactMap { $0.location?.chapter }, [0, 1])
        let matches = try file.markdownDocumentMatches("marker", options: .init(), startPage: 0, counting: true, maximum: 10)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.compactMap { $0.source?.chapter }, [0, 1])
        XCTAssertEqual(try file.markdownDocumentMatches("marker", options: .init(), startPage: matches[0].page,
                                                       after: matches[0].source).first?.source, matches[1].source)
        let first = try XCTUnwrap(crossing.source)
        let words = try (0..<file.count).flatMap { try file.words($0) }
        let ending = try XCTUnwrap(words.last { $0.source?.chapter == 1 && $0.source?.node == 1 }?.source)
        let characters: [(NativeSourceAnchor, UInt32)] = words.compactMap { word in
            guard let source = word.source, source >= first, source <= ending,
                  let scalar = word.text.unicodeScalars.first else { return nil }
            return (source, scalar.value)
        }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(try file.sourceSelectionText(characters), "boundaryword\nSecond")
    }

    func testLegacyWholeDocumentOrdinalRestoresTheSameGlyphAfterReflow() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try open("# First\n\nalpha\n\n## Second\n\nbeta\n", in: directory)
        let beta = try XCTUnwrap(file.words(1).first { $0.text == "b" })
        let current = try XCTUnwrap(file.passage(1, at: CGPoint(x: beta.bounds.minX + 0.1, y: beta.bounds.minY + 0.1)))
        XCTAssertEqual(current.source.chapter, 1)
        XCTAssertEqual(current.source.node, 2)
        // The old complete tree assigns First=1, alpha=2, Second=3, beta=4.
        let legacy = NativePassage(source: .init(node: 4, offset: current.source.offset, part: current.source.part),
            offsetX: current.offsetX, offsetY: current.offsetY, sourceRevision: current.sourceRevision,
            styleSignature: current.styleSignature, chapter: 0)
        _ = try file.relayout(fontSize: 28, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 480, height: 400))
        let restored = try XCTUnwrap(file.position(for: legacy))
        let expected = try XCTUnwrap(file.position(for: current))
        XCTAssertEqual(restored.page, expected.page)
        XCTAssertEqual(restored.x, expected.x)
        XCTAssertEqual(restored.y, expected.y)
        XCTAssertEqual(restored.nativePassage?.source, current.source)
        XCTAssertEqual(restored.nativePassage?.chapter, 1)
    }

    func testSelectionAcrossThreeChaptersCopiesEveryAuthoredParagraph() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Selection.md")
        try "# First\n\nalpha\n\n## Second\n\nbeta\n\n## Third\n\ngamma\n"
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                    pageSize: CGSize(width: 620, height: 0))
        let firstWords = try await pages.words(PageLocation(chapter: 0, page: 0))
        let lastWords = try await pages.words(PageLocation(chapter: 2, page: 0))
        let first = try XCTUnwrap(firstWords.first { $0.source != nil }?.source)
        let last = try XCTUnwrap(lastWords.last { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) }?.source)
        let selected = try await pages.selection(from: first, to: last)
        XCTAssertEqual(Set(selected.keys.map(\.chapter)), [0, 1, 2])
        let copied = try await pages.markdownCopyText(selected)
        XCTAssertEqual(copied?.trimmingCharacters(in: .whitespacesAndNewlines), "First\nalpha\nSecond\nbeta\nThird\ngamma")
    }

    func testFacingRowUsesThePredecessorsFinalPageAndKeepsTheSelectedSourceAcrossReflow() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Facing.md")
        let body = "# Previous\n\n" + String(repeating: "Previous body remains in document order.\n\n", count: 100)
            + "PREVIOUS_TAIL\n\n## Current\n\nCURRENT_BODY\n\n"
            + String(repeating: "Current body spans several pages.\n\n", count: 40)
            + "## Unseen\n\nUnseen body.\n"
        try body.write(to: input, atomically: true, encoding: .utf8)
        var crossedBackward = false
        for cover in [false, true] {
            let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                        pageSize: CGSize(width: 420, height: 400))
            let target = PageLocation(chapter: 1, page: 0)
            let selected = try await pages.position(target)
            let source = try XCTUnwrap(selected.nativePassage)
            let provisional = await pages.chapterLayout
            XCTAssertFalse(provisional.isLaidOut(0))
            XCTAssertEqual(provisional.pageCount(0), 1)

            let prepared = try await pages.prepareFacingPages(selected, cover: cover)
            let table = await pages.chapterLayout
            XCTAssertGreaterThan(table.pageCount(0), 2)
            XCTAssertTrue(table.isLaidOut(0))
            XCTAssertFalse(table.isLaidOut(2), "Preparing a row must keep distant chapters lazy")
            XCTAssertEqual(ChapterTable.bookmarkLocation(try XCTUnwrap(prepared.anchor))?.location, target)
            XCTAssertEqual(prepared.nativePassage, selected.nativePassage)
            let row = PageRows.range(page: prepared.page, count: table.totalPages, spread: true, cover: cover)
            let locations = try row.map { try XCTUnwrap(table.location(page: $0)) }
            XCTAssertTrue(locations.contains(target))
            if locations.first?.chapter == 0 {
                crossedBackward = true
                let last = PageLocation(chapter: 0, page: table.pageCount(0) - 1)
                XCTAssertEqual(locations, [last, target])
                let tail = try await pages.text(last)
                XCTAssertTrue(tail.contains("PREVIOUS_TAIL"))
                XCTAssertFalse(tail.contains("Previous\n"))
            }
            // Debounced capture can still hold the old flat page after the
            // predecessor publishes its count. The chapter anchor owns it.
            let captured = try await pages.capturePassage(selected, theme: "light", userCSS: "")
            XCTAssertEqual(captured?.source, source.source)
            XCTAssertEqual(captured?.chapter, 1)
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                        pageSize: CGSize(width: 840, height: 0), readingPosition: prepared)
            let continuous = await pages.layoutPosition
            XCTAssertEqual(continuous.nativePassage?.source, source.source)
            XCTAssertEqual(continuous.nativePassage?.chapter, 1)
        }
        XCTAssertTrue(crossedBackward, "One cover alignment must show the cross-chapter row")
    }
}
#endif
