#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

/// Exercises native companion ownership and accessory layout.
/// These fixtures do not enter a fullscreen Space or prove transition-frame
/// rendering, system snapshots, or the original reporter's T2 video resolved.
@MainActor final class ReaderFirstCompanionOwnershipTests: XCTestCase {
    func testFloatingChromeCollapsesNativeAccessoryAndRestoresItsExistingHiddenChoice() throws {
        _ = NSApplication.shared
        for initiallyHidden in [false, true] {
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/floating-accessory-layout.txt"), content: .text("Book"))
            state.immersiveControls = false; state.toolbarDisplayMode = .shown
            let window = NSWindow(contentRect: .init(x: 2200, y: 100, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            state.window = window
            let reader = try XCTUnwrap(window.contentView)
            let frameView = try XCTUnwrap(reader.superview)
            frameView.layoutSubtreeIfNeeded()
            let withoutAccessory = window.contentLayoutRect
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .bottom
            accessory.automaticallyAdjustsSize = false
            let accessoryView = NSView(frame: .init(x: 0, y: 0, width: 700, height: 28))
            accessory.view = accessoryView
            window.addTitlebarAccessoryViewController(accessory)
            accessory.isHidden = initiallyHidden
            let observer = ReaderToolbarWindow.Host()
            observer.state = state; observer.reducedMotion = true
            reader.addSubview(observer)
            defer {
                observer.detach(); window.contentView = nil; window.close(); state.windowClosed()
            }
            frameView.layoutSubtreeIfNeeded()
            let nativeLayout = window.contentLayoutRect
            let windowFrame = window.frame, readerFrame = reader.frame
            if !initiallyHidden {
                XCTAssertLessThan(nativeLayout.maxY, withoutAccessory.maxY,
                    "The real native accessory must reserve height before floating chrome replaces it")
            }

            state.immersiveControls = true
            observer.updateChrome(revealingNativeControls: false)
            frameView.layoutSubtreeIfNeeded()
            XCTAssertTrue(accessory.isHidden)
            XCTAssertEqual(window.contentLayoutRect.maxY, withoutAccessory.maxY, accuracy: 0.001,
                "Floating chrome collapses the native accessory's reserved height to zero")
            XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { $0 === accessory })
            XCTAssertTrue(accessory.view === accessoryView)
            XCTAssertTrue(accessoryView.window === window,
                "A collapsed accessory stays mounted and remains an available companion-discovery anchor")
            XCTAssertEqual(window.frame, windowFrame)
            XCTAssertEqual(reader.frame, readerFrame, "Changing native chrome must not resize the reading surface")

            state.immersiveControls = false
            observer.updateChrome(revealingNativeControls: false)
            frameView.layoutSubtreeIfNeeded()
            XCTAssertEqual(accessory.isHidden, initiallyHidden,
                "Returning to native chrome restores the user's existing accessory choice")
            XCTAssertEqual(window.contentLayoutRect, nativeLayout)
            XCTAssertEqual(window.frame, windowFrame)
            XCTAssertEqual(reader.frame, readerFrame)

            // Normal Auto keeps the native layout installed while its views
            // fade; collapsing custom chrome must not change that contract.
            state.toolbarDisplayMode = .auto
            observer.pointerMoved(to: .init(x: 350, y: 100))
            observer.updateChrome(revealingNativeControls: false)
            frameView.layoutSubtreeIfNeeded()
            XCTAssertEqual(accessory.isHidden, initiallyHidden)
            XCTAssertEqual(window.contentLayoutRect, nativeLayout)

            state.immersiveControls = true
            observer.updateChrome(revealingNativeControls: false)
            XCTAssertTrue(accessory.isHidden)
            observer.detach()
            frameView.layoutSubtreeIfNeeded()
            XCTAssertEqual(accessory.isHidden, initiallyHidden, "Releasing the chrome owner restores the original choice")
            XCTAssertTrue(accessoryView.window === window)
            XCTAssertEqual(window.contentLayoutRect, nativeLayout)
            XCTAssertEqual(window.frame, windowFrame)
            XCTAssertEqual(reader.frame, readerFrame)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testFirstUpdateFollowsCapturedNativeButtonWhenItsOldContainerStaysInParent() throws {
        final class FactoryLookupWindow: NSWindow {
            var factoryClose: NSButton?
            override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
                type == .closeButton ? factoryClose ?? super.standardWindowButton(type) : super.standardWindowButton(type)
            }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/first-companion-button-migration.txt"), content: .text("Book"))
        state.immersiveControls = true; state.toolbarDisplayMode = .shown
        let parent = FactoryLookupWindow(contentRect: .init(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.alphaValue = 0; parent.ignoresMouseEvents = true
        let reader = try XCTUnwrap(parent.contentView)
        let nativeClose = try XCTUnwrap(parent.standardWindowButton(.closeButton))
        let oldContainer = try XCTUnwrap(nativeClose.superview)
        let nativeFrame = nativeClose.frame
        let controls = ReaderFloatingWindowButtons.Buttons(frame: .init(x: 16, y: 16, width: 54, height: 20))
        reader.addSubview(controls)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        reader.addSubview(observer)
        let companion = NSWindow(contentRect: .init(x: 2200, y: 600, width: 700, height: 70),
            styleMask: .borderless, backing: .buffered, defer: false)
        companion.isReleasedWhenClosed = false; companion.alphaValue = 0
        companion.backgroundColor = .white; companion.isOpaque = true; companion.hasShadow = true
        let content = try XCTUnwrap(companion.contentView)
        parent.addChildWindow(companion, ordered: .above)
        defer {
            observer.detach(); controls.stopObservingWindow(); controls.removeFromSuperview()
            parent.factoryClose = nil
            oldContainer.addSubview(nativeClose); nativeClose.frame = nativeFrame
            parent.removeChildWindow(companion); companion.close()
            parent.contentView = nil; parent.close(); state.windowClosed()
        }
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(oldContainer.isHidden,
            "Start with the actual native container already captured and hidden by floating chrome")
        parent.factoryClose = try XCTUnwrap(controls.subviews.compactMap { $0 as? NSButton }.first {
            $0.tag == Int(NSWindow.ButtonType.closeButton.rawValue)
        })

        // Only the button migrates. Its previously captured container is still
        // in the parent when Host first has to discover the new companion.
        content.addSubview(nativeClose)
        XCTAssertTrue(oldContainer.window === parent)
        XCTAssertTrue(nativeClose.window === companion)
        XCTAssertTrue(parent.standardWindowButton(.closeButton)?.superview === controls)
        XCTAssertEqual(content.alphaValue, 1, accuracy: 0.001)
        XCTAssertTrue(companion.isOpaque)

        observer.updateChrome(revealingNativeControls: false)
        XCTAssertEqual(content.alphaValue, 0, accuracy: 0.001,
            "The first update must hide the newly discovered native companion")
        XCTAssertFalse(companion.isOpaque)
        XCTAssertEqual(companion.backgroundColor.alphaComponent, 0)
        XCTAssertFalse(companion.hasShadow)
        XCTAssertTrue(companion.ignoresMouseEvents)
        XCTAssertEqual(reader.alphaValue, 1)
        XCTAssertFalse(controls.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(parent.factoryClose?.isEnabled == true)
        XCTAssertTrue(parent.factoryClose?.target === parent)
    }
}
#endif
