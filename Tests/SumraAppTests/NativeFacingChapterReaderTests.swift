#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeFacingChapterReaderTests: XCTestCase {
    func testFacingChapterReaderSettlesAndKeepsSourceAcrossModes() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("FacingReader.md")
        let body = "# Previous\n\n" + String(repeating: "Previous paragraph stays before the selected chapter.\n\n", count: 100)
            + "PREVIOUS_TAIL\n\n## Current\n\nCURRENT_BODY\n\n"
            + String(repeating: "Current paragraph stays in the selected chapter.\n\n", count: 100)
            + "## Next\n\n" + String(repeating: "Skipped paragraph precedes the linked chapter.\n\n", count: 100)
            + "NEXT_TAIL\n\n## Distant\n\n" + String(repeating: "Distant body follows the skipped chapter.\n\n", count: 40)
            + "## Unseen\n\nUnseen body.\n"
        try body.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.reflowable = false; state.searchable = false; state.automaticLayout = false
        state.flow = "paged"; state.spread = true; state.cover = false; state.fit = "width"; state.zoom = 1
        state.fontSize = 17; state.lineHeight = 1.6; state.font = "system"; state.theme = "light"
        state.margin = 32; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "smart"
        state.updatePosition(.init(anchor: "1:0"))
        let preferences = ["flow", "spread"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1728, height: 984),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            for (key, value) in preferences { UserDefaults.standard.set(value, forKey: key) }
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func painted(_ location: PageLocation, in view: NSView) -> Bool {
            RasterReader.pageIsRendered(in: view, pages: pages, location: location) || view.subviews.contains { painted(location, in: $0) }
        }
        func canvas(_ location: PageLocation, in view: NSView) -> NSView? {
            if Mirror(reflecting: view).children.first(where: { $0.label == "location" })?.value as? PageLocation == location { return view }
            return view.subviews.lazy.compactMap { canvas(location, in: $0) }.first
        }
        func image(_ view: NSView) -> CGImage? {
            guard let value = Mirror(reflecting: view).children.first(where: { $0.label == "image" })?.value,
                  let bitmap = Mirror(reflecting: value).children.first?.value else { return nil }
            return (bitmap as! CGImage)
        }
        var stage = "initial"
        func settle(chapter: Int = 1) async throws {
            let deadline = Date().addingTimeInterval(15)
            var lastRevision = -1, steadyTicks = 0
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let revision = await pages.layoutRevision, table = await pages.chapterLayout
                let native = await pages.layoutPosition
                let target = native.anchor.flatMap(ChapterTable.bookmarkLocation)?.location
                if state.reflowable, state.pendingReflowPosition == nil, state.chapterLayout == table,
                   state.currentPosition.nativePassage?.chapter == chapter,
                   let target, target.chapter == chapter, painted(target, in: host) {
                    steadyTicks = revision == lastRevision ? steadyTicks + 1 : 0
                    if steadyTicks == 50 { return }
                } else { steadyTicks = 0 }
                lastRevision = revision
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            let native = await pages.layoutPosition
            XCTFail(state.error ?? "Reader did not settle: stage=\(stage), nativeRevision=\(lastRevision), UIRevision=\(state.renderRevision), ticks=\(steadyTicks), page=\(state.page), anchor=\(state.currentPosition.anchor ?? "nil"), nativeAnchor=\(native.anchor ?? "nil"), pending=\(state.pendingReflowPosition != nil), sourceChapter=\(String(describing: state.currentPosition.nativePassage?.chapter))")
            throw CancellationError()
        }
        try await settle()
        let source = try XCTUnwrap(state.currentPosition.nativePassage).source
        for mode in [ReaderMenuCommand.paged, .twoPages, .continuous, .twoPages] {
            stage = String(describing: mode)
            mode.run(state)
            try await settle()
            XCTAssertEqual(state.currentPosition.nativePassage?.source, source)
            let table = await pages.chapterLayout
            XCTAssertFalse(table.isLaidOut(3), "Visible reading must not automatically count the whole Markdown book")
            let revision = await pages.layoutRevision
            let locations = state.continuousReflow ? [] : state.visiblePages.map { state.pageLocation($0) }
            let bitmaps = try locations.map { location in
                try XCTUnwrap(image(XCTUnwrap(canvas(location, in: host))), "Every facing page must finish drawing")
            }
            for _ in 0..<50 {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let after = await pages.layoutRevision
            XCTAssertEqual(after, revision, "An unchanged reader frame must not feed fitted scrollbar geometry back into pagination")
            for (location, bitmap) in zip(locations, bitmaps) {
                let view = try XCTUnwrap(canvas(location, in: host))
                XCTAssertTrue(painted(location, in: view), "Every facing page must remain ready at idle")
                XCTAssertTrue(image(view) === bitmap, "Idle paints must reuse the bitmap instead of cycling the fitted viewport and rendering again")
            }
            XCTAssertNil(state.error)
        }
        stage = "sidebar-width"
        window.setContentSize(CGSize(width: 1433, height: 984))
        try await settle()
        let beforeLink = await pages.chapterLayout
        XCTAssertFalse(beforeLink.isLaidOut(2), "The skipped predecessor must still be lazy before following the link")
        XCTAssertFalse(beforeLink.isLaidOut(3))
        var firstDestinationTable: ChapterTable?
        let publication = state.$page.sink { _ in
            if state.currentPosition.nativePassage?.chapter == 3, firstDestinationTable == nil {
                firstDestinationTable = state.chapterLayout
            }
        }
        defer { publication.cancel() }
        stage = "local-link"
        state.navigate(.href("#distant"))
        try await settle(chapter: 3)
        let published = try XCTUnwrap(firstDestinationTable)
        XCTAssertTrue(published.isLaidOut(2), "Publish the linked facing row only after its predecessor has a real page count")
        XCTAssertGreaterThan(published.pageCount(2), 2)
        XCTAssertFalse(published.isLaidOut(4), "Following a link must keep distant chapters lazy")
        let target = PageLocation(chapter: 3, page: 0)
        let row = PageRows.range(page: try XCTUnwrap(published.page(for: target)), count: published.totalPages,
                                 spread: true, cover: state.cover)
        let locations = try row.map { try XCTUnwrap(published.location(page: $0)) }
        if locations.first?.chapter == 2 {
            XCTAssertEqual(locations, [.init(chapter: 2, page: published.pageCount(2) - 1), target])
        }
        XCTAssertNil(state.error)
    }
}
#endif
