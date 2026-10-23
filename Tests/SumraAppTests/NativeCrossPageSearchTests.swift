#if os(macOS)
import AppKit
import CoreText
import SumraCore
import XCTest
@testable import Sumra

final class NativeCrossPageSearchTests: XCTestCase {
    private func pdf(_ pages: [[String]], in directory: TemporaryDirectory) throws -> URL {
        let url = directory.url.appendingPathComponent("cross-page.pdf")
        var box = CGRect(x: 0, y: 0, width: 320, height: 240)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 17, nil)]
        for lines in pages {
            context.beginPDFPage(nil)
            for (line, text) in lines.enumerated() {
                context.textPosition = CGPoint(x: 20, y: 200 - line * 30)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testPDFPhraseSpansFourPagesWithOneOwnerAndAllHighlights() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(pdf([["alpha"], ["beta"], ["gamma"], ["delta"]], in: directory), engine: .mupdf)
        let hit = try XCTUnwrap(file.matches("alpha beta gamma delta", page: 0).first)
        XCTAssertEqual(hit.page, 0)
        XCTAssertEqual(hit.fragments?.map(\.page), [0, 1, 2, 3])
        for page in 0..<4 { XCTAssertFalse(hit.rects(on: page).isEmpty) }
        XCTAssertEqual(try (0..<4).flatMap { try file.matches("alpha beta gamma delta", page: $0) }.count, 1)
        XCTAssertEqual(try file.matches("alpha beta gamma delta", page: 0, backwards: true), [hit])
        XCTAssertTrue(try file.matches("alpha beta gamma delta", page: 0, after: hit.index).isEmpty)
        XCTAssertTrue(try file.matches("alpha beta gamma delta", page: 0,
            options: .init(allowedPages: IndexSet([0, 1, 3]))).isEmpty)
        XCTAssertTrue(hit.context.contains("alpha beta gamma delta"))
    }

    func testPDFChinesePhraseSpansPhysicalPagesWithoutAddingASpace() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(pdf([["普通"], ["汉字"]], in: directory), engine: .mupdf)
        let matches = try file.matches("普通汉字", page: 0)
        let hit = try XCTUnwrap(matches.first)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(hit.fragments?.map(\.page), [0, 1])
        XCTAssertFalse(hit.rects(on: 0).isEmpty)
        XCTAssertFalse(hit.rects(on: 1).isEmpty)
        XCTAssertEqual(try file.matches("普通汉字", page: 0, backwards: true), matches)
    }

    func testPDFNextPreviousFindsEachLogicalSpanOnce() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(pdf([["alpha"], ["beta alpha"], ["beta"]], in: directory), engine: .mupdf)
        let first = try XCTUnwrap(file.matches("alpha beta", page: 0, maximum: 1).first)
        let second = try XCTUnwrap(file.matches("alpha beta", page: 1, maximum: 1).first)
        XCTAssertEqual(first.fragments?.map(\.page), [0, 1])
        XCTAssertEqual(second.fragments?.map(\.page), [1, 2])
        XCTAssertEqual(try file.matches("alpha beta", page: 1, backwards: true, maximum: 1).first, second)
        XCTAssertEqual(try file.matches("alpha beta", page: 0, backwards: true, maximum: 1).first, first)
        XCTAssertTrue(try file.matches("alpha beta", page: 1, after: second.index, maximum: 1).isEmpty)
        XCTAssertEqual(try (0..<file.count).flatMap { try file.matches("alpha beta", page: $0) }.count, 2)
    }

    func testPDFLineAndPageHyphenationKeepsOriginalNavigationOffsets() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(pdf([["prefix inter-", "national"], ["inter-"], ["national well-known"]], in: directory), engine: .mupdf)
        let line = try XCTUnwrap(file.matches("international", page: 0).first)
        let page = try XCTUnwrap(file.matches("international", page: 1).first)
        XCTAssertEqual(line.fragments?.map(\.page), [0])
        XCTAssertEqual(page.fragments?.map(\.page), [1, 2])
        let original = try XCTUnwrap(file.text(0)) as NSString
        XCTAssertEqual(original.substring(with: NSRange(location: line.index, length: 5)), "inter")
        XCTAssertTrue(try file.matches("wellknown", page: 2).isEmpty)
        XCTAssertEqual(try file.matches("well-known", page: 2).count, 1)
    }

    func testDjVuZonePhraseRetainsPerPageGeometryAndOriginalCursor() throws {
        func zone(_ text: String, y: Int = 0) -> RasterWord {
            RasterWord(text: text, rect: [10, Double(y), Double(text.utf16.count * 10), 20])
        }
        let words = [[zone("prefix inter-"), zone("\n", y: 30)], [zone("national"), zone("\n", y: 30)],
                     [zone("普通"), zone("\n", y: 30)], [zone("汉字")]]
        let hit = try XCTUnwrap(NativeFile.zoneMatches("international", page: 3, pageWords: words, options: .init()).first)
        XCTAssertEqual(hit.index, 7)
        XCTAssertEqual(hit.fragments?.map(\.page), [3, 4])
        XCTAssertFalse(hit.rects(on: 3).isEmpty)
        XCTAssertFalse(hit.rects(on: 4).isEmpty)
        XCTAssertTrue(try NativeFile.zoneMatches("international", page: 3, pageWords: words,
            options: .init(), after: hit.index).isEmpty)
        XCTAssertEqual(try NativeFile.zoneMatches("international", page: 3, pageWords: words,
            options: .init(), backwards: true).first?.index, hit.index)
        let cjk = try XCTUnwrap(NativeFile.zoneMatches("普通汉字", page: 5,
            pageWords: Array(words.suffix(2)), options: .init()).first)
        XCTAssertEqual(cjk.fragments?.map(\.page), [5, 6])
        XCTAssertEqual(try NativeFile.zoneMatches("softword", page: 0,
            pageWords: [[zone("soft\u{ad}word")]], options: .init()).count, 1)
        XCTAssertTrue(try NativeFile.zoneMatches("wellknown", page: 0,
            pageWords: [[zone("well-known")]], options: .init()).isEmpty)
    }

    func testFiniteEPUBPhraseCrossesSpineChaptersAndSourceSurvivesReflow() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let filler = String(repeating: "<p>Opening passage moves the final source marker when the font changes.</p>", count: 12)
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest><item id='a' href='a.xhtml' media-type='application/xhtml+xml'/><item id='b' href='b.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>",
            "a.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body>\(filler)<p>普通</p></body></html>",
            "b.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>汉字</p></body></html>"
        ]
        for (name, contents) in files { try contents.write(to: directory.url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory.url
        zip.arguments = ["-q", "-0", "cross-chapter.epub"] + files.keys.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        let file = try NativeFile(directory.url.appendingPathComponent("cross-chapter.epub"), engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 260, height: 180))
        XCTAssertTrue(try file.chapterMayMatch("普通 汉字", chapter: 0, options: .init()), "A phrase continuation in the next spine item cannot make its owner a negative candidate")
        let first = try XCTUnwrap((0..<file.count).flatMap { try file.matches("普通 汉字", page: $0) }.first)
        XCTAssertEqual(first.fragments?.compactMap { $0.location?.chapter }, [0, 1])
        let source = try XCTUnwrap(first.source), rect = try XCTUnwrap(first.rects.first)
        let passage = try XCTUnwrap(file.passage(first.page, at: CGPoint(x: rect.midX, y: rect.midY)))
        let text = try XCTUnwrap(file.text(first.page)) as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: first.index, length: 2)), "普通")
        _ = try file.relayout(fontSize: 23, lineHeight: 1.6, font: "system", theme: "light", pageSize: CGSize(width: 200, height: 150))
        let position = try XCTUnwrap(file.position(for: passage))
        let restored = try XCTUnwrap(file.matches("普通 汉字", page: position.page).first)
        XCTAssertEqual(restored.source, source)
        XCTAssertEqual(restored.fragments?.compactMap { $0.location?.chapter }, [0, 1])
        XCTAssertEqual(try (0..<file.count).flatMap { try file.matches("普通 汉字", page: $0) }.count, 1)
    }

    func testPaginatedHTMLSourceIdentityAndFragmentsSurviveReflow() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("cross-page.xhtml")
        let phrase = String(repeating: "普通汉字跨页短语", count: 40)
        try "<html><body><p>\(phrase)</p><p>inter&#xad;national</p></body></html>".write(to: url, atomically: true, encoding: .utf8)
        let file = try NativeFile(url, engine: .mupdf)
        let css = "@page{margin:0}body{margin:0}p{margin:0;font-family:monospace !important;}"
        _ = try file.relayout(fontSize: 17, lineHeight: 1, font: "system", theme: "light", userCSS: css,
            pageSize: CGSize(width: 38, height: 24))
        let first = try XCTUnwrap(file.matches(phrase, page: 0).first)
        XCTAssertGreaterThan(try XCTUnwrap(first.fragments).count, 2)
        let source = try XCTUnwrap(first.source)
        XCTAssertEqual(try (0..<file.count).flatMap { try file.matches("international", page: $0) }.count, 1)
        _ = try file.relayout(fontSize: 13, lineHeight: 1.4, font: "system", theme: "light", userCSS: css,
            pageSize: CGSize(width: 80, height: 55))
        let second = try XCTUnwrap(file.matches(phrase, page: 0).first)
        XCTAssertEqual(second.source, source)
        XCTAssertFalse(second.rects(on: second.page).isEmpty)
    }
}
#endif
