#if os(macOS)
import AppKit
import CoreText
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativeReaderFontTests: XCTestCase {
    func testInstalledVariableWeightSurvivesReadingAndPDFExport() throws {
        let selected = CTFontCreateWithNameAndOptions("KefaIII-Bold" as CFString, 12, nil,
            [.preventAutoActivation, .preventAutoDownload])
        guard CTFontCopyPostScriptName(selected) as String == "KefaIII-Bold",
              let variations = CTFontCopyVariation(selected), CFDictionaryGetCount(variations) > 0 else {
            throw XCTSkip("This host does not have the variable Kefa III font")
        }
        let family = CTFontCopyFamilyName(selected) as String
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let phrase = "ሀለሐመሠረሰ"
        func ink(_ image: CGImage) -> Int {
            let bitmap = NSBitmapImageRep(cgImage: image)
            var count = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.5 { count += 1 }
            } }
            return count
        }
        var painted = [Int](), systemPainted = [Int]()
        for bold in [false, true] {
            let input = temporary.url.appendingPathComponent(bold ? "bold.html" : "regular.html")
            let body = bold ? "<strong>\(phrase)</strong>" : phrase
            try "<html lang='am'><meta charset='utf-8'><body style=\"font-family:'\(family)'\"><p>\(body)</p></body></html>"
                .write(to: input, atomically: true, encoding: .utf8)
            let file = try NativeFile(input, engine: .mupdf)
            _ = try file.relayout(fontSize: 28, lineHeight: 1.4, font: "system", theme: "light")
            let readingInk = ink(try file.image(0, width: 840))
            painted.append(readingInk)
            let output = input.deletingPathExtension().appendingPathExtension("pdf")
            XCTAssertTrue(try file.exportPDF(to: output))
            let reopened = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(try XCTUnwrap(reopened.text(0)).filter { !$0.isWhitespace }, phrase)
            XCTAssertEqual(Double(ink(try reopened.image(0, width: 840))), Double(readingInk), accuracy: Double(readingInk) * 0.05,
                           "Saved static outlines must retain the selected variable weight")
            let systemPDF = try XCTUnwrap(CGPDFDocument(output as CFURL))
            let page = try XCTUnwrap(systemPDF.page(at: 1)), box = page.getBoxRect(.mediaBox)
            let scale = 840 / box.width, height = Int(ceil(box.height * scale))
            let context = try XCTUnwrap(CGContext(data: nil, width: 840, height: height, bitsPerComponent: 8,
                bytesPerRow: 840 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 840, height: height))
            context.scaleBy(x: scale, y: scale); context.drawPDFPage(page)
            systemPainted.append(ink(try XCTUnwrap(context.makeImage())))
        }
        XCTAssertGreaterThan(painted[1], Int(Double(painted[0]) * 1.1), "Bold must paint the selected weight, not the default regular instance")
        XCTAssertGreaterThan(systemPainted[1], systemPainted[0], "An independent PDF renderer must retain the heavier selected instance")
        print("SUMRA_VARIABLE_FONT reading_ink=\(painted) coregraphics_ink=\(systemPainted)")
    }

    func testDefaultSerifHebrewUsesAnInstalledFontInReadingAndPDF() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("hebrew.html")
        let phrase = "קריאה פותחת אופקים חדשים"
        try "<html lang='he'><meta charset='utf-8'><body dir='rtl'><p>\(phrase)</p><p><b>\(phrase)</b></p><p><i>\(phrase)</i></p></body></html>"
            .write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        _ = try file.relayout(fontSize: 20, lineHeight: 1.4, font: "system", theme: "light")
        let output = directory.url.appendingPathComponent("hebrew.pdf")
        XCTAssertTrue(try file.exportPDF(to: output))
        let pdf = try NativeFile(output, engine: .mupdf)
        let base = CTFontCreateWithNameAndOptions("Times" as CFString, 12, nil,
            [.preventAutoActivation, .preventAutoDownload])
        let fallback = CTFontCreateForStringWithLanguage(base, "א" as CFString, CFRange(location: 0, length: 1), nil)
        let family = CTFontCopyFamilyName(fallback) as String
        let report = try pdf.pdfResourceReport()
        XCTAssertTrue(report.contains(family), "Default Hebrew text must use real installed glyphs, not Charis missing-glyph boxes: \(report)")
        let extracted = try (0..<pdf.count).map { try pdf.text($0) ?? "" }.joined()
        XCTAssertEqual(extracted.filter { !$0.isWhitespace }, String(repeating: phrase, count: 3).filter { !$0.isWhitespace })
        _ = try file.image(0, width: 840)
    }

    func testInstalledIowanFamilyIsUsedInReflowAndVectorExport() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("installed-font.html")
        try "<html><body><p>Iowan Old Style reading font, with italic <em>letters</em> and <strong>bold</strong>.</p></body></html>"
            .write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        _ = try file.relayout(fontSize: 20, lineHeight: 1.4, font: "Iowan Old Style", theme: "light")
        let export = directory.url.appendingPathComponent("iowan.pdf")
        XCTAssertTrue(try file.exportPDF(to: export))
        let pdf = try NativeFile(export, engine: .mupdf)
        let report = try pdf.pdfResourceReport()
        for face in ["Iowan Old Style Roman", "Iowan Old Style Italic", "Iowan Old Style Bold"] {
            XCTAssertTrue(report.contains(face), report)
        }
        XCTAssertTrue(try XCTUnwrap(pdf.text(0)).contains("Iowan Old Style reading font"))
    }

    func testCommonGlyphCoverageAndSystemFontLifetime() throws {
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
            throw XCTSkip("Build the native engine objects and archives before reader font tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let object = directory.url.appendingPathComponent("reader-fonts.o")
        let executable = directory.url.appendingPathComponent("reader-fonts")
        let commands = [
            ["clang", "-std=c11", "-O1", "-mmacosx-version-min=13.0",
             "-I" + root.appendingPathComponent("build/deps/mupdf/include").path,
             "-c", root.appendingPathComponent("Tests/Native/ReaderFonts.c").path, "-o", object.path],
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
        try runSumraProcess(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, "Real glyph coverage and font bytes must survive context teardown")
    }

    func testNonembeddedCIDSubstitutionSurvivesExportAndPrint() throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw XCTSkip("Build the MuPDF engine before reader font integration tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("nonembedded-cid.pdf")
        try nonembeddedCIDFixture().write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let expected = "中文"
        XCTAssertTrue(try XCTUnwrap(file.text(0)).contains(expected))
        let reference = try file.image(0, width: 320, transparent: true)
        let bitmap = NSBitmapImageRep(cgImage: reference)
        var ink = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               color.alphaComponent > 0.5 && color.redComponent < 0.5 { ink += 1 }
        } }
        XCTAssertGreaterThan(ink, 100, "Substituted CID glyphs must actually draw")
        for mode in ["export", "print"] {
            let output = directory.url.appendingPathComponent(mode + ".pdf")
            if mode == "export" { XCTAssertTrue(try file.exportPDF(to: output)) }
            else { _ = try file.printPDF(to: output) }
            let reopened = try NativeFile(output, engine: .mupdf)
            XCTAssertTrue(try XCTUnwrap(reopened.text(0)).contains(expected), mode)
            XCTAssertEqual(try reopened.image(0, width: 320, transparent: true).dataProvider?.data as Data?,
                           reference.dataProvider?.data as Data?, mode)
        }
    }

    private func nonembeddedCIDFixture() -> Data {
        let content = "BT /F1 30 Tf 30 70 Td <4E2D6587> Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 140] /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light /Encoding /UniGB-UTF16-H /DescendantFonts [5 0 R] >>",
            "<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 4 >> /FontDescriptor 6 0 R /DW 1000 >>",
            "<< /Type /FontDescriptor /FontName /STSong-Light /Flags 6 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(offsets.count) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
#endif
