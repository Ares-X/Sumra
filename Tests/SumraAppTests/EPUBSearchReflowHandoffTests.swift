#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class EPUBSearchReflowHandoffTests: XCTestCase {
    func testFindWithoutFindPanelSelectsAMatchAfterQueuedReflow() async throws {
        for chapterCount in [1, 14] {
            try await verifyFindAfterQueuedReflow(chapterCount: chapterCount)
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

    private func fixture(in directory: URL, query: String) throws -> URL {
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
            let paragraphs = (0..<24).map { paragraph in
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
