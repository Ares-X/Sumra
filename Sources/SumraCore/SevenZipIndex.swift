import Foundation
import CArchive
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The system archive reader owns names, passwords and ordinary metadata. This
/// supplements its 7z stream map with LZMA2 dictionary-reset offsets; decoding
/// still uses that same system library. Nothing is written to disk.
final class SevenZipIndex {
    private struct Unsupported: Error { }
    private struct Coder {
        var id: UInt64
        var properties: Data
    }
    private struct Folder {
        var coder: Coder
        var packedOffset = 0
        var packedSize = 0
        var size = 0
        var crc: UInt32?
        var sizes: [Int] = []
        var crcs: [UInt32?] = []
    }
    private struct Entry {
        var folder: Int
        var offset: Int
        var size: Int
        var crc: UInt32?
    }
    private struct Point {
        var packed: Int
        var unpacked: Int
    }
    private struct Scan {
        var packed: Int
        var unpacked = 0
        var points: [Point] = []
        var finished = false
    }
    private struct Bytes {
        var data: Data
        var position = 0
        var remaining: Int { data.count - position }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw ReadError("Truncated 7z stream metadata") }
            defer { position += count }
            return data.subdata(in: position..<(position + count))
        }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw ReadError("Truncated 7z stream metadata") }
            defer { position += 1 }
            return data[position]
        }
        mutating func integer() throws -> Int {
            let first = try byte()
            var value: UInt64 = 0, mask: UInt8 = 0x80
            for index in 0..<8 {
                if first & mask == 0 {
                    value |= UInt64(first & (mask - 1)) << (8 * index)
                    guard let result = Int(exactly: value) else { throw ReadError("7z stream size overflows") }
                    return result
                }
                value |= UInt64(try byte()) << (8 * index)
                mask >>= 1
            }
            guard let result = Int(exactly: value) else { throw ReadError("7z stream size overflows") }
            return result
        }
        mutating func u32() throws -> UInt32 {
            let bytes = try take(4)
            return bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        mutating func bits(_ count: Int) throws -> [Bool] {
            let bytes = try take(count / 8 + (count % 8 == 0 ? 0 : 1))
            return (0..<count).map { bytes[$0 / 8] & (0x80 >> ($0 % 8)) != 0 }
        }
        mutating func digests(_ count: Int) throws -> [UInt32?] {
            let all = try byte()
            guard all <= 1 else { throw ReadError("Invalid 7z checksum map") }
            if all == 1, count > remaining / 4 { throw ReadError("Truncated 7z checksums") }
            let defined = try all == 1 ? Array(repeating: true, count: count) : bits(count)
            return try defined.map { try $0 ? u32() : nil }
        }
    }

    private let file: FileHandle
    private let folders: [Folder]
    private let entries: [Entry]
    private var scans: [Scan]
    private var reader: OpaquePointer?
    private var readingFolder = -1
    private var position = 0

    static func make(file: FileHandle, regularFiles: [(file: Int, size: Int)],
                     fileCount: Int) throws -> SevenZipIndex? {
        guard fileCount > 0 else { return nil }
        do { return try SevenZipIndex(file: file, regularFiles: regularFiles, fileCount: fileCount) }
        catch is Unsupported { return nil }
    }

    private init(file: FileHandle, regularFiles: [(file: Int, size: Int)], fileCount: Int) throws {
        self.file = file
        let start = try Self.read(file, at: 0, count: 32)
        guard start.prefix(6) == Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) else { throw Unsupported() }
        guard Self.crc(start.subdata(in: 12..<32)) == Self.little32(start, 8) else {
            throw ReadError("Damaged 7z start header")
        }
        func size(_ offset: Int) throws -> Int {
            let value = (0..<8).reduce(UInt64(0)) { $0 | UInt64(start[offset + $1]) << (8 * $1) }
            guard let result = Int(exactly: value) else { throw ReadError("7z header size overflows") }
            return result
        }
        let headerOffset = try Self.add(32, size(12)), headerSize = try size(20)
        let fileSize = try file.seekToEnd()
        guard UInt64(headerOffset) <= fileSize, UInt64(headerSize) <= fileSize - UInt64(headerOffset) else {
            throw ReadError("Truncated 7z header range")
        }
        let next = try Self.read(file, at: headerOffset, count: headerSize)
        guard Self.crc(next) == Self.little32(start, 28) else { throw ReadError("Damaged 7z header") }
        var header = Bytes(data: next)
        var kind = try header.byte()
        if kind == 0x17 {
            let encoded = try Self.streams(&header)
            guard encoded.count == 1 else { throw Unsupported() }
            let stream = encoded[0]
            let decoded = try Self.decode(file, stream)
            if let crc = stream.crc, Self.crc(decoded) != crc { throw ReadError("Damaged decoded 7z header") }
            header = Bytes(data: decoded)
            kind = try header.byte()
        }
        guard kind == 1 else { throw Unsupported() }
        kind = try header.byte()
        if kind == 2 {
            while try header.byte() != 0 { _ = try header.take(header.integer()) }
            kind = try header.byte()
        }
        guard kind == 4 else { throw Unsupported() }
        let parsed = try Self.streams(&header)
        guard !parsed.isEmpty, parsed.allSatisfy({ $0.coder.id == 0x21 && $0.coder.properties.count == 1 }) else {
            throw Unsupported()
        }
        guard try header.byte() == 5 else { throw Unsupported() }
        guard try header.integer() == fileCount else { throw Unsupported() }
        var empty = Array(repeating: false, count: fileCount)
        while true {
            let property = try header.byte()
            if property == 0 { break }
            var payload = try Bytes(data: header.take(header.integer()))
            if property == 0x0e { empty = try payload.bits(fileCount) }
        }

        var streams: [Entry] = []
        for (index, folder) in parsed.enumerated() {
            var offset = 0
            for (substream, size) in folder.sizes.enumerated() {
                streams.append(Entry(folder: index, offset: offset, size: size, crc: folder.crcs[substream]))
                offset = try Self.add(offset, size)
            }
            guard offset == folder.size else { throw ReadError("Invalid 7z folder size") }
        }
        var byFile = Array(repeating: Entry(folder: -1, offset: 0, size: 0, crc: nil), count: fileCount)
        var streamIndex = 0
        for index in 0..<fileCount where !empty[index] {
            guard streamIndex < streams.count else { throw ReadError("Invalid 7z file stream map") }
            byFile[index] = streams[streamIndex]
            streamIndex += 1
        }
        guard streamIndex == streams.count else { throw ReadError("Invalid 7z file stream count") }
        entries = try regularFiles.map {
            let entry = byFile[$0.file]
            guard entry.size == $0.size else { throw ReadError("7z file size changed") }
            return entry
        }
        folders = parsed
        scans = parsed.map { Scan(packed: $0.packedOffset) }
    }

    deinit { reset() }

    func reset() {
        if let reader { archive_read_free(reader) }
        reader = nil
        readingFolder = -1
        position = 0
    }

    func read(_ target: Int, completed: (Int, Data) -> Void) throws -> Data {
        let entry = entries[target]
        if entry.size == 0 { completed(target, Data()); return Data() }
        let folder = folders[entry.folder]
        let point = try point(before: entry.offset, folder: entry.folder)
        if reader == nil || readingFolder != entry.folder || position > entry.offset || point.unpacked > position {
            reset()
            let stream = try Self.open(file, offset: point.packed,
                packed: Self.add(folder.packedOffset, folder.packedSize) - point.packed - 1,
                unpacked: folder.size - point.unpacked, coder: folder.coder)
            reader = stream
            readingFolder = entry.folder
            position = point.unpacked
        }
        for index in 0...target {
            let item = entries[index]
            guard item.folder == readingFolder, item.offset >= position else { continue }
            try Task.checkCancellation()
            try consume(item.offset - position, keeping: false)
            let bytes = try consume(item.size, keeping: true)
            if let crc = item.crc, Self.crc(bytes) != crc { throw ReadError("7z entry checksum mismatch") }
            if position == folder.size {
                var byte: UInt8 = 0
                guard let reader, archive_read_data(reader, &byte, 1) == 0 else {
                    throw Self.error(reader, "Invalid 7z decoded stream size")
                }
            }
            completed(index, bytes)
            try Task.checkCancellation()
            if index == target { return bytes }
        }
        throw ReadError("Cannot locate indexed 7z entry")
    }

    @discardableResult
    private func consume(_ count: Int, keeping: Bool) throws -> Data {
        guard let reader else { throw ReadError("No 7z stream reader") }
        var left = count, result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while left > 0 {
            let amount = archive_read_data(reader, &buffer, min(left, buffer.count))
            guard amount > 0 else { throw Self.error(reader, "Truncated indexed 7z entry") }
            if keeping { result.append(contentsOf: buffer.prefix(amount)) }
            position += amount
            left -= amount
        }
        return result
    }

    private func point(before target: Int, folder index: Int) throws -> Point {
        let folder = folders[index]
        let end = try Self.add(folder.packedOffset, folder.packedSize)
        guard folder.packedSize > 0, try Self.read(file, at: end - 1, count: 1)[0] == 0 else {
            throw ReadError("Missing LZMA2 end marker")
        }
        while !scans[index].finished && scans[index].unpacked <= target {
            try Task.checkCancellation()
            let at = scans[index].packed
            guard at < end else { throw ReadError("Missing LZMA2 end marker") }
            let bytes = try Self.read(file, at: at, count: min(6, end - at))
            let control = bytes[0]
            if control == 0 {
                guard scans[index].unpacked == folder.size else { throw ReadError("Invalid LZMA2 output size") }
                scans[index].finished = true
                break
            }
            var headerSize: Int, packed: Int, unpacked: Int
            if control == 1 || control == 2 {
                guard bytes.count >= 3 else { throw ReadError("Truncated LZMA2 copy header") }
                headerSize = 3
                unpacked = (Int(bytes[1]) << 8 | Int(bytes[2])) + 1
                packed = unpacked
            } else if control >= 0x80 {
                headerSize = control >= 0xc0 ? 6 : 5
                guard bytes.count >= headerSize else { throw ReadError("Truncated LZMA2 chunk header") }
                unpacked = (Int(control & 31) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])) + 1
                packed = (Int(bytes[3]) << 8 | Int(bytes[4])) + 1
            } else { throw ReadError("Invalid LZMA2 control byte") }
            let nextPacked = try Self.add(at, Self.add(headerSize, packed))
            let nextUnpacked = try Self.add(scans[index].unpacked, unpacked)
            guard nextPacked < end, nextUnpacked <= folder.size else { throw ReadError("Invalid LZMA2 chunk size") }
            if control == 1 || control >= 0xe0 {
                scans[index].points.append(Point(packed: at, unpacked: scans[index].unpacked))
            }
            scans[index].packed = nextPacked
            scans[index].unpacked = nextUnpacked
        }
        guard let point = scans[index].points.last(where: { $0.unpacked <= target }) else {
            throw ReadError("Missing independent LZMA2 start")
        }
        return point
    }

    private static func streams(_ bytes: inout Bytes) throws -> [Folder] {
        guard try bytes.byte() == 6 else { throw Unsupported() }
        let packOffset = try add(32, bytes.integer()), packCount = try bytes.integer()
        guard packCount <= bytes.remaining, try bytes.byte() == 9 else { throw ReadError("Invalid 7z pack map") }
        var packed: [Int] = []
        for _ in 0..<packCount { packed.append(try bytes.integer()) }
        var kind = try bytes.byte()
        if kind == 10 { _ = try bytes.digests(packCount); kind = try bytes.byte() }
        guard kind == 0, try bytes.byte() == 7, try bytes.byte() == 11 else { throw Unsupported() }
        let count = try bytes.integer()
        guard count <= bytes.remaining, count == packCount, try bytes.byte() == 0 else { throw Unsupported() }
        var folders: [Folder] = [], position = packOffset
        for index in 0..<count {
            guard try bytes.integer() == 1 else { throw Unsupported() }
            let flags = try bytes.byte(), length = Int(flags & 15)
            guard length > 0, flags & 0x80 == 0 else { throw Unsupported() }
            let idBytes = try bytes.take(length)
            guard length <= 8 else { throw Unsupported() }
            let id = idBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if flags & 0x10 != 0 {
                guard try bytes.integer() == 1, try bytes.integer() == 1 else { throw Unsupported() }
            }
            let properties = try flags & 0x20 != 0 ? bytes.take(bytes.integer()) : Data()
            guard id == 0x21 || id == 0x030101 else { throw Unsupported() }
            folders.append(Folder(coder: Coder(id: id, properties: properties),
                packedOffset: position, packedSize: packed[index]))
            position = try add(position, packed[index])
        }
        guard try bytes.byte() == 12 else { throw ReadError("Missing 7z unpack sizes") }
        for index in folders.indices { folders[index].size = try bytes.integer() }
        kind = try bytes.byte()
        if kind == 10 {
            let crcs = try bytes.digests(count)
            for index in folders.indices { folders[index].crc = crcs[index] }
            kind = try bytes.byte()
        }
        guard kind == 0 else { throw ReadError("Invalid 7z unpack map") }
        var counts = Array(repeating: 1, count: count)
        kind = try bytes.byte()
        if kind == 8 {
            kind = try bytes.byte()
            if kind == 13 {
                for index in counts.indices { counts[index] = try bytes.integer() }
                kind = try bytes.byte()
            }
            for index in folders.indices {
                guard counts[index] <= bytes.remaining + 1 else { throw ReadError("Invalid 7z substream count") }
                var total = 0, sizes: [Int] = []
                if counts[index] > 1 {
                    guard kind == 9 else { throw ReadError("Missing 7z substream sizes") }
                    for _ in 1..<counts[index] {
                        let size = try bytes.integer()
                        total = try add(total, size)
                        sizes.append(size)
                    }
                }
                guard total <= folders[index].size else { throw ReadError("Invalid 7z substream size") }
                if counts[index] > 0 { sizes.append(folders[index].size - total) }
                folders[index].sizes = sizes
            }
            if kind == 9 { kind = try bytes.byte() }
            let digestCount = try folders.indices.reduce(0) {
                try add($0, counts[$1] == 1 && folders[$1].crc != nil ? 0 : counts[$1])
            }
            let crcs = try kind == 10 ? bytes.digests(digestCount) : Array<UInt32?>(repeating: nil, count: digestCount)
            if kind == 10 { kind = try bytes.byte() }
            guard kind == 0 else { throw ReadError("Invalid 7z substream map") }
            var at = 0
            for index in folders.indices {
                if counts[index] == 1, let crc = folders[index].crc { folders[index].crcs = [crc] }
                else {
                    folders[index].crcs = Array(crcs[at..<(at + counts[index])])
                    at += counts[index]
                }
            }
            kind = try bytes.byte()
        } else {
            for index in folders.indices {
                folders[index].sizes = [folders[index].size]
                folders[index].crcs = [folders[index].crc]
            }
        }
        guard kind == 0 else { throw ReadError("Invalid 7z streams terminator") }
        return folders
    }

    private static func open(_ file: FileHandle, offset: Int, packed: Int, unpacked: Int,
                             coder: Coder) throws -> OpaquePointer {
        guard let reader = archive_read_new() else { throw ReadError("Cannot allocate 7z stream reader") }
        let status = coder.properties.withUnsafeBytes {
            sumra_archive_open_7z_stream(reader, file.fileDescriptor, Int64(offset), Int64(packed),
                Int64(unpacked), coder.id, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }
        if status != ARCHIVE_OK {
            let cause = error(reader, "Cannot open indexed 7z stream")
            archive_read_free(reader)
            throw cause
        }
        var entry: OpaquePointer?
        guard archive_read_next_header(reader, &entry) == ARCHIVE_OK else {
            let cause = error(reader, "Cannot read indexed 7z stream")
            archive_read_free(reader)
            throw cause
        }
        return reader
    }

    private static func decode(_ file: FileHandle, _ folder: Folder) throws -> Data {
        let terminal = folder.coder.id == 0x21 ? 1 : 0
        let reader = try open(file, offset: folder.packedOffset, packed: folder.packedSize - terminal,
            unpacked: folder.size, coder: folder.coder)
        defer { archive_read_free(reader) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let amount = archive_read_data(reader, &buffer, buffer.count)
            guard amount >= 0 else { throw error(reader, "Cannot decode 7z header") }
            if amount == 0 { break }
            data.append(contentsOf: buffer.prefix(amount))
            guard data.count <= folder.size else { throw ReadError("Invalid decoded 7z header size") }
        }
        guard data.count == folder.size else {
            throw ReadError("Truncated decoded 7z header: \(data.count) of \(folder.size) bytes")
        }
        return data
    }

    private static func read(_ file: FileHandle, at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else { throw ReadError("Invalid 7z stream range") }
        var data = Data(count: count)
        let amount = data.withUnsafeMutableBytes { pread(file.fileDescriptor, $0.baseAddress, count, off_t(offset)) }
        guard amount >= 0 else { throw ReadError("Cannot read 7z index: " + String(cString: strerror(errno))) }
        guard amount == count else { throw ReadError("Truncated 7z stream index") }
        return data
    }

    private static func add(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow, left >= 0, right >= 0 else { throw ReadError("7z stream range overflows") }
        return value
    }
    private static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { sumra_archive_crc32($0.baseAddress, $0.count) }
    }
    private static func little32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }
    private static func error(_ reader: OpaquePointer?, _ fallback: String) -> ReadError {
        ReadError(reader.flatMap { archive_error_string($0) }.map(String.init(cString:)) ?? fallback)
    }
}
