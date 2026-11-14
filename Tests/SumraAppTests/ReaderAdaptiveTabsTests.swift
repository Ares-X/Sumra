#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderAdaptiveTabsTests: XCTestCase {
    func testWholeToolbarAdaptsToTabCountAndMeasuredSideControls() async throws {
        var wideWidths: [Int: CGFloat] = [:]
        for count in [1, 2, 6, 12] {
            let fixture = Fixture(count: count)
            defer { fixture.close() }
            for width in [560.0, 680.0, 1000.0, 1600.0] {
                fixture.window.setContentSize(CGSize(width: width, height: 150))
                try await settle(fixture)
                let elements = try accessibilityElements(in: fixture.window)
                let navigation = try XCTUnwrap(elements.first { $0.identifier == "floating-navigation" }).frame
                let documents = try XCTUnwrap(elements.first { $0.identifier == "floating-documents" }).frame
                let tools = try XCTUnwrap(elements.first { $0.identifier == "floating-tools" }).frame
                XCTAssertGreaterThan(documents.width, 0)
                XCTAssertLessThan(navigation.maxX, documents.minX, "Navigation must keep its own gap at \(count) tabs / \(width) points")
                XCTAssertLessThan(documents.maxX, tools.minX, "The tab surface must stop before the measured tools")
                XCTAssertEqual(documents.midY, navigation.midY, accuracy: 1)
                XCTAssertEqual(documents.midY, tools.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(navigation.minX, fixture.window.frame.minX)
                XCTAssertLessThanOrEqual(tools.maxX, fixture.window.frame.maxX)
                if width == 1600 { wideWidths[count] = documents.width }
                if count > 1 {
                    let scroll = try XCTUnwrap(descendants(fixture.host).compactMap { $0 as? NSScrollView }.first)
                    XCTAssertGreaterThan(scroll.contentView.bounds.width, 0)
                    if count == 12 && width == 560 {
                        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.width, scroll.contentView.bounds.width)
                    }
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(wideWidths[2]), try XCTUnwrap(wideWidths[1]))
        XCTAssertGreaterThan(try XCTUnwrap(wideWidths[6]), try XCTUnwrap(wideWidths[2]))
        XCTAssertGreaterThan(try XCTUnwrap(wideWidths[6]), 360, "Several tabs can use the free space beyond the old fixed ceiling")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(wideWidths[12]), try XCTUnwrap(wideWidths[6]))
    }

    func testVerticalWheelReachesOverflowAndPreservesSelectionVisibilityOnReactivation() async throws {
        let fixture = Fixture(count: 12, fullSizeContent: true, readerSurface: true)
        defer { fixture.close() }
        fixture.window.setContentSize(CGSize(width: 560, height: 150))
        try await settle(fixture)
        let surface = try XCTUnwrap(try accessibilityElements(in: fixture.window).first { $0.identifier == "floating-documents" }).frame
        let scroll = try XCTUnwrap(descendants(fixture.host).compactMap { $0 as? NSScrollView }.first { view in
            let frame = fixture.window.convertToScreen(view.convert(view.bounds, to: nil))
            return surface.contains(CGPoint(x: frame.midX, y: frame.midY))
        })
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.width, scroll.contentView.bounds.width)
        XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1,
                       "The selected last native tab must initially be visible")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let point = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let originalPage = fixture.state.page
        let selected = fixture.window.tabGroup?.selectedWindow
        func wheel(_ delta: Int32, x: Int32 = 0) throws {
            let event = try wheelEvent(window: fixture.window, point: point, y: delta, x: x)
            let hit = try XCTUnwrap(ReaderState.hitView(for: event))
            XCTAssertTrue(hit === scroll || hit.enclosingScrollView === scroll,
                          "The mounted tab viewport must own the real window hit")
            hit.scrollWheel(with: event)
        }
        try wheel(-1)
        let advanced = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(advanced, 0, "An ordinary vertical mouse notch must move the horizontal strip")
        try wheel(1)
        XCTAssertLessThan(scroll.contentView.bounds.minX, advanced)
        for _ in 0..<100 { try wheel(-1) }
        XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1,
                       "Repeated notches must reach the final document")
        try wheel(-1)
        XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1)
        for _ in 0..<100 { try wheel(1) }
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
        try wheel(0, x: -1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0, "Native horizontal wheel input must still scroll")
        XCTAssertEqual(fixture.state.page, originalPage)
        XCTAssertTrue(fixture.window.tabGroup?.selectedWindow === selected)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
        try await settle(fixture)
        XCTAssertEqual(scroll.documentVisibleRect.maxX, document.bounds.maxX, accuracy: 1,
                       "Reactivation must reveal selection after manual scrolling")
        let elements = try accessibilityElements(in: fixture.window)
        let selection = try XCTUnwrap(elements.first { $0.role == .radioButton && $0.label == fixture.window.title })
        let close = try XCTUnwrap(elements.first { $0.role == .button && $0.label == L("Close Tab") + ": " + fixture.window.title })
        XCTAssertGreaterThanOrEqual(selection.frame.height, 28)
        XCTAssertGreaterThanOrEqual(close.frame.height, 20)
        let lowerPoint = fixture.window.convertFromScreen(CGRect(x: selection.frame.minX + 10,
            y: selection.frame.minY + 2, width: 0, height: 0)).origin
        let root = try XCTUnwrap(fixture.window.contentView?.superview)
        let hit = try XCTUnwrap(root.hitTest(root.convert(lowerPoint, from: nil)))
        XCTAssertTrue(hit.enclosingScrollView === scroll, "The lower half of the selected tab remains in the tab viewport")
    }

    func testRTLSelectedTabRemainsVisibleAfterMountResizeAndReactivation() async throws {
        let fixture = Fixture(count: 12, layoutDirection: .rightToLeft)
        defer { fixture.close() }
        for width in [560.0, 1000.0, 560.0] {
            fixture.window.setContentSize(CGSize(width: width, height: 150))
            try await settle(fixture)
            let scroll = try XCTUnwrap(descendants(fixture.host).compactMap { $0 as? NSScrollView }.first)
            func assertSelectedVisible() throws {
                let elements = try accessibilityElements(in: fixture.window)
                let selected = try XCTUnwrap(elements.first { $0.role == .radioButton && $0.label == fixture.window.title })
                let viewport = fixture.window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                XCTAssertGreaterThan(selected.frame.width, 0)
                XCTAssertGreaterThanOrEqual(selected.frame.minX, viewport.minX - 1)
                XCTAssertLessThanOrEqual(selected.frame.maxX, viewport.maxX + 1,
                    "The selected native tab must be visible in its RTL visual position")
            }
            try assertSelectedVisible()
            let document = try XCTUnwrap(scroll.documentView)
            scroll.contentView.scroll(to: CGPoint(x: max(0, document.bounds.width - scroll.contentView.bounds.width), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.window)
            try await settle(fixture)
            try assertSelectedVisible()
        }
    }

    func testMountedToolbarRespondsToNativeMembershipAndWiderZoomLabel() async throws {
        let fixture = Fixture(count: 2)
        defer { fixture.close() }
        fixture.window.setContentSize(CGSize(width: 1600, height: 150))
        try await settle(fixture)
        func documentsFrame() throws -> CGRect {
            try XCTUnwrap(accessibilityElements(in: fixture.window).first { $0.identifier == "floating-documents" }).frame
        }
        let initialWidth = try documentsFrame().width
        let sibling = try XCTUnwrap(fixture.windows.first { $0 !== fixture.window })
        fixture.window.tabGroup?.removeWindow(sibling)
        sibling.orderOut(nil)
        try await settle(fixture)
        XCTAssertLessThan(try documentsFrame().width, initialWidth,
                          "Removing a native group member must shrink the mounted tab surface")
        fixture.window.addTabbedWindow(sibling, ordered: .above)
        fixture.window.tabGroup?.selectedWindow = fixture.window
        try await settle(fixture)
        XCTAssertEqual(try documentsFrame().width, initialWidth, accuracy: 1)
        fixture.window.setContentSize(CGSize(width: 680, height: 150))
        try await settle(fixture)
        let before = try accessibilityElements(in: fixture.window)
        let oldTools = try XCTUnwrap(before.first { $0.identifier == "floating-tools" }).frame
        let oldDocuments = try documentsFrame()
        fixture.state.zoom = 12.345
        try await settle(fixture)
        let after = try accessibilityElements(in: fixture.window)
        let tools = try XCTUnwrap(after.first { $0.identifier == "floating-tools" }).frame
        let documents = try documentsFrame()
        XCTAssertGreaterThan(tools.width, oldTools.width)
        XCTAssertLessThan(documents.width, oldDocuments.width,
                          "A wider actual tool label must reduce the constrained middle viewport")
        XCTAssertLessThan(documents.maxX, tools.minX)
    }

    func testFullSizeNativeTabWindowsKeepHostedTabTargetsInsideTheViewport() async throws {
        for count in [2, 12] {
            let fixture = Fixture(count: count, fullSizeContent: true)
            defer { fixture.close() }
            for width in [560.0, 1000.0, 560.0] {
                fixture.window.setContentSize(CGSize(width: width, height: 150))
                try await settle(fixture)
                let scroll = try XCTUnwrap(descendants(fixture.host).compactMap { $0 as? NSScrollView }.first)
                let viewport = fixture.window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
                let elements = try accessibilityElements(in: fixture.window)
                let surface = try XCTUnwrap(elements.first { $0.identifier == "floating-documents" }).frame
                let selection = try XCTUnwrap(elements.first { $0.role == .radioButton && $0.label == fixture.window.title })
                let close = try XCTUnwrap(elements.first {
                    $0.role == .button && $0.label == L("Close Tab") + ": " + fixture.window.title
                })
                XCTAssertGreaterThanOrEqual(selection.frame.height, 28)
                XCTAssertGreaterThanOrEqual(close.frame.height, 20)
                for target in [selection, close] {
                    XCTAssertGreaterThanOrEqual(target.frame.minY, viewport.minY - 1,
                        "Native titlebar safe areas must not shift a hosted tab target below its clip view")
                    XCTAssertLessThanOrEqual(target.frame.maxY, viewport.maxY + 1,
                        "The complete target must fit vertically inside the native scroll viewport")
                    XCTAssertGreaterThanOrEqual(target.frame.minY, surface.minY - 1)
                    XCTAssertLessThanOrEqual(target.frame.maxY, surface.maxY + 1,
                        "Hosted tab targets must stay inside the painted floating surface")
                }
            }
        }
    }

    @MainActor private final class Fixture {
        let state: ReaderState
        let windows: [NSWindow]
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(count: Int, layoutDirection: LayoutDirection = .leftToRight, fullSizeContent: Bool = false, readerSurface: Bool = false) {
            _ = NSApplication.shared
            NSApp.finishLaunching()
            let identifier = UUID().uuidString
            let ownedWindows = (0..<count).map { index in
                let style: NSWindow.StyleMask = fullSizeContent
                    ? [.titled, .closable, .resizable, .fullSizeContentView] : [.titled, .closable, .resizable]
                let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 1000, height: 150),
                    styleMask: style, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0; window.ignoresMouseEvents = true
                window.title = "Adaptive \(index) \(identifier).epub"
                if fullSizeContent {
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.toolbarStyle = .unifiedCompact
                }
                return window
            }
            for sibling in ownedWindows.dropFirst() { ownedWindows[0].addTabbedWindow(sibling, ordered: .above) }
            let selectedWindow = ownedWindows[0].tabGroup?.windows.last ?? ownedWindows[0]
            selectedWindow.tabGroup?.selectedWindow = selectedWindow
            let readerState = ReaderState(recordsHistory: false)
            readerState.window = selectedWindow
            readerState.document = ReadingDocument(url: URL(fileURLWithPath: "/\(selectedWindow.title)"), content: .text("book"))
            readerState.toolbarDisplayMode = .shown
            readerState.immersiveControls = true
            let controls = ReaderFloatingControls(state: readerState, open: {})
                .environment(\.layoutDirection, layoutDirection)
            // Input in a full-size native window needs the actual chrome owner
            // to retire the native tab/titlebar hit surface, just as in the app.
            let root = readerSurface ? AnyView(ReaderView(state: readerState))
                : fullSizeContent ? AnyView(controls.ignoresSafeArea()) : AnyView(controls)
            let hostingView = NSHostingView(rootView: root)
            selectedWindow.contentView = hostingView
            selectedWindow.orderBack(nil)
            windows = ownedWindows; window = selectedWindow; state = readerState; host = hostingView
        }

        func close() {
            window.contentView = nil
            for window in windows { window.orderOut(nil); window.close() }
            state.windowClosed()
        }
    }

    private func settle(_ fixture: Fixture) async throws {
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: fixture.window)
        for _ in 0..<20 {
            fixture.host.layoutSubtreeIfNeeded()
            if let bitmap = fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds) {
                fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private struct Element {
        let role: NSAccessibility.Role
        let label: String?
        let identifier: String?
        let frame: CGRect
    }

    private func accessibilityElements(in window: NSWindow) throws -> [Element] {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        let application = AXUIElementCreateApplication(getpid())
        let windows = try XCTUnwrap(attribute(application, kAXWindowsAttribute) as? [AXUIElement])
        let target = try XCTUnwrap(windows.first { attribute($0, kAXTitleAttribute) as? String == window.title })
        func collect(_ element: AXUIElement) -> [Element] {
            var position = CGPoint.zero, size = CGSize.zero
            if let value = attribute(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgPoint, &position)
            }
            if let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                AXValueGetValue(value as! AXValue, .cgSize, &size)
            }
            let item = Element(role: NSAccessibility.Role(rawValue: attribute(element, kAXRoleAttribute) as? String ?? ""),
                label: attribute(element, kAXDescriptionAttribute) as? String ?? attribute(element, kAXTitleAttribute) as? String,
                identifier: attribute(element, kAXIdentifierAttribute) as? String,
                frame: CGRect(x: position.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - position.y - size.height,
                              width: size.width, height: size.height))
            return [item] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(collect)
        }
        return collect(target)
    }

    private func wheelEvent(window: NSWindow, point: CGPoint, y: Int32, x: Int32 = 0) throws -> NSEvent {
        let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let cg = try XCTUnwrap(seed.cgEvent?.copy())
        cg.type = .scrollWheel
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.window === window)
        return event
    }
}
#endif
