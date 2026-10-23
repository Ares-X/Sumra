#if os(macOS)
import AppKit
import CoreText
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFSourceWordTests: XCTestCase {
    func testExportedJapanesePhraseSearchKeepsPhysicalLineHighlights() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let phrase = "読書で世界を知る。ひらがな、カタカナ、漢字。"
        let source = directory.url.appendingPathComponent("japanese.html")
        try "<html lang='ja'><meta charset='utf-8'><body><p>\(phrase)</p></body></html>"
            .write(to: source, atomically: true, encoding: .utf8)
        for width in [260.0, 360.0] {
            let file = try NativeFile(source, engine: .mupdf)
            _ = try file.relayout(fontSize: 22, lineHeight: 1.6, font: "system", theme: "light",
                                  pageSize: CGSize(width: width, height: 500))
            let output = directory.url.appendingPathComponent("japanese-\(width).pdf")
            XCTAssertTrue(try file.exportPDF(to: output))
            let pdf = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(pdf.count, 1)
            let text = try XCTUnwrap(pdf.text(0))
            XCTAssertGreaterThan(text.split(separator: "\n").count, 1, "Exercise a physical line wrap")
            XCTAssertEqual(text.filter { !$0.isWhitespace }, phrase)
            let hit = try XCTUnwrap(pdf.matches(phrase, page: 0).first)
            XCTAssertEqual(try pdf.matches(phrase, page: 0).count, 1)
            XCTAssertEqual(try pdf.matches(phrase, page: 0, backwards: true).first, hit)
            XCTAssertGreaterThan(hit.rects.reduce(CGRect.null) { $0.union($1) }.height, 22,
                                 "The phrase highlight must cover both physical lines")
        }
    }

    func testShapedWordsKeepCopyAndSearchAfterExport() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let samples = [
            ("ur", "کتاب پڑھنا علم میں اضافہ کرتا ہے۔"),
            ("bn", "পড়া আমাদের নতুন জগৎ চিনতে সাহায্য করে।"),
            ("gu", "વાંચન આપણને દુનિયા સમજવામાં મદદ કરે છે."),
            ("or", "ପଢ଼ିବା ଆମକୁ ଜଗତ ବୁଝିବାରେ ସାହାଯ୍ୟ କରେ।"),
            ("ta", "வாசிப்பு உலகத்தைப் புரிந்துகொள்ள உதவுகிறது."),
            ("kn", "ಓದುವುದು ಜಗತ್ತನ್ನು ಅರ್ಥಮಾಡಿಕೊಳ್ಳಲು ಸಹಾಯ ಮಾಡುತ್ತದೆ."),
            ("ml", "വായന ലോകത്തെ മനസ്സിലാക്കാൻ സഹായിക്കുന്നു."),
            ("si", "කියවීම ලෝකය තේරුම් ගැනීමට උපකාරී වේ."),
            ("my", "စာဖတ်ခြင်းက ကမ္ဘာကို နားလည်စေသည်။"),
            ("km", "ការអានជួយឱ្យយើងយល់ពីពិភពលោក។")
        ]
        for (language, phrase) in samples {
            for width in [320.0, 600.0] {
                let source = directory.url.appendingPathComponent("\(language)-\(width).html")
                let direction = language == "ur" ? "rtl" : "ltr"
                try "<html lang='\(language)'><meta charset='utf-8'><body dir='\(direction)'><p>\(phrase)</p><p>\(phrase)</p></body></html>"
                    .write(to: source, atomically: true, encoding: .utf8)
                let file = try NativeFile(source, engine: .mupdf)
                _ = try file.relayout(fontSize: 22, lineHeight: 1.6, font: "system", theme: "light",
                                      pageSize: CGSize(width: width, height: 800))
                let output = source.deletingPathExtension().appendingPathExtension("pdf")
                XCTAssertTrue(try file.exportPDF(to: output))
                let pdf = try NativeFile(output, engine: .mupdf)
                let text = try (0..<pdf.count).map { try pdf.text($0) ?? "" }.joined(separator: " ")
                XCTAssertEqual(words(text), words(phrase + " " + phrase), "\(language) \(width): no inferred separators inside shaped words")
                for word in phrase.split(whereSeparator: \.isWhitespace).map(String.init) {
                    let hits = try (0..<pdf.count).flatMap { try pdf.matches(word, page: $0) }
                    XCTAssertEqual(hits.count, 2, "\(language) \(width): \(word)")
                    XCTAssertTrue(hits.allSatisfy { !$0.rects.isEmpty && $0.rects.allSatisfy { !$0.isEmpty && !$0.isInfinite && !$0.isNull } })
                }
                XCTAssertEqual(try (0..<pdf.count).flatMap { try pdf.matches(phrase, page: $0) }.count, 2,
                               "Adjacent words and genuine wrapping must retain phrase search")
            }
        }
    }

    func testOutlinedUrduContinuationIsInsideSearchHighlight() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("word.html")
        let phrase = "کتاب"
        try "<html lang='ur'><meta charset='utf-8'><body dir='rtl'><p>\(phrase)</p></body></html>"
            .write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        _ = try file.relayout(fontSize: 30, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 300, height: 400))
        let output = source.deletingPathExtension().appendingPathExtension("pdf")
        XCTAssertTrue(try file.exportPDF(to: output))
        let pdf = try NativeFile(output, engine: .mupdf)
        let hit = try XCTUnwrap(pdf.matches(phrase, page: 0).first)
        let highlight = hit.rects.reduce(CGRect.null) { $0.union($1) }
        let image = try pdf.image(0, width: 1200)
        let bounds = try XCTUnwrap(pdf.bounds(0)), scale = CGFloat(image.width) / bounds.width
        let ink = inkBounds(image)
        XCTAssertFalse(ink.isNull)
        let painted = CGRect(x: ink.minX / scale, y: ink.minY / scale, width: ink.width / scale, height: ink.height / scale)
        XCTAssertTrue(highlight.insetBy(dx: -1, dy: -1).contains(painted), "\(highlight) must enclose painted word \(painted), including continuation outlines")
        XCTAssertLessThan(highlight.width, bounds.width / 2, "A word highlight must not expand to the page")
        let independent = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let page = try XCTUnwrap(independent.page(at: 1))
        XCTAssertEqual(try actualTextWords(page), [phrase], "An independent PDF parser must read the exact logical replacement text")
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.scaleBy(x: scale, y: scale); context.drawPDFPage(page)
        let systemInk = inkBounds(try XCTUnwrap(context.makeImage()))
        for (a, b) in [(ink.minX, systemInk.minX), (ink.maxX, systemInk.maxX),
                       (ink.minY, systemInk.minY), (ink.maxY, systemInk.maxY)] {
            XCTAssertEqual(a, b, accuracy: 2, "Independent rendering must retain the painted word geometry")
        }
    }

    func testInlineFontChangesAndRealWordBoundariesSurviveExport() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("mixed.html")
        let expected = "office affinity Café cafe\u{301} العربية עברית हिन्दी ไทย 😀 alpha beta"
        try "<html><meta charset='utf-8'><body><p>office af<span style='color:blue'>fi</span>nity Café cafe\u{301} العربية עברית हिन्दी ไทย 😀 alpha beta</p></body></html>"
            .write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        _ = try file.relayout(fontSize: 22, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 260, height: 800))
        let output = source.deletingPathExtension().appendingPathExtension("pdf")
        XCTAssertTrue(try file.exportPDF(to: output))
        let pdf = try NativeFile(output, engine: .mupdf)
        let text = try (0..<pdf.count).map { try pdf.text($0) ?? "" }.joined(separator: " ")
        XCTAssertEqual(words(text), words(expected))
        XCTAssertEqual(try pdf.matches("affinity", page: 0).count, 1)
        XCTAssertEqual(try pdf.matches("alpha beta", page: 0).count, 1)
        XCTAssertTrue(try pdf.matches("alphabeta", page: 0).isEmpty)

        let plain = directory.url.appendingPathComponent("geometric.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 120)
        let context = try XCTUnwrap(CGContext(plain as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for (text, x) in [("alpha", 20.0), ("beta", 75.0)] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.init(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: x, y: 70); CTLineDraw(line, context)
        }
        context.endPDFPage(); context.closePDF()
        let ordinary = try NativeFile(plain, engine: .mupdf)
        XCTAssertEqual(try ordinary.matches("alpha beta", page: 0).count, 1, "PDFs without authored metadata still need geometric space inference")
        XCTAssertTrue(try ordinary.matches("alphabeta", page: 0).isEmpty)
    }

    func testAATDeletedGlyphRetainsTextWithoutMovingThePDFOutline() throws {
        let selected = CTFontCreateWithNameAndOptions("OriyaMN" as CFString, 12, nil,
            [.preventAutoActivation, .preventAutoDownload])
        guard CTFontCopyPostScriptName(selected) as String == "OriyaMN" else {
            throw XCTSkip("This host does not have Oriya MN's AAT font")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("odia.html"), phrase = "ସାହାଯ୍ୟ"
        try "<html lang='or'><meta charset='utf-8'><body><p>\(phrase)</p></body></html>"
            .write(to: source, atomically: true, encoding: .utf8)
        let file = try NativeFile(source, engine: .mupdf)
        _ = try file.relayout(fontSize: 40, lineHeight: 1.6, font: "system", theme: "light",
                              pageSize: CGSize(width: 500, height: 400))
        let reading = inkBounds(try file.image(0, width: 1000))
        let output = source.deletingPathExtension().appendingPathExtension("pdf")
        XCTAssertTrue(try file.exportPDF(to: output))
        let pdf = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(words(try pdf.text(0) ?? ""), [phrase])
        XCTAssertEqual(try pdf.matches(phrase, page: 0).count, 1)
        let saved = inkBounds(try pdf.image(0, width: 1000))
        XCTAssertFalse(reading.isNull)
        for (a, b) in [(reading.minX, saved.minX), (reading.maxX, saved.maxX),
                       (reading.minY, saved.minY), (reading.maxY, saved.maxY)] {
            XCTAssertEqual(a, b, accuracy: 1, "Deleted AAT glyphs must not add a PDF font advance")
        }
    }

    private func inkBounds(_ image: CGImage) -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var ink = CGRect.null
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.5 {
                ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        } }
        return ink
    }

    private func actualTextWords(_ page: CGPDFPage) throws -> [String] {
        let table = try XCTUnwrap(CGPDFOperatorTableCreate())
        CGPDFOperatorTableSetCallback(table, "BDC") { scanner, info in
            guard let info else { return }
            var dictionary: CGPDFDictionaryRef?, tag: UnsafePointer<CChar>?
            guard CGPDFScannerPopDictionary(scanner, &dictionary), let dictionary,
                  CGPDFScannerPopName(scanner, &tag) else { return }
            var value: CGPDFStringRef?
            if CGPDFDictionaryGetString(dictionary, "ActualText", &value), let value,
               let string = CGPDFStringCopyTextString(value) {
                info.assumingMemoryBound(to: [String].self).pointee.append(string as String)
            }
        }
        var result = [String]()
        let stream = try XCTUnwrap(CGPDFContentStreamCreateWithPage(page))
        try withUnsafeMutablePointer(to: &result) { pointer in
            let scanner = try XCTUnwrap(CGPDFScannerCreate(stream, table, pointer))
            XCTAssertTrue(CGPDFScannerScan(scanner))
        }
        return result
    }

    private func words(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
#endif
