#if os(macOS)
import AppKit
import CoreText
import ImageIO
import SumraCore

func runSumraProcess(_ process: Process) throws {
    try Task.checkCancellation()
    try process.run()

    while process.isRunning {
        if Task.isCancelled {
            process.terminate()
            process.waitUntilExit()
            throw CancellationError()
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Sumra-" + UUID().uuidString, isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

enum MarkdownRenderer: String, Codable, CaseIterable, Sendable {
    case automatic, paged, compatible

    static let largeDocumentThreshold = 8 * 1_024 * 1_024
    // A source-density heuristic for Automatic, not a DOM/AX node limit.
    // The observed 150,000-paragraph input stalls WebKit's AX traversal even
    // below 8 MiB. Explicit Compatibility still preserves browser rendering.
    static let denseSourceRunThreshold = 100_000

    static func preferenceKey(for url: URL) -> String {
        "markdownRenderer:" + url.standardizedFileURL.path
    }

    static func layoutHintKey(for url: URL) -> String {
        "markdownLayoutLimit:" + url.standardizedFileURL.path
    }

    static func sourceSignature(for url: URL) -> String? {
        guard let version = NativeFile.FileVersion(url) else { return nil }
        // Finder's last-opened metadata changes ctime without changing the
        // document. Layout observations follow content metadata instead.
        return version.contentMetadataSignature
    }

    static func rememberLayoutLimit(for url: URL, openedSignature: String?) -> Bool {
        guard let openedSignature, sourceSignature(for: url) == openedSignature else { return false }
        UserDefaults.standard.set(openedSignature, forKey: layoutHintKey(for: url))
        return true
    }

    func effective(for url: URL) throws -> MarkdownRenderer {
        guard self == .automatic else { return self }
        guard let version = NativeFile.FileVersion(url) else {
            throw ReadError("Cannot inspect Markdown file: \(url.lastPathComponent)")
        }
        let key = Self.layoutHintKey(for: url)
        if let hinted = UserDefaults.standard.string(forKey: key) {
            if hinted == version.contentMetadataSignature { return .paged }
            UserDefaults.standard.removeObject(forKey: key)
        }
        if version.size >= Int64(Self.largeDocumentThreshold) { return .paged }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var runs = 0, bytesRead = 0
        var lineHasContent = false, inRun = false, previousCR = false
        while bytesRead < Self.largeDocumentThreshold {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: min(65_536, Self.largeDocumentThreshold - bytesRead)),
                  !data.isEmpty else { return .compatible }
            bytesRead += data.count
            let dense = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes {
                    if byte == 10 || byte == 13 {
                        if byte == 10 && previousCR { previousCR = false; continue }
                        previousCR = byte == 13
                        if !lineHasContent { inRun = false }
                        lineHasContent = false
                    } else {
                        previousCR = false
                        if byte != 32 && byte != 9 && !lineHasContent {
                            lineHasContent = true
                            if !inRun {
                                inRun = true
                                runs += 1
                                if runs >= Self.denseSourceRunThreshold { return true }
                            }
                        }
                    }
                }
                return false
            }
            if dense { return .paged }
        }
        // A file that grew during inspection also follows the size rule.
        return .paged
    }
}

struct ReadingDocument: Identifiable {
    let id = UUID()
    enum Content {
        case text(String)
        case browser(any BrowserSource)
        case pages(Pages)
    }

    var url: URL
    let content: Content
    let temporary: TemporaryDirectory?
    var sourceTemporary: TemporaryDirectory?
    /// The selected policy and effective renderer exist only for inspected Markdown.
    var markdownPreference: MarkdownRenderer?
    var markdownRenderer: MarkdownRenderer?
    var markdownSourceSignature: String?
    // An open descriptor retains access to the source after unlink/rename without
    // a second memory buffer or disk copy for every loaded document.
    private var sourceFile: FileHandle?

    var settingsFormat: String {
        switch content {
        case .text: return "text"
        case .browser: return Format.detect(url.lastPathComponent).rawValue
        case .pages(let pages):
            if pages.isPDF { return "pdf" }
            if url.hasDirectoryPath { return "comic" }
            if Format.isComicImage(url.lastPathComponent) { return "image" }
            return Format.detect(url.lastPathComponent).rawValue
        }
    }

    init(url: URL, content: Content, temporary: TemporaryDirectory? = nil,
         markdownPreference: MarkdownRenderer? = nil, markdownRenderer: MarkdownRenderer? = nil,
         markdownSourceSignature: String? = nil) {
        self.url = url
        self.content = content
        self.temporary = temporary
        self.markdownPreference = markdownPreference
        self.markdownRenderer = markdownRenderer
        self.markdownSourceSignature = markdownSourceSignature
        sourceFile = url.hasDirectoryPath ? nil : try? FileHandle(forReadingFrom: url)
    }

    mutating func retargetSource(to url: URL) {
        guard self.url != url else { return }
        // A multi-file browser keeps its renderer, but Save a Copy must retain
        // the newly displayed file. Never fall back to the previous file's bytes.
        let file = url.hasDirectoryPath ? nil : try? FileHandle(forReadingFrom: url)
        self.url = url
        sourceFile = file
        if case .browser(let source) = content, source is MarkupSource {
            let prefix = (try? file?.read(upToCount: 2_048)) ?? Data()
            if let inspected = try? Format.inspect(url, prefix: prefix), inspected.format == .markdown {
                markdownRenderer = .compatible
                markdownSourceSignature = MarkdownRenderer.sourceSignature(for: url)
                markdownPreference = (try? Self.markdownPolicy(for: url, inspected: inspected.format))?.preference
                    ?? .automatic
            } else {
                markdownPreference = nil
                markdownRenderer = nil
                markdownSourceSignature = nil
            }
        }
    }

    func copySource(to destination: URL) throws {
        let source = url.resolvingSymlinksInPath()
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            throw ReadError("The source file has been replaced by a directory.")
        }
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch {
            guard !FileManager.default.fileExists(atPath: url.path), let sourceFile else { throw error }
            try sourceFile.seek(toOffset: 0)
            try Data().write(to: destination, options: .withoutOverwriting)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while let block = try sourceFile.read(upToCount: 1_048_576), !block.isEmpty { try output.write(contentsOf: block) }
            try output.synchronize()
        }
    }

    var hasSeparatePDFSource: Bool {
        guard case .pages(let pages) = content, pages.isPDF else { return false }
        let source = pages.pdfSourceURL
        return url != source && !PDFTools.sameFile(url, source)
    }

    // Converted/unwrapped PDFs can save either the live PDF, including edits,
    // or the original container. Original-file copies never mark PDF edits saved.
    @MainActor
    func saveCopy(to destination: URL, originalFile: Bool = false) async throws {
        guard !url.hasDirectoryPath else { throw ReadError("Save a Copy is only available for files.") }
        guard !PDFTools.sameFile(url, destination) else {
            throw ReadError("Choose a different location for Save a Copy.")
        }
        if case .pages(let pages) = content, pages.isPDF {
            guard !PDFTools.sameFile(pages.pdfSourceURL, destination) else {
                throw ReadError("Choose a different location for Save a Copy.")
            }
            if !originalFile {
                try await pages.pdfSaveCopy(to: destination)
                return
            }
        }
        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            throw ReadError("Choose a file location, not a directory")
        }
        let files = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Sumra-copy-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        try copySource(to: temporary)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: destination)
        }
    }

    // Sumatra CreateThumbnailFromFileThread: a sibling cover, then the EPUB
    // cover declared by its OPF, then page one through the existing reader.
    // This temporary document never enters reading history or saved positions.
    static func thumbnail(_ url: URL, size: CGSize) async throws -> CGImage? {
        try Task.checkCancellation()
        let options: CFDictionary = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height)] as CFDictionary
        for ext in ["jpg", "jpeg", "png"] {
            let cover = url.deletingPathExtension().appendingPathExtension(ext)
            if cover != url, FileManager.default.fileExists(atPath: cover.path),
               let source = CGImageSourceCreateWithURL(cover as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) { return image }
        }
        if url.pathExtension.lowercased() == "epub", let data = try? epubCover(url),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) { return image }
        try Task.checkCancellation()
        // MarkdownModel::CreateThumbnail is empty. This applies to both
        // renderers: opening a paged home preview would lay out the whole book.
        let declared = Format.detect(url.lastPathComponent)
        if declared == .markdown || declared == .html {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 2048) ?? Data()
            let format = try Format.resolve(url, prefix: prefix)
            if format == .markdown || format == .html { return nil }
        }
        let document = try open(url)
        defer { withExtendedLifetime(document) {} }
        switch document.content {
        case .pages(let pages):
            let bounds = try await pages.bounds(0)
            let width = bounds.height > 0 ? min(size.width, size.height * bounds.width / bounds.height) : size.width
            return try await pages.image(0, width: max(1, Int(width.rounded(.up))))
        case .text(let text):
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: size.width / 600, y: size.width / 600)
            let attributed = NSAttributedString(string: String(text.prefix(8_000)), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            let layout = CTFramesetterCreateWithAttributedString(attributed)
            let area = CGRect(x: 24, y: 24, width: 552, height: size.height * 600 / size.width - 48)
            CTFrameDraw(CTFramesetterCreateFrame(layout, CFRange(location: 0, length: 0), CGPath(rect: area, transform: nil), nil), context)
            return context.makeImage()
        case .browser(let source):
            guard source is CHMSource else { return nil }
            return try await BrowserReader.thumbnail(source, size: size)
        }
    }

    // EpubCoverImageData from pinned EbookDoc.cpp. Foundation owns XML and URL
    // decoding; Archive owns decompression. No chapter parsing or extraction.
    static func epubCover(_ url: URL) throws -> Data? {
        let archive = try Archive(url)
        guard archive.contains("META-INF/container.xml") else { return nil }
        let container = try XMLDocument(data: archive.data("META-INF/container.xml"), options: .nodeLoadExternalEntitiesNever)
        guard let path = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue?.removingPercentEncoding,
              archive.contains(path) else { return nil }
        let package = try XMLDocument(data: archive.data(path), options: .nodeLoadExternalEntitiesNever)
        let coverID = try package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='meta'][@name='cover']/@content").first?.stringValue
        for case let item as XMLElement in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard ["image/png", "image/jpeg", "image/gif"].contains(item.attribute(forName: "media-type")?.stringValue ?? "") else { continue }
            let properties = item.attribute(forName: "properties")?.stringValue?.split(whereSeparator: \.isWhitespace) ?? []
            guard coverID != nil && item.attribute(forName: "id")?.stringValue == coverID || properties.contains("cover-image"),
                  let href = item.attribute(forName: "href")?.stringValue,
                  let cover = URL(string: href, relativeTo: URL(fileURLWithPath: "/" + path))?.standardized.path,
                  archive.contains(String(cover.dropFirst())) else { continue }
            return try archive.data(String(cover.dropFirst()))
        }
        return nil
    }

    static func open(_ url: URL, password: String? = nil, deferReflowLayout: Bool = false,
                     markdownRenderer requestedRenderer: MarkdownRenderer? = nil) throws -> ReadingDocument {
        let started = DispatchTime.now().uptimeNanoseconds
        NativeReadingPerformance.mark("source-open-entry")
        defer { NativeReadingPerformance.mark("source-open-return", started: started) }
        try Task.checkCancellation()

        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let folder = URL(fileURLWithPath: url.path, isDirectory: true)
            return .init(url: folder, content: .pages(try Pages(folder, format: .comic, deferReflowLayout: deferReflowLayout)))
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 2048) ?? Data()
        let inspected = try Format.inspect(url, prefix: prefix, password: password)
        let format = inspected.format

        switch format {
        case .pdf:
            let temporary: TemporaryDirectory?
            let source: URL
            if url.pathExtension.lowercased() == "p7m", !prefix.starts(with: Data("%PDF-".utf8)) {
                let directory = try TemporaryDirectory()
                let extracted = directory.url.appendingPathComponent("document.pdf")
                do {
                    // Like EngineCreate.cpp, extract the envelope before content
                    // sniffing: its embedded PDF header can occur in the prefix.
                    try NativePDFTools.unwrap(source: url, destination: extracted)
                    source = extracted; temporary = directory
                } catch {
                    guard Format.hasPDFMarker(prefix) else { throw error }
                    source = url; temporary = nil
                }
            } else { source = url; temporary = nil }
            return .init(url: url, content: .pages(try Pages(source, format: .pdf, password: password)), temporary: temporary)

        case .replica:
            let data = try LegacyText.palm(
                Data(contentsOf: url, options: .mappedIfSafe),
                replica: true
            )
            return try embeddedPDF(data, url: url, password: password)

        case .text:
            return .init(
                url: url,
                content: .text(decode(try Data(contentsOf: url, options: .mappedIfSafe)))
            )

        case .palm:
            let content = try LegacyText.palmContent(Data(contentsOf: url, options: .mappedIfSafe))
            let directory = try TemporaryDirectory()
            let source = directory.url.appendingPathComponent("document.html")
            try content.html.write(to: source)
            let outline = content.bookmarks.map { ContentsItem(title: $0.title, target: "#" + $0.fragment) }
            return .init(url: url, content: .pages(try Pages(source, format: .mupdf, outline: outline, deferReflowLayout: deferReflowLayout)), temporary: directory)

        case .tcr:
            let data = try LegacyText.tcr(Data(contentsOf: url, options: .mappedIfSafe))
            return .init(url: url, content: .text(decode(data)))

        case .book:
            if prefix.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
                let archive = try inspected.archive ?? Archive(url, password: password)
                let files = archive.entries.filter { $0.lowercased().hasSuffix(".fb2") }
                if files.count == 1, !archive.contains("META-INF/container.xml") {
                    let directory = try TemporaryDirectory()
                    let source = directory.url.appendingPathComponent("document.fb2")
                    try archive.data(files[0]).write(to: source)
                    return .init(url: url, content: .pages(try Pages(source, format: .mupdf, deferReflowLayout: deferReflowLayout)), temporary: directory)
                }
            }
            if prefix.count >= 68, String(decoding: prefix[60..<68], as: UTF8.self) == "BOOKMOBI" {
                let input = try Data(contentsOf: url, options: .mappedIfSafe)
                if let data = try LegacyText.mobiPDF(input) { return try embeddedPDF(data, url: url, password: password) }
                if let content = try LegacyText.mobiContent(input) {
                    let directory = try TemporaryDirectory()
                    let source = directory.url.appendingPathComponent("document.mobihtml")
                    try content.html.write(to: source)
                    for (name, data) in content.resources { try data.write(to: directory.url.appendingPathComponent(name)) }
                    let outline = content.outline.map { ContentsItem(title: $0.title, target: $0.target, depth: $0.level) }
                    return .init(url: url, content: .pages(try Pages(source, format: .mupdf, outline: outline.isEmpty ? nil : outline, deferReflowLayout: deferReflowLayout)), temporary: directory)
                }
                let decoded = try LegacyText.mobi(input)
                if decoded != input {
                    let directory = try TemporaryDirectory()
                    let source = directory.url.appendingPathComponent("document.mobi")
                    try decoded.write(to: source)
                    return .init(url: url, content: .pages(try Pages(source, format: .mupdf, deferReflowLayout: deferReflowLayout)), temporary: directory)
                }
            }
            return .init(url: url, content: .pages(try Pages(url, format: .mupdf, deferReflowLayout: deferReflowLayout)))

        case .markdown:
            let sourceSignature = NativeFile.FileVersion(descriptor: handle.fileDescriptor)
                .flatMap { version -> String? in
                    guard NativeFile.FileVersion(url) == version else { return nil }
                    return MarkdownRenderer.sourceSignature(for: url)
                }
            let policy = try markdownPolicy(for: url, inspected: format, requested: requestedRenderer)!
            let (preference, renderer) = policy
            if renderer == .paged {
                return .init(url: url, content: .pages(try Pages(url, format: .markdown, deferReflowLayout: deferReflowLayout)),
                             markdownPreference: preference, markdownRenderer: renderer,
                             markdownSourceSignature: sourceSignature)
            }
            return .init(url: url, content: .browser(try MarkupSource(url)),
                         markdownPreference: preference, markdownRenderer: renderer,
                         markdownSourceSignature: sourceSignature)

        case .html:
            if UserDefaults.standard.bool(forKey: "useFixedPageUI") {
                return .init(url: url, content: .pages(try Pages(url, format: format, deferReflowLayout: deferReflowLayout)))
            }
            return .init(url: url, content: .browser(try MarkupSource(url)))

        case .chm:
            return .init(url: url, content: .browser(try CHMSource(url)))

        case .lit:
            let (temporary, root) = try LitConverter.convert(url)
            return .init(
                url: url,
                content: .pages(try Pages(root, format: .mupdf, deferReflowLayout: deferReflowLayout)),
                temporary: temporary
            )

        case .image, .comic, .mupdf, .djvu:
            let archive = format == .comic ? try inspected.archive ?? Archive(url, password: password) : nil
            return .init(url: url, content: .pages(try Pages(url, format: format, archive: archive, deferReflowLayout: deferReflowLayout)))

        case .postscript:
            return try openPostScript(url)

        default:
            throw ReadError("Unsupported document: \(url.lastPathComponent)")
        }
    }

    static func markdownPolicy(for url: URL, inspected format: Format,
                               requested: MarkdownRenderer? = nil) throws -> (preference: MarkdownRenderer, renderer: MarkdownRenderer)? {
        guard format == .markdown else { return nil }
        let saved = UserDefaults.standard.string(forKey: MarkdownRenderer.preferenceKey(for: url))
            .flatMap(MarkdownRenderer.init(rawValue:))
        let preference = requested ?? saved
            ?? (UserDefaults.standard.bool(forKey: "useFixedPageUI") ? .paged : .automatic)
        return (preference, try preference.effective(for: url))
    }

    /// Called before a MarkupSource sibling is handed to WebKit. The same
    /// inspected type and Markdown policy used by open decide its reader.
    static func markupSiblingNeedsDocumentOpen(_ url: URL) -> Bool {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 2_048),
              let inspected = try? Format.inspect(url, prefix: prefix) else { return false }
        switch inspected.format {
        case .pdf: return true
        case .markdown:
            return (try? markdownPolicy(for: url, inspected: inspected.format)?.renderer) == .paged
        default: return false
        }
    }

    // Parse once on the loading task. A failed reload must not replace a readable document.
    private static func embeddedPDF(_ data: Data, url: URL, password: String?) throws -> ReadingDocument {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("document.pdf")
        try data.write(to: source)
        return .init(url: url, content: .pages(try Pages(source, format: .pdf, password: password)), temporary: directory)
    }

    static func decode(_ data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        var converted: NSString?
        _ = NSString.stringEncoding(
            for: data,
            encodingOptions: [:],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        return converted as String? ?? String(decoding: data, as: UTF8.self)
    }

    private static func openPostScript(_ url: URL) throws -> ReadingDocument {
        let candidates = ["/opt/homebrew/bin/gs", "/usr/local/bin/gs", "/usr/bin/gs"]
        guard let ghostscript = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ReadError("PostScript/PJL needs Ghostscript.")
        }

        let temporary = try TemporaryDirectory()
        let output = temporary.url.appendingPathComponent("document.pdf")
        let diagnostics = temporary.url.appendingPathComponent("converter-error.txt")
        guard FileManager.default.createFile(atPath: diagnostics.path, contents: nil) else { throw ReadError("Cannot create conversion diagnostics") }
        let errors = try FileHandle(forWritingTo: diagnostics)
        defer { try? errors.close() }
        func failure(_ message: String) -> ReadError {
            let detail = (try? String(contentsOf: diagnostics, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ReadError(detail.isEmpty ? message : message + "\n" + detail)
        }
        let input: URL

        if url.lastPathComponent.lowercased().hasSuffix(".ps.gz") {
            input = temporary.url.appendingPathComponent("document.ps")

            guard FileManager.default.createFile(atPath: input.path, contents: nil) else {
                throw ReadError("Cannot create temporary PostScript")
            }
            let handle = try FileHandle(forWritingTo: input)
            defer { try? handle.close() }

            let gzip = Process()
            gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            gzip.arguments = ["-dc", url.path]
            gzip.standardOutput = handle
            gzip.standardError = errors

            try runSumraProcess(gzip)
            guard gzip.terminationStatus == 0 else {
                throw failure("Cannot decompress PostScript")
            }
        } else {
            input = url
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghostscript)
        process.arguments = [
            "-dSAFER",
            "-dBATCH",
            "-dNOPAUSE",
            "-sDEVICE=pdfwrite",
            "-sOutputFile=" + output.path,
            "-f",
            input.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        try runSumraProcess(process)
        guard process.terminationStatus == 0 else {
            throw failure("Ghostscript could not convert this file.")
        }

        return .init(url: url, content: .pages(try Pages(output, format: .pdf)), temporary: temporary)
    }
}
#endif
