#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class SessionRestorationTests: XCTestCase {
    func testUnopenedRestoredTabRetainsPositionForSessionAndClosedHistory() throws {
        let defaults = UserDefaults.standard
        let keys = ["disableHistory", "closedDocuments"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let terminating = ReaderWindows.isTerminating
        defaults.set(false, forKey: "disableHistory")
        ReaderWindows.isTerminating = false
        defer {
            ReaderWindows.isTerminating = terminating
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        let position = ReadingPosition(page: 12, x: 18, y: 210, zoom: 1.4)
        var saved = WindowPayload(path: "/unopened-background-book.pdf", position: position)
        saved.tabColor = 0x4288AA
        saved.selected = true; saved.active = true
        saved.restoring = true
        let state = ReaderState(restoring: saved)
        state.tabColor = saved.tabColor
        XCTAssertNil(state.document)
        XCTAssertFalse(state.busy)
        XCTAssertEqual(state.generation, 0, "An unopened restored tab must not enter the document loader")
        let snapshot = try XCTUnwrap(ReaderWindows.payload(state))
        XCTAssertEqual(snapshot.path, saved.path)
        XCTAssertEqual(snapshot.position, position)
        XCTAssertEqual(snapshot.tabColor, saved.tabColor)
        let encoded = try JSONEncoder().encode([saved])
        let restored = try JSONDecoder().decode([WindowPayload].self, from: encoded)
        XCTAssertEqual(restored.first?.position, position)
        XCTAssertEqual(restored.first?.selected, true)
        XCTAssertEqual(restored.first?.active, true)
        XCTAssertEqual(restored.first?.restoring, false)

        ReaderWindows.rememberClosed(state)
        state.windowClosed()
        XCTAssertEqual(ReaderWindows.saved("closedDocuments").last?.path, saved.path)
        XCTAssertEqual(ReaderWindows.saved("closedDocuments").last?.position, position)
        state.activateRestoredDocument()
        XCTAssertEqual(state.generation, 1, "Closing before activation must never start a document load")
        XCTAssertNil(state.restoredPayload)
    }

    func testExplicitOpenSupersedesAnUnparsedRestoredTab() async throws {
        let directory = try TemporaryDirectory()
        let explicit = directory.url.appendingPathComponent("explicit.txt")
        try "Explicit open bypasses the dormant saved document".write(to: explicit, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false, restoring: WindowPayload(path: "/missing-restored-book.pdf", position: .init(page: 8)))
        defer { state.windowClosed(); withExtendedLifetime(directory) {} }
        state.openWithoutHistory(explicit)
        try await waitFor { !state.busy }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.document?.url, explicit)
        XCTAssertNil(state.restoredPayload)
        let generation = state.generation
        state.activateRestoredDocument()
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.document?.url, explicit)
    }

    func testNativeTabRestorationLoadsCurrentThenLoadsBackgroundOnlyOnActivation() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["disableHistory", "disableReadingState", "disableTabs", "showContentsOnOpen", "restoreSession", "session", "documentOpenHistory"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        let previousCapture = ScreenshotHotkey.capture
        defaults.set(false, forKey: "disableHistory")
        defaults.set(true, forKey: "disableReadingState")
        defaults.set(false, forKey: "disableTabs")
        defaults.set(false, forKey: "showContentsOnOpen")
        let directory = try TemporaryDirectory()
        let urls = ["first.txt", "current.txt", "last.txt"].map { directory.url.appendingPathComponent($0) }
        for url in urls { try url.lastPathComponent.write(to: url, atomically: true, encoding: .utf8) }
        let identifier = "Sumra-Restore-Test-" + UUID().uuidString
        var saved = urls.map { WindowPayload(path: $0.path, position: ReadingPosition(page: 0, zoom: 1.5)) }
        for index in saved.indices { saved[index].tabIdentifier = identifier }
        saved[1].selected = true; saved[1].active = true
        let requests = ReaderWindows.prepareRestoration(saved)
        XCTAssertEqual(requests.first?.path, urls[1].path)
        let application = ReaderApplicationDelegate()
        var windows: [NSWindow] = []
        defer {
            _ = ReaderWindows.prepareRestoration([])
            for window in windows {
                (window.delegate as? ReaderCloseGuard)?.state?.windowClosed()
                window.contentView = nil; window.close()
            }
            ReaderFiles.setRecent(recent)
            ScreenshotHotkey.capture = previousCapture
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime((directory, application)) {}
        }
        for request in requests {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReaderWindow(payload: .constant(request), application: application))
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            try await waitFor { (window.delegate as? ReaderCloseGuard)?.state != nil }
        }
        let currentWindow = windows[0]
        let current = try XCTUnwrap((currentWindow.delegate as? ReaderCloseGuard)?.state)
        try await waitFor { !current.busy && current.document != nil }
        XCTAssertNil(current.error)
        XCTAssertEqual(current.document?.url, urls[1])
        XCTAssertEqual(current.zoom, 1.5)
        try await waitFor {
            currentWindow.tabGroup?.selectedWindow === currentWindow &&
                currentWindow.tabbedWindows?.compactMap { ($0.delegate as? ReaderCloseGuard)?.state }.compactMap(ReaderWindows.payload).map(\.path) == urls.map { Optional($0.path) }
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: currentWindow)
        XCTAssertTrue(currentWindow.tabGroup?.selectedWindow === currentWindow)
        XCTAssertEqual(currentWindow.tabbedWindows?.compactMap { ($0.delegate as? ReaderCloseGuard)?.state }.compactMap(ReaderWindows.payload).map(\.path), urls.map { Optional($0.path) })
        let background = try XCTUnwrap((windows[1].delegate as? ReaderCloseGuard)?.state)
        let last = try XCTUnwrap((windows[2].delegate as? ReaderCloseGuard)?.state)
        XCTAssertNil(background.document); XCTAssertFalse(background.busy); XCTAssertEqual(background.generation, 0)
        XCTAssertNil(last.document); XCTAssertFalse(last.busy); XCTAssertEqual(last.generation, 0)

        // Save an untouched tab with its original location before activating it.
        defaults.set(true, forKey: "restoreSession")
        ReaderWindows.saveSession([current, background, last])
        let session = ReaderWindows.saved("session")
        XCTAssertEqual(session.map(\.path), urls.map { Optional($0.path) })
        XCTAssertEqual(session.first?.position?.zoom, 1.5)
        XCTAssertEqual(session.first(where: { $0.active == true })?.path, urls[1].path)
        windows[1].tabGroup?.selectedWindow = windows[1]
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windows[1])
        try await waitFor { background.document != nil && !background.busy }
        XCTAssertNil(background.error)
        XCTAssertEqual(background.document?.url, urls[0])
        XCTAssertEqual(background.zoom, 1.5)
        XCTAssertNil(last.document)
        XCTAssertEqual(last.generation, 0)
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Session restoration did not settle", line: line)
    }
}
#endif
