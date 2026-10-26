#if os(macOS)
import AppKit
import Combine
import CryptoKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Explicit local opt-in: the original B03 book remains outside the repository.
/// Timings describe this machine/run; no universal responsiveness threshold is asserted.
@MainActor
final class HighVolumeSearchTests: XCTestCase {
    func testHostedFullResultsPublicationAndReplacementRemainInteractive() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_HIGH_VOLUME_SEARCH_BOOK"], !path.isEmpty else {
            throw XCTSkip("Set SUMRA_HIGH_VOLUME_SEARCH_BOOK to the original B03 EPUB")
        }
        let source = URL(fileURLWithPath: path)
        let expectedSHA = "c300796c73901957d6284ba76e4b898768d4f3c241d9396f72841811aa79852c"
        let originalSHA = try sha256(source)
        XCTAssertEqual(originalSHA, expectedSHA, "The frozen same-layout oracle belongs to the unchanged B03 original")
        guard originalSHA == expectedSHA else { return }
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before this opt-in integration test") }
        let reportDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/issue42/third-pass-publication", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        var report: [String: Any] = ["source": source.path, "sha256Before": originalSHA, "query": "the",
            "wholeWord": true, "expectedCount": 100_144, "oracleSourceAnchorCount": 100_144,
            "oracle": "build/issue42/third-pass-performance/baseline-host779x590-source-keys.json",
            "oracleBoundary": "779x590 with pinned reader CSS. Existing glyph EOL-hyphen joining changes whole-word matches when compounds wrap; the distinct 736x536 bare-CSS oracle remains 100145.",
            "timerIntervalSeconds": 0.005, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "timingBoundary": "Hosted count includes native search, Swift decoding, result projection, publication and mounted NSTableView layout. Native-only time is not separately observable here."]
        func checkpoint(_ stage: String) throws {
            report["checkpoint"] = stage
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportDirectory.appendingPathComponent("hosted-publication.json"), options: .atomic)
        }
        var passed = false
        defer {
            report["passed"] = passed
            do {
                let after = try sha256(source)
                report["sha256After"] = after
                XCTAssertEqual(after, originalSHA, "The input book must remain unchanged")
                try checkpoint("final")
            } catch { XCTFail("Cannot preserve high-volume search evidence: \(error)") }
        }

        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let settings: [String: Any] = ["findFloating": false, "sidebarRight": false, "sidebarWidth": 220.0,
            "disableReadingState": true, "flow": "paged", "spread": false, "cover": false, "rtl": false,
            "theme": "light", "font": "system", "fontSize": 17.0, "lineHeight": 1.4, "margin": 32.0,
            "userCSS": "", "useDocumentCSS": true, "formatDefaults": "{}"]
        let previousDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // ReaderView persists its splitter measurement even with history disabled.
        let domainName = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let oldSidebarWidth = defaults.persistentDomain(forName: domainName)?["sidebarWidth"]
        defaults.setVolatileDomain(previousDomain.merging(settings) { _, fixture in fixture }, forName: UserDefaults.argumentDomain)
        defer {
            defaults.set(oldSidebarWidth, forKey: "sidebarWidth")
            defaults.setVolatileDomain(previousDomain, forName: UserDefaults.argumentDomain)
        }
        let document = try ReadingDocument.open(source, deferReflowLayout: true)
        guard case .pages(let pages) = document.content else { return XCTFail("B03 must use the native book reader") }
        let prepared = try await pages.prepare()
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
        state.flow = "paged"; state.fit = "page"; state.zoom = 1; state.spread = false; state.cover = false
        state.automaticLayout = false; state.freePan = false; state.uniformPageWidth = false
        state.trimEmptyMargins = false; state.landscapeAsSpread = false; state.rtl = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "system"; state.theme = "light"; state.margin = 32
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil; state.scrollbarMode = "hidden"
        state.showContents = false; state.showAI = false; state.searchCaseSensitive = false; state.searchWholeWord = true
        _ = state.applyChapterLayout(await pages.chapterLayout)
        state.showFindPanel()
        let host = NSHostingView(rootView: ReaderView(state: state))
        // The open Find panel reserves the 22-point search-session status row.
        // Keep the reader viewport at the frozen oracle's 779x590 geometry.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 672),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let clip = state.readerScrollView?.contentView,
               let bitmap = clip.bitmapImageRepForCachingDisplay(in: clip.bounds) {
                clip.cacheDisplay(in: clip.bounds, to: bitmap)
            }
        }
        func wait(_ reason: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(300)
            repeat {
                paint()
                if predicate() { return }
                if let error = state.error {
                    report["waitFailure"] = "\(reason): \(error)"
                    report["resultCountAtWaitFailure"] = state.searchResults.count
                    try checkpoint("wait-error")
                    throw ReadError("\(reason): \(error)")
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            } while Date() < deadline
            report["waitFailure"] = "Timed out: \(reason)"
            report["resultCountAtWaitFailure"] = state.searchResults.count
            report["countingAtWaitFailure"] = state.searchCounting
            report["statusAtWaitFailure"] = state.status
            try checkpoint("wait-timeout")
            throw ReadError("Timed out: \(reason); page=\(state.page), count=\(state.searchCountText)")
        }
        func settle() async throws {
            for _ in 0..<50 { paint(); try await Task.sleep(nanoseconds: 5_000_000) }
        }
        try await wait("Initial reader and visible results sidebar") {
            state.readerFocusView != nil && state.readerScrollView != nil && state.showSearchResults && state.count > 0
        }
        try await settle()
        report["resultsSidebarMounted"] = state.showSearchResults && !defaults.bool(forKey: "findFloating")
        report["windowSize"] = [window.frame.width, window.frame.height]
        let pageBounds = try await pages.bounds(state.pageLocation(state.page))
        let preparedPageSize = await pages.layoutPageSize
        let requestedPageSize = try XCTUnwrap(preparedPageSize)
        // These are the frozen glyph oracle's actual layout inputs, not cover
        // bounds. Changing line wrapping can join an EOL hyphen in compounds
        // such as "state-of-the-art", changing whole-word results without loss.
        let effectiveCSSSHA = SHA256.hash(data: Data(state.effectiveUserCSS.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(requestedPageSize.width, 779, "The same-layout count oracle requires its measured width")
        XCTAssertEqual(requestedPageSize.height, 590, "The same-layout count oracle requires its measured height")
        XCTAssertEqual(effectiveCSSSHA, "e1515caffe5131e06b9f376af7138f0bb61a886c7d6898c10440aa1569befbd6",
            "The reader CSS must match the frozen glyph oracle")
        report["nativeLayout"] = ["width": pageBounds.width, "height": pageBounds.height,
            "requestedWidth": requestedPageSize.width, "requestedHeight": requestedPageSize.height,
            "effectiveUserCSS": state.effectiveUserCSS, "effectiveUserCSSSHA256": effectiveCSSSHA, "resolvedTheme": state.resolvedTheme,
            "useDocumentCSS": state.useDocumentCSS, "font": state.font, "fontSize": state.fontSize,
            "lineHeight": state.lineHeight, "margin": state.margin,
            "pageMargins": state.pageMargins.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data(), as: UTF8.self) } ?? "nil"]
        try checkpoint("initial-layout-before-search")

        let pulse = MainActorSearchPulse()
        let requestedStarted = ProcessInfo.processInfo.systemUptime
        var countingStarted: TimeInterval?, countingFinished: TimeInterval?
        var publications = [[String: Any]](), transitions = [[String: Any]]()
        pulse.start()
        let countingObserver = state.$searchCounting.sink { counting in
            let now = ProcessInfo.processInfo.systemUptime
            if counting, countingStarted == nil { countingStarted = now }
            if !counting, countingStarted != nil { countingFinished = now }
            transitions.append(["seconds": now - requestedStarted, "counting": counting,
                "resultsBeforeSetter": state.searchResults.count])
            report["countingTransitions"] = transitions
        }
        let resultsObserver = state.$searchResults.sink { results in
            publications.append(["seconds": ProcessInfo.processInfo.systemUptime - requestedStarted,
                "count": results.count, "countingAtPublication": state.searchCounting])
            report["publications"] = publications
            report["latestPublishedCount"] = results.count
            report["mainActorPulse"] = pulse.report
            do { try checkpoint("search-publication") }
            catch { XCTFail("Cannot checkpoint publication diagnostics: \(error)") }
        }
        defer {
            countingObserver.cancel(); resultsObserver.cancel(); pulse.stop()
            report["mainActorPulse"] = pulse.report
            report["publications"] = publications
            report["countingTransitions"] = transitions
            report["finalObservedResultCount"] = state.searchResults.count
            report["finalObservedSearchCounting"] = state.searchCounting
            report["finalObservedError"] = state.error ?? ""
        }
        state.send(.find("the"))
        try await wait("Complete B03 count and publication") {
            countingStarted != nil && countingFinished != nil && state.findQuery == "the" &&
                !state.searchCounting && !state.searchResults.isEmpty && state.status == state.searchCountText
        }
        // Include deferred NSTableView reconciliation after the final @Published setter.
        try await settle()
        let updatedPageSize = await pages.layoutPageSize
        let settledPageSize = try XCTUnwrap(updatedPageSize)
        XCTAssertEqual(settledPageSize.width, requestedPageSize.width,
            "Search publication must not change the measured reader width")
        XCTAssertEqual(settledPageSize.height, requestedPageSize.height,
            "Search publication must not change the measured reader height")
        report["layoutAfterSearch"] = ["width": settledPageSize.width, "height": settledPageSize.height]
        pulse.stop(); countingObserver.cancel(); resultsObserver.cancel()
        report["mainActorPulse"] = pulse.report
        report["publications"] = publications
        report["countingSeconds"] = countingFinished.map { $0 - (countingStarted ?? $0) }
        let actualCount = state.searchResults.count
        report["resultCount"] = actualCount
        report["countingAtCompletion"] = state.searchCounting
        report["queryAtCompletion"] = state.findQuery
        report["completedSearchSeconds"] = ProcessInfo.processInfo.systemUptime - requestedStarted
        report["countingTransitions"] = transitions
        try checkpoint("complete-count-before-oracle-assertion")
        XCTAssertEqual(actualCount, 100_144)
        let lastTarget = try XCTUnwrap(state.searchResults.last?.target)
        report["lastTarget"] = lastTarget
        let targetParts = lastTarget.split(separator: ":")
        XCTAssertEqual(targetParts.count, 3)
        let lastPage = try XCTUnwrap(targetParts.count == 3 ? Int(targetParts[1]) : nil)
        let lastIndex = try XCTUnwrap(targetParts.count == 3 ? Int(targetParts[2]) : nil)
        state.navigate(.href(lastTarget))
        try await wait("Last result navigates and paints") {
            state.selectedSearchTarget == lastTarget && state.searchCountText == "\(actualCount) / \(actualCount)" &&
                state.page == lastPage && RasterReader.highlightedMatch(in: state.readerFocusView)?.index == lastIndex &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page))
        }
        report["lastResultPage"] = state.page
        report["lastResultCountText"] = state.searchCountText

        // Start a fresh count, exercise reading while it runs, then replace it.
        state.send(.find(""))
        try await wait("Clear first search") { !state.searchCounting && state.searchResults.isEmpty }
        state.navigate(.page(0))
        try await wait("Return to book start") { state.page == 0 }
        state.send(.find("the"))
        try await wait("Second count has partial results") {
            state.searchCounting && !state.searchResults.isEmpty && state.searchResults.count < actualCount
        }
        let partialCount = state.searchResults.count, readingPage = min(state.count - 1, state.page + 1)
        let readingStarted = ProcessInfo.processInfo.systemUptime
        state.navigate(.page(readingPage))
        try await wait("Reading command progresses during search") {
            state.page == readingPage && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                location: state.pageLocation(state.page))
        }
        report["readingDuringCount"] = ["partialCountAtCommand": partialCount, "page": readingPage,
            "seconds": ProcessInfo.processInfo.systemUptime - readingStarted, "countingWhenPainted": state.searchCounting]
        XCTAssertTrue(state.searchCounting || state.searchResults.count == actualCount,
            "Reading must preserve the running or completed count")
        report["cancellationIssuedWhileCounting"] = state.searchCounting
        let absent = "SUMRAHIGHVOLUMEABSENTQUERY9A4E73"
        let replacementStarted = ProcessInfo.processInfo.systemUptime
        state.send(.find(absent))
        try await wait("Replacement cancels old count and completes") {
            state.findQuery == absent && !state.searchCounting && state.searchResults.isEmpty &&
                state.selectedSearchTarget == nil && state.status == L("No matches")
        }
        try await settle()
        XCTAssertTrue(state.searchResults.isEmpty, "A cancelled old count must not republish stale hits")
        report["replacement"] = ["query": absent, "seconds": ProcessInfo.processInfo.systemUptime - replacementStarted,
            "resultsAfterSettling": state.searchResults.count, "selectedTargetCleared": state.selectedSearchTarget == nil]
        XCTAssertNil(state.error)
        passed = actualCount == 100_144
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class MainActorSearchPulse {
    private var timer: Timer?
    private var last: TimeInterval = 0
    private var started: TimeInterval = 0
    private var stopped: TimeInterval?
    private var pulses = 0
    private var maximumGap: TimeInterval = 0
    private var gapsOver50ms = 0
    private var gapsOver100ms = 0
    func start() {
        started = ProcessInfo.processInfo.systemUptime; last = started
        timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime, gap = now - last
        maximumGap = max(maximumGap, gap); last = now; pulses += 1
        if gap > 0.05 { gapsOver50ms += 1 }
        if gap > 0.1 { gapsOver100ms += 1 }
    }
    func stop() {
        if stopped == nil { stopped = ProcessInfo.processInfo.systemUptime }
        timer?.invalidate(); timer = nil
    }
    var report: [String: Any] {
        ["pulses": pulses, "maximumGapSeconds": maximumGap, "gapsOver50ms": gapsOver50ms,
         "gapsOver100ms": gapsOver100ms, "observedSeconds": (stopped ?? ProcessInfo.processInfo.systemUptime) - started]
    }
}
#endif
