#if os(macOS)
import XCTest
import AppKit
import Combine
import SwiftUI
@testable import Sumra

@MainActor
final class ReaderToolbarTests: XCTestCase {
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
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("toolbar.fb2")
        let paragraphs = (0..<100).map { "<p>Paragraph \($0) keeps its place when temporary controls overlay this book.</p>" }.joined()
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>\(paragraphs)</section></body></FictionBook>"
            .write(to: input, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let saved = ["flow", "spread", "cover"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }

        for flow in ["paged", "continuous"] {
            let document = try ReadingDocument.open(input, deferReflowLayout: true)
            guard case .pages(let pages) = document.content else { return XCTFail("Expected native book") }
            let state = ReaderState(recordsHistory: false)
            state.document = document; state.flow = flow; state.toolbarDisplayMode = .auto
            state.showContents = false; state.showAI = false; state.showFind = false
            state.spread = false; state.cover = false; state.automaticLayout = false
            state.font = "serif"; state.fontSize = 17; state.margin = 32
            state.freePan = false; state.fit = "page"; state.zoom = 1; state.scrollbarMode = "hidden"
            let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 900, height: 650),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.toolbarStyle = .unifiedCompact
            let toolbar = NSToolbar(identifier: "hover-book-\(flow)")
            window.toolbar = toolbar; toolbar.isVisible = false
            let host = NSHostingView(rootView: ReaderView(state: state))
            window.contentView = host
            defer { state.windowClosed(); window.contentView = nil; window.close() }
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
            try await settle()
            let scroll = try XCTUnwrap(state.readerScrollView)
            let frame = scroll.convert(scroll.bounds, to: nil)
            let viewport = scroll.contentView.safeAreaRect.size
            let generation = state.chapterLayout?.generation
            let position = state.currentPosition.nativePassage
            let revision = state.renderRevision
            for shown in [true, false, true, false] {
                state.toolbarHoverVisible = shown; toolbar.isVisible = shown
                try await settle()
                XCTAssertEqual(scroll.convert(scroll.bounds, to: nil), frame, flow)
                XCTAssertEqual(scroll.contentView.safeAreaRect.size, viewport, flow)
                XCTAssertEqual(state.chapterLayout?.generation, generation, "Hover must not paginate the book again")
                XCTAssertEqual(state.renderRevision, revision, "Hover must not schedule a replacement surface")
                XCTAssertEqual(state.currentPosition.nativePassage, position, "Hover must preserve the reading passage")
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
                XCTAssertEqual(state.toolbarHoverVisible, mode == .auto)
                XCTAssertEqual(state.toolbarShown, mode == .auto || (mode == .shown && !presentation))
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
