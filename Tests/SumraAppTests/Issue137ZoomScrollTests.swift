#if os(macOS)
import XCTest
import SwiftUI
import PDFKit
@testable import Sumra

final class Issue137ZoomScrollTests: XCTestCase {
    private final class ReboundClipView: NSClipView {
        var permitsOverscroll = false
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            permitsOverscroll ? proposedBounds : super.constrainBoundsRect(proposedBounds)
        }
    }

    @MainActor
    func testZoomedPageKeepsMixedAxisGestureWithTheScrollView() async throws {
        _ = NSApplication.shared
        let pdf = PDFDocument()
        for height in [1200, 1300, 1400] {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 1200, height: CGFloat(height)), for: .mediaBox)
            pdf.insert(page, at: pdf.pageCount)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(pdf); state.count = 3
        let pages = try XCTUnwrap(state.nativePDF)
        state.flow = "paged"; state.fit = "actual"; state.zoom = 1
        state.spread = false; state.cover = false; state.rtl = false
        state.rotation = 0; state.freePan = false; state.automaticLayout = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 500, height: 350),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            } while Date() < deadline && state.error == nil
            _ = try XCTUnwrap(condition() ? true : nil,
                state.error ?? "Reader did not settle; page \(state.page), command \(state.command.revision): \(state.command.action), clip \(String(describing: state.readerScrollView?.contentView.bounds)), canvas \(String(describing: state.readerFocusView?.bounds))", line: line)
        }
        try await waitFor {
            guard let scroll = state.readerScrollView, let view = scroll.documentView else { return false }
            return view.frame.width > scroll.contentView.bounds.width + 100 && view.frame.height > scroll.contentView.bounds.height + 100
        }
        state.restore(.init(page: 1))
        try await waitFor {
            guard state.page == 1, let canvas = state.readerFocusView, canvas.window === window else { return false }
            return abs(canvas.bounds.height - 1300) <= 1
        }
        func settleCommands(line: UInt = #line) async throws {
            var completed = false
            state.send(.none) { completed = true }
            try await waitFor({ completed }, line: line)
        }
        try await settleCommands()
        let scroll = try XCTUnwrap(state.readerScrollView)
        let canvas = try XCTUnwrap(scroll.documentView)
        let clip = ReboundClipView(frame: scroll.contentView.frame)
        scroll.contentView = clip
        scroll.documentView = canvas
        func send(_ x: Int32, _ y: Int32, phase: CGScrollPhase?, momentum: Int64 = 0) throws -> Bool {
            let point = clip.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
            let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let cg = try XCTUnwrap(seed.cgEvent?.copy()); cg.type = .scrollWheel
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            // Exercise the application's routing boundary against a mounted
            // reader. Synthetic trackpad samples do not reproduce physical
            // AppKit gesture scrolling; ordinary scroll delivery is covered by
            // testWheelRoutesAcrossPageMarginsWithoutSkippingOnMomentum.
            return state.handleScrollWheel(event)
        }
        // Start at the left edge and inside the vertical range. A trackpad
        // gesture begins by panning down, then its dominant component wobbles
        // left at the edge while its vertical component continues to pan.
        var origin = clip.bounds.origin; origin.x = 0; origin.y = 200
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
        XCTAssertFalse(try send(0, -20, phase: .began))
        XCTAssertFalse(try send(30, -10, phase: .changed))
        XCTAssertFalse(try send(0, 0, phase: .ended))
        XCTAssertFalse(try send(20, -5, phase: nil, momentum: 1))
        try await settleCommands()
        XCTAssertEqual(state.page, 1, "Mixed-axis panning must not turn the page")

        // A fresh diagonal gesture can start with its dominant component at
        // an edge while the other component still has room to move.
        origin = clip.bounds.origin; origin.x = 0; origin.y = 200
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
        XCTAssertFalse(try send(30, -10, phase: .began))
        XCTAssertFalse(try send(20, -20, phase: .changed))
        XCTAssertFalse(try send(0, 0, phase: .ended))
        try await settleCommands()
        XCTAssertEqual(state.page, 1)

        // A new deliberate horizontal gesture at the left edge still turns
        // to the previous page; this must not inherit the prior pan latch.
        origin = clip.bounds.origin; origin.x = 0
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
        XCTAssertTrue(try send(30, 0, phase: .began))
        try await waitFor { state.page == 0 }
        try await settleCommands()

        state.restore(.init(page: 1))
        try await waitFor {
            state.page == 1 && abs((state.readerFocusView?.bounds.height ?? 0) - 1300) <= 1
        }
        try await settleCommands()

        // A strong pan can leave the real clip outside its constrained bounds
        // while AppKit springs it back. A new outward gesture at that edge must
        // turn immediately instead of latching onto the rebound as a new pan.
        origin = clip.bounds.origin; origin.x = -20; origin.y = 200
        // AppKit's public setters constrain ordinary programmatic scrolling.
        // Permit this one placement, then use native constraints for routing.
        clip.permitsOverscroll = true
        clip.setBoundsOrigin(origin)
        clip.permitsOverscroll = false
        XCTAssertEqual(clip.bounds.minX, -20, accuracy: 0.5)
        XCTAssertEqual(clip.constrainBoundsRect(clip.bounds).minX, 0, accuracy: 0.5)
        XCTAssertTrue(try send(30, 0, phase: .began))
        XCTAssertTrue(try send(20, 0, phase: .changed))
        XCTAssertFalse(try send(0, 0, phase: .ended))
        XCTAssertTrue(try send(20, 0, phase: nil, momentum: 1))
        try await settleCommands()
        XCTAssertEqual(state.page, 0, "A fresh gesture during rebound must turn once without waiting")
    }
}
#endif
