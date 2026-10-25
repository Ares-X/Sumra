#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeLinkInteractionTests: XCTestCase {
    func testHoverImageFitsShortAndNarrowScreensWithoutCoveringItsSourceLink() {
        let preferred = CGSize(width: 320, height: 440)
        let cases: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1280, height: 720), CGRect(x: 600, y: 350, width: 80, height: 20)),
            (CGRect(x: -280, y: 110, width: 280, height: 300), CGRect(x: -265, y: 250, width: 80, height: 20)),
            (CGRect(x: 1728, y: -323, width: 2560, height: 1415), CGRect(x: 1740, y: 1000, width: 80, height: 20)),
            (CGRect(x: 1728, y: -323, width: 2560, height: 1415), CGRect(x: 4180, y: -300, width: 80, height: 20)),
        ]
        for (screen, link) in cases {
            let frame = RasterCanvas.Canvas.linkPreviewFrame(size: preferred, anchor: link, visibleFrame: screen)
            XCTAssertTrue(screen.insetBy(dx: -0.001, dy: -0.001).contains(frame), "Preview clipped by screen: \(screen), \(frame)")
            XCTAssertFalse(frame.intersects(link), "Keep the hovered source link visible")
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertEqual(frame.width / frame.height, preferred.width / preferred.height, accuracy: 0.001)
            XCTAssertLessThanOrEqual(frame.width, preferred.width)
            XCTAssertLessThanOrEqual(frame.height, preferred.height)
        }
    }

    func testTooltipOwnerSurvivesAutoreleaseAndUsesCurrentVisibleLinksAcrossLifecycle() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.hoverPreview = true
        let canvas = RasterCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        canvas.state = state; canvas.pageBounds = canvas.bounds; canvas.visibleBounds = canvas.bounds
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = canvas
        let window = NSWindow(contentRect: scroll.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        scroll.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero)
        let owner: any NSViewToolTipOwner = canvas
        func tooltip(_ point: CGPoint) -> String {
            owner.view(canvas, stringForToolTip: 0, point: point, userData: nil)
        }
        let source = CGPoint(x: 50, y: 40), distant = CGPoint(x: 50, y: 440)
        autoreleasepool {
            let uri = String(format: "https://example.org/a%%20b?revision=%d#part%%202", 7)
            canvas.links = [RasterLink(uri: uri, rect: [20, 20, 120, 40]),
                RasterLink(uri: "#distant-一", rect: [20, 420, 120, 40])]
            canvas.updateLinkHints()
        }
        XCTAssertEqual(tooltip(source), "https://example.org/a%20b?revision=7#part%202")
        XCTAssertEqual(tooltip(distant), "#distant-一", "Finite pages retain all authored link hints")
        XCTAssertEqual(tooltip(CGPoint(x: 300, y: 100)), "")

        autoreleasepool {
            canvas.links = [RasterLink(uri: "#replacement", rect: [20, 20, 120, 40]),
                RasterLink(uri: "#distant-一", rect: [20, 420, 120, 40])]
            canvas.viewportTileSize = CGSize(width: 400, height: 200)
            canvas.updateLinkHints()
        }
        XCTAssertEqual(tooltip(source), "#replacement", "Rebuilt tooltips must resolve the current URI")
        XCTAssertEqual(tooltip(distant), "", "Natural chapters expose hints only for visible tiles")
        state.hoverPreview = false; canvas.updateLinkHints()
        XCTAssertEqual(tooltip(source), "", "Disabling hover must invalidate pending tooltip text")
        state.hoverPreview = true; canvas.updateLinkHints()
        XCTAssertEqual(tooltip(source), "#replacement")
        window.contentView = nil
        XCTAssertEqual(tooltip(source), "", "A pending callback must not expose a detached page's tooltip")
    }

    func testHoverImagePreservesReaderFocusAndFirstClickFollowsEbookLinkWithoutMarker() async throws {
        let (directory, pages, state, host, window) = try await makeReader()
        defer { close(state, window); withExtendedLifetime(directory) {} }
        try await wait(host, state) {
            self.canvases(in: host).contains { !$0.links.isEmpty && $0.readingReady }
        }
        let canvas = try XCTUnwrap(canvases(in: host).first { !$0.links.isEmpty && $0.readingReady })
        let link = try XCTUnwrap(canvas.links.first { $0.uri == "#destination" })
        let resolved = try await pages.resolve(link.uri, from: state.currentPosition)
        let destination = try XCTUnwrap(resolved)
        XCTAssertGreaterThan(destination.page, 0)
        window.makeFirstResponder(canvas)
        let keyWindow = NSApp.keyWindow
        try enterLink(in: canvas)
        try await wait(host, state) { window.childWindows?.contains { $0.isVisible } == true }
        let preview = try XCTUnwrap(window.childWindows?.first { $0.contentView is NSImageView })
        XCTAssertTrue(preview.ignoresMouseEvents, "The hover image must pass pointer events to the reader")
        XCTAssertFalse(preview.canBecomeKey)
        XCTAssertTrue(window.firstResponder === canvas)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertNotNil((preview.contentView as? NSImageView)?.image)
        let screen = try XCTUnwrap(window.screen)
        XCTAssertTrue(screen.visibleFrame.contains(preview.frame), "The whole preview must remain on its display")
        let anchor = window.convertToScreen(canvas.convert(link.bounds.applying(canvas.pageTransform), to: nil))
        XCTAssertFalse(preview.frame.intersects(anchor), "The source link must remain visible below the pointer")

        let point = CGPoint(x: link.bounds.midX, y: link.bounds.midY).applying(canvas.pageTransform)
        let windowPoint = canvas.convert(point, to: nil)
        let content = try XCTUnwrap(window.contentView)
        let hit = content.hitTest(content.convert(windowPoint, from: nil))
        XCTAssertTrue(hit === canvas,
            "The source link must be the window's pointer target")
        let target = try XCTUnwrap(hit)
        // XCTest's application does not run AppKit's event loop or acquire
        // key-window state. Dispatch one click to the real hit-tested view;
        // OS window dispatch is exercised separately in GUI acceptance.
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: windowPoint, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if kind == .leftMouseDown { target.mouseDown(with: event) }
            else { target.mouseUp(with: event) }
        }
        try await wait(host, state) {
            state.page == destination.page && self.canvases(in: host).contains {
                RasterReader.pageIsRendered(in: $0, pages: pages, location: state.pageLocation(state.page))
            }
        }
        XCTAssertFalse(preview.isVisible)
        XCTAssertNil(preview.parent)
        XCTAssertNil(state.linkDestinationHint, "Ordinary ebook navigation must not paint a destination circle")
        XCTAssertTrue(state.canNavigateBack)
        XCTAssertNil(state.error)
    }

    func testLeavingDisablingAndDetachingReaderDismissHoverImage() async throws {
        let (directory, _, state, host, window) = try await makeReader()
        defer { close(state, window); withExtendedLifetime(directory) {} }
        try await wait(host, state) {
            self.canvases(in: host).contains { !$0.links.isEmpty && $0.readingReady }
        }
        let canvas = try XCTUnwrap(canvases(in: host).first { !$0.links.isEmpty && $0.readingReady })
        try enterLink(in: canvas)
        canvas.mouseExited(with: NSEvent())
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(window.childWindows?.isEmpty != false, "Leaving during the hover delay must cancel the image")

        try enterLink(in: canvas)
        try await wait(host, state) { window.childWindows?.contains { $0.isVisible } == true }
        let first = try XCTUnwrap(window.childWindows?.first)
        state.hoverPreview = false
        try await wait(host, state) { !first.isVisible && first.parent == nil }
        XCTAssertFalse(canvas.trackingAreas.contains { $0.userInfo?["uri"] != nil })

        state.hoverPreview = true
        try await wait(host, state) { canvas.trackingAreas.contains { $0.userInfo?["uri"] != nil } }
        try enterLink(in: canvas)
        try await wait(host, state) { window.childWindows?.contains { $0.isVisible } == true }
        let second = try XCTUnwrap(window.childWindows?.first)
        window.contentView = nil
        XCTAssertFalse(second.isVisible)
        XCTAssertNil(second.parent)
        XCTAssertNil(state.error)
    }

    private func makeReader() async throws -> (TemporaryDirectory, Pages, ReaderState, NSHostingView<RasterReader>, NSWindow) {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("links.md")
        try ("[Jump to destination](#destination)\n\n"
            + String(repeating: "Filler text before the destination.\n\n", count: 60)
            + "# Destination\n\nDestination body.\n")
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.reflowable = true; state.automaticLayout = false
        state.flow = "paged"; state.spread = false; state.fit = "page"; state.zoom = 1
        state.fontSize = 17; state.lineHeight = 1.6; state.font = "system"; state.theme = "light"
        state.margin = 32; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.rectangularSelection = false; state.disableLinks = false
        state.keyboardLinkFollowing = false; state.keyboardTextSelection = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.landscapeAsSpread = false
        state.hoverPreview = true; state.showContents = false; state.scrollbarMode = "hidden"
        let prepared = try await pages.prepare()
        state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
        _ = try await pages.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
            margin: state.margin, font: state.font, theme: state.resolvedTheme,
            userCSS: state.effectiveUserCSS, useDocumentCSS: state.useDocumentCSS,
            pageMargins: state.pageMargins, pageSize: CGSize(width: 520, height: 440))
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        var frame = CGRect(x: 200, y: 300, width: 520, height: 440)
        if let display = ProcessInfo.processInfo.environment["SUMRA_TEST_DISPLAY_NAME"] {
            let screen = try XCTUnwrap(NSScreen.screens.first { $0.localizedName == display }, "Requested test display is unavailable")
            frame.origin = CGPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2)
        }
        let window = NSWindow(contentRect: frame,
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (directory, pages, state, host, window)
    }

    private func enterLink(in canvas: RasterCanvas.Canvas) throws {
        let event = LinkHoverEvent()
        event.area = try XCTUnwrap(canvas.trackingAreas.first { $0.userInfo?["uri"] as? String == "#destination" })
        canvas.mouseEntered(with: event)
    }

    private func canvases(in view: NSView) -> [RasterCanvas.Canvas] {
        if let canvas = view as? RasterCanvas.Canvas { return [canvas] }
        return view.subviews.flatMap { canvases(in: $0) }
    }

    private func wait(_ host: NSView, _ state: ReaderState, _ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Link interaction did not settle", line: line)
    }

    private func close(_ state: ReaderState, _ window: NSWindow) {
        state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
    }
}

private final class LinkHoverEvent: NSEvent {
    var area: NSTrackingArea?
    override var trackingArea: NSTrackingArea? { area }
}
#endif
