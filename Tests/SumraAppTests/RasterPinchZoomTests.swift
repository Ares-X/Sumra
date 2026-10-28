#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class RasterPinchZoomTests: XCTestCase {
    @MainActor
    func testPinchKeepsPagePointAcrossRasterAndReflowLayouts() async throws {
        _ = NSApplication.shared
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before reader integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pdf = directory.url.appendingPathComponent("anchor.pdf")
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let writer = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &media, nil))
        for _ in 0..<4 {
            writer.beginPDFPage(nil); writer.setFillColor(NSColor.red.cgColor); writer.fill(media)
            writer.endPDFPage()
        }
        writer.closePDF()
        let comic = directory.url.appendingPathComponent("comic", isDirectory: true)
        try FileManager.default.createDirectory(at: comic, withIntermediateDirectories: true)
        let image = try XCTUnwrap(CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8,
            bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image.setFillColor(NSColor.red.cgColor); image.fill(media)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(image.makeImage())).representation(using: .png, properties: [:]))
        for index in 0..<4 {
            let width = index % 2 == 0 ? 600 : 900
            let art = try XCTUnwrap(CGContext(data: nil, width: width, height: 800, bitsPerComponent: 8,
                bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            art.setFillColor(NSColor.red.cgColor); art.fill(CGRect(x: 0, y: 0, width: width, height: 800))
            try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(art.makeImage())).representation(using: .png, properties: [:]))
                .write(to: comic.appendingPathComponent("\(index).png"))
        }
        let fb2 = directory.url.appendingPathComponent("anchor.fb2")
        try """
        <FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0' xmlns:l='http://www.w3.org/1999/xlink'>
        <description><title-info><book-title>Pinch anchor</book-title><lang>en</lang></title-info></description>
        <body><section><title><p>Pinch anchor</p></title><p><image l:href='#art'/></p><p>Author</p></section>
        <section>\(String(repeating: "<p>Following paragraphs preserve the zoomed page position.</p>", count: 70))</section></body>
        <binary id='art' content-type='image/png'>\(png.base64EncodedString())</binary></FictionBook>
        """.write(to: fb2, atomically: true, encoding: .utf8)

        let epub = try imageEPUB(in: directory.url, image: png)
        for (input, format, flow, spread, fit) in [
            (fb2, Format.book, "paged", false, "page"),
            (fb2, .book, "continuous", false, "actual"),
            (pdf, .pdf, "paged", true, "page"),
            (pdf, .pdf, "continuous", false, "actual"),
            (comic, .comic, "paged", false, "actual"),
            (comic, .comic, "continuous", true, "page"),
            (epub, .book, "paged", false, "page")
        ] {
            try await check(input: input, format: format, flow: flow, spread: spread, fit: fit)
        }
        try await check(input: pdf, format: .pdf, flow: "paged", spread: false, fit: "page", rotation: 90)
        try await check(input: comic, format: .comic, flow: "paged", spread: false, fit: "actual", uniform: true, initialPage: 1)
        for side in [0, 1] {
            try await check(input: pdf, format: .pdf, flow: "paged", spread: true, fit: "page", anchorSide: side)
            try await check(input: comic, format: .comic, flow: "paged", spread: true, fit: "page", anchorSide: side)
            try await check(input: epub, format: .book, flow: "paged", spread: true, fit: "page", anchorSide: side)
        }
    }

    @MainActor
    func testOriginalAliceMOBIAndFB2Pinch() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_LEGACY_TITLE_SAMPLES"] else {
            throw XCTSkip("Set SUMRA_LEGACY_TITLE_SAMPLES to the original Alice sample directory")
        }
        for suffix in ["fb2", "mobi"] {
            let source = URL(fileURLWithPath: path).appendingPathComponent("AlicesAdventuresinWonderland_Chapter1." + suffix)
            try await check(input: source, format: .book, flow: "paged", spread: false, fit: "page")
        }
    }

    @MainActor
    func testOriginalEPUBAndAZW3Pinch() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_FORMAT_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("Set SUMRA_FORMAT_SAMPLE_DIRECTORY to the original format sampler")
        }
        for suffix in ["epub", "azw3"] {
            let source = URL(fileURLWithPath: path).appendingPathComponent("sample_illustrated." + suffix)
            try await check(input: source, format: .book, flow: "paged", spread: false, fit: "page")
        }
    }

    @MainActor
    func testOriginalIssue42EPUBSpreadPinchKeepsEitherPagePoint() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE42_RESIZE_EPUB"] else {
            throw XCTSkip("Set SUMRA_ISSUE42_RESIZE_EPUB to misalignedepubsecondroundC.epub")
        }
        for side in [0, 1] {
            try await check(input: URL(fileURLWithPath: path), format: .book,
                flow: "paged", spread: true, fit: "page", anchorSide: side)
        }
    }

    private func imageEPUB(in directory: URL, image: Data) throws -> URL {
        let root = directory.appendingPathComponent("epub", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='chapter' href='chapter.xhtml' media-type='application/xhtml+xml'/><item id='art' href='art.png' media-type='image/png'/></manifest><spine><itemref idref='chapter'/></spine></package>",
            "chapter.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><h1>Image anchor</h1><img src='art.png' style='width:240px;height:320px'/><p>Following text keeps the image in its native reflow page.</p><p style='page-break-before:always'>The facing page keeps its own source point.</p><img src='art.png' style='width:240px;height:320px'/></body></html>"
        ]
        for (name, text) in files { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try image.write(to: root.appendingPathComponent("art.png"))
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-0", "image.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted() + ["art.png"]
        try runSumraProcess(zip); XCTAssertEqual(zip.terminationStatus, 0)
        return root.appendingPathComponent("image.epub")
    }

    @MainActor
    func testRightPageAnchorWaitsForBothSpreadFramesAtZoomInAndOut() throws {
        _ = NSApplication.shared
        for factor in [2.0, 0.5] {
            let state = ReaderState(recordsHistory: false)
            state.count = 2; state.spread = true; state.cover = false; state.zoom = 1; state.fit = "actual"
            state.rotation = 0; state.rtl = false; state.landscapeAsSpread = false
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 360))
            let document = NSView(frame: CGRect(x: 0, y: 0, width: 1204, height: 800))
            var canvases = [RasterCanvas.Canvas]()
            for index in 0..<2 {
                let canvas = RasterCanvas.Canvas(frame: CGRect(x: CGFloat(index)*604, y: 0, width: 600, height: 800))
                canvas.state = state; canvas.page = index; canvas.location = .init(page: index)
                canvas.pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800); canvas.visibleBounds = canvas.pageBounds
                canvas.lastDisplaySize = canvas.bounds.size; document.addSubview(canvas); canvases.append(canvas)
            }
            scroll.documentView = document
            RasterPinchZoom.attach(to: scroll, state: state)
            let gesture = try XCTUnwrap(scroll.gestureRecognizers.compactMap { $0 as? RasterPinchZoom }.first)
            let clip = scroll.contentView
            clip.scroll(to: CGPoint(x: 604, y: 100))
            let location = CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
            let source = canvases[1].convert(location, from: clip).applying(canvases[1].pageTransform.inverted())
            let offset = CGPoint(x: location.x-clip.bounds.minX, y: location.y-clip.bounds.minY)
            gesture.handle(phase: .began, magnification: 0, location: location)
            gesture.handle(phase: .ended, magnification: factor-1, location: location)
            // The right representable receives its new size first. Its origin
            // will move again when the left page is placed by the row owner.
            canvases[1].frame.size = CGSize(width: 600*factor, height: 800*factor)
            canvases[1].lastDisplaySize = canvases[1].bounds.size
            RasterPinchZoom.restore(in: scroll, finishing: true)
            canvases[0].frame.size = canvases[1].bounds.size
            canvases[0].lastDisplaySize = canvases[0].bounds.size
            canvases[1].frame.origin.x = canvases[0].bounds.width+4
            document.frame.size = CGSize(width: 1200*factor+4, height: 800*factor)
            RasterPinchZoom.restore(in: scroll, finishing: true)
            let point = canvases[1].convert(source.applying(canvases[1].pageTransform), to: clip)
            let expected = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: point.x-offset.x, y: point.y-offset.y), size: clip.bounds.size))
            XCTAssertEqual(clip.bounds.minX, expected.minX, accuracy: 0.5)
            XCTAssertEqual(clip.bounds.minY, expected.minY, accuracy: 0.5)
        }
    }

    @MainActor
    func testPercentageZoomPreservesViewportCenterThroughRepeatedInAndOut() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.count = 1; state.zoom = 1; state.fit = "actual"
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 360))
        let canvas = RasterCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 1200, height: 1600))
        canvas.state = state; canvas.pageBounds = canvas.bounds; canvas.visibleBounds = canvas.bounds
        canvas.lastDisplaySize = canvas.bounds.size; scroll.documentView = canvas; state.readerScrollView = scroll
        RasterPinchZoom.attach(to: scroll, state: state)
        let clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 200, y: 300))
        let revision = state.command.revision
        for zoom in [2.0, 1.25, 3.0, 0.75] {
            let center = CGPoint(x: clip.safeAreaRect.midX, y: clip.safeAreaRect.midY)
            let source = canvas.convert(center, from: clip).applying(canvas.pageTransform.inverted())
            let offset = CGPoint(x: center.x-clip.bounds.minX, y: center.y-clip.bounds.minY)
            state.setZoom(zoom)
            canvas.frame.size = CGSize(width: 1200*zoom, height: 1600*zoom)
            canvas.lastDisplaySize = canvas.bounds.size
            RasterPinchZoom.restore(in: scroll, finishing: true)
            let point = canvas.convert(source.applying(canvas.pageTransform), to: clip)
            let expected = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: point.x-offset.x, y: point.y-offset.y), size: clip.bounds.size))
            XCTAssertEqual(clip.bounds.minX, expected.minX, accuracy: 0.5)
            XCTAssertEqual(clip.bounds.minY, expected.minY, accuracy: 0.5)
            XCTAssertEqual(state.command.revision, revision, "Percentage zoom must not queue an asynchronous top-left restore")
        }
    }

    @MainActor
    func testPinchClampsScaleAndDropsAnchorForNavigation() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.zoomLimit = 2; state.zoom = 17
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 360))
        let canvas = RasterCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        canvas.state = state; canvas.pageBounds = canvas.bounds; canvas.visibleBounds = canvas.bounds
        canvas.lastDisplaySize = canvas.bounds.size
        scroll.documentView = canvas
        RasterPinchZoom.attach(to: scroll, state: state)
        let gesture = try XCTUnwrap(scroll.gestureRecognizers.compactMap { $0 as? RasterPinchZoom }.first)
        let point = CGPoint(x: 250, y: 180)
        func applyLayout() {
            canvas.frame.size = CGSize(width: 600*state.zoom, height: 800*state.zoom)
            canvas.lastDisplaySize = canvas.frame.size
            RasterPinchZoom.restore(in: scroll, finishing: true)
        }
        gesture.handle(phase: .began, magnification: 0, location: point)
        gesture.handle(phase: .changed, magnification: 100, location: point)
        XCTAssertEqual(state.zoom, 2)
        applyLayout()
        gesture.handle(phase: .ended, magnification: 100, location: point)
        applyLayout()
        XCTAssertEqual(scroll.contentView.bounds.minX, 250, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 180, accuracy: 0.5)
        gesture.handle(phase: .began, magnification: 0, location: scroll.contentView.bounds.origin)
        gesture.handle(phase: .ended, magnification: -0.999, location: point)
        XCTAssertEqual(state.zoom, ReadingZoom.minimum)
        applyLayout()
        gesture.handle(phase: .began, magnification: 0, location: scroll.contentView.bounds.origin)
        gesture.handle(phase: .changed, magnification: 9, location: point)
        state.send(.page(1))
        applyLayout()
        let origin = scroll.contentView.bounds.origin
        RasterPinchZoom.restore(in: scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin, "A navigation command ends the old page anchor")
    }

    @MainActor
    func testCancellationAndNavigationCannotResumeTheSameGesture() throws {
        _ = NSApplication.shared
        for interruption in ["cancel", "cancelled", "failed", "page", "fit", "zoom", "queued page", "queued fit", "queued zoom"] {
            let state = ReaderState(recordsHistory: false)
            state.zoomLimit = 4; state.fit = "actual"; state.zoom = 1
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 360))
            let canvas = RasterCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            canvas.state = state; canvas.pageBounds = canvas.bounds; canvas.visibleBounds = canvas.bounds
            canvas.lastDisplaySize = canvas.bounds.size; scroll.documentView = canvas; state.readerScrollView = scroll
            if interruption.hasPrefix("queued ") { state.send(.none) }
            RasterPinchZoom.attach(to: scroll, state: state)
            let gesture = try XCTUnwrap(scroll.gestureRecognizers.compactMap { $0 as? RasterPinchZoom }.first)
            let point = CGPoint(x: 250, y: 180)
            gesture.handle(phase: .began, magnification: 0, location: point)
            gesture.handle(phase: .changed, magnification: 0.25, location: point)
            switch interruption.replacingOccurrences(of: "queued ", with: "") {
            case "cancel": RasterPinchZoom.cancel(in: scroll)
            case "cancelled": gesture.handle(phase: .cancelled, magnification: 0.25, location: point)
            case "failed": gesture.handle(phase: .failed, magnification: 0.25, location: point)
            case "page": state.send(.page(1))
            case "fit": state.setFit("page")
            case "zoom": state.setZoom(0.75)
            default: break
            }
            let zoom = state.zoom, fit = state.fit, revision = state.command.revision
            gesture.handle(phase: .changed, magnification: 0.9, location: point)
            gesture.handle(phase: .ended, magnification: 1, location: point)
            XCTAssertEqual(state.zoom, zoom, "Late samples after \(interruption) must not reuse or recapture the old anchor")
            XCTAssertEqual(state.fit, fit, "Late samples must not replace the new fit mode after \(interruption)")
            XCTAssertEqual(state.command.revision, revision)
            gesture.handle(phase: .began, magnification: 0, location: point)
            gesture.handle(phase: .changed, magnification: 0.1, location: point)
            XCTAssertEqual(state.zoom, 1.1, accuracy: 0.001, "A new began starts a new gesture after \(interruption)")
        }
    }

    @MainActor
    func testNativeMarkdownPinchSurvivesItsOwnReflowCommands() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("pinch.md")
        try "# Pinch reflow\n\nMarkdown keeps its existing text-zoom gesture.".write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.zoom = 1; state.fit = "page"
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 500, height: 360))
        let canvas = RasterCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        canvas.state = state; canvas.pageBounds = canvas.bounds; canvas.visibleBounds = canvas.bounds
        canvas.lastDisplaySize = canvas.bounds.size; scroll.documentView = canvas; state.readerScrollView = scroll
        RasterPinchZoom.attach(to: scroll, state: state)
        XCTAssertFalse(scroll.gestureRecognizers.contains { $0 is RasterPinchZoom }, "Text reflow must keep its semantic SwiftUI zoom owner")
        var start: Double?
        state.magnifyMarkdown(1.25, startingAt: &start)
        XCTAssertEqual(state.zoom, 1.25)
        state.magnifyMarkdown(1.5, startingAt: &start)
        XCTAssertEqual(state.zoom, 1.5, "A pinch's own text reflow command must not terminate its gesture")
        state.didHandleCommand(state.command.revision)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        state.magnifyMarkdown(1.75, startingAt: &start)
        XCTAssertEqual(state.zoom, 1.75, "The next queued reflow command is still owned by this gesture")
        XCTAssertEqual(state.fit, "page", "Text zoom keeps its authored finite-page fit mode")
        start = nil
        state.magnifyMarkdown(0.8, startingAt: &start)
        XCTAssertEqual(state.zoom, 1.4, accuracy: 0.001, "A new text pinch starts at the previous gesture's final text size")
    }

    @MainActor
    private func check(input: URL, format: Format, flow: String, spread: Bool, fit: String,
                       rotation: Int = 0, uniform: Bool = false, initialPage: Int = 0, anchorSide: Int? = nil) async throws {
        let document = format == .book ? try ReadingDocument.open(input, deferReflowLayout: true)
            : ReadingDocument(url: input, content: .pages(try Pages(input, format: format)))
        guard case .pages(let pages) = document.content else { return XCTFail("Expected the native raster reader") }
        let state = ReaderState(recordsHistory: false)
        state.document = document
        state.reflowable = format == .book; state.flow = flow; state.fit = fit; state.zoom = 7
        state.spread = spread; state.cover = false; state.rotation = rotation; state.rtl = false
        state.automaticLayout = false; state.uniformPageWidth = uniform; state.trimEmptyMargins = false
        state.landscapeAsSpread = false
        state.freePan = false; state.scrollbarMode = "hidden"; state.presentation = false
        if state.reflowable {
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.3, margin: 24, font: "system", theme: "light",
                pageSize: CGSize(width: 500, height: flow == "continuous" ? 0 : 360))
        }
        state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        state.updatePosition(.init(page: initialPage))
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        var inspectFrame: (() -> Void)?
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
            inspectFrame?()
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            repeat {
                paint()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail("Pinch did not settle: \(format) \(flow) \(spread) \(fit), \(state.error ?? "no error")")
            throw CancellationError()
        }
        try await wait { RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) && state.readerScrollView?.gestureRecognizers.contains(where: { $0 is RasterPinchZoom }) == true }
        state.send(.none)
        try await wait { state.command.action == .none && RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: state.pageLocation(state.page)) }
        let scroll = try XCTUnwrap(state.readerScrollView), clip = scroll.contentView
        let gesture = try XCTUnwrap(scroll.gestureRecognizers.compactMap { $0 as? RasterPinchZoom }.first)
        func canvases(_ view: NSView) -> [RasterCanvas.Canvas] {
            (view as? RasterCanvas.Canvas).map { [$0] } ?? view.subviews.flatMap(canvases)
        }
        if anchorSide != nil {
            try await wait { canvases(host).filter { state.visiblePages.contains($0.page) && $0.readingReady }.count == 2 }
        }
        let selectedCanvas: RasterCanvas.Canvas?
        if let side = anchorSide {
            let row = canvases(host).filter { state.visiblePages.contains($0.page) }
                .sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
            selectedCanvas = row.indices.contains(side) ? row[side] : nil
        } else { selectedCanvas = state.readerFocusView as? RasterCanvas.Canvas }
        let canvas = try XCTUnwrap(selectedCanvas)
        // Use the displayed page center for the fit-to-custom transition; the
        // outer canvas edges correctly constrain off-center zoomed-out points.
        let point = canvas.convert(CGPoint(x: canvas.bounds.midX, y: min(canvas.bounds.midY, 150)), to: clip)
        let initialOffset = CGPoint(x: point.x-clip.bounds.minX, y: point.y-clip.bounds.minY)
        let source = canvas.convert(point, from: clip).applying(canvas.pageTransform.inverted())
        var maxPaintDrift: CGFloat = 0
        var lastDrift: CGFloat = 0
        func anchored(_ source: CGPoint, _ offset: CGPoint) -> Bool {
            let target = canvas.convert(source.applying(canvas.pageTransform), to: clip)
            let desired = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: target.x-offset.x, y: target.y-offset.y), size: clip.bounds.size))
            lastDrift = max(abs(desired.minX-clip.bounds.minX), abs(desired.minY-clip.bounds.minY))
            return lastDrift < 1
        }
        let originalScale = Double(hypot(canvas.pageTransform.a, canvas.pageTransform.b))
        inspectFrame = {
            XCTAssertTrue(anchored(source, initialOffset), "Every painted frame keeps the original anchor: \(format) \(flow)")
            maxPaintDrift = max(maxPaintDrift, lastDrift)
        }
        let revision = state.command.revision
        gesture.handle(phase: .began, magnification: 0, location: point)
        for sample in 1...20 {
            gesture.handle(phase: .changed, magnification: CGFloat(sample) / 20, location: point)
            try await Task.sleep(nanoseconds: 3_000_000); paint()
        }
        gesture.handle(phase: .ended, magnification: 1, location: point)
        try await wait { abs(Double(hypot(canvas.pageTransform.a, canvas.pageTransform.b))-originalScale*2) < 0.001 && anchored(source, initialOffset) }
        XCTAssertEqual(state.zoom, originalScale*2/canvas.zoomNormalization, accuracy: 0.001, "Start from actual fitted geometry even when state.zoom was stale")
        XCTAssertEqual(state.command.revision, revision, "Trackpad samples must not enqueue asynchronous position restores")
        XCTAssertTrue(anchored(source, initialOffset), "Preserve the gesture point within canvas edge constraints: \(format) \(flow)")

        gesture.handle(phase: .began, magnification: 0, location: canvas.convert(source.applying(canvas.pageTransform), to: clip))
        for sample in 1...10 {
            gesture.handle(phase: .changed, magnification: -CGFloat(sample)/20, location: point)
            try await Task.sleep(nanoseconds: 3_000_000); paint()
        }
        gesture.handle(phase: .ended, magnification: -0.5, location: point)
        try await wait { abs(Double(hypot(canvas.pageTransform.a, canvas.pageTransform.b))-originalScale) < 0.001 && anchored(source, initialOffset) }

        // Once zoomed, repeated samples around an interior viewport point must
        // retain it to a point. Cancellation keeps the last completed scale.
        let visiblePage = canvas.visibleRect.intersection(canvas.bounds)
        let interior = canvas.convert(CGPoint(x: visiblePage.midX, y: visiblePage.midY), to: clip)
        let fixed = canvas.convert(interior, from: clip).applying(canvas.pageTransform.inverted())
        let offset = CGPoint(x: interior.x-clip.bounds.minX, y: interior.y-clip.bounds.minY)
        inspectFrame = {
            XCTAssertTrue(anchored(fixed, offset), "Every intermediate frame keeps the interior anchor: \(format) \(flow)")
            maxPaintDrift = max(maxPaintDrift, lastDrift)
        }
        let start = state.zoom
        gesture.handle(phase: .began, magnification: 0, location: interior)
        for amount in [0.1, 0.3, 0.15, 0.5] {
            gesture.handle(phase: .changed, magnification: amount, location: interior)
            try await Task.sleep(nanoseconds: 3_000_000); paint()
        }
        gesture.handle(phase: .cancelled, magnification: 0.5, location: interior)
        try await wait { abs(state.zoom-start*1.5) < 0.001 && abs(Double(hypot(canvas.pageTransform.a, canvas.pageTransform.b))-state.zoom*canvas.zoomNormalization) < 0.001 && anchored(fixed, offset) }
        XCTAssertTrue(anchored(fixed, offset), "Rapid samples and cancellation must keep the page anchor")
        inspectFrame = nil
        // A cancelled gesture stops owning subsequent navigation/scrolling.
        let origin = clip.constrainBoundsRect(CGRect(origin: CGPoint(x: 20, y: 40), size: clip.bounds.size)).origin
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
        for _ in 0..<5 { paint(); try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(clip.bounds.minY, origin.y, accuracy: 1, "Scroll after cancel: \(format) \(flow), command \(state.command), fit \(state.fit)")
        print("Pinch max painted-frame drift=\(maxPaintDrift)pt: \(format) \(flow) spread=\(spread), fit=\(fit), scale \(originalScale) → \(state.zoom)")
    }
}
#endif
