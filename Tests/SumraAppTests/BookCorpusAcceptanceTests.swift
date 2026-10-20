#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import WebKit
import XCTest
@testable import Sumra

/// Opt-in hosted integration over a caller-owned, read-only local corpus.
/// This exercises reader owners and painted views, not physical user input.
final class BookCorpusAcceptanceTests: XCTestCase {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private let extensions: Set<String> = ["epub", "pdf", "cbz", "cbr", "cb7", "cbt", "zip", "rar", "tar", "7z", "ora", "txt", "md", "markdown", "chm", "mobi"]
    private let comicExtensions: Set<String> = ["cbz", "cbr", "cb7", "cbt", "zip", "rar", "tar", "7z", "ora"]

    private func corpus() throws -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_BOOK_CORPUS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SUMRA_BOOK_CORPUS_DIR to opt into local book acceptance")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        let inputs = try files.filter {
            guard extensions.contains($0.pathExtension.lowercased()) else { return false }
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !inputs.isEmpty else { throw Failure(description: "The configured corpus contains no supported books") }
        return inputs
    }

    private func checkpoint(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return ["bytes": values.fileSize ?? -1, "modified": values.contentModificationDate?.timeIntervalSince1970 ?? -1]
    }

    private func writeReport(_ report: [String: Any], suffix: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_BOOK_CORPUS_REPORT"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let destination = suffix.isEmpty ? url : url.deletingPathExtension().appendingPathExtension(suffix + ".json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
    }

    @MainActor
    func testAllDocumentWorkflows() async throws {
        _ = NSApplication.shared
        let files = try corpus()
        var results = [[String: Any]]()
        for file in files {
            let started = Date()
            var result: [String: Any] = ["file": file.lastPathComponent, "extension": file.pathExtension.lowercased()]
            do {
                let before = try checkpoint(file)
                result["sourceBefore"] = before
                try await workflow(file, result: &result)
                let after = try checkpoint(file)
                result["sourceAfter"] = after
                try require(NSDictionary(dictionary: before).isEqual(to: after), "Source size or modification time changed")
                result["passed"] = true
            } catch {
                result["passed"] = false; result["error"] = String(describing: error)
                XCTFail("\(file.lastPathComponent): \(error)")
            }
            result["seconds"] = Date().timeIntervalSince(started)
            results.append(result)
            // Checkpoint after every file, retaining earlier evidence if a later decoder crashes.
            try writeReport(["layer": "hosted-reader-integration", "inventoryCount": files.count,
                "inventoryByExtension": Dictionary(grouping: files, by: { $0.pathExtension.lowercased() }).mapValues(\.count),
                "files": results], suffix: "")
        }
    }

    @MainActor
    private func workflow(_ url: URL, result: inout [String: Any]) async throws {
        let state = ReaderState(recordsHistory: false)
        state.flow = "paged"; state.fit = "page"; state.zoom = 1; state.spread = false; state.cover = false
        state.theme = "light"; state.automaticLayout = false; state.fontSize = 17; state.lineHeight = 1.4
        state.font = "system"; state.margin = 32; state.userCSS = ""; state.pageMargins = nil
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        let started = Date()
        // Loading rereads preferences and format defaults. The explicit
        // position applies this harness's layout after that publication.
        state.openWithoutHistory(url, at: state.currentPosition)
        try await wait(state, host: host, reason: "Opening and first paint") {
            guard !state.busy, state.document != nil, state.count > 0 else { return false }
            if case .browser = state.document?.content {
                return try await self.browserIsDisplaying(state.browserView, page: state.page)
            }
            return self.ready(state)
        }
        result["flow"] = state.flow
        result["fit"] = state.fit
        try require(state.flow == "paged" && state.fit == "page" && !state.spread && !state.cover,
                    "The configured single-page layout was not applied after opening")
        result["firstPaintSeconds"] = Date().timeIntervalSince(started)
        result["initialCount"] = state.count
        var observations = [[String: Any]](), sampledText = ""
        for fraction in [0.0, 0.5, 1.0] {
            var target = Int(Double(max(0, state.count - 1)) * fraction)
            // A lazy book's global midpoint may still lie in its first laid-out
            // chapter. Sample the middle/final source chapter explicitly.
            if fraction > 0, case .pages(let pages) = state.document?.content {
                let table = await pages.chapterLayout
                if table.chapterCount > 1 {
                    let chapter = fraction == 1 ? table.chapterCount - 1 : table.chapterCount / 2
                    let count = try await pages.searchPageCount(chapter)
                    _ = state.applyChapterLayout(await pages.chapterLayout)
                    target = state.pageNumber(.init(chapter: chapter,
                        page: fraction == 1 ? max(0, count - 1) : count / 2))
                }
            }
            let location = state.pageLocation(target), navigationStarted = Date()
            state.send(.page(target))
            try await wait(state, host: host, reason: "Navigation to \(target)") {
                guard self.ready(state) else { return false }
                if case .pages = state.document?.content { return state.pageLocation(state.page) == location }
                // Text lines at the end clamp to the final visible viewport.
                if case .text = state.document?.content { return target == 0 ? state.page == 0 : state.page > 0 }
                guard state.page == target else { return false }
                return try await self.browserIsDisplaying(state.browserView, page: target)
            }
            let bitmap = try bitmap(host)
            try require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Hosted view has no rendered pixels")
            var observation: [String: Any] = ["fraction": fraction, "requested": target, "observed": state.page,
                "count": state.count, "seconds": Date().timeIntervalSince(navigationStarted),
                "flow": state.flow, "fit": state.fit,
                "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh]
            switch state.document?.content {
            case .pages(let pages):
                observation["chapter"] = state.pageLocation(state.page).chapter
                observation["chapterPage"] = state.pageLocation(state.page).page
                let text = try await pages.text(state.pageLocation(state.page))
                observation["textCharacters"] = text.count
                if sampledText.isEmpty { sampledText = text }
            case .text(let text): sampledText = text
            case .browser:
                if let view = state.browserView {
                    let text = try await browserText(view)
                    observation["textCharacters"] = text.count
                    if sampledText.isEmpty { sampledText = text }
                }
            case nil: throw Failure(description: "Document disappeared")
            }
            observations.append(observation)
            result["navigation"] = observations
        }
        result["navigation"] = observations
        // Empty outlines are valid for books without a source TOC. Exercise the
        // actual contents command and record both inventory and selected entry.
        let contentsStarted = Date()
        state.showContents = true
        state.send(.toc)
        try await wait(state, host: host, reason: "Contents") { !state.outlineBusy && self.ready(state) }
        result["contentsOpenSeconds"] = Date().timeIntervalSince(contentsStarted)
        result["outlineCount"] = state.outline.count
        if let entry = state.outline.first(where: { !$0.target.isEmpty }) {
            state.send(.href(entry.target))
            try await wait(state, host: host, reason: "Contents navigation") {
                guard self.ready(state) else { return false }
                if case .browser = state.document?.content {
                    if let page = entry.page, state.page != page { return false }
                    return try await self.browserIsDisplaying(state.browserView, page: state.page)
                }
                return true
            }
            result["outlineNavigation"] = entry.title
        }
        state.showContents = false
        try await wait(state, host: host, reason: "Closing Contents") { self.ready(state) }
        var textCapability = true, fixedLayout = false
        if case .pages(let pages) = state.document?.content {
            textCapability = await pages.hasText
            fixedLayout = try await pages.metadata()["EPUBLayout"] == "fixed"
        }
        result["textCapability"] = textCapability
        result["fixedLayoutEPUB"] = fixedLayout
        if !comicExtensions.contains(url.pathExtension.lowercased()) {
            let hasSampledText = !sampledText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Native text capability means an extraction API exists, not that
            // authored image-only pages contain glyphs. The existing metadata
            // owner identifies fixed EPUB; do not infer it from a filename.
            if !hasSampledText {
                try require(!textCapability || fixedLayout || url.pathExtension.lowercased() == "pdf",
                    "Text book produced no text at sampled locations")
            }
            let query = hasSampledText ? try searchToken(sampledText) : "SUMRA_CORPUS_ABSENT_QUERY"
            let searchStarted = Date()
            state.status = ""
            state.send(.find(query))
            if hasSampledText {
                try await wait(state, host: host, reason: "First search selection") {
                    // Keep the same realm observation as the completed-count
                    // check: an occluded hosted WKWebView otherwise throttles
                    // the cross-topic scan while no first hit exists yet.
                    if case .browser = state.document?.content,
                       !(try await self.browserIsDisplaying(state.browserView, page: state.page)) { return false }
                    return state.selectedSearchTarget != nil && self.ready(state)
                }
                result["firstSearchSelectionSeconds"] = Date().timeIntervalSince(searchStarted)
            }
            try await wait(state, host: host, reason: "Search selection and count") {
                // Search can navigate to another topic. Native loading flags
                // alone can still describe its predecessor's painted surface.
                if case .browser = state.document?.content,
                   !(try await self.browserIsDisplaying(state.browserView, page: state.page)) { return false }
                if !hasSampledText {
                    return state.status == L("No matches") && !state.searchCounting &&
                        state.searchResults.isEmpty && state.selectedSearchTarget == nil && self.ready(state)
                }
                return state.selectedSearchTarget != nil && !state.searchResults.isEmpty && !state.searchCounting && self.ready(state)
            }
            result["search"] = ["classification": hasSampledText ? "searchable-text" : "no-searchable-text-at-sampled-locations",
                "query": query, "results": state.searchResults.count, "countText": state.searchCountText,
                "completed": !state.searchCounting, "selected": state.selectedSearchTarget ?? "",
                "seconds": Date().timeIntervalSince(searchStarted)]
        }
        try require(state.error == nil, state.error ?? "Reader failed")
    }

    @MainActor
    private func ready(_ state: ReaderState) -> Bool {
        switch state.document?.content {
        case .pages(let pages): return RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
        case .text: return state.readerFocusView != nil && !state.outlineBusy
        case .browser:
            return state.count > 0 && state.browserView?.isLoading == false &&
                (state.browserView?.navigationDelegate as? BrowserReader.Coordinator)?.ready == true
        case nil: return false
        }
    }

    @MainActor
    private func wait(_ state: ReaderState, host: NSView, reason: String, until condition: () async throws -> Bool) async throws {
        // A configurable stall watchdog, not a reading-performance threshold.
        let timeout = ProcessInfo.processInfo.environment["SUMRA_BOOK_CORPUS_TIMEOUT"].flatMap(Double.init) ?? 120
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // Let representable updates consume the issued command before
            // accepting an already painted surface from its predecessor.
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
            _ = try bitmap(host)
            if let error = state.error { throw Failure(description: "\(reason): \(error)") }
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        throw Failure(description: "\(reason) stalled; page=\(state.page), count=\(state.count), status=\(state.status), search=\(state.searchCountText)")
    }

    @MainActor
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "No hosted bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func browserText(_ view: WKWebView) async throws -> String {
        let result = try await view.evaluateJavaScript("document.body.innerText")
        return result as? String ?? ""
    }

    @MainActor
    private func browserIsDisplaying(_ view: WKWebView?, page: Int) async throws -> Bool {
        guard let view, !view.isLoading else { return false }
        // Inspect the loaded realm rather than WKWebView.url, which can already
        // identify an incoming topic while the previous DOM remains visible.
        return try await view.callAsyncJavaScript("""
        const config = window.sumraDocument;
        if (!config || typeof window.leafCommand !== 'function' || document.readyState !== 'complete') return false;
        if (document.fonts && document.fonts.status !== 'loaded') return false;
        const target = config.pages?.[page];
        if (!target) return false;
        const actual = new URL(document.location.href).pathname;
        const expected = new URL(target, document.location.href).pathname;
        return config.chm ? actual.toLowerCase() === expected.toLowerCase() : actual === expected;
        """, arguments: ["page": page], in: nil, contentWorld: .world(name: "SumraMarkup")) as? Bool == true
    }

    private func searchToken(_ text: String) throws -> String {
        guard let range = text.range(of: #"[\p{L}\p{N}]{3,}"#, options: .regularExpression) else {
            throw Failure(description: "No searchable token in extracted text")
        }
        return String(text[range].prefix(12))
    }

    func testAllComicPages() async throws {
        guard ProcessInfo.processInfo.environment["SUMRA_BOOK_CORPUS_ALL_COMIC_PAGES"] == "1" else {
            throw XCTSkip("Set SUMRA_BOOK_CORPUS_ALL_COMIC_PAGES=1 for every-page comic decoding")
        }
        let files = try corpus().filter { comicExtensions.contains($0.pathExtension.lowercased()) }
        var results = [[String: Any]]()
        for file in files {
            let started = Date()
            var result: [String: Any] = ["file": file.lastPathComponent]
            do {
                let before = try checkpoint(file), document = try ReadingDocument.open(file)
                guard case .pages(let pages) = document.content else { throw Failure(description: "Comic did not use Pages") }
                let count = await pages.count
                try require(count > 0, "Comic has no pages")
                result["pages"] = count
                var decoded = 0
                for page in 0..<count {
                    do {
                        let image = try await pages.image(.init(page: page), width: 800)
                        try require(image.width > 0 && image.height > 0, "Decoded comic image is empty")
                        decoded += 1
                    } catch {
                        XCTFail("\(file.lastPathComponent), page \(page): \(error)")
                        var failures = result["pageFailures"] as? [[String: Any]] ?? []
                        failures.append(["page": page, "error": String(describing: error)])
                        result["pageFailures"] = failures
                    }
                }
                result["decoded"] = decoded
                let after = try checkpoint(file)
                try require(NSDictionary(dictionary: before).isEqual(to: after), "Comic source changed")
                result["passed"] = decoded == count
            } catch {
                result["passed"] = false; result["error"] = String(describing: error)
                XCTFail("\(file.lastPathComponent): \(error)")
            }
            result["seconds"] = Date().timeIntervalSince(started)
            results.append(result)
            try writeReport(["layer": "internal-pages-every-comic-page-decode", "files": results], suffix: "comics")
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
}
#endif
