#if os(macOS)
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFModifiedUTF8Tests: XCTestCase {
    func testPDFMetadataPreservesEmbeddedNULThroughNativeJSON() throws {
        try assertStrings(title: "热力学\0第二版😀", author: "\0Author\0after\0", bookmark: "Chapter", utf16: true)
    }

    func testPDFBookmarksPreserveEmbeddedNULThroughNativeJSON() throws {
        try assertStrings(title: "Title", author: "Author", bookmark: "章节\0后续😀\n\"\\", utf16: true)
    }

    func testOrdinaryPDFStringsPreserveJSONEscapingAndUnicode() throws {
        for utf16 in [false, true] {
            try assertStrings(title: utf16 ? "热力学😀" : "Title", author: "Author\n\"\\",
                              bookmark: "Chapter\t\"\\", utf16: utf16)
        }
    }

    private func assertStrings(title: String, author: String, bookmark: String, utf16: Bool) throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw XCTSkip("Build MuPDF before PDF string encoding tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("strings.pdf")
        try fixture(title: title, author: author, bookmark: bookmark, utf16: utf16).write(to: input)
        // NativeFile decodes metadata while opening, before callers can ask
        // for the outline. Exercise each NUL-bearing path independently.
        let file = try NativeFile(input, engine: .mupdf)
        XCTAssertEqual(file.count, 1)
        let metadata = try file.metadata()
        XCTAssertEqual(metadata["Title"], title)
        XCTAssertEqual(metadata["Author"], author)
        let outline = try file.outline()
        XCTAssertEqual(outline.count, 1)
        XCTAssertEqual(outline.first?.title, bookmark)
        XCTAssertEqual(outline.first?.page, 0)
    }

    private func fixture(title: String, author: String, bookmark: String, utf16: Bool) -> Data {
        func pdfString(_ value: String) -> String {
            let bytes = utf16 ? [UInt8(0xfe), 0xff] + value.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
                : Array(value.utf8)
            return "<" + bytes.map { String(format: "%02x", $0) }.joined() + ">"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
            "<< /Title \(pdfString(title)) /Author \(pdfString(author)) >>",
            "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>",
            "<< /Title \(pdfString(bookmark)) /Parent 5 0 R /Dest [3 0 R /Fit] >>"
        ]
        var pdf = "%PDF-1.7\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 4 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
#endif
