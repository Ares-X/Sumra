#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderPredictionTests: XCTestCase {
    private func waitForQueued(_ count: Int, in queue: ReaderRenderQueue) async throws {
        let deadline = Date().addingTimeInterval(5)
        while queue.waitingCount != count, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(queue.waitingCount, count)
    }

    func testVisibleRenderingAndPromotedPredictionRunBeforeBackgroundPixels() async throws {
        let queue = ReaderRenderQueue()
        let entered = expectation(description: "Active rendering entered")
        var release: AsyncStream<Void>.Continuation!
        let held = AsyncStream<Void> { release = $0 }
        var order: [String] = []
        let active = Task {
            try await queue.perform {
                entered.fulfill()
                for await _ in held { break }
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        defer { release.finish() }
        let background = Task {
            try await queue.perform(priority: .init(visible: false)) {
                await MainActor.run { order.append("background") }
            }
        }
        try await waitForQueued(1, in: queue)
        let priority = ReaderRenderPriority(visible: false)
        let predicted = Task {
            try await queue.perform(priority: priority) {
                await MainActor.run { order.append("promoted") }
            }
        }
        try await waitForQueued(2, in: queue)
        let visible = Task {
            try await queue.perform {
                await MainActor.run { order.append("visible") }
            }
        }
        try await waitForQueued(3, in: queue)
        priority.promote()
        release.yield(())
        try await active.value; try await background.value; try await predicted.value; try await visible.value
        XCTAssertEqual(order, ["promoted", "visible", "background"],
                       "The original predicted request must move ahead of queued background pixels when it becomes visible")
        XCTAssertFalse(predicted.isCancelled)
    }

    func testCancellingQueuedRenderingCompletesBeforeActiveNativeWorkIsReleased() async throws {
        let queue = ReaderRenderQueue()
        let entered = expectation(description: "Active rendering entered")
        var release: AsyncStream<Void>.Continuation!
        let held = AsyncStream<Void> { release = $0 }
        let active = Task {
            try await queue.perform {
                entered.fulfill()
                for await _ in held { break }
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        defer { release.finish() }
        var cancelledRendered = false
        let cancelled = Task {
            try await queue.perform(priority: .init(visible: false)) {
                await MainActor.run { cancelledRendered = true }
            }
        }
        try await waitForQueued(1, in: queue)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Queued cancellation must throw")
        } catch is CancellationError {}
        XCTAssertEqual(queue.waitingCount, 0)
        XCTAssertFalse(cancelledRendered, "A cancelled request must not enter the decoder")
        let visible = Task { try await queue.perform { 42 } }
        try await waitForQueued(1, in: queue)
        release.yield(())
        try await active.value
        let result = try await visible.value
        XCTAssertEqual(result, 42, "Cancelling a waiter must preserve the active decoder permit")
    }

    func testIndependentPDFReplaysRunConcurrentlyWithinTheQueueCapacity() async throws {
        let queue = ReaderRenderQueue(concurrency: 2)
        let entered = expectation(description: "Both replay permits entered")
        entered.expectedFulfillmentCount = 2
        var releases = [AsyncStream<Void>.Continuation]()
        let held = (0..<2).map { _ in AsyncStream<Void> { releases.append($0) } }
        let workers = held.map { stream in Task {
            try await queue.perform {
                entered.fulfill()
                for await _ in stream { break }
            }
        } }
        await fulfillment(of: [entered], timeout: 5)
        defer { releases.forEach { $0.finish() } }
        let next = Task { try await queue.perform { 42 } }
        try await waitForQueued(1, in: queue)
        releases[0].yield(())
        let result = try await next.value
        XCTAssertEqual(result, 42)
        releases[1].yield(())
        for worker in workers { try await worker.value }
        XCTAssertEqual(queue.waitingCount, 0)
    }

    private func paint(_ host: NSHostingView<RasterReader>) {
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
    }

    private func waitFor(_ host: NSHostingView<RasterReader>, state: ReaderState,
                         line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            paint(host)
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Reader did not reach the expected painted state", line: line)
        throw CancellationError()
    }

    private func field(_ label: String, in value: Any) -> Any? {
        Mirror(reflecting: value).children.first(where: { $0.label == label })?.value
    }

    private func unwrapped(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }

    private func predictedPage(in scroll: NSScrollView, state: ReaderState) -> Int? {
        guard let token = unwrapped(field("prediction", in: scroll)),
              let location = field("location", in: token) as? PageLocation else { return nil }
        return state.pageNumber(location)
    }

    private func image(in canvas: NSView?) -> CGImage? {
        guard let canvas, let value = unwrapped(field("image", in: canvas)) else { return nil }
        return (value as! CGImage)
    }

    private func darkPixels(in view: NSView) throws -> Int {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).reduce(0) { count, index in
            let pixel = index * 4
            return count + (pixels[pixel] < 128 && pixels[pixel + 1] < 128 && pixels[pixel + 2] < 128 ? 1 : 0)
        }
    }

    private func comic(in directory: URL, brokenPage: Int? = nil) throws -> URL {
        let folder = directory.appendingPathComponent("Prediction", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for page in 0..<6 {
            let output = folder.appendingPathComponent("\(page + 1).png")
            if page == brokenPage {
                try Data("broken neighbor".utf8).write(to: output)
                continue
            }
            let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 420,
                bitsPerComponent: 8, bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(page) / 4, green: 0.25, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 420))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL,
                "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        return folder
    }

    private func twoChapterEPUB(in directory: URL) throws -> URL {
        let metadata = directory.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='a' href='a.xhtml' media-type='application/xhtml+xml'/><item id='b' href='b.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>",
            "a.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body>" + String(repeating: "<p>First chapter has ordinary readable text near its seam.</p>", count: 24) + "</body></html>",
            "b.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body>" + String(repeating: "<p>Second chapter keeps readable text after crossing the seam.</p>", count: 24) + "</body></html>"
        ]
        for (name, content) in files {
            try content.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype", "META-INF/container.xml", "content.opf", "a.xhtml", "b.xhtml"]
        try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("book.epub")
    }

    private func canvas(for location: PageLocation, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if field("location", in: view) as? PageLocation == location,
           field("tilePredictionViewport", in: view) != nil { return view }
        for child in view.subviews {
            if let result = canvas(for: location, in: child) { return result }
        }
        return nil
    }

    private func openComic(_ folder: URL, initialPage: Int = 0) async throws -> (Pages, ReaderState, NSHostingView<RasterReader>, NSWindow) {
        let pages = try Pages(folder, format: .comic)
        try await pages.seedImageBounds(page: 0, uniform: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: folder, content: .pages(pages))
        state.count = await pages.count; state.page = initialPage
        state.flow = "continuous"; state.fit = "width"; state.spread = false
        state.automaticLayout = false; state.scrollbarMode = "hidden"
        state.freePan = false; state.trimEmptyMargins = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 390),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        return (pages, state, host, window)
    }

    func testNeighborPredictionWaitsForVisiblePaintAndKeepsOffscreenPagesUnmounted() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let folder = try comic(in: directory.url)
        let (pages, state, host, window) = try await openComic(folder)
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        try await waitFor(host, state: state) {
            guard let scroll = state.readerScrollView else { return false }
            return RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0)) &&
                predictedPage(in: scroll, state: state) == 1
        }
        let scroll = try XCTUnwrap(state.readerScrollView)
        XCTAssertEqual(scroll.documentView?.subviews.count, 1,
                       "Pre-rendering a neighbor must not mount its view or accessibility children")
        XCTAssertEqual(state.page, 0)
        XCTAssertNil(state.error)
        let firstImage = try XCTUnwrap(image(in: state.readerFocusView))

        state.send(.preservePosition(.init(page: 1, x: 0, y: 0)))
        try await waitFor(host, state: state) {
            state.page == 1 && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                                                          location: .init(page: 1))
        }
        XCTAssertEqual(scroll.documentView?.subviews.count, 1)
        state.send(.preservePosition(.init(page: 0, x: 0, y: 0)))
        try await waitFor(host, state: state) {
            state.page == 0 && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages,
                                                          location: .init(page: 0))
        }
        XCTAssertTrue(try XCTUnwrap(image(in: state.readerFocusView)) === firstImage,
                      "A short reverse scroll should reuse the cached preview")
        XCTAssertEqual(scroll.documentView?.subviews.count, 1)
    }

    func testBrokenPredictedNeighborDoesNotReportAnErrorForVisiblePage() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let folder = try comic(in: directory.url, brokenPage: 5)
        let (pages, state, host, window) = try await openComic(folder, initialPage: 4)
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        try await waitFor(host, state: state) {
            guard let scroll = state.readerScrollView else { return false }
            return RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 4)) &&
                predictedPage(in: scroll, state: state) == 5
        }
        for _ in 0..<20 { paint(host); try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(state.error, "Only a visible page failure may replace the reader with an error")
        XCTAssertEqual(state.readerScrollView?.documentView?.subviews.count, 1)
    }

    func testNaturalChapterWarmsNextViewportAndRetainsPaintedTileAcrossShortScroll() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = directory.url.appendingPathComponent("natural-prediction.html")
        let paragraphs = (0..<160).map {
            "<p>Passage \($0): The reader keeps the painted source passage while warming the next natural viewport.</p>"
        }.joined()
        try ("<html><body>" + paragraphs + "</body></html>").write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .html), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = true; state.searchable = true; state.automaticLayout = false
        state.flow = "continuous"; state.fit = "width"; state.spread = false
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 24
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        try await waitFor(host, state: state) {
            guard let canvas = state.readerFocusView else { return false }
            return RasterReader.pageIsRendered(in: canvas, pages: pages, location: .init(page: 0)) &&
                unwrapped(field("tilePredictionViewport", in: canvas)) != nil &&
                ((field("tileImages", in: canvas) as? [RasterLayout.Tile: CGImage])?.count ?? 0) >= 2
        }
        let canvas = try XCTUnwrap(state.readerFocusView)
        let scroll = try XCTUnwrap(state.readerScrollView)
        let initialTiles = try XCTUnwrap(field("tileImages", in: canvas) as? [RasterLayout.Tile: CGImage])
        let first = try XCTUnwrap(initialTiles.min(by: { $0.key.y < $1.key.y }))
        XCTAssertEqual(scroll.documentView?.subviews.count, 1)

        // Hold the actual decoder so scrolling can exercise a prediction that
        // has not completed. Pixel motion must not throw that useful work away.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = Task.detached { await pages.holdPredictionRendering(entered, until: release) }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitFor(host, state: state) {
            unwrapped(field("tilePredictionTask", in: canvas)) as? Task<Void, Never> != nil
        }
        let prediction = try XCTUnwrap(unwrapped(field("tilePredictionTask", in: canvas)) as? Task<Void, Never>)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        paint(host)
        try await Task.sleep(nanoseconds: 10_000_000)
        paint(host)
        XCTAssertFalse(prediction.isCancelled, "A one-pixel scroll must retain the useful predicted tile")
        let predictedTile = try XCTUnwrap(unwrapped(field("tilePredictionTile", in: canvas)) as? RasterLayout.Tile)
        // Enter the predicted strip while the decoder remains held. The visible
        // request must join its existing task rather than cancel and rerender it.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 321))
        scroll.reflectScrolledClipView(scroll.contentView)
        paint(host)
        try await Task.sleep(nanoseconds: 10_000_000)
        paint(host)
        XCTAssertFalse(prediction.isCancelled, "Making a predicted tile visible must continue its render")
        release.signal(); await blocked.value; await prediction.value
        try await waitFor(host, state: state) {
            RasterReader.pageIsRendered(in: canvas, pages: pages, location: .init(page: 0))
        }
        XCTAssertNotNil((field("tileImages", in: canvas) as? [RasterLayout.Tile: CGImage])?[predictedTile],
                        "The retained prediction must produce the visible tile pixels")

        state.send(.preservePosition(.init(page: 0, x: 0, y: 250)))
        try await waitFor(host, state: state) {
            scroll.contentView.bounds.minY >= 249 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        let forwardTiles = try XCTUnwrap(field("tileImages", in: canvas) as? [RasterLayout.Tile: CGImage])
        XCTAssertTrue(forwardTiles[first.key] === first.value,
                      "A short forward scroll should retain the already painted tile")
        state.send(.preservePosition(.init(page: 0, x: 0, y: 0)))
        try await waitFor(host, state: state) {
            scroll.contentView.bounds.minY < 1 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        let reverseTiles = try XCTUnwrap(field("tileImages", in: canvas) as? [RasterLayout.Tile: CGImage])
        XCTAssertTrue(reverseTiles[first.key] === first.value,
                      "Returning to the source passage should reuse the same tile pixels")

        state.send(.preservePosition(.init(page: 0, x: 0, y: 1_000)))
        try await waitFor(host, state: state) {
            scroll.contentView.bounds.minY >= 999 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        let sourceY = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(try darkPixels(in: scroll.contentView), 100)
        window.setContentSize(CGSize(width: 480, height: 380))
        try await waitFor(host, state: state) {
            scroll.contentView.bounds.height == 380 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(page: 0))
        }
        XCTAssertEqual(scroll.contentView.bounds.minY, sourceY, accuracy: 1,
                       "Changing viewport height should keep the same source position")
        XCTAssertGreaterThan(try darkPixels(in: scroll.contentView), 100,
                             "The resized viewport must retain painted text")
        XCTAssertNil(state.error)
    }

    func testEPUBSeamPredictsOnlyFromPaintedDirectionEdgeAndKeepsVisibleHosts() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = try twoChapterEPUB(in: directory.url)
        let pages = try Pages(input, format: .book), state = ReaderState(recordsHistory: false)
        state.fontSize = 17; state.lineHeight = 1.4; state.margin = 24; state.font = "serif"; state.theme = "light"
        state.flow = "continuous"; state.fit = "width"; state.spread = false; state.automaticLayout = false
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "serif",
                                     theme: "light", userCSS: state.effectiveUserCSS,
                                     pageSize: CGSize(width: 480, height: 0))
        _ = try await pages.ensureFullLayout()
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.reflowable = true
        _ = state.applyChapterLayout(await pages.chapterLayout)
        XCTAssertEqual(state.count, 2)
        let firstHeight = try await pages.bounds(PageLocation(chapter: 0, page: 0)).height
        XCTAssertGreaterThan(firstHeight, 360)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        let firstLocation = PageLocation(chapter: 0, page: 0)
        let secondLocation = PageLocation(chapter: 1, page: 0)
        try await waitFor(host, state: state) {
            RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: firstLocation)
        }
        let scroll = try XCTUnwrap(state.readerScrollView)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = Task.detached { await pages.holdPredictionRendering(entered, until: release) }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let seamY = firstHeight - 90
        scroll.contentView.scroll(to: CGPoint(x: 0, y: seamY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitFor(host, state: state) {
            abs(scroll.contentView.bounds.minY - seamY) < 1 &&
                scroll.documentView?.subviews.count == 2 &&
                canvas(for: firstLocation, in: scroll.documentView) != nil &&
                canvas(for: secondLocation, in: scroll.documentView) != nil
        }
        let firstCanvas = try XCTUnwrap(canvas(for: firstLocation, in: scroll.documentView))
        let secondCanvas = try XCTUnwrap(canvas(for: secondLocation, in: scroll.documentView))
        XCTAssertNotEqual(unwrapped(field("tilePredictionViewport", in: firstCanvas)) as? CGRect,
                          firstCanvas.visibleRect,
                          "The painted first chapter must not predict for the seam before the other visible chapter")
        XCTAssertNil(unwrapped(field("tilePredictionViewport", in: secondCanvas)))
        release.signal(); await blocked.value
        try await waitFor(host, state: state) {
            let firstReady = RasterReader.pageIsRendered(in: firstCanvas, pages: pages, location: firstLocation)
            let secondReady = RasterReader.pageIsRendered(in: secondCanvas, pages: pages, location: secondLocation)
            let predicted = unwrapped(field("tilePredictionViewport", in: secondCanvas))
            return firstReady && secondReady && predicted != nil
        }
        XCTAssertNotEqual(unwrapped(field("tilePredictionViewport", in: firstCanvas)) as? CGRect,
                          firstCanvas.visibleRect,
                          "Only the forward edge chapter should warm its next viewport")
        let secondTiles = try XCTUnwrap(field("tileImages", in: secondCanvas) as? [RasterLayout.Tile: CGImage])
        let painted = try XCTUnwrap(secondTiles.min(by: { $0.key.y < $1.key.y }))
        XCTAssertGreaterThan(try darkPixels(in: scroll.contentView), 100)

        state.send(.preservePosition(.init(page: 1, x: 0, y: 30, anchor: "1:0")))
        try await waitFor(host, state: state) {
            state.pageLocation(state.page) == secondLocation &&
                scroll.documentView?.subviews.count == 1 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: secondLocation)
        }
        let after = try XCTUnwrap(canvas(for: secondLocation, in: scroll.documentView))
        let retained = try XCTUnwrap(field("tileImages", in: after) as? [RasterLayout.Tile: CGImage])
        XCTAssertTrue(retained[painted.key] === painted.value,
                      "Crossing the seam should keep the already painted second-chapter tile")
        XCTAssertGreaterThan(try darkPixels(in: scroll.contentView), 100)
        XCTAssertNil(state.error)
    }
}

private extension Pages {
    func holdPredictionRendering(_ entered: DispatchSemaphore, until release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
#endif
