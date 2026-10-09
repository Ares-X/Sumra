#if os(macOS)
import AppKit
import CryptoKit
import PDFKit
import Security
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFToolsTests: XCTestCase {
    func testLivePDFDestinationExportPreservesUnspecifiedCoordinatesAndRemotePages() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("destination-coordinates.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(partial) << /D [3 0 R /XYZ null 290 null] >>] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /CropBox [20 30 180 270] /Rotate 90 /Resources << >> >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let named = try XCTUnwrap(file.pdfResolveDestination("#nameddest=partial", pdfCoordinates: true))
        XCTAssertEqual(named.page, 0)
        XCTAssertNil(named.x); XCTAssertNil(named.zoom)
        XCTAssertEqual(named.y, 290, "Export preserves raw PDF coordinates, including positions outside the CropBox")
        let remoteURI = "file:other.pdf#page=3&zoom=nan,nan,66"
        let remote = try XCTUnwrap(file.pdfResolveDestination(remoteURI, pdfCoordinates: true))
        XCTAssertEqual(remote.page, 2); XCTAssertNil(remote.x); XCTAssertNil(remote.zoom)
        XCTAssertEqual(remote.y, 66, "A remote destination does not use this document's rotation or CropBox")
        XCTAssertNil(try file.pdfResolveDestination(remoteURI), "The navigation API still treats remote links as external")
        XCTAssertNil(try file.pdfResolveDestination("file:other.pdf#nameddest=partial", pdfCoordinates: true),
                     "A remote named destination must not resolve against this document's name tree")
        XCTAssertNil(try file.pdfResolveDestination("https://example.org/", pdfCoordinates: true))
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
        XCTAssertFalse(after.editingEnabled)
    }

    func testLivePDFExportsMetadataAndAllAttachmentContainersWithoutChangingTheDocument() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("attachments-and-xmp.pdf")
        let xmp = "<?xpacket begin=''?><x:xmpmeta xmlns:x='adobe:ns:meta/'>原始 metadata</x:xmpmeta><?xpacket end='w'?>"
        func stream(_ value: String) -> String { "<< /Length \(value.utf8.count) >>\nstream\n\(value)\nendstream" }
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 11 0 R >> /AF [7 0 R] /Metadata 17 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /AF [9 0 R] /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [20 30 40 50] /FS 6 0 R >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [60 30 80 50] /FS 12 0 R >>",
            "<< /Type /Filespec /UF (../../shared.txt) /F (../../shared.txt) /Desc (Shared attachment) /EF << /UF 8 0 R /F 8 0 R >> >>",
            "<< /Type /Filespec /F (root.txt) /EF << /F 10 0 R >> >>",
            stream("shared"),
            "<< /Type /Filespec /UF (unicode.txt) /F (legacy.txt) /EF << /UF 13 0 R /F 14 0 R >> >>",
            stream("root"),
            "<< /Kids [15 0 R] >>",
            "<< /Type /Filespec /F (annotation.txt) /EF << /F 16 0 R >> >>",
            stream("unicode"), stream("legacy"), "<< /Names [(named) 6 0 R] >>", stream("annotation"), stream(xmp)
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(try file.pdfXMP(), Data(xmp.utf8))
        let attachments = try file.pdfAttachments()
        XCTAssertEqual(attachments.map(\.name), ["shared.txt", "root.txt", "unicode.txt", "legacy.txt", "annotation.txt"])
        XCTAssertEqual(attachments.map(\.data), ["shared", "root", "unicode", "legacy", "annotation"].map { Data($0.utf8) })
        XCTAssertEqual(attachments.first?.description, "Shared attachment")
        XCTAssertEqual(try file.pdfAttachment(page: 0, id: 4).name, attachments.first?.name)
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
        XCTAssertFalse(after.editingEnabled)
        let replacement = directory.appendingPathComponent("replacement.bin")
        try Data("unsaved replacement".utf8).write(to: replacement)
        try file.pdfSetEditing(true)
        try file.pdfEditAnnotation(page: 0, id: 5, edits: [.attachment(replacement, filename: "replacement.bin", mime: "application/octet-stream")])
        let changed = try file.pdfAttachments()
        XCTAssertFalse(changed.contains { $0.name == "annotation.txt" })
        XCTAssertEqual(changed.first { $0.name == "replacement.bin" }?.data, Data("unsaved replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: source), bytes, "Exports read the live edit without reopening or rewriting its source")
        let encrypted = directory.appendingPathComponent("no-copy.pdf")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        let restricted = try NativeFile(encrypted, engine: .mupdf, password: "reader")
        XCTAssertThrowsError(try restricted.pdfAttachments())
        XCTAssertEqual(try restricted.pdfXMP(), Data(xmp.utf8), "Metadata remains readable without content-copy permission")
    }

    func testSingleAttachmentKeepsMuPDFFilespecNameAndStreamSelection() throws {
        let directory = try fixtureDirectory()
        for (label, fields, expectedName, expectedData) in [
            ("unicode", "/UF (modern.bin) /F (legacy.bin) /EF << /UF 6 0 R /F 7 0 R >>", "modern.bin", "modern"),
            ("fallback", "/UF (modern.bin) /EF << /F 7 0 R >>", "modern.bin", "legacy"),
            ("platform-fallback", "/Unix (unix.bin) /EF << /Mac 7 0 R >>", "unix.bin", "legacy")
        ] {
            let source = directory.appendingPathComponent(label + ".pdf")
            try rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Annots [4 0 R] >>",
                "<< /Type /Annot /Subtype /FileAttachment /Rect [10 10 30 30] /FS 5 0 R >>",
                "<< /Type /Filespec \(fields) >>",
                "<< /Length 6 >>\nstream\nmodern\nendstream", "<< /Length 6 >>\nstream\nlegacy\nendstream"
            ]).write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            let attachment = try file.pdfAttachment(page: 0, id: 4)
            XCTAssertEqual(attachment.name, expectedName, label)
            XCTAssertEqual(attachment.data, Data(expectedData.utf8), label)
            XCTAssertEqual(try file.pdfInfo()?.dirty, false)
        }
    }

    func testSingleAttachmentRetainsMuPDFCompressionBombProtection() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Native/AttachmentCompressionLimit.pdf")
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        // A 144 MiB Flate stream exceeds MuPDF's existing relative compression threshold.
        XCTAssertThrowsError(try file.pdfAttachment(page: 0, id: 4)) { error in
            XCTAssertTrue(error.localizedDescription.contains("compression bomb"), error.localizedDescription)
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
    }


    @MainActor func testLivePDFStampImageCopyKeepsSoftMaskAndSeparateAnnotationOpacity() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("image-stamp.pdf")
        let appearance = "/GS gs /I Do\n", colors = "FF000000FF000000FFFFFF00>", mask = "FF0080FF>"
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [20 30 100 110] /CA 0.25 /F 4 /AP << /N 5 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /I 6 0 R >> /ExtGState << /GS << /ca 0.25 /CA 0.25 >> >> >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream",
            "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 7 0 R /Filter /ASCIIHexDecode /Length \(colors.utf8.count) >>\nstream\n\(colors)\nendstream",
            "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(mask.utf8.count) >>\nstream\n\(mask)\nendstream"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let png = try XCTUnwrap(file.pdfStampImage(page: 0, id: 4))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 2); XCTAssertEqual(image.pixelsHigh, 2)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 1, y: 0)).alphaComponent, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(image.colorAt(x: 0, y: 1)).alphaComponent, 128.0 / 255, accuracy: 0.001)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty, "Copying is allowed while editing is locked and must not journal an edit")
        let asset = directory.appendingPathComponent("copied.png"), target = directory.appendingPathComponent("target.pdf")
        try png.write(to: asset)
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>"
        ]).write(to: target)
        let destination = try NativeFile(target, engine: .mupdf)
        try destination.pdfSetEditing(true)
        let original = try XCTUnwrap(file.pdfAnnotations(0).first)
        let id = try destination.pdfPasteAnnotation(.init(page: 0, type: "Stamp", bounds: original.copyBounds,
                                                          edits: [.stampImage(asset), .opacity(original.opacity)]))
        XCTAssertEqual(try destination.pdfAnnotations(0).first { $0.id == id }?.copyBounds, original.copyBounds)
        func pixels(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }
        XCTAssertEqual(try pixels(file.image(0, width: 200)), try pixels(destination.image(0, width: 200)))
        for opacity: Float in [0, 1] {
            try destination.pdfEditAnnotation(page: 0, id: id, edits: [.opacity(opacity)])
            XCTAssertEqual(try destination.pdfStampImage(page: 0, id: id), png, "Annotation opacity must not be baked into the copied asset")
        }
        let saved = directory.appendingPathComponent("pasted.pdf")
        try destination.pdfWrite(to: saved)
        let reopened = try NativeFile(saved, engine: .mupdf)
        XCTAssertEqual(try reopened.pdfStampImage(page: 0, id: id), png)
        let protected = directory.appendingPathComponent("no-copy.pdf")
        try NativePDFTools.encrypt(source: source, destination: protected, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        let restricted = try NativeFile(protected, engine: .mupdf, password: "reader")
        XCTAssertThrowsError(try restricted.pdfStampImage(page: 0, id: 4))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFCustomVectorStampCopyAndOpacityDoNotSilentlyChangeArtwork() throws {
        let directory = try fixtureDirectory()
        for name in ["", "/Name /PublisherLogo"] {
            let source = directory.appendingPathComponent("vector-\(name.isEmpty).pdf"), commands = "0 0 1 rg 0 0 100 50 re f\n"
            try rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Annots [4 0 R 6 0 R] >>",
                "<< /Type /Annot /Subtype /Stamp /Rect [20 30 120 80] \(name) /AP << /N 5 0 R >> >>",
                "<< /Type /XObject /Subtype /Form /BBox [0 0 100 50] /Resources << >> /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream",
                "<< /Type /Annot /Subtype /Stamp /Rect [20 100 120 150] /Name /Draft >>"
            ]).write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            XCTAssertThrowsError(try file.pdfStampImage(page: 0, id: 4))
            XCTAssertNil(try file.pdfStampImage(page: 0, id: 6), "A standard text stamp is recreated by its name")
            let image = try file.image(0, width: 200), pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            try file.pdfSetEditing(true)
            let before = try XCTUnwrap(file.pdfInfo())
            XCTAssertThrowsError(try file.pdfEditAnnotation(page: 0, id: 4, edits: [.opacity(0.4)]))
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).dirty, before.dirty)
            XCTAssertEqual(try XCTUnwrap(file.image(0, width: 200).dataProvider?.data) as Data, pixels)
        }
    }

    func testLivePDFPolylineEndsAndCutPastePreserveGeometryAndOneUndo() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("cut.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [5 0 R 6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> >>",
            "<< /Type /Annot /Subtype /PolyLine /Rect [20 20 120 120] /Vertices [20 20 120 40 40 120] /LE [/None /None] >>",
            "<< /Type /Annot /Subtype /Square /Rect [30 150 120 210] /Contents (locked) /F 128 >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        let original = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == 5 })
        try file.pdfEditAnnotation(page: 0, id: 5, edits: [.lineEnds(start: 3, end: 5)])
        let changed = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == 5 })
        XCTAssertEqual(changed.lineEnds, [3, 5])
        XCTAssertEqual(changed.vertices, original.vertices)
        XCTAssertTrue(changed.line.isEmpty)
        let item = PDFAnnotationCreation(page: 1, type: "PolyLine", bounds: changed.copyBounds,
                                         edits: [.vertices(changed.vertices.map { CGPoint(x: $0[0], y: $0[1]) }), .lineEnds(start: 3, end: 5)])
        let before = try XCTUnwrap(file.pdfInfo())
        XCTAssertThrowsError(try file.pdfPasteAnnotation(item, removing: (0, 6)))
        XCTAssertTrue(try file.pdfAnnotations(1).isEmpty, "Failed source deletion must roll back the new annotation")
        XCTAssertEqual(try file.pdfAnnotations(0).map(\.id), [5, 6])
        let id = try file.pdfPasteAnnotation(item, removing: (0, 5))
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition + 1)
        XCTAssertFalse(try file.pdfAnnotations(0).contains { $0.id == 5 })
        XCTAssertEqual(try file.pdfAnnotations(1).first?.id, id)
        XCTAssertEqual(try file.pdfAnnotations(1).first?.vertices, original.vertices)
        XCTAssertEqual(try file.pdfAnnotations(1).first?.lineEnds, [3, 5])
        try file.pdfUndo(redo: false)
        XCTAssertTrue(try file.pdfAnnotations(1).isEmpty)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 5 }?.lineEnds, [3, 5])
        let square = try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 30, y: 100, width: 80, height: 60),
                                                 edits: [.border(width: 8, style: 0, dash: [])])
        let initial = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == square })
        var copy = initial
        for _ in 0..<3 {
            let newID = try file.pdfPasteAnnotation(.init(page: 1, type: "Square", bounds: copy.copyBounds,
                                                        edits: [.border(width: copy.borderWidth, style: copy.borderStyle, dash: copy.dash)]))
            copy = try XCTUnwrap(file.pdfAnnotations(1).first { $0.id == newID })
            XCTAssertEqual(copy.copyBounds, initial.copyBounds, "Copying must not repeatedly add the border expansion")
            XCTAssertEqual(copy.bounds, initial.bounds)
        }
    }

    func testNativePageExtractionUsesCurrentCopyAndUpstreamSubsetPolicy() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("extract-source.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 12 0 R >> >> >> /Names << /JavaScript << /Names [(ShowMenu) 9 0 R] >> >> /Outlines 10 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Annots [6 0 R 7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Annots [8 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (field) /V (value) /Rect [10 10 190 40] /P 4 0 R >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 60 100 90] /Dest [5 0 R /Fit] >>",
            "<< /Type /Annot /Subtype /Square /Rect [20 20 80 80] /Contents (original note) >>",
            "<< /S /JavaScript /JS (function ShowMenu\\(\\) { app.popUpMenu\\(\"Item\"\\); }) >>",
            "<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>",
            "<< /Title (Marked page) /Parent 10 0 R /Dest [5 0 R /Fit] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        try bytes.write(to: source)
        let live = try NativeFile(source, engine: .mupdf)
        try live.pdfSetEditing(true)
        try live.pdfEditAnnotation(page: 2, id: 8, edits: [.contents("unsaved note")])
        let snapshot = directory.appendingPathComponent("current.pdf"), output = directory.appendingPathComponent("extracted.pdf")
        try live.pdfWrite(to: snapshot)
        let before = try XCTUnwrap(live.pdfInfo())
        try NativePDFTools.selectPages(source: snapshot, destination: output, pages: [2, 1])
        let result = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try result.bounds(0)?.size, CGSize(width: 300, height: 300))
        XCTAssertEqual(try result.bounds(1)?.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(try result.pdfAnnotations(0).first { $0.type == "Square" }?.contents, "unsaved note")
        XCTAssertEqual(try result.pdfLinks(1).first?.actions.first?.destination?.page, 0)
        XCTAssertEqual(try result.outline().first?.page, 0)
        let catalogDocument = try XCTUnwrap(CGPDFDocument(output as CFURL))
        defer { withExtendedLifetime(catalogDocument) {} }
        let catalog = try XCTUnwrap(catalogDocument.catalog)
        var acroForm: CGPDFDictionaryRef?
        XCTAssertFalse(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), "pdfclean's subset policy does not preserve the AcroForm catalog")
        XCTAssertEqual(try result.pdfJavaScriptMenu("ShowMenu();"), [], "Document-level scripts are not retained by pdfclean")
        let marked = directory.appendingPathComponent("marked-only.pdf")
        try NativePDFTools.selectPages(source: snapshot, destination: marked, pages: [0, 1, 2], annotationsOnly: true)
        let markedResult = try NativeFile(marked, engine: .mupdf)
        XCTAssertEqual(markedResult.count, 1, "Links and widgets do not count as user annotations")
        XCTAssertEqual(try markedResult.pdfAnnotations(0).first?.contents, "unsaved note")
        let existingOutput = try Data(contentsOf: output)
        XCTAssertThrowsError(try NativePDFTools.selectPages(source: snapshot, destination: output, pages: [3]))
        XCTAssertEqual(try Data(contentsOf: output), existingOutput)
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoPosition, before.undoPosition)
        XCTAssertTrue(try XCTUnwrap(live.pdfInfo()).dirty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let encrypted = directory.appendingPathComponent("no-copy.pdf")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        XCTAssertThrowsError(try NativePDFTools.selectPages(source: encrypted, destination: output, pages: [0], password: "reader"))
        XCTAssertEqual(try Data(contentsOf: output), existingOutput)
    }

    func testNativeMergePreservesPageContentExternalLinksAndNestedOutlineOffsets() throws {
        let directory = try fixtureDirectory()
        func book(_ name: String) -> Data {
            let commands = "BT /F1 12 Tf 20 40 Td (\(name) page body) Tj ET\n"
            return rawPDF([
                "<< /Type /Catalog /Pages 2 0 R /Outlines 8 0 R >>",
                "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /Rotate 90 /Resources << /Font << /F1 12 0 R >> >> /Contents 13 0 R /Annots [5 0 R 6 0 R 7 0 R] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>",
                "<< /Type /Annot /Subtype /Link /Rect [20 100 100 140] /A << /S /URI /URI (https://example.org/\(name)) >> >>",
                "<< /Type /Annot /Subtype /Link /Rect [20 160 100 200] /Dest [4 0 R /Fit] >>",
                "<< /Type /Annot /Subtype /Square /Rect [20 250 100 300] /Contents (Not grafted) >>",
                "<< /Type /Outlines /First 9 0 R /Last 11 0 R /Count 3 >>",
                "<< /Title (\(name) group) /Parent 8 0 R /First 10 0 R /Last 10 0 R /Count 1 /Next 11 0 R >>",
                "<< /Title (\(name) child) /Parent 9 0 R /Dest [4 0 R /Fit] >>",
                "<< /Title (\(name) start) /Parent 8 0 R /Prev 9 0 R /Dest [3 0 R /Fit] >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream"
            ])
        }
        let a = directory.appendingPathComponent("a.pdf"), b = directory.appendingPathComponent("b.pdf")
        let aBytes = book("A"), bBytes = book("B")
        try aBytes.write(to: a); try bBytes.write(to: b)
        let output = directory.appendingPathComponent("merged.pdf")
        try NativePDFTools.merge(sources: [(a, ""), (b, "")], destination: output)
        let merged = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(merged.count, 4)
        XCTAssertTrue(try merged.text(0)?.contains("A page body") == true)
        XCTAssertTrue(try merged.text(2)?.contains("B page body") == true)
        for (index, source) in [(0, a), (2, b)] {
            let original = try NativeFile(source, engine: .mupdf)
            let external = try XCTUnwrap(original.pdfLinks(0).first { $0.actions.first?.kind == "URI" })
            let links = try merged.pdfLinks(index)
            XCTAssertEqual(links.count, 1, "pdfmerge copies external links, not internal links")
            XCTAssertEqual(links.first?.bounds, external.bounds)
            XCTAssertEqual(links.first?.actions.first?.uri, external.actions.first?.uri)
            XCTAssertTrue(try merged.pdfAnnotations(index).isEmpty, "pdfmerge does not graft other annotations or fields")
        }
        let outline = try merged.outline()
        XCTAssertEqual(outline.map(\.title), ["A group", "A child", "A start", "B group", "B child", "B start"])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 0, 0, 1, 0])
        XCTAssertEqual(outline.map(\.page), [1, 1, 0, 3, 3, 2])
        let existingOutput = try Data(contentsOf: output)
        XCTAssertThrowsError(try NativePDFTools.merge(sources: [(a, ""), (directory.appendingPathComponent("missing.pdf"), "")], destination: output))
        XCTAssertEqual(try Data(contentsOf: output), existingOutput, "An unreadable source must not silently produce a partial merge")
        XCTAssertThrowsError(try NativePDFTools.merge(sources: [(a, ""), (b, "")], destination: b))
        XCTAssertEqual(try Data(contentsOf: a), aBytes)
        XCTAssertEqual(try Data(contentsOf: b), bBytes)
    }

    func testLivePDFFreeTextKeepsPublisherFontWhenChangingSizeColorAndAlignment() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("fonts.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [20 200 240 260] /Contents (Styled text) /DA (/Helv 12 Tf 0 g) /DS (font-family:'Georgia',serif;font-weight:700;font-style:oblique;text-decoration:underline) >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [20 100 240 160] /Contents (Shorthand) /DA (/Helv 12 Tf 0 g) /DS (font:italic bold 12pt 'Times New Roman',serif) >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let original = try file.pdfAnnotations(0)
        XCTAssertEqual(original.first { $0.id == 4 }?.fontFamily, "Georgia")
        XCTAssertEqual(original.first { $0.id == 4 }?.fontStyle, 7)
        XCTAssertEqual(original.first { $0.id == 5 }?.fontFamily, "Times New Roman")
        XCTAssertEqual(original.first { $0.id == 5 }?.fontStyle, 3)
        try file.pdfSetEditing(true)
        try file.pdfEditAnnotation(page: 0, id: 4, edits: [.textAppearance(font: "Helv", size: 18, color: SIMD3(0, 0, 1), alignment: 2)])
        let changed = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == 4 })
        XCTAssertEqual(changed.fontFamily, "Georgia")
        XCTAssertEqual(changed.fontStyle, 7)
        XCTAssertEqual(changed.fontSize, 18)
        XCTAssertEqual(changed.alignment, 2)
        let copy = directory.appendingPathComponent("styled-copy.pdf")
        try file.pdfWrite(to: copy)
        let reopened = try XCTUnwrap(NativeFile(copy, engine: .mupdf).pdfAnnotations(0).first { $0.id == 4 })
        XCTAssertEqual(reopened.fontFamily, "Georgia")
        XCTAssertEqual(reopened.fontStyle, 7)
        XCTAssertEqual(reopened.fontSize, 18)
        try file.pdfEditAnnotation(page: 0, id: 4, edits: [.textStyle(family: "Courier", style: 0)])
        let plain = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == 4 })
        XCTAssertEqual(plain.font, "Cour")
        XCTAssertEqual(plain.fontFamily, "Courier")
        XCTAssertEqual(plain.fontStyle, 0)
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 4 }?.fontStyle, 7)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 4 }?.fontFamily, "Georgia")
    }

    func testLivePDFLinksUsePageCoordinatesAndPreserveActionsWhenMoved() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("links.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /Rotate 90 /Resources << >> /Annots [4 0 R 5 0 R 6 0 R 7 0 R 8 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 100 100 140] /A << /S /URI /URI (https://example.org/original) /Next << /S /JavaScript /JS (app.alert\\(\"next\"\\);) >> >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 200 100 240] /Dest [3 0 R /Fit] >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 250 100 290] /A << /S /JavaScript /JS (app.alert\\(\"only\"\\);) >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 300 100 340] /F 128 /A << /S /URI /URI (https://example.org/locked) >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [120 200 200 240] /A << /S /ResetForm /Fields [(Name)] /Flags 1 /Next << /S /JavaScript /JS (app.alert\\(\"reset\"\\);) >> >> >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let box = CGRect(x: 40, y: 50, width: 100, height: 30)
        XCTAssertThrowsError(try file.pdfCreateLink(page: 0, bounds: box, uri: "https://example.org/new"))
        try file.pdfSetEditing(true)
        let id = try file.pdfCreateLink(page: 0, bounds: box, uri: "https://example.org/new")
        XCTAssertEqual(try file.pdfLinks(0).first { $0.id == id }?.bounds, box)
        let moved = box.offsetBy(dx: 30, dy: 40)
        try file.pdfEditLink(page: 0, id: 4, bounds: moved, uri: nil)
        let original = try XCTUnwrap(file.pdfLinks(0).first { $0.id == 4 })
        XCTAssertEqual(original.bounds, moved)
        XCTAssertEqual(original.actions.map(\.kind), ["URI", "JavaScript"])
        try file.pdfEditLink(page: 0, id: 5, bounds: box, uri: "https://example.org/retargeted")
        let retargeted = try XCTUnwrap(file.pdfLinks(0).first { $0.id == 5 })
        XCTAssertEqual(retargeted.actions.map(\.kind), ["URI"], "An old /Dest must not override the new /A")
        XCTAssertEqual(retargeted.actions.first?.uri, "https://example.org/retargeted")
        for actionID: Int32 in [6, 8] {
            let original = try XCTUnwrap(file.pdfLinks(0).first { $0.id == actionID })
            XCTAssertNil(original.actions.first?.uri)
            try file.pdfEditLink(page: 0, id: actionID, bounds: moved, uri: nil)
            let edited = try XCTUnwrap(file.pdfLinks(0).first { $0.id == actionID })
            XCTAssertEqual(edited.bounds, moved)
            XCTAssertEqual(edited.actions.map(\.kind), original.actions.map(\.kind))
            XCTAssertEqual(edited.actions.map(\.javascript), original.actions.map(\.javascript))
            XCTAssertEqual(edited.actions.map(\.fields), original.actions.map(\.fields))
            XCTAssertEqual(edited.actions.map(\.flags), original.actions.map(\.flags))
            try file.pdfUndo(redo: false)
            XCTAssertEqual(try file.pdfLinks(0).first { $0.id == actionID }?.bounds, original.bounds)
            try file.pdfUndo(redo: true)
        }
        let before = try XCTUnwrap(file.pdfInfo())
        XCTAssertThrowsError(try file.pdfEditLink(page: 0, id: 7, bounds: box, uri: "https://example.org/changed"))
        XCTAssertThrowsError(try file.pdfDeleteLink(page: 0, id: 7))
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
        try file.pdfDeleteLink(page: 0, id: 6)
        XCTAssertFalse(try file.pdfLinks(0).contains { $0.id == 6 }, "JavaScript-only links must also be deletable")
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfLinks(0).first { $0.id == 6 }?.actions.first?.kind, "JavaScript")
        try file.pdfDeleteLink(page: 0, id: id)
        XCTAssertFalse(try file.pdfLinks(0).contains { $0.id == id })
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfLinks(0).first { $0.id == id }?.bounds, box)
        let copy = directory.appendingPathComponent("links-copy.pdf")
        try file.pdfWrite(to: copy)
        let reopened = try NativeFile(copy, engine: .mupdf)
        XCTAssertEqual(try reopened.pdfLinks(0).first { $0.id == 4 }?.bounds, moved)
        XCTAssertEqual(try reopened.pdfLinks(0).first { $0.id == 4 }?.actions.map(\.kind), ["URI", "JavaScript"])
        XCTAssertEqual(try reopened.pdfLinks(0).first { $0.id == 6 }?.bounds, moved)
        let reset = try XCTUnwrap(reopened.pdfLinks(0).first { $0.id == 8 })
        XCTAssertEqual(reset.bounds, moved)
        XCTAssertEqual(reset.actions.map(\.kind), ["ResetForm", "JavaScript"])
        XCTAssertEqual(reset.actions.first?.fields, ["Name"])
        XCTAssertEqual(reset.actions.first?.flags, 1)
        XCTAssertEqual(reset.actions.last?.javascript, "app.alert(\"reset\");")
    }

    func testLivePDFBatchMarkupAndInkErasingAreSingleUndoOperations() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("batch.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        let box = CGRect(x: 20, y: 40, width: 100, height: 20)
        let quad = PDFAnnotationEdit.Quad(upperLeft: box.origin, upperRight: CGPoint(x: box.maxX, y: box.minY),
                                          lowerLeft: CGPoint(x: box.minX, y: box.maxY), lowerRight: CGPoint(x: box.maxX, y: box.maxY))
        let ids = try file.pdfCreateAnnotations([0, 1].map {
            PDFAnnotationCreation(page: $0, type: "Highlight", bounds: box, edits: [.quads([quad])])
        })
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, 1)
        try file.pdfUndo(redo: false)
        XCTAssertTrue(try file.pdfAnnotations(0).isEmpty)
        XCTAssertTrue(try file.pdfAnnotations(1).isEmpty)
        try file.pdfUndo(redo: true)
        XCTAssertEqual(try file.pdfAnnotations(0).first?.id, ids[0])
        XCTAssertEqual(try file.pdfAnnotations(1).first?.id, ids[1])
        let stroke = [CGPoint(x: 20, y: 80), CGPoint(x: 120, y: 100)]
        let other = [CGPoint(x: 20, y: 110), CGPoint(x: 120, y: 130)]
        let ink = try file.pdfCreateAnnotations([
            .init(page: 0, type: "Ink", bounds: box, edits: [.ink([stroke, other])]),
            .init(page: 0, type: "Ink", bounds: box, edits: [.ink([stroke])])
        ])
        let before = try XCTUnwrap(file.pdfInfo())
        try file.pdfEraseInk(page: 0, edits: [.init(id: ink[0], strokes: [other]), .init(id: ink[1], strokes: [])])
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition + 1)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == ink[0] }?.ink.count, 1)
        XCTAssertFalse(try file.pdfAnnotations(0).contains { $0.id == ink[1] })
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == ink[0] }?.ink.count, 2)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == ink[1] }?.ink.count, 1)
        XCTAssertThrowsError(try file.pdfCreateAnnotations([
            .init(page: 0, type: "Square", bounds: box, edits: []), .init(page: 9, type: "Square", bounds: box, edits: [])
        ]))
        XCTAssertEqual(try file.pdfAnnotations(0).map(\.id), [ids[0], ink[0], ink[1]])
    }

    func testLivePDFMovingVectorAnnotationsTranslatesTheirGeometry() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("geometry.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /Rotate 90 /Resources << >> >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        let quad = PDFAnnotationEdit.Quad(upperLeft: CGPoint(x: 30, y: 40), upperRight: CGPoint(x: 100, y: 40),
                                          lowerLeft: CGPoint(x: 30, y: 60), lowerRight: CGPoint(x: 100, y: 60))
        let box = CGRect(x: 20, y: 30, width: 100, height: 60)
        let items: [(String, PDFAnnotationEdit)] = [
            ("Line", .line(from: CGPoint(x: 110, y: 30), to: CGPoint(x: 20, y: 90), start: 0, end: 0)),
            ("Polygon", .vertices([CGPoint(x: 20, y: 30), CGPoint(x: 110, y: 50), CGPoint(x: 40, y: 90)])),
            ("Ink", .ink([[CGPoint(x: 20, y: 30), CGPoint(x: 110, y: 90)]])),
            ("Redact", .quads([quad]))
        ]
        for (type, edit) in items {
            let id = try file.pdfCreateAnnotation(page: 0, type: type, bounds: box, edits: [edit])
            let before = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == id })
            func points(_ value: PDFAnnotationSnapshot) -> [[Double]] {
                value.line + value.vertices + value.quads.flatMap { $0 } + value.ink.flatMap { $0 }
            }
            let originalPoints = points(before)
            XCTAssertFalse(originalPoints.isEmpty)
            try file.pdfEditAnnotation(page: 0, id: id, edits: [.rect(before.bounds.offsetBy(dx: 15, dy: -10))])
            let translated = points(try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == id }))
            XCTAssertEqual(translated.count, originalPoints.count)
            for (actual, original) in zip(translated, originalPoints) {
                XCTAssertEqual(actual[0], original[0] + 15, accuracy: 0.001, type)
                XCTAssertEqual(actual[1], original[1] - 10, accuracy: 0.001, type)
            }
            try file.pdfUndo(redo: false)
            XCTAssertEqual(points(try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == id })), originalPoints)
        }
    }

    func testLivePDFSnapshotsKeepRedoAndPreserveOriginalActionsAcrossRepeatedWrites() throws {
        let directory = try fixtureDirectory()
        for stream in [false, true] {
            let source = directory.appendingPathComponent("source-\(stream).pdf")
            let bytes = rawPDF([
                "<< /Type /Catalog /Pages 2 0 R /Names << /JavaScript << /Names [(ShowCompProps_R1) 8 0 R] >> >> >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [4 0 R 5 0 R 9 0 R] >>",
                "<< /Type /Annot /Subtype /Square /Rect [10 20 80 60] /Contents (original) >>",
                "<< /Type /Annot /Subtype /Link /Rect [20 300 180 320] /A << /S /GoTo /D [3 0 R /XYZ 20 300 1.25] /Next [6 0 R 7 0 R] >> >>",
                "<< /S /JavaScript /JS (ShowCompProps_R1\\(\\);) >>",
                "<< /S /URI /URI (https://example.org/next) >>",
                "<< /S /JavaScript /JS (app.popUpMenu\\(\"R1\", \"URL: https://example.org/component\"\\);) >>",
                "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (details) /Rect [20 240 120 280] /AA << /U << /S /URI /URI (https://example.org/button) >> >> >>"
            ], xrefStream: stream)
            try bytes.write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            try file.pdfSetEditing(true)
            try file.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("first")])
            try file.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("future")])
            try file.pdfUndo(redo: false)
            let before = try XCTUnwrap(file.pdfInfo())
            XCTAssertEqual(before.undoPosition, 1)
            XCTAssertEqual(before.undoSteps, 2)
            let first = directory.appendingPathComponent("first-\(stream).pdf")
            let second = directory.appendingPathComponent("second-\(stream).pdf")
            XCTAssertFalse(try file.pdfWrite(to: first))
            XCTAssertFalse(try file.pdfWrite(to: second))
            XCTAssertTrue(try Data(contentsOf: first).starts(with: bytes), "Incremental snapshots retain the exact source bytes")
            XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second), "Writing a copy must not grow the live object table")
            let after = try XCTUnwrap(file.pdfInfo())
            XCTAssertEqual(after.undoPosition, before.undoPosition)
            XCTAssertEqual(after.undoSteps, before.undoSteps)
            XCTAssertEqual(after.redoTitle, before.redoTitle)
            XCTAssertTrue(after.dirty)
            for saved in [first, second] {
                let reopened = try NativeFile(saved, engine: .mupdf)
                XCTAssertEqual(try reopened.pdfAnnotations(0).first { $0.id == 4 }?.contents, "first")
                let links = try reopened.pdfLinks(0)
                let actions = try XCTUnwrap(links.first { $0.id == 5 }).actions
                XCTAssertEqual(actions.map(\.kind), ["GoTo", "JavaScript", "URI"])
                XCTAssertEqual(actions.map(\.index), [0, 1, 2])
                XCTAssertEqual(actions.first?.destination?.page, 0)
                XCTAssertEqual(actions.last?.uri, "https://example.org/next")
                XCTAssertEqual(links.first { $0.id == 9 }?.actions.first?.uri, "https://example.org/button")
                XCTAssertEqual(try reopened.pdfJavaScriptMenu(try XCTUnwrap(actions[1].javascript)), ["R1", "URL: https://example.org/component"])
            }
            try file.pdfUndo(redo: true)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 4 }?.contents, "future")
            XCTAssertFalse(try file.pdfWrite(to: second))
            try file.pdfMarkSaved()
            XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
            try file.pdfUndo(redo: false)
            XCTAssertThrowsError(try file.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("partial"), .opacity(-1)]))
            try file.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("different branch")])
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, 2)
            XCTAssertTrue(try XCTUnwrap(file.pdfInfo()).dirty, "The discarded saved branch must not match a reused journal index")
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testLivePDFSnapshotOpenFailureLeavesTheDocumentEditable() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("failure.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Square /Rect [10 10 90 90] /Contents (original) >>"
        ], xrefStream: true).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        try file.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("first")])
        let before = try XCTUnwrap(file.pdfInfo())
        XCTAssertThrowsError(try file.pdfWrite(to: directory.appendingPathComponent("missing/output.pdf")))
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, before.undoSteps)
        try file.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("after failure")])
        let output = directory.appendingPathComponent("retry.pdf")
        XCTAssertFalse(try file.pdfWrite(to: output))
        XCTAssertEqual(try NativeFile(output, engine: .mupdf).pdfAnnotations(0).first?.contents, "after failure")
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first?.contents, "first")
    }

    func testLivePDFRepairedCopiesKeepFormsEncryptionAndFurtherEdits() throws {
        let directory = try fixtureDirectory(), input = directory.appendingPathComponent("input.pdf")
        try scriptedFormPDF().write(to: input)
        for encrypted in [false, true] {
            let protected = directory.appendingPathComponent("protected.pdf")
            if encrypted { try NativePDFTools.encrypt(source: input, destination: protected, ownerPassword: "owner", userPassword: "") }
            let source = directory.appendingPathComponent("repaired-\(encrypted).pdf")
            // Repair runs before caller authentication in the pinned MuPDF.
            // An empty user password lets that repair decode encrypted ObjStm;
            // the nonempty owner password still tests AES/owner preservation.
            // Nonempty reader passwords are covered by the incremental tests.
            // No test-only native state mutation is used here.
            try NativePDFTools.transform(source: encrypted ? protected : input, destination: source,
                                         operation: .compress, password: encrypted ? "owner" : "")
            var original = try Data(contentsOf: source)
            XCTAssertTrue(latin1(original).contains("/ObjStm"))
            let marker = try XCTUnwrap(original.range(of: Data("startxref\n".utf8), options: .backwards))
            original.replaceSubrange(marker.upperBound..<original.endIndex, with: Data("0\n%%EOF\n".utf8))
            try original.write(to: source)
            let file = try NativeFile(source, engine: .mupdf, password: encrypted ? "owner" : nil)
            try file.pdfSetEditing(true)
            let inputID = try XCTUnwrap(file.pdfAnnotations(0).first { $0.fieldName == "input" }).id
            try file.pdfSetWidgetValue(page: 0, id: inputID, value: "7")
            let before = try XCTUnwrap(file.pdfInfo())
            XCTAssertThrowsError(try file.pdfWrite(to: directory.appendingPathComponent("missing/output.pdf")))
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, before.undoSteps)
            XCTAssertTrue(try XCTUnwrap(file.pdfInfo()).dirty)
            // An output-open failure must not leave save_in_progress set and
            // silently bypass journaling on the next edit.
            try file.pdfSetWidgetValue(page: 0, id: inputID, value: "8")
            try file.pdfUndo(redo: false)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "7")
            let withRedo = try XCTUnwrap(file.pdfInfo())
            XCTAssertThrowsError(try file.pdfWrite(to: directory.appendingPathComponent("missing/with-redo.pdf")))
            let failed = try XCTUnwrap(file.pdfInfo())
            XCTAssertEqual(failed.undoPosition, withRedo.undoPosition)
            XCTAssertEqual(failed.undoSteps, withRedo.undoSteps)
            XCTAssertEqual(failed.redoTitle, withRedo.redoTitle)
            try file.pdfUndo(redo: true)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "8")
            try file.pdfUndo(redo: false)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "7")
            let first = directory.appendingPathComponent("full-\(encrypted).pdf")
            XCTAssertTrue(try file.pdfWrite(to: first), "A repaired source needs the full writer")
            let repeated = directory.appendingPathComponent("repeated-full-\(encrypted).pdf")
            XCTAssertTrue(try file.pdfWrite(to: repeated))
            XCTAssertTrue(try XCTUnwrap(file.pdfInfo()).dirty, "Save Copy must not mark the source clean")
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, withRedo.undoSteps)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).redoTitle, withRedo.redoTitle)
            let repeatedCopy = try NativeFile(repeated, engine: .mupdf, password: nil)
            XCTAssertEqual(try repeatedCopy.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "7")
            XCTAssertEqual(try repeatedCopy.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "15")
            try file.pdfUndo(redo: true)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "8")
            try file.pdfUndo(redo: false)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "7")
            if encrypted {
                let reader = try NativeFile(first, engine: .mupdf)
                XCTAssertFalse(try XCTUnwrap(reader.pdfInfo()).ownerAuthenticated)
                XCTAssertEqual(try reader.metadata()["encryption"], try file.metadata()["encryption"])
                XCTAssertTrue(try XCTUnwrap(reader.metadata()["encryption"]).contains("AES"))
                XCTAssertThrowsError(try NativeFile(first, engine: .mupdf, password: "wrong")) { XCTAssertTrue($0 is PasswordRequired) }
            }
            let firstCopy = try NativeFile(first, engine: .mupdf, password: encrypted ? "owner" : nil)
            let copiedInput = try XCTUnwrap(firstCopy.pdfAnnotations(0).first { $0.fieldName == "input" })
            XCTAssertEqual(copiedInput.value, "7")
            XCTAssertEqual(try firstCopy.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "15")
            try firstCopy.pdfSetEditing(true)
            XCTAssertThrowsError(try firstCopy.pdfSetWidgetValue(page: 0, id: copiedInput.id, value: "-1"), "The copied validation action must still run")
            try firstCopy.pdfSetWidgetValue(page: 0, id: copiedInput.id, value: "9")
            XCTAssertEqual(try firstCopy.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "19", "The copied document-level script and calculation order survive full writing")
            // Save Copy leaves the original document live. A later edit and a
            // second full write must include both the old and new xref data.
            try file.pdfSetWidgetValue(page: 0, id: inputID, value: "10")
            let edited = try XCTUnwrap(file.pdfInfo())
            let second = directory.appendingPathComponent("second-full-\(encrypted).pdf")
            XCTAssertTrue(try file.pdfWrite(to: second))
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, edited.undoPosition)
            XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, edited.undoSteps)
            let reopened = try NativeFile(second, engine: .mupdf, password: nil)
            XCTAssertEqual(try reopened.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "10")
            XCTAssertEqual(try reopened.pdfAnnotations(0).first { $0.fieldName == "total" }?.value,
                           try file.pdfAnnotations(0).first { $0.fieldName == "total" }?.value)
            try file.pdfUndo(redo: false)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "7")
            try file.pdfUndo(redo: true)
            XCTAssertEqual(try file.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "10")
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testLivePDFAttachmentReadUsesCurrentFileSpecAndCopyPermissionWhileEditingIsLocked() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("attachment.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [10 10 30 30] /FS 6 0 R >>",
            "<< /Type /Annot /Subtype /Square /Rect [40 10 60 30] >>",
            "<< /Type /Filespec /UF (folder/payload.bin) /Desc (Publisher data) /EF << /UF 7 0 R >> >>",
            "<< /Type /EmbeddedFile /Filter /ASCIIHexDecode /Length 13 >>\nstream\n00017F80FEFF>\nendstream"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).editingEnabled)
        let attachment = try file.pdfAttachment(page: 0, id: 4)
        XCTAssertEqual(attachment.name, "payload.bin")
        XCTAssertEqual(attachment.description, "Publisher data")
        XCTAssertEqual(attachment.data, Data([0, 1, 127, 128, 254, 255]))
        XCTAssertThrowsError(try file.pdfAttachment(page: 0, id: 5))
        XCTAssertThrowsError(try file.pdfAttachment(page: 0, id: 999))
        let replacement = directory.appendingPathComponent("replacement.bin"), changed = Data([9, 8, 7])
        try changed.write(to: replacement)
        try file.pdfSetEditing(true)
        try file.pdfEditAnnotation(page: 0, id: 4, edits: [.attachment(replacement, filename: "new.bin", mime: "application/octet-stream")])
        try file.pdfSetEditing(false)
        XCTAssertEqual(try file.pdfAttachment(page: 0, id: 4).data, changed, "Read the unsaved live filespec, not the source file")
        XCTAssertEqual(try file.pdfAttachment(page: 0, id: 4).name, "new.bin")
        let protected = directory.appendingPathComponent("protected.pdf")
        try NativePDFTools.encrypt(source: source, destination: protected, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        let reader = try NativeFile(protected, engine: .mupdf, password: "reader")
        XCTAssertFalse(try XCTUnwrap(reader.pdfInfo()).permissions.copy)
        XCTAssertThrowsError(try reader.pdfAttachment(page: 0, id: 4))
        let owner = try NativeFile(protected, engine: .mupdf, password: "owner")
        XCTAssertEqual(try owner.pdfAttachment(page: 0, id: 4).data, attachment.data)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFDestinationResolutionUsesMuPDFNamedAndExplicitCoordinates() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("destinations.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(Chapter 1) [3 0 R /XYZ 30 350 1.25]] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 20 30 40] /Dest (Chapter 1) >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let action = try XCTUnwrap(file.pdfLinks(0).first?.actions.first)
        let expected = try XCTUnwrap(action.destination)
        let named = try XCTUnwrap(file.pdfResolveDestination("#nameddest=Chapter%201"))
        XCTAssertEqual(named.page, 0)
        XCTAssertEqual(named.type, expected.type)
        XCTAssertEqual(named.x, expected.x)
        XCTAssertEqual(named.y, expected.y)
        XCTAssertEqual(named.zoom, expected.zoom)
        XCTAssertEqual(named.x, 20)
        XCTAssertEqual(named.y, 70)
        XCTAssertEqual(named.zoom, 125)
        let explicit = try XCTUnwrap(file.pdfResolveDestination("#page=1&zoom=150,25,60"))
        XCTAssertEqual(explicit.page, 0)
        XCTAssertEqual(explicit.x, 25)
        XCTAssertEqual(explicit.y, 60)
        XCTAssertEqual(explicit.zoom, 150)
        XCTAssertNil(try file.pdfResolveDestination("#nameddest=missing"))
        XCTAssertNil(try file.pdfResolveDestination("https://example.org/#page=1"))
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
    }

    func testLivePDFAtomicSaveKeepsEncryptionAndOnlySuccessfulSaveMarksClean() async throws {
        let directory = try fixtureDirectory(), input = directory.appendingPathComponent("input.pdf")
        try scriptedFormPDF().write(to: input)
        let source = directory.appendingPathComponent("encrypted.pdf")
        try NativePDFTools.encrypt(source: input, destination: source, ownerPassword: "owner", userPassword: "reader")
        let pages = try Pages(source, format: .pdf, password: "owner")
        try await pages.pdfSetEditing(true)
        let fields = try await pages.pdfAnnotations(0)
        let inputID = try XCTUnwrap(fields.first { $0.fieldName == "input" }).id
        try await pages.pdfSetWidgetValue(page: 0, id: inputID, value: "7")
        let copy = directory.appendingPathComponent("copy.pdf")
        try await pages.pdfSaveCopy(to: copy)
        var info = try await pages.pdfInfo()
        XCTAssertTrue(try XCTUnwrap(info).dirty)
        do { try await pages.pdfSaveCopy(to: source); XCTFail("Save a Copy must not overwrite its source") } catch {}
        let directoryTarget = directory.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
        let sentinel = directoryTarget.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        do { try await pages.pdfSave(to: directoryTarget); XCTFail("Saving must not replace a directory") } catch {}
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        info = try await pages.pdfInfo()
        XCTAssertTrue(try XCTUnwrap(info).dirty)
        try await pages.pdfSave(to: source)
        info = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(info).dirty)
        try await pages.pdfSetWidgetValue(page: 0, id: inputID, value: "8")
        try await pages.pdfSave(to: source)
        info = try await pages.pdfInfo()
        XCTAssertFalse(try XCTUnwrap(info).dirty)
        XCTAssertThrowsError(try NativeFile(source, engine: .mupdf)) { XCTAssertTrue($0 is PasswordRequired) }
        let saved = try NativeFile(source, engine: .mupdf, password: "reader")
        XCTAssertEqual(try saved.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "8")
        XCTAssertEqual(try saved.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "18")
        try await pages.pdfUndo()
        info = try await pages.pdfInfo()
        XCTAssertTrue(try XCTUnwrap(info).dirty)
        try await pages.pdfSave(to: source)
        let undone = try NativeFile(source, engine: .mupdf, password: "reader")
        XCTAssertEqual(try undone.pdfAnnotations(0).first { $0.fieldName == "input" }?.value, "7")
        XCTAssertEqual(try undone.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "15")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".Sumra-save-") })
    }

    func testLivePDFAuthenticationPermissionsAndPageLabels() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("labels.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r /P <FEFF7B2C0020> /St 4 >>] >> /PageLayout /TwoPageRight /PageMode /UseOutlines /ViewerPreferences << /Direction /R2L /PrintScaling /None /Duplex /DuplexFlipLongEdge /NumCopies 2 /PickTrayByPDFSize true >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /Rotate 90 /Resources << >> >>"
        ])
        try bytes.write(to: source)
        let encrypted = directory.appendingPathComponent("protected.pdf")
        let plain = try NativeFile(source, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(plain.pdfInfo()).ownerAuthenticated,
                      "An unencrypted PDF must not require an owner password for output tools")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        for password in [nil, "incorrect"] as [String?] {
            XCTAssertThrowsError(try NativeFile(encrypted, engine: .mupdf, password: password)) { XCTAssertTrue($0 is PasswordRequired) }
        }
        let reader = try NativeFile(encrypted, engine: .mupdf, password: "reader")
        let info = try XCTUnwrap(reader.pdfInfo())
        XCTAssertEqual(info.pageCount, 1)
        XCTAssertTrue(info.permissions.print)
        XCTAssertFalse(info.permissions.copy)
        XCTAssertFalse(info.ownerAuthenticated)
        XCTAssertFalse(info.editingEnabled)
        XCTAssertFalse(info.dirty)
        XCTAssertEqual(info.layout, "TwoPageRight")
        XCTAssertEqual(info.pageMode, "UseOutlines")
        XCTAssertEqual(info.viewerPreferences.direction, "R2L")
        XCTAssertEqual(info.viewerPreferences.printScaling, "None")
        XCTAssertEqual(info.viewerPreferences.duplex, "DuplexFlipLongEdge")
        XCTAssertEqual(info.viewerPreferences.numCopies, 2)
        XCTAssertEqual(info.viewerPreferences.pickTrayByPDFSize, true)
        XCTAssertTrue(info.hasPageLabels)
        XCTAssertEqual(try reader.pdfPageLabel(0), "第 iv")
        XCTAssertEqual(try reader.bounds(0)?.size, CGSize(width: 400, height: 300))
        XCTAssertThrowsError(try reader.pdfSetEditing(true))
        let owner = try NativeFile(encrypted, engine: .mupdf, password: "owner")
        XCTAssertTrue(try XCTUnwrap(owner.pdfInfo()).ownerAuthenticated)
        XCTAssertTrue(try XCTUnwrap(owner.pdfInfo()).permissions.copy)
        try owner.pdfSetEditing(true)
        XCTAssertTrue(try XCTUnwrap(owner.pdfInfo()).editingEnabled)
        let invalid = directory.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        XCTAssertThrowsError(try NativeFile(invalid, engine: .mupdf)) { XCTAssertFalse($0 is PasswordRequired) }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFAnnotationEditIsOneUndoStepAndRollsBackFailedChanges() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("annotations.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 300 40 320] /Contents (note) >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [60 300 180 350] /Name /Approved >>"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let initialIDs = try file.pdfAnnotations(0).map(\.id)
        XCTAssertEqual(initialIDs, [4, 5], "Non-border annotation types must remain readable")
        XCTAssertThrowsError(try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 30, y: 30, width: 80, height: 40), edits: []))
        try file.pdfSetEditing(true)
        let id = try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 30, y: 30, width: 80, height: 40), edits: [
            .contents("original"), .color(SIMD3(1, 0, 0), interior: true), .opacity(0.5)
        ])
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, 1)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, 1)
        XCTAssertTrue(try XCTUnwrap(file.pdfInfo()).dirty)
        XCTAssertThrowsError(try file.pdfEditAnnotation(page: 0, id: id, edits: [.contents("partial change"), .opacity(-1)]))
        let annotation = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == id })
        XCTAssertEqual(annotation.contents, "original")
        XCTAssertEqual(annotation.opacity, 0.5)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoSteps, 1)
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).map(\.id), initialIDs)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        XCTAssertNoThrow(try file.pdfUndo(redo: false), "Repeated Undo at the start of history is a no-op")
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, 0)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        try file.pdfUndo(redo: true)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == id }?.contents, "original")
        XCTAssertNoThrow(try file.pdfUndo(redo: true), "Repeated Redo at the end of history is a no-op")
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, 1)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == id }?.contents, "original")
        try file.pdfSetEditing(false)
        XCTAssertThrowsError(try file.pdfDeleteAnnotation(page: 0, id: id))
        XCTAssertThrowsError(try file.pdfUndo(redo: false))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFUsesOneFormScriptRuntimeAcrossEditUndoAndValidation() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("form.pdf")
        let bytes = scriptedFormPDF()
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        try file.pdfSetWidgetValue(page: 0, id: 4, value: "7")
        func value(_ name: String) throws -> String? { try file.pdfAnnotations(0).first { $0.fieldName == name }?.value }
        XCTAssertEqual(try value("input"), "7")
        XCTAssertEqual(try value("total"), "15")
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try value("input"), "2")
        XCTAssertEqual(try value("total"), "4", "Undo restores objects without calculating again")
        try file.pdfSetWidgetValue(page: 0, id: 4, value: "8")
        XCTAssertEqual(try value("total"), "18", "The existing MuJS global survives native undo")
        XCTAssertThrowsError(try file.pdfSetWidgetValue(page: 0, id: 4, value: "-1"))
        XCTAssertThrowsError(try file.pdfSetWidgetValue(page: 0, id: 5, value: "99"))
        XCTAssertEqual(try value("input"), "8")
        XCTAssertEqual(try value("total"), "18")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFEditAndUndoInvalidateTheExistingPagesBitmapCache() async throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("cache.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>"
        ]).write(to: source)
        let pages = try Pages(source, format: .pdf)
        func pixels(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }
        let original = try pixels(await pages.image(0, width: 100))
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 10, y: 10, width: 80, height: 80), edits: [.color(SIMD3(1, 0, 0), interior: true)])
        let changed = try pixels(await pages.image(0, width: 100))
        XCTAssertNotEqual(changed, original)
        try await pages.pdfUndo()
        let undone = try pixels(await pages.image(0, width: 100))
        XCTAssertEqual(undone, original)
    }

    func testLivePDFAnnotationVisibilityPreservesContentWidgetsAndLockedJournal() async throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("visibility.pdf")
        // Author DeviceRGB directly and inspect the decoder's RGB bytes: no
        // PDFKit authoring or display-profile conversion changes these colors.
        let content = "/DeviceRGB cs 1 0 0 sc 0 0 40 40 re f\n"
        let widget = "/DeviceRGB cs 0 1 0 sc 0 0 40 40 re f\n"
        let annotation = "/DeviceRGB cs 0 0 1 sc 0 0 40 40 re f\n"
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 40] /Resources << >> /Contents 4 0 R /Annots [5 0 R 6 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (button) /Rect [40 0 80 40] /AP << /N 7 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [80 0 120 40] /AP << /N 8 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources << >> /Length \(widget.utf8.count) >>\nstream\n\(widget)endstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources << >> /Length \(annotation.utf8.count) >>\nstream\n\(annotation)endstream"
        ])
        try bytes.write(to: source)
        let pages = try Pages(source, format: .pdf)
        let initial = try await pages.pdfInfo(), before = try XCTUnwrap(initial)
        XCTAssertFalse(before.editingEnabled)
        XCTAssertFalse(before.dirty)
        XCTAssertEqual(before.undoPosition, 0)
        XCTAssertEqual(before.undoSteps, 0)
        func pixels(_ image: CGImage) throws -> Data {
            XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 40)
            XCTAssertEqual(image.bitsPerComponent, 8); XCTAssertEqual(image.bitsPerPixel, 24)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        func sample(_ data: Data, _ image: CGImage, x: Int) -> [UInt8] {
            let offset = 20 * image.bytesPerRow + x * 3
            return Array(data[offset..<(offset + 3)])
        }
        let visible = try await pages.image(0, width: 120), visiblePixels = try pixels(visible)
        XCTAssertEqual(sample(visiblePixels, visible, x: 20), [255, 0, 0])
        XCTAssertEqual(sample(visiblePixels, visible, x: 60), [0, 255, 0])
        XCTAssertEqual(sample(visiblePixels, visible, x: 100), [0, 0, 255])
        for show in [false, true] {
            try await pages.pdfSetAnnotationsVisible(show)
            let image = try await pages.image(0, width: 120), actual = try pixels(image)
            XCTAssertEqual(sample(actual, image, x: 20), [255, 0, 0], "Page content remains visible")
            XCTAssertEqual(sample(actual, image, x: 60), [0, 255, 0], "The widget's authored AP remains visible")
            XCTAssertEqual(sample(actual, image, x: 100), show ? [0, 0, 255] : [255, 255, 255])
            if show { XCTAssertEqual(actual, visiblePixels, "Restoring visibility rebuilds the same page image") }
            let current = try await pages.pdfInfo(), info = try XCTUnwrap(current)
            XCTAssertEqual(info.editingEnabled, before.editingEnabled)
            XCTAssertEqual(info.dirty, before.dirty)
            XCTAssertEqual(info.undoPosition, before.undoPosition)
            XCTAssertEqual(info.undoSteps, before.undoSteps)
            XCTAssertEqual(info.undoTitle, before.undoTitle)
            XCTAssertEqual(info.redoTitle, before.redoTitle)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFWidgetSnapshotsInheritAppearanceAndAlignment() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("inherited-fields.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 7 0 R] /DA (/TiRo 9 Tf 0 g) /Q 1 /DR << /Font << /Cour 8 0 R /Helv 9 0 R /TiRo 10 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Annots [5 0 R 6 0 R 7 0 R] >>",
            "<< /FT /Tx /T (parent) /Kids [5 0 R 6 0 R] /DA (/Cour 17 Tf 0 g) /Q 2 >>",
            "<< /Type /Annot /Subtype /Widget /Parent 4 0 R /Rect [10 150 200 180] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 4 0 R /Rect [10 100 200 130] /DA (/Helv 0 Tf 0 g) /Q 0 >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (fallback) /Rect [10 50 200 80] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf), fields = try file.pdfAnnotations(0)
        let expected: [(Int32, String, Float, Int32)] = [(5, "Cour", 17, 2), (6, "Helv", 0, 0), (7, "TiRo", 9, 1)]
        for (id, font, size, alignment) in expected {
            let field = try XCTUnwrap(fields.first { $0.id == id })
            XCTAssertEqual(field.type, "Widget")
            XCTAssertEqual(field.font, font)
            XCTAssertEqual(field.fontSize, size, "An explicit zero keeps PDF auto-sizing")
            XCTAssertEqual(field.alignment, alignment, "Local Q=0 overrides the parent; missing Q inherits")
            XCTAssertEqual(field.textColor, [0, 0, 0])
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLivePDFAnnotationFlagsRejectProtectedEditsWithoutChangingTheJournal() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("locked-annotations.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Annots [4 0 R 5 0 R 6 0 R] >>",
            "<< /Type /Annot /Subtype /Square /F 64 /Rect [10 120 80 180] /Contents (read only) >>",
            "<< /Type /Annot /Subtype /Square /F 128 /Rect [100 120 170 180] /Contents (locked) >>",
            "<< /Type /Annot /Subtype /Square /F 512 /Rect [10 20 80 80] /Contents (locked contents) >>"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        let original = try file.pdfAnnotations(0), before = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(original.map(\.contents), ["read only", "locked", "locked contents"])
        XCTAssertEqual(original.map(\.flags), [64, 128, 512])
        for id: Int32 in [4, 5] {
            XCTAssertThrowsError(try file.pdfDeleteAnnotation(page: 0, id: id))
            XCTAssertThrowsError(try file.pdfEditAnnotation(page: 0, id: id, edits: [.move(CGSize(width: 7, height: 9))]))
            XCTAssertThrowsError(try file.pdfEditAnnotation(page: 0, id: id, edits: [.contents("changed")]))
        }
        XCTAssertThrowsError(try file.pdfEditAnnotation(page: 0, id: 6, edits: [.contents("changed")]))
        let unchanged = try file.pdfAnnotations(0), rejected = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(unchanged.map(\.id), original.map(\.id))
        XCTAssertEqual(unchanged.map(\.bounds), original.map(\.bounds))
        XCTAssertEqual(unchanged.map(\.contents), original.map(\.contents))
        XCTAssertEqual(rejected.undoPosition, before.undoPosition)
        XCTAssertEqual(rejected.undoSteps, before.undoSteps)
        XCTAssertEqual(rejected.dirty, before.dirty)
        let bounds = try XCTUnwrap(original.first { $0.id == 6 }).bounds
        try file.pdfEditAnnotation(page: 0, id: 6, edits: [.move(CGSize(width: 7, height: 9))])
        let moved = try XCTUnwrap(file.pdfAnnotations(0).first { $0.id == 6 })
        XCTAssertEqual(moved.bounds, bounds.offsetBy(dx: 7, dy: 9))
        XCTAssertEqual(moved.contents, "locked contents")
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition + 1)
        // The first move turns the display-only appearance into a real AP/RD.
        // Moving it again must preserve dimensions just like the first move.
        try file.pdfEditAnnotation(page: 0, id: 6, edits: [.move(CGSize(width: 7, height: 9))])
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 6 }?.bounds, bounds.offsetBy(dx: 14, dy: 18))
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 6 }?.bounds, moved.bounds)
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.pdfAnnotations(0).first { $0.id == 6 }?.bounds, bounds)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).dirty, before.dirty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor func testPDFInformationAndResourceReportUseOriginalFileWithoutMutation() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("information.pdf")
        let input = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /MarkInfo << /Marked true >> /OutputIntents [<< /S /GTS_PDFA1 >> << /S /GTS_PDFX >>] /AcroForm << /Fields [] /XFA [(template) 8 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /Resources << /Font << /F1 4 0 R /F2 9 0 R >> /XObject << /Im1 10 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type0 /BaseFont /OuterName /DescendantFonts [5 0 R] /Encoding /Identity-H >>",
            "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+EmbeddedName /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 6 0 R >>",
            "<< /Type /FontDescriptor /FontName /ABCDEF+EmbeddedName /FontFile2 7 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Length 6 >>\nstream\n<xfa/>\nendstream",
            "<< /Type /Font /Subtype /Type3 /Name /MissingGlyphs >>",
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Length 1 >>\nstream\nx\nendstream"
        ])
        try input.write(to: source)
        let information = try NativePDFTools.information(source: source)
        XCTAssertEqual(information["PDFVersion"], "1.7")
        XCTAssertEqual(information["Encryption"], "None")
        XCTAssertEqual(information["Linearized"], "No")
        XCTAssertEqual(information["Tagged"], "Yes")
        XCTAssertEqual(information["OutputIntents"], "PDF/X (ISO 15930), PDF/A (ISO 19005)")
        XCTAssertEqual(information["UnsupportedFeatures"], "XFA")
        let report = try NativePDFTools.resourceReport(source: source)
        XCTAssertTrue(report.contains("PDF-1.7"))
        XCTAssertTrue(report.contains("Mediaboxes (1)"))
        XCTAssertTrue(report.contains("Images (1)"))
        XCTAssertTrue(report.contains("Fonts (2)"))
        XCTAssertEqual(try Data(contentsOf: source), input)
    }

    @MainActor func testAltiumNamedComponentMenuAndPushButtonNavigation() throws {
        let script = #"app.popUpMenu("R1", "Value: 10\u03a9", "-", ["submenu", "ignored"], "URL: https://example.org/data");"#
        let source = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /Names << /JavaScript << /Names [(ShowCompProps_R1) 6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 300 120 340] /A << /S /JavaScript /JS (ShowCompProps_R1\\(\\);) >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (details) /Rect [20 240 120 280] /AA << /U << /S /URI /URI (https://example.org/button) >> >> >>",
            "<< /S /JavaScript /JS 7 0 R >>",
            "<< /Length \(script.utf8.count) >>\nstream\n\(script)\nendstream"
        ])
        let directory = try fixtureDirectory(), url = directory.appendingPathComponent("altium.pdf")
        try source.write(to: url)
        let document = try NativeFile(url, engine: .mupdf)
        let links = try document.pdfLinks(0)
        let action = try XCTUnwrap(links.first { $0.id == 4 }?.actions.first)
        XCTAssertEqual(action.kind, "JavaScript")
        XCTAssertEqual(try document.pdfJavaScriptMenu(XCTUnwrap(action.javascript)), ["R1", "Value: 10Ω", "-", "URL: https://example.org/data"])
        let button = try XCTUnwrap(links.first { $0.id == 5 }?.actions.first)
        XCTAssertEqual(button.kind, "URI")
        XCTAssertEqual(button.uri, "https://example.org/button")
        XCTAssertEqual(PDFJavaScriptMenu.items(in: #"app.popUpMenuEx({cName:'Name: Q1'}, {cName:'Symbol: \uD83D\uDD0C'});"#), ["Name: Q1", "Symbol: 🔌"])
    }

    @MainActor func testLiveFormPagesRetainTheSourceAcrossAtomicPathReplacement() throws {
        let directory = try fixtureDirectory(), url = directory.appendingPathComponent("forms.pdf")
        let appearance = "0 0 1 rg 0 0 100 30 re f\n"
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [6 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (first) /V (one) /Rect [20 300 120 330] /P 3 0 R /CA 0.5 /AP << /N 7 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (second) /V (two) /Rect [20 300 120 330] /P 4 0 R /CA 0.5 /AP << /N 7 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 100 30] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ])
        try bytes.write(to: url)
        let document = try NativeFile(url, engine: .mupdf)
        let first = try document.image(0, width: 300)
        try rawPDF(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"]).write(to: url, options: .atomic)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try document.pdfAnnotations(0).first?.value, "one")
        XCTAssertEqual(try document.pdfAnnotations(1).first?.value, "two")
        let second = try document.image(1, width: 300)
        XCTAssertEqual(try XCTUnwrap(first.dataProvider?.data) as Data, try XCTUnwrap(second.dataProvider?.data) as Data,
                       "The next page must use the retained stream, not reopen the removed pathname")
        let output = directory.appendingPathComponent("retained.pdf")
        try document.pdfWrite(to: output)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.page(at: 0)?.annotations.first?.widgetStringValue, "one")
        XCTAssertEqual(saved.page(at: 1)?.annotations.first?.widgetStringValue, "two")
    }

    private func scriptedFormPDF() -> Data {
        rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R /Names << /JavaScript << /Names [(init) 8 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (input) /V (2) /Rect [20 300 200 330] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) /AA << /V << /S /JavaScript /JS (event.rc = Number\\(event.value\\) >= 0; if \\(event.rc\\) edits++;) >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (total) /V (4) /Ff 1 /Rect [20 250 200 280] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) /AA << /C << /S /JavaScript /JS (event.value = Number\\(this.getField\\('input'\\).value\\) * 2 + edits;) >> /F << /S /JavaScript /JS (event.value = 'USD ' + event.value;) >> >> >>",
            "<< /Fields [4 0 R 5 0 R] /CO [5 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 7 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /S /JavaScript /JS (var edits = 0;) >>"
        ])
    }

    @MainActor func testMuPDFFormCommitKeepsFormattedAppearanceAcrossSaveAndEncryption() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("form.pdf")
        let input = scriptedFormPDF()
        try input.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        try file.pdfSetEditing(true)
        try file.pdfSetWidgetValue(page: 0, id: 4, value: "7")
        let savedURL = directory.appendingPathComponent("formatted-saved.pdf")
        try file.pdfWrite(to: savedURL)
        let saved = try XCTUnwrap(PDFDocument(url: savedURL)), fields = try XCTUnwrap(saved.page(at: 0)).annotations
        XCTAssertEqual(fields.first { $0.fieldName == "input" }?.widgetStringValue, "7")
        XCTAssertEqual(fields.first { $0.fieldName == "total" }?.widgetStringValue, "15")
        XCTAssertEqual(fields.filter { $0.type == "Widget" }.count, 2)
        let total = try XCTUnwrap(fields.first { $0.fieldName == "total" })
        XCTAssertTrue(total.hasAppearanceStream)
        var annotations: CGPDFArrayRef?, rawField: CGPDFDictionaryRef?, rawAP: CGPDFDictionaryRef?, rawStream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(saved.page(at: 0)?.pageRef?.dictionary), "Annots", &annotations))
        let fieldIndex = try XCTUnwrap(fields.firstIndex { $0 === total })
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), fieldIndex, &rawField))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(rawField), "AP", &rawAP))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(rawAP), "N", &rawStream))
        var format = CGPDFDataFormat.raw
        let appearanceText = String(decoding: try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(rawStream), &format)) as Data, as: UTF8.self)
        XCTAssertTrue(appearanceText.contains("(USD 15)"), "The saved AP contains the formatted text, not just V=15")
        let reopened = try NativeFile(savedURL, engine: .mupdf)
        XCTAssertEqual(try XCTUnwrap(file.image(0, width: 300).dataProvider?.data) as Data,
                       try XCTUnwrap(reopened.image(0, width: 300).dataProvider?.data) as Data)
        let baked = directory.appendingPathComponent("formatted-appearance.pdf")
        try NativePDFTools.transform(source: savedURL, destination: baked, operation: .bake)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: baked)?.string).contains("USD 15"))
        let encrypted = directory.appendingPathComponent("encrypted.pdf"), filled = directory.appendingPathComponent("filled.pdf")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader")
        let protected = try NativeFile(encrypted, engine: .mupdf, password: "reader")
        try protected.pdfSetEditing(true)
        try protected.pdfSetWidgetValue(page: 0, id: 4, value: "7")
        try protected.pdfWrite(to: filled)
        let verified = try XCTUnwrap(PDFDocument(url: filled))
        XCTAssertTrue(verified.isEncrypted); XCTAssertTrue(verified.unlock(withPassword: "reader"))
        XCTAssertEqual(verified.page(at: 0)?.annotations.first { $0.fieldName == "total" }?.widgetStringValue, "15")
        XCTAssertEqual(try Data(contentsOf: source), input)
    }

    @MainActor func testRadioNoTogglePreservesRedoAndNamedGroupValueAcrossSaveCopy() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("radio-source.pdf")
        func appearance(_ content: String) -> String {
            "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >> /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
        }
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Annots [7 0 R 9 0 R 11 0 R 12 0 R 13 0 R] >>",
            "<< /Fields [6 0 R 8 0 R 10 0 R 13 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /FT /Tx /T (notes) /Ff 4096 /MaxLen 24 /V (ab\\ncd) /Kids [7 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /P 3 0 R /Rect [40 380 360 520] /F 4 /DA (/Helv 12 Tf 0 g) >>",
            "<< /FT /Tx /T (code) /MaxLen 5 /V (abc) /Kids [9 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /P 3 0 R /Rect [40 300 180 332] /F 4 /DA (/Helv 12 Tf 0 g) >>",
            "<< /FT /Btn /Ff 49152 /T (pick) /V /One /Kids [11 0 R 12 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 10 0 R /P 3 0 R /Rect [40 210 60 230] /F 4 /AS /One /AP << /N << /Off 14 0 R /One 15 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 10 0 R /P 3 0 R /Rect [180 210 200 230] /F 4 /AS /Off /AP << /N << /Off 14 0 R /Two 15 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (check) /P 3 0 R /Rect [40 140 60 160] /F 4 /V /Off /AS /Off /AP << /N << /Off 14 0 R /Yes 15 0 R >> >> >>",
            appearance("0 g 0.8 w 1 1 18 18 re S\n"),
            appearance("0 g 0.8 w 1 1 18 18 re S\n6 6 8 8 re f\n")
        ])
        try original.write(to: source)
        let live = try NativeFile(source, engine: .mupdf)
        try live.pdfSetEditing(true)
        func radioPixels(_ file: NativeFile) throws -> [Data] {
            try widgetPixels(file, rects: [CGRect(x: 40, y: 370, width: 20, height: 20),
                CGRect(x: 180, y: 370, width: 20, height: 20)])
        }
        let originalRadioPixels = try radioPixels(live)
        XCTAssertNotEqual(originalRadioPixels[0], originalRadioPixels[1])
        func state(_ file: NativeFile) throws -> (radio: String?, checkbox: String?) {
            let fields = try file.pdfAnnotations(0)
            return (fields.first { $0.id == 11 }?.value, fields.first { $0.id == 13 }?.value)
        }
        func assertHistory(_ position: Int, _ steps: Int, _ dirty: Bool, file: NativeFile,
                           filePath: StaticString = #filePath, line: UInt = #line) throws {
            let info = try XCTUnwrap(file.pdfInfo(), file: filePath, line: line)
            XCTAssertEqual(info.undoPosition, position, file: filePath, line: line)
            XCTAssertEqual(info.undoSteps, steps, file: filePath, line: line)
            XCTAssertEqual(info.dirty, dirty, file: filePath, line: line)
        }
        func assertRawStates(_ url: URL, radio: String, first: String, second: String, checkbox: String) throws {
            let document = try XCTUnwrap(PDFDocument(url: url))
            var acroForm: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, group: CGPDFDictionaryRef?
            var annotations: CGPDFArrayRef?, firstWidget: CGPDFDictionaryRef?, secondWidget: CGPDFDictionaryRef?, checkWidget: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(document.documentRef?.catalog), "AcroForm", &acroForm))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(acroForm), "Fields", &fields))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 2, &group))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: 0)?.pageRef?.dictionary), "Annots", &annotations))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 2, &firstWidget))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 3, &secondWidget))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 4, &checkWidget))
            func name(_ dict: CGPDFDictionaryRef, _ key: String) throws -> String {
                var value: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFDictionaryGetName(dict, key, &value), "\(key) must remain a PDF name")
                return String(cString: try XCTUnwrap(value))
            }
            XCTAssertEqual(try name(XCTUnwrap(group), "V"), radio)
            XCTAssertEqual(try name(XCTUnwrap(firstWidget), "AS"), first)
            XCTAssertEqual(try name(XCTUnwrap(secondWidget), "AS"), second)
            XCTAssertEqual(try name(XCTUnwrap(checkWidget), "V"), checkbox)
            XCTAssertEqual(try name(XCTUnwrap(checkWidget), "AS"), checkbox)
        }

        try assertHistory(0, 0, false, file: live)
        XCTAssertEqual(try state(live).radio, "One")
        try live.pdfToggleWidget(page: 0, id: 11) // NoToggleToOff: this is already selected.
        try assertHistory(0, 0, false, file: live)
        try live.pdfToggleWidget(page: 0, id: 13)
        try assertHistory(1, 1, true, file: live)
        try live.pdfUndo(redo: false)
        let redoTitle = try XCTUnwrap(live.pdfInfo()).redoTitle
        XCTAssertNotNil(redoTitle)
        try assertHistory(0, 1, false, file: live)
        try live.pdfToggleWidget(page: 0, id: 11)
        try assertHistory(0, 1, false, file: live)
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).redoTitle, redoTitle)
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try state(live).checkbox, "Yes")
        try live.pdfToggleWidget(page: 0, id: 12)
        XCTAssertEqual(try state(live).radio, "Two")
        try assertHistory(2, 2, true, file: live)
        let selectedTwoPixels = try radioPixels(live)
        XCTAssertEqual(selectedTwoPixels, originalRadioPixels.reversed(), "Selecting a radio must reuse its custom On/Off appearances")

        let saved = directory.appendingPathComponent("radio-saved.pdf")
        try live.pdfWrite(to: saved)
        try assertHistory(2, 2, true, file: live)
        try assertRawStates(saved, radio: "Two", first: "Off", second: "Two", checkbox: "Yes")
        let reopened = try NativeFile(saved, engine: .mupdf)
        XCTAssertEqual(try state(reopened).radio, "Two")
        XCTAssertEqual(try state(reopened).checkbox, "Yes")
        XCTAssertEqual(try radioPixels(reopened), selectedTwoPixels)

        try live.pdfToggleWidget(page: 0, id: 11)
        XCTAssertEqual(try state(live).radio, "One")
        XCTAssertEqual(try radioPixels(live), originalRadioPixels)
        try assertHistory(3, 3, true, file: live)
        try live.pdfToggleWidget(page: 0, id: 11)
        try assertHistory(3, 3, true, file: live)
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try state(live).radio, "Two")
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try state(live).radio, "One")
        XCTAssertEqual(try state(live).checkbox, "Yes")
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try state(live).radio, "Two")
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try state(live).radio, "One")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testScriptedButtonsKeepNamesCustomAppearancesAndOneUndoStep() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("script-buttons.pdf")
        func stream(_ content: String, appearance: Bool = false) -> String {
            "<< /Length \(content.utf8.count) \(appearance ? "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >>" : "") >>\nstream\n\(content)endstream"
        }
        let off = "0 g 0.8 w 1 1 18 18 re S\n", on = off + "6 6 8 8 re f\n"
        let script = "this.getField('pick').value = event.value === 'b' ? 'Two' : 'One'; this.getField('check').value = event.value === 'b' ? 'Yes' : 'Off';\n"
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Annots [7 0 R 9 0 R 10 0 R 11 0 R] >>",
            "<< /Fields [6 0 R 8 0 R 11 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /FT /Tx /T (trigger) /V (a) /Kids [7 0 R] /AA << /V << /S /JavaScript /JS 14 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /P 3 0 R /Rect [40 220 360 252] /F 4 >>",
            "<< /FT /Btn /Ff 49152 /T (pick) /V /One /Kids [9 0 R 10 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /P 3 0 R /Rect [40 130 60 150] /F 4 /AS /One /AP << /N << /Off 12 0 R /One 13 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /P 3 0 R /Rect [180 130 200 150] /F 4 /AS /Off /AP << /N << /Off 12 0 R /Two 13 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (check) /P 3 0 R /Rect [40 70 60 90] /F 4 /V /Off /AS /Off /AP << /N << /Off 12 0 R /Yes 13 0 R >> >> >>",
            stream(off, appearance: true), stream(on, appearance: true), stream(script)
        ])
        try original.write(to: source)
        let live = try NativeFile(source, engine: .mupdf)
        try live.pdfSetEditing(true)
        func values(_ file: NativeFile) throws -> [String] {
            let fields = try file.pdfAnnotations(0)
            return try [7, 9, 11].map { id in try XCTUnwrap(fields.first { $0.id == id }?.value) }
        }
        func pixels(_ file: NativeFile) throws -> [Data] {
            try widgetPixels(file, rects: [CGRect(x: 40, y: 150, width: 20, height: 20),
                CGRect(x: 180, y: 150, width: 20, height: 20),
                CGRect(x: 40, y: 210, width: 20, height: 20)])
        }
        func inspect(_ url: URL, radio: String, checkbox: String) throws {
            let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
            var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, group: CGPDFDictionaryRef?, check: CGPDFDictionaryRef?
            var annotations: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(document.catalog), "AcroForm", &form))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 1, &group))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 2, &check))
            func name(_ dictionary: CGPDFDictionaryRef, _ key: String) throws -> String {
                var value: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFDictionaryGetName(dictionary, key, &value), "Button \(key) must be a PDF name")
                return String(cString: try XCTUnwrap(value))
            }
            XCTAssertEqual(try name(XCTUnwrap(group), "V"), radio)
            XCTAssertEqual(try name(XCTUnwrap(check), "V"), checkbox)
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: 1)?.dictionary), "Annots", &annotations))
            for (index, onName, selected) in [(1, "One", radio == "One" ? "One" : "Off"),
                                               (2, "Two", radio == "Two" ? "Two" : "Off"),
                                               (3, "Yes", checkbox)] {
                var widget: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?, normal: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), index, &widget))
                XCTAssertEqual(try name(XCTUnwrap(widget), "AS"), selected)
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(widget), "AP", &appearance))
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(appearance), "N", &normal))
                for (state, expected) in [("Off", off), (onName, on)] {
                    var appearanceStream: CGPDFStreamRef?, format = CGPDFDataFormat.raw
                    XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(normal), state, &appearanceStream))
                    let decoded = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(appearanceStream), &format)) as Data
                    XCTAssertEqual(decoded, Data(expected.utf8), "Scripts must retain imported button appearances")
                }
            }
        }
        let initialPixels = try pixels(live)
        XCTAssertNotEqual(initialPixels[0], initialPixels[1])
        XCTAssertEqual(try values(live), ["a", "One", "Off"])
        try live.pdfSetWidgetValue(page: 0, id: 7, value: "b")
        XCTAssertEqual(try values(live), ["b", "Two", "Yes"])
        let changedPixels = try pixels(live)
        XCTAssertEqual(changedPixels, [initialPixels[1], initialPixels[0], initialPixels[0]])
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoPosition, 1)
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoSteps, 1, "The triggering edit and its scripts form one operation")
        let copy = directory.appendingPathComponent("script-buttons-copy.pdf")
        try live.pdfWrite(to: copy)
        try inspect(copy, radio: "Two", checkbox: "Yes")
        let reopened = try NativeFile(copy, engine: .mupdf)
        XCTAssertEqual(try values(reopened), ["b", "Two", "Yes"])
        XCTAssertEqual(try pixels(reopened), changedPixels)
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try values(live), ["a", "One", "Off"])
        XCTAssertEqual(try pixels(live), initialPixels)
        XCTAssertFalse(try XCTUnwrap(live.pdfInfo()).dirty)
        XCTAssertNotNil(try XCTUnwrap(live.pdfInfo()).redoTitle)
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try values(live), ["b", "Two", "Yes"])
        XCTAssertEqual(try pixels(live), changedPixels)
        try reopened.pdfSetEditing(true)
        let trigger = try XCTUnwrap(reopened.pdfAnnotations(0).first { $0.fieldName == "trigger" })
        try reopened.pdfSetWidgetValue(page: 0, id: trigger.id, value: "a")
        XCTAssertEqual(try values(reopened), ["a", "One", "Off"], "The validation script survives save/reopen")
        XCTAssertEqual(try pixels(reopened), initialPixels)
        let secondCopy = directory.appendingPathComponent("script-buttons-reset-copy.pdf")
        try reopened.pdfWrite(to: secondCopy)
        try inspect(secondCopy, radio: "One", checkbox: "Off")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testScriptedResetRestoresDefaultsWithoutReplacingButtonAppearances() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("reset-defaults.pdf")
        func stream(_ content: String, appearance: Bool = false) -> String {
            "<< /Length \(content.utf8.count) \(appearance ? "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >>" : "") >>\nstream\n\(content)endstream"
        }
        let off = "0 g 0.8 w 1 1 18 18 re S\n", on = off + "6 6 8 8 re f\n"
        let script = "if (event.value === 'subset') this.resetForm(['pick','check']); if (event.value === 'all') this.resetForm();\n"
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Annots [7 0 R 9 0 R 11 0 R 13 0 R 14 0 R 15 0 R 16 0 R] >>",
            "<< /Fields [6 0 R 8 0 R 10 0 R 12 0 R 15 0 R 16 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /FT /Tx /T (trigger) /V (begin) /DV (idle) /Kids [7 0 R] /AA << /V << /S /JavaScript /JS 19 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /P 3 0 R /Rect [40 400 360 432] /F 4 >>",
            "<< /FT /Tx /T (notes) /Ff 1 /V (changed) /DV (restored) /Kids [9 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /P 3 0 R /Rect [40 330 360 362] /F 4 >>",
            "<< /FT /Ch /Ff 131072 /T (choice) /V (two) /DV (one) /Opt [[(one) (First)] [(two) (Second)]] /Kids [11 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 10 0 R /P 3 0 R /Rect [40 260 180 292] /F 4 >>",
            "<< /FT /Btn /Ff 49152 /T (pick) /V /One /DV /Two /Kids [13 0 R 14 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 12 0 R /P 3 0 R /Rect [40 170 60 190] /F 4 /AS /One /AP << /N << /Off 17 0 R /One 18 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 12 0 R /P 3 0 R /Rect [180 170 200 190] /F 4 /AS /Off /AP << /N << /Off 17 0 R /Two 18 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (check) /P 3 0 R /Rect [40 110 60 130] /F 4 /V /Off /DV /Yes /AS /Off /AP << /N << /Off 17 0 R /Yes 18 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (empty) /P 3 0 R /Rect [220 110 240 130] /F 4 /V /Yes /AS /Yes /AP << /N << /Off 17 0 R /Yes 18 0 R >> >> >>",
            stream(off, appearance: true), stream(on, appearance: true), stream(script)
        ])
        try original.write(to: source)
        let live = try NativeFile(source, engine: .mupdf)
        try live.pdfSetEditing(true)
        func values(_ file: NativeFile) throws -> [String] {
            let fields = try file.pdfAnnotations(0)
            return try ["trigger", "notes", "choice", "pick", "check", "empty"].map { name in
                try XCTUnwrap(fields.first { $0.fieldName == name }?.value)
            }
        }
        func pixels(_ file: NativeFile) throws -> [Data] {
            try widgetPixels(file, rects: [CGRect(x: 40, y: 310, width: 20, height: 20),
                CGRect(x: 180, y: 310, width: 20, height: 20),
                CGRect(x: 40, y: 370, width: 20, height: 20),
                CGRect(x: 220, y: 370, width: 20, height: 20)])
        }
        func appearanceStreams(_ url: URL) throws -> [Data] {
            let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
            var annotations: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: 1)?.dictionary), "Annots", &annotations))
            var result = [Data]()
            for (index, onName) in [(3, "One"), (4, "Two"), (5, "Yes"), (6, "Yes")] {
                var widget: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?, normal: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), index, &widget))
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(widget), "AP", &appearance))
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(appearance), "N", &normal))
                for state in ["Off", onName] {
                    var stream: CGPDFStreamRef?, format = CGPDFDataFormat.raw
                    XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(normal), state, &stream))
                    result.append(try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data)
                }
            }
            return result
        }
        let initial = ["begin", "changed", "two", "One", "Off", "Yes"]
        let subset = ["subset", "changed", "two", "Two", "Yes", "Yes"]
        // The committing trigger retains its submitted value after resetForm.
        let all = ["all", "restored", "one", "Two", "Yes", ""]
        let originalPixels = try pixels(live), originalStreams = try appearanceStreams(source)
        XCTAssertNotEqual(originalPixels[0], originalPixels[1])
        XCTAssertEqual(try values(live), initial)
        try live.pdfSetWidgetValue(page: 0, id: 7, value: "subset")
        XCTAssertEqual(try values(live), subset, "Named reset leaves unlisted fields untouched")
        XCTAssertEqual(try pixels(live), [originalPixels[1], originalPixels[0], originalPixels[0], originalPixels[0]])
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoPosition, 1)
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoSteps, 1)
        try live.pdfSetWidgetValue(page: 0, id: 7, value: "all")
        XCTAssertEqual(try values(live), all, "All-field reset restores read-only text, choice and absent defaults")
        let resetPixels = try pixels(live)
        XCTAssertEqual(resetPixels, [originalPixels[1], originalPixels[0], originalPixels[0], originalPixels[1]])
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoPosition, 2)
        XCTAssertEqual(try XCTUnwrap(live.pdfInfo()).undoSteps, 2)
        let copy = directory.appendingPathComponent("reset-copy.pdf")
        try live.pdfWrite(to: copy)
        XCTAssertEqual(try appearanceStreams(copy), originalStreams)
        let rawSaved = try XCTUnwrap(CGPDFDocument(copy as CFURL))
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(rawSaved.catalog), "AcroForm", &form))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
        func field(_ index: Int) throws -> CGPDFDictionaryRef {
            var dictionary: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), index, &dictionary))
            return try XCTUnwrap(dictionary)
        }
        for (index, value, defaultValue) in [(0, "all", "idle"), (1, "restored", "restored"), (2, "one", "one")] {
            for (key, expected) in [("V", value), ("DV", defaultValue)] {
                var string: CGPDFStringRef?
                XCTAssertTrue(CGPDFDictionaryGetString(try field(index), key, &string))
                XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(string))) as String, expected)
            }
        }
        for (index, expected) in [(3, "Two"), (4, "Yes")] {
            for key in ["V", "DV"] {
                var name: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFDictionaryGetName(try field(index), key, &name))
                XCTAssertEqual(String(cString: try XCTUnwrap(name)), expected)
            }
        }
        XCTAssertFalse(CGPDFDictionaryGetObject(try field(5), "V", nil))
        XCTAssertFalse(CGPDFDictionaryGetObject(try field(5), "DV", nil))
        var emptyState: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetName(try field(5), "AS", &emptyState))
        XCTAssertEqual(String(cString: try XCTUnwrap(emptyState)), "Off")
        let saved = try XCTUnwrap(PDFDocument(url: copy))
        let widgets = try XCTUnwrap(saved.page(at: 0)).annotations
        XCTAssertEqual(widgets.first { $0.fieldName == "notes" }?.widgetStringValue, "restored")
        XCTAssertTrue(try XCTUnwrap(widgets.first { $0.fieldName == "notes" }).isReadOnly)
        let reopened = try NativeFile(copy, engine: .mupdf)
        XCTAssertEqual(try values(reopened), all)
        XCTAssertEqual(try pixels(reopened), resetPixels)
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try values(live), subset)
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try values(live), initial)
        XCTAssertEqual(try pixels(live), originalPixels)
        XCTAssertFalse(try XCTUnwrap(live.pdfInfo()).dirty)
        try live.pdfUndo(redo: true)
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try values(live), all)
        XCTAssertEqual(try pixels(live), resetPixels)
        try reopened.pdfSetEditing(true)
        try reopened.pdfSetWidgetValue(page: 0, id: 7, value: "subset")
        XCTAssertEqual(try values(reopened), ["subset", "restored", "one", "Two", "Yes", ""])
        XCTAssertEqual(try pixels(reopened), resetPixels)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testScriptedResetStillSynthesizesAMissingCheckboxAppearance() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("reset-missing-appearance.pdf")
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Annots [6 0 R 7 0 R] >>",
            "<< /Fields [6 0 R 7 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (trigger) /V (begin) /P 3 0 R /Rect [40 140 360 172] /F 4 /AA << /V << /S /JavaScript /JS (this.resetForm\\(['check']\\);) >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (check) /V /Off /DV /Yes /AS /Off /P 3 0 R /Rect [40 70 60 90] /F 4 >>"
        ])
        try original.write(to: source)
        let live = try NativeFile(source, engine: .mupdf)
        try live.pdfSetEditing(true)
        let rects = [CGRect(x: 40, y: 110, width: 20, height: 20)]
        let initialPixels = try widgetPixels(live, rects: rects)
        try live.pdfSetWidgetValue(page: 0, id: 6, value: "reset")
        XCTAssertEqual(try live.pdfAnnotations(0).first { $0.fieldName == "check" }?.value, "Yes")
        let resetPixels = try widgetPixels(live, rects: rects)
        XCTAssertNotEqual(resetPixels, initialPixels, "A missing imported appearance must still be synthesized")
        let copy = directory.appendingPathComponent("reset-missing-appearance-copy.pdf")
        try live.pdfWrite(to: copy)
        let reopened = try NativeFile(copy, engine: .mupdf)
        XCTAssertEqual(try reopened.pdfAnnotations(0).first { $0.fieldName == "check" }?.value, "Yes")
        XCTAssertEqual(try widgetPixels(reopened, rects: rects), resetPixels)
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try live.pdfAnnotations(0).first { $0.fieldName == "check" }?.value, "Off")
        XCTAssertEqual(try widgetPixels(live, rects: rects), initialPixels)
        XCTAssertFalse(try XCTUnwrap(live.pdfInfo()).dirty)
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try widgetPixels(live, rects: rects), resetPixels)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func widgetPixels(_ file: NativeFile, rects: [CGRect]) throws -> [Data] {
        let image = try file.image(0, width: 400)
        return try rects.map { rect in
            let crop = try XCTUnwrap(image.cropping(to: rect))
            var data = Data(count: crop.width * crop.height * 4)
            try data.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width,
                    height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            return data
        }
    }

    @MainActor func testChoiceExportValueKeepsItsDisplayAppearanceAcrossSaveAndUndo() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("choice.pdf")
        // The /Opt arrays live on parent fields, not their page widgets. The
        // editable combo may also hold a value absent from its option list.
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 8 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Annots [5 0 R 7 0 R] >>",
            "<< /FT /Ch /Ff 131072 /T (choice) /V (one) /Opt [[(one) (First choice)] [(two) (Second choice)]] /Kids [5 0 R] /AA << /V << /S /JavaScript /JS (event.rc = event.value != 'rejected';) >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 4 0 R /Rect [20 120 220 150] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /FT /Ch /Ff 393216 /T (custom) /V (First choice) /Opt [[(one) (First choice)] [(two) (Second choice)]] /Kids [7 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [20 60 220 90] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Fields [4 0 R 6 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 9 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        try original.write(to: source)
        let live = try NativeFile(source, engine: .mupdf)
        try live.pdfSetEditing(true)
        try live.pdfSetWidgetValue(page: 0, id: 5, value: "two")
        try live.pdfSetWidgetValue(page: 0, id: 7, value: "Other typed")
        func values(_ file: NativeFile) throws -> [String: String] {
            Dictionary(uniqueKeysWithValues: try file.pdfAnnotations(0).compactMap { field in
                guard let name = field.fieldName, let value = field.value else { return nil }
                return (name, value)
            })
        }
        XCTAssertEqual(try values(live), ["choice": "two", "custom": "Other typed"])
        try live.pdfUndo(redo: false)
        try live.pdfUndo(redo: false)
        XCTAssertEqual(try values(live), ["choice": "one", "custom": "First choice"])
        try live.pdfUndo(redo: true)
        try live.pdfUndo(redo: true)
        XCTAssertEqual(try values(live), ["choice": "two", "custom": "Other typed"])

        // Branch after undo, rather than only restoring the original redo.
        // Generated appearance resources must survive subsequent new edits.
        try live.pdfUndo(redo: false)
        try live.pdfUndo(redo: false)
        XCTAssertThrowsError(try live.pdfSetWidgetValue(page: 0, id: 5, value: "rejected"))
        XCTAssertEqual(try values(live), ["choice": "one", "custom": "First choice"])
        try live.pdfSetWidgetValue(page: 0, id: 5, value: "two")
        try live.pdfSetWidgetValue(page: 0, id: 7, value: "Other typed")
        XCTAssertEqual(try values(live), ["choice": "two", "custom": "Other typed"])

        let savedURL = directory.appendingPathComponent("choice-saved.pdf")
        try live.pdfWrite(to: savedURL)
        let saved = try XCTUnwrap(PDFDocument(url: savedURL))
        let reopened = try NativeFile(savedURL, engine: .mupdf)
        XCTAssertEqual(try values(reopened), ["choice": "two", "custom": "Other typed"])
        var annotations: CGPDFArrayRef?, rawWidget: CGPDFDictionaryRef?, rawAP: CGPDFDictionaryRef?, rawStream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(saved.page(at: 0)?.pageRef?.dictionary), "Annots", &annotations))
        for (index, expected) in [(0, "Second choice"), (1, "Other typed")] {
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), index, &rawWidget))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(rawWidget), "AP", &rawAP))
            XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(rawAP), "N", &rawStream))
            var format = CGPDFDataFormat.raw
            let appearance = String(decoding: try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(rawStream), &format)) as Data, as: UTF8.self)
            XCTAssertTrue(appearance.contains("(\(expected))"), "The saved field appearance must show its displayed value")
            var resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?, font: CGPDFDictionaryRef?, baseFont: UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(rawStream))), "Resources", &resources))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Font", &fonts))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(fonts), "Helv", &font), "A regenerated field must retain its referenced font object in the saved PDF")
            XCTAssertTrue(CGPDFDictionaryGetName(try XCTUnwrap(font), "BaseFont", &baseFont))
            XCTAssertEqual(String(cString: try XCTUnwrap(baseFont)), "Helvetica")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testFormScriptsSurviveLiveSaveAndReopen() throws {
        let directory = try fixtureDirectory()
        let initialization = "var offset = 5; this.getField('sentinel').value = 'loaded';"
        let keystroke = "event.rc = event.value.indexOf('x') < 0;"
        let calculation = "event.value = Number(this.getField('group.input').value) * 2;"
        // The widget order differs from CO. Scripts include strings, streams,
        // a name tree with children and an inherited field action dictionary.
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 8 0 R /Names << /JavaScript << /Kids [14 0 R 15 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [4 0 R 5 0 R 6 0 R 7 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 17 0 R /Rect [20 300 200 330] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (total) /V (10) /Ff 1 /Rect [20 250 200 280] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) /AA << /C << /S /JavaScript /JS (event.value = Number\\(this.getField\\('middle'\\).value\\) + offset;) >> /F << /S /JavaScript /JS (event.value = 'USD ' + event.value;) >> >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 18 0 R /Rect [20 200 200 230] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (sentinel) /V (untouched) /Rect [20 150 200 180] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Fields [19 0 R 5 0 R 18 0 R 7 0 R] /CO [18 0 R 5 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 9 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /S /JavaScript /JS 11 0 R >>",
            "<< /Length \(initialization.utf8.count) >>\nstream\n\(initialization)\nendstream",
            "<< /Length \(keystroke.utf8.count) >>\nstream\n\(keystroke)\nendstream",
            "<< /Length \(calculation.utf8.count) >>\nstream\n\(calculation)\nendstream",
            "<< /Names [(a-init) 10 0 R] /Limits [(a-init) (a-init)] >>",
            "<< /Names [(b-offset) 16 0 R] /Limits [(b-offset) (b-offset)] >>",
            "<< /S /JavaScript /JS (offset += 1;) >>",
            "<< /FT /Tx /T (input) /Parent 19 0 R /V (2) /Kids [4 0 R] /AA << /K << /S /JavaScript /JS 12 0 R >> /V << /S /JavaScript /JS (event.rc = Number\\(event.value\\) >= 0;) >> >> >>",
            "<< /FT /Tx /T (middle) /V (4) /Ff 1 /Kids [6 0 R] /AA << /C << /S /JavaScript /JS 13 0 R >> >> >>",
            "<< /T (group) /Kids [17 0 R] >>"
        ])
        func widgets(_ document: PDFDocument) throws -> [PDFAnnotation] { try XCTUnwrap(document.page(at: 0)).annotations.filter { $0.type == "Widget" } }
        func value(_ document: PDFDocument, _ name: String) throws -> String? { try widgets(document).first { $0.fieldName == name }?.widgetStringValue }
        func assertSavedStructure(_ document: PDFDocument, file: StaticString = #filePath, line: UInt = #line) throws {
            let catalog = try XCTUnwrap(document.documentRef?.catalog, file: file, line: line)
            var form: CGPDFDictionaryRef?, order: CGPDFArrayRef?, names: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?, entries: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), file: file, line: line)
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "CO", &order), file: file, line: line)
            let orderArray = try XCTUnwrap(order)
            var rawAnnotations: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: 0)?.pageRef?.dictionary), "Annots", &rawAnnotations))
            var input: CGPDFDictionaryRef?, terminal: CGPDFDictionaryRef?, group: CGPDFDictionaryRef?, partialName: CGPDFStringRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(rawAnnotations), 0, &input))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(input), "Parent", &terminal), "A dotted display name must remain a real field hierarchy", file: file, line: line)
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(terminal), "T", &partialName))
            XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(partialName))) as String, "input")
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(terminal), "Parent", &group))
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(group), "T", &partialName))
            XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(partialName))) as String, "group")
            var orderNames = [String]()
            for index in 0..<CGPDFArrayGetCount(orderArray) {
                var field: CGPDFDictionaryRef?, name: CGPDFStringRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(orderArray, index, &field), file: file, line: line)
                XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "T", &name), file: file, line: line)
                orderNames.append(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(name))) as String)
                if index < 2 {
                    var widget: CGPDFDictionaryRef?
                    XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(rawAnnotations), [2, 1][index], &widget))
                    if index == 0 {
                        var parent: CGPDFDictionaryRef?
                        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(widget), "Parent", &parent))
                        XCTAssertEqual(field, parent, "CO names the terminal field shared by the widget", file: file, line: line)
                    } else { XCTAssertEqual(field, widget, file: file, line: line) }
                }
            }
            XCTAssertEqual(orderNames, ["middle", "total"], file: file, line: line)
            XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Names", &names), file: file, line: line)
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(names), "JavaScript", &tree), file: file, line: line)
            var children: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(tree), "Kids", &children), file: file, line: line)
            XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(children)), 2, file: file, line: line)
            for index in 0..<2 {
                var child: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(children), index, &child))
                XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(child), "Names", &entries))
                XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(entries)), 2)
            }
            XCTAssertEqual(try XCTUnwrap(document.page(at: 0)).annotations.count, 4, file: file, line: line)
        }

        let source = directory.appendingPathComponent("scripts.pdf"), saved = directory.appendingPathComponent("saved-scripts.pdf")
        try original.write(to: source)
        XCTAssertEqual(try value(XCTUnwrap(PDFDocument(data: original)), "sentinel"), "untouched")
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        try document.pdfSetWidgetValue(page: 0, id: 4, value: "7")
        XCTAssertEqual(try document.pdfAnnotations(0).first { $0.fieldName == "middle" }?.value, "14")
        XCTAssertEqual(try document.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "20")
        XCTAssertEqual(try document.pdfAnnotations(0).first { $0.fieldName == "sentinel" }?.value, "loaded")
        try document.pdfWrite(to: saved)
        let independent = try XCTUnwrap(PDFDocument(url: saved))
        try assertSavedStructure(independent)
        XCTAssertEqual(try value(independent, "group.input"), "7")
        let resumed = try NativeFile(saved, engine: .mupdf)
        try resumed.pdfSetEditing(true)
        try resumed.pdfSetWidgetValue(page: 0, id: 4, value: "8")
        XCTAssertEqual(try resumed.pdfAnnotations(0).first { $0.fieldName == "middle" }?.value, "16")
        XCTAssertEqual(try resumed.pdfAnnotations(0).first { $0.fieldName == "total" }?.value, "22", "CO ordering and document globals survive save/reopen")
        XCTAssertThrowsError(try resumed.pdfSetWidgetValue(page: 0, id: 4, value: "-1"))
        XCTAssertThrowsError(try resumed.pdfSetWidgetValue(page: 0, id: 4, value: "x"))
        let savedAgain = directory.appendingPathComponent("saved-again.pdf")
        try resumed.pdfWrite(to: savedAgain)
        try assertSavedStructure(XCTUnwrap(PDFDocument(url: savedAgain)))
        XCTAssertEqual(try value(XCTUnwrap(PDFDocument(url: savedAgain)), "total"), "22")
        XCTAssertEqual(try document.pdfAnnotations(0).first { $0.fieldName == "group.input" }?.value, "7")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testPlainFormFieldReferencesStayUnifiedAcrossRepeatedEdits() throws {
        let directory = try fixtureDirectory()
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (input) /V (original) /Rect [20 300 200 330] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Fields [4 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        func assertField(_ document: PDFDocument, equals value: String) throws {
            var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, annotations: CGPDFArrayRef?, field: CGPDFDictionaryRef?, widget: CGPDFDictionaryRef?, stored: CGPDFStringRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(document.documentRef?.catalog), "AcroForm", &form))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 0, &field))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: 0)?.pageRef?.dictionary), "Annots", &annotations))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &widget))
            XCTAssertEqual(field, widget, "The field tree and page must share one editable widget")
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "V", &stored))
            XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(stored))) as String, value)
            XCTAssertEqual(document.page(at: 0)?.annotations.first?.widgetStringValue, value)
        }
        let source = directory.appendingPathComponent("plain-form.pdf"), first = directory.appendingPathComponent("first.pdf"), second = directory.appendingPathComponent("second.pdf")
        try original.write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        try document.pdfSetWidgetValue(page: 0, id: 4, value: "first edit")
        try document.pdfWrite(to: first)
        try assertField(XCTUnwrap(PDFDocument(url: first)), equals: "first edit")
        let reopened = try NativeFile(first, engine: .mupdf)
        try reopened.pdfSetEditing(true)
        try reopened.pdfSetWidgetValue(page: 0, id: 4, value: "second edit")
        try reopened.pdfWrite(to: second)
        try assertField(XCTUnwrap(PDFDocument(url: second)), equals: "second edit")
        XCTAssertEqual(try document.pdfAnnotations(0).first?.value, "first edit")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testNestedFieldKeepsDistinctWidgetsOnTwoPages() throws {
        let directory = try fixtureDirectory()
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 7 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [6 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /Rect [20 300 200 330] /F 4 /P 3 0 R >>",
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /Rect [20 300 200 330] /F 4 /P 4 0 R >>",
            "<< /Fields [9 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 10 0 R >> >> >>",
            "<< /T (value) /Parent 9 0 R /FT /Tx /V (initial) /DA (/Helv 12 Tf 0 g) /Kids [5 0 R 6 0 R] >>",
            "<< /T (group) /Kids [8 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        func assertWidgets(_ document: PDFDocument, value: String) throws {
            var rawWidgets = [CGPDFDictionaryRef](), parents = [CGPDFDictionaryRef]()
            for index in 0..<2 {
                let page = try XCTUnwrap(document.page(at: index))
                var annotations: CGPDFArrayRef?, widget: CGPDFDictionaryRef?, parent: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(page.pageRef?.dictionary), "Annots", &annotations))
                XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(annotations)), 1)
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &widget))
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(widget), "Parent", &parent))
                rawWidgets.append(try XCTUnwrap(widget)); parents.append(try XCTUnwrap(parent))
                XCTAssertEqual(page.annotations.first?.fieldName, "group.value")
                XCTAssertEqual(page.annotations.first?.widgetStringValue, value)
            }
            XCTAssertNotEqual(rawWidgets[0], rawWidgets[1], "Distinct page widgets must never be deduplicated by name or geometry")
            XCTAssertEqual(parents[0], parents[1], "Widgets of the same original field must share its value")
        }
        let source = directory.appendingPathComponent("nested.pdf"), output = directory.appendingPathComponent("updated.pdf")
        try original.write(to: source)
        try assertWidgets(XCTUnwrap(PDFDocument(url: source)), value: "initial")
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        try document.pdfSetWidgetValue(page: 1, id: 6, value: "updated")
        XCTAssertEqual(try document.pdfAnnotations(0).first?.value, "updated")
        XCTAssertEqual(try document.pdfAnnotations(1).first?.value, "updated")
        try document.pdfWrite(to: output)
        try assertWidgets(XCTUnwrap(PDFDocument(url: output)), value: "updated")
        let reopened = try NativeFile(output, engine: .mupdf)
        try reopened.pdfSetEditing(true)
        try reopened.pdfSetWidgetValue(page: 0, id: 5, value: "reopened edit")
        let next = directory.appendingPathComponent("updated-again.pdf")
        try reopened.pdfWrite(to: next)
        try assertWidgets(XCTUnwrap(PDFDocument(url: next)), value: "reopened edit")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testAdvancedLiveAnnotationsPreserveSubtypeGeometryAndAppearance() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("annotations.pdf")
        try rawPDF(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] >>"]).write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        let types = ["Squiggly", "Caret", "Stamp", "Polygon", "PolyLine", "FileAttachment", "Redact"]
        let asset = directory.appendingPathComponent("attached.txt"), payload = Data("attachment bytes".utf8)
        try payload.write(to: asset)
        for (index, type) in types.enumerated() {
            var edits: [PDFAnnotationEdit] = [.color(SIMD3<Float>(1, 0, 0), interior: false)]
            if type == "Stamp" { edits.append(.icon("Draft")) }
            if ["Polygon", "PolyLine"].contains(type) { edits.append(.vertices([CGPoint(x: 40, y: 100), CGPoint(x: 100, y: 60), CGPoint(x: 200, y: 100)])) }
            if ["Squiggly", "Redact"].contains(type) {
                edits.append(.quads([.init(upperLeft: CGPoint(x: 40, y: 60), upperRight: CGPoint(x: 200, y: 60),
                                           lowerLeft: CGPoint(x: 40, y: 100), lowerRight: CGPoint(x: 200, y: 100))]))
            }
            if type == "FileAttachment" { edits.append(.attachment(asset, filename: "attached.txt", mime: "text/plain")) }
            let id = try document.pdfCreateAnnotation(page: 0, type: type, bounds: CGRect(x: 40, y: 60, width: 160, height: 40), edits: edits)
            let result = try XCTUnwrap(document.pdfAnnotations(0).first { $0.id == id })
            XCTAssertEqual(result.type, type)
            XCTAssertTrue(result.bounds.width.isFinite && result.bounds.height.isFinite, type)
            XCTAssertLessThan(result.bounds.width, 200, type); XCTAssertLessThan(result.bounds.height, 80, type)
            XCTAssertEqual(try document.pdfAnnotations(0).count, index + 1)
        }
        let output = directory.appendingPathComponent("saved-annotations.pdf")
        try document.pdfWrite(to: output)
        let saved = try XCTUnwrap(PDFDocument(url: output)), savedPage = try XCTUnwrap(saved.page(at: 0))
        // pdf_create_annot(FileAttachment) also creates its structural Popup.
        // MuPDF deliberately does not synthesize an AP for Popup annotations.
        XCTAssertEqual(Set(savedPage.annotations.compactMap(\.type)), Set(types + ["Popup"]))
        let dictionary = try XCTUnwrap(savedPage.pageRef?.dictionary)
        var annotations: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
        let raw = try XCTUnwrap(annotations)
        XCTAssertEqual(CGPDFArrayGetCount(raw), types.count + 1)
        for index in 0..<CGPDFArrayGetCount(raw) {
            var annotation: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(raw, index, &annotation))
            let object = try XCTUnwrap(annotation)
            var subtype: UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetName(object, "Subtype", &subtype))
            let type = String(cString: try XCTUnwrap(subtype))
            if type == "Popup" {
                var parent: CGPDFDictionaryRef?, linkedPopup: CGPDFDictionaryRef?, parentSubtype: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFDictionaryGetDictionary(object, "Parent", &parent))
                let attachment = try XCTUnwrap(parent)
                XCTAssertTrue(CGPDFDictionaryGetName(attachment, "Subtype", &parentSubtype))
                XCTAssertEqual(String(cString: try XCTUnwrap(parentSubtype)), "FileAttachment")
                XCTAssertTrue(CGPDFDictionaryGetDictionary(attachment, "Popup", &linkedPopup))
                XCTAssertEqual(linkedPopup, object, "The popup and attachment must retain their mutual references")
                XCTAssertFalse(CGPDFDictionaryGetDictionary(object, "AP", &appearance))
                continue
            }
            XCTAssertTrue(types.contains(type))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(object, "AP", &appearance), type)
            XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &stream))
        }
        let reopened = try NativeFile(output, engine: .mupdf)
        let visibleAnnotations = try reopened.pdfAnnotations(0)
        XCTAssertEqual(visibleAnnotations.count, types.count)
        XCTAssertEqual(Set(visibleAnnotations.map(\.type)), Set(types), "MuPDF must keep the structural Popup out of the reader's annotation list")
        XCTAssertEqual(try reopened.pdfAttachments().first?.name, "attached.txt")
        XCTAssertEqual(try reopened.pdfAttachments().first?.data, payload)
        let next = directory.appendingPathComponent("saved-again.pdf")
        try reopened.pdfWrite(to: next)
        XCTAssertEqual(try NativeFile(next, engine: .mupdf).pdfAttachments().first?.data, payload)
    }

    @MainActor func testAnnotationOpacityUsesNativeAppearanceAndSurvivesSaving() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("opacity.pdf"), output = directory.appendingPathComponent("saved-opacity.pdf")
        try rawPDF(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>"]).write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        let id = try document.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 30, y: 60, width: 100, height: 40),
            edits: [.color(SIMD3<Float>(1, 0, 0), interior: true), .opacity(0.35)])
        XCTAssertEqual(try XCTUnwrap(document.pdfAnnotations(0).first).opacity, 0.35, accuracy: 0.0001)
        let before = try XCTUnwrap(document.pdfInfo())
        XCTAssertThrowsError(try document.pdfEditAnnotation(page: 0, id: id, edits: [.opacity(.nan)]))
        XCTAssertEqual(try XCTUnwrap(document.pdfInfo()).undoPosition, before.undoPosition)
        try document.pdfWrite(to: output)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        var annotations: CGPDFArrayRef?, stored: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(saved.page(at: 0)?.pageRef?.dictionary), "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &stored))
        var opacity: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(try XCTUnwrap(stored), "CA", &opacity))
        XCTAssertEqual(opacity, 0.35, accuracy: 0.0001)
        XCTAssertTrue(saved.page(at: 0)?.annotations.first?.hasAppearanceStream == true)
        XCTAssertEqual(try XCTUnwrap(NativeFile(output, engine: .mupdf).pdfAnnotations(0).first).opacity, 0.35, accuracy: 0.0001)
    }

    @MainActor func testReadingAndSavingDoNotDecodeAnAttachment() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("unknown-filter.pdf"), output = directory.appendingPathComponent("saved.pdf")
        let input = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [20 30 40 50] /FS 5 0 R >>",
            "<< /Type /Filespec /F (broken.bin) /EF << /F 6 0 R >> >>",
            "<< /Length 4 /Filter /UnknownDecode >>\nstream\nnope\nendstream"
        ])
        try input.write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        XCTAssertEqual(document.count, 1)
        _ = try document.image(0, width: 300)
        try document.pdfSetEditing(true)
        try document.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("edited")])
        try document.pdfWrite(to: output)
        let bytes = try Data(contentsOf: output)
        XCTAssertTrue(bytes.starts(with: input), "Saving retains the encoded attachment without decoding its unknown filter")
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.page(at: 0)?.annotations.first?.contents, "edited")
        let raw = try primaryActionAnnotation(saved, page: 0, index: 0)
        var spec: CGPDFDictionaryRef?, embedded: CGPDFDictionaryRef?, stream: CGPDFStreamRef?, filter: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(raw, "FS", &spec))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(spec), "EF", &embedded))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(embedded), "F", &stream))
        XCTAssertTrue(CGPDFDictionaryGetName(try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(stream))), "Filter", &filter))
        XCTAssertEqual(filter.map { String(cString: $0) }, "UnknownDecode")
        XCTAssertEqual(try Data(contentsOf: source), input)
    }

    @MainActor func testSaveKeepsCompressedAttachmentWithoutMaterializingItsContents() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("large-attachment.pdf"), output = directory.appendingPathComponent("saved.pdf")
        let size = 65 * 1_048_576
        let compressed = String(repeating: "8141", count: size / 128) + "80>"
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [20 30 40 50] /Contents (original) /FS 5 0 R >>",
            "<< /Type /Filespec /F (large.bin) /EF << /F 6 0 R >> >>",
            "<< /Length \(compressed.utf8.count) /DL \(size) /Filter [/ASCIIHexDecode /RunLengthDecode] >>\nstream\n\(compressed)\nendstream"
        ])
        try bytes.write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        try document.pdfEditAnnotation(page: 0, id: 4, edits: [.contents("edited note")])
        try document.pdfWrite(to: output)
        XCTAssertLessThan(try Data(contentsOf: output).count, 4 * 1_048_576, "Save keeps the compressed stream instead of materializing 65 MiB")
        let independent = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(independent.page(at: 0)?.annotations.first?.contents, "edited note")
        let reopened = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(try reopened.pdfAttachments().first?.data.count, size)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor func testReplacingEncryptedAttachmentKeepsTheNewFileAndOriginalActions() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("original.pdf")
        let encrypted = directory.appendingPathComponent("encrypted.pdf"), asset = directory.appendingPathComponent("new.bin")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /FileAttachment /Rect [20 30 40 50] /FS 5 0 R /AA << /U << /S /URI /URI (https://example.org/original) >> >> >>",
            "<< /Type /Filespec /F (old.bin) /EF << /F 6 0 R >> >>",
            "<< /Length 3 >>\nstream\nold\nendstream"
        ])
        try bytes.write(to: source)
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader")
        let protected = try Data(contentsOf: encrypted)
        let document = try NativeFile(encrypted, engine: .mupdf, password: "owner")
        try document.pdfSetEditing(true)
        let replacementBytes = Data("replacement payload".utf8)
        try replacementBytes.write(to: asset)
        try document.pdfEditAnnotation(page: 0, id: 4, edits: [.attachment(asset, filename: "new.bin", mime: "application/octet-stream")])
        let output = directory.appendingPathComponent("replaced.pdf")
        try document.pdfWrite(to: output)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(saved.isEncrypted); XCTAssertTrue(saved.unlock(withPassword: "owner"))
        let reopened = try NativeFile(output, engine: .mupdf, password: "owner")
        XCTAssertEqual(try reopened.pdfAttachments().first?.data, replacementBytes)
        var annots: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?, additional: CGPDFDictionaryRef?, action: CGPDFDictionaryRef?, uri: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(saved.page(at: 0)?.pageRef?.dictionary), "Annots", &annots))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annots), 0, &annotation))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(annotation), "AA", &additional))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(additional), "U", &action))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(action), "URI", &uri))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(uri))) as String, "https://example.org/original")
        let again = directory.appendingPathComponent("replaced-again.pdf")
        try reopened.pdfWrite(to: again)
        XCTAssertEqual(try NativeFile(again, engine: .mupdf, password: "owner").pdfAttachments().first?.data, replacementBytes)
        let target = directory.appendingPathComponent("clipboard-target.pdf"), pasted = directory.appendingPathComponent("pasted.pdf")
        try rawPDF(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>"]).write(to: target)
        let destination = try NativeFile(target, engine: .mupdf)
        try destination.pdfSetEditing(true)
        let copied = try document.pdfAttachment(page: 0, id: 4)
        try copied.data.write(to: asset)
        _ = try destination.pdfPasteAnnotation(.init(page: 0, type: "FileAttachment", bounds: CGRect(x: 20, y: 30, width: 20, height: 20),
            edits: [.attachment(asset, filename: copied.name, mime: "application/octet-stream")]))
        try FileManager.default.removeItem(at: asset)
        try destination.pdfWrite(to: pasted)
        XCTAssertEqual(try NativeFile(pasted, engine: .mupdf).pdfAttachments().first?.data, replacementBytes)
        XCTAssertEqual(try Data(contentsOf: encrypted), protected)
    }

    @MainActor func testMixedAdditionalActionChainsSurviveLiveEditsAndSaving() throws {
        let directory = try fixtureDirectory()
        for chained in [false, true] {
            let source = directory.appendingPathComponent("actions-\(chained).pdf"), output = directory.appendingPathComponent("saved-\(chained).pdf")
            let bytes = rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>",
                "<< /Type /Annot /Subtype /Link /Rect [20 30 40 50] /AA << /U 6 0 R >> >>",
                "<< /S /JavaScript /JS (var unchanged = 1;) /Next \(chained ? "7 0 R" : "[7 0 R 8 0 R]") >>",
                "<< /S /GoTo /D [4 0 R /Fit] \(chained ? "/Next 8 0 R" : "") >>",
                "<< /S /URI /URI (https://example.org/after) >>"
            ])
            try bytes.write(to: source)
            let document = try NativeFile(source, engine: .mupdf)
            try document.pdfSetEditing(true)
            try document.pdfEditLink(page: 0, id: 5, bounds: CGRect(x: 30, y: 340, width: 20, height: 20), uri: nil)
            try document.pdfWrite(to: output)
            let saved = try XCTUnwrap(PDFDocument(url: output))
            let annotation = try primaryActionAnnotation(saved, page: 0, index: 0)
            var additional: CGPDFDictionaryRef?, head: CGPDFDictionaryRef?, go: CGPDFDictionaryRef?, uri: CGPDFDictionaryRef?, script: CGPDFStringRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(annotation, "AA", &additional))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(additional), "U", &head))
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(head), "JS", &script))
            XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(script))) as String, "var unchanged = 1;")
            if chained {
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(head), "Next", &go))
                XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(go), "Next", &uri))
            } else {
                var next: CGPDFArrayRef?
                XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(head), "Next", &next))
                XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(next)), 2)
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(next), 0, &go))
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(next), 1, &uri))
            }
            var destination: CGPDFArrayRef?, target: CGPDFDictionaryRef?, address: CGPDFStringRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(go), "D", &destination))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(destination), 0, &target))
            XCTAssertEqual(target, saved.page(at: 1)?.pageRef?.dictionary)
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(uri), "URI", &address))
            XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(address))) as String, "https://example.org/after")
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    @MainActor func testPrimaryActionNextSurvivesOrdinarySave() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("primary.pdf"), output = directory.appendingPathComponent("saved.pdf")
        try primaryActionFixture().write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        try document.pdfEditLink(page: 0, id: 5, bounds: CGRect(x: 30, y: 340, width: 60, height: 20), uri: nil)
        try document.pdfWrite(to: output)
        try assertPrimaryActionChains(XCTUnwrap(PDFDocument(url: output)), sourcePage: 0, targetPage: 1)
    }

    @MainActor func testPrimaryActionNextSurvivesReorderAndDuplicatedPages() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("primary.pdf"), output = directory.appendingPathComponent("reordered.pdf")
        try primaryActionFixture().write(to: source)
        try NativePDFTools.selectPages(source: source, destination: output, pages: [1, 0, 1])
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.pageCount, 3)
        try assertPrimaryActionChains(saved, sourcePage: 1, targetPage: 0)
    }

    @MainActor func testChangingPrimaryActionKeepsTheNewURLInsteadOfTheOriginalGraph() throws {
        let directory = try fixtureDirectory()
        for index in [0, 1] { // GoTo and an opaque JavaScript head.
            let source = directory.appendingPathComponent("primary-\(index).pdf"), output = directory.appendingPathComponent("edited-\(index).pdf")
            try primaryActionFixture().write(to: source)
            let document = try NativeFile(source, engine: .mupdf)
            try document.pdfSetEditing(true)
            try document.pdfEditLink(page: 0, id: Int32(5 + index), bounds: CGRect(x: 20, y: 300, width: 60, height: 20), uri: "https://example.org/edited")
            try document.pdfWrite(to: output)
            let saved = try XCTUnwrap(PDFDocument(url: output))
            let raw = try primaryActionAnnotation(saved, page: 0, index: index)
            var action: CGPDFDictionaryRef?, type: UnsafePointer<CChar>?, uri: CGPDFStringRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(raw, "A", &action))
            XCTAssertTrue(CGPDFDictionaryGetName(try XCTUnwrap(action), "S", &type))
            XCTAssertEqual(type.map { String(cString: $0) }, "URI")
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(action), "URI", &uri))
            XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(uri))) as String, "https://example.org/edited")
            XCTAssertFalse(CGPDFDictionaryGetObject(try XCTUnwrap(action), "Next", nil))
        }
    }

    @MainActor func testDeletingLinksDoesNotRestoreTheirOriginalActionGraphs() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("primary.pdf"), output = directory.appendingPathComponent("deleted.pdf")
        try primaryActionFixture().write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        for id: Int32 in [5, 6] { try document.pdfDeleteLink(page: 0, id: id) }
        try document.pdfWrite(to: output)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(try XCTUnwrap(saved.page(at: 0)).annotations.isEmpty)
        XCTAssertTrue(try NativeFile(output, engine: .mupdf).pdfLinks(0).isEmpty)
    }

    @MainActor func testDeletingPrimaryGoToTargetRemovesItsLinkAsUpstreamDoes() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("primary.pdf"), output = directory.appendingPathComponent("deleted-page.pdf")
        try primaryActionFixture().write(to: source)
        try NativePDFTools.selectPages(source: source, destination: output, pages: [0])
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.pageCount, 1)
        // pdf-clean-file.c removes a Link whose primary GoTo points outside
        // the retained page set. It does not recursively rewrite opaque JS.
        XCTAssertEqual(saved.page(at: 0)?.annotations.count, 1)
        let annotation = try primaryActionAnnotation(saved, page: 0, index: 0)
        var action: CGPDFDictionaryRef?, script: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(annotation, "A", &action))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(action), "JS", &script))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(script))) as String, "var before = 1;")
    }

    private func primaryActionFixture() -> Data {
        rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Annots [5 0 R 6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 30 80 50] /A 7 0 R >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 70 80 90] /A 10 0 R >>",
            "<< /S /GoTo /D [4 0 R /Fit] /Next [8 0 R 9 0 R] >>",
            "<< /S /URI /URI (https://example.org/after) >>",
            "<< /S /JavaScript /JS (var retained = 1;) >>",
            "<< /S /JavaScript /JS (var before = 1;) /Next 11 0 R >>",
            "<< /S /GoTo /D [4 0 R /Fit] >>"
        ])
    }

    @MainActor private func primaryActionAnnotation(_ document: PDFDocument, page: Int, index: Int) throws -> CGPDFDictionaryRef {
        var annotations: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(document.page(at: page)?.pageRef?.dictionary), "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), index, &annotation))
        return try XCTUnwrap(annotation)
    }

    @MainActor private func assertPrimaryActionChains(_ document: PDFDocument, sourcePage: Int, targetPage: Int) throws {
        func target(_ action: CGPDFDictionaryRef) throws -> CGPDFDictionaryRef {
            var destination: CGPDFArrayRef?, page: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(action, "D", &destination))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(destination), 0, &page))
            return try XCTUnwrap(page)
        }
        let expectedTarget = try XCTUnwrap(document.page(at: targetPage)?.pageRef?.dictionary)
        let first = try primaryActionAnnotation(document, page: sourcePage, index: 0)
        var action: CGPDFDictionaryRef?, next: CGPDFArrayRef?, uriAction: CGPDFDictionaryRef?, scriptAction: CGPDFDictionaryRef?, text: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(first, "A", &action))
        XCTAssertEqual(try target(XCTUnwrap(action)), expectedTarget, "The primary action must reference the actual first retained copy of its destination")
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(action), "Next", &next))
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(next)), 2)
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(next), 0, &uriAction))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(uriAction), "URI", &text))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(text))) as String, "https://example.org/after")
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(next), 1, &scriptAction))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(scriptAction), "JS", &text))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(text))) as String, "var retained = 1;")

        let second = try primaryActionAnnotation(document, page: sourcePage, index: 1)
        var head: CGPDFDictionaryRef?, nestedGoTo: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(second, "A", &head))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(head), "JS", &text))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(text))) as String, "var before = 1;")
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(head), "Next", &nestedGoTo))
        XCTAssertEqual(try target(XCTUnwrap(nestedGoTo)), expectedTarget, "A destination in Next must also reference an actual output page")
    }

    @MainActor func testImageStampOpacityPreservesArtworkIncludingAfterZeroOpacity() throws {
        let directory = try fixtureDirectory(), asset = directory.appendingPathComponent("stamp.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in stride(from: 0, to: 8 * 8 * 4, by: 4) {
            pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 255; pixels[index + 3] = 255
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: asset)
        let source = directory.appendingPathComponent("stamp.pdf"), output = directory.appendingPathComponent("saved-stamp.pdf")
        try rawPDF(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"]).write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        let id = try document.pdfCreateAnnotation(page: 0, type: "Stamp", bounds: CGRect(x: 20, y: 30, width: 80, height: 80),
            edits: [.stampImage(asset), .opacity(0.4)])
        func blueComponent(_ page: PDFPage) throws -> Int {
            let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            page.draw(with: .mediaBox, to: context)
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return stride(from: 0, to: 200 * 200 * 4, by: 4).filter { pixels[$0 + 2] == 255 && pixels[$0] == pixels[$0 + 1] }
                .map { Int(pixels[$0]) }.min() ?? 255
        }
        for opacity: Float in [0.4, 0.7, 0, 1] {
            try document.pdfEditAnnotation(page: 0, id: id, edits: [.opacity(opacity)])
            try document.pdfWrite(to: output)
            let saved = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(try blueComponent(XCTUnwrap(saved.page(at: 0))), Int((1 - opacity) * 255), accuracy: 2)
        }
    }

    @MainActor func testApplyRedactionsRemovesUnderlyingTextAndPreservesOtherContent() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("marked.pdf"), output = directory.appendingPathComponent("redacted.pdf")
        let stream = "BT /F1 20 Tf 30 280 Td (SECRET) Tj ET\nBT /F1 20 Tf 30 100 Td (public) Tj ET\n"
        let input = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Redact /Rect [20 260 140 310] /F 4 /P 3 0 R >>"
        ])
        try input.write(to: source)
        try NativePDFTools.transform(source: source, destination: output, operation: .redact)
        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertFalse(result.string?.contains("SECRET") ?? true)
        XCTAssertTrue(result.string?.contains("public") ?? false)
        XCTAssertFalse(result.page(at: 0)?.annotations.contains { $0.type == "Redact" } ?? true)
        XCTAssertEqual(try Data(contentsOf: source), input)
        XCTAssertThrowsError(try NativePDFTools.transform(source: output, destination: directory.appendingPathComponent("again.pdf"), operation: .redact))
    }

    @MainActor func testSavingRedactionMarksPreservesContentFormsLinksAndOutlineUntilApply() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("original-marks.pdf"), output = directory.appendingPathComponent("saved-marks.pdf")
        let stream = "BT /F1 20 Tf 30 280 Td (SECRET) Tj ET\nBT /F1 20 Tf 30 100 Td (public) Tj ET\n"
        let input = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /Outlines 9 0 R /AcroForm << /Fields [8 0 R] /DA (/F1 12 Tf 0 g) /DR << /Font << /F1 5 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R 8 0 R] >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Redact /Rect [20 260 140 310] /F 4 /P 3 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 250] /Resources << >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (original) /Rect [20 150 180 180] /P 3 0 R /F 4 /DA (/F1 12 Tf 0 g) >>",
            "<< /Type /Outlines /First 10 0 R /Last 10 0 R /Count 1 >>",
            "<< /Title (Second page) /Parent 9 0 R /Dest [7 0 R /XYZ 0 0 null] >>"
        ])
        try input.write(to: source)
        let document = try NativeFile(source, engine: .mupdf)
        try document.pdfSetEditing(true)
        try document.pdfSetWidgetValue(page: 0, id: 8, value: "edited")
        _ = try document.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 40, y: 110, width: 20, height: 20),
            edits: [.contents("Keep until Apply")])
        _ = try document.pdfCreateLink(page: 0, bounds: CGRect(x: 20, y: 330, width: 100, height: 20), uri: "https://example.org/")
        let before = try XCTUnwrap(document.pdfInfo()), annotationIDs = try document.pdfAnnotations(0).map(\.id)
        try document.pdfWrite(to: output)
        let saved = try XCTUnwrap(PDFDocument(url: output)), savedPage = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertEqual(saved.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 250))
        XCTAssertTrue(saved.string?.contains("SECRET") == true)
        XCTAssertTrue(savedPage.annotations.contains { $0.type == "Redact" })
        XCTAssertTrue(savedPage.annotations.contains { $0.contents == "Keep until Apply" })
        XCTAssertEqual(savedPage.annotations.first { $0.fieldName == "name" }?.widgetStringValue, "edited")
        XCTAssertEqual((savedPage.annotations.first { $0.type == "Link" }?.action as? PDFActionURL)?.url?.absoluteString, "https://example.org/")
        XCTAssertEqual(saved.outlineRoot?.child(at: 0)?.label, "Second page")
        XCTAssertTrue(saved.outlineRoot?.child(at: 0)?.destination?.page === saved.page(at: 1))
        XCTAssertEqual(try document.pdfAnnotations(0).map(\.id), annotationIDs)
        XCTAssertEqual(try XCTUnwrap(document.pdfInfo()).undoPosition, before.undoPosition)
        XCTAssertEqual(try XCTUnwrap(document.pdfInfo()).dirty, before.dirty)
        XCTAssertTrue(try document.text(0)?.contains("SECRET") == true)
        XCTAssertEqual(try document.pdfAnnotations(0).first { $0.fieldName == "name" }?.value, "edited")
        let flattenedURL = directory.appendingPathComponent("flattened.pdf")
        try NativePDFTools.transform(source: output, destination: flattenedURL, operation: .flatten)
        let flattened = try XCTUnwrap(PDFDocument(url: flattenedURL))
        XCTAssertTrue(flattened.string?.contains("SECRET") == true, "Flatten draws marks without applying redactions")
        XCTAssertFalse(flattened.page(at: 0)?.annotations.contains { $0.type == "Redact" } ?? true)
        XCTAssertEqual(flattened.page(at: 0)?.annotations.first { $0.fieldName == "name" }?.widgetStringValue, "edited")
        let applied = directory.appendingPathComponent("applied.pdf")
        try NativePDFTools.transform(source: output, destination: applied, operation: .redact)
        let result = try XCTUnwrap(PDFDocument(url: applied))
        XCTAssertFalse(result.string?.contains("SECRET") ?? true)
        XCTAssertTrue(result.string?.contains("public") == true)
        XCTAssertTrue(try document.text(0)?.contains("SECRET") == true)
        XCTAssertEqual(try Data(contentsOf: source), input)
    }

    @MainActor func testAttachedCMSEnvelopeOpensPDFAndPreservesInput() async throws {
        let directory = try fixtureDirectory(), pdf = try makePDF(in: directory)
        _ = try signingIdentity(in: directory)
        let envelope = directory.appendingPathComponent("document.p7m")
        let created = try openssl(["cms", "-sign", "-binary", "-nodetach", "-in", pdf.path,
            "-signer", directory.appendingPathComponent("certificate.pem").path,
            "-inkey", directory.appendingPathComponent("identity.key").path,
            "-outform", "DER", "-out", envelope.path])
        XCTAssertEqual(created.status, 0, created.output)
        let original = try Data(contentsOf: envelope)
        let reading = try ReadingDocument.open(envelope)
        guard case .pages(let document) = reading.content, document.isPDF else { return XCTFail("CMS content should use MuPDF") }
        let count = await document.count, source = document.pdfSourceURL
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reading.settingsFormat, "pdf")
        XCTAssertNotNil(reading.temporary)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: pdf))
        XCTAssertEqual(try Data(contentsOf: envelope), original)
        let separateSource = reading.hasSeparatePDFSource
        XCTAssertTrue(separateSource)
        let state = ReaderState(recordsHistory: false)
        state.document = reading
        XCTAssertFalse(state.canSave, "Save must preserve the signed P7M container")
        state.document = nil
        state.windowClosed()
        try await document.pdfSetEditing(true)
        _ = try await document.pdfCreateAnnotation(page: 0, type: "Text", bounds: CGRect(x: 40, y: 40, width: 20, height: 20),
                                                   edits: [.contents("P7M live PDF edit")])
        let before = try await document.pdfInfo()
        let originalCopy = directory.appendingPathComponent("container-copy.p7m")
        let pdfCopy = directory.appendingPathComponent("edited-copy.pdf")
        try Data("Existing container output".utf8).write(to: originalCopy)
        try await reading.saveCopy(to: originalCopy, originalFile: true)
        try await reading.saveCopy(to: pdfCopy)
        XCTAssertEqual(try Data(contentsOf: originalCopy), original)
        let saved = try XCTUnwrap(PDFDocument(url: pdfCopy))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertTrue(saved.page(at: 0)?.annotations.contains { $0.contents == "P7M live PDF edit" } == true)
        XCTAssertEqual(try Data(contentsOf: envelope), original)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: pdf))
        for destination in [envelope, source] {
            do { try await reading.saveCopy(to: destination, originalFile: true); XCTFail("Neither input may be overwritten") }
            catch { XCTAssertTrue(error.localizedDescription.contains("different location"), error.localizedDescription) }
        }
        try FileManager.default.removeItem(at: envelope)
        try await reading.saveCopy(to: originalCopy, originalFile: true)
        XCTAssertEqual(try Data(contentsOf: originalCopy), original)
        let after = try await document.pdfInfo()
        XCTAssertEqual(after?.dirty, true)
        XCTAssertEqual(after?.undoPosition, before?.undoPosition)
        XCTAssertEqual(after?.undoSteps, before?.undoSteps)
        let sentinel = directory.appendingPathComponent("unchanged.pdf")
        try Data("unchanged".utf8).write(to: sentinel)
        XCTAssertThrowsError(try NativePDFTools.unwrap(source: pdf, destination: sentinel))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        withExtendedLifetime(reading) {}
    }
    @MainActor func testLeadingPDFWithMobiTextAtCreatorOffsetUsesPDF() async throws {
        let directory = try fixtureDirectory()
        let beginning = "leading bytes\n%PDF-1.7\n%"
        let prefixes = [
            beginning + String(repeating: " ", count: 60 - beginning.utf8.count) + "BOOKMOBI\n",
            String(repeating: " ", count: 60) + "BOOKMOBI\n" + String(repeating: " ", count: 31)
        ]
        for prefix in prefixes {
            let original = rawPDF([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>"
            ], prefix: prefix)
            XCTAssertEqual(original.subdata(in: 60..<68), Data("BOOKMOBI".utf8))
            XCTAssertEqual(try XCTUnwrap(PDFDocument(data: original)).pageCount, 2, "The independent PDF parser accepts the complete fixture")
            for suffix in ["pdf", "p7m"] {
                let url = directory.appendingPathComponent("mobi-comment." + suffix)
                try original.write(to: url)
                let inspected = try Format.inspect(url, prefix: Data(original.prefix(2048)))
                XCTAssertEqual(inspected.format, .pdf, suffix)
                guard inspected.format == .pdf else { continue }
                let reading = try ReadingDocument.open(url)
                guard case .pages(let pages) = reading.content, pages.isPDF else { return XCTFail("Expected direct PDF") }
                let count = await pages.count
                XCTAssertEqual(count, 2, suffix)
                XCTAssertEqual(pages.pdfSourceURL, url)
                XCTAssertNil(reading.temporary)
                XCTAssertFalse(reading.hasSeparatePDFSource)
                XCTAssertEqual(try Data(contentsOf: url), original)
                withExtendedLifetime(reading) {}
            }
        }
    }

    @MainActor func testPDFWithLeadingBytesAndP7MExtensionOpensAsPlainPDF() async throws {
        let directory = try fixtureDirectory(), url = directory.appendingPathComponent("misnamed.p7m")
        let original = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>"
        ], prefix: "leading bytes\n")
        try original.write(to: url)
        let reading = try ReadingDocument.open(url)
        guard case .pages(let document) = reading.content, document.isPDF else { return XCTFail("The content signature must select MuPDF") }
        let count = await document.count, source = document.pdfSourceURL
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reading.settingsFormat, "pdf")
        XCTAssertNil(reading.temporary, "A plain PDF must retain its original source")
        XCTAssertEqual(source, url)
        let separateSource = reading.hasSeparatePDFSource
        XCTAssertFalse(separateSource, "The file's contents, not its p7m extension, determine the available copy formats")
        let state = ReaderState(recordsHistory: false)
        state.document = reading
        XCTAssertTrue(state.canSave, "A naked PDF may save in place even with a p7m extension")
        state.document = nil
        state.windowClosed()
        XCTAssertEqual(try Data(contentsOf: url), original)
        withExtendedLifetime(reading) {}
    }

    func testAESPasswordsUseUTF8ByteCapacityInsteadOfASCIIRestriction() {
        XCTAssertNoThrow(try NativePDFTools.validatePasswords(owner: String(repeating: "书", count: 41), user: "阅读者"))
        XCTAssertThrowsError(try NativePDFTools.validatePasswords(owner: String(repeating: "书", count: 43), user: ""))
        XCTAssertThrowsError(try NativePDFTools.validatePasswords(owner: "", user: "reader"))
        XCTAssertThrowsError(try NativePDFTools.validatePasswords(owner: "before\0after", user: ""))
    }
    func testPDFToolsPreserveSourceAtOutputBoundary() {
        let source = URL(fileURLWithPath: "/tmp/document.pdf")
        XCTAssertThrowsError(try NativePDFTools.validateDestination(source: source, destination: source))
        XCTAssertThrowsError(try NativePDFTools.validateDestination(source: URL(string: "https://example.test/document.pdf")!, destination: source))
        XCTAssertNoThrow(try NativePDFTools.validateDestination(source: source, destination: URL(fileURLWithPath: "/tmp/document-signed.pdf")))
    }
    func testSignatureBoundsAndPageAreRepresentableByNativeEngine() {
        XCTAssertNoThrow(try NativePDFTools.validateSignature(fieldName: "Signature", page: 0, bounds: .zero))
        XCTAssertNoThrow(try NativePDFTools.validateSignature(fieldName: "签名", page: 3, bounds: CGRect(x: 20, y: 30, width: 180, height: 60)))
        XCTAssertNoThrow(try NativePDFTools.validateSignature(fieldName: "", page: 0, bounds: .zero))
        XCTAssertThrowsError(try NativePDFTools.validateSignature(fieldName: "before\0after", page: 0, bounds: .zero))
        XCTAssertThrowsError(try NativePDFTools.validateSignature(fieldName: "Signature", page: Int(Int32.max)+1, bounds: .zero))
        XCTAssertThrowsError(try NativePDFTools.validateSignature(fieldName: "Signature", page: 0, bounds: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
    }

    private func fixtureDirectory() throws -> URL {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before native PDF integration tests") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-native-PDF-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    @MainActor private func makePDF(in directory: URL) throws -> URL {
        let document = PDFDocument()
        for index in 0..<2 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            let annotation = PDFAnnotation(bounds: CGRect(x: 30, y: 300, width: 240, height: 50), forType: .freeText, withProperties: nil)
            annotation.contents = "Page \(index+1) retained text"
            annotation.font = NSFont.systemFont(ofSize: 16); annotation.fontColor = .black
            page.addAnnotation(annotation); document.insert(page, at: index)
        }
        let url = directory.appendingPathComponent("source.pdf")
        try XCTUnwrap(document.dataRepresentation()).write(to: url)
        return url
    }
    // Preserve PDF name objects in the publisher's exact /Lock dictionary.
    private func makeLockedPDF(in directory: URL, fieldName: String = "PublisherLocked") throws -> URL {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (\(fieldName)) /Rect [30 30 230 90] /F 4 /P 3 0 R /Lock << /Action /All >> /DA (/Helv 0 Tf 0 g) >>",
            "<< /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 7 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        let bytes = rawPDF(objects)
        let url = directory.appendingPathComponent(fieldName.isEmpty ? "publisher-unnamed.pdf" : "publisher-locked.pdf")
        try bytes.write(to: url)
        return url
    }
    private func rawPDF(_ objects: [String], prefix: String = "", xrefStream: Bool = false) -> Data {
        var bytes = Data((prefix + "%PDF-1.7\n").utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        if xrefStream {
            var entries = Data([0, 0, 0, 0, 0, 255, 255])
            for offset in offsets + [xref] {
                let offset = UInt32(offset)
                entries.append(contentsOf: [1, UInt8(truncatingIfNeeded: offset >> 24), UInt8(truncatingIfNeeded: offset >> 16),
                                           UInt8(truncatingIfNeeded: offset >> 8), UInt8(truncatingIfNeeded: offset), 0, 0])
            }
            bytes.append(Data("\(objects.count + 1) 0 obj\n<< /Type /XRef /Root 1 0 R /Size \(objects.count + 2) /W [1 4 2] /Length \(entries.count) >>\nstream\n".utf8))
            bytes.append(entries)
            bytes.append(Data("\nendstream\nendobj\nstartxref\n\(xref)\n%%EOF\n".utf8))
            return bytes
        }
        bytes.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
    // Map bytes one-to-one to UTF-16 code units. Regex locations then remain
    // PDF byte offsets even beside binary streams and CMS padding.
    private func latin1(_ data: Data) -> NSString { String(decoding: data.map { UInt16($0) }, as: UTF16.self) as NSString }

    @MainActor func testAES256UsesIndependentPDFKitUnlockAndPreservesOwnerBoundary() throws {
        let directory = try fixtureDirectory(), source = try makePDF(in: directory)
        let original = try Data(contentsOf: source)
        let encryptedURL = directory.appendingPathComponent("encrypted.pdf")
        try NativePDFTools.encrypt(source: source, destination: encryptedURL, ownerPassword: "owner秘密", userPassword: "reader中文", permissions: 1 | 32)
        let information = try NativePDFTools.information(source: encryptedURL, password: "reader中文")
        XCTAssertTrue(information["Encryption"]?.contains("256-bit AES") == true)
        XCTAssertThrowsError(try NativePDFTools.information(source: encryptedURL, password: "incorrect"))
        XCTAssertTrue(try NativePDFTools.resourceReport(source: encryptedURL, password: "reader中文").contains("Encryption object"))
        let encryptedBytes = try Data(contentsOf: encryptedURL)
        XCTAssertNotEqual(encryptedBytes, original)
        XCTAssertTrue(latin1(encryptedBytes).contains("/AESV3"), "Encryption must use AES-256, not legacy RC4")
        let reader = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(reader.isEncrypted); XCTAssertTrue(reader.isLocked)
        XCTAssertFalse(reader.unlock(withPassword: "wrong")); XCTAssertTrue(reader.isLocked)
        XCTAssertTrue(reader.unlock(withPassword: "reader中文")); XCTAssertEqual(reader.pageCount, 2)
        XCTAssertTrue(reader.allowsPrinting); XCTAssertFalse(reader.allowsCopying)
        let owner = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(owner.unlock(withPassword: "owner秘密")); XCTAssertEqual(owner.pageCount, 2)
        XCTAssertEqual(try storedPermissions(encryptedURL, password: "reader中文"), -3388)
        XCTAssertTrue(owner.allowsCopying, "Owner authentication grants operations beyond the stored reader permissions")
        let readerInfo = try XCTUnwrap(NativeFile(encryptedURL, engine: .mupdf, password: "reader中文").pdfInfo())
        XCTAssertTrue(readerInfo.permissions.accessibility)
        XCTAssertFalse(readerInfo.permissions.printHighQuality)
        XCTAssertThrowsError(try NativeFile(encryptedURL, engine: .mupdf, password: "wrong"))
        XCTAssertFalse(try XCTUnwrap(NativeFile(encryptedURL, engine: .mupdf, password: "reader中文").pdfInfo()).ownerAuthenticated)
        XCTAssertTrue(try XCTUnwrap(NativeFile(encryptedURL, engine: .mupdf, password: "owner秘密").pdfInfo()).ownerAuthenticated)
        let rejected = directory.appendingPathComponent("rejected.pdf")
        let sentinel = Data("Existing output remains intact".utf8)
        try sentinel.write(to: rejected)
        XCTAssertThrowsError(try NativePDFTools.transform(source: encryptedURL, destination: rejected, operation: .compress, password: "reader中文"))
        XCTAssertThrowsError(try NativePDFTools.decrypt(source: encryptedURL, destination: rejected, password: "reader中文"))
        XCTAssertEqual(try Data(contentsOf: rejected), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: encryptedURL), encryptedBytes)
        let plainURL = directory.appendingPathComponent("decrypted.pdf")
        try NativePDFTools.decrypt(source: encryptedURL, destination: plainURL, password: "owner秘密")
        let plain = try XCTUnwrap(PDFDocument(url: plainURL))
        XCTAssertFalse(plain.isEncrypted); XCTAssertFalse(plain.isLocked); XCTAssertEqual(plain.pageCount, 2)
        XCTAssertEqual(try Data(contentsOf: encryptedURL), encryptedBytes)
    }

    @MainActor func testEncryptionDefaultsGrantFullPermissionsForPlainSources() throws {
        let directory = try fixtureDirectory(), source = try makePDF(in: directory)
        let original = try Data(contentsOf: source), output = directory.appendingPathComponent("encrypted.pdf")
        try NativePDFTools.encrypt(source: source, destination: output, ownerPassword: "owner", userPassword: "reader")
        XCTAssertEqual(try storedPermissions(output, password: "reader"), -4)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testEncryptionDefaultsKeepStoredPermissionsWithOwnerAuthentication() throws {
        let directory = try fixtureDirectory(), plain = try makePDF(in: directory)
        // Independently allow print/assembly/form and high-quality print/edit/comment.
        // These asymmetric masks also exercise bits that common PDF writers imply.
        let masks: [(platform: UInt, stored: Int32)] = [(1 | 8 | 128, -2620), (2 | 4 | 64, -1816)]
        for (permissions, expected) in masks {
            let source = directory.appendingPathComponent("source-\(permissions).pdf")
            let output = directory.appendingPathComponent("output-\(permissions).pdf")
            try NativePDFTools.encrypt(source: plain, destination: source, ownerPassword: "owner", userPassword: "reader", permissions: permissions)
            let original = try Data(contentsOf: source)
            XCTAssertEqual(try storedPermissions(source, password: "reader"), expected)
            let sentinel = Data("Keep existing output on rejected owner authentication".utf8)
            try sentinel.write(to: output)
            for password in ["reader", "incorrect"] {
                XCTAssertThrowsError(try NativePDFTools.encrypt(source: source, destination: output, ownerPassword: "new owner", userPassword: "new reader", documentPassword: password))
                XCTAssertEqual(try Data(contentsOf: output), sentinel)
            }
            try NativePDFTools.encrypt(source: source, destination: output, ownerPassword: "new owner", userPassword: "new reader", documentPassword: "owner")
            XCTAssertEqual(try storedPermissions(output, password: "new reader"), expected, "Owner authentication must not turn stored reader restrictions into full access")
            try NativePDFTools.encrypt(source: source, destination: output, ownerPassword: "new owner", userPassword: "new reader", documentPassword: "owner", permissions: 16 | 32)
            XCTAssertEqual(try storedPermissions(output, password: "new reader"), -3376, "An explicit mask overrides the stored source permissions")
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    @MainActor func testEncryptionExplicitPermissionsMatchIndependentOutputInspection() throws {
        let directory = try fixtureDirectory(), source = try makePDF(in: directory)
        // Expected signed /P values include the PDF specification's reserved bits.
        let masks: [(platform: UInt, stored: Int32)] = [
            (0, -3904), (1, -3900), (2, -1856), (4, -3896), (8, -2880),
            (16, -3888), (32, -3392), (64, -3872), (128, -3648), (255, -4)
        ]
        for (permissions, expected) in masks {
            let output = directory.appendingPathComponent("permissions-\(permissions).pdf")
            try NativePDFTools.encrypt(source: source, destination: output, ownerPassword: "owner", userPassword: "reader", permissions: permissions)
            XCTAssertEqual(try storedPermissions(output, password: "reader"), expected)
        }
    }

    private func storedPermissions(_ source: URL, password: String) throws -> Int32 {
        let pdf = try XCTUnwrap(CGPDFDocument(source as CFURL))
        XCTAssertTrue(pdf.isEncrypted)
        XCTAssertTrue(pdf.unlockWithPassword(password))
        // These generated AES-256 fixtures have a plaintext Standard Encrypt
        // dictionary with /P before its string/nested entries. Read its stored
        // integer directly; CoreGraphics normalizes effective access flags.
        let text = latin1(try Data(contentsOf: source))
        let expression = try NSRegularExpression(pattern: #"/Filter\s*/Standard\b[^<>]*?/P\s+(-?\d+)\b"#)
        let match = try XCTUnwrap(expression.matches(in: text as String, range: NSRange(location: 0, length: text.length)).last)
        return try XCTUnwrap(Int32(text.substring(with: match.range(at: 1))))
    }

    func testNativeFlattenKeepsEditableFormsWhileBakeRemovesThem() throws {
        let directory = try fixtureDirectory(), source = directory.appendingPathComponent("form-and-note.pdf")
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 6 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /Helv 6 0 R >> >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (field) /V (editable value) /Rect [20 120 240 160] /P 3 0 R /DA (/Helv 12 Tf 0 g) /F 4 >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [20 40 240 80] /Contents (retained note) /DA (/Helv 12 Tf 0 g) /F 4 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        try bytes.write(to: source)
        for operation in [PDFAdvancedOperation.flatten, .bake] {
            let output = directory.appendingPathComponent(operation.rawValue + ".pdf")
            try NativePDFTools.transform(source: source, destination: output, operation: operation)
            let file = try NativeFile(output, engine: .mupdf)
            XCTAssertTrue(try file.text(0)?.contains("retained note") == true, "The note must become page content")
            let annotations = try file.pdfAnnotations(0)
            if operation == .flatten {
                XCTAssertEqual(annotations.map(\.type), ["Widget"])
                let widget = try XCTUnwrap(annotations.first)
                XCTAssertEqual(widget.value, "editable value")
                try file.pdfSetEditing(true)
                try file.pdfSetWidgetValue(page: 0, id: widget.id, value: "still editable")
                XCTAssertEqual(try file.pdfAnnotations(0).first?.value, "still editable")
            } else {
                XCTAssertTrue(annotations.isEmpty)
                XCTAssertTrue(try file.text(0)?.contains("editable value") == true, "Baking includes form appearances")
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    @MainActor func testNativeTransformsPreservePagesAndBakeAnnotations() throws {
        let directory = try fixtureDirectory(), source = try makePDF(in: directory)
        let original = try Data(contentsOf: source)
        for operation in [PDFAdvancedOperation.compress, .decompress, .bake] {
            let destination = directory.appendingPathComponent(operation.rawValue + ".pdf")
            try NativePDFTools.transform(source: source, destination: destination, operation: operation)
            let document = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(document.pageCount, 2)
            for index in 0..<2 {
                let page = try XCTUnwrap(document.page(at: index))
                XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 300, height: 400))
                if operation == .bake {
                    XCTAssertTrue(page.annotations.isEmpty)
                    XCTAssertTrue(page.string?.contains("retained text") == true)
                } else { XCTAssertTrue(page.annotations.contains { $0.contents?.contains("retained text") == true }) }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    @MainActor
    func testSignatureSelectionUsesPDFCoordinatesWithRotationCropAndUserUnit() throws {
        let directory = try fixtureDirectory()
        let identity = try signingIdentity(in: directory)
        let source = directory.appendingPathComponent("rotated.pdf"), output = directory.appendingPathComponent("signed.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 820] /CropBox [30 40 570 760] /Rotate 90 /UserUnit 2 /Resources << >> >>"
        ]).write(to: source)
        let original = try Data(contentsOf: source)
        try NativePDFTools.sign(source: source, destination: output, identity: .pkcs12(identity, password: "fixture"),
            bounds: CGRect(x: 60, y: 80, width: 160, height: 40), boundsInPDFSpace: true)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(document.documentRef?.page(at: 1)?.dictionary)
        var annotations: CGPDFArrayRef?, widget: CGPDFDictionaryRef?, rect: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(page, "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &widget))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(widget), "Rect", &rect))
        for (index, expected) in [60.0, 80, 220, 120].enumerated() {
            var value: CGPDFReal = 0
            XCTAssertTrue(CGPDFArrayGetNumber(try XCTUnwrap(rect), index, &value))
            XCTAssertEqual(Double(value), expected, accuracy: 0.01)
        }
        let bytes = try Data(contentsOf: output), signature = try XCTUnwrap(try signatures(in: bytes).first)
        XCTAssertEqual(try verify(signature, in: directory).status, 0)
        XCTAssertTrue(bytes.starts(with: original))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private struct OpenSSLResult { let status: Int32; let output: String }
    private func openssl(_ arguments: [String]) throws -> OpenSSLResult {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return OpenSSLResult(status: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self))
    }
    private func signingIdentity(in directory: URL, qualifiedTimestamp: Bool = false) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw XCTSkip("System OpenSSL is unavailable") }
        let capability = try openssl(["cms", "-help"])
        guard capability.output.contains("-verify") else { throw XCTSkip("System OpenSSL lacks CMS verification; digital signatures have not been verified") }
        let key = directory.appendingPathComponent("identity.key"), certificate = directory.appendingPathComponent("certificate.pem")
        var extensions = [String]()
        if qualifiedTimestamp {
            let configuration = directory.appendingPathComponent("qualified-certificate.cnf")
            try """
            [req]
            distinguished_name=dn
            x509_extensions=extensions
            [dn]
            [extensions]
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature
            extendedKeyUsage=critical,timeStamping
            1.3.6.1.5.5.7.1.3=ASN1:SEQUENCE:statements
            [statements]
            statement=SEQUENCE:compliance
            [compliance]
            statementId=OID:0.4.0.1862.1.1
            """.write(to: configuration, atomically: true, encoding: .utf8)
            extensions = ["-config", configuration.path]
        }
        let request = try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", qualifiedTimestamp ? "-sha384" : "-sha256", "-days", "1", "-subj", "/CN=Sumra Native PDF Test", "-keyout", key.path, "-out", certificate.path] + extensions)
        guard request.status == 0 else { throw NSError(domain: "SumraSigningFixture", code: Int(request.status), userInfo: [NSLocalizedDescriptionKey: request.output]) }
        let identity = directory.appendingPathComponent("identity.p12")
        let exported = try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", certificate.path, "-out", identity.path, "-passout", "pass:fixture"])
        guard exported.status == 0 else { throw NSError(domain: "SumraSigningFixture", code: Int(exported.status), userInfo: [NSLocalizedDescriptionKey: exported.output]) }
        return identity
    }
    // A legal, separated terminal field owns V and has two page widgets. Sign
    // its fixed byte ranges with independent OpenSSL, rather than relying on
    // MuPDF's signer to produce the topology that its clearing API must handle.
    private func separatedSignatureFixture(in directory: URL, readOnly: Bool = false, widgets: Bool = true, subFilter: String = "adbe.pkcs7.detached") throws -> URL {
        let capacity = 16_384
        let rangeTemplate = "/ByteRange [0000000000 0000000000 0000000000 0000000000]"
        let appearance = "q 0.923 0.123 0.456 rg 0 0 200 60 re f Q\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 8 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots \(widgets ? "[5 0 R]" : "[]") >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Annots \(widgets ? "[6 0 R]" : "[]") >>",
            "<< /Type /Annot /Subtype /Widget /Parent 7 0 R /Rect [30 30 230 90] /F 4 /P 3 0 R /AP << /N 11 0 R >> >>",
            "<< /Type /Annot /Subtype /Widget /Parent 7 0 R /Rect [30 120 230 180] /F 4 /P 4 0 R /AP << /N 11 0 R >> >>",
            "<< /FT /Sig /T (Separated) /V 9 0 R /Kids \(widgets ? "[5 0 R 6 0 R]" : "[]") /Ff \(readOnly ? 1 : 0) /Lock << /Action /Include /Fields [] >> /DA (/Helv 0 Tf 0 g) >>",
            "<< /Fields [7 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 10 0 R >> >> >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /\(subFilter) /Reason (Review approval) /Location (Fixture) \(rangeTemplate) /Contents <\(String(repeating: "0", count: capacity * 2))> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 200 60] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ]
        var bytes = rawPDF(objects)
        let source = latin1(bytes)
        let begin = source.range(of: "/Contents <").location + "/Contents ".utf16.count
        let end = begin + capacity * 2 + 2
        let ranges = [0, begin, end, bytes.count - end]
        let range = source.range(of: rangeTemplate)
        let replacement = "/ByteRange [" + ranges.map { String(format: "%010ld", $0) }.joined(separator: " ") + "]"
        bytes.replaceSubrange(range.location..<(range.location + range.length), with: Data(replacement.utf8))
        var content = bytes.subdata(in: 0..<begin)
        content.append(bytes.subdata(in: end..<bytes.count))
        let prefix = UUID().uuidString
        var input = directory.appendingPathComponent(prefix + ".bin")
        let output = directory.appendingPathComponent(prefix + ".der")
        try content.write(to: input)
        var contentOptions = [String]()
        if subFilter == "adbe.pkcs7.sha1" {
            let digest = directory.appendingPathComponent(prefix + ".sha1")
            let hashed = try openssl(["dgst", "-sha1", "-binary", "-out", digest.path, input.path])
            guard hashed.status == 0 else { throw NSError(domain: "SumraSigningFixture", code: Int(hashed.status), userInfo: [NSLocalizedDescriptionKey: hashed.output]) }
            input = digest
            contentOptions = ["-nodetach"]
        }
        let signed = try openssl(["cms", "-sign", "-binary", "-md", "sha256", "-nosmimecap", "-in", input.path,
            "-signer", directory.appendingPathComponent("certificate.pem").path, "-inkey", directory.appendingPathComponent("identity.key").path,
            "-outform", "DER", "-out", output.path] + contentOptions)
        guard signed.status == 0 else { throw NSError(domain: "SumraSigningFixture", code: Int(signed.status), userInfo: [NSLocalizedDescriptionKey: signed.output]) }
        let cms = try Data(contentsOf: output)
        guard cms.count <= capacity else { throw NSError(domain: "SumraSigningFixture", code: 1) }
        let hex = cms.map { String(format: "%02x", $0) }.joined() + String(repeating: "0", count: (capacity - cms.count) * 2)
        bytes.replaceSubrange((begin + 1)..<(end - 1), with: Data(hex.utf8))
        let url = directory.appendingPathComponent(prefix + ".pdf")
        try bytes.write(to: url)
        return url
    }

    private func widgetAppearance(_ document: PDFDocument, page: Int) throws -> Data {
        let dictionary = try XCTUnwrap(document.documentRef?.page(at: page + 1)?.dictionary)
        var annotations: CGPDFArrayRef?, widget: CGPDFDictionaryRef?, appearance: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &widget))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(widget), "AP", &appearance))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(stream), &format)) as Data
    }
    private struct Signature { let ranges: [Int]; let cms: Data; let content: Data }
    private func signatures(in pdf: Data) throws -> [Signature] {
        let string = latin1(pdf)
        let expression = try NSRegularExpression(pattern: #"/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]"#)
        var signatures = [Signature]()
        for match in expression.matches(in: string as String, range: NSRange(location: 0, length: string.length)) {
            let ranges = try (1...4).map { try XCTUnwrap(Int(string.substring(with: match.range(at: $0)))) }
            if signatures.contains(where: { $0.ranges == ranges }) { continue }
            guard ranges[0] == 0, ranges[1] > 0, ranges[2] > ranges[1], ranges[2] <= pdf.count, ranges[3] >= 0, ranges[3] <= pdf.count-ranges[2] else {
                throw NSError(domain: "SumraByteRange", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PDF signature byte ranges"])
            }
            let gap = string.substring(with: NSRange(location: ranges[1], length: ranges[2]-ranges[1]))
            let hex = gap.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" }
            var bytes = [UInt8](), cursor = hex.startIndex
            while cursor < hex.endIndex {
                let end = hex.index(cursor, offsetBy: 2, limitedBy: hex.endIndex)
                let next = try XCTUnwrap(end), byte = try XCTUnwrap(UInt8(hex[cursor..<next], radix: 16))
                bytes.append(byte); cursor = next
            }
            // Security emits legal BER (including indefinite lengths). Let the
            // independent CMS parser consume it and ignore PDF reservation padding.
            var content = pdf.subdata(in: 0..<ranges[1])
            content.append(pdf.subdata(in: ranges[2]..<(ranges[2]+ranges[3])))
            signatures.append(Signature(ranges: ranges, cms: Data(bytes), content: content))
        }
        return signatures
    }
    private func verify(_ signature: Signature, in directory: URL, tampering: Bool = false) throws -> OpenSSLResult {
        let prefix = UUID().uuidString, cms = directory.appendingPathComponent(prefix + ".der"), content = directory.appendingPathComponent(prefix + ".bin"), output = directory.appendingPathComponent(prefix + ".verified")
        try signature.cms.write(to: cms)
        var data = signature.content
        if tampering { data[0] ^= 1 }
        try data.write(to: content)
        // -noverify skips certificate-chain trust only. The CMS signature and
        // signed content digest are still independently verified by OpenSSL.
        let result = try openssl(["cms", "-verify", "-binary", "-inform", "DER", "-in", cms.path, "-content", content.path, "-noverify", "-out", output.path])
        if result.status == 0 { XCTAssertEqual(try Data(contentsOf: output), data) }
        return result
    }


    @MainActor func testSignatureInspectionSeparatesDigestTrustAndIncrementalChanges() throws {
        let directory = try fixtureDirectory(), identity = try signingIdentity(in: directory)
        let source = try separatedSignatureFixture(in: directory)
        let original = try Data(contentsOf: source)
        let independent = try XCTUnwrap(try signatures(in: original).first)
        XCTAssertEqual(try verify(independent, in: directory).status, 0)

        let info = try NativeFile(source, engine: .mupdf).pdfSignatureInfo()
        XCTAssertEqual(info.signatures.count, 1, "A field with multiple page widgets is one signature")
        let first = try XCTUnwrap(info.signatures.first)
        XCTAssertEqual(first.name, "Separated")
        XCTAssertEqual(first.reason, "Review approval")
        XCTAssertEqual(first.location, "Fixture")
        XCTAssertEqual(first.page, 0)
        XCTAssertEqual(first.digestValid, true)
        XCTAssertEqual(first.changedSinceSigning, false)
        XCTAssertEqual(first.certificateTrusted, false, "A self-signed fixture is not a trusted local anchor")
        XCTAssertEqual(first.signers.count, 1)
        XCTAssertEqual(first.signers.first?.name, "Sumra Native PDF Test")
        let certificateData = try XCTUnwrap(first.signers.first?.certificateDER?.first)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Sumra Native PDF Test")
        XCTAssertEqual(first.signers.first?.certificateTrusted, false)
        XCTAssertNotNil(first.signers.first?.trustError)
        XCTAssertNotNil(first.signers.first?.signingTime)
        let signer = try XCTUnwrap(first.signers.first)
        XCTAssertNil(signer.metadataError)
        XCTAssertNil(signer.certificateMetadataError)
        XCTAssertEqual(signer.hashAlgorithm?.lowercased(), "sha256")
        XCTAssertEqual(signer.signatureAlgorithm, "rsaEncryption")
        XCTAssertEqual(signer.documentHash, SHA256.hash(data: independent.content).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(signer.qualifiedCertificate, false)
        XCTAssertNil(signer.policyOID)

        var tampered = original
        let appearance = latin1(tampered).range(of: "0.923 0.123 0.456")
        XCTAssertNotEqual(appearance.location, NSNotFound)
        tampered.replaceSubrange(appearance.location..<(appearance.location + 5), with: Data("0.823".utf8))
        let tamperedURL = directory.appendingPathComponent("tampered-signature.pdf")
        try tampered.write(to: tamperedURL)
        let altered = try XCTUnwrap(try signatures(in: tampered).first)
        XCTAssertNotEqual(try verify(altered, in: directory).status, 0)
        let bad = try XCTUnwrap(try NativeFile(tamperedURL, engine: .mupdf).pdfSignatureInfo().signatures.first)
        XCTAssertEqual(bad.digestValid, false)
        XCTAssertEqual(bad.certificateTrusted, false)
        XCTAssertFalse(bad.digestError.isEmpty)

        let incremented = directory.appendingPathComponent("incremented-signature.pdf")
        try NativePDFTools.sign(source: source, destination: incremented, identity: identity,
            password: "fixture", fieldName: "Later", page: 1, reason: "Review approval", location: "Fixture")
        let incrementedBytes = try Data(contentsOf: incremented)
        XCTAssertTrue(incrementedBytes.starts(with: original))
        for signature in try signatures(in: incrementedBytes) {
            XCTAssertEqual(try verify(signature, in: directory).status, 0)
        }
        let laterInfo = try NativeFile(incremented, engine: .mupdf).pdfSignatureInfo()
        XCTAssertEqual(laterInfo.signatures.count, 2)
        let previous = try XCTUnwrap(laterInfo.signatures.first { $0.name == "Separated" })
        let later = try XCTUnwrap(laterInfo.signatures.first { $0.name == "Later" })
        XCTAssertEqual(previous.digestValid, true)
        XCTAssertEqual(previous.changedSinceSigning, true)
        XCTAssertEqual(later.digestValid, true)
        XCTAssertEqual(later.changedSinceSigning, false)
        XCTAssertEqual(later.certificateTrusted, false)
        // Sumatra PdfSign.cpp uses these in the visible appearance, not the
        // signature dictionary. MuPDF's reserved signed bytes stay untouched.
        XCTAssertTrue(later.reason.isEmpty)
        XCTAssertTrue(later.location.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testSignatureMetadataUsesCMSAlgorithmAndQualifiedCertificateExtension() throws {
        let directory = try fixtureDirectory()
        _ = try signingIdentity(in: directory, qualifiedTimestamp: true)
        let source = try separatedSignatureFixture(in: directory)
        let original = try Data(contentsOf: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let signer = try XCTUnwrap(try file.pdfSignatureInfo().signatures.first?.signers.first)
        // This certificate is itself signed with SHA-384, whereas the CMS
        // signer uses SHA-256. Certificate algorithm substitution must fail.
        XCTAssertEqual(signer.hashAlgorithm?.lowercased(), "sha256")
        XCTAssertEqual(signer.signatureAlgorithm, "rsaEncryption")
        XCTAssertEqual(signer.qualifiedCertificate, true)
        XCTAssertEqual(signer.certificateTrusted, false)
        XCTAssertNil(signer.metadataError)
        XCTAssertNil(signer.certificateMetadataError)
        XCTAssertEqual(try XCTUnwrap(file.pdfInfo()).undoPosition, before.undoPosition)
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testDocumentTimestampMetadataUsesOpenSSLTimestampDecoder() throws {
        let directory = try fixtureDirectory()
        _ = try signingIdentity(in: directory, qualifiedTimestamp: true)
        let source = try separatedSignatureFixture(in: directory)
        var pdf = try Data(contentsOf: source)
        let subfilter = latin1(pdf).range(of: "adbe.pkcs7.detached")
        pdf.replaceSubrange(subfilter.location..<(subfilter.location + subfilter.length), with: Data("ETSI.RFC3161       ".utf8))
        let signature = try XCTUnwrap(try signatures(in: pdf).first)
        let content = directory.appendingPathComponent("timestamp-content.bin")
        let query = directory.appendingPathComponent("timestamp-query.tsq"), token = directory.appendingPathComponent("timestamp-token.der")
        let serial = directory.appendingPathComponent("timestamp-serial"), config = directory.appendingPathComponent("timestamp.cnf")
        try signature.content.write(to: content); try "01\n".write(to: serial, atomically: true, encoding: .utf8)
        try """
        [tsa]
        default_tsa=signer
        [signer]
        serial=\(serial.path)
        signer_cert=\(directory.appendingPathComponent("certificate.pem").path)
        signer_key=\(directory.appendingPathComponent("identity.key").path)
        certs=\(directory.appendingPathComponent("certificate.pem").path)
        signer_digest=sha256
        default_policy=1.2.3.4.5
        digests=sha256
        accuracy=secs:1
        ordering=yes
        tsa_name=yes
        ess_cert_id_chain=no
        """.write(to: config, atomically: true, encoding: .utf8)
        let queried = try openssl(["ts", "-query", "-data", content.path, "-sha256", "-cert", "-out", query.path])
        XCTAssertEqual(queried.status, 0, queried.output)
        let generated = try openssl(["ts", "-reply", "-config", config.path, "-queryfile", query.path, "-token_out", "-out", token.path])
        XCTAssertEqual(generated.status, 0, generated.output)
        // LibreSSL's timestamp signer may choose SHA-1 despite signer_digest.
        // Compare the CMS signer algorithm independently; the imprint is SHA-256.
        let cms = try openssl(["cms", "-cmsout", "-print", "-inform", "DER", "-in", token.path])
        XCTAssertEqual(cms.status, 0, cms.output)
        let algorithm = try NSRegularExpression(pattern: #"(?s)signerInfos:.*?digestAlgorithm:\s*algorithm:\s*(\S+)"#)
        let match = try XCTUnwrap(algorithm.firstMatch(in: cms.output, range: NSRange(cms.output.startIndex..., in: cms.output)))
        let expectedHash = (cms.output as NSString).substring(with: match.range(at: 1))
        let bytes = try Data(contentsOf: token)
        let capacity = (signature.ranges[2] - signature.ranges[1] - 2) / 2
        guard bytes.count <= capacity else { throw ReadError("Timestamp fixture exceeds reserved signature space") }
        let encoded = bytes.map { String(format: "%02x", $0) }.joined() + String(repeating: "0", count: (capacity - bytes.count) * 2)
        pdf.replaceSubrange((signature.ranges[1] + 1)..<(signature.ranges[2] - 1), with: Data(encoded.utf8))
        // The token binds these byte ranges, but metadata inspection must not
        // claim RFC3161 imprint verification, which remains separate.
        let timestampPDF = directory.appendingPathComponent("document-timestamp.pdf"); try pdf.write(to: timestampPDF)
        let info = try NativeFile(timestampPDF, engine: .mupdf).pdfSignatureInfo()
        let field = try XCTUnwrap(info.signatures.first), signer = try XCTUnwrap(field.signers.first)
        XCTAssertTrue(field.isDocumentTimestamp)
        XCTAssertNil(field.digestValid, "Reading timestamp metadata is not RFC3161 imprint validation")
        XCTAssertEqual(signer.policyOID, "1.2.3.4.5")
        XCTAssertEqual(signer.hashAlgorithm?.lowercased(), expectedHash.lowercased())
        XCTAssertNotNil(signer.generationTime)
        XCTAssertEqual(signer.qualifiedCertificate, true)
        XCTAssertNil(signer.metadataError)
        let der = try XCTUnwrap(signer.certificateDER?.first)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(try Data(contentsOf: timestampPDF), pdf)
    }

    @MainActor func testSignatureInspectionIncludesUnsignedAndWidgetlessFields() throws {
        let directory = try fixtureDirectory()
        _ = try signingIdentity(in: directory)
        let unsigned = try makeLockedPDF(in: directory)
        let field = try XCTUnwrap(try NativeFile(unsigned, engine: .mupdf).pdfSignatureInfo().unsignedFields.first)
        XCTAssertEqual(field.name, "PublisherLocked")
        XCTAssertEqual(field.page, 0)
        XCTAssertFalse(field.isSigned)
        XCTAssertNil(field.digestValid)
        XCTAssertNil(field.certificateTrusted)

        let source = try separatedSignatureFixture(in: directory, widgets: false)
        let info = try NativeFile(source, engine: .mupdf).pdfSignatureInfo()
        XCTAssertEqual(info.signatures.count, 1, "Signed terminal fields do not require a page widget")
        let signature = try XCTUnwrap(info.signatures.first)
        XCTAssertNil(signature.page)
        XCTAssertEqual(signature.digestValid, true)
        XCTAssertEqual(signature.certificateTrusted, false)

        let encrypted = directory.appendingPathComponent("encrypted-signature-fields.pdf")
        try NativePDFTools.encrypt(source: unsigned, destination: encrypted, ownerPassword: "owner", userPassword: "reader")
        XCTAssertEqual(try NativeFile(encrypted, engine: .mupdf, password: "reader").pdfSignatureInfo().unsignedFields.count, 1)
        XCTAssertThrowsError(try NativeFile(encrypted, engine: .mupdf, password: "incorrect").pdfSignatureInfo())

        let unnamedSource = try makeLockedPDF(in: directory, fieldName: "")
        let unnamed = try XCTUnwrap(try NativeFile(unnamedSource, engine: .mupdf).pdfSignatureInfo().unsignedFields.first)
        XCTAssertEqual(unnamed.name, "")
        let unnamedSigned = directory.appendingPathComponent("unnamed-signed.pdf")
        try NativePDFTools.sign(source: unnamedSource, destination: unnamedSigned,
            identity: directory.appendingPathComponent("identity.p12"), password: "fixture", fieldName: unnamed.name)
        let reused = try XCTUnwrap(try NativeFile(unnamedSigned, engine: .mupdf).pdfSignatureInfo().signatures.first)
        XCTAssertEqual(reused.name, "")
        XCTAssertEqual(reused.digestValid, true)
        XCTAssertEqual(try NativeFile(unnamedSigned, engine: .mupdf).pdfSignatureInfo().signatures.count, 1)

    }


    @MainActor func testLegacyAttachedSHA1SignatureBindsThePDFByteRanges() throws {
        let directory = try fixtureDirectory()
        _ = try signingIdentity(in: directory)
        let source = try separatedSignatureFixture(in: directory, subFilter: "adbe.pkcs7.sha1")
        let original = try Data(contentsOf: source)
        let field = try XCTUnwrap(try NativeFile(source, engine: .mupdf).pdfSignatureInfo().signatures.first)
        XCTAssertEqual(field.digestValid, true)
        XCTAssertEqual(field.certificateTrusted, false)
        var bytes = original
        let appearance = latin1(bytes).range(of: "0.923 0.123 0.456")
        XCTAssertNotEqual(appearance.location, NSNotFound)
        bytes.replaceSubrange(appearance.location..<(appearance.location + 5), with: Data("0.823".utf8))
        let tampered = directory.appendingPathComponent("tampered-legacy.pdf")
        try bytes.write(to: tampered)
        let altered = try XCTUnwrap(try NativeFile(tampered, engine: .mupdf).pdfSignatureInfo().signatures.first)
        XCTAssertEqual(altered.digestValid, false, "A valid attached CMS payload must still match the PDF byte ranges")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }


    @MainActor func testMalformedSignatureRangesRemainUnverifiedWithNativeCause() throws {
        let directory = try fixtureDirectory()
        _ = try signingIdentity(in: directory)
        let source = try separatedSignatureFixture(in: directory)
        var bytes = try Data(contentsOf: source)
        let range = latin1(bytes).range(of: "/ByteRange [")
        XCTAssertNotEqual(range.location, NSNotFound)
        let offset = range.location + "/ByteRange [".utf8.count
        bytes.replaceSubrange(offset..<(offset + 10), with: Data("-000000001".utf8))
        let malformed = directory.appendingPathComponent("negative-signature-range.pdf")
        try bytes.write(to: malformed)
        let field = try XCTUnwrap(try NativeFile(malformed, engine: .mupdf).pdfSignatureInfo().signatures.first)
        XCTAssertNil(field.digestValid)
        XCTAssertTrue(field.digestError.contains("offset"), field.digestError)
        XCTAssertNil(field.changedSinceSigning)
        XCTAssertFalse(field.changeError.isEmpty)
        XCTAssertEqual(try Data(contentsOf: malformed), bytes)
    }


    @MainActor func testCMSSignatureDetectsTamperingAndSurvivesSecondIncrementalSignature() throws {
        let directory = try fixtureDirectory(), identity = try signingIdentity(in: directory), source = try makePDF(in: directory)
        let original = try Data(contentsOf: source), firstURL = directory.appendingPathComponent("signed.pdf")
        try NativePDFTools.sign(source: source, destination: firstURL, identity: identity, password: "fixture", fieldName: "First", page: 0, bounds: CGRect(x: 30, y: 30, width: 200, height: 60))
        let firstBytes = try Data(contentsOf: firstURL), first = try signatures(in: firstBytes)
        XCTAssertEqual(first.count, 1)
        let firstSignature = try XCTUnwrap(first.first)
        let firstVerification = try verify(firstSignature, in: directory)
        XCTAssertEqual(firstVerification.status, 0, firstVerification.output)
        XCTAssertNotEqual(try verify(firstSignature, in: directory, tampering: true).status, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let alias = directory.appendingPathComponent("source-alias.pdf"), aliasSigned = directory.appendingPathComponent("alias-signed.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        try NativePDFTools.sign(source: alias, destination: aliasSigned, identity: identity, password: "fixture", fieldName: "Alias")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), source.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: aliasSigned.path)[.type] as? FileAttributeType, .typeRegular)
        let aliasBytes = try Data(contentsOf: aliasSigned)
        XCTAssertTrue(aliasBytes.starts(with: original))
        let aliasSignature = try XCTUnwrap(try signatures(in: aliasBytes).first)
        let aliasVerification = try verify(aliasSignature, in: directory)
        XCTAssertEqual(aliasVerification.status, 0, aliasVerification.output)
        let rewritten = directory.appendingPathComponent("rewritten.pdf")
        XCTAssertThrowsError(try NativePDFTools.transform(source: firstURL, destination: rewritten, operation: .compress))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rewritten.path))
        try NativePDFTools.transform(source: firstURL, destination: rewritten, operation: .compress, invalidateSignatures: true)
        XCTAssertTrue(try signatures(in: Data(contentsOf: rewritten)).isEmpty)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: rewritten)).pageCount, 2)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        let secondURL = directory.appendingPathComponent("signed-twice.pdf")
        try NativePDFTools.sign(source: firstURL, destination: secondURL, identity: identity, password: "fixture", fieldName: "Second", page: 1)
        let secondBytes = try Data(contentsOf: secondURL), both = try signatures(in: secondBytes)
        XCTAssertEqual(both.count, 2)
        XCTAssertTrue(secondBytes.starts(with: firstBytes))
        for signature in both {
            let verification = try verify(signature, in: directory)
            XCTAssertEqual(verification.status, 0, verification.output)
        }
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: secondURL)).pageCount, 2)

        // Reuse the publisher-provided signature field and preserve its bounds.
        let clearableSource = directory.appendingPathComponent("clearable-source.pdf")
        let form = try XCTUnwrap(PDFDocument(url: source))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 30, width: 200, height: 60), forType: .widget, withProperties: nil)
        field.widgetFieldType = .signature; field.fieldName = "Clearable"; field.isReadOnly = false
        try XCTUnwrap(form.page(at: 0)).addAnnotation(field)
        try XCTUnwrap(form.dataRepresentation()).write(to: clearableSource)
        let clearableSigned = directory.appendingPathComponent("clearable-signed.pdf")
        try NativePDFTools.sign(source: clearableSource, destination: clearableSigned, identity: identity, password: "fixture", fieldName: "Clearable")
        let clearableBytes = try Data(contentsOf: clearableSigned)
        let signedForm = try XCTUnwrap(PDFDocument(url: clearableSigned))
        let signedField = try XCTUnwrap(signedForm.page(at: 0)?.annotations.first { $0.fieldName == "Clearable" })
        XCTAssertEqual(signedField.bounds, field.bounds)
        let clearableSignature = try XCTUnwrap(try signatures(in: clearableBytes).first)
        let clearableVerification = try verify(clearableSignature, in: directory)
        XCTAssertEqual(clearableVerification.status, 0, clearableVerification.output)
        try NativePDFTools.transform(source: clearableSigned, destination: rewritten, operation: .compress, invalidateSignatures: true)
        XCTAssertTrue(try signatures(in: Data(contentsOf: rewritten)).isEmpty)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: rewritten)).pageCount, 2)
        XCTAssertEqual(try Data(contentsOf: clearableSigned), clearableBytes)
        XCTAssertEqual(try Data(contentsOf: source), original)

        let movedSigned = directory.appendingPathComponent("moved-signature.pdf")
        try NativePDFTools.sign(source: clearableSource, destination: movedSigned, identity: identity, password: "fixture",
            fieldName: "Clearable", bounds: CGRect(x: 40, y: 50, width: 150, height: 40))
        let movedForm = try XCTUnwrap(PDFDocument(url: movedSigned))
        let movedField = try XCTUnwrap(movedForm.page(at: 0)?.annotations.first { $0.fieldName == "Clearable" })
        XCTAssertEqual(movedField.bounds, CGRect(x: 40, y: 310, width: 150, height: 40), "Explicit top-left PDF bounds override the existing field")
        let movedSignature = try XCTUnwrap(try signatures(in: Data(contentsOf: movedSigned)).first)
        let movedVerification = try verify(movedSignature, in: directory)
        XCTAssertEqual(movedVerification.status, 0, movedVerification.output)

        let separatedSource = try separatedSignatureFixture(in: directory)
        let separatedBytes = try Data(contentsOf: separatedSource)
        let separatedForm = try XCTUnwrap(PDFDocument(url: separatedSource))
        XCTAssertFalse(try NativeFile(separatedSource, engine: .mupdf).pdfSignatureInfo().signatures.isEmpty)
        let separatedSignature = try XCTUnwrap(try signatures(in: separatedBytes).first)
        let separatedVerification = try verify(separatedSignature, in: directory)
        XCTAssertEqual(separatedVerification.status, 0, separatedVerification.output)
        let appearances = try (0..<2).map { try widgetAppearance(separatedForm, page: $0) }
        let separatedOutput = directory.appendingPathComponent("separated-cleared.pdf")
        XCTAssertThrowsError(try NativePDFTools.transform(source: separatedSource, destination: separatedOutput, operation: .compress))
        XCTAssertFalse(FileManager.default.fileExists(atPath: separatedOutput.path))
        try NativePDFTools.transform(source: separatedSource, destination: separatedOutput, operation: .compress, invalidateSignatures: true)
        let unsignedForm = try XCTUnwrap(PDFDocument(url: separatedOutput))
        let clearedFields = try NativeFile(separatedOutput, engine: .mupdf).pdfSignatureInfo().signatures
        XCTAssertEqual(clearedFields.map(\.name), ["Separated"])
        XCTAssertEqual(clearedFields.map(\.isSigned), [false], "Clearing a signature retains the reusable unsigned field")
        XCTAssertTrue(try signatures(in: Data(contentsOf: separatedOutput)).isEmpty)
        for page in 0..<2 {
            XCTAssertNotEqual(try widgetAppearance(unsignedForm, page: page), appearances[page], "Every widget's signed appearance must be cleared")
        }
        XCTAssertEqual(try Data(contentsOf: separatedSource), separatedBytes)

        let readOnlySource = try separatedSignatureFixture(in: directory, readOnly: true)
        let readOnlyBytes = try Data(contentsOf: readOnlySource)
        let readOnlyOutput = directory.appendingPathComponent("read-only-separated.pdf")
        let readOnlySentinel = Data("Preserve existing output".utf8)
        try readOnlySentinel.write(to: readOnlyOutput)
        XCTAssertThrowsError(try NativePDFTools.transform(source: readOnlySource, destination: readOnlyOutput, operation: .compress, invalidateSignatures: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("read only"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: readOnlyOutput), readOnlySentinel)
        XCTAssertEqual(try Data(contentsOf: readOnlySource), readOnlyBytes)

        let noWidgetSource = try separatedSignatureFixture(in: directory, widgets: false)
        let noWidgetBytes = try Data(contentsOf: noWidgetSource)
        XCTAssertFalse(try NativeFile(noWidgetSource, engine: .mupdf).pdfSignatureInfo().signatures.isEmpty)
        let noWidgetOutput = directory.appendingPathComponent("no-widget-output.pdf")
        try readOnlySentinel.write(to: noWidgetOutput)
        XCTAssertThrowsError(try NativePDFTools.transform(source: noWidgetSource, destination: noWidgetOutput, operation: .compress, invalidateSignatures: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("page widget"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: noWidgetOutput), readOnlySentinel)
        XCTAssertEqual(try Data(contentsOf: noWidgetSource), noWidgetBytes)

        // An author's Lock/All policy remains authoritative. Explicitly
        // clearing such a read-only signature must retain the native error.
        let lockedSource = try makeLockedPDF(in: directory)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: lockedSource)).pageCount, 2)
        let lockedOriginal = try Data(contentsOf: lockedSource)
        let lockedSigned = directory.appendingPathComponent("publisher-signed.pdf")
        try NativePDFTools.sign(source: lockedSource, destination: lockedSigned, identity: identity, password: "fixture", fieldName: "PublisherLocked")
        let lockedBytes = try Data(contentsOf: lockedSigned)
        let lockedSignature = try XCTUnwrap(try signatures(in: lockedBytes).first)
        let lockedVerification = try verify(lockedSignature, in: directory)
        XCTAssertEqual(lockedVerification.status, 0, lockedVerification.output)
        let rejected = directory.appendingPathComponent("publisher-rejected.pdf"), sentinel = Data("Preserve existing output".utf8)
        try sentinel.write(to: rejected)
        XCTAssertThrowsError(try NativePDFTools.transform(source: lockedSigned, destination: rejected, operation: .compress, invalidateSignatures: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("read only"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: rejected), sentinel)
        XCTAssertEqual(try Data(contentsOf: lockedSigned), lockedBytes)
        XCTAssertEqual(try Data(contentsOf: lockedSource), lockedOriginal)
    }
}
#endif
