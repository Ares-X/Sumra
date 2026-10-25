#if os(macOS)
import AppKit
import Combine
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderInitialLayoutTests: XCTestCase {
    func testUnresolvedChapterTargetStartsInNaturalGeometry() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='a' href='first.xhtml' media-type='application/xhtml+xml'/><item id='b' href='target.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>"
        ]
        for (name, heading) in [("first.xhtml", "FIRST"), ("target.xhtml", "TARGET_START")] {
            let body = (0..<80).map { "<p>\(heading) paragraph \($0). This chapter target has never been paginated.</p>" }.joined()
            files[name] = "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>\(heading)</h1>\(body)</body></html>"
        }
        for (name, text) in files { try text.write(to: directory.url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory.url
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        let input = directory.url.appendingPathComponent("book.epub")
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        let target = PageLocation(chapter: 1, page: 0)
        let bookmark = ChapterTable(chapters: 2).bookmark(target)
        XCTAssertEqual(try XCTUnwrap(ChapterTable.bookmarkLocation(bookmark)).count, 0)
        state.apply(.init(page: 1, anchor: bookmark))
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.flow = "continuous"; state.spread = false; state.fit = "width"
        state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.4; state.margin = 32
        state.theme = "light"; state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.scrollbarMode = "smart"; state.automaticLayout = false; state.zoom = 1
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false; state.landscapeAsSpread = false
        state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
        var publications = [(position: ReadingPosition, layout: ChapterTable?)]()
        let publication = state.$renderRevision.sink { revision in
            if revision > 0 { publications.append((state.currentPosition, state.chapterLayout)) }
        }
        defer { publication.cancel() }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
            if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: target) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTAssertNil(state.error)
        XCTAssertTrue(RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: target))
        let first = try XCTUnwrap(publications.first)
        let restored = try XCTUnwrap(first.position.anchor.flatMap(ChapterTable.bookmarkLocation))
        XCTAssertEqual(restored.location, target)
        XCTAssertEqual(try XCTUnwrap(first.layout).pageCount(target.chapter), 1)
        XCTAssertEqual(first.position.nativePassage?.chapter, target.chapter)
        let clip = try XCTUnwrap(state.readerScrollView?.contentView.safeAreaRect.size)
        let bounds = try await pages.bounds(target)
        XCTAssertEqual(bounds.width, RasterReader.pageSize(in: clip, spread: false, continuous: true).width, accuracy: 0.01)
        XCTAssertGreaterThan(bounds.height, clip.height)
        let reference = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await reference.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight, margin: state.margin,
            font: state.font, theme: state.resolvedTheme, userCSS: state.effectiveUserCSS,
            pageSize: RasterReader.pageSize(in: clip, spread: false, continuous: true), viewport: clip)
        let expected = try await reference.position(target, viewport: clip)
        XCTAssertEqual(first.position.nativePassage?.source, expected.nativePassage?.source)
        XCTAssertNotNil(expected.nativePassage)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(publications.count, 1)
        let revision = await pages.layoutRevision
        XCTAssertEqual(revision, 1, "An unresolved target has no finite geometry to recover before natural layout")
    }

    func testLegacyFiniteBookmarkPublishesNaturalGeometryAndItsSavedSource() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("LegacyViewport.html")
        try ("<html><body>" + (0..<160).map {
            "<p>Paragraph \($0): The saved finite page must reopen at the same source in the first continuous canvas.</p>"
        }.joined() + "</body></html>")
            .write(to: input, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        state.flow = "continuous"; state.spread = false; state.fit = "width"
        state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.4; state.margin = 32
        state.theme = "light"; state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.scrollbarMode = "smart"; state.automaticLayout = false; state.zoom = 1
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false; state.landscapeAsSpread = false
        state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
        let reference = try Pages(input, format: .html, deferReflowLayout: true)
        _ = try await reference.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
            margin: state.margin, font: state.font, theme: state.resolvedTheme, userCSS: state.effectiveUserCSS)
        let finiteCount = await reference.count
        XCTAssertGreaterThan(finiteCount, 1)
        let finitePage = finiteCount / 2
        let finiteWords = try await reference.words(finitePage)
        let glyph = try XCTUnwrap(finiteWords.first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
        let saved = try await reference.position(page: finitePage, x: Double(glyph.bounds.minX), y: Double(glyph.bounds.minY))
        let savedSource = try XCTUnwrap(saved.nativePassage).source
        var legacy = saved; legacy.nativePassage = nil
        legacy = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(legacy.nativePassage)
        XCTAssertGreaterThan(try XCTUnwrap(legacy.anchor.flatMap(ChapterTable.bookmarkLocation)).count, 1)
        state.apply(legacy)
        let pages = try Pages(input, format: .html, deferReflowLayout: true)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        var publications = [(position: ReadingPosition, layout: ChapterTable?)]()
        let publication = state.$renderRevision.sink { revision in
            if revision > 0 { publications.append((state.currentPosition, state.chapterLayout)) }
        }
        defer { publication.cancel() }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(5)
        var visible: CGRect?
        repeat {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) {
                visible = RasterReader.visiblePageBounds(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
                if visible != nil { break }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTAssertNil(state.error)
        let first = try XCTUnwrap(publications.first)
        XCTAssertEqual(try XCTUnwrap(first.layout).pageCount(0), 1, "The first published canvas must already use natural chapter geometry")
        XCTAssertEqual(first.position.nativePassage?.source, savedSource, "Legacy geometry must resolve the exact saved source before natural reflow")
        let clip = try XCTUnwrap(state.readerScrollView?.contentView.safeAreaRect.size)
        let pageSize = RasterReader.pageSize(in: clip, spread: false, continuous: true)
        _ = try await reference.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
            margin: state.margin, font: state.font, theme: state.resolvedTheme, userCSS: state.effectiveUserCSS,
            pageSize: pageSize, readingPosition: saved, viewport: clip)
        let expected = await reference.layoutPosition
        XCTAssertEqual(try XCTUnwrap(first.position.y), try XCTUnwrap(expected.y), accuracy: 1, "The first publication must use the source-resolved natural coordinate")
        let bounds = try await pages.bounds(state.page)
        XCTAssertEqual(bounds.width, pageSize.width, accuracy: 0.01)
        XCTAssertGreaterThan(bounds.height, clip.height)
        XCTAssertEqual(try XCTUnwrap(visible).minY, try XCTUnwrap(expected.y), accuracy: 1, "The first rendered viewport must use the source-resolved natural coordinate")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(publications.count, 1, "Mounting must not publish a second layout to replace finite geometry")
        let revision = await pages.layoutRevision
        XCTAssertEqual(revision, 2, "Legacy source mapping needs one finite layout and one final viewport layout")
    }

    func testInitialViewportUsesTheMountedWindowLayout() async throws {
        _ = NSApplication.shared
        var measurements = [CGSize]()
        let host = NSHostingView(rootView: ReaderInitialViewport { measurements.append($0) })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        window.setContentSize(CGSize(width: 800, height: 600))
        window.orderFront(nil)

        let deadline = Date().addingTimeInterval(5)
        while measurements.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(measurements, [CGSize(width: 800, height: 600)])
        window.setContentSize(CGSize(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(measurements.count, 1, "Later resizing belongs to the mounted raster reader")
    }

    func testMarkdownUsesItsReadingModeViewportForItsFirstLayout() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("FirstViewport.md")
        try String(repeating: "Text remains continuous through the whole book.\n\n", count: 160)
            .write(to: input, atomically: true, encoding: .utf8)

        for toolbarMode in ReaderToolbarDisplayMode.allCases {
        for (flow, spread) in [("continuous", false), ("paged", false), ("paged", true)] {
        for mode in ["smart", "shown", "hidden"] {
            let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
            let state = ReaderState(recordsHistory: false)
            state.toolbarDisplayMode = toolbarMode
            state.document = ReadingDocument(url: input, content: .pages(pages))
            state.flow = flow; state.spread = spread; state.fit = "width"
            state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.4
            state.theme = "light"; state.userCSS = ""; state.pageMargins = nil
            state.scrollbarMode = mode; state.automaticLayout = false
            state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
            var publications = [ReadingPosition]()
            var publishedBounds: Task<CGRect, Error>?
            let publication = state.$renderRevision.sink { revision in
                if revision > 0 {
                    publications.append(state.currentPosition)
                    if publishedBounds == nil { publishedBounds = Task { try await pages.bounds(0) } }
                }
            }
            defer { publication.cancel() }
            let host = NSHostingView(rootView: ReaderView(state: state))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            let initialViewport = ReaderScrollbars.initialReadingViewport(in: host.bounds.size,
                mode: mode, continuous: flow == "continuous")
            let initialPageSize = RasterReader.pageSize(in: initialViewport,
                spread: spread, continuous: flow == "continuous")
            defer { state.windowClosed(); window.contentView = nil; window.close() }

            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertNil(state.error)
            XCTAssertTrue(RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)))
            // Allow mounted-scroll-view callbacks to deliver any width change.
            try await Task.sleep(nanoseconds: 100_000_000)
            let revision = await pages.layoutRevision
            let bounds = try await pages.bounds(0)
            let clip = try XCTUnwrap(state.readerScrollView?.contentView.safeAreaRect.size)
            let expected = RasterReader.pageSize(in: clip, spread: spread, continuous: flow == "continuous")
            if flow == "continuous", mode == "shown" {
                // A width-fitted natural chapter needs only the vertical bar.
                // A horizontal bar steals reading height and feeds a different
                // clip size back into its already fitted canvas.
                XCTAssertEqual(clip.height, host.bounds.height, accuracy: 0.01)
                let scroll = try XCTUnwrap(state.readerScrollView)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertLessThanOrEqual(document.frame.width, clip.width + 0.01)
                XCTAssertFalse(scroll.hasHorizontalScroller)
            }
            XCTAssertEqual(bounds.width, expected.width, accuracy: 0.01, "\(toolbarMode) \(flow) \(spread) \(mode)")
            XCTAssertEqual(revision, initialPageSize == expected ? 1 : 2, "\(toolbarMode) \(flow) \(spread) \(mode) may relayout only for an actual viewport change")
            XCTAssertEqual(publications.count, 1, "\(toolbarMode): The mounted reader must receive its final geometry in the first publication")
            let first = try XCTUnwrap(publications.first)
            XCTAssertNotNil(first.nativePassage)
            XCTAssertEqual(first.nativePassage?.source, state.currentPosition.nativePassage?.source)
            let firstBounds = try await XCTUnwrap(publishedBounds).value
            XCTAssertEqual(firstBounds.width, expected.width, accuracy: 0.01)
            if flow == "continuous" { XCTAssertGreaterThan(bounds.height, clip.height) }
            else {
                XCTAssertEqual(bounds.height, expected.height, accuracy: 0.01)
                XCTAssertEqual(firstBounds.height, expected.height, accuracy: 0.01)
            }
        }
        }
        }
    }
}
#endif
