#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderFloatingNativeIntegrationTests: XCTestCase {
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
            // Fixed pages do not consume these reflow overrides. The actual
            // mounted viewport must still reserve full control clearance.
            let cases: [(Double, ReaderToolbarDisplayMode, ReaderToolbarDisplayMode, CGFloat, CGFloat)] = [
                (16, .auto, .shown, ReaderFloatingControls.topInset + ReaderFloatingControls.height + 2, 34),
                (24, .auto, .shown, ReaderFloatingControls.topInset + ReaderFloatingControls.height + 10, 40),
                (8, .auto, .shown, 0, 0), (24, .hidden, .hidden, 0, 0)
            ]
            for (margin, toolbar, progress, top, bottom) in cases {
                state.margin = margin; state.pageMargins = .init(cssValues: [margin])
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

    func testHomeHeaderKeepsWindowControlsAndOpenInsetWithoutDocumentTabs() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        let state = ReaderState(recordsHistory: false)
        state.window = window
        let host = NSHostingView(rootView: ReaderHomeHeader(state: state, open: {}))
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
            let buttons = mounted.compactMap { $0 as? NSButton }
            let open = try XCTUnwrap(buttons.first { !$0.isDescendant(of: controls) })
            XCTAssertEqual(open.convert(open.bounds, to: host).maxX, host.bounds.maxX - 16, accuracy: 1)
            XCTAssertEqual(buttons.count, 4, "Home has window controls and Open, without document-tab actions")
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
            let buttons = views(scroll).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 4, "Both documents keep independent selection and close targets")
            let closeButtons = buttons.filter { abs($0.bounds.width - 20) < 1 }
            XCTAssertEqual(closeButtons.count, 2)
            XCTAssertTrue(closeButtons.allSatisfy { $0.bounds.height >= 20 })
            if width >= 360 {
                let frame = scroll.convert(scroll.bounds, to: host)
                let lastClose = try XCTUnwrap(closeButtons.map { $0.convert($0.bounds, to: host) }.max { $0.maxX < $1.maxX })
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
