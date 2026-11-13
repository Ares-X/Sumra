#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

// These tests exercise real native groups and the mounted scene-ready callback.
// They model late selection changes; they do not simulate or prove macOS Spaces.
@MainActor
final class NativeFullscreenTabLifecycleTests: XCTestCase {
    func testBatchWaitsForEverySceneAndSelectsTheLastRequestedTabOnceDespiteReverseReadiness() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeParent()
        var payloads = [WindowPayload]()
        ReaderWindows.open([URL(fileURLWithPath: "/first-request.txt"), URL(fileURLWithPath: "/last-request.txt")],
                           in: parent.state, behavior: .newTab) { payloads.append($0) }
        XCTAssertEqual(payloads.count, 2)
        let requested = fixture.mount(payloads[1])
        let group = try XCTUnwrap(parent.window.tabGroup)
        group.selectedWindow = parent.window
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertEqual(fixture.ready, [payloads[1].id])
        XCTAssertTrue(fixture.windows.allSatisfy { $0.focusSelections.isEmpty },
                      "A partially mounted batch must not issue its own focus changes")

        _ = fixture.mount(payloads[0])
        group.selectedWindow = parent.window
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertTrue(group.selectedWindow === requested.window,
                      "Scene installation order must not override the last requested document")
        XCTAssertEqual(requested.window.focusSelections, [requested.window.windowNumber],
                       "Select the actual native tab before ordering its window")
        XCTAssertEqual(fixture.windows.flatMap(\.focusSelections).count, 1,
                       "One batch owns one final focus operation")

        ReaderWindows.windowReady(requested.window, payload: payloads[1])
        XCTAssertEqual(requested.window.focusSelections.count, 1, "A repeated ready callback cannot refocus a completed batch")
    }

    func testDuplicateSelectsItsPlacedTabAtSceneReadyAfterASelectionChange() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeParent()
        var payloads = [WindowPayload]()
        parent.state.createWindow = { payloads.append($0) }
        parent.state.duplicate(inTab: true)
        let payload = try XCTUnwrap(payloads.first)
        let duplicate = fixture.mount(payload)
        let group = try XCTUnwrap(parent.window.tabGroup)
        XCTAssertEqual(group.windows, [parent.window, duplicate.window])
        // Model selection changing after addTabbedWindow and before the
        // existing next-runloop scene-ready callback, without entering Spaces.
        group.selectedWindow = parent.window
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertTrue(group.selectedWindow === duplicate.window)
        XCTAssertEqual(duplicate.window.focusSelections, [duplicate.window.windowNumber])
        XCTAssertTrue(duplicate.state.window === duplicate.window)
    }

    func testColdBatchWithoutAParentSelectsItsRequestedTabAfterNativeGroupAssembly() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let coldState = ReaderState(recordsHistory: false)
        var payloads = [WindowPayload]()
        ReaderWindows.open([URL(fileURLWithPath: "/cold-first.txt"), URL(fileURLWithPath: "/cold-last.txt")],
                           in: coldState, behavior: .newTab) { payloads.append($0) }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertTrue(payloads.allSatisfy { $0.tabWith == nil })
        XCTAssertEqual(Set(payloads.compactMap(\.tabIdentifier)).count, 1)

        let selected = fixture.mount(payloads[1])
        await fixture.drainReadyCallbacks()
        let other = fixture.mount(payloads[0])
        let group = try XCTUnwrap(selected.window.tabGroup)
        group.selectedWindow = other.window
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertEqual(Set(group.windows.map(\.windowNumber)), Set(fixture.windows.map(\.windowNumber)))
        XCTAssertTrue(group.selectedWindow === selected.window)
        XCTAssertEqual(selected.window.focusSelections, [selected.window.windowNumber])
        XCTAssertEqual(fixture.windows.flatMap(\.focusSelections).count, 1)
    }

    func testReadyDoesNotSelectATabMovedToAnUnrelatedNativeGroup() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeParent()
        let unrelated = fixture.makeParent()
        var payloads = [WindowPayload]()
        ReaderWindows.open([URL(fileURLWithPath: "/moving-tab.txt")], in: parent.state,
                           behavior: .newTab) { payloads.append($0) }
        let child = fixture.mount(try XCTUnwrap(payloads.first))
        unrelated.window.addTabbedWindow(child.window, ordered: .above)
        let otherGroup = try XCTUnwrap(unrelated.window.tabGroup)
        otherGroup.selectedWindow = unrelated.window
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertTrue(otherGroup.selectedWindow === unrelated.window)
        XCTAssertTrue(fixture.windows.allSatisfy { $0.focusSelections.isEmpty },
                      "The opening request no longer owns a tab moved away from its parent")
        XCTAssertEqual(otherGroup.windows, [unrelated.window, child.window])
    }

    func testIndependentNewWindowKeepsItsOwnReadyLifecycle() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let parent = fixture.makeParent()
        var payloads = [WindowPayload]()
        ReaderWindows.open([URL(fileURLWithPath: "/independent.txt")], in: parent.state,
                           behavior: .newWindow) { payloads.append($0) }
        let independent = fixture.mount(try XCTUnwrap(payloads.first))
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertEqual(parent.window.tabbedWindows ?? [parent.window], [parent.window])
        XCTAssertEqual(independent.window.tabbedWindows ?? [independent.window], [independent.window])
        XCTAssertTrue(fixture.windows.allSatisfy { $0.focusSelections.isEmpty },
                      "Only explicit tab opening requests own post-placement selection")
    }

    func testSavedRestorationStillWaitsForEverySceneAndUsesItsSavedSelection() async throws {
        let fixture = Fixture()
        defer { fixture.close(); _ = ReaderWindows.prepareRestoration([]) }
        let parent = fixture.makeParent()
        var selected = WindowPayload(path: "/saved-selected.txt", tabWith: parent.window.windowNumber)
        selected.selected = true; selected.active = true
        let other = WindowPayload(path: "/saved-other.txt", tabWith: parent.window.windowNumber)
        let payloads = ReaderWindows.prepareRestoration([selected, other])
        let restored = fixture.mount(payloads[0])
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()
        XCTAssertTrue(ReaderWindows.isRestoringWindows)
        XCTAssertTrue(fixture.windows.allSatisfy { $0.focusSelections.isEmpty })

        _ = fixture.mount(payloads[1])
        let group = try XCTUnwrap(parent.window.tabGroup)
        group.selectedWindow = parent.window
        fixture.clearFocusRequests()
        await fixture.drainReadyCallbacks()

        XCTAssertFalse(ReaderWindows.isRestoringWindows)
        XCTAssertTrue(group.selectedWindow === restored.window,
                      "Ordinary opening's last-request policy must not replace the saved group's selection")
        XCTAssertEqual(restored.window.focusSelections, [restored.window.windowNumber])
        XCTAssertEqual(fixture.windows.flatMap(\.focusSelections).count, 1)
    }

    @MainActor private final class Window: NSWindow {
        var focusSelections = [Int]()
        override func makeKeyAndOrderFront(_ sender: Any?) {
            focusSelections.append(tabGroup?.selectedWindow?.windowNumber ?? -1)
            // Keep this lifecycle test's invisible windows off the desktop.
            // Real WindowServer activation and Spaces belong to GUI acceptance.
        }
    }

    @MainActor private final class Fixture {
        struct Reader {
            let state: ReaderState
            let window: Window
            let host: WindowTabs.HostView
        }
        private var readers = [Reader]()
        private let previousArguments: [String: Any]
        private(set) var ready = [UUID]()
        var windows: [Window] { readers.map(\.window) }

        init() {
            _ = NSApplication.shared
            previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            var arguments = previousArguments
            arguments["disableTabs"] = false
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }

        func makeParent() -> Reader {
            var payload = WindowPayload(path: "/parent-\(UUID().uuidString).txt")
            payload.tabIdentifier = "Native-Ready-" + UUID().uuidString
            return mount(payload, reportsReady: false)
        }

        func mount(_ payload: WindowPayload, reportsReady: Bool = true) -> Reader {
            let state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: URL(fileURLWithPath: payload.path!), content: .text("Book"))
            let window = Window(contentRect: CGRect(x: 2400, y: 100, width: 640, height: 480),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            let host = WindowTabs.HostView()
            host.state = state; host.tabWith = payload.tabWith
            host.groupIdentifier = payload.tabIdentifier; host.openingPath = payload.path
            host.restorationID = payload.restoring ? payload.id : nil
            host.onWindowReady = { [weak self, weak window] in
                guard reportsReady, let window else { return }
                ReaderWindows.windowReady(window, payload: payload)
                self?.ready.append(payload.id)
            }
            let reader = Reader(state: state, window: window, host: host)
            readers.append(reader)
            window.contentView?.addSubview(host)
            return reader
        }

        func clearFocusRequests() {
            for window in windows { window.focusSelections.removeAll() }
        }

        func drainReadyCallbacks() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        func close() {
            for reader in readers { reader.host.removeFromSuperview() }
            for reader in readers {
                reader.state.windowClosed()
                reader.window.close()
            }
            readers.removeAll()
            UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
    }
}
#endif
