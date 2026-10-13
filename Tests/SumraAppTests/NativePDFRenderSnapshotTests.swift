#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

final class NativePDFRenderSnapshotTests: XCTestCase {
    func testConcurrentImmutableReplayMatchesSerialPDFPixelsAndStyles() async throws {
        let source = try fixture()
        let file = try NativeFile(source, engine: .mupdf)
        let styles: [PDFColors.Style?] = [nil,
            .init(mode: .legacy, text: 0xffffff, background: 0x102030, link: 0x80c0ff),
            .init(engineering: true, rasterEngineering: true, hairlineEngineering: true, grayscale: true, showImageBounds: true)]
        for style in styles {
            let snapshot = try file.preparePDFRender(0, style: style)
            for region in [nil, CGRect(x: 15, y: 27, width: 130, height: 89)] {
                let expected = try Self.bytes(file.image(0, width: 320, region: region, style: style))
                let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
                    for _ in 0..<8 {
                        group.addTask { try Self.bytes(snapshot.image(width: 320, region: region)) }
                    }
                    var result = [Data]()
                    for try await bytes in group { result.append(bytes) }
                    return result
                }
                XCTAssertEqual(outputs.count, 8)
                for output in outputs { XCTAssertEqual(output, expected) }
            }
        }
    }

    func testSnapshotKeepsPreEditPixelsThroughInvalidationUndoAndDocumentClose() async throws {
        let source = try fixture()
        var file: NativeFile? = try NativeFile(source, engine: .mupdf)
        let style = PDFColors.Style(mode: .smart, text: 0xffffff, background: 0x102030, showImageBounds: true)
        let snapshot = try XCTUnwrap(file).preparePDFRender(0, style: style)
        let expected = try Self.bytes(snapshot.image(width: 240))
        let worker = Task.detached { try Self.bytes(snapshot.image(width: 240)) }
        try XCTUnwrap(file).pdfSetEditing(true)
        _ = try XCTUnwrap(file).pdfCreateAnnotation(page: 0, type: "Square",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 70),
            edits: [.color(SIMD3(1, 0, 0), interior: true), .opacity(1)])
        XCTAssertNotEqual(try Self.bytes(XCTUnwrap(file).image(0, width: 240, style: style)), expected)
        let workerBytes = try await worker.value
        XCTAssertEqual(workerBytes, expected)
        XCTAssertEqual(try Self.bytes(snapshot.image(width: 240)), expected)
        try XCTUnwrap(file).pdfSetAnnotationsVisible(false)
        XCTAssertEqual(try Self.bytes(XCTUnwrap(file).image(0, width: 240, style: style)), expected)
        try XCTUnwrap(file).pdfUndo(redo: false)
        XCTAssertEqual(try Self.bytes(XCTUnwrap(file).image(0, width: 240, style: style)), expected)
        file = nil
        let closedBytes = try await Task.detached { try Self.bytes(snapshot.image(width: 240)) }.value
        XCTAssertEqual(closedBytes, expected)
    }

    func testType3GlyphSnapshotRetainsItsOwnerAfterReaderReleaseWithoutAWarmGlyphCache() throws {
        let source = try fixture(type3: true)
        let reference = try NativeFile(source, engine: .mupdf)
        let expected = try Self.bytes(reference.image(0, width: 270))
        var file: NativeFile? = try NativeFile(source, engine: .mupdf)
        let snapshot = try XCTUnwrap(file).preparePDFRender(0)
        // Use a different font owner for expected pixels so its glyph cache
        // cannot conceal a lost Type3 resource after the reader drops its owner.
        file = nil
        XCTAssertEqual(try Self.bytes(snapshot.image(width: 270)), expected)
    }

    func testCancelledSnapshotDiscardsOutputWithoutPoisoningTheDisplayList() throws {
        let file = try NativeFile(fixture(), engine: .mupdf)
        let expected = try Self.bytes(file.image(0, width: 240))
        let cancellation = try NativeRenderCancellation()
        let snapshot = try file.preparePDFRender(0, cancellation: cancellation)
        cancellation.cancel()
        XCTAssertThrowsError(try snapshot.image(width: 240)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Self.bytes(file.preparePDFRender(0).image(width: 240)), expected)
        XCTAssertEqual(try Self.bytes(file.image(0, width: 240)), expected)
    }

    private static func bytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func fixture(type3: Bool = false) throws -> URL {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("Build MuPDF before native replay tests")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-replay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("scan-and-vector.pdf")
        // Full-page paper with short glyph-like ink runs exercises the mutable
        // scan classifier alongside vector hairlines and recoloring.
        var image = ""
        for y in 0..<96 {
            for x in 0..<96 {
                let ink = y % 9 < 4 && x % 7 < 3 && x > 8 && x < 88
                image += ink ? "38" : "ee"
            }
        }
        image += ">"
        let content = "q 200 0 0 200 0 0 cm /Im Do Q .7 G .1 w 12 12 m 188 188 l S\n"
        let objects: [String]
        if type3 {
            let content = "BT /F1 90 Tf 30 60 Td (A) Tj ET\n"
            let glyph = "600 0 0 0 500 700 d1 0 0 500 700 re f\n"
            objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
                "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 700] /FontMatrix [.001 0 0 .001 0 0] /CharProcs << /A 6 0 R >> /Encoding << /Type /Encoding /Differences [65 /A] >> /FirstChar 65 /LastChar 65 /Widths [600] /Resources << >> >>",
                "<< /Length \(glyph.utf8.count) >>\nstream\n\(glyph)endstream"
            ]
        } else {
            objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /XObject /Subtype /Image /Width 96 /Height 96 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(image.utf8.count) >>\nstream\n\(image)\nendstream"
            ]
        }
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: source)
        return source
    }
}
#endif
