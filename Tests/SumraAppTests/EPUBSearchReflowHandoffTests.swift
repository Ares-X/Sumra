#if os(macOS)
import AppKit
import Combine
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class EPUBSearchReflowHandoffTests: XCTestCase {
    func testTwoChapterWorkersClaimEveryOffsetOnce() async {
        let queue = ChapterSearchQueue(firstOffset: 1, lastOffset: 1_471)
        let claim: @Sendable () async -> [Int] = {
            var offsets = [Int]()
            while let offset = await queue.next() {
                offsets.append(offset)
                await Task.yield()
            }
            return offsets
        }
        let first = Task.detached { await claim() }
        let second = Task.detached { await claim() }
        let firstOffsets = await first.value
        let secondOffsets = await second.value
        let offsets = firstOffsets + secondOffsets
        XCTAssertEqual(offsets.count, 1_471)
        XCTAssertEqual(offsets.sorted(), Array(1...1_471))
    }

    func testIndependentChapterCountRetainsSourceAndReaderLocations() async throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF is required for EPUB search")
        }
        let directory = try TemporaryDirectory(), query = "REFLOW_HANDOFF_NEEDLE"
        let input = try fixture(in: directory.url, query: query)
        let pages = try Pages(input, format: .book, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32,
            font: "system", theme: "light", pageSize: CGSize(width: 620, height: 400))
        let chapters = await pages.chapterLayout.chapterCount
        XCTAssertEqual(chapters, 14)
        let queue = ChapterSearchQueue(firstOffset: 7, lastOffset: chapters)
        let possibleWorker = await pages.chapterSearchWorker(query, options: .init(),
            start: PageLocation(chapter: 0, page: 0), queue: queue, excludingChapters: [])
        let worker = try XCTUnwrap(possibleWorker)
        let result = try await worker.value
        let table = try await pages.integrateChapterSearchWorker(result)
        XCTAssertEqual(result.matches.count, 4)
        XCTAssertEqual(Set(result.matches.compactMap(\.location?.chapter)), [13])
        XCTAssertTrue(result.chapterTable.isLaidOut(13))
        XCTAssertTrue(table.isLaidOut(13))
        var reference = [RasterMatch]()
        for page in 0..<table.pageCount(13) {
            reference += try await pages.matches(query, location: PageLocation(chapter: 13, page: page))
        }
        XCTAssertEqual(result.matches.map(\.source), reference.map(\.source))
        XCTAssertEqual(result.matches.map(\.location), reference.map(\.location))
        XCTAssertEqual(result.matches.map(\.index), reference.map(\.index))
        XCTAssertEqual(result.matches.map(\.rects), reference.map(\.rects))
        _ = try await pages.relayout(fontSize: 23, lineHeight: 1.6, margin: 32,
            font: "system", theme: "light", pageSize: CGSize(width: 420, height: 300))
        do {
            _ = try await pages.integrateChapterSearchWorker(result)
            XCTFail("Results from the preceding layout cannot repopulate the new chapter table")
        } catch is CancellationError { }
        withExtendedLifetime(directory) {}
    }

    func testWorkerOwnedSpineSeamRetainsBothFragmentPages() async throws {
        let directory = try TemporaryDirectory()
        let base = directory.url
        try FileManager.default.createDirectory(at: base.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"
        ]
        var manifest = "", spine = ""
        for chapter in 0..<4 {
            let name = "chapter\(chapter).xhtml"
            manifest += "<item id='c\(chapter)' href='\(name)' media-type='application/xhtml+xml'/>"
            spine += "<itemref idref='c\(chapter)'/>"
            let text = chapter == 2 ? "普通" : chapter == 3 ? "汉字" : "Opening passage"
            files[name] = "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>\(text)</p></body></html>"
        }
        files["content.opf"] = "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        for (name, contents) in files {
            try contents.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = base; zip.arguments = ["-q", "-0", "seam.epub"] + files.keys.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        let pages = try Pages(base.appendingPathComponent("seam.epub"), format: .book, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.2, margin: 16,
            font: "system", theme: "light", pageSize: CGSize(width: 260, height: 180))
        let queue = ChapterSearchQueue(firstOffset: 2, lastOffset: 4)
        let possibleWorker = await pages.chapterSearchWorker("普通 汉字", options: .init(),
            start: PageLocation(chapter: 0, page: 0), queue: queue, excludingChapters: [])
        let result = try await XCTUnwrap(possibleWorker).value
        let hit = try XCTUnwrap(result.matches.first)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(hit.fragments?.compactMap { $0.location?.chapter }, [2, 3])
        let table = try await pages.integrateChapterSearchWorker(result)
        XCTAssertTrue(table.isLaidOut(2))
        XCTAssertTrue(table.isLaidOut(3))
        for fragment in try XCTUnwrap(hit.fragments) {
            XCTAssertEqual(fragment.page, table.page(for: try XCTUnwrap(fragment.location)))
        }
        let original = try await pages.matches("普通 汉字", location: PageLocation(chapter: 2, page: 0))
        XCTAssertEqual(result.matches.map(\.source), original.map(\.source))
        XCTAssertEqual(result.matches.map(\.fragments), original.map(\.fragments))
        withExtendedLifetime(directory) {}
    }

    func testChapterCountingSkipsEmptyPagesAndRetainsMatchLocations() async throws {
        let directory = try TemporaryDirectory(), query = "LATE_CHAPTER_MATCH"
        let input = try singleChapterFixture(in: directory.url, query: query)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 16,
            font: "system", theme: "light", pageSize: CGSize(width: 320, height: 180))
        let count = try await pages.searchPageCount(0)
        let layout = await pages.chapterLayout
        var reference: [RasterMatch] = []
        for page in 0..<count {
            reference += try await pages.matches(query, location: .init(chapter: 0, page: page))
        }
        XCTAssertEqual(reference.count, 4)
        XCTAssertGreaterThan(try XCTUnwrap(reference.first?.location).page, 0)
        var actual: [RasterMatch] = [], cursor = 0
        while cursor < count {
            let batch = try await pages.nextChapterMatches(query, chapter: 0, pageRange: cursor..<count,
                options: .init(), maximum: 1000)
            XCTAssertGreaterThan(batch.nextPage, cursor)
            XCTAssertEqual(batch.layout, layout)
            actual += batch.matches; cursor = batch.nextPage
        }
        XCTAssertEqual(actual, reference)
        let after = await pages.chapterLayout
        XCTAssertEqual(after, layout, "Searching prepared pages must retain chapter geometry")
        let absent = try await pages.nextChapterMatches("ABSENT_CHAPTER_QUERY", chapter: 0,
            pageRange: 0..<count, options: .init(), maximum: 1000)
        XCTAssertTrue(absent.matches.isEmpty)
        XCTAssertEqual(absent.nextPage, count)
        let limited = try await pages.nextChapterMatches(query, chapter: 0, pageRange: 0..<count,
            options: .init(), maximum: 1)
        XCTAssertEqual(limited.matches, Array(reference.prefix(1)))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pages.nextChapterMatches(query, chapter: 0, pageRange: 0..<count,
                options: .init(), maximum: 1000)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled counting must not publish a batch") }
        catch is CancellationError { }
        let started = expectation(description: "Empty-page batch requested")
        var completed = false
        let interrupted = Task {
            started.fulfill()
            defer { completed = true }
            return try await pages.nextChapterMatches("ABSENT_CHAPTER_QUERY", chapter: 0,
                pageRange: 0..<count, options: .init(), maximum: 1000)
        }
        await fulfillment(of: [started], timeout: 1)
        let text = try await pages.text(PageLocation(chapter: 0, page: 0))
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(completed, "Reading must run while the empty-page scan is unfinished")
        interrupted.cancel()
        do { _ = try await interrupted.value; XCTFail("Cancellation during a batch must stop its scan") }
        catch is CancellationError { }
        // A cancelled batch's abort cookie must not poison the next operation.
        // Multiple successful batches also exercise independent cookie lifetimes.
        var recovered = [RasterMatch](), next = 0
        while next < count {
            let batch = try await pages.nextChapterMatches(query, chapter: 0,
                pageRange: next..<count, options: .init(), maximum: 1000)
            XCTAssertGreaterThan(batch.nextPage, next)
            recovered += batch.matches; next = batch.nextPage
        }
        XCTAssertEqual(recovered, reference)
        withExtendedLifetime(directory) {}
    }

    func testFindWithoutFindPanelSelectsAMatchAfterQueuedReflow() async throws {
        for chapterCount in [1, 14] {
            try await verifyFindAfterQueuedReflow(chapterCount: chapterCount)
        }
    }

    func testCompletedSearchSelectionAndResultsStayTogetherDuringLazyChapterPagination() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), query = "合计四十九营二万五千人之"
        let input = try fixture(in: directory.url, query: query, ordinaryParagraphs: 240)
        let state = ReaderState(recordsHistory: false)
        state.flow = "paged"; state.spread = false; state.cover = false
        state.fit = "page"; state.zoom = 1; state.automaticLayout = false
        state.fontSize = 17; state.lineHeight = 1.4; state.margin = 32
        state.font = "system"; state.theme = "light"; state.pageMargins = nil
        state.userCSS = ""; state.useDocumentCSS = true; state.scrollbarMode = "hidden"
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.freePan = false
        state.landscapeAsSpread = false; state.rtl = false
        var completedSelection: String?, completedWithLazyChapters = false
        var mismatchedSelections = [String]()
        let subscription = state.$selectedSearchTarget.sink { target in
            guard let target else { return }
            guard !state.searchCounting, !state.searchResults.isEmpty else { return }
            if !state.searchResults.contains(where: { $0.target == target }) {
                mismatchedSelections.append("selected=\(target) published=\(state.searchResults.map(\.target))")
            }
        }
        let completion = state.$searchCounting.dropFirst().sink { counting in
            if !counting, state.searchResults.count == 4 {
                completedSelection = state.selectedSearchTarget
                completedWithLazyChapters = state.chapterLayout?.complete == false
            }
        }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            subscription.cancel(); completion.cancel(); state.windowClosed(); window.makeFirstResponder(nil)
            window.contentView = nil; window.close(); withExtendedLifetime(directory) {}
        }
        func wait(_ reason: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if let error = state.error { throw ReadError(error) }
                if condition() { return }
            } while Date() < deadline
            throw ReadError("\(reason): \(state.searchCountText)")
        }
        func painted() -> Bool {
            guard case .pages(let current) = state.document?.content else { return false }
            return RasterReader.pageIsRendered(in: state.readerFocusView, pages: current, location: state.pageLocation(state.page))
        }
        state.openWithoutHistory(input, at: state.currentPosition)
        try await wait("Initial reader") { !state.busy && painted() }
        // Exercise the same real viewport boundary as the original report:
        // opening/closing Contents relayouts the reader and makes chapter counts
        // lazy again before an ordinary user find command.
        state.showContents = true; state.send(.toc)
        try await wait("Open Contents") { !state.outlineBusy && painted() }
        state.showContents = false
        try await wait("Close Contents") { painted() }
        state.send(.find(query))
        try await wait("Search and resumed background pagination") {
            if state.chapterLayout?.complete == true, !state.searchCounting,
               state.searchResults.count == 4, let target = state.selectedSearchTarget {
                return state.searchResults.contains(where: { $0.target == target }) && painted()
            }
            return false
        }
        XCTAssertNotNil(completedSelection)
        XCTAssertTrue(completedWithLazyChapters,
                      "The search must complete before earlier negative chapters are laid out")
        XCTAssertNotEqual(completedSelection, state.selectedSearchTarget,
                          "Background chapter layout after completed search must change the selected page projection")
        XCTAssertTrue(mismatchedSelections.isEmpty, mismatchedSelections.joined(separator: "\n"))
        XCTAssertEqual(state.searchCountText, "1 / 4")
        XCTAssertFalse(window.isVisible)
    }

    func testCompletedNegativeFindIsReusedUntilSearchChanges() async throws {
        for chapterCount in [1, 14] {
            _ = NSApplication.shared
            let directory = try TemporaryDirectory(), token = "NEGATIVE_FIND_LIFECYCLE"
            let input = try chapterCount == 1 ? singleChapterFixture(in: directory.url, query: token)
                : fixture(in: directory.url, query: token)
            let pages = try Pages(input, format: chapterCount == 1 ? .mupdf : .book, deferReflowLayout: true)
            let state = ReaderState(recordsHistory: false)
            state.flow = "paged"; state.spread = false; state.cover = false
            state.fit = "page"; state.zoom = 1; state.automaticLayout = false
            state.fontSize = 17; state.lineHeight = 1.4; state.margin = 32
            state.font = "system"; state.theme = "light"; state.pageMargins = nil
            state.userCSS = ""; state.useDocumentCSS = true; state.scrollbarMode = "hidden"
            state.trimEmptyMargins = false; state.uniformPageWidth = false; state.freePan = false
            state.landscapeAsSpread = false; state.rtl = false
            _ = try await pages.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
                margin: state.margin, font: state.font, theme: state.resolvedTheme,
                userCSS: state.effectiveUserCSS, pageSize: CGSize(width: 620, height: 400))
            state.document = ReadingDocument(url: input, content: .pages(pages))
            state.reflowable = true; state.searchable = true
            _ = state.applyChapterLayout(await pages.chapterLayout)
            let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer {
                state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
                withExtendedLifetime(directory) {}
            }
            func wait(_ reason: String, _ condition: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(15)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                    }
                    if let error = state.error { throw ReadError(error) }
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while Date() < deadline
                throw ReadError("\(reason): \(state.searchCountText)")
            }
            try await wait("Initial reader") {
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                    location: state.pageLocation(state.page))
            }
            var countingStarts = 0
            let subscription = state.$searchCounting.sink { if $0 { countingStarts += 1 } }
            defer { subscription.cancel() }
            var options = TextSearchOptions(); options.caseSensitive = true
            let query = token.lowercased()
            state.send(.find(query, options: options))
            try await wait("Definitive negative find") { countingStarts > 0 && !state.searchCounting }
            XCTAssertTrue(state.searchResults.isEmpty)
            let completedStarts = countingStarts
            state.send(.find(query, backwards: true, options: options))
            let repeatedRevision = state.command.revision
            state.send(.none)
            try await wait("Repeated negative command handled") { state.command.revision > repeatedRevision && state.command.action == .none }
            XCTAssertEqual(countingStarts, completedStarts, "An unchanged completed zero must not restart document scanning")
            options.caseSensitive = false
            state.send(.find(query, options: options))
            try await wait("Changed options must invalidate the negative result") {
                state.searchResults.count == 4 && !state.searchCounting
            }
            options.allowedPages = IndexSet()
            state.send(.find(query, options: options))
            try await wait("Empty page restriction") { state.searchResults.isEmpty && !state.searchCounting }
            options.allowedPages = nil
            state.send(.find(query, options: options))
            try await wait("Changed allowed pages must invalidate the negative result") {
                state.searchResults.count == 4 && !state.searchCounting
            }
            state.send(.find("ENTIRELY_ABSENT_QUERY"))
            try await wait("Replacement negative query") { state.searchResults.isEmpty && !state.searchCounting }
            let beforeReflow = countingStarts, revision = state.renderRevision
            state.fontSize = 20; state.send(.style)
            try await wait("Reflow must invalidate the negative result") {
                state.renderRevision > revision && countingStarts > beforeReflow && !state.searchCounting
            }
            // Closing or cancelling search retires the preceding proof. The
            // next identical request must perform its own complete traversal.
            state.send(.toc)
            let clearRevision = state.command.revision
            state.send(.none)
            try await wait("Search cleared") { state.command.revision > clearRevision && state.command.action == .none }
            let beforeClear = countingStarts
            state.send(.find("ENTIRELY_ABSENT_QUERY"))
            try await wait("Cleared negative search must run again") { countingStarts > beforeClear && !state.searchCounting }
            state.send(.find("CANCELLED_ABSENT_QUERY")); state.send(.toc)
            state.send(.find(query, options: options))
            try await wait("Cancelled work cannot suppress its replacement") {
                state.searchResults.count == 4 && !state.searchCounting
            }
        }
    }

    func testMarkdownNegativeFindKeepsSelectionFilterSeparate() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), token = "SELECTED_NEEDLE"
        let input = directory.url.appendingPathComponent("selection.md")
        try Array(repeating: token, count: 4).joined(separator: " ").write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.flow = "paged"; state.spread = false; state.cover = false
        state.fit = "page"; state.zoom = 1; state.automaticLayout = false
        state.fontSize = 17; state.lineHeight = 1.4; state.margin = 32
        state.font = "system"; state.theme = "light"; state.pageMargins = nil
        state.userCSS = ""; state.useDocumentCSS = true; state.scrollbarMode = "hidden"
        _ = try await pages.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
            margin: state.margin, font: state.font, theme: state.resolvedTheme,
            userCSS: state.effectiveUserCSS, pageSize: CGSize(width: 620, height: 400))
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func wait(_ reason: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if let error = state.error { throw ReadError(error) }
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            throw ReadError("\(reason): \(state.searchCountText)")
        }
        try await wait("Initial Markdown reader") {
            RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                location: state.pageLocation(state.page))
        }
        var starts = 0
        let subscription = state.$searchCounting.sink { if $0 { starts += 1 } }
        defer { subscription.cancel() }
        state.send(.find("UNAUTHORED_MARKDOWN_NEEDLE"))
        try await wait("Definitive Markdown zero") { starts > 0 && !state.searchCounting }
        let completedStarts = starts
        state.send(.find("UNAUTHORED_MARKDOWN_NEEDLE", backwards: true))
        let revision = state.command.revision
        state.send(.none)
        try await wait("Repeated Markdown negative handled") { state.command.revision > revision && state.command.action == .none }
        XCTAssertEqual(starts, completedStarts)
        state.send(.toc); state.send(.selectAll)
        try await wait("Select every authored match") { state.selectedText.components(separatedBy: token).count == 5 }
        let selectedMissStarts = starts
        state.send(.find("SELECTED_ABSENT_QUERY", fromSelection: true))
        try await wait("Selected absent query completes") {
            starts > selectedMissStarts && !state.searchCounting && state.searchResults.isEmpty
        }
        let filteredMissStarts = starts
        state.send(.find("SELECTED_ABSENT_QUERY"))
        try await wait("A selection-filtered miss must not suppress the complete unfiltered find") {
            starts > filteredMissStarts && !state.searchCounting && state.searchResults.isEmpty
        }
        let selectionStarts = starts
        state.send(.find(token, fromSelection: true))
        try await wait("Selection-based find wraps through authored matches") {
            starts > selectionStarts && state.searchResults.count == 4 && !state.searchCounting
        }
        state.send(.find(token))
        try await wait("Unfiltered find must still select and count real matches") {
            state.searchResults.count == 4 && !state.searchCounting && state.selectedSearchTarget != nil
        }
    }

    private func verifyFindAfterQueuedReflow(chapterCount: Int) async throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF is required for EPUB search handoff")
        }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), query = "REFLOW_HANDOFF_NEEDLE"
        let input = try chapterCount == 1 ? singleChapterFixture(in: directory.url, query: query)
            : fixture(in: directory.url, query: query)
        let pages = try Pages(input, format: chapterCount == 1 ? .mupdf : .book, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.flow = "paged"; state.spread = false; state.cover = false
        state.fit = "page"; state.zoom = 1; state.automaticLayout = false
        state.fontSize = 17; state.lineHeight = 1.4; state.margin = 32
        state.font = "system"; state.theme = "light"; state.pageMargins = nil
        state.userCSS = ""; state.useDocumentCSS = true; state.scrollbarMode = "hidden"
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.freePan = false
        state.landscapeAsSpread = false; state.rtl = false
        _ = try await pages.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
            margin: state.margin, font: state.font, theme: state.resolvedTheme,
            userCSS: state.effectiveUserCSS, pageSize: CGSize(width: 620, height: 400))
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func ready() -> Bool {
            RasterReader.pageIsRendered(in: state.readerFocusView,
                pages: pages, location: state.pageLocation(state.page))
        }
        func wait(_ reason: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if let error = state.error { throw ReadError(error) }
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline
            throw ReadError("\(reason): \(state.searchCountText), selected=\(state.selectedSearchTarget ?? "none")")
        }
        try await wait("Initial reading surface") { ready() }
        XCTAssertFalse(state.showFind)
        let initialRevision = state.renderRevision
        // Find navigation is asynchronous. Queue a real typography reflow while
        // it is still traversing negative pages toward the final passages.
        state.send(.find(query))
        state.fontSize = 20
        state.send(.style)
        try await wait("Search must navigate as well as count after reflow") {
            ready() && state.renderRevision > initialRevision && state.searchResults.count == 4 && !state.searchCounting &&
                state.selectedSearchTarget != nil && RasterReader.highlightedMatch(in: state.readerFocusView) != nil
        }
        XCTAssertFalse(state.showFind, "Search navigation must not depend on panel visibility")
        XCTAssertEqual(state.pageLocation(state.page).chapter, chapterCount - 1)
        let selected = state.selectedSearchTarget
        state.send(.find(query))
        try await wait("Find Next must retain its selected-match cursor") {
            ready() && state.selectedSearchTarget != nil && state.selectedSearchTarget != selected
        }
        let closingRevision = state.renderRevision
        state.send(.toc)
        state.fontSize = 21
        state.send(.style)
        try await wait("Closing search must prevent reflow from reviving it") {
            ready() && state.renderRevision > closingRevision && state.searchResults.isEmpty && state.selectedSearchTarget == nil && !state.searchCounting
        }
    }

    private func singleChapterFixture(in directory: URL, query: String) throws -> URL {
        let source = directory.appendingPathComponent("document.mobihtml")
        let paragraphs = (0..<240).map { index in
            "<p>\(index >= 236 ? query : "Ordinary passage") paragraph \(index). " +
                "Reading and search use the same authored document through typography changes.</p>"
        }.joined()
        try ("<html><body>" + paragraphs + "</body></html>").write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private func fixture(in directory: URL, query: String, ordinaryParagraphs: Int = 24) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"
        ]
        var manifest = "", spine = ""
        for chapter in 0..<14 {
            let filename = "chapter\(chapter).xhtml"
            manifest += "<item id='c\(chapter)' href='\(filename)' media-type='application/xhtml+xml'/>"
            spine += "<itemref idref='c\(chapter)'/>"
            let paragraphs = (0..<(chapter == 13 ? 24 : ordinaryParagraphs)).map { paragraph in
                let token = chapter == 13 && paragraph < 4 ? query : "Ordinary passage"
                return "<p>\(token) chapter \(chapter) paragraph \(paragraph). Reading and search use the same authored document through typography changes.</p>"
            }.joined()
            files[filename] = "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter \(chapter)</title></head><body>\(paragraphs)</body></html>"
        }
        files["content.opf"] = "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "search.epub"] + files.keys.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("search.epub")
    }
}
#endif
