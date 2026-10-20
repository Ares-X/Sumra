import Foundation
import XCTest
@testable import SumraCore

final class SevenZipSeekTests: XCTestCase {
    func testEmptyArchiveWithoutNextHeaderRemainsReadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".7z")
        // A valid empty 7z has zero next-header offset, size and CRC.
        try Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4, 0x8d, 0x9b, 0xd5, 0x0f]
                 + Array(repeating: UInt8(0), count: 20)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url)
        XCTAssertEqual(archive.entries, [])
        XCTAssertEqual(archive.images, [])
        XCTAssertThrowsError(try archive.data("missing.png")) { XCTAssertTrue($0 is ReadError) }
    }

    func testEncodedHeaderAcceptsLZMA1DictionaryThatIsNotAPowerOfTwo() throws {
        // Python stdlib raw LZMA1 compressed plain header, lc=3/lp=0/pb=2,
        // dictionary=196608 (3 * 65536), properties=5d00000300. File payloads
        // use independent LZMA2 copy resets. Verified by system libarchive.
        let bytes = try XCTUnwrap(Data(base64Encoded: "N3q8ryccAATDmBqscgAAAAAAAAAgAAAAAAAAAA0G5MYBAAlmaXJzdCBwYWdlAQAKc2Vjb25kIHBhZ2UBAAl0aGlyZCBwYWdlAAAAgTMHrg/QluR8nz9HQQQEMjfmkzuLfhOCLo7Fddrv3Xkutn9rkxo5B5UZnf5WSBIdMedQQLzzl9WF4/cKOIdpf7P//+pvIAAXBikBCUkABwsBAAEjAwEBBV0AAAMADFUKAWayPNkAAA=="))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".7z")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url)
        XCTAssertEqual(archive.entries, ["1.png", "2.png", "3.png"])
        XCTAssertEqual(try archive.data("3.png"), Data("third page".utf8))
        XCTAssertEqual(try archive.data("1.png"), Data("first page".utf8))
        XCTAssertEqual(try archive.data("2.png", prefixBytes: 6), Data("second".utf8))
        XCTAssertEqual(try archive.data("2.png"), Data("second page".utf8))
    }

    func testFarJumpAndPrefixReadReturnTheLaterResetBytes() throws {
        let pages = (0..<12).map { page in
            Data((0..<8192).map { UInt8(truncatingIfNeeded: page * 19 + $0) })
        }
        let files = pages.enumerated().map { ("\($0.offset + 1).png", $0.element) }
        let archive = try Archive(writeFixture(files, blocks: pages.map(copyReset)))
        XCTAssertEqual(archive.entries, files.map(\.0))
        XCTAssertEqual(try archive.data("12.png", prefixBytes: 127), Data(pages[11].prefix(127)))
        XCTAssertEqual(try archive.data("12.png"), pages[11])
        XCTAssertEqual(try archive.data("8.png"), pages[7])
        XCTAssertEqual(try archive.data("1.png"), pages[0])
    }

    func testEntrySpanningResetBoundariesReturnsAllBytes() throws {
        let first = Data("cover".utf8)
        let spanning = Data((0..<257).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let last = Data("last-page".utf8)
        let payload = first + spanning + last
        // Both boundaries fall inside 2.png, including one before the prefix ends.
        let blocks = [Data(payload.prefix(17)), Data(payload[17..<193]), Data(payload.dropFirst(193))]
        let archive = try Archive(writeFixture([("1.png", first), ("2.png", spanning), ("3.png", last)], blocks: blocks.map(copyReset)))
        XCTAssertEqual(try archive.data("2.png", prefixBytes: 211), Data(spanning.prefix(211)))
        XCTAssertEqual(try archive.data("2.png"), spanning)
        XCTAssertEqual(try archive.data("3.png"), last)
    }

    func testCorruptEarlierCompressedSegmentDoesNotPreventIndependentLaterRead() throws {
        let first = Data(repeating: 65, count: 4096)
        let second = Data("independent second page".utf8)
        let tail = Data("independent final page".utf8)
        // Python stdlib lzma FORMAT_RAW, FILTER_LZMA2, dict_size=1<<20,
        // encoding 4096 ASCII A bytes. Remove the terminal 0 so resets can follow.
        var compressed = Data([0xe0, 0x0f, 0xff, 0, 0x19, 0x5d, 0, 0x20,
                               0xef, 0xfb, 0xbf, 0xfe, 0xa3, 0xb1, 0x5e, 0xe5,
                               0xf8, 0x3f, 0xb2, 0xaa, 0x26, 0x55, 0xf8, 0x68,
                               0x70, 0x41, 0x70, 0x15, 0x0e, 0x24, 0x18, 0xcf])
        // Keep the control, compressed/uncompressed lengths and properties valid;
        // break the range coder's initial byte. Sequential decoding must fail.
        compressed[6] = 0xff
        let archive = try Archive(writeFixture([("1.png", first), ("2.png", second), ("3.png", tail)],
                                              blocks: [compressed, copyReset(second), copyReset(tail)]))
        // Correct bytes beyond an undecodable first segment prove that reaching
        // the target did not decode the earlier segment, without a timing limit.
        XCTAssertEqual(try archive.data("3.png", prefixBytes: 11), Data(tail.prefix(11)))
        XCTAssertEqual(try archive.data("3.png"), tail)
        XCTAssertEqual(try archive.data("2.png"), second)
        XCTAssertThrowsError(try archive.data("1.png")) { XCTAssertTrue($0 is ReadError) }
        XCTAssertEqual(try archive.data("3.png"), tail)
    }

    func testTargetChecksumMismatchRejectsFullAndPrefixReads() throws {
        let first = Data("first page".utf8), target = Data("checksum protected target".utf8)
        let url = try writeFixture([("1.png", first), ("2.png", target)],
                                   blocks: [copyReset(first), copyReset(target)],
                                   checksumOverrides: [1: crc32(target) ^ 1])
        for prefix: Int? in [nil, 3] {
            let archive = try Archive(url)
            XCTAssertThrowsError(try archive.data("2.png", prefixBytes: prefix)) { XCTAssertTrue($0 is ReadError) }
            XCTAssertEqual(try archive.data("1.png"), first)
        }
    }

    func testOpenDescriptorSupportsUnreadForwardAndReverseSegmentsAfterMove() throws {
        let pages = (1...4).map { Data(repeating: UInt8($0), count: $0 * 101) }
        let files = pages.enumerated().map { ("\($0.offset + 1).png", $0.element) }
        let url = try writeFixture(files, blocks: pages.map(copyReset))
        let archive = try Archive(url)
        XCTAssertEqual(try archive.data("1.png"), pages[0])
        let moved = url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: url, to: moved)
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
        XCTAssertEqual(try archive.data("4.png"), pages[3])
        // These pages have never been requested; neither traversal nor reverse
        // reads may depend on reopening the original pathname.
        XCTAssertEqual(try archive.data("2.png", prefixBytes: 31), Data(pages[1].prefix(31)))
        XCTAssertEqual(try archive.data("3.png"), pages[2])
        XCTAssertEqual(try archive.data("2.png"), pages[1])
    }

    func testRepeatedNamesKeepFirstEntryAcrossResetSegments() throws {
        let first = Data("first".utf8), duplicate = Data("duplicate".utf8), tail = Data("tail".utf8)
        let archive = try Archive(writeFixture([("1.png", first), ("1.png", duplicate), ("2.png", tail)],
                                              blocks: [first, duplicate, tail].map(copyReset)))
        XCTAssertEqual(archive.images, ["1.png", "2.png"])
        XCTAssertEqual(try archive.data("2.png"), tail)
        XCTAssertEqual(try archive.data("1.png"), first)
        XCTAssertEqual(try archive.data("1.PNG", prefixBytes: 2), Data(first.prefix(2)))
    }

    func testSingleResetSolidArchiveRemainsReadable() throws {
        let first = Data("first".utf8), second = Data("second".utf8)
        let archive = try Archive(writeFixture([("1.png", first), ("2.png", second)],
                                              blocks: [copyReset(first + second)]))
        XCTAssertEqual(try archive.data("2.png"), second)
        XCTAssertEqual(try archive.data("1.png", prefixBytes: 2), Data(first.prefix(2)))
        XCTAssertEqual(try archive.data("1.png"), first)
    }

    func testMultipleFoldersUseTheirOwnPackedRanges() throws {
        let pages = (1...4).map { Data(repeating: UInt8($0 * 43), count: $0 * 137) }
        let files = pages.enumerated().map { ("\($0.offset + 1).png", $0.element) }
        let archive = try Archive(writeFixture(files, folders: [
            (2, [copyReset(pages[0]), copyReset(pages[1])]),
            (2, [copyReset(pages[2]), copyReset(pages[3])])
        ]))
        XCTAssertEqual(try archive.data("4.png"), pages[3])
        XCTAssertEqual(try archive.data("2.png"), pages[1])
        XCTAssertEqual(try archive.data("3.png", prefixBytes: 57), Data(pages[2].prefix(57)))
        XCTAssertEqual(try archive.data("1.png"), pages[0])
    }

    func testEmptyStreamMapSeparatesDirectoriesAndEmptyRegularFiles() throws {
        let first = Data("first-page".utf8), second = Data("second-page".utf8), last = Data("last-page".utf8)
        let archive = try Archive(writeFixture([
            ("directory/", Data()), ("1.png", first), ("empty.png", Data()),
            ("another-directory/", Data()), ("2.png", second),
            ("later-empty.png", Data()), ("3.png", last)
        ], blocks: [first, second, last].map(copyReset), directories: [0, 3]))
        XCTAssertEqual(archive.entries, ["1.png", "empty.png", "2.png", "later-empty.png", "3.png"])
        XCTAssertEqual(try archive.data("3.png"), last)
        XCTAssertEqual(try archive.data("empty.png"), Data())
        XCTAssertEqual(try archive.data("2.png"), second)
        XCTAssertEqual(try archive.data("later-empty.png"), Data())
        XCTAssertEqual(try archive.data("1.png"), first)
        XCTAssertFalse(archive.contains("directory/"))
    }

    func testFolderChecksumWithoutSubstreamChecksumsProtectsSingleFileFolders() throws {
        let first = Data("first folder page".utf8), second = Data("second folder page".utf8)
        let files = [("1.png", first), ("2.png", second)]
        let folders = [(1, [copyReset(first)]), (1, [copyReset(second)])]
        let archive = try Archive(writeFixture(files, folders: folders, folderChecksumsOnly: true))
        XCTAssertEqual(try archive.data("2.png"), second)
        XCTAssertEqual(try archive.data("1.png"), first)
        let damaged = try Archive(writeFixture(files, checksumOverrides: [1: crc32(second) ^ 1],
                                              folders: folders, folderChecksumsOnly: true))
        XCTAssertThrowsError(try damaged.data("2.png", prefixBytes: 3)) { XCTAssertTrue($0 is ReadError) }
        XCTAssertEqual(try damaged.data("1.png"), first)
    }

    // A minimal plain-header 7z fixture: one LZMA2 coder/folder, named file
    // substreams with individual CRC32 values. Copy chunks contain at most 64K.
    // No compression executable, dependency, book mutation or extracted files.
    private func copyReset(_ data: Data) -> Data {
        precondition(!data.isEmpty && data.count <= 65536)
        let size = data.count - 1
        return Data([1, UInt8(size >> 8), UInt8(size & 255)]) + data
    }

    private func writeFixture(_ files: [(String, Data)], blocks: [Data] = [],
                              checksumOverrides: [Int: UInt32] = [:],
                              folders: [(fileCount: Int, blocks: [Data])]? = nil,
                              directories: Set<Int> = [], folderChecksumsOnly: Bool = false) throws -> URL {
        let streams = files.enumerated().filter { !$0.element.1.isEmpty }
        let folders = folders ?? [(streams.count, blocks)]
        let packedFolders = folders.map { $0.blocks.reduce(into: Data()) { $0.append($1) } + Data([0]) }
        let packed = packedFolders.reduce(into: Data()) { $0.append($1) }
        var fileOffset = 0
        let folderFiles = folders.map { folder in
            defer { fileOffset += folder.fileCount }
            return Array(streams[fileOffset..<(fileOffset + folder.fileCount)])
        }
        var header = Data([1, 4, 6, 0]) // Header, MainStreamsInfo, PackInfo
        header.append(number(folders.count))
        header.append(9)
        for bytes in packedFolders { header.append(number(bytes.count)) }
        header.append(contentsOf: [0, 7, 11])
        header.append(number(folders.count))
        header.append(0)
        for _ in folders { header.append(contentsOf: [1, 0x21, 0x21, 1, 0x10]) }
        header.append(12)
        for group in folderFiles { header.append(number(group.reduce(0) { $0 + $1.element.1.count })) }
        if folderChecksumsOnly {
            precondition(folders.allSatisfy { $0.fileCount == 1 })
            header.append(contentsOf: [10, 1])
            for group in folderFiles {
                let file = group[0]
                header.append(littleEndian(checksumOverrides[file.offset] ?? crc32(file.element.1)))
            }
        }
        header.append(0)
        if folderChecksumsOnly {
            // Defaults: one substream per folder, inheriting its folder CRC.
            // No redundant NumUnpackStream, Size or CRC properties.
            header.append(contentsOf: [8, 0])
        } else {
            header.append(contentsOf: [8, 13]) // SubStreamsInfo, NumUnpackStream
            for folder in folders { header.append(number(folder.fileCount)) }
            header.append(9)
            for group in folderFiles {
                for file in group.dropLast() { header.append(number(file.element.1.count)) }
            }
            header.append(contentsOf: [10, 1]) // all substream CRCs defined
            for file in streams { header.append(littleEndian(checksumOverrides[file.offset] ?? crc32(file.element.1))) }
            header.append(0)
        }
        header.append(contentsOf: [0, 5]) // End streams, FilesInfo
        header.append(number(files.count))
        let emptyFiles = files.indices.filter { files[$0].1.isEmpty }
        if !emptyFiles.isEmpty {
            let emptyStreams = bits(files.indices.map { files[$0].1.isEmpty })
            header.append(14)
            header.append(number(emptyStreams.count))
            header.append(emptyStreams)
            let regularEmptyFiles = bits(emptyFiles.map { !directories.contains($0) })
            header.append(15)
            header.append(number(regularEmptyFiles.count))
            header.append(regularEmptyFiles)
        }
        var names = Data([0]) // external = false
        for (name, _) in files {
            for unit in (name + "\0").utf16 {
                names.append(UInt8(truncatingIfNeeded: unit))
                names.append(UInt8(truncatingIfNeeded: unit >> 8))
            }
        }
        header.append(17)
        header.append(number(names.count))
        header.append(names)
        header.append(contentsOf: [0, 0])
        let start = littleEndian(UInt64(packed.count)) + littleEndian(UInt64(header.count)) + littleEndian(crc32(header))
        let archive = Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4]) + littleEndian(crc32(start)) + start + packed + header
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".7z")
        try archive.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func bits(_ values: [Bool]) -> Data {
        var result = Data(repeating: 0, count: (values.count + 7) / 8)
        for (index, value) in values.enumerated() where value { result[index / 8] |= 0x80 >> (index % 8) }
        return result
    }

    private func number(_ value: Int) -> Data {
        let value = UInt64(value)
        for count in 0..<8 where value < (UInt64(1) << (7 + count * 7)) {
            var result = Data([UInt8(truncatingIfNeeded: (UInt64(0xff) << (8 - count)) | (value >> (8 * count)))])
            for index in 0..<count { result.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
            return result
        }
        return Data([0xff]) + littleEndian(value)
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
        }
        return ~crc
    }
}
