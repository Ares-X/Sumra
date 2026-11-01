#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderTitlebarDragTests: XCTestCase {
    func testNativeOverlayTitlebarKeepsDragInputAboveSelectableText() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let text = "Section 1\n" + String(repeating: "Selectable reading content remains below the window controls.\n", count: 100)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/titlebar-drag.txt"), content: .text(text))
        state.immersiveControls = false; state.toolbarDisplayMode = .auto
        state.showContents = false; state.showAI = false; state.showFind = false
        let window = NSWindow(contentRect: NSRect(x: 2200, y: 100, width: 1100, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.toolbarStyle = .unifiedCompact; window.isReleasedWhenClosed = false
        // NSHostingView is not a WindowGroup scene; install the native
        // toolbar that the actual document scene supplies.
        window.toolbar = NSToolbar(identifier: "titlebar-drag-native-toolbar")
        window.contentView = NSHostingView(rootView: ReaderView(state: state).navigationTitle("titlebar-drag.txt"))
        window.ignoresMouseEvents = true
        state.window = window; window.orderBack(nil)
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        try await Task.sleep(nanoseconds: 150_000_000)
        let content = try XCTUnwrap(window.contentView)
        let root = try XCTUnwrap(content.superview)
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let observer = try XCTUnwrap(descendants(content).compactMap { $0 as? ReaderToolbarWindow.Host }.first)
        let initialFrame = window.frame
        for mode in [ReaderToolbarDisplayMode.auto, .hidden] {
            state.toolbarDisplayMode = mode
            for revealed in [false, true, false] {
                state.toolbarHoverVisible = revealed; state.toolbarHoverOpacity = revealed ? 1 : 0
                observer.updateChrome()
                try await Task.sleep(nanoseconds: 100_000_000)
                root.layoutSubtreeIfNeeded()
                let nativeContainer = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
                let nativeHeight = nativeContainer.bounds.height
                print("[titlebar-drag] mode=\(mode) revealed=\(revealed) native=\(nativeContainer.frame) layout=\(window.contentLayoutRect)")
                XCTAssertGreaterThan(nativeHeight, 0, "The fixture must have a native window titlebar")
                let point = NSPoint(x: 250, y: window.frame.height - 10)
                let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                XCTAssertFalse(hit is NSTextView, "The titlebar must not select the underlying text, mode=\(mode) revealed=\(revealed)")
                XCTAssertTrue(hit.mouseDownCanMoveWindow, "The titlebar's blank area must keep window dragging, hit=\(type(of: hit))")
                let body = try XCTUnwrap(root.hitTest(root.convert(NSPoint(x: 250, y: 200), from: nil)))
                let textView = try XCTUnwrap(body as? NSTextView, "The body must keep its normal text selection")
                XCTAssertTrue(textView.isSelectable)
                XCTAssertFalse(textView.mouseDownCanMoveWindow)
                if mode == .auto && revealed {
                    for control in [try XCTUnwrap(window.standardWindowButton(.closeButton))] {
                        XCTAssertTrue(control.window === window, "The fixture control must be mounted in the native window")
                        XCTAssertGreaterThan(control.bounds.width, 0)
                        XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, "Verify actual visible native controls")
                        let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                        let target = try XCTUnwrap(root.hitTest(root.convert(center, from: nil)))
                        XCTAssertTrue(target === control || target.isDescendant(of: control),
                            "The drag overlay must not intercept native controls: \(type(of: target))")
                    }
                }
                XCTAssertEqual(window.frame, initialFrame, "Revealing chrome must preserve the window frame")
            }
        }
    }
}
#endif
