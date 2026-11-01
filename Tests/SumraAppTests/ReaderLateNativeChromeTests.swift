#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderLateNativeChromeTests: XCTestCase {
    private final class LateButtonWindow: NSWindow {
        var exposesNativeButtons = false
        var dragEvents: [NSEvent] = []
        override var isKeyWindow: Bool { true }
        override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
            exposesNativeButtons ? super.standardWindowButton(type) : nil
        }
        func mountedButton(_ type: NSWindow.ButtonType) -> NSButton? { super.standardWindowButton(type) }
        override func performDrag(with event: NSEvent) { dragEvents.append(event) }
    }

    func testLateMountedNativeButtonsFollowAutoVisibilityAndKeepTitlebarInput() throws {
        _ = NSApplication.shared
        let previousCursor = NSCursor.current
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/late-native-chrome.txt"), content: .text("Selectable body"))
        state.immersiveControls = false; state.toolbarDisplayMode = .auto
        let window = LateButtonWindow(contentRect: NSRect(x: 2200, y: 100, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "late-native-chrome")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let text = NSTextView(frame: content.bounds)
        text.string = "Selectable body"; text.isEditable = false; text.isSelectable = true
        text.autoresizingMask = [.width, .height]
        content.addSubview(text); window.contentView = content
        let observer = ReaderToolbarWindow.Host(frame: content.bounds)
        observer.state = state; observer.reducedMotion = true
        observer.autoresizingMask = [.width, .height]
        content.addSubview(observer)
        state.window = window
        defer {
            observer.detach(); window.contentView = nil; window.close()
            state.windowClosed(); previousCursor.set()
        }
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try XCTUnwrap(window.mountedButton($0))
        }
        XCTAssertTrue(buttons.allSatisfy { $0.window === window }, "The delayed lookup must expose real mounted native controls")
        XCTAssertNil(window.standardWindowButton(.closeButton))
        window.exposesNativeButtons = true
        let originalFrame = window.frame
        let root = try XCTUnwrap(content.superview)
        let titlebar = try XCTUnwrap(buttons[0].superview)
        let filename = NSTextField(labelWithString: "Reading.txt")
        filename.frame = NSRect(x: 350, y: 5, width: 180, height: 22)
        titlebar.addSubview(filename)
        let blank = titlebar.convert(NSPoint(x: 240, y: titlebar.bounds.midY), to: nil)
        let body = NSPoint(x: 240, y: 180)
        func down(at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        observer.pointerMoved(to: body)
        observer.updateChrome(revealingNativeControls: false)
        root.layoutSubtreeIfNeeded()
        for button in buttons {
            XCTAssertTrue(button.isHiddenOrHasHiddenAncestor, "Late native buttons must hide over reading content in Auto")
        }
        let top = NSPoint(x: 240, y: window.frame.height - 10)
        let hit = try XCTUnwrap(root.hitTest(root.convert(top, from: nil)))
        XCTAssertTrue(hit === observer, "The hidden native title band must stop text selection after late control installation")
        XCTAssertTrue(hit.mouseDownCanMoveWindow)
        XCTAssertFalse(observer.handleMouseDown(try down(at: body)), "The reading body must retain its input")

        for mode in [ReaderToolbarDisplayMode.auto, .shown] {
            state.toolbarDisplayMode = mode
            observer.pointerMoved(to: top)
            observer.updateChrome(revealingNativeControls: false)
            root.layoutSubtreeIfNeeded()
            for button in buttons {
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, "Late native controls must reveal with the toolbar")
                let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                XCTAssertFalse(observer.handleMouseDown(try down(at: center)), "Native window controls retain their input")
            }
            for point in [blank, filename.convert(NSPoint(x: filename.bounds.midX, y: filename.bounds.midY), to: nil)] {
                let event = try down(at: point)
                let count = window.dragEvents.count
                XCTAssertTrue(observer.handleMouseDown(event), "Native toolbar blank space and filename must keep window dragging")
                XCTAssertEqual(window.dragEvents.count, count + 1)
                XCTAssertTrue(window.dragEvents.last === event)
            }
            XCTAssertEqual(window.frame, originalFrame)
        }
        state.toolbarDisplayMode = .auto
        observer.pointerMoved(to: body)
        observer.updateChrome(revealingNativeControls: false)
        for button in buttons {
            XCTAssertTrue(button.isHiddenOrHasHiddenAncestor, "Returning to the body must hide the late native controls again")
        }
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isHiddenOrHasHiddenAncestor)
    }
}
#endif
