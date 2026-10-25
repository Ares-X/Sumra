#if os(macOS)
import AppKit
import Combine
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class FullSearchResponsivenessTests: XCTestCase {
    private let occurrenceCount = 1206

    private func fixture(_ directory: TemporaryDirectory) throws -> Pages {
        let url = directory.url.appendingPathComponent("OneLongSection.md")
        // A single authored paragraph prevents chapter boundaries from making
        // a source walker appear cooperative while one long section still stalls.
        let text = (0..<occurrenceCount).map {
            "needle occurrence \($0) has ordinary reading text around it. "
        }.joined() + "finalonly marker.\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try Pages(url, format: .markdown, deferReflowLayout: true)
    }

    private func layout(_ pages: Pages, fontSize: Double = 17) async throws {
        _ = try await pages.relayout(fontSize: fontSize, lineHeight: 1.4, margin: 16,
            font: "system", theme: "light", pageSize: CGSize(width: 320, height: 220))
    }

    private func nativeReference(_ pages: Pages) throws -> NativeFile {
        let file = try NativeFile(pages.pdfSourceURL, engine: .mupdf, deferReflowLayout: true)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "system", theme: "light",
                              pageSize: CGSize(width: 320, height: 220))
        return file
    }

    func testHostedInitialFindFinishesAfterFontAndViewportReflow() async throws {
        try await hostedInitialFind(replacingQueryDuringReflow: false)
    }

    func testHostedDifferentQueryQueuedAfterReflowClearFinishesOnCommittedSurface() async throws {
        try await hostedInitialFind(replacingQueryDuringReflow: true)
    }

    private func hostedInitialFind(replacingQueryDuringReflow: Bool) async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        try await layout(pages)
        let reference = try nativeReference(pages)
        let expectedSource = try XCTUnwrap(reference.markdownDocumentMatches("finalonly", options: .init(),
                                                                            startPage: 0).first?.source)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: pages.pdfSourceURL, content: .pages(pages),
                                         markdownPreference: .paged, markdownRenderer: .paged)
        state.reflowable = true; state.searchable = true
        state.fontSize = 17; state.lineHeight = 1.4; state.margin = 16; state.font = "system"; state.theme = "light"
        state.flow = "paged"; state.fit = "page"; state.zoom = 1
        state.spread = false; state.cover = false; state.automaticLayout = false
        state.uniformPageWidth = false; state.trimEmptyMargins = false; state.landscapeAsSpread = false
        state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true; state.scrollbarMode = "hidden"
        let initialSize = replacingQueryDuringReflow ? CGSize(width: 320, height: 220) : CGSize(width: 620, height: 400)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 16, font: "system", theme: "light",
                                     userCSS: state.effectiveUserCSS, pageSize: initialSize)
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: initialSize),
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
        func wait(_ reason: String, until predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !predicate(), Date() < deadline {
                if let error = state.error { throw ReadError("\(reason): \(error)") }
                paint(); try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNil(state.error)
            XCTAssertTrue(predicate(), "\(reason): \(state.searchCountText)")
        }
        try await wait("Mounted initial reader") { state.readerFocusView != nil && state.readerScrollView != nil }
        let revision = state.renderRevision
        var reflowRequested = false, replacementArmed = false, replacementQueued = false
        var replacementRequestedDuringStyle = false, replacementDispatchedAfterCommit = false
        var reflowTask: Task<Void, Never>?
        let selectionSubscription = state.$selectedText.sink { text in
            guard replacingQueryDuringReflow, replacementArmed, text.isEmpty else { return }
            // style captures searchRevision immediately before clearing this
            // selection, then awaits the decoder before committing its surface.
            // The request arrives during style, but ReaderState deliberately
            // keeps its command queued until that style acknowledges completion.
            replacementArmed = false; replacementQueued = true
            let styleRevision = state.command.revision
            let styleOwnsSurface = state.command.action == .style && state.renderRevision == revision
            state.send(.find("finalonly"))
            replacementRequestedDuringStyle = styleOwnsSurface && state.command.revision == styleRevision &&
                state.command.action == .style && state.findQuery == "finalonly"
        }
        let commandSubscription = state.$command.sink { command in
            if replacementQueued, case .find(let query, _, _, _, _) = command.action, query == "finalonly" {
                replacementDispatchedAfterCommit = state.renderRevision > revision
            }
        }
        let subscription = state.$searchCounting.sink { counting in
            guard counting, !reflowRequested else { return }
            reflowRequested = true
            reflowTask = Task { @MainActor in
                // Deliver real typography and viewport commands while the
                // initial find is entering its cooperative native work.
                await Task.yield()
                if replacingQueryDuringReflow {
                    state.selectedText = "Selection before the requested reflow"
                    replacementArmed = true
                }
                state.fontSize = 23; state.send(.style)
                if !replacingQueryDuringReflow {
                    window.setContentSize(CGSize(width: 560, height: 360))
                    state.send(.style)
                }
            }
        }
        defer { subscription.cancel(); selectionSubscription.cancel(); commandSubscription.cancel(); reflowTask?.cancel() }
        state.send(.find(replacingQueryDuringReflow ? "absentfromsource" : "finalonly"))
        try await wait("First find after reflow") {
            state.renderRevision > revision && !state.searchCounting && state.searchResults.count == 1 &&
                RasterReader.highlightedMatch(in: state.readerFocusView)?.source == expectedSource
        }
        XCTAssertTrue(reflowRequested)
        if replacingQueryDuringReflow {
            XCTAssertTrue(replacementQueued, "The new query must be queued after the style owner's search-generation capture")
            XCTAssertTrue(replacementRequestedDuringStyle, "The different query must be requested while the style command still owns the outgoing surface")
            XCTAssertTrue(replacementDispatchedAfterCommit, "The command queue must dispatch the new query after the style commits its surface")
        }
        XCTAssertEqual(state.fontSize, 23)
        let highlighted = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
        let exact = try await pages.markdownDocumentMatches("finalonly", options: .init(), startPage: highlighted.page,
                                                            after: expectedSource, inclusive: true)
        XCTAssertEqual(highlighted, exact.first)
        XCTAssertFalse(highlighted.rects.isEmpty)
        XCTAssertEqual(state.selectedSearchTarget, state.searchResults.first?.target)
        XCTAssertEqual(state.searchCountText, "1 / 1")
        XCTAssertNil(state.error)
    }

    func testInteractiveFindSessionsAllowReadingBeforeMissForwardAndBackwardCompletion() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        let file = try nativeReference(pages)
        for (query, backwards) in [("absentfromsource", false), ("finalonly", false), ("needle", true)] {
            let expected = try file.markdownDocumentMatches(query, options: .init(), startPage: 0,
                                                           backwards: backwards)
            let search = try file.beginMarkdownFind(query, options: .init(), startPage: 0, backwards: backwards)
            defer { file.closeMarkdownSearch(search) }
            var step = try file.stepMarkdownSearch(search)
            XCTAssertFalse(step.complete, "The one-section fixture must require more than one native work quantum")
            XCTAssertTrue(step.matches.isEmpty)
            XCTAssertFalse(try XCTUnwrap(file.text(0)).isEmpty)
            XCTAssertGreaterThan(try file.image(0, width: 320).width, 0)
            // A real reading operation returned while this same production
            // find session was unfinished, without timing or test-only hooks.
            var actual = step.matches
            while !step.complete {
                await Task.yield()
                step = try file.stepMarkdownSearch(search)
                actual += step.matches
            }
            XCTAssertEqual(actual, expected, "Interactive stepping must preserve exact source and geometry")
        }
    }

    func testPagesInteractiveFindPreservesSourceDirectionWrapAndCallerBudgets() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        try await layout(pages)
        let file = try nativeReference(pages)
        let first = try XCTUnwrap(file.markdownDocumentMatches("needle", options: .init(), startPage: 0).first)
        let count = await pages.count
        let last = try XCTUnwrap(file.markdownDocumentMatches("needle", options: .init(),
                                                             startPage: count - 1, backwards: true).first)
        let forward = try await pages.markdownDocumentMatches("needle", options: .init(), startPage: 0,
                                                               after: first.source, maximum: 3)
        XCTAssertEqual(forward, try file.markdownDocumentMatches("needle", options: .init(), startPage: 0,
                                                                 after: first.source, maximum: 3))
        let backwards = try await pages.markdownDocumentMatches("needle", options: .init(),
            startPage: count - 1, after: last.source, backwards: true, maximum: 3, inclusive: true)
        XCTAssertEqual(backwards, try file.markdownDocumentMatches("needle", options: .init(),
            startPage: count - 1, after: last.source, backwards: true, maximum: 3, inclusive: true))
        let wrapped = try await pages.markdownDocumentMatches("needle", options: .init(),
            startPage: count - 1, after: last.source)
        XCTAssertEqual(wrapped.first?.source, first.source)
        let absent = try await pages.markdownDocumentMatches("absentfromsource", options: .init(), startPage: 0)
        XCTAssertTrue(absent.isEmpty)
        let limited = try await pages.markdownDocumentMatches("needle", options: .init(), startPage: 0,
                                                              counting: true, maximum: 1005)
        XCTAssertEqual(limited.count, 1005)
        let unlimited = try await pages.markdownDocumentMatches("needle", options: .init(), startPage: 0,
                                                                counting: true, maximum: nil)
        XCTAssertEqual(unlimited.count, occurrenceCount)
        XCTAssertEqual(unlimited.last?.source, last.source)
    }

    func testInteractiveFindCancellationAndReflowCloseItsNativeSession() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        let file = try nativeReference(pages)
        let cancelled = Task {
            let search = try file.beginMarkdownFind("absentfromsource", options: .init(), startPage: 0)
            defer { file.closeMarkdownSearch(search) }
            XCTAssertFalse(try file.stepMarkdownSearch(search).complete)
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try file.stepMarkdownSearch(search)
        }
        do { try await cancelled.value; XCTFail("An unfinished initial find must stop after cancellation") }
        catch is CancellationError { }
        XCTAssertGreaterThan(try file.image(0, width: 320).height, 0)
        let search = try file.beginMarkdownFind("finalonly", options: .init(), startPage: 0)
        defer { file.closeMarkdownSearch(search) }
        XCTAssertFalse(try file.stepMarkdownSearch(search).complete)
        _ = try file.relayout(fontSize: 23, lineHeight: 1.4, font: "system", theme: "light",
                              pageSize: CGSize(width: 320, height: 220))
        do { _ = try file.stepMarkdownSearch(search); XCTFail("Reflow must retire the paused find before reusing flow pointers") }
        catch is CancellationError { }
        let fresh = try file.beginMarkdownFind("finalonly", options: .init(), startPage: 0)
        defer { file.closeMarkdownSearch(fresh) }
        var actual = [RasterMatch](), complete = false
        while !complete {
            let batch = try file.stepMarkdownSearch(fresh)
            actual += batch.matches; complete = batch.complete
            if !complete { await Task.yield() }
        }
        XCTAssertEqual(actual, try file.markdownDocumentMatches("finalonly", options: .init(), startPage: 0))
    }

    func testFullCountAllowsReadingNavigationRenderingAndMainActorWorkBeforeCompletion() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        try await layout(pages)
        let pageCount = await pages.count
        XCTAssertGreaterThan(pageCount, 1)
        let referenceFinal = try await pages.markdownDocumentMatches("needle", options: .init(),
            startPage: pageCount - 1, backwards: true)
        let expectedFinal = try XCTUnwrap(referenceFinal.first)
        var all = [RasterMatch](), publications = 0, readDuringCount = false, mainActorRan = false
        var completed = false
        try await pages.markdownDocumentMatchBatches("needle", options: .init()) { batch, _ in
            all += batch; publications += 1
            guard !readDuringCount else { return }
            XCTAssertFalse(completed)
            XCTAssertLessThan(all.count, self.occurrenceCount,
                              "The read must run during an unfinished full count")
            let heartbeat = Task { @MainActor in
                await Task.yield()
                mainActorRan = true
            }
            let text = try await pages.text(PageLocation(chapter: 0, page: 0))
            XCTAssertTrue(text.contains("needle"))
            let position = try await pages.advance(.init(chapter: 0, page: 0), by: 1)
            XCTAssertEqual(position.page, 1)
            let image = try await pages.image(PageLocation(chapter: 0, page: 1), width: 320)
            XCTAssertGreaterThan(image.width, 0)
            await heartbeat.value
            XCTAssertFalse(completed)
            readDuringCount = true
        }
        completed = true
        XCTAssertTrue(readDuringCount)
        XCTAssertTrue(mainActorRan)
        XCTAssertGreaterThan(publications, 1)
        XCTAssertEqual(all.count, occurrenceCount)
        XCTAssertEqual(Set(all.compactMap(\.source)).count, occurrenceCount)
        XCTAssertTrue(all.allSatisfy { !$0.rects.isEmpty && $0.fragments?.isEmpty == false })
        XCTAssertEqual(all.last, expectedFinal,
                       "The final result must retain the native navigation source and all highlight geometry")
    }

    func testCancellationDropsActiveCountAndReplacementQueryHasOnlyItsOwnResults() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        try await layout(pages)
        var oldResults = [RasterMatch](), oldPublications = 0
        let counting = Task {
            try await pages.markdownDocumentMatchBatches("needle", options: .init()) { batch, _ in
                oldResults += batch; oldPublications += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await counting.value
            XCTFail("Cancelling an unfinished count must terminate it")
        } catch is CancellationError { }
        XCTAssertEqual(oldPublications, 1)
        XCTAssertFalse(oldResults.isEmpty)
        XCTAssertLessThan(oldResults.count, occurrenceCount)
        let image = try await pages.image(PageLocation(chapter: 0, page: 0), width: 320)
        XCTAssertGreaterThan(image.height, 0)
        var replacement = [RasterMatch]()
        try await pages.markdownDocumentMatchBatches("finalonly", options: .init()) { batch, _ in
            replacement += batch
        }
        XCTAssertEqual(replacement.count, 1)
        XCTAssertTrue(try XCTUnwrap(replacement.first).context.contains("finalonly"))
        XCTAssertEqual(oldPublications, 1, "The cancelled count must never resume publication")
    }

    func testReflowInvalidatesPausedCountAndFreshCountRetainsFinalSourceWithNewGeometry() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pages = try fixture(directory)
        try await layout(pages)
        let pageCount = await pages.count
        let previous = try await pages.markdownDocumentMatches("needle", options: .init(),
            startPage: pageCount - 1, backwards: true)
        let final = try XCTUnwrap(previous.first)
        var stalePublications = 0
        do {
            try await pages.markdownDocumentMatchBatches("needle", options: .init()) { _, _ in
                stalePublications += 1
                try await self.layout(pages, fontSize: 23)
            }
            XCTFail("Reflow must invalidate the count before its native pointers can be reused")
        } catch is CancellationError { }
        XCTAssertEqual(stalePublications, 1)
        var refreshed = [RasterMatch]()
        try await pages.markdownDocumentMatchBatches("needle", options: .init()) { batch, _ in
            refreshed += batch
        }
        XCTAssertEqual(refreshed.count, occurrenceCount)
        let refreshedFinal = try XCTUnwrap(refreshed.last)
        XCTAssertEqual(refreshedFinal.source, final.source)
        XCTAssertFalse(refreshedFinal.rects.isEmpty)
        XCTAssertNotEqual(refreshedFinal.rects, final.rects)
        let exact = try await pages.markdownDocumentMatches("needle", options: .init(),
            startPage: refreshedFinal.page, after: refreshedFinal.source, inclusive: true)
        XCTAssertEqual(refreshedFinal, exact.first)
        XCTAssertEqual(stalePublications, 1)
    }
}
#endif
