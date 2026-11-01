#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeReflowSpreadTests: XCTestCase {
    func testMixedCoverAndTextShareFitScaleDuringAndAfterLiveResize() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url)
        let state = ReaderState(recordsHistory: false)
        let defaults = UserDefaults.standard
        let saved = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        state.flow = "paged"; state.spread = true; state.cover = false; state.fit = "page"
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"; state.margin = 32
        state.pageMargins = nil; state.marginPresetSelection = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.automaticLayout = false; state.freePan = false; state.uniformPageWidth = false
        state.trimEmptyMargins = false; state.landscapeAsSpread = false; state.rtl = false; state.scrollbarMode = "hidden"
        let pages = try Pages(input, format: .book, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "serif", theme: "light",
            userCSS: state.effectiveUserCSS, pageSize: CGSize(width: 398, height: 600))
        _ = try await pages.prepareFacingPages(.init(page: 0), cover: false)
        state.document = ReadingDocument(url: input, content: .pages(pages)); state.reflowable = true
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let initialBounds = try await pages.bounds(0)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages, initialBounds: initialBounds))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
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
                if visible().count == count, visible().allSatisfy(\.readingReady), revision.map({ current > $0 }) ?? true { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "Mixed EPUB spread did not settle")
            throw CancellationError()
        }
        func assertSharedFit(line: UInt = #line) throws {
            let pair = visible()
            XCTAssertEqual(pair.count, 2, line: line)
            let first = try XCTUnwrap(pair.first), second = try XCTUnwrap(pair.last)
            XCTAssertNotEqual(first.pageBounds.height, second.pageBounds.height, "Exercise a natural cover canvas beside a finite text page", line: line)
            let clip = try XCTUnwrap(first.enclosingScrollView?.contentView)
            let slot = (clip.safeAreaRect.width - 4) / 2
            let scale = pair.map { min(slot / $0.pageBounds.width, clip.safeAreaRect.height / $0.pageBounds.height) }.min()!
            for canvas in pair {
                XCTAssertEqual(canvas.bounds.width, canvas.pageBounds.width * scale, accuracy: 0.5, line: line)
                XCTAssertEqual(canvas.bounds.height, canvas.pageBounds.height * scale, accuracy: 0.5, line: line)
                XCTAssertTrue(clip.safeAreaRect.insetBy(dx: -0.5, dy: -0.5).contains(canvas.convert(canvas.bounds, to: clip)), line: line)
            }
            XCTAssertEqual(first.convert(.zero, to: host).y, second.convert(.zero, to: host).y, accuracy: 0.5, line: line)
        }
        try await settle()
        // Initial mounting can paint its prepared bitmap before the viewport's
        // queued style command publishes on MainActor. Capture the drag's
        // bitmap identities only after that command has completed.
        await withCheckedContinuation { continuation in
            state.send(.style, completed: { continuation.resume() })
        }
        try await settle()
        try assertSharedFit()
        let revision = await pages.layoutRevision
        let images = visible().map(\.image)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        for size in [CGSize(width: 620, height: 450), CGSize(width: 920, height: 480), CGSize(width: 560, height: 700)] {
            window.setContentSize(size)
            for _ in 0..<5 {
                paint(); try assertSharedFit()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let currentRevision = await pages.layoutRevision
            XCTAssertEqual(currentRevision, revision)
            for (canvas, image) in zip(visible(), images) {
                XCTAssertTrue(canvas.image === image, "Live resizing must retain its prepared bitmap for page \(canvas.page), native revision \(revision), render revision \(state.renderRevision)")
            }
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        try await settle(after: revision)
        try assertSharedFit()
        state.cover = true
        try await settle(count: 1)
        let singleRevision = await pages.layoutRevision
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        window.setContentSize(CGSize(width: 740, height: 450))
        for _ in 0..<5 {
            paint()
            let canvas = try XCTUnwrap(visible().first), clip = try XCTUnwrap(canvas.enclosingScrollView?.contentView)
            XCTAssertEqual(visible().count, 1)
            let scale = min(clip.safeAreaRect.width / canvas.pageBounds.width, clip.safeAreaRect.height / canvas.pageBounds.height)
            XCTAssertEqual(canvas.bounds.width, canvas.pageBounds.width * scale, accuracy: 0.5)
            XCTAssertEqual(canvas.bounds.height, canvas.pageBounds.height * scale, accuracy: 0.5)
            XCTAssertTrue(clip.safeAreaRect.insetBy(dx: -0.5, dy: -0.5).contains(canvas.convert(canvas.bounds, to: clip)))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        try await settle(count: 1, after: singleRevision)
        XCTAssertNil(state.error)
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
#endif
