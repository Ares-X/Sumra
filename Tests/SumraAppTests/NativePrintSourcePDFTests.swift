#if os(macOS)
import AppKit
import Darwin
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativePrintSourcePDFTests: XCTestCase {
    func testSourcePageInsertionPreservesUnicodePaperAndSystemMetadata() throws {
        let (directory, source, pdf, paper) = try fixture()
        defer { withExtendedLifetime(directory) {} }
        let page = try XCTUnwrap(pdf.page(at: 1))
        let output = directory.url.appendingPathComponent("system-save.pdf")
        try quartzSave(page, to: output, paper: paper)
        let before = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(before.pageCount, 1)
        let title = before.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let author = before.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let xmp = try NativeFile(output, engine: .mupdf).pdfXMP()
        XCTAssertNotNil(xmp)
        XCTAssertNotNil(xmp?.range(of: Data("System XMP".utf8)))
        let metadata = Array("retained xattr".utf8)
        XCTAssertEqual(metadata.withUnsafeBytes { setxattr(output.path, "com.sumra.test.print-source",
            $0.baseAddress, $0.count, 0, 0) }, 0)

        let writer = try NativePDFTools.SourcePrintPDF()
        let sourceBox = page.getBoxRect(.mediaBox)
        try writer.add(source, paperSize: paper.size,
                       transform: CGAffineTransform(translationX: (paper.width - sourceBox.width) / 2,
                                                    y: (paper.height - sourceBox.height) / 2), clip: sourceBox)
        try writer.finish(output)

        let document = try XCTUnwrap(PDFDocument(url: output)), text = document.string ?? ""
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox), paper)
        XCTAssertTrue(text.contains("⼀⼆⼃⽥"))
        XCTAssertTrue(text.contains("office affine"))
        XCTAssertTrue(text.contains("Hindi"))
        XCTAssertTrue(text.contains("END77"))
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title)
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, author)
        XCTAssertEqual(try NativeFile(output, engine: .mupdf).pdfXMP(), xmp)
        var copiedMetadata = [UInt8](repeating: 0, count: metadata.count)
        let copiedCount = copiedMetadata.withUnsafeMutableBytes { getxattr(output.path,
            "com.sumra.test.print-source", $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(copiedCount, metadata.count)
        XCTAssertEqual(copiedMetadata, metadata)
    }

    func testEncryptedSystemSaveRemainsByteForByteUntouched() throws {
        let (directory, source, pdf, paper) = try fixture()
        defer { withExtendedLifetime(directory) {} }
        let page = try XCTUnwrap(pdf.page(at: 1))
        let plain = directory.url.appendingPathComponent("plain.pdf")
        let encrypted = directory.url.appendingPathComponent("encrypted.pdf")
        try quartzSave(page, to: plain, paper: paper)
        try NativePDFTools.encrypt(source: plain, destination: encrypted,
                                   ownerPassword: "owner", userPassword: "reader")
        let original = try Data(contentsOf: encrypted)
        let writer = try NativePDFTools.SourcePrintPDF()
        let box = page.getBoxRect(.mediaBox)
        try writer.add(source, paperSize: paper.size,
                       transform: CGAffineTransform(translationX: 87.5, y: 123.5), clip: box)
        XCTAssertThrowsError(try writer.finish(encrypted))
        XCTAssertEqual(try Data(contentsOf: encrypted), original)
    }

    func testMismatchedPhysicalPageCountAndPaperKeepSystemSaveUntouched() throws {
        let (directory, source, pdf, paper) = try fixture()
        defer { withExtendedLifetime(directory) {} }
        let page = try XCTUnwrap(pdf.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        for (name, sheets, declaredPaper) in [
            ("page-count", 2, paper),
            ("paper-size", 1, CGRect(x: 0, y: 0, width: paper.width + 5, height: paper.height))
        ] {
            let output = directory.url.appendingPathComponent(name + ".pdf")
            try quartzSave(page, to: output, paper: paper, sheets: sheets)
            let original = try Data(contentsOf: output)
            let writer = try NativePDFTools.SourcePrintPDF()
            try writer.add(source, paperSize: declaredPaper.size,
                           transform: CGAffineTransform(translationX: 87.5, y: 123.5), clip: box)
            XCTAssertThrowsError(try writer.finish(output))
            XCTAssertEqual(try Data(contentsOf: output), original)
        }
    }

    func testRepeatedSourcePagesShareFontProgramsAndKeepEveryPageText() throws {
        let (directory, source, pdf, paper) = try fixture()
        defer { withExtendedLifetime(directory) {} }
        let page = try XCTUnwrap(pdf.page(at: 1))
        let sourceBox = page.getBoxRect(.mediaBox)
        let placement = CGAffineTransform(translationX: (paper.width - sourceBox.width) / 2,
                                          y: (paper.height - sourceBox.height) / 2)
        func correctedOutput(_ count: Int) throws -> URL {
            let output = directory.url.appendingPathComponent("source-pages-\(count).pdf")
            try quartzSave(page, to: output, paper: paper, sheets: count)
            let writer = try NativePDFTools.SourcePrintPDF()
            for _ in 0..<count {
                try writer.add(source, paperSize: paper.size, transform: placement, clip: sourceBox)
            }
            try writer.finish(output)
            let result = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(result.pageCount, count)
            for index in 0..<count {
                let text = try XCTUnwrap(result.page(at: index)).string ?? ""
                XCTAssertTrue(text.contains("⼀⼆⼃⽥"))
                XCTAssertTrue(text.contains("office affine"))
                XCTAssertTrue(text.contains("END77"))
            }
            return output
        }
        let single = try correctedOutput(1)
        let repeated = try correctedOutput(3)
        let oneSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: single.path)[.size] as? NSNumber).int64Value
        let threeSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: repeated.path)[.size] as? NSNumber).int64Value
        // A page-sized font copy for each sheet would grow roughly threefold.
        // Allow room for page dictionaries and stream encoding differences.
        XCTAssertLessThan(threeSize, oneSize * 3 / 2 + 1_048_576)
    }

    private func fixture() throws -> (TemporaryDirectory, Data, CGPDFDocument, CGRect) {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("Build the MuPDF engine before native print source tests")
        }
        let directory = try TemporaryDirectory()
        let markdown = directory.url.appendingPathComponent("Unicode.md")
        try Data("# 阅读指南\n\n普通汉字 一二三 田 ⼀⼆⼃⽥\n\noffice affine fi fl ﬁ ﬂ\n\nHindi END77\n".utf8).write(to: markdown)
        let file = try NativeFile(markdown, engine: .mupdf)
        let source = directory.url.appendingPathComponent("source.pdf")
        try file.exportPDF(to: source, selectedPages: [0])
        let bytes = try Data(contentsOf: source)
        let pdf = try XCTUnwrap(CGPDFDocument(source as CFURL))
        _ = try XCTUnwrap(pdf.page(at: 1))
        let text = PDFDocument(url: source)?.string ?? ""
        XCTAssertTrue(text.contains("⼀⼆⼃⽥"))
        XCTAssertTrue(text.contains("office affine"))
        XCTAssertTrue(text.contains("Hindi"))
        XCTAssertTrue(text.contains("END77"))
        return (directory, bytes, pdf, CGRect(x: 0, y: 0, width: 595, height: 842))
    }

    private func quartzSave(_ page: CGPDFPage, to output: URL, paper: CGRect, sheets: Int = 1) throws {
        var box = paper
        let properties = [kCGPDFContextTitle as String: "Native Unicode Save",
                          kCGPDFContextAuthor as String: "Sumra QA",
                          kCGPDFContextCreator as String: "Sumra"] as CFDictionary
        let context = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &box, properties))
        context.addDocumentMetadata(Data(#"<?xpacket begin=''?><x:xmpmeta xmlns:x='adobe:ns:meta/'>System XMP</x:xmpmeta><?xpacket end='w'?>"#.utf8) as CFData)
        let source = page.getBoxRect(.mediaBox)
        for _ in 0..<sheets {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: (paper.width - source.width) / 2,
                                y: (paper.height - source.height) / 2)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}
#endif
