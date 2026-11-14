#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor final class UnifiedReaderTabsTests: XCTestCase {
    func testClosingATabReallocatesTheHostedCaptionsWithoutPointerMovement() async throws {
        let fixture = Fixture(count: 3)
        defer { fixture.close() }
        let window = fixture.windows[0]
        let host = try fixture.mountTabs().tabsView
        await settle(host)
        let before = targets(in: host)
        XCTAssertEqual(before.count, 3)
        let width = try XCTUnwrap(before.first).bounds.width
        let frame = window.frame
        XCTAssertTrue(window.ignoresMouseEvents, "No pointer input enters this hosted strip during the close")
        fixture.windows[2].close()
        await settle(host)
        let after = targets(in: host)
        XCTAssertEqual(after.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(after.first).bounds.width, width)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.tabGroup?.windows, Array(fixture.windows.prefix(2)))
    }

    func testCaptionsExposeSelectedRadioSemanticsAndSelectTheirRepresentedWindow() async throws {
        let fixture = Fixture(count: 3)
        defer { fixture.close() }
        let host = try fixture.mountTabs().tabsView
        await settle(host)
        let captions = targets(in: host)
        let selected = try XCTUnwrap(captions.first { $0.tabWindow === fixture.windows[0] })
        let sibling = try XCTUnwrap(captions.first { $0.tabWindow === fixture.windows[2] })
        XCTAssertEqual(selected.accessibilityRole(), .radioButton)
        XCTAssertEqual((selected.accessibilityValue() as? NSNumber)?.intValue, 1)
        XCTAssertEqual((sibling.accessibilityValue() as? NSNumber)?.intValue, 0)
        XCTAssertTrue(sibling.accessibilityPerformPress())
        XCTAssertTrue(fixture.windows[2].tabGroup?.selectedWindow === fixture.windows[2])
        XCTAssertTrue(sibling.tabWindow === fixture.windows[2], "The caption owns its represented sibling, not its hosting window")
    }

    func testDraggingReordersAroundTheSelectedSourceWithoutChangingItsDocumentWindow() {
        let fixture = Fixture(count: 4)
        defer { fixture.close() }
        let source = fixture.windows[1]
        XCTAssertEqual(source.tabGroup?.windows, fixture.windows)
        let frame = source.frame
        ReaderTabInteraction.Target.move(source, relativeTo: fixture.windows[3], before: false)
        XCTAssertEqual(source.tabGroup?.windows, [fixture.windows[0], fixture.windows[2], fixture.windows[3], source])
        XCTAssertTrue(source.tabGroup?.selectedWindow === source)
        ReaderTabInteraction.Target.move(source, relativeTo: fixture.windows[0], before: true)
        XCTAssertEqual(source.tabGroup?.windows, [source, fixture.windows[0], fixture.windows[2], fixture.windows[3]])
        XCTAssertTrue(source.tabGroup?.selectedWindow === source)
        XCTAssertEqual(source.frame, frame)
        XCTAssertTrue(fixture.states[1].window === source)
    }

    func testCrossGroupDropAndDetachOperateOnTheDraggedSiblingIncludingCancellation() {
        let sourceGroup = Fixture(count: 3)
        let destinationGroup = Fixture(count: 2)
        defer { sourceGroup.close(); destinationGroup.close() }
        let source = sourceGroup.windows[2]
        XCTAssertEqual(source.tabGroup?.windows, sourceGroup.windows)
        XCTAssertEqual(destinationGroup.windows[0].tabGroup?.windows, destinationGroup.windows)
        let destination = destinationGroup.windows[0]
        ReaderTabInteraction.Target.move(source, relativeTo: destination, before: false)
        XCTAssertEqual(sourceGroup.windows[0].tabGroup?.windows, Array(sourceGroup.windows.prefix(2)))
        XCTAssertEqual(destination.tabGroup?.windows, [destination, source, destinationGroup.windows[1]])
        XCTAssertTrue(source.tabGroup?.selectedWindow === source)
        let caption = ReaderTabInteraction.Target(frame: CGRect(x: 0, y: 0, width: 180, height: 28))
        caption.tabWindow = source
        sourceGroup.windows[0].contentView?.addSubview(caption)
        caption.finishDrag(at: CGPoint(x: -10000, y: -10000), operation: [], cancelled: true)
        XCTAssertTrue(source.tabGroup === destination.tabGroup)
        caption.finishDrag(at: CGPoint(x: -10000, y: -10000), operation: .move, cancelled: false)
        XCTAssertTrue(source.tabGroup === destination.tabGroup)
        caption.finishDrag(at: CGPoint(x: -10000, y: -10000), operation: [], cancelled: false)
        XCTAssertEqual(source.tabGroup?.windows ?? [source], [source])
        XCTAssertEqual(destination.tabGroup?.windows, destinationGroup.windows)
        XCTAssertEqual(sourceGroup.windows[0].tabGroup?.windows, Array(sourceGroup.windows.prefix(2)))
    }

    func testOnlyTheFrontmostVisibleStripAcceptsCaptionAndPlusAreaDrops() {
        _ = NSApplication.shared
        final class VisibilityWindow: NSWindow {
            var reportedVisible = true
            var reportedMiniaturized = false
            override var isVisible: Bool { reportedVisible }
            override var isMiniaturized: Bool { reportedMiniaturized }
        }
        for (visible, miniaturized) in [(true, false), (false, false), (true, true)] {
            let destination = VisibilityWindow(contentRect: CGRect(x: 3200, y: 100, width: 600, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            destination.isReleasedWhenClosed = false
            defer { destination.contentView = nil; destination.close() }
            destination.reportedVisible = visible
            destination.reportedMiniaturized = miniaturized
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 28))
            let strip = NSView(frame: scroll.bounds)
            scroll.documentView = strip
            let destinationCaption = ReaderTabInteraction.Target(frame: strip.bounds)
            strip.addSubview(destinationCaption)
            destination.contentView?.addSubview(scroll)
            for rightToLeft in [false, true] {
                destinationCaption.rightToLeft = rightToLeft
                let plusX: CGFloat = rightToLeft ? -14 : 514
                for x in [CGFloat(100), plusX] {
                    let point = destination.convertPoint(toScreen: scroll.convert(CGPoint(x: x, y: 14), to: nil))
                    XCTAssertEqual(ReaderTabInteraction.Target.isOverStrip(at: point, inWindowNumber: destination.windowNumber),
                                   visible && !miniaturized,
                                   "Only an exposed, visible strip or its plus area suppresses tear-off")
                    XCTAssertFalse(ReaderTabInteraction.Target.isOverStrip(at: point, inWindowNumber: -1),
                        "The same screen coordinates must not accept a drop through an occluding window")
                }
                let outside = destination.convertPoint(toScreen: scroll.convert(CGPoint(x: 100, y: 40), to: nil))
                XCTAssertFalse(ReaderTabInteraction.Target.isOverStrip(at: outside, inWindowNumber: destination.windowNumber))
            }
        }
    }

    func testShownNormalTabsStayBelowTheNativeToolbarWithAndWithoutDockedFind() async throws {
        let defaults = UserDefaults.standard
        let originalFind = defaults.object(forKey: "findFloating")
        defaults.set(false, forKey: "findFloating")
        defer {
            if let originalFind { defaults.set(originalFind, forKey: "findFloating") }
            else { defaults.removeObject(forKey: "findFloating") }
        }
        let fixture = Fixture(count: 2)
        defer { fixture.close() }
        let state = fixture.states[0]
        state.immersiveControls = false
        state.tabBarShown = true
        state.showContents = false; state.showAI = false; state.showFind = false
        // Match the scene's actual minimum size before measuring positions;
        // a bare ReaderView otherwise sizes this native fixture to its tools.
        let controller = NSHostingController(rootView: ReaderView(state: state).frame(minWidth: 560, minHeight: 400))
        let window = fixture.windows[0]
        window.styleMask.insert(.fullSizeContentView)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        window.setContentSize(CGSize(width: 800, height: 600))
        await settle(controller.view)
        let mountedFrame = window.frame
        let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.compactMap { $0 as? ReaderNormalTabsAccessory }.first)
        let caption = try XCTUnwrap(targets(in: accessory.view).first)
        XCTAssertEqual(caption.bounds.height, 28, accuracy: 0.5,
            "The tab content retains its intended input height inside AppKit's accessory framing")
        XCTAssertGreaterThanOrEqual(accessory.view.bounds.height, ReaderNormalDocumentTabs.height)
        let withoutFind = caption.convert(caption.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(withoutFind.minY, window.contentLayoutRect.maxY - 0.5,
            "AppKit's accessory owns the strip above the document's layout boundary")
        state.showFind = true
        await settle(controller.view)
        let withFindCaption = try XCTUnwrap(targets(in: accessory.view).first)
        let withFind = withFindCaption.convert(withFindCaption.bounds, to: nil)
        print("Unified shown tabs: frameBefore=\(mountedFrame) frameAfter=\(window.frame) captionBefore=\(withoutFind) captionAfter=\(withFind) nativeLayout=\(window.contentLayoutRect)")
        XCTAssertEqual(window.frame, mountedFrame, "Showing docked Find must preserve the mounted reader window frame")
        XCTAssertEqual(withFind.maxY, withoutFind.maxY, accuracy: 0.5,
            "Docked Find is below the tab row and must not add a second native-toolbar inset above it")
        XCTAssertEqual(withFind.height, withoutFind.height, accuracy: 0.5)
    }

    func testNormalAccessoryExistsOnlyWhileItsPresentationUsesTheRow() throws {
        let fixture = Fixture(count: 1)
        defer { fixture.close() }
        let state = fixture.states[0], window = fixture.windows[0]
        let host = ReaderToolbarWindow.Host(frame: .zero)
        host.state = state; host.reducedMotion = true
        window.contentView?.addSubview(host)
        defer { host.detach(); host.removeFromSuperview() }
        func owned() -> [ReaderNormalTabsAccessory] {
            window.titlebarAccessoryViewControllers.compactMap { $0 as? ReaderNormalTabsAccessory }
        }
        state.tabBarShown = false
        host.updateChrome()
        XCTAssertTrue(owned().isEmpty, "A single document without a tab bar must not change titlebar accessory ownership")
        state.tabBarShown = true
        host.updateChrome()
        let original = try XCTUnwrap(owned().first)
        state.toolbarDisplayMode = .auto
        host.updateChrome()
        XCTAssertTrue(owned().first === original, "Auto Hide keeps its existing allocated row")
        state.toolbarDisplayMode = .hidden
        host.updateChrome()
        XCTAssertTrue(owned().isEmpty)
        state.toolbarDisplayMode = .shown; state.immersiveControls = true
        host.updateChrome()
        XCTAssertTrue(owned().isEmpty, "Floating controls must not install a native accessory that reparents fullscreen chrome")
        state.immersiveControls = false; state.presentation = true
        host.updateChrome()
        XCTAssertTrue(owned().isEmpty)
        state.presentation = false; state.document = nil
        host.updateChrome()
        XCTAssertTrue(owned().isEmpty, "Home owns no document tab accessory")
    }

    private func targets(in view: NSView) -> [ReaderTabInteraction.Target] {
        (view as? ReaderTabInteraction.Target).map { [$0] } ?? view.subviews.flatMap { targets(in: $0) }
    }
    private func settle(_ host: NSView) async {
        for _ in 0..<8 {
            NSApp.updateWindows()
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private final class Fixture {
        let states: [ReaderState]
        let windows: [NSWindow]
        private var tabHosts: [ReaderToolbarWindow.Host] = []
        init(count: Int) {
            _ = NSApplication.shared
            states = (0..<count).map { index in
                let state = ReaderState(recordsHistory: false)
                state.toolbarDisplayMode = .shown
                state.immersiveControls = false
                state.document = ReadingDocument(url: URL(fileURLWithPath: "/unified-tab-\(index).txt"), content: .text("Book \(index)"))
                return state
            }
            let identifier = "Unified-Tabs-" + UUID().uuidString
            let visibleFrame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let origin = CGPoint(x: visibleFrame.midX - 350, y: visibleFrame.midY - 250)
            windows = states.enumerated().map { index, state in
                let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 700, height: 500)),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0; window.ignoresMouseEvents = true
                window.title = "Book \(index)"
                window.tabbingIdentifier = identifier
                state.window = window
                return window
            }
            for index in windows.indices.dropFirst() { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
            windows[0].tabGroup?.selectedWindow = windows[0]
            for state in states { state.tabCount = windows.count }
        }
        func mountTabs() throws -> ReaderNormalTabsAccessory {
            let host = ReaderToolbarWindow.Host(frame: .zero)
            host.state = states[0]
            host.reducedMotion = true
            windows[0].contentView?.addSubview(host)
            tabHosts.append(host)
            host.updateChrome()
            return try XCTUnwrap(windows[0].titlebarAccessoryViewControllers.compactMap { $0 as? ReaderNormalTabsAccessory }.first)
        }
        func close() {
            for host in tabHosts { host.detach(); host.removeFromSuperview() }
            tabHosts.removeAll()
            for (window, state) in zip(windows, states) {
                window.contentView = nil; window.delegate = nil
                window.close(); state.windowClosed()
            }
        }
    }
}
#endif
