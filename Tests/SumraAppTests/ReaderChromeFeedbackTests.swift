#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor final class ReaderChromeFeedbackTests: XCTestCase {
    func testFullscreenCreatedNativeTabKeepsAppKitButtonOpacityAfterExit() throws {
        final class TabWindow: NSWindow {
            var fullscreen = true
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
        }
        _ = NSApplication.shared
        let window = TabWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try XCTUnwrap(window.standardWindowButton($0))
        }
        // A new tab first mounts while AppKit's fullscreen controls are hidden.
        // These remain the same native buttons when AppKit restores the window.
        for button in buttons { button.alphaValue = 0 }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/fullscreen-batch-tab.txt"), content: .text("Book"))
        state.immersiveControls = false; state.toolbarDisplayMode = .shown; state.window = window
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer {
            observer.detach(); window.fullscreen = false
            window.contentView = nil; window.close(); state.windowClosed()
        }
        window.fullscreen = false
        // Model the platform restoring its own opacity on fullscreen exit.
        // The chrome owner must not put its initial fullscreen snapshot back.
        for button in buttons { button.alphaValue = 1 }
        observer.updateChrome(revealingNativeControls: false)
        for button in buttons {
            XCTAssertEqual(button.alphaValue, 1, "A tab created fullscreen must keep AppKit's restored windowed controls")
            XCTAssertFalse(button.isHidden)
        }
        for button in buttons { button.alphaValue = 0.5 }
        observer.detach()
        XCTAssertTrue(buttons.allSatisfy { $0.alphaValue == 0.5 },
            "Teardown must not restore opacity this owner never changed")
    }

    func testFullscreenCreatedTabDoesNotTransferNativeZeroAlphaToFloatingButtonsOnExit() throws {
        final class TabWindow: NSWindow {
            var fullscreen = false
            var lookedUpButtons: [NSWindow.ButtonType: NSButton] = [:]
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
            override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
                lookedUpButtons[type] ?? super.standardWindowButton(type)
            }
        }
        _ = NSApplication.shared
        // Model the observed control-identity handoff on one window. A real
        // fullscreen tab group owns additional AppKit Space state; the full
        // new-tab-in-fullscreen flow is exercised by application UAT.
        let created = TabWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        created.fullscreen = true
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            let native = try XCTUnwrap(created.standardWindowButton(type))
            native.alphaValue = 0
            created.lookedUpButtons[type] = native
        }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/fullscreen-created-tab.txt"), content: .text("Book"))
        state.immersiveControls = true; state.toolbarDisplayMode = .shown; state.window = created
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        created.contentView?.addSubview(observer)
        let controls = ReaderFloatingWindowButtons.Buttons(frame: CGRect(x: 16, y: 16, width: 54, height: 20))
        created.contentView?.addSubview(controls)
        defer {
            observer.detach(); controls.removeFromSuperview()
            created.lookedUpButtons.removeAll(); created.fullscreen = false
            created.contentView = nil; created.close(); state.windowClosed()
        }
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        for button in buttons {
            created.lookedUpButtons[NSWindow.ButtonType(rawValue: UInt(button.tag))!] = button
        }
        // On the reported fullscreen-created tab AppKit's standard lookup
        // changes from native controls with alpha zero to the mounted factory.
        observer.updateChrome(revealingNativeControls: false)
        created.fullscreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: created)
        controls.updateButtons()
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertEqual(buttons.count, 3)
        for button in buttons {
            XCTAssertTrue(button.isEnabled, "The new tab's controls remain available after leaving fullscreen")
            XCTAssertEqual(button.alphaValue, 1, "A native control's captured alpha must never be applied to its factory replacement")
            XCTAssertTrue(button.target === created)
        }
        observer.detach()
        XCTAssertTrue(buttons.allSatisfy { $0.alphaValue == 1 && $0.isEnabled },
            "Native teardown must restore the captured controls instead of changing later lookup results")
    }

    func testAlwaysHiddenNormalToolbarRevealsOnlyNativeWindowButtons() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/hidden-toolbar.txt"), content: .text("Book"))
        state.immersiveControls = false
        state.toolbarDisplayMode = .hidden
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = window.frame
        XCTAssertTrue(close.isHidden)
        for depth: CGFloat in [20, 40, 20, 80] {
            observer.pointerMoved(to: NSPoint(x: 30, y: frame.height - depth))
            observer.updateChrome(revealingNativeControls: false)
            XCTAssertFalse(close.isHidden, "Always Hide must still expose native close/minimize/fullscreen controls")
            XCTAssertFalse(state.toolbarShown, "Window-control hover must never reveal the hidden toolbar")
            XCTAssertEqual(window.frame, frame)
        }
        observer.pointerMoved(to: NSPoint(x: 200, y: frame.height - 150))
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(close.isHidden)
        XCTAssertFalse(state.toolbarShown)
    }

    func testNormalProgressLabelsAndTrackAreCenteredAsAGroup() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "progressDisplayMode")
        defaults.set(ReaderToolbarDisplayMode.shown.rawValue, forKey: "progressDisplayMode")
        defer {
            if let previous { defaults.set(previous, forKey: "progressDisplayMode") }
            else { defaults.removeObject(forKey: "progressDisplayMode") }
        }
        for count in [12, 99_999] {
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/progress.txt"), content: .text("Book"))
            state.count = count
            state.theme = "light"
            let host = NSHostingView(rootView: ReaderProgressFooter(state: state).background(Color.white))
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 1000, height: 26),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { state.windowClosed(); window.contentView = nil; window.close() }
            state.page = count - 1  // both visible labels fill their allocated widths
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            func hasTextInk(_ x: Int) -> Bool {
                (0..<bitmap.pixelsHigh).contains { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return max(color.redComponent, color.greenComponent, color.blueComponent) < 0.6
                }
            }
            let first = try XCTUnwrap((0..<bitmap.pixelsWide).first(where: hasTextInk))
            let last = try XCTUnwrap((0..<bitmap.pixelsWide).last(where: hasTextInk))
            XCTAssertEqual(first, bitmap.pixelsWide - last - 1, accuracy: 4,
                "Center the visible percentage, track, and position together, including long line counts")
        }
    }

    func testHTMLPageCounterSeeksInsideItsCurrentFile() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("chapter.html")
        try "<html><body>Book</body></html>".write(to: input, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .browser(try MarkupSource(input)))
        state.count = 5; state.page = 2
        state.browserPage = 3; state.browserPageCount = 12; state.browserProgress = 0.3
        defer { state.windowClosed() }
        let progress = state.readingProgress
        XCTAssertEqual(progress.label(), "\(L("Page:")) 4 / 12")
        XCTAssertEqual(progress.action(at: 1), .progress(1), "Seeking an HTML page must not switch document files")
    }
}
#endif
