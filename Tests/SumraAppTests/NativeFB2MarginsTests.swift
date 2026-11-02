#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeFB2MarginsTests: XCTestCase {
    func testReaderMarginsReplaceFictionBookInsetsAndRetainAuthoredContent() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("margins.fb2")
        try """
        <FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0'>
        <stylesheet type='text/css'>
        FictionBook{margin:31pt;padding:13pt;width:220pt;max-width:220pt}
        section{margin:0}p{margin:0;text-indent:0}cite{margin:0 0 0 23pt}
        </stylesheet><body><section><p>ANCHOR</p><cite><p>QUOTE</p></cite>
        <p>\(String(repeating: "Wrapping words use the available reading width. ", count: 12))</p>
        </section></body></FictionBook>
        """.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        func layout(_ margins: PageMargins?, height: CGFloat = 0, fontSize: Double = 17, css: String = "") throws -> CGRect {
            _ = try file.relayout(fontSize: fontSize, lineHeight: 1.6, font: "serif", theme: "light",
                userCSS: css, pageMargins: margins, pageSize: CGSize(width: 640, height: height))
            return try XCTUnwrap(file.matches("ANCHOR", page: 0).first?.rects.first)
        }
        let publisher = try layout(nil)
        let choices = try [[8.0], [16.0], [24.0], [9.0, 19.0, 29.0, 39.0]].map {
            try XCTUnwrap(PageMargins(cssValues: $0))
        }
        for height in [CGFloat(0), 480] {
            for size in [17.0, 23.0] {
                for margins in choices {
                    let anchor = try layout(margins, height: height, fontSize: size)
                    XCTAssertEqual(anchor.minX, margins.left, accuracy: 1,
                                   "FB2 must use the selected margin without another root inset")
                    let quote = try XCTUnwrap(file.matches("QUOTE", page: 0).first?.rects.first)
                    XCTAssertEqual(quote.minX - anchor.minX, 23, accuracy: 0.1,
                                   "Authored content indentation remains inside the reader margins")
                    XCTAssertGreaterThan(try file.words(0).map(\.bounds.maxX).max() ?? 0, 500,
                                         "FictionBook width locks must not constrain reader reflow")
                }
            }
        }
        let custom = try layout(PageMargins(cssValues: [16]), css: "FictionBook{margin-left:19pt!important}")
        XCTAssertEqual(custom.minX, 35, accuracy: 1, "Explicit user CSS remains authoritative")
        XCTAssertEqual(try layout(nil).minX, publisher.minX, accuracy: 0.1,
                       "Clearing reader margins restores publisher root spacing")
    }

    func testOriginalFormatSamplerFB2UsesPresetWithoutDefaultEmInset() throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_FORMAT_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("Set SUMRA_FORMAT_SAMPLE_DIRECTORY to the original format sampler")
        }
        let input = URL(fileURLWithPath: path).appendingPathComponent("sample_illustrated.fb2")
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        for height in [CGFloat(0), 480] {
            for margin in [8.0, 16.0, 24.0] {
                _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "serif", theme: "light",
                    pageMargins: PageMargins(cssValues: [margin]), pageSize: CGSize(width: 640, height: height))
                let firstParagraph = try XCTUnwrap((0..<file.count).lazy.compactMap {
                    try file.matches("Lorem ipsum", page: $0).first?.rects.first
                }.first)
                XCTAssertEqual(firstParagraph.minX, margin, accuracy: 1,
                               "The original FB2 has no authored stylesheet or paragraph indent here")
            }
        }
    }
}
#endif
