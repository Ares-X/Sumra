#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class DocumentOpenBehaviorTests: XCTestCase {
    func testDefaultKeepsLoadedDocumentAndCreatesIndependentWindows() throws {
        let fixture = try Fixture(behavior: nil)
        defer { fixture.close() }
        fixture.loadCurrent()
        let original = fixture.state.document?.id
        var created = [WindowPayload]()

        XCTAssertEqual(DocumentOpenBehavior.current, .newWindow)
        ReaderWindows.open(fixture.urls, in: fixture.state) { created.append($0) }

        XCTAssertEqual(fixture.state.document?.id, original)
        XCTAssertFalse(fixture.state.busy)
        XCTAssertEqual(created.map(\.path), fixture.urls.map(\.path))
        XCTAssertTrue(created.allSatisfy { $0.tabWith == nil && $0.tabIdentifier == nil })
    }

    func testEveryPolicyFillsWelcomeBeforeOpeningRemainingFiles() async throws {
        for behavior in DocumentOpenBehavior.allCases {
            let fixture = try Fixture(behavior: behavior)
            defer { fixture.close() }
            var created = [WindowPayload]()

            ReaderWindows.open(fixture.urls, in: fixture.state, recordsHistory: false) { created.append($0) }
            try await waitUntilIdle(fixture.state)

            XCTAssertEqual(fixture.state.document?.url, fixture.urls[0])
            XCTAssertEqual(created.map(\.path), [fixture.urls[1].path])
            XCTAssertEqual(created[0].recordsHistory, false)
            XCTAssertEqual(created[0].tabWith, behavior == .newTab ? fixture.window.windowNumber : nil)
        }
    }

    func testNewTabTargetsLoadedReaderAndRespectsDisabledTabs() throws {
        let fixture = try Fixture(behavior: .newTab)
        defer { fixture.close() }
        fixture.loadCurrent()
        let original = fixture.state.document?.id

        for disabled in [false, true] {
            UserDefaults.standard.set(disabled, forKey: "disableTabs")
            var created = [WindowPayload]()
            ReaderWindows.open(fixture.urls, in: fixture.state) { created.append($0) }
            XCTAssertEqual(fixture.state.document?.id, original)
            XCTAssertEqual(created.map(\.path), fixture.urls.map(\.path))
            XCTAssertTrue(created.allSatisfy { $0.tabWith == (disabled ? nil : fixture.window.windowNumber) })
        }
    }

    func testReplaceCurrentReplacesOnlyFirstFileAndCancelPreservesDirtyDocument() async throws {
        let fixture = try Fixture(behavior: .replaceCurrent)
        defer { fixture.close() }
        fixture.loadCurrent()
        var created = [WindowPayload]()

        ReaderWindows.open(fixture.urls, in: fixture.state, recordsHistory: false) { created.append($0) }
        try await waitUntilIdle(fixture.state)
        XCTAssertEqual(fixture.state.document?.url, fixture.urls[0])
        XCTAssertEqual(created.map(\.path), [fixture.urls[1].path])
        XCTAssertNil(created[0].tabWith)

        let reading = try nativePDFReadingFixture()
        fixture.state.document = reading
        let pages = try XCTUnwrap(fixture.state.nativePDF)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
            bounds: CGRect(x: 10, y: 20, width: 30, height: 40), edits: [.contents("Keep unsaved changes")])
        try await fixture.state.nativePDFDidChange(pages)
        let originalBytes = try Data(contentsOf: reading.url)
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated { NSApp.stopModal(withCode: .alertThirdButtonReturn) }
        }
        ReaderWindows.open([fixture.urls[1]], in: fixture.state) { created.append($0) }
        XCTAssertEqual(fixture.state.document?.id, reading.id)
        XCTAssertTrue(fixture.state.modified)
        XCTAssertFalse(fixture.state.busy)
        XCTAssertEqual(try Data(contentsOf: reading.url), originalBytes)
        XCTAssertEqual(created.count, 1)
    }

    func testNewTabBatchWithoutALiveReaderCreatesOneGroupAndPreservesPendingReaders() throws {
        let fixture = try Fixture(behavior: .newTab)
        defer { fixture.close() }
        fixture.state.windowClosed()
        var created = [WindowPayload]()
        ReaderWindows.open(fixture.urls, in: fixture.state) { created.append($0) }
        XCTAssertEqual(created.map(\.path), fixture.urls.map(\.path))
        let identifier = try XCTUnwrap(created.first?.tabIdentifier)
        XCTAssertTrue(created.allSatisfy { $0.tabWith == nil && $0.tabIdentifier == identifier })
        XCTAssertNil(fixture.state.document)

        for behavior in DocumentOpenBehavior.allCases {
            UserDefaults.standard.set(behavior.rawValue, forKey: "documentOpenBehavior")
            let pending = ReaderState(recordsHistory: false, restoring: WindowPayload(path: "/pending.txt"))
            pending.window = fixture.window
            defer { pending.windowClosed() }
            let generation = pending.generation
            ReaderWindows.open(fixture.urls, in: pending) { _ in }
            XCTAssertEqual(pending.restoredPayload?.path, "/pending.txt")
            XCTAssertEqual(pending.generation, generation)
            XCTAssertNil(pending.document)
        }
    }

    func testFinderUsesFrontReaderForTabPolicyAndNewTabCancellationLeavesWelcomeAlone() throws {
        let fixture = try Fixture(behavior: .newTab)
        defer { fixture.close() }
        var created = [WindowPayload]()
        fixture.state.createWindow = { created.append($0) }
        XCTAssertTrue(ReaderMenuCommand.newTab.enabled(fixture.state))
        var pickerRequests = 0
        ReaderMenuCommand.newTab.run(fixture.state, choose: { _ in pickerRequests += 1 })
        XCTAssertEqual(pickerRequests, 1)
        XCTAssertTrue(created.isEmpty, "Cancelling selection must not create a blank tab")
        fixture.loadCurrent()
        fixture.window.orderFront(nil)
        let delegate = ReaderApplicationDelegate()
        delegate.installWindowOpener { created.append($0) }
        delegate.finishLaunching()
        delegate.application(NSApp, open: fixture.urls)
        XCTAssertEqual(created.map(\.path), fixture.urls.map(\.path))
        XCTAssertTrue(created.allSatisfy { $0.tabWith == fixture.window.windowNumber })

        UserDefaults.standard.set(true, forKey: "disableTabs")
        XCTAssertFalse(ReaderMenuCommand.newTab.enabled(fixture.state))
        ReaderMenuCommand.newTab.run(fixture.state, choose: { _ in XCTFail("Disabled tabs must not show a picker") })
        XCTAssertEqual(created.count, 2)
    }

    func testNewTabSelectionOverridesEveryDefaultOpenPolicyWithoutReplacingTheBook() throws {
        for behavior in DocumentOpenBehavior.allCases {
            let fixture = try Fixture(behavior: behavior)
            defer { fixture.close() }
            fixture.loadCurrent()
            let original = fixture.state.document?.id
            var created = [WindowPayload]()
            fixture.state.createWindow = { created.append($0) }
            ReaderMenuCommand.newTab.run(fixture.state, choose: { receive in receive(fixture.urls) })
            XCTAssertEqual(fixture.state.document?.id, original, behavior.rawValue)
            XCTAssertFalse(fixture.state.busy)
            XCTAssertEqual(created.map(\.path), fixture.urls.map(\.path))
            XCTAssertTrue(created.allSatisfy { $0.tabWith == fixture.window.windowNumber })
        }
    }

    func testNewTabEmptySelectionAndCancellationPreserveTheCurrentBook() throws {
        let fixture = try Fixture(behavior: .replaceCurrent)
        defer { fixture.close() }
        fixture.loadCurrent()
        let original = fixture.state.document?.id
        var created = [WindowPayload]()
        fixture.state.createWindow = { created.append($0) }
        ReaderMenuCommand.newTab.run(fixture.state, choose: { _ in })
        ReaderMenuCommand.newTab.run(fixture.state, choose: { receive in receive([]) })
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(fixture.state.document?.id, original)
        XCTAssertFalse(fixture.state.busy)
    }

    func testNativeNewTabActionUsesTheSameCommandAvailability() throws {
        let fixture = try Fixture(behavior: .replaceCurrent)
        defer { fixture.close() }
        fixture.loadCurrent()
        fixture.state.createWindow = { _ in }
        let action = #selector(ReaderCloseGuard.newWindowForTab(_:))
        let item = NSMenuItem(title: "New Tab", action: action, keyEquivalent: "")
        XCTAssertTrue(fixture.closeGuard.responds(to: action))
        XCTAssertTrue(fixture.closeGuard.validateUserInterfaceItem(item))
        UserDefaults.standard.set(true, forKey: "disableTabs")
        XCTAssertFalse(fixture.closeGuard.validateUserInterfaceItem(item))
    }

    private func waitUntilIdle(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.error)
    }

    @MainActor private final class Fixture {
        let directory: TemporaryDirectory
        let urls: [URL]
        let state: ReaderState
        let window: NSWindow
        let closeGuard: ReaderCloseGuard
        let previous: [(String, Any?)]

        init(behavior: DocumentOpenBehavior?) throws {
            _ = NSApplication.shared
            let directory = try TemporaryDirectory()
            self.directory = directory
            urls = ["first.txt", "second.txt"].map { directory.url.appendingPathComponent($0) }
            for url in urls { try "Open policy fixture".write(to: url, atomically: true, encoding: .utf8) }
            let defaults = UserDefaults.standard
            previous = ["documentOpenBehavior", "disableTabs", "disableHistory", "disableReadingState"].map {
                ($0, defaults.object(forKey: $0))
            }
            defaults.set(behavior?.rawValue, forKey: "documentOpenBehavior")
            defaults.set(false, forKey: "disableTabs")
            defaults.set(true, forKey: "disableHistory")
            defaults.set(true, forKey: "disableReadingState")
            state = ReaderState(recordsHistory: false)
            window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 560, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0; window.ignoresMouseEvents = true
            state.window = window
            closeGuard = ReaderCloseGuard(state: state, previous: nil)
            window.delegate = closeGuard
        }

        func loadCurrent() {
            state.document = ReadingDocument(url: directory.url.appendingPathComponent("current.txt"), content: .text("Current book"))
        }

        func close() {
            state.windowClosed()
            window.delegate = nil
            window.close()
            for (key, value) in previous { UserDefaults.standard.set(value, forKey: key) }
        }
    }
}
#endif
