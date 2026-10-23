#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class EPUBCoverAspectTests: XCTestCase {
    private func fixture(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 0, 1]))); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 0, 1, 1]))); context.fillEllipse(in: CGRect(x: 60, y: 110, width: 80, height: 80))
        let picture = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(picture, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (picture as Data).write(to: directory.appendingPathComponent("cover.png"))

        let embedded = "data:image/png;base64," + (picture as Data).base64EncodedString()
        let chapters: [(String, String)] = [
            ("viewBox='0 0 200 300'", "<image width='200' height='300' href='cover.png'/>"),
            ("viewBox='0 0 200 300' preserveAspectRatio='none'", "<image width='200' height='300' href='cover.png'/>"),
            ("viewBox='0 0 360 240'", "<image width='360' height='240' href='\(embedded)'/>"),
            ("viewBox='0 0 360 240'", "<image width='360' height='240' preserveAspectRatio='none' href='cover.png'/>"),
            ("viewBox='0 0 200 300' preserveAspectRatio='xMidYMid slice'", "<image width='200' height='300' href='cover.png'/>"),
            ("viewBox='0 0 200 300' preserveAspectRatio='xMaxYMin meet'", "<image width='200' height='300' href='cover.png'/>")
        ]
        let manifest = chapters.indices.map { "<item id='c\($0)' href='c\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
        let spine = chapters.indices.map { "<itemref idref='c\($0)'/>" }.joined()
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest>\(manifest)<item id='cover' href='cover.png' media-type='image/png'/></manifest><spine>\(spine)</spine></package>"
        ]
        for (index, chapter) in chapters.enumerated() {
            files["c\(index).xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>@page{margin:0}html,body{margin:0}svg{display:block;width:100%;height:100%}</style></head><body><svg xmlns='http://www.w3.org/2000/svg' width='100%' height='100%' \(chapter.0)>\(chapter.1)</svg></body></html>"
        }
        for (name, contents) in files { try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "cover-aspect.epub"] + files.keys.sorted() + ["cover.png"]
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create the EPUB cover fixture") }
        let input = directory.appendingPathComponent("cover-aspect.epub")
        if let path = ProcessInfo.processInfo.environment["SUMRA_EPUB_COVER_FIXTURE"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: input).write(to: output)
        }
        return input
    }

    private func coloredBounds(_ image: CGImage, blue: Bool = false) throws -> CGRect {
        let data = try XCTUnwrap(image.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let components = image.bitsPerPixel / 8
        var x0 = image.width, y0 = image.height, x1 = -1, y1 = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = bytes + y * image.bytesPerRow + x * components
                let colored = blue ? pixel[2] > 220 && pixel[0] < 30 && pixel[1] < 30
                    : pixel[0] > 220 && pixel[1] < 30 && pixel[2] < 30
                if colored { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
            }
        }
        guard x1 >= x0 else { throw ReadError("The cover must paint visible pixels") }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    private func retain(_ image: CGImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_EPUB_COVER_FIXTURE"] else { return }
        let output = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testFullPageSVGPreservesCoverGeometryAcrossSingleAndDoublePageWidths() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(fixture(in: directory.url), engine: .mupdf)
        for size in [CGSize(width: 720, height: 480), CGSize(width: 360, height: 480), CGSize(width: 480, height: 720)] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
            for chapter in [0, 2] {
                let page = try file.page(.init(chapter: chapter, page: 0))
                let image = try file.image(page, width: Int(size.width))
                try retain(image, name: "cover-\(chapter)-\(Int(size.width))x\(Int(size.height))")
                let red = try coloredBounds(image), blue = try coloredBounds(image, blue: true)
                XCTAssertEqual(red.width / red.height, 2.0 / 3.0, accuracy: 0.015, "chapter \(chapter), viewport \(size): \(red)")
                XCTAssertEqual(blue.width / blue.height, 1, accuracy: 0.025, "The circular cover marker must remain round")
                XCTAssertEqual(red.midX, CGFloat(image.width) / 2, accuracy: 2)
                XCTAssertEqual(red.midY, CGFloat(image.height) / 2, accuracy: 2)
            }
            let none = try file.image(file.page(.init(chapter: 1, page: 0)), width: Int(size.width))
            let stretched = try coloredBounds(none)
            XCTAssertEqual(stretched.width / stretched.height, size.width / size.height, accuracy: 0.015, "Explicit SVG none keeps the author's nonuniform scaling")
        }
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 360, height: 240))
        let innerNone = try file.image(file.page(.init(chapter: 3, page: 0)), width: 360)
        let stretched = try coloredBounds(innerNone)
        XCTAssertEqual(stretched.width / stretched.height, 1.5, accuracy: 0.015, "An image's explicit none remains authoritative inside an SVG")
        let slice = try file.image(file.page(.init(chapter: 4, page: 0)), width: 360)
        try retain(slice, name: "cover-slice-360x240")
        let cropped = try coloredBounds(slice), circle = try coloredBounds(slice, blue: true)
        XCTAssertEqual(cropped.width, 360, accuracy: 1); XCTAssertEqual(cropped.height, 240, accuracy: 1)
        XCTAssertEqual(circle.width / circle.height, 1, accuracy: 0.025, "Slice crops the cover without stretching it")
        let aligned = try file.image(file.page(.init(chapter: 5, page: 0)), width: 360)
        let right = try coloredBounds(aligned)
        XCTAssertEqual(right.maxX, 360, accuracy: 1); XCTAssertEqual(right.minY, 0, accuracy: 1)
    }

    func testContinuousSVGPercentHeightUsesTheIntrinsicRatio() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(fixture(in: directory.url), engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 360, height: 0))
        let image = try file.image(0, width: 360)
        let red = try coloredBounds(image), blue = try coloredBounds(image, blue: true)
        XCTAssertEqual(red.width / red.height, 2.0 / 3.0, accuracy: 0.015)
        XCTAssertEqual(blue.width / blue.height, 1, accuracy: 0.025)
    }

    func testSVGSubareaKeepsTheSameCoverGeometryAsTheFullPage() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(fixture(in: directory.url), engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 720, height: 480))
        let whole = try file.image(0, width: 720)
        let region = CGRect(x: 240, y: 150, width: 240, height: 180)
        let tile = try file.image(0, width: 720, region: region)
        let fullCircle = try coloredBounds(whole, blue: true), tileCircle = try coloredBounds(tile, blue: true)
        XCTAssertEqual(tile.width, 240); XCTAssertEqual(tile.height, 180)
        XCTAssertEqual(tileCircle.minX, fullCircle.minX - region.minX, accuracy: 1)
        XCTAssertEqual(tileCircle.minY, fullCircle.minY - region.minY, accuracy: 1)
        XCTAssertEqual(tileCircle.width, fullCircle.width, accuracy: 1)
        XCTAssertEqual(tileCircle.height, fullCircle.height, accuracy: 1)
    }

    @MainActor
    func testNormalDocumentOpenPaintsCoverInTheHostedReadingModes() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let document = try ReadingDocument.open(fixture(in: directory.url))
        guard case .pages(let pages) = document.content else { return XCTFail("EPUB must open through the graphical document path") }
        let initialCount = await pages.count
        XCTAssertGreaterThan(initialCount, 0)
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.flow = "paged"; state.spread = false
        state.automaticLayout = false; state.fit = "page"; state.zoom = 1
        state.fontSize = 17; state.lineHeight = 1.2; state.font = "system"; state.theme = "light"
        state.margin = 0; state.pageMargins = PageMargins(cssValues: [0]); state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false; state.landscapeAsSpread = false
        let defaults = UserDefaults.standard
        let previous = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            for (key, value) in previous { defaults.set(value, forKey: key) }
            state.windowClosed(); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        for command in [ReaderMenuCommand.paged, .twoPages, .continuous] {
            command.run(state)
            let deadline = Date().addingTimeInterval(10)
            var painted = false
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                painted = state.reflowable && state.error == nil && state.pendingReflowPosition == nil &&
                    RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(chapter: 0, page: 0))
                if painted { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTAssertTrue(painted, "Mode \(command) must paint the cover: \(state.error ?? "no error")")
            let image = try await pages.image(.init(chapter: 0, page: 0), width: 360)
            let red = try coloredBounds(image), blue = try coloredBounds(image, blue: true)
            XCTAssertEqual(red.width / red.height, 2.0 / 3.0, accuracy: 0.015)
            XCTAssertEqual(blue.width / blue.height, 1, accuracy: 0.025)
        }
    }
}
#endif
