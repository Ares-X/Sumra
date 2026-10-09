#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

final class PDFColorsTests: XCTestCase {
    func testCancelledRecolorLeavesTheRetainedPageUsable() throws {
        try requireEngine()
        let page = try document(fixture())
        let normal = try page.image(0, width: 300, style: .init())
        let cancellation = try NativeRenderCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try page.image(0, width: 600,
            style: .init(mode: .smart, text: 0xffffff, background: 0), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        let next = try page.image(0, width: 300, style: .init())
        XCTAssertEqual(try pixel(next, 150, 100), try pixel(normal, 150, 100))
        XCTAssertEqual(try pixel(next, 5, 5), try pixel(normal, 5, 5))
    }

    func testLivePageReplaysClipsZoomAndStylesWithoutChangingPixels() throws {
        try requireEngine()
        let retained = try document(fixture(cad: true))
        let enhanced = PDFColors.Style(engineering: true)
        _ = try retained.image(0, width: 600, style: enhanced)
        let normal = try retained.image(0, width: 300, style: .init())
        let fresh = try document(fixture(cad: true)).image(0, width: 300)
        XCTAssertEqual(try pixel(normal, 30, 110), try pixel(fresh, 30, 110), "Leaving engineering mode must reset its native minimum stroke width")
        let page = try document(fixture())
        let style = PDFColors.Style(mode: .smart, text: 0xf0f0f0, background: 0x101010)
        let full = try page.image(0, width: 300, style: style)
        for x in [0.3, 0.4, 0.5] {
            let clip = try page.image(0, width: 300,
                region: CGRect(x: (x * 300).rounded(), y: 60, width: 60, height: 80), style: style)
            XCTAssertEqual(try pixel(clip, 30, 40), try pixel(full, Int(x * 300) + 30, 100))
        }
        let legacy = try page.image(0, width: 300, style: .init(mode: .legacy, text: 0xffffff, background: 0))
        XCTAssertEqual(try pixel(legacy, 5, 5), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(try page.image(0, width: 300, style: style), 150, 100), try pixel(full, 150, 100))
    }

    func testSmartKeepsArtworkWhileLegacyAndLiveAnnotationsFollowTheTheme() throws {
        try requireEngine()
        let source = fixture(), page = try document(source), original = try page.image(0, width: 300)
        var style = PDFColors.Style(mode: .smart, text: 0xf0f0f0, background: 0x101010)
        let smart = try page.image(0, width: 300, style: style)
        XCTAssertEqual(try pixel(smart, 150, 100), try pixel(original, 150, 100), "Artwork keeps the original rendered pixels")
        XCTAssertEqual(try pixel(smart, 5, 5), [16, 16, 16, 255])
        XCTAssertEqual(try pixel(original, 260, 160), [0, 255, 0, 255])
        XCTAssertEqual(try pixel(smart, 260, 160), [240, 16, 240, 255], "Live annotation artwork participates in the same theme replay as page contents")
        style.mode = .legacy
        let legacy = try page.image(0, width: 300, style: style)
        XCTAssertNotEqual(try pixel(legacy, 150, 100), try pixel(original, 150, 100))
        style.mode = .smart; style.preserveImages = false
        let noPreserve = try page.image(0, width: 300, style: style)
        XCTAssertEqual(try pixel(noPreserve, 150, 100), try pixel(legacy, 150, 100))
        XCTAssertFalse(try XCTUnwrap(page.pdfInfo()).dirty)
    }
    func testTransparentBackgroundAndGrayscalePreserveAlpha() throws {
        try requireEngine()
        let page = try document(fixture())
        var style = PDFColors.Style(transparent: true, grayscale: true)
        let image = try page.image(0, width: 300, style: style)
        XCTAssertEqual(try pixel(image, 5, 5), [0, 0, 0, 0])
        let picture = try pixel(image, 150, 100)
        XCTAssertEqual(picture[0], picture[1]); XCTAssertEqual(picture[1], picture[2]); XCTAssertEqual(picture[3], 255)
        style.mode = .legacy; style.text = 0xe0e0e0; style.background = 0x202020
        let dark = try page.image(0, width: 300, style: style)
        XCTAssertEqual(try pixel(dark, 5, 5), [0, 0, 0, 0])
        XCTAssertEqual(try pixel(dark, 25, 175), [224, 224, 224, 255])
    }
    func testLargeImageSamplingRetainsArtworkVariance() throws {
        try requireEngine()
        let page = try document(fixture(imageSize: 128))
        let normal = try page.image(0, width: 300, style: .init())
        let smart = try page.image(0, width: 300, style: .init(mode: .smart, text: 0xffffff, background: 0))
        XCTAssertEqual(try pixel(smart, 150, 100), try pixel(normal, 150, 100), "Downsampling uses image dimensions rather than a one-pixel transform")
        XCTAssertEqual(try pixel(smart, 5, 5), [0, 0, 0, 255])
    }
    func testClipBoundsPreventPreservingUnrelatedPaper() throws {
        try requireEngine()
        let page = try document(fixture(clipImage: true))
        let style = PDFColors.Style(mode: .smart, text: 0xffffff, background: 0)
        let smart = try page.image(0, width: 300, style: style)
        let legacy = try page.image(0, width: 300, style: .init(mode: .legacy, text: 0xffffff, background: 0))
        XCTAssertEqual(try pixel(smart, 120, 100), try pixel(legacy, 120, 100), "A clipped sliver is not a full photograph preserve region")
        XCTAssertEqual(try pixel(smart, 170, 100), [0, 0, 0, 255])
    }
    func testVisibleRegionUsesFullPageClassificationAndOriginalPlacement() throws {
        try requireEngine()
        let page = try document(fixture())
        let style = PDFColors.Style(mode: .smart, text: 0xf0f0f0, background: 0x101010)
        let full = try page.image(0, width: 300, style: style)
        let clipped = try page.image(0, width: 300,
            region: CGRect(x: 120, y: 60, width: 60, height: 80), style: style)
        XCTAssertEqual(clipped.width, 60); XCTAssertEqual(clipped.height, 80)
        XCTAssertEqual(try pixel(clipped, 30, 40), try pixel(full, 150, 100), "Visible-region rendering keeps full-page preserve decisions and coordinates")
    }
    func testEngineeringMetadataAndContentDetectionKeepNormalBooksOff() throws {
        try requireEngine()
        XCTAssertTrue(try document(fixture(producer: "AutoCAD")).pdfEngineering().enabled)
        XCTAssertFalse(try document(fixture(producer: "Microsoft Word AutoCAD")).pdfEngineering().enabled)
        let ordinary = try document(fixture(producer: "Word processor")).pdfEngineering()
        XCTAssertFalse(ordinary.enabled); XCTAssertFalse(ordinary.raster); XCTAssertFalse(ordinary.hairline)
        let pdfe = try document(fixture(producer: "Microsoft Word", pdfe: true)).pdfEngineering()
        XCTAssertTrue(pdfe.enabled, "PDF/E marker takes precedence over author metadata")
    }
    func testImageBoundsReuseContentImageGeometryWithoutRecoloring() throws {
        try requireEngine()
        let page = try document(fixture())
        let original = try page.image(0, width: 300, style: .init())
        let outlined = try page.image(0, width: 300, style: .init(showImageBounds: true))
        XCTAssertEqual(try pixel(outlined, 150, 48), [0, 160, 0, 255])
        XCTAssertEqual(try pixel(outlined, 150, 100), try pixel(original, 150, 100))
        XCTAssertEqual(try pixel(outlined, 5, 5), [255, 255, 255, 255])
    }
    func testEngineeringEnhancesThinGrayContentWithoutDarkeningAreaFills() throws {
        try requireEngine()
        let page = try document(fixture(cad: true)), normal = try page.image(0, width: 300)
        let enhanced = try page.image(0, width: 300, style: .init(engineering: true))
        XCTAssertLessThan(try pixel(enhanced, 30, 110)[0], try pixel(normal, 30, 110)[0])
        XCTAssertEqual(try pixel(enhanced, 60, 80), try pixel(normal, 60, 80), "Gray area fills keep their intended contrast")
    }

    private func requireEngine() throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("Build MuPDF before native PDF display tests")
        }
    }
    private func document(_ data: Data) throws -> NativeFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-colors-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.pdf")
        addTeardownBlock {
            defer { try? FileManager.default.removeItem(at: directory) }
            XCTAssertEqual(try Data(contentsOf: source), data, "Display rendering never changes source PDF bytes")
        }
        try data.write(to: source)
        return try NativeFile(source, engine: .mupdf)
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let components = image.bitsPerPixel / 8, offset = y * image.bytesPerRow + x * components
        let color = Array(UnsafeBufferPointer(start: bytes + offset, count: components))
        return components == 3 ? color + [255] : color
    }
    private func fixture(clipImage: Bool = false, producer: String = "", pdfe: Bool = false, cad: Bool = false, imageSize: Int = 4) -> Data {
        let palette = [0x702020, 0x205020, 0x202080, 0x604020, 0x401030, 0x103050, 0x706010, 0x203060,
                     0x301010, 0x106050, 0x703050, 0x305070, 0x504010, 0x104020, 0x602060, 0x203030]
        let image = (0..<(imageSize * imageSize)).map { String(format: "%06x", palette[$0 % palette.count]) }.joined() + ">"
        let content = cad ? "0.5 0 0 0.5 0 0 cm .7 g 20 178 100 4 re f 100 200 100 100 re f\n" :
            "0 g 10 10 30 30 re f q \(clipImage ? "100 50 40 100 re W n " : "")100 0 0 100 100 50 cm /Im Do Q\n"
        let appearance = "0 1 0 rg 0 0 40 40 re f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /XObject /Subtype /Image /Width \(imageSize) /Height \(imageSize) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(image.utf8.count) >>\nstream\n\(image)\nendstream",
            "<< /Type /Annot /Subtype /Square /Rect [240 20 280 60] /F 4 /AP << /N 7 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream",
            "<< /Producer (\(producer)) \(pdfe ? "/ISO_PDFEVersion (PDF/E-1)" : "") >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 8 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
#endif
