#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeReflowSelectionTests: XCTestCase {
    func testSelectionEndingInWrappedSpaceRestoresPaintedGlyphs() async throws {
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("WrappedSpace.md")
        let phrase = "These words stay intact "
        try String(repeating: phrase + "while the next word wraps.\n\n", count: 20).write(to: input, atomically: true, encoding: .utf8)
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light")
        let original = try await pages.text(0) as NSString
        let selected = try await pages.selection(0, range: original.range(of: phrase))
        let start = try XCTUnwrap(selected.sourceStart), end = try XCTUnwrap(selected.sourceEnd)
        let sources = Set((selected.words ?? []).compactMap(\.source))
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", textZoom: 6)
        let native = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        _ = try native.relayout(fontSize: 102, lineHeight: 1.6, font: "system", theme: "light")
        XCTAssertNil(try native.position(for: end), "The fixture's terminal space must be unpainted after wrapping")
        let restored = try await pages.selection(from: start, to: end, sources: sources)
        let text = restored.keys.sorted().compactMap { restored[$0]?.text }.joined().filter { !$0.isWhitespace }
        XCTAssertTrue(text == phrase.filter { !$0.isWhitespace }, "A wrapped terminal space must not discard the painted selected glyphs")
    }

    func testInteriorCanvasSelectionSurvivesRepeatedReflowAndOffscreenScroll() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("OwnedSelection.md")
        try (0..<120).map { "Paragraph \($0): These words stay intact while the reader keeps this exact source passage through wrapping and zoom.\n\n" }
            .joined().write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.font = "system"; state.theme = "light"
        state.zoom = 1; state.fit = "custom"; state.flow = "continuous"; state.spread = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.automaticLayout = false
        state.scrollbarMode = "hidden"
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light",
                                     userCSS: state.effectiveUserCSS, useDocumentCSS: state.useDocumentCSS,
                                     pageMargins: state.pageMargins, pageSize: CGSize(width: 900, height: 0))
        let count = await pages.count, target = 0
        XCTAssertEqual(count, 1, "Continuous Markdown uses one natural-height chapter")
        state.reflowable = true; state.count = count; state.chapterLayout = await pages.chapterLayout
        let initialBounds = try await pages.bounds(target)
        state.updatePosition(try await pages.position(page: target, y: Double(initialBounds.height / 2)))
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        try await wait(host, state: state) {
            RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(target)) &&
                state.currentPosition.nativePassage != nil
        }
        // Finish the initial viewport style command before reading glyphs and
        // sending mouse events against the mounted canvas.
        let initialCommand = state.command.revision
        state.send(.none)
        try await wait(host, state: state) {
            state.command.revision > initialCommand && state.command.action == .none &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(target))
        }
        let canvas = try XCTUnwrap(state.readerFocusView), bounds = try await pages.bounds(target)
        let words = try await pages.words(target)
        let visible = canvas.visibleRect
        let visibleSourceTop = bounds.minY + visible.minY * bounds.height / canvas.bounds.height
        let line = try XCTUnwrap(words.first { !$0.bounds.isEmpty && $0.bounds.minY > visibleSourceTop + 20 }).bounds
        let first = try XCTUnwrap(words.first { !$0.bounds.isEmpty && abs($0.bounds.minY-line.minY) < 1 })
        let last = try XCTUnwrap(words.filter { !$0.bounds.isEmpty && abs($0.bounds.minY-line.minY) < 1 }.prefix(24).last)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            let displayed = CGPoint(x: (point.x-bounds.minX)*canvas.bounds.width/bounds.width, y: (point.y-bounds.minY)*canvas.bounds.height/bounds.height)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(displayed, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let start = CGPoint(x: first.bounds.minX+0.1, y: first.bounds.midY)
        let end = CGPoint(x: last.bounds.maxX-0.1, y: last.bounds.midY)
        canvas.mouseDown(with: try event(.leftMouseDown, start))
        canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        canvas.mouseUp(with: try event(.leftMouseUp, end))
        try await wait(host, state: state) { state.hasSelection }
        let selected = state.selectedText.filter { !$0.isWhitespace }
        XCTAssertFalse(selected.isEmpty)
        let reference = try Pages(input, format: .markdown, deferReflowLayout: true)
        var expectedBounds: [Double: CGRect] = [:]
        for zoom in [1.0, 1.5, 6.0] {
            _ = try await reference.relayout(fontSize: 17, lineHeight: 1.6, margin: 32,
                font: "system", theme: "light", userCSS: state.effectiveUserCSS,
                useDocumentCSS: state.useDocumentCSS, pageMargins: state.pageMargins,
                textZoom: zoom, pageSize: CGSize(width: 900, height: 0))
            expectedBounds[zoom] = try await reference.bounds(0)
        }
        func painted(at zoom: Double) -> Bool {
            guard let canvas = state.readerFocusView as? RasterCanvas.Canvas else { return false }
            return canvas.pageBounds == expectedBounds[zoom] && canvas.renderRevision == state.renderRevision &&
                RasterReader.pageIsRendered(in: canvas, pages: pages, location: state.pageLocation(target))
        }
        for zoom in [1.5, 6.0, 1.0] {
            let revision = state.renderRevision
            state.setZoom(zoom)
            try await wait(host, state: state) { state.renderRevision > revision && painted(at: zoom) }
            XCTAssertTrue(state.hasSelection, "Selection lost at zoom \(zoom)")
            XCTAssertEqual(state.selectedText.filter { !$0.isWhitespace }, selected, "Text changed at zoom \(zoom)")
            // Begin the next zoom after this style command is acknowledged.
            let command = state.command.revision
            state.send(.none)
            try await wait(host, state: state) {
                state.command.revision > command && state.command.action == .none && painted(at: zoom)
            }
        }
        let revision = state.renderRevision
        state.setZoom(1.5)
        try await Task.sleep(nanoseconds: 10_000_000)
        state.setZoom(6)
        try await wait(host, state: state) {
            // Adjacent absolute zooms may coalesce. The final native geometry
            // and painted selection matter, rather than two layout executions.
            state.renderRevision > revision && painted(at: 6) &&
                (state.readerScrollView?.contentView.bounds.minY ?? 0) > (state.readerScrollView?.contentView.bounds.height ?? 0)
        }
        let finalBounds = try await pages.bounds(target)
        XCTAssertEqual(finalBounds, expectedBounds[6])
        XCTAssertTrue(state.hasSelection, "Queued reflow must retain the source selection")
        XCTAssertEqual(state.selectedText.filter { !$0.isWhitespace }, selected)
        // Native scrolling must retain the reader-owned selection after its
        // source passage leaves the viewport of the natural-height chapter.
        let scroll = try XCTUnwrap(state.readerScrollView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(state.hasSelection)
        XCTAssertEqual(state.selectedText.filter { !$0.isWhitespace }, selected)
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        let sentinel = "OWNED_SELECTION_COPY_SENTINEL"
        pasteboard.clearContents(); pasteboard.setString(sentinel, forType: .string)
        // Exercise the canvas responder's Copy action after its passage leaves
        // the viewport, rather than querying an internal selection container.
        _ = canvas.perform(NSSelectorFromString("copy:"), with: nil)
        try await wait(host, state: state) { pasteboard.string(forType: .string) != sentinel }
        XCTAssertEqual(pasteboard.string(forType: .string)?.filter { !$0.isWhitespace }, selected)
    }

    private func wait(_ host: NSView, state: ReaderState, file: StaticString = #filePath, line: UInt = #line,
                      until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), state.error == nil, Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(state.error, file: file, line: line)
        XCTAssertTrue(predicate(), "Timed out waiting for hosted native reader: revision=\(state.renderRevision), zoom=\(state.zoom), viewport=\(String(describing: state.readerScrollView?.contentView.bounds))", file: file, line: line)
    }
}
#endif
