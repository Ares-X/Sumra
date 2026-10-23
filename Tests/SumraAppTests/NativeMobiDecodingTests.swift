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
    func testOrdinaryMobiReusesDecodedHTMLWithNativeTextImagesAndPagination() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII="))
        for codepage in [1252, 65001] {
            for compression in [1, 2] {
                let phrase = codepage == 65001 ? "Café ordinary 中文 passage." : "Café ordinary passage."
                let markup = "<html><body><p>" + String(repeating: phrase + " ", count: 280) + "</p><img recindex='00001'/><p>Final marker.</p></body></html>"
                let text = try XCTUnwrap(markup.data(using: codepage == 65001 ? .utf8 : .windowsCP1252))
                let blocks = stride(from: 0, to: text.count, by: 4096).map { Data(text[$0..<min($0 + 4096, text.count)]) }
                var header = Data(repeating: 0, count: 244)
                put(compression, at: 0, size: 2, in: &header)
                put(text.count, at: 4, size: 4, in: &header)
                put(blocks.count, at: 8, size: 2, in: &header)
                put(4096, at: 10, size: 2, in: &header)
                header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
                put(228, at: 20, size: 4, in: &header)
                put(codepage, at: 28, size: 4, in: &header)
                put(blocks.count + 1, at: 108, size: 4, in: &header)
                put(0xffff_ffff, at: 168, size: 4, in: &header)
                let records = [header] + blocks.map { block -> Data in
                    if compression == 1 { return block }
                    var encoded = Data()
                    for offset in stride(from: 0, to: block.count, by: 8) {
                        let slice = block[offset..<min(offset + 8, block.count)]
                        encoded.append(UInt8(slice.count)); encoded.append(slice)
                    }
                    return encoded
                } + [image]
                var bytes = Data(repeating: 0, count: 78 + records.count * 8 + 2)
                bytes.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8))
                put(records.count, at: 76, size: 2, in: &bytes)
                for (index, record) in records.enumerated() {
                    put(bytes.count, at: 78 + index * 8, size: 4, in: &bytes)
                    bytes.append(record)
                }
                let url = directory.url.appendingPathComponent("ordinary-\(compression)-\(codepage).mobi")
                try bytes.write(to: url)
                let native = try NativeFile(url, engine: .mupdf)
                let reading = try ReadingDocument.open(url)
                let extracted = try XCTUnwrap(reading.temporary, "Already decoded ordinary MOBI must reuse the HTML adapter")
                XCTAssertEqual(try Data(contentsOf: extracted.url.appendingPathComponent("00001")), image)
                let adapted = try NativeFile(extracted.url.appendingPathComponent("document.mobihtml"), engine: .mupdf)
                for file in [native, adapted] {
                    _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 260, height: 300))
                }
                XCTAssertEqual(native.count, adapted.count)
                XCTAssertGreaterThan(adapted.count, 1)
                for page in 0..<native.count {
                    XCTAssertEqual(try native.text(page), try adapted.text(page), "Page text must remain identical after removing the second decode")
                }
                for page in [0, native.count - 1] {
                    let before = try native.image(page, width: 260), after = try adapted.image(page, width: 260)
                    XCTAssertEqual(before.width, after.width); XCTAssertEqual(before.height, after.height)
                    XCTAssertEqual(before.dataProvider?.data as Data?, after.dataProvider?.data as Data?)
                }
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                withExtendedLifetime(reading) {}
            }
        }
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
