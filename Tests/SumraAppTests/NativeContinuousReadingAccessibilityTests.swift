#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeContinuousReadingAccessibilityTests: XCTestCase {
    func testNaturalChapterPublishesNavigableTextForPaintedViewportAfterDistantScroll() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("accessible-continuous.md")
        let chapter = (0..<800).map {
            "Paragraph \($0): 中文😀 natural continuous reading keeps accessible text and its source geometry aligned with the painted viewport.\n\n"
        }.joined()
        try chapter.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "page"; state.zoom = 1; state.spread = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "system"; state.theme = "light"; state.margin = 32
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        // Prepare the deferred Markdown chapter before mounting, as in the
        // existing mounted AX test. The assertions below inspect paint and AX;
        // they must not request chapter layout while SwiftUI starts its layout.
        _ = try await pages.relayout(fontSize: state.fontSize, lineHeight: state.lineHeight,
            margin: state.margin, font: state.font, theme: state.resolvedTheme,
            userCSS: state.effectiveUserCSS, useDocumentCSS: state.useDocumentCSS,
            pageMargins: state.pageMargins, pageSize: CGSize(width: 620, height: 0))
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let location = state.pageLocation(0)
        let bounds = try await pages.bounds(location)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        func waitFor(_ predicate: () async throws -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(20)
            repeat {
                paint()
                if try await predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Natural reading accessibility did not settle", line: line)
        }
        try await waitFor {
            return bounds.height > 400 * 50 &&
                abs((state.readerFocusView?.frame.height ?? 0) - bounds.height) < 0.5 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: location) &&
                self.readingElement(in: state.readerFocusView)?.isAccessibilityElement() == true
        }
        let canvas = try XCTUnwrap(state.readerFocusView)
        let scroll = try XCTUnwrap(state.readerScrollView)
        let element = try XCTUnwrap(readingElement(in: canvas))
        let count = await pages.count
        XCTAssertEqual(count, 1, "The regression must exercise one natural chapter rather than paginated text")

        func compareViewport() async throws -> RasterSelection {
            let transform = RasterLayout.transform(bounds: bounds, size: canvas.bounds.size, rotation: state.rotation)
            let region = canvas.visibleRect.applying(transform.inverted()).intersection(bounds)
            let selections = try await pages.selection(areas: [location: region])
            let selection = try XCTUnwrap(selections[location])
            let words = try XCTUnwrap(selection.words)
            let expected = NativeReadingAccessibilitySnapshot(words: words)
            XCTAssertGreaterThan(expected.text.length, 0)
            try await waitFor {
                RasterReader.pageIsRendered(in: canvas, pages: pages, location: location) &&
                    element.accessibilityValue() == (expected.text as String)
            }
            let snapshot = try XCTUnwrap(element.snapshot)
            XCTAssertEqual(snapshot.text, expected.text)
            XCTAssertEqual(snapshot.glyphs.count, expected.glyphs.count)
            XCTAssertEqual(snapshot.lines, expected.lines)
            for (actual, wanted) in zip(snapshot.glyphs, expected.glyphs) {
                XCTAssertEqual(actual.range, wanted.range)
                XCTAssertEqual(actual.bounds, wanted.bounds, "AX geometry must remain in native source coordinates")
            }
            XCTAssertLessThan(snapshot.text.length, chapter.utf16.count, "Publishing a viewport must not decode the entire natural chapter")
            let glyph = try XCTUnwrap(snapshot.glyphs.first { !$0.bounds.isEmpty && $0.range.length > 0 })
            XCTAssertEqual(element.accessibilityString(for: glyph.range), snapshot.text.substring(with: glyph.range))
            let line = element.accessibilityLine(for: glyph.range.location)
            XCTAssertNotEqual(line, NSNotFound)
            XCTAssertTrue(NSLocationInRange(glyph.range.location, element.accessibilityRange(forLine: line)))
            XCTAssertEqual(element.accessibilityFrame(for: glyph.range),
                window.convertToScreen(canvas.convert(glyph.bounds.applying(transform), to: nil)))
            XCTAssertGreaterThan(element.accessibilityVisibleCharacterRange().length, 0)
            XCTAssertNotNil(words.first(where: { $0.source != nil })?.source)
            XCTAssertNotNil(words.last(where: { $0.source != nil })?.source)
            return selection
        }

        let initial = try await compareViewport()
        XCTAssertTrue(element.accessibilityValue()?.contains("Paragraph 0:") == true)
        XCTAssertFalse(element.accessibilityValue()?.contains("Paragraph 799:") == true)
        element.setAccessibilityFocused(true)
        let destination = bounds.height * 0.7
        state.send(.preservePosition(.init(page: 0, x: 0, y: Double(destination))))
        try await waitFor {
            abs(scroll.contentView.bounds.minY - destination) < 0.5 &&
                RasterReader.pageIsRendered(in: canvas, pages: pages, location: location) &&
                element.isAccessibilityElement() && element.accessibilityValue()?.contains("Paragraph 0:") == false
        }
        XCTAssertTrue(readingElement(in: canvas) === element, "Scrolling preserves the navigable reading element and its AX focus")
        XCTAssertTrue(element.isAccessibilityFocused())
        let distant = try await compareViewport()
        XCTAssertNotEqual(initial.words?.map(\.text).joined(), distant.words?.map(\.text).joined())
        XCTAssertLessThan(try XCTUnwrap(initial.words?.last(where: { $0.source != nil })?.source),
                          try XCTUnwrap(distant.words?.first(where: { $0.source != nil })?.source))
        element.setAccessibilityFocused(false)

        // The outgoing natural-height canvas can lose its tiling metadata
        // before finite reflow replaces its geometry. AX still owns only the
        // painted viewport during this transition.
        let naturalCanvas = try XCTUnwrap(canvas as? RasterCanvas.Canvas)
        let tileSize = try XCTUnwrap(naturalCanvas.viewportTileSize)
        naturalCanvas.viewportTileSize = nil
        element.clear()
        naturalCanvas.updateReadingAccessibility()
        let deadline = Date().addingTimeInterval(10)
        while !element.isAccessibilityElement(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(element.accessibilityValue(), distant.words?.map(\.text).joined(),
                       "A missing tile size must not decode the entire outgoing natural chapter")
        naturalCanvas.viewportTileSize = tileSize

        state.setFlow("paged")
        try await waitFor {
            let table = await pages.chapterLayout
            guard table.totalPages > 50, state.chapterLayout == table,
                  let canvas = state.readerFocusView as? RasterCanvas.Canvas,
                  canvas.viewportTileSize == nil,
                  let scroll = state.readerScrollView,
                  !String(reflecting: type(of: scroll)).contains("RasterViewport") else { return false }
            let finiteBounds = try await pages.bounds(canvas.location)
            return canvas.visibleBounds == finiteBounds &&
                RasterReader.pageIsRendered(in: canvas, pages: pages, location: state.pageLocation(state.page)) &&
                self.readingElement(in: canvas)?.isAccessibilityElement() == true
        }
        let finiteCanvas = try XCTUnwrap(state.readerFocusView as? RasterCanvas.Canvas)
        let finiteElement = try XCTUnwrap(readingElement(in: finiteCanvas))
        let finiteBounds = try await pages.bounds(finiteCanvas.location)
        let finiteTransform = RasterLayout.transform(bounds: finiteBounds, size: finiteCanvas.bounds.size, rotation: state.rotation)
        let finiteRegion = finiteCanvas.visibleRect.applying(finiteTransform.inverted()).intersection(finiteBounds)
        let finiteSelections = try await pages.selection(areas: [finiteCanvas.location: finiteRegion])
        let finiteSelection = try XCTUnwrap(finiteSelections[finiteCanvas.location])
        let finiteWords = try XCTUnwrap(finiteSelection.words)
        try await waitFor { finiteElement.accessibilityValue() == finiteWords.map(\.text).joined() }
        let finiteSnapshot = try XCTUnwrap(finiteElement.snapshot)
        let finiteGlyph = try XCTUnwrap(finiteSnapshot.glyphs.first { !$0.bounds.isEmpty && $0.range.length > 0 })
        XCTAssertEqual(finiteElement.accessibilityString(for: finiteGlyph.range), finiteSnapshot.text.substring(with: finiteGlyph.range))
        try await waitFor {
            finiteElement.accessibilityFrame(for: finiteGlyph.range) ==
                window.convertToScreen(finiteCanvas.convert(finiteGlyph.bounds.applying(finiteCanvas.pageTransform), to: nil))
        }
        XCTAssertEqual(finiteCanvas.visibleBounds, finiteBounds)
        XCTAssertEqual(finiteElement.accessibilityFrame(for: finiteGlyph.range),
                       window.convertToScreen(finiteCanvas.convert(finiteGlyph.bounds.applying(finiteCanvas.pageTransform), to: nil)))
        XCTAssertNotNil(finiteWords.first(where: { $0.source != nil })?.source)
        XCTAssertFalse(finiteSelection.text.isEmpty)
        XCTAssertNil(state.error)
    }

    func testDistantOutlineViewportPassagePreservesHeadingThroughTypography() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("distant-outline.md")
        let prose = (0..<2_400).map { "Paragraph \($0) keeps neutral document text and source anchors stable through reader typography changes.\n\n" }
        let marker = "DistantHeadingMarker"
        let chapter = "# Opening\n\n" + prose.prefix(1_200).joined() + "## \(marker)\n\n" + prose.suffix(1_200).joined()
        try chapter.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let viewport = CGSize(width: 620, height: 400), pageSize = CGSize(width: 620, height: 0)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "serif", theme: "light", pageSize: pageSize)
        let contents = try await pages.prepare().outline
        let heading = try XCTUnwrap(contents.first { $0.title == marker })
        let started = ContinuousClock.now
        let resolved = try await pages.resolve(heading.target, viewport: viewport)
        print("distant-outline-first-viewport-resolve: \(started.duration(to: .now))")
        let position = try XCTUnwrap(resolved)
        let passage = try XCTUnwrap(position.nativePassage)
        let location = try XCTUnwrap(position.anchor.flatMap(ChapterTable.bookmarkLocation)?.location)
        let bounds = try await pages.bounds(location)
        XCTAssertGreaterThan(bounds.height, viewport.height * 50)
        let region = CGRect(x: position.x ?? 0, y: position.y ?? 0, width: viewport.width, height: viewport.height)
        let selected = try await pages.selection(areas: [location: region])
        let selection = try XCTUnwrap(selected[location])
        XCTAssertTrue(selection.text.contains(marker))
        XCTAssertEqual(passage.source, selection.words?.first(where: { $0.source != nil })?.source,
                       "The destination passage must anchor the heading painted in its viewport")

        _ = try await pages.relayout(fontSize: 19, lineHeight: 1.4, margin: 32, font: "serif", theme: "light",
            pageSize: pageSize, readingPosition: position, viewport: viewport)
        let restored = await pages.layoutPosition
        XCTAssertEqual(restored.nativePassage?.source, passage.source)
        let restoredLocation = try XCTUnwrap(restored.anchor.flatMap(ChapterTable.bookmarkLocation)?.location)
        let restoredRegion = CGRect(x: restored.x ?? 0, y: restored.y ?? 0, width: viewport.width, height: viewport.height)
        let restoredSelection = try await pages.selection(areas: [restoredLocation: restoredRegion])
        XCTAssertTrue(restoredSelection[restoredLocation]?.text.contains(marker) == true)
        withExtendedLifetime(directory) {}
    }

    private func readingElement(in view: NSView?) -> NativeReadingAccessibilityPage? {
        guard let view else { return nil }
        if let element = (view.accessibilityChildren() ?? []).first(where: { $0 is NativeReadingAccessibilityPage }) as? NativeReadingAccessibilityPage { return element }
        return view.subviews.lazy.compactMap { self.readingElement(in: $0) }.first
    }
}
#endif
