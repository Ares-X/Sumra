#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ColdStartToolbarTests: XCTestCase {
    func testHomeAsyncOpenReconcilesStationaryPointerWithoutAnotherKeyOrMouseEvent() async throws {
        final class StationaryWindow: NSWindow {
            var pointerDepth: CGFloat = 34
            override var isKeyWindow: Bool { true }
            override var isMainWindow: Bool { true }
            override var mouseLocationOutsideOfEventStream: NSPoint {
                NSPoint(x: frame.width / 2, y: frame.height - pointerDepth)
            }
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["immersiveControls", "toolbarDisplayMode", "disableHistory", "disableReadingState", "disableTabs", "showContentsOnOpen"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let capture = ScreenshotHotkey.capture
        defaults.set(true, forKey: "immersiveControls")
        defaults.set("auto", forKey: "toolbarDisplayMode")
        defaults.set(true, forKey: "disableHistory")
        defaults.set(true, forKey: "disableReadingState")
        defaults.set(true, forKey: "disableTabs")
        defaults.set(false, forKey: "showContentsOnOpen")
        defer {
            ScreenshotHotkey.capture = capture
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("stationary-open.fb2")
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section><p>A stationary pointer must reveal the newly loaded book controls.</p></section></body></FictionBook>".write(to: input, atomically: true, encoding: .utf8)
        for depth in [CGFloat(34), CGFloat(200)] {
            let application = ReaderApplicationDelegate()
            let window = StationaryWindow(contentRect: CGRect(x: 2200, y: 100, width: 800, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.pointerDepth = depth
            let controller = NSHostingController(rootView: ReaderWindow(payload: .constant(WindowPayload()), application: application))
            window.contentViewController = controller
            defer {
                (window.delegate as? ReaderCloseGuard)?.state?.windowClosed()
                window.contentViewController = nil
                window.close()
                withExtendedLifetime(application) {}
            }
            let mounted = Date().addingTimeInterval(3)
            while window.delegate as? ReaderCloseGuard == nil, Date() < mounted {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let state = try XCTUnwrap((window.delegate as? ReaderCloseGuard)?.state)
            XCTAssertNil(state.document)
            XCTAssertFalse(state.toolbarShown)
            XCTAssertTrue(state.immersiveControls)
            XCTAssertEqual(state.toolbarDisplayMode, .auto)
            // The same key window changes from Home to a loaded book. No
            // mouse-moved event or key notification occurs after this point.
            state.openWithoutHistory(input)
            let opened = Date().addingTimeInterval(10)
            repeat {
                controller.view.layoutSubtreeIfNeeded()
                if !state.busy, state.document != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < opened
            for _ in 0..<70 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(state.error)
            XCTAssertEqual(state.document?.url, input)
            XCTAssertTrue(state.usesFloatingChrome)
            XCTAssertEqual(state.toolbarShown, depth == 34,
                "Home-to-book opening must sample the stationary pointer at depth \(depth) without another input event")
            XCTAssertFalse(window.isVisible)
        }
        withExtendedLifetime(directory) {}
    }

    func testPersistedFloatingAutoHideSurvivesReaderWindowColdMountAndAsyncOpen() async throws {
        final class ColdWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var isMainWindow: Bool { true }
            var mouseAcceptanceWrites: [Bool] = []
            override var acceptsMouseMovedEvents: Bool {
                get { super.acceptsMouseMovedEvents }
                set { mouseAcceptanceWrites.append(newValue); super.acceptsMouseMovedEvents = newValue }
            }
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["immersiveControls", "toolbarDisplayMode", "disableHistory", "disableReadingState", "disableTabs", "showContentsOnOpen"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let capture = ScreenshotHotkey.capture
        defaults.set(true, forKey: "immersiveControls")
        defaults.set("auto", forKey: "toolbarDisplayMode")
        defaults.set(true, forKey: "disableHistory")
        defaults.set(true, forKey: "disableReadingState")
        defaults.set(true, forKey: "disableTabs")
        defaults.set(false, forKey: "showContentsOnOpen")
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("cold-start.fb2")
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section><title><p>Cold start</p></title><p>Reader chrome must receive pointer events after asynchronous opening.</p></section></body></FictionBook>".write(to: input, atomically: true, encoding: .utf8)
        let application = ReaderApplicationDelegate()
        let window = ColdWindow(contentRect: CGRect(x: 2200, y: 100, width: 800, height: 700),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = false
        let payload = WindowPayload(path: input.path, recordsHistory: false)
        let controller = NSHostingController(rootView: ReaderWindow(payload: .constant(payload), application: application))
        window.contentViewController = controller
        defer {
            (window.delegate as? ReaderCloseGuard)?.state?.windowClosed()
            window.contentViewController = nil
            window.close()
            ScreenshotHotkey.capture = capture
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime((directory, application)) {}
        }
        func hosts(in view: NSView) -> [ReaderToolbarWindow.Host] {
            (view as? ReaderToolbarWindow.Host).map { [$0] } ?? view.subviews.flatMap { hosts(in: $0) }
        }
        var mounted: [(Int, Bool)] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            controller.view.layoutSubtreeIfNeeded()
            let count = hosts(in: controller.view).filter { $0.window === window }.count
            if mounted.last?.0 != count || mounted.last?.1 != window.acceptsMouseMovedEvents {
                mounted.append((count, window.acceptsMouseMovedEvents))
            }
            if let state = (window.delegate as? ReaderCloseGuard)?.state, !state.busy, state.document != nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        let state = try XCTUnwrap((window.delegate as? ReaderCloseGuard)?.state)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.document?.url, input)
        XCTAssertTrue(state.usesFloatingChrome)
        XCTAssertEqual(state.toolbarDisplayMode, .auto)
        // Let native toolbar installation and any superseded representable
        // dismantle finish before checking the surviving event owner.
        for _ in 0..<30 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let live = hosts(in: controller.view).filter { $0.window === window }
        print("COLD_TOOLBAR hosts=\(live.count) accepts=\(window.acceptsMouseMovedEvents) writes=\(window.mouseAcceptanceWrites) mount=\(mounted)")
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(window.acceptsMouseMovedEvents, "Cold-mounted Auto Hide needs real mouse-moved delivery")
        let owner = try XCTUnwrap(live.first)
        for depth in [200.0, 34.0, 200.0] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                location: NSPoint(x: window.frame.width / 2, y: window.frame.height - depth),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            owner.handleMouseMoved(event)
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(state.toolbarShown, depth == 34, "Pointer depth: \(depth)")
        }
        XCTAssertFalse(window.isVisible, "The cold-mount check must not show a window")
    }
}
#endif
