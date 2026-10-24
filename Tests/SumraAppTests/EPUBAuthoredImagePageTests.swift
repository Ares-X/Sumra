#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import XCTest
@testable import Sumra

final class EPUBAuthoredImagePageTests: XCTestCase {
    private func fixture(in directory: URL, chapters: [String], coverChapter: Int? = 0,
                         unusedCover: Bool = false, missingLastChapter: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8,
            bytesPerRow: 800, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let image = directory.appendingPathComponent("art.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        // A separate resource identity is important: a metadata cover outside the
        // spine must not change the first visible chapter's layout.
        try Data(contentsOf: image).write(to: directory.appendingPathComponent("cover.png"))
        let metadata = coverChapter != nil || unusedCover ? "<meta name='cover' content='cover-image'/>" : ""
        let manifest = chapters.indices.map { "<item id='c\($0)' href='c\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
        let spine = chapters.indices.map { "<itemref idref='c\($0)'/>" }.joined()
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata>\(metadata)</metadata><manifest>\(manifest)<item id='cover-image' href='cover.png' media-type='image/png'/><item id='art' href='art.png' media-type='image/png'/></manifest><spine>\(spine)</spine></package>"
        ]
        for (index, chapter) in chapters.enumerated() where !missingLastChapter || index != chapters.count - 1 {
            files["c\(index).xhtml"] = chapter
        }
        for (name, contents) in files { try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "image-pages.epub"] + files.keys.sorted() + ["art.png", "cover.png"]
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("image-pages.epub")
    }

    private var cover: String { "<html><body><img src='cover.png'/></body></html>" }
    private let sizes = [CGSize(width: 720, height: 480), CGSize(width: 720, height: 800),
                         CGSize(width: 1200, height: 800), CGSize(width: 1200, height: 480),
                         CGSize(width: 360, height: 480), CGSize(width: 1200, height: 800), CGSize(width: 720, height: 480)]

    private func layout(_ file: NativeFile, size: CGSize) throws {
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
    }

    private func image(_ file: NativeFile, chapter: Int) throws -> CGRect {
        XCTAssertEqual(file.chapterTable?.pageCount(chapter), 1, "A single illustration must not acquire blank or duplicate pages")
        let images = try file.imageBounds(file.page(.init(chapter: chapter, page: 0)))
        XCTAssertEqual(images.count, 1)
        return try XCTUnwrap(images.first)
    }

    func testViewportHeightIllustrationTracksGrowingAndReturningWindow() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let html = "<html><head><style>@page{margin:0}html,body{margin:0}.frame{height:98vh;text-align:center}img{height:100%;max-width:100%;max-height:100%}</style></head><body><div class='frame'><img src='art.png'/></div></body></html>"
        let file = try NativeFile(fixture(in: directory.url, chapters: [cover, html]), engine: .mupdf)
        for size in sizes {
            try layout(file, size: size)
            let art = try image(file, chapter: 1)
            XCTAssertEqual(art.height, size.height * 0.98, accuracy: 0.05)
            XCTAssertEqual(art.width, size.height * 0.98 * 2 / 3, accuracy: 0.05)
            XCTAssertEqual(art.midX, size.width / 2, accuracy: 0.05)
            XCTAssertGreaterThanOrEqual(art.minY, -0.05)
            XCTAssertLessThanOrEqual(art.maxY, size.height + 0.05)
        }
    }

    func testViewportHeightImageFrameDoesNotAddAnEmptyPageFromOuterInsets() throws {
        for fraction in [1.0, 0.5] {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let html = "<html><head><style>@page{margin:51px 34px}body{margin:17px}.frame{height:98vh;text-align:center}img{height:\(fraction * 100)%}</style></head><body><div class='frame'><img src='art.png'/></div></body></html>"
            let file = try NativeFile(fixture(in: directory.url, chapters: [cover, html]), engine: .mupdf)
            for size in sizes {
                try layout(file, size: size)
                let art = try image(file, chapter: 1)
                XCTAssertEqual(art.height, (size.height - 136) * fraction, accuracy: 0.05)
                XCTAssertEqual(art.midX, size.width / 2, accuracy: 0.05)
                XCTAssertGreaterThanOrEqual(art.minY, 68 - 0.05)
                XCTAssertLessThanOrEqual(art.maxY, size.height - 68 + 0.05)
            }
        }
    }

    func testIndependentSingleImageAndIndefinitePercentageArtFitEachPage() throws {
        for css in ["img{max-width:100%;max-height:100%}", "p,img{height:98%}"] {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let html = "<html><head><style>@page{margin:0}html,body,p{margin:0}\(css)</style></head><body><p><img id='art' src='art.png'/></p></body></html>"
            let file = try NativeFile(fixture(in: directory.url, chapters: [cover, html]), engine: .mupdf)
            for size in sizes {
                try layout(file, size: size)
                let art = try image(file, chapter: 1)
                let fit = min(size.width / 200, size.height / 300)
                XCTAssertEqual(art.width, 200 * fit, accuracy: 0.05)
                XCTAssertEqual(art.height, 300 * fit, accuracy: 0.05)
                XCTAssertEqual(art.midX, size.width / 2, accuracy: 0.05)
                XCTAssertEqual(art.midY, size.height / 2, accuracy: 0.05)
                let anchor = try XCTUnwrap(file.resolve("c1.xhtml#art")?.anchor)
                XCTAssertEqual(ChapterTable.bookmarkLocation(anchor)?.location.chapter, 1)
            }
            try layout(file, size: CGSize(width: 360, height: 0))
            XCTAssertEqual(try image(file, chapter: 1).width, 150, accuracy: 0.05, "Continuous flow retains natural image sizing")
            try layout(file, size: sizes[0])
            XCTAssertEqual(try image(file, chapter: 1).height, 480, accuracy: 0.05)
        }
    }

    func testUnusedMetadataCoverDoesNotChangeFirstVisiblePageMargins() throws {
        for text in ["", "<p>VISIBLE TITLE</p>"] {
            let directories = try (0..<2).map { _ in try TemporaryDirectory() }
            defer { withExtendedLifetime(directories) {} }
            let imageStyle = text.isEmpty ? "width:100%" : "width:80px"
            let html = "<html><head><style>@page{margin:30px 20px 0 20px}body{margin:7px}img{\(imageStyle);display:block}</style></head><body>\(text)<div><img src='art.png'/></div></body></html>"
            let files = try directories.enumerated().map { index, directory in
                try NativeFile(fixture(in: directory.url, chapters: [html, "<html><body>SECOND VISIBLE CHAPTER</body></html>"], coverChapter: nil, unusedCover: index == 1), engine: .mupdf)
            }
            for size in sizes {
                for file in files { try layout(file, size: size) }
                let first = try image(files[0], chapter: 0), second = try image(files[1], chapter: 0)
                XCTAssertEqual(first.minX, second.minX, accuracy: 0.05)
                XCTAssertEqual(first.minY, second.minY, accuracy: 0.05)
                XCTAssertEqual(first.width, second.width, accuracy: 0.05)
                XCTAssertEqual(first.height, second.height, accuracy: 0.05)
                XCTAssertEqual(try files[0].bounds(0), try files[1].bounds(0))
                if !text.isEmpty { XCTAssertTrue(try XCTUnwrap(files[1].text(0)).contains("VISIBLE TITLE")) }
            }
        }
    }

    func testDeclaredLaterCoverDoesNotEnlargeFirstSmallLogo() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let logo = "<html><head><style>@page{margin:0}body{margin:0}img{width:20px;height:30px}</style></head><body><img src='art.png'/></body></html>"
        let file = try NativeFile(fixture(in: directory.url, chapters: [logo, cover], coverChapter: 1), engine: .mupdf)
        for size in sizes {
            try layout(file, size: size)
            let art = try image(file, chapter: 0)
            XCTAssertEqual(art.width, 20, accuracy: 0.05)
            XCTAssertEqual(art.height, 30, accuracy: 0.05)
        }
    }

    func testViewportSizedSmallIllustrationKeepsAuthoredDimensions() throws {
        for css in ["height:10vh", "width:25vw", "height:10vmin", "height:10vmax"] {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let html = "<html><head><style>@page{margin:0}html,body{margin:0}img{\(css)}</style></head><body><img src='art.png'/></body></html>"
            let file = try NativeFile(fixture(in: directory.url, chapters: [cover, html]), engine: .mupdf)
            for size in sizes {
                try layout(file, size: size)
                let art = try image(file, chapter: 1)
                let height: CGFloat
                switch css {
                case "width:25vw": height = size.width * 0.25 * 1.5
                case "height:10vmin": height = min(size.width, size.height) * 0.1
                case "height:10vmax": height = max(size.width, size.height) * 0.1
                default: height = size.height * 0.1
                }
                XCTAssertEqual(art.width, height * 2 / 3, accuracy: 0.05)
                XCTAssertEqual(art.height, height, accuracy: 0.05)
            }
        }
    }

    func testAuthoredImageMaximaShrinkWithoutEnlargingSmallArt() throws {
        for css in ["max-width:25%", "width:100%;max-width:25%", "max-height:10vh", "max-width:0", "max-height:0"] {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let html = "<html><head><style>@page{margin:0}body{margin:0}img{\(css)}</style></head><body><img src='art.png'/></body></html>"
            let file = try NativeFile(fixture(in: directory.url, chapters: [cover, html]), engine: .mupdf)
            for size in sizes {
                try layout(file, size: size)
                let art = try image(file, chapter: 1)
                let height = css.hasSuffix(":0") ? 0 : css == "max-height:10vh" ? min(225, size.height * 0.1)
                    : (css.hasPrefix("width:") ? size.width * 0.25 : min(150, size.width * 0.25)) * 1.5
                XCTAssertEqual(art.width, height * 2 / 3, accuracy: 0.05)
                XCTAssertEqual(art.height, height, accuracy: 0.05)
            }
        }
    }

    func testAuthoredMaximaAndPercentageReferencesInPagedAndContinuousProse() throws {
        let cases: [(String, CGFloat, CGFloat)] = [
            ("img{max-width:25%}", 90, 135),
            ("img{max-height:40px}", 80.0 / 3, 40),
            ("img{max-width:0}", 0, 0),
            ("img{max-height:0}", 0, 0),
            (".frame{height:200px}img{max-height:50%}", 200.0 / 3, 100),
            ("img{max-height:10%}", 150, 225)
        ]
        for (css, width, height) in cases {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let html = "<html><head><style>@page{margin:0}html,body,p{margin:0}\(css)</style></head><body><p>VISIBLE CAPTION</p><div class='frame'><img src='art.png'/></div></body></html>"
            let file = try NativeFile(fixture(in: directory.url, chapters: [cover, html]), engine: .mupdf)
            for pageHeight: CGFloat in [480, 0, 480] {
                try layout(file, size: CGSize(width: 360, height: pageHeight))
                let art = try image(file, chapter: 1)
                XCTAssertEqual(art.width, width, accuracy: 0.05, "\(css), paged height \(pageHeight)")
                XCTAssertEqual(art.height, height, accuracy: 0.05, "\(css), paged height \(pageHeight)")
                XCTAssertTrue(try XCTUnwrap(file.text(file.page(.init(chapter: 1, page: 0)))).contains("VISIBLE CAPTION"))
            }
        }
    }

    func testUnusedCoverDoesNotLoadUnreadableLaterChapterBeforeFirstPage() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, chapters: ["<html><body>FIRST READABLE CHAPTER</body></html>", "<html><body>LATER CHAPTER</body></html>"],
                                coverChapter: nil, unusedCover: true, missingLastChapter: true)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        try layout(file, size: CGSize(width: 720, height: 480))
        let page = try file.page(.init(chapter: 0, page: 0))
        XCTAssertTrue(try XCTUnwrap(file.text(page)).contains("FIRST READABLE CHAPTER"))
    }
}
#endif
