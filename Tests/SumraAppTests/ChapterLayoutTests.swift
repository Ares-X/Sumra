#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class ChapterLayoutTests: XCTestCase {
    func testJumpingToTheLastChapterKeepsTheMiddleChapterLazyAndPublicationPreservesContent() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(epub(in: directory.url), format: .mupdf, deferReflowLayout: true)
        let unopenedCount = await pages.count
        XCTAssertEqual(unopenedCount, 0)
        _ = try await layout(pages, size: 17)
        let first = await pages.chapterLayout
        XCTAssertEqual(first.chapterCount, 3)
        XCTAssertFalse(first.isLaidOut(0), "Applying initial CSS must not lay out the first chapter before restoring the saved chapter")
        XCTAssertFalse(first.isLaidOut(1))
        XCTAssertFalse(first.isLaidOut(2))

        let outline = try await pages.prepare().outline
        let target = try XCTUnwrap(outline.first { $0.title == "Gamma" }?.target)
        let resolved = try await pages.resolve(target)
        let location = try bookmark(try XCTUnwrap(resolved)).location
        XCTAssertEqual(location, PageLocation(chapter: 2, page: 0))
        let before = await pages.chapterLayout
        XCTAssertFalse(before.isLaidOut(0), "Opening a later chapter must not lay out the first chapter")
        XCTAssertFalse(before.isLaidOut(1), "A direct URI jump must not count the intervening chapter")
        XCTAssertTrue(before.isLaidOut(2))
        let position = try await pages.position(location, x: 4, y: 8)
        let text = try await pages.text(location), image = try await pages.image(location, width: 240)
        let bounds = try await pages.bounds(location)
        let range = (text as NSString).range(of: "GAMMA_START")
        XCTAssertNotEqual(range.location, NSNotFound)
        let selected = try await pages.selection(location, range: range)
        XCTAssertEqual(selected.text, "GAMMA_START")
        XCTAssertFalse(selected.rects.isEmpty)

        try await pages.warmChapter(1)
        let warmed = await pages.chapterLayout
        XCTAssertEqual(warmed, before, "Background counting must not republish changing flat page numbers")
        try await pages.publishWarmedChapters()
        let published = await pages.chapterLayout
        XCTAssertTrue(published.complete)
        XCTAssertGreaterThan(published.pageCount(1), 1)
        XCTAssertGreaterThan(try XCTUnwrap(published.page(for: location)), try XCTUnwrap(before.page(for: location)))
        let savedAfterPublication = await pages.layoutPosition
        XCTAssertEqual(savedAfterPublication.anchor, position.anchor)
        XCTAssertEqual(savedAfterPublication.page, published.page(for: location))
        let newPosition = try await pages.position(location, x: 4, y: 8)
        let newText = try await pages.text(location), newImage = try await pages.image(location, width: 240)
        let newBounds = try await pages.bounds(location), newSelection = try await pages.selection(location, range: range)
        XCTAssertEqual(newPosition.anchor, position.anchor)
        XCTAssertEqual(newPosition.x, position.x)
        XCTAssertEqual(newPosition.y, position.y)
        XCTAssertNotEqual(newPosition.page, position.page)
        XCTAssertEqual(newText, text)
        XCTAssertEqual(newBounds, bounds)
        XCTAssertEqual(newImage.width, image.width)
        XCTAssertEqual(newImage.height, image.height)
        XCTAssertEqual(try pixels(newImage), try pixels(image))
        XCTAssertEqual(newSelection.text, selected.text)
        XCTAssertEqual(newSelection.rects, selected.rects)
        let revisitedPosition = try await pages.resolve(target)
        let revisited = try XCTUnwrap(revisitedPosition)
        XCTAssertEqual(try bookmark(revisited).location, location)
        XCTAssertEqual(revisited.x, resolved?.x)
        XCTAssertEqual(revisited.y, resolved?.y)
        XCTAssertEqual(revisited.page, published.page(for: location))
    }

    func testPreviousAndLastUseTheRealChapterEnds() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(epub(in: directory.url), format: .mupdf, deferReflowLayout: true)
        _ = try await layout(pages, size: 17)
        let last = try await pages.lastPosition()
        let lastLocation = try bookmark(last).location, beforePrevious = await pages.chapterLayout
        XCTAssertFalse(beforePrevious.isLaidOut(1))
        XCTAssertEqual(lastLocation, PageLocation(chapter: 2, page: beforePrevious.pageCount(2) - 1))
        let lastText = try await pages.text(lastLocation)
        XCTAssertTrue(lastText.contains("GAMMA_END"))
        let previous = try await pages.advance(.init(chapter: 2, page: 0), by: -1)
        let previousLocation = try bookmark(previous).location, afterPrevious = await pages.chapterLayout
        XCTAssertTrue(afterPrevious.isLaidOut(1))
        XCTAssertGreaterThan(afterPrevious.pageCount(1), 1)
        XCTAssertEqual(previousLocation, PageLocation(chapter: 1, page: afterPrevious.pageCount(1) - 1))
        let previousText = try await pages.text(previousLocation)
        XCTAssertTrue(previousText.contains("BETA_END"))
        let forward = try await pages.advance(previousLocation, by: 1)
        XCTAssertEqual(try bookmark(forward).location, PageLocation(chapter: 2, page: 0))
        let endAgain = try await pages.advance(lastLocation, by: 1)
        XCTAssertEqual(try bookmark(endAgain).location, lastLocation)
        let speech = try await pages.readablePage(from: previousLocation, advance: true)
        XCTAssertEqual(try bookmark(try XCTUnwrap(speech?.position)).location, PageLocation(chapter: 2, page: 0))
        XCTAssertTrue(try XCTUnwrap(speech?.text).contains("GAMMA_START"))
        let afterEnd = try await pages.readablePage(from: lastLocation, advance: true)
        XCTAssertNil(afterEnd)
    }

    func testBookmarkRestoresChapterProgressAfterFontReflow() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(epub(in: directory.url), format: .mupdf, deferReflowLayout: true)
        _ = try await layout(pages, size: 13)
        let oldTable = try await pages.ensureFullLayout()
        XCTAssertGreaterThan(oldTable.pageCount(0), 2)
        let location = PageLocation(chapter: 0, page: oldTable.pageCount(0) / 2)
        let position = try await pages.position(location, x: 7, y: 11)
        let saved = try bookmark(position)
        _ = try await layout(pages, size: 30)
        let restored = try await pages.restore(position), newTable = await pages.chapterLayout
        XCTAssertGreaterThan(newTable.pageCount(0), oldTable.pageCount(0))
        let expectedPage = Int((Double(saved.location.page + 1) * Double(newTable.pageCount(0)) / Double(saved.count)).rounded()) - 1
        let actual = try bookmark(restored)
        XCTAssertEqual(actual.location, PageLocation(chapter: 0, page: expectedPage))
        XCTAssertEqual(actual.count, newTable.pageCount(0))
        XCTAssertEqual(restored.x, 7)
        XCTAssertEqual(restored.y, 11)
        let restoredText = try await pages.text(actual.location)
        XCTAssertTrue(restoredText.contains("ALPHA"))
    }

    @MainActor
    func testExportCountsEveryChapterAndKeepsDocumentAndSelectedPageOrder() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epub(in: directory.url), original = try Data(contentsOf: input)
        let eager = try NativeFile(input, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(eager.chapterTable).complete, "Non-reader callers must retain eager page counts")
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await layout(pages, size: 17)
        let before = await pages.chapterLayout
        XCTAssertFalse(before.complete)
        let output = directory.url.appendingPathComponent("all.pdf")
        try await pages.exportPDF(to: output)
        let table = await pages.chapterLayout, pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(table.complete)
        XCTAssertEqual(pdf.pageCount, table.totalPages)
        let markers = ["ALPHA", "BETA", "GAMMA"]
        for index in 0..<pdf.pageCount {
            let location = try XCTUnwrap(table.location(page: index))
            let text = try XCTUnwrap(pdf.page(at: index)?.string)
            XCTAssertTrue(text.contains(markers[location.chapter]), "Export page \(index) must belong to chapter \(location.chapter)")
        }
        let last = PageLocation(chapter: 2, page: table.pageCount(2) - 1)
        let selection = directory.url.appendingPathComponent("selected.pdf")
        try await pages.exportPDF(to: selection, locations: [last, .init(chapter: 0, page: 0), last])
        let selected = try XCTUnwrap(PDFDocument(url: selection))
        XCTAssertEqual(selected.pageCount, 3)
        XCTAssertTrue(try XCTUnwrap(selected.page(at: 0)?.string).contains("GAMMA_END"))
        XCTAssertTrue(try XCTUnwrap(selected.page(at: 1)?.string).contains("ALPHA_START"))
        XCTAssertEqual(selected.page(at: 2)?.string, selected.page(at: 0)?.string)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testPendingChapterJumpAndLegacyFlatPositionRestoreDifferentIntents() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epub(in: directory.url)
        let pending = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await layout(pending, size: 17)
        let first = await pending.chapterLayout
        let target = PageLocation(chapter: 2, page: 0)
        let restored = try await pending.restore(.init(page: first.totalPages - 1, anchor: first.bookmark(target)))
        XCTAssertEqual(try bookmark(restored).location, target)
        let afterJump = await pending.chapterLayout
        XCTAssertFalse(afterJump.isLaidOut(1))

        let legacy = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await layout(legacy, size: 17)
        _ = try await legacy.text(PageLocation(chapter: 0, page: 0))
        let before = await legacy.chapterLayout
        let oldFlat = before.pageCount(0) + 1
        let migrated = try await legacy.restore(.init(page: oldFlat))
        XCTAssertEqual(try bookmark(migrated).location, .init(chapter: 1, page: 1))
        let after = await legacy.chapterLayout
        XCTAssertTrue(after.isLaidOut(1))
        XCTAssertFalse(after.isLaidOut(2), "Legacy flat positions count only as far as required")
    }

    @MainActor
    func testPublishedChapterSnapshotsNeverRegressAndPreserveCurrentAnchor() {
        let state = ReaderState()
        var first = ChapterTable(chapters: 2)
        first.setPageCount(chapter: 1, count: 1)
        XCTAssertTrue(state.applyChapterLayout(first))
        state.updatePosition(.init(page: 1, x: 5, y: 9, anchor: "1:0:1"))
        var complete = first
        complete.setPageCount(chapter: 0, count: 1)
        XCTAssertEqual(complete.generation, first.generation)
        XCTAssertTrue(state.applyChapterLayout(complete))
        XCTAssertFalse(state.applyChapterLayout(first))
        XCTAssertEqual(state.chapterLayout, complete)
        var expanded = complete
        expanded.setPageCount(chapter: 0, count: 8)
        XCTAssertTrue(state.applyChapterLayout(expanded))
        XCTAssertEqual(state.page, 8)
        XCTAssertEqual(state.location.anchor, "1:0:1")
        XCTAssertEqual(state.location.x, 5)
        XCTAssertEqual(state.location.y, 9)
        XCTAssertFalse(state.applyChapterLayout(complete))
        XCTAssertEqual(state.count, 9)
        XCTAssertEqual(state.page, 8)
    }

    @MainActor
    func testResolvedContentsKeepsItsChapterTargetWhenEarlierPagesArePublished() {
        let state = ReaderState()
        var table = ChapterTable(chapters: 2)
        table.setPageCount(chapter: 1, count: 5)
        state.applyChapterLayout(table)
        state.outline = [
            .init(title: "Chapter", target: "chapter1.xhtml", chapter: 1),
            .init(title: "Later heading", target: "chapter1.xhtml#later", chapter: 1)
        ]
        let position = ReadingPosition(page: 4, anchor: "1:3:5")
        state.cacheContentsPosition(position, target: "chapter1.xhtml#later")
        state.updatePosition(position)
        XCTAssertEqual(state.currentContentsIndex, 1)
        table.setPageCount(chapter: 0, count: 8)
        state.applyChapterLayout(table)
        XCTAssertEqual(state.page, 11)
        XCTAssertEqual(state.outline[1].page, 11)
        XCTAssertEqual(state.currentContentsIndex, 1)
        XCTAssertNil(state.outline[0].page, "Unvisited fragment destinations must remain lazy")
        state.clearChapterContentsPages()
        XCTAssertTrue(state.outline.allSatisfy { $0.page == nil })
    }

    private func layout(_ pages: Pages, size: Double) async throws -> Int? {
        try await pages.relayout(fontSize: size, lineHeight: 1.4, margin: 24, font: "serif", theme: "light")
    }
    private func bookmark(_ position: ReadingPosition) throws -> (location: PageLocation, count: Int) {
        try XCTUnwrap(ChapterTable.bookmarkLocation(try XCTUnwrap(position.anchor)))
    }
    private func pixels(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }
    private func requireEngine() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine must be built before chapter integration tests") }
    }
    private func epub(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let chapters = [("ALPHA", 80), ("BETA", 45), ("GAMMA", 20)]
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='a' href='chapter0.xhtml' media-type='application/xhtml+xml'/><item id='b' href='chapter1.xhtml' media-type='application/xhtml+xml'/><item id='c' href='chapter2.xhtml' media-type='application/xhtml+xml'/><item id='ncx' href='toc.ncx' media-type='application/x-dtbncx+xml'/></manifest><spine toc='ncx'><itemref idref='a'/><itemref idref='b'/><itemref idref='c'/></spine></package>",
            "toc.ncx": "<ncx xmlns='http://www.daisy.org/z3986/2005/ncx/'><navMap><navPoint id='a'><navLabel><text>Alpha</text></navLabel><content src='chapter0.xhtml#start'/></navPoint><navPoint id='b'><navLabel><text>Beta</text></navLabel><content src='chapter1.xhtml#start'/></navPoint><navPoint id='c'><navLabel><text>Gamma</text></navLabel><content src='chapter2.xhtml#start'/></navPoint></navMap></ncx>"
        ]
        for (index, chapter) in chapters.enumerated() {
            let body = (0..<chapter.1).map { "<p>\(chapter.0) paragraph \($0). A small fixture makes chapter layout observable.</p>" }.joined()
            files["chapter\(index).xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1 id='start'>\(chapter.0)_START</h1>\(body)<p>\(chapter.0)_END</p></body></html>"
        }
        for (name, text) in files { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("book.epub")
    }
}
#endif
