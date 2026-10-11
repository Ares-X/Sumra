#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class ComicFolderOutlineTests: XCTestCase {
    private func archiveEntries(in directory: URL) throws -> [(name: String, data: Data)] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path))
        return try enumerator.allObjects.compactMap { item in
            guard let relativePath = item as? String else { return nil }
            let url = directory.appendingPathComponent(relativePath)
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let name = relativePath + (isDirectory ? "/" : "")
            return (name, isDirectory ? Data() : try Data(contentsOf: url))
        }.sorted { $0.name < $1.name }
    }

    private func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) }
        }
        return crc ^ UInt32.max
    }

    private func fixture(in directory: URL, images: [(String, Int)], extras: [String] = []) throws -> URL {
        for (name, width) in images {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 20))
            let image = try XCTUnwrap(context.makeImage())
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        }
        for name in extras {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Not a comic page".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        // Stored ZIP entries explicitly mark UTF-8 names, including comic folders.
        let entries = try archiveEntries(in: directory)
        var archive = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8), crc = checksum(entry.data), offset = UInt32(archive.count)
            archive.appendLE(UInt32(0x04034b50))
            for value: UInt16 in [20, 0x0800, 0, 0, 0] { archive.appendLE(value) }
            archive.appendLE(crc)
            archive.appendLE(UInt32(entry.data.count)); archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0))
            archive.append(name); archive.append(entry.data)
            central.appendLE(UInt32(0x02014b50))
            for value: UInt16 in [20, 20, 0x0800, 0, 0, 0] { central.appendLE(value) }
            central.appendLE(crc)
            central.appendLE(UInt32(entry.data.count)); central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count))
            for value: UInt16 in [0, 0, 0, 0] { central.appendLE(value) }
            central.appendLE(UInt32(entry.name.hasSuffix("/") ? 0x10 : 0))
            central.appendLE(offset); central.append(name)
        }
        let offset = UInt32(archive.count)
        archive.append(central); archive.appendLE(UInt32(0x06054b50))
        archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count)); archive.appendLE(offset); archive.appendLE(UInt16(0))
        try archive.write(to: directory.appendingPathComponent("book.cbz"))
        return directory.appendingPathComponent("book.cbz")
    }

    func testNestedArchiveFoldersUseNaturalPageOrderAndNavigateToFirstImages() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, images: [
            ("漫画/Chapter 10/10.png", 100), ("漫画/Chapter 2/10.png", 40),
            ("漫画/Chapter 2/2.png", 30), ("漫画/Chapter 2/Part 3/1.png", 50),
            ("漫画/Chapter 10/2.png", 90)
        ], extras: ["Notes/readme.txt", "漫画/Chapter 1/readme.txt"])
        let book = try Pages(input, format: .comic)
        let outline = try await book.prepare().outline
        let count = await book.count
        XCTAssertEqual(count, 5)
        XCTAssertEqual(outline.map(\.title), ["漫画", "Chapter 2", "Part 3", "Chapter 10"])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 2, 1])
        XCTAssertEqual(outline.map(\.page), [0, 0, 2, 3])
        for (entry, width) in zip(outline, [30.0, 30.0, 50.0, 90.0]) {
            let destination = try await book.resolve(entry.target)
            let position = try XCTUnwrap(destination)
            let bounds = try await book.bounds(position.page)
            let refreshedPage = try await book.outlinePage(entry.target)
            XCTAssertEqual(position.page, entry.page)
            XCTAssertEqual(refreshedPage, entry.page)
            XCTAssertEqual(bounds.width, width, accuracy: 0.01)
        }
    }

    func testFlatArchiveHasNoInventedImageContents() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, images: [("10.png", 40), ("2.png", 30)],
            extras: ["Notes/readme.txt"])
        let book = try Pages(input, format: .comic)
        let count = await book.count, outline = try await book.prepare().outline
        XCTAssertEqual(count, 2)
        XCTAssertTrue(outline.isEmpty)
    }

    func testFolderPagesKeepTheirExistingIndicesWhenRootImagesArePresent() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try fixture(in: directory.url, images: [("0.png", 20), ("Chapter 2/2.png", 30),
            ("Chapter 10/1.png", 40)])
        let book = try Pages(input, format: .comic)
        let outline = try await book.prepare().outline
        XCTAssertEqual(outline.map(\.title), ["Chapter 2", "Chapter 10"])
        XCTAssertEqual(outline.map(\.page), [1, 2])
        let destination = try await book.resolve(outline[1].target)
        XCTAssertEqual(destination?.page, 2)
    }

    func testRARFoldersNavigateThroughTheComicArchiveReader() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        _ = try fixture(in: directory.url, images: [("Sample/Chapter 10/1.png", 90),
            ("Sample/Chapter 2/10.png", 40), ("Sample/Chapter 2/2.png", 30),
            ("Sample/Chapter 2/Part 3/1.png", 50)], extras: ["Notes/readme.txt"])
        // Stored RAR 5 headers follow https://www.rarlab.com/technote.htm.
        func vint(_ value: Int) -> Data {
            var value = value, result = Data()
            while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }
            result.append(UInt8(value)); return result
        }
        func block(_ header: Data, _ data: Data = Data()) -> Data {
            let header = vint(header.count) + header
            var result = Data(); result.appendLE(checksum(header))
            result.append(header); result.append(data); return result
        }
        var archive = Data([0x52, 0x61, 0x72, 0x21, 0x1a, 7, 1, 0]) + block(Data([1, 0, 0]))
        for entry in try archiveEntries(in: directory.url) where !entry.name.hasSuffix("/") && !entry.name.hasSuffix(".cbz") {
            let name = Data(entry.name.utf8), data = entry.data
            var header = vint(2) + vint(2) + vint(data.count) + vint(4)
            header.append(vint(data.count)); header.append(vint(0o100644)); header.appendLE(checksum(data))
            header.append(vint(0)); header.append(vint(1)); header.append(vint(name.count)); header.append(name)
            archive.append(block(header, data))
        }
        archive.append(block(Data([5, 0, 0])))
        try archive.write(to: directory.url.appendingPathComponent("book.cbr"))
        let input = directory.url.appendingPathComponent("book.cbr")
        XCTAssertEqual(Array(try Data(contentsOf: input).prefix(8)), [0x52, 0x61, 0x72, 0x21, 0x1a, 7, 1, 0])
        let book = try Pages(input, format: .comic)
        let outline = try await book.prepare().outline
        let count = await book.count
        XCTAssertEqual(count, 4)
        XCTAssertEqual(outline.map(\.title), ["Sample", "Chapter 2", "Part 3", "Chapter 10"])
        XCTAssertEqual(outline.map(\.depth), [0, 1, 2, 1])
        XCTAssertEqual(outline.map(\.page), [0, 0, 2, 3])
        for (entry, width) in zip(outline, [30.0, 30.0, 50.0, 90.0]) {
            let destination = try await book.resolve(entry.target)
            let position = try XCTUnwrap(destination)
            let bounds = try await book.bounds(position.page)
            XCTAssertEqual(position.page, entry.page)
            XCTAssertEqual(bounds.width, width, accuracy: 0.01)
        }
    }
}
private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
#endif
