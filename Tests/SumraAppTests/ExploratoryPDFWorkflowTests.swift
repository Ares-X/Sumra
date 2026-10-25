#if os(macOS)
import AppKit
import CryptoKit
import SumraCore
import XCTest
@testable import Sumra

final class ExploratoryPDFWorkflowTests: XCTestCase {
    func testEncryptedSaveBranchKeepsConcurrentReaderAndMixedEditsIndependent() async throws {
        let directory = try fixtureDirectory(), plain = directory.appendingPathComponent("plain.pdf")
        let original = fixture(); try original.write(to: plain)
        let originalHash = SHA256.hash(data: original)
        let source = directory.appendingPathComponent("encrypted.pdf")
        try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        let pages = try Pages(source, format: .pdf, password: "owner")
        try await pages.pdfSetEditing(true)
        try await pages.pdfSetWidgetValue(page: 0, id: 5, value: "SAVED FORM")
        let originalNote = try await pages.pdfCreateAnnotation(page: 1, type: "Square",
            bounds: CGRect(x: 40, y: 40, width: 80, height: 60), edits: [.contents("Saved first branch")])
        try await pages.pdfSave(to: source)
        let savedInfo = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(savedInfo).dirty)

        // A second window retains the first saved version while the first
        // window undoes across that save and replaces its future history.
        let reader = try NativeFile(source, engine: .mupdf, password: "reader")
        XCTAssertThrowsError(try reader.pdfSetEditing(true))
        try await pages.pdfUndo()
        try await pages.pdfUndo()
        let baselineCopy = directory.appendingPathComponent("undone.pdf")
        try await pages.pdfSaveCopy(to: baselineCopy)
        let baseline = try NativeFile(baselineCopy, engine: .mupdf, password: "reader")
        XCTAssertEqual(try baseline.pdfAnnotations(0).first { $0.fieldName == "review" }?.value, "Original")
        XCTAssertTrue(try baseline.pdfAnnotations(1).isEmpty)

        try await pages.pdfUndo(redo: true)
        _ = try await pages.pdfCreateAnnotation(page: 1, type: "FreeText",
            bounds: CGRect(x: 30, y: 80, width: 220, height: 50), edits: [.contents("New branch note")])
        try await pages.pdfSave(to: source)
        let current = try NativeFile(source, engine: .mupdf, password: "reader")
        XCTAssertEqual(try current.pdfAnnotations(0).first { $0.fieldName == "review" }?.value, "SAVED FORM")
        XCTAssertEqual(try current.pdfAnnotations(1).map(\.contents), ["New branch note"])
        XCTAssertFalse(try XCTUnwrap(current.pdfInfo()).permissions.copy)
        XCTAssertTrue(try XCTUnwrap(current.pdfInfo()).permissions.print)
        XCTAssertEqual(try reader.pdfAnnotations(1).first { $0.id == originalNote }?.contents, "Saved first branch")
        let oldPrint = directory.appendingPathComponent("old-window-print.pdf")
        try reader.printPDF(to: oldPrint)
        let printed = try NativeFile(oldPrint, engine: .mupdf)
        XCTAssertFalse(try XCTUnwrap(printed.text(1)).contains("New branch note"))
        XCTAssertThrowsError(try current.exportPDF(to: directory.appendingPathComponent("forbidden-export.pdf")))
        let finalInfo = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(finalInfo).dirty)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: plain)), originalHash)
    }

    func testEditedRotatedSnapshotSurvivesSubsetDuplicatesExportAndPrintWhileLiveRedoContinues() async throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("source.pdf")
        let original = fixture(); try original.write(to: source)
        let originalHash = SHA256.hash(data: original), pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        try await pages.pdfSetWidgetValue(page: 0, id: 5, value: "REVIEWED ROTATED")
        let note = try await pages.pdfCreateAnnotation(page: 1, type: "Square",
            bounds: CGRect(x: 30, y: 50, width: 90, height: 60), edits: [.contents("Snapshot note")])
        try await pages.pdfEditAnnotation(page: 1, id: note, edits: [.contents("Future live note")])
        try await pages.pdfUndo()
        let before = try await pages.pdfInfo()
        let snapshot = directory.appendingPathComponent("snapshot.pdf")
        try await pages.pdfSaveCopy(to: snapshot)
        let subset = directory.appendingPathComponent("subset.pdf")
        try NativePDFOutput.write(snapshot: snapshot, password: "", operation: .extract([1, 0, 1], annotationsOnly: false),
            to: subset, originalSources: [source])
        let extracted = try NativeFile(subset, engine: .mupdf)
        XCTAssertEqual(extracted.count, 3)
        XCTAssertEqual(try extracted.pdfAnnotations(0).first?.contents, "Snapshot note")
        XCTAssertEqual(try extracted.pdfAnnotations(2).first?.contents, "Snapshot note")
        let exportedURL = directory.appendingPathComponent("export.pdf")
        XCTAssertTrue(try extracted.exportPDF(to: exportedURL))
        let exported = try NativeFile(exportedURL, engine: .mupdf)
        for index in 0..<3 {
            // Compare premultiplied appearance pixels before opaque background
            // composition can round antialiased glyph edges by one code value.
            let input = try extracted.image(index, width: 480, transparent: true)
            let output = try exported.image(index, width: 480, transparent: true)
            if ProcessInfo.processInfo.environment["SUMRA_PDF_WORKFLOW_EVIDENCE"] != nil {
                for (name, image) in [("input", input), ("export", output)] {
                    try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("page-\(index)-\(name).png"))
                }
            }
            XCTAssertEqual(input.width, output.width); XCTAssertEqual(input.height, output.height)
            XCTAssertEqual(input.dataProvider?.data as Data?, output.dataProvider?.data as Data?)
        }
        XCTAssertTrue(try XCTUnwrap(exported.text(1)).contains("REVIEWED ROTATED"))
        let printedURL = directory.appendingPathComponent("printed.pdf")
        try extracted.printPDF(to: printedURL, selectedPages: [1, 2, 0], rotation: 90)
        let printed = try NativeFile(printedURL, engine: .mupdf)
        XCTAssertEqual(printed.count, 3)
        for (outputIndex, inputIndex) in [1, 2, 0].enumerated() {
            let input = try XCTUnwrap(extracted.bounds(inputIndex)), output = try XCTUnwrap(printed.bounds(outputIndex))
            XCTAssertEqual(output.width, input.height, accuracy: 0.001)
            XCTAssertEqual(output.height, input.width, accuracy: 0.001)
            XCTAssertTrue(try printed.imageBounds(outputIndex).isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(printed.text(0)).contains("REVIEWED ROTATED"))
        let deletedURL = directory.appendingPathComponent("deleted.pdf")
        try NativePDFOutput.write(snapshot: subset, password: "", operation: .delete([0, 2], count: 3),
            to: deletedURL, originalSources: [source, subset])
        let remaining = try NativeFile(deletedURL, engine: .mupdf)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try remaining.bounds(0), try extracted.bounds(1))
        XCTAssertEqual(try remaining.pdfAnnotations(0).first { $0.type == "Widget" }?.value, "REVIEWED ROTATED")
        let after = try await pages.pdfInfo()
        XCTAssertEqual(after?.undoPosition, before?.undoPosition); XCTAssertEqual(after?.undoSteps, before?.undoSteps)
        try await pages.pdfUndo(redo: true)
        let liveNotes = try await pages.pdfAnnotations(1)
        XCTAssertEqual(liveNotes.first { $0.id == note }?.contents, "Future live note")
        XCTAssertEqual(try extracted.pdfAnnotations(0).first?.contents, "Snapshot note")
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), originalHash)
    }

    func testCancelledCopyAfterSourceReplacementPreservesDestinationAndCanRecoverThenContinueEditing() async throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("source.pdf")
        try fixture().write(to: source)
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        try await pages.pdfSetWidgetValue(page: 0, id: 5, value: "LOCAL UNSAVED")
        let replacement = Data("External replacement must survive".utf8)
        try replacement.write(to: source, options: .atomic)
        let output = directory.appendingPathComponent("existing.pdf"), sentinel = Data("Existing destination must survive".utf8)
        try sentinel.write(to: output)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await pages.pdfSaveCopy(to: output)
        }
        do { try await cancelled.value; XCTFail("A cancelled copy must not replace its destination") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        do { try await pages.pdfSave(to: source); XCTFail("Ordinary Save must retain an external replacement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed outside")) }
        try await pages.pdfSaveCopy(to: output)
        let recovered = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(try recovered.pdfAnnotations(0).first { $0.fieldName == "review" }?.value, "LOCAL UNSAVED")
        try await pages.pdfUndo()
        try await pages.pdfSetWidgetValue(page: 0, id: 5, value: "CONTINUED AFTER CANCEL")
        let prepared = try await pages.preparePDFPrint(to: directory.appendingPathComponent("print-snapshot.pdf"), password: "")
        let printedURL = directory.appendingPathComponent("print.pdf")
        try prepared.file.printPDF(to: printedURL)
        XCTAssertTrue(try XCTUnwrap(NativeFile(printedURL, engine: .mupdf).text(0)).contains("CONTINUED AFTER CANCEL"))
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".Sumra-save-") })
    }

    private func fixtureDirectory() throws -> URL {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before PDF workflow exploration") }
        let evidenceRoot = ProcessInfo.processInfo.environment["SUMRA_PDF_WORKFLOW_EVIDENCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = (evidenceRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Sumra-pdf-workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if evidenceRoot == nil { addTeardownBlock { try? FileManager.default.removeItem(at: directory) } }
        return directory
    }

    private func fixture() -> Data {
        let first = "BT /Helv 14 Tf 50 180 Td (VECTOR ROTATED PAGE) Tj ET\n"
        let second = "BT /Helv 14 Tf 30 180 Td (VECTOR SECOND PAGE) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 330 260] /CropBox [30 40 310 240] /Rotate 90 /Resources << /Font << /Helv 6 0 R >> >> /Contents 7 0 R /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 240] /Resources << /Font << /Helv 6 0 R >> >> /Contents 8 0 R >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (review) /V (Original) /Rect [50 90 290 130] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(first.utf8.count) >>\nstream\n\(first)endstream",
            "<< /Length \(second.utf8.count) >>\nstream\n\(second)endstream"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
#endif
