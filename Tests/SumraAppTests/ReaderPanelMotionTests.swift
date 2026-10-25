#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor final class ReaderPanelMotionTests: XCTestCase {
    func testReducedMotionClosesSettingsSynchronouslyAndRevealsSelectionWithoutFade() {
        let parent = parentWindow()
        let settings = ReaderReadingSettingsPanel(contentRect: CGRect(x: 2100, y: 150, width: 430, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.contentView = NSView(); settings.attach(to: parent)
        settings.reveal(reducedMotion: true)
        XCTAssertEqual(settings.alphaValue, 1)
        settings.dismiss(reducedMotion: true)
        XCTAssertNil(settings.contentView)
        XCTAssertNil(settings.parent, "Reduced Motion must complete teardown in the calling turn")
        let selection = ReaderSelectionToolbar.Panel(contentRect: CGRect(x: 2100, y: 150, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        selection.isReleasedWhenClosed = false
        defer { selection.close(); parent.close() }
        selection.reveal(reducedMotion: true)
        selection.dismiss(reducedMotion: true)
        XCTAssertTrue(selection.ignoresMouseEvents)
        selection.reveal(reducedMotion: true)
        XCTAssertFalse(selection.ignoresMouseEvents)
        XCTAssertEqual(selection.alphaValue, 1)
        XCTAssertFalse(selection.isVisible)
        XCTAssertFalse(parent.isVisible)
    }

    private func parentWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testReadingSettingsReopenCancelsPendingClose() async throws {
        let parent = parentWindow()
        let panel = ReaderReadingSettingsPanel(contentRect: CGRect(x: 2100, y: 150, width: 430, height: 420),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = NSView()
        panel.contentView = content
        panel.attach(to: parent)
        defer { parent.close() }
        panel.alphaValue = 0
        panel.reveal()
        panel.close()
        XCTAssertTrue(panel.ignoresMouseEvents)
        // Reduced Motion closes synchronously, so reopening creates a new panel.
        if ReaderMotion.reducedMotion {
            XCTAssertNil(panel.contentView)
            XCTAssertNil(panel.parent)
        } else {
            panel.reveal()
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertTrue(panel.contentView === content, "An old fade completion must not tear down the reopened settings")
            XCTAssertTrue(panel.parent === parent)
            XCTAssertFalse(panel.ignoresMouseEvents)
            XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
        }
        XCTAssertFalse(parent.isVisible)
        XCTAssertFalse(panel.isVisible)
    }

    func testReadingSettingsParentCloseTearsDownDuringFade() async throws {
        let parent = parentWindow()
        let panel = ReaderReadingSettingsPanel(contentRect: CGRect(x: 2100, y: 150, width: 430, height: 420),
                                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView()
        panel.attach(to: parent)
        panel.reveal()
        panel.close()
        parent.close()
        XCTAssertNil(panel.contentView, "Parent close must release settings immediately, without waiting for animation")
        XCTAssertNil(panel.parent)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(panel.contentView)
        XCTAssertFalse(panel.isVisible)
    }

    func testSelectionFadeStopsHitTestingAndPreservesReaderResponder() async throws {
        let parent = parentWindow()
        let reader = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        reader.string = "A selected reading passage"
        parent.contentView = reader
        parent.makeFirstResponder(reader)
        reader.setSelectedRange(NSRange(location: 2, length: 8))
        let panel = ReaderSelectionToolbar.Panel(contentRect: CGRect(x: 2100, y: 150, width: 200, height: 40),
                                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        parent.addChildWindow(panel, ordered: .above)
        defer { parent.removeChildWindow(panel); panel.close(); parent.close() }
        panel.alphaValue = 0
        panel.reveal()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        panel.dismiss()
        XCTAssertTrue(panel.ignoresMouseEvents, "A fading toolbar must immediately let input reach the document")
        panel.reveal()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
        XCTAssertTrue(parent.firstResponder === reader)
        XCTAssertEqual(reader.selectedRange(), NSRange(location: 2, length: 8))
        XCTAssertFalse(parent.isVisible)
        XCTAssertFalse(panel.isVisible)
    }
}
#endif
