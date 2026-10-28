#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class NativeTabGroupModelTests: XCTestCase {
    func testBulkCloseUsesTheNativeGroupWithoutAPresentationSnapshot() async throws {
        for (subset, remaining) in [("all", []), ("other", [1]), ("left", [1, 2]), ("right", [0, 1])] {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.states[1].closeTabs(subset)
            let deadline = Date().addingTimeInterval(5)
            while fixture.states.filter(\.isWindowClosed).count < 3 - remaining.count, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(fixture.states.indices.filter { !fixture.states[$0].isWindowClosed }, remaining, subset)
        }
    }

    func testSessionPreservesGroupOrderAndSelectionWithoutAPresentationSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        ReaderWindows.saveSession(fixture.states)
        let saved = ReaderWindows.saved("session")
        XCTAssertEqual(saved.map(\.path), fixture.states.map { $0.document?.url.path })
        XCTAssertEqual(Set(saved.compactMap(\.tabIdentifier)).count, 1,
                       "Books must restore together rather than as three independent windows")
        XCTAssertEqual(saved.filter { $0.selected == true }.map(\.path), [fixture.states[1].document?.url.path])
    }

    func testNamedGroupSavesEveryBookAndSelectionWithoutAPresentationSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let name = "hidden-group-" + UUID().uuidString
        let key = "tabGroup:" + name
        defer { UserDefaults.standard.removeObject(forKey: key) }
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                let field = NSApp.modalWindow?.initialFirstResponder as? NSTextField
                XCTAssertNotNil(field)
                field?.stringValue = name
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
        }
        fixture.states[1].saveTabGroup()
        let saved = ReaderWindows.saved(key)
        XCTAssertEqual(saved.map(\.path), fixture.states.map { $0.document?.url.path })
        XCTAssertEqual(saved.filter { $0.selected == true }.map(\.path), [fixture.states[1].document?.url.path])
    }

    func testSmartSwitchReachesOtherBooksWithoutAPresentationSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for index in [2, 0, 1] { ReaderWindows.activated(fixture.windows[index]) }
        fixture.states[1].selectTab(1, smart: true)
        XCTAssertTrue(fixture.windows[0].tabGroup?.selectedWindow === fixture.windows[0],
                      "Smart switching must retain the native group's MRU sibling")
    }

    // NSWindow.h documents tabbedWindows as nullable when no native tab bar
    // is shown. This macOS ignores toggleTabBar for a multi-window group, so
    // provide that documented nil response while retaining a real AppKit group.
    // These are consumer contract tests, not proof of three-tab bar hiding.
    @MainActor private final class Window: NSWindow {
        var presentationSnapshotUnavailable = false
        override var tabbedWindows: [NSWindow]? {
            presentationSnapshotUnavailable ? nil : super.tabbedWindows
        }
    }

    @MainActor private final class Fixture {
        let states: [ReaderState]
        let windows: [NSWindow]
        private let delegates: [ReaderCloseGuard]
        private let previous: [(String, Any?)]
        private var observations = [NSObjectProtocol]()

        init() throws {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            previous = ["restoreSession", "session", "disableHistory", "disableReadingState"].map {
                ($0, defaults.object(forKey: $0))
            }
            defaults.set(true, forKey: "restoreSession")
            defaults.set(false, forKey: "disableHistory")
            defaults.set(true, forKey: "disableReadingState")
            let identifier = "Hidden-Native-" + UUID().uuidString
            states = (0..<3).map { index in
                let state = ReaderState(recordsHistory: true)
                state.document = ReadingDocument(url: URL(fileURLWithPath: "/hidden-tab-\(index).txt"), content: .text("book"))
                return state
            }
            windows = states.map { state in
                let window = Window(contentRect: CGRect(x: 2200, y: 100, width: 700, height: 400),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0; window.ignoresMouseEvents = true
                window.tabbingIdentifier = identifier
                state.window = window
                return window
            }
            delegates = states.map { ReaderCloseGuard(state: $0, previous: nil) }
            for index in windows.indices {
                windows[index].delegate = delegates[index]
                let state = states[index]
                observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: windows[index], queue: .main) { _ in MainActor.assumeIsolated { state.windowClosed() } })
                if index > 0 { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
            }
            do {
                let group = try XCTUnwrap(windows[0].tabGroup)
                group.selectedWindow = windows[1]
                for case let window as Window in windows { window.presentationSnapshotUnavailable = true }
                XCTAssertEqual(group.windows, windows)
                for window in windows { XCTAssertNil(window.tabbedWindows, "Supply the SDK's documented nullable presentation snapshot") }
            } catch { close(); throw error }
        }

        func close() {
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations = []
            ReaderWindows.finishSmartSwitch()
            for (window, state) in zip(windows, states) {
                window.delegate = nil; window.orderOut(nil); window.close(); state.windowClosed()
            }
            for (key, value) in previous { UserDefaults.standard.set(value, forKey: key) }
        }
    }
}
#endif
