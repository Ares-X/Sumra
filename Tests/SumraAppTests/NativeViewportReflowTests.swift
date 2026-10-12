#if os(macOS)
import CoreGraphics
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativeViewportReflowTests: XCTestCase {
    func testLightThemeUpgradeKeepsLegacyAndCurrentPassagesWithStrictSourceAndUserStyles() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Upgrade.md")
        let paragraphs = (0..<120).map { "Paragraph \($0) keeps its source passage when an upgrade adds reader palette colors." }
        try paragraphs.joined(separator: "\n\n").write(to: input, atomically: true, encoding: .utf8)
        let css = "p{letter-spacing:0.1pt}"
        let legacy = try NativeFile(input, engine: .mupdf)
        _ = try legacy.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light", userCSS: css,
                                pageSize: CGSize(width: 620, height: 360))
        let page = legacy.count / 2
        XCTAssertGreaterThan(page, 0)
        let glyph = try XCTUnwrap(legacy.words(page).first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
        let saved = try XCTUnwrap(legacy.passage(page, at: CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)))
        let serialized = try JSONDecoder().decode(NativePassage.self, from: JSONEncoder().encode(saved))
        let effectiveCSS = try XCTUnwrap(ReaderTheme.all.first { $0.id == "light" }).css + "\n" + css
        func layout(_ file: NativeFile, css: String = effectiveCSS, useDocumentCSS: Bool = true) throws {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light", userCSS: css,
                                  useDocumentCSS: useDocumentCSS, pageSize: CGSize(width: 380, height: 0))
        }
        let upgraded = try NativeFile(input, engine: .mupdf)
        try layout(upgraded)
        XCTAssertEqual(upgraded.count, 1)
        let restored = try XCTUnwrap(upgraded.position(for: serialized))
        XCTAssertGreaterThan(try XCTUnwrap(restored.y), 800, "The old paginated passage must restore inside the continuous document")
        let current = try XCTUnwrap(upgraded.passage(restored.page, at: CGPoint(x: try XCTUnwrap(restored.x), y: try XCTUnwrap(restored.y))))
        XCTAssertEqual(current.source, serialized.source)
        XCTAssertNotEqual(current.styleSignature, serialized.styleSignature)
        let reopened = try NativeFile(input, engine: .mupdf)
        try layout(reopened)
        XCTAssertEqual(try reopened.position(for: serialized)?.nativePassage?.source, serialized.source)
        XCTAssertEqual(try reopened.position(for: current)?.nativePassage, current, "Bookmarks written by the current candidate must remain valid")
        try layout(reopened, css: effectiveCSS + "\np{display:none}")
        XCTAssertNil(try reopened.position(for: serialized))
        XCTAssertNil(try reopened.position(for: current))
        try layout(reopened, useDocumentCSS: false)
        XCTAssertNil(try reopened.position(for: serialized))
        XCTAssertNil(try reopened.position(for: current))
        try paragraphs.joined(separator: "\n\n").replacingOccurrences(of: "source", with: "different").write(to: input, atomically: true, encoding: .utf8)
        let changed = try NativeFile(input, engine: .mupdf)
        try layout(changed)
        XCTAssertNil(try changed.position(for: serialized))
        XCTAssertNil(try changed.position(for: current))
    }

    func testEPUBResizeRestoresTheOriginalTextWithoutLoadingOtherChapters() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epubFixture(in: directory.url)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        func layout(_ size: CGSize) throws {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                                  pageMargins: PageMargins(cssValues: [20]), pageSize: size)
        }
        let wide = CGSize(width: 640, height: 720)
        try layout(wide)
        try file.ensureChapter(1)
        let wideCount = try XCTUnwrap(file.chapterTable?.pageCount(1))
        let originalLocation = PageLocation(chapter: 1, page: wideCount / 2)
        let originalPage = try file.page(originalLocation)
        let words = try file.words(originalPage)
        let glyphIndex = try XCTUnwrap(words.firstIndex { $0.text == "W" && $0.bounds.midY > 200 })
        let glyph = words[glyphIndex]
        let readingWord = words[glyphIndex...].prefix(10).map(\.text).joined()
        let point = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
        let bookmark = try XCTUnwrap(file.passage(originalPage, at: point))
        XCTAssertGreaterThan(point.y, 200, "The captured viewport must be inside the page rather than at its top")
        XCTAssertEqual(file.chapterTable?.isLaidOut(0), false)

        try layout(CGSize(width: 320, height: 360))
        let restored = try XCTUnwrap(file.position(for: bookmark))
        XCTAssertEqual(try file.location(restored.page).chapter, 1)
        XCTAssertTrue(try XCTUnwrap(file.text(restored.page)).contains(readingWord), "The text at the old viewport must remain on the restored page after resize")
        let restoredPoint = CGPoint(x: try XCTUnwrap(restored.x), y: try XCTUnwrap(restored.y))
        XCTAssertGreaterThan(restoredPoint.y, 0, "Resize must restore the glyph's page coordinate")
        XCTAssertEqual(try file.passage(restored.page, at: restoredPoint)?.source, bookmark.source)
        XCTAssertGreaterThan(try XCTUnwrap(file.chapterTable?.pageCount(1)), wideCount)
        XCTAssertEqual(file.chapterTable?.isLaidOut(0), false, "The preceding invalid fixed canvas must remain unopened")

        try layout(CGSize(width: 320, height: 0))
        let continuous = try XCTUnwrap(file.position(for: bookmark))
        XCTAssertEqual(try file.location(continuous.page), PageLocation(chapter: 1, page: 0))
        XCTAssertEqual(file.chapterTable?.pageCount(1), 1)
        XCTAssertGreaterThan(try XCTUnwrap(file.bounds(continuous.page)).height, 720)
        XCTAssertEqual(try file.passage(continuous.page, at: CGPoint(x: try XCTUnwrap(continuous.x), y: try XCTUnwrap(continuous.y)))?.source, bookmark.source)
        XCTAssertEqual(file.chapterTable?.isLaidOut(0), false)

        try layout(wide)
        let returned = try XCTUnwrap(file.position(for: bookmark))
        XCTAssertEqual(try file.location(returned.page), originalLocation)
        XCTAssertEqual(try XCTUnwrap(returned.x), Double(point.x), accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(returned.y), Double(point.y), accuracy: 0.05)
        XCTAssertEqual(file.chapterTable?.isLaidOut(0), false)
        XCTAssertThrowsError(try file.bounds(0), "Requesting the preceding invalid fixed canvas must fail")
    }

    private func epubFixture(in directory: URL, fixedHTML: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let prose = (0..<1200).map { String(format: "WORD%06d", $0) }.joined(separator: " ")
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest><item id='bad' href='bad.xhtml' media-type='application/xhtml+xml'/><item id='prose' href='prose.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='bad' properties='rendition:layout-pre-paginated'/><itemref idref='prose'/></spine></package>",
            "bad.xhtml": fixedHTML ?? "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>A fixed canvas without its required viewport.</p></body></html>",
            "prose.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>\(prose)</p></body></html>"
        ]
        for (name, contents) in files { try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create the EPUB viewport fixture") }
        return directory.appendingPathComponent("book.epub")
    }

    func testContinuousEPUBKeepsFixedCanvasAndRendersOnlyTheRequestedTile() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try epubFixture(in: directory.url, fixedHTML: "<html xmlns='http://www.w3.org/1999/xhtml'><head><meta name='viewport' content='width=240,height=320'/></head><body><p>AUTHOR</p></body></html>")
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                              pageMargins: PageMargins(cssValues: [20]), pageSize: CGSize(width: 320, height: 0))
        XCTAssertEqual(try file.bounds(0)?.size, CGSize(width: 240, height: 320))
        let prose = try file.page(PageLocation(chapter: 1, page: 0))
        XCTAssertEqual(file.chapterTable?.pageCount(1), 1)
        XCTAssertGreaterThan(try XCTUnwrap(file.bounds(prose)).height, 720)
        let tile = try file.image(prose, width: 320, region: CGRect(x: 0, y: 200, width: 320, height: 128))
        XCTAssertEqual(tile.width, 320)
        XCTAssertEqual(tile.height, 128)
        XCTAssertEqual((tile.dataProvider?.data as Data?)?.count, tile.bytesPerRow * 128)
    }

    func testContinuousHTMLAndMarkdownUseNaturalHeightWithoutPageGaps() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let text = String(repeating: "Ordinary words flow without paper boundaries. ", count: 80)
        for ext in ["html", "md"] {
            let input = directory.url.appendingPathComponent("Stream.\(ext)")
            let content = ext == "html"
                ? "<html><head><meta name='viewport' content='width=1200,height=800'/></head><body><p>\(text)</p><p style='page-break-before:always'>\(text)</p></body></html>"
                : text + "\n\n" + text
            try content.write(to: input, atomically: true, encoding: .utf8)
            let file = try NativeFile(input, engine: .mupdf)
            let css = "body,p{margin:0;padding:0} @page{margin:50pt 32pt !important}"
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light", userCSS: css, pageSize: CGSize(width: 320, height: 360))
            let glyph = try XCTUnwrap(file.words(0).first { $0.source != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let passage = try XCTUnwrap(file.passage(0, at: CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)))
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light", userCSS: css, pageSize: CGSize(width: 320, height: 0))
            XCTAssertEqual(file.count, 1)
            let bounds = try XCTUnwrap(file.bounds(0))
            XCTAssertEqual(bounds.width, 320, "Author viewport sizing must not override the stream's window width")
            XCTAssertGreaterThan(bounds.height, 720)
            XCTAssertEqual(try file.text(0)?.filter { !$0.isWhitespace }, (text + text).filter { !$0.isWhitespace })
            let words = try file.words(0).filter { !$0.bounds.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            XCTAssertEqual(try XCTUnwrap(words.first).bounds.minX, 32, accuracy: 0.05, "Continuous layout must keep custom side margins")
            XCTAssertLessThan(try XCTUnwrap(words.first).bounds.minY, 20, "Continuous layout must remove repeated top page margins")
            let rows = Array(Set(words.map { Int(($0.bounds.minY * 100).rounded()) })).sorted()
            let gaps = zip(rows, rows.dropFirst()).map { pair in Double(pair.1 - pair.0) / 100 }
            XCTAssertFalse(gaps.isEmpty)
            XCTAssertTrue(gaps.allSatisfy { abs($0 - 17 * 1.4) < 0.1 }, "Every adjacent line must keep natural leading, including the authored page break")
            let restored = try XCTUnwrap(file.position(for: passage))
            XCTAssertEqual(restored.nativePassage?.source, passage.source)
            XCTAssertTrue(words.contains { $0.source == passage.source })
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light", userCSS: css, pageSize: CGSize(width: 320, height: 360))
            XCTAssertGreaterThan(file.count, 1)
            let finiteGlyph = try XCTUnwrap(file.words(0).first { $0.source == glyph.source })
            XCTAssertEqual(finiteGlyph.bounds.minX, glyph.bounds.minX, accuracy: 0.05)
            XCTAssertEqual(finiteGlyph.bounds.minY, glyph.bounds.minY, accuracy: 0.05, "Returning to paper pages must restore authored vertical margins")
        }
    }

    func testEmptyContinuousChapterHasOneNaturalEmptyLine() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Empty.html")
        try "<html><body></body></html>".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light", userCSS: "body{margin:0;padding:0}", pageSize: CGSize(width: 320, height: 0))
        XCTAssertEqual(file.count, 1)
        XCTAssertEqual(try file.bounds(0)?.size, CGSize(width: 320, height: 17))
        XCTAssertTrue(try XCTUnwrap(file.text(0)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let image = try file.image(0, width: 320)
        XCTAssertEqual(image.height, 17)
    }

    func testContinuousRectangleSelectionKeepsOnlyVisibleGlyphsAndTheirSourceBounds() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Regions.html")
        let paragraphs = (0..<200).map { "<p>Line \($0) office ﬁ keeps its source.</p>" }.joined()
        try "<html><body>\(paragraphs)</body></html>".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                              userCSS: "body,p{margin:0;padding:0}",
                              pageMargins: PageMargins(cssValues: [20]), pageSize: CGSize(width: 320, height: 0))
        let whole = try file.words(0)
        let glyphs = whole.filter { !$0.bounds.isEmpty }
        let rows = Array(Set(glyphs.map { $0.bounds.minY })).sorted()
        XCTAssertGreaterThan(rows.count, 100)
        var regions = [CGRect]()
        for start in [rows.count / 5, rows.count * 4 / 5] {
            let rowGlyphs = glyphs.filter { rows[start...start + 2].contains($0.bounds.minY) }
            let first = try XCTUnwrap(rowGlyphs.map { $0.bounds.minY }.min())
            let last = try XCTUnwrap(rowGlyphs.map { $0.bounds.maxY }.max())
            let region = CGRect(x: start == rows.count / 5 ? 0 : 60, y: first - 2,
                                width: start == rows.count / 5 ? 320 : 90, height: last - first + 4)
            regions.append(region)
            let selected = try file.selection(0, from: region.origin,
                                              to: CGPoint(x: region.maxX, y: region.maxY), mode: 3)
            let words = try XCTUnwrap(selected.words)
            let actual = words.filter { !$0.bounds.isEmpty }
            let expected = glyphs.filter { $0.bounds.intersects(region) }
            XCTAssertFalse(actual.isEmpty)
            XCTAssertLessThan(actual.count, glyphs.count / 20, "A visible region must not return the natural chapter's entire glyph stream")
            XCTAssertEqual(actual.count, expected.count)
            for (actual, expected) in zip(actual, expected) {
                XCTAssertEqual(actual.text, expected.text)
                XCTAssertEqual(actual.source, expected.source)
                XCTAssertEqual(actual.rect, expected.rect, "Regional extraction must keep the original glyph bounds")
            }
            XCTAssertTrue(actual.contains { $0.source != nil })
            XCTAssertEqual(selected.text, words.map(\.text).joined())
            let intersectedRows = Set(expected.map { $0.bounds.minY }).count
            XCTAssertEqual(words.filter { $0.text == "\n" }.count, intersectedRows - 1,
                           "Every intersecting line, including partially visible boundary lines, retains its separator")
        }
        XCTAssertFalse(regions[0].intersects(regions[1]))
        let after = try file.words(0)
        XCTAssertEqual(after.map(\.text), whole.map(\.text), "Regional requests must preserve ordinary whole-page selection")
        XCTAssertEqual(after.map(\.source), whole.map(\.source))
        XCTAssertEqual(after.map(\.rect), whole.map(\.rect))
    }

    func testContinuousViewportPassageMatchesFullSourceAndOffsets() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("ViewportPassage.html")
        let paragraphs = (0..<120).map { "<p>Line \($0) keeps its original source position.</p>" }.joined()
        try "<html><body>\(paragraphs)</body></html>".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                              userCSS: "body,p{margin:0;padding:0}",
                              pageMargins: PageMargins(cssValues: [20]), pageSize: CGSize(width: 320, height: 0))
        let glyphs = try file.words(0).filter {
            $0.source != nil && !$0.bounds.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let rows = Array(Set(glyphs.map { $0.bounds.minY })).sorted()
        XCTAssertGreaterThan(rows.count, 100)
        for row in [rows[rows.count / 5], rows[rows.count * 4 / 5]] {
            let glyph = try XCTUnwrap(glyphs.first { $0.bounds.minY == row })
            let region = CGRect(x: 0, y: glyph.bounds.minY - 4, width: 320, height: glyph.bounds.height + 8)
            let points = [CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY),
                          CGPoint(x: 0, y: glyph.bounds.midY)]
            for point in points {
                let full = try XCTUnwrap(file.passage(0, at: point))
                let bounded = try XCTUnwrap(file.passage(0, at: point, in: region))
                XCTAssertEqual(full.source, glyph.source, "A glyph or adjacent left margin must anchor to the same nearest line")
                XCTAssertEqual(bounded.source, full.source)
                XCTAssertEqual(bounded.offsetX, full.offsetX)
                XCTAssertEqual(bounded.offsetY, full.offsetY)
                XCTAssertEqual(bounded, full, "Viewport capture must preserve the full capture's exact source identity and offsets")
            }
        }
    }

    func testSourceOnlyLookupKeepsLigaturePartsAndCombiningGlyphBounds() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("Clusters.html")
        try "<html><body><p>office affine ﬁ ﬃ a\u{0301} x\u{0308}</p><p><span class='base'>a</span><span class='mark'>\u{0301}</span> ending</p></body></html>"
            .write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        typealias Lookup = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, UInt32, UInt32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let lookup = try XCTUnwrap(file.symbol("lf_html_anchor_position", Lookup.self))
        struct Result: Decodable { let page: Int; let rect: [Double] }
        for height in [CGFloat(0), CGFloat(360)] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                                  userCSS: ".base{font-family:sans-serif!important}.mark{font-family:serif!important}",
                                  pageSize: CGSize(width: 320, height: height))
            let whole = try file.words(0)
            XCTAssertTrue(whole.contains { ($0.source?.part ?? 0) > 0 }, "The fixture must exercise decomposed presentation-ligature parts")
            XCTAssertTrue(whole.contains { $0.text == "\u{0301}" }, "The fixture must exercise a combining character that inherits its base's pen")
            for glyph in whole where glyph.source != nil && !glyph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let source = try XCTUnwrap(glyph.source)
                var error = [CChar](repeating: 0, count: 512)
                let result = try file.decode(lookup(file.document, 0, source.node, source.offset, source.part, &error),
                                             error: error, as: Result?.self)
                let resolved = try XCTUnwrap(result, "Source-only extraction must retain every original source part")
                XCTAssertEqual(resolved.page, 0)
                XCTAssertEqual(resolved.rect, glyph.rect, "Source \(source) (\(glyph.text)) must retain its whole-page glyph bounds")
            }
            let glyph = try XCTUnwrap(whole.last {
                $0.source != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            let source = try XCTUnwrap(glyph.source)
            let original = try XCTUnwrap(file.position(for: source))
            let passage = try XCTUnwrap(original.nativePassage)
            XCTAssertEqual(try file.position(for: passage), original,
                           "Repeated passage lookups must preserve the resolved source position")
            var previous = original
            for fontSize in [Double(17), Double(23)] {
                _ = try file.relayout(fontSize: fontSize, lineHeight: 1.4, font: "serif", theme: "light",
                                      userCSS: ".base{font-family:sans-serif!important}.mark{font-family:serif!important}",
                                      pageSize: CGSize(width: 160, height: height))
                let restored = try XCTUnwrap(file.position(for: passage))
                let currentGlyph = try XCTUnwrap(file.words(restored.page).first { $0.source == source })
                XCTAssertEqual(restored.nativePassage?.source, source)
                XCTAssertEqual(restored.x, Double(currentGlyph.bounds.minX))
                XCTAssertEqual(restored.y, Double(currentGlyph.bounds.minY))
                XCTAssertTrue(restored.x != previous.x || restored.y != previous.y,
                              "Width or font-size changes must resolve the source at its new geometry")
                XCTAssertEqual(try file.position(for: passage), restored,
                               "Repeated lookups after reflow must preserve the new source geometry")
                previous = restored
            }
        }
    }

    func testSourceLookupReturnsItsActualPageAndClusterGeometryInLongFlow() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("LongSourceFlow.html")
        let prose = String(repeating: "office ﬁ affine a\u{0301} keeps its source position. ", count: 300)
        try "<html><body><p>\(prose)</p></body></html>".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        typealias Lookup = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, UInt32, UInt32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let lookup = try XCTUnwrap(file.symbol("lf_html_anchor_position", Lookup.self))
        struct Result: Decodable { let page: Int; let rect: [Double] }
        for height in [CGFloat(0), CGFloat(360)] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                                  pageSize: CGSize(width: 320, height: height))
            if height > 0 { XCTAssertGreaterThan(file.count, 5) }
            let pages = height == 0 ? [0] : [0, file.count / 2, file.count - 1]
            for page in pages {
                let glyphs = try file.words(page).filter { $0.source != nil }
                XCTAssertFalse(glyphs.isEmpty)
                let space = try XCTUnwrap(glyphs.first { $0.text == " " })
                for glyph in [glyphs[0], glyphs[glyphs.count / 2], glyphs[glyphs.count - 1], space] {
                    let source = try XCTUnwrap(glyph.source)
                    var error = [CChar](repeating: 0, count: 512)
                    let result = try file.decode(lookup(file.document, 0, source.node, source.offset, source.part, &error),
                                                 error: error, as: Result?.self)
                    let resolved = try XCTUnwrap(result)
                    XCTAssertEqual(resolved.page, page, "Source resolution must return the target's page rather than chapter page zero")
                    XCTAssertEqual(resolved.rect, glyph.rect)
                }
            }
            var error = [CChar](repeating: 0, count: 512)
            let missing = try file.decode(lookup(file.document, 0, UInt32.max, 0, 0, &error), error: error, as: Result?.self)
            XCTAssertNil(missing)
        }
    }

    func testViewportChangesPaginationAndPreservesTheSourceGlyph() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let paragraphs = (0..<80).map {
            "Paragraph \($0): The reader keeps the exact source glyph while a wider window changes line wrapping and page breaks."
        }
        for ext in ["md", "html"] {
            let input = directory.url.appendingPathComponent("Viewport.\(ext)")
            let contents = ext == "md" ? paragraphs.joined(separator: "\n\n")
                : "<html><body>" + paragraphs.map { "<p>\($0)</p>" }.joined() + "</body></html>"
            try contents.write(to: input, atomically: true, encoding: .utf8)
            let file = try NativeFile(input, engine: .mupdf)
            let wide = CGSize(width: 640, height: 720)
            let narrow = CGSize(width: 320, height: 720)
            let short = CGSize(width: 320, height: 360)
            func layout(_ size: CGSize) throws {
                _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: "light",
                                      pageMargins: PageMargins(cssValues: [20]), pageSize: size)
                XCTAssertEqual(try file.bounds(0)?.size, size)
            }
            try layout(wide)
            let wideCount = file.count
            let page = file.count / 2
            let glyph = try XCTUnwrap(file.words(page).first {
                $0.source != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            let passage = try XCTUnwrap(file.passage(page, at: CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)))

            try layout(narrow)
            XCTAssertGreaterThan(file.count, wideCount, "A narrow page must wrap the same prose onto more pages")
            let narrowCount = file.count
            try layout(short)
            XCTAssertGreaterThan(file.count, narrowCount, "A shorter page must use its available height for pagination")
            let restored = try XCTUnwrap(file.position(for: passage))
            XCTAssertEqual(restored.nativePassage?.source, passage.source)
            XCTAssertTrue(try file.words(restored.page).contains { $0.source == passage.source })
            let text = try (0..<file.count).map { try XCTUnwrap(file.text($0)) }.joined()
            XCTAssertEqual(text.filter { !$0.isWhitespace }, paragraphs.joined().filter { !$0.isWhitespace })

            try layout(wide)
            XCTAssertEqual(file.count, wideCount)
            let returned = try XCTUnwrap(file.position(for: passage))
            XCTAssertEqual(returned.page, page)
            XCTAssertEqual(returned.nativePassage?.source, passage.source)
            XCTAssertEqual(try file.words(page).first { $0.source == glyph.source }?.rect, glyph.rect)
        }
    }

    func testReaderThemeReplacesPublisherBlocksAndExplicitUserCSSWins() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("PublisherColors.html")
        try """
        <html><head><style>
        body,p{margin:0;padding:0} .block{background-color:black !important;color:white !important;height:180pt}
        </style></head><body>
        <div class='block'><p>Readable class theme text</p></div>
        <div class='block' style='background:black;color:white !important'><p>Readable inline theme text</p></div>
        </body></html>
        """.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        func rgb(_ value: UInt32) -> [UInt8] {
            [UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        }
        func snapshot(theme: String, css: String = "") throws -> (CGImage, Data) {
            _ = try file.relayout(fontSize: 22, lineHeight: 1.4, font: "serif", theme: theme, userCSS: css,
                                  pageMargins: PageMargins(cssValues: [0]), pageSize: CGSize(width: 400, height: 400))
            let image = try file.image(0, width: 400)
            XCTAssertEqual(image.bitsPerPixel, 24)
            return (image, try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        func sample(_ snapshot: (CGImage, Data), x: Int, y: Int) -> [UInt8] {
            let offset = y * snapshot.0.bytesPerRow + x * 3
            return Array(snapshot.1[offset..<(offset + 3)])
        }
        for theme in ["light", "dark", "light-warm"] {
            let palette = try XCTUnwrap(ReaderTheme.all.first { $0.id == theme })
            let rendered = try snapshot(theme: theme)
            XCTAssertEqual(sample(rendered, x: 200, y: 100), rgb(palette.background), "Publisher blocks must follow the reader paper color")
            XCTAssertEqual(sample(rendered, x: 200, y: 280), rgb(palette.background), "Inline publisher backgrounds must follow the reader paper color")
            XCTAssertEqual(sample(rendered, x: 200, y: 390), rgb(palette.background))
            let foreground = rgb(palette.text)
            for rows in [0..<180, 180..<360] {
                XCTAssertTrue(rows.contains { y in
                    (0..<rendered.0.width).contains { x in sample(rendered, x: x, y: y) == foreground }
                }, "Both class and inline publisher text must use the reader color")
            }
        }
        let overridden = try snapshot(theme: "light", css: ".block{background-color:#ff0000 !important;color:#00ff00 !important}")
        XCTAssertEqual(sample(overridden, x: 200, y: 100), [255, 0, 0])
        XCTAssertEqual(sample(overridden, x: 200, y: 280), [255, 0, 0])
        XCTAssertEqual(sample(overridden, x: 200, y: 390), rgb(ReaderTheme.all[0].background))
    }
}
#endif
