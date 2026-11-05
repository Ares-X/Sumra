#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderScrollbarClearanceTests: XCTestCase {
    func testNativeSafeAreaAlreadyReservedByContentInsetsDoesNotReceiveDuplicateScrollbarClearance() throws {
        _ = NSApplication.shared
        for style in [NSScroller.Style.legacy, .overlay] {
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 900, height: 740),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = try XCTUnwrap(window.contentView)
            let nativeTop: CGFloat = 38, contentPadding: CGFloat = 7.5, footer: CGFloat = 26
            let scroll = NSScrollView(frame: CGRect(x: 0, y: footer, width: root.bounds.width,
                height: root.bounds.height - footer))
            let document = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1800))
            scroll.documentView = document
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.scrollerStyle = style; scroll.autohidesScrollers = false
            // SwiftUI manages the paged reader's native safe-area inset itself.
            // Its scroll view extends above ReaderView's background, even with
            // Always Show; that overlap has already been reserved in content.
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: nativeTop + contentPadding, left: 0, bottom: 0, right: 0)
            root.addSubview(scroll)
            scroll.tile()
            let vertical = try XCTUnwrap(scroll.verticalScroller)
            let baselineTrack = scroll.convert(vertical.bounds, from: vertical)
            let contentInsets = scroll.contentInsets
            let clipFrame = scroll.contentView.frame, clipBounds = scroll.contentView.bounds
            let documentFrame = document.frame, documentBounds = document.bounds

            let state = ReaderState(recordsHistory: false)
            let clearance = ReaderScrollbarClearance.Host(frame: CGRect(x: 0, y: 0,
                width: root.bounds.width, height: root.bounds.height - nativeTop))
            clearance.state = state; clearance.top = 0; clearance.bottom = 0
            root.addSubview(clearance)
            defer { state.windowClosed(); window.contentView = nil; window.close() }
            let readerInHost = clearance.convert(scroll.bounds, from: scroll)
            XCTAssertEqual(readerInHost.minY, -nativeTop, accuracy: 0.01,
                "Exercise the actual native-safe-area overlap, not a reader entirely inside its background")

            state.readerScrollView = scroll
            XCTAssertEqual(scroll.scrollerInsets.top, 0,
                "Always Show requests no overlay clearance because the native safe area is already reserved")
            XCTAssertEqual(scroll.convert(vertical.bounds, from: vertical), baselineTrack,
                "Publishing the reader must retain its native content-inset track without another top reserve")
            XCTAssertTrue(NSEdgeInsetsEqual(scroll.contentInsets, contentInsets))
            XCTAssertEqual(scroll.contentView.frame, clipFrame)
            XCTAssertEqual(scroll.contentView.bounds, clipBounds)
            XCTAssertEqual(document.frame, documentFrame)
            XCTAssertEqual(document.bounds, documentBounds)
        }
    }

    func testNativeScrollerTracksUpdateImmediatelyWhenClearanceChangesWithoutResize() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 600, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)
        let scroll = NSScrollView(frame: root.bounds)
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 4000))
        scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        root.addSubview(scroll)
        let coordinates = ReaderScrollbarClearance.Host(frame: root.bounds)
        root.addSubview(coordinates)
        defer { window.contentView = nil; window.close() }

        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            ReaderScrollbars.clearControls(in: scroll, above: 0, below: 0)
            // Establish the native zero-inset baseline once. Clearance changes
            // below must update the real track without a caller tiling it.
            scroll.tile()
            let vertical = try XCTUnwrap(scroll.verticalScroller)
            let baseline = coordinates.convert(vertical.bounds, from: vertical)
            let viewportFrame = scroll.contentView.frame, viewportBounds = scroll.contentView.bounds
            let documentFrame = document.frame, documentBounds = document.bounds
            let scrollFrame = scroll.frame
            XCTAssertGreaterThan(baseline.height, 0)

            for (top, bottom) in [(CGFloat(52), CGFloat(56)), (20, 12), (0, 0)] {
                ReaderScrollbars.clearControls(in: scroll, above: top, below: bottom)
                let track = coordinates.convert(vertical.bounds, from: vertical)
                XCTAssertEqual(track.minY, baseline.minY + top, accuracy: 1,
                    "Changing clearance must immediately move the actual track's top in \(style)")
                XCTAssertEqual(track.maxY, baseline.maxY - bottom, accuracy: 1,
                    "Removing clearance must immediately restore the actual track's ends in \(style)")
                XCTAssertEqual(scroll.frame, scrollFrame, "The caller must not need to resize the scroll view")
                XCTAssertEqual(scroll.contentView.frame, viewportFrame)
                XCTAssertEqual(scroll.contentView.bounds, viewportBounds)
                XCTAssertEqual(document.frame, documentFrame)
                XCTAssertEqual(document.bounds, documentBounds)
            }
        }
    }

    func testNativeScrollerTracksClearControlsWithoutShrinkingTheReadingViewport() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 4_000))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        root.addSubview(scroll)
        let state = ReaderState(recordsHistory: false)
        state.readerScrollView = scroll
        let clearance = ReaderScrollbarClearance.Host(frame: root.bounds)
        clearance.state = state; clearance.top = 52; clearance.bottom = 56
        root.addSubview(clearance)
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style; scroll.tile()
            let clip = scroll.contentView.frame
            clearance.updateScrollbars()
            XCTAssertEqual(scroll.contentView.frame, clip,
                "Only the track should be inset; reading content continues beneath the controls")
            let vertical = try XCTUnwrap(scroll.verticalScroller)
            let track = clearance.convert(vertical.bounds, from: vertical)
            XCTAssertGreaterThanOrEqual(track.minY, clearance.top)
            XCTAssertLessThanOrEqual(track.maxY, clearance.bounds.maxY - clearance.bottom)
        }
        // A reserved toolbar/footer row already moves the reader inward.
        scroll.frame = CGRect(x: 0, y: 56, width: 600, height: 500 - 52 - 56)
        clearance.updateScrollbars()
        XCTAssertEqual(scroll.scrollerInsets.top, 0)
        XCTAssertEqual(scroll.scrollerInsets.bottom, 0)
    }

    func testReaderViewKeepsNativeTextScrollbarEndsOutsideFloatingAndAutoHiddenControls() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, saved = defaults.object(forKey: "progressDisplayMode")
        defer { defaults.set(saved, forKey: "progressDisplayMode") }
        defaults.set("auto", forKey: "progressDisplayMode")
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/scrollbar-clearance.txt"),
            content: .text(String(repeating: "A native text reader passage.\n", count: 300)))
        state.controlTopMargin = 0; state.controlBottomMargin = 0
        state.pageMargins = PageMargins(cssValues: [0]); state.marginPresetSelection = "custom"
        state.showContents = false; state.showAI = false
        state.showFind = false; state.scrollbarMode = "shown"
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer { state.windowClosed(); window.contentView = nil; window.orderOut(nil); window.close() }
        for floating in [true, false] {
            state.immersiveControls = floating
            state.toolbarDisplayMode = .auto
            for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
            let scroll = try XCTUnwrap(state.readerScrollView)
            XCTAssertGreaterThan(scroll.scrollerInsets.top, 0)
            let readerFrame = host.convert(scroll.bounds, from: scroll)
            if floating { XCTAssertGreaterThan(scroll.scrollerInsets.bottom, 0) }
            else {
                let bottom = host.isFlipped ? host.bounds.maxY - readerFrame.maxY : readerFrame.minY - host.bounds.minY
                XCTAssertEqual(bottom, ReaderProgressFooter.height, accuracy: 1,
                    "Normal Auto Hide progress keeps its own row below the reading area")
            }
            let before = scroll.scrollerInsets
            state.toolbarHoverVisible = true
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(NSEdgeInsetsEqual(scroll.scrollerInsets, before),
                "Hovering controls must not move the scrollbar track during use")
        }
    }
}
#endif
