#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeTabHostTests: XCTestCase {
    func testNativeMembershipPublishesCountAndKeepsMultipleTabCaptionsVisible() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.makeReader(title: "first"), second = fixture.makeReader(title: "second")
        var firstCounts = [Int](), secondCounts = [Int]()
        let firstSubscription = first.state.$tabCount.dropFirst().sink { firstCounts.append($0) }
        let secondSubscription = second.state.$tabCount.dropFirst().sink { secondCounts.append($0) }
        defer { firstSubscription.cancel(); secondSubscription.cancel() }
        try await fixture.mount(first)
        XCTAssertEqual(first.state.tabCount, 1)
        XCTAssertFalse(first.state.normalTabBarShown)
        let toggle = NSMenuItem(title: "Show Tab Bar", action: #selector(ReaderCloseGuard.toggleTabBar(_:)), keyEquivalent: "")
        let firstGuard = try XCTUnwrap(first.window.delegate as? ReaderCloseGuard)
        XCTAssertTrue(firstGuard.validateUserInterfaceItem(toggle))
        firstGuard.toggleTabBar(nil)
        XCTAssertTrue(first.state.tabBarShown)
        XCTAssertTrue(first.state.normalTabBarShown)
        firstGuard.toggleTabBar(nil)
        XCTAssertFalse(first.state.normalTabBarShown)

        try await fixture.mount(second, beside: first.window)
        fixture.publishNativeUpdates()
        let group = try XCTUnwrap(first.window.tabGroup)
        XCTAssertEqual(group.windows, [first.window, second.window])
        XCTAssertEqual(first.state.tabCount, 2); XCTAssertEqual(second.state.tabCount, 2)
        XCTAssertTrue(first.state.normalTabBarShown); XCTAssertTrue(second.state.normalTabBarShown)
        XCTAssertFalse(firstGuard.validateUserInterfaceItem(toggle), "A group with several documents cannot hide its captions")
        XCTAssertFalse(try XCTUnwrap(second.window.delegate as? ReaderCloseGuard).validateUserInterfaceItem(toggle))
        fixture.publishNativeUpdates()
        XCTAssertEqual(firstCounts, [2], "Repeated native updates must not republish an unchanged count")
        XCTAssertEqual(secondCounts, [2])

        group.removeWindow(second.window)
        fixture.publishNativeUpdates()
        XCTAssertEqual(first.state.tabCount, 1); XCTAssertEqual(second.state.tabCount, 1)
        XCTAssertFalse(first.state.normalTabBarShown); XCTAssertFalse(second.state.normalTabBarShown)
        XCTAssertEqual(firstCounts, [2, 1]); XCTAssertEqual(secondCounts, [2, 1])
        XCTAssertTrue(firstGuard.validateUserInterfaceItem(toggle))
        XCTAssertTrue(first.state.window === first.window); XCTAssertTrue(second.state.window === second.window)
    }

    func testCountObserverWaitsForNativeAndManualPlacementAndResetsOnWindowMove() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeReader(title: "placed-parent")
        try await fixture.mount(parent)
        let child = fixture.makeReader(title: "deferred-child")
        let host = WindowTabs.HostView(frame: .zero)
        host.state = child.state
        host.openingPath = child.state.document?.url.path
        host.tabWith = parent.window.windowNumber
        host.groupIdentifier = parent.window.tabbingIdentifier
        var ready = false
        host.onWindowReady = { ready = true }
        XCTAssertFalse(ReaderWindows.isRestoringNativeWindows)
        ReaderWindows.isRestoringNativeWindows = true
        defer { ReaderWindows.finishNativeRestoration(); host.removeFromSuperview() }
        child.window.contentView?.addSubview(host)
        let nativeReads = child.window.tabGroupReadCount
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: child.window)
        XCTAssertEqual(child.window.tabGroupReadCount, nativeReads,
            "The new count observer must not request a native group before system restoration completes")
        XCTAssertFalse(ready)
        XCTAssertEqual(child.state.tabCount, 1)
        var sawManualPlacement = false
        child.window.identifierChanged = { [weak window = child.window] in
            guard let window else { return }
            sawManualPlacement = true
            let before = window.tabGroupReadCount
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            XCTAssertEqual(window.tabGroupReadCount, before,
                "The identifier setter runs after the placed reentrancy latch but before manual grouping returns")
        }
        ReaderWindows.finishNativeRestoration()
        child.window.identifierChanged = nil
        XCTAssertTrue(sawManualPlacement)
        let deadline = Date().addingTimeInterval(3)
        while !ready, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ready)
        XCTAssertEqual(child.state.tabCount, 2, "Ready publishes the completed native membership")
        XCTAssertEqual(parent.state.tabCount, 2)

        let next = fixture.makeReader(title: "new-native-owner")
        ready = false
        ReaderWindows.isRestoringNativeWindows = true
        next.window.contentView?.addSubview(host)
        let movedReads = next.window.tabGroupReadCount
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: next.window)
        XCTAssertEqual(next.window.tabGroupReadCount, movedReads,
            "Changing the host's native window resets count observation until placement completes again")
        XCTAssertFalse(ready)
        ReaderWindows.finishNativeRestoration()
        let movedDeadline = Date().addingTimeInterval(3)
        while !ready, Date() < movedDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ready)
        XCTAssertEqual(child.state.tabCount, 1)
    }

    func testNormalTabVisibilityAndMenuRespectFloatingControlsAndPresentation() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let reader = fixture.makeReader(title: "visibility")
        try await fixture.mount(reader)
        let guardDelegate = try XCTUnwrap(reader.window.delegate as? ReaderCloseGuard)
        let toggle = NSMenuItem(title: "Show Tab Bar", action: #selector(ReaderCloseGuard.toggleTabBar(_:)), keyEquivalent: "")
        guardDelegate.toggleTabBar(nil)
        XCTAssertTrue(reader.state.normalTabBarShown)
        reader.state.immersiveControls = true
        XCTAssertFalse(reader.state.normalTabBarShown)
        XCTAssertFalse(guardDelegate.validateUserInterfaceItem(toggle))
        reader.state.immersiveControls = false
        XCTAssertTrue(reader.state.normalTabBarShown, "The explicit single-tab choice survives a chrome switch")
        reader.state.presentation = true
        XCTAssertFalse(reader.state.normalTabBarShown)
        reader.state.presentation = false
        XCTAssertTrue(reader.state.normalTabBarShown)
    }

    func testClosingMountedTabDoesNotReconfigureItAsHome() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.makeReader(title: "first"), second = fixture.makeReader(title: "second")
        try await fixture.mount(first)
        try await fixture.mount(second, beside: first.window)
        let group = try XCTUnwrap(first.window.tabGroup)
        XCTAssertEqual(group.windows, [first.window, second.window])
        second.window.tabbingChanges.removeAll()

        second.window.performClose(nil)
        XCTAssertTrue(second.state.isWindowClosed, "Exercise the mounted HostView's native close notification")
        let closedReads = second.window.tabGroupReadCount
        var closedCounts: [Int] = []
        let closedSubscription = second.state.$tabCount.dropFirst().sink { closedCounts.append($0) }
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: second.window)
        XCTAssertEqual(second.window.tabGroupReadCount, closedReads, "A retained closed host must not request a native group during stack teardown")
        XCTAssertTrue(closedCounts.isEmpty, "Native close updates must not republish a closed reader's count")
        closedSubscription.cancel()
        for _ in 0..<5 {
            second.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(group.windows, [first.window])
        fixture.publishNativeUpdates()
        XCTAssertEqual(first.state.tabCount, 1)
        XCTAssertFalse(first.state.normalTabBarShown)
        XCTAssertFalse(second.window.tabbingChanges.contains { $0.mode == .disallowed },
            "A closed document scene must not become Home and alter AppKit's native tab teardown: \(second.window.tabbingChanges)")
        XCTAssertTrue(first.state.document != nil)
        XCTAssertTrue(first.state.window === first.window)
    }

    func testMountedTabMovesOnlyItselfFromAnotherNativeGroupToTheRequestedParent() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeReader(title: "requested")
        let unrelated = fixture.makeReader(title: "unrelated")
        let sibling = fixture.makeReader(title: "unrelated-sibling")
        let child = fixture.makeReader(title: "new-tab")
        try await fixture.mount(parent)
        try await fixture.mount(unrelated)
        try await fixture.mount(sibling, beside: unrelated.window)
        // SwiftUI/AppKit may have attached a scene before its native host is
        // installed. Exercise the existing group with real AppKit membership.
        unrelated.window.addTabbedWindow(child.window, ordered: .above)
        let otherGroup = try XCTUnwrap(unrelated.window.tabGroup)
        let otherSelection = otherGroup.selectedWindow
        let otherFrame = unrelated.window.frame
        try await fixture.mount(child, beside: parent.window)

        XCTAssertEqual(parent.window.tabGroup?.windows, [parent.window, child.window])
        XCTAssertEqual(otherGroup.windows, [unrelated.window, sibling.window])
        if otherSelection !== child.window { XCTAssertTrue(otherGroup.selectedWindow === otherSelection) }
        XCTAssertEqual(unrelated.window.frame, otherFrame)
        XCTAssertEqual(child.window.tabbingIdentifier, parent.window.tabbingIdentifier)
        XCTAssertTrue(child.state.window === child.window)
        XCTAssertTrue(child.window.styleMask.contains([.titled, .closable, .resizable]))
        XCTAssertNotNil(child.window.standardWindowButton(.closeButton))
        XCTAssertFalse(child.window.standardWindowButton(.closeButton)?.isHidden ?? true)
    }

    @MainActor private final class Window: NSWindow {
        struct Change: CustomStringConvertible {
            let mode: NSWindow.TabbingMode
            let groupCount: Int
            var description: String { "mode=\(mode.rawValue) group-count=\(groupCount)" }
        }
        var tabbingChanges = [Change]()
        var tabGroupReadCount = 0
        var identifierChanged: (() -> Void)?
        override var tabGroup: NSWindowTabGroup? {
            tabGroupReadCount += 1
            return super.tabGroup
        }
        override var tabbingIdentifier: NSWindow.TabbingIdentifier {
            didSet { identifierChanged?() }
        }
        override var tabbingMode: NSWindow.TabbingMode {
            didSet { tabbingChanges.append(Change(mode: tabbingMode, groupCount: tabGroup?.windows.count ?? 0)) }
        }
    }

    private struct HostContent: View {
        @ObservedObject var state: ReaderState
        let parent: Int?
        let identifier: String
        let onWindowReady: () -> Void
        var body: some View {
            ZStack {
                if !state.isWindowClosed { Color.clear }
            }
            .background(WindowTabs(state: state, tabWith: parent, identifier: identifier,
                openingPath: state.document?.url.path, onWindowReady: onWindowReady))
        }
    }

    @MainActor private final class Fixture {
        struct Reader {
            let state: ReaderState
            let window: Window
        }
        private var readers = [Reader]()
        private let previousArguments: [String: Any]

        init() {
            _ = NSApplication.shared
            previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            var arguments = previousArguments
            arguments["disableTabs"] = false
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }

        func makeReader(title: String) -> Reader {
            let state = ReaderState(recordsHistory: false)
            state.immersiveControls = false; state.toolbarDisplayMode = .shown
            state.document = ReadingDocument(url: URL(fileURLWithPath: "/native-host-\(UUID().uuidString)-\(title).txt"),
                                             content: .text("Book " + title))
            let window = Window(contentRect: CGRect(x: 2400, y: 100, width: 640, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.title = title
            window.tabbingIdentifier = "Native-Host-" + UUID().uuidString
            let reader = Reader(state: state, window: window)
            readers.append(reader)
            return reader
        }

        func mount(_ reader: Reader, beside parent: NSWindow? = nil) async throws {
            let identifier = parent?.tabbingIdentifier ?? reader.window.tabbingIdentifier
            var ready = false
            reader.window.contentView = NSHostingView(rootView: HostContent(state: reader.state,
                parent: parent?.windowNumber, identifier: identifier, onWindowReady: { ready = true }))
            let deadline = Date().addingTimeInterval(3)
            while !ready, Date() < deadline {
                reader.window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(reader.state.window === reader.window, "The real NSViewRepresentable host must install its reader delegate")
            XCTAssertTrue(ready, "Wait for native placement and its asynchronous count publication")
        }

        func publishNativeUpdates() {
            // Exercise the real HostView notification boundary after AppKit
            // membership changes, without ordering these offscreen fixtures in.
            for reader in readers where !reader.state.isWindowClosed {
                NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: reader.window)
            }
        }

        func close() {
            for reader in readers {
                reader.window.contentView = nil
                reader.window.delegate = nil
                reader.window.close()
                if !reader.state.isWindowClosed { reader.state.windowClosed() }
            }
            UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
