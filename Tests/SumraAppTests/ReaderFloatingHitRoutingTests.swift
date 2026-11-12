#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Checks the mounted view tree's native hit routing. No pointer events or
/// button actions are sent; passing does not prove WindowServer hover delivery
/// or presentation of the system green-button menu.
@MainActor final class ReaderFloatingHitRoutingTests: XCTestCase {
    func testMountedReaderFloatingGreenReceivesContentRootHit() async throws {
        let state = documentState(mode: .shown)
        state.showContents = false; state.showAI = false; state.showFind = false
        let fixture = Fixture(state: state, width: 900, content: ReaderView(state: state))
        defer { fixture.close() }
        try await assertGreenOwnsHit(in: fixture)
    }

    func testDocumentFloatingGreenReceivesContentRootHitsInWideAndCompactLayouts() async throws {
        for width in [560.0, 900.0] {
            let state = documentState(mode: .shown)
            let fixture = Fixture(state: state, width: width,
                content: ReaderFloatingControls(state: state, open: {}))
            defer { fixture.close() }
            try await assertGreenOwnsHit(in: fixture)
        }
    }

    func testAlwaysHiddenDocumentGreenReceivesContentRootHitsWhenRevealed() async throws {
        let state = documentState(mode: .hidden)
        let fixture = Fixture(state: state, width: 900,
            content: ReaderFloatingControls(state: state, open: {}))
        defer { fixture.close() }
        try await assertGreenOwnsHit(in: fixture)
    }

    func testHomeHeaderGreenReceivesTheSameContentRootHit() async throws {
        for width in [560.0, 900.0] {
            let state = ReaderState(recordsHistory: false)
            let fixture = Fixture(state: state, width: width,
                content: ReaderHomeHeader(state: state))
            defer { fixture.close() }
            try await assertGreenOwnsHit(in: fixture)
        }
    }

    private func documentState(mode: ReaderToolbarDisplayMode) -> ReaderState {
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/floating-hit-routing.txt"), content: .text("Book"))
        state.immersiveControls = true
        state.toolbarDisplayMode = mode
        state.toolbarHoverVisible = true
        state.toolbarHoverOpacity = 1
        return state
    }

    private func assertGreenOwnsHit(in fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<15 {
            fixture.root.layoutSubtreeIfNeeded()
            fixture.host.layoutSubtreeIfNeeded()
            if let bitmap = fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds) {
                fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Search only the hosted content, excluding the window's separate
        // native titlebar. The public accessibility subrole identifies green.
        let green = try XCTUnwrap(descendants(fixture.host).compactMap { $0 as? NSButton }.first {
            $0.accessibilitySubrole() == .fullScreenButton
        }, file: file, line: line)
        XCTAssertTrue(green.isEnabled, file: file, line: line)
        XCTAssertFalse(green.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertTrue(green.target === fixture.window, file: file, line: line)
        XCTAssertGreaterThan(green.bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(green.bounds.height, 0, file: file, line: line)

        let center = NSPoint(x: green.bounds.midX, y: green.bounds.midY)
        let windowPoint = green.convert(center, to: nil)
        // NSView.hitTest receives a point in the receiver's superview space.
        let rootPoint = fixture.root.superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint
        let hit = try XCTUnwrap(fixture.root.hitTest(rootPoint), file: file, line: line)
        XCTAssertTrue(hit === green || hit.isDescendant(of: green),
            "The green button must own its center hit; received \(type(of: hit)) at \(windowPoint)",
            file: file, line: line)
        XCTAssertEqual(fixture.window.alphaValue, 0, file: file, line: line)
        XCTAssertTrue(fixture.window.ignoresMouseEvents, file: file, line: line)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private final class Fixture {
        let state: ReaderState
        let window: NSWindow
        let root: NSView
        let host: NSHostingView<AnyView>

        init<Content: View>(state: ReaderState, width: CGFloat, content: Content) {
            _ = NSApplication.shared
            self.state = state
            let size = NSSize(width: width, height: 240)
            window = NSWindow(contentRect: NSRect(origin: .init(x: 2400, y: 100), size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            state.window = window
            root = NSView(frame: NSRect(origin: .zero, size: size))
            host = NSHostingView(rootView: AnyView(content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)))
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
            window.contentView = root
            // Materialize the native hosting hierarchy without activation or
            // a visible/input-receiving test window on the user's desktop.
            window.orderBack(nil)
        }

        func close() {
            func stopControls(in view: NSView) {
                (view as? ReaderFloatingWindowButtons.Buttons)?.stopObservingWindow()
                for child in view.subviews { stopControls(in: child) }
            }
            stopControls(in: host)
            window.contentView = nil
            window.orderOut(nil)
            window.close()
            state.windowClosed()
        }
    }
}
#endif
