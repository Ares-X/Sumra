#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativeTabClosingTests: XCTestCase {
    func testNativeCloseKeepsSurvivingTabOrderAndSelection() async throws {
        for closing in 0..<5 {
            let fixture = try Tabs(count: 5, selected: 2)
            defer { fixture.close() }
            for state in fixture.states { state.immersiveControls = false; state.toolbarDisplayMode = .shown }
            let group = try XCTUnwrap(fixture.windows[2].tabGroup)
            let remaining = fixture.windows.indices.filter { $0 != closing }.map { fixture.windows[$0] }
            let frames = remaining.map(\.frame)
            let documentIDs = fixture.states.map { $0.document?.id }
            let generations = fixture.states.map(\.generation)
            let keyWindow = NSApp.keyWindow, mainWindow = NSApp.mainWindow
            let visibility = remaining.map(\.isVisible)
            fixture.windows[closing].performClose(nil)
            XCTAssertTrue(fixture.closed.contains(closing), "An ordinary close must finish in AppKit’s original event")
            XCTAssertEqual(group.windows, remaining)
            XCTAssertTrue(group.isTabBarVisible)
            XCTAssertEqual(remaining.map(\.frame), frames)
            XCTAssertTrue(NSApp.keyWindow === keyWindow)
            XCTAssertTrue(NSApp.mainWindow === mainWindow)
            for (index, window) in remaining.enumerated() where window !== group.selectedWindow {
                XCTAssertEqual(window.isVisible, visibility[index], "Closing a tab must not expose background readers")
            }
            for index in fixture.states.indices where index != closing {
                XCTAssertEqual(fixture.states[index].document?.id, documentIDs[index])
                XCTAssertEqual(fixture.states[index].generation, generations[index], "Closing a tab must not load or replace surviving documents")
            }
            let selected = try XCTUnwrap(group.selectedWindow)
            XCTAssertTrue(remaining.contains(selected))
            if closing != 2 { XCTAssertTrue(selected === fixture.windows[2], "Closing a background tab must retain the selected reader") }
            XCTAssertEqual(fixture.approvals.map(\.requests), fixture.windows.indices.map { $0 == closing ? 1 : 0 })
        }
    }

    func testBulkCloseCompletesAllOtherLeftAndRightNativeTabSubsets() async throws {
        for (subset, remaining) in [("all", []), ("other", [2]), ("left", [2, 3, 4]), ("right", [0, 1, 2])] {
            let fixture = try Tabs(count: 5, selected: 2)
            defer { fixture.close() }
            fixture.states[2].closeTabs(subset)
            try await waitFor { fixture.closed.count == 5 - remaining.count }
            XCTAssertEqual(fixture.states.indices.filter { fixture.states[$0].document != nil }, remaining, subset)
            XCTAssertEqual(fixture.approvals.map(\.requests), fixture.states.indices.map { remaining.contains($0) ? 0 : 1 }, subset)
            if !remaining.isEmpty {
                XCTAssertEqual(fixture.windows[remaining[0]].tabbedWindows ?? [fixture.windows[remaining[0]]],
                    remaining.map { fixture.windows[$0] }, subset)
            }
        }
    }

    func testBulkCloseTraversesLoadedHomeAndDormantRestoredTabsWithoutLoadingTheRestoredFile() async throws {
        let directory = try TemporaryDirectory()
        func loaded(_ name: String) throws -> ReaderState {
            let url = directory.url.appendingPathComponent(name)
            try "Loaded text tab".write(to: url, atomically: true, encoding: .utf8)
            let state = ReaderState(recordsHistory: false)
            state.document = try ReadingDocument.open(url)
            return state
        }
        let restoredURL = directory.url.appendingPathComponent("dormant.txt")
        try "This restored text must remain unopened".write(to: restoredURL, atomically: true, encoding: .utf8)
        var saved = WindowPayload(path: restoredURL.path, position: .init(page: 0, zoom: 1.4), recordsHistory: false)
        saved.restoring = true; saved.active = false; saved.selected = false
        let dormant = ReaderState(recordsHistory: false, restoring: saved)
        let home = ReaderState(recordsHistory: false)
        let fixture = try Tabs(states: [loaded("first.txt"), home, dormant, loaded("last.txt")], selected: 3)
        defer { fixture.close(); withExtendedLifetime(directory) {} }
        XCTAssertNil(home.document)
        XCTAssertNil(home.restoredPayload)
        XCTAssertNil(dormant.document)
        XCTAssertEqual(dormant.restoredPayload?.position, saved.position)
        XCTAssertEqual(dormant.generation, 0)

        fixture.states[3].closeTabs("all")
        try await waitFor { fixture.closed.count == 4 }
        XCTAssertEqual(fixture.approvals.map(\.requests), [1, 1, 1, 1], "Each kind of tab must use its real ReaderCloseGuard approval")
        XCTAssertTrue(fixture.states.allSatisfy { $0.isWindowClosed && $0.document == nil && $0.window == nil })
        XCTAssertNil(dormant.restoredPayload)
        XCTAssertFalse(dormant.busy)
        XCTAssertEqual(dormant.generation, 1, "Only closing may advance the dormant reader's generation; no parser may start")
        XCTAssertTrue(fixture.states.allSatisfy { $0.error == nil })
    }

    func testBulkCloseStopsWhenNativeDelegateRejectsTheNextTab() async throws {
        let fixture = try Tabs(count: 3, selected: 2)
        defer { fixture.close() }
        fixture.approvals[1].allowed = false
        fixture.states[2].closeTabs("all")
        try await waitFor { fixture.approvals[1].requests == 1 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.closed, [0])
        XCTAssertNotNil(fixture.states[1].document)
        XCTAssertNotNil(fixture.states[2].document)
        XCTAssertEqual(fixture.approvals[2].requests, 0, "A rejected close must stop the remaining batch")
    }

    func testBulkCloseCancelKeepsDirtyPDFAndLaterTabs() async throws {
        let fixture = try Tabs(count: 3, selected: 2)
        defer { fixture.close() }
        let reading = try await dirtyPDF(in: fixture.states[1])
        let original = try Data(contentsOf: reading.url)
        var answered = false
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                answered = true
                NSApp.stopModal(withCode: .alertThirdButtonReturn)
            }
        }
        fixture.states[2].closeTabs("all")
        try await waitFor { answered && NSApp.modalWindow == nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.closed, [0])
        XCTAssertEqual(fixture.states[1].document?.id, reading.id)
        XCTAssertTrue(fixture.states[1].modified)
        XCTAssertNotNil(fixture.states[2].document)
        XCTAssertEqual(fixture.approvals[1].requests, 0, "Cancel must not reach the native close delegate")
        XCTAssertEqual(fixture.approvals[2].requests, 0)
        XCTAssertEqual(try Data(contentsOf: reading.url), original)
        withExtendedLifetime(reading) {}
    }

    func testBulkCloseSaveAndDiscardResolveBeforeClosingLaterTabs() async throws {
        for save in [true, false] {
            let fixture = try Tabs(count: 3, selected: 2)
            defer { fixture.close() }
            let reading = try await dirtyPDF(in: fixture.states[1])
            let original = try Data(contentsOf: reading.url)
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    NSApp.stopModal(withCode: save ? .alertFirstButtonReturn : .alertSecondButtonReturn)
                }
            }
            fixture.states[2].closeTabs("all")
            try await waitFor { fixture.closed.count == 3 }
            XCTAssertEqual(fixture.approvals.map(\.requests), [1, 1, 1])
            let saved = try NativeFile(reading.url, engine: .mupdf)
            XCTAssertEqual(try saved.pdfAnnotations(0).first?.contents, save ? "Unsaved tab annotation" : nil)
            if !save { XCTAssertEqual(try Data(contentsOf: reading.url), original, "Discard must leave the file unchanged") }
            XCTAssertTrue(fixture.states.allSatisfy { $0.error == nil })
            withExtendedLifetime(reading) {}
        }
    }

    func testBulkCloseSaveFailureRetainsLivePDFAndStopsLaterTabs() async throws {
        let fixture = try Tabs(count: 3, selected: 2)
        defer { fixture.close() }
        let state = fixture.states[1], reading = try await dirtyPDF(in: state)
        let pages = try XCTUnwrap(state.nativePDF)
        // A directory at the original file path makes the actual atomic save
        // fail without relying on the test user's filesystem permissions.
        try FileManager.default.removeItem(at: reading.url)
        try FileManager.default.createDirectory(at: reading.url, withIntermediateDirectories: false)
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
        }
        fixture.states[2].closeTabs("all")
        try await waitFor { state.error != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.closed, [0])
        XCTAssertEqual(state.document?.id, reading.id)
        XCTAssertTrue(state.modified)
        XCTAssertFalse(try XCTUnwrap(state.error).isEmpty, "Retain the original save error")
        let annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.first?.contents, "Unsaved tab annotation")
        XCTAssertNotNil(fixture.states[2].document)
        XCTAssertEqual(fixture.approvals[1].requests, 0)
        XCTAssertEqual(fixture.approvals[2].requests, 0)
        withExtendedLifetime(reading) {}
    }

    private func dirtyPDF(in state: ReaderState) async throws -> ReadingDocument {
        let reading = try nativePDFReadingFixture()
        state.document = reading
        let pages = try XCTUnwrap(state.nativePDF)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 20, width: 30, height: 40),
            edits: [.contents("Unsaved tab annotation")])
        try await state.nativePDFDidChange(pages)
        XCTAssertTrue(state.canSave)
        XCTAssertTrue(state.modified)
        return reading
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else { XCTFail("Native tab close did not settle", line: line); throw CancellationError() }
    }

    @MainActor private final class Approval: NSObject, NSWindowDelegate {
        var allowed = true
        var requests = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return allowed }
    }

    @MainActor private final class Tabs {
        let states: [ReaderState]
        let windows: [NSWindow]
        let approvals: [Approval]
        let delegates: [ReaderCloseGuard]
        var closed = Set<Int>()
        private var observations = [NSObjectProtocol]()

        convenience init(count: Int, selected: Int) throws {
            let states = (0..<count).map { index in
                let state = ReaderState(recordsHistory: false)
                state.document = ReadingDocument(url: URL(fileURLWithPath: "/tab-close-\(UUID().uuidString)-\(index).txt"), content: .text("Open tab \(index)"))
                return state
            }
            try self.init(states: states, selected: selected)
        }

        init(states: [ReaderState], selected: Int) throws {
            _ = NSApplication.shared
            self.states = states
            let identifier = "Sumra-Tab-Close-" + UUID().uuidString
            windows = states.map { state in
                let window = NSWindow(contentRect: CGRect(x: 2000, y: 100, width: 640, height: 480),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.alphaValue = 0; window.ignoresMouseEvents = true
                window.tabbingIdentifier = identifier; window.tabbingMode = .preferred
                state.window = window
                return window
            }
            approvals = states.map { _ in Approval() }
            delegates = zip(states, approvals).map { ReaderCloseGuard(state: $0.0, previous: $0.1) }
            for index in windows.indices {
                windows[index].delegate = delegates[index]
                let state = states[index]
                observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: windows[index], queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closed.insert(index); state.windowClosed() }
                })
                if index > 0 { windows[index - 1].addTabbedWindow(windows[index], ordered: .above) }
            }
            let group = try XCTUnwrap(windows[0].tabGroup)
            group.selectedWindow = windows[selected]
            XCTAssertEqual(group.windows, windows, "Exercise a real AppKit tab group in source order")
        }

        func close() {
            for observer in observations { NotificationCenter.default.removeObserver(observer) }
            observations = []
            for (window, state) in zip(windows, states) {
                window.delegate = nil; window.close(); state.windowClosed()
            }
        }
    }
}
#endif
