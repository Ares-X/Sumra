#if os(macOS)
import CoreGraphics
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativeEPUBPositionTests: XCTestCase {
    private let token = "CHAPTER_ONE_PASSAGE_0070"

    func testSavedSingleChapterPassageWithoutChapterStillDecodes() throws {
        let saved = Data("{\"source\":[7,3,0],\"offsetX\":2,\"offsetY\":4,\"sourceRevision\":\"original\",\"styleSignature\":\"style\"}".utf8)
        let passage = try JSONDecoder().decode(NativePassage.self, from: saved)
        XCTAssertEqual(passage.chapter, 0)
        XCTAssertEqual(passage.source, NativeSourceAnchor(node: 7, offset: 3, part: 0))
        XCTAssertEqual(passage.offsetX, 2); XCTAssertEqual(passage.offsetY, 4)
    }

    func testSavedPassageReopensInItsChapterAfterWidthAndFontChanges() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epub(in: directory.url)
        let saved: ReadingPosition
        do {
            let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light", pageSize: CGSize(width: 640, height: 0))
            let page = try file.page(PageLocation(chapter: 1, page: 0))
            let rect = try XCTUnwrap(file.matches(token, page: page).first?.rects.first)
            XCTAssertGreaterThan(rect.minY, 1000)
            let passage = try XCTUnwrap(file.passage(page, at: CGPoint(x: rect.minX, y: rect.minY)))
            saved = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(
                ReadingPosition(page: page, x: Double(rect.minX), y: Double(rect.minY), anchor: try file.anchor(page), nativePassage: passage)))
        }
        let reopened = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        _ = try reopened.relayout(fontSize: 23, lineHeight: 1.4, font: "sans-serif", theme: "light", pageSize: CGSize(width: 380, height: 0))
        let restored = try XCTUnwrap(reopened.position(for: XCTUnwrap(saved.nativePassage)))
        XCTAssertEqual(try reopened.location(restored.page), PageLocation(chapter: 1, page: 0))
        let rect = try XCTUnwrap(reopened.matches(token, page: restored.page).first?.rects.first)
        XCTAssertEqual(try XCTUnwrap(restored.x), Double(rect.minX), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(restored.y), Double(rect.minY), accuracy: 1)
        XCTAssertGreaterThan(abs(try XCTUnwrap(restored.y) - XCTUnwrap(saved.y)), 100)
        XCTAssertEqual(restored.nativePassage?.source, saved.nativePassage?.source)
        XCTAssertFalse(try XCTUnwrap(reopened.chapterTable).isLaidOut(0))
        _ = try reopened.relayout(fontSize: 23, lineHeight: 1.4, font: "sans-serif", theme: "light", pageSize: CGSize(width: 380, height: 420))
        let paged = try XCTUnwrap(reopened.position(for: XCTUnwrap(saved.nativePassage)))
        let originalLocation = try reopened.location(paged.page)
        try reopened.publishWarmedChapters()
        let published = try XCTUnwrap(reopened.position(for: XCTUnwrap(saved.nativePassage)))
        XCTAssertEqual(try reopened.location(published.page), originalLocation, "Counting earlier chapters must only change the source's flat page projection")
        XCTAssertTrue(try XCTUnwrap(reopened.text(published.page)).contains(token))
    }

    func testFontReflowAndReadingModesKeepTheOriginalChapterPassage() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epub(in: directory.url)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "serif", theme: "light", pageSize: CGSize(width: 640, height: 0))
        let matches = try await pages.matches(token, location: PageLocation(chapter: 1, page: 0))
        let rect = try XCTUnwrap(matches.first?.rects.first)
        XCTAssertGreaterThan(rect.minY, 1000)
        var position = try await pages.position(PageLocation(chapter: 1, page: 0), x: Double(rect.minX), y: Double(rect.minY))
        let source = position.nativePassage?.source
        for (fontSize, font, size) in [(18.0, "serif", CGSize(width: 640, height: 0)),
                                       (23.0, "sans-serif", CGSize(width: 380, height: 420)),
                                       (23.0, "sans-serif", CGSize(width: 720, height: 420)),
                                       (23.0, "sans-serif", CGSize(width: 380, height: 0))] {
            _ = try await pages.relayout(fontSize: fontSize, lineHeight: 1.4, margin: 32, font: font, theme: "light", pageSize: size, readingPosition: position)
            position = await pages.layoutPosition
            let location = try XCTUnwrap(position.anchor.flatMap(ChapterTable.bookmarkLocation)?.location)
            XCTAssertEqual(location.chapter, 1)
            let matches = try await pages.matches(token, page: position.page)
            let target = try XCTUnwrap(matches.first?.rects.first, "The restored page must contain the original passage")
            XCTAssertEqual(try XCTUnwrap(position.x), Double(target.minX), accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(position.y), Double(target.minY), accuracy: 1)
            XCTAssertEqual(position.nativePassage?.source, source)
        }
        XCTAssertNotNil(source)
    }

    func testImagePlacementsKeepTheirSourceAcrossPaginationAndContinuousLayout() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try EPUBImagePositionFixture.make(in: directory.url, repeatedImage: true)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        var identities = Set<NativeSourceAnchor>()
        for image in [0, 2, 3] {
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.2, margin: 0, font: "system", theme: "light", pageSize: CGSize(width: 720, height: 480))
            var position = try await pages.position(.init(chapter: 1, page: image), x: 0, y: 0, viewport: CGSize(width: 720, height: 480))
            let passage = try XCTUnwrap(position.nativePassage, "An image-only page needs a stable source passage")
            identities.insert(passage.source)
            let saved = try JSONDecoder().decode(NativePassage.self, from: JSONEncoder().encode(passage))
            for size in [CGSize(width: 720, height: 0), CGSize(width: 360, height: 480),
                         CGSize(width: 360, height: 0), CGSize(width: 720, height: 480)] {
                _ = try await pages.relayout(fontSize: 17, lineHeight: 1.2, margin: 0, font: "system", theme: "light",
                                             pageSize: size, readingPosition: position)
                position = await pages.layoutPosition
                let location = try XCTUnwrap(position.anchor.flatMap(ChapterTable.bookmarkLocation)?.location)
                XCTAssertEqual(location, PageLocation(chapter: 1, page: size.height == 0 ? 0 : image))
                XCTAssertEqual(position.nativePassage?.source, saved.source)
                let images = try await pages.imageBounds(location)
                let rect = try XCTUnwrap(size.height == 0 ? (images.indices.contains(image) ? images[image] : nil) : images.first)
                XCTAssertEqual(try XCTUnwrap(position.x) - saved.offsetX, Double(rect.minX), accuracy: 0.03)
                XCTAssertEqual(try XCTUnwrap(position.y) - saved.offsetY, Double(rect.minY), accuracy: 0.03)
            }
        }
        XCTAssertEqual(identities.count, 3, "Repeated placements of the same raster must keep distinct source identities")
    }

    func testVisibleCaptionKeepsItsGlyphPriorityOverAnImagePassage() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try EPUBImagePositionFixture.make(in: directory.url, captions: true)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 720, height: 480))
        let page = try file.page(.init(chapter: 1, page: 0))
        let image = try XCTUnwrap(file.imageBounds(page).first)
        let caption = try XCTUnwrap(file.matches("CAPTION_IMAGE_0", page: page).first?.rects.first)
        let textPassage = try XCTUnwrap(file.passage(page, at: caption.origin))
        let wholePage = try XCTUnwrap(file.passage(page, at: CGPoint(x: image.midX, y: image.midY)))
        XCTAssertEqual(wholePage.source.node, textPassage.source.node, "Existing prose and captions remain the authoritative source when visible")
        let imageRegion = try XCTUnwrap(file.passage(page, at: image.origin, in: image.insetBy(dx: 1, dy: 1)))
        XCTAssertNotEqual(imageRegion.source.node, textPassage.source.node, "An image-only viewport must have its own stable source")
    }

    private func epub(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let names = ["zero", "one", "two"]
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest>" + names.map { "<item id='\($0)' href='\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined() + "</manifest><spine>" + names.map { "<itemref idref='\($0)'/>" }.joined() + "</spine></package>"
        ]
        for (chapter, name) in names.enumerated() {
            let prose = (0..<100).map { paragraph in
                let marker = chapter == 1 && paragraph == 70 ? token : "CHAPTER_\(chapter)_PASSAGE_\(paragraph)"
                return "<p>\(marker) keeps this authored passage in its own chapter when typography and reading geometry change. The source remains ordinary readable prose.</p>"
            }.joined()
            files[name + ".xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><body>\(prose)</body></html>"
        }
        for (name, contents) in files { try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create the EPUB position fixture") }
        return directory.appendingPathComponent("book.epub")
    }
}
#endif
