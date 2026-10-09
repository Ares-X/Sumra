#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFPrintingTests: XCTestCase {
    @MainActor
    func testPrintCommandsFollowLivePDFPermissionAndRetainNonPDFPrinting() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("source.pdf")
        let original = fixture(); try original.write(to: source)
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        XCTAssertFalse(ReaderMenuCommand.print.enabled(state))
        for permissions in [UInt(0), UInt(1), UInt(1 | 2)] {
            let encrypted = directory.appendingPathComponent("protected-\(permissions).pdf")
            try NativePDFTools.encrypt(source: source, destination: encrypted,
                ownerPassword: "owner", userPassword: "reader", permissions: permissions)
            for password in ["reader", "owner"] {
                let pages = try Pages(encrypted, format: .pdf, password: password)
                state.document = ReadingDocument(url: encrypted, content: .pages(pages))
                state.hasSelection = true
                XCTAssertFalse(ReaderMenuCommand.print.enabled(state), "A new PDF awaits its own permission snapshot")
                XCTAssertFalse(ReaderMenuCommand.printSelection.enabled(state))
                state.nativePDFInfo = try await pages.pdfInfo()
                let printable = permissions != 0 || password == "owner"
                XCTAssertEqual(ReaderMenuCommand.print.enabled(state), printable)
                XCTAssertEqual(ReaderMenuCommand.printSelection.enabled(state), printable,
                               "Selection printing follows the same permission, independent of Copy and Print HQ")
                state.hasSelection = false
                XCTAssertFalse(ReaderMenuCommand.printSelection.enabled(state))
            }
        }
        let svg = directory.appendingPathComponent("non-PDF.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10' fill='red'/></svg>".utf8).write(to: svg)
        state.document = try ReadingDocument.open(svg)
        state.hasSelection = true
        XCTAssertTrue(state.isFixed)
        XCTAssertNil(state.nativePDF)
        XCTAssertTrue(ReaderMenuCommand.print.enabled(state))
        XCTAssertTrue(ReaderMenuCommand.printSelection.enabled(state))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPrintingUsesPrintPermissionWithoutRequiringCopyOrHQ() throws {
        let directory = try directory(), source = directory.appendingPathComponent("source.pdf")
        let original = fixture(); try original.write(to: source)
        // CoreGraphics uses bits 0/1 for low/high quality printing; bit 5 is accessibility.
        for permissions in [UInt(0), UInt(1), UInt(1 | 2)] {
            let encrypted = directory.appendingPathComponent("protected-\(permissions).pdf")
            try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: permissions)
            let file = try NativeFile(encrypted, engine: .mupdf, password: "reader"), info = try XCTUnwrap(file.pdfInfo())
            XCTAssertFalse(info.permissions.copy)
            let output = directory.appendingPathComponent("print-\(permissions).pdf"), sentinel = Data("Existing output".utf8)
            try sentinel.write(to: output)
            if permissions == 0 {
                XCTAssertThrowsError(try file.printPDF(to: output))
                XCTAssertEqual(try Data(contentsOf: output), sentinel)
            } else {
                XCTAssertEqual(info.permissions.printHighQuality, permissions & 2 != 0)
                try file.printPDF(to: output)
                let printed = try NativeFile(output, engine: .mupdf)
                XCTAssertTrue(try XCTUnwrap(printed.text(0)).contains("VECTOR PRINT"))
                XCTAssertTrue(try printed.imageBounds(0).isEmpty, "Print follows Sumatra's PRINT permission policy without inventing a raster fallback")
            }
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, info.undoPosition)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).dirty, info.dirty)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPrintUsageHonorsFlagsAndOptionalContentRegardlessOfViewerVisibility() throws {
        let directory = try directory(), source = directory.appendingPathComponent("flags.pdf")
        func stream(_ body: String, form: Bool = false) -> String {
            "<< \(form ? "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >>" : "") /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
        }
        // Red and green OCGs swap View/Print visibility. The blue annotation
        // is NoView|Print; another green one is screen-only and a red one Hidden.
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /BaseState /ON /Order [5 0 R 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 40] /Resources << /Properties << /P 5 0 R /V 6 0 R >> >> /Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R] >>",
            stream("/OC /P BDC 1 0 0 rg 0 0 20 40 re f EMC /OC /V BDC 0 1 0 rg 20 0 20 40 re f EMC"),
            "<< /Type /OCG /Name (Print only) /Usage << /View << /ViewState /OFF >> /Print << /PrintState /ON >> >> >>",
            "<< /Type /OCG /Name (View only) /Usage << /View << /ViewState /ON >> /Print << /PrintState /OFF >> >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [40 0 60 20] /F 36 /AP << /N 10 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [60 0 80 20] /F 0 /AP << /N 11 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [80 0 100 20] /F 6 /AP << /N 12 0 R >> >>",
            stream("0 0 1 rg 0 0 20 20 re f", form: true), stream("0 1 0 rg 0 0 20 20 re f", form: true),
            stream("1 0 0 rg 0 0 20 20 re f", form: true)
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let view = try file.image(0, width: 100)
        XCTAssertEqual(try pixel(view, 10, 30), [255, 255, 255])
        XCTAssertEqual(try pixel(view, 30, 30), [0, 255, 0])
        for visible in [false, true] {
            try file.pdfSetAnnotationsVisible(visible)
            let output = directory.appendingPathComponent("print-\(visible).pdf")
            let content = try file.printPDF(to: output)
            XCTAssertEqual(content, [CGRect(x: 0, y: 0, width: 60, height: 40)],
                           "Print fit uses the print-only layer and annotation, excluding view-only artwork")
            let printed = try NativeFile(output, engine: .mupdf).image(0, width: 100)
            XCTAssertEqual(try pixel(printed, 10, 30), [255, 0, 0])
            XCTAssertEqual(try pixel(printed, 30, 30), [255, 255, 255])
            XCTAssertEqual(try pixel(printed, 50, 30), [0, 0, 255], "NoView does not suppress an annotation's Print appearance")
            XCTAssertEqual(try pixel(printed, 70, 30), [255, 255, 255])
            XCTAssertEqual(try pixel(printed, 90, 30), [255, 255, 255])
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testPrintUsesUnsavedFormAppearanceAndLeavesUndoAndSourceIntact() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("form.pdf")
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Original) /Rect [10 30 190 70] /F 4 /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        try original.write(to: source)
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true); try await pages.pdfSetWidgetValue(page: 0, id: 4, value: "UNSAVED FORM")
        let beforeValue = try await pages.pdfInfo(), before = try XCTUnwrap(beforeValue)
        let output = directory.appendingPathComponent("print.pdf")
        do {
            _ = try await pages.preparePDFPrint(to: directory.appendingPathComponent("missing/snapshot.pdf"), password: "")
            XCTFail("A failed snapshot must surface its write error")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        let prepared = try await pages.preparePDFPrint(to: directory.appendingPathComponent("snapshot.pdf"), password: "")
        let printFile = prepared.file
        try printFile.printPDF(to: output)
        XCTAssertTrue(try XCTUnwrap(NativeFile(output, engine: .mupdf).text(0)).contains("UNSAVED FORM"))
        let afterValue = try await pages.pdfInfo(), after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.undoSteps, before.undoSteps)
        XCTAssertEqual(after.dirty, before.dirty); XCTAssertTrue(after.dirty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try await pages.pdfUndo(redo: false)
        let annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.first?.value, "Original")
        XCTAssertEqual(try printFile.pdfAnnotations(0).first?.value, "UNSAVED FORM",
                       "The independent print document must not change when reading continues")
    }

    func testPrintPreparationReopensImmutableCleanSourceAfterMoveOrReplacement() async throws {
        let directory = try directory()
        for change in ["unchanged", "moved", "replaced"] {
            let source = directory.appendingPathComponent(change + ".pdf")
            try fixture().write(to: source)
            let pages = try Pages(source, format: .pdf)
            if change == "moved" { try FileManager.default.moveItem(at: source, to: source.appendingPathExtension("moved")) }
            if change == "replaced" { try fixture(secondPage: true).write(to: source, options: .atomic) }
            let snapshot = directory.appendingPathComponent(change + "-snapshot.pdf")
            let prepared = try await pages.preparePDFPrint(to: snapshot, password: "")
            let printFile = prepared.file
            XCTAssertEqual(printFile.count, 1, "Print the open version, not a replacement at the same path")
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path), "A clean document shares its immutable input without another disk copy")
            let output = directory.appendingPathComponent(change + "-print.pdf")
            try printFile.printPDF(to: output, selectedPages: [0])
            XCTAssertTrue(try XCTUnwrap(NativeFile(output, engine: .mupdf).text(0)).contains("VECTOR PRINT"))
            let info = try await pages.pdfInfo()
            XCTAssertFalse(try XCTUnwrap(info).dirty)
        }
    }

    func testPrintAfterOrdinarySaveRetainsSavedEditsAndLiveJournal() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("saved-edits.pdf")
        try fixture().write(to: source)
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        let id = try await pages.pdfCreateAnnotation(page: 0, type: "Square",
            bounds: CGRect(x: 20, y: 20, width: 50, height: 40), edits: [.contents("Saved note")])
        try await pages.pdfSave(to: source)
        let beforeValue = try await pages.pdfInfo(), before = try XCTUnwrap(beforeValue)
        XCTAssertFalse(before.dirty)
        XCTAssertGreaterThan(before.undoPosition, 0)
        let snapshot = directory.appendingPathComponent("saved-print.pdf")
        let prepared = try await pages.preparePDFPrint(to: snapshot, password: "")
        XCTAssertEqual(try prepared.file.pdfAnnotations(0).first { $0.id == id }?.contents, "Saved note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let afterValue = try await pages.pdfInfo(), after = try XCTUnwrap(afterValue)
        XCTAssertFalse(after.dirty)
        XCTAssertEqual(after.undoPosition, before.undoPosition)
        XCTAssertEqual(after.undoSteps, before.undoSteps)
        try await pages.pdfUndo()
        XCTAssertEqual(try prepared.file.pdfAnnotations(0).first { $0.id == id }?.contents, "Saved note")
        try await pages.pdfUndo(redo: true)
        let restored = try await pages.pdfAnnotations(0)
        XCTAssertEqual(restored.first { $0.id == id }?.contents, "Saved note")
    }

    func testPrintPreparationRetainsOwnerAuthenticationAndRejectsRestrictedReader() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("source.pdf")
        try fixture().write(to: source)
        let encrypted = directory.appendingPathComponent("protected.pdf")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 0)
        for password in ["reader", "owner"] {
            let pages = try Pages(encrypted, format: .pdf, password: password)
            let snapshot = directory.appendingPathComponent(password + "-snapshot.pdf")
            if password == "reader" {
                do {
                    _ = try await pages.preparePDFPrint(to: snapshot, password: password)
                    XCTFail("Restricted readers cannot prepare a print document")
                } catch { XCTAssertTrue(error.localizedDescription.contains("printing")) }
            } else {
                let prepared = try await pages.preparePDFPrint(to: snapshot, password: password)
                let printFile = prepared.file
                XCTAssertTrue(try XCTUnwrap(printFile.pdfInfo()).ownerAuthenticated)
                try printFile.printPDF(to: directory.appendingPathComponent("owner-print.pdf"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        }
    }

    func testPrintingRepairedEditsUsesIndependentSnapshotAndKeepsRedo() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("repaired.pdf")
        var original = fixture()
        let marker = try XCTUnwrap(original.range(of: Data("startxref\n".utf8), options: .backwards))
        original.replaceSubrange(marker.upperBound..<original.endIndex, with: Data("0\n%%EOF\n".utf8))
        try original.write(to: source)
        let pages = try Pages(source, format: .pdf)
        try await pages.pdfSetEditing(true)
        let id = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 20, y: 20, width: 30, height: 30))
        try await pages.pdfEditAnnotation(page: 0, id: id, edits: [.contents("Second edit")])
        try await pages.pdfUndo()
        let beforeValue = try await pages.pdfInfo(), before = try XCTUnwrap(beforeValue)
        XCTAssertTrue(before.dirty)
        let output = directory.appendingPathComponent("print.pdf")
        let prepared = try await pages.preparePDFPrint(to: directory.appendingPathComponent("snapshot.pdf"), password: "")
        let bounds = try prepared.file.printPDF(to: output, selectedPages: [0], rotation: 90)
        XCTAssertEqual(bounds.count, 1)
        XCTAssertTrue(try XCTUnwrap(NativeFile(output, engine: .mupdf).text(0)).contains("VECTOR PRINT"))
        let afterValue = try await pages.pdfInfo(), after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.undoSteps, before.undoSteps)
        XCTAssertTrue(after.dirty)
        try await pages.pdfUndo(redo: true)
        let annotations = try await pages.pdfAnnotations(0)
        XCTAssertEqual(annotations.first { $0.id == id }?.contents, "Second edit")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPrintingRetainsOriginalSourceAfterInPlaceOverwrite() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("changed.pdf")
        try fixture().write(to: source)
        let pages = try Pages(source, format: .pdf), output = directory.appendingPathComponent("print.pdf")
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 0); try writer.write(contentsOf: fixture(secondPage: true)); try writer.close()
        let prepared = try await pages.preparePDFPrint(to: output, password: "")
        XCTAssertEqual(prepared.file.count, 1)
        XCTAssertTrue(try XCTUnwrap(prepared.file.text(0)).contains("VECTOR PRINT"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "An unchanged original can reopen its private input without an output snapshot")
        XCTAssertEqual(try Data(contentsOf: source), fixture(secondPage: true))
    }

    func testPrintContentBoundsUseEmittedCoordinatesAndBlankPageFallback() throws {
        let directory = try directory(), source = directory.appendingPathComponent("content.pdf")
        let body = "1 0 0 rg 60 30 30 40 re f\n"
        for rotation in [0, 90, 180, 270] {
            try rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [40 20 140 220] /Rotate \(rotation) /Contents 4 0 R >>",
                "<< /Length \(body.utf8.count) >>\nstream\n\(body)endstream",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 80 60] >>"
            ]).write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            let output = directory.appendingPathComponent("print-\(rotation).pdf")
            let content = try file.printPDF(to: output)
            let painted: CGRect
            switch rotation {
            case 90: painted = CGRect(x: 10, y: 50, width: 40, height: 30)
            case 180: painted = CGRect(x: 50, y: 150, width: 30, height: 40)
            case 270: painted = CGRect(x: 150, y: 20, width: 40, height: 30)
            default: painted = CGRect(x: 20, y: 10, width: 30, height: 40)
            }
            XCTAssertEqual(content, [painted, CGRect(x: 0, y: 0, width: 80, height: 60)])
        }
    }

    func testSelectionPrintPreservesVectorTextCropRotationAndRepeatedPages() throws {
        let directory = try directory()
        for sourceRotation in [0, 90, 180, 270] {
            let source = directory.appendingPathComponent("source-\(sourceRotation).pdf"), bytes = fixture(rotation: sourceRotation)
            try bytes.write(to: source)
            let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
            let textBounds = try file.words(0).reduce(CGRect.null) { $0.union($1.bounds) }
            let area = textBounds.insetBy(dx: -5, dy: -5).intersection(try XCTUnwrap(file.bounds(0)))
            XCTAssertFalse(area.isEmpty)
            let output = directory.appendingPathComponent("selection-\(sourceRotation).pdf")
            try file.printPDF(to: output, selectedPages: [0, 0], regions: [[area], [area]], rotation: 90)
            let printed = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(printed.count, 2)
            for page in 0..<2 {
                let box = try XCTUnwrap(printed.bounds(page))
                XCTAssertEqual(box.width, area.height, accuracy: 0.001); XCTAssertEqual(box.height, area.width, accuracy: 0.001)
                XCTAssertTrue(try XCTUnwrap(printed.text(page)).contains("VECTOR PRINT"))
                XCTAssertTrue(try printed.imageBounds(page).isEmpty, "Selection printing must not turn text or paths into a screenshot")
            }
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).dirty, before.dirty)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testCancelledAndInvalidPrintRequestsLeaveTheLiveDocumentUsable() throws {
        let directory = try directory(), source = directory.appendingPathComponent("source.pdf")
        try fixture().write(to: source)
        let file = try NativeFile(source, engine: .mupdf), output = directory.appendingPathComponent("print.pdf")
        let cancellation = try NativeRenderCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try file.printPDF(to: output, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try file.printPDF(to: output, selectedPages: [1]))
        XCTAssertThrowsError(try file.printPDF(to: output, selectedPages: [0], regions: []))
        XCTAssertThrowsError(try file.printPDF(to: output, selectedPages: [0], regions: [[CGRect(x: 1000, y: 1000, width: 10, height: 10)]]))
        XCTAssertThrowsError(try file.printPDF(to: directory.appendingPathComponent("missing/print.pdf")))
        try file.printPDF(to: output)
        XCTAssertTrue(try XCTUnwrap(NativeFile(output, engine: .mupdf).text(0)).contains("VECTOR PRINT"))
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
    }

    @MainActor func testAppKitPrintViewKeepsVectorContentAndRejectsInvalidPDF() throws {
        let directory = try directory(), source = directory.appendingPathComponent("source.pdf"), output = directory.appendingPathComponent("print.pdf")
        try fixture(secondPage: true).write(to: source)
        try NativeFile(source, engine: .mupdf).printPDF(to: output, selectedPages: [1, 0])
        let view = try ReaderPrinting.PDFPrintView(url: output, scaling: .fit)
        var range = NSRange()
        XCTAssertTrue(view.knowsPageRange(&range)); XCTAssertEqual(range, NSRange(location: 1, length: 2))
        XCTAssertEqual(view.rectForPage(0), .zero); XCTAssertEqual(view.rectForPage(3), .zero)
        for page in 1...2 {
            let rectangle = view.rectForPage(page), copy = directory.appendingPathComponent("appkit-\(page).pdf")
            try view.dataWithPDF(inside: rectangle).write(to: copy)
            let rendered = try NativeFile(copy, engine: .mupdf)
            XCTAssertTrue(try XCTUnwrap(rendered.text(0)).contains(page == 1 ? "SECOND PRINT" : "VECTOR PRINT"))
            XCTAssertTrue(try rendered.imageBounds(0).isEmpty)
        }
        let invalid = directory.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        XCTAssertThrowsError(try ReaderPrinting.PDFPrintView(url: invalid, scaling: .fit))
    }

    private func directory() throws -> URL {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else { throw XCTSkip("Build MuPDF before native printing tests") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-print-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data, channels = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * channels
        return Array(bytes[offset..<(offset + 3)])
    }
    private func fixture(rotation: Int = 0, secondPage: Bool = false) -> Data {
        let content = "0 g BT /F1 12 Tf 1 0 0 1 30 140 Tm (VECTOR PRINT) Tj ET 1 0 0 rg 15 25 10 10 re f\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R \(secondPage ? "6 0 R" : "")] /Count \(secondPage ? 2 : 1) >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /CropBox [10 20 190 180] /Rotate \(rotation) /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        if secondPage {
            let content = "0 g BT /F1 10 Tf 1 0 0 1 5 150 Tm (SECOND PRINT) Tj ET\n"
            objects += [
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 300] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
            ]
        }
        return rawPDF(objects)
    }
    private func rawPDF(_ objects: [String]) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return bytes
    }
}
#endif
