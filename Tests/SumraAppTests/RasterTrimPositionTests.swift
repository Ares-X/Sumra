#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor final class RasterTrimPositionTests: XCTestCase {
    func testContinuousPDFTrimKeepsTheSelectedPageAndRetainsAnInContentSourcePoint() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("trim-position.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 800)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &media, nil))
        for _ in 0..<5 {
            writer.beginPDFPage(nil)
            writer.setFillColor(CGColor(gray: 0.3, alpha: 1))
            writer.fill(CGRect(x: 80, y: 100, width: 240, height: 550))
            writer.endPDFPage()
        }
        writer.closePDF()
        let original = try Data(contentsOf: input)
        let pages = try Pages(input, format: .pdf)
        let pageBounds = try await pages.bounds(0)
        let content = try await pages.contentBounds(2)
        XCTAssertGreaterThan(content.minY, pageBounds.minY, "Exercise a real removed top margin")
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.count = await pages.count; state.reflowable = false
        state.flow = "continuous"; state.fit = "width"; state.spread = false; state.cover = false
        state.rotation = 0; state.rtl = false; state.automaticLayout = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.freePan = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        state.pageMargins = PageMargins(cssValues: [0]); state.marginPresetSelection = "custom"
        state.engineeringEnhance = "off"
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages, initialBounds: pageBounds))
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 540, height: 420),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.title = "Continuous PDF trim position"
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer {
            state.windowClosed(); window.orderOut(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func canvases(_ view: NSView) -> [RasterCanvas.Canvas] {
            (view as? RasterCanvas.Canvas).map { [$0] } ?? view.subviews.flatMap(canvases)
        }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                paint()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Native PDF geometry did not settle; page=\(state.page), y=\(String(describing: state.currentPosition.y))", line: line)
            throw CancellationError()
        }
        func settle() async throws {
            for _ in 0..<15 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
        }
        func sourceY() throws -> CGFloat {
            let canvas = try XCTUnwrap(state.readerFocusView as? RasterCanvas.Canvas)
            let clip = try XCTUnwrap(canvas.enclosingScrollView?.contentView)
            return canvas.convert(clip.bounds.origin, from: clip).applying(canvas.pageTransform.inverted()).y
        }
        func go(to page: Int) async throws {
            let revision = state.command.revision + 2
            state.send(.page(page)); state.send(.none)
            try await waitFor {
                state.command.revision >= revision && state.command.action == .none && state.page == page &&
                    RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: page))
            }
            try await settle()
        }
        try await waitFor { state.readerScrollView?.window === window }
        try await go(to: 2)
        XCTAssertEqual(try sourceY(), pageBounds.minY, accuracy: 0.5)
        state.trimEmptyMargins = true
        try await waitFor {
            canvases(host).contains { $0.page == 2 && $0.readingReady && $0.visibleBounds == content }
        }
        try await settle()
        XCTAssertEqual(state.page, 2, "Trimming the selected page's top margin must not scroll into the previous physical page")
        if state.page == 2 {
            XCTAssertEqual(try sourceY(), content.minY, accuracy: 0.5,
                "A source point in the removed top margin moves to the same page's first visible content")
        }

        // An already visible source point must survive trimming and resizing;
        // always snapping to the page start would lose this reading position.
        state.trimEmptyMargins = false
        try await settle()
        let anchorY = content.minY + 180
        state.send(.restore(.init(page: 2, y: Double(anchorY)))); state.send(.none)
        try await waitFor { state.page == 2 && abs((state.currentPosition.y ?? -1) - Double(anchorY)) < 0.5 }
        try await settle()
        state.trimEmptyMargins = true
        try await waitFor {
            canvases(host).contains { $0.page == 2 && $0.readingReady && $0.visibleBounds == content }
        }
        try await settle()
        XCTAssertEqual(state.page, 2)
        XCTAssertEqual(try sourceY(), anchorY, accuracy: 0.5)
        for size in [CGSize(width: 380, height: 420), CGSize(width: 700, height: 500)] {
            window.setContentSize(size)
            try await settle()
            XCTAssertEqual(state.page, 2)
            XCTAssertEqual(try sourceY(), anchorY, accuracy: 0.5)
        }

        // A real page command still selects that page's cropped beginning;
        // subsequent native scrolling records the new point instead of
        // replaying the preceding trim restoration.
        try await go(to: 3)
        XCTAssertEqual(try sourceY(), content.minY, accuracy: 0.5)
        let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.bounds.minY + 150))
        scroll.reflectScrolledClipView(clip)
        try await waitFor { state.page == 3 && (state.currentPosition.y ?? 0) > Double(content.minY) }
        try await settle()
        XCTAssertGreaterThan(try sourceY(), content.minY)
        XCTAssertNil(state.error)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
}
#endif
