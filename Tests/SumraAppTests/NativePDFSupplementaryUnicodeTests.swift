#if os(macOS)
import CoreGraphics
import Foundation
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFSupplementaryUnicodeTests: XCTestCase {
    func testSupplementaryCMapsAndRichFreeTextSurviveSubsetAndReopen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let native = root.appendingPathComponent("build/engines")
        let core = root.appendingPathComponent("build/mupdf/libmupdf.a")
        let third = root.appendingPathComponent("build/mupdf/libmupdf-third.a")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let crypto = root.appendingPathComponent("build/native-macos13/openssl-3.5.9-\(architecture)/libcrypto.a")
        let objects = ["MuPDF", "Markdown", "PDFTools", "PDFInfo", "PDFColors", "SyncTeXParser", "SyncTeXUtils", "SyncTeX"]
            .map { native.appendingPathComponent($0 + ".o") }
        guard (objects + [core, third, crypto]).allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Build native engine objects and archives before PDF supplementary Unicode tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let object = directory.url.appendingPathComponent("supplementary.o")
        let executable = directory.url.appendingPathComponent("supplementary")
        let commands = [
            ["clang", "-std=c11", "-O1", "-mmacosx-version-min=13.0",
             "-I" + root.appendingPathComponent("build/deps/mupdf/include").path,
             "-I" + root.appendingPathComponent("build/deps/mupdf/thirdparty/freetype/include").path,
             "-c", root.appendingPathComponent("Tests/Native/PDFSupplementaryUnicode.c").path, "-o", object.path],
            ["clang++", "-mmacosx-version-min=13.0", "-Wl,-dead_strip", object.path] + objects.map(\.path) +
                [core.path, third.path, crypto.path, "-lm", "-lpthread", "-lz",
                 "-framework", "Security", "-framework", "CoreFoundation", "-framework", "CoreText", "-o", executable.path]
        ]
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            try runSumraProcess(process)
            XCTAssertEqual(process.terminationStatus, 0)
            guard process.terminationStatus == 0 else { return }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [directory.url.path]
        try runSumraProcess(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0,
                       "UTF-16 mappings and real rich Emoji must survive saving, reopening and font subsetting")
        guard process.terminationStatus == 0 else { return }

        let boundary = "AB\u{FFFE}\u{FFFF}\u{10000}\u{10001}\u{103FE}\u{103FF}\u{10400}\u{10402}😀"
        for name in ["boundary", "emoji"] {
            for kind in ["full", "subset"] {
                let url = directory.url.appendingPathComponent("\(name)-\(kind).pdf")
                let pdf = try XCTUnwrap(PDFDocument(url: url))
                let pageIndex = name == "emoji" ? 1 : 0
                let text = try XCTUnwrap(pdf.page(at: pageIndex)?.string)
                XCTAssertTrue(text.contains(name == "emoji" ? "Latin 😀" : boundary),
                              "Platform text extraction must preserve every supplementary scalar")
                let cgPDF = try XCTUnwrap(CGPDFDocument(url as CFURL))
                let cgPage = try XCTUnwrap(cgPDF.page(at: pageIndex + 1))
                let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 150,
                    bitsPerComponent: 8, bytesPerRow: 2000, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 500, height: 150))
                context.drawPDFPage(cgPage)
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let ink = (0..<(500 * 150)).filter {
                    pixels[$0 * 4] < 128 && pixels[$0 * 4 + 1] < 128 && pixels[$0 * 4 + 2] < 128
                }.count
                XCTAssertGreaterThan(ink, 10, "Saved embedded glyphs must also render through CoreGraphics")
            }
        }
        // Rare Han is reported separately as OPEN by the native diagnostic;
        // this test does not claim installed-font or bundled U+20000 coverage.
    }
}
#endif
