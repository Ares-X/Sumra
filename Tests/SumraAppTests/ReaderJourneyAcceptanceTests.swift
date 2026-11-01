#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class ReaderJourneyAcceptanceTests: XCTestCase {
    func testClosingNativeTabsToLastReaderKeepsHoverAcrossChromeModes() async throws {
        final class DocumentWindow: NSWindow {
            var receivesPointer = false
            var pointer = NSPoint.zero
            override var isKeyWindow: Bool { receivesPointer }
            override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        }
        _ = NSApplication.shared
        let states = (0..<3).map { index in
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-close-journey-\(index).txt"),
                content: .text("The surviving passage belongs to document \(index)."))
            state.immersiveControls = false
            state.toolbarDisplayMode = .auto
            return state
        }
        let windows = states.enumerated().map { index, state in
            let window = DocumentWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.toolbar = NSToolbar(identifier: "native-close-journey-\(index)")
            state.window = window
            return window
        }
        let guards = states.map { ReaderCloseGuard(state: $0, previous: nil) }
        for index in windows.indices { windows[index].delegate = guards[index] }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[0].addTabbedWindow(windows[2], ordered: .above)
        let group = try XCTUnwrap(windows[0].tabGroup)
        let observers = states.enumerated().map { index, state in
            let observer = ReaderToolbarWindow.Host()
            observer.state = state; observer.reducedMotion = true
            windows[index].contentView?.addSubview(observer)
            return observer
        }
        defer {
            for observer in observers { observer.detach() }
            for window in windows { window.delegate = nil; window.contentView = nil; window.close() }
            for state in states { state.windowClosed() }
        }

        let survivor = windows[0]
        group.selectedWindow = survivor
        observers[0].updateChrome()
        survivor.contentView?.superview?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(survivor.contentView)
        let nativeHeight = max(content.safeAreaInsets.top,
            content.bounds.maxY - content.convert(survivor.contentLayoutRect, from: nil).maxY)
        XCTAssertGreaterThan(nativeHeight, 48, "Start the journey over the actual native tab strip")
        survivor.pointer = NSPoint(x: 350, y: survivor.frame.height - nativeHeight + 5)

        // Continue the same journey past the existing 3 → 2 regression: the
        // second close removes the tab strip, then the last reader changes its
        // chrome mode while keeping its own pointer routing.
        for index in [2, 1] {
            survivor.receivesPointer = false
            group.selectedWindow = windows[index]
            let closed = expectation(description: "Close document \(index) through its approval owner")
            guards[index].close(windows[index]) { allowed in
                XCTAssertTrue(allowed)
                closed.fulfill()
            }
            await fulfillment(of: [closed], timeout: 2)
            let remaining = survivor.tabbedWindows ?? [survivor]
            XCTAssertFalse(remaining.contains { $0 === windows[index] })
            XCTAssertEqual(remaining.count, index)
            survivor.tabGroup?.selectedWindow = survivor
            survivor.receivesPointer = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: survivor)
            await Task.yield()
            observers[0].updateChrome()

            // The old tab-row position remains inside the current reveal strip
            // only while a tab row exists. Move into the actual top controls
            // before continuing after the group collapses to its final reader.
            if index == 2 {
                XCTAssertTrue(states[0].toolbarShown, "Closing a sibling under the pointer reveals the surviving tab row")
            }
            survivor.pointer = NSPoint(x: 350, y: survivor.frame.height - 20)
            for floating in [true, false] {
                states[0].immersiveControls = floating
                observers[0].updateChrome()
                let layout = survivor.contentLayoutRect
                for point in [NSPoint(x: 350, y: 100), survivor.pointer] {
                    let screen = survivor.convertPoint(toScreen: point)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: screen,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        eventNumber: 0, clickCount: 0, pressure: 0))
                    observers[0].handleMouseMoved(event)
                    observers[0].updateChrome()
                    XCTAssertEqual(states[0].toolbarShown, point == survivor.pointer)
                    XCTAssertEqual(survivor.contentLayoutRect, layout, "Hover must preserve the surviving reading viewport")
                    XCTAssertEqual(content.alphaValue, 1, "Chrome teardown must not hide the reading surface")
                }
            }
        }
        XCTAssertTrue((survivor.tabGroup?.selectedWindow ?? survivor) === survivor)
        XCTAssertEqual(survivor.tabbedWindows?.count ?? 1, 1)
        XCTAssertFalse(windows[1].isVisible)
        XCTAssertFalse(windows[2].isVisible)
    }
}
#endif
