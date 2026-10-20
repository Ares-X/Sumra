#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ClosedReaderSceneTests: XCTestCase {
    @MainActor
    func testRetainedClosedWindowDoesNotMountHome() async throws {
        try await checkClose(closingWindow: true)
    }

    @MainActor
    func testReturningHomeKeepsTheOpenSceneUsable() async throws {
        try await checkClose(closingWindow: false)
    }

    @MainActor
    private func checkClose(closingWindow: Bool) async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousCapture = ScreenshotHotkey.capture
        let overrides: [(String, Any)] = [
            ("disableHistory", true), ("disableReadingState", true),
            ("homePageViewMode", "list"), ("showContentsOnOpen", false)
        ]
        let previous = overrides.map { defaults.object(forKey: $0.0) }
        for (key, value) in overrides { defaults.set(value, forKey: key) }
        defer {
            ScreenshotHotkey.capture = previousCapture
            for ((key, _), value) in zip(overrides, previous) { defaults.set(value, forKey: key) }
        }

        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("retained-scene.txt")
        let marker = "Retained reader scene fixture"
        try marker.write(to: input, atomically: true, encoding: .utf8)
        let application = ReaderApplicationDelegate()
        let host = NSHostingView(rootView: ReaderWindow(
            payload: .constant(WindowPayload(path: input.path, recordsHistory: false)), application: application))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            (window.delegate as? ReaderCloseGuard)?.state?.windowClosed()
            window.contentView = nil
            window.close()
            withExtendedLifetime((directory, application)) {}
        }

        func waitFor(_ condition: () -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            XCTFail("The retained reader scene did not finish updating", line: line)
        }
        func hasReaderText() -> Bool {
            descendants(of: NSTextView.self, in: host).contains { $0.string.contains(marker) }
        }
        func hasHome() -> Bool {
            !descendants(of: NSSegmentedControl.self, in: host).isEmpty
        }

        try await waitFor { (window.delegate as? ReaderCloseGuard)?.state?.document?.url == input && hasReaderText() }
        let state = try XCTUnwrap((window.delegate as? ReaderCloseGuard)?.state)
        XCTAssertFalse(hasHome(), "A loaded reader must not already contain the Home file-view control")
        if closingWindow { window.close() }
        else { state.close() }
        try await waitFor { state.document == nil && !hasReaderText() }
        XCTAssertNil(state.document, "Closing must release the outgoing document while the scene is retained")
        if closingWindow {
            XCTAssertFalse(hasHome(), "A retained closed scene must not mount Home or start its cover work")
        } else {
            try await waitFor { hasHome() }
            XCTAssertTrue(hasHome(), "Returning Home must keep its file browser available in the open window")
            XCTAssertTrue(state.window === window)
        }
        withExtendedLifetime((host, state)) {}
    }

    @MainActor
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(of: type, in: $0) }
    }
}
#endif
