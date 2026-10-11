#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeReflowSpacingTests: XCTestCase {
    private func fixture(_ body: String, in directory: URL) throws -> NativeFile {
        let input = directory.appendingPathComponent(UUID().uuidString + ".html")
        try "<html><body style='margin:0'>\(body)</body></html>".write(to: input, atomically: true, encoding: .utf8)
        return try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
    }

    private func layout(_ file: NativeFile, preserve: Bool = false, width: CGFloat = 640, height: CGFloat = 0) throws {
        _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                              userCSS: preserve ? "body{-sumra-prose-spacing:preserve !important;}" : "",
                              pageMargins: PageMargins(cssValues: [20]), pageSize: CGSize(width: width, height: height))
    }

    private func gap(_ file: NativeFile) throws -> CGFloat {
        let first = try XCTUnwrap(file.matches("FIRST", page: 0).first?.rects.first)
        let second = try XCTUnwrap(file.matches("SECOND", page: 0).first?.rects.first)
        return second.minY - first.minY
    }

    func testRepeatedBreaksCompactToOneHardNewlineWithoutChangingSourceGlyphs() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for (separator, height) in ["<br></br><br></br>", "<br/><br/><br/>", "<br/>　 <a id='gap'></a>　<br/>"]
            .flatMap({ separator in [CGFloat(0), 300].map { (separator, $0) } }) {
            let file = try fixture("FIRST\(separator)SECOND", in: directory.url)
            try layout(file, preserve: true, height: height)
            let authored = try gap(file)
            let before = try file.words(0).filter { !$0.text.allSatisfy(\.isWhitespace) }
            let originalBlankSources = try file.words(0).filter { $0.text == "　" }.map(\.source)
            try layout(file, height: height)
            XCTAssertEqual(try gap(file), 27.2, accuracy: 0.05)
            XCTAssertGreaterThan(authored, try gap(file) + 20)
            let after = try file.words(0).filter { !$0.text.allSatisfy(\.isWhitespace) }
            XCTAssertEqual(after.map(\.text), before.map(\.text))
            XCTAssertEqual(after.map(\.source), before.map(\.source))
            XCTAssertEqual(try file.words(0).filter { $0.text == "　" }.map(\.source), originalBlankSources)
            XCTAssertTrue(try file.matches("FIRSTSECOND", page: 0).isEmpty, "Authored source separators must remain searchable boundaries")
            if separator.contains("gap") {
                let destination = try XCTUnwrap(file.resolve("#gap"))
                XCTAssertEqual(destination.page, 0)
                XCTAssertGreaterThan(try XCTUnwrap(destination.y), 0)
                XCTAssertLessThan(try XCTUnwrap(destination.y), 70)
            }
        }
        let single = try fixture("FIRST<br/>SECOND", in: directory.url)
        try layout(single, preserve: true)
        let authored = try gap(single)
        try layout(single)
        XCTAssertEqual(try gap(single), authored, accuracy: 0.05)
    }

    func testPreformattedPoetryCodeAndTableCellsKeepTheirBlankRows() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for body in [
            "<pre>FIRST\n\nSECOND</pre>",
            "<div style='white-space:pre-wrap'>FIRST\n\nSECOND</div>",
            "<div style='white-space:pre-line'>FIRST\n\nSECOND</div>",
            "<code>FIRST<br/><br/>SECOND</code>",
            "<table><tr><td>FIRST<br/><br/>SECOND</td></tr></table>"
        ] {
            let file = try fixture(body, in: directory.url)
            try layout(file, preserve: true)
            let authored = try gap(file)
            try layout(file)
            XCTAssertEqual(try gap(file), authored, accuracy: 0.05, body)
            XCTAssertGreaterThan(authored, 40, body)
        }
    }

    func testEmptyProseParagraphsCompactWhileNormalParagraphMarginsStayAuthored() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let first = "<p style='margin:23px 0'>FIRST</p>", second = "<p style='margin:23px 0'>SECOND</p>"
        let reference = try fixture(first + second, in: directory.url)
        try layout(reference)
        let normalGap = try gap(reference)
        try layout(reference, preserve: true)
        XCTAssertEqual(try gap(reference), normalGap, accuracy: 0.05)
        let blank = "<p style='margin:71px 0'>&#160;</p><p style='margin:71px 0'></p><p style='margin:71px 0' id='gap'><span>　<a id='inner'></a>&#160;</span></p>"
        let file = try fixture(first + String(repeating: blank, count: 3) + second, in: directory.url)
        for height in [CGFloat(0), 300] {
            try layout(file, preserve: true, height: height)
            let before = try (0..<file.count).flatMap { try file.words($0) }.filter { !$0.text.allSatisfy(\.isWhitespace) }
            try layout(file, height: height)
            XCTAssertEqual(file.count, 1)
            XCTAssertEqual(try gap(file), normalGap, accuracy: 0.05)
            let after = try file.words(0).filter { !$0.text.allSatisfy(\.isWhitespace) }
            XCTAssertEqual(after.map(\.text), before.map(\.text))
            XCTAssertEqual(after.map(\.source), before.map(\.source))
            for uri in ["#gap", "#inner"] {
                let destination = try XCTUnwrap(file.resolve(uri))
                XCTAssertEqual(destination.page, 0)
                XCTAssertGreaterThan(try XCTUnwrap(destination.y), 0)
                XCTAssertLessThan(try XCTUnwrap(destination.y), 100)
            }
        }
    }

    func testEmptyParagraphAuthoredPageBreakKeepsItsGeometry() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try fixture("<p>FIRST</p><p id='turn' style='margin:21px 0;page-break-after:always'>&#160;</p><p>SECOND</p>", in: directory.url)
        try layout(file, preserve: true, height: 300)
        let before = try (0..<file.count).map { try file.words($0).map(\.rect) }
        let authoredDestination = try XCTUnwrap(file.resolve("#turn"))
        XCTAssertEqual(file.count, 2)
        try layout(file, height: 300)
        XCTAssertEqual(try (0..<file.count).map { try file.words($0).map(\.rect) }, before)
        let destination = try XCTUnwrap(file.resolve("#turn"))
        XCTAssertEqual(destination.page, authoredDestination.page)
        XCTAssertEqual(destination.y, authoredDestination.y)
        XCTAssertEqual(try file.matches("SECOND", page: 1).count, 1)
    }

    func testImageOnlyBlocksAndAuthoredPageBreaksRemainIntact() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let image = NSImage(size: CGSize(width: 24, height: 24))
        image.lockFocus(); NSColor.red.setFill(); CGRect(x: 0, y: 0, width: 24, height: 24).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let imageURL = directory.url.appendingPathComponent("square.png")
        try data.write(to: imageURL)
        let file = try fixture("<p><img src='square.png'/><br/><br/><img src='square.png'/></p><p style='page-break-after:always'>FIRST</p><p>SECOND</p>", in: directory.url)
        try layout(file, preserve: true, height: 300)
        let images = try file.imageBounds(0)
        XCTAssertEqual(images.count, 2)
        XCTAssertGreaterThan(images[1].minY - images[0].minY, 24)
        let count = file.count
        try layout(file, height: 300)
        XCTAssertEqual(try file.imageBounds(0), images)
        XCTAssertEqual(file.count, count)
        XCTAssertEqual(try file.matches("FIRST", page: 0).count, 1)
        XCTAssertTrue(try file.matches("SECOND", page: 0).isEmpty)
        XCTAssertEqual(try file.matches("SECOND", page: 1).count, 1)
    }

    func testSearchSelectionAndPassageSurviveSpacingAndResize() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let phrase = "SECOND source passage stays intact through reader resizing."
        let body = (0..<30).map { "FIRST \($0)<br></br>　<a id='gap\($0)'></a><br></br>\(phrase)<br/>" }.joined()
        let file = try fixture(body, in: directory.url)
        try layout(file, preserve: true)
        let words = try file.words(0)
        let glyph = try XCTUnwrap(words.first { $0.text == "S" && $0.bounds.minY > 300 })
        let source = try XCTUnwrap(glyph.source)
        let bookmark = try XCTUnwrap(file.passage(0, at: CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)))
        let text = try XCTUnwrap(file.text(0)) as NSString
        let selection = try file.selection(0, range: text.range(of: phrase))
        let start = try XCTUnwrap(selection.sourceStart), end = try XCTUnwrap(selection.sourceEnd)
        let expected = selection.text.filter { !$0.isWhitespace }
        for width in [CGFloat(640), 260, 900] {
            try layout(file, width: width)
            XCTAssertEqual(try file.matches(phrase, page: 0).count, 30)
            let restored = try XCTUnwrap(file.position(for: bookmark.source))
            let point = CGPoint(x: try XCTUnwrap(restored.x), y: try XCTUnwrap(restored.y))
            XCTAssertEqual(try file.passage(restored.page, at: point)?.source, bookmark.source)
            XCTAssertNotNil(try file.position(for: source))
            XCTAssertEqual(try file.selection(0, from: start, to: end).text.filter { !$0.isWhitespace }, expected)
        }
    }
}
#endif
