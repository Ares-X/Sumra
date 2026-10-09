#if os(macOS)
import CoreGraphics
import Foundation
import XCTest
@testable import Sumra

final class NativeHTMLWidthTests: XCTestCase {
    func testRepeatedWordWidthsStayLocalToFontSizeCapsLanguageAndDirection() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let cases: [(style: String, language: String, text: String)] = [
            ("font-family:serif;font-size:12px", "en", "office office Z"),
            ("font-family:monospace;font-size:22px", "en", "office office Z"),
            ("font-family:serif;font-size:18px;font-variant:small-caps", "en", "office office Z"),
            ("font-family:serif;font-size:18px", "en", "office office Z"),
            ("font-family:serif;font-size:18px", "tr", "office office Z"),
            ("font-family:serif;font-size:18px;direction:rtl;unicode-bidi:embed", "he", "שלום שלום Z"),
            ("font-family:serif;font-size:18px", "en", "café office Z")
        ]

        func document(_ paragraphs: [(style: String, language: String, text: String)]) -> String {
            let body = paragraphs.map { item in
                "<p lang='\(item.language)' style='\(item.style)'>\(item.text)</p>"
            }.joined()
            return "<html><head><meta charset='utf-8'><style>body,p{margin:0;padding:0}</style></head><body>\(body)</body></html>"
        }
        func markerOffsets(_ file: NativeFile) throws -> [CGFloat] {
            var offsets: [CGFloat] = [], segment: [RasterWord] = []
            for page in 0..<file.count {
                for word in try file.words(page) {
                    if word.text == "Z" {
                        let first = try XCTUnwrap(segment.first {
                            !$0.bounds.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        })
                        offsets.append(word.bounds.minX - first.bounds.minX)
                        segment.removeAll()
                    } else {
                        segment.append(word)
                    }
                }
            }
            return offsets
        }

        let mixedURL = directory.url.appendingPathComponent("mixed.html")
        try document(cases).write(to: mixedURL, atomically: true, encoding: .utf8)
        let mixed = try NativeFile(mixedURL, engine: .mupdf)
        _ = try mixed.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light")
        let mixedOffsets = try markerOffsets(mixed)
        XCTAssertEqual(mixedOffsets.count, cases.count)
        guard mixedOffsets.count == cases.count else { return }

        for (index, item) in cases.enumerated() {
            let controlURL = directory.url.appendingPathComponent("control-\(index).html")
            try document([item]).write(to: controlURL, atomically: true, encoding: .utf8)
            let control = try NativeFile(controlURL, engine: .mupdf)
            _ = try control.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light")
            let controlOffsets = try markerOffsets(control)
            XCTAssertEqual(controlOffsets.count, 1)
            if let expected = controlOffsets.first {
                XCTAssertEqual(mixedOffsets[index], expected, accuracy: 0.05,
                               "Earlier paragraphs must not supply this style's word width")
            }
        }
    }

    func testFontChangeAndReturnRestoreWordGeometryAndRaster() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("reflow.html")
        let paragraphs = String(repeating: "<p>office affine official café שלום 世界 office affine Z</p>", count: 24)
        try ("<html><head><meta charset='utf-8'></head><body>\(paragraphs)</body></html>")
            .write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)

        func snapshot() throws -> (words: [String], rects: [[Double]], pixels: Data) {
            let words = try file.words(0)
            let image = try file.image(0, width: 720, transparent: true)
            return (words.map(\.text), words.map(\.rect), try XCTUnwrap(image.dataProvider?.data as Data?))
        }

        _ = try file.relayout(fontSize: 17, lineHeight: 1.3, font: "serif", theme: "light")
        let original = try snapshot()
        _ = try file.relayout(fontSize: 23, lineHeight: 1.3, font: "monospace", theme: "light")
        let changed = try snapshot()
        XCTAssertNotEqual(changed.rects, original.rects, "The intermediate layout must exercise different widths")
        _ = try file.relayout(fontSize: 17, lineHeight: 1.3, font: "serif", theme: "light")
        let restored = try snapshot()
        XCTAssertEqual(restored.words, original.words)
        XCTAssertEqual(restored.rects, original.rects)
        XCTAssertEqual(restored.pixels, original.pixels)
    }
}
#endif
