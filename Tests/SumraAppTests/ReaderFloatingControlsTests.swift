#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import SumraCore
@testable import Sumra

@MainActor final class ReaderFloatingControlsTests: XCTestCase {
    func testFloatingNativeWindowButtonsPaintHoverAndClearItWithoutReplacingTheirActions() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 100, height: 60),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controls = ReaderFloatingWindowButtons.Buttons(frame: CGRect(x: 16, y: 20, width: 54, height: 20))
        let host = try XCTUnwrap(window.contentView)
        host.addSubview(controls)
        defer { controls.stopObservingWindow(); window.contentView = nil; window.close() }
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        XCTAssertEqual(buttons.count, 3)
        let actions = try types.map { type in
            try XCTUnwrap(NSWindow.standardWindowButton(type, for: window.styleMask)?.action)
        }
        controls.updateTrackingAreas()
        func pointer(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            if type == .mouseMoved {
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: controls.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0))
            }
            return try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: controls.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        func raster() throws -> Data {
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true; controls.needsDisplay = true
            buttons.forEach { $0.needsDisplay = true }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            controls.mouseExited(with: try pointer(.mouseExited, at: .zero))
            let baseline = try raster()
            for (button, action) in zip(buttons, actions) {
                let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
                XCTAssertTrue(controls.hitTest(controls.convert(point, to: host)) === button)
                controls.mouseEntered(with: try pointer(.mouseEntered, at: point))
                XCTAssertNotEqual(try raster(), baseline, "Hover must visibly paint in \(appearance.rawValue)")
                XCTAssertTrue(button.target === window)
                XCTAssertEqual(button.action, action, "AppKit keeps ownership of window actions and modifier semantics")
                XCTAssertFalse(button.isHighlighted, "Hover must not masquerade as the native pressed state")
                controls.mouseMoved(with: try pointer(.mouseMoved, at: NSPoint(x: 18, y: 10)))
                XCTAssertEqual(try raster(), baseline, "Moving between native hit regions clears the feedback")
                controls.mouseEntered(with: try pointer(.mouseEntered, at: point))
                controls.mouseExited(with: try pointer(.mouseExited, at: .zero))
                XCTAssertEqual(try raster(), baseline, "Exit removes the feedback")
            }
            controls.mouseEntered(with: try pointer(.mouseEntered, at: NSPoint(x: 27, y: 10)))
            controls.removeFromSuperview()
            host.addSubview(controls)
            XCTAssertEqual(try raster(), baseline, "Unmounting clears a retained hover")
        }
        window.styleMask.remove(.miniaturizable)
        controls.updateButtons()
        let minimize = buttons[1]
        XCTAssertFalse(minimize.isEnabled)
        let disabledBaseline = try raster()
        controls.mouseEntered(with: try pointer(.mouseEntered, at: NSPoint(x: minimize.frame.midX, y: minimize.frame.midY)))
        XCTAssertEqual(try raster(), disabledBaseline, "Unavailable actions must not receive hover emphasis")
        XCTAssertFalse(window.isVisible)
    }

    func testWelcomeDocumentAndHomeKeepTheirOwnChromeAndRetainTheFloatingSetting() async throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.immersiveControls = true; state.toolbarDisplayMode = .shown
        state.showContents = false; state.showAI = false; state.showFind = false
        let controller = NSHostingController(rootView: ReaderView(state: state))
        let window = NSWindow(contentViewController: controller)
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.setContentSize(CGSize(width: 800, height: 600))
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        state.window = window
        let nativeButtons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let host = controller.view
        window.orderBack(nil)
        defer { state.windowClosed(); window.orderOut(nil); window.contentViewController = nil; window.close() }
        func groups(in view: NSView) -> [ReaderFloatingWindowButtons.Buttons] {
            (view as? ReaderFloatingWindowButtons.Buttons).map { [$0] } ?? view.subviews.flatMap { groups(in: $0) }
        }
        func toolbar(in view: NSView) -> NSView? {
            if view === host { return nil }
            if view.accessibilityRole() == .toolbar { return view }
            return view.subviews.lazy.compactMap { toolbar(in: $0) }.first
        }
        func settle() async throws {
            for _ in 0..<25 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func assertHomeChrome() throws {
            XCTAssertFalse(state.hasDocument)
            XCTAssertFalse(state.usesFloatingChrome)
            XCTAssertTrue(state.usesCustomChrome)
            XCTAssertTrue(state.immersiveControls)
            let homeButtons = try XCTUnwrap(groups(in: host).first)
            XCTAssertEqual(groups(in: host).count, 1, "Home has one fixed header, without a reading overlay")
            XCTAssertEqual(homeButtons.convert(homeButtons.bounds, to: host).minX, 16, accuracy: 1)
            XCTAssertTrue(try XCTUnwrap(window.toolbar).isVisible,
                          "Keep the installed native layout while its chrome is hidden")
            if let nativeToolbar = toolbar(in: try XCTUnwrap(host.superview)) {
                XCTAssertTrue(nativeToolbar.isHiddenOrHasHiddenAncestor || nativeToolbar.alphaValue == 0)
            }
            XCTAssertEqual(nativeButtons.count, 3)
            for button in nativeButtons {
                XCTAssertTrue(button.isHiddenOrHasHiddenAncestor || button.superview?.alphaValue == 0)
                XCTAssertEqual(button.alphaValue, 1)
                XCTAssertTrue(button.isEnabled)
            }
            XCTAssertTrue(window.validateUserInterfaceItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")))
        }
        try await settle()
        try assertHomeChrome()
        state.busy = true
        try await settle()
        try assertHomeChrome()
        state.busy = false
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/welcome-reading-boundary.txt"), content: .text("Reading content."))
        try await settle()
        XCTAssertTrue(state.usesFloatingChrome)
        XCTAssertEqual(groups(in: host).count, 1)
        XCTAssertTrue(state.immersiveControls)
        state.busy = true
        XCTAssertTrue(state.usesFloatingChrome, "An existing document stays readable while its replacement loads")
        state.busy = false
        state.close()
        let deadline = Date().addingTimeInterval(2)
        while state.hasDocument, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try await settle()
        try assertHomeChrome()
        XCTAssertFalse(window.isKeyWindow)
    }

    func testFloatingHoverPreservesPaintedBookGeometryAndPassageAtBothWindowWidths() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("floating.fb2")
        let text = (0..<120).map { "<p>Paragraph \($0) remains still under the floating reading controls.</p>" }.joined()
        try "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>\(text)</section></body></FictionBook>"
            .write(to: input, atomically: true, encoding: .utf8)
        defer { withExtendedLifetime(directory) {} }
        for width in [560.0, 1000.0] {
            let state = ReaderState(recordsHistory: false)
            let document = try ReadingDocument.open(input, deferReflowLayout: true)
            guard case .pages(let pages) = document.content else { return XCTFail("Expected reflow book") }
            state.document = document; state.flow = "paged"; state.spread = true; state.cover = false
            state.automaticLayout = false; state.fit = "page"; state.scrollbarMode = "hidden"
            state.showContents = false; state.showAI = false; state.showFind = false
            state.margin = 16; state.pageMargins = PageMargins(cssValues: [16])
            state.immersiveControls = true; state.toolbarDisplayMode = .auto
            state.typographyForAll = false
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: width, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.toolbarStyle = .unifiedCompact
            window.toolbar = NSToolbar(identifier: "floating-book")
            state.window = window
            let host = NSHostingView(rootView: ReaderView(state: state))
            window.contentView = host
            defer { state.windowClosed(); window.contentView = nil; window.close() }
            func paint() {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
            }
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint()
                let viewport = state.readerScrollView?.contentView.safeAreaRect.size ?? .zero
                let expected = RasterReader.pageSize(in: viewport, spread: true, continuous: false)
                if RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)),
                   state.pendingReflowPosition == nil, state.currentPosition.nativePassage != nil {
                    let current = try await pages.bounds(state.page)
                    if abs(current.width - expected.width) < 0.5, abs(current.height - expected.height) < 0.5 { break }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            XCTAssertNil(state.error)
            let scroll = try XCTUnwrap(state.readerScrollView)
            let passage = try XCTUnwrap(state.currentPosition.nativePassage)
            let frame = scroll.convert(scroll.bounds, to: nil)
            let viewport = scroll.contentView.safeAreaRect.size
            let generation = state.chapterLayout?.generation
            let revision = state.renderRevision
            for shown in [true, false, true, false] {
                state.toolbarHoverVisible = shown; state.toolbarHoverOpacity = shown ? 1 : 0
                for _ in 0..<20 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertEqual(scroll.convert(scroll.bounds, to: nil), frame)
                XCTAssertEqual(scroll.contentView.safeAreaRect.size, viewport)
                XCTAssertEqual(state.chapterLayout?.generation, generation)
                XCTAssertEqual(state.renderRevision, revision)
                XCTAssertEqual(state.currentPosition.nativePassage, passage)
            }
            XCTAssertFalse(window.isVisible)
        }
    }

    func testFloatingHoverRetainsTheWholeControlGroupAtNarrowWidth() throws {
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/floating.txt"), content: .text("book"))
        state.immersiveControls = true; state.toolbarDisplayMode = .auto
        let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 560, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = ReaderToolbarWindow.Host()
        observer.state = state; observer.reducedMotion = true
        window.contentView?.addSubview(observer)
        defer { observer.detach(); window.contentView = nil; window.close(); state.windowClosed() }
        observer.pointerMoved(to: CGPoint(x: 280, y: window.frame.height - 60))
        XCTAssertTrue(state.toolbarShown)
        observer.pointerMoved(to: CGPoint(x: 280, y: window.frame.height - 85))
        XCTAssertTrue(state.toolbarShown, "All floating controls stay reachable within the retained band")
        observer.pointerMoved(to: CGPoint(x: 280, y: window.frame.height - 200))
        XCTAssertFalse(state.toolbarShown)
    }

    func testTextAndBrowserUseTheSameFloatingClearanceWithoutHoverRelayout() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let previousProgress = UserDefaults.standard.object(forKey: "progressDisplayMode")
        UserDefaults.standard.set("shown", forKey: "progressDisplayMode")
        defer { UserDefaults.standard.set(previousProgress, forKey: "progressDisplayMode") }
        let previousFindFloating = UserDefaults.standard.object(forKey: "findFloating")
        UserDefaults.standard.set(false, forKey: "findFloating")
        defer {
            if let previousFindFloating { UserDefaults.standard.set(previousFindFloating, forKey: "findFloating") }
            else { UserDefaults.standard.removeObject(forKey: "findFloating") }
        }
        for suffix in ["txt", "html", "fb2"] {
            let input = directory.url.appendingPathComponent("margins.\(suffix)")
            let text = String(repeating: "Reading content keeps its position under the toolbar. ", count: 100)
            let source: String
            switch suffix {
            case "html": source = "<html><body><p>\(text)</p></body></html>"
            case "fb2": source = "<FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section><p>\(text)</p></section></body></FictionBook>"
            default: source = text
            }
            try source.write(to: input, atomically: true, encoding: .utf8)
            let state = ReaderState(recordsHistory: false)
            state.document = try ReadingDocument.open(input, deferReflowLayout: true)
            state.showContents = false; state.showAI = false; state.showFind = false
            state.flow = "continuous"; state.spread = false
            state.immersiveControls = true; state.toolbarDisplayMode = .auto
            state.typographyForAll = false
            state.controlTopMargin = 54; state.controlBottomMargin = 44
            state.margin = 16; state.pageMargins = PageMargins(cssValues: [16]); state.marginPresetSelection = "custom"
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; state.window = window
            let host = NSHostingView(rootView: ReaderView(state: state))
            window.contentView = host
            defer { state.windowClosed(); window.contentView = nil; window.close() }
            func settle() async throws {
                for _ in 0..<50 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            try await settle()
            let reader = try XCTUnwrap((state.browserView as NSView?) ?? state.readerScrollView)
            let stableWindowFrame = window.frame
            func frameInHost() -> CGRect {
                let frame = reader.convert(reader.bounds, to: host)
                // The root host fills the actual content area. Verify the top
                // distance independently in window coordinates as well.
                let content = host.convert(host.bounds, to: nil)
                let viewport = reader.convert(reader.bounds, to: nil)
                XCTAssertEqual(content.maxY - viewport.maxY, frame.minY, accuracy: 0.1, suffix)
                XCTAssertEqual(window.frame, stableWindowFrame, "Margin changes must not resize the window")
                if suffix == "fb2", let scroll = state.readerScrollView {
                    let clip = scroll.contentView
                    XCTAssertEqual(clip.convert(clip.safeAreaRect, to: host).minY, frame.minY, accuracy: 1,
                                   "The native reading viewport must not add a second titlebar safe area")
                }
                return frame
            }
            func assertClearance(top: CGFloat, bottom: CGFloat) {
                let frame = frameInHost()
                XCTAssertEqual(frame.minY + CGFloat(state.contentMargins?.top ?? 0), top, accuracy: 1, suffix)
                XCTAssertEqual(host.bounds.height - frame.maxY + CGFloat(state.contentMargins?.bottom ?? 0), bottom, accuracy: 1, suffix)
            }
            let mediumFrame = frameInHost()
            assertClearance(top: 54, bottom: 44)
            state.toolbarHoverVisible = true; state.toolbarHoverOpacity = 1
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(frameInHost(), mediumFrame, suffix)

            for preset in ReaderMarginPreset.allCases {
                state.applyMarginPreset(preset)
                try await settle()
                assertClearance(top: 54, bottom: 44)
                XCTAssertEqual(frameInHost().width, mediumFrame.width, accuracy: 1)
            }
            state.setCustomMargins(PageMargins(cssValues: [80]))
            try await settle()
            assertClearance(top: 80, bottom: 80)
            state.setCustomMargins(nil)
            try await settle()
            assertClearance(top: 54, bottom: 44)
            state.setCustomMargins(PageMargins(cssValues: [16]))
            for (top, bottom) in [(76.0, 44.0), (76.0, 67.0), (0.0, 67.0), (0.0, 0.0)] {
                state.setControlMargins(top: top, bottom: bottom)
                try await settle()
                assertClearance(top: CGFloat(max(16, top)), bottom: CGFloat(max(16, bottom)))
                let frame = frameInHost()
                state.toolbarHoverVisible.toggle()
                state.toolbarHoverOpacity = state.toolbarHoverVisible ? 1 : 0
                try await settle()
                XCTAssertEqual(frameInHost(), frame, "Control visibility must not relayout \(suffix)")
            }
            state.setControlMargins(top: 76, bottom: 67)
            state.toolbarDisplayMode = .hidden
            try await settle()
            assertClearance(top: 16, bottom: 67)
            UserDefaults.standard.set("hidden", forKey: "progressDisplayMode")
            try await settle()
            assertClearance(top: 16, bottom: 16)
            UserDefaults.standard.set("shown", forKey: "progressDisplayMode")
            state.toolbarDisplayMode = .auto
            state.setControlMargins(top: 0, bottom: 0)
            try await settle()
            XCTAssertEqual(frameInHost().minY, 0, accuracy: 1,
                           "Zero control spacing must allow reading under the floating controls")
            state.showFind = true
            try await settle()
            let field = try XCTUnwrap(state.findInputField)
            XCTAssertGreaterThanOrEqual(field.convert(field.bounds, to: host).minY,
                                        ReaderFloatingControls.topInset + ReaderFloatingControls.height,
                                        "Zero control spacing may overlay reading content, but Find must remain below the floating toolbar")
            state.showFind = false
            XCTAssertFalse(window.isVisible)
        }
    }
}
#endif
