#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class NativeContinuousReaderTests: XCTestCase {
    @MainActor
    func testModeHandoffKeepsTheNaturalChapterTiledUntilPaginationFinishes() async throws {
        _ = NSApplication.shared
        let oldFlow = UserDefaults.standard.object(forKey: "flow")
        defer { UserDefaults.standard.set(oldFlow, forKey: "flow") }
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("mode-handoff.md")
        try String(repeating: "Visible prose remains readable during pagination.\n\n", count: 2_000)
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.flow = "continuous"; state.spread = false; state.fit = "width"
        state.theme = "light"; state.fontSize = 17; state.lineHeight = 1.4
        state.userCSS = ""; state.pageMargins = nil; state.automaticLayout = false
        state.showContents = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        let deadline = Date().addingTimeInterval(10)
        while !RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)), Date() < deadline {
            paint(); try await Task.sleep(nanoseconds: 10_000_000)
        }
        let outgoing = try XCTUnwrap(state.readerFocusView as? RasterCanvas.Canvas)
        XCTAssertNotNil(outgoing.viewportTileSize)
        XCTAssertNil(outgoing.image, "Natural chapters use viewport tiles rather than a chapter-sized bitmap")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = Task.detached { await pages.holdRenderingForResize(entered, until: release) }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        state.setFlow("paged")
        for _ in 0..<8 {
            paint(); try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertNotNil(outgoing.viewportTileSize, "The outgoing chapter must stay tiled while native pagination is pending")
            XCTAssertNil(outgoing.image)
        }
        release.signal(); await blocked.value
        let pagedDeadline = Date().addingTimeInterval(10)
        repeat {
            paint(); try await Task.sleep(nanoseconds: 10_000_000)
        } while (!RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) ||
                  (state.readerFocusView as? RasterCanvas.Canvas)?.viewportTileSize != nil) && Date() < pagedDeadline
        let incoming = try XCTUnwrap(state.readerFocusView as? RasterCanvas.Canvas)
        XCTAssertNil(incoming.viewportTileSize)
        XCTAssertNotNil(incoming.image)
        XCTAssertLessThan(incoming.pageBounds.height, 500)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testReturningFromLaterSpreadPageRestoresTheNaturalPassage() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let oldFlow = defaults.object(forKey: "flow"), oldSpread = defaults.object(forKey: "spread")
        defer { defaults.set(oldFlow, forKey: "flow"); defaults.set(oldSpread, forKey: "spread") }
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("later-mode-handoff.md")
        try (0..<2_000).map { "Paragraph \($0): Visible prose keeps its source passage across reading modes.\n\n" }
            .joined().write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.flow = "continuous"; state.spread = false; state.fit = "width"
        state.theme = "light"; state.fontSize = 17; state.lineHeight = 1.4
        state.userCSS = ""; state.pageMargins = nil; state.automaticLayout = false
        state.showContents = false; state.scrollbarMode = "hidden"
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        func settle(natural: Bool, preservingFinitePages: Bool = false, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint(); try await Task.sleep(nanoseconds: 10_000_000)
                if preservingFinitePages {
                    func inspect(_ view: NSView) {
                        if let canvas = view as? RasterCanvas.Canvas, canvas.viewportTileSize == nil {
                            XCTAssertLessThan(canvas.pageBounds.height, 500,
                                "The outgoing finite surface must not render a natural chapter", line: line)
                        }
                        for child in view.subviews { inspect(child) }
                    }
                    inspect(host)
                }
                if let canvas = state.readerFocusView as? RasterCanvas.Canvas,
                   (canvas.viewportTileSize != nil) == natural,
                   RasterReader.pageIsRendered(in: canvas, pages: pages, location: state.pageLocation(state.page)),
                   state.pendingReflowPosition == nil { return }
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Mode handoff did not paint the restored passage", line: line)
        }
        try await settle(natural: true)
        state.send(.preservePosition(.init(page: 0, x: 0, y: 10_000)))
        try await settle(natural: true)
        // Let the actual viewport acquire its native source glyph, then require
        // both paginations to settle before returning from a nonzero page.
        for _ in 0..<20 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
        let original = try XCTUnwrap(state.currentPosition.nativePassage)
        state.setFlow("paged")
        try await settle(natural: false)
        XCTAssertGreaterThan(state.page, 0)
        state.captureReflowPosition(); state.spread = true
        try await settle(natural: false)
        XCTAssertGreaterThan(state.page, 0)
        state.setFlow("continuous")
        try await settle(natural: true, preservingFinitePages: true)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.pageLocation(state.page), .init(page: 0))
        let restored = try XCTUnwrap(state.currentPosition.nativePassage)
        XCTAssertEqual(restored.source, original.source)
        let canvas = try XCTUnwrap(state.readerFocusView as? RasterCanvas.Canvas)
        XCTAssertNotNil(canvas.viewportTileSize)
        XCTAssertGreaterThan(canvas.pageBounds.height, 10_000)
        XCTAssertGreaterThan(try XCTUnwrap(state.readerScrollView).contentView.bounds.minY, 9_000)
        XCTAssertNil(state.error)
    }

    func testQueuedFiniteRenderDoesNotRasterizeTheReplacementNaturalChapter() async throws {
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("queued-mode-render.md")
        try String(repeating: "A queued page render belongs to the pagination that requested it.\n\n", count: 2_000)
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let viewport = CGSize(width: 620, height: 400), location = PageLocation(page: 7)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "serif", theme: "light", pageSize: viewport)
        let finite = try await pages.render(location, viewport: viewport, scale: 1, columns: 2,
            rotation: 0, fit: "width", zoom: 1)
        XCTAssertNotNil(finite.image)
        XCTAssertEqual(finite.bounds.height, viewport.height)

        // Hold the actor after the replacement native layout, so the outgoing
        // finite request arrives before the UI can commit its new surface.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let replacement = Task.detached {
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "serif", theme: "light",
                pageSize: CGSize(width: viewport.width, height: 0))
            await pages.holdRenderingForResize(entered, until: release)
        }
        defer { release.signal(); withExtendedLifetime(directory) {} }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let queued = DispatchSemaphore(value: 0)
        let outgoing = Task.detached {
            queued.signal()
            return try await pages.render(location, viewport: viewport, scale: 1, columns: 2,
                rotation: 0, fit: "width", zoom: 1)
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 5), .success)
        release.signal()
        try await replacement.value
        do {
            _ = try await outgoing.value
            XCTFail("A superseded finite request must not rasterize the entire natural chapter")
        } catch is CancellationError {}
        let natural = try await pages.render(.init(page: 0), viewport: viewport, scale: 1, columns: 1,
            rotation: 0, fit: "width", zoom: 1, viewportOnly: true)
        XCTAssertNil(natural.image)
        XCTAssertGreaterThan(natural.bounds.height, 10_000)
    }

    @MainActor
    func testResizeKeepsPaintedTextWhileReplacementRenderingWaits() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("resize.html")
        let paragraphs = (0..<500).map {
            "<p>Paragraph \($0): Visible text stays on screen while this chapter reflows to the resized viewport. The replacement renderer may be busy.</p>"
        }.joined()
        try ("<html><body>" + paragraphs + "</body></html>").write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "page"; state.zoom = 1; state.spread = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 32
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        _ = state.applyChapterLayout(await pages.chapterLayout)
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
        func ready() -> Bool {
            RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        func waitForPaint() async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint()
                if ready() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Natural reader did not finish painting")
        }
        func inkPixels(in view: NSView) throws -> Int {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return (0..<(image.width * image.height)).reduce(0) { count, pixel in
                let offset = pixel * 4
                return count + (pixels[offset + 3] > 128 && pixels[offset] < 128 &&
                                pixels[offset + 1] < 128 && pixels[offset + 2] < 128 ? 1 : 0)
            }
        }
        try await waitForPaint()
        let scroll = try XCTUnwrap(state.readerScrollView)
        state.send(.preservePosition(.init(page: 0, x: 0, y: 1_000)))
        for _ in 0..<10 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
        try await waitForPaint()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 900)
        XCTAssertGreaterThan(try inkPixels(in: scroll.contentView), 100)

        // Hold the real Pages actor so the resized surface must paint before
        // either its new geometry or replacement tile render can finish.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockedRender = Task.detached { await pages.holdRenderingForResize(entered, until: release) }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        window.setContentSize(CGSize(width: 520, height: 480))
        for _ in 0..<8 {
            paint()
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertGreaterThan(try inkPixels(in: scroll.contentView), 100,
                                 "A pending resize render must not replace the passage with blank paper")
        }
        XCTAssertFalse(ready(), "Retained old pixels must not count as the new tiles being ready")
        release.signal()
        await blockedRender.value
        try await waitForPaint()
        XCTAssertGreaterThan(try inkPixels(in: scroll.contentView), 100)
        XCTAssertNil(state.error)

        state.document = nil
        for _ in 0..<4 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(try inkPixels(in: scroll.contentView), 0,
                       "Closing a document must remove current and retained tile pixels")
    }

    @MainActor
    func testNaturalReaderKeepsFullWidthAndSmallWheelDistanceAcrossOldPageEdges() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("continuous.html")
        let paragraphs = (0..<1_000).map { "<p>Paragraph \($0): Natural continuous reading keeps ordinary line spacing throughout this chapter, across every former screen and paper boundary.</p>" }.joined()
        try ("<html><body>" + paragraphs + "</body></html>").write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "page"; state.zoom = 1; state.spread = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 32
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        _ = state.applyChapterLayout(await pages.chapterLayout)
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
        func waitFor(_ condition: () async throws -> Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint()
                if try await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Natural continuous reader did not settle", line: line)
        }
        try await waitFor {
            let bounds = try await pages.bounds(0)
            return bounds.width == 620 && bounds.height > 400 * 50 &&
                abs((state.readerFocusView?.frame.height ?? 0) - bounds.height) < 0.5 &&
                abs((state.readerScrollView?.documentView?.frame.height ?? 0) - bounds.height) < 0.5 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        let scroll = try XCTUnwrap(state.readerScrollView), canvas = try XCTUnwrap(state.readerFocusView)
        let bounds = try await pages.bounds(0), revision = await pages.layoutRevision
        XCTAssertEqual(canvas.frame.width, 620, accuracy: 0.5, "A long natural chapter must stay at reading width")
        XCTAssertEqual(canvas.frame.height, bounds.height, accuracy: 0.5, "Canvas length must not shrink the text")
        let enormous = CGSize(width: 620, height: ReadingZoom.maximumCanvasExtent * 2)
        XCTAssertEqual(RasterLayout.size(page: enormous, viewport: CGSize(width: 620, height: 400),
            columns: 1, rotation: 0, fit: "page", zoom: 1, continuous: true), enormous)
        let boundary = scroll.contentView.bounds.height * 2
        state.send(.preservePosition(.init(page: 0, x: 0, y: boundary - 4)))
        try await waitFor {
            abs(scroll.contentView.bounds.minY - (boundary - 4)) < 0.5 &&
                RasterReader.pageIsRendered(in: canvas, pages: pages, location: .init(page: 0))
        }
        for phase: CGScrollPhase in [.began, .changed] {
            let point = scroll.contentView.convert(CGPoint(x: 100, y: boundary), to: nil)
            let seed = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            let cg = try XCTUnwrap(seed.cgEvent?.copy()); cg.type = .scrollWheel
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -3)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -3)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg)), before = scroll.contentView.bounds.minY
            scroll.scrollWheel(with: event)
            for _ in 0..<4 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(scroll.contentView.bounds.minY - before, -event.scrollingDeltaY, accuracy: 0.5)
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, boundary)
        let count = await pages.count
        XCTAssertEqual(count, 1)
        window.setContentSize(CGSize(width: 620, height: 560))
        try await waitFor { scroll.contentView.bounds.height == 560 && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) }
        let afterHeight = await pages.layoutRevision, afterBounds = try await pages.bounds(0)
        XCTAssertEqual(afterHeight, revision, "Only width or typography changes natural line wrapping")
        XCTAssertEqual(afterBounds, bounds)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSmartScrollbarsSettleNaturalWidthAfterResize() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("smart-scrollbars.html")
        let paragraphs = (0..<400).map { "<p>Paragraph \($0): The visible body keeps its width and paint after a window resize.</p>" }.joined()
        try ("<html><body>" + paragraphs + "</body></html>").write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "page"; state.zoom = 1; state.spread = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 32
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "smart"
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 926, height: 768),
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
        func waitForPaint() async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint()
                if let scroll = state.readerScrollView {
                    let width = scroll.contentView.safeAreaRect.width
                    let bounds = try await pages.bounds(0)
                    if width > 0, bounds.width == width, bounds.height > scroll.contentView.bounds.height * 5,
                       RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) { return }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Natural layout did not paint at the unobscured clip width")
        }
        try await waitForPaint()
        let scroll = try XCTUnwrap(state.readerScrollView)
        if NSScroller.preferredScrollerStyle == .legacy {
            XCTAssertFalse(scroll.autohidesScrollers, "Natural overflow owns legacy visibility before restoring its reading position")
        }
        window.setContentSize(CGSize(width: 890, height: 768))
        try await waitForPaint()
        // The first painted frame can precede the command acknowledgement.
        // Let that initial completion drain before checking for another cycle.
        let drainUntil = Date().addingTimeInterval(1)
        repeat {
            paint()
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < drainUntil
        let revision = await pages.layoutRevision
        let renderedRevision = state.renderRevision
        let width = scroll.contentView.safeAreaRect.width
        let deadline = Date().addingTimeInterval(5)
        repeat {
            paint()
            try await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        XCTAssertEqual(scroll.contentView.safeAreaRect.width, width, accuracy: 0.5)
        let finalBounds = try await pages.bounds(0), finalRevision = await pages.layoutRevision
        XCTAssertEqual(finalBounds.width, width, accuracy: 0.5)
        XCTAssertEqual(finalRevision, revision, "A settled clip must not start another native reflow")
        XCTAssertEqual(state.renderRevision, renderedRevision, "A settled clip must not rebuild the visible surface")
        XCTAssertTrue(RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)))

        state.scrollbarMode = "hidden"
        try await waitForPaint()
        XCTAssertFalse(scroll.hasVerticalScroller)
        state.scrollbarMode = "smart"
        try await waitForPaint()
        XCTAssertTrue(scroll.hasVerticalScroller, "Returning to smart mode must restore a needed vertical bar")

        // Width-fit owns one scrolling axis, while explicit zoom must still
        // allow panning across an enlarged natural chapter.
        func waitForWidth(_ enlarged: Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                paint()
                if let canvas = state.readerFocusView,
                   (canvas.bounds.width > scroll.contentView.bounds.width + 1) == enlarged,
                   state.command.action == .none,
                   RasterReader.pageIsRendered(in: canvas, pages: pages, location: .init(page: 0)) { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Natural chapter did not settle after changing fit")
        }
        state.setZoom(2); state.send(.none)
        try await waitForWidth(true)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 100, dy: 0)).origin)
        scroll.reflectScrolledClipView(clip)
        XCTAssertGreaterThan(clip.bounds.minX, 0, "Explicit zoom must retain horizontal panning")
        state.setFit("width"); state.send(.none)
        try await waitForWidth(false)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.5)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSmartLegacyNaturalScrollbarHidesWhenTheDocumentFits() async throws {
        _ = NSApplication.shared
        guard NSScroller.preferredScrollerStyle == .legacy else { throw XCTSkip("Requires the system's legacy scrollbar preference") }
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("short-natural.html")
        try ("<html><body>" + String(repeating: "<p>A short document follows the available reading height.</p>", count: 8) + "</body></html>")
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "width"; state.spread = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 32
        state.userCSS = ""; state.pageMargins = nil; state.scrollbarMode = "smart"
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 180),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close(); withExtendedLifetime(directory) {} }
        func settle(overflow: Bool, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if let scroll = state.readerScrollView,
                   scroll.hasVerticalScroller == overflow,
                   (scroll.documentView!.frame.height > scroll.contentView.bounds.height) == overflow,
                   RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) {
                    XCTAssertFalse(scroll.autohidesScrollers, line: line)
                    XCTAssertFalse(scroll.hasHorizontalScroller, line: line)
                    let expectedWidth = overflow ? 620 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 620
                    XCTAssertEqual(scroll.contentView.bounds.width, expectedWidth, accuracy: 0.5, line: line)
                    return
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Natural scrollbar did not follow document overflow", line: line)
        }
        try await settle(overflow: true)
        window.setContentSize(CGSize(width: 620, height: 1_000))
        try await settle(overflow: false)
        window.setContentSize(CGSize(width: 620, height: 180))
        try await settle(overflow: true)
        XCTAssertNil(state.error)
    }
}

private extension Pages {
    func holdRenderingForResize(_ entered: DispatchSemaphore, until release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
#endif
