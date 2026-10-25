import Foundation
import CArchive

extension LegacyText.MobiContent {
    static func partName(_ index: Int) -> String { String(format: "part-%05d.xhtml", index) }

    /// KF8 spine documents keep separate stylesheet contexts in MuPDF's EPUB
    /// reader. Ordinary MOBI and single-part KF8 retain their HTML adapter.
    public func materialize(in directory: URL) throws -> URL {
        if additionalParts.isEmpty {
            let source = directory.appendingPathComponent("document.mobihtml")
            try html.write(to: source)
            for (name, bytes) in resources { try bytes.write(to: directory.appendingPathComponent(name)) }
            return source
        }
        let parts = [html] + additionalParts
        let source = directory.appendingPathComponent("document.mobiepub")
        let container = "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>"
        var manifest = parts.indices.map { "<item id='part-\($0)' href='\(Self.partName($0))' media-type='application/xhtml+xml'/>" }.joined()
        for (index, name) in resources.keys.sorted().enumerated() {
            let type: String
            if name.hasSuffix(".css") { type = "text/css" }
            else if name.hasSuffix(".svg") { type = "image/svg+xml" }
            else if resources[name]!.starts(with: [0xff, 0xd8]) { type = "image/jpeg" }
            else if resources[name]!.starts(with: [0x89, 0x50, 0x4e, 0x47]) { type = "image/png" }
            else if resources[name]!.starts(with: Array("GIF8".utf8)) { type = "image/gif" }
            else { type = "application/octet-stream" }
            manifest += "<item id='resource-\(index)' href='\(name)' media-type='\(type)'/>"
        }
        let spine = parts.indices.map { "<itemref idref='part-\($0)'/>" }.joined()
        let package = "<package xmlns='http://www.idpf.org/2007/opf' version='2.0' unique-identifier='book-id'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title>Kindle document</dc:title><dc:identifier id='book-id'>urn:sumra:kf8</dc:identifier><dc:language>und</dc:language></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        guard let writer = archive_write_new() else { throw ReadError("Cannot create KF8 EPUB archive") }
        defer { archive_write_free(writer) }
        func check(_ status: Int32) throws {
            guard status == ARCHIVE_OK else { throw ReadError(archive_error_string(writer).map { String(cString: $0) } ?? "Cannot write KF8 EPUB archive") }
        }
        try check(archive_write_set_format_zip(writer))
        try check(archive_write_set_options(writer, "zip:compression=store"))
        try check(archive_write_open_filename(writer, source.path))
        func write(_ name: String, _ bytes: Data) throws {
            guard let entry = archive_entry_new() else { throw ReadError("Cannot create KF8 EPUB entry") }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, name)
            archive_entry_set_filetype(entry, 0o100000)
            archive_entry_set_perm(entry, 0o644)
            archive_entry_set_size(entry, Int64(bytes.count))
            archive_entry_set_mtime(entry, 0, 0)
            try check(archive_write_header(writer, entry))
            let written = bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
            guard written == bytes.count else { throw ReadError(archive_error_string(writer).map { String(cString: $0) } ?? "Cannot write KF8 EPUB entry") }
        }
        try write("mimetype", Data("application/epub+zip".utf8))
        try write("META-INF/container.xml", Data(container.utf8))
        try write("book.opf", Data(package.utf8))
        for (index, bytes) in parts.enumerated() { try write(Self.partName(index), bytes) }
        for name in resources.keys.sorted() { try write(name, resources[name]!) }
        try check(archive_write_close(writer))
        return source
    }
}
