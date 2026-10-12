#if os(macOS)
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativeMobiDecodingTests: XCTestCase {
    private func put(_ value: Int, at offset: Int, size: Int, in data: inout Data) {
        for index in 0..<size { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (size - index - 1))) }
    }

    @MainActor
    func testHuffAndTrailerMobiOpenAsNativeTextWithResources() async throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF engine must be built before native integration tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        var html = Data("<html><body><p>Caf".utf8)
        html.append(0xe9)
        html.append(Data(" chapter remains readable.</p><img recindex='1'></body></html>".utf8))
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII="))
        for compression in [1, 17480] {
            var header = Data(repeating: 0, count: 244)
            put(compression, at: 0, size: 2, in: &header)
            put(html.count, at: 4, size: 4, in: &header)
            put(1, at: 8, size: 2, in: &header)
            put(4096, at: 10, size: 2, in: &header)
            header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
            put(228, at: 20, size: 4, in: &header)
            put(1252, at: 28, size: 4, in: &header)
            put(2, at: 108, size: 4, in: &header)
            put(0xffff_ffff, at: 168, size: 4, in: &header)
            var records: [Data]
            if compression == 1 {
                put(2, at: 242, size: 2, in: &header)
                records = [header, html + Data([0, 0, 0, 0x84]), image]
            } else {
                put(3, at: 112, size: 4, in: &header)
                put(2, at: 116, size: 4, in: &header)
                var huff = Data(repeating: 0, count: 1304)
                huff.replaceSubrange(0..<4, with: Data("HUFF".utf8))
                put(24, at: 4, size: 4, in: &huff)
                put(24, at: 8, size: 4, in: &huff)
                put(1048, at: 12, size: 4, in: &huff)
                for index in 0..<256 { put((255 << 8) | 0x80 | 8, at: 24 + index * 4, size: 4, in: &huff) }
                var cdic = Data(repeating: 0, count: 22)
                cdic.replaceSubrange(0..<4, with: Data("CDIC".utf8))
                put(16, at: 4, size: 4, in: &cdic)
                put(1, at: 8, size: 4, in: &cdic)
                put(1, at: 12, size: 4, in: &cdic)
                put(4, at: 16, size: 2, in: &cdic)
                put(html.count | 0x8000, at: 20, size: 2, in: &cdic)
                cdic.append(html)
                records = [header, Data([255]), image, huff, cdic]
            }
            var container = Data(repeating: 0, count: 78 + records.count * 8 + 2)
            container.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
            put(records.count, at: 76, size: 2, in: &container)
            for (index, record) in records.enumerated() {
                put(container.count, at: 78 + index * 8, size: 4, in: &container)
                container.append(record)
            }
            let source = directory.url.appendingPathComponent("book-\(compression).mobi")
            try container.write(to: source)
            let reading = try ReadingDocument.open(source)
            guard case .pages(let pages) = reading.content else { return XCTFail("Expected native MOBI pages") }
            let text = try await pages.text(0)
            XCTAssertTrue(text.contains("Café chapter remains readable."))
            let generated = try XCTUnwrap(reading.temporary).url
            XCTAssertEqual(try Data(contentsOf: generated.appendingPathComponent("00001")), image)
            XCTAssertEqual(try Data(contentsOf: source), container, "Reading preserves the original container")
        }
    }
}
#endif
