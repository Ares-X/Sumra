import Foundation
import CArchive

/// Thin libarchive reader. Metadata is indexed once; sequential entry reads reuse one cursor.
public final class Archive: @unchecked Sendable {
    public let url: URL
    public let entries: [String]

    private let password: String?
    private let positions: [String: Int]
    private let is7Zip: Bool
    private let lock = NSLock()
    private var cursor: OpaquePointer?
    private var cursorIndex = -1
    private var entryCache = [String: Data]()

    public init(_ url: URL, password: String? = nil) throws {
        self.url = url
        self.password = password
        let handle = try Self.open(url, password: password)
        defer { archive_read_free(handle) }

        var entry: OpaquePointer?
        var result: [String] = []
        while try Self.next(handle, &entry), let entry {
            try Task.checkCancellation()
            guard archive_entry_filetype(entry) == 0o100000,
                  let name = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            else { continue }
            if archive_entry_is_encrypted(entry) != 0 {
                guard password != nil else { throw PasswordRequired("Archive password required") }
                // Validate the passphrase before installing a lazily rendered document.
                var byte: UInt8 = 0
                guard archive_read_data(handle, &byte, 1) >= 0 else { throw Self.error(handle) }
            }
            result.append(String(cString: name))
        }

        is7Zip = (archive_format(handle) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_7ZIP
        entries = result
        positions = Dictionary(
            result.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
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
            // Reuse complete entries like Sumatra Archive::GetFileData[Part]ById,
            // retaining decoded entries until this Archive is released.
            // A cache hit does not move the libarchive cursor.
            if let data = entryCache[entryName] {
                return prefixBytes.map { data.prefix($0) } ?? data
            }
            if cursor == nil || target <= cursorIndex {
                resetCursor()
                cursor = try Self.open(url, password: password)
            }
            guard let cursor else { throw ReadError("Cannot read archive") }

            var entry: OpaquePointer?
            while try Self.next(cursor, &entry), let entry {
                try Task.checkCancellation()
                guard archive_entry_filetype(entry) == 0o100000,
                      let pathname = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
                else {
                    archive_read_data_skip(cursor)
                    continue
                }

                cursorIndex += 1
                guard cursorIndex == target else {
                    archive_read_data_skip(cursor)
                    continue
                }
                // Reopening after disk replacement must not bind a different
                // entry's bytes to the name captured by the original index.
                guard String(cString: pathname) == entryName else {
                    throw ReadError("Archive entry changed: \(entryName)")
                }

                var result = Data()
                result.reserveCapacity(64 * 1024)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                // A 7z prefix otherwise makes bounds -> image replay the same
                // solid stream. Decode this one entry once; ZIP keeps partial I/O.
                let readPrefix = is7Zip ? nil : prefixBytes

                while true {
                    try Task.checkCancellation()
                    let requested = readPrefix.map { min(buffer.count, $0 - result.count) } ?? buffer.count
                    if requested == 0 { return result }
                    let n = archive_read_data(cursor, &buffer, requested)
                    if n == 0 {
                        entryCache[entryName] = result
                        return prefixBytes.map { result.prefix($0) } ?? result
                    }
                    guard n > 0 else { throw Self.error(cursor) }
                    result.append(contentsOf: buffer.prefix(n))
                }
            }

            throw ReadError("Archive entry not found: \(name)")
        } catch {
            resetCursor()
            entryCache.removeAll()
            throw error
        }
    }

    private func resetCursor() {
        if let cursor { archive_read_free(cursor) }
        cursor = nil
        cursorIndex = -1
    }

    private static func open(_ url: URL, password: String?) throws -> OpaquePointer {
        guard let archive = archive_read_new() else {
            throw ReadError("Cannot create archive reader")
        }
        if let password { archive_read_add_passphrase(archive, password) }
        archive_read_support_filter_all(archive)
        archive_read_support_format_all(archive)
        // Entry names are opaque reader inputs. Do not interpret __MACOSX
        // entries as AppleDouble metadata for filesystem extraction.
        archive_read_set_option(archive, "zip", "mac-ext", nil)
        guard archive_read_open_filename(archive, url.path, 64 * 1024) == ARCHIVE_OK else {
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
