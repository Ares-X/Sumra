#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeGeneratedMarkdownLayoutTests: XCTestCase {
    func testGeneratedTablesFootnotesAndEscapedCodeKeepTextAndLinks() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Generated.md")
        let markdown = """
        # Generated content

        | Label | Value |
        |:------|------:|
        | left | **right** |

        A [link](https://example.com/?a=1&b=2 "literal data-footnote-backref data and data-footnote-ref> and data-footnotes>") has a title.

        ```swift
        let text = "<html>&amp;"
        ```

        A footnote[^1] remains reachable.

        [^1]: Footnote answer with **bold** text.
        """
        try markdown.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 18, lineHeight: 1.5, font: "system", theme: "light",
                              pageSize: CGSize(width: 804, height: 0))
        let text = try XCTUnwrap(file.text(0))
        XCTAssertTrue(text.contains("left right"))
        XCTAssertTrue(text.contains("let text = \"<html>&\""))
        XCTAssertTrue(text.contains("Footnote answer with bold text."))
        XCTAssertEqual(try file.matches("Footnote answer", page: 0).count, 1)
        XCTAssertTrue(try file.links(0).contains { $0.uri.hasPrefix("https://example.com/?a=1&b=2") })
        XCTAssertNotNil(try file.image(0, width: 804))
    }

    func testRawHTMLSpanningMarkdownParagraphsKeepsFollowingContent() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Raw.md")
        let markdown = """
        # Raw span boundary

        Before <i>Italic begins

        and continues after the paragraph</i> without losing the ending.

        <table><tr><td>raw cell</td></tr></table>

        Final text stays visible.
        """
        try markdown.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 18, lineHeight: 1.5, font: "system", theme: "light",
                              pageSize: CGSize(width: 804, height: 0))
        let text = try XCTUnwrap(file.text(0))
        XCTAssertTrue(text.contains("Italic begins"))
        XCTAssertTrue(text.contains("continues after the paragraph"))
        XCTAssertTrue(text.contains("raw cell"))
        XCTAssertTrue(text.contains("Final text stays visible."))
        XCTAssertEqual(try file.matches("Final text stays visible", page: 0).count, 1)
        XCTAssertNotNil(try file.image(0, width: 804))
    }
}
#endif
