#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderFixedPDFChromeLayoutTests: XCTestCase {
    func testPagedTwoPageWidthFitKeepsRawPositionWhenHiddenChangesToAuto() async throws {
        try await checkPagedPositionWhenChangingToAuto(from: .hidden)
    }

    func testPagedTwoPageWidthFitKeepsScrolledPageWhenShownChangesToAuto() async throws {
        try await checkPagedPositionWhenChangingToAuto(from: .shown)
    }

    private func checkPagedPositionWhenChangingToAuto(from initialMode: ReaderToolbarDisplayMode) async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("two-page-position.pdf")
        var page = CGRect(x: 0, y: 0, width: 400, height: 1200)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &page, nil))
        for _ in 0..<(initialMode == .shown ? 4 : 2) {
            writer.beginPDFPage(nil)
            for stripe in 0..<15 {
                writer.setFillColor(CGColor(gray: stripe.isMultiple(of: 2) ? 0.1 : 0.5, alpha: 1))
                writer.fill(CGRect(x: 0, y: CGFloat(stripe * 80), width: 400, height: 80))
            }
            writer.endPDFPage()
        }
        writer.closePDF()
        let defaults = UserDefaults.standard
        let savedProgress = defaults.object(forKey: "progressDisplayMode")
        // Shown→Auto also changes the native footer from a reserved row to an
        // overlay. Include that structural boundary in the position regression.
        defaults.set((initialMode == .shown ? ReaderToolbarDisplayMode.auto : .hidden).rawValue, forKey: "progressDisplayMode")
        defer { defaults.set(savedProgress, forKey: "progressDisplayMode") }

        let document = try ReadingDocument.open(input)
        guard case .pages(let pages) = document.content else { return XCTFail("Expected MuPDF PDF pages") }
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.count = await pages.count
        state.flow = "paged"; state.spread = true; state.cover = false; state.fit = "width"
        state.automaticLayout = false; state.landscapeAsSpread = false; state.rtl = false
        state.immersiveControls = false; state.toolbarDisplayMode = initialMode; state.presentation = false
        if initialMode == .shown { state.updatePosition(.init(page: 2)) }
        state.pageMargins = .init(cssValues: [0]); state.marginPresetSelection = "custom"
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.scrollbarMode = "hidden"; state.theme = "light"; state.zoom = 1; state.rotation = 0
        state.invertColors = false; state.grayscale = false; state.engineeringEnhance = "off"
        state.showFitContentArea = false; state.showFind = false; state.showAI = false
        state.showContents = false; state.showBookmarks = false; state.showThumbnails = false; state.showAnnotations = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.toolbarStyle = .unifiedCompact; window.toolbar = NSToolbar(identifier: "two-page-position")
        window.contentView = host; state.window = window
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func canvases(in view: NSView) -> [RasterCanvas.Canvas] {
            if let canvas = view as? RasterCanvas.Canvas { return [canvas] }
            return view.subviews.flatMap { canvases(in: $0) }
        }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            var paintedPasses = 0
            repeat {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if let error = state.error { throw ReadError(error) }
                let mounted = canvases(in: host)
                if mounted.count == 2, mounted.allSatisfy({ $0.readingReady && $0.window === window }) {
                    paintedPasses += 1
                    if paintedPasses == 10 { return }
                } else { paintedPasses = 0 }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            throw ReadError("Both fixed PDF pages did not paint")
        }
        try await settle()
        let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
        let documentView = try XCTUnwrap(scroll.documentView)
        let extent = documentView.bounds.height - clip.bounds.height
        XCTAssertGreaterThan(extent, 200, "The fixture must have real vertical travel at Two Pages/Fit Width")
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: documentView.bounds.minY + extent * 0.75))
        scroll.reflectScrolledClipView(clip)
        try await settle()
        let before = clip.bounds, safeArea = clip.safeAreaRect, documentBounds = documentView.bounds
        let frame = clip.convert(clip.bounds, to: nil), selectedPage = state.page
        let visiblePages = state.visiblePages, position = state.currentPosition
        let mounted = canvases(in: host)
        let sourceRects = mounted.map { $0.visibleRect.intersection($0.bounds).applying($0.pageTransform.inverted()) }
        XCTAssertGreaterThan(before.minY - documentBounds.minY, 100, "The comparison must start away from the top")
        XCTAssertTrue(sourceRects.allSatisfy { !$0.isEmpty }, "Both facing PDF pages must be visible")
        if initialMode == .shown { XCTAssertEqual(selectedPage, 2, "Start on a nonzero facing pair so page resets are observable") }
        print("[fixed-pdf-mode-position] \(initialMode) clip=\(before) document=\(documentBounds) page=\(selectedPage) source=\(sourceRects)")

        state.toolbarDisplayMode = .auto
        try await settle()
        let afterScroll = try XCTUnwrap(state.readerScrollView), afterClip = afterScroll.contentView
        let afterDocument = try XCTUnwrap(afterScroll.documentView)
        if initialMode == .hidden {
            XCTAssertTrue(afterScroll === scroll, "Changing temporary chrome must retain the mounted PDF scroll owner")
            XCTAssertTrue(afterDocument === documentView)
            XCTAssertEqual(afterClip.bounds, before, "Hidden to Auto must preserve the raw scroll origin and viewport size")
            XCTAssertEqual(afterClip.safeAreaRect, safeArea)
            XCTAssertEqual(afterClip.convert(afterClip.bounds, to: nil), frame)
            XCTAssertEqual(afterDocument.bounds, documentBounds)
            XCTAssertEqual(state.currentPosition.x, position.x); XCTAssertEqual(state.currentPosition.y, position.y)
        } else {
            XCTAssertGreaterThan(afterClip.bounds.height, before.height, "Auto must reclaim the native chrome/footer area")
            XCTAssertEqual(afterDocument.bounds.size, documentBounds.size, "Width fit must preserve the PDF scale when only height grows")
            let legalOrigin = afterClip.constrainBoundsRect(CGRect(origin: before.origin, size: afterClip.bounds.size)).origin
            XCTAssertEqual(afterClip.bounds.origin.y, legalOrigin.y, accuracy: 1, "Allow legal clamping after viewport growth, but never reset the passage")
            XCTAssertEqual(afterClip.bounds.origin.x, legalOrigin.x, accuracy: 1)
            XCTAssertGreaterThan(afterClip.bounds.minY - afterDocument.bounds.minY, 100, "A scrolled PDF must not return to its top")
        }
        XCTAssertEqual(state.page, selectedPage); XCTAssertEqual(state.visiblePages, visiblePages)
        let afterCanvases = canvases(in: host)
        XCTAssertEqual(afterCanvases.map(\.location), mounted.map(\.location))
        let afterSource = afterCanvases.map { $0.visibleRect.intersection($0.bounds).applying($0.pageTransform.inverted()) }
        if initialMode == .hidden {
            XCTAssertEqual(afterSource, sourceRects, "The same source rectangles on both PDF pages must remain visible")
        } else {
            for (old, new) in zip(sourceRects, afterSource) {
                XCTAssertFalse(new.isEmpty)
                XCTAssertGreaterThanOrEqual(new.height, old.height, "A taller viewport must expose at least the old source height")
                // When no bottom clamp is needed, preserve the source line at
                // the reading area's top even if SwiftUI remounts its scroll.
                if before.minY + afterClip.bounds.height <= afterDocument.bounds.maxY {
                    XCTAssertEqual(new.minY, old.minY, accuracy: 1)
                }
            }
        }
        print("[fixed-pdf-mode-position] auto clip=\(afterClip.bounds) document=\(afterDocument.bounds) page=\(state.page) sameScroll=\(afterScroll === scroll) source=\(afterSource)")
        XCTAssertFalse(window.isVisible, "The fixture must not show a window or interfere with the live reader")
    }

    func testHiddenNativeChromeLetsFixedPDFPaintToWindowTopWithoutHoverLayoutChanges() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("fixed-pdf-top-marker.pdf")
        var page = CGRect(x: 0, y: 0, width: 400, height: 1200)
        let writer = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &page, nil))
        writer.beginPDFPage(nil)
        // Both the page top and content exposed by scrolling contrast with
        // the white reader/titlebar background. MuPDF renders this fixture.
        writer.setFillColor(CGColor(gray: 0.12, alpha: 1)); writer.fill(page)
        writer.setFillColor(CGColor(gray: 0, alpha: 1))
        writer.fill(CGRect(x: 0, y: page.maxY - 120, width: page.width, height: 120))
        writer.endPDFPage(); writer.closePDF()

        let defaults = UserDefaults.standard
        let savedProgress = defaults.object(forKey: "progressDisplayMode")
        defaults.set(ReaderToolbarDisplayMode.hidden.rawValue, forKey: "progressDisplayMode")
        defer { defaults.set(savedProgress, forKey: "progressDisplayMode") }

        let document = try ReadingDocument.open(input)
        guard case .pages(let pages) = document.content else { return XCTFail("Expected MuPDF pages") }
        let prepared = try await pages.prepare()
        XCTAssertFalse(prepared.reflowable, "The regression must use a fixed PDF, not a reflowable book")
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.count = await pages.count
        state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
        state.flow = "continuous"; state.fit = "width"; state.spread = false; state.cover = false
        state.rtl = false; state.automaticLayout = false; state.presentation = false
        state.immersiveControls = false; state.toolbarDisplayMode = .shown
        state.theme = "light"; state.invertColors = false; state.grayscale = false
        state.margin = 0; state.pageMargins = .init(cssValues: [0]); state.marginPresetSelection = "custom"
        state.scrollbarMode = "hidden"; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.freePan = false; state.rotation = 0; state.zoom = 1; state.landscapeAsSpread = false
        state.showFitContentArea = false; state.engineeringEnhance = "off"
        state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
        state.showAnnotations = false; state.showAI = false; state.showFind = false

        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "fixed-pdf-native-top")
        window.contentView = host; state.window = window
        defer { state.windowClosed(); window.contentView = nil; window.close() }

        func observer(in view: NSView) -> ReaderToolbarWindow.Host? {
            if let value = view as? ReaderToolbarWindow.Host { return value }
            return view.subviews.lazy.compactMap { observer(in: $0) }.first
        }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            var paintedPasses = 0
            repeat {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if let error = state.error { throw ReadError(error) }
                if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(0)) {
                    paintedPasses += 1
                    if paintedPasses == 10 { return }
                } else { paintedPasses = 0 }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < deadline
            throw ReadError("Fixed PDF did not settle and paint")
        }
        func assertDarkPDF(atWindowTop top: CGFloat, context: String) throws {
            let center = host.convert(NSPoint(x: host.convert(host.bounds, to: nil).midX, y: top - 8), from: nil)
            let sample = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: sample))
            host.cacheDisplay(in: sample, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.3,
                "The PDF marker must paint at the reading area's top, rather than a white chrome band: \(context)")
        }

        for mode in [ReaderToolbarDisplayMode.shown, .auto, .hidden, .shown] {
            state.toolbarDisplayMode = mode; state.toolbarHoverVisible = false; state.toolbarHoverOpacity = 0
            try await settle()
            let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
            let chrome = try XCTUnwrap(observer(in: host))
            chrome.reducedMotion = true
            chrome.updateChrome(revealingNativeControls: false)
            try await settle()
            let root = host.convert(host.bounds, to: nil)
            let expectedTop = mode == .shown ? window.contentLayoutRect.maxY : root.maxY
            let visible = clip.convert(clip.visibleRect.intersection(clip.bounds), to: nil)
            XCTAssertLessThan(window.contentLayoutRect.maxY, window.frame.height,
                "The fixture must install native chrome above its document content")
            XCTAssertEqual(visible.maxY, expectedTop, accuracy: 1,
                "Shown reserves native chrome; Auto and Hidden reclaim its document area: \(mode)")
            XCTAssertEqual(clip.convert(clip.safeAreaRect, to: nil).maxY, expectedTop, accuracy: 1,
                "The PDF's unobscured viewport must reach the same top: \(mode)")
            try assertDarkPDF(atWindowTop: expectedTop, context: "\(mode), initial position")

            // Reproduce content travelling beneath the former 54pt band.
            let beforeScroll = clip.bounds.origin
            clip.scroll(to: NSPoint(x: beforeScroll.x, y: beforeScroll.y + 180))
            scroll.reflectScrolledClipView(clip)
            try await settle()
            XCTAssertGreaterThan(clip.bounds.origin.y, beforeScroll.y + 100)
            try assertDarkPDF(atWindowTop: expectedTop, context: "\(mode), scrolled")
            let viewport = clip.convert(clip.bounds, to: nil), safeArea = clip.safeAreaRect
            let position = clip.bounds.origin, frame = window.frame
            if mode != .shown {
                for revealed in [true, false] {
                    state.toolbarHoverVisible = revealed; state.toolbarHoverOpacity = revealed ? 1 : 0
                    chrome.updateChrome(revealingNativeControls: false)
                    try await settle()
                    XCTAssertEqual(clip.convert(clip.bounds, to: nil), viewport, "Hover must not resize the PDF viewport")
                    XCTAssertEqual(clip.safeAreaRect, safeArea)
                    XCTAssertEqual(clip.bounds.origin, position, "Hover must retain the visible PDF passage")
                    XCTAssertEqual(window.frame, frame)
                    if !revealed { try assertDarkPDF(atWindowTop: expectedTop, context: "\(mode), dismissed hover") }
                }
            }
        }
        XCTAssertFalse(window.isVisible, "This layout test must not open a visible window or fullscreen Space")
    }
}
#endif
