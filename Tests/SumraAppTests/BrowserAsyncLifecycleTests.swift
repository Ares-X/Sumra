#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import WebKit
import XCTest
@testable import Sumra

final class BrowserAsyncLifecycleTests: XCTestCase {
    @MainActor
    private final class Lifetime {
        weak var view: WKWebView?
        weak var coordinator: BrowserReader.Coordinator?
        weak var source: MarkupSource?
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Browser lifecycle condition timed out")
        guard condition() else { throw CancellationError() }
    }

    @MainActor
    private func closeWithPendingMermaid() async throws -> Lifetime {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("pending.md")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let fixedPage = defaults.object(forKey: "useFixedPageUI")
        defaults.set(false, forKey: "useFixedPageUI")
        defer {
            if let fixedPage { defaults.set(fixedPage, forKey: "useFixedPageUI") }
            else { defaults.removeObject(forKey: "useFixedPageUI") }
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(file)
        guard case .browser(let source) = state.document?.content else {
            XCTFail("Expected browser document")
            throw CancellationError()
        }
        let coordinator = BrowserReader.Coordinator(state: state, source: source)
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            state.windowClosed()
            window.contentView = nil
            window.close()
            withExtendedLifetime(directory) {}
        }
        coordinator.load(view)
        try await waitUntil { coordinator.ready }
        _ = try await view.evaluateJavaScript("""
            const pre = document.createElement('pre');
            const code = document.createElement('code');
            code.className = 'language-mermaid';
            code.textContent = 'graph TD; A-->B';
            pre.append(code); document.body.append(pre);
            window.sumraRenderMermaid = () => {
                window.pendingMermaidEntered = true;
                return new Promise(() => {});
            };
            void 0;
            """, in: nil, contentWorld: coordinator.scriptWorld)
        coordinator.renderMermaid(view)
        let deadline = Date().addingTimeInterval(5)
        var entered = false
        while !entered, Date() < deadline {
            entered = try await view.evaluateJavaScript("window.pendingMermaidEntered === true", in: nil,
                contentWorld: coordinator.scriptWorld) as? Bool == true
            if !entered { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(entered, "Mermaid must reach the deliberately pending promise")
        let lifetime = Lifetime()
        lifetime.view = view
        lifetime.coordinator = coordinator
        return lifetime
    }

    @MainActor
    func testClosingBrowserReleasesViewAndCoordinatorDuringPendingMermaid() async throws {
        let lifetime = try await closeWithPendingMermaid()
        let deadline = Date().addingTimeInterval(1)
        while (lifetime.view != nil || lifetime.coordinator != nil), Date() < deadline {
            autoreleasepool {}
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(lifetime.view, "A pending Mermaid promise must not retain a closed browser view")
        XCTAssertNil(lifetime.coordinator, "A pending Mermaid promise must not retain the closed document coordinator")
    }

    @MainActor
    private func mountedBrowserLifetime(_ state: ReaderState) throws -> Lifetime {
        let view = try XCTUnwrap(state.browserView)
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        XCTAssertTrue(coordinator.ready)
        let lifetime = Lifetime()
        lifetime.view = view
        lifetime.coordinator = coordinator
        lifetime.source = try XCTUnwrap(coordinator.markup)
        return lifetime
    }

    @MainActor
    private func checkMountedBrowserReplacement(withPDF: Bool) async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let markdown = directory.url.appendingPathComponent("mounted.md")
        try "# Mounted browser\n\nAn owned browser document.\n".write(to: markdown, atomically: true, encoding: .utf8)
        // Keep the fixture's lease alive while state.open reads its native PDF.
        let pdf = withPDF ? try nativePDFReadingFixture() : nil
        let replacement = pdf?.url ?? directory.url.appendingPathComponent("replacement.txt")
        if !withPDF { try "Native text replacement.\n".write(to: replacement, atomically: true, encoding: .utf8) }
        let defaults = UserDefaults.standard
        let fixedPage = defaults.object(forKey: "useFixedPageUI")
        defaults.set(false, forKey: "useFixedPageUI")
        defer {
            if let fixedPage { defaults.set(fixedPage, forKey: "useFixedPageUI") }
            else { defaults.removeObject(forKey: "useFixedPageUI") }
            withExtendedLifetime((directory, pdf)) {}
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(markdown)
        let host = NSHostingView(rootView: ReaderView(state: state))
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            state.windowClosed()
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { (state.browserView?.navigationDelegate as? BrowserReader.Coordinator)?.ready == true }
        let lifetime = try mountedBrowserLifetime(state)

        state.openWithoutHistory(replacement)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return !state.busy && state.document?.url == replacement && !state.isBrowser
        }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.isPDF, withPDF)
        XCTAssertEqual(state.isText, !withPDF)
        let deadline = Date().addingTimeInterval(1)
        while (lifetime.view != nil || lifetime.coordinator != nil || lifetime.source != nil), Date() < deadline {
            host.layoutSubtreeIfNeeded()
            autoreleasepool {}
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(lifetime.view, "SwiftUI replacement must release the old mounted browser view")
        XCTAssertNil(lifetime.coordinator, "SwiftUI replacement must release the old browser coordinator")
        XCTAssertNil(lifetime.source, "SwiftUI replacement must release the outgoing Markdown source")
        // Verify release while the replacement's hosting view and window still live.
        withExtendedLifetime((host, window, state)) {}
    }

    @MainActor
    func testMountedMarkdownReplacementWithTextReleasesBrowserOwners() async throws {
        try await checkMountedBrowserReplacement(withPDF: false)
    }

    @MainActor
    func testMountedMarkdownReplacementWithNativePDFReleasesBrowserOwners() async throws {
        try await checkMountedBrowserReplacement(withPDF: true)
    }
}
#endif
