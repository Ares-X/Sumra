#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class EPUBCoverAspectTests: XCTestCase {
    private func fixture(in directory: URL, coverDocument: String? = nil, guide: Bool = false) throws -> URL {
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
        if let coverDocument {
            files["c0.xhtml"] = coverDocument
            if guide {
                files["content.opf"] = files["content.opf"]?.replacingOccurrences(of: "</package>",
                    with: "<guide><reference type='cover' href='c0.xhtml#cover'/></guide></package>")
            } else {
                files["content.opf"] = files["content.opf"]?.replacingOccurrences(of: "id='c0'", with: "id='Cover'")
                    .replacingOccurrences(of: "idref='c0'", with: "idref='Cover' linear='no'")
            }
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

    func testDeclaredImageCoversFitOnePageAcrossPublisherWrappersAndWindowSizes() throws {
        let bodies = [
            "<div id='cover'><a name='legacy-cover'/><svg xmlns='http://www.w3.org/2000/svg' width='100%' height='100%' viewBox='0 0 200 300' preserveAspectRatio='none'><image width='200' height='300' href='cover.png'/></svg></div>",
            "<p><img src='cover.png'/></p>",
            "<div style='height:50%;margin-bottom:-250px'></div><div style='height:0;position:relative'><table style='height:500px;width:100%'><tr><td><img src='cover.png'/></td></tr></table></div>"
        ]
        for (index, body) in bodies.enumerated() {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let html = "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>body{margin:2em}p{margin:1em}svg{width:98%;height:100%}</style></head><body>\(body)</body></html>"
            let file = try NativeFile(fixture(in: directory.url, coverDocument: html, guide: index == 0), engine: .mupdf)
            for size in [CGSize(width: 720, height: 480), CGSize(width: 360, height: 480), CGSize(width: 480, height: 720)] {
                _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
                XCTAssertEqual(file.chapterTable?.pageCount(0), 1, "A cover must not create a leading or trailing empty page")
                if index == 0 {
                    XCTAssertEqual(try file.resolve("c0.xhtml#cover")?.page, 0)
                    XCTAssertEqual(try file.resolve("c0.xhtml#legacy-cover")?.page, 0)
                }
                let image = try file.image(0, width: Int(size.width))
                let red = try coloredBounds(image), blue = try coloredBounds(image, blue: true)
                XCTAssertEqual(red.width / red.height, 2.0 / 3.0, accuracy: 0.015)
                XCTAssertEqual(blue.width / blue.height, 1, accuracy: 0.025)
                XCTAssertEqual(red.midX, CGFloat(image.width) / 2, accuracy: 2)
                XCTAssertEqual(red.midY, CGFloat(image.height) / 2, accuracy: 2)
                XCTAssertEqual(min(CGFloat(image.width) - red.width, CGFloat(image.height) - red.height), 0, accuracy: 2,
                    "The cover must grow to the available page, including small raster sources")
            }
            _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 360, height: 0))
            let continuous = try file.image(0, width: 360)
            let red = try coloredBounds(continuous)
            XCTAssertEqual(red.width / red.height, 2.0 / 3.0, accuracy: 0.015)
            XCTAssertEqual(red.width, 360, accuracy: 2, "Continuous covers use their natural height at the reading width")
        }
    }

    func testKeepTogetherFigureReservesItsCaptionAfterEarlierText() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let html = """
            <html><head><style>@page{margin:0}body{margin:8px}p{margin:0;line-height:20px}
            div{page-break-inside:avoid}img{width:100%;height:auto}</style></head><body>
            <p>BEFORE FIGURE</p><div><p style='margin-top:12px'><img src='cover.png'/></p>
            <p>ASSOCIATED CAPTION</p></div><p>AFTER FIGURE</p></body></html>
            """
        let file = try NativeFile(fixture(in: directory.url, coverDocument: html), engine: .mupdf)
        for size in [CGSize(width: 720, height: 480), CGSize(width: 360, height: 480)] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
            let first = try XCTUnwrap(file.text(0))
            XCTAssertTrue(first.contains("BEFORE FIGURE"))
            XCTAssertTrue(first.contains("ASSOCIATED CAPTION"), "The figure's caption must stay on its image page")
            let image = try file.image(0, width: Int(size.width))
            let red = try coloredBounds(image)
            XCTAssertEqual(red.width / red.height, 2.0 / 3.0, accuracy: 0.015)
            let following = try (0..<(file.chapterTable?.pageCount(0) ?? 0)).map { try file.text($0) ?? "" }.joined()
            XCTAssertTrue(following.contains("AFTER FIGURE"), "The layout measurement must retain following content")
        }
    }

    func testInteriorArtPagesUseTheReadersRealCSSComposition() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pictures = (0..<4).map { "<p><a id='art\($0)'/><img src='cover.png'/></p>" }.joined()
        let html = "<html><head><style>@page{margin:0}body,p{margin:0}img{width:auto;height:auto}</style></head><body>\(pictures)</body></html>"
        let file = try NativeFile(fixture(in: directory.url, coverDocument: html), engine: .mupdf)
        for useDocumentCSS in [true, false] {
            for userCSS in ["", "@page{margin:24px!important}body{margin:11px!important}"] {
                for size in [CGSize(width: 720, height: 480), CGSize(width: 360, height: 480),
                             CGSize(width: 480, height: 720), CGSize(width: 1200, height: 800)] {
                    _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light",
                                          userCSS: userCSS, useDocumentCSS: useDocumentCSS, pageSize: size)
                    XCTAssertEqual(file.chapterTable?.pageCount(0), 4, "Each independent illustration needs its own page")
                    for index in 0..<4 {
                        let page = try file.page(.init(chapter: 0, page: index))
                        let canvas = try XCTUnwrap(file.bounds(page))
                        let images = try file.imageBounds(page)
                        XCTAssertEqual(images.count, 1)
                        let art = try XCTUnwrap(images.first)
                        XCTAssertEqual(art.width / art.height, 2.0 / 3.0, accuracy: 0.002)
                        XCTAssertEqual(art.midX, canvas.midX, accuracy: 0.03)
                        XCTAssertEqual(art.midY, canvas.midY, accuracy: 0.03)
                        XCTAssertGreaterThan(art.height, 225, "Full-page art must grow beyond the 200x300 source's natural height")
                        XCTAssertGreaterThanOrEqual(art.minX, canvas.minX - 0.03)
                        XCTAssertLessThanOrEqual(art.maxX, canvas.maxX + 0.03)
                        XCTAssertGreaterThanOrEqual(art.minY, canvas.minY - 0.03)
                        XCTAssertLessThanOrEqual(art.maxY, canvas.maxY + 0.03)
                        XCTAssertEqual(try file.resolve("c0.xhtml#art\(index)")?.page, index)
                    }
                }
            }
        }
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light",
                              pageSize: CGSize(width: 360, height: 0))
        XCTAssertEqual(file.chapterTable?.pageCount(0), 1)
        let images = try file.imageBounds(0)
        XCTAssertEqual(images.count, 4)
        for art in images {
            XCTAssertEqual(art.width, 150, accuracy: 0.03, "Continuous reading retains the source's natural size within its column")
            XCTAssertEqual(art.height, 225, accuracy: 0.03)
        }
    }

    func testReaderBridgePreservesExplicitImageConstraintsAndPercentageHeightReferences() throws {
        // Max constraints remain a classification boundary. General max-size
        // layout is still unsupported, so those cases retain their natural size.
        let cases: [(String, String, CGSize, CGSize?)] = [
            ("width only", "img{width:40px}", CGSize(width: 40, height: 60), nil),
            ("height only", "img{height:30px}", CGSize(width: 20, height: 30), nil),
            ("em height", "img{height:2em}", CGSize(width: 34 * 2.0 / 3.0, height: 34), nil),
            ("maximum width", "img{max-width:25%}", CGSize(width: 150, height: 225), nil),
            ("ancestor maximum height", ".frame{max-height:25%}", CGSize(width: 150, height: 225), nil),
            ("percentage width container", ".frame{width:25%}img{width:100%}", CGSize(width: 180, height: 270), nil),
            ("percentage height in auto container", "img{height:50%}", CGSize(width: 150, height: 225), nil),
            ("percentage height in pixel container", ".frame{height:200px}img{height:50%}", CGSize(width: 100 * 2.0 / 3.0, height: 100), nil),
            ("percentage height in em container", ".frame{height:12em}img{height:50%}", CGSize(width: 68, height: 102), nil),
            ("percentage height in percentage container", ".stage{height:200px}.frame{height:50%}img{height:50%}", CGSize(width: 50 * 2.0 / 3.0, height: 50), nil),
            ("zero pixel container", "html,body,.stage{height:100%}.frame{height:0px}img{height:50%}", .zero, nil),
            ("zero percentage container", "html,body,.stage{height:100%}.frame{height:0%}img{height:50%}", .zero, CGSize(width: 150, height: 225))
        ]
        for (name, css, expected, continuousExpected) in cases {
            for display in ["inline", "block"] {
                let directory = try TemporaryDirectory()
                defer { withExtendedLifetime(directory) {} }
                let pictures = (0..<4).map { "<section class='stage'><div class='frame'><img id='art\($0)' src='cover.png'/></div></section>" }.joined()
                let following = expected == .zero ? "<p>VISIBLE TEXT</p>" : ""
                let html = "<html><head><style>@page{margin:0}body{margin:0}img{display:\(display)}\(css)</style></head><body>\(pictures)\(following)</body></html>"
                let file = try NativeFile(fixture(in: directory.url, coverDocument: html), engine: .mupdf)
                for height in [CGFloat(480), 0] {
                    _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light",
                                          pageSize: CGSize(width: 720, height: height))
                    let pageCount = try XCTUnwrap(file.chapterTable?.pageCount(0))
                    let images = try (0..<pageCount).flatMap { index in
                        try file.imageBounds(file.page(.init(chapter: 0, page: index)))
                    }
                    XCTAssertEqual(images.count, 4, "\(name), \(display): each source image must remain visible once")
                    let size = height == 0 ? continuousExpected ?? expected : expected
                    for art in images {
                        XCTAssertEqual(art.width, size.width, accuracy: 0.03, "\(name), \(display), height \(height)")
                        XCTAssertEqual(art.height, size.height, accuracy: 0.03, "\(name), \(display), height \(height)")
                    }
                    if expected == .zero {
                        let text = try (0..<pageCount).map { index in
                            try file.text(file.page(.init(chapter: 0, page: index))) ?? ""
                        }.joined()
                        XCTAssertTrue(text.contains("VISIBLE TEXT"), "Zero image dimensions must not consume the following text")
                    }
                }
            }
        }
    }

    func testDeclaredTextCoverKeepsItsAuthoredContent() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let html = "<html><body><p>AUTHOR TITLE</p><img src='cover.png'/></body></html>"
        let file = try NativeFile(fixture(in: directory.url, coverDocument: html), engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 360, height: 480))
        XCTAssertTrue(try XCTUnwrap(file.text(0)).contains("AUTHOR TITLE"))
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
        let fullCircle = try coloredBounds(whole, blue: true)
        let region = fullCircle.insetBy(dx: -10, dy: -10).integral
        let tile = try file.image(0, width: 720, region: region)
        let tileCircle = try coloredBounds(tile, blue: true)
        XCTAssertEqual(tile.width, Int(region.width)); XCTAssertEqual(tile.height, Int(region.height))
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
