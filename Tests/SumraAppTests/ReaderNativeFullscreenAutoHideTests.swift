#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

/// These fixtures use real AppKit chrome objects with a simulated fullscreen
/// mask. They verify ownership and lifecycle, not native fullscreen animation,
/// WindowServer pointer delivery, or real Space creation and cleanup.
@MainActor final class ReaderNativeFullscreenAutoHideTests: XCTestCase {
    func testFullscreenExitReturnsOpacityToWindowedHoverAndPreservesPageInputFocusMeaning() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.state.toolbarDisplayMode = .auto
        fixture.observer.pointerMoved(to: .init(x: 350, y: 100))
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertFalse(fixture.state.toolbarShown,
            "Go to Page must not use an unrevealed toolbar field")
        XCTAssertEqual(fixture.content.alphaValue, 0, accuracy: 0.001)

        let field = NSTextField(string: "1")
        field.frame = .init(x: 100, y: 100, width: 80, height: 24)
        fixture.parent.contentView?.addSubview(field)
        fixture.state.pageInputField = field
        fixture.state.count = 4
        fixture.observer.pointerMoved(to: .init(x: 350, y: fixture.parent.frame.height - 1))
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(fixture.state.toolbarShown)
        ReaderMenuCommand.goToPage.run(fixture.state)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(fixture.parent.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), .init(location: 0, length: 1))
        fixture.parent.makeFirstResponder(nil)
        fixture.observer.pointerMoved(to: .init(x: 350, y: 100))
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertFalse(fixture.state.toolbarShown)
        XCTAssertEqual(fixture.content.alphaValue, 0, accuracy: 0.001)

        // Post the observed exit notification after changing the actual mask
        // read by Host. The companion remains mounted for this ownership check.
        fixture.parent.fullscreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: fixture.parent)
        XCTAssertFalse(fixture.state.toolbarShown)
        XCTAssertEqual(fixture.content.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(fixture.companion.ignoresMouseEvents)
        fixture.observer.pointerMoved(to: .init(x: 350, y: fixture.parent.frame.height - 1))
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(fixture.state.toolbarShown)
        XCTAssertEqual(fixture.content.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(fixture.companion.ignoresMouseEvents)

        fixture.observer.pointerMoved(to: .init(x: 350, y: 100))
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertFalse(fixture.state.toolbarShown)
        XCTAssertEqual(fixture.content.alphaValue, 0, accuracy: 0.001)

        // Model AppKit returning its standard-button lookup to the parent.
        fixture.parent.companionClose = nil
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertEqual(fixture.content.alphaValue, 0.7, accuracy: 0.001)
        XCTAssertFalse(fixture.companion.ignoresMouseEvents)
        XCTAssertFalse(fixture.parent.isVisible, "The focus fixture never orders a real window onscreen")
    }

    func testChangingHiddenToAutoResamplesAStationaryWindowPointerAfterTheViewUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        // Drain the initial document attachment while this fixture is not key.
        await finishViewUpdate()
        fixture.parent.receivesPointer = true
        fixture.parent.pointer = .init(x: 350, y: fixture.parent.frame.height - 1)
        fixture.state.toolbarDisplayMode = .auto
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertFalse(fixture.state.toolbarHoverVisible, "Mode selection first clears the old hover")
        await finishViewUpdate()
        XCTAssertTrue(fixture.state.toolbarHoverVisible,
            "The mode update must sample the stationary window pointer without a mouse callback")
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(fixture.state.toolbarShown)
        XCTAssertEqual(fixture.content.alphaValue, 1, accuracy: 0.001)

        fixture.parent.pointer = .init(x: 350, y: 100)
        fixture.state.toolbarDisplayMode = .hidden
        fixture.observer.updateChrome(revealingNativeControls: false)
        await finishViewUpdate()
        fixture.state.toolbarDisplayMode = .auto
        fixture.observer.updateChrome(revealingNativeControls: false)
        await finishViewUpdate()
        fixture.observer.updateChrome(revealingNativeControls: false)
        XCTAssertFalse(fixture.state.toolbarHoverVisible)
        XCTAssertEqual(fixture.state.toolbarHoverOpacity, 0)
        XCTAssertEqual(fixture.content.alphaValue, 0, accuracy: 0.001)
        XCTAssertFalse(fixture.companion.isOpaque)
        XCTAssertTrue(fixture.companion.ignoresMouseEvents)
        XCTAssertFalse(fixture.parent.isVisible, "The simulated key-window accessor never activates the desktop")
    }

    private func finishViewUpdate() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class FullscreenWindow: NSWindow {
        var fullscreen = false
        var companionClose: NSButton?
        var receivesPointer = false
        var pointer = NSPoint(x: 350, y: 100)
        override var isKeyWindow: Bool { receivesPointer }
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        override var styleMask: NSWindow.StyleMask {
            get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
            set { super.styleMask = newValue.subtracting(.fullScreen) }
        }
        override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
            type == .closeButton ? companionClose ?? super.standardWindowButton(type) : super.standardWindowButton(type)
        }
        // requestPageInput selects a native field without activating the user's
        // desktop. This fixture does not claim real fullscreen focus delivery.
        override func makeKeyAndOrderFront(_ sender: Any?) {}
    }

    @MainActor private final class Fixture {
        let state = ReaderState(recordsHistory: false)
        let parent: FullscreenWindow
        let companion: NSWindow
        let content: NSView
        let tools = NSView(frame: .init(x: 100, y: 0, width: 500, height: 38))
        let tabs = NSTitlebarAccessoryViewController()
        let toolbar = NSToolbar(identifier: "native-fullscreen-auto-" + UUID().uuidString)
        let observer = ReaderToolbarWindow.Host()

        init() throws {
            _ = NSApplication.shared
            parent = FullscreenWindow(contentRect: .init(x: 2200, y: 100, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            companion = NSWindow(contentRect: .init(x: 2200, y: 600, width: 700, height: 70),
                styleMask: .borderless, backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; companion.isReleasedWhenClosed = false
            parent.alphaValue = 0; parent.ignoresMouseEvents = true; companion.alphaValue = 0
            companion.backgroundColor = .white; companion.isOpaque = true
            content = try XCTUnwrap(companion.contentView)
            content.alphaValue = 0.7
            parent.addChildWindow(companion, ordered: .above)
            tools.setAccessibilityRole(.toolbar)
            tools.addSubview(NSButton(title: "Reader action", target: nil, action: nil))
            content.addSubview(tools)
            let close = try XCTUnwrap(NSWindow.standardWindowButton(.closeButton, for: parent.styleMask))
            content.addSubview(close); parent.companionClose = close
            parent.toolbar = toolbar
            tabs.view = NSView(frame: .init(x: 0, y: 38, width: 700, height: 25))
            parent.addTitlebarAccessoryViewController(tabs)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-fullscreen-auto.txt"), content: .text("Book"))
            state.immersiveControls = false; state.toolbarDisplayMode = .hidden; state.window = parent
            parent.fullscreen = true
            observer.state = state; observer.reducedMotion = true
            parent.contentView?.addSubview(observer)
        }

        func close() {
            observer.detach(); parent.fullscreen = false; parent.companionClose = nil
            parent.makeFirstResponder(nil)
            companion.parent?.removeChildWindow(companion)
            parent.contentView = nil; companion.close(); parent.close(); state.windowClosed()
        }
    }
}
#endif
