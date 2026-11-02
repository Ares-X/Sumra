#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderScrollbarClearanceTests: XCTestCase {
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
            clearance.updateScrollbars(); scroll.tile()
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
            XCTAssertGreaterThan(scroll.scrollerInsets.bottom, 0)
            let before = scroll.scrollerInsets
            state.toolbarHoverVisible = true
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(NSEdgeInsetsEqual(scroll.scrollerInsets, before),
                "Hovering controls must not move the scrollbar track during use")
        }
    }
}
#endif
