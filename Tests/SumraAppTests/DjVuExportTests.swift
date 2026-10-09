#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class DjVuExportTests: XCTestCase {
    func testSelectedNativePagesPreserveOrderAndRejectInvalidIndicesBeforeWriting() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, width: 128, height: 96, dpi: 300)
        let output = directory.url.appendingPathComponent("Selected.pdf"), native = try NativeFile(input, engine: .djvu)
        XCTAssertTrue(try native.exportPDF(to: output, selectedPages: [0, 0]))
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        for index in 1...2 {
            let bounds = try XCTUnwrap(pdf.page(at: index)).getBoxRect(.mediaBox)
            XCTAssertEqual(bounds.width, 128 * 72 / 300.0, accuracy: 0.0001)
            XCTAssertEqual(bounds.height, 96 * 72 / 300.0, accuracy: 0.0001)
        }
        let saved = try Data(contentsOf: output)
        for indices in [[], [-1], [1], [Int.max]] {
            XCTAssertThrowsError(try native.exportPDF(to: output, selectedPages: indices))
            XCTAssertEqual(try Data(contentsOf: output), saved)
        }
    }
    func testExportPreservesSourcePixelsDPIAndCoordinatesAcrossBands() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let width = 4096, height = 1600, dpi = 600
        let input = try fixture(in: directory.url, width: width, height: height, dpi: dpi)
        let original = try Data(contentsOf: input), output = directory.url.appendingPathComponent("Export.pdf")
        let pages = try Pages(input, format: .djvu)
        try await pages.exportPDF(to: output)
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL)), page = try XCTUnwrap(pdf.page(at: 1))
        XCTAssertEqual(pdf.numberOfPages, 1)
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, CGFloat(width) * 72 / CGFloat(dpi), accuracy: 0.0001)
        XCTAssertEqual(box.height, CGFloat(height) * 72 / CGFloat(dpi), accuracy: 0.0001)

        // The encoded image objects retain every source pixel. Export does not
        // downsample to a display width or put the whole RGB page in one image.
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &objects))
        var sizes = [(Int, Int)]()
        CGPDFDictionaryApplyBlock(try XCTUnwrap(objects), { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return true }
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { XCTFail("Image stream has no dictionary"); return true }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dictionary, "Width", &width),
               CGPDFDictionaryGetInteger(dictionary, "Height", &height) { sizes.append((width, height)) }
            return true
        }, nil)
        XCTAssertGreaterThan(sizes.count, 1)
        XCTAssertTrue(sizes.allSatisfy { $0.0 == width && $0.1 > 0 && $0.0 * $0.1 * 3 <= 16 * 1024 * 1024 })
        XCTAssertEqual(sizes.reduce(0) { $0 + $1.0 * $1.1 }, width * height)

        let native = try NativeFile(input, engine: .djvu)
        let source = try bitmap(width: width, height: height)
        source.draw(try native.image(0, width: width), in: CGRect(x: 0, y: 0, width: width, height: height))
        let exported = try bitmap(width: width, height: height)
        exported.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        exported.drawPDFPage(page)
        let expected = try XCTUnwrap(source.data).assumingMemoryBound(to: UInt8.self)
        let actual = try XCTUnwrap(exported.data).assumingMemoryBound(to: UInt8.self)
        // Every row is sampled, including both sides of every band boundary.
        // The asymmetric pattern also detects reversed rows or swapped bands.
        for y in 0..<height {
            for x in [0, 9, 63, 135, 511, 1023, 2047, 3071, width - 1] {
                let index = (y * width + x) * 4
                for channel in 0..<3 where abs(Int(expected[index + channel]) - Int(actual[index + channel])) > 2 {
                    XCTFail("Export changed source pixel at \(x),\(y), channel \(channel)")
                    return
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testNativeExportReportsOutputFailureAndDoesNotReplaceSource() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, width: 128, height: 96, dpi: 300)
        let original = try Data(contentsOf: input), native = try NativeFile(input, engine: .djvu)
        XCTAssertThrowsError(try native.exportPDF(to: directory.url.appendingPathComponent("absent/output.pdf"))) {
            XCTAssertTrue($0.localizedDescription.contains("Cannot create PDF"))
        }
        let pages = try Pages(input, format: .djvu)
        do { try await pages.exportPDF(to: input); XCTFail("Source must not be overwritten") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different location")) }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).contains { $0.hasPrefix(".Sumra-export-") })
    }

    func testNativeRenderRegionsPreserveOffsetPixelsWithoutAllocatingTheScaledPage() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, width: 128, height: 96, dpi: 300)
        let native = try NativeFile(input, engine: .djvu)
        for width in [128, 161] {
            let whole = try native.image(0, width: width)
            let region = CGRect(x: 13, y: 17, width: 43, height: 41)
            let tile = try native.image(0, width: width, region: region)
            XCTAssertEqual(tile.width, 43); XCTAssertEqual(tile.height, 41)
            let actual = try bitmap(width: tile.width, height: tile.height)
            actual.draw(tile, in: CGRect(origin: .zero, size: region.size))
            let expected = try bitmap(width: tile.width, height: tile.height)
            expected.draw(try XCTUnwrap(whole.cropping(to: region)), in: CGRect(origin: .zero, size: region.size))
            let count = tile.width * tile.height * 4
            XCTAssertEqual(Data(bytes: try XCTUnwrap(actual.data), count: count),
                Data(bytes: try XCTUnwrap(expected.data), count: count), "DjVu tile coordinates use the scaled page's top-left origin")
        }
        let high = try native.image(0, width: 65_536, region: CGRect(x: 32_768, y: 24_576, width: 512, height: 384))
        XCTAssertEqual(high.width, 512); XCTAssertEqual(high.height, 384)
        XCTAssertLessThan(high.bytesPerRow * high.height, 1024 * 1024)
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        return context
    }

    private func fixture(in directory: URL, width: Int, height: Int, dpi: Int) throws -> URL {
        let engine = try NativeFile.libraryURL(for: .djvu)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("DjVu engine must be built before native integration tests") }
        let encoders = ["/opt/homebrew/opt/djvulibre/bin/cjb2", "/usr/local/opt/djvulibre/bin/cjb2"]
        guard let encoder = encoders.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("DjVuLibre's development encoder is needed to construct the lossless test fixture")
        }
        // PBM is top-down, one bit per pixel; cjb2's default mode is lossless.
        // Construct during the future test run instead of retaining large fixtures.
        var bytes = Data("P4\n\(width) \(height)\n".utf8)
        for y in 0..<height {
            for x in 0..<(width / 8) { bytes.append(y % 23 < 4 || x < 3 || (x / 17 + y / 31) % 7 == 0 ? 255 : 0) }
        }
        let pbm = directory.appendingPathComponent("Source.pbm"), output = directory.appendingPathComponent("Source.djvu")
        try bytes.write(to: pbm)
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: encoder)
        process.arguments = ["-lossless", "-dpi", String(dpi), pbm.path, output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReadError("Cannot construct DjVu fixture: \(String(decoding: message, as: UTF8.self))") }
        return output
    }
}
#endif
