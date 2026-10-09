#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeMarkdownHeadingTests: XCTestCase {
    func testAuthoredUnicodeFragmentsResolveToHeadingTextAndSourceAcrossLevels() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let cases = [
            ("Halo 世界", "Halo 世界", "halo-世界"),
            ("Rocket 😀 End", "Rocket 😀 End", "rocket-😀-end"),
            ("ASCII -- Slug", "ASCII -- Slug", "ascii-slug"),
            ("Café", "Café", "cafa"),
            ("Inline **世界**", "Inline 世界", "inline-世界"),
            ("Code `𠮷` End", "Code 𠮷 End", "code-𠮷-end")
        ]
        for (offset, fixture) in cases.enumerated() {
            let (heading, title, slug) = fixture
            let input = temporary.url.appendingPathComponent("Heading\(offset + 1).md")
            let original = Data(("[Jump to destination](#\(slug))\n\n"
                + String(repeating: "Filler text before the destination.\n\n", count: 35)
                + String(repeating: "#", count: offset + 1) + " " + heading
                + "\n\nTerminal marker HEADINGEND\(offset).\n").utf8)
            try original.write(to: input)
            let document = try NativeFile(input, engine: .mupdf)
            _ = try document.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light")
            let link = try XCTUnwrap(document.links(0).first { $0.uri == "#" + slug }, title)
            XCTAssertFalse(link.bounds.isEmpty)
            // Resolve the authored link before outline() populates its destination cache.
            let destination = try XCTUnwrap(document.resolve(link.uri), title)
            XCTAssertGreaterThan(destination.page, 0, title)
            let destinationText = try XCTUnwrap(document.text(destination.page))
            XCTAssertTrue(destinationText.contains(title), title)
            let outline = try XCTUnwrap(document.outline().first { $0.title == title }, title)
            XCTAssertEqual(outline.target, link.uri, title)
            XCTAssertEqual(outline.page, destination.page, title)
            let hit = try XCTUnwrap(document.markdownDocumentMatches(title, options: .init(), startPage: 0).first, title)
            XCTAssertNotNil(hit.source, title)
            XCTAssertEqual(hit.fragments?.first?.page, destination.page, title)
            XCTAssertFalse(try XCTUnwrap(hit.fragments?.first).rects.isEmpty, title)
            let html = try XCTUnwrap(document.htmlSource())
            XCTAssertTrue(html.contains("<h\(offset + 1) id=\"\(slug)\">"), title)
            XCTAssertTrue(html.contains("HEADINGEND\(offset)"), "A supplementary scalar must not terminate the generated document")
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testTwoByteScalarDoesNotConsumeTheFollowingSlugCharacter() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Accents.md")
        // Keep cMark's existing accent folding (including its é -> a rule).
        try "[Jump](#cafax-noir)\n\n# CaféX Noir\n".write(to: input, atomically: true, encoding: .utf8)
        let document = try NativeFile(input, engine: .mupdf)
        let link = try XCTUnwrap(document.links(0).first)
        XCTAssertEqual(link.uri, "#cafax-noir")
        XCTAssertNotNil(try document.resolve(link.uri))
        XCTAssertEqual(try document.outline().first?.target, link.uri)
    }

    func testEmptyGeneratedSlugAndAuthoredAnchorRemainAvailable() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Empty.md")
        try "[Jump](#manual)\n\n# !!!\n\n<a id=\"manual\"></a>\n\nAuthored destination.\n"
            .write(to: input, atomically: true, encoding: .utf8)
        let document = try NativeFile(input, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(document.htmlSource()).contains("<h1 id=\"\">!!!</h1>"))
        let link = try XCTUnwrap(document.links(0).first { $0.uri == "#manual" })
        let destination = try XCTUnwrap(document.resolve(link.uri))
        XCTAssertTrue(try XCTUnwrap(document.text(destination.page)).contains("Authored destination."))
    }
}
#endif
