#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

final class NativePDFContentBoundsTests: XCTestCase {
    func testCropMarksOutsideThePageDoNotExpandVisibleContent() throws {
        // One stroked path holds disjoint marks at opposite page corners.
        // Its aggregate bounds cover the page, although none of its ink does.
        let file = try fixture("""
        0 g 60 50 80 100 re f
        0 G 1 w
        -20 -15 m -10 -15 l -15 -20 m -15 -10 l
        210 215 m 220 215 l 215 210 m 215 220 l S
        """)
        XCTAssertEqual(try file.contentBounds(0), CGRect(x: 60, y: 50, width: 80, height: 100))
    }

    func testVisibleContentUsesTheCurrentClipAndRestoresItAfterPop() throws {
        let file = try fixture("""
        q 50 50 100 100 re W n 0 0 200 200 re f Q
        25 75 10 50 re f
        """)
        XCTAssertEqual(try file.contentBounds(0), CGRect(x: 25, y: 50, width: 125, height: 100))
    }

    func testBlankPageRetainsItsPageBounds() throws {
        let file = try fixture("")
        XCTAssertEqual(try file.contentBounds(0), CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    private func fixture(_ content: String) throws -> NativeFile {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("Build MuPDF before native content-bounds tests")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-content-bounds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("crop-marks.pdf")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
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
        try bytes.write(to: source)
        return try NativeFile(source, engine: .mupdf)
    }
}
#endif
