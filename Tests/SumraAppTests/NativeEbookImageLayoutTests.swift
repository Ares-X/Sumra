#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class NativeEbookImageLayoutTests: XCTestCase {
    private func picture(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fixture(in directory: URL, suffix: String, count: Int = 4, landscape: Bool = false) throws -> URL {
        let image = try picture(width: 1600, height: landscape ? 800 : 2400)
        let source = directory.appendingPathComponent("illustrations." + suffix)
        let contents: String
        if suffix == "fb2" {
            let illustrations = String(repeating: "<section><image l:href='#art'/></section>", count: count)
            contents = """
                <FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0' xmlns:l='http://www.w3.org/1999/xlink'>
                <description><title-info><book-title>Illustrations</book-title><lang>en</lang></title-info></description>
                <body>\(illustrations)</body><binary id='art' content-type='image/png'>\(image.base64EncodedString())</binary></FictionBook>
                """
        } else {
            try image.write(to: directory.appendingPathComponent("art.png"))
            let illustrations = String(repeating: "<p><img src='art.png'/></p>", count: count)
            contents = "<html><head><style>@page{margin:0}body{margin:8px}p{margin:12px 0}</style></head><body>\(illustrations)</body></html>"
        }
        try contents.write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private let boundaryCSS = "@page{margin:0}body{margin:8px}p,section{margin:0}.figure{page-break-inside:avoid}"

    private func mixedFixture(in directory: URL, suffix: String, landscape: Bool = false) throws -> URL {
        let image = try picture(width: 1600, height: landscape ? 800 : 2400)
        let leading = (0..<18).map { "<p>LEADING \($0). Source prose before the image.</p>" }.joined()
        let art = suffix == "fb2" ? "<image l:href='#art'/>" : suffix == "mobi" ? "<img recindex='1'/>" : "<img src='art.png'/>"
        let body = leading + "<p id='before'>BEFORE FIGURE</p><section class='figure' id='art-anchor'>" + art +
            "<p id='caption'>ASSOCIATED CAPTION</p></section><p id='after'>AFTER FIGURE</p>"
        let contents: String
        if suffix == "fb2" {
            contents = """
                <FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0' xmlns:l='http://www.w3.org/1999/xlink'>
                <description><title-info><book-title>Mixed illustrations</book-title><lang>en</lang></title-info></description>
                <body><section>\(body)</section></body><binary id='art' content-type='image/png'>\(image.base64EncodedString())</binary></FictionBook>
                """
        } else {
            try image.write(to: directory.appendingPathComponent("art.png"))
            contents = "<html><body>\(body)</body></html>"
        }
        let source = directory.appendingPathComponent("boundary." + suffix)
        if suffix == "mobi" { try mobiContainer(html: contents, image: image).write(to: source) }
        else { try contents.write(to: source, atomically: true, encoding: .utf8) }
        return source
    }

    private func mobiContainer(html: String, image: Data) -> Data {
        func put(_ value: Int, at offset: Int, size: Int, in data: inout Data) {
            for index in 0..<size { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (size - index - 1))) }
        }
        let text = Data(html.utf8)
        let blocks = stride(from: 0, to: text.count, by: 4096).map { Data(text[$0..<min($0 + 4096, text.count)]) }
        var header = Data(repeating: 0, count: 244)
        put(1, at: 0, size: 2, in: &header)
        put(text.count, at: 4, size: 4, in: &header)
        put(blocks.count, at: 8, size: 2, in: &header)
        put(4096, at: 10, size: 2, in: &header)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(228, at: 20, size: 4, in: &header)
        put(65001, at: 28, size: 4, in: &header)
        put(6, at: 36, size: 4, in: &header)
        put(blocks.count + 1, at: 108, size: 4, in: &header)
        put(0xffff_ffff, at: 168, size: 4, in: &header)
        let records = [header] + blocks + [image]
        var container = Data(repeating: 0, count: 78 + records.count * 8 + 2)
        container.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
        put(records.count, at: 76, size: 2, in: &container)
        for (index, record) in records.enumerated() {
            put(container.count, at: 78 + index * 8, size: 4, in: &container)
            container.append(record)
        }
        return container
    }

    func testMixedProseImageKeepsCaptionTextAndSourceAnchorsAcrossThePageBoundary() throws {
        for suffix in ["fb2", "mobihtml"] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let file = try NativeFile(mixedFixture(in: directory.url, suffix: suffix), engine: .mupdf)
            for size in [CGSize(width: 720, height: 480), CGSize(width: 360, height: 480),
                         CGSize(width: 480, height: 720), CGSize(width: 360, height: 0),
                         CGSize(width: 720, height: 480)] {
                _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light",
                                      userCSS: boundaryCSS, pageSize: size)
                let count = try XCTUnwrap(file.chapterTable?.pageCount(0))
                var occurrences = [(Int, CGRect)](), text = ""
                for index in 0..<count {
                    let page = try file.page(.init(chapter: 0, page: index))
                    text += try file.text(page) ?? ""
                    let canvas = try XCTUnwrap(file.bounds(page))
                    for art in try file.imageBounds(page) {
                        occurrences.append((page, art))
                        XCTAssertTrue(canvas.insetBy(dx: -0.03, dy: -0.03).contains(art), "Mixed prose must not clip its image: \(suffix), \(size)")
                        XCTAssertEqual(art.width / art.height, 2.0 / 3.0, accuracy: 0.002)
                    }
                }
                XCTAssertEqual(occurrences.count, 1, "Pagination must neither duplicate nor lose the image")
                let (page, art) = try XCTUnwrap(occurrences.first)
                XCTAssertTrue(try XCTUnwrap(file.text(page)).contains("ASSOCIATED CAPTION"), "The authored keep-together figure includes its caption")
                for marker in ["LEADING 0.", "LEADING 17.", "BEFORE FIGURE", "ASSOCIATED CAPTION", "AFTER FIGURE"] {
                    XCTAssertTrue(text.contains(marker), "Image fitting must retain \(marker)")
                }
                XCTAssertEqual(try file.resolve("#art-anchor")?.page, page)
                XCTAssertEqual(try file.resolve("#caption")?.page, page)
                let following = try XCTUnwrap(file.resolve("#after"))
                XCTAssertTrue(try XCTUnwrap(file.text(following.page)).contains("AFTER FIGURE"))
                if size == CGSize(width: 720, height: 480) {
                    let before = try XCTUnwrap(file.resolve("#before"))
                    let marker = try XCTUnwrap(file.matches("BEFORE FIGURE", page: before.page).first?.rects.first)
                    XCTAssertGreaterThan(marker.minY, size.height * 0.6, "The fixture must reach the lower part of a page before its image")
                    if page == before.page { XCTAssertGreaterThanOrEqual(art.minY, marker.maxY) }
                    else { XCTAssertGreaterThan(page, before.page) }
                }
            }
        }
    }

    func testFB2AndMobiImagesRemainWholeAndOccurOnceAcrossPaginationAndContinuousLayout() throws {
        for suffix in ["fb2", "mobihtml"] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let file = try NativeFile(fixture(in: directory.url, suffix: suffix), engine: .mupdf)
            for size in [CGSize(width: 720, height: 480), CGSize(width: 360, height: 480),
                         CGSize(width: 480, height: 720), CGSize(width: 1200, height: 800),
                         CGSize(width: 360, height: 0), CGSize(width: 720, height: 480)] {
                _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
                let count = try XCTUnwrap(file.chapterTable?.pageCount(0))
                var occurrences = 0
                for index in 0..<count {
                    let page = try file.page(.init(chapter: 0, page: index))
                    let canvas = try XCTUnwrap(file.bounds(page))
                    for art in try file.imageBounds(page) {
                        occurrences += 1
                        XCTAssertEqual(art.width / art.height, 2.0 / 3.0, accuracy: 0.002, "\(suffix), \(size)")
                        XCTAssertTrue(canvas.insetBy(dx: -0.03, dy: -0.03).contains(art), "The complete image must fit its page: \(suffix), \(size), \(art), \(canvas)")
                    }
                }
                XCTAssertEqual(occurrences, 4, "Each source image must be visible exactly once: \(suffix), \(size)")
                if size.height == 0 { XCTAssertEqual(count, 1, "Continuous reading keeps the native chapter together") }
            }
        }
    }

    func testMobiSmallLogosAndAuthoredImageSizeStaySmall() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        try picture(width: 80, height: 40).write(to: directory.url.appendingPathComponent("logo.png"))
        try picture(width: 1600, height: 2400).write(to: directory.url.appendingPathComponent("art.png"))
        let source = directory.url.appendingPathComponent("sizing.mobihtml")
        try """
            <html><head><style>@page{margin:0}body,p{margin:0}</style></head><body>
            <p>BEFORE IMAGES</p><p><img src='logo.png'/></p>
            <p><img src='art.png' style='width:40px;height:auto'/></p><p>AFTER IMAGES</p></body></html>
            """.write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        for height in [CGFloat(480), 0, 720] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 720, height: height))
            let images = try file.imageBounds(0)
            XCTAssertEqual(images.count, 2)
            let logo = try XCTUnwrap(images.first), art = try XCTUnwrap(images.last)
            XCTAssertEqual(logo.width, 60, accuracy: 0.03)
            XCTAssertEqual(logo.height, 30, accuracy: 0.03)
            XCTAssertEqual(art.width, 40, accuracy: 0.03)
            XCTAssertEqual(art.height, 60, accuracy: 0.03)
            let text = try XCTUnwrap(file.text(0))
            XCTAssertTrue(text.contains("BEFORE IMAGES"))
            XCTAssertTrue(text.contains("AFTER IMAGES"))
        }
    }

    @MainActor
    func testHostedFB2AndMobiPaintTheWholeImageAcrossModeChangesAndResize() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let preferences = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in preferences { defaults.set(value, forKey: key) } }
        for (suffix, mixed) in [("fb2", false), ("mobihtml", false), ("fb2", true), ("mobi", true)] {
            let directory = try TemporaryDirectory()
            let source = try mixed ? mixedFixture(in: directory.url, suffix: suffix, landscape: true)
                : fixture(in: directory.url, suffix: suffix, count: 1, landscape: true)
            let originalBytes = try Data(contentsOf: source)
            let document = try mixed ? ReadingDocument.open(source)
                : ReadingDocument(url: source, content: .pages(Pages(source, format: .mupdf, deferReflowLayout: true)))
            guard case .pages(let pages) = document.content else { return XCTFail("The ebook must use native pages") }
            if suffix == "mobi" {
                let adapted = try XCTUnwrap(document.temporary).url
                let markup = try String(contentsOf: adapted.appendingPathComponent("document.mobihtml"), encoding: .utf8)
                XCTAssertTrue(markup.contains("LEADING 0."))
                XCTAssertTrue(markup.contains("ASSOCIATED CAPTION"))
                XCTAssertTrue(markup.contains("AFTER FIGURE"), "The ordinary MOBI path must preserve its body rather than synthesize image pages")
            }
            let state = ReaderState(recordsHistory: false)
            state.document = document
            state.flow = "paged"; state.spread = false; state.cover = false
            state.reflowable = true; state.automaticLayout = false; state.fit = "page"; state.zoom = 1
            state.fontSize = 17; state.lineHeight = 1.2; state.font = "system"; state.theme = "light"
            state.margin = 0; state.pageMargins = PageMargins(cssValues: [0]); state.userCSS = mixed ? boundaryCSS : ""; state.useDocumentCSS = true
            state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false; state.landscapeAsSpread = false
            state.showContents = false; state.scrollbarMode = "hidden"
            let host = NSHostingView(rootView: ReaderView(state: state))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer {
                state.windowClosed(); window.contentView = nil; window.close()
                withExtendedLifetime(directory) {}
            }
            try await assertPaintedImage(host, state: state, pages: pages, suffix: suffix)
            let stages: [(ReaderMenuCommand, CGSize)] = [
                (.twoPages, CGSize(width: 920, height: 560)), (.continuous, CGSize(width: 520, height: 620)),
                (.paged, CGSize(width: 640, height: 480)), (.twoPages, CGSize(width: 760, height: 560))
            ]
            for (command, size) in stages {
                let modeRevision = await pages.layoutRevision
                command.run(state)
                try await assertPaintedImage(host, state: state, pages: pages, suffix: suffix, after: modeRevision)
                let resizeRevision = await pages.layoutRevision
                window.setContentSize(size)
                try await assertPaintedImage(host, state: state, pages: pages, suffix: suffix, after: resizeRevision)
            }
            XCTAssertEqual(try Data(contentsOf: source), originalBytes, "Reading must preserve the original ebook")
        }
    }

    @MainActor
    private func waitForCanvas(_ host: NSView, state: ReaderState, pages: Pages, suffix: String,
                               after revision: Int? = nil, at target: PageLocation? = nil) async throws -> RasterCanvas.Canvas {
        let deadline = Date().addingTimeInterval(10)
        var steady = 0, lastRevision = -1
        repeat {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let currentRevision = await pages.layoutRevision
            let location = target ?? state.pageLocation(state.page)
            let ready = state.error == nil && state.pendingReflowPosition == nil &&
                (revision.map { currentRevision > $0 } ?? true) &&
                renderedCanvas(in: host, pages: pages, location: location) != nil
            steady = ready && currentRevision == lastRevision ? steady + 1 : 0
            lastRevision = currentRevision
            if steady == 15 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTAssertEqual(steady, 15, "Hosted \(suffix) image did not settle in \(state.flow), spread \(state.spread): \(state.error ?? "no error")")
        return try XCTUnwrap(renderedCanvas(in: host, pages: pages, location: target ?? state.pageLocation(state.page)))
    }

    @MainActor
    private func assertPaintedImage(_ host: NSView, state: ReaderState, pages: Pages, suffix: String, after revision: Int? = nil) async throws {
        var canvas = try await waitForCanvas(host, state: state, pages: pages, suffix: suffix, after: revision)
        if !state.userCSS.isEmpty {
            let resolved = try await pages.resolve("#art-anchor", from: state.currentPosition)
            let destination = try XCTUnwrap(resolved)
            state.navigate(.href("#art-anchor"))
            canvas = try await waitForCanvas(host, state: state, pages: pages, suffix: suffix, at: state.pageLocation(destination.page))
        }
        let location = canvas.location
        let images = try await pages.imageBounds(location)
        XCTAssertEqual(images.count, 1)
        let art = try XCTUnwrap(images.first)
        let displayed = art.applying(canvas.pageTransform)
        XCTAssertTrue(canvas.visibleRect.insetBy(dx: -1, dy: -1).contains(displayed), "The whole illustration must be inside the displayed viewport")
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["SUMRA_EBOOK_IMAGE_EVIDENCE"] {
            let name = "\(state.userCSS.isEmpty ? "art" : "mixed")-\(suffix)-\(state.flow)-\(state.spread)-\(Int(host.bounds.width))x\(Int(host.bounds.height)).png"
            let destination = URL(fileURLWithPath: path).appendingPathComponent(name)
            try bitmap.representation(using: .png, properties: [:])?.write(to: destination)
        }
        let painted = try redBounds(bitmap)
        var expected = displayed
        if !canvas.isFlipped { expected.origin.y = canvas.bounds.height - expected.maxY }
        let scaleX = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / canvas.bounds.height
        expected = CGRect(x: expected.minX * scaleX, y: expected.minY * scaleY, width: expected.width * scaleX, height: expected.height * scaleY)
        XCTAssertEqual(painted.minX, expected.minX, accuracy: 3, "The painted left edge must match the native image")
        XCTAssertEqual(painted.maxX, expected.maxX, accuracy: 3, "The painted right edge must match the native image")
        XCTAssertEqual(painted.minY, expected.minY, accuracy: 3, "The painted top edge must match the native image")
        XCTAssertEqual(painted.maxY, expected.maxY, accuracy: 3, "The painted bottom edge must match the native image")
    }

    @MainActor
    private func renderedCanvas(in view: NSView, pages: Pages, location: PageLocation) -> RasterCanvas.Canvas? {
        if let canvas = view as? RasterCanvas.Canvas,
           RasterReader.pageIsRendered(in: canvas, pages: pages, location: location),
           !canvas.isHiddenOrHasHiddenAncestor, !canvas.visibleRect.isEmpty { return canvas }
        return view.subviews.lazy.compactMap { self.renderedCanvas(in: $0, pages: pages, location: location) }.first
    }

    private func redBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        let image = try XCTUnwrap(bitmap.cgImage)
        let width = image.width, height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels + y * context.bytesPerRow + x * 4
                // AppKit color management changes exact channel values; the
                // source remains red against white paper and black body text.
                guard Int(pixel[0]) > 180, Int(pixel[0]) > 2 * Int(pixel[1]),
                      Int(pixel[0]) > 2 * Int(pixel[2]) else { continue }
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left else { throw ReadError("The hosted reader did not paint the red illustration") }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
#endif
