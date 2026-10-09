import Foundation
import XCTest
@testable import SumraCore

final class ProductRegressionTests: XCTestCase {
    func testChapterLineNumbersAcrossLineEndings() {
        let text = "第一章 起点\n\n正文。\n\n第二章 终点\n"
        let expected = ChapterDetector.detect(text)
        XCTAssertEqual(expected.map(\.line), [0, 4])
        for newline in ["\r\n", "\r"] {
            XCTAssertEqual(ChapterDetector.detect(text.replacingOccurrences(of: "\n", with: newline)), expected)
        }
    }

    func testBOMDoesNotHideFirstChapter() {
        let text = "第一章 起点\n\n正文。\n\n第二章 终点\n"
        XCTAssertEqual(ChapterDetector.detect("\u{feff}" + text), ChapterDetector.detect(text))
    }

    func testImageMagicAgreesAcrossFormatAndDecoderRouting() {
        let signatures: [(bytes: [UInt8], format: Format, engine: String?)] = [
            ([0xff, 0x0a], .image, "JPEGXL"),
            ([0, 0, 0, 12, 0x4a, 0x58, 0x4c, 0x20, 13, 10, 0x87, 10], .image, "JPEGXL"),
            ([0x49, 0x49, 0xbc, 0], .mupdf, "MuPDF"),
            ([0x49, 0x49, 0xbc, 1], .mupdf, "MuPDF"),
            ([0x89, 0x50, 0x4e, 0x47, 13, 10, 0x1a, 10], .image, nil),
            ([0xff, 0xd8], .image, nil)
        ]
        for signature in signatures {
            var bytes = Data(repeating: 0xaa, count: 32)
            bytes.append(contentsOf: signature.bytes)
            let slice = bytes.dropFirst(32)
            XCTAssertEqual(slice.startIndex, 32)
            for prefix in [Data(signature.bytes), slice] {
                XCTAssertEqual(Format.sniff(prefix), signature.format)
                for name in ["image.bin", "image.png", "image.jxl", "image.jxr"] {
                    XCTAssertEqual(Format.resolve(name, prefix: prefix), signature.format)
                    XCTAssertEqual(Format.imageEngine(name, prefix: prefix), signature.engine)
                }
            }
        }
    }

    func testJPEGXRRequiresItsFourthSignatureByteBeforeOverridingTheExtension() {
        let unrecognized: [[UInt8]] = [[0x49], [0x49, 0x49], [0x49, 0x49, 0xbc], [0x49, 0x49, 0xbc, 5], [0x49, 0x49, 0xbc, 0xff]]
        for bytes in unrecognized {
            let prefix = Data(bytes)
            XCTAssertNil(Format.sniff(prefix))
            XCTAssertNil(Format.imageEngine("image.bin", prefix: prefix))
            XCTAssertEqual(Format.resolve("image.png", prefix: prefix), .image)
            XCTAssertNil(Format.imageEngine("image.png", prefix: prefix))
            XCTAssertEqual(Format.imageEngine("image.jxr", prefix: prefix), "MuPDF")
        }
        // Extension-only routing remains available before enough bytes arrive.
        XCTAssertEqual(Format.imageEngine("image.jxr"), "MuPDF")
        XCTAssertEqual(Format.imageEngine("image.jxl"), "JPEGXL")
    }

    func testLineOffsetsUseUTF16AndAllSupportedNewlines() {
        for newline in ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "😀" + newline + "第二行" + newline
            let n = newline.utf16.count
            XCTAssertEqual(ChapterDetector.lineOffsets(text), [0, 2 + n, 5 + 2 * n], "newline: \(Array(newline.utf16))")
        }
    }

    func testControlWhitespaceDoesNotCreatePhantomLine() {
        for control in ["\u{000b}", "\u{000c}"] {
            let text = "正文" + control + "第一章 标题\n\n正文\n\n第二章 标题\n"
            XCTAssertEqual(ChapterDetector.detect(text).map(\.line), [4])
            XCTAssertEqual(ChapterDetector.lineOffsets("a" + control + "b" + control), [0])
        }
    }

    func testEmptyAndTerminalLines() {
        XCTAssertEqual(ChapterDetector.lineOffsets(""), [0])
        XCTAssertEqual(ChapterDetector.lineOffsets("正文"), [0])
        XCTAssertEqual(ChapterDetector.lineOffsets("\r\n"), [0, 2])
        XCTAssertEqual(ChapterDetector.lineOffsets("\n\n"), [0, 1, 2])
    }

}
