#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeReflowSpreadTests: XCTestCase {
    func testMixedCoverAndTextFitTheirSlotsDuringAndAfterLiveResize() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        try await checkLiveResize(try fixture(in: directory.url), start: CGSize(width: 800, height: 600),
            sizes: [CGSize(width: 620, height: 450), CGSize(width: 920, height: 480), CGSize(width: 560, height: 700)])
    }

    func testOriginalIssue82CoverAndFacingArtworkStayAlignedDuringWidthChanges() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE82_SPREAD_SAMPLES"] else {
            throw XCTSkip("Set SUMRA_ISSUE82_SPREAD_SAMPLES to the original reporter books")
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent("repeat-misalignedepubsecondroundC.epub")
        for margins in [nil, PageMargins(cssValues: [32]), PageMargins(cssValues: [12, 24, 36, 48])] {
            for start in [CGSize(width: 904, height: 524), CGSize(width: 1512, height: 847)] {
                let sizes = [-100, 100, 250].map { CGSize(width: start.width + CGFloat($0), height: start.height) }
                try await checkLiveResize(url, start: start, sizes: sizes, checkArtwork: true, margins: margins)
            }
        }
    }

    func testOriginalIssue82EFirstSpreadKeepsItsNaturalCoverPairing() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE82_SPREAD_SAMPLES"] else {
            throw XCTSkip("Set SUMRA_ISSUE82_SPREAD_SAMPLES to the original reporter books")
        }
        try await checkLiveResize(URL(fileURLWithPath: path).appendingPathComponent("repeat-misalignedepubE.epub"),
            start: CGSize(width: 904, height: 524), sizes: [CGSize(width: 660, height: 524), CGSize(width: 1512, height: 847)], checkArtwork: true)
    }

    private func checkLiveResize(_ input: URL, start: CGSize, sizes: [CGSize], checkArtwork: Bool = false, margins: PageMargins? = nil) async throws {
        let state = ReaderState(recordsHistory: false)
        let defaults = UserDefaults.standard
        let saved = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        state.flow = "paged"; state.spread = true; state.cover = false; state.fit = "page"
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 32
        state.pageMargins = margins; state.marginPresetSelection = margins == nil ? nil : "custom"; state.userCSS = ""; state.useDocumentCSS = true
        state.automaticLayout = false; state.freePan = false; state.uniformPageWidth = false
        state.trimEmptyMargins = false; state.landscapeAsSpread = false; state.rtl = false; state.scrollbarMode = "hidden"
        let pages = try Pages(input, format: .book, deferReflowLayout: true)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        let root: AnyView
        if checkArtwork {
            // Exercise the normal document-entry owner with its unprepared
            // native document and real reader controls/clearances.
            state.font = "system"; state.lineHeight = 1.6
            state.controlTopMargin = 54; state.controlBottomMargin = 44
            root = AnyView(ReaderView(state: state))
        } else {
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "serif", theme: "light",
                userCSS: state.effectiveUserCSS, pageMargins: state.pageMargins, pageSize: RasterReader.pageSize(in: start, spread: true))
            _ = try await pages.prepareFacingPages(.init(page: 0), cover: false)
            state.reflowable = true
            _ = state.applyChapterLayout(await pages.chapterLayout)
            root = AnyView(RasterReader(state: state, pages: pages, initialBounds: try await pages.bounds(0)))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: start),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        func visible() -> [RasterCanvas.Canvas] {
            canvases(host).filter { state.visiblePages.contains($0.page) }.sorted { $0.page < $1.page }
        }
        func paint() {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
        }
        func settle(count: Int = 2, after revision: Int? = nil) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                paint()
                let current = await pages.layoutRevision
                let painted = visible()
                if painted.count == count, painted.allSatisfy(\.readingReady), revision.map({ current > $0 }) ?? true {
                    // The decoder can finish repagination before the new canvases mount.
                    var currentBounds = [CGRect]()
                    for canvas in painted { currentBounds.append(try await pages.bounds(canvas.location)) }
                    if painted.map(\.pageBounds) == currentBounds { return }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Mixed EPUB spread did not settle")
            throw CancellationError()
        }
        var artwork = [PageLocation: CGRect]()
        var artworkNativeRevision = -1
        func assertSlotFit(resizing original: [CGSize]? = nil, line: UInt = #line) throws {
            let pair = visible()
            XCTAssertEqual(pair.count, 2, line: line)
            let first = try XCTUnwrap(pair.first), second = try XCTUnwrap(pair.last)
            XCTAssertNotEqual(first.pageBounds.height, second.pageBounds.height, "Exercise a natural cover beside a finite chapter page", line: line)
            let clip = try XCTUnwrap(first.enclosingScrollView?.contentView)
            let slot = (clip.safeAreaRect.width - 4) / 2
            if let original {
                let factor = original.map { min(slot / $0.width, clip.safeAreaRect.height / $0.height) }.min()!
                for (canvas, size) in zip(pair, original) {
                    XCTAssertEqual(canvas.bounds.width, size.width * factor, accuracy: 0.5, line: line)
                    XCTAssertEqual(canvas.bounds.height, size.height * factor, accuracy: 0.5, line: line)
                }
            } else {
                for canvas in pair {
                    let scale = min(slot / canvas.visibleBounds.width, clip.safeAreaRect.height / canvas.visibleBounds.height)
                    XCTAssertEqual(canvas.bounds.width, canvas.visibleBounds.width * scale, accuracy: 0.5, line: line)
                    XCTAssertEqual(canvas.bounds.height, canvas.visibleBounds.height * scale, accuracy: 0.5, line: line)
                }
            }
            for canvas in pair {
                XCTAssertTrue(clip.safeAreaRect.insetBy(dx: -0.5, dy: -0.5).contains(canvas.convert(canvas.bounds, to: clip)), line: line)
            }
            XCTAssertEqual(first.convert(first.bounds, to: host).midY, second.convert(second.bounds, to: host).midY, accuracy: 0.5, line: line)
            if checkArtwork {
                let displayed = try pair.map { canvas in
                    canvas.convert(try XCTUnwrap(artwork[canvas.location]).applying(canvas.pageTransform), to: host)
                }
                XCTAssertEqual(displayed[0].minY, displayed[1].minY, accuracy: 1, "Art top edges at \(host.bounds.size), native revision \(artworkNativeRevision), render revision \(state.renderRevision)", line: line)
                XCTAssertEqual(displayed[0].maxY, displayed[1].maxY, accuracy: 1, "Art bottom edges at \(host.bounds.size), native revision \(artworkNativeRevision), render revision \(state.renderRevision)", line: line)
                for canvas in pair {
                    let art = try XCTUnwrap(artwork[canvas.location])
                    let displayed = art.applying(canvas.pageTransform)
                    XCTAssertEqual(displayed.width, displayed.height * art.width / art.height, accuracy: 0.5, "Artwork must retain its aspect within a display pixel", line: line)
                    XCTAssertTrue(clip.safeAreaRect.insetBy(dx: -0.5, dy: -0.5).contains(canvas.convert(displayed, to: clip)), "Artwork must remain inside its viewport", line: line)
                }
            }
        }
        try await settle()
        // Initial mounting can paint its prepared bitmap before the viewport's
        // queued style command publishes on MainActor. Capture the drag's
        // bitmap identities only after that command has completed.
        await withCheckedContinuation { continuation in
            state.send(.style, completed: { continuation.resume() })
        }
        try await settle()
        func measureArtwork() async throws {
            guard checkArtwork else { return }
            let deadline = Date().addingTimeInterval(10)
            repeat {
                let pair = visible()
                // The decoder can advance ahead of SwiftUI publication. Read
                // both image boxes in one actor turn and use them only with
                // canvases displaying that exact native page geometry.
                let snapshot = try await pages.spreadArtworkSources(pair.map(\.location))
                let sources = snapshot.sources
                paint()
                let painted = visible()
                if painted.count == 2, painted.allSatisfy({ canvas in
                    canvas.readingReady && canvas.renderRevision == state.renderRevision &&
                        sources[canvas.location]?.bounds == canvas.pageBounds
                }) {
                    artworkNativeRevision = snapshot.revision
                    artwork = try Dictionary(uniqueKeysWithValues: painted.map { canvas in
                        (canvas.location, try XCTUnwrap(sources[canvas.location]?.image))
                    })
                    return
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Artwork source did not match the displayed spread")
            throw CancellationError()
        }
        try await measureArtwork()
        try assertSlotFit()
        let revision = await pages.layoutRevision
        let images = visible().map(\.image)
        let original = try visible().map { canvas in
            let clip = try XCTUnwrap(canvas.enclosingScrollView?.contentView)
            let slot = (clip.safeAreaRect.width - 4) / 2
            let scale = min(slot / canvas.visibleBounds.width, clip.safeAreaRect.height / canvas.visibleBounds.height)
            // Derive the starting fit before AppKit rounds its display frame.
            // Scaling an already rounded frame can amplify a half-pixel error.
            return CGSize(width: canvas.visibleBounds.width * scale, height: canvas.visibleBounds.height * scale)
        }
        let originalBounds = visible().map(\.pageBounds)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        for size in sizes {
            window.setContentSize(size)
            for _ in 0..<5 {
                paint(); try assertSlotFit(resizing: original)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let currentRevision = await pages.layoutRevision
            XCTAssertEqual(currentRevision, revision)
            for (canvas, image) in zip(visible(), images) {
                XCTAssertTrue(canvas.image === image, "Live resizing must retain its prepared bitmap for page \(canvas.page), native revision \(revision), render revision \(state.renderRevision)")
            }
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        if checkArtwork {
            // Start another drag before the decoder can replace the first spread.
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            window.setContentSize(CGSize(width: start.width + 125, height: start.height))
            paint()
            XCTAssertEqual(visible().map(\.pageBounds), originalBounds)
            try assertSlotFit(resizing: original)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        }
        for _ in 0..<10 {
            paint()
            if visible().map(\.pageBounds) != originalBounds { break }
            try assertSlotFit(resizing: original)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await settle(after: revision)
        try await measureArtwork()
        try assertSlotFit()
        state.cover = true
        try await settle(count: 1)
        let singleRevision = await pages.layoutRevision
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        window.setContentSize(CGSize(width: 740, height: 450))
        for _ in 0..<5 {
            paint()
            let canvas = try XCTUnwrap(visible().first), clip = try XCTUnwrap(canvas.enclosingScrollView?.contentView)
            XCTAssertEqual(visible().count, 1)
            let scale = min(clip.safeAreaRect.width / canvas.visibleBounds.width, clip.safeAreaRect.height / canvas.visibleBounds.height)
            XCTAssertEqual(canvas.bounds.width, canvas.visibleBounds.width * scale, accuracy: 0.5)
            XCTAssertEqual(canvas.bounds.height, canvas.visibleBounds.height * scale, accuracy: 0.5)
            XCTAssertTrue(clip.safeAreaRect.insetBy(dx: -0.5, dy: -0.5).contains(canvas.convert(canvas.bounds, to: clip)))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        try await settle(count: 1, after: singleRevision)
        XCTAssertNil(state.error)
    }

    func testOriginalIssue82ArtAndPDFHeightsInFitPage() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE82_SPREAD_SAMPLES"] else {
            throw XCTSkip("Set SUMRA_ISSUE82_SPREAD_SAMPLES to the original EPUB C/E and Midnight PDF directory")
        }
        let directory = URL(fileURLWithPath: path), viewport = CGSize(width: 1512, height: 945)
        for (name, format) in [("repeat-misalignedepubsecondroundC.epub", Format.book),
                               ("repeat-misalignedepubE.epub", .book), ("Midnight-pages-1-7.pdf", .pdf)] {
            let pages = try Pages(directory.appendingPathComponent(name), format: format)
            if format == .book {
                _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 0, font: "serif", theme: "light",
                    pageMargins: PageMargins(cssValues: [0]), pageSize: RasterReader.pageSize(in: viewport, spread: true))
                _ = try await pages.prepareFacingPages(.init(page: 0), cover: false)
            }
            var heights = [CGFloat]()
            for page in 0...1 {
                let result = try await pages.render(page, viewport: viewport, scale: 1, columns: 2,
                    rotation: 0, fit: "page", zoom: 1, facingPage: 1 - page)
                XCTAssertNotNil(result.image)
                let art = format == .book ? try await pages.imageBounds(page).first : result.bounds
                let bounds = try XCTUnwrap(art)
                let factor = result.display.height / result.bounds.height
                XCTAssertEqual(bounds.midY * factor, result.display.height / 2, accuracy: 0.5, name)
                heights.append(bounds.height * factor)
            }
            XCTAssertEqual(heights[0], heights[1], accuracy: 2, name)
        }
    }

    func testFixedImageMarginsReduceTheActualFitViewport() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("square.png")
        try image().write(to: input)
        let pages = try Pages(input, format: .image), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.count = await pages.count
        state.flow = "paged"; state.spread = false; state.fit = "page"; state.automaticLayout = false
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false; state.scrollbarMode = "hidden"
        state.marginPresetSelection = "custom"; state.pageMargins = PageMargins(cssValues: [11, 23, 17, 31])
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(10)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let canvas = canvases(host).first, canvas.readingReady, let clip = canvas.enclosingScrollView?.contentView {
                XCTAssertEqual(clip.bounds.width, 546, accuracy: 0.5)
                XCTAssertEqual(clip.bounds.height, 472, accuracy: 0.5)
                XCTAssertEqual(canvas.bounds.height, 472, accuracy: 0.5)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Fixed image did not paint")
    }

    private func canvases(_ view: NSView) -> [RasterCanvas.Canvas] {
        (view as? RasterCanvas.Canvas).map { [$0] } ?? view.subviews.flatMap(canvases)
    }

    private func image() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 240, bitsPerComponent: 8, bytesPerRow: 480,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 120, height: 240))
        let data = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return data as Data
    }

    private func fixture(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let prose = String(repeating: "<p>Ordinary body text remains beside the cover while the window changes size.</p>", count: 60)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "book.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest><item id='cover' href='cover.xhtml' media-type='application/xhtml+xml'/><item id='art' href='cover.png' properties='cover-image' media-type='image/png'/><item id='text' href='text.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='cover'/><itemref idref='text'/></spine></package>",
            "cover.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><img src='cover.png'/></body></html>",
            "text.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body>\(prose)</body></html>"
        ]
        for (name, text) in files { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try image().write(to: directory.appendingPathComponent("cover.png"))
        let archive = Process(); archive.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); archive.currentDirectoryURL = directory
        archive.arguments = ["-q", "-0", "book.epub"] + files.keys.sorted() + ["cover.png"]
        try runSumraProcess(archive)
        XCTAssertEqual(archive.terminationStatus, 0)
        return directory.appendingPathComponent("book.epub")
    }
}

private extension Pages {
    func spreadArtworkSources(_ locations: [PageLocation]) throws -> (revision: Int, sources: [PageLocation: (bounds: CGRect, image: CGRect?)]) {
        var sources = [PageLocation: (bounds: CGRect, image: CGRect?)]()
        for location in locations {
            sources[location] = (try bounds(location), try imageBounds(location).first)
        }
        return (layoutRevision, sources)
    }
}
#endif
