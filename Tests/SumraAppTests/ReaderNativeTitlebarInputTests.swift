#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderNativeTitlebarInputTests: XCTestCase {
    private final class DragWindow: NSWindow {
        var dragEvents: [NSEvent] = []
        var key = true
        var activations = 0
        override var isKeyWindow: Bool { key }
        override func makeKeyAndOrderFront(_ sender: Any?) { key = true; activations += 1 }
        override func performDrag(with event: NSEvent) { dragEvents.append(event) }
    }

    func testNativeTitlebarClicksActivateTheWindowInEveryToolbarMode() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/inactive-toolbar.txt"), content: .text("book"))
        state.immersiveControls = false
        let window = DragWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "inactive-toolbar")
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        for mode in ReaderToolbarDisplayMode.allCases {
            state.toolbarDisplayMode = mode
            observer.updateChrome()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            // Hiding the native toolbar changes the titlebar's current bounds.
            let point = titlebar.convert(NSPoint(x: titlebar.bounds.midX, y: titlebar.bounds.midY), to: nil)
            window.key = false
            let before = window.activations
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            _ = observer.handleMouseDown(event)
            XCTAssertTrue(window.isKeyWindow, "Clicking native titlebar space must activate \(mode)")
            XCTAssertEqual(window.activations, before + 1)
        }
        XCTAssertFalse(window.isVisible)
    }

    private final class DraggableAccessoryView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    @MainActor private final class ToolbarItems: NSObject, NSToolbarDelegate {
        let button = NSButton(title: "Next", target: nil, action: nil)
        let page = NSTextField(string: "12")
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.flexibleSpace, .init("next"), .init("page")]
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarAllowedItemIdentifiers(toolbar)
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = identifier.rawValue
            let view: NSView = identifier.rawValue == "next" ? button : page
            item.view = view
            view.widthAnchor.constraint(equalToConstant: identifier.rawValue == "next" ? 70 : 60).isActive = true
            return item
        }
    }

    func testNativeAccessoryBackgroundAndDescendantsKeepMouseDownWhileHiddenBandStillDrags() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/accessory-input.txt"), content: .text("Reading body"))
        state.immersiveControls = false; state.toolbarDisplayMode = .shown
        let window = DragWindow(contentRect: NSRect(x: 2200, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "native-accessory-input")
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = DraggableAccessoryView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
        let child = DraggableAccessoryView(frame: NSRect(x: 100, y: 4, width: 100, height: 20))
        accessory.view.addSubview(child)
        window.addTitlebarAccessoryViewController(accessory)
        let content = try XCTUnwrap(window.contentView)
        let observer = ReaderToolbarWindow.Host(frame: content.bounds)
        observer.autoresizingMask = [.width, .height]
        observer.state = state; observer.reducedMotion = true
        content.addSubview(observer)
        state.window = window; window.orderBack(nil)
        defer {
            observer.detach(); state.windowClosed(); window.contentView = nil; window.orderOut(nil); window.close()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let root = try XCTUnwrap(content.superview)
        func down(at point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        for mode in [ReaderToolbarDisplayMode.shown, .auto] {
            state.toolbarDisplayMode = mode
            state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1
            observer.updateChrome(); root.layoutSubtreeIfNeeded()
            for target in [accessory.view, child] {
                let local = target === accessory.view ? NSPoint(x: target.bounds.width * 0.75, y: target.bounds.midY)
                    : NSPoint(x: target.bounds.midX, y: target.bounds.midY)
                let point = target.convert(local, to: nil)
                let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                XCTAssertTrue(hit === target, "The fixture must hit the native accessory background or its actual descendant")
                XCTAssertTrue(hit.mouseDownCanMoveWindow, "The native owner may report draggable input")
                for flags: NSEvent.ModifierFlags in [[], [.control, .shift]] {
                    XCTAssertFalse(observer.handleMouseDown(try down(at: point, flags: flags)),
                        "The titlebar accessory owns its mouseDown even when its native hit reports draggable")
                    XCTAssertTrue(window.dragEvents.isEmpty)
                }
            }
        }
        state.toolbarDisplayMode = .auto
        observer.pointerMoved(to: NSPoint(x: 300, y: 100)); observer.updateChrome()
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(accessory.view.isHidden)
        let hiddenPoint = accessory.view.convert(NSPoint(x: accessory.view.bounds.width * 0.75, y: accessory.view.bounds.midY), to: nil)
        let hiddenHit = try XCTUnwrap(root.hitTest(root.convert(hiddenPoint, from: nil)))
        XCTAssertFalse(hiddenHit === accessory.view || hiddenHit.isDescendant(of: accessory.view))
        XCTAssertTrue(observer.handleMouseDown(try down(at: hiddenPoint)),
            "The hidden accessory's former bounds must not take drag input from the reading overlay")
    }

    func testRevealedNativeTabsKeepTheirMouseDownAndTitleClearance() async throws {
        guard #available(macOS 15, *) else {
            throw XCTSkip("The native title-item policy requires macOS 15; legacy AppKit ownership has separate coverage")
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let title = "Native toolbar title.txt"
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/" + title), content: .text("Selectable body"))
        state.immersiveControls = false; state.toolbarDisplayMode = .shown
        state.showContents = false; state.showAI = false; state.showFind = false
        let window = DragWindow(contentRect: NSRect(x: 2200, y: 100, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let sibling = NSWindow(contentRect: window.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let siblingState = ReaderState(recordsHistory: false)
        siblingState.document = ReadingDocument(url: URL(fileURLWithPath: "/Other.txt"), content: .text("Other body"))
        siblingState.immersiveControls = false; siblingState.toolbarDisplayMode = .shown
        siblingState.showContents = false; siblingState.showAI = false; siblingState.showFind = false
        window.isReleasedWhenClosed = false; sibling.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        sibling.alphaValue = 0; sibling.ignoresMouseEvents = true
        window.toolbarStyle = .unifiedCompact
        window.contentView = NSHostingView(rootView: ReaderView(state: state).navigationTitle(title))
        sibling.toolbarStyle = .unifiedCompact
        sibling.contentView = NSHostingView(rootView: ReaderView(state: siblingState).navigationTitle("Other.txt"))
        siblingState.window = sibling
        state.window = window
        window.addTabbedWindow(sibling, ordered: .above)
        let group = try XCTUnwrap(window.tabGroup)
        group.selectedWindow = window
        window.orderBack(nil)
        defer {
            state.windowClosed(); window.contentView = nil
            siblingState.windowClosed(); sibling.contentView = nil
            sibling.orderOut(nil); sibling.close(); window.orderOut(nil); window.close()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let content = try XCTUnwrap(window.contentView)
        let root = try XCTUnwrap(content.superview)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let observer = try XCTUnwrap(descendants(content).compactMap { $0 as? ReaderToolbarWindow.Host }.first)
        let phases: [(ReaderToolbarDisplayMode, Bool)] = [
            (.auto, true), (.auto, false), (.auto, true), (.auto, false),
            (.hidden, false), (.hidden, true), (.shown, false), (.auto, true)
        ]
        for (mode, hover) in phases {
            group.selectedWindow = sibling
            try await Task.sleep(nanoseconds: 30_000_000)
            group.selectedWindow = window
            try await Task.sleep(nanoseconds: 30_000_000)
            state.toolbarDisplayMode = mode; siblingState.toolbarDisplayMode = mode
            observer.pointerMoved(to: NSPoint(x: 500, y: hover ? window.frame.height - 10 : 100))
            observer.updateChrome()
            try await Task.sleep(nanoseconds: 600_000_000)
            root.layoutSubtreeIfNeeded()
            let shown = mode == .shown || (mode == .auto && hover)
            XCTAssertEqual(state.toolbarHoverVisible, mode != .shown && hover)
            XCTAssertEqual(window.titleVisibility, shown ? .visible : .hidden)
            XCTAssertEqual(window.title, title, "Removing the title item must retain document identity")
            XCTAssertEqual(window.tab.title, title, "Hidden native tools must retain the native tab title")
            let fields = descendants(root).compactMap { $0 as? NSTextField }.filter {
                $0.stringValue == title && !$0.isHiddenOrHasHiddenAncestor && !$0.isDescendant(of: content)
            }
            guard shown else {
                XCTAssertTrue(fields.isEmpty, "SwiftUI must not reinstall a native title while the tools are hidden")
                continue
            }
            let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
                try XCTUnwrap(window.standardWindowButton($0))
            }
            XCTAssertFalse(fields.isEmpty, "The fixture must mount the actual native document title")
            for field in fields {
                let frame = field.convert(field.bounds, to: nil)
                for button in buttons {
                    let buttonFrame = button.convert(button.bounds, to: nil)
                    XCTAssertFalse(frame.intersects(buttonFrame), "Native title must clear revealed traffic lights: title=\(frame), button=\(buttonFrame)")
                }
            }
            let accessories = window.titlebarAccessoryViewControllers.map(\.view)
            XCTAssertFalse(accessories.isEmpty, "The fixture must mount AppKit's native tab bar")
            for accessory in accessories {
                let point = accessory.convert(NSPoint(x: accessory.bounds.width * 0.75, y: accessory.bounds.midY), to: nil)
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let hit = root.hitTest(root.convert(point, from: nil))
                XCTAssertTrue(hit === accessory || hit?.isDescendant(of: accessory) == true,
                    "The native tab accessory must receive its own input")
                XCTAssertFalse(observer.handleMouseDown(event), "Native tab clicks must reach AppKit instead of starting a window drag")
                XCTAssertTrue(window.dragEvents.isEmpty)
            }
        }
    }

    func testNativeToolbarBlankAndFilenameOwnCursorAndDragWithoutConsumingControls() async throws {
        _ = NSApplication.shared
        let previousCursor = NSCursor.current
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-input.txt"), content: .text("Selectable body"))
        state.immersiveControls = false
        let window = DragWindow(contentRect: NSRect(x: 2200, y: 100, width: 1100, height: 600),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        window.toolbarStyle = .unifiedCompact
        let items = ToolbarItems()
        let toolbar = NSToolbar(identifier: "native-titlebar-input")
        toolbar.delegate = items
        window.toolbar = toolbar
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        window.contentView = content
        let observer = ReaderToolbarWindow.Host(frame: content.bounds)
        observer.autoresizingMask = [.width, .height]
        observer.state = state; observer.reducedMotion = true
        content.addSubview(observer)
        state.window = window
        window.orderBack(nil)
        defer {
            observer.detach(); window.orderOut(nil); window.contentView = nil; window.close()
            state.windowClosed(); previousCursor.set()
            withExtendedLifetime(items) {}
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let titlebar = try XCTUnwrap(close.superview)
        let filename = NSTextField(labelWithString: "Reading.txt")
        filename.frame = NSRect(x: 350, y: 5, width: 180, height: 22)
        titlebar.addSubview(filename)

        func event(_ type: NSEvent.EventType, at point: NSPoint,
                   flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: clickCount, pressure: 1))
        }
        func center(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        for mode in [ReaderToolbarDisplayMode.shown, .auto] {
            state.toolbarDisplayMode = mode
            state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1
            observer.updateChrome()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(titlebar.bounds.height, 0)
            XCTAssertGreaterThan(filename.bounds.height, 0)
            XCTAssertFalse(filename.isEditable)
            for control in [close, items.button, items.page, filename] as [NSView] {
                XCTAssertTrue(control.window === window)
                XCTAssertGreaterThan(control.bounds.width, 0)
                XCTAssertGreaterThan(control.bounds.height, 0)
                XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            }
            XCTAssertTrue(items.page.isEditable)
            let blank = titlebar.convert(NSPoint(x: 220, y: titlebar.bounds.midY), to: nil)
            let body = NSPoint(x: 220, y: 200)
            let draggable = [blank, center(filename)]
            let excluded = [body, center(close), center(items.button), center(items.page)]
            for point in draggable {
                for control in [close, items.button, items.page] as [NSView] {
                    XCTAssertFalse(control.convert(control.bounds, to: nil).contains(point), "The blank/title fixture must be outside toolbar controls")
                }
                NSCursor.iBeam.set()
                observer.handleMouseMoved(try event(.mouseMoved, at: point))
                XCTAssertEqual(NSCursor.current, NSCursor.arrow, "Native toolbar blank/title must clear the text cursor in \(mode)")
                let down = try event(.leftMouseDown, at: point)
                let previousCount = window.dragEvents.count
                XCTAssertTrue(observer.handleMouseDown(down))
                XCTAssertEqual(window.dragEvents.count, previousCount + 1)
                XCTAssertTrue(window.dragEvents.last === down, "Window Server dragging needs the original mouseDown event")
            }
            for point in excluded {
                let down = try event(.leftMouseDown, at: point)
                let previousCount = window.dragEvents.count
                XCTAssertFalse(observer.handleMouseDown(down), "Reading content and real controls keep their own mouseDown")
                XCTAssertEqual(window.dragEvents.count, previousCount)
            }
            for nativeClick in [try event(.leftMouseDown, at: center(filename), flags: .command),
                                try event(.leftMouseDown, at: center(filename), clickCount: 2)] {
                let previousCount = window.dragEvents.count
                XCTAssertFalse(observer.handleMouseDown(nativeClick), "Native title path menus and double-click actions retain their original event")
                XCTAssertEqual(window.dragEvents.count, previousCount)
            }
            NSCursor.iBeam.set()
            observer.handleMouseMoved(try event(.mouseMoved, at: body))
            XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "The document retains its text cursor")
        }
    }
}
#endif
