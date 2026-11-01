#if os(macOS)
import AppKit
import ApplicationServices
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor final class ReaderTopControlsLayoutTests: XCTestCase {
    func testContentsHeaderDoesNotReserveTopClearanceAgainBelowDockedFind() async throws {
        try await checkLayout(ai: false)
    }

    func testAIHeaderDoesNotReserveTopClearanceAgainBelowDockedFind() async throws {
        try await checkLayout(ai: true)
    }

    func testHiddenToolbarReleasesContentsClearanceAndPreservesWindowControlSpace() async throws {
        try await checkLayout(ai: false, hidden: true)
    }

    func testHiddenToolbarReleasesAIClearanceAndPreservesWindowControlSpace() async throws {
        try await checkLayout(ai: true, hidden: true)
    }

    private func checkLayout(ai: Bool, hidden: Bool = false) async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard
        let keys = ["language", "findFloating", "sidebarRight", "progressDisplayMode", "toolbarDisplayMode", "immersiveControls"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set("en", forKey: "language")
        defaults.set(false, forKey: "findFloating")
        defaults.set(false, forKey: "sidebarRight")
        defaults.set("hidden", forKey: "progressDisplayMode")
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/top-controls-layout.txt"),
            content: .text("A paragraph for the reader."))
        state.count = 2
        state.showContents = !ai; state.showAI = ai
        state.showAnnotations = false; state.showBookmarks = false; state.showThumbnails = false
        state.immersiveControls = true; state.toolbarDisplayMode = hidden ? .hidden : .shown
        state.controlTopMargin = 54; state.controlBottomMargin = 0
        state.showFind = !hidden

        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 1000, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        window.title = "Top clearance \(ai ? "AI" : "Contents") hidden=\(hidden)"
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer {
            state.windowClosed()
            window.orderOut(nil); window.contentView = nil; window.close()
        }

        func settle() async throws {
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func header(in elements: [Element]) throws -> CGRect {
            let label = L(ai ? "Ask Document" : "Close Sidebar")
            return try XCTUnwrap(elements.first { $0.label == label || $0.value == label },
                "The actual sidebar header must be mounted").frame
        }
        func findRow(in elements: [Element]) throws -> CGRect {
            let input = try XCTUnwrap(elements.first { $0.label == L("Find in document") })
            let close = try XCTUnwrap(elements.first { $0.label == L("Close Find") })
            // Find's count row is followed by a separate bottom status row with
            // the same text. Select its uppermost mounted occurrence.
            let count = try XCTUnwrap(elements.filter {
                $0.role == kAXStaticTextRole && ($0.value == state.searchCountText || $0.label == state.searchCountText)
            }.min { $0.frame.minY < $1.frame.minY })
            return input.frame.union(close.frame).union(count.frame)
        }

        try await settle()
        if hidden {
            // Expose the real window-button hover group without changing the
            // window's order or sending pointer input to another application.
            state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1
            try await settle()
            let initial = try elements(in: window)
            let initialHeader = try header(in: initial)
            let controls = try XCTUnwrap(initial.first { $0.identifier == "floating-window-controls" }).frame
            XCTAssertGreaterThan(controls.height, 0, "The actual window-control hover group must be exposed")
            XCTAssertGreaterThanOrEqual(initialHeader.minY, controls.maxY,
                "A hidden toolbar must retain space for its actual window controls")
            state.controlTopMargin = 200
            try await settle()
            let enlarged = try elements(in: window)
            let enlargedHeader = try header(in: enlarged)
            let enlargedControls = try XCTUnwrap(enlarged.first { $0.identifier == "floating-window-controls" }).frame
            XCTAssertEqual(enlargedHeader.minY, initialHeader.minY, accuracy: 1,
                "A hidden toolbar releases the user's clearance independently of its retained window-control footprint")
            XCTAssertGreaterThanOrEqual(enlargedHeader.minY, enlargedControls.maxY,
                "Releasing user clearance must keep sidebar headers below the actual window controls")
            return
        }
        let initial = try elements(in: window)
        let initialGap = try header(in: initial).minY - findRow(in: initial).maxY
        state.controlTopMargin = 200
        try await settle()
        let enlarged = try elements(in: window)
        let enlargedHeader = try header(in: enlarged)
        let enlargedRow = try findRow(in: enlarged)
        let enlargedGap = enlargedHeader.minY - enlargedRow.maxY
        XCTAssertGreaterThan(enlargedHeader.height, 0)
        XCTAssertGreaterThan(enlargedRow.height, 0)
        XCTAssertEqual(enlargedGap, initialGap, accuracy: 1,
            "Docked Find already clears floating controls; changing window-edge clearance must not add another gap before the sidebar header")
        XCTAssertGreaterThanOrEqual(enlargedGap, 0, "The sidebar header must remain below the actual Find row")

        state.showFind = false
        try await settle()
        let closed = try elements(in: window)
        let closedHeader = try header(in: closed)
        XCTAssertFalse(closed.contains { $0.label == L("Close Find") }, "Find must actually be unmounted")
        state.showFind = true
        try await settle()
        let reopened = try elements(in: window)
        let reopenedHeader = try header(in: reopened)
        let reopenedRow = try findRow(in: reopened)
        XCTAssertEqual(reopenedHeader.minY - reopenedRow.maxY, initialGap, accuracy: 1,
            "Opening Find at a large clearance must not reserve that clearance again inside the sidebar")
        XCTAssertEqual(reopenedHeader.minY, enlargedHeader.minY, accuracy: 1,
            "Closing and reopening Find must restore the same mounted geometry")
        // The visible Find row is the only new vertical content. Allow its
        // own control-height padding, measured from the mounted input rather
        // than repeating ReaderView's clearance constants.
        let inputHeight = try XCTUnwrap(reopened.first { $0.label == L("Find in document") }).frame.height
        XCTAssertGreaterThan(reopenedHeader.minY, closedHeader.minY)
        XCTAssertLessThanOrEqual(reopenedHeader.minY - closedHeader.minY,
            reopenedRow.height + inputHeight * 2,
            "Showing Find must add its row footprint, not another window-edge clearance")
    }

    private struct Element {
        let role: String
        let label: String?
        let value: String?
        let identifier: String?
        let frame: CGRect
    }

    private func elements(in window: NSWindow) throws -> [Element] {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
        let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
        func descendants(_ element: AXUIElement) -> [Element] {
            var position = CGPoint.zero, size = CGSize.zero
            if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &position)
            }
            if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
            }
            // Keep the public AX coordinate system: increasing y moves down.
            let item = Element(role: attribute(element, kAXRoleAttribute) as? String ?? "",
                label: attribute(element, kAXDescriptionAttribute) as? String ?? attribute(element, kAXTitleAttribute) as? String,
                value: attribute(element, kAXValueAttribute) as? String,
                identifier: attribute(element, kAXIdentifierAttribute) as? String,
                frame: CGRect(origin: position, size: size))
            return [item] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
        }
        return descendants(target)
    }
}
#endif
