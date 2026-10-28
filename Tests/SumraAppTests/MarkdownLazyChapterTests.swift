#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class MarkdownLazyChapterTests: XCTestCase {
    private func open(_ text: String, in directory: TemporaryDirectory, name: String = "Lazy.md") throws -> NativeFile {
        let input = directory.url.appendingPathComponent(name)
        try text.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true, deferMarkdownMetadata: true)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 620, height: 0))
        return file
    }

    func testLeadingHeadingRunsStayWithTheirFirstBodyWithoutWarmingLaterSections() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try open("# Collection\n\n### Banner\n\n## First\n\nalpha\n\n## Second\n\n### Part\n\n## Third\n\nbeta\n\n## Last\n\ngamma\n", in: directory)
        XCTAssertEqual(file.chapterTable?.chapterCount, 3)
        let first = try XCTUnwrap(file.text(0))
        XCTAssertTrue(first.contains("Collection"))
        XCTAssertTrue(first.contains("Banner"))
        XCTAssertTrue(first.contains("First"))
        XCTAssertTrue(first.contains("alpha"))
        XCTAssertFalse(first.contains("beta"))
        XCTAssertEqual(file.chapterTable?.isLaidOut(1), false)
        let outline = try file.outline()
        XCTAssertEqual(outline.map(\.title), ["Collection", "Banner", "First", "Second", "Part", "Third", "Last"])
        XCTAssertEqual(outline.map(\.chapter), [0, 0, 0, 1, 1, 1, 2])
        XCTAssertEqual(file.chapterTable?.isLaidOut(2), false)
        let second = try XCTUnwrap(file.resolve("#third"))
        XCTAssertEqual(try file.location(second.page).chapter, 1)
        XCTAssertTrue(try XCTUnwrap(file.text(second.page)).contains("beta"))
        let matches = try file.markdownDocumentMatches("alpha Second", options: .init(), startPage: 0)
        XCTAssertEqual(matches.first?.fragments?.compactMap { $0.location?.chapter }, [0, 1])
        let all = try (0..<file.count).map { try file.text($0) ?? "" }.joined(separator: "\n")
        for marker in ["Collection", "Banner", "First", "alpha", "Second", "Part", "Third", "beta", "Last", "gamma"] {
            XCTAssertEqual(all.components(separatedBy: marker).count - 1, 1, marker)
        }
    }

    func testShippedSectionPassageFixturesMigrateExactGlyphsAndRemainStableThroughReflow() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let text = "# Collection\n\n### Banner\n\n## First\n\nalpha\n\n## Second\n\n### Part\n\n## Third\n\nbeta\n\n## Last\n\ngamma\n"
        let file = try open(text, in: directory)
        // Captured from the shipped 0.2.21 engine before changing its section
        // index: chapter/local flow node/word. Include removed and shifted sections.
        let fixtures = [(0, 1, "Collection"), (0, 2, "Banner"), (1, 1, "First"), (1, 2, "alpha"),
                        (2, 1, "Second"), (2, 2, "Part"), (3, 1, "Third"), (3, 2, "beta"), (4, 2, "gamma")]
        var restoredPassages = [NativePassage]()
        for (oldChapter, oldNode, word) in fixtures {
            let hit = try XCTUnwrap(file.markdownDocumentMatches(word, options: .init(), startPage: 0).first, word)
            let source = try XCTUnwrap(hit.source, word)
            let target = try XCTUnwrap(file.position(for: source), word)
            let current = try XCTUnwrap(target.nativePassage, word)
            let json: [String: Any] = ["source": [oldNode, 0, 0, oldChapter], "offsetX": 3.25, "offsetY": 4.5,
                "sourceRevision": current.sourceRevision, "styleSignature": current.styleSignature, "chapter": oldChapter]
            let old = try JSONDecoder().decode(NativePassage.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(old.markdownSections)
            let restored = try XCTUnwrap(file.position(for: old), word)
            XCTAssertEqual(restored.nativePassage?.source, source, word)
            XCTAssertEqual(restored.nativePassage?.markdownSections, 2, word)
            XCTAssertEqual(try XCTUnwrap(restored.x), try XCTUnwrap(target.x) + 3.25, accuracy: 0.001, word)
            XCTAssertEqual(try XCTUnwrap(restored.y), try XCTUnwrap(target.y) + 4.5, accuracy: 0.001, word)
            restoredPassages.append(try XCTUnwrap(restored.nativePassage))
        }
        _ = try file.relayout(fontSize: 28, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 420, height: 360))
        for current in restoredPassages {
            let reopened = try JSONDecoder().decode(NativePassage.self, from: JSONEncoder().encode(current))
            let restored = try XCTUnwrap(file.position(for: reopened))
            XCTAssertEqual(restored.nativePassage?.source, current.source)
            XCTAssertEqual(restored.nativePassage?.offsetX, current.offsetX)
            XCTAssertEqual(restored.nativePassage?.offsetY, current.offsetY)
        }
        XCTAssertEqual(try String(contentsOf: directory.url.appendingPathComponent("Lazy.md"), encoding: .utf8), text)
    }

    func testLegacyPageBookmarkKeepsItsPixelOffsetInsideTheMergedChapterAndPreferences() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try open("# Collection\n\n## First\n\nalpha\n\n## Last\n\ngamma\n", in: directory)
        let oldSection = try open("## First\n\nalpha\n", in: directory, name: "OldSection.md")
        let oldHeading = try XCTUnwrap(oldSection.position(for: .init(node: 1, offset: 0, part: 0, chapter: 0)))
        let heading = try XCTUnwrap(file.markdownDocumentMatches("First", options: .init(), startPage: 0).first?.source)
        let expected = try XCTUnwrap(file.position(for: heading))
        var old = ReadingPosition(page: 1, x: oldHeading.x, y: try XCTUnwrap(oldHeading.y) + 7, anchor: "1:0:1")
        old.fontSize = 19; old.lineHeight = 1.7; old.zoom = 1.2; old.flow = "continuous"; old.scrollFraction = 0.35
        let restored = try file.migratedMarkdownPosition(old)
        XCTAssertEqual(try file.location(restored.page).chapter, 0)
        XCTAssertEqual(try XCTUnwrap(restored.y), try XCTUnwrap(expected.y) + 7, accuracy: 0.01)
        XCTAssertNotEqual(restored.y, old.y)
        XCTAssertEqual(restored.nativePassage?.source, heading)
        XCTAssertEqual(restored.fontSize, old.fontSize); XCTAssertEqual(restored.lineHeight, old.lineHeight)
        XCTAssertEqual(restored.zoom, old.zoom); XCTAssertEqual(restored.flow, old.flow)
        XCTAssertEqual(restored.scrollFraction, old.scrollFraction)
        XCTAssertTrue(try XCTUnwrap(restored.anchor).hasPrefix("md2:"))
        XCTAssertEqual(try file.migratedMarkdownPosition(restored), restored)
        let last = try file.migratedMarkdownPosition(ReadingPosition(page: 2, anchor: "2:0:1"))
        XCTAssertEqual(try file.location(last.page).chapter, 1)
        XCTAssertTrue(try XCTUnwrap(file.text(last.page)).contains("gamma"))
    }

    func testMultiPageLegacyBookmarkRestoresTheSameBodyGlyphThroughViewportReflow() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let section = "## First\n\n" + (0..<80).map { "Paragraph\($0) carries authored body words across several finite pages.\n\n" }.joined()
        let file = try open("# Collection\n\n" + section + "## Last\n\ngamma\n", in: directory)
        let oldSection = try open(section, in: directory, name: "OldSection.md")
        for document in [file, oldSection] {
            _ = try document.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                                      pageSize: CGSize(width: 420, height: 360))
        }
        let oldCount = oldSection.count
        XCTAssertGreaterThan(oldCount, 4)
        let oldPage = 3
        let glyph = try XCTUnwrap(oldSection.words(oldPage).first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
        let source = try XCTUnwrap(glyph.source)
        // The merged prefix contributes Collection's single flow node.
        let expectedSource = NativeSourceAnchor(node: source.node + 1, offset: source.offset, part: source.part, chapter: 0)
        let expected = try XCTUnwrap(file.position(for: expectedSource))
        let legacy = ReadingPosition(page: oldPage + 1, x: Double(glyph.bounds.minX), y: Double(glyph.bounds.minY) + 2,
                                     anchor: "1:\(oldPage):\(oldCount)")
        let restored = try file.migratedMarkdownPosition(legacy)
        XCTAssertEqual(restored.nativePassage?.source, expectedSource)
        XCTAssertEqual(try XCTUnwrap(restored.y), try XCTUnwrap(expected.y) + 2, accuracy: 0.01)
        let passage = try XCTUnwrap(restored.nativePassage)
        _ = try file.relayout(fontSize: 24, lineHeight: 1.8, font: "system", theme: "light",
                              pageSize: CGSize(width: 700, height: 0))
        let reflowed = try XCTUnwrap(file.position(for: passage))
        XCTAssertEqual(reflowed.nativePassage?.source, expectedSource)
        XCTAssertEqual(reflowed.nativePassage?.offsetY, passage.offsetY)
        let around = try XCTUnwrap(file.text(reflowed.page))
        XCTAssertTrue(around.contains("Paragraph"))
    }

    func testSingleMergedChapterRestoresShippedAnchorsAndHonorsExplicitPageBreaks() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try open("# Collection\n\n## First\n\nalpha\n", in: directory)
        XCTAssertEqual(file.chapterTable?.chapterCount, 1)
        XCTAssertTrue(try XCTUnwrap(file.text(0)).contains("alpha"))
        let hit = try XCTUnwrap(file.markdownDocumentMatches("alpha", options: .init(), startPage: 0).first?.source)
        let current = try XCTUnwrap(file.position(for: hit)?.nativePassage)
        let old = NativePassage(source: .init(node: 2, offset: 0, part: 0, chapter: 1), offsetX: 0, offsetY: 0,
            sourceRevision: current.sourceRevision, styleSignature: current.styleSignature, chapter: 1)
        XCTAssertEqual(try file.position(for: old)?.nativePassage?.source, hit)
        XCTAssertEqual(try file.location(try file.migratedMarkdownPosition(.init(anchor: "1:0:1")).page).chapter, 0)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                              userCSS: "h2{page-break-before:always;}", pageSize: CGSize(width: 620, height: 500))
        XCTAssertGreaterThan(file.count, 1)
        XCTAssertFalse(try XCTUnwrap(file.text(0)).contains("alpha"))
        XCTAssertTrue(try (1..<file.count).map { try file.text($0) ?? "" }.joined().contains("alpha"))
    }

    func testPagesRestoresLegacyPassagesBookmarksAndFacingTargetsBeforeIndexingCurrentChapters() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Restore.md")
        try "# Collection\n\n## First\n\nalpha\n\n## Last\n\ngamma\n".write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                    pageSize: CGSize(width: 620, height: 0))
        let old = ReadingPosition(page: 2, anchor: "2:0:1")
        let captured = try await pages.capturePassage(old, theme: "light", userCSS: "")
        XCTAssertEqual(captured?.source.chapter, 1)
        XCTAssertEqual(captured?.markdownSections, 2)
        let restored = try await pages.restore(old)
        XCTAssertEqual(captured?.source, restored.nativePassage?.source)
        XCTAssertEqual(ChapterTable.bookmarkLocation(try XCTUnwrap(restored.anchor))?.location.chapter, 1)
        XCTAssertEqual(restored.nativePassage?.markdownSections, 2)
        let facing = try await pages.prepareFacingPages(old, cover: false)
        XCTAssertEqual(ChapterTable.bookmarkLocation(try XCTUnwrap(facing.anchor))?.location.chapter, 1)
        _ = try await pages.relayout(fontSize: 23, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                    pageSize: CGSize(width: 420, height: 360), readingPosition: old)
        let reflowed = await pages.layoutPosition
        XCTAssertEqual(reflowed.nativePassage?.source.chapter, 1)
        let text = try await pages.text(PageLocation(chapter: 1, page: 0))
        XCTAssertTrue(text.contains("gamma"))
    }

    @MainActor
    func testVersionedMarkdownBookmarksKeepTheCurrentPageLabelAndUserChapterInput() async throws {
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        state.reflowable = true
        var table = ChapterTable(chapters: 3, bookmarkScheme: "md2")
        table.setPageCount(chapter: 1, count: 4)
        _ = state.applyChapterLayout(table)
        state.updatePosition(.init(page: 2, anchor: "md2:1:1:4"))
        XCTAssertEqual(state.pageLabel, "2:2")
        XCTAssertEqual(ReaderState.chapterInput("md2:1:1", offset: 1), "2:2")
        XCTAssertEqual(ReaderState.chapterInput("1:1:4", offset: 1), "2:2")
        XCTAssertEqual(ReaderState.chapterInput("2:2", offset: -1), "1:1")
        XCTAssertNil(ReaderState.chapterInput("md2:2:2", offset: -1))
        XCTAssertNil(ReaderState.chapterInput("0:2", offset: -1))
        XCTAssertNil(ReaderState.chapterInput("2147483648:2", offset: -1))
        state.go("2:2")
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(state.command.action, .location("2:2"))
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
