#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

/// Reproduces the observed native-policy ordering with hidden AppKit windows.
/// A simulated fullscreen mask does not enter or validate a fullscreen Space.
@MainActor final class NativeLoadingHomeTabPlacementTests: XCTestCase {
    func testFirstTabUpdatesLoadingHomePolicyBeforeNativeAttachment() throws {
        let fixture = Fixture(disableTabs: false)
        defer { fixture.close() }
        XCTAssertEqual(fixture.parent.tabbingMode, .disallowed)

        fixture.parent.fullscreen = true
        fixture.parentState.busy = true
        // Do not update the parent host: the observed first child mounts before
        // SwiftUI delivers that update for the reused, now-loading Home.
        XCTAssertNil(fixture.parentState.document)
        XCTAssertNil(fixture.parentHost.openingPath)
        XCTAssertEqual(fixture.parent.tabbingMode, .disallowed)
        fixture.mountChild()

        XCTAssertEqual(fixture.parent.modesAtAttachment, [.preferred],
            "The first native add must see the loading parent's current policy")
        XCTAssertEqual(fixture.parent.tabbingMode, .preferred)
        XCTAssertEqual(fixture.parent.tabGroup?.windows, [fixture.parent, fixture.child])
        XCTAssertEqual(fixture.child.tabbingIdentifier, fixture.parent.tabbingIdentifier)
        XCTAssertTrue(fixture.parent.styleMask.contains(.fullScreen))
        XCTAssertTrue(fixture.parentState.busy)
        XCTAssertNil(fixture.parentState.document)
        XCTAssertFalse((fixture.parent.delegate as? ReaderCloseGuard)?.isHome ?? true)
    }

    func testDisabledTabsDoesNotPromoteOrAttachLoadingHome() throws {
        let fixture = Fixture(disableTabs: true)
        defer { fixture.close() }
        fixture.parent.fullscreen = true
        fixture.parentState.busy = true
        fixture.mountChild()

        XCTAssertEqual(fixture.parent.tabbingMode, .disallowed)
        XCTAssertEqual(fixture.child.tabbingMode, .disallowed)
        XCTAssertTrue(fixture.parent.modesAtAttachment.isEmpty)
        XCTAssertEqual(fixture.parent.tabGroup?.windows ?? [fixture.parent], [fixture.parent])
        XCTAssertEqual(fixture.child.tabGroup?.windows ?? [fixture.child], [fixture.child])
    }

    private final class ParentWindow: NSWindow {
        var fullscreen = false
        var modesAtAttachment: [NSWindow.TabbingMode] = []
        override var styleMask: NSWindow.StyleMask {
            get { fullscreen ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
            set { super.styleMask = newValue.subtracting(.fullScreen) }
        }
        override func addTabbedWindow(_ window: NSWindow, ordered: NSWindow.OrderingMode) {
            modesAtAttachment.append(tabbingMode)
            super.addTabbedWindow(window, ordered: ordered)
        }
    }

    @MainActor private final class Fixture {
        let parentState = ReaderState(recordsHistory: false)
        let childState = ReaderState(recordsHistory: false)
        let parent: ParentWindow
        let child: NSWindow
        let parentHost = WindowTabs.HostView()
        let childHost = WindowTabs.HostView()
        private let previousArguments: [String: Any]

        init(disableTabs: Bool) {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(previousArguments.merging(["disableTabs": disableTabs]) { _, fixture in fixture },
                                      forName: UserDefaults.argumentDomain)
            let rect = NSRect(x: 2400, y: 100, width: 700, height: 500)
            let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
            parent = ParentWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            child = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            for window in [parent, child] {
                window.isReleasedWhenClosed = false
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
            parentHost.state = parentState
            parentHost.groupIdentifier = "Loading-Home-" + UUID().uuidString
            parent.contentView?.addSubview(parentHost)
        }

        func mountChild() {
            childHost.state = childState
            childHost.openingPath = "/pending-second-document.txt"
            childHost.tabWith = parent.windowNumber
            child.contentView?.addSubview(childHost)
        }

        func close() {
            childHost.removeFromSuperview()
            parentHost.removeFromSuperview()
            parent.fullscreen = false
            child.close()
            parent.close()
            parentState.windowClosed()
            childState.windowClosed()
            UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
