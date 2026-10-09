#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFExportTests: XCTestCase {
    func testExportAfterMarkingEditedJournalSavedIncludesCurrentFormAppearance() throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("saved-form.pdf")
        try appearanceFixture().write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        try file.pdfSetWidgetValue(page: 0, id: 8, value: "SAVED VALUE")
        let saved = directory.url.appendingPathComponent("saved.pdf")
        _ = try file.pdfWrite(to: saved)
        try file.pdfMarkSaved()
        let before = try XCTUnwrap(file.pdfInfo())
        XCTAssertFalse(before.dirty)
        XCTAssertGreaterThan(before.undoPosition, 0)
        let output = directory.url.appendingPathComponent("exported.pdf")
        XCTAssertTrue(try file.exportPDF(to: output))
        XCTAssertTrue(try XCTUnwrap(NativeFile(output, engine: .mupdf).text(0)).contains("SAVED VALUE"))
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.dirty, before.dirty)
        XCTAssertEqual(after.undoPosition, before.undoPosition)
        XCTAssertEqual(after.undoSteps, before.undoSteps)
    }

    func testExportPreservesUnicodeMappingsAndOrderedDuplicatePages() throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("unicode.pdf")
        let bytes = unicodeFixture(); try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let before = try XCTUnwrap(file.pdfInfo())
        let texts = try (0..<file.count).map { try XCTUnwrap(file.text($0)) }
        XCTAssertTrue(texts[0].contains("目入文门"))
        XCTAssertTrue(texts[0].contains("⽬⼊⽂⻔"))
        XCTAssertTrue(texts[0].contains("fi😀"))
        for selection in [nil, [1, 0, 1]] as [[Int]?] {
            let output = directory.url.appendingPathComponent(selection == nil ? "all.pdf" : "ordered.pdf")
            XCTAssertTrue(try file.exportPDF(to: output, selectedPages: selection))
            let exported = try NativeFile(output, engine: .mupdf)
            let pdf = try XCTUnwrap(PDFDocument(url: output))
            let order = selection ?? [0, 1]
            XCTAssertEqual(exported.count, order.count)
            XCTAssertEqual(pdf.pageCount, order.count)
            for (index, original) in order.enumerated() {
                XCTAssertEqual(try exported.text(index), texts[original])
                XCTAssertTrue(pdf.page(at: index)?.string?.contains("目入文门") == true)
                XCTAssertTrue(pdf.page(at: index)?.string?.contains("⽬⼊⽂⻔") == true)
                XCTAssertTrue(pdf.page(at: index)?.string?.contains("fi😀") == true)
                XCTAssertEqual(try exported.bounds(index), try file.bounds(original))
                let input = try file.image(original, width: 480, transparent: true)
                let result = try exported.image(index, width: 480, transparent: true)
                XCTAssertEqual(result.width, input.width); XCTAssertEqual(result.height, input.height)
                XCTAssertEqual(result.dataProvider?.data as Data?, input.dataProvider?.data as Data?)
                XCTAssertTrue(try exported.pdfAnnotations(index).isEmpty)
            }
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.undoSteps, before.undoSteps)
        XCTAssertEqual(after.dirty, before.dirty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testExportFlattensLiveWidgetAndViewAppearancesWithoutCommittingUndo() throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("appearances.pdf")
        let bytes = appearanceFixture(); try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        try file.pdfSetWidgetValue(page: 0, id: 8, value: "UNSAVED VALUE")
        let before = try XCTUnwrap(file.pdfInfo())
        let input = try file.image(0, width: 480, transparent: true)
        for selection in [nil, [0, 0]] as [[Int]?] {
            let output = directory.url.appendingPathComponent(selection == nil ? "all.pdf" : "duplicates.pdf")
            XCTAssertTrue(try file.exportPDF(to: output, selectedPages: selection))
            let exported = try NativeFile(output, engine: .mupdf)
            for index in 0..<exported.count {
                XCTAssertTrue(try XCTUnwrap(exported.text(index)).contains("UNSAVED VALUE"))
                let kitPage = try XCTUnwrap(PDFDocument(url: output)?.page(at: index))
                XCTAssertTrue(try XCTUnwrap(kitPage.string).contains("UNSAVED VALUE"))
                XCTAssertTrue(kitPage.selection(for: kitPage.bounds(for: .mediaBox))?.string?.contains("UNSAVED VALUE") == true)
                let appearance = try XCTUnwrap(exported.pdfAnnotations(index).first)
                XCTAssertEqual(appearance.type, "Stamp")
                XCTAssertEqual(appearance.flags & (64 | 128 | 512), 64 | 128 | 512)
                XCTAssertNil(appearance.fieldName); XCTAssertNil(appearance.value)
                try exported.pdfSetEditing(true)
                XCTAssertThrowsError(try exported.pdfEditAnnotation(page: index, id: appearance.id, edits: [.contents("Cannot edit this static appearance")]))
                let result = try exported.image(index, width: 480, transparent: true)
                XCTAssertEqual(result.dataProvider?.data as Data?, input.dataProvider?.data as Data?)
            }
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertTrue(after.dirty)
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.undoSteps, before.undoSteps)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 8 }?.value, "UNSAVED VALUE")
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 8 }?.value, "Original")
        try file.pdfUndo(redo: true)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 8 }?.value, "UNSAVED VALUE")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testExportPreservesOriginalContentAfterExternalInPlaceWrite() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf"), output = directory.url.appendingPathComponent("existing.pdf")
        let original = unicodeFixture(); try original.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let pages = try Pages(source, format: .pdf)
        let reference = try (0..<file.count).map { try file.image($0, width: 480, transparent: true) }
        let writer = try FileHandle(forUpdating: source)
        defer { try? writer.close() }
        let position = try XCTUnwrap(original.range(of: Data("01020304".utf8))).lowerBound
        try writer.seek(toOffset: UInt64(position)); try writer.write(contentsOf: Data("05060708".utf8))
        let sentinel = Data("Keep existing output".utf8); try sentinel.write(to: output)
        XCTAssertTrue(try file.exportPDF(to: output))
        for direct in [true, false] {
            if !direct { try await pages.exportPDF(to: output) }
            let exported = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(exported.count, reference.count)
            for index in 0..<exported.count {
                let result = try exported.image(index, width: 480, transparent: true)
                XCTAssertEqual(result.dataProvider?.data as Data?, reference[index].dataProvider?.data as Data?)
            }
        }
        var replacement = original
        replacement.replaceSubrange(position..<(position + 8), with: Data("05060708".utf8))
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).contains { $0.hasPrefix(".Sumra-export-") })
    }

    func testExportLeavesUnreadAppearanceStateAndUndoEntryContentsIntact() throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        let original = appearanceFixture(); try original.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let before = directory.url.appendingPathComponent("before.pdf"), after = directory.url.appendingPathComponent("after.pdf")
        // The source has a widget value but no AP. Export may synthesize its
        // independent copy; it must leave the unread reader graph unchanged.
        try file.pdfWrite(to: before)
        XCTAssertTrue(try file.exportPDF(to: directory.url.appendingPathComponent("unread-export.pdf")))
        try file.pdfWrite(to: after)
        XCTAssertEqual(try Data(contentsOf: after), try Data(contentsOf: before))
        try file.pdfSetEditing(true)
        let annotation = try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 30, y: 40, width: 20, height: 20), edits: [.contents("First entry")])
        try file.pdfEditAnnotation(page: 0, id: annotation, edits: [.contents("Future entry")])
        try file.pdfUndo(redo: false)
        try file.pdfWrite(to: before)
        XCTAssertTrue(try file.exportPDF(to: directory.url.appendingPathComponent("edited-export.pdf")))
        try file.pdfWrite(to: after)
        XCTAssertEqual(try Data(contentsOf: after), try Data(contentsOf: before))
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == annotation }?.contents, "First entry")
        try file.pdfUndo(redo: true)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == annotation }?.contents, "Future entry")
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == annotation }?.contents, "First entry")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExportKeepsPageBlendingAndIgnoresInertContentStreamKeys() throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        // Page rendering isolates its contents and does not use a page's I/K
        // flags as a Form would. A Contents stream's OC/Group keys are inert.
        for (index, group) in ["", "/Group << /S /Transparency /CS /DeviceGray >>",
                               "/Group << /S /Transparency /CS /DeviceGray /I false /K true >>"].enumerated() {
            for polluted in [false, true] {
                let source = directory.url.appendingPathComponent("source-\(index)-\(polluted).pdf")
                let dictionary = polluted ? "/OC 6 0 R /Group << /S /Transparency /CS /DeviceGray /K true >> /StructParent 9" : ""
                try rawPDF([
                    "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [6 0 R] /D << /BaseState /OFF >> >> >>",
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] \(group) /Resources << /ExtGState << /G 4 0 R >> /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
                    "<< /Type /ExtGState /ca 0.5 /CA 0.5 /BM /Multiply >>",
                    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                    "<< /Type /OCG /Name (Off) >>",
                    stream("q /G gs 0 1 0 rg 20 20 90 90 re f 1 0 0 rg 60 60 90 90 re f Q BT /F1 16 Tf 20 140 Td (Retained text) Tj ET", dictionary: dictionary)
                ]).write(to: source)
                let file = try NativeFile(source, engine: .mupdf)
                let input = try file.image(0, width: 480, transparent: true)
                let output = directory.url.appendingPathComponent("output-\(index)-\(polluted).pdf")
                XCTAssertTrue(try file.exportPDF(to: output))
                let exported = try NativeFile(output, engine: .mupdf)
                XCTAssertEqual(try exported.text(0), try file.text(0))
                let result = try exported.image(0, width: 480, transparent: true)
                XCTAssertEqual(result.dataProvider?.data as Data?, input.dataProvider?.data as Data?, "group \(index), content dictionary \(polluted)")
            }
        }
        for (index, group) in ["", "/Group << /S /Transparency /CS /DeviceGray >>"].enumerated() {
            let source = directory.url.appendingPathComponent("overlapping-\(index).pdf")
            try rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] \(group) /Resources << /ExtGState << /G 4 0 R >> >> /Contents 5 0 R /Annots [6 0 R] >>",
                "<< /Type /ExtGState /ca 0.5 /CA 0.5 /BM /Multiply >>",
                stream("/G gs 0 1 0 rg 20 20 90 90 re f 1 0 0 rg 60 60 90 90 re f"),
                "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [40 40 140 140] /F 4 /AP << /N 7 0 R >> >>",
                stream("/G gs 0 0 1 rg 0 0 100 100 re f", dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /ExtGState << /G 4 0 R >> >>")
            ]).write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            let output = directory.url.appendingPathComponent("overlapping-output-\(index).pdf")
            XCTAssertTrue(try file.exportPDF(to: output))
            let exported = try NativeFile(output, engine: .mupdf)
            for transparent in [false, true] {
                let input = try file.image(0, width: 480, transparent: transparent)
                let result = try exported.image(0, width: 480, transparent: transparent)
                XCTAssertEqual(result.dataProvider?.data as Data?, input.dataProvider?.data as Data?, "overlapping AP, group \(index), transparent \(transparent)")
            }
        }
    }

    func testExportSynthesizedAppearanceOnPageWithoutResources() throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (field) /V (FORM VALUE) /Rect [20 20 200 60] /F 4 /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let input = try file.image(0, width: 480, transparent: true)
        let output = directory.url.appendingPathComponent("output.pdf")
        XCTAssertTrue(try file.exportPDF(to: output))
        let exported = try NativeFile(output, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(exported.text(0)).contains("FORM VALUE"))
        XCTAssertTrue(PDFDocument(url: output)?.page(at: 0)?.string?.contains("FORM VALUE") == true)
        let result = try exported.image(0, width: 480, transparent: true)
        XCTAssertEqual(result.dataProvider?.data as Data?, input.dataProvider?.data as Data?)
    }

    @MainActor
    func testPDFExportFollowsCopyPermissionAndLeavesPrintingIndependent() async throws {
        try requireEngine()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("source.pdf")
        try unicodeFixture().write(to: source)
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        XCTAssertFalse(ReaderMenuCommand.exportPDF.enabled(state))
        let protected = directory.url.appendingPathComponent("protected.pdf")
        try NativePDFTools.encrypt(source: source, destination: protected, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        for password in ["reader", "owner"] {
            let pages = try Pages(protected, format: .pdf, password: password)
            state.document = ReadingDocument(url: protected, content: .pages(pages))
            XCTAssertFalse(ReaderMenuCommand.exportPDF.enabled(state), "Wait for this document's own permissions")
            state.nativePDFInfo = try await pages.pdfInfo()
            XCTAssertTrue(ReaderMenuCommand.print.enabled(state))
            let allowed = password == "owner"
            XCTAssertEqual(ReaderMenuCommand.exportPDF.enabled(state), allowed)
            let output = directory.url.appendingPathComponent("\(password).pdf")
            let sentinel = Data("Keep existing output".utf8); try sentinel.write(to: output)
            if allowed {
                try await pages.exportPDF(to: output)
                let exported = try NativeFile(output, engine: .mupdf)
                XCTAssertTrue(try XCTUnwrap(exported.text(0)).contains("目入文门"))
            } else {
                do { try await pages.exportPDF(to: output); XCTFail("Copy-restricted export must fail") }
                catch { XCTAssertEqual(try Data(contentsOf: output), sentinel) }
            }
        }
        let svg = directory.url.appendingPathComponent("image.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'/>".utf8).write(to: svg)
        state.document = try ReadingDocument.open(svg)
        XCTAssertTrue(ReaderMenuCommand.exportPDF.enabled(state))
    }

    private func requireEngine() throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF engine is required")
        }
    }
    private func stream(_ value: String, dictionary: String = "") -> String {
        "<< /Length \(value.utf8.count) \(dictionary) >>\nstream\n\(value)\nendstream"
    }
    private func unicodeFixture() -> Data {
        // Two encoded character sequences share outlines but have different
        // authoritative Unicode. A font-cmap reverse lookup cannot recover it.
        rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 250 180] /CropBox [20 30 240 170] /Rotate 90 /UserUnit 2 /Resources << /Font << /F1 5 0 R >> >> /Contents [6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 /A /B /C /D /A /B /C /D /fi /A] >> /ToUnicode 8 0 R >>",
            stream("BT /F1 16 Tf 30 130 Td <01020304> Tj 0 -30 Td <05060708> Tj 0 -30 Td <090A> Tj ET"),
            stream("BT /F1 16 Tf 30 130 Td <05060708> Tj 0 -30 Td <01020304> Tj 0 -30 Td <090A> Tj ET"),
            stream("/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def /CMapName /Unicode def /CMapType 2 def 1 begincodespacerange <00> <FF> endcodespacerange 10 beginbfchar <01> <76EE> <02> <5165> <03> <6587> <04> <95E8> <05> <2F6C> <06> <2F0A> <07> <2F42> <08> <2ED4> <09> <00660069> <0A> <D83DDE00> endbfchar endcmap CMapName currentdict /CMap defineresource pop end end")
        ])
    }
    private func appearanceFixture() -> Data {
        rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [8 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 9 0 R >> >> >> /OCProperties << /OCGs [10 0 R 11 0 R] /D << /BaseState /ON /Order [10 0 R 11 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 250 180] /CropBox [20 30 240 170] /Rotate 90 /UserUnit 2 /Group << /S /Transparency /CS /DeviceGray /I true >> /Resources << /Properties << /V 10 0 R /P 11 0 R >> >> /Contents 4 0 R /Annots [5 0 R 6 0 R 7 0 R 8 0 R 12 0 R] >>",
            stream("/OC /V BDC 0 1 0 rg 30 130 20 20 re f EMC /OC /P BDC 1 0 0 rg 60 130 20 20 re f EMC"),
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [30 90 50 110] /F 16 /AP << /N 13 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [60 90 80 110] /F 36 /AP << /N 14 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [90 90 110 110] /F 6 /AP << /N 14 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (input) /V (Original) /Rect [30 40 210 70] /F 4 /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /OCG /Name (View) /Usage << /View << /ViewState /ON >> /Print << /PrintState /OFF >> >> >>",
            "<< /Type /OCG /Name (Print) /Usage << /View << /ViewState /OFF >> /Print << /PrintState /ON >> >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [120 90 140 110] /F 0 /OC 11 0 R /AP << /N 14 0 R >> >>",
            stream("0 0 1 rg 0 0 20 20 re f", dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >>"),
            stream("1 0 0 rg 0 0 20 20 re f", dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >>")
        ])
    }
    private func rawPDF(_ objects: [String]) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Root 1 0 R /Size \(offsets.count) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
#endif
