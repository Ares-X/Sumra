#if os(macOS)
import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import Sumra

/// Opt-in, downloaded primary-source documents. Originals are never edited.
/// Set SUMRA_PDF_INTEROP_DIR to the folder documented in PDF_INTEROPERABILITY.
final class RealPDFInteroperabilityTests: XCTestCase {
    func testPublishedPDFsRetainContentAndForeignAnnotationsAfterNativeSave() throws {
        let folder = try corpus()
        for name in ["attention.pdf", "pbc-2024-q4.pdf", "pdf20-utf8-test.pdf"] {
            let source = folder.appendingPathComponent(name)
            let original = try Data(contentsOf: source)
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let output = directory.url.appendingPathComponent(name)
            let foreign = try XCTUnwrap(PDFDocument(url: source))
            let text = foreign.page(at: 0)?.string
            let foreignNotes = foreign.page(at: 0)?.annotations.compactMap(\.contents) ?? []
            let marker = "Sumra 中文互通 2026"
            var live: NativeFile? = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(live?.count, foreign.pageCount)
            let first = try XCTUnwrap(live?.image(0, width: 720))
            XCTAssertGreaterThan(first.height, 0)
            try live?.pdfSetEditing(true)
            _ = try live?.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 12, y: 12, width: 80, height: 35),
                                            edits: [.contents(marker), .color([1, 0, 0], interior: false)])
            try live?.pdfWrite(to: output)
            live = nil // close MuPDF before the independent reader opens saved bytes
            let reopened = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(reopened.pageCount, foreign.pageCount, name)
            XCTAssertEqual(reopened.page(at: 0)?.string, text, name)
            let notes = reopened.page(at: 0)?.annotations.compactMap(\.contents) ?? []
            XCTAssertTrue(notes.contains(marker), name)
            for note in foreignNotes { XCTAssertTrue(notes.contains(note), name) }
            let quartz = try XCTUnwrap(CGPDFDocument(output as CFURL))
            XCTAssertEqual(quartz.numberOfPages, foreign.pageCount)
            let saved = try NativeFile(output, engine: .mupdf)
            XCTAssertTrue(try saved.pdfAnnotations(0).contains { $0.contents == marker })
            XCTAssertEqual(try Data(contentsOf: source), original)
            print("INTEROP \(name) pages=\(foreign.pageCount) sha256=\(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()) annotation=PDFKit+MuPDF preserved")
        }
    }

    func testPublishedAcroFormRetainsChineseValueAndAppearanceInExternalReader() throws {
        let folder = try corpus(), source = folder.appendingPathComponent("fw9.pdf")
        let original = try Data(contentsOf: source)
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let output = directory.url.appendingPathComponent("filled.pdf")
        var live: NativeFile? = try NativeFile(source, engine: .mupdf)
        let field = try XCTUnwrap(live?.pdfAnnotations(0).first { $0.type == "Widget" && $0.fieldType == 7 && $0.readOnly == false })
        let value = "中文验收 Sumra"
        try live?.pdfSetEditing(true)
        try live?.pdfSetWidgetValue(page: 0, id: field.id, value: value)
        try live?.pdfWrite(to: output)
        live = nil
        let external = try XCTUnwrap(PDFDocument(url: output))
        let widget = try XCTUnwrap(external.page(at: 0)?.annotations.first { $0.fieldName == field.fieldName })
        XCTAssertEqual(widget.widgetStringValue, value)
        let reopened = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(try reopened.pdfAnnotations(0).first { $0.fieldName == field.fieldName }?.value, value)
        XCTAssertEqual(try Data(contentsOf: source), original)
        // Retain independent-reader appearance evidence only when requested.
        if let evidence = ProcessInfo.processInfo.environment["SUMRA_PDF_INTEROP_EVIDENCE"] {
            let evidenceURL = URL(fileURLWithPath: evidence, isDirectory: true)
            try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
            let page = try XCTUnwrap(external.page(at: 0))
            let image = page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: evidenceURL.appendingPathComponent("fw9-PDFKit.png"))
            try Data(contentsOf: output).write(to: evidenceURL.appendingPathComponent("fw9-filled.pdf"))
        }
        print("INTEROP fw9.pdf field=\(field.fieldName ?? "") Chinese value=PDFKit+MuPDF preserved")
    }

    private func corpus() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_PDF_INTEROP_DIR"] else {
            throw XCTSkip("Opt in with downloaded primary-source PDF corpus")
        }
        return URL(fileURLWithPath: path)
    }
}
#endif
