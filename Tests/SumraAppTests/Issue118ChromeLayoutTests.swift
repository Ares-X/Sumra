#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class Issue118ChromeLayoutTests: XCTestCase {
    func testLateMountedReaderScrollViewGetsClearanceWithoutResizing() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 600, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)
        let clearance = ReaderScrollbarClearance.Host(frame: root.bounds)
        clearance.state = state; clearance.top = 52; clearance.bottom = 56
        root.addSubview(clearance)
        clearance.updateScrollbars()
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 4000))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
        scroll.postsFrameChangedNotifications = false
        // Raster configuration can publish before AppKit attaches the view.
        state.readerScrollView = scroll
        XCTAssertNil(scroll.window)
        root.addSubview(scroll, positioned: .below, relativeTo: clearance)
        scroll.tile()
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        let clip = scroll.contentView.frame
        // The mounted canvas publishes the same scroll owner after attachment.
        // The first track must be correct without a resize or a second chrome update.
        state.readerScrollView = scroll
        XCTAssertEqual(scroll.scrollerInsets.top, 52)
        XCTAssertEqual(scroll.scrollerInsets.bottom, 56)
        XCTAssertEqual(scroll.contentView.frame, clip)
        let track = clearance.convert(try XCTUnwrap(scroll.verticalScroller).bounds, from: scroll.verticalScroller)
        XCTAssertGreaterThanOrEqual(track.minY, 52)
        XCTAssertLessThanOrEqual(track.maxY, clearance.bounds.maxY - 56)
        // A sibling's final SwiftUI layout can arrive after the chrome update.
        scroll.frame = CGRect(x: 0, y: 56, width: 600, height: 500 - 52 - 56)
        XCTAssertEqual(scroll.scrollerInsets.top, 0)
        XCTAssertEqual(scroll.scrollerInsets.bottom, 0)
        clearance.removeFromSuperview()
        XCTAssertFalse(scroll.postsFrameChangedNotifications, "Releasing chrome restores the reader's notification setting")
    }

    func testFullscreenChromeSwitchPreservesNativeMenuClearanceWithoutAddingFloatingSpace() async throws {
        final class FullscreenWindow: NSWindow {
            override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
            override var styleMask: NSWindow.StyleMask {
                get { super.styleMask.union(.fullScreen) }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let savedMenu = NSApp.mainMenu
        if NSApp.mainMenu == nil { NSApp.mainMenu = NSMenu(title: "Sumra") }
        defer { NSApp.mainMenu = savedMenu }
        let menuHeight = try XCTUnwrap(NSApp.mainMenu).menuBarHeight
        XCTAssertGreaterThan(menuHeight, 0)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/fullscreen-inset.txt"), content: .text("Book"))
        state.immersiveControls = false; state.toolbarDisplayMode = .shown
        let window = FullscreenWindow(contentRect: CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        var inset: CGFloat = -1
        observer.fullscreenMenuInset = Binding(get: { inset }, set: { inset = $0 })
        window.contentView?.addSubview(observer)
        defer { observer.detach(); state.windowClosed(); window.contentView = nil; window.close() }
        for excludedMenuHeight in [CGFloat(0), menuHeight] {
            window.setFrame(CGRect(x: screen.frame.minX + 40, y: screen.frame.maxY - excludedMenuHeight - 500,
                width: 700, height: 500), display: false)
            XCTAssertTrue(window.screen === screen, "The invisible fixture must use the measured screen")
            for floating in [false, true, false] {
                state.immersiveControls = floating
                let expected = floating ? 0 : menuHeight - excludedMenuHeight
                for menuVisible in [false, true, false] {
                    observer.updateChrome(revealingNativeControls: menuVisible)
                    try await Task.sleep(nanoseconds: 10_000_000)
                    XCTAssertEqual(inset, expected, accuracy: 0.01,
                        floating
                            ? "Floating chrome must retain its windowed inset while AppKit overlays transient native chrome"
                            : "Native chrome must reserve only the menu strip not already excluded by the fullscreen frame")
                }
            }
        }
    }

    func testAlwaysHiddenTabbedToolbarLeavesOnlyHoveredTrafficLightsAndPreservesSharedCaptions() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let states = try (0..<2).map { index in
            let file = directory.url.appendingPathComponent("Native title \(index).txt")
            try "A real represented document.\n".write(to: file, atomically: true, encoding: .utf8)
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: file, content: .text("A real represented document.\n"))
            state.immersiveControls = false; state.toolbarDisplayMode = .shown
            state.showContents = false; state.showAI = false; state.showFind = false
            return state
        }
        let windows = states.map { state in
            let title = state.document!.url.lastPathComponent
            let controller = NSHostingController(rootView: ReaderView(state: state).navigationTitle(title))
            let window = NSWindow(contentViewController: controller)
            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
            window.setFrame(CGRect(x: 2200, y: 100, width: 900, height: 700), display: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            window.toolbarStyle = .unifiedCompact
            window.representedURL = state.document!.url
            state.window = window
            return window
        }
        let state = states[0], window = windows[0]
        window.addTabbedWindow(windows[1], ordered: .above)
        var group = try XCTUnwrap(window.tabGroup)
        for state in states { state.tabCount = group.windows.count }
        let closeGuards = zip(windows, states).map { window, state in
            let closeGuard = ReaderCloseGuard(state: state, previous: window.delegate)
            window.delegate = closeGuard
            return closeGuard
        }
        group.selectedWindow = window; window.orderBack(nil)
        defer {
            for state in states { state.windowClosed() }
            for (window, closeGuard) in zip(windows, closeGuards) {
                window.delegate = closeGuard.previous
                window.contentViewController = nil; window.orderOut(nil); window.close()
            }
            withExtendedLifetime(directory) {}
        }
        func settle() async throws {
            for _ in 0..<20 {
                for window in windows { window.contentView?.layoutSubtreeIfNeeded() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func chromeHost(in view: NSView) -> ReaderToolbarWindow.Host? {
            (view as? ReaderToolbarWindow.Host) ?? view.subviews.lazy.compactMap { chromeHost(in: $0) }.first
        }
        try await settle()
        let content = try XCTUnwrap(window.contentView), root = try XCTUnwrap(content.superview)
        let observer = try XCTUnwrap(chromeHost(in: content))
        observer.reducedMotion = true
        let accessories = window.titlebarAccessoryViewControllers.filter { !($0 is ReaderNormalTabsAccessory) }
        XCTAssertFalse(accessories.isEmpty, "The fixture must mount AppKit's real native tab accessory")
        XCTAssertTrue(accessories.allSatisfy { $0.isHidden && $0.view.visibleRect.isEmpty },
            "Shared captions replace native accessory layout even with Always Show")
        XCTAssertTrue(state.normalTabBarShown)
        let proxy = try XCTUnwrap(window.standardWindowButton(.documentIconButton), "The real represented document must mount its native proxy")
        let titlebar = try XCTUnwrap(window.standardWindowButton(.closeButton)?.superview)
        let headerPoint = NSPoint(x: window.frame.width * 0.8, y: window.frame.height - 20)
        XCTAssertTrue(titlebar.convert(titlebar.bounds, to: nil).contains(headerPoint),
            "The proxy probe must use the actual native header band")
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: headerPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            window.sendEvent(event)
        }
        root.layoutSubtreeIfNeeded()
        let proxyInitiallyVisible = !proxy.isHiddenOrHasHiddenAncestor && proxy.alphaValue > 0 && !proxy.visibleRect.isEmpty
        print("Issue118 proxy Shown precondition: visible=\(proxyInitiallyVisible), hidden=\(proxy.isHidden), alpha=\(proxy.alphaValue), bounds=\(proxy.bounds), visibleRect=\(proxy.visibleRect), headerPoint=\(headerPoint)")
        if !proxyInitiallyVisible {
            print("Issue118 proxy: this isolated host did not reproduce an initially visible proxy; its hidden-state assertions are not proxy baseline-red evidence. GUI covers the physical header-click path.")
        }
        let originalProxyHidden = proxy.isHidden, originalProxyAlpha = proxy.alphaValue
        let proxyAction = proxy.action, proxyTarget = proxy.target, representedURL = window.representedURL
        let frame = window.frame
        let tabOrder = group.windows.map(\.windowNumber)
        let scroll = try XCTUnwrap(state.readerScrollView)
        let shownViewport = scroll.convert(scroll.bounds, to: nil)
        for state in states { state.toolbarDisplayMode = .hidden }
        try await settle()
        for hovered in [false, true] {
            observer.pointerMoved(to: NSPoint(x: 30, y: hovered ? window.frame.height - 10 : 100))
            observer.updateChrome(revealingNativeControls: false)
            root.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.toolbar?.isVisible ?? true)
            XCTAssertFalse(state.toolbarShown)
            for accessory in accessories {
                XCTAssertTrue(accessory.isHidden, "Always Hide must hide the native accessory controller, including its container")
                XCTAssertTrue(accessory.view.visibleRect.isEmpty, "The native tab strip must be collapsed, not only its painted leaf hidden")
            }
            XCTAssertTrue(proxy.isHidden, "Revealing three window buttons must not reveal the document proxy")
            let proxyPoint = root.convert(NSPoint(x: proxy.bounds.midX, y: proxy.bounds.midY), from: proxy)
            let proxyHit = root.hitTest(proxyPoint)
            XCTAssertFalse(proxyHit === proxy || proxyHit?.isDescendant(of: proxy) == true)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                XCTAssertEqual(button.isHiddenOrHasHiddenAncestor, !hovered)
                if hovered {
                    var ancestor: NSView? = button
                    while let view = ancestor {
                        XCTAssertGreaterThan(view.alphaValue, 0, "Every native view ancestor must paint a revealed window control")
                        XCTAssertFalse(view.visibleRect.isEmpty, "Every native view ancestor must expose a revealed window control")
                        ancestor = view.superview
                    }
                    let point = root.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    let parentPoint = try XCTUnwrap(observer.superview).convert(
                        NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
                    XCTAssertNil(observer.hitTest(parentPoint),
                        "The document overlay must yield native window controls instead of returning a view outside its subtree")
                    let hit = root.hitTest(point)
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                        "The actual native traffic light must retain its own input")
                }
            }
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(group.windows.map(\.windowNumber), tabOrder, "Collapsing native chrome must preserve the tab group")
            XCTAssertEqual(scroll.contentView.convert(scroll.contentView.safeAreaRect, to: nil).maxY, window.frame.height, accuracy: 0.1,
                "Permanently hidden native chrome releases the reading viewport through the window top")
        }
        for state in states { state.toolbarDisplayMode = .shown }
        try await settle()
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(accessories.allSatisfy(\.isHidden), "Restoring tools must retain shared ownership of captions")
        XCTAssertTrue(state.normalTabBarShown)
        XCTAssertEqual(proxy.isHidden, originalProxyHidden)
        XCTAssertEqual(proxy.alphaValue, originalProxyAlpha)
        XCTAssertEqual(proxy.action, proxyAction); XCTAssertTrue(proxy.target === proxyTarget)
        XCTAssertEqual(window.representedURL, representedURL, "Proxy visibility must retain macOS document callbacks")
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(try XCTUnwrap(state.readerScrollView).convert(scroll.bounds, to: nil), shownViewport,
            "Restoring the shown toolbar restores its existing reading geometry")
        // The shared strip's explicit single-tab choice survives toolbar mode
        // switches without changing AppKit's underlying document membership.
        group.removeWindow(windows[1])
        for state in states { state.tabCount = 1 }
        try await settle()
        XCTAssertFalse(state.normalTabBarShown)
        closeGuards[0].toggleTabBar(nil)
        try await settle()
        XCTAssertTrue(state.normalTabBarShown)
        closeGuards[0].toggleTabBar(nil)
        try await settle()
        XCTAssertFalse(state.normalTabBarShown, "The routed action hides the single shared caption")
        observer.updateChrome(revealingNativeControls: false)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.allSatisfy(\.isHidden))
        state.toolbarDisplayMode = .hidden
        try await settle()
        state.toolbarDisplayMode = .shown
        try await settle()
        XCTAssertFalse(state.normalTabBarShown, "Leaving Always Hide preserves the single-caption choice")
        closeGuards[0].toggleTabBar(nil)
        try await settle()
        XCTAssertTrue(state.normalTabBarShown)
        window.addTabbedWindow(windows[1], ordered: .above)
        group = try XCTUnwrap(window.tabGroup)
        for state in states { state.tabCount = group.windows.count }
        group.selectedWindow = window
        try await settle()
        XCTAssertEqual(group.windows.map(\.windowNumber), tabOrder)
        state.toolbarDisplayMode = .hidden
        try await settle()
        group.selectedWindow = windows[1]
        try await settle()
        let selectedContent = try XCTUnwrap(windows[1].contentView)
        let selectedObserver = try XCTUnwrap(chromeHost(in: selectedContent))
        selectedObserver.reducedMotion = true; selectedObserver.updateChrome(revealingNativeControls: false)
        let selectedAccessories = windows[1].titlebarAccessoryViewControllers.filter { !($0 is ReaderNormalTabsAccessory) }
        XCTAssertFalse(selectedAccessories.isEmpty)
        XCTAssertTrue(states[1].normalTabBarShown)
        XCTAssertTrue(selectedAccessories.allSatisfy(\.isHidden), "The selected reader keeps native captions collapsed")
        observer.detach()
        XCTAssertTrue(selectedAccessories.allSatisfy(\.isHidden), "Inactive-owner teardown must not restore native captions over the selected reader")
        XCTAssertEqual(proxy.isHidden, originalProxyHidden)
        XCTAssertEqual(proxy.action, proxyAction); XCTAssertTrue(proxy.target === proxyTarget)
        XCTAssertEqual(group.windows.map(\.windowNumber), tabOrder)
    }

    func testNormalAutoProgressReservesReadingRoomInBothHiddenToolbarModes() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, saved = defaults.object(forKey: "progressDisplayMode")
        defaults.set("auto", forKey: "progressDisplayMode")
        defer { defaults.set(saved, forKey: "progressDisplayMode") }
        let directory = try TemporaryDirectory()
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 200, height: 400, bitsPerComponent: 8,
            bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        let image = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(bitmap.makeImage())).representation(using: .png, properties: [:]))
        try image.write(to: directory.url.appendingPathComponent("page.png"))
        let pages = try Pages(directory.url, format: .comic)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: directory.url, content: .pages(pages)); state.count = 1
        state.immersiveControls = false; state.showContents = false; state.showAI = false; state.showFind = false
        state.scrollbarMode = "shown"; state.flow = "continuous"; state.fit = "actual"; state.zoom = 1
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer { state.windowClosed(); window.contentView = nil; window.orderOut(nil); window.close(); withExtendedLifetime(directory) {} }
        for mode in [ReaderToolbarDisplayMode.auto, .hidden] {
            state.toolbarDisplayMode = mode
            for _ in 0..<50 {
                host.layoutSubtreeIfNeeded()
                if state.readerScrollView != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); await Task.yield() }
            let scroll = try XCTUnwrap(state.readerScrollView)
            let frame = host.convert(scroll.bounds, from: scroll)
            let bottom = host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY - host.bounds.minY
            XCTAssertEqual(bottom, ReaderProgressFooter.height, accuracy: 1,
                "The normal Auto Hide footer needs its own reading room in \(mode), even before hover")
        }
    }
}
#endif
