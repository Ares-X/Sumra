#if os(macOS)
import AppKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class MarkdownCrossRendererLinkTests: XCTestCase {
    @MainActor
    func testBrowserLinkPreservesEncodedUnicodeHeadingIntoPagedMarkdown() async throws {
        try await assertPagedLink(heading: "Halo 世界", fragment: "halo-%E4%B8%96%E7%95%8C", preference: .paged)
    }

    @MainActor
    func testDirectWebKitNavigationPreservesItsOwnFragmentWithoutAPendingCommand() async throws {
        try await assertPagedLink(heading: "Halo 世界", fragment: "halo-%E4%B8%96%E7%95%8C", preference: .paged,
                                  directNavigation: true)
    }

    @MainActor
    func testBrowserLinkPreservesEncodedPunctuationInAuthoredAnchor() async throws {
        try await assertPagedLink(heading: "Authored destination", fragment: "part%3A2%2Eend", preference: .paged,
                                  authoredAnchor: "part:2.end")
    }

    @MainActor
    func testBrowserLinkPreservesHeadingWhenAutomaticRoutesLargeMarkdownToMuPDF() async throws {
        try await assertPagedLink(heading: "Rocket 😀 End", fragment: "rocket-%F0%9F%98%80-end", preference: .automatic,
                                  large: true)
    }

    @MainActor
    private func assertPagedLink(heading: String, fragment: String, preference: MarkdownRenderer,
                                 authoredAnchor: String? = nil, large: Bool = false, directNavigation: Bool = false) async throws {
        let before = String(repeating: "Earlier paragraphs are outside the requested destination.\n\n", count: 80)
        let after = String(repeating: "Following paragraphs leave room to align the heading.\n\n", count: 40)
        let destination = authoredAnchor.map { "<a id=\"\($0)\"></a>" + heading + " DESTINATION65" }
            ?? "## " + heading + "\n\nDESTINATION65"
        var content = "# Beginning\n\n" + before + destination + "\n\n" + after
        if large {
            // Exercise the actual automatic size policy without laying out
            // megabytes of irrelevant glyphs. Markdown comments have no paint.
            content += "\n<!--" + String(repeating: "x", count: MarkdownRenderer.largeDocumentThreshold) + "-->\n"
        }
        try await withReader(targetContent: content, fragment: fragment, preference: preference) { state, coordinator, view, target in
            XCTAssertTrue(state.shouldOpenMarkupSibling(target))
            // A previous visit must not replace an explicit link destination.
            let old = ReadingPosition(page: 0, x: 0, y: 0, markdownRenderer: .paged)
            UserDefaults.standard.set(try JSONEncoder().encode(old), forKey: "position:" + target.path + ":markdown:paged")
            let sourceID = state.document?.id
            if directNavigation {
                let requested = try XCTUnwrap(URL(string: "B.md#" + fragment, relativeTo: coordinator.source.startURL)?.absoluteURL)
                XCTAssertNotNil(coordinator.pageIndex(requested))
                XCTAssertNil(coordinator.navigationRevision)
                view.load(URLRequest(url: requested))
            } else {
                try await clickLink("Target", state: state, coordinator: coordinator, view: view)
            }
            try await wait { !state.busy && state.document?.url == target && state.isNativeMarkdown }
            XCTAssertNotEqual(state.document?.id, sourceID)
            XCTAssertEqual(state.document?.markdownPreference, preference)
            XCTAssertEqual(state.currentPosition.anchor, "#" + fragment,
                           "WebKit's encoded fragment must reach the native opening position unchanged")
            XCTAssertNil(state.currentPosition.nativePassage)
            guard case .pages(let pages) = state.document?.content else { return XCTFail("Expected MuPDF Markdown pages") }
            let initial = state.currentPosition

            // ReaderView prepares the real MuPDF layout before restoring the
            // initial destination; exercise that same order on the loaded Pages.
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                        pageSize: CGSize(width: 420, height: 595))
            let restored = try await pages.restore(initial)
            let expectedFragment = "#" + (try XCTUnwrap(fragment.removingPercentEncoding))
            let expected = try await pages.resolve(expectedFragment)
            let destination = try XCTUnwrap(expected)
            XCTAssertGreaterThan(restored.page, 0, "The explicit destination must win over the saved first page")
            XCTAssertEqual(restored.page, destination.page)
            XCTAssertEqual(try XCTUnwrap(restored.y), try XCTUnwrap(destination.y), accuracy: 0.01)
            let destinationText = try await pages.text(restored.page)
            XCTAssertTrue(destinationText.contains(heading), "Resolved target text: \(destinationText.prefix(240))")
            XCTAssertNotNil(restored.nativePassage, "The resolved heading enters the existing source-position reflow path")
        }
    }

    @MainActor
    func testSameFileAndOrdinaryBrowserSiblingLinksKeepWebKitNavigation() async throws {
        let content = "# Beginning\n\n" + String(repeating: "Before the browser destination.\n\n", count: 80)
            + "## Browser Destination\n\n" + String(repeating: "After the browser destination.\n\n", count: 40)
        try await withReader(targetContent: content, fragment: "browser-destination", preference: .compatible) { state, coordinator, view, target in
            let originalID = state.document?.id
            XCTAssertFalse(state.shouldOpenMarkupSibling(target))
            try await clickLink("Local", state: state, coordinator: coordinator, view: view)
            let localTop = try await view.callAsyncJavaScript("return document.getElementById('source-heading').getBoundingClientRect().top",
                arguments: [:], in: nil, contentWorld: coordinator.scriptWorld)
            XCTAssertEqual(try XCTUnwrap(localTop as? Double), 0, accuracy: 2)
            XCTAssertEqual(state.document?.id, originalID)

            try await clickLink("Target", state: state, coordinator: coordinator, view: view)
            try await wait { coordinator.ready && coordinator.displayedURL?.lastPathComponent == "B.md" && state.document?.url == target }
            let siblingTop = try await view.callAsyncJavaScript("return document.getElementById('browser-destination').getBoundingClientRect().top",
                arguments: [:], in: nil, contentWorld: coordinator.scriptWorld)
            XCTAssertEqual(try XCTUnwrap(siblingTop as? Double), 0, accuracy: 2)
            XCTAssertEqual(state.document?.id, originalID)
            XCTAssertEqual(state.document?.markdownRenderer, .compatible)
            XCTAssertTrue(coordinator.isCurrent)
            XCTAssertNil(state.nativePDF)
        }
    }

    @MainActor
    private func clickLink(_ title: String, state: ReaderState, coordinator: BrowserReader.Coordinator,
                           view: WKWebView) async throws {
        let diagnostic = try await view.callAsyncJavaScript("""
            const link = [...document.querySelectorAll('a[href]')].find(link => link.textContent === title);
            return {href: link?.href ?? null, hrefType: typeof link?.href, tag: link?.tagName ?? null,
                attribute: link?.getAttribute('href') ?? null, base: document.baseURI, mainFrame: window === top,
                anchors: [...document.querySelectorAll('a')].slice(0, 4).map(a => ({id:a.id, href:a.getAttribute('href')}))};
            """, arguments: ["title": title], in: nil, contentWorld: coordinator.scriptWorld)
        let values = try XCTUnwrap(diagnostic as? [String: Any])
        XCTAssertEqual(values["hrefType"] as? String, "string", "\(values)")
        XCTAssertEqual(values["tag"] as? String, "A", "\(values)")
        XCTAssertEqual(values["mainFrame"] as? Bool, true, "\(values)")
        let requested = try XCTUnwrap((values["href"] as? String).flatMap(URL.init(string:)), "\(values)")
        XCTAssertNotNil(coordinator.pageIndex(requested), "The click must cross the indexed sibling policy branch: \(values)")
        let previousRevision = state.command.revision
        _ = try await view.callAsyncJavaScript("""
            [...document.querySelectorAll('a[href]')].find(link => link.textContent === title).click();
            """, arguments: ["title": title], in: nil, contentWorld: coordinator.scriptWorld)
        try await wait { state.command.revision > previousRevision }
        let command = state.command
        XCTAssertEqual(command.action, .href(requested.absoluteString))
        // This fixture mounts the native Coordinator without SwiftUI. Deliver
        // the click's emitted command as updateNSView does in the application.
        state.send(.none)
        coordinator.deliver(command, to: view)
        try await wait { state.command.revision > command.revision || state.error != nil || !coordinator.isCurrent }
        if let error = state.error { throw ReadError(error) }
        if coordinator.isCurrent {
            coordinator.deliver(state.command, to: view)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func withReader(targetContent: String, fragment: String, preference: MarkdownRenderer,
                            body: (ReaderState, BrowserReader.Coordinator, WKWebView, URL) async throws -> Void) async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("A.md").resolvingSymlinksInPath()
        let target = directory.url.appendingPathComponent("B.md").resolvingSymlinksInPath()
        let defaults = UserDefaults.standard
        let keys = ["useFixedPageUI", "disableHistory", "disableReadingState", "documentOpenHistory", "closedDocuments",
                    MarkdownRenderer.preferenceKey(for: target), MarkdownRenderer.layoutHintKey(for: target)]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        let recent = NSDocumentController.shared.recentDocumentURLs
        defer {
            ReaderFiles.setRecent(recent)
            for (key, value) in previous { defaults.set(value, forKey: key) }
            for file in [source, target] {
                for suffix in ["", ":markdown:paged", ":markdown:compatible"] {
                    defaults.removeObject(forKey: "position:" + file.path + suffix)
                }
            }
            withExtendedLifetime(directory) {}
        }
        defaults.set(false, forKey: "useFixedPageUI")
        defaults.set(false, forKey: "disableHistory")
        defaults.set(false, forKey: "disableReadingState")
        defaults.set(preference.rawValue, forKey: MarkdownRenderer.preferenceKey(for: target))
        let sourceContent = "# Start\n\n[Target](B.md#" + fragment + ")\n\n[Local](#source-heading)\n\n"
            + String(repeating: "Before the local destination.\n\n", count: 60)
            + "## Source Heading\n\n" + String(repeating: "Following local text.\n\n", count: 40)
        try sourceContent.write(to: source, atomically: true, encoding: .utf8)
        try targetContent.write(to: target, atomically: true, encoding: .utf8)
        let state = ReaderState(recordsHistory: false)
        state.document = try ReadingDocument.open(source, markdownRenderer: .compatible)
        state.flow = "continuous"; state.spread = false; state.rtl = false
        state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32
        state.pageMargins = nil; state.marginPresetSelection = nil
        state.theme = "light"; state.zoom = 1; state.userCSS = ""; state.useDocumentCSS = true
        guard case .browser(let browser) = state.document?.content else { throw ReadError("Expected browser source") }
        let coordinator = BrowserReader.Coordinator(state: state, source: browser)
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer {
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            state.close(); window.contentView = nil; window.close()
        }
        coordinator.load(view)
        try await wait { coordinator.ready || coordinator.readerError != nil }
        if let error = coordinator.readerError { throw error }
        try await body(state, coordinator, view, target)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard condition() else { throw ReadError("Markdown navigation timed out") }
    }
}
#endif
