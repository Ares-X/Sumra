#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

// Exercise the production AppKit factory with isolated windows. Actual
// fullscreen Spaces require GUI acceptance.
@MainActor
final class NativeHostedTabWindowTests: XCTestCase {
    func testExplicitTabIsHostedWithItsOriginalIdentityBeforeNativeJoinAndReleasedOnClose() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("Native hosting uses the macOS 14 toolbar bridge") }
        let fixture = try Fixture()
        defer { fixture.close() }
        let payload = fixture.tabRequest()
        weak var retiredController: NSWindowController?
        weak var retiredWindow: NSWindow?
        var joins = 0
        fixture.parent.willAddTab = { child in
            joins += 1
            XCTAssertFalse(child.isVisible, "The new reader must enter native grouping before its first ordering")
            XCTAssertGreaterThan(child.windowNumber, 0, "Unselected tabs need their native identity before entering the tab model")
            XCTAssertFalse(child.isRestorable, "The app session owns this reader's payload, not an incomplete native controller archive")
            XCTAssertNotNil(child.contentViewController, "Install the production reader before grouping its window")
            XCTAssertTrue(child.windowController === fixture.application.readerWindowControllers[payload.id])
            XCTAssertEqual(child.tabbingIdentifier, fixture.parent.tabbingIdentifier)
            XCTAssertEqual(child.contentMinSize, NSSize(width: 560, height: 400))
            XCTAssertEqual(child.toolbarStyle, .unifiedCompact)
        }

        try autoreleasepool {
            fixture.application.openReaderWindow(payload)
            let controller = try XCTUnwrap(fixture.application.readerWindowControllers[payload.id])
            let child = try XCTUnwrap(controller.window)
            retiredController = controller; retiredWindow = child
            XCTAssertEqual(joins, 1, "The controller owns one native join; its hosted scene must not join again")
            XCTAssertTrue(fixture.sceneRequests.isEmpty, "An explicit tab with a live parent uses the native factory")
            XCTAssertEqual(fixture.parent.tabGroup?.windows, [fixture.parent, child])
            child.contentView?.layoutSubtreeIfNeeded()
            let owner = try XCTUnwrap(child.delegate as? ReaderCloseGuard)
            XCTAssertEqual(owner.restorationID, payload.id, "The native root must keep the original opening request identity")
            XCTAssertEqual(owner.openingPath, payload.path)
            let state = try XCTUnwrap(owner.state)
            XCTAssertTrue(state.window === child)

            // Close synchronously, before the first yield can run scene-ready
            // selection. Keep the window itself alive to inspect native teardown.
            child.close()
            XCTAssertTrue(fixture.application.readerWindowControllers.isEmpty)
            XCTAssertNil(controller.window)
            XCTAssertNil(child.contentViewController)
            XCTAssertNil(child.delegate)
            XCTAssertTrue(state.isWindowClosed)
            XCTAssertNil(state.window)
            XCTAssertFalse(child.isVisible)
        }
        await fixture.drainReadyCallbacks()
        XCTAssertEqual(joins, 1)
        XCTAssertNil(retiredController, "Closing must release the owner's retention through its hosted close delegate")
        XCTAssertTrue(fixture.application.readerWindowControllers.isEmpty)
        XCTAssertNotEqual(retiredWindow?.isVisible, true, "A stale ready callback cannot show a closed native reader")
    }

    func testUnselectedBatchTabsHaveDistinctNativeIdentitiesBeforeDisplay() async throws {
        guard #available(macOS 14, *) else { throw XCTSkip("Native hosting uses the macOS 14 toolbar bridge") }
        let fixture = try Fixture()
        defer { fixture.close() }
        var children = [NSWindow]()
        for _ in 0..<3 {
            let payload = fixture.tabRequest()
            fixture.application.openReaderWindow(payload)
            let controller = try XCTUnwrap(fixture.application.readerWindowControllers[payload.id])
            children.append(try XCTUnwrap(controller.window))
        }
        XCTAssertEqual(fixture.parent.tabGroup?.windows.count, 4)
        XCTAssertTrue(children.allSatisfy { $0.windowNumber > 0 })
        XCTAssertEqual(Set(children.map(\.windowNumber)).count, children.count,
                       "A batch must not expose repeated -1 identifiers for tabs that have not been selected")
        for child in children { child.close() }
        await fixture.drainReadyCallbacks()
        XCTAssertTrue(fixture.application.readerWindowControllers.isEmpty)
        XCTAssertTrue(children.allSatisfy { !$0.isVisible })
    }

    func testSelectedHostedReaderRegistersNormalToolbarItems() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var payload = fixture.tabRequest()
        guard #available(macOS 14, *) else {
            fixture.application.openReaderWindow(payload)
            let request = try XCTUnwrap(fixture.sceneRequests.first)
            XCTAssertEqual(request.id, payload.id)
            XCTAssertTrue(request.tabOpening === payload.tabOpening)
            return
        }
        // Keep automatic ordering pending while the selected test tab loads.
        payload.tabOpening = ReaderWindows.TabOpening(payloads: [payload, WindowPayload()], parent: fixture.parent)
        fixture.application.openReaderWindow(payload)
        let child = try XCTUnwrap(fixture.application.readerWindowControllers[payload.id]?.window)
        child.alphaValue = 0; child.ignoresMouseEvents = true
        defer {
            child.tabGroup?.removeWindow(child)
            child.orderOut(nil)
            child.close()
            fixture.parent.orderOut(nil)
        }
        child.contentView?.layoutSubtreeIfNeeded()
        let state = try XCTUnwrap((child.delegate as? ReaderCloseGuard)?.state)
        let deadline = Date().addingTimeInterval(3)
        while !state.hasDocument && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(state.supportsSearch)

        child.tabGroup?.selectedWindow = child
        child.setContentSize(NSSize(width: 1100, height: 500))
        child.orderFront(nil)
        child.displayIfNeeded()
        await fixture.drainReadyCallbacks()
        XCTAssertTrue(child.tabGroup?.selectedWindow === child)
        let toolbar = try XCTUnwrap(child.toolbar)
        XCTAssertTrue(toolbar.isVisible)
        let registered = Set(toolbar.items.map(\.itemIdentifier.rawValue))
        XCTAssertTrue(Set(["open", "navigation", "zoom", "find"]).isSubset(of: registered), "Installed items: \(registered)")
        let visible = try XCTUnwrap(toolbar.visibleItems)
        let find = try XCTUnwrap(visible.first { $0.itemIdentifier.rawValue == "find" })
        // Use the same toolbar item's AppKit overflow action without taking
        // mouse or keyboard focus from the current application.
        let overflowFind = try XCTUnwrap(find.menuFormRepresentation)
        let action = try XCTUnwrap(overflowFind.action)
        XCTAssertFalse(state.showFind)
        XCTAssertTrue(NSApp.sendAction(action, to: overflowFind.target, from: overflowFind))
        await fixture.drainReadyCallbacks()
        XCTAssertTrue(state.showFind)
        state.toggleFindPanel()
        await fixture.drainReadyCallbacks()
    }

    func testOrdinaryAndRestoredRequestsKeepTheirOriginalSceneOpenerPayloads() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var independent = WindowPayload(path: fixture.input.path, position: ReadingPosition(page: 142, zoom: 1.75), recordsHistory: false)
        independent.tabIdentifier = "Independent-" + UUID().uuidString
        independent.tabColor = 0x4288AA
        fixture.application.openReaderWindow(independent)

        var restored = fixture.tabRequest()
        restored.restoring = true
        restored.position = ReadingPosition(page: 36, zoom: 1.25)
        restored.selected = true; restored.active = true
        fixture.application.openReaderWindow(restored)

        XCTAssertTrue(fixture.application.readerWindowControllers.isEmpty)
        XCTAssertEqual(fixture.sceneRequests.count, 2)
        for (actual, expected) in zip(fixture.sceneRequests, [independent, restored]) {
            XCTAssertEqual(actual.id, expected.id)
            XCTAssertEqual(actual.path, expected.path)
            XCTAssertEqual(actual.position, expected.position)
            XCTAssertEqual(actual.recordsHistory, expected.recordsHistory)
            XCTAssertEqual(actual.tabWith, expected.tabWith)
            XCTAssertEqual(actual.tabIdentifier, expected.tabIdentifier)
            XCTAssertEqual(actual.tabColor, expected.tabColor)
            XCTAssertEqual(actual.restoring, expected.restoring)
            XCTAssertEqual(actual.selected, expected.selected)
            XCTAssertEqual(actual.active, expected.active)
            XCTAssertTrue(actual.tabOpening === expected.tabOpening)
        }
    }

    func testRequestWhoseParentClosedBeforeRoutingDoesNotCreateAnOwnedTab() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let payload = fixture.tabRequest()
        fixture.closeParent()
        var joins = 0
        fixture.parent.willAddTab = { _ in joins += 1 }

        fixture.application.openReaderWindow(payload)

        XCTAssertEqual(joins, 0, "A request must not join a closed parent's retained native window")
        XCTAssertTrue(fixture.application.readerWindowControllers.isEmpty)
        let forwarded = try XCTUnwrap(fixture.sceneRequests.first)
        XCTAssertEqual(fixture.sceneRequests.count, 1)
        XCTAssertEqual(forwarded.id, payload.id)
        XCTAssertEqual(forwarded.path, payload.path)
        XCTAssertTrue(forwarded.tabOpening === payload.tabOpening)
    }

    @MainActor private final class ParentWindow: NSWindow {
        var willAddTab: ((NSWindow) -> Void)?
        override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) {
            willAddTab?(window)
            super.addTabbedWindow(window, ordered: ordered)
        }
        override func makeKeyAndOrderFront(_ sender: Any?) {
            XCTFail("This factory fixture must not activate its hidden parent")
        }
    }

    @MainActor private final class Fixture {
        let application = ReaderApplicationDelegate()
        let parent: ParentWindow
        let parentState = ReaderState(recordsHistory: false)
        let directory: TemporaryDirectory
        let input: URL
        private let host = WindowTabs.HostView()
        private let arguments: [String: Any]
        private let capture: (() -> Void)?
        private(set) var sceneRequests = [WindowPayload]()

        init() throws {
            _ = NSApplication.shared
            guard !ReaderWindows.isRestoringNativeWindows, !ReaderWindows.isRestoringWindows else {
                throw XCTSkip("Another native restoration is pending")
            }
            directory = try TemporaryDirectory()
            input = directory.url.appendingPathComponent("native-owned-reader.txt")
            try "Native window owner lifecycle fixture".write(to: input, atomically: true, encoding: .utf8)
            arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            capture = ScreenshotHotkey.capture
            parent = ParentWindow(contentRect: NSRect(x: 2400, y: 100, width: 700, height: 500),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.alphaValue = 0; parent.ignoresMouseEvents = true
            var overrides = arguments
            overrides["disableTabs"] = false
            overrides["disableHistory"] = true
            overrides["disableReadingState"] = true
            overrides["showContentsOnOpen"] = false
            overrides["toolbarDisplayMode"] = ReaderToolbarDisplayMode.shown.rawValue
            overrides["immersiveControls"] = false
            overrides["findFloating"] = false
            UserDefaults.standard.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
            parentState.document = ReadingDocument(url: input, content: .text("Parent reader"))
            host.state = parentState
            host.groupIdentifier = "Native-Owned-" + UUID().uuidString
            host.openingPath = input.path
            parent.contentView?.addSubview(host)
            application.installWindowOpener { [weak self] in self?.sceneRequests.append($0) }
        }

        func tabRequest() -> WindowPayload {
            var payload = WindowPayload(path: input.path, position: ReadingPosition(page: 142, zoom: 1.5),
                                        tabWith: parent.windowNumber, recordsHistory: false)
            payload.tabIdentifier = parent.tabbingIdentifier
            payload.tabOpening = ReaderWindows.TabOpening(payloads: [payload], parent: parent)
            return payload
        }

        func closeParent() {
            host.removeFromSuperview()
            parentState.windowClosed()
            parent.close()
        }

        func drainReadyCallbacks() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        func close() {
            parent.willAddTab = nil
            for controller in Array(application.readerWindowControllers.values) { controller.window?.close() }
            closeParent()
            application.removeTabResponder()
            ScreenshotHotkey.capture = capture
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            withExtendedLifetime(directory) {}
        }
    }
}
#endif
