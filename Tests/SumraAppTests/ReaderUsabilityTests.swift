#if os(macOS)
import XCTest
import AppKit
@testable import Sumra

@MainActor final class ReaderUsabilityTests: XCTestCase {
    func testSelectionActionsFollowCurrentDocumentCapabilities() {
        let state = ReaderState(recordsHistory: false)
        XCTAssertTrue(ReaderSelectionToolbar.actions(for: state).isEmpty)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/selection.txt"), content: .text("Selected paragraph"))
        state.selectedText = "Selected"
        XCTAssertEqual(ReaderSelectionToolbar.actions(for: state), [.copy, .speakSelection, .translateGoogle])
        state.selectedText = ""
        XCTAssertTrue(ReaderSelectionToolbar.actions(for: state).isEmpty)
    }

    func testSelectionToolbarAnchorsToVisibleSelectionAndAvoidsClipping() throws {
        let visible = CGRect(x: 100, y: 100, width: 800, height: 600)
        let size = CGSize(width: 280, height: 34)
        let middle = try XCTUnwrap(ReaderSelectionToolbar.frame(selection: CGRect(x: 400, y: 300, width: 120, height: 20), visible: visible, size: size))
        XCTAssertEqual(middle.midX, 460)
        XCTAssertGreaterThan(middle.minY, 320)
        let top = try XCTUnwrap(ReaderSelectionToolbar.frame(selection: CGRect(x: 870, y: 680, width: 100, height: 30), visible: visible, size: size))
        XCTAssertLessThan(top.maxY, 680)
        XCTAssertLessThanOrEqual(top.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(top.minX, visible.minX)
        XCTAssertNil(ReaderSelectionToolbar.frame(selection: CGRect(x: 200, y: 800, width: 80, height: 20), visible: visible, size: size))
    }

    func testSelectionPanelCannotBecomeKeyOrMain() {
        _ = NSApplication.shared
        let panel = ReaderSelectionToolbar.Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isVisible)
    }

    func testNavigationPreferencesAreExportableBooleans() {
        XCTAssertTrue(ReaderPreferences.booleans.contains("preservePageTurnPosition"))
        XCTAssertTrue(ReaderPreferences.booleans.contains("keepZoomOnLinks"))
    }
}
#endif
