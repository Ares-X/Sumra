#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class NativeReaderCloseCommandTests: XCTestCase {
    private final class FullscreenWindow: NSWindow {
        override var styleMask: NSWindow.StyleMask {
            get { super.styleMask.union(.fullScreen) }
            set { super.styleMask = newValue.subtracting(.fullScreen) }
        }
    }

    private final class Approval: NSObject, NSWindowDelegate {
        var requests = 0
        var allowed = false
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            requests += 1
            return allowed
        }
    }

    func testFullscreenCloseCommandUsesDocumentApprovalWhenNativeButtonIsUnavailable() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let window = FullscreenWindow(contentRect: NSRect(x: 2200, y: 100, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let approval = Approval()
        let owner = ReaderCloseGuard(state: state, previous: approval)
        window.delegate = owner
        state.window = window
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        button.isHidden = true
        button.isEnabled = false
        defer {
            window.delegate = nil
            state.windowClosed()
            window.close()
        }

        // Fullscreen moves native controls out of the reader's normal titlebar.
        // Their current enabled state must not suppress the document command.
        XCTAssertTrue(ReaderMenuCommand.close.enabled(state))
        ReaderMenuCommand.close.run(state)
        let deadline = Date().addingTimeInterval(2)
        while approval.requests == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(approval.requests, 1, "Close must reach the document owner even when the native fullscreen control is unavailable")
        XCTAssertTrue(state.window === window, "The original window delegate must retain its close veto")
    }

    func testCloseCommandRejectsWindowWithoutCloseCapability() {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let window = NSWindow(contentRect: NSRect(x: 2200, y: 100, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.window = window
        defer { state.windowClosed(); window.close() }
        XCTAssertFalse(ReaderMenuCommand.close.enabled(state))
    }

    func testCloseAvailabilityUsesAuxiliaryWindowCapabilitiesAndRejectsAnAttachedSheet() throws {
        _ = NSApplication.shared
        let window = FullscreenWindow(contentRect: NSRect(x: 2200, y: 100, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 2200, y: 100, width: 200, height: 100),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        let native = try XCTUnwrap(window.standardWindowButton(.closeButton))
        native.isHidden = true
        native.isEnabled = false
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet) }
            sheet.close()
            window.close()
        }
        XCTAssertTrue(ReaderMenuCommand.close.enabled(nil, window: window),
            "Auxiliary windows have no focused reader; native button availability is still independent of Close")
        window.beginSheet(sheet)
        XCTAssertFalse(ReaderMenuCommand.close.enabled(nil, window: window),
            "Closing the parent must not bypass its active sheet")
    }
}
#endif
