#if os(macOS)
import AppKit
import Foundation
import ImageIO
import SumraCore
import XCTest
@testable import Sumra

final class EPUBFixedLayoutTests: XCTestCase {
    private func fixture(in directory: URL, layout: String? = "pre-paginated",
                         chapters: [(properties: String, html: String)], resources: [String: Data] = [:]) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let declaration = layout.map { "<meta property='rendition:layout'>\($0)</meta>" } ?? ""
        let manifest = chapters.indices.map { "<item id='c\($0)' href='c\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
            + resources.keys.sorted().enumerated().map { "<item id='r\($0.offset)' href='\($0.element)' media-type='image/png'/>" }.joined()
        let spine = chapters.enumerated().map { "<itemref idref='c\($0.offset)' properties='\($0.element.properties)'/>" }.joined()
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata>\(declaration)</metadata><manifest>\(manifest)</manifest><spine page-progression-direction='rtl'>\(spine)</spine></package>"
        ]
        for (index, chapter) in chapters.enumerated() { files["c\(index).xhtml"] = chapter.html }
        for (name, contents) in files { try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        for (name, contents) in resources { try contents.write(to: directory.appendingPathComponent(name)) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted() + resources.keys.sorted()
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create the EPUB integration fixture") }
        return directory.appendingPathComponent("book.epub")
    }

    private func html(_ body: String, viewport: String? = "width=240,height=320", css: String = "") -> String {
        let meta = viewport.map { "<meta name='viewport' content='\($0)'/>" } ?? ""
        return "<html xmlns='http://www.w3.org/1999/xhtml'><head>\(meta)<style>p{margin:0;font-size:16px;line-height:20px}\(css)</style></head><body>\(body)</body></html>"
    }

    func testAuthorCanvasesRemainSinglePagesAndExcludeInvisibleTextAndLinks() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let body = "<p><a href='https://example.org/visible'>VISIBLE</a></p><p style='page-break-before:always'>AFTERBREAK</p><div style='height:600px'/><p id='outside'><a href='https://example.org/outside'>HIDDEN</a></p>"
        let input = try fixture(in: directory.url, chapters: [
            ("", html(body)), ("", html("<p>SECOND</p>", viewport: "width=320,height=180"))
        ])
        let book = try NativeFile(input, engine: .mupdf)
        XCTAssertFalse(book.reflowable)
        XCTAssertEqual(book.count, 2)
        XCTAssertEqual(try book.metadata()["EPUBLayout"], "fixed")
        XCTAssertEqual(try book.metadata()["ReadingDirection"], "rtl")
        XCTAssertEqual(try book.bounds(0)?.size, CGSize(width: 240, height: 320))
        XCTAssertEqual(try book.bounds(1)?.size, CGSize(width: 320, height: 180))
        let text = try XCTUnwrap(book.text(0))
        XCTAssertTrue(text.contains("VISIBLE"))
        XCTAssertTrue(text.contains("AFTERBREAK"), "A forced page break must not move author content off its single canvas")
        XCTAssertFalse(text.contains("HIDDEN"))
        XCTAssertEqual(try book.matches("HIDDEN", page: 0).count, 0)
        XCTAssertEqual(try book.matches("VISIBLE", page: 0).count, 1)
        let links = try book.links(0)
        XCTAssertEqual(links.map(\.uri), ["https://example.org/visible"])
        XCTAssertTrue(links.allSatisfy { CGRect(x: 0, y: 0, width: 240, height: 320).contains($0.bounds) })
        XCTAssertEqual(try book.resolve("c0.xhtml#outside")?.page, 0, "An off-canvas fragment must never invent a second page")
        XCTAssertNil(try book.relayout(fontSize: 40, lineHeight: 2, font: "sans-serif", theme: "dark"))
        XCTAssertEqual(try book.text(0), text)
    }

    func testMixedBookReflowsOnlyTheDeclaredReflowChapter() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let prose = String(repeating: "<p>Ordinary prose changes pagination when the reader increases the font size.</p>", count: 80)
        let input = try fixture(in: directory.url, chapters: [
            ("rendition:page-spread-center", html("<p>AUTHOR</p>")),
            ("rendition:page-spread-left\trendition:layout-reflowable", html(prose, viewport: nil))
        ])
        let book = try NativeFile(input, engine: .mupdf)
        XCTAssertTrue(book.reflowable)
        XCTAssertEqual(try book.metadata()["EPUBLayout"], "mixed")
        let fixed = try book.words(0).map(\.rect)
        _ = try book.relayout(fontSize: 12, lineHeight: 1.2, font: "serif", theme: "light")
        let smallCount = book.count
        _ = try book.relayout(fontSize: 30, lineHeight: 1.6, font: "sans-serif", theme: "dark", useDocumentCSS: false)
        XCTAssertGreaterThan(book.count, smallCount)
        XCTAssertEqual(book.chapterTable?.pageCount(0), 1)
        XCTAssertEqual(try book.bounds(0)?.size, CGSize(width: 240, height: 320))
        XCTAssertEqual(try book.words(0).map(\.rect), fixed, "User typography and disabled publisher CSS must not alter a fixed chapter")

        let reverse = try fixture(in: directory.url.appendingPathComponent("reverse"), layout: nil, chapters: [
            ("rendition:layout-pre-paginated", html("<p>AUTHOR</p>")),
            ("rendition:layout-pre-paginated-extra", html(prose, viewport: nil))
        ])
        let reverseBook = try NativeFile(reverse, engine: .mupdf)
        XCTAssertTrue(reverseBook.reflowable)
        XCTAssertEqual(try reverseBook.metadata()["EPUBLayout"], "mixed")
        XCTAssertEqual(try reverseBook.bounds(0)?.size, CGSize(width: 240, height: 320))
        XCTAssertGreaterThan(reverseBook.count, 2, "A property suffix must not be mistaken for the exact fixed-layout token")
    }

    func testInvalidViewportFailsWhenTheCanvasIsRequested() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for (index, viewport) in [nil, "width=240", "width=0,height=320", "width=nan,height=320", "width=240,width=320,height=320"].enumerated() {
            let input = try fixture(in: directory.url.appendingPathComponent("case\(index)"), chapters: [("", html("<p>AUTHOR</p>", viewport: viewport))])
            let book = try NativeFile(input, engine: .mupdf)
            XCTAssertEqual(book.count, 1)
            XCTAssertThrowsError(try book.bounds(0), "Invalid metadata must not silently become a 420 by 595 reader canvas")
        }
    }

    func testFixedBookZoomDoesNotParseEveryUnseenCanvas() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let chapters = [(properties: "", html: html("<p>FIRST</p>"))] + Array(repeating: (properties: "", html: html("<p>LATER</p>", viewport: nil)), count: 19)
        let input = try fixture(in: directory.url, chapters: chapters)
        let pages = try Pages(input, format: .book, deferReflowLayout: true)
        let count = await pages.count
        XCTAssertEqual(count, 20)
        _ = try await pages.zoomLimit(rotation: 0, maximumZoom: ReadingZoom.absoluteMaximum)
        let firstBounds = try await pages.bounds(0)
        XCTAssertEqual(firstBounds.size, CGSize(width: 240, height: 320))
        _ = try await pages.zoomLimit(rotation: 90, maximumZoom: ReadingZoom.absoluteMaximum, uniform: true)
        do { _ = try await pages.bounds(19); XCTFail("The unread later canvas must fail only when requested") }
        catch { XCTAssertTrue(error.localizedDescription.contains("viewport")) }
    }

    func testConflictingLayoutDoesNotSilentlyDropASpineChapter() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, chapters: [
            ("", html("<p>FIRST</p>")),
            ("rendition:layout-pre-paginated rendition:layout-reflowable", html("<p>SECOND</p>")),
            ("", html("<p>LAST</p>"))
        ])
        XCTAssertThrowsError(try NativeFile(input, engine: .mupdf)) { error in
            XCTAssertTrue(error.localizedDescription.contains("conflicting"))
        }
    }

    func testFixedPaintingUsesPixelIntrinsicSizeAndCanvasPositioning() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 20, bitsPerComponent: 8, bytesPerRow: 1200,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 0, 1]))); context.fill(CGRect(x: 0, y: 0, width: 300, height: 20))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 1, 0, 1]))); context.fill(CGRect(x: 260, y: 0, width: 40, height: 20))
        let picture = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(picture, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let input = try fixture(in: directory.url, chapters: [("", html("""
        <img src='picture.png'/>
        <div style='position:absolute;left:25%;top:50%;width:25%;height:10%;background:#00ff00'/>
        <div style='position:fixed;right:10px;bottom:20px;width:40px;height:30px;background:#0000ff'/>
        """))], resources: ["picture.png": picture as Data])
        let book = try NativeFile(input, engine: .mupdf)
        let image = try book.image(0, width: 240)
        XCTAssertEqual(image.width, 240); XCTAssertEqual(image.height, 320)
        let data = try XCTUnwrap(image.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let components = image.bitsPerPixel / 8
            return Array(UnsafeBufferPointer(start: bytes + y * image.bytesPerRow + x * components, count: 3))
        }
        let imageBounds = try book.imageBounds(0)
        XCTAssertEqual(imageBounds, [CGRect(x: 0, y: 0, width: 240, height: 20)])
        XCTAssertEqual(pixel(235, 10), [255, 0, 0], "An oversized image is clipped, retaining intrinsic CSS pixels; image bounds=\(imageBounds)")
        XCTAssertEqual(pixel(70, 170), [0, 255, 0], "Percentage positions and sizes use the author canvas")
        XCTAssertEqual(pixel(200, 280), [0, 0, 255], "Fixed bottom/right positioning uses the author canvas")
        XCTAssertEqual(pixel(150, 230), [255, 255, 255])
    }
}
#endif
