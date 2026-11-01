#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderFloatingLateTitlebarTests: XCTestCase {
    private final class CloseApproval: NSObject, NSWindowDelegate {
        var requests = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
    }

    private final class FactoryLookupWindow: NSWindow {
        weak var floatingButtons: ReaderFloatingWindowButtons.Buttons?
        override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
            if let button = floatingButtons?.subviews.compactMap({ $0 as? NSButton })
                .first(where: { $0.tag == Int(type.rawValue) }) { return button }
            return super.standardWindowButton(type)
        }
        func nativeButton(_ type: NSWindow.ButtonType) -> NSButton? { super.standardWindowButton(type) }
    }

    func testFloatingControlsMountedBeforeChromeHostHideNativeTitlebarAndRestoreItOnExit() throws {
        _ = NSApplication.shared
        let window = FactoryLookupWindow(contentRect: NSRect(x: 2200, y: 100, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let approval = CloseApproval()
        window.delegate = approval
        let content = try XCTUnwrap(window.contentView)
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let native = try types.map { try XCTUnwrap(window.nativeButton($0)) }
        let nativeContainer = try XCTUnwrap(native[0].superview)
        XCTAssertFalse(nativeContainer.isDescendant(of: content))
        XCTAssertTrue(native.allSatisfy { $0.window === window && !$0.isHiddenOrHasHiddenAncestor })
        let originalAlpha = nativeContainer.alphaValue
        let floating = ReaderFloatingWindowButtons.Buttons(frame: NSRect(x: 16, y: 430, width: 54, height: 20))
        content.addSubview(floating)
        window.floatingButtons = floating
        let factory = floating.subviews.compactMap { $0 as? NSButton }
        for (index, type) in types.enumerated() {
            let button = factory[index]
            XCTAssertTrue(window.standardWindowButton(type) === button,
                "The new tab must expose its mounted factory before the chrome host attaches")
            XCTAssertEqual(button.action, native[index].action,
                "Native control identity comes from AppKit's action, including titlebars without an AX subrole")
        }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/floating-new-tab.txt"), content: .text("Book"))
        state.immersiveControls = true; state.toolbarDisplayMode = .shown; state.window = window
        let observer = ReaderToolbarWindow.Host(frame: content.bounds)
        observer.state = state; observer.reducedMotion = true
        content.addSubview(observer)
        defer {
            observer.detach(); window.floatingButtons = nil; floating.removeFromSuperview()
            window.delegate = nil; window.contentView = nil; window.close(); state.windowClosed()
        }
        let frame = window.frame
        for reveal in [false, true, false] {
            observer.updateChrome(revealingNativeControls: reveal)
            XCTAssertTrue(native.allSatisfy { $0.isHiddenOrHasHiddenAncestor },
                "Floating reading controls must own the only visible traffic lights after a new tab mounts")
            XCTAssertTrue(factory.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue == 1 && $0.isEnabled },
                "Discovering the original titlebar must preserve the mounted floating controls")
            XCTAssertEqual(window.frame, frame)
        }
        window.performClose(nil)
        XCTAssertEqual(approval.requests, 1,
            "Hiding the original titlebar container must preserve the native close command and document veto")
        state.immersiveControls = false
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(native.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(nativeContainer.alphaValue, originalAlpha)
        state.immersiveControls = true
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(native.allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        observer.detach()
        XCTAssertTrue(native.allSatisfy { !$0.isHiddenOrHasHiddenAncestor },
            "Removing the reader host must restore AppKit's actual controls even while lookup returns the factory")
        XCTAssertEqual(nativeContainer.alphaValue, originalAlpha)
        XCTAssertTrue(factory.allSatisfy { $0.alphaValue == 1 && $0.isEnabled })
    }
}
#endif
