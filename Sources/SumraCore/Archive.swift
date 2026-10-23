import Foundation
import CArchive

/// System libarchive reader with reusable cursors and independent LZMA2 section seeking.
public final class Archive: @unchecked Sendable {
    public let url: URL
    public let entries: [String]

    private let password: String?
    private let positions: [String: Int]
    private let is7Zip: Bool
    private let source: FileHandle?
    private let indexed: SevenZipIndex?
    private let lock = NSLock()
    private var cursor: OpaquePointer?
    private var cursorIndex = -1
    // Encoded entry bytes have their own budget, separate from rendered pages.
    private static let entryCacheLimit = 64 * 1024 * 1024
    private var entryCache = [String: Data]()
    private var entryOrder = [String]()
    private var entryBytes = 0

    public init(_ url: URL, password: String? = nil) throws {
        self.url = url
        self.password = password
        let file = try FileHandle(forReadingFrom: url)
        let handle = try Self.open(url, password: password, descriptor: file.fileDescriptor)
        defer { archive_read_free(handle) }

        var entry: OpaquePointer?
        var result: [String] = []
        var regularFiles: [(file: Int, size: Int)] = []
        var fileCount = 0
        while try Self.next(handle, &entry), let entry {
            try Task.checkCancellation()
            let fileIndex = fileCount
            fileCount += 1
            guard archive_entry_filetype(entry) == 0o100000,
                  let name = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            else { continue }
            if archive_entry_is_encrypted(entry) != 0 {
                guard password != nil else { throw PasswordRequired("Archive password required") }
                // Validate the passphrase before installing a lazily rendered document.
                var byte: UInt8 = 0
                guard archive_read_data(handle, &byte, 1) >= 0 else { throw Self.error(handle) }
            }
            guard let size = Int(exactly: archive_entry_size(entry)), size >= 0 else {
                throw ReadError("Invalid archive entry size")
            }
            regularFiles.append((fileIndex, size))
            result.append(String(cString: name))
        }

        is7Zip = (archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_7ZIP
        entries = result
        positions = Dictionary(
            result.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        source = is7Zip ? file : nil
        indexed = try is7Zip ? SevenZipIndex.make(file: file, regularFiles: regularFiles, fileCount: fileCount) : nil
    }

    deinit { resetCursor() }

    private func position(_ name: String) -> Int? {
        // Archive::GetFileId resolves names for both lookup and reading. Keep
        // an exact spelling when available, otherwise use directory order.
        positions[name] ?? entries.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func contains(_ name: String) -> Bool { position(name) != nil }

    public var images: [String] {
        positions.keys.filter {
            !$0.split(separator: "/").contains(where: { ($0.hasPrefix(".") && $0 != "." && $0 != "..") || $0 == "__MACOSX" })
                && Format.isComicImage($0)
        }.sorted { $0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedAscending }
    }

    public func data(_ name: String, prefixBytes: Int? = nil) throws -> Data {
        guard let target = position(name) else {
            throw ReadError("Archive entry not found: \(name)")
        }
        let entryName = entries[target]
        if let prefixBytes {
            guard prefixBytes >= 0 else { throw ReadError("Invalid archive prefix size") }
            if prefixBytes == 0 { return Data() }
        }

        lock.lock()
        defer { lock.unlock() }

        // A request cancelled before reading has not touched the cursor or
        // completed entries. Keep them available to subsequent page requests.
        try Task.checkCancellation()
        do {
            // A cache hit promotes the entry without moving the archive cursor.
            if let data = entryCache[entryName] {
                entryOrder.removeAll { $0 == entryName }
                entryOrder.append(entryName)
                return prefixBytes.map { data.prefix($0) } ?? data
            }
            if let indexed {
                let data = try indexed.read(target) { index, bytes in
                    let name = entries[index]
                    if positions[name] == index { remember(bytes, named: name) }
                }
                return prefixBytes.map { data.prefix($0) } ?? data
            }
            if cursor == nil || target <= cursorIndex {
                resetCursor()
                if let source { try source.seek(toOffset: 0) }
                cursor = try Self.open(url, password: password, descriptor: source?.fileDescriptor)
            }
            guard let cursor else { throw ReadError("Cannot read archive") }

            var entry: OpaquePointer?
            while true {
                try Task.checkCancellation()
                guard try Self.next(cursor, &entry), let entry else { break }
                guard archive_entry_filetype(entry) == 0o100000,
                      let pathname = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
                else {
                    archive_read_data_skip(cursor)
                    continue
                }

                cursorIndex += 1
                guard cursorIndex == target || is7Zip else {
                    archive_read_data_skip(cursor)
                    continue
                }
                let currentName = entries[cursorIndex]
                // Reopening after disk replacement must not bind a different
                // entry's bytes to the name captured by the original index.
                guard String(cString: pathname) == currentName else {
                    throw ReadError("Archive entry changed: \(currentName)")
                }

                var result = Data()
                result.reserveCapacity(64 * 1024)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                // Skipping a solid 7z entry still decompresses its bytes. Retain
                // recent traversed entries for reverse scrolling.
                // ZIP keeps partial I/O and skips unrelated entries.
                let readPrefix = is7Zip ? nil : prefixBytes

                while true {
                    try Task.checkCancellation()
                    let requested = readPrefix.map { min(buffer.count, $0 - result.count) } ?? buffer.count
                    if requested == 0 { return result }
                    let n = archive_read_data(cursor, &buffer, requested)
                    if n == 0 {
                        if positions[currentName] == cursorIndex { remember(result, named: currentName) }
                        try Task.checkCancellation()
                        if cursorIndex == target { return prefixBytes.map { result.prefix($0) } ?? result }
                        break
                    }
                    guard n > 0 else { throw Self.error(cursor) }
                    result.append(contentsOf: buffer.prefix(n))
                }
            }

            throw ReadError("Archive entry not found: \(name)")
        } catch is CancellationError {
            resetCursor()
            throw CancellationError()
        } catch {
            resetCursor()
            indexed?.reset()
            entryCache.removeAll()
            entryOrder.removeAll()
            entryBytes = 0
            throw error
        }
    }

    private func remember(_ data: Data, named name: String) {
        // A large requested entry can be returned without displacing the entire
        // useful working set or remaining resident for the document's lifetime.
        guard data.count <= Self.entryCacheLimit else { return }
        if let previous = entryCache.removeValue(forKey: name) {
            entryBytes -= previous.count
            entryOrder.removeAll { $0 == name }
        }
        while entryBytes > Self.entryCacheLimit - data.count, let oldest = entryOrder.first {
            entryOrder.removeFirst()
            entryBytes -= entryCache.removeValue(forKey: oldest)!.count
        }
        entryCache[name] = data
        entryOrder.append(name)
        entryBytes += data.count
    }

    private func resetCursor() {
        if let cursor { archive_read_free(cursor) }
        cursor = nil
        cursorIndex = -1
    }

    private static func open(_ url: URL, password: String?, descriptor: Int32? = nil) throws -> OpaquePointer {
        guard let archive = archive_read_new() else {
            throw ReadError("Cannot create archive reader")
        }
        if let password { archive_read_add_passphrase(archive, password) }
        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        // Entry names are opaque reader inputs. Do not interpret __MACOSX
        // entries as AppleDouble metadata for filesystem extraction.
        archive_read_set_option(archive, "zip", "mac-ext", nil)
        let status = descriptor.map { archive_read_open_fd(archive, $0, 64 * 1024) }
            ?? archive_read_open_filename(archive, url.path, 64 * 1024)
        guard status == ARCHIVE_OK else {
            let error = error(archive)
            archive_read_free(archive)
            throw error
        }
        return archive
    }

    private static func next(_ archive: OpaquePointer, _ entry: inout OpaquePointer?) throws -> Bool {
        let status = archive_read_next_header(archive, &entry)
        if status == ARCHIVE_EOF { return false }
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            throw error(archive)
        }
        return true
    }

    private static func error(_ archive: OpaquePointer) -> Error {
        let message = archive_error_string(archive).map(String.init(cString:)) ?? "Cannot read archive"
        if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("password") || message.localizedCaseInsensitiveContains("decrypt") {
            return PasswordRequired(message)
        }
        return ReadError(message)
    }
}
