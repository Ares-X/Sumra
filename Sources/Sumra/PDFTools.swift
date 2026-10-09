#if os(macOS)
import Foundation
import AppKit
import CoreGraphics
import Darwin

// Shared PDF output data, page ranges, image writing and file identity.
// The live MuPDF document owns reading, editing and existing-PDF operations.
enum PDFTools {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    struct OutlineEntry: Codable {
        let title: String
        let depth: Int
        let page: Int?
        let x: Double?
        let y: Double?
        let zoom: Double?
        let url: String?
    }

    struct Attachment {
        /// A display filename, never an extraction path.
        let name: String
        let description: String?
        let data: Data
    }

    // Zero-based translation of Sumatra PdfTools.cpp::ParseDeletePages, revision
    // 012d997f6a3a5c5c97b878e1a340db3bffde8c0e. Copyright SumatraPDF authors, GPLv3.
    static func parsePages(_ specification: String, count: Int) throws -> [Int] {
        guard count > 0 else { throw Failure("This PDF has no pages") }
        var pages = Set<Int>()
        func number(_ value: String) throws -> Int {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let page = text.uppercased() == "N" ? count : Int(text)
            guard let page, page > 0, page <= count else { throw Failure("Invalid page: \(text)") }
            return page
        }
        for part in specification.split(separator: ",", omittingEmptySubsequences: false) {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let dash = text.firstIndex(of: "-") {
                let first = try number(String(text[..<dash]))
                let tail = String(text[text.index(after: dash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let last = try number(tail.isEmpty ? "N" : tail)
                guard first <= last else { throw Failure("Page ranges must be ascending") }
                for page in first...last { pages.insert(page - 1) }
            } else { pages.insert(try number(text) - 1) }
        }
        guard !pages.isEmpty else { throw Failure("Choose at least one page") }
        return pages.sorted()
    }

    static func images(_ images: [CGImage], dpi: Double = 72) throws -> Data {
        try self.images(count: images.count, dpi: dpi) { images[$0] }
    }

    private final class ImagePDFOutput {
        let file: FileHandle
        var failure: Error?

        init(_ url: URL) throws {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }
            file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func consumer() -> CGDataConsumer? {
            var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
                guard let info else { return 0 }
                let output = Unmanaged<ImagePDFOutput>.fromOpaque(info).takeUnretainedValue()
                guard output.failure == nil else { return 0 }
                do {
                    try output.file.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer), count: count, deallocator: .none))
                    return count
                } catch { output.failure = error; return 0 }
            }, releaseConsumer: { info in
                if let info { Unmanaged<ImagePDFOutput>.fromOpaque(info).release() }
            })
            let retained = Unmanaged.passRetained(self)
            let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks)
            if consumer == nil { retained.release() }
            return consumer
        }

        func close() throws {
            do { try file.close() } catch { if failure == nil { failure = error } }
            if let failure { throw failure }
        }
    }

    static func images(count: Int, dpi: Double = 72, imageAt: (Int) throws -> CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData) else { throw Failure("Cannot create PDF") }
        try drawImages(count: count, dpi: dpi, consumer: consumer, imageAt: imageAt)
        return bytes as Data
    }

    static func writeImages(count: Int, to destination: URL, dpi: Double = 72,
                            pageSize: ((Int) throws -> CGSize)? = nil, imageAt: (Int) throws -> CGImage) throws {
        let output = try ImagePDFOutput(destination)
        do {
            guard let consumer = output.consumer() else { throw Failure("Cannot create PDF") }
            try drawImages(count: count, dpi: dpi, consumer: consumer, pageSize: pageSize) { index in
                if let failure = output.failure { throw failure }
                return try imageAt(index)
            }
            try output.close()
        } catch { try? output.close(); throw error }
    }

    // Decode one page at a time and return the platform writer's PDF directly.
    // Reopening it in PDFKit and serializing a second time loses this benefit.
    private static func drawImages(count: Int, dpi: Double, consumer: CGDataConsumer,
                                   pageSize: ((Int) throws -> CGSize)? = nil, imageAt: (Int) throws -> CGImage) throws {
        guard count > 0, dpi.isFinite, dpi > 0 else { throw Failure("Choose images and a positive DPI") }
        guard let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw Failure("Cannot create PDF") }
        defer { context.closePDF() }
        for index in 0..<count {
            let image = try imageAt(index)
            let size = try pageSize?(index) ?? CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            var bounds = CGRect(origin: .zero, size: size)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw Failure("The image DPI produces invalid PDF page dimensions")
            }
            let box = withUnsafeBytes(of: &bounds) { Data($0) }
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            context.draw(image, in: bounds)
            context.endPDFPage()
        }
    }

    @MainActor
    static func outputImage(_ image: CGImage, action: ReaderAction, state: ReaderState) throws {
        try outputImages([image], action: action, state: state)
    }

    @MainActor
    static func outputImages(_ images: [CGImage], action: ReaderAction, state: ReaderState) throws {
        guard !images.isEmpty else { throw Failure("Select a page area first") }
        if action == .searchSelectionWithLens {
            try ReaderImages.searchWithLens(images, state: state)
            return
        }
        let image = try RasterLayout.join(images)
        let bitmap = NSBitmapImageRep(cgImage: image)
        if action == .saveSelection {
            let panel = NSSavePanel()
            panel.allowedFileTypes = ["png", "jpg", "tiff", "bmp"]
            panel.nameFieldStringValue = "Selection.png"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            if let document = state.document, sameFile(destination, document.url) { throw Failure("Choose a different location for the selection") }
            guard let data = bitmap.representation(using: try imageType(for: destination), properties: [:]) else { throw Failure("Cannot encode selection image") }
            try data.write(to: destination, options: .atomic)
        } else {
            guard let data = bitmap.representation(using: .tiff, properties: [:]) else { throw Failure("Cannot encode selection image") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .tiff)
        }
    }

    static func imageType(for destination: URL) throws -> NSBitmapImageRep.FileType {
        switch destination.pathExtension.lowercased() {
        case "", "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "bmp": return .bmp
        default: throw Failure("Choose a PNG, JPEG, TIFF or BMP filename")
        }
    }

    // Translate Sumatra PdfTools.cpp WithDefaultImageExt/EnsurePagePlaceholder/
    // ReplacePagePlaceholder (012d997f, GPLv3), with %d for page export filenames.
    // Validate the complete output plan before any page is rendered or written.
    static func imageDestinations(pages: [Int], template: URL, sources: [URL] = []) throws -> [URL] {
        guard template.isFileURL, !template.hasDirectoryPath,
              (try? template.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
              !pages.isEmpty, pages.allSatisfy({ $0 >= 0 && $0 < Int.max }) else { throw Failure("Choose pages and a local output filename") }
        _ = try imageType(for: template)
        var path = (template.pathExtension.isEmpty ? template.appendingPathExtension("png") : template).path
        if pages.count > 1, !path.contains("%d") {
            let url = URL(fileURLWithPath: path)
            path = url.deletingPathExtension().path + "-%d." + url.pathExtension
        }
        let destinations = pages.map { URL(fileURLWithPath: path.replacingOccurrences(of: "%d", with: String($0 + 1))) }
        let inputs = Set(sources.map(fileIdentity))
        var outputs = Set<AnyHashable>()
        for destination in destinations {
            guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
                throw Failure("An image output is a directory")
            }
            let identity = fileIdentity(destination)
            guard !inputs.contains(identity), outputs.insert(identity).inserted else {
                throw Failure("Image outputs must not overwrite input files or each other")
            }
        }
        return destinations
    }

    private static func fileIdentity(_ url: URL) -> AnyHashable {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let id = (try? canonical.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject {
            return AnyHashable(id)
        }
        return AnyHashable(canonical)
    }

    static func sameFile(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath() == second.standardizedFileURL.resolvingSymlinksInPath()
            || fileIdentity(first) == fileIdentity(second)
    }

}
#endif
