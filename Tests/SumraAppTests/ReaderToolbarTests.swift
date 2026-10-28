#if os(macOS)
import XCTest
import AppKit
import Combine
import SwiftUI
@testable import Sumra

@MainActor
final class ReaderToolbarTests: XCTestCase {
    func testFloatingTitleOwnerSurvivesDynamicTitlesAndResizeThenRestoresNativeTitle() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("The public default toolbar-title policy requires macOS 15") }
        final class Titles: ObservableObject { @Published var value = "Floating title initial" }
        struct WindowContent: View {
            @ObservedObject var state: ReaderState
            @ObservedObject var titles: Titles
            var body: some View { ReaderView(state: state).navigationTitle(titles.value) }
        }
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        let menu = NSMenu(title: "Window"), main = NSMenu(title: "Sumra")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = menu
        NSApp.mainMenu = main; NSApp.windowsMenu = menu
        defer { NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu }
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("native-title.txt")
        try "Reading content keeps its native document name.".write(to: input, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .text("Reading content."))
        state.toolbarDisplayMode = .shown; state.immersiveControls = true
        state.showContents = false; state.showAI = false; state.showFind = false
        let titles = Titles()
        let controller = NSHostingController(rootView: WindowContent(state: state, titles: titles))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.styleMask.formUnion([.titled, .closable, .resizable])
        window.representedURL = input; window.isExcludedFromWindowsMenu = false
        state.window = window
        window.orderBack(nil)
        defer {
            window.orderOut(nil); NSApp.removeWindowsItem(window)
            state.windowClosed(); window.contentViewController = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func visibleNativeTitles(in view: NSView) -> [NSTextField] {
            if view === controller.view { return [] }
            var fields = [NSTextField]()
            if let field = view as? NSTextField, field.stringValue == titles.value,
               !field.isHiddenOrHasHiddenAncestor {
                var current: NSView? = field
                var visible = true
                while let ancestor = current {
                    if ancestor.alphaValue == 0 { visible = false }
                    current = ancestor.superview
                }
                if visible { fields.append(field) }
            }
            return fields + view.subviews.flatMap { visibleNativeTitles(in: $0) }
        }
        var step = 0
        for floating in [true, true, true, false, true] {
            state.immersiveControls = floating
            titles.value = "Floating title \(step)"
            window.setFrame(CGRect(x: 2200, y: 100, width: 770 + step * 9, height: 675 + step * 3), display: false)
            for _ in 0..<20 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(window.title, titles.value)
            XCTAssertEqual(window.tab.title, titles.value, "Removing the visible title must preserve native tab names")
            XCTAssertTrue(menu.items.contains { $0.title == titles.value }, "The native Window menu must retain the document title")
            let frame = try XCTUnwrap(window.contentView?.superview)
            if floating {
                XCTAssertEqual(window.titleVisibility, .hidden)
                XCTAssertTrue(visibleNativeTitles(in: frame).isEmpty, "SwiftUI must not recreate a native title over the floating one")
            } else {
                XCTAssertEqual(window.titleVisibility, .visible)
                XCTAssertFalse(visibleNativeTitles(in: frame).isEmpty, "Turning off floating controls must restore the native title")
            }
            step += 1
        }
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
    }

    func testMenuTrackingKeepsRevealedNativeTabsStableThroughPendingDismissal() async throws {
        final class MenuWindow: NSWindow {
            override var isKeyWindow: Bool { true }
            override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: 350, y: 100) }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/menu-hover.txt"), content: .text("book"))
        state.immersiveControls = false; state.toolbarDisplayMode = .auto
        let window = MenuWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let sibling = NSWindow(contentRect: window.frame,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; sibling.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "menu-hover")
        window.addTabbedWindow(sibling, ordered: .above)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = false
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; sibling.close(); window.close(); state.windowClosed() }
        let tabs = window.titlebarAccessoryViewControllers.map(\.view)
        XCTAssertFalse(tabs.isEmpty)
        let menu = NSMenu(title: "View")
        let toggleTabs = NSMenuItem(title: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        let originallyEnabled = window.validateUserInterfaceItem(toggleTabs)
        let frame = window.frame, layout = window.contentLayoutRect
        for delay in [50_000_000, 170_000_000] as [UInt64] {
            observer.pointerMoved(to: NSPoint(x: 350, y: window.frame.height - 1))
            observer.pointerMoved(to: NSPoint(x: 350, y: 100))
            try await Task.sleep(nanoseconds: delay)
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            observer.pointerMoved(to: NSPoint(x: 350, y: window.frame.height + 20))
            try await Task.sleep(nanoseconds: 350_000_000)
            observer.updateChrome()
            XCTAssertTrue(state.toolbarHoverVisible, "Opening View must cancel the pending toolbar dismissal")
            XCTAssertEqual(state.toolbarHoverOpacity, 1)
            XCTAssertEqual(window.titleVisibility, .visible)
            for view in tabs { XCTAssertFalse(view.isHidden); XCTAssertEqual(view.alphaValue, 1, accuracy: 0.001) }
            XCTAssertEqual(window.validateUserInterfaceItem(toggleTabs), originallyEnabled,
                           "AppKit's tab command availability must stay stable during native menu tracking")
            XCTAssertEqual(window.frame, frame); XCTAssertEqual(window.contentLayoutRect, layout)
            observer.reducedMotion = true
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            XCTAssertFalse(state.toolbarHoverVisible, "Ending menu tracking resumes normal pointer-based dismissal")
            observer.reducedMotion = false
        }
        XCTAssertFalse(window.isVisible); XCTAssertFalse(sibling.isVisible)
    }

    func testMenuTrackingDoesNotRemainLatchedAfterWindowDeactivation() throws {
        final class MenuWindow: NSWindow {
            var key = true
            var pointer = NSPoint.zero
            override var isKeyWindow: Bool { key }
            override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/menu-focus.txt"), content: .text("book"))
        state.immersiveControls = false; state.toolbarDisplayMode = .auto
        let window = MenuWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        let menu = NSMenu(title: "View")
        window.pointer = NSPoint(x: 350, y: window.frame.height - 1)
        observer.pointerMoved(to: window.pointer)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(state.toolbarHoverVisible)
        observer.pointerMoved(to: NSPoint(x: 350, y: 100))
        XCTAssertFalse(state.toolbarHoverVisible, "A menu ended in another window cannot latch this window's later hover")
        XCTAssertFalse(window.isVisible)
    }

    func testBlankWelcomeTabKeepsNativeTabsVisibleAndInstalled() async throws {
        _ = NSApplication.shared
        let states = (0..<2).map { index in
            let state = ReaderState(recordsHistory: false)
            if index == 0 { state.document = ReadingDocument(url: URL(fileURLWithPath: "/welcome-tab.txt"), content: .text("book")) }
            state.immersiveControls = false; state.toolbarDisplayMode = .auto
            return state
        }
        let windows = states.enumerated().map { index, state in
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 600),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            window.toolbar = NSToolbar(identifier: "welcome-tab-\(index)")
            window.contentView = NSHostingView(rootView: ReaderView(state: state))
            return window
        }
        defer {
            for window in windows { window.contentView = nil; window.close() }
            for state in states { state.windowClosed() }
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        let group = try XCTUnwrap(windows[0].tabGroup)
        for index in [1, 0, 1] {
            let window = windows[index]
            group.selectedWindow = window
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            for _ in 0..<10 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(try XCTUnwrap(window.toolbar).isVisible,
                          "Welcome keeps native chrome installed so a blank tab remains part of its tab group")
            XCTAssertTrue(group.isTabBarVisible)
            if index == 1 {
                let tabs = window.titlebarAccessoryViewControllers.map(\.view)
                XCTAssertFalse(tabs.isEmpty)
                for view in tabs { XCTAssertFalse(view.isHidden); XCTAssertEqual(view.alphaValue, 1, accuracy: 0.001) }
                XCTAssertEqual(window.titleVisibility, .visible)
            }
        }
        for window in windows { XCTAssertEqual(window.alphaValue, 0); XCTAssertTrue(window.ignoresMouseEvents) }
    }

    func testAutoHideRevealsWindowTitleWithItsControls() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/hover-title.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }

        let frame = window.frame, viewport = window.contentView?.frame
        XCTAssertEqual(window.titleVisibility, .hidden)
        observer.pointerMoved(to: NSPoint(x: 350, y: window.frame.height - 1))
        observer.updateChrome()
        XCTAssertEqual(window.titleVisibility, .visible,
                       "Auto Hide reveals the document title together with its native window controls")
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.contentView?.frame, viewport,
                       "Revealing the title must not resize the reading viewport")
        observer.pointerMoved(to: NSPoint(x: 350, y: 100))
        observer.updateChrome()
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(window.isVisible)
    }

    func testNativeTabActivationRevealsControlsUnderStationaryPointer() throws {
        final class PointerWindow: NSWindow {
            var pointer = NSPoint.zero
            override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/tab-activation.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = PointerWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "stationary-tab-activation")
        let tabs = NSTitlebarAccessoryViewController()
        tabs.view = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 28))
        window.addTitlebarAccessoryViewController(tabs)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }

        // A native tab receives the key-window notification after AppKit has
        // selected it, before any mouse-moved event reaches the new document.
        window.pointer = NSPoint(x: 350, y: window.frame.height - 1)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(state.toolbarHoverVisible,
                      "Selecting a native tab under the pointer must not require a subsequent mouse move")
        XCTAssertFalse(tabs.view.isHidden)
        XCTAssertEqual(tabs.view.alphaValue, 1, accuracy: 0.001)

        window.pointer = NSPoint(x: 350, y: 100)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(state.toolbarHoverVisible,
                       "Keyboard activation with the pointer in the book must retain Auto Hide")
        XCTAssertFalse(window.isVisible)
    }

    func testPointerMovementPublishesOnlyToolbarTransitions() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar-pointer.txt"), content: .text("book"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.state = state
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        var publications = 0
        let observation = state.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for reducedMotion in [false, true] {
            observer.reducedMotion = reducedMotion
            for mode in ReaderToolbarDisplayMode.allCases {
                state.toolbarDisplayMode = mode
                let before = publications
                for x in 0..<700 { observer.pointerMoved(to: NSPoint(x: CGFloat(x), y: 100)) }
                XCTAssertEqual(publications, before, "Moving through the book without a toolbar transition must not invalidate the reader: \(mode), reduced motion \(reducedMotion)")
            }
        }
        state.toolbarDisplayMode = .auto
        observer.pointerMoved(to: NSPoint(x: 350, y: window.frame.height - 40))
        XCTAssertTrue(state.toolbarHoverVisible)
        XCTAssertEqual(state.toolbarHoverOpacity, 1)
        let revealed = publications
        for x in 0..<700 { observer.pointerMoved(to: NSPoint(x: CGFloat(x), y: window.frame.height - 40)) }
        XCTAssertEqual(publications, revealed, "Moving across already visible controls must not republish them")
        observer.pointerMoved(to: NSPoint(x: 350, y: 100))
        XCTAssertFalse(state.toolbarHoverVisible)
        XCTAssertEqual(state.toolbarHoverOpacity, 0)
        XCTAssertGreaterThan(publications, revealed, "The real dismissal must still publish")
        XCTAssertFalse(window.isVisible)
    }

    func testHoverMotionCanReverseDuringGraceAndFadeWithoutBlinking() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar-motion.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = false
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        let top = NSPoint(x: 350, y: window.frame.height - 40)
        let body = NSPoint(x: 350, y: 100)
        var visibility = [Bool]()
        let observation = state.$toolbarHoverVisible.dropFirst().sink { visibility.append($0) }
        defer { observation.cancel() }
        observer.pointerMoved(to: top)
        observer.pointerMoved(to: body)
        XCTAssertTrue(state.toolbarHoverVisible, "Leaving the edge must allow a gentle outro")
        try await Task.sleep(nanoseconds: 50_000_000)
        observer.pointerMoved(to: top)
        try await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertEqual(visibility, [true], "A quick return must not hide and remount the controls")
        XCTAssertEqual(state.toolbarHoverOpacity, 1)

        observer.pointerMoved(to: body)
        try await Task.sleep(nanoseconds: 170_000_000)
        XCTAssertTrue(state.toolbarHoverVisible)
        XCTAssertEqual(state.toolbarHoverOpacity, 0, "The fade target changes before the native toolbar is removed")
        observer.pointerMoved(to: top)
        try await Task.sleep(nanoseconds: 320_000_000)
        XCTAssertEqual(visibility, [true], "Returning during a fade must cancel its old completion")
        XCTAssertEqual(state.toolbarHoverOpacity, 1)

        observer.pointerMoved(to: body)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(state.toolbarHoverVisible)
        observer.pointerMoved(to: top)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(state.toolbarHoverVisible, "Focus loss must dismiss immediately")
        observer.reducedMotion = true
        observer.pointerMoved(to: top); observer.pointerMoved(to: body)
        XCTAssertFalse(state.toolbarHoverVisible, "Reduced Motion must not wait for the outro")
        XCTAssertEqual(state.toolbarHoverOpacity, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testHoverToolbarPreservesBookViewportLayoutAndPassage() async throws {
        _ = NSApplication.shared
        final class FixedHeightMenu: NSMenu {
            var height: CGFloat = 0
            override var menuBarHeight: CGFloat { height }
        }
        let originalMenu = NSApp.mainMenu
        if originalMenu == nil { NSApp.mainMenu = NSMenu(title: "Sumra") }
        // This test simulates fullscreen flags; hold its external menu geometry
        // fixed while checking that hover itself never changes book layout.
        let menu = FixedHeightMenu(title: "Sumra")
        menu.height = try XCTUnwrap(NSApp.mainMenu).menuBarHeight
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMenu }
        let menuHeight = try XCTUnwrap(NSApp.mainMenu).menuBarHeight
        XCTAssertGreaterThan(menuHeight, 0, "The regression needs the native system menu's reserved height")
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("toolbar.fb2")
        let paragraphs = (0..<100).map { "<p>Paragraph \($0) keeps its place when temporary controls overlay this book.</p>" }.joined()
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>\(paragraphs)</section></body></FictionBook>"
            .write(to: input, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let saved = ["flow", "spread", "cover"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }

        let modes: [(ReaderToolbarDisplayMode, Bool)] = [(.shown, false), (.auto, false), (.hidden, false), (.auto, true)]
        // Exercise the reader's response to fullscreen notifications without
        // asking AppKit to enter a visible fullscreen Space during unit tests.
        final class FullscreenWindow: NSWindow {
            var fullscreen = false
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
        }
        for (flow, tabbed, mode, presentation) in ["paged", "continuous"].flatMap({ flow in
            [false, true].flatMap { tabbed in modes.map { (flow, tabbed, $0.0, $0.1) } }
        }) {
            let document = try ReadingDocument.open(input, deferReflowLayout: true)
            guard case .pages(let pages) = document.content else { return XCTFail("Expected native book") }
            let state = ReaderState(recordsHistory: false)
            state.document = document; state.flow = flow; state.toolbarDisplayMode = mode; state.presentation = presentation
            state.showContents = false; state.showAI = false; state.showFind = false
            state.spread = false; state.cover = false; state.automaticLayout = false
            state.font = "serif"; state.fontSize = 17; state.margin = 32
            state.freePan = false; state.fit = "page"; state.zoom = 1; state.scrollbarMode = "hidden"
            let window = FullscreenWindow(contentRect: CGRect(x: 2000, y: 100, width: 900, height: 650),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.toolbarStyle = .unifiedCompact
            let toolbar = NSToolbar(identifier: "hover-book-\(flow)")
            window.toolbar = toolbar; toolbar.isVisible = true
            let sibling = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 900, height: 650),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            sibling.isReleasedWhenClosed = false
            if tabbed { window.addTabbedWindow(sibling, ordered: .above) }
            let host = NSHostingView(rootView: ReaderView(state: state))
            window.contentView = host
            defer { state.windowClosed(); window.contentView = nil; sibling.close(); window.close() }
            func toolbarObserver(in view: NSView) -> ReaderToolbarWindow.Host? {
                if let observer = view as? ReaderToolbarWindow.Host { return observer }
                return view.subviews.lazy.compactMap { toolbarObserver(in: $0) }.first
            }
            func settle() async throws {
                let deadline = Date().addingTimeInterval(10)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                    }
                    if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)),
                       state.pendingReflowPosition == nil, state.currentPosition.nativePassage != nil { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline && state.error == nil
                for _ in 0..<15 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertNil(state.error)
                XCTAssertNotNil(state.currentPosition.nativePassage)
            }
            for fullscreen in [false, true, false] {
                window.fullscreen = fullscreen
                NotificationCenter.default.post(name: fullscreen ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification,
                                                object: window)
                try await settle()
                let scroll = try XCTUnwrap(state.readerScrollView)
                let installedToolbar = try XCTUnwrap(window.toolbar)
                let observer = try XCTUnwrap(toolbarObserver(in: host))
                let frame = scroll.convert(scroll.bounds, to: nil)
                let viewport = scroll.contentView.safeAreaRect.size
                let generation = state.chapterLayout?.generation
                let position = state.currentPosition.nativePassage
                let revision = state.renderRevision
                XCTAssertLessThan(window.contentLayoutRect.maxY, window.frame.height,
                                  "The fixture must have installed native chrome above the reading area")
                func checkReservedChrome() {
                    let readingRect = scroll.contentView.convert(scroll.contentView.safeAreaRect, to: nil)
                    let reservedMenu = fullscreen ? menuHeight : 0
                    XCTAssertEqual(window.contentLayoutRect.maxY - readingRect.maxY, reservedMenu, accuracy: 0.1,
                                   "Fullscreen must also reserve the menu above the installed toolbar and tabs; normal windows need no extra gap")
                    XCTAssertTrue(installedToolbar.isVisible, "Reader modes keep native chrome layout installed")
                }
                checkReservedChrome()
                for shown in [true, false, true, false] {
                    state.toolbarHoverVisible = shown; state.toolbarHoverOpacity = shown ? 1 : 0
                    observer.updateChrome(revealingNativeControls: shown)
                    try await settle()
                    XCTAssertEqual(scroll.convert(scroll.bounds, to: nil), frame, flow)
                    XCTAssertEqual(scroll.contentView.safeAreaRect.size, viewport, flow)
                    checkReservedChrome()
                    XCTAssertEqual(state.chapterLayout?.generation, generation, "Hover must not paginate the book again")
                    XCTAssertEqual(state.renderRevision, revision, "Hover must not schedule a replacement surface")
                    XCTAssertEqual(state.currentPosition.nativePassage, position, "Hover must preserve the reading passage")
                }
            }
            XCTAssertFalse(window.isVisible, "This regression must not activate or display a test window")
        }
    }

    func testHiddenToolbarReclaimsTitlebarAndFollowsDocumentTheme() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let originalBackground = window.backgroundColor
        let originalMouseMoved = window.acceptsMouseMovedEvents
        let toolbar = NSToolbar(identifier: "toolbar-layout-test")
        window.toolbar = toolbar
        let observer = ReaderToolbarWindow.Host()
        observer.reducedMotion = true
        observer.state = state
        window.contentView?.addSubview(observer)
        defer { observer.detach(); observer.removeFromSuperview(); window.close(); state.windowClosed() }

        func apply() {
            observer.updateChrome()
            // Auto Hide leaves native chrome installed; its items/background
            // fade while the document continues through the titlebar.
            toolbar.isVisible = true
            observer.updateChrome()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let frame = window.frame
        for theme in ["light", "light-warm", "dark", "dracula", "gruvbox"] {
            state.theme = theme; apply()
            XCTAssertTrue(toolbar.isVisible)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(type)).isHidden)
            }
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
            XCTAssertTrue(window.titlebarAppearsTransparent)
            XCTAssertEqual(window.titleVisibility, .hidden)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none)
            XCTAssertEqual(window.contentView?.frame.maxY ?? 0, window.frame.height, accuracy: 0.1,
                           "The book must occupy the unused titlebar space")
            XCTAssertEqual(window.backgroundColor, ReaderTheme.color(state.palette.background), theme)
        }
        let hiddenHeight = try XCTUnwrap(window.contentView).frame.height
        observer.pointerMoved(to: NSPoint(x: 320, y: window.frame.height - 1))
        apply()
        XCTAssertTrue(toolbar.isVisible)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(type)).isHidden)
        }
        XCTAssertEqual(window.frame, frame, "Revealing must not resize or move the reader window")
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(try XCTUnwrap(window.contentView).frame.height, hiddenHeight, accuracy: 0.1,
                       "Hover controls must overlay the book without resizing its viewport")
        observer.pointerMoved(to: NSPoint(x: 320, y: window.contentLayoutRect.maxY + 1))
        XCTAssertTrue(state.toolbarHoverVisible, "Controls stay usable after entering the toolbar")
        observer.pointerMoved(to: NSPoint(x: 320, y: window.contentLayoutRect.midY))
        apply()
        XCTAssertTrue(toolbar.isVisible)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(type)).isHidden)
        }
        XCTAssertEqual(window.frame, frame, "Hiding must reclaim content space in the same window frame")
        XCTAssertEqual(try XCTUnwrap(window.contentView).frame.height, hiddenHeight, accuracy: 0.1)

        observer.detach()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.titlebarAppearsTransparent)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(type)).isHidden)
        }
        XCTAssertEqual(window.backgroundColor, originalBackground)
        XCTAssertEqual(window.acceptsMouseMovedEvents, originalMouseMoved)
        XCTAssertFalse(window.isVisible, "Geometry checks must leave the user's windows undisturbed")
    }

    func testBorderlessReaderViewCanHostAutoHiddenChrome() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/borderless-toolbar.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertEqual(host.frame.size, CGSize(width: 700, height: 500))
        XCTAssertFalse(window.isVisible)
    }

    func testNarrowToolbarHidesNativeOverflowWithoutChangingItsLayout() async throws {
        final class Items: NSObject, NSToolbarDelegate {
            func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
                (0..<7).map { .init("overflow-\($0)") }
            }
            func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
                toolbarAllowedItemIdentifiers(toolbar)
            }
            func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                         willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
                let item = NSToolbarItem(itemIdentifier: identifier)
                let button = NSButton(title: "Reader action", target: nil, action: nil)
                button.widthAnchor.constraint(equalToConstant: 120).isActive = true
                item.label = identifier.rawValue; item.view = button
                return item
            }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/overflow-toolbar.txt"), content: .text("book"))
        state.toolbarDisplayMode = .shown
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true
        window.toolbarStyle = .unifiedCompact
        let items = Items(), toolbar = NSToolbar(identifier: "narrow-overflow-toolbar")
        toolbar.delegate = items; window.toolbar = toolbar
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer {
            observer.detach(); window.contentView = nil; window.close(); state.windowClosed()
            withExtendedLifetime(items) {}
        }
        // AppKit installs overflow controls when the window is ordered. Keep
        // this window transparent and unable to receive the user's input.
        window.orderBack(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        let root = try XCTUnwrap(window.contentView?.superview)
        func toolbarView(in view: NSView) -> NSView? {
            if view.accessibilityRole() == .toolbar { return view }
            return view.subviews.lazy.compactMap { toolbarView(in: $0) }.first
        }
        let nativeToolbar = try XCTUnwrap(toolbarView(in: root))
        XCTAssertGreaterThan(toolbar.items.count, try XCTUnwrap(toolbar.visibleItems).count,
                             "The fixture must contain AppKit's real overflow control")
        let frame = window.frame, layout = window.contentLayoutRect, viewport = window.contentView?.frame
        for mode in [ReaderToolbarDisplayMode.auto, .hidden, .shown, .auto] {
            state.toolbarDisplayMode = mode
            observer.updateChrome()
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(nativeToolbar.isHidden, mode != .shown)
            XCTAssertEqual(nativeToolbar.alphaValue, mode == .shown ? 1 : 0, accuracy: 0.001)
            if mode != .shown {
                XCTAssertNil(nativeToolbar.hitTest(NSPoint(x: nativeToolbar.bounds.maxX - 20, y: nativeToolbar.bounds.midY)),
                             "Hidden overflow must not intercept clicks on the book")
            }
            XCTAssertTrue(toolbar.isVisible, "The native toolbar layout must remain installed")
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(window.contentLayoutRect, layout)
            XCTAssertEqual(window.contentView?.frame, viewport)
        }
        observer.pointerMoved(to: NSPoint(x: 280, y: window.frame.height - 1))
        observer.updateChrome()
        XCTAssertFalse(nativeToolbar.isHidden)
        XCTAssertEqual(nativeToolbar.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.contentLayoutRect, layout)
        observer.detach()
        XCTAssertFalse(nativeToolbar.isHidden)
        XCTAssertEqual(nativeToolbar.alphaValue, 1, accuracy: 0.001)
    }

    func testBothNativeTabHostsKeepControlsUsableAcrossTabSelection() throws {
        _ = NSApplication.shared
        let states = (0..<2).map { index in
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/tabbed-toolbar-\(index).txt"), content: .text("book"))
            state.toolbarDisplayMode = .auto
            return state
        }
        let windows = (0..<2).map { index in
            let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Selecting a native tab orders its window in. Keep this real
            // AppKit selection test invisible and unable to intercept input.
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.toolbar = NSToolbar(identifier: "tabbed-toolbar-host-\(index)")
            return window
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        let group = try XCTUnwrap(windows[0].tabGroup)
        let observers = states.enumerated().map { index, state in
            let observer = ReaderToolbarWindow.Host()
            observer.state = state; observer.reducedMotion = true
            windows[index].contentView?.addSubview(observer)
            return observer
        }
        defer {
            for observer in observers { observer.detach() }
            for window in windows { window.contentView = nil; window.close() }
            for state in states { state.windowClosed() }
        }
        for index in [0, 1, 0, 1] {
            group.selectedWindow = windows[index]
            let window = windows[index], observer = observers[index]
            let frame = window.frame, layout = window.contentLayoutRect
            for shown in [true, false, true] {
                observer.pointerMoved(to: NSPoint(x: 350, y: shown ? window.frame.height - 1 : 100))
                for host in observers { host.updateChrome() }
                XCTAssertTrue(group.selectedWindow === window)
                for view in window.titlebarAccessoryViewControllers.map(\.view) {
                    XCTAssertEqual(view.isHidden, !shown)
                    XCTAssertEqual(view.alphaValue, shown ? 1 : 0, accuracy: 0.001)
                }
                XCTAssertEqual(window.frame, frame)
                XCTAssertEqual(window.contentLayoutRect, layout)
            }
        }
        for window in windows { XCTAssertEqual(window.alphaValue, 0); XCTAssertTrue(window.ignoresMouseEvents) }
    }

    func testSharedDetachedChromeKeepsSelectedTabOwnershipAcrossModeChanges() throws {
        _ = NSApplication.shared
        let states = (0..<2).map { index in
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/shared-toolbar-\(index).txt"), content: .text("book"))
            state.toolbarDisplayMode = .auto
            return state
        }
        let windows = (0..<2).map { _ in
            let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            return window
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        let group = try XCTUnwrap(windows[0].tabGroup)
        group.selectedWindow = windows[0]
        let companion = NSWindow(contentRect: CGRect(x: 2000, y: 600, width: 700, height: 70),
            styleMask: .borderless, backing: .buffered, defer: false)
        companion.isReleasedWhenClosed = false; companion.alphaValue = 0
        let content = try XCTUnwrap(companion.contentView)
        content.alphaValue = 0.7
        windows[0].addChildWindow(companion, ordered: .above)
        let observers = states.enumerated().map { index, state in
            let observer = ReaderToolbarWindow.Host()
            observer.state = state; observer.reducedMotion = true
            windows[index].contentView?.addSubview(observer)
            return observer
        }
        for window in windows { content.addSubview(try XCTUnwrap(window.standardWindowButton(.closeButton))) }
        defer {
            for observer in observers { observer.detach() }
            companion.parent?.removeChildWindow(companion); companion.close()
            for window in windows { window.contentView = nil; window.close() }
            for state in states { state.windowClosed() }
        }
        observers[0].updateChrome()
        XCTAssertEqual(content.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(companion.ignoresMouseEvents)

        group.selectedWindow = windows[1]
        windows[0].removeChildWindow(companion)
        windows[1].addChildWindow(companion, ordered: .above)
        // Tab selection installs the selected window's own native controls;
        // fullscreen then moves those controls into its shared companion.
        content.addSubview(try XCTUnwrap(windows[1].standardWindowButton(.closeButton)))
        observers[1].updateChrome()
        states[1].toolbarDisplayMode = .hidden
        observers[1].updateChrome()
        states[1].toolbarDisplayMode = .shown
        observers[1].updateChrome()
        XCTAssertEqual(content.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(companion.ignoresMouseEvents, "The new tab must not preserve the old tab's hidden mouse state")

        observers[0].updateChrome()
        observers[0].detach()
        XCTAssertEqual(content.alphaValue, 1, accuracy: 0.001, "Inactive-tab teardown must not overwrite selected chrome")
        XCTAssertFalse(companion.ignoresMouseEvents)
        observers[1].detach()
        XCTAssertEqual(content.alphaValue, 0.7, accuracy: 0.001, "Restore the original appearance, not a hidden snapshot from another tab")
        XCTAssertFalse(companion.ignoresMouseEvents)
    }

    func testNativeTabsFadeWithToolbarWithoutCollapsingTheirLayout() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/tabbed-toolbar.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let sibling = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; sibling.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "tabbed-toolbar")
        window.addTabbedWindow(sibling, ordered: .above)
        let group = try XCTUnwrap(window.tabGroup)
        XCTAssertTrue(group.isTabBarVisible)
        let accessories = window.titlebarAccessoryViewControllers.map(\.view)
        XCTAssertFalse(accessories.isEmpty, "AppKit exposes the native tab bar as a titlebar accessory")
        for view in accessories {
            view.alphaValue = 0.75; view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemPink.cgColor
        }
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer {
            observer.detach(); window.contentView = nil
            sibling.close(); window.close(); state.windowClosed()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let frame = window.frame
        let viewport = try XCTUnwrap(window.contentView).frame
        let layout = window.contentLayoutRect
        let accessoryFrames = accessories.map(\.frame)
        for shown in [false, true, false, true, false] {
            if shown { observer.pointerMoved(to: NSPoint(x: 350, y: window.frame.height - 1)) }
            else { observer.pointerMoved(to: NSPoint(x: 350, y: 100)) }
            observer.updateChrome()
            window.contentView?.layoutSubtreeIfNeeded()
            for view in accessories {
                XCTAssertEqual(view.alphaValue, shown ? 0.75 : 0, accuracy: 0.001)
                XCTAssertEqual(view.isHidden, !shown)
                if !shown { XCTAssertNil(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)),
                    "Invisible native tabs must not intercept clicks on the book") }
            }
            XCTAssertTrue(group.isTabBarVisible, "The native tab layout stays installed while its views fade")
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(window.contentView?.frame, viewport)
            XCTAssertEqual(window.contentLayoutRect, layout)
            XCTAssertEqual(accessories.map(\.frame), accessoryFrames)
        }
        state.toolbarDisplayMode = .shown
        observer.updateChrome()
        for view in accessories { XCTAssertFalse(view.isHidden); XCTAssertEqual(view.alphaValue, 0.75, accuracy: 0.001) }
        let originalTheme = state.theme
        defer { state.theme = originalTheme }
        for theme in ["light", "dark"] {
            state.theme = theme; observer.updateChrome()
            for view in accessories {
                let background = try XCTUnwrap(view.layer?.backgroundColor)
                XCTAssertEqual(background.alpha, 1, "Revealed tabs need an opaque background over the book")
                XCTAssertEqual(NSColor(cgColor: background), ReaderTheme.color(state.palette.background))
            }
        }
        state.toolbarDisplayMode = .hidden
        observer.updateChrome()
        for view in accessories { XCTAssertTrue(view.isHidden) }
        observer.detach()
        for view in accessories {
            XCTAssertFalse(view.isHidden); XCTAssertEqual(view.alphaValue, 0.75, accuracy: 0.001)
            XCTAssertEqual(view.layer?.backgroundColor, NSColor.systemPink.cgColor)
        }
        XCTAssertFalse(window.isVisible); XCTAssertFalse(sibling.isVisible)
    }

    func testDetachedToolbarSurvivesNavigationRemovalAndRestoresItsWindowWhenReattached() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/detached-toolbar.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let child = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 38),
                             styleMask: .borderless, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; child.isReleasedWhenClosed = false
        parent.addChildWindow(child, ordered: .above)
        child.alphaValue = 0.8
        let content = try XCTUnwrap(child.contentView)
        content.alphaValue = 0.7
        let field = NSTextField(string: "1")
        child.contentView?.addSubview(field)
        state.pageInputField = field; state.window = parent
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        parent.contentView?.addSubview(observer)
        let closeButton = try XCTUnwrap(parent.standardWindowButton(.closeButton))
        child.contentView?.addSubview(closeButton)
        defer {
            observer.detach(); parent.removeChildWindow(child); child.close(); parent.close(); state.windowClosed()
        }
        let parentFrame = parent.frame, childFrame = child.frame, parentAlpha = parent.alphaValue
        var nativeAlpha: CGFloat = 0.8
        func check(_ alpha: CGFloat, ignoresMouse: Bool) {
            observer.updateChrome()
            XCTAssertEqual(content.alphaValue, alpha, accuracy: 0.001)
            XCTAssertEqual(child.alphaValue, nativeAlpha, accuracy: 0.001, "The fullscreen companion retains window-alpha ownership")
            XCTAssertEqual(child.ignoresMouseEvents, ignoresMouse)
            XCTAssertEqual(parent.frame, parentFrame); XCTAssertEqual(child.frame, childFrame)
            XCTAssertEqual(parent.alphaValue, parentAlpha)
            XCTAssertFalse(parent.ignoresMouseEvents)
        }
        check(0, ignoresMouse: true)
        // The fullscreen companion writes window alpha after the entry event.
        // Its later writes must leave the hidden toolbar content untouched.
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: parent)
        child.alphaValue = 1
        nativeAlpha = 1
        check(0, ignoresMouse: true)
        observer.pointerMoved(to: NSPoint(x: 320, y: parent.frame.height - 40))
        check(1, ignoresMouse: false)
        state.pageInputField = nil
        field.removeFromSuperview()
        check(1, ignoresMouse: false)
        state.toolbarDisplayMode = .hidden
        check(0, ignoresMouse: true)
        state.toolbarDisplayMode = .shown
        check(1, ignoresMouse: false)
        state.presentation = true
        check(0, ignoresMouse: true)
        state.presentation = false
        check(1, ignoresMouse: false)
        state.toolbarDisplayMode = .auto
        check(0, ignoresMouse: true)
        parent.contentView?.addSubview(closeButton)
        check(0.7, ignoresMouse: false)
        XCTAssertFalse(parent.isVisible); XCTAssertFalse(child.isVisible)
    }

    func testNativeMenuRevealShowsWindowControlsWithoutRevealingHiddenReaderChrome() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-menu-toolbar.txt"), content: .text("book"))
        let parent = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let companion = NSWindow(contentRect: CGRect(x: 2000, y: 600, width: 700, height: 70),
            styleMask: .borderless, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; companion.isReleasedWhenClosed = false
        parent.alphaValue = 0; companion.alphaValue = 0
        parent.addChildWindow(companion, ordered: .above)
        let content = try XCTUnwrap(companion.contentView)
        // AppKit hosts the reader toolbar and tab accessory below the same
        // fullscreen companion that owns native window controls.
        let tools = NSView(frame: CGRect(x: 100, y: 0, width: 500, height: 38))
        tools.setAccessibilityRole(.toolbar)
        tools.addSubview(NSButton(title: "Reader action", target: nil, action: nil))
        content.addSubview(tools)
        let tabs = NSTitlebarAccessoryViewController()
        tabs.view = NSView(frame: CGRect(x: 0, y: 38, width: 700, height: 25))
        parent.addTitlebarAccessoryViewController(tabs)
        content.addSubview(tabs.view)
        let close = try XCTUnwrap(parent.standardWindowButton(.closeButton))
        content.addSubview(close)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        parent.contentView?.addSubview(observer)
        defer {
            observer.detach(); parent.contentView = nil
            parent.removeChildWindow(companion); companion.close(); parent.close(); state.windowClosed()
        }
        let frame = parent.frame, viewport = parent.contentView?.frame, layout = parent.contentLayoutRect
        let companionFrame = companion.frame
        for mode in [ReaderToolbarDisplayMode.hidden, .auto, .shown] {
            state.toolbarDisplayMode = mode
            for presentation in [false, true] {
                state.presentation = presentation
                // A stale hover or an actual top-edge hover must never reveal
                // reader tools during Always Hide or presentation.
                observer.pointerMoved(to: NSPoint(x: 350, y: parent.frame.height - 1))
                if presentation { state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1 }
                observer.updateChrome(revealingNativeControls: true)
                let readerVisible = !presentation && mode != .hidden
                XCTAssertEqual(state.toolbarShown, readerVisible,
                               "Presentation must suppress toolbar state even when an Auto Hide hover is still set")
                XCTAssertEqual(content.alphaValue, 1, accuracy: 0.001)
                XCTAssertFalse(companion.ignoresMouseEvents, "Native controls must remain interactive on menu reveal")
                XCTAssertFalse(close.isHidden)
                for view in [tools, tabs.view] {
                    XCTAssertEqual(view.isHidden, !readerVisible)
                    XCTAssertEqual(view.alphaValue, readerVisible ? 1 : 0, accuracy: 0.001)
                    if !readerVisible {
                        XCTAssertNil(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)),
                                     "Hidden reader tools and tabs must not intercept native controls or book input")
                    }
                }
                if readerVisible {
                    XCTAssertEqual(tabs.view.layer?.backgroundColor, ReaderTheme.color(state.palette.background).cgColor)
                }
                XCTAssertEqual(parent.frame, frame); XCTAssertEqual(parent.contentView?.frame, viewport)
                XCTAssertEqual(parent.contentLayoutRect, layout); XCTAssertEqual(companion.frame, companionFrame)
            }
        }
        // Returning from native menu reveal must hand opacity back to the
        // companion without leaving a child toolbar at zero opacity.
        state.presentation = false; state.toolbarDisplayMode = .auto
        observer.pointerMoved(to: NSPoint(x: 350, y: parent.frame.height - 1))
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertEqual(content.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(tools.isHidden); XCTAssertEqual(tools.alphaValue, 1, accuracy: 0.001)
        state.toolbarDisplayMode = .hidden
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertEqual(content.alphaValue, 0, accuracy: 0.001)
        XCTAssertTrue(companion.ignoresMouseEvents)
    }

    func testThreeModesControlHoverAndPresentationWithoutChangingTheChoice() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar.txt"), content: .text("book"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.reducedMotion = true; observer.state = state
        window.contentView?.addSubview(observer)
        defer { observer.detach(); observer.removeFromSuperview(); window.close(); state.windowClosed() }
        let top = NSPoint(x: 320, y: window.frame.height - 1)
        for mode in ReaderToolbarDisplayMode.allCases {
            for presentation in [false, true] {
                state.toolbarDisplayMode = mode; state.presentation = presentation
                state.toolbarHoverVisible = false
                XCTAssertEqual(state.toolbarShown, mode == .shown && !presentation)
                XCTAssertEqual(state.toolbarOverlaysContent, mode != .shown || presentation)
                observer.pointerMoved(to: top)
                XCTAssertEqual(state.toolbarHoverVisible, mode == .auto && !presentation)
                XCTAssertEqual(state.toolbarShown, !presentation && (mode == .auto || mode == .shown))
                XCTAssertEqual(state.toolbarDisplayMode, mode)
                observer.pointerMoved(to: NSPoint(x: top.x, y: window.frame.height + 1))
                XCTAssertFalse(state.toolbarHoverVisible)
                observer.pointerMoved(to: top)
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                XCTAssertFalse(state.toolbarHoverVisible)
            }
        }
        state.presentation = false; state.toolbarDisplayMode = .auto
        observer.pointerMoved(to: top)
        XCTAssertTrue(state.toolbarShown)
        state.toolbarDisplayMode = .hidden
        XCTAssertFalse(state.toolbarShown, "Always Hide must cancel an existing hover immediately")
        XCTAssertEqual(state.toolbarHoverOpacity, 0)
        state.toolbarDisplayMode = .shown
        XCTAssertTrue(state.toolbarShown)
        state.document = nil
        observer.pointerMoved(to: top)
        XCTAssertFalse(state.toolbarShown)
        XCTAssertFalse(window.isVisible)
    }

    func testToolbarModeMigratesOldPreferenceOnceAndPreservesNewChoice() throws {
        let suite = "SumraToolbarTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReaderToolbarDisplayMode.load(from: defaults), .shown)
        for enabled in [false, true] {
            defaults.removeObject(forKey: "toolbarDisplayMode")
            defaults.set(enabled, forKey: "revealHiddenToolbar")
            XCTAssertEqual(ReaderToolbarDisplayMode.load(from: defaults), enabled ? .auto : .shown)
            XCTAssertNil(defaults.object(forKey: "revealHiddenToolbar"))
        }
        defaults.set("hidden", forKey: "toolbarDisplayMode")
        defaults.set(true, forKey: "revealHiddenToolbar")
        XCTAssertEqual(ReaderToolbarDisplayMode.load(from: defaults), .hidden)
    }

    func testModeRoundTripsAndUpdatesEveryOpenReaderAndNewReaders() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, key = "toolbarDisplayMode"
        let original = defaults.object(forKey: key)
        let readers = [ReaderState(recordsHistory: false), ReaderState(recordsHistory: false)]
        let windows = readers.map { state -> NSWindow in
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; state.window = window
            return window
        }
        let delegates = readers.map { ReaderCloseGuard(state: $0, previous: nil) }
        for (window, delegate) in zip(windows, delegates) { window.delegate = delegate }
        defer {
            withExtendedLifetime(delegates) {}
            for (window, state) in zip(windows, readers) { window.delegate = nil; window.close(); state.windowClosed() }
            defaults.set(original, forKey: key)
        }
        for mode in ReaderToolbarDisplayMode.allCases {
            mode.apply()
            XCTAssertTrue(readers.allSatisfy { $0.toolbarDisplayMode == mode })
            XCTAssertEqual(ReaderState(recordsHistory: false).toolbarDisplayMode, mode, "New windows restore the shared choice")
            let data = try ReaderPreferences.data(matching: key)
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(exported[key], mode.rawValue)
            try ReaderPreferences.apply(Data("{\"toolbarDisplayMode\":\"shown\"}".utf8))
            try ReaderPreferences.apply(data)
            XCTAssertTrue(readers.allSatisfy { $0.toolbarDisplayMode == mode })
        }
        for invalid in ["true", "\"invalid\""] {
            XCTAssertThrowsError(try ReaderPreferences.apply(Data("{\"toolbarDisplayMode\":\(invalid)}".utf8)))
            XCTAssertEqual(defaults.string(forKey: key), "hidden")
        }
        XCTAssertTrue(windows.allSatisfy { !$0.isVisible })
    }

    func testHoverEntryAndExitStayStableWhenNativeChromeChangesLayout() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar-hysteresis.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "toolbar-hover-hysteresis-test")
        window.toolbar = toolbar
        let observer = ReaderToolbarWindow.Host()
        observer.reducedMotion = true
        observer.state = state
        window.contentView?.addSubview(observer)
        toolbar.isVisible = state.toolbarShown
        var changes = [Bool]()
        let observation = state.$toolbarHoverVisible.dropFirst().sink { changes.append($0) }
        defer {
            observation.cancel(); observer.detach(); observer.removeFromSuperview()
            window.close(); state.windowClosed()
        }
        let frame = window.frame
        func point(_ depth: CGFloat) -> NSPoint { NSPoint(x: frame.width / 2, y: frame.height - depth) }
        observer.pointerMoved(to: point(49))
        XCTAssertFalse(state.toolbarHoverVisible)
        observer.pointerMoved(to: point(40))
        XCTAssertTrue(state.toolbarHoverVisible, "The pointer must reveal controls well inside the window")
        observer.updateChrome()
        toolbar.isVisible = state.toolbarShown
        observer.pointerMoved(to: point(60))
        XCTAssertTrue(state.toolbarHoverVisible, "The retention region must extend below the entry region")
        for visible in [false, true, false] {
            toolbar.isVisible = visible
            window.contentView?.layoutSubtreeIfNeeded()
            observer.pointerMoved(to: point(60))
            observer.updateChrome()
            XCTAssertTrue(state.toolbarHoverVisible, "Native content-layout changes must not hide controls under a stationary pointer")
            XCTAssertEqual(window.frame, frame)
        }
        observer.pointerMoved(to: point(96))
        XCTAssertTrue(state.toolbarHoverVisible)
        XCTAssertEqual(changes, [true], "A stationary pointer must not generate repeated show/hide transitions")
        observer.pointerMoved(to: point(97))
        XCTAssertFalse(state.toolbarHoverVisible)
        observer.pointerMoved(to: point(60))
        XCTAssertFalse(state.toolbarHoverVisible, "Leaving the retention region must require re-entering the top strip")
        observer.pointerMoved(to: point(48))
        XCTAssertTrue(state.toolbarHoverVisible)
        XCTAssertEqual(changes, [true, false, true])
        XCTAssertFalse(window.isVisible)
    }

    func testExternalToolbarVisibilityPreservesFrameAfterLateInstallationAndReleasesOnDetach() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar-late.txt"), content: .text("book"))
        state.toolbarDisplayMode = .shown
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.reducedMotion = true
        observer.state = state; window.contentView?.addSubview(observer)
        defer { observer.detach(); observer.removeFromSuperview(); window.close(); state.windowClosed() }
        let toolbar = NSToolbar(identifier: "toolbar-late-observation-test")
        window.toolbar = toolbar
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        let frame = window.frame
        for shown in [false, true] {
            toolbar.isVisible = shown
            observer.updateChrome()
            XCTAssertEqual(toolbar.isVisible, shown, "The visibility owner must not be overwritten by the geometry observer")
            XCTAssertEqual(window.frame, frame, "The toolbar setter must preserve the window's pre-change frame")
        }
        observer.detach(); observer.removeFromSuperview()
        let detachedFrame = window.frame
        toolbar.isVisible = false
        XCTAssertNotEqual(window.frame, detachedFrame, "Detaching must return native toolbar sizing to its window")
        XCTAssertFalse(window.isVisible)
    }

    func testHoverRoutesOwnedChildWindowCoordinatesAndIgnoresUnrelatedWindows() throws {
        _ = NSApplication.shared
        final class DocumentWindow: NSWindow {
            var receivesPointer = true
            override var isKeyWindow: Bool { receivesPointer }
        }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar-child.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = DocumentWindow(contentRect: CGRect(x: 200, y: 180, width: 640, height: 480),
            styleMask: .titled, backing: .buffered, defer: false)
        let child = NSWindow(contentRect: CGRect(x: 250, y: window.frame.maxY - 70, width: 500, height: 60),
            styleMask: .borderless, backing: .buffered, defer: false)
        let unrelated = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        for item in [window, child, unrelated] { item.isReleasedWhenClosed = false }
        window.addChildWindow(child, ordered: .above)
        let observer = ReaderToolbarWindow.Host()
        observer.reducedMotion = true
        observer.state = state
        window.contentView?.addSubview(observer)
        defer {
            observer.detach(); observer.removeFromSuperview()
            window.removeChildWindow(child)
            for item in [child, unrelated, window] { item.close() }
            state.windowClosed()
        }
        func event(in owner: NSWindow, point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: owner.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let top = NSPoint(x: window.frame.width / 2, y: window.frame.height - 4)
        let childTop = child.convertPoint(fromScreen: window.convertPoint(toScreen: top))
        XCTAssertLessThan(childTop.y, window.frame.height - 8,
            "The child-local point must differ from the document's hover-strip coordinates")
        observer.handleMouseMoved(try event(in: child, point: childTop))
        XCTAssertTrue(state.toolbarHoverVisible, "An owned native chrome window must reveal its document's toolbar")

        state.toolbarHoverVisible = false
        observer.handleMouseMoved(try event(in: unrelated, point: top))
        XCTAssertFalse(state.toolbarHoverVisible, "A different window cannot reveal this document's toolbar")
        observer.handleMouseMoved(try event(in: window, point: top))
        XCTAssertTrue(state.toolbarHoverVisible, "Direct document events keep their original coordinate path")

        state.toolbarHoverVisible = false
        window.receivesPointer = false
        observer.handleMouseMoved(try event(in: child, point: childTop))
        XCTAssertFalse(state.toolbarHoverVisible, "Owned child events still require the document to be key")
        XCTAssertTrue([window, child, unrelated].allSatisfy { !$0.isVisible })
    }

    func testHoverRevealKeepsPageInputCompositionUntilEditingEnds() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/toolbar.txt"), content: .text("book"))
        state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.reducedMotion = true
        observer.state = state
        window.contentView?.addSubview(observer)
        let field = NSTextField(string: "1")
        field.frame = CGRect(x: 100, y: 100, width: 80, height: 24)
        window.contentView?.addSubview(field)
        state.pageInputField = field
        defer { window.makeFirstResponder(nil); observer.detach(); window.close(); state.windowClosed() }
        observer.pointerMoved(to: NSPoint(x: 320, y: window.frame.height - 1))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("2", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        observer.pointerMoved(to: NSPoint(x: 320, y: 200))
        XCTAssertTrue(state.toolbarShown)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "2")
        window.makeFirstResponder(nil)
        observer.pointerMoved(to: NSPoint(x: 320, y: 200))
        XCTAssertFalse(state.toolbarShown)
        XCTAssertFalse(window.isVisible)
    }

    func testFocusedPageInputTracksNavigationAndPreservesDraftAndComposition() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/page-input.txt"), content: .text("one\ntwo\nthree\nfour"))
        state.count = 4; state.page = 0
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window
        let host = NSHostingView(rootView: ReaderPageInput(state: state, finished: { window.makeFirstResponder(nil) })
            .frame(width: 80, height: 24))
        window.contentView = host
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); state.windowClosed() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if state.pageInputField?.window === window { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let field = try XCTUnwrap(state.pageInputField)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(window.isVisible, "The regression fixture must not disturb the user's windows")
        XCTAssertEqual(editor.string, "1")
        state.page = 1
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if editor.string == "2" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(editor.string, "2", "An untouched focused input must track external navigation")
        XCTAssertEqual(field.stringValue, "2")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertTrue(window.firstResponder === editor)

        editor.insertText("2", replacementRange: editor.selectedRange())
        state.page = 2
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if field.toolTip == state.positionLabel { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(editor.string, "2", "Even a draft equal to the old page label belongs to the user")
        window.makeFirstResponder(nil)
        XCTAssertEqual(field.stringValue, "3", "Blur discards the draft and shows the actual page")

        field.selectText(nil)
        let compositionEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        compositionEditor.setMarkedText("3", selectedRange: NSRange(location: 1, length: 0), replacementRange: compositionEditor.selectedRange())
        XCTAssertTrue(compositionEditor.hasMarkedText())
        state.page = 3
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if field.toolTip == state.positionLabel { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(compositionEditor.string, "3")
        XCTAssertTrue(compositionEditor.hasMarkedText(), "Navigation must leave input method composition intact")
    }

    func testPageInputFocusSelectsTextAndReturnCommitsWhileEscapeAndBlurDiscard() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/page-input.txt"), content: .text("one\ntwo\nthree\nfour"))
        state.count = 4; state.page = 2; state.toolbarDisplayMode = .shown
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; state.window = window
        let host = NSHostingView(rootView: ReaderPageInput(state: state, finished: { window.makeFirstResponder(nil) })
            .frame(width: 80, height: 24))
        window.contentView = host
        if let display = ProcessInfo.processInfo.environment["SUMRA_TEST_DISPLAY_NAME"] {
            let screen = try XCTUnwrap(NSScreen.screens.first { $0.localizedName == display })
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
        }
        window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close(); state.windowClosed() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if state.pageInputField?.window === window { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let field = try XCTUnwrap(state.pageInputField)
        ReaderMenuCommand.goToPage.run(state)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "3")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertEqual(state.page, 2, "Focusing the input must not navigate")
        editor.insertText("4", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(field.stringValue, "4")
        XCTAssertNil(field.currentEditor())

        ReaderMenuCommand.goToPage.run(state)
        let nextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        nextEditor.insertText("2", replacementRange: nextEditor.selectedRange())
        ReaderMenuCommand.goToPage.run(state)
        XCTAssertEqual(nextEditor.string, "2", "Repeated focus preserves the draft and selects it")
        XCTAssertEqual(nextEditor.selectedRange(), NSRange(location: 0, length: 1))
        nextEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(state.page, 3)
        XCTAssertEqual(field.stringValue, "4")
        XCTAssertNil(field.currentEditor())

        ReaderMenuCommand.goToPage.run(state)
        let lastEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        lastEditor.insertText("1", replacementRange: lastEditor.selectedRange())
        window.makeFirstResponder(nil)
        XCTAssertEqual(state.page, 3, "Leaving an unfinished draft must not navigate")
        XCTAssertEqual(field.stringValue, "4")

        state.page = 0
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if field.stringValue == "1" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(field.stringValue, "1", "Navigation outside the field must refresh its displayed page")
    }

    func testToolbarTargetsExistingCommandsAndKeepsUserOrder() throws {
        let entries = try ReaderToolbarButton.read("""
        [{"command":"next","symbol":"chevron.right"},{"external":"Preview","text":"Open Preview"},{"custom":"Next 3 pages","text":"Next three"},{"command":"next","text":"Next"}]
        """)
        XCTAssertEqual(entries.map(\.command), ["next", nil, nil, "next"])
        XCTAssertEqual(entries[1].external, "Preview")
        XCTAssertEqual(entries[2].custom, "Next 3 pages")
        for invalid in ["[{}]", "[{\"command\":\"missing\"}]", "[{\"external\":\"  \"}]",
                        "[{\"command\":\"next\",\"external\":\"Preview\"}]", "[{\"command\":\"next\",\"custom\":\"Next 3 pages\"}]",
                        "[{\"external\":\"Preview\",\"custom\":\"Next 3 pages\"}]", "[{\"custom\":\"  \"}]",
                        "[{\"command\":\"next\",\"symbol\":\"invalid-sumra-symbol\"}]"] {
            XCTAssertThrowsError(try ReaderToolbarButton.read(invalid))
        }
    }

    func testSVGIconsUseMuPDFWithAlphaAndExplicitColor() throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("MuPDF engine is not built") }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><circle cx=\"10\" cy=\"10\" r=\"6\" fill=\"#d00000\"/></svg>"
        let image = try ReaderToolbarSVGRenderer.render(svg, size: 40)
        XCTAssertEqual(image.width, 40); XCTAssertEqual(image.height, 40)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertEqual(bytes[3], 0)
        let center = 20 * image.bytesPerRow + 20 * 4
        XCTAssertGreaterThan(bytes[center], 190)
        XCTAssertLessThan(bytes[center + 1], 10)
        XCTAssertEqual(bytes[center + 3], 255)
        XCTAssertThrowsError(try ReaderToolbarSVGRenderer.render("<svg><broken", size: 40))
        XCTAssertEqual(try ReaderToolbarSVGRenderer.render(svg, size: 20).width, 20)
    }
}
#endif
