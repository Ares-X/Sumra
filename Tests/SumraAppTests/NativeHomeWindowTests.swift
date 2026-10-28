#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class NativeHomeWindowTests: XCTestCase {
    func testClosingHomeLeavesBothBooksInTheirNativeGroup() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.attach(path: "/first.epub", loaded: true)
        let second = fixture.attach(path: "/second.epub", loaded: true, to: first)
        let home = fixture.attach(path: nil, to: second)
        let homeState = try XCTUnwrap(fixture.states.last)
        let group = try XCTUnwrap(first.tabGroup)

        home.performClose(nil)
        let deadline = Date().addingTimeInterval(5)
        while !homeState.isWindowClosed, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(homeState.isWindowClosed)
        XCTAssertEqual(group.windows, [first, second])
        XCTAssertTrue(fixture.states.prefix(2).allSatisfy { !$0.isWindowClosed && $0.document != nil })
    }

    func testHomeRemainsIndependentOfExistingAndSubsequentBookTabs() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.attach(path: "/first.epub", loaded: true)
        let second = fixture.attach(path: "/second.epub", loaded: true, to: first)
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(group.windows, [first, second])

        let home = fixture.attach(path: nil, to: second)
        XCTAssertEqual(group.windows, [first, second])
        XCTAssertEqual(home.tabbingMode, .disallowed)
        XCTAssertEqual(home.tabbedWindows ?? [home], [home])

        let third = fixture.attach(path: "/third.epub", loaded: true, to: second)
        XCTAssertEqual(group.windows, [first, second, third], "Home must never enter the native book group")
    }

    func testPendingFileRequestIsNotHomeBeforeItsDocumentLoads() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.attach(path: "/first.epub", loaded: true)
        let pending = fixture.attach(path: "/pending.epub", to: first)
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertNil(fixture.states.last?.document, "Exercise the pending request before document publication")
        XCTAssertEqual(group.windows, [first, pending], "A pending file request is a book tab")

        let home = fixture.attach(path: nil, to: pending)
        XCTAssertEqual(group.windows, [first, pending])
        XCTAssertEqual(pending.tabbingMode, .preferred)
        XCTAssertEqual(home.tabbingMode, .disallowed)
    }

    func testIdentifierGroupingExcludesHomeButIncludesLoadedAndDormantReaders() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.attach(path: "/first.epub", loaded: true)
        // With no explicit parent, the host joins by its native group identifier.
        let home = fixture.attach(path: nil)
        XCTAssertEqual(home.tabbingMode, .disallowed)
        XCTAssertEqual(first.tabbedWindows ?? [first], [first])

        let loaded = fixture.attach(path: nil, loaded: true, to: first)
        let dormant = fixture.attach(path: nil, restoring: true, to: loaded)
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(group.windows, [first, loaded, dormant],
                       "A loaded or dormant reader must not be mistaken for a blank Home")
        XCTAssertNil(fixture.states.last?.document)
        XCTAssertEqual(fixture.states.last?.restoredPayload?.path, "/restored.epub")
    }

    func testLoadingAndReturningHomeUpdatesTheNativeTabPolicy() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let home = fixture.attach(path: nil)
        let state = try XCTUnwrap(fixture.states.last)
        let host = try XCTUnwrap(fixture.hosts.last)
        XCTAssertEqual(home.tabbingMode, .disallowed)
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/loaded.epub"), content: .text("book"))
        host.updateDocumentProperties()
        XCTAssertEqual(home.tabbingMode, .preferred)
        let other = fixture.attach(path: "/other.epub", loaded: true, to: home)
        XCTAssertEqual(home.tabbedWindows, [home, other])

        state.document = nil
        host.updateDocumentProperties()
        XCTAssertEqual(home.tabbingMode, .disallowed)
        XCTAssertEqual(home.tabbedWindows ?? [home], [home])
        XCTAssertEqual(other.tabbedWindows ?? [other], [other])
        XCTAssertFalse(fixture.states[1].isWindowClosed)
        XCTAssertNotNil(fixture.states[1].document)
    }

    func testHomeCommandReusesIndependentHomeAndPreservesEveryBook() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.attach(path: "/first.epub", loaded: true)
        let second = fixture.attach(path: "/second.epub", loaded: true, to: first)
        let state = fixture.states[0]
        let original = state.document?.id
        var created = [WindowPayload]()
        state.createWindow = { created.append($0) }
        ReaderMenuCommand.home.run(state)
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created[0].path)
        XCTAssertNil(created[0].tabWith)
        let home = fixture.attach(path: nil)
        ReaderMenuCommand.home.run(state)
        XCTAssertEqual(created.count, 1, "Reuse the existing independent Home")
        XCTAssertEqual(state.document?.id, original)
        XCTAssertEqual(first.tabbedWindows, [first, second])
        XCTAssertTrue(fixture.states.prefix(2).allSatisfy { !$0.isWindowClosed && $0.document != nil })
        XCTAssertEqual(home.tabbingMode, .disallowed)
    }

    func testBusyHomeBecomesADocumentGroupBeforeItsFirstBookPublishes() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = fixture.attach(path: nil)
        let state = try XCTUnwrap(fixture.states.last)
        let host = try XCTUnwrap(fixture.hosts.last)
        XCTAssertEqual(first.tabbingMode, .disallowed)
        // Home's first selected file is parsing; its scene path and document
        // have not been published when the next selection attaches its window.
        state.busy = true
        host.updateDocumentProperties()
        XCTAssertNil(host.openingPath)
        XCTAssertNil(state.document)
        XCTAssertEqual(first.tabbingMode, .preferred)
        let second = fixture.attach(path: "/second.epub", to: first)
        XCTAssertEqual(first.tabGroup?.windows, [first, second])
        XCTAssertFalse((first.delegate as? ReaderCloseGuard)?.isHome ?? true)
    }

    @MainActor private final class Fixture {
        private let identifier = "Sumra-Home-Ordering-" + UUID().uuidString
        private let defaults = UserDefaults.standard
        private let previousArguments: [String: Any]
        private var windows = [NSWindow]()
        private(set) var hosts = [WindowTabs.HostView]()
        private(set) var states = [ReaderState]()

        init() {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(previousArguments.merging(["disableTabs": false]) { _, fixture in fixture },
                                      forName: UserDefaults.argumentDomain)
        }

        func attach(path: String?, loaded: Bool = false, restoring: Bool = false, to parent: NSWindow? = nil) -> NSWindow {
            let state = ReaderState(recordsHistory: false,
                restoring: restoring ? WindowPayload(path: "/restored.epub") : nil)
            if loaded {
                state.document = ReadingDocument(url: URL(fileURLWithPath: path ?? "/loaded.epub"), content: .text("book"))
            }
            let window = NSWindow(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 400),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            let host = WindowTabs.HostView()
            host.state = state; host.tabWith = parent?.windowNumber
            host.groupIdentifier = identifier; host.openingPath = path
            states.append(state); windows.append(window); hosts.append(host)
            window.contentView?.addSubview(host)
            return window
        }

        func close() {
            for host in hosts { host.removeFromSuperview() }
            for window in windows { window.orderOut(nil); window.close() }
            for state in states { state.windowClosed() }
            defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
