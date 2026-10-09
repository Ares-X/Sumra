#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import SumraCore

enum NativeEngine: String {
    case mupdf = "MuPDF", djvu = "DjVu", chm = "CHM", jpegXL = "JPEGXL"
}

struct RasterLink: Decodable {
    let uri: String
    let rect: [Double]
    var bounds: CGRect { CGRect(raster: rect) }
}
// HTML flow identities identify a source glyph, including repeated passages.
// They are valid only for the same source revision and parsing style.
struct NativeSourceAnchor: Codable, Hashable, Comparable {
    let node: UInt32, offset: UInt32, part: UInt32
    init(node: UInt32, offset: UInt32, part: UInt32) { self.node = node; self.offset = offset; self.part = part }
    static func < (a: Self, b: Self) -> Bool {
        if a.node != b.node { return a.node < b.node }
        if a.offset != b.offset { return a.offset < b.offset }
        return a.part < b.part
    }
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        node = try values.decode(UInt32.self); offset = try values.decode(UInt32.self); part = try values.decode(UInt32.self)
        guard values.isAtEnd else { throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid source anchor") }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(node); try values.encode(offset); try values.encode(part)
    }
}
struct NativePassage: Codable, Hashable {
    let source: NativeSourceAnchor
    let offsetX: Double, offsetY: Double
    let sourceRevision: String, styleSignature: String
}
struct RasterSelection: Decodable {
    let text: String
    let rects: [[Double]]
    var words: [RasterWord]? = nil
    // MuPDF's selection geometry in page space, ordered ul, ur, ll, lr.
    // Other engines and rectangular selections keep their existing rects.
    var quads: [[[Double]]]? = nil
    var sourceStart: NativeSourceAnchor? = nil
    var sourceEnd: NativeSourceAnchor? = nil
    var bounds: [CGRect] { rects.map { CGRect(raster: $0) } }

    static func select(_ words: [RasterWord], range: NSRange) -> Self {
        let text = words.map(\.text).joined() as NSString
        guard range.location >= 0, range.length >= 0, range.location <= text.length,
              range.length <= text.length-range.location else { return .init(text: "", rects: [], words: []) }
        var offset = 0, selected = [RasterWord]()
        for word in words {
            let count = word.text.utf16.count
            let overlap = NSIntersectionRange(range, NSRange(location: offset, length: count))
            if overlap.length > 0 {
                var box = word.bounds
                // DjVu exposes word zones; retain its proportional glyph boxes.
                // MuPDF already provides one entry per Unicode scalar.
                if !box.isEmpty {
                    box.origin.x += box.width * CGFloat(overlap.location-offset) / CGFloat(count)
                    box.size.width *= CGFloat(overlap.length) / CGFloat(count)
                }
                let fragment = (word.text as NSString).substring(with: NSRange(location: overlap.location-offset, length: overlap.length))
                selected.append(.init(text: fragment, rect: box.raster, source: word.source))
            }
            offset += count
        }
        let sources = selected.compactMap(\.source)
        return .init(text: text.substring(with: range), rects: selected.filter { !$0.bounds.isEmpty }.map(\.rect), words: selected,
                     sourceStart: sources.min(), sourceEnd: sources.max())
    }
}
struct RasterWord: Decodable {
    let text: String
    let rect: [Double]
    var source: NativeSourceAnchor? = nil
    var bounds: CGRect { CGRect(raster: rect) }
}
extension CGRect {
    init(raster values: [Double]) {
        self = values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : .zero
    }
    var raster: [Double] { [Double(minX), Double(minY), Double(width), Double(height)] }
}

// FitzAbortCookie has a public cross-thread abort contract. The callback owns
// this same object as the render operation, including its independent dylib
// reference; neither the cookie nor its code can disappear during cancellation.
final class NativeRenderCancellation: @unchecked Sendable {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Action = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Status = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private let library: UnsafeMutableRawPointer
    let handle: UnsafeMutableRawPointer
    private let abortCookie: Action, dropCookie: Action
    private let cookieStatus: Status

    init() throws {
        let path = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(path.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load MuPDF: " + (dlerror().map { String(cString: $0) } ?? "unknown loader error"))
        }
        do {
            func required<T>(_ name: String, _: T.Type) throws -> T {
                guard let value = dlsym(library, name) else { throw ReadError("Incompatible MuPDF engine: " + name) }
                return unsafeBitCast(value, to: T.self)
            }
            let create = try required("lf_render_cookie_new", Create.self)
            let abort = try required("lf_render_cookie_abort", Action.self)
            let drop = try required("lf_render_cookie_drop", Action.self)
            let status = try required("lf_render_cookie_aborted", Status.self)
            guard let handle = create() else { throw ReadError("Cannot allocate render cancellation cookie") }
            self.library = library; self.handle = handle
            abortCookie = abort; dropCookie = drop; cookieStatus = status
        } catch { dlclose(library); throw error }
    }
    func cancel() { abortCookie(handle) }
    var isCancelled: Bool { cookieStatus(handle) != 0 }
    deinit { dropCookie(handle); dlclose(library) }
}

// A NativeFile is confined to one decoder owner. The Pages actor serializes
// layout, rendering and PDF output on its context.
final class NativeFile {
    typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias OpenClassified = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>, Int32) -> UnsafeMutableRawPointer?
    typealias Close = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Count = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias Render = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias PageJSON = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?

    let library: UnsafeMutableRawPointer
    let document: UnsafeMutableRawPointer
    private let initialCount: Int
    private let lazyChapters: Bool
    private(set) var chapterTable: ChapterTable?
    var layoutChanged: ((ChapterTable) -> Void)?
    var count: Int { chapterTable?.totalPages ?? initialCount }
    let engine: NativeEngine
    let fixedLayoutEPUB: Bool
    private let closeDocument: Close
    private let render: Render?
    private var wordCache: (PageLocation, [RasterWord])?
    private var resolvedDestinations = [String: (location: PageLocation, x: Double?, y: Double?)]()
    private var imageColorSpace: CGColorSpace?
    private let authenticationPassword: String
    private let pdfSource: PDFSource?
    private let sourceRevision: String
    private var htmlStyleSignature = ""

    struct FileVersion: Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds: Int
        var contentMetadataSignature: String {
            "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)"
        }
        var signature: String {
            "\(contentMetadataSignature):\(changedSeconds):\(changedNanoseconds)"
        }
        init?(_ url: URL) {
            var value = stat()
            guard stat(url.path, &value) == 0 else { return nil }
            self.init(value)
        }
        init?(descriptor: Int32) {
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { return nil }
            self.init(value)
        }
        private init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
        func matchesContentMetadata(_ other: Self) -> Bool {
            device == other.device && inode == other.inode && size == other.size &&
                modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    struct FileCheckpoint {
        let version: FileVersion
        let digest: SHA256.Digest
        init?(_ url: URL) throws {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard let version = FileVersion(descriptor: file.fileDescriptor), FileVersion(url) == version else { return nil }
            let digest = try Self.digest(file)
            guard FileVersion(url) == version else { return nil }
            self.version = version; self.digest = digest
        }
        init(version: FileVersion, digest: SHA256.Digest) {
            self.version = version; self.digest = digest
        }
        func matches(_ url: URL) throws -> Bool {
            guard let current = FileVersion(url) else { return false }
            if current == version { return true }
            guard version.matchesContentMetadata(current) else { return false }
            // Opening/recording a recent file can change metadata without changing
            // PDF bytes. A digest also detects equal-length writes restoring mtime.
            let digest = try Self.digest(url)
            return digest == self.digest && FileVersion(url) == current
        }
        private static func digest(_ url: URL) throws -> SHA256.Digest {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            return try digest(file)
        }
        private static func digest(_ file: FileHandle) throws -> SHA256.Digest {
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize()
        }
    }

    // MuPDF reads streams lazily. Retaining an fd protects against replacement,
    // but only a private snapshot protects unread pages against in-place writes.
    // Reopened print documents share this owner until their final decoder closes.
    final class PDFSource {
        let temporary: TemporaryDirectory
        let url: URL
        let checkpoint: FileCheckpoint

        init(_ source: URL, expected: FileCheckpoint) throws {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            guard FileVersion(descriptor: file.fileDescriptor) == expected.version else {
                throw ReadError("The PDF file changed while opening. Open it again.")
            }
            var attributes = stat()
            guard fstat(file.fileDescriptor, &attributes) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let lockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
            let temporary = try TemporaryDirectory()
            guard chmod(temporary.url.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let snapshot = temporary.url.appendingPathComponent("input.pdf")
            var needsCopy = attributes.st_flags & lockingFlags != 0
            if !needsCopy {
                let cloned = snapshot.path.withCString {
                    fclonefileat(file.fileDescriptor, AT_FDCWD, $0, UInt32(CLONE_NOOWNERCOPY))
                }
                if cloned != 0 {
                    let failure = errno
                    guard failure == EXDEV || failure == ENOTSUP else {
                        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
                    }
                    needsCopy = true
                } else {
                    // If the source became locked during cloning, clear only
                    // the private copy's locking flags so failure cleanup works.
                    var clonedAttributes = stat()
                    guard stat(snapshot.path, &clonedAttributes) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if clonedAttributes.st_flags & lockingFlags != 0,
                       chflags(snapshot.path, clonedAttributes.st_flags & ~lockingFlags) != 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
            if needsCopy {
                // External volumes may not support cloning. Bound memory and
                // cancellation while copying from the same already-open inode.
                let descriptor = snapshot.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? output.close() }
                try file.seek(toOffset: 0)
                while let block = try file.read(upToCount: 1_048_576), !block.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: block)
                }
                try output.close()
            }
            try Task.checkCancellation()
            // A streaming copy can span concurrent source writes. Digest equality
            // with the pre-open checkpoint is required even when metadata agrees.
            guard FileVersion(descriptor: file.fileDescriptor) == expected.version,
                  let captured = try FileCheckpoint(snapshot), captured.digest == expected.digest else {
                throw ReadError("The PDF file changed while opening. Open it again.")
            }
            guard chmod(snapshot.path, 0o400) == 0, let version = FileVersion(snapshot) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            self.temporary = temporary; url = snapshot
            checkpoint = FileCheckpoint(version: version, digest: captured.digest)
        }
    }

    static func libraryURL(for engine: NativeEngine) throws -> URL {
        let directory = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.privateFrameworksURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/engines")
        guard let directory else { throw ReadError("Missing native engine directory") }
        return directory.appendingPathComponent(engine.rawValue + ".dylib")
    }
    convenience init(_ url: URL, engine: NativeEngine, password: String? = nil, deferReflowLayout: Bool = false, sourceCheckpoint: FileCheckpoint? = nil, deferMarkdownMetadata: Bool = false) throws {
        try self.init(url, engine: engine, password: password, deferReflowLayout: deferReflowLayout,
                      sourceCheckpoint: sourceCheckpoint, retainedPDFSource: nil, deferMarkdownMetadata: deferMarkdownMetadata)
    }

    private init(_ url: URL, engine: NativeEngine, password: String?, deferReflowLayout: Bool,
                 sourceCheckpoint: FileCheckpoint?, retainedPDFSource: PDFSource?, deferMarkdownMetadata: Bool = false) throws {
        authenticationPassword = password ?? ""
        let version = sourceCheckpoint?.version ?? (engine == .mupdf ? FileVersion(url) : nil)
        sourceRevision = version?.signature ?? ""
        var pdfSource = retainedPDFSource
        if engine == .mupdf, pdfSource == nil, let sourceCheckpoint {
            pdfSource = try PDFSource(url, expected: sourceCheckpoint)
        }
        let path = try Self.libraryURL(for: engine)
        guard let library = dlopen(path.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load \(engine.rawValue): \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
        }
        do {
            func required<T>(_ name: String, _: T.Type) throws -> T {
                guard let pointer = dlsym(library, name) else { throw ReadError("Incompatible \(engine.rawValue) engine: \(name)") }
                return unsafeBitCast(pointer, to: T.self)
            }
            let close = try required("lf_close", Close.self)
            let pageCount = try required("lf_count", Count.self)
            let isReflowable: Count? = deferReflowLayout && engine == .mupdf ? try required("lf_reflowable", Count.self) : nil
            var error = [CChar](repeating: 0, count: 512)
            if engine == .mupdf, pdfSource == nil {
                typealias Recognize = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
                let recognize = try required("lf_pdf_source", Recognize.self)
                let result = recognize(url.path, &error)
                guard result >= 0 else { throw Self.failure(error, "Cannot recognize this file") }
                if result == 1 {
                    guard let captured = try FileCheckpoint(url), captured.version == version else {
                        throw ReadError("The PDF file changed while opening. Open it again.")
                    }
                    pdfSource = try PDFSource(url, expected: captured)
                }
            }
            var opened: UnsafeMutableRawPointer?
            var installed = false
            defer { if !installed, let opened { close(opened) } }
            if engine == .mupdf {
                let opener = deferReflowLayout && deferMarkdownMetadata ? "lf_open_classified_deferred" : "lf_open_classified"
                let open = try required(opener, OpenClassified.self)
                func openPDFInput(_ input: URL) throws -> UnsafeMutableRawPointer? {
                    var needsPassword: Int32 = 0
                    let value = input.path.withCString { path in
                        if let password { return password.withCString { open(path, $0, &needsPassword, &error, pdfSource == nil ? 0 : 1) } }
                        return open(path, nil, &needsPassword, &error, pdfSource == nil ? 0 : 1)
                    }
                    if needsPassword != 0 { throw PasswordRequired(String(cString: error)) }
                    return value
                }
                opened = try openPDFInput(pdfSource?.url ?? url)
            } else {
                let open = try required("lf_open", Open.self)
                opened = open(url.path, &error)
            }
            guard let document = opened else { throw Self.failure(error, "Cannot decode this file") }
            typealias CheckedCount = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> Int32
            let count: Int
            // Counting a reflowable document may lay out every chapter. The
            // reader supplies its typography before the first count; other
            // callers keep the eager open and count path.
            let deferred = (isReflowable?(document) ?? 0) != 0
            if deferred { count = 0 }
            else if let pointer = dlsym(library, "lf_count_error") { count = Int(unsafeBitCast(pointer, to: CheckedCount.self)(document, &error)) }
            else { count = Int(pageCount(document)) }
            guard deferred || count > 0 else { throw Self.failure(error, "Document has no readable content") }
            var table: ChapterTable?
            if engine == .mupdf, !deferred {
                let chapters = try required("lf_chapters", CheckedCount.self)
                typealias CountChapter = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<CChar>) -> Int32
                let chapterPages = try required("lf_chapter_pages", CountChapter.self)
                let n = Int(chapters(document, &error))
                guard n > 0 else { throw Self.failure(error, "Cannot read chapters") }
                var value = ChapterTable(chapters: n)
                for chapter in 0..<n {
                    let pages = Int(chapterPages(document, Int32(chapter), &error))
                    guard pages >= 0 else { throw Self.failure(error, "Cannot count chapter pages") }
                    value.setPageCount(chapter: chapter, count: pages)
                }
                table = value
            }
            var fixedLayoutEPUB = false
            if engine == .mupdf, !(deferred && deferMarkdownMetadata) {
                typealias Metadata = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
                let metadata = try required("lf_metadata", Metadata.self)
                let values = try Self.decode(metadata(document, &error), error: error, as: [String: String].self)
                fixedLayoutEPUB = values["EPUBLayout"] == "fixed"
            }
            self.library = library; self.document = document; initialCount = count; self.engine = engine; closeDocument = close
            self.fixedLayoutEPUB = fixedLayoutEPUB
            lazyChapters = deferred; chapterTable = table
            render = dlsym(library, "lf_render").map { unsafeBitCast($0, to: Render.self) }
            self.pdfSource = pdfSource
            installed = true
        } catch { dlclose(library); throw error }
    }
    deinit { closeDocument(document); dlclose(library) }

    func validatePDFSource() throws {
        guard let pdfSource else { throw ReadError("The PDF source cannot be verified. Reload it before saving, exporting or printing.") }
        let sourceCheckpoint = pdfSource.checkpoint, original = sourceCheckpoint.version
        if let current = FileVersion(pdfSource.url), original.device == current.device, original.inode == current.inode {
            guard original.matchesContentMetadata(current), try sourceCheckpoint.matches(pdfSource.url) else {
                throw ReadError("The PDF source was modified outside Sumra. Reload it before saving, exporting or printing.")
            }
            return
        }
        // The path can change while another process still writes the original
        // inode. Recovery requires the actual MuPDF stream to retain its bytes.
        typealias Cancelled = @convention(c) () -> Int32
        typealias Digest = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>, Cancelled, UnsafeMutablePointer<CChar>) -> Int32
        guard let digest = symbol("lf_pdf_live_source_digest", Digest.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_source_digest") }
        var bytes = [UInt8](repeating: 0, count: 32), error = [CChar](repeating: 0, count: 512)
        let cancelled: Cancelled = { Task<Never, Never>.isCancelled ? 1 : 0 }
        let result = digest(document, &bytes, cancelled, &error)
        if result < 0 { throw CancellationError() }
        guard result > 0 else { throw Self.failure(error, "Cannot verify the retained PDF source") }
        try Task.checkCancellation()
        guard bytes.elementsEqual(sourceCheckpoint.digest) else {
            throw ReadError("The retained PDF source was modified outside Sumra. Reload it before saving, exporting or printing.")
        }
    }

    // EngineMupdf::Clone opens an independent decoder of the original PDF bytes.
    // Its lifetime shares the immutable input, independent of the original path.
    func reopenPDF(password: String, info: PDFDocumentInfo) throws -> NativeFile? {
        // A saved journal can be clean while differing from its initial input.
        guard !info.dirty, info.undoPosition == 0, engine == .mupdf, let pdfSource else { return nil }
        try validatePDFSource()
        return try NativeFile(pdfSource.url, engine: .mupdf, password: password, deferReflowLayout: false,
                              sourceCheckpoint: nil, retainedPDFSource: pdfSource)
    }

    var hasChapters: Bool { (chapterTable?.chapterCount ?? 1) > 1 }
    private func chapterCount() throws -> Int {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> Int32
        guard let fn = symbol("lf_chapters", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_chapters") }
        var error = [CChar](repeating: 0, count: 512)
        let value = Int(fn(document, &error))
        guard value > 0 else { throw Self.failure(error, "Cannot read chapters") }
        return value
    }
    /// WarmChapter does not publish flat page numbers while the UI uses them.
    @discardableResult func warmChapter(_ chapter: Int) throws -> Int {
        try Task.checkCancellation()
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<CChar>) -> Int32
        guard let fn = symbol("lf_chapter_pages", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_chapter_pages") }
        var error = [CChar](repeating: 0, count: 512)
        let count = Int(fn(document, Int32(chapter), &error))
        guard count >= 0 else { throw Self.failure(error, "Cannot count chapter pages") }
        return max(1, count)
    }
    func ensureChapter(_ chapter: Int) throws {
        guard var table = chapterTable, !table.isLaidOut(chapter) else { return }
        guard chapter >= 0, chapter < table.chapterCount else { throw ReadError("Chapter out of range") }
        table.setPageCount(chapter: chapter, count: try warmChapter(chapter))
        chapterTable = table
        layoutChanged?(table)
    }
    func publishWarmedChapters() throws {
        guard var table = chapterTable, !table.complete else { return }
        for chapter in 0..<table.chapterCount where !table.isLaidOut(chapter) {
            table.setPageCount(chapter: chapter, count: try warmChapter(chapter))
        }
        chapterTable = table
        layoutChanged?(table)
    }
    func location(_ page: Int) throws -> PageLocation {
        if let table = chapterTable {
            guard let location = table.location(page: page) else { throw ReadError("Page out of range") }
            return location
        }
        guard (0..<count).contains(page) else { throw ReadError("Page out of range") }
        return .init(page: page)
    }
    func page(_ location: PageLocation) throws -> Int {
        guard chapterTable != nil else { return location.page }
        try ensureChapter(location.chapter)
        guard let page = chapterTable?.page(for: location) else { throw ReadError("Page out of range") }
        return page
    }
    // PagePosition.cpp::LocationFromFlatPageNo: migrate an old saved flat
    // page by counting only the preceding chapters needed to identify it.
    func locationFromFlatPage(_ page: Int) throws -> PageLocation {
        guard let table = chapterTable else { return .init(page: page) }
        var remaining = max(0, page)
        for chapter in 0..<table.chapterCount {
            try ensureChapter(chapter)
            let count = chapterTable!.pageCount(chapter)
            if remaining < count { return .init(chapter: chapter, page: remaining) }
            remaining -= count
        }
        let last = table.chapterCount - 1
        return .init(chapter: last, page: chapterTable!.pageCount(last) - 1)
    }
    private func preparedLocation(_ page: Int) throws -> PageLocation {
        let location = try location(page)
        try ensureChapter(location.chapter)
        return location
    }
    func symbol<T>(_ name: String, _: T.Type) -> T? {
        dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
    }
    static func failure(_ error: [CChar], _ fallback: String) -> ReadError {
        let message = String(cString: error)
        return ReadError(message.isEmpty ? fallback : message)
    }
    func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, error: [CChar], as: T.Type) throws -> T {
        try Self.decode(pointer, error: error, as: T.self)
    }
    private static func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, error: [CChar], as: T.Type) throws -> T {
        guard let pointer else { throw Self.failure(error, "Cannot read document information") }
        defer { free(pointer) }
        return try JSONDecoder().decode(T.self, from: Data(bytes: pointer, count: strlen(pointer)))
    }
    func invalidatePDFCaches() {
        wordCache = nil
        resolvedDestinations.removeAll()
    }
    private func pageJSON<T: Decodable>(_ symbolName: String, page: Int, as: T.Type) throws -> T? {
        var error = [CChar](repeating: 0, count: 512)
        if engine == .mupdf {
            typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
            guard let fn = symbol(symbolName + "_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: " + symbolName + "_at") }
            let location = try preparedLocation(page)
            return try decode(fn(document, Int32(location.chapter), Int32(location.page), &error), error: error, as: T.self)
        }
        guard let fn = symbol(symbolName, PageJSON.self) else { return nil }
        return try decode(fn(document, Int32(page), &error), error: error, as: T.self)
    }

    func image(_ page: Int, width: Int, transparent: Bool = false, region: CGRect? = nil,
               style: PDFColors.Style? = nil, cancellation: NativeRenderCancellation? = nil) throws -> CGImage {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard let nativeWidth = Int32(exactly: width) else { throw ReadError("Page bitmap width cannot be represented by the native engine") }
        let space = try colorSpace()
        var info = [Int32](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
        var tile: [Int32]?
        if let region {
            let values = [region.minX, region.minY, region.width, region.height]
            guard width > 0,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= CGFloat(Int32.max) && $0.rounded() == $0 }),
                  region.width > 0, region.height > 0 else { throw ReadError("Invalid render region") }
            tile = values.map { Int32($0) }
        }
        let output: UnsafeMutableRawPointer?
        if engine == .mupdf {
            typealias RenderAt = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Int32>?, Int32,
                UnsafePointer<Int32>?, UnsafePointer<UInt32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
            guard let fn = symbol("lf_render_cancelable_at", RenderAt.self) else { throw ReadError("Incompatible MuPDF engine: lf_render_cancelable_at") }
            let location = try preparedLocation(page)
            func run(_ region: UnsafePointer<Int32>?) -> UnsafeMutableRawPointer? {
                if let style, style.isActive {
                    return fn(document, Int32(location.chapter), Int32(location.page), nativeWidth, region,
                              transparent || style.transparent ? 1 : 0, style.nativeValues, style.nativeColors,
                              cancellation?.handle, &info, &error)
                }
                return fn(document, Int32(location.chapter), Int32(location.page), nativeWidth, region, transparent ? 1 : 0,
                          nil, nil, cancellation?.handle, &info, &error)
            }
            if let tile { output = tile.withUnsafeBufferPointer { run($0.baseAddress) } }
            else { output = run(nil) }
        } else if let tile {
            typealias RenderTile = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Int32>, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
            guard let fn = symbol("lf_render_tile_at", RenderTile.self) else { throw ReadError("This engine cannot render page regions") }
            output = tile.withUnsafeBufferPointer {
                fn(document, 0, Int32(page), nativeWidth, $0.baseAddress!, transparent ? 1 : 0, &info, &error)
            }
        } else {
            guard let render else { throw ReadError("This engine cannot render the requested page image") }
            output = render(document, Int32(page), nativeWidth, &info, &error)
        }
        // DjVuLibre and bitmap codecs do not expose this abort mechanism.
        // Their completed stale buffers are still released before CGImage/cache.
        if Task.isCancelled || cancellation?.isCancelled == true {
            free(output); throw CancellationError()
        }
        guard let pointer = output else { throw Self.failure(error, "Cannot render page") }
        let width = Int(info[0]), height = Int(info[1]), sourceStride = Int(info[2]), sourceChannels = Int(info[3])
        var stride = sourceStride, channels = sourceChannels
        guard width > 0, height > 0, (channels == 3 || channels == 4), width <= Int.max / channels,
              stride >= width * channels, height <= Int.max / stride else {
            free(pointer); throw ReadError("Invalid native page bitmap")
        }
        if space.numberOfComponents == 1 {
            // libjxl expands gray into RGB channels. Pack its matching gray
            // profile and optional alpha in place without a second bitmap.
            channels = sourceChannels == 4 ? 2 : 1
            stride = width * channels
            let bytes = pointer.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let source = y * sourceStride + x * sourceChannels, target = y * stride + x * channels
                    let gray = bytes[source], alpha = sourceChannels == 4 ? bytes[source + 3] : 255
                    bytes[target] = gray
                    if channels == 2 { bytes[target + 1] = alpha }
                }
            }
        }
        let data = Data(bytesNoCopy: pointer, count: stride * height, deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: channels * 8, bytesPerRow: stride,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: (channels == 4 || channels == 2 ? (engine == .mupdf ? CGImageAlphaInfo.premultipliedLast : .last) : .none).rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { throw ReadError("Cannot create page image") }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        return image
    }
    private func colorSpace() throws -> CGColorSpace {
        if let imageColorSpace { return imageColorSpace }
        typealias Profile = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let fn = symbol("lf_color_profile", Profile.self) {
            var size = 0, error = [CChar](repeating: 0, count: 512)
            if let profile = fn(document, &size, &error) {
                defer { free(profile) }
                guard size > 0,
                      let decoded = CGColorSpace(iccData: Data(bytes: profile, count: size) as CFData),
                      decoded.numberOfComponents == 1 || decoded.numberOfComponents == 3 else {
                    throw Self.failure(error, "Invalid native image color profile")
                }
                space = decoded
            } else if error.first != 0 { throw Self.failure(error, "Cannot read native image color profile") }
        }
        imageColorSpace = space
        return space
    }
    var hasText: Bool { dlsym(library, engine == .mupdf ? "lf_text_at" : "lf_text") != nil }
    var reflowable: Bool { symbol("lf_reflowable", Count.self).map { $0(document) != 0 } ?? false }
    var hasSelection: Bool { dlsym(library, engine == .mupdf ? "lf_select_at" : "lf_words") != nil }

    func exportPDF(to destination: URL, selectedPages: [Int]? = nil) throws -> Bool {
        try Task.checkCancellation()
        guard engine == .mupdf || engine == .djvu else { return false }
        let pdf = try pdfInfo()
        if let pdf {
            try validatePDFSource()
            guard pdf.permissions.copy else { throw ReadError("This PDF does not allow content extraction") }
            // Loading pages can synthesize appearances or recalculate forms.
            // Export from an independent owner, just as native PDF printing
            // does; output work must not change the reader's undo entries.
            var temporary: TemporaryDirectory?
            defer { withExtendedLifetime(temporary) {} }
            let copy: NativeFile
            if let reopened = try reopenPDF(password: authenticationPassword, info: pdf) {
                copy = reopened
            } else {
                let directory = try TemporaryDirectory(); temporary = directory
                let snapshot = directory.url.appendingPathComponent("Export.pdf")
                try pdfWrite(to: snapshot)
                copy = try NativeFile(snapshot, engine: .mupdf, password: authenticationPassword)
            }
            let result = try copy.writePDFExport(to: destination, selectedPages: selectedPages)
            try validatePDFSource()
            return result
        }
        return try writePDFExport(to: destination, selectedPages: selectedPages)
    }

    private func writePDFExport(to destination: URL, selectedPages: [Int]?) throws -> Bool {
        typealias Cancelled = @convention(c) () -> Int32
        typealias Export = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<Int32>?, Int32, Cancelled, UnsafeMutablePointer<CChar>) -> Int32
        guard let fn = symbol("lf_export_pdf", Export.self) else { throw ReadError("Incompatible \(engine.rawValue) engine: lf_export_pdf") }
        let selected: [Int32]? = try selectedPages.map { pages in
            guard !pages.isEmpty, pages.count <= Int(Int32.max) else { throw ReadError("Choose pages to export") }
            return try pages.map { page in
                guard let index = Int32(exactly: page) else { throw ReadError("Page out of range") }
                return index
            }
        }
        var error = [CChar](repeating: 0, count: 512)
        let cancelled: Cancelled = { Task<Never, Never>.isCancelled ? 1 : 0 }
        let result = destination.path.withCString { path in
            if let selected { return selected.withUnsafeBufferPointer { fn(document, path, $0.baseAddress, Int32($0.count), cancelled, &error) } }
            return fn(document, path, nil, 0, cancelled, &error)
        }
        if result < 0 { throw CancellationError() }
        guard result != 0 else { throw Self.failure(error, "Cannot export PDF") }
        return true
    }

    @discardableResult
    func printPDF(to destination: URL, selectedPages: [Int]? = nil, regions: [[CGRect]]? = nil,
                  rotation: Int = 0, cancellation: NativeRenderCancellation? = nil) throws -> [CGRect] {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard engine == .mupdf, rotation % 90 == 0 else { throw ReadError("Invalid PDF print request") }
        let pages: [Int32]? = try selectedPages.map { pages in
            guard !pages.isEmpty, pages.count <= Int(Int32.max), pages.allSatisfy({ (0..<count).contains($0) }) else {
                throw ReadError("Choose valid pages to print")
            }
            return pages.map(Int32.init)
        }
        let rectangles: [Float]? = try regions.map { regions in
            guard let pages, regions.count == pages.count,
                  regions.allSatisfy({ !$0.isEmpty && $0.count <= Int(Int32.max) && $0.allSatisfy {
                      !$0.isEmpty && !$0.isNull && [$0.minX, $0.minY, $0.width, $0.height].allSatisfy { $0.isFinite && abs($0) <= CGFloat(Float.greatestFiniteMagnitude) }
                  } }) else {
                throw ReadError("Invalid PDF print selection")
            }
            return regions.flatMap { $0.flatMap { [$0.minX, $0.minY, $0.width, $0.height].map(Float.init) } }
        }
        typealias Print = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<Int32>?, Int32,
            UnsafePointer<Float>?, UnsafePointer<Int32>?, Int32, UnsafeMutablePointer<Float>, Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> Int32
        guard let print = symbol("lf_print_pdf", Print.self) else { throw ReadError("Incompatible MuPDF engine: lf_print_pdf") }
        var error = [CChar](repeating: 0, count: 512)
        let outputCount = pages?.count ?? count
        var contentBounds = [Float](repeating: 0, count: outputCount * 4)
        let result = (pages ?? []).withUnsafeBufferPointer { pages in
            (rectangles ?? []).withUnsafeBufferPointer { rectangles in
                (regions?.map { Int32($0.count) } ?? []).withUnsafeBufferPointer { counts in
                    print(document, destination.path, selectedPages == nil ? nil : pages.baseAddress, Int32(pages.count),
                          regions == nil ? nil : rectangles.baseAddress, counts.baseAddress,
                          Int32(rotation % 360), &contentBounds, Int32(outputCount), cancellation?.handle, &error)
                }
            }
        }
        if result < 0 || Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
        guard result != 0 else { throw Self.failure(error, "Cannot prepare PDF for printing") }
        return stride(from: 0, to: contentBounds.count, by: 4).map {
            CGRect(x: CGFloat(contentBounds[$0]), y: CGFloat(contentBounds[$0+1]),
                   width: CGFloat(contentBounds[$0+2]), height: CGFloat(contentBounds[$0+3]))
        }
    }

    static func exportImages(to destination: URL, count: Int, image: (Int) throws -> (Data, CGSize)) throws {
        typealias Begin = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        typealias Add = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt8>, Int, Float, Float, UnsafeMutablePointer<CChar>) -> Int32
        typealias End = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<CChar>) -> Int32
        let path = try libraryURL(for: .mupdf)
        guard let library = dlopen(path.path, RTLD_LOCAL | RTLD_NOW) else { throw ReadError("Cannot load MuPDF: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")") }
        defer { dlclose(library) }
        guard let beginSymbol = dlsym(library, "lf_image_pdf_begin"), let addSymbol = dlsym(library, "lf_image_pdf_add"),
              let endSymbol = dlsym(library, "lf_image_pdf_end") else { throw ReadError("Incompatible MuPDF engine: image PDF writer") }
        let begin = unsafeBitCast(beginSymbol, to: Begin.self), add = unsafeBitCast(addSymbol, to: Add.self), end = unsafeBitCast(endSymbol, to: End.self)
        var error = [CChar](repeating: 0, count: 512), closed = false
        guard let writer = destination.path.withCString({ begin($0, &error) }) else { throw failure(error, "Cannot create image PDF") }
        defer { if !closed { _ = end(writer, 0, &error) } }
        for page in 0..<count {
            try Task.checkCancellation()
            let (data, size) = try image(page)
            guard !data.isEmpty else { throw ReadError("Empty image") }
            let result = data.withUnsafeBytes { bytes in
                add(writer, bytes.bindMemory(to: UInt8.self).baseAddress!, data.count, Float(size.width), Float(size.height), &error)
            }
            guard result != 0 else { throw failure(error, "Cannot add image to PDF") }
        }
        try Task.checkCancellation()
        let result = end(writer, 1, &error); closed = true
        guard result != 0 else { throw failure(error, "Cannot save image PDF") }
    }

    func bounds(_ page: Int) throws -> CGRect? {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
        var values = [Float](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
        let result: Int32
        if engine == .mupdf {
            typealias GetAt = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
            guard let fn = symbol("lf_bounds_at", GetAt.self) else { throw ReadError("Incompatible MuPDF engine: lf_bounds_at") }
            let location = try preparedLocation(page)
            result = fn(document, Int32(location.chapter), Int32(location.page), &values, &error)
        } else {
            guard let fn = symbol("lf_bounds", Get.self) else { return nil }
            result = fn(document, Int32(page), &values, &error)
        }
        guard result != 0 else { throw Self.failure(error, "Cannot read page size") }
        guard values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { throw ReadError("Invalid page dimensions") }
        return CGRect(raster: values.map(Double.init))
    }
    func contentBounds(_ page: Int, cancellation: NativeRenderCancellation? = nil) throws -> CGRect? {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard engine == .mupdf else { return nil }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Float>, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> Int32
        guard let fn = symbol("lf_content_bounds_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_content_bounds") }
        let location = try preparedLocation(page)
        var values = [Float](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
        let result = fn(document, Int32(location.chapter), Int32(location.page), &values, cancellation?.handle, &error)
        if Task.isCancelled || cancellation?.isCancelled == true { throw CancellationError() }
        guard result != 0 else { throw Self.failure(error, "Cannot measure page content") }
        guard values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { throw ReadError("Invalid page content dimensions") }
        return CGRect(raster: values.map(Double.init))
    }
    func outline() throws -> [ContentsItem] {
        struct Entry: Decodable {
            let contents: ContentsItem
            let x: Double?, y: Double?
            enum CodingKeys: String, CodingKey { case x, y }
            init(from decoder: Decoder) throws {
                contents = try ContentsItem(from: decoder)
                let coordinates = try decoder.container(keyedBy: CodingKeys.self)
                x = try coordinates.decodeIfPresent(Double.self, forKey: .x)
                y = try coordinates.decodeIfPresent(Double.self, forKey: .y)
            }
        }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let fn = symbol("lf_outline", Get.self) else { return [] }
        var error = [CChar](repeating: 0, count: 512)
        let entries = try decode(fn(document, &error), error: error, as: [Entry].self)
        if engine == .mupdf {
            for entry in entries {
                if let page = entry.contents.page, !entry.contents.target.isEmpty {
                    resolvedDestinations[entry.contents.target] = (.init(chapter: entry.contents.chapter ?? 0, page: page), entry.x, entry.y)
                }
            }
        }
        return entries.map(\.contents)
    }
    func imageDimensions(_ page: Int) throws -> CGSize? {
        if engine == .jpegXL { return try bounds(page)?.size }
        guard engine == .mupdf else { return nil }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> Int32
        guard let fn = symbol("lf_image_dimensions_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_image_dimensions") }
        let location = try preparedLocation(page)
        var size = [Int32](repeating: 0, count: 2), error = [CChar](repeating: 0, count: 512)
        let result = fn(document, Int32(location.chapter), Int32(location.page), &size, &error)
        guard result >= 0 else { throw Self.failure(error, "Cannot read image dimensions") }
        return result == 0 ? nil : CGSize(width: Int(size[0]), height: Int(size[1]))
    }
    func metadata() throws -> [String: String] {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let fn = symbol("lf_metadata", Get.self) else { return [:] }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(fn(document, &error), error: error, as: [String: String].self)
    }
    func htmlSource() throws -> String? {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard engine == .mupdf else { return nil }
        guard let fn = symbol("lf_html_source", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_html_source") }
        var error = [CChar](repeating: 0, count: 512)
        guard let pointer = fn(document, &error) else {
            if error.first != 0 { throw Self.failure(error, "Cannot read generated HTML") }
            return nil
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    func links(_ page: Int) throws -> [RasterLink] { try pageJSON("lf_links", page: page, as: [RasterLink].self) ?? [] }
    func imageBounds(_ page: Int) throws -> [CGRect] {
        guard engine == .mupdf else { return [] }
        return try (pageJSON("lf_image_bounds", page: page, as: [[Double]].self) ?? []).map(CGRect.init(raster:))
    }
    // Complete original JPEG/PNG/etc. bytes when possible; transformed images
    // are PNG. The output owner uses ImageIO to retain the actual media type.
    func embeddedImage(_ page: Int, at point: CGPoint) throws -> Data? {
        guard engine == .mupdf else { return nil }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Float, Float, UnsafeMutablePointer<Int>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        guard let fn = symbol("lf_image_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_image_at") }
        let location = try preparedLocation(page)
        var size = 0, error = [CChar](repeating: 0, count: 512)
        guard let pointer = fn(document, Int32(location.chapter), Int32(location.page), Float(point.x), Float(point.y), &size, &error) else {
            if error.first != 0 { throw Self.failure(error, "Cannot read embedded image") }
            return nil
        }
        return Data(bytesNoCopy: pointer, count: size, deallocator: .free)
    }

    func relayout(fontSize: Double, lineHeight: Double, font: String, theme: String, userCSS: String = "", useDocumentCSS: Bool = true, pageMargins: PageMargins? = nil) throws -> Int? {
        typealias Layout = @convention(c) (UnsafeMutableRawPointer, Float, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<CChar>) -> Int32
        guard reflowable else { return nil }
        guard let fn = symbol("lf_relayout_css", Layout.self) else { throw ReadError("Incompatible MuPDF engine: lf_relayout_css") }
        // Translate Sumatra's EbookGeneratedCssTemp: only explicit margins
        // override the publisher's @page rule; code keeps its monospace family.
        let elements = "body,p,div,span,a,em,strong,b,i,u,s,small,big,sub,sup,li,ol,ul,dl,dt,dd,td,th,caption,table,h1,h2,h3,h4,h5,h6,blockquote,q,cite,section,article,aside,header,footer,nav,main,figure,figcaption,label,center,font"
        let familyName = ["serif", "monospace", "sans-serif"].contains(font) ? font : "\"" + font.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let family = font == "system" ? "" : "\(elements){font-family:\(familyName) !important;}\n"
        let colors = theme == "dark" ? "*{color:#ddd !important;background-color:transparent !important;} html,body{background-color:#111 !important;color:#ddd !important;} a,a *{color:#8ab4f8 !important;}" : ""
        let margins = pageMargins.map { "@page{margin:\($0.css) !important;}\n" } ?? ""
        let css = margins + "body,body *{line-height:\(lineHeight) !important;}\n" + family + colors + "\n" + userCSS
        var error = [CChar](repeating: 0, count: 512)
        let count = css.withCString { fn(document, Float(fontSize), $0, useDocumentCSS ? 1 : 0, &error) }
        guard count > 0 else { throw Self.failure(error, "Cannot lay out this document") }
        // Reader font, line-height, theme colors and page margins change geometry,
        // not the parsed text identity. User/publisher CSS can change visible
        // flow nodes, so only that boundary invalidates a source passage.
        htmlStyleSignature = SHA256.hash(data: Data((userCSS + "\n" + String(useDocumentCSS)).utf8)).map { String(format: "%02x", $0) }.joined()
        wordCache = nil
        resolvedDestinations.removeAll()
        let n = try chapterCount()
        if chapterTable?.chapterCount == n { chapterTable?.reset() }
        else { chapterTable = ChapterTable(chapters: n) }
        if !lazyChapters || n == 1 { try publishWarmedChapters() }
        else if let chapterTable { layoutChanged?(chapterTable) }
        return self.count
    }
    func text(_ page: Int) throws -> String? {
        if engine == .djvu { return try words(page).map(\.text).joined() }
        var error = [CChar](repeating: 0, count: 512)
        let result: UnsafeMutablePointer<CChar>?
        if engine == .mupdf {
            typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
            guard let fn = symbol("lf_text_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_text_at") }
            let location = try preparedLocation(page)
            result = fn(document, Int32(location.chapter), Int32(location.page), &error)
        } else {
            guard let fn = symbol("lf_text", PageJSON.self) else { return nil }
            result = fn(document, Int32(page), &error)
        }
        guard let pointer = result else { throw Self.failure(error, "Cannot extract text") }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    func words(_ page: Int) throws -> [RasterWord] {
        let location = try preparedLocation(page)
        if let cached = wordCache, cached.0 == location { return cached.1 }
        let words = try pageJSON("lf_words", page: page, as: [RasterWord].self) ?? []
        wordCache = (location, words)
        return words
    }
    func selection(_ page: Int, range: NSRange) throws -> RasterSelection {
        try RasterSelection.select(words(page), range: range)
    }
    func matches(_ query: String, page: Int, options: TextSearchOptions = .init(), after: Int? = nil,
                 backwards: Bool = false, maximum: Int? = nil) throws -> [RasterMatch] {
        try Task.checkCancellation()
        guard !query.isEmpty else { return [] }
        if let maximum, maximum <= 0 { return [] }
        if backwards, let after, after <= 0 { return [] }
        if engine == .mupdf {
            typealias Cancelled = @convention(c) () -> Int32
            typealias Search = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<CChar>, Int32, Int64, Int64, Cancelled, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
            guard let fn = symbol("lf_search_options_at", Search.self) else { throw ReadError("Incompatible MuPDF engine: lf_search_options") }
            let location = try preparedLocation(page)
            var error = [CChar](repeating: 0, count: 512)
            let flags: Int32 = (options.caseSensitive ? 1 : 0) | (options.wholeWord ? 2 : 0) | (backwards ? 4 : 0)
            let cancelled: Cancelled = { Task<Never, Never>.isCancelled ? 1 : 0 }
            let pointer = query.withCString {
                fn(document, Int32(location.chapter), Int32(location.page), $0, flags,
                   after.map { Int64(max(-1, $0)) } ?? -1, maximum.map { Int64($0) } ?? -1, cancelled, &error)
            }
            if Task.isCancelled { if let pointer { free(pointer) }; throw CancellationError() }
            struct Hit: Decodable { let start: Int; let length: Int; let rects: [[Double]] }
            struct Results: Decodable { let text: String; let matches: [Hit] }
            let result = try decode(pointer, error: error, as: Results.self), text = result.text as NSString
            return try result.matches.map { hit in
                try Task.checkCancellation()
                return RasterMatch(page: page, index: hit.start, rects: hit.rects.map { CGRect(raster: $0) },
                    context: TextSearchOptions.snippet(in: text, range: NSRange(location: hit.start, length: hit.length)))
            }
        }
        let words = try words(page)
        let string = words.map(\.text).joined(), text = string as NSString
        let hits = try options.ranges(in: string, query: query, after: after, backwards: backwards, maximum: maximum)
        var offsets = [(NSRange, CGRect)](), offset = 0
        for word in words {
            let length = (word.text as NSString).length
            offsets.append((NSRange(location: offset, length: length), word.bounds)); offset += length
        }
        var cursor = backwards ? offsets.count : 0
        return try hits.map { hit in
            try Task.checkCancellation()
            if backwards {
                while cursor > 0, NSMaxRange(offsets[cursor - 1].0) > hit.location { cursor -= 1 }
            } else {
                while cursor < offsets.count, NSMaxRange(offsets[cursor].0) <= hit.location { cursor += 1 }
            }
            var end = cursor
            while end < offsets.count, offsets[end].0.location < NSMaxRange(hit) { end += 1 }
            let rects: [CGRect] = offsets[cursor..<end].compactMap { range, box in
                let intersection = NSIntersectionRange(range, hit)
                guard intersection.length > 0, range.length > 0, !box.isEmpty else { return nil }
                // Port Sumatra CollectZonesUtf8's approximate per-glyph boxes.
                let start = CGFloat(intersection.location-range.location)/CGFloat(range.length)
                let length = CGFloat(intersection.length)/CGFloat(range.length)
                return CGRect(x: box.minX+box.width*start, y: box.minY, width: box.width*length, height: box.height)
            }
            return RasterMatch(page: page, index: hit.location, rects: rects, context: TextSearchOptions.snippet(in: text, range: hit))
        }
    }
    func markdownDocumentMatches(_ query: String, options: TextSearchOptions, startPage: Int,
                                 after: NativeSourceAnchor? = nil, backwards: Bool = false,
                                 counting: Bool = false, maximum: Int = 1, inclusive: Bool = false) throws -> [RasterMatch] {
        try Task.checkCancellation()
        guard engine == .mupdf, !query.isEmpty, maximum > 0 else { return [] }
        typealias Cancelled = @convention(c) () -> Int32
        typealias Search = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Int32, Int32,
            UInt32, UInt32, UInt32, Int64, UnsafePointer<UInt8>?, Int, Cancelled,
            UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let fn = symbol("lf_markdown_document_search", Search.self) else {
            throw ReadError("Incompatible MuPDF engine: lf_markdown_document_search")
        }
        let mask: [UInt8]? = options.allowedPages.map { allowed in
            var bits = [UInt8](repeating: 0, count: (count + 7) / 8)
            for range in allowed.rangeView {
                let lower = max(0, range.lowerBound), upper = min(count, range.upperBound)
                guard lower < upper else { continue }
                for page in lower..<upper {
                    bits[page / 8] |= 1 << UInt8(page & 7)
                }
            }
            return bits
        }
        var error = [CChar](repeating: 0, count: 512)
        let flags: Int32 = (options.caseSensitive ? 1 : 0) | (options.wholeWord ? 2 : 0) |
            (backwards ? 4 : 0) | (counting ? 8 : 0) | (inclusive ? 16 : 0)
        let cancelled: Cancelled = { Task<Never, Never>.isCancelled ? 1 : 0 }
        let pointer = query.withCString { needle in
            if let mask {
                return mask.withUnsafeBufferPointer { bits in
                    fn(document, needle, flags, Int32(startPage), after?.node ?? 0, after?.offset ?? 0,
                       after?.part ?? 0, Int64(maximum), bits.baseAddress, bits.count, cancelled, &error)
                }
            }
            return fn(document, needle, flags, Int32(startPage), after?.node ?? 0, after?.offset ?? 0,
                      after?.part ?? 0, Int64(maximum), nil, 0, cancelled, &error)
        }
        if Task.isCancelled { if let pointer { free(pointer) }; throw CancellationError() }
        struct Fragment: Decodable { let page, start, length: Int; let rects: [[Double]] }
        struct Hit: Decodable {
            let source: NativeSourceAnchor
            let page, index: Int
            let context: String
            let fragments: [Fragment]
        }
        struct Results: Decodable { let matches: [Hit] }
        let result = try decode(pointer, error: error, as: Results.self)
        return result.matches.compactMap { hit in
            guard hit.page >= 0, !hit.fragments.isEmpty else { return nil }
            let fragments = hit.fragments.map { fragment in
                RasterMatchFragment(page: fragment.page, start: fragment.start, length: fragment.length,
                                    rects: fragment.rects.map { CGRect(raster: $0) })
            }
            return RasterMatch(page: hit.page, index: hit.index, rects: fragments.first?.rects ?? [],
                               context: hit.context, source: hit.source, fragments: fragments)
        }
    }
    func selection(_ page: Int, from a: CGPoint, to b: CGPoint, mode: Int32 = 0,
                   cancellation: NativeRenderCancellation? = nil) throws -> RasterSelection {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        typealias Select = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Float, Float, Float, Float, Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        if engine == .mupdf, let fn = symbol("lf_select_at", Select.self) {
            let location = try preparedLocation(page)
            var error = [CChar](repeating: 0, count: 512)
            let pointer = fn(document, Int32(location.chapter), Int32(location.page), Float(a.x), Float(a.y), Float(b.x), Float(b.y), mode, cancellation?.handle, &error)
            if Task.isCancelled || cancellation?.isCancelled == true { free(pointer); throw CancellationError() }
            return try decode(pointer, error: error, as: RasterSelection.self)
        }
        // The DjVu decoder provides ordered word zones, as Sumatra's
        // CollectZonesUtf8 does; selection includes the intersected word range.
        let words = try words(page)
        if mode == 3 {
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x-b.x), height: abs(a.y-b.y))
            let selected = words.filter { $0.bounds.intersects(box) }
            return .init(text: selected.map(\.text).joined(), rects: [box.raster], words: selected)
        }
        let selectable = words.indices.filter { !words[$0].bounds.isEmpty }
        guard !selectable.isEmpty else { return RasterSelection(text: "", rects: []) }
        func nearest(_ p: CGPoint) -> Int {
            selectable.min {
                let x = words[$0].bounds, y = words[$1].bounds
                func distance(_ r: CGRect) -> CGFloat {
                    let dx = max(max(r.minX-p.x, 0), p.x-r.maxX), dy = max(max(r.minY-p.y, 0), p.y-r.maxY)
                    return dx*dx + dy*dy
                }
                return distance(x) < distance(y)
            } ?? 0
        }
        let first = nearest(a), last = nearest(b)
        var lower = min(first, last), upper = max(first, last)
        if mode == 2 {
            while lower > 0, words[lower-1].text != "\n" { lower -= 1 }
            while upper+1 < words.count, words[upper+1].text != "\n" { upper += 1 }
        }
        let selected = words[lower...upper]
        return RasterSelection(text: selected.map(\.text).joined(), rects: selected.filter { !$0.bounds.isEmpty }.map { $0.bounds.raster }, words: Array(selected))
    }
    func resolve(_ uri: String) throws -> ReadingPosition? {
        var point = [Float](repeating: .nan, count: 2), error = [CChar](repeating: 0, count: 512)
        if engine == .mupdf {
            // EngineMupdf::ResolveDest keeps chapter coordinates valid across
            // flat-page renumbering; only a new text layout invalidates them.
            if let destination = resolvedDestinations[uri] {
                let page = try page(destination.location)
                return ReadingPosition(page: page, x: destination.x, y: destination.y, anchor: chapterTable?.bookmark(destination.location))
            }
            typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
            guard let fn = symbol("lf_resolve_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_resolve_at") }
            var values = [Int32](repeating: 0, count: 2)
            let found = uri.withCString { fn(document, $0, &values, &point, &error) }
            guard found >= 0 else { throw Self.failure(error, "Cannot resolve document link") }
            guard found != 0 else { return nil }
            let location = PageLocation(chapter: Int(values[0]), page: Int(values[1]))
            let page = try page(location)
            let x = point[0].isFinite ? Double(point[0]) : nil, y = point[1].isFinite ? Double(point[1]) : nil
            resolvedDestinations[uri] = (location, x, y)
            return ReadingPosition(page: page, x: x, y: y, anchor: chapterTable?.bookmark(location))
        }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
        guard let fn = symbol("lf_resolve", Get.self) else { return nil }
        let page = uri.withCString { fn(document, $0, &point, &error) }
        guard page >= 0 else { throw Self.failure(error, "Cannot resolve document link") }
        return ReadingPosition(page: Int(page), x: point[0].isFinite ? Double(point[0]) : nil, y: point[1].isFinite ? Double(point[1]) : nil)
    }
    func passage(_ page: Int, at point: CGPoint) throws -> NativePassage? {
        guard engine == .mupdf, reflowable else { return nil }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Float, Float, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let fn = symbol("lf_html_page_anchor_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_html_page_anchor_at") }
        let location = try preparedLocation(page)
        var error = [CChar](repeating: 0, count: 512)
        struct Result: Decodable { let source: NativeSourceAnchor; let rect: [Double] }
        guard let value = try decode(fn(document, Int32(location.chapter), Int32(location.page), Float(point.x), Float(point.y), &error), error: error, as: Result?.self) else { return nil }
        let rect = CGRect(raster: value.rect)
        return NativePassage(source: value.source, offsetX: Double(point.x-rect.minX), offsetY: Double(point.y-rect.minY),
                             sourceRevision: sourceRevision, styleSignature: htmlStyleSignature)
    }
    func position(for passage: NativePassage) throws -> ReadingPosition? {
        guard engine == .mupdf, reflowable, !sourceRevision.isEmpty,
              passage.sourceRevision == sourceRevision, passage.styleSignature == htmlStyleSignature else { return nil }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, UInt32, UInt32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let fn = symbol("lf_html_anchor_position", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_html_anchor_position") }
        var error = [CChar](repeating: 0, count: 512)
        struct Result: Decodable { let page: Int; let rect: [Double]; let whitespace: Bool? }
        let anchor = passage.source
        guard let value = try decode(fn(document, 0, anchor.node, anchor.offset, anchor.part, &error), error: error, as: Result?.self) else { return nil }
        let rect = CGRect(raster: value.rect)
        let x = Double(rect.minX)+passage.offsetX, y = Double(rect.minY)+passage.offsetY
        // Older reading records can name a space that disappears on wrapping.
        // Normalize just those records at their original viewport point.
        let canonical = value.whitespace == true ? try self.passage(value.page, at: CGPoint(x: x, y: y)) : passage
        return ReadingPosition(page: value.page, x: x, y: y,
                               anchor: try self.anchor(value.page), nativePassage: canonical)
    }
    func selection(_ page: Int, from start: NativeSourceAnchor, to end: NativeSourceAnchor) throws -> RasterSelection {
        try Task.checkCancellation()
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard engine == .mupdf, let fn = symbol("lf_select_anchors_at", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_select_anchors_at") }
        let location = try preparedLocation(page)
        var error = [CChar](repeating: 0, count: 512)
        return try decode(fn(document, Int32(location.chapter), Int32(location.page), start.node, start.offset, start.part,
                             end.node, end.offset, end.part, &error), error: error, as: RasterSelection.self)
    }
    func sourceSelectionText(_ characters: [(NativeSourceAnchor, UInt32)]) throws -> String {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<UInt32>?, UnsafePointer<UInt32>?, UnsafePointer<UInt32>?, UnsafePointer<Int32>?, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard engine == .mupdf, reflowable,
              let fn = symbol("lf_html_source_selection_text", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_html_source_selection_text") }
        guard characters.count <= Int(Int32.max) else { throw ReadError("Selection is too large") }
        let nodes = characters.map { $0.0.node }, offsets = characters.map { $0.0.offset }, parts = characters.map { $0.0.part }
        let runes = characters.map { Int32($0.1) }
        var error = [CChar](repeating: 0, count: 512)
        struct Result: Decodable { let text: String }
        let pointer = nodes.withUnsafeBufferPointer { nodeBuffer in
            offsets.withUnsafeBufferPointer { offsetBuffer in
                parts.withUnsafeBufferPointer { partBuffer in
                    runes.withUnsafeBufferPointer { runeBuffer in
                        fn(document, nodeBuffer.baseAddress, offsetBuffer.baseAddress, partBuffer.baseAddress,
                           runeBuffer.baseAddress, Int32(characters.count), &error)
                    }
                }
            }
        }
        return try decode(pointer, error: error, as: Result.self).text
    }
    func position(for source: NativeSourceAnchor) throws -> ReadingPosition? {
        try position(for: NativePassage(source: source, offsetX: 0, offsetY: 0, sourceRevision: sourceRevision, styleSignature: htmlStyleSignature))
    }
    func anchor(_ page: Int) throws -> String? {
        guard reflowable else { return nil }
        let location = try preparedLocation(page)
        return chapterTable?.bookmark(location)
    }
    func page(for anchor: String) throws -> Int? {
        guard reflowable, let saved = ChapterTable.bookmarkLocation(anchor), let table = chapterTable else { return nil }
        let chapter = min(saved.location.chapter, table.chapterCount - 1)
        try ensureChapter(chapter)
        guard let current = chapterTable else { return nil }
        return current.page(for: current.restored(saved.location, savedCount: saved.count))
    }
    func rawPath(_ index: Int) throws -> Data {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32) -> UnsafePointer<CChar>?
        guard let fn = symbol("lf_path", Get.self), let pointer = fn(document, Int32(index)) else { throw ReadError("Missing CHM entry") }
        return Data(bytes: pointer, count: strlen(pointer))
    }
    func path(_ index: Int) throws -> String { String(decoding: try rawPath(index), as: UTF8.self) }
    func data(_ index: Int) throws -> Data {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<Int>) -> UnsafeMutableRawPointer?
        var size = 0
        guard let fn = symbol("lf_read", Get.self), let pointer = fn(document, Int32(index), &size) else { throw ReadError("Cannot read CHM entry") }
        return Data(bytesNoCopy: pointer, count: size, deallocator: .free)
    }
}
#endif
