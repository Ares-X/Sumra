#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class NativeEbookPositionTests: XCTestCase {
    func testRegeneratedEbookInputsKeepPassageIdentityAndRejectChangedSource() throws {
        let firstDirectory = try TemporaryDirectory(), secondDirectory = try TemporaryDirectory()
        defer { withExtendedLifetime((firstDirectory, secondDirectory)) {} }
        for suffix in ["mobihtml", "html", "fb2"] {
            let paragraphs = (0..<80).map { "Ebook paragraph \($0) retains authored source identity while its page width and font change." }
            let body = paragraphs.map { "<p>\($0)</p>" }.joined()
            let content = suffix == "fb2"
                ? "<?xml version='1.0' encoding='utf-8'?><FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'><body><section>\(body)</section></body></FictionBook>"
                : "<html><body>\(body)</body></html>"
            let firstURL = firstDirectory.url.appendingPathComponent("document." + suffix)
            let secondURL = secondDirectory.url.appendingPathComponent("document." + suffix)
            try content.write(to: firstURL, atomically: true, encoding: .utf8)
            try content.write(to: secondURL, atomically: true, encoding: .utf8)
            let first = try NativeFile(firstURL, engine: .mupdf)
            _ = try first.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light", pageSize: CGSize(width: 620, height: 0))
            let glyph = try XCTUnwrap(first.words(0).first { $0.source != nil && $0.bounds.minY > 800 && !$0.text.allSatisfy(\.isWhitespace) })
            let passage = try XCTUnwrap(first.passage(0, at: CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)))
            let serialized = try JSONDecoder().decode(NativePassage.self, from: JSONEncoder().encode(passage))
            let second = try NativeFile(secondURL, engine: .mupdf)
            _ = try second.relayout(fontSize: 23, lineHeight: 1.6, font: "serif", theme: "light", pageSize: CGSize(width: 380, height: 300))
            let target = try XCTUnwrap(second.position(for: serialized))
            XCTAssertEqual(target.nativePassage, serialized)
            XCTAssertTrue(try second.words(target.page).contains { $0.source == passage.source })
            try content.replacingOccurrences(of: "authored", with: "replacement").write(to: secondURL, atomically: true, encoding: .utf8)
            let changed = try NativeFile(secondURL, engine: .mupdf)
            _ = try changed.relayout(fontSize: 23, lineHeight: 1.6, font: "serif", theme: "light", pageSize: CGSize(width: 380, height: 300))
            XCTAssertNil(try changed.position(for: serialized), "A new source must invalidate the old node identity")
        }
    }

    @MainActor
    func testStartupUsesResolvedSavedSourceInsteadOfItsOldPixelCoordinate() async throws {
        _ = NSApplication.shared
        let firstDirectory = try TemporaryDirectory(), secondDirectory = try TemporaryDirectory()
        let source = "<html><body>" + (0..<160).map {
            "<p>Paragraph \($0): The saved ebook passage must remain visible after the native source is reopened in a narrower reading window.</p>"
        }.joined() + "</body></html>"
        let firstURL = firstDirectory.url.appendingPathComponent("document.mobihtml")
        let secondURL = secondDirectory.url.appendingPathComponent("document.mobihtml")
        try source.write(to: firstURL, atomically: true, encoding: .utf8)
        try source.write(to: secondURL, atomically: true, encoding: .utf8)
        let first = try Pages(firstURL, format: .mupdf, deferReflowLayout: true)
        let settings = ReaderState(recordsHistory: false)
        settings.fontSize = 17; settings.lineHeight = 1.6; settings.margin = 32; settings.font = "system"; settings.theme = "light"
        settings.userCSS = ""; settings.useDocumentCSS = true; settings.pageMargins = nil
        settings.flow = "continuous"; settings.fit = "page"; settings.zoom = 1; settings.spread = false
        settings.automaticLayout = false; settings.freePan = false; settings.uniformPageWidth = false
        settings.trimEmptyMargins = false; settings.landscapeAsSpread = false; settings.scrollbarMode = "smart"
        _ = try await first.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", userCSS: settings.effectiveUserCSS, pageSize: CGSize(width: 620, height: 0))
        let words = try await first.words(0)
        let glyph = try XCTUnwrap(words.first { $0.source != nil && $0.bounds.minY > 2000 && !$0.text.allSatisfy(\.isWhitespace) })
        settings.document = ReadingDocument(url: firstURL, content: .pages(first))
        settings.reflowable = true; settings.count = await first.count
        settings.updatePosition(try await first.position(page: 0, x: 0, y: Double(glyph.bounds.minY)))
        let saved = settings.currentPosition
        XCTAssertNotNil(saved.nativePassage)
        let reopened = try Pages(secondURL, format: .mupdf, deferReflowLayout: true), state = ReaderState(recordsHistory: false)
        state.apply(saved)
        let document = ReadingDocument(url: secondURL, content: .pages(reopened))
        state.freePan = false; state.uniformPageWidth = false; state.trimEmptyMargins = false; state.landscapeAsSpread = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 380, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        state.document = document
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime((firstDirectory, secondDirectory)) {} }
        let reference = try NativeFile(secondURL, engine: .mupdf, deferReflowLayout: true)
        let deadline = Date().addingTimeInterval(5)
        var expectedY: Double?, actualY: Double?, referenceWidth: CGFloat?
        repeat {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
            if state.reflowable,
               RasterReader.pageIsRendered(in: state.readerFocusView, pages: reopened, location: state.pageLocation(state.page)),
               let visible = RasterReader.visiblePageBounds(in: state.readerFocusView, pages: reopened, location: state.pageLocation(state.page)) {
                let width = try await reopened.bounds(state.page).width
                if referenceWidth != width {
                    _ = try reference.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: state.resolvedTheme, userCSS: state.effectiveUserCSS, pageSize: CGSize(width: width, height: 0))
                    referenceWidth = width
                }
                let target = try XCTUnwrap(reference.position(for: XCTUnwrap(saved.nativePassage)))
                expectedY = target.y; actualY = Double(visible.minY)
                if let expectedY, abs(expectedY - actualY!) < 1 { break }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTAssertGreaterThan(abs(try XCTUnwrap(expectedY) - XCTUnwrap(saved.y)), 100, "Narrow reflow must change the saved glyph's numeric Y")
        XCTAssertEqual(try XCTUnwrap(actualY), try XCTUnwrap(expectedY), accuracy: 1, "The initial scroll request must use resolved source geometry")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeEbookCapturePreserveDiscardAndCloseSaveKeepRendererIndependentPosition() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("document.mobihtml")
        defer { withExtendedLifetime(directory) {} }
        try ("<html><body>" + (0..<80).map { "<p>Saved passage \($0) retains its location across reader mode changes.</p>" }.joined() + "</body></html>")
            .write(to: source, atomically: true, encoding: .utf8)
        let pages = try Pages(source, format: .mupdf, deferReflowLayout: true), state = ReaderState()
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", pageSize: CGSize(width: 620, height: 400))
        state.document = ReadingDocument(url: directory.url.appendingPathComponent("record.mobi"), content: .pages(pages))
        state.reflowable = true; state.flow = "paged"; state.fontSize = 17; state.lineHeight = 1.6
        state.margin = 32; state.font = "system"; state.theme = "light"; state.zoom = 1.5; state.userCSS = ""
        state.useDocumentCSS = true; state.pageMargins = nil
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", userCSS: state.effectiveUserCSS, pageSize: CGSize(width: 620, height: 400))
        state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        let original = try await pages.position(page: state.count / 2, x: 40, y: 80)
        let passage = try XCTUnwrap(original.nativePassage)
        state.updatePosition(original)
        XCTAssertNil(state.currentPosition.markdownRenderer)
        XCTAssertEqual(state.filePosition?.nativePassage, passage)
        state.updatePosition(.init(page: original.page, x: 0, y: 0), preservingNativePassage: true)
        XCTAssertEqual(state.currentPosition.nativePassage, passage, "Clamped scroll reports must retain the restored source")
        state.discardNativePassage()
        XCTAssertNil(state.currentPosition.nativePassage, "User movement must relinquish the restored source")
        let key = "position:" + state.document!.url.standardizedFileURL.path
        defer { state.windowClosed(); UserDefaults.standard.removeObject(forKey: key) }
        state.updatePosition(.init(page: original.page, x: 40, y: 80))
        state.persist() // Save before the debounced source lookup can finish.
        let deadline = Date().addingTimeInterval(5)
        var saved: ReadingPosition?
        repeat {
            saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReadingPosition.self, from: $0) }
            if saved?.nativePassage != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTAssertNotNil(saved?.nativePassage)
        XCTAssertNil(saved?.markdownRenderer)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSelectedEbookFindHitStaysSelectedAcrossContinuousSingleAndTwoPages() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("document.mobihtml")
        try ("<html><body>" + (0..<100).map { index in
            "<p>Paragraph \(index): " + (index == 4 || index == 60 ? "MODEPASSAGE " : "") + "The native ebook source survives reading mode changes and preserves the selected occurrence.</p>"
        }.joined() + "</body></html>").write(to: source, atomically: true, encoding: .utf8)
        let pages = try Pages(source, format: .mupdf, deferReflowLayout: true), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: source, content: .pages(pages))
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "page"; state.zoom = 1; state.spread = false; state.cover = false
        state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.font = "system"; state.theme = "light"
        state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false; state.landscapeAsSpread = false
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", pageSize: CGSize(width: 620, height: 0))
        state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        func wait(_ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if try await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Native ebook mode did not settle")
        }
        try await wait { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) }
        state.showFind = true
        state.send(.find("MODEPASSAGE"))
        try await wait { state.searchResults.count == 2 && !state.searchCounting && state.currentPosition.nativePassage != nil }
        let firstTarget = state.selectedSearchTarget
        state.send(.find("MODEPASSAGE"))
        try await wait { state.selectedSearchTarget != firstTarget && state.currentPosition.nativePassage != nil }
        let secondMatch = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
        let secondRect = try XCTUnwrap(secondMatch.rects.first)
        let secondSource = try await pages.capturePassage(.init(page: secondMatch.page, x: Double(secondRect.midX), y: Double(secondRect.midY)), theme: state.resolvedTheme, userCSS: state.effectiveUserCSS)
        try await wait { state.currentPosition.nativePassage?.source.node == secondSource?.source.node }
        let original = try XCTUnwrap(state.currentPosition.nativePassage)
        for mode in [ReaderMenuCommand.paged, .twoPages, .continuous] {
            let revision = state.renderRevision
            mode.run(state)
            try await wait {
                state.renderRevision > revision && state.searchResults.count == 2 && !state.searchCounting &&
                    state.selectedSearchTarget != nil && RasterReader.highlightedMatch(in: state.readerFocusView) != nil
            }
            XCTAssertEqual(state.currentPosition.nativePassage?.source, original.source)
            let match = try XCTUnwrap(RasterReader.highlightedMatch(in: state.readerFocusView))
            let rect = try XCTUnwrap(match.rects.first)
            let selectedSource = try await pages.capturePassage(.init(page: match.page, x: Double(rect.midX), y: Double(rect.midY)), theme: state.resolvedTheme, userCSS: state.effectiveUserCSS)
            XCTAssertEqual(selectedSource?.source.node, original.source.node, "Mode changes must retain the second occurrence")
        }
        XCTAssertNil(state.error)
    }


}
#endif
