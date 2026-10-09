#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeMarkdownFindTests: XCTestCase {
    private let prefix = "# Small mode check\n\nOpening passage MODESTART796.\n\n## Middle search\n\nDistinctive middle passage MID796. "
    private let suffix = " 一二三田 ⼀⼆⼃⽥.\n\n## Terminal chapter\n\nUnique ending MODEEND796.\n"

    func testCJKFindUsesAuthoredTextAcrossVisualWrapWithRealGeometryAndCursors() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Visual-wrap.md")
        try (prefix + "普通汉字" + suffix).write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        for em in [11.0, 17.0] {
            XCTAssertNotNil(try file.relayout(fontSize: em, lineHeight: 1.6, font: "system", theme: "light"))
            let text = try XCTUnwrap(file.text(0)) as NSString
            let hits = try file.matches("普通汉字", page: 0)
            XCTAssertEqual(hits.count, 1)
            let hit = try XCTUnwrap(hits.first)
            XCTAssertEqual(text.substring(with: NSRange(location: hit.index, length: 4)), "普通汉字")
            XCTAssertTrue(hit.context.contains("普通汉字"))
            XCTAssertFalse(hit.rects.isEmpty)
            XCTAssertTrue(hit.rects.allSatisfy { $0.width > 0 && $0.height > 0 })
            if em == 17 { XCTAssertGreaterThanOrEqual(Set(hit.rects.map { Int($0.minY.rounded()) }).count, 2) }
            XCTAssertTrue(try file.matches("普通 汉字", page: 0).isEmpty)
            XCTAssertEqual(try file.matches("普通汉字", page: 0, backwards: true).first?.index, hit.index)
            XCTAssertTrue(try file.matches("普通汉字", page: 0, after: hit.index).isEmpty)
            XCTAssertEqual(try file.matches("普通汉字", page: 0, options: .init(caseSensitive: true)).count, 1)
        }
    }

    func testCJKFindRetainsAuthoredSpaceAndParagraphBoundaries() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        for (name, body) in [("Space", prefix + "普通 汉字" + suffix), ("Blocks", "普通\n\n汉字\n")] {
            let input = temporary.url.appendingPathComponent(name + ".md")
            try body.write(to: input, atomically: true, encoding: .utf8)
            let file = try NativeFile(input, engine: .mupdf)
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light")
            XCTAssertTrue(try file.matches("普通汉字", page: 0).isEmpty, "An authored separator must not be removed")
            XCTAssertEqual(try file.matches("普通 汉字", page: 0).count, 1)
        }
    }

    func testSourceBlockContinuationsKeepHiddenContentAndParagraphGaps() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        for style in ["visibility:hidden", "color:transparent"] {
            for (name, markup) in [
                ("Paragraph", "<p>BEFORE</p><p><span style=\"\(style)\">HIDDEN</span>AFTER</p>"),
                ("Inline", "<p>BEFORE<span style=\"\(style)\">HIDDEN</span>AFTER</p>")
            ] {
                let input = temporary.url.appendingPathComponent(name + ".html")
                try markup.write(to: input, atomically: true, encoding: .utf8)
                let file = try NativeFile(input, engine: .mupdf)
                _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light")
                XCTAssertTrue(try file.matches("BEFOREAFTER", page: 0).isEmpty, "\(name): \(style)")
                XCTAssertTrue(try file.matches("HIDDEN", page: 0).isEmpty)
                XCTAssertEqual(try file.matches("BEFORE AFTER", page: 0).count, 1, "\(name): \(style)")
            }
        }
    }

    func testNativeHTMLSourceFindKeepsEnglishWrapsLigaturesFoldingAndRTLWords() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Find-controls.md")
        let wrapped = "This long sentence must wrap between authored English words."
        let rtl = "שלום עולם בדיקה עברית מילים מסמך קריאה חיפוש גבולות"
        try ("# Search controls\n\nThe ordinary English passage has office ligatures, café accents and Straße folding. " + wrapped + "\n\n" + rtl + "\n")
            .write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light")
        for query in [wrapped, "office", "cafe", "strasse", rtl] {
            let hits = try file.matches(query, page: 0)
            XCTAssertEqual(hits.count, 1, query)
            XCTAssertFalse(try XCTUnwrap(hits.first).rects.isEmpty)
        }
        XCTAssertTrue(try file.matches("Englishpassage", page: 0).isEmpty)
    }
    func testSourcePartsUTF16AndNoSourcePDFFindRetainGeometry() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Ligatures.html")
        try "<p>😀 ﬁ ﬂ ffi office affine</p>".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light")
        let text = try XCTUnwrap(file.text(0)) as NSString
        XCTAssertTrue(try file.words(0).contains { ($0.source?.part ?? 0) > 0 })
        let fi = try file.matches("fi", page: 0)
        let expected = try NSRegularExpression(pattern: "fi").matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { $0.range.location }
        XCTAssertEqual(fi.map(\.index), expected)
        XCTAssertEqual(fi.first?.index, 3, "The leading supplementary scalar occupies two UTF-16 units")
        XCTAssertTrue(fi.allSatisfy { $0.rects.contains { $0.width > 0 && $0.height > 0 } },
                      "Every partial-ligature match must have paintable geometry")
        XCTAssertEqual(try file.matches("fi", page: 0, backwards: true).map(\.index), Array(expected.reversed()))
        for query in ["office", "affine"] {
            XCTAssertTrue(try XCTUnwrap(file.matches(query, page: 0).first).rects.contains { $0.width > 0 && $0.height > 0 })
        }
        let pdfURL = temporary.url.appendingPathComponent("No-source.pdf")
        try noSourcePDF().write(to: pdfURL)
        let pdf = try NativeFile(pdfURL, engine: .mupdf)
        XCTAssertTrue(try pdf.words(0).allSatisfy { $0.source == nil })
        let pdfHits = try pdf.matches("HELLO WORLD", page: 0)
        XCTAssertEqual(pdfHits.count, 1)
        XCTAssertTrue(try XCTUnwrap(pdfHits.first).rects.contains { $0.width > 0 && $0.height > 0 })
        XCTAssertTrue(try pdf.matches("HELLOWORLD", page: 0).isEmpty,
                      "No-source PDF line boundaries must retain their separator")
    }

    func testActualLanguageAutoHyphensAndMixedRTLWrapKeepSearchSemantics() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Auto.html")
        try "<p lang=\"en\" style=\"hyphens:auto\">internationalization</p>".write(to: input, atomically: true, encoding: .utf8)
        let automatic = try NativeFile(input, engine: .mupdf)
        _ = try automatic.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light", userCSS: "@page{margin:42px 150px !important;}")
        let hit = try XCTUnwrap(automatic.matches("internationalization", page: 0).first)
        XCTAssertGreaterThanOrEqual(Set(hit.rects.map { Int($0.minY.rounded()) }).count, 2, "The auto-hyphen control must really span visual lines")
        XCTAssertTrue(try automatic.matches("interna tionalization", page: 0).isEmpty)
        let rtl = "שלום עולם בדיקה עברית מילים מסמך קריאה חיפוש גבולות"
        let mixedInput = temporary.url.appendingPathComponent("Mixed.html")
        try ("<p dir=\"rtl\" lang=\"he\">" + rtl + " ABC796 tail " + rtl.replacingOccurrences(of: "שלום", with: "בוקר") + "</p>")
            .write(to: mixedInput, atomically: true, encoding: .utf8)
        let mixed = try NativeFile(mixedInput, engine: .mupdf)
        _ = try mixed.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light")
        for query in [rtl, "ABC796 tail"] {
            XCTAssertEqual(try mixed.matches(query, page: 0).count, 1)
        }
        XCTAssertTrue(try mixed.matches("ABC796tail", page: 0).isEmpty)
    }

    private func noSourcePDF() -> Data {
        let stream = "BT /F1 16 Tf 40 170 Td (HELLO) Tj 0 -24 Td (WORLD) Tj ET"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 240] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
                       "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                       "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"]
        var data = Data("%PDF-1.4\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer << /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
#endif
