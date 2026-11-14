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
        var dispatchedEvents: [NSEvent] = []
        var key = true
        var activations = 0
        var pointerLocation: NSPoint?
        override var isKeyWindow: Bool { key }
        override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation ?? super.mouseLocationOutsideOfEventStream }
        override func makeKeyAndOrderFront(_ sender: Any?) { key = true; activations += 1 }
        override func performDrag(with event: NSEvent) { dragEvents.append(event) }
        // Stop at the native dispatch boundary without starting Window Server tracking.
        override func sendEvent(_ event: NSEvent) { dispatchedEvents.append(event) }
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
            NSApp.sendEvent(event)
            XCTAssertTrue(window.isKeyWindow, "Clicking native titlebar space must activate \(mode)")
            XCTAssertEqual(window.activations, before + 1)
            XCTAssertTrue(window.dispatchedEvents.last === event, "Activation must preserve native titlebar input")
            XCTAssertTrue(window.dragEvents.isEmpty)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testNativeResizeEdgesReachWindowBeforeAnyOverlayDrag() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/resize-dispatch.txt"), content: .text("Book"))
        state.immersiveControls = false
        let window = DragWindow(contentRect: NSRect(x: 2200, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "native-resize-dispatch")
        let content = try XCTUnwrap(window.contentView)
        let observer = ReaderToolbarWindow.Host(frame: content.bounds)
        observer.autoresizingMask = [.width, .height]
        observer.state = state; observer.reducedMotion = true
        content.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        let root = try XCTUnwrap(content.superview)
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        var sampledDraggableHit = false
        for mode in ReaderToolbarDisplayMode.allCases {
            state.toolbarDisplayMode = mode
            observer.updateChrome(); root.layoutSubtreeIfNeeded()
            let rect = titlebar.convert(titlebar.bounds, to: nil)
            XCTAssertGreaterThan(rect.height, 0)
            // Sample inside the outermost physical pixel, without guessing
            // how many points AppKit reserves for its native resize regions.
            let pixel = 1 / window.backingScaleFactor
            let points = [NSPoint(x: rect.midX, y: rect.maxY - pixel / 2),
                          NSPoint(x: rect.maxX - pixel / 2, y: rect.midY),
                          NSPoint(x: rect.maxX - pixel / 2, y: rect.maxY - pixel / 2)]
            for point in points {
                XCTAssertTrue(rect.contains(point))
                let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                sampledDraggableHit = sampledDraggableHit || hit.mouseDownCanMoveWindow
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let count = window.dispatchedEvents.count
                NSApp.sendEvent(event)
                XCTAssertEqual(window.dispatchedEvents.count, count + 1, "AppKit must receive every native edge mouseDown in \(mode)")
                XCTAssertTrue(window.dispatchedEvents.last === event, "Native resizing needs the unmodified original event")
                XCTAssertTrue(window.dragEvents.isEmpty, "The monitor must not replace a potential native resize with a window move")
            }
        }
        XCTAssertTrue(sampledDraggableHit, "At least one edge sample must exercise the native/overlay drag eligibility that previously swallowed input")
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

    func testCollapsedNativeAccessoryYieldsItsFormerBandToTheCurrentInputOwner() async throws {
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
        content.superview?.layoutSubtreeIfNeeded()
        XCTAssertTrue(accessory.view.window === window)
        XCTAssertTrue(child.window === window)
        let formerPoints = [accessory.view, child].map { target in
            target.convert(NSPoint(x: target.bounds.width * 0.75, y: target.bounds.midY), to: nil)
        }
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
        for mode in ReaderToolbarDisplayMode.allCases {
            state.toolbarDisplayMode = mode
            state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1
            observer.updateChrome(); root.layoutSubtreeIfNeeded()
            XCTAssertTrue(accessory.isHidden, "The shared document strip replaces native accessory layout")
            XCTAssertTrue(accessory.view.isHidden)
            for point in formerPoints {
                let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                XCTAssertFalse(hit === accessory.view || hit.isDescendant(of: accessory.view),
                    "Neither the collapsed native background nor its descendants may intercept input")
                for flags: NSEvent.ModifierFlags in [[], [.control, .shift]] {
                    let event = try down(at: point, flags: flags)
                    NSApp.sendEvent(event)
                    XCTAssertTrue(window.dispatchedEvents.last === event,
                        "AppKit must dispatch the former accessory band to its current hit owner")
                    XCTAssertTrue(window.dragEvents.isEmpty)
                }
            }
        }
    }

    func testSharedTabsKeepTheirMouseDownAndNativeTitleClearance() async throws {
        final class PointerWindow: NSWindow {
            var pointer = NSPoint.zero
            var dragEvents = [NSEvent]()
            var dispatchedEvents = [NSEvent]()
            override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
            override func performDrag(with event: NSEvent) { dragEvents.append(event) }
            override func sendEvent(_ event: NSEvent) { dispatchedEvents.append(event) }
        }
        guard #available(macOS 15, *) else {
            throw XCTSkip("The native title-item policy requires macOS 15; legacy AppKit ownership has separate coverage")
        }
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let previousActivation = NSApp.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        XCTAssertTrue(NSApp.setActivationPolicy(.regular))
        defer {
            NSApp.setActivationPolicy(previousActivation)
            previousApplication?.activate(options: [])
        }
        let state = ReaderState(recordsHistory: false)
        let title = "Native toolbar title.txt"
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/" + title), content: .text("Selectable body"))
        state.immersiveControls = false; state.toolbarDisplayMode = .auto
        state.showContents = false; state.showAI = false; state.showFind = false
        let visibleFrame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let window = PointerWindow(contentRect: NSRect(x: visibleFrame.midX - 500, y: visibleFrame.midY - 300, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let sibling = NSWindow(contentRect: window.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let siblingState = ReaderState(recordsHistory: false)
        siblingState.document = ReadingDocument(url: URL(fileURLWithPath: "/Other.txt"), content: .text("Other body"))
        siblingState.immersiveControls = false; siblingState.toolbarDisplayMode = .auto
        siblingState.showContents = false; siblingState.showAI = false; siblingState.showFind = false
        window.isReleasedWhenClosed = false; sibling.isReleasedWhenClosed = false
        // This raw native input fixture needs real key-window eligibility;
        // transparent, mouse-ignoring windows exercise a different AppKit path.
        // Establish the actual document owners before ReaderDocumentTabs can
        // receive onAppear. This fixture does not mount WindowTabs.HostView.
        siblingState.window = sibling
        state.window = window
        window.addTabbedWindow(sibling, ordered: .above)
        let group = try XCTUnwrap(window.tabGroup)
        state.tabCount = group.windows.count; siblingState.tabCount = group.windows.count
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = NSHostingController(rootView: ReaderView(state: state).navigationTitle(title)
            .frame(minWidth: 560, minHeight: 400))
        sibling.toolbarStyle = .unifiedCompact
        sibling.contentViewController = NSHostingController(rootView: ReaderView(state: siblingState).navigationTitle("Other.txt")
            .frame(minWidth: 560, minHeight: 400))
        window.setContentSize(NSSize(width: 1000, height: 600))
        sibling.setContentSize(NSSize(width: 1000, height: 600))
        XCTAssertFalse(window.titlebarAccessoryViewControllers.isEmpty, "Exercise the replaced native caption accessory")
        group.selectedWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            state.windowClosed(); window.contentViewController = nil
            siblingState.windowClosed(); sibling.contentViewController = nil
            sibling.orderOut(nil); sibling.close(); window.orderOut(nil); window.close()
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let content = try XCTUnwrap(window.contentView)
        let root = try XCTUnwrap(content.superview)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let observer = try XCTUnwrap(descendants(content).compactMap { $0 as? ReaderToolbarWindow.Host }.first)
        let originalFrameOrder = root.subviews
        let phases: [(ReaderToolbarDisplayMode, Bool)] = [
            (.auto, true), (.auto, false), (.auto, true), (.auto, false),
            (.hidden, false), (.hidden, true), (.shown, false), (.auto, true)
        ]
        for (mode, hover) in phases {
            // Toolbar-mode changes and native activation both sample this
            // property asynchronously. Keep them on the same pointer used by
            // the explicit hover event instead of the user's physical pointer.
            window.pointer = NSPoint(x: 500, y: hover ? window.frame.height - 10 : 100)
            group.selectedWindow = sibling
            try await Task.sleep(nanoseconds: 30_000_000)
            group.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            // This asserts the raw view input boundary. The same inactive
            // native window can hit captions in Always Show; key-window
            // activation is not a precondition for NSView.hitTest ownership.
            state.toolbarDisplayMode = mode; siblingState.toolbarDisplayMode = mode
            observer.pointerMoved(to: window.pointer)
            observer.updateChrome()
            try await Task.sleep(nanoseconds: 600_000_000)
            root.layoutSubtreeIfNeeded()
            let shown = mode == .shown || (mode == .auto && hover)
            print("Shared tabs phase: mode=\(mode), hover=\(hover), observed=\(state.toolbarHoverVisible), frame=\(window.frame), pointer=\(window.pointer), owner=\(observer.window?.windowNumber ?? -1), expectedOwner=\(window.windowNumber)")
            XCTAssertEqual(state.toolbarHoverVisible, mode != .shown && hover)
            XCTAssertEqual(window.titleVisibility, shown ? .visible : .hidden)
            XCTAssertEqual(window.title, title, "Removing the title item must retain document identity")
            XCTAssertEqual(window.tab.title, title, "Hidden native tools must retain the native tab title")
            let owned = window.titlebarAccessoryViewControllers.compactMap { $0 as? ReaderNormalTabsAccessory }.first
            XCTAssertEqual(window.titlebarAccessoryViewControllers.filter { $0 is ReaderNormalTabsAccessory }.count, mode == .hidden ? 0 : 1,
                "Only an allocated normal strip owns an app accessory")
            if let owned { XCTAssertEqual(owned.tabsView.acceptsTabInput, shown) }
            let legacy = window.titlebarAccessoryViewControllers.filter { !($0 is ReaderNormalTabsAccessory) }
            XCTAssertTrue(legacy.allSatisfy(\.isHidden))
            for accessory in legacy.map(\.view) {
                XCTAssertTrue(accessory.isHidden, "Native captions stay replaced when reader tools reveal")
                XCTAssertNil(accessory.hitTest(NSPoint(x: accessory.bounds.midX, y: accessory.bounds.midY)))
            }
            let fields = descendants(root).compactMap { $0 as? NSTextField }.filter {
                $0.stringValue == title && !$0.isHiddenOrHasHiddenAncestor && !$0.isDescendant(of: content)
            }
            guard shown else {
                XCTAssertTrue(fields.isEmpty, "SwiftUI must not reinstall a native title while the tools are hidden")
                if let owned {
                    XCTAssertNil(owned.tabsView.hitTest(NSPoint(x: owned.tabsView.bounds.midX, y: owned.tabsView.bounds.midY)),
                        "The allocated Auto Hide row cannot intercept reading input while hidden")
                    let hiddenPoint = owned.tabsView.convert(NSPoint(x: owned.tabsView.bounds.midX, y: owned.tabsView.bounds.midY), to: nil)
                    let hiddenHit = root.hitTest(root.convert(hiddenPoint, from: nil))
                    XCTAssertTrue(hiddenHit === content || hiddenHit?.isDescendant(of: content) == true,
                        "Reading content regains the native row's input when Auto Hide dismisses")
                    XCTAssertEqual(root.subviews, originalFrameOrder,
                        "Hiding controls restores the frame's original sibling order")
                }
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
            let captionOwner = try XCTUnwrap(owned)
            let caption = try XCTUnwrap(descendants(captionOwner.tabsView).compactMap { $0 as? ReaderTabInteraction.Target }
                .first { $0.tabWindow === window && !$0.isHiddenOrHasHiddenAncestor })
            let point = caption.convert(NSPoint(x: caption.bounds.midX, y: caption.bounds.midY), to: nil)
            let requestedDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            // Match the adjacent native-title input fixture: AppKit's frame
            // hit routing must observe this window's actual mouse-down event.
            NSApp.postEvent(requestedDown, atStart: true)
            let event = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast,
                inMode: .default, dequeue: true))
            XCTAssertTrue(NSApp.currentEvent === event)
            XCTAssertEqual(event.windowNumber, window.windowNumber)
            XCTAssertEqual(event.locationInWindow, point)
            let hit = root.hitTest(root.convert(point, from: nil))
            print("Shared tabs hit: mode=\(mode), hover=\(hover), caption=\(caption.convert(caption.bounds, to: nil)), layout=\(window.contentLayoutRect), hit=\(String(describing: hit)), captionView=\(caption)")
            if hit !== caption {
                var ancestor: NSView? = caption
                while let view = ancestor {
                    print("Shared caption ancestor: view=\(view) frame=\(view.frame) alpha=\(view.alphaValue) hidden=\(view.isHidden) window=\(view.window?.windowNumber ?? -1)")
                    ancestor = view.superview
                }
                for child in root.subviews {
                    let parentPoint = root.convert(point, from: nil)
                    print("Shared root child: view=\(child) frame=\(child.frame) alpha=\(child.alphaValue) hidden=\(child.isHidden) hit=\(String(describing: child.hitTest(parentPoint)))")
                }
                print("Shared caption root: root=\(root), key=\(window.isKeyWindow), captionWindow=\(caption.window?.windowNumber ?? -1), nativeHit=\(String(describing: captionOwner.tabsView.hitTest(captionOwner.tabsView.convert(point, from: nil))))")
            }
            XCTAssertTrue(hit === caption,
                "The shared caption must own its real input instead of a titlebar drag overlay")
            NSApp.sendEvent(event)
            XCTAssertTrue(window.dispatchedEvents.last === event, "Shared tab input must retain AppKit's dispatch boundary")
            XCTAssertTrue(window.dragEvents.isEmpty)
        }
        observer.detach()
        XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { $0 is ReaderNormalTabsAccessory },
            "Detaching the native chrome owner removes its app-owned accessory")
    }

    func testNativeToolbarBlankAndFilenameDragAfterHitTestingWhileControlsKeepNativeInput() async throws {
        _ = NSApplication.shared
        let previousCursor = NSCursor.current
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-input.txt"), content: .text("Selectable body"))
        state.immersiveControls = false; state.toolbarDisplayMode = .hidden
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
        let root = try XCTUnwrap(content.superview)
        let filename = NSTextField(labelWithString: "Reading.txt")
        filename.frame = NSRect(x: 350, y: 5, width: 180, height: 22)
        titlebar.addSubview(filename)
        let nativeTitlebarViews = titlebar.subviews

        func event(_ type: NSEvent.EventType, at point: NSPoint,
                   flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: clickCount, pressure: 1))
        }
        func center(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func currentMouseDown(_ event: NSEvent) throws -> NSEvent {
            NSApp.postEvent(event, atStart: true)
            let fetched = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast,
                                                        inMode: .default, dequeue: true))
            XCTAssertEqual(fetched.windowNumber, event.windowNumber)
            XCTAssertEqual(fetched.locationInWindow, event.locationInWindow)
            XCTAssertEqual(fetched.modifierFlags, event.modifierFlags)
            XCTAssertEqual(fetched.clickCount, event.clickCount)
            XCTAssertTrue(NSApp.currentEvent === fetched, "Hit testing must observe the actual dequeued event")
            return fetched
        }
        func dragReceiver(at point: NSPoint) throws -> NSView {
            let hit = root.hitTest(root.convert(point, from: nil))
            return try XCTUnwrap(hit.flatMap { view in
                view === titlebar.subviews.last && !nativeTitlebarViews.contains { $0 === view } ? view : nil
            }, "The visible blank gap must hit its mounted drag receiver before mouseDown is dispatched")
        }
        var revealedDragView: NSView?
        var blankPoint = NSPoint.zero
        for mode in [ReaderToolbarDisplayMode.shown, .auto] {
            state.toolbarDisplayMode = mode
            // Native layout completion now samples the stationary pointer.
            // Keep this synthetic reveal independent of the physical desktop.
            window.pointerLocation = NSPoint(x: 500, y: window.frame.height - 10)
            state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1
            observer.updateChrome()
            root.layoutSubtreeIfNeeded()
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
            let filenameFrame = filename.convert(filename.bounds, to: nil)
            let firstItemFrame = items.button.convert(items.button.bounds, to: nil)
            XCTAssertLessThan(filenameFrame.maxX, firstItemFrame.minX,
                              "The fixture must contain the reported blank gap between the filename and first toolbar control")
            let blank = NSPoint(x: (filenameFrame.maxX + firstItemFrame.minX) / 2,
                                y: firstItemFrame.midY)
            blankPoint = blank
            XCTAssertTrue(titlebar.convert(titlebar.bounds, to: nil).contains(blank))
            let body = NSPoint(x: 220, y: 200)
            let draggable = [blank, center(filename)]
            let excluded = [body, center(close), center(items.button), center(items.page)]
            let nativeDragView = try dragReceiver(at: blank)
            revealedDragView = nativeDragView
            for point in draggable {
                for control in [close, items.button, items.page] as [NSView] {
                    XCTAssertFalse(control.convert(control.bounds, to: nil).contains(point), "The blank/title fixture must be outside toolbar controls")
                }
                NSCursor.iBeam.set()
                observer.handleMouseMoved(try event(.mouseMoved, at: point))
                XCTAssertEqual(NSCursor.current, NSCursor.arrow, "Native toolbar blank/title must clear the text cursor in \(mode)")
                let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                guard hit === nativeDragView else {
                    XCTFail("The actual native blank/title hit must reach the drag receiver in \(mode), hit=\(type(of: hit))")
                    return
                }
                let down = try event(.leftMouseDown, at: point)
                let dragCount = window.dragEvents.count
                NSApp.sendEvent(down)
                XCTAssertTrue(window.dispatchedEvents.last === down, "AppKit must first receive the original event for native edge dispatch")
                XCTAssertEqual(window.dragEvents.count, dragCount, "The monitor must leave window dragging to the dispatched view")
                // Invoke the actual hit owner after the native dispatch boundary.
                // The window spy prevents Window Server drag tracking.
                hit.mouseDown(with: down)
                XCTAssertEqual(window.dragEvents.count, dragCount + 1)
                XCTAssertTrue(window.dragEvents.last === down, "The visible blank/title hit must drag using its original mouseDown")
            }
            for point in excluded {
                let hit = try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
                XCTAssertFalse(hit === nativeDragView,
                               "Reading content and real controls must remain their actual hit owners")
                let down = try event(.leftMouseDown, at: point)
                let dragCount = window.dragEvents.count
                NSApp.sendEvent(down)
                XCTAssertTrue(window.dispatchedEvents.last === down, "Reading content and real controls keep their own mouseDown")
                XCTAssertEqual(window.dragEvents.count, dragCount)
            }
            for requestedClick in [try event(.leftMouseDown, at: center(filename), flags: .command),
                                try event(.leftMouseDown, at: center(filename), clickCount: 2)] {
                let dragCount = window.dragEvents.count
                let nativeClick = try currentMouseDown(requestedClick)
                let nativeHit = try XCTUnwrap(root.hitTest(root.convert(nativeClick.locationInWindow, from: nil)))
                XCTAssertFalse(nativeHit === nativeDragView, "Command clicks and double-clicks must hit the original native title owner")
                NSApp.sendEvent(nativeClick)
                XCTAssertTrue(window.dispatchedEvents.last === nativeClick, "Native title path menus and double-click actions retain their original event")
                XCTAssertEqual(window.dragEvents.count, dragCount)
            }
            _ = try currentMouseDown(event(.leftMouseDown, at: blank))
            NSCursor.iBeam.set()
            observer.handleMouseMoved(try event(.mouseMoved, at: body))
            XCTAssertEqual(NSCursor.current, NSCursor.iBeam, "The document retains its text cursor")
        }
        let previousDragView = try XCTUnwrap(revealedDragView)
        state.toolbarDisplayMode = .auto
        observer.pointerMoved(to: NSPoint(x: 220, y: 200)); observer.updateChrome()
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(state.toolbarHoverVisible)
        XCTAssertNil(previousDragView.superview, "Auto must remove the native drag receiver when the toolbar hides")
        state.toolbarDisplayMode = .hidden
        observer.updateChrome()
        XCTAssertNil(previousDragView.superview, "Always Hide must leave native titlebar input to the reading-band receiver")
        state.toolbarDisplayMode = .shown
        observer.updateChrome(); root.layoutSubtreeIfNeeded()
        let remountedDragView = try dragReceiver(at: blankPoint)
        XCTAssertFalse(remountedDragView === previousDragView)
        observer.removeFromSuperview()
        XCTAssertNil(remountedDragView.superview, "Detaching the host must retire its native drag receiver")
        content.addSubview(observer)
        observer.updateChrome(); root.layoutSubtreeIfNeeded()
        let reattachedDragView = try dragReceiver(at: blankPoint)
        XCTAssertFalse(reattachedDragView === remountedDragView)
        let remountedDown = try event(.leftMouseDown, at: blankPoint)
        let dragCount = window.dragEvents.count
        reattachedDragView.mouseDown(with: remountedDown)
        XCTAssertEqual(window.dragEvents.count, dragCount + 1)
        XCTAssertTrue(window.dragEvents.last === remountedDown, "The remounted receiver must still drag using the original mouseDown")
    }
}
#endif
