#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderFloatingNativeIntegrationTests: XCTestCase {
    func testFullscreenFloatingTargetsClearMenuWithoutMovingBookOnReveal() async throws {
        final class FullscreenWindow: NSWindow {
            var fullscreen = false
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
        }
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard
        let keys = ["findFloating", "progressDisplayMode", "sidebarRight"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: "findFloating"); defaults.set("hidden", forKey: "progressDisplayMode")
        defaults.set(false, forKey: "sidebarRight")
        let originalMenu = NSApp.mainMenu
        if originalMenu == nil { NSApp.mainMenu = NSMenu(title: "Sumra") }
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            NSApp.mainMenu = originalMenu
        }
        let menuHeight = try XCTUnwrap(NSApp.mainMenu).menuBarHeight
        XCTAssertGreaterThan(menuHeight, 0)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/floating-menu-clearance.txt"),
            content: .text(String(repeating: "Reading content remains stationary when menu chrome reveals.\n", count: 200)))
        state.immersiveControls = true; state.showContents = true; state.showAI = false
        state.showFind = false; state.controlTopMargin = 0; state.scrollbarMode = "shown"
        let controller = NSHostingController(rootView: ReaderView(state: state))
        let window = FullscreenWindow(contentViewController: controller)
        window.styleMask.formUnion([.titled, .closable, .resizable])
        window.setFrame(CGRect(x: 2200, y: 100, width: 1000, height: 700), display: false)
        window.title = "Floating fullscreen menu clearance"
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        state.window = window; window.orderBack(nil)
        defer { state.windowClosed(); window.orderOut(nil); window.contentViewController = nil; window.close() }
        func observer(in view: NSView) -> ReaderToolbarWindow.Host? {
            (view as? ReaderToolbarWindow.Host) ?? view.subviews.lazy.compactMap { observer(in: $0) }.first
        }
        func windowButtons(in view: NSView) -> ReaderFloatingWindowButtons.Buttons? {
            (view as? ReaderFloatingWindowButtons.Buttons) ?? view.subviews.lazy.compactMap { windowButtons(in: $0) }.first
        }
        func clearanceHost(in view: NSView) -> ReaderScrollbarClearance.Host? {
            (view as? ReaderScrollbarClearance.Host) ?? view.subviews.lazy.compactMap { clearanceHost(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<20 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            }
        }
        try await settle()
        for mode in [ReaderToolbarDisplayMode.shown, .auto, .hidden] {
            state.toolbarDisplayMode = mode
            for margin in [0.0, 200.0] {
                state.controlTopMargin = margin; state.showFind = false
                window.fullscreen = false
                try XCTUnwrap(observer(in: controller.view)).updateChrome(revealingNativeControls: false)
                try await settle()
                let scroll = try XCTUnwrap(state.readerScrollView)
                let bookFrame = scroll.convert(scroll.bounds, to: nil)
                window.fullscreen = true
                let host = try XCTUnwrap(observer(in: controller.view))
                host.reducedMotion = true
                host.updateChrome(revealingNativeControls: false)
                try await settle()
                XCTAssertEqual(scroll.convert(scroll.bounds, to: nil), bookFrame,
                    "Floating fullscreen menu clearance belongs to controls, not a second root inset on the book")
                let viewport = scroll.contentView.safeAreaRect.size
                let trackInsets = scroll.scrollerInsets
                var targets = [CGRect]()
                for menuVisible in [true, false, true] {
                    host.pointerMoved(to: CGPoint(x: window.frame.width / 2, y: window.frame.height - 1))
                    host.updateChrome(revealingNativeControls: menuVisible)
                    try await settle()
                    let elements = try accessibleElements(in: window)
                    let groupID = mode == .hidden ? "floating-window-controls" : "floating-navigation"
                    let group = try XCTUnwrap(elements.first { $0.identifier == groupID }).frame
                    XCTAssertLessThanOrEqual(group.maxY, window.frame.maxY - menuHeight,
                        "The actual floating controls must paint entirely below the native menu strip")
                    let buttons = try XCTUnwrap(windowButtons(in: controller.view)).subviews.compactMap { $0 as? NSButton }
                    XCTAssertEqual(buttons.count, 3)
                    for button in buttons {
                        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                        XCTAssertLessThanOrEqual(frame.maxY, window.frame.maxY - menuHeight,
                            "Every native traffic-light target must remain fully below the menu")
                    }
                    if mode != .hidden {
                        let open = try XCTUnwrap(elements.first { $0.label == L("Open Document") }).frame
                        XCTAssertLessThanOrEqual(open.maxY, window.frame.maxY - menuHeight,
                            "The actionable icon target must clear the menu, not only its capsule background")
                    }
                    if let previous = targets.last { XCTAssertEqual(group, previous) }
                    targets.append(group)
                    let target = window.convertPoint(fromScreen: CGPoint(x: group.midX, y: group.minY + 1))
                    host.pointerMoved(to: target)
                    if mode != .shown { XCTAssertTrue(state.toolbarHoverVisible, "The bottom of shifted controls must retain hover") }
                    XCTAssertEqual(scroll.convert(scroll.bounds, to: nil), bookFrame)
                    XCTAssertEqual(scroll.contentView.safeAreaRect.size, viewport)
                    XCTAssertTrue(NSEdgeInsetsEqual(scroll.scrollerInsets, trackInsets),
                        "Menu reveal must not move scrollbar tracks")
                }
                state.showFind = true
                try await settle()
                let field = try XCTUnwrap(state.findInputField)
                let input = window.convertToScreen(field.convert(field.bounds, to: nil))
                XCTAssertLessThanOrEqual(input.maxY, try XCTUnwrap(targets.last).minY,
                    "Docked Find must share the floating toolbar's measured menu clearance")
                let currentScroll = try XCTUnwrap(state.readerScrollView)
                let clearance = try XCTUnwrap(clearanceHost(in: controller.view))
                let currentFrame = clearance.convert(currentScroll.bounds, from: currentScroll)
                let controlsBottom = clearance.convert(window.convertPoint(fromScreen:
                    CGPoint(x: 0, y: try XCTUnwrap(targets.last).minY)), from: nil).y
                let remainingClearance = max(0, controlsBottom - currentFrame.minY)
                print("Floating Find track: mode=\(mode.rawValue) margin=\(margin) sameScroll=\(currentScroll === scroll) capturedMounted=\(scroll.window === window) currentMounted=\(currentScroll.window === window) capturedFrame=\(scroll.convert(scroll.bounds, to: nil)) currentFrame=\(currentScroll.convert(currentScroll.bounds, to: nil)) clearanceFrame=\(clearance.bounds) clearanceTop=\(clearance.top) remaining=\(remainingClearance) capturedInset=\(scroll.scrollerInsets.top) currentInset=\(currentScroll.scrollerInsets.top)")
                XCTAssertTrue(currentScroll.window === window, "The asserted scrollbar must belong to the current mounted reader")
                XCTAssertEqual(remainingClearance, 0, "Find must move the current reader below the whole control band")
                XCTAssertEqual(currentScroll.scrollerInsets.top, 0,
                    "The docked controls already consume the toolbar and menu clearance")
                state.showFind = false
                try await settle()
                let restoredScroll = try XCTUnwrap(state.readerScrollView)
                XCTAssertTrue(restoredScroll.window === window)
                XCTAssertEqual(restoredScroll.convert(restoredScroll.bounds, to: nil), bookFrame,
                    "Closing Find must restore the current reader's original frame")
                XCTAssertEqual(restoredScroll.contentView.safeAreaRect.size, viewport)
                XCTAssertTrue(NSEdgeInsetsEqual(restoredScroll.scrollerInsets, trackInsets),
                    "Closing Find must restore the original live scrollbar clearance for \(mode.rawValue), margin \(margin)")
            }
        }
    }

    private struct AccessibleElement {
        let role: NSAccessibility.Role
        let label: String?
        let value: String?
        let frame: CGRect
        let identifier: String?
        func accessibilityRole() -> NSAccessibility.Role { role }
        func accessibilityLabel() -> String? { label }
        func accessibilityValue() -> Any? { value }
        func accessibilityFrame() -> CGRect { frame }
    }
    private static var accessibilityLaunched = false

    // NSHostingView's in-process protocol getters expose its AppKit children,
    // whereas the public AX client includes SwiftUI's virtual button nodes.
    private func accessibleElements(in window: NSWindow) throws -> [AccessibleElement] {
        if !Self.accessibilityLaunched {
            NSApp.finishLaunching()
            Self.accessibilityLaunched = true
        }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
        let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title },
            "The fixture window must be registered with AppKit's accessibility server")
        func descendants(_ element: AXUIElement) -> [AccessibleElement] {
            var position = CGPoint.zero, size = CGSize.zero
            if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &position)
            }
            if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
            }
            // Client AX coordinates start at the main screen's top left.
            let frame = CGRect(x: position.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - position.y - size.height,
                width: size.width, height: size.height)
            let item = AccessibleElement(role: NSAccessibility.Role(rawValue: attribute(element, kAXRoleAttribute) as? String ?? ""),
                label: attribute(element, kAXDescriptionAttribute) as? String ?? attribute(element, kAXTitleAttribute) as? String,
                value: attribute(element, kAXValueAttribute) as? String, frame: frame,
                identifier: attribute(element, kAXIdentifierAttribute) as? String)
            return [item] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(descendants)
        }
        return descendants(target)
    }

    private func frame(of element: AccessibleElement, in view: NSView) -> CGRect {
        guard let window = view.window else { return .zero }
        return view.convert(window.convertFromScreen(element.frame), from: nil)
    }

    func testEmptyContentsHeaderRemainsAtTheTopOfItsPane() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["sidebarRight", "sidebarWidth", "progressDisplayMode", "toolbarDisplayMode", "immersiveControls"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: "sidebarRight")
        defaults.set(220.0, forKey: "sidebarWidth")
        defaults.set("hidden", forKey: "progressDisplayMode")
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/contents-header-layout.txt"),
            content: .text(String(repeating: "Section 1\nA paragraph to fill the native reading viewport.\n", count: 80)))
        state.count = 80; state.showContents = true; state.showAI = false
        state.showAnnotations = false; state.showBookmarks = false; state.showThumbnails = false
        state.toolbarDisplayMode = .auto
        state.immersiveControls = false; state.toolbarHoverVisible = false
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Contents header layout"
        window.alphaValue = 0; window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer { state.windowClosed(); window.contentView = nil; window.orderOut(nil); window.close() }
        for right in [false, true] {
            defaults.set(right, forKey: "sidebarRight")
            for floating in [false, true, false] {
                state.immersiveControls = floating
                for populated in [false, true, false] {
                    state.outline = populated ? [ContentsItem(title: "Section 1", target: "0", depth: 0)] : []
                    for _ in 0..<25 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let close = try XCTUnwrap(accessibleElements(in: window).first { $0.label == L("Close Sidebar") })
                    let header = frame(of: close, in: host)
                    let topGap = host.isFlipped ? header.minY - host.bounds.minY : host.bounds.maxY - header.maxY
                    let chromeHeight = floating
                        ? ReaderFloatingControls.topInset + ReaderFloatingControls.height + 10
                        : host.safeAreaInsets.top
                    print("Contents header right=\(right), floating=\(floating), populated=\(populated), top gap=\(topGap), chrome=\(chromeHeight)")
                    XCTAssertEqual(topGap, chromeHeight + 13, accuracy: 3,
                        "The header must sit immediately below one reserved chrome area, including after content and toolbar changes")
                }
            }
        }
    }

    func testContentsListUsesItsContainerBackgroundAcrossThemeChanges() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["theme", "lastLightTheme", "lastDarkTheme"]
        let saved = keys.map { defaults.object(forKey: $0) }, appearance = NSApp.appearance
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            NSApp.appearance = appearance
        }
        let state = ReaderState(recordsHistory: false)
        state.outline = [.init(title: "Chapter", target: "0")]
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 300, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ContentsTree(state: state).background(Color.white))
        window.contentView = host; state.window = window; window.orderBack(nil)
        defer { state.windowClosed(); window.contentView = nil; window.orderOut(nil); window.close() }
        for theme in ["light", "dark", "light-warm", "light"] {
            state.theme = theme; ReaderTheme.applyAppearance(theme)
            host.rootView = ContentsTree(state: state).background(Color(nsColor: ReaderTheme.color(state.palette.background)))
            for _ in 0..<25 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
            let tree = try XCTUnwrap(state.contentsFocusView)
            let clip = try XCTUnwrap(tree.enclosingScrollView?.contentView)
            let bottom = clip.isFlipped ? clip.bounds.maxY - 20 : clip.bounds.minY + 20
            let listPoint = clip.convert(NSPoint(x: clip.bounds.midX, y: bottom), to: host)
            let searchAreaPoint = NSPoint(x: 4, y: 4)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let samples = try [("list", listPoint), ("search area", searchAreaPoint)].map { label, point in
                let x = Int(point.x * CGFloat(bitmap.pixelsWide) / host.bounds.width)
                let y = Int((host.isFlipped ? point.y : host.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / host.bounds.height)
                let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                print("Contents theme=\(theme) \(label) rgb=\(actual.redComponent),\(actual.greenComponent),\(actual.blueComponent)")
                return actual
            }
            let actual = samples[0], expected = samples[1]
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01, "\(theme) list and search area")
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01, "\(theme) list and search area")
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01, "\(theme) list and search area")
            if theme == "dark" { XCTAssertLessThan(expected.redComponent, 0.05) }
            else if theme == "light-warm" { XCTAssertLessThan(expected.blueComponent, 0.95) }
            else { XCTAssertGreaterThan(expected.blueComponent, 0.95) }
        }
    }

    func testPortraitFixedPagesReserveFloatingControlsWithoutReflowMarginsOrHoverLayoutChanges() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        var page = CGRect(x: 0, y: 0, width: 300, height: 600)
        let pdf = directory.url.appendingPathComponent("portrait.pdf")
        let writer = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &page, nil))
        writer.beginPDFPage(nil); writer.setFillColor(CGColor(gray: 0.4, alpha: 1)); writer.fill(page)
        writer.endPDFPage(); writer.closePDF()
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 300, height: 600, bitsPerComponent: 8,
            bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0.4, alpha: 1)); bitmap.fill(page)
        let png = directory.url.appendingPathComponent("portrait.png")
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(bitmap.makeImage()))
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: png)
        let defaults = UserDefaults.standard, savedProgress = defaults.object(forKey: "progressDisplayMode")
        defer { defaults.set(savedProgress, forKey: "progressDisplayMode") }
        for input in [pdf, png] {
            let document = try ReadingDocument.open(input)
            guard case .pages(let pages) = document.content else { return XCTFail("Expected fixed native pages") }
            let prepared = try await pages.prepare()
            let state = ReaderState(recordsHistory: false)
            state.document = document; state.count = await pages.count
            state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
            state.flow = "paged"; state.fit = "page"; state.spread = false; state.cover = false
            state.rtl = false; state.automaticLayout = false; state.presentation = false
            state.immersiveControls = true; state.scrollbarMode = "hidden"
            state.showContents = false; state.showThumbnails = false; state.showBookmarks = false
            state.showAnnotations = false; state.showAI = false; state.showFind = false
            state.trimEmptyMargins = false; state.uniformPageWidth = false; state.freePan = false
            let host = NSHostingView(rootView: ReaderView(state: state))
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 800, height: 700),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            window.contentView = host; state.window = window
            defer { state.windowClosed(); window.contentView = nil; window.close() }
            func waitForPaint() async throws {
                let deadline = Date().addingTimeInterval(5)
                repeat {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                    }
                    if let error = state.error { throw ReadError(error) }
                    if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(0)) { return }
                } while Date() < deadline
                throw ReadError("Fixed page did not paint")
            }
            // Content margins and each independently chosen clearance reserve
            // their maximum once; zero clearance allows reading under controls.
            let cases: [(Double, Double, Double, ReaderToolbarDisplayMode, ReaderToolbarDisplayMode, CGFloat, CGFloat)] = [
                (16, 54, 44, .auto, .shown, 54, 44),
                (24, 54, 44, .auto, .shown, 54, 44),
                (8, 54, 44, .auto, .shown, 54, 44),
                (80, 54, 44, .auto, .shown, 80, 80),
                (16, 76, 44, .auto, .shown, 76, 44),
                (16, 76, 67, .auto, .shown, 76, 67),
                (16, 0, 67, .auto, .shown, 16, 67),
                (16, 0, 0, .auto, .shown, 16, 16),
                (24, 76, 67, .hidden, .hidden, 24, 24)
            ]
            for (margin, topMargin, bottomMargin, toolbar, progress, top, bottom) in cases {
                state.margin = margin; state.pageMargins = .init(cssValues: [margin]); state.marginPresetSelection = "custom"
                state.controlTopMargin = topMargin; state.controlBottomMargin = bottomMargin
                state.toolbarDisplayMode = toolbar; defaults.set(progress.rawValue, forKey: "progressDisplayMode")
                state.toolbarHoverVisible = false; state.toolbarHoverOpacity = 0
                try await waitForPaint()
                let clip = try XCTUnwrap(state.readerScrollView?.contentView)
                let canvas = try XCTUnwrap(state.readerFocusView)
                let root = host.convert(host.bounds, to: nil)
                let viewport = clip.convert(clip.bounds, to: nil)
                let canvasFrame = canvas.convert(canvas.bounds, to: nil)
                XCTAssertFalse(state.usesReflowMargins)
                XCTAssertEqual(root.maxY - viewport.maxY, top, accuracy: 1, "\(input.pathExtension), margin=\(margin)")
                XCTAssertEqual(viewport.minY - root.minY, bottom, accuracy: 1, "\(input.pathExtension), margin=\(margin)")
                XCTAssertEqual(canvasFrame.width / canvasFrame.height, 0.5, accuracy: 0.002)
                XCTAssertLessThanOrEqual(canvasFrame.maxY, viewport.maxY + 1)
                XCTAssertGreaterThanOrEqual(canvasFrame.minY, viewport.minY - 1)
                let windowFrame = window.frame
                for shown in [true, false] {
                    state.toolbarHoverVisible = shown; state.toolbarHoverOpacity = shown ? 1 : 0
                    try await waitForPaint()
                    XCTAssertEqual(clip.convert(clip.bounds, to: nil), viewport)
                    XCTAssertEqual(canvas.convert(canvas.bounds, to: nil), canvasFrame)
                    XCTAssertEqual(window.frame, windowFrame)
                }
            }
        }
    }

    func testAlwaysHideRevealsOnlyWindowButtonsAndKeepsReadingToolsHidden() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/hidden-toolbar-book.txt"), content: .text("book"))
        state.immersiveControls = true; state.toolbarDisplayMode = .hidden
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        state.window = window
        let host = NSHostingView(rootView: ReaderFloatingControls(state: state, open: { XCTFail("Reading tools stay hidden") })
            .frame(width: 700, height: 400, alignment: .top))
        window.contentView = host; window.orderBack(nil)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        host.addSubview(observer)
        defer {
            observer.detach(); window.contentView = nil; window.orderOut(nil); window.close(); state.windowClosed()
        }
        let initialFrame = window.frame
        XCTAssertFalse(state.toolbarShown); XCTAssertFalse(state.toolbarHoverVisible)
        observer.pointerMoved(to: NSPoint(x: 30, y: window.frame.height - 10))
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(state.toolbarHoverVisible)
        XCTAssertFalse(state.toolbarShown, "Window buttons must not reveal the hidden reading toolbar")
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let buttons = views(host).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3, "Only close, minimize and fullscreen belong in this reveal")
        XCTAssertTrue(buttons.allSatisfy { $0.target === window && $0.isEnabled })
        XCTAssertEqual(window.frame, initialFrame)
        observer.pointerMoved(to: NSPoint(x: 350, y: 100))
        XCTAssertFalse(state.toolbarHoverVisible)
        XCTAssertFalse(state.toolbarShown)
        state.presentation = true
        observer.pointerMoved(to: NSPoint(x: 30, y: window.frame.height - 10))
        XCTAssertFalse(state.toolbarHoverVisible, "Presentation suppresses the window-control reveal as well")
    }

    func testHomeHeaderKeepsOnlyWindowControlsWithoutDuplicateWelcomeCommands() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.title = "Home chrome integration fixture"
        let state = ReaderState(recordsHistory: false)
        state.window = window
        let host = NSHostingView(rootView: ReaderHomeHeader())
        window.contentView = host; window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close(); state.windowClosed() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        for width in [560.0, 1000.0] {
            window.setContentSize(CGSize(width: width, height: 400))
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let mounted = views(host)
            let controls = try XCTUnwrap(mounted.compactMap { $0 as? ReaderFloatingWindowButtons.Buttons }.first)
            XCTAssertEqual(controls.convert(controls.bounds, to: host).minX, 16, accuracy: 1)
            let elements = try accessibleElements(in: window)
            let headerFrame = host.convert(host.bounds, to: nil)
            let headerScreen = window.convertToScreen(headerFrame)
            let buttons = elements.filter { $0.role == .button && headerScreen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            XCTAssertEqual(buttons.count, 3, "The header contains only the native window controls")
            XCTAssertFalse(buttons.contains { $0.accessibilityLabel() == L("Open Document") },
                "Welcome already owns the document-opening action")
            XCTAssertFalse(elements.contains {
                $0.accessibilityRole() == .staticText && ($0.accessibilityValue() as? String == "Sumra" || $0.accessibilityLabel() == "Sumra")
            }, "Welcome already displays the application title")
            XCTAssertTrue(controls.subviews.compactMap { $0 as? NSButton }.allSatisfy { $0.target === window && $0.isEnabled })
            XCTAssertFalse(mounted.contains { $0 is NSScrollView })
        }
    }

    func testTwoDocumentTabsFillTheStripAndNarrowStripScrollsInsteadOfShrinkingTargets() async throws {
        _ = NSApplication.shared
        let windows = ["first-book.epub", "second-book.epub"].map { title in
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 600, height: 100),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = title
            window.alphaValue = 0; window.ignoresMouseEvents = true
            return window
        }
        windows[0].addTabbedWindow(windows[1], ordered: .above)
        windows[0].tabGroup?.selectedWindow = windows[1]
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/second-book.epub"), content: .text("book"))
        state.window = windows[1]
        let host = NSHostingView(rootView: ReaderDocumentTabs(state: state))
        windows[1].contentView = host; windows[1].orderBack(nil)
        defer {
            windows[1].contentView = nil
            for window in windows { window.orderOut(nil); window.close() }
            state.windowClosed()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        for width in [360.0, 600.0, 220.0] {
            windows[1].setContentSize(CGSize(width: width, height: 100))
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let scroll = try XCTUnwrap(views(host).compactMap { $0 as? NSScrollView }.first)
            let buttons = try accessibleElements(in: windows[1]).filter {
                $0.role == .button && (["first-book.epub", "second-book.epub"].contains($0.label ?? "") || $0.label?.hasPrefix(L("Close Tab") + ": ") == true)
            }
            XCTAssertEqual(buttons.count, 4, "Both documents keep independent selection and close targets")
            let closeButtons = buttons.filter { $0.accessibilityLabel()?.hasPrefix(L("Close Tab") + ": ") == true }
            XCTAssertEqual(closeButtons.count, 2)
            XCTAssertTrue(closeButtons.allSatisfy { $0.accessibilityFrame().height >= 20 })
            for title in ["first-book.epub", "second-book.epub"] {
                let selection = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == title })
                XCTAssertGreaterThanOrEqual(selection.accessibilityFrame().height, 28,
                    "The document name retains the whole tab height as its click target")
            }
            if width >= 360 {
                let frame = scroll.convert(scroll.bounds, to: host)
                let lastClose = try XCTUnwrap(closeButtons.map { self.frame(of: $0, in: host) }.max { $0.maxX < $1.maxX })
                XCTAssertEqual(lastClose.maxX, frame.maxX - 8, accuracy: 1,
                               "Fitting tabs use the available strip instead of leaving an empty trailing region")
            } else {
                XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.width, scroll.contentView.bounds.width,
                                     "Narrow strips scroll rather than crushing document and close targets")
            }
        }
    }

    func testCustomHomeChromeNeverAdoptsSiblingFactoryButtonsAsANativeCompanion() throws {
        final class SharedLookupWindow: NSWindow {
            var sharedClose: NSButton?
            override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
                if type == .closeButton, let sharedClose { return sharedClose }
                return super.standardWindowButton(type)
            }
        }
        _ = NSApplication.shared
        let sibling = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let home = SharedLookupWindow(contentRect: sibling.frame,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        sibling.isReleasedWhenClosed = false; home.isReleasedWhenClosed = false
        let controls = ReaderFloatingWindowButtons.Buttons(frame: CGRect(x: 16, y: 16, width: 54, height: 20))
        sibling.contentView?.addSubview(controls)
        home.sharedClose = try XCTUnwrap(controls.subviews.compactMap { $0 as? NSButton }.first { $0.tag == Int(NSWindow.ButtonType.closeButton.rawValue) })
        let state = ReaderState(recordsHistory: false)
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        home.contentView?.addSubview(observer)
        defer {
            observer.detach(); home.contentView = nil; controls.removeFromSuperview()
            home.close(); sibling.close(); state.windowClosed()
        }
        for menuVisible in [false, true, false] {
            observer.updateChrome(revealingNativeControls: menuVisible)
            XCTAssertFalse(controls.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(controls.alphaValue, 1)
            XCTAssertEqual(sibling.contentView?.alphaValue, 1)
            XCTAssertFalse(sibling.ignoresMouseEvents)
        }
    }

    func testMountedWindowButtonsRecoverAfterSwiftUIDismantleAndFullscreenContextChanges() throws {
        final class FullscreenWindow: NSWindow {
            var fullscreen = false
            override var styleMask: NSWindow.StyleMask {
                get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
                set { super.styleMask = newValue.subtracting(.fullScreen) }
            }
        }
        _ = NSApplication.shared
        let window = FullscreenWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 150),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controls = ReaderFloatingWindowButtons.Buttons(frame: CGRect(x: 0, y: 0, width: 54, height: 20))
        window.contentView?.addSubview(controls)
        defer { controls.removeFromSuperview(); window.close() }
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3)
        XCTAssertTrue(buttons.allSatisfy { $0.isEnabled && $0.target === window })

        // SwiftUI may dismantle and reuse a platform view without changing its
        // actual AppKit window. A later update must use that mounted owner.
        ReaderFloatingWindowButtons.dismantleNSView(controls, coordinator: ())
        XCTAssertTrue(controls.window === window)
        controls.updateButtons()
        XCTAssertTrue(controls.readerWindow === window)
        XCTAssertTrue(buttons.allSatisfy { $0.isEnabled && $0.target === window })

        // Exercise public fullscreen capability notifications without entering
        // a visible fullscreen Space from a unit test.
        window.fullscreen = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        XCTAssertEqual(buttons.map(\.isEnabled), [true, false, true])
        XCTAssertTrue(buttons.allSatisfy { $0.target === window })
        window.fullscreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertTrue(buttons.allSatisfy { $0.isEnabled && $0.target === window })

        controls.removeFromSuperview()
        XCTAssertNil(controls.readerWindow)
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled && $0.target == nil })
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled && $0.target == nil })
        XCTAssertFalse(window.isVisible)
    }

    func testFloatingChromeDoesNotHideFactoryControlsRegisteredAsNativeButtons() throws {
        // A real fullscreen transition registers the mounted factory controls
        // as NSWindow's standard buttons. Reproduce that public lookup change
        // without taking the test runner into a visible fullscreen Space.
        final class RegisteredFactoryWindow: NSWindow {
            var registeredButtons: [NSWindow.ButtonType: NSButton] = [:]
            override func standardWindowButton(_ type: NSWindow.ButtonType) -> NSButton? {
                registeredButtons[type] ?? super.standardWindowButton(type)
            }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-owner-reading.txt"), content: .text("Reading content."))
        state.immersiveControls = true; state.toolbarDisplayMode = .shown
        let window = RegisteredFactoryWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let nativeButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let nativeContainer = try XCTUnwrap(nativeButtons.first?.superview)
        let nativeAppearance = (hidden: nativeContainer.isHidden, alpha: nativeContainer.alphaValue)
        let content = try XCTUnwrap(window.contentView)
        let controls = ReaderFloatingWindowButtons.Buttons(frame: CGRect(x: 16, y: 16, width: 54, height: 20))
        content.addSubview(controls)
        let chrome = ReaderToolbarWindow.Host(frame: .zero)
        chrome.state = state
        content.addSubview(chrome)
        defer {
            chrome.removeFromSuperview(); controls.removeFromSuperview()
            window.registeredButtons.removeAll(); window.close(); state.windowClosed()
        }
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3)
        for button in buttons {
            let type = try XCTUnwrap(NSWindow.ButtonType(rawValue: UInt(button.tag)))
            XCTAssertFalse(window.standardWindowButton(type) === button)
            window.registeredButtons[type] = button
        }
        for _ in 0..<2 {
            chrome.updateChrome()
            controls.updateButtons()
            for button in buttons {
                let type = try XCTUnwrap(NSWindow.ButtonType(rawValue: UInt(button.tag)))
                XCTAssertTrue(window.standardWindowButton(type) === button)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor,
                               "A factory button registered by fullscreen remains part of the reader content")
                XCTAssertTrue(button.isEnabled)
                XCTAssertTrue(button.target === window)
            }
            XCTAssertFalse(controls.isHidden)
            XCTAssertEqual(controls.alphaValue, 1)
            XCTAssertTrue(nativeContainer.isHidden)
            XCTAssertEqual(nativeContainer.alphaValue, 0)
            XCTAssertTrue(nativeButtons.allSatisfy { !$0.isHidden && $0.alphaValue == 1 && $0.isEnabled },
                          "Hide the actual native container while preserving stock command capabilities")
        }
        state.immersiveControls = false
        chrome.updateChrome()
        XCTAssertEqual(nativeContainer.isHidden, nativeAppearance.hidden)
        XCTAssertEqual(nativeContainer.alphaValue, nativeAppearance.alpha)
        state.immersiveControls = true
        chrome.updateChrome()
        XCTAssertTrue(nativeContainer.isHidden, "Re-enabling floating controls must retain the discovered native owner despite the redirected lookup")
        XCTAssertEqual(nativeContainer.alphaValue, 0)
        chrome.detach()
        XCTAssertEqual(nativeContainer.isHidden, nativeAppearance.hidden)
        XCTAssertEqual(nativeContainer.alphaValue, nativeAppearance.alpha)
        XCTAssertTrue(nativeButtons.allSatisfy(\.isEnabled))
        XCTAssertFalse(controls.isHidden)
        XCTAssertEqual(controls.alphaValue, 1)
        XCTAssertFalse(window.isVisible)
    }

    func testFloatingWindowButtonsRemainVisibleInsideFullReaderChrome() async throws {
        final class CloseApproval: NSObject, NSWindowDelegate {
            var requests = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
        }
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/full-reader-floating.txt"), content: .text("Reading content."))
        state.immersiveControls = true; state.toolbarDisplayMode = .shown
        state.showContents = false; state.showAI = false; state.showFind = false
        state.theme = "light"; state.margin = 16
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.toolbarStyle = .unifiedCompact
        let approval = CloseApproval()
        let guardedClose = ReaderCloseGuard(state: state, previous: approval)
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let originals = try buttonTypes.map { try XCTUnwrap(window.standardWindowButton($0)) }
        let originalAppearance = originals.map { (hidden: $0.isHidden, alpha: $0.alphaValue) }
        let host = NSHostingView(rootView: ReaderView(state: state))
        window.contentView = host
        state.window = window
        window.delegate = guardedClose
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        func controls(in view: NSView) -> [ReaderFloatingWindowButtons.Buttons] {
            (view as? ReaderFloatingWindowButtons.Buttons).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        var expectedCloseRequests = 0
        for width in [560.0, 800.0, 560.0] {
            window.setContentSize(CGSize(width: width, height: 700))
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let groups = controls(in: host)
            XCTAssertEqual(groups.count, 1)
            let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rendered)
            let bitmap = try XCTUnwrap(rendered.converting(to: .sRGB, renderingIntent: .default))
            for group in groups {
                XCTAssertEqual(group.bounds.size, CGSize(width: 54, height: 20))
                XCTAssertTrue(group.readerWindow === window)
                let buttons = group.subviews.compactMap { $0 as? NSButton }
                XCTAssertEqual(buttons.count, 3)
                for (index, button) in buttons.enumerated() {
                    let buttonType = NSWindow.ButtonType(rawValue: UInt(button.tag))!
                    let native = try XCTUnwrap(window.standardWindowButton(buttonType))
                    XCTAssertTrue(native === originals[index])
                    XCTAssertFalse(native === button)
                    XCTAssertEqual(native.alphaValue, originalAppearance[index].alpha)
                    XCTAssertTrue(native.isHiddenOrHasHiddenAncestor ||
                                  native.superview?.alphaValue == 0,
                                  "Floating chrome must hide the native container, preserving the real button's command capability")
                    XCTAssertTrue(native.isEnabled, "Hiding native chrome must not disable the stock window commands")
                    var ancestor: NSView? = button
                    while let view = ancestor {
                        XCTAssertFalse(view.isHidden)
                        XCTAssertGreaterThan(view.alphaValue, 0)
                        ancestor = view.superview
                    }
                    XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                    XCTAssertTrue(button.isEnabled)
                    XCTAssertTrue(button.target === window)
                    XCTAssertTrue(button.isAccessibilityElement())
                    XCTAssertGreaterThan(button.bounds.width, 0); XCTAssertGreaterThan(button.bounds.height, 0)
                    let frame = button.convert(button.bounds, to: host)
                    let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
                    let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
                    let pixels = CGRect(x: frame.minX * scaleX,
                        y: (host.isFlipped ? frame.minY : host.bounds.height - frame.maxY) * scaleY,
                        width: frame.width * scaleX, height: frame.height * scaleY).integral
                    var painted = 0
                    for y in Int(pixels.minY)..<Int(pixels.maxY) {
                        for x in Int(pixels.minX)..<Int(pixels.maxX) {
                            if let color = bitmap.colorAt(x: x, y: y),
                               min(color.redComponent, color.greenComponent, color.blueComponent) < 0.99 { painted += 1 }
                        }
                    }
                    XCTAssertGreaterThan(painted, 5, "The complete ReaderView must actually paint each floating native control")
                }
            }
            let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            XCTAssertTrue(window.validateUserInterfaceItem(closeItem))
            expectedCloseRequests += 1
            window.performClose(nil)
            let deadline = Date().addingTimeInterval(2)
            while approval.requests < expectedCloseRequests, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(approval.requests, expectedCloseRequests, "Native Close must reach the existing document close owner and its veto")
            XCTAssertNotNil(state.document)
        }
        for floating in [false, true, false] {
            state.immersiveControls = floating
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let groups = controls(in: host)
            XCTAssertEqual(groups.count, floating ? 1 : 0)
            for (index, type) in buttonTypes.enumerated() {
                let native = try XCTUnwrap(window.standardWindowButton(type))
                XCTAssertEqual(native.isHidden, originalAppearance[index].hidden)
                XCTAssertEqual(native.alphaValue, originalAppearance[index].alpha,
                               "Turning off floating controls must restore the native window controls")
                if !floating { XCTAssertFalse(native.isHiddenOrHasHiddenAncestor) }
            }
            for button in groups.flatMap({ $0.subviews.compactMap { $0 as? NSButton } }) {
                XCTAssertTrue(button.isEnabled)
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
                XCTAssertTrue(button.target === window)
            }
        }
        XCTAssertFalse(window.isVisible)
        withExtendedLifetime(guardedClose) {}
    }

    func testHostedFloatingWindowButtonsBindLateWindowAndHavePaintedAccessibleFrames() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 120, height: 70),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReaderFloatingWindowButtons()
            .frame(width: 54, height: 20).padding(12).background(Color.white).preferredColorScheme(.light))
        // SwiftUI creates the controls before WindowTabs binds ReaderState.window.
        // The native view's real window must become the owner on attachment.
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window); XCTAssertNil(state.window)
        window.contentView = host
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        func findControls(in view: NSView) -> ReaderFloatingWindowButtons.Buttons? {
            if let controls = view as? ReaderFloatingWindowButtons.Buttons { return controls }
            return view.subviews.lazy.compactMap { findControls(in: $0) }.first
        }
        let controls = try XCTUnwrap(findControls(in: host))
        XCTAssertNil(state.window, "Native window controls must not depend on a later ReaderState publication")
        XCTAssertTrue(controls.readerWindow === window)
        XCTAssertEqual(controls.bounds.size, CGSize(width: 54, height: 20),
                       "The SwiftUI wrapper must give the native controls their reserved drawable area")
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3)
        for (button, subrole) in zip(buttons, [NSAccessibility.Subrole.closeButton, .minimizeButton, .fullScreenButton]) {
            XCTAssertGreaterThan(button.bounds.width, 0); XCTAssertGreaterThan(button.bounds.height, 0)
            XCTAssertTrue(controls.bounds.contains(button.frame))
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor); XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.target === window)
            XCTAssertTrue(button.isAccessibilityElement())
            XCTAssertEqual(button.accessibilityRole(), .button)
            XCTAssertEqual(button.accessibilitySubrole(), subrole)
            XCTAssertFalse(try XCTUnwrap(button.accessibilityLabel()).isEmpty)
            let expectedFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let accessibleFrame = button.accessibilityFrame()
            XCTAssertGreaterThan(accessibleFrame.width, 0); XCTAssertGreaterThan(accessibleFrame.height, 0)
            XCTAssertEqual(accessibleFrame.midX, expectedFrame.midX, accuracy: 0.1)
            XCTAssertEqual(accessibleFrame.midY, expectedFrame.midY, accuracy: 0.1)
            let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rendered)
            let bitmap = try XCTUnwrap(rendered.converting(to: .sRGB, renderingIntent: .default))
            let paintedFrame = button.convert(button.bounds, to: host)
            let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
            let pixelFrame = CGRect(x: paintedFrame.minX * scaleX,
                y: (host.isFlipped ? paintedFrame.minY : host.bounds.height - paintedFrame.maxY) * scaleY,
                width: paintedFrame.width * scaleX, height: paintedFrame.height * scaleY).integral
            var visiblePixels = 0
            for y in Int(pixelFrame.minY)..<Int(pixelFrame.maxY) {
                for x in Int(pixelFrame.minX)..<Int(pixelFrame.maxX) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.1,
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.99 { visiblePixels += 1 }
                }
            }
            XCTAssertGreaterThan(visiblePixels, 5, "Each real button must paint its control, including the inactive appearance")
        }
        XCTAssertFalse(buttons[0].frame.intersects(buttons[1].frame))
        XCTAssertFalse(buttons[1].frame.intersects(buttons[2].frame))
        XCTAssertFalse(window.isVisible)
    }

    func testSelectedLongTitleTabScrollsIntoViewOnMountAndReactivation() async throws {
        _ = NSApplication.shared
        let windows = (0..<6).map { index in
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 150),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
            window.title = "Long document title number \(index), with enough text to overflow the floating tab strip"
            return window
        }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/long-tab.txt"), content: .text("book"))
        state.toolbarDisplayMode = .shown; state.theme = "light"
        for sibling in windows.dropFirst() { windows[0].addTabbedWindow(sibling, ordered: .above) }
        let group = try XCTUnwrap(windows[0].tabGroup)
        let selected = try XCTUnwrap(group.windows.last)
        state.window = selected
        group.selectedWindow = selected
        let host = NSHostingView(rootView: ReaderFloatingControls(state: state, open: {}))
        selected.contentView = host
        defer {
            selected.contentView = nil
            for window in windows { window.close() }
            state.windowClosed()
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        for (width, surfaceCount) in [(560.0, 1), (1000.0, 3), (560.0, 1)] {
            selected.setContentSize(CGSize(width: width, height: 150))
            try await settle()
            XCTAssertEqual(host.bounds.width, width, accuracy: 0.1)
            XCTAssertEqual(host.bounds.height, ReaderFloatingControls.height + 16, accuracy: 0.1)
            let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rendered)
            // Sample the painted row, including the return to narrow width.
            // Narrow windows merge the controls into one surface; wide ones
            // retain three islands, all within the same fixed-height band.
            let scale = CGFloat(rendered.pixelsWide) / host.bounds.width
            let row = Int(20 * CGFloat(rendered.pixelsHigh) / host.bounds.height)
            var islands = [Range<Int>]()
            var start: Int?
            for x in 0..<rendered.pixelsWide {
                let opaque = (rendered.colorAt(x: x, y: row)?.alphaComponent ?? 0) > 0.95
                if opaque, start == nil { start = x }
                else if !opaque, let first = start { islands.append(first..<x); start = nil }
            }
            if let first = start { islands.append(first..<rendered.pixelsWide) }
            XCTAssertEqual(islands.count, surfaceCount, "The toolbar must paint \(surfaceCount) surfaces at \(width) points")
            if let first = islands.first, let last = islands.last {
                XCTAssertGreaterThan(first.lowerBound, 0)
                XCTAssertLessThan(last.upperBound, rendered.pixelsWide)
            }
            if islands.count == 3 {
                XCTAssertLessThanOrEqual(CGFloat(islands[1].count) / scale, 360.5)
            }
            let scroll = try XCTUnwrap(scrollView(in: host))
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(document.bounds.width, scroll.contentView.bounds.width,
                                 "The fixture must overflow at both floating toolbar widths")
            XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1,
                           "The selected last tab must be visible after mounting or changing rows")
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertLessThan(scroll.documentVisibleRect.maxX, document.bounds.maxX - 1)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: selected)
            try await settle()
            XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1,
                           "Keyboard activation must reveal the selected tab after the strip was scrolled away")
        }
        for window in windows { XCTAssertEqual(window.alphaValue, 0); XCTAssertTrue(window.ignoresMouseEvents) }
    }

    func testFloatingTabRendersAndRemovesItsNativeColorMarker() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/colored-tab.txt"), content: .text("book"))
        state.toolbarDisplayMode = .shown; state.theme = "light"
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 150),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Colored tab"; state.window = window
        let host = NSHostingView(rootView: ReaderFloatingControls(state: state, open: {}))
        window.contentView = host
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        func markerPixels() async throws -> Int {
            var rendered: NSBitmapImageRep?
            for _ in 0..<20 {
                NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                rendered = bitmap
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            // Cached views use the display's profile (Display P3 on this Mac).
            // Normalize the bitmap before comparing sRGB marker components.
            let bitmap = try XCTUnwrap(rendered?.converting(to: .sRGB, renderingIntent: .default))
            var result = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y),
                       color.redComponent > 0.9, color.blueComponent > 0.9, color.greenComponent < 0.1 {
                        result += 1
                    }
                }
            }
            return result
        }
        state.tabColor = 0xff00ff
        XCTAssertNotNil(window.tab.accessoryView)
        let colored = try await markerPixels()
        XCTAssertGreaterThan(colored, 5, "The native Tab Color marker must remain visible in the floating replacement")
        state.tabColor = nil
        XCTAssertNil(window.tab.accessoryView)
        let cleared = try await markerPixels()
        XCTAssertEqual(cleared, 0, "Clearing the native tab color must also clear its floating marker")
        XCTAssertFalse(window.isVisible)
    }

    func testFloatingWindowButtonsKeepNativeActionsTargetsAndCloseApproval() async throws {
        final class CloseApproval: NSObject, NSWindowDelegate {
            var requests = 0
            func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 150),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let approval = CloseApproval(); window.delegate = approval
        let controls = ReaderFloatingWindowButtons.Buttons(frame: CGRect(x: 0, y: 0, width: 54, height: 20))
        window.contentView?.addSubview(controls)
        defer { controls.removeFromSuperview(); window.delegate = nil; window.close() }
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3)
        for (button, type) in zip(buttons, [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]) {
            let native = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertEqual(button.action, native.action, "AppKit must retain its own modifier/fullscreen action")
            XCTAssertTrue(button.window === window)
            XCTAssertTrue(button.target === native.target)
            let target = NSApp.target(forAction: try XCTUnwrap(button.action), to: button.target, from: button)
            XCTAssertTrue((target as AnyObject?) === window)
            let capability: NSWindow.StyleMask
            switch type {
            case .closeButton: capability = .closable
            case .miniaturizeButton: capability = .miniaturizable
            default: capability = .resizable
            }
            window.styleMask.remove(capability)
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            XCTAssertFalse(button.isEnabled, "Button availability must follow actual window capabilities")
            window.styleMask.insert(capability)
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            XCTAssertTrue(button.isEnabled)
        }
        try XCTUnwrap(buttons.first).performClick(nil)
        XCTAssertEqual(approval.requests, 1, "The native close action must still honor document/window approval")
        let sheet = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 100, height: 50),
            styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.alphaValue = 0; sheet.ignoresMouseEvents = true
        window.alphaValue = 0; window.ignoresMouseEvents = true
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet) }
            sheet.orderOut(nil); sheet.close()
        }
        window.beginSheet(sheet, completionHandler: nil)
        window.update()
        XCTAssertTrue(window.attachedSheet === sheet)
        XCTAssertFalse(try XCTUnwrap(buttons.first).isEnabled)
        try XCTUnwrap(buttons.first).performClick(nil)
        XCTAssertEqual(approval.requests, 1, "An attached sheet blocks parent-window Close before asking for document approval")
        XCTAssertTrue(buttons.dropFirst().allSatisfy(\.isEnabled), "A sheet does not disable the native minimize and zoom capabilities")
        window.endSheet(sheet); sheet.orderOut(nil)
        let deadline = Date().addingTimeInterval(2)
        while window.attachedSheet != nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        window.update()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try XCTUnwrap(buttons.first).isEnabled)
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        controls.removeFromSuperview()
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled && $0.target == nil })
    }
}
#endif
