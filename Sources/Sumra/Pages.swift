#if os(macOS)
import AppKit
import Darwin
import CoreGraphics
import SwiftUI
import ImageIO
import OSLog
import SumraCore

// Content-free local diagnostics. Sparse opening stages persist at default level;
// rendering stays debug. The monotonic clock compares waiting, work and drawing.
enum NativeReadingPerformance {
    private static let logger = Logger(subsystem: "com.leaf.reader", category: "native-reading")
    // Initial-prepare flags: 1 = source passage, 2 = legacy finite geometry,
    // 4 = single-page bookmark, 8 = continuous flow. No document text is logged.
    static func mark(_ stage: String, pages: Pages? = nil, pagesIdentity: ObjectIdentifier? = nil, revision: Int = -1, page: Int = -1, started: UInt64? = nil, size: CGSize = .zero, persistent: Bool = false, flags: Int = 0) {
        let now = DispatchTime.now().uptimeNanoseconds
        let owner = (pages.map { ObjectIdentifier($0) } ?? pagesIdentity).map { UInt(bitPattern: $0) } ?? 0
        logger.log(level: persistent ? .default : .debug, "\(stage, privacy: .public) monotonic_ns=\(now, privacy: .public) owner=\(owner, privacy: .public) revision=\(revision, privacy: .public) page=\(page, privacy: .public) duration_ns=\(started.map { now &- $0 } ?? 0, privacy: .public) width=\(Double(size.width), privacy: .public) height=\(Double(size.height), privacy: .public) flags=\(flags, privacy: .public)")
    }
}

struct RasterMatchFragment: Equatable {
    let page: Int
    let rects: [CGRect]
    var location: PageLocation? = nil
}
struct RasterMatch: Equatable {
    let page: Int
    let index: Int
    let rects: [CGRect]
    var context = ""
    var source: NativeSourceAnchor? = nil
    var fragments: [RasterMatchFragment]? = nil
    var location: PageLocation? = nil
    func rects(on page: Int) -> [CGRect] {
        fragments?.first(where: { $0.page == page })?.rects ?? (self.page == page ? rects : [])
    }
    func contains(_ page: Int) -> Bool {
        fragments?.contains(where: { $0.page == page }) ?? (self.page == page)
    }
    var lastPage: Int { fragments?.last?.page ?? page }
}
fileprivate struct RasterStyle: Equatable {
    let fontSize: Double, lineHeight: Double, margin: Double
    let font: String, theme: String
    var userCSS = ""
    var useDocumentCSS = true
    var pageMargins: PageMargins?
    var textZoom = 1.0
    var pageSize = CGSize(width: 420, height: 595)
}

// The actor serializes all operations on this synchronous decoder owner.
fileprivate final class RasterDocument {
    let url: URL, format: Format
    let archive: Archive?
    let names: [String]
    var native: NativeFile?
    var source: CGImageSource?
    private var storedCount = 0
    var count: Int { native?.count ?? storedCount }
    var isImageCollection: Bool { format == .image || format == .comic || Format.imageEngine(url.lastPathComponent) != nil }
    var style: RasterStyle?
    private var comicVector: (page: Int, file: NativeFile, temporary: TemporaryDirectory?)?
    func isVectorImage(_ page: Int) -> Bool {
        (names.isEmpty ? url.pathExtension : URL(fileURLWithPath: names[page]).pathExtension).lowercased() == "svg"
    }
    private var cache = [(location: PageLocation, width: Int, transparent: Bool, pdfStyle: PDFColors.Style?, image: CGImage)]()
    // EngineMupdf keeps this document classification until the file is reopened.
    private var engineering: PDFColors.Engineering?
    private(set) var pageBounds = [PageLocation: CGRect]()
    private var contentBoxes = [PageLocation: CGRect]()

    // DisplayModel::UpdateEstimatedMediaBox: unseen image pages use the most
    // common measured size. A few spreads must not resize the whole canvas.
    var estimatedBounds: CGRect {
        var sizes = [(size: CGSize, count: Int)]()
        for location in pageBounds.keys.sorted() {
            guard let size = pageBounds[location]?.size, size.width >= 100, size.height >= 100 else { continue }
            if let index = sizes.firstIndex(where: { $0.size == size }) { sizes[index].count += 1 }
            else if sizes.count < 16 { sizes.append((size, 1)) }
        }
        var best = CGSize(width: 420, height: 595), count = 0
        for item in sizes where item.count > count { best = item.size; count = item.count }
        return CGRect(origin: .zero, size: best)
    }

    init(_ url: URL, format: Format, archive existing: Archive? = nil, password: String? = nil, deferReflowLayout: Bool = false, sourceCheckpoint: NativeFile.FileCheckpoint? = nil) throws {
        self.url = url; self.format = format
        if format == .comic {
            native = nil; source = nil
            if url.hasDirectoryPath {
                archive = nil
                // EngineImages::LoadImageDir reads this directory only. Keep
                // each entry's name so a symlink still opens through its alias.
                let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                names = files.filter {
                    Format.isComicImage($0.lastPathComponent) &&
                    (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            } else {
                let archive = try existing ?? Archive(url)
                self.archive = archive
                names = url.pathExtension.lowercased() == "ora" ? archive.entries.filter { $0 == "mergedimage.png" } : archive.images
            }
            storedCount = names.count
        } else if format == .image {
            archive = nil; names = []; storedCount = 0
            let prefix: Data
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            prefix = try file.read(upToCount: 32) ?? Data()
            if let engine = Format.imageEngine(url.lastPathComponent, prefix: prefix).flatMap(NativeEngine.init(rawValue:)) {
                native = try NativeFile(url, engine: engine); source = nil; storedCount = native!.count
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                self.source = source; native = nil; storedCount = CGImageSourceGetCount(source)
            } else {
                source = nil; native = try NativeFile(url, engine: .mupdf); storedCount = native!.count
            }
        } else {
            archive = nil; names = []; source = nil
            native = try NativeFile(url, engine: format == .djvu ? .djvu : .mupdf, password: password, deferReflowLayout: deferReflowLayout, sourceCheckpoint: sourceCheckpoint, deferMarkdownMetadata: format == .markdown); storedCount = native!.count
        }
        guard count > 0 || deferReflowLayout && native?.reflowable == true else { throw ReadError("No readable pages found") }
    }
    func outline() throws -> [ContentsItem] {
        if let native { return try native.outline() }
        guard format == .comic else { return [] }
        var outline = [ContentsItem](), folders = Set<String>()
        // These are the same naturally sorted names used to paint pages.
        // Directory metadata supplies Contents without reading image bytes.
        for (page, name) in names.enumerated() {
            let parts = name.split(separator: "/").filter { $0 != "." }
            var path = ""
            for (depth, title) in parts.dropLast().enumerated() {
                path += "/" + title
                if folders.insert(path).inserted {
                    outline.append(ContentsItem(title: String(title), target: "#page=\(page + 1)", depth: depth, page: page))
                }
            }
        }
        return outline
    }
    func comicPage(_ target: String) -> Int? {
        guard format == .comic, target.hasPrefix("#page=") else { return nil }
        return Int(target.dropFirst(6)).map { $0 - 1 }
    }
    func relayout(_ style: RasterStyle) throws -> Int? {
        guard let count = try native?.relayout(fontSize: style.fontSize * style.textZoom, lineHeight: style.lineHeight, font: style.font, theme: style.theme, userCSS: style.userCSS, useDocumentCSS: style.useDocumentCSS, pageMargins: style.pageMargins, pageSize: style.pageSize) else { return nil }
        self.style = style; self.storedCount = count; cache.removeAll(); pageBounds.removeAll(); contentBoxes.removeAll()
        return count
    }
    func invalidatePDFCaches() {
        cache.removeAll(); contentBoxes.removeAll()
    }
    func displayStyle(_ requested: PDFColors.Style?, engineeringAuto: Bool, cancellation: NativeRenderCancellation?) throws -> PDFColors.Style? {
        guard format == .pdf, var style = requested, let native else { return nil }
        if style.engineering || engineeringAuto {
            if engineering == nil { engineering = try native.pdfEngineering(cancellation: cancellation) }
            if let engineering {
                style.engineering = style.engineering || (engineeringAuto && engineering.enabled)
                style.rasterEngineering = engineering.raster
                style.hairlineEngineering = engineering.hairline
            }
        }
        return style.isActive ? style : nil
    }
    private func data(_ page: Int, prefixBytes: Int? = nil) throws -> Data {
        guard names.indices.contains(page) else { throw ReadError("Page out of range") }
        if let archive { return try archive.data(names[page], prefixBytes: prefixBytes) }
        let path = url.appendingPathComponent(names[page])
        if let prefixBytes {
            let file = try FileHandle(forReadingFrom: path)
            defer { try? file.close() }
            return try file.read(upToCount: prefixBytes) ?? Data()
        }
        return try Data(contentsOf: path)
    }
    func originalData(_ page: Int) throws -> (data: Data, filename: String) {
        guard (0..<count).contains(page) else { throw ReadError("Page out of range") }
        if !names.isEmpty { return (try data(page), URL(fileURLWithPath: names[page]).lastPathComponent) }
        guard format == .image || Format.imageEngine(url.lastPathComponent) != nil else { throw ReadError("This document page is not an original image file") }
        return (try Data(contentsOf: url), url.lastPathComponent)
    }
    func pdfImage(_ page: Int) throws -> (Data, CGSize) {
        let original = try originalData(page)
        let input = source ?? CGImageSourceCreateWithData(original.data as CFData, nil)
        let size = try input.flatMap { Self.imageBounds($0, index: names.isEmpty ? page : 0, physical: true)?.size } ?? bounds(page).size
        if let input,
           !names.isEmpty || CGImageSourceGetCount(input) == 1,
           let type = CGImageSourceGetType(input) as String?, ["public.jpeg", "public.jpeg-2000", "public.png"].contains(type) {
            return (original.data, size)
        }
        // Multi-frame and platform-only formats use the existing original-size
        // decoder and lossless PNG, with no rendering-size resampling or cache.
        return (try ReaderImages.encoded(editableImage(page).image, extension: "png"), size)
    }
    static func writeImages(count: Int, to destination: URL,
                            page: @escaping (Int) throws -> (RasterDocument, Int)) throws {
        if FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) {
            try NativeFile.exportImages(to: destination, count: count) { index in
                let (document, number) = try page(index)
                return try document.pdfImage(number)
            }
        } else {
            // Core builds keep the same original-size decoder and platform writer.
            // A present but broken native engine still reports its actual failure.
            let pageSize: (Int) throws -> CGSize = { index in
                let (document, number) = try page(index)
                if let source = document.source,
                   let bounds = Self.imageBounds(source, index: number, physical: true) { return bounds.size }
                let data = try document.originalData(number).data
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let bounds = Self.imageBounds(source, index: document.names.isEmpty ? number : 0, physical: true) { return bounds.size }
                return try document.bounds(number).size
            }
            try PDFTools.writeImages(count: count, to: destination, pageSize: pageSize) { index in
                try Task.checkCancellation()
                let (document, number) = try page(index)
                return try document.editableImage(number).image
            }
        }
    }
    func editableImage(_ page: Int) throws -> (image: CGImage, original: (data: Data, filename: String)?, dpi: Double) {
        let original = isImageCollection ? try originalData(page) : nil
        var dpi = 72.0
        if native == nil, let original, let input = source ?? CGImageSourceCreateWithData(original.data as CFData, nil),
           let bounds = Self.imageBounds(input, index: names.isEmpty ? page : 0) {
            let index = names.isEmpty ? page : 0
            let properties = CGImageSourceCopyPropertiesAtIndex(input, index, nil) as? [CFString: Any]
            dpi = ReaderImages.imageDPI(properties)
            let image: CGImage?
            if (properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1 {
                image = CGImageSourceCreateImageAtIndex(input, index, nil)
            } else {
                image = CGImageSourceCreateThumbnailAtIndex(input, index, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(bounds.width, bounds.height)] as CFDictionary)
            }
            if let image { return (image, original, dpi) }
        }
        if let original {
            func originalImage(_ file: NativeFile, page: Int) throws -> CGImage? {
                guard let size = try file.imageDimensions(page) else { return nil }
                if let bounds = try file.bounds(page) { dpi = Double(size.width) * 72 / Double(bounds.width) }
                let rendered = try file.image(page, width: Int(ceil(size.width)), transparent: true)
                // Native page bounds can include unequal X/Y density. Image
                // editing and explicit print DPI use the original pixel grid.
                return try ReaderImages.resized(rendered, width: Int(size.width), height: Int(size.height))
            }
            if let native, let image = try originalImage(native, page: page) { return (image, original, dpi) }
            if !names.isEmpty {
                let engine = Format.imageEngine(names[page], prefix: original.data.prefix(32)).flatMap(NativeEngine.init(rawValue:)) ?? .mupdf
                if let image = try withComicNative(page, data: original.data, engine: engine, { try originalImage($0, page: 0) }) { return (image, original, dpi) }
            }
        }
        let bounds = try bounds(page), width = original == nil ? bounds.width * 2 : bounds.width
        let bitmap = try image(prepareImage(page, width: Int(ceil(width))), cancellation: nil)
        return (bitmap, original, original == nil ? Double(bitmap.width) * 72 / Double(bounds.width) : dpi)
    }
    func metadata() throws -> [String: String] {
        var result = try native?.metadata() ?? [:]
        if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            func append(_ properties: [String: Any], prefix: String = "") {
                for (name, value) in properties {
                    let key = prefix + name.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                    if let nested = value as? [String: Any] { append(nested, prefix: key + ".") }
                    else if let data = value as? Data { result[key] = "\(data.count) bytes" }
                    else if let values = value as? [Any] { result[key] = values.map { String(describing: $0) }.joined(separator: ", ") }
                    else { result[key] = String(describing: value) }
                }
            }
            append(properties)
        }
        if format == .comic {
            let info: Data?
            if let archive, let name = archive.entries.first(where: { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "comicinfo.xml" }) { info = try archive.data(name) }
            else if url.hasDirectoryPath, let item = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.lowercased() == "comicinfo.xml" }) { info = try Data(contentsOf: item) }
            else { info = nil }
            if let info { result.merge(try ComicMetadata.read(info), uniquingKeysWith: { _, new in new }) }
        }
        return result
    }
    private func withComicNative<T>(_ page: Int, data: @autoclosure () throws -> Data, engine: NativeEngine, _ body: (NativeFile) throws -> T) throws -> T {
        if let cached = comicVector, cached.page == page { return try body(cached.file) }
        let directory = url.hasDirectoryPath ? nil : try TemporaryDirectory()
        let path = directory?.url.appendingPathComponent(URL(fileURLWithPath: names[page]).lastPathComponent)
            ?? url.appendingPathComponent(names[page])
        if directory != nil { try data().write(to: path) }
        let file = try NativeFile(path, engine: engine)
        // SVG tiles replay one decoder/display list, including archived pages.
        // Bitmap decoders still release their original pixels after rendering.
        if isVectorImage(page) { comicVector = (page, file, directory) }
        return try withExtendedLifetime(directory) { try body(file) }
    }
    struct ImageRequest {
        let page: Int, width: Int
        let transparent: Bool
        let region: CGRect?
        let pdfStyle: PDFColors.Style?
        let location: PageLocation
        let cached: CGImage?
    }
    func concurrentComicImage(_ request: ImageRequest) -> Bool {
        archive != nil && format == .comic && request.region == nil
            && Format.imageEngine(names[request.page]) == nil
    }
    func comicImageData(_ request: ImageRequest) throws -> Data { try data(request.page) }
    func comicNativeImage(_ request: ImageRequest, data: Data, cancellation: NativeRenderCancellation?) throws -> CGImage {
        let engine = Format.imageEngine(names[request.page], prefix: data.prefix(32)).flatMap(NativeEngine.init(rawValue:)) ?? .mupdf
        return try withComicNative(request.page, data: data, engine: engine) { file in
            let pixels = isVectorImage(request.page) ? nil : try file.imageDimensions(0)
            return try file.image(0, width: min(request.width, Int(ceil(pixels?.width ?? CGFloat(request.width)))),
                                  transparent: request.transparent, cancellation: cancellation)
        }
    }
    static func comicImage(_ data: Data, width: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ReadError("ImageIO cannot read this image")
        }
        return try imageIO(source, index: 0, width: width)
    }
    // Normalize and consult the bitmap cache once, before the caller creates
    // a render cookie. Region pixels remain owned by the visible tile canvas.
    func prepareImage(_ page: Int, width: Int, transparent: Bool = false, region: CGRect? = nil, pdfStyle: PDFColors.Style? = nil) throws -> ImageRequest {
        try Task.checkCancellation()
        guard (0..<count).contains(page) else { throw ReadError("Page out of range") }
        var width = width
        if region == nil, isImageCollection, !isVectorImage(page), let dimensions = try native?.imageDimensions(page) {
            width = min(width, max(1, Int(ceil(dimensions.width))))
        }
        let location = region == nil ? try native?.location(page) ?? PageLocation(page: page) : PageLocation(page: page)
        var cached: CGImage?
        if region == nil, let index = cache.firstIndex(where: { $0.location == location && $0.width == width && $0.transparent == transparent && $0.pdfStyle == pdfStyle }) {
            let hit = cache.remove(at: index); cache.append(hit); cached = hit.image
        }
        return ImageRequest(page: page, width: width, transparent: transparent, region: region,
                            pdfStyle: pdfStyle, location: location, cached: cached)
    }
    func image(_ request: ImageRequest, cancellation: NativeRenderCancellation?) throws -> CGImage {
        try Task.checkCancellation()
        if let image = request.cached { return image }
        let page = request.page, transparent = request.transparent, pdfStyle = request.pdfStyle
        var width = request.width
        let location = request.location
        if let region = request.region {
            // Visible tiles belong to their canvas, not the whole-page cache.
            if comicVector?.page != page { comicVector = nil }
            if let native { return try native.image(page, width: width, transparent: transparent, region: region, style: pdfStyle, cancellation: cancellation) }
            guard !names.isEmpty, isVectorImage(page) else { throw ReadError("This image does not support page regions") }
            return try withComicNative(page, data: data(page), engine: .mupdf) {
                try $0.image(0, width: width, transparent: transparent, region: region, cancellation: cancellation)
            }
        }
        if comicVector?.page != page { comicVector = nil }
        let image: CGImage
        if let native { image = try native.image(page, width: width, transparent: transparent, style: pdfStyle, cancellation: cancellation) }
        else if let source {
            do { image = try Self.imageIO(source, index: page, width: width) }
            catch {
                // ImageIO can recognize a container without decoding its image.
                // On this transition MuPDF becomes the single decoder owner.
                let value = try NativeFile(url, engine: .mupdf)
                guard page < value.count else { throw error }
                self.native = value; self.source = nil; self.storedCount = value.count
                if let dimensions = try value.imageDimensions(page) { width = min(width, max(1, Int(ceil(dimensions.width)))) }
                image = try value.image(page, width: width, transparent: transparent, cancellation: cancellation)
            }
        } else {
            let data = try data(page)
            if Format.imageEngine(names[page], prefix: data.prefix(32)) != nil {
                image = try comicNativeImage(request, data: data, cancellation: cancellation)
            } else {
                do { image = try Self.comicImage(data, width: width) }
                catch { image = try comicNativeImage(request, data: data, cancellation: cancellation) }
            }
        }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        retainImage(image, location: location, width: width, transparent: transparent, pdfStyle: pdfStyle)
        return image
    }
    func retainImage(_ image: CGImage, for request: ImageRequest) {
        if request.region == nil {
            retainImage(image, location: request.location, width: request.width,
                        transparent: request.transparent, pdfStyle: request.pdfStyle)
        }
    }
    private func retainImage(_ image: CGImage, location: PageLocation, width: Int, transparent: Bool, pdfStyle: PDFColors.Style?) {
        cache.removeAll { $0.location == location && $0.width == width && $0.transparent == transparent && $0.pdfStyle == pdfStyle }
        cache.append((location, width, transparent, pdfStyle, image))
        while cache.count > 1 && cache.reduce(0, { $0 + $1.image.bytesPerRow * $1.image.height }) > 64*1024*1024 { cache.removeFirst() }
    }
    func bounds(_ page: Int) throws -> CGRect {
        let location = try native?.location(page) ?? PageLocation(page: page)
        if let value = pageBounds[location] { return value }
        guard (0..<count).contains(page) else { throw ReadError("Page out of range") }
        let bounds: CGRect
        if let native, let size = try native.bounds(page) { bounds = size }
        else if let source, let size = Self.imageBounds(source, index: page) { bounds = size }
        else if !names.isEmpty {
            // Sumatra EngineCbx::LoadMediabox reads 1 KiB before the whole image.
            // ImageIO owns header parsing; incomplete orientation metadata must
            // fall back to the full image instead of caching unrotated bounds.
            let header = try data(page, prefixBytes: 1024)
            let source = CGImageSourceCreateIncremental(nil), complete = header.count < 1024
            CGImageSourceUpdateData(source, header as CFData, complete)
            if let value = Self.imageBounds(source, index: 0, requireOrientation: !complete) {
                pageBounds[location] = value
                return value
            }
            let data = try data(page)
            if let engine = Format.imageEngine(names[page], prefix: data.prefix(32)).flatMap(NativeEngine.init(rawValue:)),
               let value = try withComicNative(page, data: data, engine: engine, { try $0.bounds(0) }) { bounds = value }
            else if let source = CGImageSourceCreateWithData(data as CFData, nil), let value = Self.imageBounds(source, index: 0) { bounds = value }
            else if let value = try withComicNative(page, data: data, engine: .mupdf, { try $0.bounds(0) }) { bounds = value }
            else { throw ReadError("Cannot read page dimensions") }
        } else { throw ReadError("Cannot read page dimensions") }
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw ReadError("Invalid page dimensions") }
        pageBounds[location] = bounds
        return bounds
    }
    func contentBounds(_ page: Int, cancellation: NativeRenderCancellation? = nil) throws -> CGRect {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        let location = try native?.location(page) ?? PageLocation(page: page)
        if let box = contentBoxes[location] { return box }
        let box: CGRect
        if native?.engine == .mupdf, format != .image { box = try native!.contentBounds(page, cancellation: cancellation) ?? bounds(page) }
        else {
            let full = try bounds(page), bitmap = try image(prepareImage(page, width: 1024), cancellation: cancellation)
            let pixels = RasterLayout.contentBounds(bitmap)
            box = CGRect(x: full.minX + pixels.minX * full.width/CGFloat(bitmap.width),
                         y: full.minY + pixels.minY * full.height/CGFloat(bitmap.height),
                         width: pixels.width * full.width/CGFloat(bitmap.width), height: pixels.height * full.height/CGFloat(bitmap.height))
        }
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        contentBoxes[location] = box
        return box
    }
    private static func imageBounds(_ source: CGImageSource, index: Int, requireOrientation: Bool = false, physical: Bool = false) -> CGRect? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        if requireOrientation, properties[kCGImagePropertyOrientation] as? Int == nil { return nil }
        var size = CGSize(width: width, height: height)
        if physical {
            // EngineImages uses pixels for reading geometry. PDF output uses
            // the frame's physical density, without changing that UI geometry.
            let x = ReaderImages.imageDPI(properties)
            let rawY = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
            let y = rawY.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? x
            size = CGSize(width: width * 72 / x, height: height * 72 / y)
        }
        let rotated = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return CGRect(x: 0, y: 0, width: rotated ? size.height : size.width, height: rotated ? size.width : size.height)
    }
    private static func imageIO(_ source: CGImageSource, index: Int, width: Int) throws -> CGImage {
        guard let bounds = imageBounds(source, index: index), bounds.width > 0, bounds.height > 0 else { throw ReadError("Invalid image dimensions") }
        let longest = max(bounds.width, bounds.height)
        let requested = CGFloat(width) * longest / bounds.width
        let maximum = Int(min(longest, requested))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximum), kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw ReadError("ImageIO cannot decode this image") }
        return image
    }
}

private final class ComicMetadata: NSObject, XMLParserDelegate {
    private var depth = 0, text = "", values = [String: String]()
    static func read(_ data: Data) throws -> [String: String] {
        let delegate = ComicMetadata(), parser = XMLParser(data: data)
        parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw parser.parserError ?? ReadError("Cannot read ComicInfo.xml") }
        return delegate.values
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; if depth == 2 { text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if depth == 2 { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 2 {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[elementName] = value }
        }
        depth -= 1
    }
}

// Admission happens outside the decoder actor: native rendering can block that
// actor while scrolling promotes an already queued tile to visible work.
final class ReaderRenderPriority: @unchecked Sendable {
    private let lock = NSLock()
    private var visible: Bool
    private var cancelled = false
    init(visible: Bool = true) { self.visible = visible }
    func promote() { lock.lock(); visible = true; lock.unlock() }
    var isVisible: Bool { lock.lock(); defer { lock.unlock() }; return visible }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    fileprivate func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

final class ReaderRenderQueue: @unchecked Sendable {
    private struct Waiting {
        let priority: ReaderRenderPriority
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private let concurrency: Int
    private var active = 0
    private var waiting: [Waiting] = []
    init(concurrency: Int = 1) { self.concurrency = concurrency }
    var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }

    func perform<Result>(priority: ReaderRenderPriority = .init(),
                         _ operation: () async throws -> Result) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if priority.isCancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError())
                } else if active < concurrency {
                    active += 1; lock.unlock(); continuation.resume()
                } else {
                    waiting.append(Waiting(priority: priority, continuation: continuation)); lock.unlock()
                }
            }
        } onCancel: { self.cancel(priority) }
        defer { finish() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancel(_ priority: ReaderRenderPriority) {
        lock.lock(); priority.cancel()
        let index = waiting.firstIndex { $0.priority === priority }
        let continuation = index.map { waiting.remove(at: $0).continuation }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
    private func finish() {
        lock.lock()
        let continuation: CheckedContinuation<Void, Error>?
        if waiting.isEmpty { active -= 1; continuation = nil }
        else {
            let index = waiting.firstIndex { $0.priority.isVisible } ?? 0
            continuation = waiting.remove(at: index).continuation
        }
        lock.unlock()
        continuation?.resume()
    }
}

// One immutable replay may serve prediction and visible requests. Subscriber
// cancellation runs outside the decoder actor so the last reader can interrupt
// native interpretation/replay even while that actor is occupied.
fileprivate final class ReaderImageRender: @unchecked Sendable {
    let request: RasterDocument.ImageRequest
    let revision: Int
    let cancellation: NativeRenderCancellation?
    var task: Task<CGImage, Error>!
    private let lock = NSLock()
    private var subscribers: Set<UUID>
    init(_ request: RasterDocument.ImageRequest, revision: Int, subscriber: UUID, cancellation: NativeRenderCancellation?) {
        self.request = request; self.revision = revision; self.cancellation = cancellation
        subscribers = [subscriber]
    }
    func matches(_ other: RasterDocument.ImageRequest, revision: Int) -> Bool {
        self.revision == revision && request.location == other.location && request.width == other.width
            && request.transparent == other.transparent && request.region == other.region && request.pdfStyle == other.pdfStyle
    }
    func subscribe(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !subscribers.isEmpty else { return false }
        subscribers.insert(id); return true
    }
    func release(_ id: UUID) {
        lock.lock()
        let cancel = subscribers.remove(id) != nil && subscribers.isEmpty
        lock.unlock()
        if cancel { cancellation?.cancel() }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return subscribers.isEmpty }
}

actor Pages {
    struct MarkdownPrintSnapshot: Sendable {
        let count: Int
        let layoutRevision: Int
        let sourceSignature: String
    }

    nonisolated let isPDF: Bool
    nonisolated let isMarkdown: Bool
    // The decoder input never retargets. UI save capabilities can inspect this
    // immutable URL without entering the actor or inferring type from a suffix.
    nonisolated let pdfSourceURL: URL
    nonisolated let isImageCollection: Bool
    private let document: RasterDocument
    private var imageRenders: [ReaderImageRender] = []
    nonisolated private let renderQueue: ReaderRenderQueue
    private let markdownOpenedSourceSignature: String?
    private let externalOutline: [ContentsItem]?
    private var pdfSavedSourceCheckpoint: NativeFile.FileCheckpoint?
    private var zoomLimitCache: (rotation: Int, revision: Int, count: Int, measured: Int, maximum: Double, uniform: Bool, value: Double)?
    private var currentLocation = PageLocation(page: 0)
    private var savedPosition = ReadingPosition()
    private var currentPage: Int { document.native?.chapterTable?.page(for: currentLocation) ?? currentLocation.page }
    var layoutPosition: ReadingPosition {
        var position = savedPosition; position.page = currentPage
        if let table = document.native?.chapterTable, document.native?.reflowable == true { position.anchor = table.bookmark(currentLocation) }
        return position
    }
    private let layoutEvents: AsyncStream<ChapterTable>
    private let layoutContinuation: AsyncStream<ChapterTable>.Continuation
    private(set) var layoutRevision = 0
    var count: Int { document.count }
    var hasText: Bool { document.native?.hasText == true }
    init(_ url: URL, format: Format, archive: Archive? = nil, outline: [ContentsItem]? = nil, password: String? = nil, deferReflowLayout: Bool = false) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        pdfSourceURL = url
        isPDF = format == .pdf
        renderQueue = ReaderRenderQueue(concurrency: isPDF || format == .comic && !url.hasDirectoryPath
                                        ? ProcessInfo.processInfo.activeProcessorCount : 1)
        isMarkdown = format == .markdown
        markdownOpenedSourceSignature = format == .markdown ? NativeFile.FileVersion(url)?.signature : nil
        let checkpoint = format == .pdf ? try NativeFile.FileCheckpoint(url) : nil
        document = try RasterDocument(url, format: format, archive: archive, password: password, deferReflowLayout: deferReflowLayout, sourceCheckpoint: checkpoint); externalOutline = outline
        pdfSavedSourceCheckpoint = try checkpoint?.matches(url) == true ? checkpoint : nil
        isImageCollection = document.isImageCollection
        var continuation: AsyncStream<ChapterTable>.Continuation!
        layoutEvents = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        layoutContinuation = continuation
        let sink = layoutContinuation
        document.native?.layoutChanged = { sink.yield($0) }
        NativeReadingPerformance.mark("native-open-return", pages: self, started: started)
    }
    deinit { layoutContinuation.finish() }
    var chapterLayout: ChapterTable { document.native?.chapterTable ?? ChapterTable(pages: document.count) }
    var hasChapters: Bool { document.native?.hasChapters == true }
    func layouts() -> AsyncStream<ChapterTable> { layoutEvents }
    func warmChapter(_ chapter: Int) throws { _ = try document.native?.warmChapter(chapter) }
    func publishWarmedChapters() throws { try document.native?.publishWarmedChapters() }
    @discardableResult func ensureFullLayout() throws -> ChapterTable {
        try document.native?.publishWarmedChapters()
        return chapterLayout
    }
    private func index(_ location: PageLocation) throws -> Int { try document.native?.page(location) ?? location.page }
    func position(_ location: PageLocation, x: Double? = nil, y: Double? = nil, passage: NativePassage? = nil, viewport: CGSize? = nil) throws -> ReadingPosition {
        try position(page: index(location), x: x, y: y, passage: passage, viewport: viewport)
    }
    func prepareFacingPages(_ position: ReadingPosition, cover: Bool) throws -> ReadingPosition {
        guard document.native?.reflowable == true else { return position }
        let location = position.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }
            ?? chapterLayout.location(page: position.page) ?? PageLocation(page: position.page)
        _ = try index(location)
        // A lazy predecessor is represented by one provisional page. Count it
        // before choosing the row, so crossing backward selects its last page
        // and its real count determines which side owns the current page.
        if location.page == 0, location.chapter > 0 {
            try document.native?.ensureChapter(location.chapter - 1)
        }
        let table = chapterLayout
        let page = try index(location)
        let row = PageRows.range(page: page, count: table.totalPages, spread: true, cover: cover)
        if let last = table.location(page: row.upperBound - 1), last.chapter > location.chapter {
            try document.native?.ensureChapter(last.chapter)
        }
        var position = position
        position.page = try index(location)
        position.anchor = chapterLayout.bookmark(location)
        return position
    }
    func capturePassage(_ position: ReadingPosition, theme: String, userCSS: String, region: CGRect? = nil) throws -> NativePassage? {
        guard document.native?.reflowable == true, let current = document.style else { return nil }
        let expected = RasterStyle(fontSize: position.fontSize ?? current.fontSize,
            lineHeight: position.lineHeight ?? current.lineHeight, margin: position.margin ?? current.margin,
            font: position.font ?? current.font, theme: theme, userCSS: userCSS,
            useDocumentCSS: position.useDocumentCSS ?? current.useDocumentCSS,
            pageMargins: position.pageMargins ?? current.pageMargins, textZoom: isMarkdown ? position.zoom ?? current.textZoom : 1, pageSize: current.pageSize)
        guard expected == current else { return nil }
        let page = try position.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }.map(index) ?? position.page
        return try document.native?.passage(page, at: CGPoint(x: position.x ?? 0, y: position.y ?? 0), in: region)
    }
    func bounds(_ location: PageLocation) throws -> CGRect { try bounds(index(location)) }
    func contentBounds(_ location: PageLocation) async throws -> CGRect { try await contentBounds(index(location)) }
    func text(_ location: PageLocation) throws -> String { try text(index(location)) }
    func words(_ location: PageLocation) throws -> [RasterWord] { try words(index(location)) }
    func imageBounds(_ location: PageLocation) throws -> [CGRect] { try imageBounds(index(location)) }
    nonisolated func image(_ location: PageLocation, width: Int, transparent: Bool = false, region: CGRect? = nil, pdfStyle: PDFColors.Style? = nil,
                           priority: ReaderRenderPriority = .init()) async throws -> CGImage {
        try await renderQueue.perform(priority: priority) {
            try await self.renderImage(location, width: width, transparent: transparent, region: region, pdfStyle: pdfStyle, priority: priority)
        }
    }
    private func renderImage(_ location: PageLocation, width: Int, transparent: Bool, region: CGRect?, pdfStyle: PDFColors.Style?, priority: ReaderRenderPriority) async throws -> CGImage {
        let request = try document.prepareImage(index(location), width: width, transparent: transparent, region: region, pdfStyle: pdfStyle)
        return try await image(request, priority: priority)
    }
    func embeddedImage(_ location: PageLocation, at point: CGPoint) throws -> Data? { try embeddedImage(index(location), at: point) }
    func selection(_ location: PageLocation, range: NSRange) throws -> RasterSelection { try selection(index(location), range: range) }
    func speechFragment(_ location: PageLocation, visible: CGRect?, offset: Int? = nil, point: CGPoint? = nil) throws -> (text: String, offset: Int) {
        try speechFragment(index(location), visible: visible, offset: offset, point: point)
    }
    func advance(_ location: PageLocation, by distance: Int) throws -> ReadingPosition {
        var location = location
        for _ in 0..<abs(distance) {
            _ = try index(location)
            let table = chapterLayout
            if distance > 0 {
                if location.page + 1 < table.pageCount(location.chapter) { location = .init(chapter: location.chapter, page: location.page + 1) }
                else if location.chapter + 1 < table.chapterCount { location = .init(chapter: location.chapter + 1, page: 0) }
            } else if location.page > 0 { location = .init(chapter: location.chapter, page: location.page - 1) }
            else if location.chapter > 0 {
                try document.native?.ensureChapter(location.chapter - 1)
                location = .init(chapter: location.chapter - 1, page: chapterLayout.pageCount(location.chapter - 1) - 1)
            }
        }
        return try position(location)
    }
    func readablePage(from location: PageLocation, advance: Bool) throws -> (position: ReadingPosition, text: String)? {
        var location = location
        if advance {
            let next = try self.advance(location, by: 1)
            let value = next.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? PageLocation(page: next.page)
            guard value != location else { return nil }
            location = value
        }
        while true {
            try Task.checkCancellation()
            let text = try self.text(location)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (try position(location), text) }
            let next = try self.advance(location, by: 1)
            let value = next.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? PageLocation(page: next.page)
            guard value != location else { return nil }
            location = value
        }
    }
    func lastPosition() throws -> ReadingPosition {
        let chapter = chapterLayout.chapterCount - 1
        try document.native?.ensureChapter(chapter)
        return try position(.init(chapter: chapter, page: chapterLayout.pageCount(chapter) - 1))
    }
    private func renderCancellation(_ page: Int) throws -> NativeRenderCancellation? {
        try Task.checkCancellation()
        let vector = (0..<document.count).contains(page) && document.isVectorImage(page)
        return document.native?.engine == .mupdf || vector ? try NativeRenderCancellation() : nil
    }
    nonisolated func image(_ page: Int, width: Int, transparent: Bool = false, region: CGRect? = nil, pdfStyle: PDFColors.Style? = nil) async throws -> CGImage {
        try await renderQueue.perform {
            try await self.renderImage(page, width: width, transparent: transparent, region: region, pdfStyle: pdfStyle)
        }
    }
    private func renderImage(_ page: Int, width: Int, transparent: Bool, region: CGRect?, pdfStyle: PDFColors.Style?) async throws -> CGImage {
        let request = try document.prepareImage(page, width: width, transparent: transparent, region: region, pdfStyle: pdfStyle)
        return try await image(request)
    }
    private func image(_ request: RasterDocument.ImageRequest, cancellation supplied: NativeRenderCancellation? = nil,
                       priority: ReaderRenderPriority = .init()) async throws -> CGImage {
        try Task.checkCancellation()
        if let image = request.cached { return image }
        if isPDF || document.concurrentComicImage(request) {
            let subscriber = UUID()
            let render: ReaderImageRender
            if let current = imageRenders.first(where: { $0.matches(request, revision: layoutRevision) && $0.subscribe(subscriber) }) {
                render = current
            } else {
                render = ReaderImageRender(request, revision: layoutRevision, subscriber: subscriber,
                                           cancellation: isPDF ? try NativeRenderCancellation() : nil)
                imageRenders.append(render)
            }
            return try await withTaskCancellationHandler {
                defer { render.release(subscriber) }
                if render.task == nil {
                    do {
                        try Task.checkCancellation()
                        // Freeze the display list or finish the current archive
                        // entry before another actor operation can advance it.
                        let snapshot = isPDF ? try document.native?.preparePDFRender(request.page,
                            style: request.pdfStyle, cancellation: render.cancellation) : nil
                        let data = isPDF ? Data() : try document.comicImageData(request)
                        render.task = Task { try await self.renderImage(render, snapshot: snapshot, data: data, priority: priority) }
                    } catch {
                        imageRenders.removeAll { $0 === render }
                        throw error
                    }
                }
                let image = try await render.task.value
                try Task.checkCancellation()
                if supplied?.isCancelled == true { throw CancellationError() }
                return image
            } onCancel: { render.release(subscriber) }
        }
        let cancellation = try supplied ?? renderCancellation(request.page)
        return try await withTaskCancellationHandler {
            return try document.image(request, cancellation: cancellation)
        } onCancel: { cancellation?.cancel() }
    }
    private func renderImage(_ render: ReaderImageRender, snapshot: NativePDFRenderSnapshot?, data: Data,
                             priority: ReaderRenderPriority) async throws -> CGImage {
        defer { imageRenders.removeAll { $0 === render } }
        guard !render.isCancelled else { throw CancellationError() }
        let request = render.request
        let image: CGImage
        if let snapshot {
            image = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: priority.isVisible ? .userInitiated : .utility).async {
                    do { continuation.resume(returning: try snapshot.image(width: request.width, transparent: request.transparent, region: request.region)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } else {
            // Archive extraction remains serialized. Only immutable entry bytes
            // cross to the worker, which creates its own ImageIO source.
            if Format.imageEngine(document.names[request.page], prefix: data.prefix(32)) != nil {
                image = try document.comicNativeImage(request, data: data, cancellation: nil)
            } else {
                do {
                    image = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: priority.isVisible ? .userInitiated : .utility).async {
                            do { continuation.resume(returning: try RasterDocument.comicImage(data, width: request.width)) }
                            catch { continuation.resume(throwing: error) }
                        }
                    }
                } catch {
                    guard !render.isCancelled else { throw CancellationError() }
                    image = try document.comicNativeImage(request, data: data, cancellation: nil)
                }
            }
        }
        guard !render.isCancelled, render.revision == layoutRevision else { throw CancellationError() }
        document.retainImage(image, for: request)
        return image
    }
    func originalData(_ page: Int) throws -> (data: Data, filename: String) { try document.originalData(page) }
    func editableImage(_ page: Int) throws -> (image: CGImage, original: (data: Data, filename: String)?, dpi: Double) {
        guard try !isPDF || pdfNative().pdfInfo()?.permissions.copy == true else { throw ReadError("This PDF does not allow copying images") }
        return try document.editableImage(page)
    }
    func metadata() throws -> [String: String] { try document.metadata() }
    func pdfInfo() throws -> PDFDocumentInfo? { try document.native?.pdfInfo() }
    func pdfInformation() throws -> [String: String] { try pdfNative().pdfInformation() }
    func pdfResourceReport() throws -> String { try pdfNative().pdfResourceReport() }
    func pdfSignatureInfo() throws -> PDFSignatureInfo { try pdfNative().pdfSignatureInfo() }
    func pdfSignCopy(to destination: URL, password: String, identity: NativePDFTools.SigningIdentity,
                     fieldName: String, page: Int, bounds: CGRect, reason: String = "", location: String = "",
                     image: URL? = nil, appearance: PDFSignatureAppearance = .standard) throws {
        try pdfNative().pdfSignCopy(to: destination, sourceURL: document.url, password: password,
            identity: identity, fieldName: fieldName, page: page, bounds: bounds,
            reason: reason, location: location, image: image, appearance: appearance)
    }
    // PrintData owns an independent engine. Keep unsaved edits and the opened
    // source version through a snapshot only when reopening cannot represent it.
    func preparePDFPrint(to snapshot: URL, password: String) throws -> (file: NativeFile, preferences: PDFDocumentInfo.ViewerPreferences) {
        try Task.checkCancellation()
        let native = try pdfNative()
        try native.validatePDFSource()
        guard let info = try native.pdfInfo() else { throw ReadError("Document is not a PDF") }
        guard info.permissions.print else { throw ReadError("This PDF does not allow printing") }
        let copy: NativeFile
        if let reopened = try native.reopenPDF(password: password, info: info) { copy = reopened }
        else {
            try NativePDFTools.validateDestination(source: document.url, destination: snapshot)
            try native.pdfWrite(to: snapshot)
            copy = try NativeFile(snapshot, engine: .mupdf, password: password)
        }
        try Task.checkCancellation()
        return (copy, info.viewerPreferences)
    }
    func prepareMarkdownPrint() throws -> MarkdownPrintSnapshot {
        guard isMarkdown else { throw ReadError("Document is not Markdown") }
        _ = try ensureFullLayout()
        guard document.count > 0, let sourceSignature = markdownOpenedSourceSignature,
              NativeFile.FileVersion(document.url)?.signature == sourceSignature else {
            throw ReadError("Cannot verify the Markdown source for printing")
        }
        return MarkdownPrintSnapshot(count: document.count, layoutRevision: layoutRevision,
                                     sourceSignature: sourceSignature)
    }
    func markdownPrintPage(_ page: Int, snapshot: MarkdownPrintSnapshot) throws -> Data {
        try Task.checkCancellation()
        try validateMarkdownPrint(snapshot, page: page)
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let output = temporary.url.appendingPathComponent("Page.pdf")
        try exportPDF(to: output, selectedPages: [page])
        try validateMarkdownPrint(snapshot, page: page)
        let bytes = try Data(contentsOf: output)
        try validateMarkdownPrint(snapshot, page: page)
        return bytes
    }
    private func validateMarkdownPrint(_ snapshot: MarkdownPrintSnapshot, page: Int) throws {
        guard isMarkdown, layoutRevision == snapshot.layoutRevision, document.count == snapshot.count,
              (0..<snapshot.count).contains(page) else {
            throw ReadError("The Markdown layout changed while printing. Print it again.")
        }
        guard NativeFile.FileVersion(document.url)?.signature == snapshot.sourceSignature else {
            throw ReadError("The Markdown source changed while printing. Open it again.")
        }
    }
    private var pdfAnnotationsVisible = true

    func pdfExportText(_ indices: [Int], to destination: URL) throws {
        let native = try pdfNative()
        guard destination.isFileURL else { throw ReadError("Choose a local output file") }
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard try native.pdfInfo()?.permissions.copy == true else { throw ReadError("This PDF does not allow text extraction") }
        guard !indices.isEmpty, indices.allSatisfy({ (0..<native.count).contains($0) }) else { throw ReadError("Invalid page selection") }
        guard !PDFTools.sameFile(destination, document.url) else { throw ReadError("Choose a different file for tool output") }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Sumra-text-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw ReadError("Cannot create text output") }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            for (offset, page) in indices.enumerated() {
                try Task.checkCancellation()
                if offset > 0 { try output.write(contentsOf: Data("\n\u{000C}\n".utf8)) }
                try autoreleasepool { try output.write(contentsOf: Data((try native.text(page) ?? "").utf8)) }
            }
            try output.close()
        } catch { try? output.close(); throw error }
        try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func pdfOutline() throws -> [PDFTools.OutlineEntry] {
        let native = try pdfNative()
        return try native.outline().map { item in
            let destination = item.target.isEmpty ? nil : try native.pdfResolveDestination(item.target, pdfCoordinates: true)
            let url = item.target.lowercased().hasPrefix("file:")
                ? NativePDFActions.fileTarget(item.target, relativeTo: document.url)?.url.absoluteString
                : (!item.target.isEmpty && !item.target.hasPrefix("#") ? item.target : nil)
            return .init(title: item.title, depth: item.depth, page: destination?.page ?? item.page,
                x: destination?.x, y: destination?.y, zoom: destination?.zoom, url: url)
        }
    }

    func pdfRenderedImage(page: Int, dpi: Double, type: NSBitmapImageRep.FileType, rotation: Int) async throws -> Data {
        let native = try pdfNative()
        guard try native.pdfInfo()?.permissions.copy == true else { throw ReadError("This PDF does not allow image extraction") }
        guard dpi.isFinite, dpi > 0 else { throw ReadError("DPI must be positive") }
        guard [.png, .jpeg, .tiff, .bmp].contains(type) else { throw ReadError("Choose PNG, JPEG, TIFF or BMP") }
        guard (0..<native.count).contains(page), let bounds = try native.bounds(page) else { throw ReadError("Invalid page selection") }
        let width = ceil(bounds.width * dpi / 72)
        let height = ceil(bounds.height * width / bounds.width)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(Int32.max), height <= CGFloat(Int32.max) else { throw ReadError("Page bitmap is too large") }
        // Native regions are output pixels after subtracting the page origin,
        // not Fitz page coordinates. A full region retains the exact export size.
        let region = CGRect(x: 0, y: 0, width: width, height: height)
        let cancellation = try NativeRenderCancellation()
        return try await withTaskCancellationHandler {
            // ConvertPagesToImages includes annotations independently of the
            // viewer's Show Annotations setting. Restore it in this actor turn.
            try native.pdfSetAnnotationsVisible(true)
            let result = Result<Data, Error> {
                let image = try native.image(page, width: Int(width), region: region, cancellation: cancellation)
                let rotated = try RasterLayout.image(image, bounds: bounds, crop: nil, rotation: rotation)
                return try ReaderImages.encoded(rotated, type: type, dpi: dpi)
            }
            try native.pdfSetAnnotationsVisible(pdfAnnotationsVisible)
            return try result.get()
        } onCancel: { cancellation.cancel() }
    }
    func pdfXMP() throws -> Data? { try pdfNative().pdfXMP() }
    func pdfAttachments() throws -> [PDFTools.Attachment] { try pdfNative().pdfAttachments() }
    func pdfPageBoxes(_ page: Int) throws -> [CGRect?] { try pdfNative().pdfPageBoxes(page) }
    func pdfPageLabel(_ page: Int) throws -> String {
        guard let native = document.native else { throw ReadError("Document is not a PDF") }
        return try native.pdfPageLabel(page)
    }
    private func pdfNative() throws -> NativeFile {
        guard let native = document.native, native.engine == .mupdf else { throw ReadError("Document is not a PDF") }
        return native
    }
    private func mutatePDF<T>(_ action: (NativeFile) throws -> T) throws -> T {
        let native = try pdfNative()
        defer { document.invalidatePDFCaches(); layoutRevision += 1 }
        return try action(native)
    }
    func pdfAnnotations(_ page: Int) throws -> [PDFAnnotationSnapshot] { try pdfNative().pdfAnnotations(page) }
    func pdfLinks(_ page: Int) throws -> [PDFLinkSnapshot] { try pdfNative().pdfLinks(page) }
    func pdfJavaScriptMenu(_ script: String) throws -> [String] { try pdfNative().pdfJavaScriptMenu(script) }
    func pdfAttachment(page: Int, id: Int32) throws -> PDFTools.Attachment { try pdfNative().pdfAttachment(page: page, id: id) }
    func pdfSetEditing(_ enabled: Bool) throws { try pdfNative().pdfSetEditing(enabled) }
    func pdfSetAnnotationsVisible(_ visible: Bool) throws {
        try pdfNative().pdfSetAnnotationsVisible(visible)
        pdfAnnotationsVisible = visible
        document.invalidatePDFCaches(); layoutRevision += 1
    }
    func pdfUndo(redo: Bool = false) throws { try mutatePDF { try $0.pdfUndo(redo: redo) } }
    func pdfCreateAnnotation(page: Int, type: String, bounds: CGRect, edits: [PDFAnnotationEdit] = []) throws -> Int32 {
        try mutatePDF { try $0.pdfCreateAnnotation(page: page, type: type, bounds: bounds, edits: edits) }
    }
    func pdfCreateAnnotations(_ items: [PDFAnnotationCreation]) throws -> [Int32] {
        try mutatePDF { try $0.pdfCreateAnnotations(items) }
    }
    func pdfCreateLink(page: Int, bounds: CGRect, uri: String) throws -> Int32 {
        try mutatePDF { try $0.pdfCreateLink(page: page, bounds: bounds, uri: uri) }
    }
    func pdfEditLink(page: Int, id: Int32, bounds: CGRect, uri: String?) throws {
        try mutatePDF { try $0.pdfEditLink(page: page, id: id, bounds: bounds, uri: uri) }
    }
    func pdfDeleteLink(page: Int, id: Int32) throws { try mutatePDF { try $0.pdfDeleteLink(page: page, id: id) } }
    func pdfStampImage(page: Int, id: Int32) throws -> Data? { try pdfNative().pdfStampImage(page: page, id: id) }
    private func unchangedCutAnnotation(_ native: NativeFile, page: Int, expected: PDFAnnotationSnapshot, stampImage: URL?) throws -> Bool {
        guard let current = try native.pdfAnnotations(page).first(where: { $0.id == expected.id }),
              current == expected, NativePDFAnnotations.editable(current) else { return false }
        // The value snapshot does not include Stamp appearance resources.
        // Compare nil too: a standard stamp can acquire bitmap artwork later.
        guard expected.type == "Stamp" else { return true }
        return try native.pdfStampImage(page: page, id: expected.id) == stampImage.map { try Data(contentsOf: $0) }
    }
    func pdfPasteAnnotation(_ item: PDFAnnotationCreation,
                            removing: (page: Int, annotation: PDFAnnotationSnapshot, stampImage: URL?)? = nil) throws -> (id: Int32, removedSource: Bool) {
        let native = try pdfNative()
        var cut: (page: Int, id: Int32)?
        if let removing, try unchangedCutAnnotation(native, page: removing.page, expected: removing.annotation, stampImage: removing.stampImage) {
            cut = (removing.page, removing.annotation.id)
        }
        // The comparison and journal transaction share this actor turn.
        let id = try mutatePDF { try $0.pdfPasteAnnotation(item, removing: cut) }
        return (id, cut != nil)
    }
    func pdfDeleteAnnotation(page: Int, matching expected: PDFAnnotationSnapshot, stampImage: URL?) throws -> Bool {
        guard try unchangedCutAnnotation(pdfNative(), page: page, expected: expected, stampImage: stampImage) else { return false }
        try mutatePDF { try $0.pdfDeleteAnnotation(page: page, id: expected.id) }
        return true
    }
    func pdfEraseInk(page: Int, points: [CGPoint], radius: CGFloat) throws -> Bool {
        let native = try pdfNative()
        // Read live strokes here: a second fast gesture must not restore strokes
        // already removed by an earlier edit whose bitmap is still rendering.
        let edits = try native.pdfAnnotations(page).compactMap { annotation -> PDFInkEdit? in
            guard annotation.type == "Ink", annotation.flags & 35 == 0, NativePDFAnnotations.editable(annotation) else { return nil }
            let strokes = annotation.ink.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
            let kept = strokes.filter { stroke in
                !points.contains { NativePDFAnnotations.strokeHit(stroke, point: $0, radius: radius + CGFloat(annotation.borderWidth) / 2) }
            }
            return kept.count == strokes.count ? nil : PDFInkEdit(id: annotation.id, strokes: kept)
        }
        if !edits.isEmpty { try mutatePDF { try $0.pdfEraseInk(page: page, edits: edits) } }
        return !edits.isEmpty
    }
    func pdfEditAnnotation(page: Int, id: Int32, edits: [PDFAnnotationEdit]) throws {
        try mutatePDF { try $0.pdfEditAnnotation(page: page, id: id, edits: edits) }
    }
    func pdfDeleteAnnotation(page: Int, id: Int32) throws { try mutatePDF { try $0.pdfDeleteAnnotation(page: page, id: id) } }
    func pdfSetWidgetValue(page: Int, id: Int32, value: String) throws {
        try mutatePDF { try $0.pdfSetWidgetValue(page: page, id: id, value: value) }
    }
    func pdfToggleWidget(page: Int, id: Int32) throws { try mutatePDF { try $0.pdfToggleWidget(page: page, id: id) } }
    func pdfSave(to destination: URL) throws {
        // Ordinary Save updates the opened file through its alias, keeping the
        // symlink and placing the atomic replacement beside the actual target.
        try writePDF(to: destination.resolvingSymlinksInPath(), markSaved: true)
    }
    func pdfSaveCopy(to destination: URL) throws {
        guard !PDFTools.sameFile(destination, document.url) else { throw ReadError("Choose a different location for Save a Copy.") }
        try writePDF(to: destination, markSaved: false)
    }
    private func writePDF(to destination: URL, markSaved: Bool) throws {
        try Task.checkCancellation()
        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            throw ReadError("Choose a file location, not a directory")
        }
        let native = try pdfNative()
        let files = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Sumra-save-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        // Reuse the upstream writer on the live document. Incremental snapshots
        // retain its input baseline; repaired/redacted PDFs require a full write.
        try native.pdfWrite(to: temporary)
        try Task.checkCancellation()
        let written = markSaved ? try NativeFile.FileCheckpoint(temporary) : nil
        // The retained MuPDF stream can still supply a copy after replacement.
        // Ordinary Save may replace only the last disk version that we own.
        if markSaved {
            guard let expected = pdfSavedSourceCheckpoint, try expected.matches(destination), written != nil else {
                throw ReadError("The PDF file changed outside Sumra. Reload it or save a copy to preserve your edits.")
            }
        }
        try Task.checkCancellation()
        if files.fileExists(atPath: destination.path) { _ = try files.replaceItemAt(destination, withItemAt: temporary) }
        else { try files.moveItem(at: temporary, to: destination) }
        if markSaved {
            pdfSavedSourceCheckpoint = nil
            guard let written, let version = NativeFile.FileVersion(destination), written.version.matchesContentMetadata(version) else {
                throw ReadError("The PDF was written, but its file version could not be verified. Save a copy to preserve the open edits.")
            }
            pdfSavedSourceCheckpoint = NativeFile.FileCheckpoint(version: version, digest: written.digest)
            try native.pdfMarkSaved()
        }
    }
    func pdfPageGeometry(_ page: Int) throws -> (transform: CGAffineTransform, mediaBox: CGRect) { try pdfNative().pdfPageGeometry(page) }
    func pdfPageForLabel(_ label: String) throws -> Int? {
        let native = try pdfNative()
        guard try native.pdfInfo()?.hasPageLabels == true else { return nil }
        for page in 0..<native.count {
            try Task.checkCancellation()
            if try native.pdfPageLabel(page) == label { return page }
        }
        return nil
    }
    func pdfInitialPage() throws -> Int? { try pdfNative().pdfInitialPage() }
    func pdfTextLines(_ page: Int) throws -> [RasterWord] { try pdfNative().pdfTextLines(page) }
    func preferredLayout() throws -> ReadingPosition {
        if isPDF, let info = try pdfInfo() {
            let direction = info.viewerPreferences.direction
            return ReadingPosition(flow: "continuous", spread: info.layout?.hasPrefix("Two") == true,
                rtl: direction == "L2R" || direction == "R2L" ? direction == "R2L" : nil,
                cover: info.layout?.hasSuffix("Right") == true)
        }
        let direction = try document.native?.metadata()["ReadingDirection"]
        let rtl = direction.map { $0 == "rtl" }
        return ReadingPosition(spread: rtl == true, rtl: rtl, cover: rtl == true)
    }
    func landscapePages(rotation: Int) throws -> Set<Int> {
        guard document.isImageCollection else { return [] }
        var result = Set<Int>()
        for (index, bounds) in document.pageBounds {
            try Task.checkCancellation()
            if rotation % 180 == 0 ? bounds.width > bounds.height : bounds.height > bounds.width { result.insert(index.page) }
        }
        return result
    }
    func seedImageBounds(page: Int, uniform: Bool) throws {
        guard document.isImageCollection else { return }
        if uniform { _ = try document.bounds(0) }
        // Include the preceding page so a restored facing row cannot pair a
        // portrait with a newly discovered landscape page.
        for index in max(0, page - 1)..<min(document.count, page + 4) {
            try Task.checkCancellation()
            _ = try document.bounds(index)
        }
    }
    func estimatedBounds() -> CGRect { document.estimatedBounds }
    func htmlSource() throws -> String? { try document.native?.htmlSource() }
    func bounds(_ page: Int) throws -> CGRect { try document.bounds(page) }
    func contentBounds(_ page: Int) async throws -> CGRect {
        let cancellation = try renderCancellation(page)
        return try await withTaskCancellationHandler {
            try document.contentBounds(page, cancellation: cancellation)
        } onCancel: { cancellation?.cancel() }
    }
    typealias RenderedPage = (bounds: CGRect, content: CGRect?, referenceWidth: CGFloat?,
        facing: RasterLayout.FacingPage?, display: CGSize, image: CGImage?, pixelWidth: Int, tileResolution: Int,
        links: [RasterLink], imageCollection: Bool, landscape: Set<Int>, limit: Double, estimate: CGRect, pdfStyle: PDFColors.Style?)
    nonisolated func render(_ location: PageLocation, viewport: CGSize, scale: CGFloat, columns: Int, rotation: Int,
                fit: String, zoom: Double, maximumZoom: Double = ReadingZoom.maximum,
                trim: Bool = false, showContent: Bool = false, uniform: Bool = false,
                transparent: Bool = false, pdfStyle: PDFColors.Style? = nil, engineeringAuto: Bool = false,
                maximumTileSize: CGSize? = nil, facingPage: Int? = nil, displaySize: CGSize? = nil, rtl: Bool = false, viewportOnly: Bool = false, preheating: Bool = false) async throws -> RenderedPage {
        try await renderQueue.perform(priority: .init(visible: !preheating)) {
            try await self.renderPage(location, viewport: viewport, scale: scale, columns: columns, rotation: rotation,
                fit: fit, zoom: zoom, maximumZoom: maximumZoom, trim: trim, showContent: showContent,
                uniform: uniform, transparent: transparent, pdfStyle: pdfStyle, engineeringAuto: engineeringAuto,
                maximumTileSize: maximumTileSize, facingPage: facingPage, displaySize: displaySize, rtl: rtl,
                viewportOnly: viewportOnly, preheating: preheating)
        }
    }
    private func renderPage(_ location: PageLocation, viewport: CGSize, scale: CGFloat, columns: Int, rotation: Int,
                fit: String, zoom: Double, maximumZoom: Double = ReadingZoom.maximum,
                trim: Bool = false, showContent: Bool = false, uniform: Bool = false,
                transparent: Bool = false, pdfStyle: PDFColors.Style? = nil, engineeringAuto: Bool = false,
                maximumTileSize: CGSize? = nil, facingPage: Int? = nil, displaySize: CGSize? = nil, rtl: Bool = false, viewportOnly: Bool = false, preheating: Bool = false) async throws -> RenderedPage {
        try Task.checkCancellation()
        // This location request belongs to a mounted reader surface. Native
        // reflow can finish before that surface is replaced, leaving its
        // queued finite render pointing at the new natural chapter.
        if document.native?.reflowable == true, let style = document.style,
           viewportOnly != (style.pageSize.height == 0) {
            NativeReadingPerformance.mark("render-superseded", pages: self, revision: layoutRevision, page: location.page)
            throw CancellationError()
        }
        // The reference chapter must be prepared before projecting this request.
        if uniform { _ = try document.bounds(0) }
        return try await renderPage(index(location), viewport: viewport, scale: scale, columns: columns, rotation: rotation,
            fit: fit, zoom: zoom, maximumZoom: maximumZoom, trim: trim, showContent: showContent,
            uniform: uniform, transparent: transparent, pdfStyle: pdfStyle, engineeringAuto: engineeringAuto, maximumTileSize: maximumTileSize, facingPage: facingPage, displaySize: displaySize, rtl: rtl, viewportOnly: viewportOnly, preheating: preheating)
    }
    nonisolated func render(_ page: Int, viewport: CGSize, scale: CGFloat, columns: Int, rotation: Int,
                fit: String, zoom: Double, maximumZoom: Double = ReadingZoom.maximum,
                trim: Bool = false, showContent: Bool = false, uniform: Bool = false,
                transparent: Bool = false, pdfStyle: PDFColors.Style? = nil, engineeringAuto: Bool = false,
                maximumTileSize: CGSize? = nil, facingPage: Int? = nil, displaySize: CGSize? = nil, rtl: Bool = false, viewportOnly: Bool = false, preheating: Bool = false) async throws -> RenderedPage {
        try await renderQueue.perform(priority: .init(visible: !preheating)) {
            try await self.renderPage(page, viewport: viewport, scale: scale, columns: columns, rotation: rotation,
                fit: fit, zoom: zoom, maximumZoom: maximumZoom, trim: trim, showContent: showContent,
                uniform: uniform, transparent: transparent, pdfStyle: pdfStyle, engineeringAuto: engineeringAuto,
                maximumTileSize: maximumTileSize, facingPage: facingPage, displaySize: displaySize, rtl: rtl,
                viewportOnly: viewportOnly, preheating: preheating)
        }
    }
    private func renderPage(_ page: Int, viewport: CGSize, scale: CGFloat, columns: Int, rotation: Int,
                fit: String, zoom: Double, maximumZoom: Double = ReadingZoom.maximum,
                trim: Bool = false, showContent: Bool = false, uniform: Bool = false,
                transparent: Bool = false, pdfStyle: PDFColors.Style? = nil, engineeringAuto: Bool = false,
                maximumTileSize: CGSize? = nil, facingPage: Int? = nil, displaySize: CGSize? = nil, rtl: Bool = false, viewportOnly: Bool = false, preheating: Bool = false) async throws -> RenderedPage {
        let started = DispatchTime.now().uptimeNanoseconds
        NativeReadingPerformance.mark("render-actor-entry", pages: self, revision: layoutRevision, page: page,
                                      size: viewport, flags: viewportOnly ? 8 : 0)
        defer { NativeReadingPerformance.mark("render-actor-return", pages: self, revision: layoutRevision, page: page, started: started) }
        let measureContent = (!viewportOnly && ReadingZoom.usesContent(fit)) || trim || showContent
        let measureFacingContent = ReadingZoom.usesContent(fit) || trim
        let cancellation = measureContent || facingPage != nil && measureFacingContent
            || isPDF && (engineeringAuto || pdfStyle?.engineering == true)
            ? try renderCancellation(page) : nil
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // Keep a solid archive's current entry alive from header measurement
            // through decoding. No other page can interleave an actor call here.
            // Read the uniform-width reference first, before opening this entry.
            let reference = uniform ? try document.bounds(0) : nil
            let measured = try document.bounds(page)
            let rotated = rotation % 180 != 0
            let referenceWidth = reference.map { rotated ? $0.height : $0.width }
            let facing = try facingPage.map { other in
                let bounds = try document.bounds(other)
                let content = measureFacingContent ? try document.contentBounds(other, cancellation: cancellation) : nil
                return RasterLayout.FacingPage(bounds: trim ? content ?? bounds : bounds, content: content, before: other < page)
            }
            // Leave this page's display list current for the render below.
            let content = measureContent ? try document.contentBounds(page, cancellation: cancellation) : nil
            let visible = trim ? content ?? measured : measured
            let limit = viewportOnly ? maximumZoom : try zoomLimit(rotation: rotation, maximumZoom: maximumZoom, uniform: uniform)
            let display = displaySize ?? RasterLayout.size(page: visible.size, viewport: viewport, columns: columns,
                rotation: rotation, fit: fit, zoom: zoom, content: content, limit: limit, uniformWidth: referenceWidth,
                origin: visible.origin, facing: facing, rtl: rtl, continuous: viewportOnly)
            let logicalWidth = (rotated ? display.height : display.width) * measured.width / visible.width
            let pixelWidth = max(1, Int(ceil(logicalWidth * scale)))
            let pixels = CGSize(width: pixelWidth, height: Int(ceil(CGFloat(pixelWidth) * measured.height / measured.width)))
            let viewportPixels = CGSize(width: viewport.width * scale, height: viewport.height * scale)
            let tileResolution = viewportOnly ? 1 : document.isImageCollection && !document.isVectorImage(page) ? 0 : RasterLayout.tileResolution(
                pixels: rotated ? CGSize(width: pixels.height, height: pixels.width) : pixels,
                maximum: maximumTileSize ?? viewportPixels, viewport: viewportPixels, fit: fit)
            // RenderCache::PaintTile keeps a lower-resolution page behind visible
            // tiles. It also makes the first high-zoom frame cheap to display.
            let previewWidth = max(1, Int(ceil(CGFloat(pixelWidth) / CGFloat(1 << tileResolution))))
            let style = try document.displayStyle(pdfStyle, engineeringAuto: engineeringAuto, cancellation: cancellation)
            let image: CGImage?
            if viewportOnly { image = nil }
            else {
                let request = try document.prepareImage(page, width: previewWidth,
                    transparent: document.isImageCollection && transparent, pdfStyle: style)
                image = try await self.image(request, cancellation: cancellation, priority: .init(visible: !preheating))
            }
            return (measured, content, referenceWidth, facing, display, image, pixelWidth, tileResolution, preheating || isPDF ? [] : try links(page), document.isImageCollection,
                    preheating ? [] : try landscapePages(rotation: rotation), limit,
                    document.isImageCollection && !preheating ? document.estimatedBounds : measured, style)
        } onCancel: { cancellation?.cancel() }
    }
    func zoomLimit(rotation: Int, maximumZoom: Double = ReadingZoom.maximum, uniform: Bool = false) throws -> Double {
        if isMarkdown { return maximumZoom }
        if let cached = zoomLimitCache, cached.rotation == rotation, cached.revision == layoutRevision,
           cached.count == document.count, cached.measured == document.pageBounds.count,
           cached.maximum == maximumZoom, cached.uniform == uniform { return cached.value }
        try Task.checkCancellation()
        let rotated = rotation % 180 != 0, value: Double
        if document.isImageCollection || document.native?.reflowable == true || document.native?.fixedLayoutEPUB == true {
            // Like EngineMupdf::reflowMediabox, unseen reflow pages do not need
            // loading for zoom limits. Fixed EPUB canvases also stay lazy;
            // keep measured publisher viewport sizes for both layouts.
            let estimate = document.estimatedBounds, reference = document.pageBounds[PageLocation(page: 0)] ?? estimate
            let referenceWidth = Double(rotated ? reference.height : reference.width)
            var height = 0.0, width = 0.0
            func include(_ box: CGRect, count: Int = 1) {
                guard count > 0 else { return }
                let w = Double(rotated ? box.height : box.width), h = Double(rotated ? box.width : box.height)
                let ratio = ReadingZoom.pageScale(zoom: 1, referenceWidth: referenceWidth, pageWidth: w, uniform: uniform)
                height += h * ratio * Double(count)
                width = max(width, w * ratio)
            }
            include(estimate, count: document.count - document.pageBounds.count)
            for box in document.pageBounds.values {
                try Task.checkCancellation()
                include(box)
            }
            value = ReadingZoom.documentLimit(totalHeight: height, maximumWidth: width, maximumZoom: maximumZoom)
        } else {
            value = try ReadingZoom.documentLimit(pageCount: document.count, uniform: uniform, maximumZoom: maximumZoom) { page in
                try Task.checkCancellation()
                let box = try document.bounds(page)
                return (Double(rotated ? box.height : box.width), Double(rotated ? box.width : box.height))
            }
        }
        zoomLimitCache = (rotation, layoutRevision, document.count, document.pageBounds.count, maximumZoom, uniform, value)
        return value
    }
    func links(_ page: Int) throws -> [RasterLink] { try document.native?.links(page) ?? [] }
    func embeddedImage(_ page: Int, at point: CGPoint) throws -> Data? {
        guard try !isPDF || pdfNative().pdfInfo()?.permissions.copy == true else { return nil }
        return try document.native?.embeddedImage(page, at: point)
    }
    func previewImage(_ href: String, from sourcePage: Int, pdfStyle: PDFColors.Style? = nil) async throws -> CGImage? {
        let page: Int
        if document.format == .djvu, href == "#+1" || href == "#-1" { page = min(max(0, sourcePage + (href == "#+1" ? 1 : -1)), document.count-1) }
        else { guard let target = try document.native?.resolve(href) else { return nil }; page = target.page }
        return try await image(page, width: 640, pdfStyle: pdfStyle)
    }
    func selection(_ page: Int, from a: CGPoint, to b: CGPoint, mode: Int32 = 0) async throws -> RasterSelection {
        let cancellation = try renderCancellation(page)
        return try await withTaskCancellationHandler {
            try document.native?.selection(page, from: a, to: b, mode: mode, cancellation: cancellation) ?? RasterSelection(text: "", rects: [])
        } onCancel: { cancellation?.cancel() }
    }
    func selection(from first: PageLocation, at start: CGPoint?, to last: PageLocation, at end: CGPoint?, mode: Int32 = 0, all: Bool = false) async throws -> [PageLocation: RasterSelection] {
        if all { _ = try ensureFullLayout() }
        else {
            for chapter in min(first.chapter, last.chapter)...max(first.chapter, last.chapter) { try document.native?.ensureChapter(chapter) }
        }
        let table = chapterLayout
        let firstPage = all ? 0 : try index(first), lastPage = all ? table.totalPages - 1 : try index(last)
        let result = try await selection(from: firstPage, at: start, to: lastPage, at: end, mode: mode)
        return Dictionary(uniqueKeysWithValues: result.compactMap { page, value in table.location(page: page).map { ($0, value) } })
    }
    func selection(areas: [PageLocation: CGRect]) async throws -> [PageLocation: RasterSelection] {
        let cancellation = try renderCancellation(0)
        return try await withTaskCancellationHandler {
            var result = [PageLocation: RasterSelection]()
            for (location, area) in areas {
                try Task.checkCancellation()
                let page = try index(location), box = area.intersection(try document.bounds(page))
                guard !box.isNull, !box.isEmpty else { continue }
                let text = try document.native?.selection(page, from: box.origin, to: CGPoint(x: box.maxX, y: box.maxY), mode: 3, cancellation: cancellation)
                result[location] = .init(text: text?.text ?? "", rects: [box.raster], words: text?.words)
            }
            return result
        } onCancel: { cancellation?.cancel() }
    }
    func textSelection(from first: PageLocation, offset: Int, to last: PageLocation, endOffset: Int) throws -> [PageLocation: RasterSelection] {
        for chapter in min(first.chapter, last.chapter)...max(first.chapter, last.chapter) { try document.native?.ensureChapter(chapter) }
        let table = chapterLayout
        let start = try index(first), end = try index(last)
        var selected = [PageLocation: RasterSelection]()
        for page in start...end {
            try Task.checkCancellation()
            let length = try text(page).utf16.count
            let from = page == start ? offset : 0, to = page == end ? endOffset : length
            if let location = table.location(page: page) { selected[location] = try selection(page, range: NSRange(location: from, length: max(0, to - from))) }
        }
        return selected
    }
    func selection(from first: Int, at start: CGPoint?, to last: Int, at end: CGPoint?, mode: Int32 = 0) async throws -> [Int: RasterSelection] {
        let cancellation = try renderCancellation(first)
        return try await withTaskCancellationHandler {
            if mode == 3, first == last, let start, let end {
                let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x-end.x), height: abs(start.y-end.y)).intersection(try document.bounds(first))
                guard !box.isNull, !box.isEmpty else { return [:] }
                let selected = try document.native?.selection(first, from: box.origin, to: CGPoint(x: box.maxX, y: box.maxY), mode: 3, cancellation: cancellation)
                return [first: .init(text: selected?.text ?? "", rects: [box.raster], words: selected?.words)]
            }
            let lower = max(0, min(first, last)), upper = min(document.count-1, max(first, last))
            guard lower <= upper else { return [:] }
            var result = [Int: RasterSelection]()
            for page in lower...upper {
                try Task.checkCancellation()
                let bounds = try document.bounds(page)
                let a = page == lower ? (first <= last ? start : end) ?? bounds.origin : bounds.origin
                let b = page == upper ? (first <= last ? end : start) ?? CGPoint(x: bounds.maxX, y: bounds.maxY) : CGPoint(x: bounds.maxX, y: bounds.maxY)
                let selected = try document.native?.selection(page, from: a, to: b, mode: lower == upper ? mode : 0, cancellation: cancellation) ?? RasterSelection(text: "", rects: [])
                if start == nil, end == nil, selected.text.isEmpty {
                    result[page] = .init(text: "", rects: [bounds.raster])
                } else { result[page] = selected }
            }
            return result
        } onCancel: { cancellation?.cancel() }
    }
    func text(_ page: Int) throws -> String { try document.native?.text(page) ?? "" }
    func words(_ page: Int) throws -> [RasterWord] { try document.native?.words(page) ?? [] }
    func imageBounds(_ page: Int) throws -> [CGRect] { try document.native?.imageBounds(page) ?? [] }
    func selection(_ page: Int, range: NSRange) throws -> RasterSelection { try document.native?.selection(page, range: range) ?? .init(text: "", rects: []) }
    func selection(from start: NativeSourceAnchor, to end: NativeSourceAnchor, sources: Set<NativeSourceAnchor>? = nil) throws -> [PageLocation: RasterSelection] {
        guard isMarkdown, let native = document.native else { return [:] }
        var first = try native.position(for: start), last = try native.position(for: end)
        // A selected space can become unpainted at a new line boundary. Keep
        // the original source range, but locate its pages with painted glyphs
        // from that same selection instead of discarding the whole range.
        if (first == nil || last == nil), let sources {
            let ordered = sources.sorted().filter { $0 >= start && $0 <= end }
            if first == nil {
                for source in ordered {
                    try Task.checkCancellation()
                    if let position = try native.position(for: source) { first = position; break }
                }
            }
            if last == nil {
                for source in ordered.reversed() {
                    try Task.checkCancellation()
                    if let position = try native.position(for: source) { last = position; break }
                }
            }
        }
        guard let first, let last else { return [:] }
        let firstLocation = try first.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? native.location(first.page)
        let lastLocation = try last.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? native.location(last.page)
        let lower = min(firstLocation, lastLocation), upper = max(firstLocation, lastLocation)
        var selected = [PageLocation: RasterSelection]()
        for chapter in lower.chapter...upper.chapter {
            try Task.checkCancellation()
            try native.ensureChapter(chapter)
            let firstPage = chapter == lower.chapter ? lower.page : 0
            let lastPage = chapter == upper.chapter ? upper.page : (native.chapterTable?.pageCount(chapter) ?? 1) - 1
            for localPage in firstPage...lastPage {
                let location = PageLocation(chapter: chapter, page: localPage)
                let page = try native.page(location)
                var value = try native.selection(page, from: start, to: end)
                if let sources, let words = value.words {
                    let kept = words.filter { word in
                        word.source.map { sources.contains($0) } ?? word.text.allSatisfy(\.isWhitespace)
                    }
                    let anchors = kept.compactMap(\.source)
                    value = RasterSelection(text: kept.map(\.text).joined(), rects: kept.filter { !$0.bounds.isEmpty }.map(\.rect), words: kept,
                                            sourceStart: anchors.min(), sourceEnd: anchors.max())
                }
                if !value.bounds.isEmpty { selected[location] = value }
            }
        }
        return selected
    }
    func markdownCopyText(_ selected: [PageLocation: RasterSelection]) throws -> String? {
        guard isMarkdown, let native = document.native else { return nil }
        var characters = [(NativeSourceAnchor, UInt32)]()
        var seen = Set<NativeSourceAnchor>()
        for page in selected.keys.sorted() {
            for word in selected[page]?.words ?? [] {
                guard let source = word.source, let scalar = word.text.unicodeScalars.first else { continue }
                guard seen.insert(source).inserted else { continue }
                characters.append((source, scalar.value))
            }
        }
        guard !characters.isEmpty else { return nil }
        characters.sort { $0.0 < $1.0 }
        let text = try native.sourceSelectionText(characters)
        return text
    }
    func speechFragment(_ page: Int, visible: CGRect?, offset: Int? = nil, point: CGPoint? = nil) throws -> (text: String, offset: Int) {
        let words = try words(page)
        var start = offset ?? point.flatMap { RasterTextPosition.offset(in: words, near: $0) } ?? 0
        if offset == nil, point == nil, let visible, let first = words.firstIndex(where: { !$0.bounds.isEmpty && !$0.bounds.intersection(visible).isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            start = words[..<first].reduce(0) { $0+$1.text.utf16.count }
        }
        let text = words.map(\.text).joined() as NSString
        start = min(max(0, start), text.length)
        return (text.substring(from: start), start)
    }
    func matches(_ query: String, page: Int, options: TextSearchOptions = .init(), after: Int? = nil,
                 backwards: Bool = false, maximum: Int? = nil) throws -> [RasterMatch] {
        try document.native?.matches(query, page: page, options: options, after: after, backwards: backwards, maximum: maximum) ?? []
    }
    func match(_ query: String, at passage: NativePassage, options: TextSearchOptions) throws -> RasterMatch? {
        guard let position = try document.native?.position(for: passage),
              let x = position.x, let y = position.y else { return nil }
        let point = CGPoint(x: x, y: y)
        return try matches(query, page: position.page, options: options).first {
            $0.rects.contains { $0.contains(point) }
        }
    }
    func searchPageCount(_ chapter: Int) throws -> Int {
        try document.native?.ensureChapter(chapter)
        return chapterLayout.pageCount(chapter)
    }
    func searchChapterMayMatch(_ query: String, chapter: Int, options: TextSearchOptions) throws -> Bool {
        try document.native?.chapterMayMatch(query, chapter: chapter, options: options) ?? false
    }
    func matches(_ query: String, location: PageLocation, options: TextSearchOptions = .init(), after: Int? = nil,
                 backwards: Bool = false, maximum: Int? = nil) throws -> [RasterMatch] {
        let page = try index(location)
        return try matches(query, page: page, options: options, after: after, backwards: backwards, maximum: maximum)
            .map { match in var match = match; match.location = location; return match }
    }
    func markdownDocumentMatches(_ query: String, options: TextSearchOptions, startPage: Int,
                                 after: NativeSourceAnchor? = nil, backwards: Bool = false,
                                 counting: Bool = false, maximum: Int = 1, inclusive: Bool = false) throws -> [RasterMatch] {
        guard isMarkdown else { return [] }
        return try document.native?.markdownDocumentMatches(query, options: options, startPage: startPage,
            after: after, backwards: backwards, counting: counting, maximum: maximum, inclusive: inclusive) ?? []
    }
    func prepare() throws -> (outline: [ContentsItem], reflowable: Bool, searchable: Bool) {
        let outline = try externalOutline ?? document.outline()
        return (outline, document.native?.reflowable == true, document.native?.hasText == true)
    }
    func outlinePage(_ target: String) throws -> Int? {
        try document.comicPage(target) ?? document.native?.resolve(target)?.page
    }
    func position(page: Int, x: Double? = nil, y: Double? = nil, passage: NativePassage? = nil, viewport: CGSize? = nil) throws -> ReadingPosition {
        try Task.checkCancellation()
        let page = min(max(0, page), document.count - 1)
        currentLocation = try document.native?.location(page) ?? .init(page: page)
        _ = try index(currentLocation)
        savedPosition = ReadingPosition(page: currentPage, x: x, y: y, anchor: try document.native?.anchor(currentPage))
        if document.native?.reflowable == true {
            if let passage, let resolved = try document.native?.position(for: passage) {
                // In continuous mode a negative glyph-relative offset can put
                // the viewport top on the preceding page of the same passage.
                savedPosition.nativePassage = resolved.nativePassage
            } else {
                let point = CGPoint(x: x ?? 0, y: y ?? 0)
                savedPosition.nativePassage = try document.native?.passage(currentPage, at: point,
                    in: viewport.map { CGRect(origin: point, size: $0) })
            }
        }
        return layoutPosition
    }
    func restore(_ position: ReadingPosition, userCSS: String? = nil, theme: String? = nil, viewport: CGSize? = nil) throws -> ReadingPosition {
        try Task.checkCancellation()
        if let current = document.style {
            let theme = theme ?? (position.theme == "system" ? current.theme : position.theme ?? current.theme)
            _ = try relayout(fontSize: position.fontSize ?? current.fontSize, lineHeight: position.lineHeight ?? current.lineHeight,
                             margin: position.margin ?? current.margin, font: position.font ?? current.font, theme: theme,
                             userCSS: userCSS ?? position.userCSS ?? current.userCSS, useDocumentCSS: position.useDocumentCSS ?? current.useDocumentCSS,
                             pageMargins: position.margin != nil || position.pageMargins != nil ? position.pageMargins : current.pageMargins,
                             textZoom: isMarkdown ? position.zoom ?? current.textZoom : 1, viewport: viewport)
        }
        if let passage = position.nativePassage, let target = try document.native?.position(for: passage) {
            return try self.position(page: target.page, x: target.x, y: target.y, passage: target.nativePassage, viewport: viewport)
        }
        if isPDF, let anchor = position.anchor,
           let destination = try pdfNative().pdfResolveDestination(anchor) {
            let target = NativePDFActions.position(for: destination, current: position)
            var restored = try self.position(page: target.page, x: target.x, y: target.y, viewport: viewport)
            restored.fit = target.fit; restored.zoom = target.zoom
            return restored
        }
        if document.format == .markdown || document.format == .html,
           let anchor = position.anchor, anchor.hasPrefix("#"),
           let target = try document.native?.resolve(anchor.removingPercentEncoding ?? anchor) {
            return try self.position(page: target.page, x: target.x, y: target.y, viewport: viewport)
        }
        let page: Int
        if let anchor = position.anchor, let restored = try document.native?.page(for: anchor) { page = restored }
        else if let native = document.native, native.hasChapters {
            page = try native.page(native.locationFromFlatPage(position.page))
        } else { page = position.page }
        var restored = try self.position(page: page, x: position.x, y: position.y, viewport: viewport)
        if isPDF { restored.fit = position.fit; restored.zoom = position.zoom }
        return restored
    }
    func fileTarget(_ href: String, relativeTo source: URL) -> (url: URL, fragment: String?)? {
        guard isPDF || document.format == .markdown || document.format == .html else { return nil }
        // EngineMupdf::IsMupdfLocalFileLink treats leading slashes as book-relative.
        // Explicit file: URLs retain their native absolute-file semantics.
        let uri = isPDF || href.lowercased().hasPrefix("file:") ? href : String(href.drop(while: { $0 == "/" }))
        return NativePDFActions.fileTarget(uri, relativeTo: source)
    }
    func resolve(_ href: String, from current: ReadingPosition? = nil, viewport: CGSize? = nil) throws -> ReadingPosition? {
        try Task.checkCancellation()
        if let page = document.comicPage(href) { return try position(page: page) }
        var href = href
        if document.format == .markdown || document.format == .html,
           let target = fileTarget(href, relativeTo: document.url) {
            guard target.url.resolvingSymlinksInPath() == document.url.resolvingSymlinksInPath() else { return nil }
            guard let fragment = target.fragment else { return try position(page: 0, viewport: viewport) }
            href = fragment.removingPercentEncoding ?? fragment
        }
        if document.format == .djvu, href == "#+1" || href == "#-1" {
            return try position(page: (current?.page ?? currentPage) + (href == "#+1" ? 1 : -1))
        }
        if isPDF, let destination = try pdfNative().pdfResolveDestination(href) {
            let target = NativePDFActions.position(for: destination, current: current ?? layoutPosition)
            var restored = try position(page: target.page, x: target.x, y: target.y)
            restored.fit = target.fit; restored.zoom = target.zoom
            return restored
        }
        guard let position = try document.native?.resolve(href) else { return nil }
        return try self.position(page: position.page, x: position.x, y: position.y, viewport: viewport)
    }
    func relayout(fontSize: Double, lineHeight: Double, margin: Double, font: String, theme: String, userCSS: String = "", useDocumentCSS: Bool = true, pageMargins: PageMargins? = nil, textZoom: Double = 1, pageSize: CGSize? = nil, readingPosition: ReadingPosition? = nil, viewport: CGSize? = nil) throws -> Int? {
        try Task.checkCancellation()
        let style = RasterStyle(fontSize: fontSize, lineHeight: lineHeight, margin: margin, font: font, theme: theme, userCSS: userCSS, useDocumentCSS: useDocumentCSS, pageMargins: pageMargins, textZoom: isMarkdown ? textZoom : 1, pageSize: pageSize ?? document.style?.pageSize ?? CGSize(width: 420, height: 595))
        guard style != document.style else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        NativeReadingPerformance.mark("layout-entry", pages: self, revision: layoutRevision, size: style.pageSize)
        defer { NativeReadingPerformance.mark("layout-return", pages: self, revision: layoutRevision, started: started, size: style.pageSize) }
        if let readingPosition {
            let location = readingPosition.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }
                ?? chapterLayout.location(page: readingPosition.page) ?? PageLocation(page: readingPosition.page)
            _ = try position(location, x: readingPosition.x, y: readingPosition.y, passage: readingPosition.nativePassage, viewport: viewport)
        }
        let anchor = document.count > 0 ? try document.native?.anchor(currentPage) : nil
        // A viewport point can lie in a margin. Once resolved, the source glyph
        // remains authoritative through reflow instead of selecting a new
        // nearest glyph from the changed page geometry.
        let point = CGPoint(x: savedPosition.x ?? 0, y: savedPosition.y ?? 0)
        let passage = document.count > 0 ? try savedPosition.nativePassage ?? document.native?.passage(currentPage, at: point,
            in: viewport.map { CGRect(origin: point, size: $0) }) : nil
        guard let count = try document.relayout(style) else { return nil }
        NativeReadingPerformance.mark("native-layout-return", pages: self, revision: layoutRevision, started: started, size: style.pageSize)
        layoutRevision += 1
        // FinishNonPDFLoading leaves initial chapters unresolved: the saved
        // position may reopen a later chapter, so let restore select it first.
        if let passage, let target = try document.native?.position(for: passage) {
            _ = try position(page: target.page, x: target.x, y: target.y, passage: target.nativePassage, viewport: viewport)
        } else if let anchor {
            let page = try document.native?.page(for: anchor) ?? min(currentPage, count-1)
            _ = try position(page: page, viewport: viewport)
        }
        return document.count
    }
    func exportPDF(to destination: URL, locations: [PageLocation]) throws {
        _ = try ensureFullLayout()
        try exportPDF(to: destination, selectedPages: locations.map { try index($0) })
    }
    func exportPDF(to destination: URL, selectedPages: [Int]? = nil) throws {
        try Task.checkCancellation()
        if let selectedPages {
            guard !selectedPages.isEmpty else { throw ReadError("Choose at least one page to export") }
            guard selectedPages.allSatisfy({ (0..<document.count).contains($0) }) else { throw ReadError("Page out of range") }
        }
        guard !PDFTools.sameFile(destination, document.url) else {
            throw ReadError("Choose a different location for PDF export")
        }
        guard (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            throw ReadError("Choose a PDF file location, not a folder")
        }
        let locations = try selectedPages?.map { try document.native?.location($0) ?? PageLocation(page: $0) }
        _ = try ensureFullLayout()
        let selectedPages = try locations?.map { try index($0) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Sumra-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let native = document.native, native.engine == .mupdf || native.engine == .djvu {
            _ = try native.exportPDF(to: temporary, selectedPages: selectedPages)
        } else if document.isImageCollection {
            let count = selectedPages?.count ?? document.count
            try RasterDocument.writeImages(count: count, to: temporary) { index in
                (self.document, selectedPages?[index] ?? index)
            }
        } else {
            throw ReadError("PDF export is unavailable for this document")
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }

}

// Intrinsic page geometry, rather than the latest render bitmap, determines
// all zoom modes. Paged and continuous readers share the same calculation.
enum RasterLayout {
    struct Tile: Hashable {
        let x: Int, y: Int, width: Int, height: Int
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    // RenderCache::GetTileRes / GetTileRectUser, Sumatra 012d997f. A power-of-two
    // grid bounds work by screen area; adjacent tiles share exact pixel edges.
    static func tileResolution(pixels: CGSize, maximum: CGSize, viewport: CGSize, fit: String) -> Int {
        var factor = sqrt(pixels.width / (max(1, maximum.width) + 1) * pixels.height / (max(1, maximum.height) + 1))
        if fit == "page" || fit == "width" || pixels.width <= viewport.width || pixels.height < viewport.height { factor /= 2 }
        return factor > 1.5 ? min(30, Int(ceil(log2(factor)))) : 0
    }
    static func tiles(bounds: CGRect, pixelWidth: Int, resolution: Int, visible: CGRect, maximumSize: CGSize? = nil) -> [Tile] {
        guard resolution > 0, pixelWidth > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = CGFloat(pixelWidth) / bounds.width
        let height = Int(ceil(bounds.height * scale)), divisions = 1 << resolution
        let clip = visible.intersection(bounds)
        guard !clip.isNull, !clip.isEmpty else { return [] }
        let pixels = CGRect(x: (clip.minX - bounds.minX) * scale, y: (clip.minY - bounds.minY) * scale,
                            width: clip.width * scale, height: clip.height * scale)
        if let maximumSize {
            // Natural reflow chapters can be arbitrarily tall. Grid cells share
            // integer pixel edges and stay within one viewport in each axis.
            let width = max(1, Int(floor(maximumSize.width))), stripHeight = max(1, Int(floor(maximumSize.height)))
            let firstColumn = max(0, Int(floor(pixels.minX)) / width)
            let lastColumn = min((pixelWidth - 1) / width, (Int(ceil(pixels.maxX)) - 1) / width)
            let firstRow = max(0, Int(floor(pixels.minY)) / stripHeight)
            let lastRow = min((height - 1) / stripHeight, (Int(ceil(pixels.maxY)) - 1) / stripHeight)
            var result = [Tile]()
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn {
                    let x = column * width, y = row * stripHeight
                    result.append(Tile(x: x, y: y, width: min(width, pixelWidth - x), height: min(stripHeight, height - y)))
                }
            }
            return result
        }
        let columns = min(divisions, pixelWidth), rows = min(divisions, height)
        let firstColumn = max(0, ((Int(floor(pixels.minX)) + 1) * columns - 1) / pixelWidth)
        let lastColumn = min(columns - 1, (Int(ceil(pixels.maxX)) * columns - 1) / pixelWidth)
        let firstRow = max(0, ((Int(floor(pixels.minY)) + 1) * rows - 1) / height)
        let lastRow = min(rows - 1, (Int(ceil(pixels.maxY)) * rows - 1) / height)
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return [] }
        var tiles = [Tile]()
        for row in firstRow...lastRow {
            let y = row * height / rows, bottom = (row + 1) * height / rows
            for column in firstColumn...lastColumn {
                let x = column * pixelWidth / columns, right = (column + 1) * pixelWidth / columns
                tiles.append(Tile(x: x, y: y, width: right - x, height: bottom - y))
            }
        }
        return tiles
    }
    // Engine selections use unrotated top-left page coordinates. Export may
    // translate the page origin or apply explicit image DPI, so map both axes
    // into the PDF's unrotated bottom-left media box before shared printing.
    static func pdfSelectionBounds(_ selection: CGRect, source: CGRect, destination: CGRect) -> CGRect {
        let crop = selection.intersection(source)
        guard !crop.isEmpty, source.width > 0, source.height > 0 else { return .null }
        let x = destination.width / source.width, y = destination.height / source.height
        return CGRect(x: destination.minX + (crop.minX-source.minX)*x,
                      y: destination.maxY - (crop.maxY-source.minY)*y,
                      width: crop.width*x, height: crop.height*y)
    }
    // Translate EngineImages::PageContentBox (012d997f): sampled solid-color
    // margins, bounded to half the image in each axis. No second trim engine.
    static func contentBounds(_ image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        guard w >= 10, h >= 10 else { return CGRect(x: 0, y: 0, width: w, height: h) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value))*255).rounded()) }
            return channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        }
        let dx = max(1, w/200), dy = max(1, h/200)
        var x = 0, y = 0, width = w, height = h
        var margin = pixel(0, h/2)
        while x < w/4, width > w/2 {
            guard stride(from: 0, through: h-dy, by: dy).allSatisfy({ pixel(x+dx, $0) == margin }) else { break }
            x += dx; width -= dx
        }
        margin = pixel(w-1, h/2)
        while width > w/2 {
            guard stride(from: 0, through: h-dy, by: dy).allSatisfy({ pixel(x+width-1-dx, $0) == margin }) else { break }
            width -= dx
        }
        margin = pixel(w/2, 0)
        while y < h/4, height > h/2 {
            guard stride(from: x, through: x+width-dx, by: dx).allSatisfy({ pixel($0, y+dy) == margin }) else { break }
            y += dy; height -= dy
        }
        margin = pixel(w/2, h-1)
        while height > h/2 {
            guard stride(from: x, through: x+width-dx, by: dx).allSatisfy({ pixel($0, y+height-1-dy) == margin }) else { break }
            height -= dy
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    struct FacingPage {
        let bounds: CGRect, content: CGRect?
        let before: Bool
    }
    static func fitContent(_ content: CGRect?, bounds: CGRect, mode: String) -> CGRect? {
        guard ReadingZoom.usesContent(mode), let content, !content.isEmpty else { return nil }
        // DisplayModel::PadContentBox keeps two page points around Fit Visible.
        let box = mode == "visible" ? content.insetBy(dx: -2, dy: -2).intersection(bounds) : content
        return box.isEmpty ? nil : box
    }
    static func contentFocus(bounds: CGRect, content: CGRect?, display: CGSize, rotation: Int,
                             mode: String, facing: FacingPage?, rtl: Bool) -> CGRect? {
        guard ReadingZoom.usesContent(mode) else { return nil }
        let content = fitContent(content, bounds: bounds, mode: mode) ?? bounds
        let transform = transform(bounds: bounds, size: display, rotation: rotation)
        var box = content.applying(transform)
        if let facing {
            let rotated = rotation % 180 != 0
            let scale = display.width / (rotated ? bounds.height : bounds.width)
            let peerSize = CGSize(width: (rotated ? facing.bounds.height : facing.bounds.width) * scale,
                                  height: (rotated ? facing.bounds.width : facing.bounds.height) * scale)
            var peer = (fitContent(facing.content, bounds: facing.bounds, mode: mode) ?? facing.bounds)
                .applying(Self.transform(bounds: facing.bounds, size: peerSize, rotation: rotation))
            // GoToPage fits the whole row. Adapt its content start to the
            // actual HStack order and its four display-point page gap.
            peer.origin.x += facing.before != rtl ? -(peerSize.width + 4) : display.width + 4
            box = box.union(peer)
        }
        return box.applying(transform.inverted())
    }
    static func size(page: CGSize, viewport: CGSize, columns: Int, rotation: Int, fit: String, zoom: Double, content: CGRect? = nil, limit: Double = ReadingZoom.maximum, uniformWidth: CGFloat? = nil, origin: CGPoint = .zero, facing: FacingPage? = nil, rtl: Bool = false, continuous: Bool = false) -> CGSize {
        let rotated = rotation % 180 != 0, width = rotated ? page.height : page.width, height = rotated ? page.width : page.height
        guard width > 0, height > 0 else { return .zero }
        let slot = max(1, (viewport.width - (columns > 1 ? 4 : 0)) / CGFloat(columns))
        // DisplayModel chooses orientation from the whole viewport, before
        // reserving a slot for each facing page.
        let mode = continuous && fit != "custom" ? "width" : fit == "orientation" ? (viewport.width > viewport.height ? "width" : "page") : fit
        let bounds = CGRect(origin: origin, size: page)
        let content = fitContent(content, bounds: bounds, mode: mode)
        let targetWidth = content.map { rotated ? $0.height : $0.width } ?? width
        let targetHeight = content.map { rotated ? $0.width : $0.height } ?? height
        var requested = mode == "custom" ? ReadingZoom.clamp(zoom, limit: limit) : min(limit, ReadingZoom.fitScale(width: Double(targetWidth), height: Double(targetHeight), viewportWidth: Double(slot), viewportHeight: Double(viewport.height), mode: mode))
        if let facing, mode != "custom", mode != "actual" {
            let other = rotated ? CGSize(width: facing.bounds.height, height: facing.bounds.width) : facing.bounds.size
            if ReadingZoom.usesContent(mode) {
                // ZoomRealFromVirtualForPage fits the union across the row,
                // retaining inner margins instead of fitting each half alone.
                var box = (content ?? bounds).applying(transform(bounds: bounds, size: CGSize(width: width, height: height), rotation: rotation))
                var peer = (fitContent(facing.content, bounds: facing.bounds, mode: mode) ?? facing.bounds).applying(transform(bounds: facing.bounds, size: other, rotation: rotation))
                // Use actual column order: asymmetric inner margins can make
                // the RTL union larger than the pinned logical-order union.
                if facing.before != rtl { box.origin.x += other.width + 4 }
                else { peer.origin.x += width + 4 }
                let row = box.union(peer).size
                // AppKit's inter-page gap stays four display points at every zoom.
                requested = min(limit, ReadingZoom.fitScale(width: Double(row.width - 4), height: Double(row.height), viewportWidth: Double(max(1, viewport.width - 4)), viewportHeight: Double(viewport.height), mode: mode))
            } else {
                // GetZoomReal: facing PDFs share the smaller of both fit zooms.
                requested = min(requested, ReadingZoom.fitScale(width: Double(other.width), height: Double(other.height), viewportWidth: Double(slot), viewportHeight: Double(viewport.height), mode: mode))
            }
        }
        // DisplayModel normalizes absolute zoom to the first page's width.
        // Fit modes already derive their scale from the available viewport.
        if let uniformWidth, fit == "custom" || fit == "actual" {
            requested = ReadingZoom.pageScale(zoom: requested, referenceWidth: Double(uniformWidth), pageWidth: Double(width), uniform: true)
        }
        let factor = CGFloat(continuous ? requested : min(requested, ReadingZoom.maximumCanvasExtent / Double(max(width, height))))
        return CGSize(width: width*factor, height: height*factor)
    }
    static func transform(bounds: CGRect, size: CGSize, rotation: Int) -> CGAffineTransform {
        let angle = (rotation % 360 + 360) % 360
        let rotated: CGAffineTransform
        switch angle {
        case 90: rotated = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.height, ty: 0)
        case 180: rotated = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: bounds.width, ty: bounds.height)
        case 270: rotated = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: bounds.width)
        default: rotated = .identity
        }
        let width = angle % 180 == 0 ? bounds.width : bounds.height, height = angle % 180 == 0 ? bounds.height : bounds.width
        return CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY).concatenating(rotated)
            .concatenating(CGAffineTransform(scaleX: size.width/width, y: size.height/height))
    }
    static func image(_ image: CGImage, bounds: CGRect, crop: CGRect?, rotation: Int) throws -> CGImage {
        let selected: CGImage
        if let crop {
            let box = crop.intersection(bounds)
            let pixels = CGRect(x: (box.minX-bounds.minX) * CGFloat(image.width)/bounds.width,
                                y: (box.minY-bounds.minY) * CGFloat(image.height)/bounds.height,
                                width: box.width * CGFloat(image.width)/bounds.width,
                                height: box.height * CGFloat(image.height)/bounds.height).integral
            guard !box.isNull, !box.isEmpty, let result = image.cropping(to: pixels) else { throw ReadError("The selection is outside the page") }
            selected = result
        } else { selected = image }
        let angle = (rotation % 360 + 360) % 360
        guard angle != 0 else { return selected }
        let w = selected.width, h = selected.height, rotated = angle % 180 != 0
        guard let context = CGContext(data: nil, width: rotated ? h : w, height: rotated ? w : h,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReadError("Cannot rotate selection image") }
        switch angle {
        case 90: context.translateBy(x: 0, y: CGFloat(w)); context.rotate(by: -.pi/2)
        case 180: context.translateBy(x: CGFloat(w), y: CGFloat(h)); context.rotate(by: .pi)
        default: context.translateBy(x: CGFloat(h), y: 0); context.rotate(by: .pi/2)
        }
        context.draw(selected, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw ReadError("Cannot create selection image") }
        return result
    }
    static func join(_ images: [CGImage]) throws -> CGImage {
        guard let first = images.first else { throw ReadError("Select a page area first") }
        guard images.count > 1 else { return first }
        let width = images.map(\.width).max() ?? 0, height = images.reduce(0) { $0+$1.height }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReadError("Cannot create selection image") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = height
        for image in images { top -= image.height; context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height)) }
        guard let result = context.makeImage() else { throw ReadError("Cannot create selection image") }
        return result
    }
}

// Selection glyphs retain their own UTF-16 order, including disjoint rectangular
// text and repeated passages. Speech never searches the page for the same string.
struct RasterSpeechSelection {
    let text: String
    private let ranges: [(page: PageLocation, spoken: NSRange, words: [RasterWord])]
    init(_ selections: [PageLocation: RasterSelection]) {
        var text = "", ranges = [(page: PageLocation, spoken: NSRange, words: [RasterWord])]()
        for page in selections.keys.sorted() {
            guard let selected = selections[page], !selected.text.isEmpty else { continue }
            if !text.isEmpty { text += "\n" }
            ranges.append((page, NSRange(location: text.utf16.count, length: selected.text.utf16.count), selected.words ?? []))
            text += selected.text
        }
        self.text = text; self.ranges = ranges
    }
    func rectangles(for range: NSRange) -> [PageLocation: [CGRect]] {
        var result = [PageLocation: [CGRect]]()
        for item in ranges {
            let overlap = NSIntersectionRange(item.spoken, range)
            guard overlap.length > 0 else { continue }
            let selected = RasterSelection.select(item.words, range: NSRange(location: overlap.location-item.spoken.location, length: overlap.length))
            if !selected.bounds.isEmpty { result[item.page] = selected.bounds }
        }
        return result
    }
}

// A text selection spans pages even when continuous scrolling recreates their
// views. Keep only native text and highlight rectangles until the next gesture.
@MainActor private final class RasterSelections: ObservableObject {
    @Published var values = [PageLocation: RasterSelection]()
    @Published var speechRects = [PageLocation: [CGRect]]()
    @Published var searchRects = [Int: [CGRect]]()
    @Published var speechPage = PageLocation(page: 0)
    var spokenSelection: RasterSpeechSelection?
    var keyboardAnchor: (page: PageLocation, offset: Int)?
    var keyboardFocus: (page: PageLocation, offset: Int)?
    var pendingReaderFocus = false
    var cursor: (page: PageLocation, point: CGPoint)?
    var caretRect: CGRect?
    var rectangular = false
    var visibleBounds = [PageLocation: CGRect]()
    private var task: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    func clear(_ state: ReaderState? = nil) { task?.cancel(); task = nil; values = [:]; keyboardAnchor = nil; keyboardFocus = nil; cursor = nil; caretRect = nil; rectangular = false; state?.hasSelection = false }
    func finish() async { if let task { await task.value } }
    var sourceRange: (start: NativeSourceAnchor, end: NativeSourceAnchor, sources: Set<NativeSourceAnchor>)? {
        guard !rectangular else { return nil }
        let selected = values.keys.sorted().compactMap { values[$0] }.filter { !$0.bounds.isEmpty }
        let words = selected.flatMap { $0.words ?? [] }
        guard !selected.isEmpty, selected.allSatisfy({ $0.sourceStart != nil && $0.sourceEnd != nil }),
              words.allSatisfy({ $0.source != nil || $0.text.allSatisfy(\.isWhitespace) }) else { return nil }
        let sources = Set(words.compactMap(\.source))
        guard let start = sources.min(), let end = sources.max() else { return nil }
        return (start, end, sources)
    }
    func restore(_ selected: [PageLocation: RasterSelection], state: ReaderState) {
        values = selected
        keyboardAnchor = nil; keyboardFocus = nil; cursor = nil; caretRect = nil; rectangular = false
        state.selectedText = selected.keys.sorted().compactMap { selected[$0]?.text }.joined(separator: "\n")
        state.hasSelection = selected.values.contains { !$0.bounds.isEmpty }
    }
    func select(pages: Pages, state: ReaderState, first: PageLocation, start: CGPoint?, last: PageLocation, end: CGPoint?, mode: Int32 = 0, all: Bool = false, areas: [PageLocation: CGRect]? = nil, completion: (() -> Void)? = nil) {
        task?.cancel()
        let documentID = state.document?.id, revision = state.renderRevision
        task = Task {
            defer { completion?() }
            do {
                let selected: [PageLocation: RasterSelection]
                if let areas { selected = try await pages.selection(areas: areas) }
                else { selected = try await pages.selection(from: first, at: start, to: last, at: end, mode: mode, all: all) }
                guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                rectangular = mode == 3 || !selected.isEmpty && selected.values.allSatisfy { $0.text.isEmpty && !$0.bounds.isEmpty }
                values = selected
                state.selectedText = !pages.isPDF || state.nativePDFInfo?.permissions.copy == true
                    ? selected.keys.sorted().compactMap { selected[$0]?.text }.joined(separator: "\n") : ""
                state.hasSelection = selected.values.contains { !$0.bounds.isEmpty }
            } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
        }
    }
    func highlight(pages: Pages, state: ReaderState, range: NSRange) {
        speechTask?.cancel()
        guard range.length > 0 else {
            speechRects = [:]
            if !state.speechRequested { spokenSelection = nil }
            return
        }
        if let spokenSelection {
            speechRects = spokenSelection.rectangles(for: range)
            if let first = speechRects.keys.min() { speechPage = first }
            return
        }
        guard let spokenPage = state.speechPage else { return }
        let page = state.pageLocation(spokenPage), documentID = state.document?.id
        speechTask = Task {
            do {
                let selected = try await pages.selection(page, range: range)
                guard !Task.isCancelled, state.document?.id == documentID, state.speechPage.map(state.pageLocation) == page else { return }
                speechRects = [page: selected.bounds]; speechPage = page
            } catch { if !Task.isCancelled, state.document?.id == documentID { state.error = error.localizedDescription } }
        }
    }
    func moveCaret(pages: Pages, state: ReaderState, at point: CGPoint?, backwards: Bool, byWord: Bool, byLine: Bool, extend: Bool) {
        task?.cancel()
        let documentID = state.document?.id
        task = Task {
            do {
                var focus = keyboardFocus ?? (state.pageLocation(state.page), 0)
                var words = try await pages.words(focus.page)
                if keyboardFocus == nil, let point { focus.offset = RasterTextPosition.offset(in: words, near: point) ?? 0 }
                let anchor = extend ? keyboardAnchor ?? focus : nil
                var text = words.map(\.text).joined() as NSString
                if backwards && focus.offset == 0 || !backwards && focus.offset == text.length {
                    let next = try await pages.advance(focus.page, by: backwards ? -1 : 1)
                    let location = next.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? PageLocation(page: next.page)
                    if location != focus.page {
                        focus.page = location
                        words = try await pages.words(focus.page); text = words.map(\.text).joined() as NSString
                        focus.offset = backwards ? text.length : 0
                    }
                } else {
                    focus.offset = RasterTextPosition.move(in: text as String, from: focus.offset, backwards: backwards, byWord: byWord, byLine: byLine)
                }
                let start = anchor ?? focus
                let ordered = start.page < focus.page || start.page == focus.page && start.offset <= focus.offset
                let first = ordered ? start : focus, last = ordered ? focus : start
                let selected = try await pages.textSelection(from: first.page, offset: first.offset, to: last.page, endOffset: last.offset)
                let position: ReadingPosition
                if state.isNativeReflow {
                    let viewport = state.currentPosition
                    let passage: NativePassage?
                    if let current = viewport.nativePassage { passage = current }
                    else { passage = try await pages.capturePassage(viewport, theme: state.resolvedTheme, userCSS: state.effectiveUserCSS) }
                    let samePage = focus.page == state.pageLocation(state.page)
                    position = try await pages.position(focus.page, x: samePage ? viewport.x : nil,
                                                        y: samePage ? viewport.y : nil, passage: passage)
                } else { position = try await pages.position(focus.page) }
                guard !Task.isCancelled, documentID == state.document?.id else { return }
                keyboardAnchor = start; keyboardFocus = focus
                rectangular = false
                var offset = 0
                caretRect = nil
                for word in words {
                    let count = word.text.utf16.count
                    if !word.bounds.isEmpty, focus.offset >= offset, focus.offset <= offset+count, count > 0 {
                        let box = word.bounds
                        caretRect = CGRect(x: box.minX+box.width*CGFloat(focus.offset-offset)/CGFloat(count), y: box.minY, width: 1, height: box.height)
                        break
                    }
                    offset += count
                }
                state.updatePosition(position)
                values = selected
                state.selectedText = !pages.isPDF || state.nativePDFInfo?.permissions.copy == true
                    ? selected.keys.sorted().compactMap { selected[$0]?.text }.joined(separator: "\n") : ""
                state.hasSelection = selected.values.contains { !$0.bounds.isEmpty }
            } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
        }
    }
}

enum RasterTextPosition {
    static func offset(in words: [RasterWord], near point: CGPoint) -> Int? {
        var result: Int?, offset = 0, nearest = CGFloat.infinity
        for word in words {
            let box = word.bounds
            if !box.isEmpty {
                let dx = max(max(box.minX-point.x, 0), point.x-box.maxX), dy = max(max(box.minY-point.y, 0), point.y-box.maxY)
                if dx*dx+dy*dy < nearest { result = offset; nearest = dx*dx+dy*dy }
            }
            offset += word.text.utf16.count
        }
        return result
    }
    static func move(in text: String, from offset: Int, backwards: Bool, byWord: Bool = false, byLine: Bool = false) -> Int {
        let string = text as NSString, offset = min(max(0, offset), text.utf16.count)
        if byWord || byLine {
            var boundaries = [0]
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [byLine ? .byLines : .byWords, .substringNotRequired]) { _, range, _, _ in
                let ns = NSRange(range, in: text); boundaries.append(ns.location); boundaries.append(NSMaxRange(ns))
            }
            boundaries.append(string.length)
            return backwards ? boundaries.last(where: { $0 < offset }) ?? 0 : boundaries.first(where: { $0 > offset }) ?? string.length
        }
        if backwards { return offset > 0 ? string.rangeOfComposedCharacterSequence(at: offset-1).location : 0 }
        return offset < string.length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: offset)) : string.length
    }
}

private struct RasterScrollRequest: Equatable {
    var position: ReadingPosition
    var toBottom = false
    init(_ position: ReadingPosition, toBottom: Bool = false) {
        self.position = position; self.toBottom = toBottom
    }
}

@MainActor struct RasterReader: View {
    static func visiblePageBounds(in view: NSView?, pages: Pages, location: PageLocation) -> CGRect? {
        guard let canvas = view as? RasterCanvas.Canvas, canvas.pages === pages, canvas.location == location else { return nil }
        let region = canvas.visibleRect.applying(canvas.pageTransform.inverted())
        return region.isEmpty ? nil : region
    }
    static func recordPosition(in view: NSView?) {
        if let view { RasterCanvas.Canvas.recordPosition(in: view) }
    }
    static func pageIsRendered(in view: NSView?, pages: Pages, location: PageLocation) -> Bool {
        guard let canvas = view as? RasterCanvas.Canvas else { return false }
        return canvas.pages === pages && canvas.location == location &&
            canvas.readingReady && canvas.window != nil
    }
    static func highlightedMatch(in view: NSView?) -> RasterMatch? {
        (view as? RasterCanvas.Canvas)?.match
    }
    static func pageSize(in viewport: CGSize, spread: Bool, continuous: Bool = false) -> CGSize {
        let spread = spread && !continuous
        let columns: CGFloat = spread ? 2 : 1
        return CGSize(width: floor((viewport.width - (spread ? 4 : 0)) / columns), height: continuous ? 0 : floor(viewport.height))
    }

    @ObservedObject var state: ReaderState
    let pages: Pages
    let initialBounds: CGRect?
    let initialPosition: ReadingPosition?
    @State private var scale: CGFloat = 2
    @State private var pinchStart: Double?
    @State private var viewport = CGSize.zero
    @State private var viewportFrame = CGSize.zero
    @State private var liveResizeViewport: CGSize?
    @State private var liveResizePosition: ReadingPosition?
    @State private var pendingResizePosition: ReadingPosition?
    @State private var renderedFlow: String
    @State private var renderedLayoutRevision: Int?
    @State private var lastFinitePage: Int?
    @State private var finitePageDirection = 1
    @State private var estimatedBounds = CGRect(x: 0, y: 0, width: 420, height: 595)
    @State private var firstRenderedRevision: Int?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchCountStarted = false
    @State private var findTask: Task<Void, Never>?
    @State private var styleTask: Task<Void, Never>?
    @State private var styleCommandRevision: Int?
    @State private var navigationTask: Task<Void, Never>?
    @State private var searchQuery = ""
    @State private var searchOptions = TextSearchOptions()
    @State private var searchBackwards = false
    @State private var searchGeneration = 0
    @State private var searchMatches = [RasterMatch]()
    @State private var selectedMatch: RasterMatch?
    @State private var scrollRequest: RasterScrollRequest?
    @StateObject private var selections = RasterSelections()

    private var reflowPageSize: CGSize {
        reflowPageSize(in: liveResizeViewport ?? readingViewport)
    }
    private var readingViewport: CGSize {
        // Finite reflow defines the document's page from the reader frame.
        // Its fitted canvas can reveal or hide a scrollbar; feeding that clip
        // size back into pagination makes successive layouts resize each other.
        if state.reflowable, !state.continuousReflow, viewportFrame.width > 0 {
            return ReaderScrollbars.initialReadingViewport(in: viewportFrame, mode: state.scrollbarMode, continuous: false)
        }
        if renderedFlow != state.flow, viewportFrame.width > 0 {
            return ReaderScrollbars.initialReadingViewport(in: viewportFrame, mode: state.scrollbarMode, continuous: state.continuousReflow)
        }
        return viewport
    }
    private func reflowPageSize(in viewport: CGSize) -> CGSize {
        Self.pageSize(in: viewport, spread: state.spread && !state.presentation, continuous: state.continuousReflow)
    }

    private func resizeReflow() {
        guard liveResizeViewport == nil, state.reflowable, state.count > 0, reflowPageSize.width > 0, viewport.height > 0 else { return }
        state.send(.style)
    }

    private func liveResizeChanged(_ resizing: Bool) {
        if resizing {
            guard state.reflowable else { return }
            if let document = state.readerScrollView?.documentView { RasterCanvas.Canvas.recordPosition(in: document) }
            liveResizePosition = scrollRequest?.position ?? state.currentPosition
            liveResizeViewport = viewport
        } else if liveResizeViewport != nil {
            if reflowPageSize != reflowPageSize(in: viewport) {
                pendingResizePosition = liveResizePosition
            }
            if let position = liveResizePosition { scrollRequest = .init(position) }
            liveResizePosition = nil
            liveResizeViewport = nil
        }
    }

    init(state: ReaderState, pages: Pages, initialBounds: CGRect? = nil, initialPosition: ReadingPosition? = nil) {
        self.state = state; self.pages = pages; self.initialBounds = initialBounds; self.initialPosition = initialPosition
        _estimatedBounds = State(initialValue: initialBounds ?? CGRect(x: 0, y: 0, width: 420, height: 595))
        _renderedFlow = State(initialValue: state.flow)
        _scrollRequest = State(initialValue: RasterScrollRequest(initialPosition ?? state.currentPosition))
    }

    var body: some View {
        GeometryReader { geometry in
            let pageViewport = liveResizeViewport ?? (readingViewport.width > 0 && readingViewport.height > 0 ? readingViewport : geometry.size)
            ZStack {
                background
                if state.count > 0 {
                    if (state.reflowable ? renderedFlow : state.flow) == "continuous", !state.presentation {
                        continuous().onAppear {
                            if !state.reflowable { scrollRequest = .init(state.currentPosition) }
                        }
                    }
                    else {
                        ScrollView([.horizontal, .vertical]) {
                            row(Array(state.visiblePages), size: pageViewport)
                                .frame(minWidth: pageViewport.width, minHeight: pageViewport.height)
                                .padding(.horizontal, state.freePan ? pageViewport.width / 2 : 0)
                                .padding(.vertical, state.freePan ? pageViewport.height / 2 : 0)
                        }
                        .onAppear {
                            // Reflow restores its source in the style command.
                            // A newly mounted surface must not replay an old
                            // paginated point over that restored destination.
                            if !state.reflowable { scrollRequest = .init(state.currentPosition) }
                        }
                    }
                }
            }
            .focusable()
            .onAppear {
                lastFinitePage = state.page
                viewportFrame = geometry.size
                viewport = ReaderScrollbars.initialReadingViewport(in: geometry.size, mode: state.scrollbarMode, continuous: state.flow == "continuous" && !state.presentation)
                if state.reflowable, initialBounds == nil {
                    estimatedBounds = CGRect(origin: .zero, size: Self.pageSize(in: geometry.size, spread: state.spread && !state.presentation))
                }
            }
            .onChange(of: geometry.size) { size in
                viewportFrame = size
                viewport = ReaderScrollbars.initialReadingViewport(in: size, mode: state.scrollbarMode, continuous: state.flow == "continuous" && !state.presentation)
            }
            .onChange(of: state.page) { page in
                if let lastFinitePage, page != lastFinitePage { finitePageDirection = page > lastFinitePage ? 1 : -1 }
                lastFinitePage = page
            }
            .onMoveCommand { direction in
                switch direction {
                case .up: state.scroll(.up)
                case .down: state.scroll(.down)
                case .left: state.scroll(.left)
                case .right: state.scroll(.right)
                @unknown default: break
                }
            }
            .gesture(MagnificationGesture().onChanged { value in
                if pinchStart == nil { pinchStart = state.zoom }
                state.setZoom((pinchStart ?? state.zoom) * Double(value))
            }.onEnded { _ in pinchStart = nil })
        }
        .onChange(of: reflowPageSize) { _ in resizeReflow() }
        .onChange(of: initialBounds) { bounds in
            if let bounds { estimatedBounds = bounds }
        }
        .onChange(of: initialPosition) { position in
            // Home-to-document mounting can retain the pre-layout request.
            // Publish the source-resolved destination with its initial bounds.
            if state.isNativeReflow, let position { scrollRequest = .init(position) }
        }
        .onChange(of: state.reflowable) { reflowable in
            if reflowable {
                // AppKit can finish choosing its scroller style while native
                // preparation runs. Use that width when mounting the reader.
                viewport = ReaderScrollbars.initialReadingViewport(in: viewportFrame,
                    mode: state.scrollbarMode, continuous: state.continuousReflow)
            }
            if reflowable, initialBounds == nil, reflowPageSize.width > 0, viewport.height > 0 {
                estimatedBounds = CGRect(origin: .zero, size: Self.pageSize(in: viewport, spread: state.spread && !state.presentation && !state.continuousReflow))
            }
            resizeReflow()
        }
        .background(WindowScale(scale: $scale, liveResizeChanged: liveResizeChanged).frame(width: 0, height: 0))
        .onAppear {
            guard pages.isPDF else { return }
            let documentID = state.document?.id
            state.nativePDFSignatureSelection = { [weak state, weak selections] in
                guard let state, let selections, state.document?.id == documentID else { return nil }
                await selections.finish()
                guard !Task.isCancelled, state.document?.id == documentID else { return nil }
                let selected = selections.values.filter { !$0.value.bounds.isEmpty }
                guard !selected.isEmpty else { return nil }
                guard selected.count == 1, let (location, selection) = selected.first else {
                    throw ReadError("Choose a rectangle on one page for the signature")
                }
                return (location.page, selection.bounds.reduce(CGRect.null) { $0.union($1) })
            }
        }
        .task {
            let documentID = state.document?.id
            for await table in await pages.layouts() {
                guard !Task.isCancelled, documentID == state.document?.id else { return }
                // Reflow publishes native chapter counts before its source
                // destination and replacement surface are committed. The style
                // command owns that publication; applying it here would make
                // the outgoing finite row render the new natural chapter.
                if state.chapterLayout != nil, styleCommandRevision == nil { applyLayout(table) }
            }
        }
        .task(id: state.annotationsVisible) {
            guard pages.isPDF else { return }
            let documentID = state.document?.id
            do {
                try await pages.pdfSetAnnotationsVisible(state.annotationsVisible)
                guard !Task.isCancelled, documentID == state.document?.id else { return }
                state.renderRevision += 1
            } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
        }
        .task(id: state.page) {
            guard pages.isPDF else { return }
            let documentID = state.document?.id, page = state.page
            do {
                let label = try await pages.pdfPageLabel(page)
                guard !Task.isCancelled, documentID == state.document?.id, page == state.page else { return }
                state.logicalPageLabel = label
            } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
        }
        .task(id: firstRenderedRevision) {
            // Whole-book chapter counting starts only after actual visible
            // pixels, so an unpainted natural canvas cannot queue it ahead of
            // the first viewport's native tile requests.
            guard firstRenderedRevision == state.renderRevision else { return }
            // Markdown chapters are measured where the reader needs them,
            // including adjacent pages prepared for a finite facing row.
            // Whole-book counting would refill the HTML store after first paint.
            guard !pages.isMarkdown else { return }
            let documentID = state.document?.id, revision = state.renderRevision
            let table = await pages.chapterLayout
            guard table.chapterCount > 1, !table.complete else { return }
            do {
                for chapter in 0..<table.chapterCount where !table.isLaidOut(chapter) {
                    try Task.checkCancellation()
                    guard documentID == state.document?.id, revision == state.renderRevision else { return }
                    try await pages.warmChapter(chapter)
                    await Task.yield()
                }
                guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                try await pages.publishWarmedChapters()
            } catch { if !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision { state.error = error.localizedDescription } }
        }
        .task(id: state.automaticLayout && state.count > 0) {
            guard state.automaticLayout, state.count > 0 else { return }
            let documentID = state.document?.id
            do {
                let layout = try await pages.preferredLayout()
                guard !Task.isCancelled, documentID == state.document?.id, state.automaticLayout else { return }
                try await state.applyPreferredLayout(layout)
            } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
        }
        // Commands must reach the reader even when SwiftUI coalesces redraws.
        // Published emits in willSet; deliver after that setter and use its value.
        .onReceive(state.$command.receive(on: DispatchQueue.main)) { command in
            guard state.claimCommand(command, for: pages) else { return }
            handleCommand(command)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSScrollView.didLiveScrollNotification))) { notification in
                // Keep this at reader lifetime: a lazy row can be between cells
                // when user input supersedes its still-pending precise jump.
                if let scroll = notification.object as? NSScrollView, scroll === state.readerScrollView { cancelNavigation() }
            }
        .onChange(of: selections.speechPage) { location in
            let page = state.pageNumber(location)
            guard state.speechFollow, state.speechRequested else { return }
            // Follow speech through the existing scroll request without clearing
            // the user's persistent selection or adding navigation history.
            if page != state.page {
                let rect = selections.speechRects[location]?.first
                let position = ReadingPosition(page: page, x: rect.map { Double($0.minX) }, y: rect.map { Double($0.minY) })
                state.updatePosition(position); scrollRequest = .init(state.currentPosition)
            }
        }
        .task(id: "\(state.configuredZoomMaximum):\(state.rotation):\(state.uniformPageWidth):\(state.count)") {
            guard state.count > 0 else { return }
            let documentID = state.document?.id
            do {
                let limit = state.continuousReflow ? state.configuredZoomMaximum : try await pages.zoomLimit(rotation: state.rotation, maximumZoom: state.configuredZoomMaximum, uniform: state.uniformPageWidth)
                guard !Task.isCancelled, documentID == state.document?.id else { return }
                state.zoomLimit = limit
                if state.fit == "custom" { state.zoom = ReadingZoom.clamp(state.zoom, limit: limit) }
            } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
        }
        .task(id: state.renderRevision) {
            let documentID = state.document?.id, revision = state.renderRevision
            guard state.count > 0, !state.outline.isEmpty, !(await pages.hasChapters),
                  !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
            state.outlineBusy = true
            defer {
                if documentID == state.document?.id, revision == state.renderRevision { state.outlineBusy = false }
            }
            do {
                // HTML/Markdown layout already resolves its outline. Refresh
                // those coordinates after reflow; resolve only missing pages.
                var located = try await pages.prepare().outline
                guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                for index in located.indices where located[index].page == nil && !located[index].target.contains("://") {
                    located[index].page = try? await pages.outlinePage(located[index].target)
                    guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                    await Task.yield()
                    guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                }
                state.outline = located
            } catch {
                if !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision { state.error = error.localizedDescription }
            }
        }
        .onDisappear {
            searchTask?.cancel(); findTask?.cancel(); styleTask?.cancel(); navigationTask?.cancel(); selections.clear(state)
            if case .pages(let current) = state.document?.content, current === pages { clearSearch() }
        }
    }
    private func applyLayout(_ table: ChapterTable) {
        // Like SyncWithEngineLayout, snapshot the real viewport before page
        // numbers move. Scroll notifications may still be awaiting UI delivery.
        if let document = state.readerScrollView?.documentView { RasterCanvas.Canvas.recordPosition(in: document) }
        guard state.applyChapterLayout(table) else { return }
        if selectedMatch?.location != nil || searchMatches.contains(where: { $0.location != nil }) {
            selectedMatch = selectedMatch.map(projectSearchMatch)
            searchMatches = searchMatches.map(projectSearchMatch)
            if !searchMatches.isEmpty { publishSearchMatches(searchMatches) }
            else { state.selectedSearchTarget = selectedMatch.map { "raster-search:\($0.page):\($0.index)" } }
        }
        // SyncWithEngineLayout preserves the position being read, rather than
        // replaying the last explicit jump after the user has scrolled away.
        scrollRequest = .init(state.currentPosition)
    }
    private func cancelNavigation() {
        navigationTask?.cancel()
        scrollRequest = nil
        state.discardNativePassage()
    }
    private func row(_ indices: [Int], size: CGSize) -> some View {
        let next = finitePageDirection > 0 ? (indices.last ?? -1) + 1 : (indices.first ?? 0) - 1
        let nextRow = (0..<state.count).contains(next) ? PageRows.range(page: next, count: state.count,
            spread: state.spread && state.isFixed && !state.presentation, cover: state.cover,
            landscape: state.landscapeAsSpread ? state.landscapePages : []) : nil
        let predictedIndex = nextRow.map { finitePageDirection > 0 ? $0.lowerBound : $0.upperBound - 1 }
        let predictedLocation = predictedIndex.map { state.pageLocation($0) }
        return HStack(alignment: .top, spacing: state.spread ? 4 : 0) {
            ForEach((state.rtl ? Array(indices.reversed()) : indices).map { state.pageLocation($0) }, id: \.self) { location in
                let index = state.pageNumber(location)
                RasterPage(state: state, pages: pages, index: index, location: location, viewport: size, scale: scale,
                           continuousReflow: false,
                           columns: pages.isPDF && state.spread ? 2 : indices.count,
                           facingPage: pages.isPDF ? indices.first { $0 != index } : nil, match: selectedMatch?.contains(index) == true ? selectedMatch : nil, scrollRequest: $scrollRequest,
                           cancelNavigation: cancelNavigation,
                           selections: selections,
                           estimate: estimatedBounds, updateEstimate: { estimatedBounds = $0 }, didRender: { firstRenderedRevision = state.renderRevision }, didPaintMatch: countAfterMatchPaint,
                           didResizeViewport: { size in if viewport != size { viewport = size } },
                           finitePrediction: index == indices.first && liveResizeViewport == nil && scrollRequest == nil && indices.count < 3 && size.width > 0 && size.height > 0
                               ? predictedLocation.map { target in
                                   RasterPage.FinitePrediction(target: target, visible: Set(indices.map { state.pageLocation($0) }),
                                       columns: pages.isPDF && state.spread ? 2 : nextRow!.count,
                                       facingPage: pages.isPDF ? nextRow!.first { $0 != predictedIndex! } : nil)
                               } : nil)
            }
        }
    }
    private func continuous() -> some View {
        RasterViewport(state: state, pages: pages, scale: scale, continuousReflow: state.reflowable, match: selectedMatch,
            request: $scrollRequest, cancelNavigation: cancelNavigation, selections: selections,
            estimate: estimatedBounds, updateEstimate: { if !state.reflowable { estimatedBounds = $0 } },
            didRender: { firstRenderedRevision = state.renderRevision }, didPaintMatch: countAfterMatchPaint,
            liveResizeViewport: liveResizeViewport,
            didResizeViewport: { size in if viewport != size { viewport = size } })
    }
    func savePosition(location: PageLocation, x: Double? = nil, y: Double? = nil) {
        // Geometry already identifies the stable chapter and page. Recording it
        // must finish before rendering that page can publish new chapter counts.
        state.updatePosition(.init(page: state.pageNumber(location), x: x, y: y,
            anchor: state.reflowable ? state.chapterLayout?.bookmark(location) : nil))
    }
    private func searchStatus() {
        state.status = !state.searchCounting && selectedMatch == nil && searchMatches.isEmpty ? L("No matches") : state.searchCountText
    }
    private func projectSearchMatch(_ match: RasterMatch) -> RasterMatch {
        guard let location = match.location else { return match }
        let fragments = match.fragments?.map { fragment in
            RasterMatchFragment(page: fragment.location.map(state.pageNumber) ?? fragment.page,
                rects: fragment.rects, location: fragment.location)
        }
        return RasterMatch(page: state.pageNumber(location), index: match.index, rects: match.rects,
            context: match.context, source: match.source, fragments: fragments, location: location)
    }
    private func publishSearchMatches(_ matches: [RasterMatch]) {
        searchMatches = matches.map(projectSearchMatch).sorted { $0.page == $1.page ? $0.index < $1.index : $0.page < $1.page }
        if let source = selectedMatch?.source, let match = searchMatches.first(where: { $0.source == source }) {
            selectedMatch = match
        }
        selections.searchRects = searchMatches.reduce(into: [:]) { result, match in
            for fragment in match.fragments ?? [RasterMatchFragment(page: match.page, rects: match.rects)] {
                result[fragment.page, default: []] += fragment.rects
            }
        }
        state.searchResults = searchMatches.map { ContentsItem(title: String(format: L("Page %d"), $0.page + 1) + ": " + $0.context,
            target: "raster-search:\($0.page):\($0.index)") }
        state.selectedSearchTarget = selectedMatch.map { "raster-search:\($0.page):\($0.index)" }
        searchStatus()
    }
    private func show(_ match: RasterMatch) {
        let match = projectSearchMatch(match.source.flatMap { source in
            searchMatches.first { $0.source == source }
        } ?? match)
        selectedMatch = match
        state.selectedSearchTarget = "raster-search:\(match.page):\(match.index)"
        state.send(.preservePosition(ReadingPosition(page: match.page, x: match.rects.first.map { Double($0.minX) }, y: match.rects.first.map { Double($0.minY) }, anchor: match.location.flatMap { state.chapterLayout?.bookmark($0) })))
        searchStatus()
    }
    private var countAfterMatchPaint: ((RasterMatch) -> Void)? {
        guard pages.isMarkdown, !searchCountStarted else { return nil }
        return { match in searchMatchPainted(match) }
    }
    private func searchMatchPainted(_ match: RasterMatch) {
        guard pages.isMarkdown, !searchCountStarted, findTask == nil,
              selectedMatch == match, !searchQuery.isEmpty else { return }
        // Native counting shares the decoder actor with navigation and tiles.
        // Let the selected passage reach the screen before queuing that scan.
        NativeReadingPerformance.mark("search-match-painted", pages: pages, revision: state.renderRevision, page: match.page)
        countMatches(searchQuery, options: searchOptions, start: match.page)
    }
    private func clearSearch(preservingSearch: Bool = false) {
        searchTask?.cancel(); searchTask = nil; findTask?.cancel(); findTask = nil
        searchGeneration &+= 1; searchCountStarted = false; searchMatches = []
        if preservingSearch {
            selectedMatch = selectedMatch.map { RasterMatch(page: $0.page, index: $0.index, rects: [],
                context: $0.context, source: $0.source, fragments: [], location: $0.location) }
        } else { searchQuery = ""; selectedMatch = nil }
        selections.searchRects = [:]; state.searchResults = []; state.status = ""
    }
    private func countMatches(_ query: String, options: TextSearchOptions, start: Int,
                              restoring source: NativeSourceAnchor? = nil, excludingChapters: Set<Int> = []) {
        let documentID = state.document?.id, generation = searchGeneration
        let startLocation = state.pageLocation(start)
        searchCountStarted = true
        state.searchCounting = true
        state.status = L("Searching…")
        searchTask = Task {
            do {
                var all = [RasterMatch]()
                var published = 0, lastPublication = Date.distantPast
                @MainActor func publish() {
                    publishSearchMatches(all)
                    published = all.count; lastPublication = Date()
                }
                if pages.isMarkdown {
                    if let source {
                        let restored = try await pages.markdownDocumentMatches(query, options: options,
                            startPage: start, after: source, inclusive: true)
                        guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                        if selectedMatch?.source == source {
                            selectedMatch = restored.first { $0.source == source }
                            state.selectedSearchTarget = selectedMatch.map { "raster-search:\($0.page):\($0.index)" }
                        }
                    }
                    let found = try await pages.markdownDocumentMatches(query, options: options,
                        startPage: start, counting: true, maximum: 1000)
                    guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                    all = Array(found.prefix(999))
                    state.searchCountCapped = found.count > 999
                    publish(); searchTask = nil; state.searchCounting = false; searchStatus()
                    return
                }
                if await pages.hasChapters, options.allowedPages == nil {
                    let chapters = await pages.chapterLayout.chapterCount
                    for offset in 0...chapters {
                        try Task.checkCancellation()
                        let chapter = (startLocation.chapter + offset) % chapters
                        // The immediately preceding find already proved these
                        // chapters negative for this query and layout.
                        if excludingChapters.contains(chapter) { continue }
                        if try await pages.searchChapterMayMatch(query, chapter: chapter, options: options) == false {
                            await Task.yield(); continue
                        }
                        let count = try await pages.searchPageCount(chapter)
                        guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                        applyLayout(await pages.chapterLayout)
                        let lower = offset == 0 ? startLocation.page : 0
                        let upper = offset == chapters ? startLocation.page : count
                        for page in lower..<max(lower, upper) {
                            let location = PageLocation(chapter: chapter, page: page)
                            let remaining = 999 - all.count
                            let found = try await pages.matches(query, location: location, options: options, maximum: remaining + 1)
                            guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                            applyLayout(await pages.chapterLayout)
                            all += found.prefix(remaining)
                            if found.count > remaining { state.searchCountCapped = true }
                            if (offset == 0 && page == lower && !all.isEmpty) || state.searchCountCapped ||
                                (published == 0 ? all.count >= 16 : all.count - published >= 100 && Date().timeIntervalSince(lastPublication) >= 0.5) {
                                publishSearchMatches(all); published = all.count; lastPublication = Date()
                            }
                            if state.searchCountCapped { break }
                            await Task.yield()
                        }
                        if state.searchCountCapped { break }
                        await Task.yield()
                    }
                    publishSearchMatches(all); searchTask = nil; state.searchCounting = false; searchStatus()
                    return
                }
                // Reflow makes chapter counts lazy again. The find cursor and
                // the count both need the complete document, including chapters
                // that have not yet been painted at the new viewport size.
                let table = try await pages.ensureFullLayout()
                guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                applyLayout(table)
                let count = table.totalPages, start = state.pageNumber(startLocation)
                // CountThread always scans forward from the first navigated
                // page. The 1,000th hit proves "999+"; exactly 999 is not capped.
                for offset in 0..<count {
                    let page = (start + offset) % count
                    try Task.checkCancellation()
                    if options.allowedPages?.contains(page) == false { continue }
                    let remaining = 999 - all.count
                    let found = try await pages.matches(query, page: page, options: options, maximum: remaining + 1)
                    guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                    let accepted = found.prefix(remaining)
                    all += accepted
                    if found.count > remaining {
                        state.searchCountCapped = true
                        break
                    }
                    // CountPartialTask batches 16 initial hits, then 100 new
                    // hits after 500 ms. Publish the reading page immediately.
                    if offset == 0 && !all.isEmpty || (published == 0 ? all.count >= 16 : all.count - published >= 100 && Date().timeIntervalSince(lastPublication) >= 0.5) {
                        publish()
                    }
                    await Task.yield()
                }
                guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                publish(); searchTask = nil; state.searchCounting = false; searchStatus()
            } catch {
                if !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration {
                    searchTask = nil; searchCountStarted = false
                    searchMatches = []; selections.searchRects = [:]; state.searchResults = []
                    state.status = ""; state.error = error.localizedDescription
                }
            }
        }
    }
    private func find(_ query: String, backwards: Bool, options: TextSearchOptions, fromSelection: Bool, inResults: Bool) {
        guard !query.isEmpty else { clearSearch(); return }
        NativeReadingPerformance.mark("find-request", pages: pages, revision: state.renderRevision, page: state.page)
        searchBackwards = backwards
        let sameSearch = query == searchQuery && options == searchOptions
        if sameSearch, inResults, !fromSelection, !searchMatches.isEmpty {
            // FindWindow::MoveResultSelection walks the published list while
            // counting continues. Main-window F3 still searches the document.
            findTask?.cancel(); findTask = nil
            let current = selectedMatch.flatMap { match in searchMatches.firstIndex { $0.page == match.page && $0.index == match.index } }
            let next = current.map { ($0 + (backwards ? -1 : 1) + searchMatches.count) % searchMatches.count }
                ?? (backwards ? searchMatches.count - 1 : 0)
            show(searchMatches[next]); return
        }
        let selected = fromSelection ? selections.values : [:]
        // FindThread resumes its cursor while any part of its page is visible,
        // including the other page in a facing row or a continuous viewport.
        let previousMatch = !fromSelection && sameSearch ? selectedMatch.flatMap { match in
            state.readerScrollView?.documentView.map { RasterCanvas.Canvas.isVisible(state.pageLocation(match.page), in: $0) } == true ? match : nil
        } : nil
        let startLocation = (backwards ? selected.keys.min() : selected.keys.max()) ?? previousMatch?.location ?? state.pageLocation(previousMatch?.page ?? state.page)
        let rtl = state.rtl
        if !sameSearch { clearSearch(); searchQuery = query; searchOptions = options }
        findTask?.cancel()
        if !searchCountStarted { state.searchCounting = true; searchStatus() }
        let documentID = state.document?.id, generation = searchGeneration
        findTask = Task {
            defer { if !Task.isCancelled, generation == searchGeneration { findTask = nil } }
            do {
                let chapterSearch = await pages.hasChapters && options.allowedPages == nil
                let table = chapterSearch ? await pages.chapterLayout : try await pages.ensureFullLayout()
                guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                applyLayout(table)
                let count = table.totalPages, start = state.pageNumber(startLocation)
                guard count > 0 else { state.searchCounting = false; state.status = L("No matches"); return }
                func beyondSelection(_ match: RasterMatch) -> Bool {
                    let candidateRects = match.rects(on: match.location == startLocation ? match.page : start)
                    if candidateRects.isEmpty { return true }
                    guard let boxes = selected[startLocation]?.bounds, let selection = backwards ? boxes.first : boxes.last,
                          let rect = backwards ? candidateRects.last : candidateRects.first else { return true }
                    if boxes.contains(where: { $0.intersection(rect).width > 0.1 && $0.intersection(rect).height > 0.1 }) { return false }
                    if abs(rect.midY - selection.midY) > min(rect.height, selection.height) / 2 { return backwards ? rect.midY < selection.midY : rect.midY > selection.midY }
                    let before = rtl ? rect.minX >= selection.maxX : rect.maxX <= selection.minX
                    return backwards ? before : !before
                }
                var match: RasterMatch?
                if pages.isMarkdown {
                    var sourceCursor = previousMatch?.source
                    var seen = Set<NativeSourceAnchor>()
                    while true {
                        try Task.checkCancellation()
                        let found = try await pages.markdownDocumentMatches(query, options: options,
                            startPage: start, after: sourceCursor, backwards: backwards,
                            maximum: !selected.isEmpty ? 16 : 1)
                        guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                        if let next = found.first(where: { candidate in
                            guard let source = candidate.source, !seen.contains(source) else { return false }
                            return beyondSelection(candidate)
                        }) {
                            match = next
                            break
                        }
                        guard let last = found.last, let source = last.source, seen.insert(source).inserted else { break }
                        sourceCursor = source
                    }
                    if let match {
                        show(match)
                    } else {
                        selectedMatch = nil; state.selectedSearchTarget = nil
                        if !searchCountStarted { state.searchCounting = false }
                        searchStatus()
                    }
                    return
                }
                if chapterSearch {
                    let chapters = table.chapterCount
                    let restricted = previousMatch != nil || !selected.isEmpty
                    var negativeChapters = Set<Int>()
                    chapterLoop: for offset in 0...chapters {
                        try Task.checkCancellation()
                        let chapter = (startLocation.chapter + (backwards ? -offset : offset) + chapters) % chapters
                        if try await pages.searchChapterMayMatch(query, chapter: chapter, options: options) == false {
                            negativeChapters.insert(chapter)
                            await Task.yield(); continue
                        }
                        let pageCount = try await pages.searchPageCount(chapter)
                        guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                        applyLayout(await pages.chapterLayout)
                        let indices: [Int]
                        if backwards {
                            let upper = offset == 0 ? startLocation.page : pageCount - 1
                            let lower = offset == chapters ? startLocation.page + (restricted ? 0 : 1) : 0
                            indices = upper >= lower ? Array(stride(from: upper, through: lower, by: -1)) : []
                        } else {
                            let lower = offset == 0 ? startLocation.page : 0
                            let upper = offset == chapters ? startLocation.page + (restricted ? 1 : 0) : pageCount
                            indices = Array(lower..<max(lower, upper))
                        }
                        for page in indices {
                            let location = PageLocation(chapter: chapter, page: page)
                            let firstPage = offset == 0 && page == startLocation.page
                            var after = firstPage ? previousMatch?.index : nil
                            repeat {
                                let found = try await pages.matches(query, location: location, options: options, after: after,
                                    backwards: backwards, maximum: firstPage && !selected.isEmpty ? 16 : 1)
                                guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                                applyLayout(await pages.chapterLayout)
                                if let first = found.first(where: { !firstPage || beyondSelection($0) }) {
                                    match = first; break chapterLoop
                                }
                                guard let last = found.last else { break }
                                after = last.index
                            } while true
                            await Task.yield()
                        }
                        await Task.yield()
                    }
                    if let match {
                        show(match)
                        if !searchCountStarted { countMatches(query, options: options, start: match.page, excludingChapters: negativeChapters) }
                    } else {
                        selectedMatch = nil; state.selectedSearchTarget = nil
                        if !searchCountStarted { state.searchCounting = false }
                        searchStatus()
                    }
                    return
                }
                // A restricted starting page gets one final visit to include
                // its matches before the cursor when the document wraps.
                let visits = count + (previousMatch != nil || !selected.isEmpty ? 1 : 0)
                search: for offset in 0..<visits {
                    let page = (start + (backwards ? -offset : offset) + count) % count
                    if options.allowedPages?.contains(page) == false { continue }
                    var after = offset == 0 ? previousMatch?.index : nil
                    repeat {
                        try Task.checkCancellation()
                        let found = try await pages.matches(query, page: page, options: options, after: after,
                            backwards: backwards, maximum: offset == 0 && !selected.isEmpty ? 16 : 1)
                        guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                        if let first = found.first(where: { offset != 0 || beyondSelection($0) }) {
                            match = first; break search
                        }
                        guard let last = found.last else { break }
                        after = last.index
                    } while true
                }
                guard !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration else { return }
                if let match {
                    show(match)
                    if !searchCountStarted {
                        countMatches(query, options: options, start: match.page)
                    }
                } else {
                    // The completed, wrapped find already proved there are no
                    // matches in the allowed pages; counting would scan twice.
                    selectedMatch = nil; state.selectedSearchTarget = nil
                    if !searchCountStarted { state.searchCounting = false }
                    searchStatus()
                }
            } catch {
                if !Task.isCancelled, documentID == state.document?.id, generation == searchGeneration {
                    if !searchCountStarted { state.searchCounting = false }
                    state.status = ""; state.error = error.localizedDescription
                }
            }
        }
    }
    private func handleCommand(_ command: ReaderCommand) {
        if let editor = state.nativePDFFormEditor, command.action != .none {
            if case .speechHighlight = command.action { performCommand(command); return }
            let documentID = state.document?.id
            Task {
                do {
                    try await editor.commit()
                    guard state.document?.id == documentID, state.command.revision == command.revision else { return }
                    performCommand(command)
                } catch {
                    if state.document?.id == documentID {
                        state.error = error.localizedDescription
                        state.didHandleCommand(command.revision)
                    }
                }
            }
            return
        }
        performCommand(command)
    }
    private func performCommand(_ command: ReaderCommand) {
        let documentID = state.document?.id
        let readingDocument = state.document
        var acknowledge = true
        defer { if acknowledge { state.didHandleCommand(command.revision) } }
        switch command.action {
        case .annotate(let kind, let preset, let position):
            guard pages.isPDF else { return }
            let explicitTarget = position.flatMap { position -> (page: Int, point: CGPoint)? in
                guard let x = position.x, let y = position.y else { return nil }
                return (position.page, CGPoint(x: x, y: y))
            }
            let pasteTarget = kind == "paste" ? explicitTarget ?? state.readerScrollView.flatMap { RasterCanvas.Canvas.pasteTarget(in: $0) } : nil
            acknowledge = false
            Task {
                defer { state.didHandleCommand(command.revision) }
                do {
                    await selections.finish()
                    guard state.document?.id == documentID else { return }
                    let selected = Dictionary(uniqueKeysWithValues: selections.values.map { (state.pageNumber($0.key), $0.value) })
                    if try await NativePDFAnnotations.perform(kind, preset: preset, selection: selected, state: state, pages: pages, pasteTarget: pasteTarget),
                       state.document?.id == documentID {
                        selections.clear(state); state.selectedText = ""
                    }
                } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
            }
        case .selectAnnotation(let page, let id):
            guard pages.isPDF else { return }
            acknowledge = false
            Task {
                defer { state.didHandleCommand(command.revision) }
                do {
                    let annotations = try await pages.pdfAnnotations(page)
                    guard state.document?.id == documentID,
                          let annotation = annotations.first(where: { Int($0.id) == id }) else { return }
                    state.nativePDFSelection = .annotation(page: page, annotation)
                    scrollRequest = .init(.init(page: page, x: Double(annotation.bounds.minX), y: Double(annotation.bounds.minY)))
                } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
            }
        case .deleteAnnotation:
            guard pages.isPDF, state.canEditPDF, let selected = state.nativePDFSelection else { return }
            acknowledge = false
            Task {
                defer { state.didHandleCommand(command.revision) }
                do {
                    guard state.document?.id == documentID, state.canEditPDF else { return }
                    switch selected {
                    case .annotation: try await pages.pdfDeleteAnnotation(page: selected.page, id: selected.id)
                    case .link: try await pages.pdfDeleteLink(page: selected.page, id: selected.id)
                    }
                    guard state.document?.id == documentID else { return }
                    state.nativePDFSelection = nil
                    try await state.nativePDFDidChange(pages)
                } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
            }
        case .print:
            guard let readingDocument else { return }
            acknowledge = false
            let info = state.printInfo, rotation = state.rotation, password = state.documentPassword
            let title = readingDocument.url.deletingPathExtension().lastPathComponent
            Task {
                defer { withExtendedLifetime(readingDocument) {}; state.didHandleCommand(command.revision) }
                do {
                    guard documentID == state.document?.id else { return }
                    if pages.isPDF {
                        let temporary = try TemporaryDirectory()
                        defer { withExtendedLifetime(temporary) {} }
                        let output = temporary.url.appendingPathComponent("Print.pdf")
                        let prepared = try await pages.preparePDFPrint(to: output, password: password)
                        guard !Task.isCancelled, documentID == state.document?.id else { return }
                        _ = try ReaderPrinting.printPDF(prepared.file, temporary: temporary, info: info, title: title,
                            preferences: prepared.preferences, rotation: rotation)
                    } else if pages.isMarkdown {
                        let snapshot = try await pages.prepareMarkdownPrint()
                        guard !Task.isCancelled, documentID == state.document?.id else { return }
                        _ = try ReaderPrinting.printMarkdown(pages, snapshot: snapshot, info: info, title: title,
                                                             rotation: rotation, documentIsCurrent: {
                            documentID == state.document?.id
                        })
                    } else {
                        let temporary = try TemporaryDirectory()
                        defer { withExtendedLifetime(temporary) {} }
                        let output = temporary.url.appendingPathComponent("Print.pdf")
                        try await pages.exportPDF(to: output)
                        guard documentID == state.document?.id else { return }
                        _ = try ReaderPrinting.printPDF(output, info: info, title: title, rotation: rotation)
                    }
                } catch {
                    if documentID == state.document?.id { state.error = error.localizedDescription }
                }
            }
        case .exportPDF:
            acknowledge = false
            let panel = NSSavePanel(); panel.allowedFileTypes = ["pdf"]; panel.nameFieldStringValue = state.document?.url.deletingPathExtension().lastPathComponent.appending(".pdf") ?? "Document.pdf"
            panel.begin { result in
                guard result == .OK, let destination = panel.url, documentID == state.document?.id else {
                    state.didHandleCommand(command.revision)
                    return
                }
                Task {
                    defer { withExtendedLifetime(readingDocument) {}; state.didHandleCommand(command.revision) }
                    guard documentID == state.document?.id else { return }
                    do { try await pages.exportPDF(to: destination) }
                    catch { if documentID == state.document?.id { state.error = error.localizedDescription } }
                }
            }
        case .style, .zoom:
            acknowledge = false
            styleTask?.cancel(); navigationTask?.cancel()
            styleCommandRevision = command.revision
            let preserveSelection = pages.isMarkdown
            state.clearChapterContentsPages()
            let font = state.font, size = state.fontSize, line = state.lineHeight, margin = state.margin, theme = state.resolvedTheme
            let userCSS = state.effectiveUserCSS, useDocumentCSS = state.useDocumentCSS
            let pageMargins = state.pageMargins
            let textZoom = pages.isMarkdown ? state.zoom : 1
            let layoutFlow = state.flow, naturalLayout = state.continuousReflow
            let layoutViewport = readingViewport
            let pageSize = state.reflowable && reflowPageSize.width > 0 && layoutViewport.height > 0 ? reflowPageSize : nil
            let capturedReflowPosition = state.pendingReflowPosition
            let capturedResizePosition = pendingResizePosition
            let layoutPosition = capturedReflowPosition ?? capturedResizePosition ?? scrollRequest?.position ?? state.currentPosition
            styleTask = Task {
                defer {
                    if styleCommandRevision == command.revision { styleCommandRevision = nil }
                    state.didHandleCommand(command.revision)
                }
                do {
                    await selections.finish()
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    let selectedSource = preserveSelection ? selections.sourceRange : nil
                    if renderedLayoutRevision == nil { renderedLayoutRevision = await pages.layoutRevision }
                    let before = layoutPosition.nativePassage == nil ? await pages.layoutPosition : layoutPosition
                    let selectedFindPassage: NativePassage?
                    if state.isNativeReflow, !pages.isMarkdown, let match = selectedMatch, let rect = match.rects.first {
                        selectedFindPassage = try await pages.capturePassage(.init(page: match.page, x: Double(rect.midX), y: Double(rect.midY)), theme: theme, userCSS: userCSS)
                    } else { selectedFindPassage = nil }
                    let changed = try await pages.relayout(fontSize: size, lineHeight: line, margin: margin, font: font, theme: theme, userCSS: userCSS, useDocumentCSS: useDocumentCSS, pageMargins: pageMargins, textZoom: textZoom, pageSize: pageSize, readingPosition: layoutPosition, viewport: viewport)
                    let layoutRevision = await pages.layoutRevision
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    if changed == nil, renderedFlow == layoutFlow, renderedLayoutRevision == layoutRevision {
                        if state.pendingReflowPosition == capturedReflowPosition { state.pendingReflowPosition = nil }
                        if pendingResizePosition == capturedResizePosition { pendingResizePosition = nil }
                        return
                    }
                    clearSearch(preservingSearch: state.reflowable)
                    let searchRevision = searchGeneration
                    selections.clear(state); state.selectedText = ""
                    var position = await pages.layoutPosition
                    if !naturalLayout, state.spread, !state.presentation {
                        position = try await pages.prepareFacingPages(position, cover: state.cover)
                    }
                    let bounds = try await pages.bounds(position.page)
                    let source = before.nativePassage, current = position.nativePassage
                    let sameSource = source != nil && source?.sourceRevision == current?.sourceRevision &&
                        source?.styleSignature == current?.styleSignature
                    let restoredSelection: [PageLocation: RasterSelection]
                    if let range = selectedSource, sameSource {
                        restoredSelection = try await pages.selection(from: range.start, to: range.end, sources: range.sources)
                    }
                    else { restoredSelection = [:] }
                    let zoomLimit = naturalLayout ? state.configuredZoomMaximum : try await pages.zoomLimit(rotation: state.rotation, maximumZoom: state.configuredZoomMaximum, uniform: state.uniformPageWidth)
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    let table = await pages.chapterLayout
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    applyLayout(table)
                    estimatedBounds = bounds
                    state.renderRevision += 1
                    if preserveSelection { selections.restore(restoredSelection, state: state) }
                    state.zoomLimit = zoomLimit
                    if state.fit == "custom" { state.zoom = ReadingZoom.clamp(state.zoom, limit: zoomLimit) }
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    state.updatePosition(position); scrollRequest = .init(state.currentPosition)
                    // Mount the new scrolling surface only after its native
                    // geometry and source destination are ready. A natural
                    // chapter must not be measured as an old finite page.
                    viewport = layoutViewport
                    renderedFlow = layoutFlow
                    renderedLayoutRevision = layoutRevision
                    styleCommandRevision = nil
                    // A menu action may have captured the next source while
                    // this style awaited its native work. Finish only our handoff.
                    if state.pendingReflowPosition == capturedReflowPosition { state.pendingReflowPosition = nil }
                    if pendingResizePosition == capturedResizePosition { pendingResizePosition = nil }
                    if searchRevision == searchGeneration, !searchQuery.isEmpty {
                        let matchSource = sameSource ? selectedMatch?.source : nil
                        if !sameSource { selectedMatch = nil }
                        if let selectedFindPassage, let match = try await pages.match(searchQuery, at: selectedFindPassage, options: searchOptions) {
                            guard !Task.isCancelled, documentID == state.document?.id, searchRevision == searchGeneration else { return }
                            selectedMatch = match
                            state.selectedSearchTarget = "raster-search:\(match.page):\(match.index)"
                            countMatches(searchQuery, options: searchOptions, start: position.page)
                        } else if await pages.hasChapters || selectedMatch == nil {
                            // Reflow cancelled the navigation task as well as
                            // its count. An active query still needs a selected
                            // hit when Find was invoked without opening its UI.
                            find(searchQuery, backwards: searchBackwards, options: searchOptions, fromSelection: false, inResults: false)
                        } else {
                            countMatches(searchQuery, options: searchOptions, start: position.page, restoring: matchSource)
                        }
                    }
                } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
            }
        case .find(let query, let backwards, let options, let selection, let inResults): find(query, backwards: backwards, options: options ?? .init(), fromSelection: selection, inResults: inResults)
        case .turnPages(let distance, let toBottom):
            acknowledge = false
            let forward = distance > 0
            let location = state.pageLocation(forward ? max(state.visiblePages.lowerBound, state.visiblePages.upperBound - 1) : state.visiblePages.lowerBound)
            navigationTask?.cancel()
            navigationTask = Task {
                defer { state.didHandleCommand(command.revision) }
                do {
                    var restored = try await pages.advance(location, by: forward ? 1 : -1)
                    if abs(distance) > 1 {
                        let next = restored.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? .init(page: restored.page)
                        restored = try await pages.advance(next, by: (abs(distance) - 1) * (state.spread ? 2 : 1) * (forward ? 1 : -1))
                    }
                    if !state.continuousReflow, state.spread, !state.presentation {
                        restored = try await pages.prepareFacingPages(restored, cover: state.cover)
                    }
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    let table = await pages.chapterLayout
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    applyLayout(table)
                    selections.clear(state); state.selectedText = ""
                    if pages.isPDF { state.apply(restored); state.persist() }
                    else { state.updatePosition(restored) }
                    scrollRequest = .init(state.currentPosition, toBottom: toBottom)
                } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
            }
        case .location(let input):
            if input == "last" {
                acknowledge = false
                navigationTask?.cancel()
                navigationTask = Task {
                    defer { state.didHandleCommand(command.revision) }
                    do {
                        var restored = try await pages.lastPosition()
                        if !state.continuousReflow, state.spread, !state.presentation {
                            restored = try await pages.prepareFacingPages(restored, cover: state.cover)
                        }
                        guard !Task.isCancelled, documentID == state.document?.id else { return }
                        let table = await pages.chapterLayout
                        guard !Task.isCancelled, documentID == state.document?.id else { return }
                        applyLayout(table)
                        selections.clear(state); state.selectedText = ""
                        state.updatePosition(restored); scrollRequest = .init(state.currentPosition)
                    } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
                }
            } else if let anchor = ReaderState.chapterInput(input, offset: -1) { state.navigate(.restore(.init(anchor: anchor))) }
        case .scroll(let direction, let amount, let count):
            guard count != 0 else { return }
            cancelNavigation()
            guard let turn = ReaderScroll.pageTurn(in: state.readerScrollView, direction: direction, amount: amount,
                fit: state.fit, continuous: state.flow == "continuous", rtl: state.rtl, count: count) else { return }
            let forward = turn.direction > 0
            let target = forward ? state.visiblePages.upperBound : state.visiblePages.lowerBound - 1
            guard target >= 0, target < state.count else { return }
            if turn.toBottom { state.send(.turnPages(turn.direction, toBottom: true)) }
            else { state.turn(turn.direction) }
        case .fit(let mode) where ReadingZoom.usesContent(mode):
            scrollRequest = .init(.init(page: state.page))
        case .page(let page):
            navigationTask?.cancel(); selections.clear(state); state.selectedText = ""
            scrollRequest = .init(.init(page: page)); savePosition(location: state.pageLocation(page))
        case .restore(let saved), .preservePosition(let saved):
            acknowledge = false
            navigationTask?.cancel()
            if case .restore = command.action { styleTask?.cancel(); selections.clear(state); state.selectedText = "" }
            navigationTask = Task {
                defer { state.didHandleCommand(command.revision) }
                do {
                    let revision = await pages.layoutRevision
                    var restored = try await pages.restore(saved, userCSS: state.effectiveUserCSS, theme: state.resolvedTheme, viewport: viewport)
                    if !state.continuousReflow, state.spread, !state.presentation {
                        restored = try await pages.prepareFacingPages(restored, cover: state.cover)
                    }
                    let updatedRevision = await pages.layoutRevision
                    let zoomLimit = try await pages.zoomLimit(rotation: state.rotation, maximumZoom: state.configuredZoomMaximum, uniform: state.uniformPageWidth)
                    let landscape = try await pages.landscapePages(rotation: state.rotation)
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    let table = await pages.chapterLayout
                    guard !Task.isCancelled, documentID == state.document?.id else { return }
                    applyLayout(table)
                    if revision != updatedRevision {
                        state.clearChapterContentsPages()
                        state.renderRevision += 1
                    }
                    if pages.isPDF { state.apply(restored); state.persist() }
                    else { state.updatePosition(restored) }
                    scrollRequest = .init(state.currentPosition)
                    state.landscapePages = landscape
                    state.zoomLimit = zoomLimit
                    if state.fit == "custom" { state.zoom = ReadingZoom.clamp(state.zoom, limit: zoomLimit) }
                } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
            }
        case .href(let href):
            if href.hasPrefix("raster-search:") {
                let parts = href.split(separator: ":")
                if parts.count == 3, let page = Int(parts[1]), let index = Int(parts[2]), let match = searchMatches.first(where: { $0.page == page && $0.index == index }) { findTask?.cancel(); findTask = nil; show(match) }
            } else if let url = NativePDFActions.externalURL(href) {
                if !NSWorkspace.shared.open(url) { state.error = "Cannot open link" }
            }
            else {
                acknowledge = false
                navigationTask?.cancel()
                let sourcePosition = state.currentPosition
                navigationTask = Task {
                    defer { state.didHandleCommand(command.revision) }
                    do {
                        var target: (url: URL, fragment: String?)?
                        if let readingDocument { target = await pages.fileTarget(href, relativeTo: readingDocument.url) }
                        let position = pages.isPDF && target != nil ? nil : try await pages.resolve(href, from: sourcePosition, viewport: viewport)
                        // A missing local fragment must not reopen the current markup file.
                        if position == nil, let target, let readingDocument,
                           pages.isPDF || target.url.resolvingSymlinksInPath() != readingDocument.url.resolvingSymlinksInPath() {
                            try await NativePDFActions.openFile(target, state: state) {
                                !Task.isCancelled && documentID == state.document?.id
                            }
                            return
                        }
                        guard var position, !Task.isCancelled, documentID == state.document?.id else { return }
                        if !state.continuousReflow, state.spread, !state.presentation {
                            position = try await pages.prepareFacingPages(position, cover: state.cover)
                        }
                        let table = await pages.chapterLayout
                        guard !Task.isCancelled, documentID == state.document?.id else { return }
                        applyLayout(table)
                        state.recordNavigation()
                        state.cacheContentsPosition(position, target: href)
                        selections.clear(state); state.selectedText = ""
                        if pages.isPDF { state.apply(position); state.persist() }
                        else { state.updatePosition(position) }
                        scrollRequest = .init(state.currentPosition)
                    } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
                }
            }
        case .selectAll, .selectCurrentPage:
            let currentOnly = command.action == .selectCurrentPage
            let entireDocument = !currentOnly && state.flow == "continuous" && !state.presentation
            let range = currentOnly ? state.page..<state.page+1 : entireDocument ? 0..<state.count : state.visiblePages
            guard let first = range.first, let last = range.last else { return }
            acknowledge = false
            selections.select(pages: pages, state: state, first: state.pageLocation(first), start: nil, last: state.pageLocation(last), end: nil, all: entireDocument) {
                state.didHandleCommand(command.revision)
            }
        case .zoomToSelection:
            acknowledge = false
            Task {
                defer { state.didHandleCommand(command.revision) }
                await selections.finish()
                guard documentID == state.document?.id,
                      let page = selections.values.keys.sorted().first(where: { selections.values[$0]?.bounds.isEmpty == false }),
                      let selection = selections.values[page] else { return }
                let box = selection.bounds.reduce(CGRect.null) { $0.union($1) }
                guard !box.isNull, !box.isEmpty else { return }
                let rotation = state.rotation, uniform = state.uniformPageWidth, trim = state.trimEmptyMargins
                let rotated = rotation % 180 != 0
                let scale = ReadingZoom.fitScale(width: Double(rotated ? box.height : box.width), height: Double(rotated ? box.width : box.height), viewportWidth: Double(viewport.width), viewportHeight: Double(viewport.height), mode: "page")
                let pageBounds: CGRect
                let reference: CGRect?
                do {
                    pageBounds = try await (trim ? pages.contentBounds(page) : pages.bounds(page))
                    reference = uniform ? try await pages.bounds(0) : nil
                }
                catch { if documentID == state.document?.id { state.error = error.localizedDescription }; return }
                guard documentID == state.document?.id, rotation == state.rotation,
                      uniform == state.uniformPageWidth, trim == state.trimEmptyMargins else { return }
                state.recordNavigation(); state.fit = "custom"
                let referenceWidth = reference.map { rotated ? $0.height : $0.width }
                let ratio = ReadingZoom.pageScale(zoom: 1, referenceWidth: Double(referenceWidth ?? 0), pageWidth: Double(rotated ? pageBounds.height : pageBounds.width), uniform: uniform)
                state.zoom = ReadingZoom.clamp(scale / ratio, limit: state.zoomLimit)
                let size = RasterLayout.size(page: pageBounds.size, viewport: viewport, columns: 1, rotation: rotation, fit: "custom", zoom: state.zoom, limit: state.zoomLimit, uniformWidth: referenceWidth)
                let transform = RasterLayout.transform(bounds: pageBounds, size: size, rotation: state.rotation)
                let point = box.applying(transform).origin.applying(transform.inverted())
                scrollRequest = .init(.init(page: state.pageNumber(page), x: Double(point.x), y: Double(point.y), anchor: state.chapterLayout?.bookmark(page)))
                if let scrollRequest { state.updatePosition(scrollRequest.position) }
            }
        case .printSelection:
            guard let readingDocument else { return }
            acknowledge = false
            let info = state.printInfo, revision = state.renderRevision, rotation = state.rotation, password = state.documentPassword
            let title = readingDocument.url.deletingPathExtension().lastPathComponent
            Task {
                defer { withExtendedLifetime(readingDocument) {}; state.didHandleCommand(command.revision) }
                do {
                    await selections.finish()
                    guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                    let selected = selections.values.mapValues(\.bounds).filter { !$0.value.isEmpty }
                    let indices = selected.keys.sorted()
                    guard !indices.isEmpty else { throw ReadError("Select a page area first") }
                    let temporary = try TemporaryDirectory()
                    defer { withExtendedLifetime(temporary) {} }
                    let output = temporary.url.appendingPathComponent("Selection.pdf")
                    if pages.isPDF {
                        let prepared = try await pages.preparePDFPrint(to: output, password: password)
                        guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                        _ = try ReaderPrinting.printPDF(prepared.file, temporary: temporary, info: info, title: title,
                            preferences: prepared.preferences, selectedPages: indices.map(\.page),
                            regions: indices.map { selected[$0]! }, rotation: rotation)
                        return
                    }
                    let layoutRevision = await pages.layoutRevision
                    var bounds = [PageLocation: CGRect]()
                    for index in indices { bounds[index] = try await pages.bounds(index) }
                    try await pages.exportPDF(to: output, locations: indices)
                    let currentLayoutRevision = await pages.layoutRevision
                    guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision,
                          layoutRevision == currentLayoutRevision else { return }
                    guard let pdf = CGPDFDocument(output as CFURL) else { throw ReadError("Cannot read the selection print document") }
                    let areas: [[CGRect]] = try indices.enumerated().map { offset, index in
                        guard let page = pdf.page(at: offset + 1), let crops = selected[index], let source = bounds[index] else {
                            throw ReadError("Cannot read selected print page")
                        }
                        return crops.map { RasterLayout.pdfSelectionBounds($0, source: source, destination: page.getBoxRect(.mediaBox)) }
                    }
                    _ = try ReaderPrinting.printPDF(output, info: info, title: title, regions: areas, rotation: rotation)
                } catch {
                    if !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision { state.error = error.localizedDescription }
                }
            }
        case .copy, .copyImage, .copySelectionImage, .saveSelection, .searchSelectionWithLens:
            guard !pages.isPDF || state.nativePDFInfo?.permissions.copy == true else { return }
            acknowledge = false
            Task {
                defer { state.didHandleCommand(command.revision) }
                await selections.finish()
                guard documentID == state.document?.id else { return }
                let copyText: String
                do {
                    copyText = command.action == .copy && pages.isMarkdown && !selections.rectangular
                        ? (try await pages.markdownCopyText(selections.values) ?? state.selectedText)
                        : state.selectedText
                } catch {
                    if documentID == state.document?.id { state.error = error.localizedDescription }
                    return
                }
                if command.action == .copy, pages.isPDF, !state.hasSelection {
                    do { _ = try await NativePDFClipboard.copy(state: state, pages: pages, cut: false) }
                    catch { if documentID == state.document?.id { state.error = error.localizedDescription } }
                    return
                }
                let hasText = await pages.hasText
                guard documentID == state.document?.id else { return }
                let selectionImage = command.action == .copySelectionImage || command.action == .saveSelection || command.action == .searchSelectionWithLens || command.action == .copy && selections.rectangular
                if selectionImage || command.action == .copyImage || (copyText.isEmpty && !hasText) {
                    do {
                        let indices = selectionImage ? selections.values.keys.sorted() : [state.pageLocation(state.page)]
                        var images = [CGImage]()
                        for page in indices {
                            let crop = selectionImage ? selections.values[page]?.bounds.reduce(CGRect.null) { $0.union($1) } : nil
                            if selectionImage, crop?.isEmpty != false { continue }
                            let bounds = try await pages.bounds(page)
                            let width = max(128, bounds.width * 2)
                            let rendered = try await pages.image(page, width: Int(width))
                            let image = try RasterLayout.image(rendered, bounds: bounds, crop: crop, rotation: state.rotation)
                            images.append(image)
                        }
                        guard !images.isEmpty else { throw ReadError("Select a page area first") }
                        guard documentID == state.document?.id else { return }
                        try PDFTools.outputImages(images, action: command.action, state: state)
                        if command.action == .copy, !copyText.isEmpty { NSPasteboard.general.setString(copyText, forType: .string) }
                    } catch { if documentID == state.document?.id { state.error = error.localizedDescription } }
                } else if !copyText.isEmpty {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copyText, forType: .string)
                }
            }
        case .readAloud, .readAloudFromTop, .readAloudFromCursor, .readAloudSelection:
            guard !pages.isPDF || state.nativePDFInfo?.permissions.copy == true else { return }
            acknowledge = false
            Task {
                defer { state.didHandleCommand(command.revision) }
                await selections.finish()
                guard documentID == state.document?.id else { return }
                let selected = command.action == .readAloudSelection || command.action == .readAloud && !state.selectedText.isEmpty
                selections.spokenSelection = nil
                selections.speechPage = state.pageLocation(state.page)
                if selected {
                    let fragment = RasterSpeechSelection(selections.values)
                    if fragment.text.isEmpty { state.status = L("Select text to read aloud") }
                    else { state.readText(fragment.text); selections.spokenSelection = fragment }
                } else {
                    do {
                        let cursor = command.action == .readAloudFromCursor || command.action == .readAloud && state.keyboardTextSelection
                        let focus = cursor ? selections.keyboardFocus : nil
                        let point = cursor && focus == nil ? selections.cursor : nil
                        if command.action == .readAloudFromCursor, focus == nil, point == nil {
                            state.status = "Place the text cursor before reading aloud"; return
                        }
                        let page = focus?.page ?? point?.page ?? state.pageLocation(state.page)
                        let fragment = try await pages.speechFragment(page, visible: selections.visibleBounds[page], offset: focus?.offset, point: point?.point)
                        guard documentID == state.document?.id else { return }
                        let number = state.pageNumber(page)
                        if number != state.page { state.updatePosition(.init(page: number, anchor: state.chapterLayout?.bookmark(page))); state.send(.page(number)) }
                        state.readText(fragment.text, page: number, startOffset: fragment.offset, location: page)
                    } catch { if documentID == state.document?.id { state.error = error.localizedDescription } }
                }
            }
        case .speechHighlight(let location, let length):
            selections.highlight(pages: pages, state: state, range: NSRange(location: location, length: length))
        case .toc: clearSearch()
        default: break
        }
    }
    private var background: Color { state.resolvedTheme == "dark" ? Color(nsColor: NSColor(white: 0.06, alpha: 1)) : .white }
}

private struct WindowScale: NSViewRepresentable {
    @Binding var scale: CGFloat
    let liveResizeChanged: (Bool) -> Void
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {
        view.liveResizeChanged = liveResizeChanged
        DispatchQueue.main.async { let value = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2; if scale != value { scale = value } }
    }
    static func dismantleNSView(_ view: View, coordinator: ()) { view.detach() }

    final class View: NSView {
        var liveResizeChanged: ((Bool) -> Void)?
        private var observers = [NSObjectProtocol]()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detachObservers()
            guard let window else { return }
            for (name, resizing) in [(NSWindow.willStartLiveResizeNotification, true), (NSWindow.didEndLiveResizeNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveResizeChanged?(resizing) }
                })
            }
        }
        private func detachObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
        func detach() { detachObservers(); liveResizeChanged = nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
// The page geometry is the translated Sumatra DocumentLayout, not a lazy
// stack's estimated content size. AppKit supplies scrolling; only visible rows
// have views. RasterPage keeps the existing decoder, drawing and selection.
@MainActor private struct RasterViewport: NSViewRepresentable {
    let state: ReaderState, pages: Pages
    let scale: CGFloat
    let continuousReflow: Bool
    let match: RasterMatch?
    @Binding var request: RasterScrollRequest?
    let cancelNavigation: () -> Void
    let selections: RasterSelections
    let estimate: CGRect
    let updateEstimate: (CGRect) -> Void
    let didRender: () -> Void
    let didPaintMatch: ((RasterMatch) -> Void)?
    let liveResizeViewport: CGSize?
    let didResizeViewport: (CGSize) -> Void

    func makeNSView(context: Context) -> Scroll { Scroll() }
    func updateNSView(_ view: Scroll, context: Context) { view.configure(self) }
    static func dismantleNSView(_ view: Scroll, coordinator: ()) { view.detach() }

    final class DocumentView: NSView { override var isFlipped: Bool { true } }
    final class Scroll: NSScrollView {
        private struct Measurement: Equatable {
            let bounds: CGRect, content: CGRect?, referenceWidth: CGFloat?
        }
        private struct LayoutKey: Equatable {
            var viewport: CGSize
            let count: Int, generation: Int, revision: Int, rotation: Int
            let fit: String
            let zoom: Double, limit: Double
            let spread: Bool, cover: Bool, rtl: Bool, uniform: Bool, trim: Bool, freePan: Bool
            let continuousReflow: Bool
            let landscape: Set<Int>
            let estimate: CGRect
        }
        private enum Geometry {
            case listed(PageRows.Layout)
            case uniform(PageRows.UniformLayout)

            var canvas: CGSize {
                switch self { case .listed(let layout): layout.canvas; case .uniform(let layout): layout.canvas }
            }
            var rowCount: Int {
                switch self { case .listed(let layout): layout.rows.count; case .uniform(let layout): layout.rowCount }
            }
            var pageCount: Int {
                switch self { case .listed(let layout): layout.pages.count; case .uniform(let layout): layout.count }
            }
            func range(row: Int) -> Range<Int> {
                switch self { case .listed(let layout): layout.rows[row]; case .uniform(let layout): layout.range(row: row) }
            }
            func frame(page: Int) -> CGRect? {
                switch self { case .listed(let layout): layout.pages[page]; case .uniform(let layout): layout.frame(page: page) }
            }
            func row(atY y: CGFloat, frame: (Range<Int>) -> CGRect) -> Int {
                switch self {
                case .uniform(let layout): return layout.row(atY: y)
                case .listed(let layout):
                    var low = 0, high = layout.rows.count
                    while low < high {
                        let middle = (low + high) / 2
                        if frame(layout.rows[middle]).minY <= y { low = middle + 1 } else { high = middle }
                    }
                    return max(0, low - 1)
                }
            }
        }
        private var owner: RasterViewport?
        private let canvas = DocumentView()
        private var key: LayoutKey?
        private var naturalScrollbarKey: LayoutKey?
        private var geometry: Geometry?
        private var locations = [PageLocation]()
        private var boxes = [CGRect]()
        private var measured = [PageLocation: Measurement]()
        private var cells = [PageLocation: NSHostingView<RasterPage>]()
        private var contentPage = 0
        private var observer: NSObjectProtocol?
        private var arranging = false
        private var positionScheduled = false
        private struct Prediction: Equatable {
            let document: UUID?, layout: LayoutKey, location: PageLocation, render: String
        }
        private var prediction: Prediction?
        private var predictionTask: Task<Void, Never>?
        private var scrollDirection = 1
        private var lastScrollY: CGFloat = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            documentView = canvas; drawsBackground = false; borderType = .noBorder
            hasHorizontalScroller = true; hasVerticalScroller = true; autohidesScrollers = true
            contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportChanged() }
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func detach() {
            cancelPrediction()
            owner = nil
            for view in cells.values { view.removeFromSuperview() }
            cells.removeAll()
        }
        override func scrollWheel(with event: NSEvent) {
            if owner?.state.isNativeReflow == true, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                owner?.cancelNavigation()
            }
            super.scrollWheel(with: event)
        }
        private var explicitNaturalScroller: Bool {
            owner?.continuousReflow == true && owner?.state.fit != "custom" && owner?.state.scrollbarMode == "smart"
                && NSScroller.preferredScrollerStyle == .legacy
        }
        func configure(_ value: RasterViewport, remeasure: Bool = false) {
            guard !arranging else { return }
            let pending = value.request?.position
            let saved = pending ?? position()
            owner = value
            arranging = true
            if !explicitNaturalScroller { naturalScrollbarKey = nil }
            if key?.revision != value.state.renderRevision { measured.removeAll() }
            // Natural width-fit never needs a horizontal bar. Reserving both
            // axes before fitting makes legacy autohiding alternate between
            // the full frame and the smaller clip while the canvas mounts.
            ReaderScrollbars.apply(to: self, mode: value.state.scrollbarMode,
                horizontal: !value.continuousReflow || value.state.fit == "custom",
                vertical: explicitNaturalScroller ? hasVerticalScroller : true,
                autohide: explicitNaturalScroller ? false : nil)
            tile()
            let state = value.state
            let viewport = explicitNaturalScroller && value.liveResizeViewport == nil
                ? NSScrollView.contentSize(forFrameSize: frame.size, horizontalScrollerClass: nil,
                    verticalScrollerClass: nil, borderType: .noBorder, controlSize: .regular, scrollerStyle: .legacy)
                : value.liveResizeViewport ?? contentView.bounds.size
            var next = LayoutKey(viewport: viewport, count: state.count,
                generation: state.chapterLayout?.generation ?? 0, revision: state.renderRevision, rotation: state.rotation,
                fit: value.continuousReflow && state.fit != "custom" ? "width" : state.fit,
                zoom: state.fit == "custom" ? state.rasterZoom : 1, limit: state.zoomLimit,
                spread: state.spread && !value.continuousReflow, cover: state.cover && !value.continuousReflow,
                rtl: state.rtl, uniform: state.uniformPageWidth && !value.continuousReflow,
                trim: state.trimEmptyMargins && !value.continuousReflow, freePan: state.freePan && !value.continuousReflow,
                continuousReflow: value.continuousReflow,
                landscape: state.landscapeAsSpread && !value.continuousReflow ? state.landscapePages : [], estimate: value.estimate)
            var preparedGeometry: Geometry?
            if explicitNaturalScroller, value.liveResizeViewport == nil {
                if naturalScrollbarKey != next || remeasure {
                    naturalScrollbarKey = next
                    // Like DisplayModel::Relayout, decide overflow from the full
                    // viewport, then reserve the bar before committing geometry.
                    // AppKit autohiding while restoring a tall chapter otherwise
                    // feeds alternating clip widths back into this same layout.
                    preparedGeometry = layoutGeometry(next)
                    let vertical = (preparedGeometry?.canvas.height ?? 0) > viewport.height
                    ReaderScrollbars.apply(to: self, mode: state.scrollbarMode,
                        horizontal: false, vertical: vertical, autohide: false)
                    tile()
                    next.viewport = contentView.bounds.size
                    if next.viewport != viewport { preparedGeometry = layoutGeometry(next) }
                } else if let key { next.viewport = key.viewport }
            }
            let target = pending?.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }
                .map { state.pageNumber($0) } ?? pending?.page ?? state.page
            let targetRow = PageRows.range(page: target, count: next.count, spread: next.spread,
                cover: next.cover, landscape: next.landscape).lowerBound
            let changed = key != next || remeasure || (ReadingZoom.usesContent(next.fit) && pending != nil && contentPage != targetRow)
            NativeReadingPerformance.mark("viewport-configure", pages: value.pages, revision: state.renderRevision,
                                          page: state.page, size: next.viewport,
                                          flags: (changed ? 1 : 0) | (value.liveResizeViewport == nil ? 0 : 2) | (value.continuousReflow ? 8 : 0)
                                              | (scrollerStyle == .legacy ? 16 : 0) | (NSScroller.preferredScrollerStyle == .legacy ? 32 : 0)
                                              | (autohidesScrollers ? 64 : 0))
            if changed {
                cancelPrediction()
                contentPage = targetRow
                key = next
                if let preparedGeometry {
                    geometry = preparedGeometry
                    canvas.frame = CGRect(origin: .zero, size: preparedGeometry.canvas)
                } else { relayout() }
                if let saved { go(to: saved) }
            } else if let pending { go(to: pending) }
            // Live resize uses the frozen layout until the drag ends. Replacing
            // its hosting roots on every clip-size update needlessly repaints
            // that same canvas and restarts SwiftUI reconciliation.
            updateCells(refresh: changed || value.liveResizeViewport == nil)
            if value.liveResizeViewport != nil { cancelPrediction() }
            arranging = false
            if case .pages(let current) = state.document?.content, current === value.pages { state.readerScrollView = self }
            schedulePosition()
        }
        override func layout() {
            super.layout()
            if key?.viewport != (owner?.liveResizeViewport ?? contentView.bounds.size) { schedulePosition() }
        }
        private func relayout() {
            guard let key else { return }
            geometry = layoutGeometry(key)
            canvas.frame = CGRect(origin: .zero, size: geometry?.canvas ?? key.viewport)
        }
        private func layoutGeometry(_ key: LayoutKey) -> Geometry? {
            guard let owner, key.viewport.width > 0, key.viewport.height > 0 else { return nil }
            let uniform = owner.state.reflowable && !key.continuousReflow && !key.trim && !key.uniform && key.landscape.isEmpty
                && measured.values.allSatisfy { $0.bounds == key.estimate }
            if uniform { locations.removeAll(); boxes.removeAll() }
            else {
                locations = (0..<key.count).map { owner.state.pageLocation($0) }
                boxes = locations.map { location in
                    let value = measured[location]
                    return key.trim ? value?.content ?? value?.bounds ?? key.estimate : value?.bounds ?? key.estimate
                }
            }
            func location(_ index: Int) -> PageLocation { uniform ? owner.state.pageLocation(index) : locations[index] }
            func box(_ index: Int) -> CGRect { uniform ? key.estimate : boxes[index] }
            // CalcZoomReal uses the requested row for content fit. Ordinary
            // scrolling keeps that scale and does not relayout the whole book.
            var contentScale: Double?
            if ReadingZoom.usesContent(key.fit), (0..<key.count).contains(contentPage) {
                let row = PageRows.range(page: contentPage, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                let facing = row.first(where: { $0 != contentPage }).map {
                    RasterLayout.FacingPage(bounds: box($0), content: measured[location($0)]?.content, before: $0 < contentPage)
                }
                let focusBox = box(contentPage)
                let size = RasterLayout.size(page: focusBox.size, viewport: key.viewport,
                    columns: owner.pages.isPDF && key.spread ? 2 : row.count, rotation: key.rotation, fit: key.fit, zoom: 1,
                    content: measured[location(contentPage)]?.content, limit: min(key.limit, 8), origin: focusBox.origin, facing: facing, rtl: key.rtl)
                contentScale = Double(size.width / (key.rotation % 180 == 0 ? focusBox.width : focusBox.height))
            }
            if uniform {
                func displaySize(columns: Int) -> CGSize {
                    let bounds = key.estimate
                    if let contentScale {
                        let size = key.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
                        let scale = min(contentScale, ReadingZoom.maximumCanvasExtent / Double(max(size.width, size.height)))
                        return CGSize(width: size.width * scale, height: size.height * scale)
                    }
                    return RasterLayout.size(page: bounds.size, viewport: key.viewport, columns: columns,
                        rotation: key.rotation, fit: key.fit, zoom: key.zoom, limit: key.limit, origin: bounds.origin)
                }
                return PageRows.uniformLayout(singleSize: displaySize(columns: 1), pairSize: displaySize(columns: 2),
                    count: key.count, viewport: key.viewport, spread: key.spread, cover: key.cover, rtl: key.rtl,
                    freePan: key.freePan, spacing: CGSize(width: 4, height: 4), inset: .zero).map(Geometry.uniform)
            }
            let rows = PageRows.ranges(count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
            var sizes = [CGSize](repeating: .zero, count: key.count)
            for row in rows {
                for index in row {
                    let value = measured[locations[index]]
                    if let contentScale {
                        let box = boxes[index]
                        let size = key.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
                        let scale = min(contentScale, ReadingZoom.maximumCanvasExtent / Double(max(size.width, size.height)))
                        sizes[index] = CGSize(width: size.width * scale, height: size.height * scale)
                    } else {
                        sizes[index] = RasterLayout.size(page: boxes[index].size, viewport: key.viewport,
                            columns: owner.pages.isPDF && key.spread ? 2 : row.count, rotation: key.rotation, fit: key.fit, zoom: key.zoom,
                            content: value?.content, limit: key.limit, uniformWidth: key.uniform ? value?.referenceWidth : nil, origin: boxes[index].origin, continuous: key.continuousReflow)
                    }
                }
            }
            return .listed(PageRows.layout(displaySizes: sizes, viewport: key.viewport, page: owner.state.page,
                continuous: true, spread: key.spread, cover: key.cover, rtl: key.rtl, landscape: key.landscape,
                freePan: key.freePan, spacing: CGSize(width: 4, height: key.continuousReflow ? 0 : 4), inset: .zero))
        }
        private func rowFrame(_ row: Range<Int>) -> CGRect {
            row.reduce(CGRect.null) { result, index in geometry?.frame(page: index).map { result.union($0) } ?? result }
        }
        // Rows have fixed coordinates until an actual layout/measurement change.
        // Reuse the PDF adapter's binary search; scrolling never walks the book.
        private func row(at y: CGFloat) -> Int {
            geometry?.row(atY: y, frame: rowFrame) ?? 0
        }
        private func location(_ index: Int) -> PageLocation {
            if case .some(.uniform(_)) = geometry { return owner!.state.pageLocation(index) }
            return locations[index]
        }
        private func box(_ index: Int) -> CGRect {
            if case .some(.uniform(_)) = geometry { return key!.estimate }
            return boxes[index]
        }
        private func position() -> ReadingPosition? {
            guard let owner, let key, let geometry, geometry.rowCount > 0 else { return nil }
            let range = geometry.range(row: row(at: contentView.bounds.minY)), index = range.lowerBound
            guard let frame = geometry.frame(page: index) else { return nil }
            var point = contentView.bounds.origin
            if !key.freePan {
                point.x = max(rowFrame(range).minX, point.x)
                point.y = max(frame.minY, point.y)
            }
            point.x -= frame.minX; point.y -= frame.minY
            point = point.applying(RasterLayout.transform(bounds: box(index), size: frame.size, rotation: key.rotation).inverted())
            let location = location(index)
            let extent = canvas.bounds.height - contentView.bounds.height
            let fraction = key.continuousReflow ? (extent > 0 ? Double(min(1, max(0, (contentView.bounds.minY - canvas.bounds.minY) / extent))) : 1) : nil
            return ReadingPosition(page: owner.state.pageNumber(location), scrollFraction: fraction, x: Double(point.x), y: Double(point.y),
                anchor: owner.state.reflowable ? owner.state.chapterLayout?.bookmark(location) : nil)
        }
        private func go(to position: ReadingPosition) {
            guard let owner, let key, let geometry, geometry.pageCount > 0 else { return }
            let index = position.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }
                .map { owner.state.pageNumber($0) } ?? position.page
            guard (0..<geometry.pageCount).contains(index), let frame = geometry.frame(page: index) else { return }
            let transform = RasterLayout.transform(bounds: box(index), size: frame.size, rotation: key.rotation)
            let origin = CGPoint.zero.applying(transform.inverted())
            var fallback = origin
            if ReadingZoom.usesContent(key.fit) {
                let row = PageRows.range(page: index, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                let content = row.reduce(CGRect.null) { union, page in
                    guard let placed = geometry.frame(page: page) else { return union }
                    let bounds = box(page)
                    let fitted = RasterLayout.fitContent(measured[location(page)]?.content, bounds: bounds, mode: key.fit) ?? bounds
                    let rect = fitted.applying(RasterLayout.transform(bounds: bounds, size: placed.size, rotation: key.rotation))
                        .offsetBy(dx: placed.minX, dy: placed.minY)
                    return union.union(rect)
                }
                fallback = CGPoint(x: content.minX - frame.minX, y: content.minY - frame.minY).applying(transform.inverted())
            }
            let point = CGPoint(x: position.x ?? Double(fallback.x), y: position.y ?? Double(fallback.y)).applying(transform)
            var bounds = contentView.bounds
            bounds.origin = CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)
            // DocumentLayout centers a narrow canvas in the usable clip width,
            // after the native scrollers have taken their space.
            if geometry.canvas.width <= bounds.width { bounds.origin.x = 0 }
            contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
            reflectScrolledClipView(contentView)
        }
        // SelectionOnPage::FromRectangle uses the existing page placements;
        // include crossed pages even when their views were scrolled off screen.
        func selectionAreas(in rect: CGRect) -> [PageLocation: CGRect] {
            guard let key, let geometry, geometry.rowCount > 0, !rect.isEmpty else { return [:] }
            var result = [PageLocation: CGRect]()
            let first = geometry.range(row: row(at: rect.minY)).lowerBound
            let last = geometry.range(row: row(at: rect.maxY)).upperBound
            for index in first..<last {
                guard let frame = geometry.frame(page: index) else { continue }
                let intersection = rect.intersection(frame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let local = intersection.offsetBy(dx: -frame.minX, dy: -frame.minY)
                result[location(index)] = local.applying(RasterLayout.transform(bounds: box(index),
                    size: frame.size, rotation: key.rotation).inverted())
            }
            return result
        }
        private func updateCells(refresh: Bool = false) {
            guard let owner, let key, let geometry, geometry.rowCount > 0 else { return }
            let visible = contentView.bounds
            var needed = [(index: Int, columns: Int)]()
            for rowIndex in row(at: visible.minY)..<geometry.rowCount {
                let range = geometry.range(row: rowIndex)
                if rowFrame(range).minY > visible.maxY { break }
                // Retain both halves of a visible spread: its taller page owns
                // the row height, even when the logical first page is shorter.
                needed += range.map { ($0, range.count) }
            }
            // Like the PDF viewport, retain the source of an active drag or
            // selection after it leaves the viewport; its responder owns it.
            var visibleIDs = Set(needed.map { location($0.index) })
            // A source destination can extend beyond an unseen chapter's
            // estimated height. Measure its row before consuming the jump.
            if let request = owner.request?.position {
                let target = request.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }
                    .map { owner.state.pageNumber($0) } ?? request.page
                if (0..<geometry.pageCount).contains(target) {
                    let range = PageRows.range(page: target, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                    for index in range where !visibleIDs.contains(location(index)) {
                        needed.append((index, range.count)); visibleIDs.insert(location(index))
                    }
                }
            }
            if owner.state.nativePDFFormEditor != nil, let index = owner.state.nativePDFFormPage,
               (0..<geometry.pageCount).contains(index), !visibleIDs.contains(location(index)) {
                let range = PageRows.range(page: index, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                needed.append((index, range.count))
                visibleIDs.insert(location(index))
            }
            if let responder = window?.firstResponder as? NSView {
                for (location, view) in cells where !visibleIDs.contains(location) && responder.isDescendant(of: view) {
                    let index = owner.state.pageNumber(location)
                    guard (0..<geometry.pageCount).contains(index), self.location(index) == location else { continue }
                    let range = PageRows.range(page: index, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                    needed.append((index, range.count))
                }
            }
            // AX focus is independent of NSWindow.firstResponder. Retain at
            // most one already-mounted focused reading page through scrolling.
            if let (focusedLocation, _) = cells.first(where: { RasterCanvas.Canvas.hasReadingAccessibilityFocus(in: $0.value) }),
               !needed.contains(where: { location($0.index) == focusedLocation }) {
                let index = owner.state.pageNumber(focusedLocation)
                if (0..<geometry.pageCount).contains(index), location(index) == focusedLocation {
                    let range = PageRows.range(page: index, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                    needed.append((index, range.count))
                }
            }
            let ids = Set(needed.map { location($0.index) })
            for (location, view) in cells where !ids.contains(location) { view.removeFromSuperview(); cells[location] = nil }
            for item in needed {
                let index = item.index, location = location(index)
                guard let frame = geometry.frame(page: index) else { continue }
                let page = page(at: index, columns: item.columns)
                if let view = cells[location] {
                    if refresh { view.rootView = page }
                    view.frame = frame
                } else {
                    let view = NSHostingView(rootView: page)
                    view.sizingOptions = []
                    view.frame = frame
                    cells[location] = view; canvas.addSubview(view)
                }
            }
            // Visible hosts enqueue their tasks first. The directional chain
            // can then overlap their decoding without waiting for a draw pass.
            DispatchQueue.main.async { [weak self] in self?.predictPages() }
        }
        private func page(at index: Int, columns: Int) -> RasterPage {
            let owner = owner!, key = key!, location = location(index)
            let frame = geometry!.frame(page: index)!
            return RasterPage(state: owner.state, pages: owner.pages, index: index, location: location,
                    viewport: key.viewport, scale: owner.scale, continuousReflow: key.continuousReflow,
                    columns: owner.pages.isPDF && key.spread ? 2 : columns, facingPage: nil,
                    match: owner.match?.contains(index) == true ? owner.match : nil, scrollRequest: owner.$request,
                    cancelNavigation: owner.cancelNavigation, selections: owner.selections,
                    estimate: measured[location]?.bounds ?? key.estimate, updateEstimate: owner.updateEstimate,
                    didRender: owner.didRender, didPaintMatch: owner.didPaintMatch, displaySize: ReadingZoom.usesContent(key.fit) ? frame.size : nil,
                    measure: { [weak self] bounds, content, reference in
                        self?.measure(location, value: Measurement(bounds: bounds, content: content, referenceWidth: reference))
                    })
        }
        private func cancelPrediction() {
            predictionTask?.cancel(); predictionTask = nil; prediction = nil
        }
        func visibleCanvasesArePainted() -> Bool {
            guard let owner, let geometry, geometry.rowCount > 0, owner.liveResizeViewport == nil else { return false }
            let visible = contentView.bounds
            for row in row(at: visible.minY)...row(at: visible.maxY) where rowFrame(geometry.range(row: row)).intersects(visible) {
                for index in geometry.range(row: row) {
                    guard let host = cells[location(index)], let canvas = RasterCanvas.Canvas.find(in: host),
                          canvas.readingReady, canvas.viewportTileSize != nil || canvas.hasPaintedPreview else { return false }
                }
            }
            return true
        }
        func predictNaturalTileAfterPainting() {
            guard let owner, let key, let geometry, key.continuousReflow,
                  owner.request == nil, window != nil,
                  case .pages(let current) = owner.state.document?.content, current === owner.pages,
                  visibleCanvasesArePainted() else { return }
            let visible = contentView.bounds
            let rows = (row(at: visible.minY)...row(at: visible.maxY))
                .filter { rowFrame(geometry.range(row: $0)).intersects(visible) }
            guard let edge = scrollDirection > 0 ? rows.last : rows.first else { return }
            let range = geometry.range(row: edge)
            let index = scrollDirection > 0 ? range.upperBound - 1 : range.lowerBound
            guard let host = cells[location(index)], let canvas = RasterCanvas.Canvas.find(in: host) else { return }
            canvas.predictViewportTile(direction: scrollDirection)
        }
        func predictPages() {
            guard let owner, let key, let geometry, !key.continuousReflow,
                  owner.liveResizeViewport == nil, owner.request == nil, window != nil,
                  case .pages(let current) = owner.state.document?.content, current === owner.pages,
                  geometry.rowCount > 0 else { return }
            let visible = contentView.bounds
            let rows = (row(at: visible.minY)...row(at: visible.maxY))
                .filter { rowFrame(geometry.range(row: $0)).intersects(visible) }
            guard let first = rows.first, let last = rows.last else { return }
            let next = scrollDirection > 0 ? last + 1 : first - 1
            guard (0..<geometry.rowCount).contains(next) else { cancelPrediction(); return }
            let ahead = visible.offsetBy(dx: 0, dy: CGFloat(scrollDirection) * visible.height)
            var targets = [RasterPage]()
            for rowIndex in stride(from: next, to: scrollDirection > 0 ? geometry.rowCount : -1, by: scrollDirection) {
                let range = geometry.range(row: rowIndex)
                guard rowFrame(range).intersects(ahead) else { break }
                let indices = scrollDirection > 0 ? Array(range) : Array(range.reversed())
                targets += indices.map { page(at: $0, columns: range.count) }
            }
            guard let page = targets.first else { cancelPrediction(); return }
            let token = Prediction(document: owner.state.document?.id, layout: key,
                location: page.location, render: page.renderID)
            guard prediction != token else { return }
            cancelPrediction(); prediction = token
            // Like RenderCache's predictive chain, decode the next viewport
            // sequentially at background priority, including both spread pages.
            // Encoded data stays with Archive; previews share the byte budget.
            // No offscreen view or accessibility children are mounted.
            predictionTask = Task(priority: .utility) { [weak self] in
                do {
                    for page in targets {
                        guard !Task.isCancelled, let self, self.prediction == token else { return }
                        NativeReadingPerformance.mark("page-prediction-start", pages: page.pages, revision: key.revision, page: page.index)
                        _ = try await page.renderResult(preheating: true)
                        NativeReadingPerformance.mark("page-prediction-ready", pages: page.pages, revision: key.revision, page: page.index)
                    }
                    if let self, self.prediction == token { self.predictionTask = nil }
                } catch {
                    // A speculative failure must not replace the current book
                    // with an error. The visible request reports real failures.
                    if let self, self.prediction == token { self.predictionTask = nil }
                }
            }
        }
        private func measure(_ location: PageLocation, value: Measurement) {
            guard let owner, measured[location] != value else { schedulePosition(); return }
            let saved = owner.request?.position ?? position()
            measured[location] = value
            if key?.count != owner.state.count || key?.generation != (owner.state.chapterLayout?.generation ?? 0) {
                configure(owner)
                return
            }
            let index = owner.state.pageNumber(location)
            if let key, let geometry, (0..<geometry.pageCount).contains(index), self.location(index) == location,
               let frame = geometry.frame(page: index) {
                let box = key.trim ? value.content ?? value.bounds : value.bounds
                let row = PageRows.range(page: index, count: key.count, spread: key.spread, cover: key.cover, landscape: key.landscape)
                let size = RasterLayout.size(page: box.size, viewport: key.viewport, columns: owner.pages.isPDF && key.spread ? 2 : row.count,
                    rotation: key.rotation, fit: key.fit, zoom: key.zoom, content: value.content,
                    limit: key.limit, uniformWidth: key.uniform ? value.referenceWidth : nil, origin: box.origin, continuous: key.continuousReflow)
                // Most reflow pages share the known media box. Rendering one
                // must not rebuild tens of thousands of unchanged page frames.
                var changedUniformBounds = false
                if case .some(.uniform(_)) = self.geometry { changedUniformBounds = value.bounds != key.estimate }
                if !changedUniformBounds && (ReadingZoom.usesContent(key.fit)
                    ? (!row.contains(contentPage) && box == self.box(index)) : size == frame.size) {
                    if case .some(.listed(_)) = self.geometry { boxes[index] = box }
                    schedulePosition()
                    return
                }
            }
            if explicitNaturalScroller { configure(owner, remeasure: true); return }
            arranging = true
            relayout()
            if let saved { go(to: saved) }
            updateCells(refresh: true)
            arranging = false
            schedulePosition()
        }
        private func viewportChanged() {
            guard !arranging else { return }
            let y = contentView.bounds.minY
            if y != lastScrollY { scrollDirection = y > lastScrollY ? 1 : -1; lastScrollY = y }
            if let prediction, let key, let geometry, let owner {
                let first = row(at: contentView.bounds.minY), last = row(at: contentView.bounds.maxY)
                let next = scrollDirection > 0 ? last + 1 : first - 1
                let visible = geometry.range(row: first).lowerBound..<geometry.range(row: last).upperBound
                let target = owner.state.pageNumber(prediction.location)
                let neighbor = (0..<geometry.rowCount).contains(next) ? geometry.range(row: next) : 0..<0
                if prediction.layout != key || (!visible.contains(target) && !neighbor.contains(target)) {
                    cancelPrediction()
                }
            }
            if key?.viewport == contentView.bounds.size { updateCells() }
            for host in cells.values {
                RasterCanvas.Canvas.find(in: host)?.updatePredictionDirection(scrollDirection)
            }
            schedulePosition()
        }
        private func schedulePosition() {
            guard !positionScheduled else { return }
            positionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                self.positionScheduled = false
                if self.key?.revision != owner.state.renderRevision ||
                    self.key?.viewport != (owner.liveResizeViewport ?? self.contentView.bounds.size) || self.key?.count != owner.state.count ||
                    self.key?.generation != (owner.state.chapterLayout?.generation ?? 0) {
                    self.configure(owner); return
                }
                // Mount the measured canvas before publishing its clip size.
                // An empty document temporarily hides an automatic legacy bar.
                let size = self.contentView.safeAreaRect.size
                if size.width > 0, size.height > 0 { owner.didResizeViewport(size) }
                if let request = owner.request?.position {
                    let location = request.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location }
                        ?? owner.state.pageLocation(request.page)
                    guard self.measured[location] != nil else { return }
                    if let key = self.key, ReadingZoom.usesContent(key.fit) {
                        let row = PageRows.range(page: owner.state.pageNumber(location), count: key.count,
                            spread: key.spread, cover: key.cover, landscape: key.landscape)
                        guard row.allSatisfy({ self.measured[self.location($0)] != nil }) else { return }
                    }
                    // The first scroll may use estimated page geometry. Apply
                    // the original destination with measured bounds/content
                    // before consuming it, including authored FitBH/FitBV axes.
                    // A command can arrive before SwiftUI updates this view.
                    // Apply its target row and fit through the layout owner
                    // before consuming the request.
                    self.configure(owner)
                    owner.request = nil
                }
                self.recordPosition()
            }
        }
        func recordPosition() {
            guard !arranging, let owner, owner.request == nil, let position = position(),
                  case .pages(let current) = owner.state.document?.content, current === owner.pages else { return }
            owner.state.updatePosition(position, preservingNativePassage: true)
            let location = owner.state.pageLocation(position.page)
            if let host = cells[location], let view = RasterCanvas.Canvas.find(in: host) { owner.state.readerFocusView = view }
        }
    }
}

@MainActor private struct RasterPage: View {
    struct FinitePrediction: Equatable {
        let target: PageLocation
        let visible: Set<PageLocation>
        let columns: Int
        let facingPage: Int?
    }
    @ObservedObject var state: ReaderState
    let pages: Pages, index: Int, location: PageLocation, viewport: CGSize, scale: CGFloat
    let continuousReflow: Bool
    let columns: Int
    let facingPage: Int?
    let match: RasterMatch?
    @Binding var scrollRequest: RasterScrollRequest?
    let cancelNavigation: () -> Void
    let selections: RasterSelections
    let estimate: CGRect
    let updateEstimate: (CGRect) -> Void
    let didRender: () -> Void
    var didPaintMatch: ((RasterMatch) -> Void)? = nil
    var displaySize: CGSize? = nil
    var measure: ((CGRect, CGRect?, CGFloat?) -> Void)?
    var didResizeViewport: ((CGSize) -> Void)?
    var finitePrediction: FinitePrediction? = nil
    @State private var measuredBounds: CGRect?
    @State private var content: CGRect?
    @State private var referenceWidth: CGFloat?
    @State private var facing: RasterLayout.FacingPage?
    @State private var image: CGImage?
    @State private var imageCollection = false
    @State private var pixelWidth = 0
    @State private var tileResolution = 0
    @State private var renderedID = ""
    @State private var links = [RasterLink]()
    @State private var pdfAnnotations = [PDFAnnotationSnapshot]()
    @State private var pdfLinks = [PDFLinkSnapshot]()
    @State private var imageBounds = [CGRect]()
    @State private var pageBoxes = [CGRect?]()
    @State private var renderedStyle: PDFColors.Style?
    private var bounds: CGRect { measuredBounds ?? estimate }
    private var pdfStyle: PDFColors.Style? {
        guard pages.isPDF else { return nil }
        var style = state.pdfColorStyle
        // Image bounds are already drawn by the existing canvas overlay.
        style.showImageBounds = false
        return style
    }
    // Local measurements and computed zoom are outputs. Continuous content fit
    // instead receives its authoritative display size from the viewport owner.
    private var viewportTileSize: CGSize? {
        guard continuousReflow else { return nil }
        let size = CGSize(width: viewport.width * scale, height: viewport.height * scale)
        return state.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
    var renderID: String {
        "\(viewport):\(scale):\(columns):\(String(describing: facingPage)):\(String(describing: displaySize)):\(state.rotation):\(state.rtl):\(state.fit):\(state.fit == "custom" ? state.rasterZoom : 1):\(state.configuredZoomMaximum):\(state.trimEmptyMargins):\(state.showFitContentArea):\(state.uniformPageWidth):\(state.showTransparencyGrid):\(String(describing: pdfStyle)):\(state.engineeringEnhance):\(state.renderRevision):\(continuousReflow)"
    }
    func renderResult(_ prediction: FinitePrediction? = nil, preheating: Bool = false) async throws -> Pages.RenderedPage {
        return try await pages.render(prediction?.target ?? location, viewport: viewport, scale: scale, columns: prediction?.columns ?? columns,
                        rotation: state.rotation, fit: state.fit, zoom: state.rasterZoom, maximumZoom: state.configuredZoomMaximum,
                        trim: state.trimEmptyMargins && !continuousReflow, showContent: state.showFitContentArea,
                        uniform: state.uniformPageWidth && !continuousReflow, transparent: state.showTransparencyGrid,
                        pdfStyle: pdfStyle, engineeringAuto: state.engineeringEnhance == "auto",
                        maximumTileSize: NSScreen.main.map { CGSize(width: $0.frame.width * scale, height: $0.frame.height * scale) }, facingPage: prediction?.facingPage ?? facingPage, displaySize: prediction == nil ? displaySize : nil, rtl: state.rtl, viewportOnly: continuousReflow, preheating: preheating)
    }
    var body: some View {
        let visible = state.trimEmptyMargins && !continuousReflow ? content ?? bounds : bounds
        let size = displaySize ?? RasterLayout.size(page: visible.size, viewport: viewport, columns: columns, rotation: state.rotation, fit: state.fit, zoom: state.rasterZoom, content: content, limit: state.zoomLimit, uniformWidth: state.uniformPageWidth ? referenceWidth : nil, origin: visible.origin, facing: facing, rtl: state.rtl, continuous: continuousReflow)
        RasterCanvas(state: state, pages: pages, page: index, location: location, image: image, imageCollection: imageCollection, readingReady: renderedID == renderID && (image != nil || continuousReflow), pixelWidth: pixelWidth, tileResolution: renderedID == renderID ? tileResolution : 0, pdfStyle: renderedStyle, imageBounds: imageBounds, pageBoxes: pageBoxes, contentBounds: content, pageBounds: bounds, visibleBounds: visible, links: links, pdfAnnotations: pdfAnnotations, pdfLinks: pdfLinks, match: match, rotation: state.rotation, request: $scrollRequest, cancelNavigation: cancelNavigation, displaySize: size, focus: index == state.page ? RasterLayout.contentFocus(bounds: visible, content: content, display: size, rotation: state.rotation, mode: state.fit, facing: facing, rtl: state.rtl) : nil, selections: selections, didResizeViewport: didResizeViewport, didPaint: didRender, didPaintMatch: didPaintMatch, viewportTileSize: viewportTileSize, finitePrediction: finitePrediction, predictionID: renderID, renderPredictedPage: finitePrediction.map { prediction in { _ = try await renderResult(prediction, preheating: true) } })
            .frame(width: size.width, height: size.height)
            .task(id: state.renderRevision) {
                guard pages.isPDF else { return }
                let documentID = state.document?.id, revision = state.renderRevision
                do {
                    let annotations = try await pages.pdfAnnotations(index)
                    let links = try await pages.pdfLinks(index)
                    guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                    pdfAnnotations = annotations; pdfLinks = links
                } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
            }
            .task(id: "\(state.showImageBounds):\(state.showPageBoxes):\(state.renderRevision)") {
                let documentID = state.document?.id, revision = state.renderRevision
                do {
                    let rects = state.showImageBounds ? try await pages.imageBounds(location) : []
                    let boxes = pages.isPDF && state.showPageBoxes ? try await pages.pdfPageBoxes(index) : []
                    guard !Task.isCancelled, documentID == state.document?.id, revision == state.renderRevision else { return }
                    imageBounds = rects; pageBoxes = boxes
                } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
            }
            .task(id: renderID) {
                let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Render visible page")
                defer { ProcessInfo.processInfo.endActivity(activity) }
                let documentID = state.document?.id, request = renderID
                NativeReadingPerformance.mark("render-request", pages: pages, revision: state.renderRevision, page: index,
                                              size: viewport, flags: continuousReflow ? 8 : 0)
                if let displaySize {
                    NativeReadingPerformance.mark("render-display-size", pages: pages, revision: state.renderRevision,
                                                  page: index, size: displaySize)
                }
                do {
                    let result = try await renderResult()
                    guard !Task.isCancelled, documentID == state.document?.id, request == renderID else { return }
                    NativeReadingPerformance.mark("render-publish", pages: pages, revision: state.renderRevision, page: index)
                    if result.imageCollection {
                        // Concurrent visible-page measurements can finish in a
                        // different order; an older snapshot must not remove a
                        // landscape page already discovered at this rotation.
                        if !result.landscape.isSubset(of: state.landscapePages) { state.landscapePages.formUnion(result.landscape) }
                        updateEstimate(result.estimate)
                    }
                    if state.zoomLimit != result.limit {
                        state.zoomLimit = result.limit
                        if state.fit == "custom" { state.zoom = ReadingZoom.clamp(state.zoom, limit: result.limit) }
                    }
                    measuredBounds = result.bounds; content = result.content; referenceWidth = result.referenceWidth; facing = result.facing
                    let measured = result.bounds, visible = state.trimEmptyMargins && !continuousReflow ? result.content ?? measured : measured
                    if location == state.pageLocation(state.page) {
                        state.pageFitZoom = Double(RasterLayout.size(page: visible.size, viewport: viewport, columns: columns, rotation: state.rotation, fit: "page", zoom: 1, limit: result.limit, origin: visible.origin, facing: result.facing, continuous: continuousReflow).width / (state.rotation % 180 == 0 ? visible.width : visible.height))
                        state.widthFitZoom = Double(RasterLayout.size(page: visible.size, viewport: viewport, columns: columns, rotation: state.rotation, fit: "width", zoom: 1, limit: result.limit, origin: visible.origin, facing: result.facing, continuous: continuousReflow).width / (state.rotation % 180 == 0 ? visible.width : visible.height))
                        if !pages.isMarkdown, state.fit != "custom", !(state.uniformPageWidth && state.fit == "actual") { state.zoom = Double(result.display.width / (state.rotation % 180 == 0 ? visible.width : visible.height)) }
                    }
                    image = result.image; links = result.links; imageCollection = result.imageCollection
                    renderedStyle = result.pdfStyle
                    pixelWidth = result.pixelWidth; tileResolution = result.tileResolution; renderedID = request
                    measure?(result.bounds, result.content, result.referenceWidth)
                } catch is CancellationError {
                    NativeReadingPerformance.mark("render-cancelled", pages: pages, revision: state.renderRevision,
                                                  page: index, size: viewport)
                    // The actor can supersede this surface before SwiftUI
                    // cancels its task. Keep its painted output until handoff.
                } catch { if !Task.isCancelled, documentID == state.document?.id { state.error = error.localizedDescription } }
            }
            .onDisappear { image = nil }
    }
}

// Native paint has no text subviews. Keep assistive reading in the same page
// lifetime as its canvas, using the decoder's selection text and glyph positions.
struct NativeReadingAccessibilitySnapshot {
    let text: NSString
    let glyphs: [(range: NSRange, bounds: CGRect)]
    let lines: [NSRange]

    init(words: [RasterWord]) {
        text = words.map(\.text).joined() as NSString
        var glyphs = [(range: NSRange, bounds: CGRect)](), lines = [NSRange]()
        var offset = 0, lineStart = 0
        var previous: CGRect?
        for word in words {
            let length = word.text.utf16.count, box = word.bounds
            // Flattened text preserves paragraphs, but painted wraps need
            // consecutive glyph geometry. Preserve native order (also for RTL).
            if !box.isEmpty, let last = previous,
               min(box.maxY, last.maxY) <= max(box.minY, last.minY) {
                if offset > lineStart { lines.append(NSRange(location: lineStart, length: offset-lineStart)) }
                lineStart = offset
            }
            glyphs.append((NSRange(location: offset, length: length), box))
            offset += length
            if word.text.contains("\n") || word.text.contains("\r") {
                lines.append(NSRange(location: lineStart, length: offset-lineStart))
                lineStart = offset; previous = nil
            } else if !box.isEmpty { previous = box }
        }
        if offset > lineStart { lines.append(NSRange(location: lineStart, length: offset-lineStart)) }
        self.glyphs = glyphs; self.lines = lines
    }
    func contains(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location <= text.length && range.length >= 0 && range.length <= text.length-range.location
    }
    func bounds(for range: NSRange) -> CGRect {
        guard contains(range) else { return .zero }
        let boxes = glyphs.filter { !$0.bounds.isEmpty && NSIntersectionRange($0.range, range).length > 0 }
        return boxes.reduce(CGRect.null) { $0.union($1.bounds) }.standardized
    }
    func visibleRange(in bounds: CGRect) -> NSRange {
        let visible = glyphs.filter { !$0.bounds.isEmpty && $0.bounds.intersects(bounds) }
        guard let first = visible.first, let last = visible.last else { return NSRange(location: 0, length: 0) }
        return NSRange(location: first.range.location, length: NSMaxRange(last.range)-first.range.location)
    }
}

@MainActor @objcMembers final class NativeReadingAccessibilityPage: NSObject, @preconcurrency NSAccessibilityNavigableStaticText {
    struct Identity: Equatable {
        let pages: ObjectIdentifier
        let document: UUID?
        let location: PageLocation
        let revision: Int
        var region: CGRect? = nil
    }
    weak var view: NSView?
    var transform = CGAffineTransform.identity
    var pageLabel = ""
    private(set) var snapshot: NativeReadingAccessibilitySnapshot?
    private var identity: Identity?
    private var task: Task<Void, Never>?
    private var focused = false

    func update(identity: Identity, allowed: Bool, words: @escaping () async throws -> [RasterWord], failure: @escaping (Error) -> Void) {
        guard allowed else { clear(); return }
        guard self.identity != identity else { return }
        clear(); self.identity = identity
        let scheduled = DispatchTime.now().uptimeNanoseconds
        NativeReadingPerformance.mark("ax-task-scheduled", pagesIdentity: identity.pages,
            revision: identity.revision, page: identity.location.page, size: identity.region?.size ?? .zero)
        task = Task { [weak self] in
            do {
                NativeReadingPerformance.mark("ax-task-entry", pagesIdentity: identity.pages,
                    revision: identity.revision, page: identity.location.page, started: scheduled)
                let words = try await words()
                guard !Task.isCancelled, let self, self.identity == identity else { return }
                let snapshotStarted = DispatchTime.now().uptimeNanoseconds
                NativeReadingPerformance.mark("ax-snapshot-entry", pagesIdentity: identity.pages,
                    revision: identity.revision, page: identity.location.page)
                self.snapshot = NativeReadingAccessibilitySnapshot(words: words)
                NativeReadingPerformance.mark("ax-snapshot-publish", pagesIdentity: identity.pages,
                    revision: identity.revision, page: identity.location.page, started: snapshotStarted)
                self.task = nil
                if let view = self.view, view.window != nil {
                    NSAccessibility.post(element: self, notification: .valueChanged)
                    NSAccessibility.post(element: view, notification: .layoutChanged)
                }
            } catch {
                guard !Task.isCancelled, let self, self.identity == identity else { return }
                self.task = nil
                failure(error)
            }
        }
    }
    func clear() {
        let hadText = snapshot != nil
        task?.cancel(); task = nil; identity = nil; snapshot = nil
        if hadText, let view, view.window != nil { NSAccessibility.post(element: view, notification: .layoutChanged) }
    }
    func invalidate(unless identity: Identity) {
        if self.identity != identity { clear() }
    }
    func accessibilityParent() -> Any? { view }
    func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    func isAccessibilityElement() -> Bool { snapshot?.text.length ?? 0 > 0 }
    func accessibilityLabel() -> String? { pageLabel }
    func accessibilityValue() -> String? { snapshot?.text as String? }
    func isAccessibilityFocused() -> Bool { focused }
    func setAccessibilityFocused(_ focused: Bool) { self.focused = focused }
    func accessibilityFrame() -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
    func accessibilityString(for range: NSRange) -> String? {
        guard let snapshot, snapshot.contains(range) else { return nil }
        return snapshot.text.substring(with: range)
    }
    func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }
    func accessibilityLine(for index: Int) -> Int {
        guard let snapshot, index >= 0, index < snapshot.text.length else { return NSNotFound }
        return snapshot.lines.firstIndex { NSLocationInRange(index, $0) } ?? NSNotFound
    }
    func accessibilityRange(forLine line: Int) -> NSRange {
        guard let snapshot, snapshot.lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        return snapshot.lines[line]
    }
    func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let snapshot, let view, let window = view.window else { return .zero }
        let box = snapshot.bounds(for: range)
        guard !box.isNull, !box.isEmpty else { return .zero }
        return window.convertToScreen(view.convert(box.applying(transform), to: nil))
    }
    func accessibilityVisibleCharacterRange() -> NSRange {
        guard let snapshot, let view else { return NSRange(location: 0, length: 0) }
        return snapshot.visibleRange(in: view.visibleRect.applying(transform.inverted()))
    }
}

@MainActor struct RasterCanvas: NSViewRepresentable {
    let state: ReaderState, pages: Pages, page: Int
    let location: PageLocation
    let image: CGImage?
    let imageCollection: Bool
    let readingReady: Bool
    let pixelWidth: Int, tileResolution: Int
    let pdfStyle: PDFColors.Style?
    let imageBounds: [CGRect]
    let pageBoxes: [CGRect?]
    let contentBounds: CGRect?
    let pageBounds: CGRect, visibleBounds: CGRect, links: [RasterLink]
    let pdfAnnotations: [PDFAnnotationSnapshot]
    let pdfLinks: [PDFLinkSnapshot]
    let match: RasterMatch?, rotation: Int
    @Binding fileprivate var request: RasterScrollRequest?
    let cancelNavigation: () -> Void
    let displaySize: CGSize
    let focus: CGRect?
    @ObservedObject fileprivate var selections: RasterSelections
    let didResizeViewport: ((CGSize) -> Void)?
    let didPaint: () -> Void
    var didPaintMatch: ((RasterMatch) -> Void)? = nil
    var viewportTileSize: CGSize? = nil
    fileprivate var finitePrediction: RasterPage.FinitePrediction? = nil
    var predictionID = ""
    var renderPredictedPage: (@MainActor () async throws -> Void)? = nil
    func makeNSView(context: Context) -> Canvas { Canvas() }
    func updateNSView(_ view: Canvas, context: Context) {
        let imageChanged = view.image !== image
        let predictionToken = finitePrediction.map {
            Canvas.FinitePredictionToken(document: state.document?.id, source: location, render: predictionID, request: $0)
        }
        if view.finitePredictionToken != predictionToken { view.cancelFinitePrediction() }
        view.finitePredictionToken = predictionToken
        view.renderPredictedPage = renderPredictedPage
        if view.pages !== pages || view.tileDocumentID != state.document?.id || view.location != location ||
            (view.viewportTileSize != nil && viewportTileSize == nil) {
            view.clearTiles()
        }
        view.tileDocumentID = state.document?.id
        if view.pages !== pages || view.location != location || (view.comment != nil && view.renderRevision != state.renderRevision) ||
            view.rotation != rotation || view.lastDisplaySize != displaySize ||
            view.commentDocumentID != state.document?.id || !state.annotationsVisible {
            view.closeComment()
        }
        if view.location != location || (focus != nil && (view.lastDisplaySize != displaySize || view.lastFocus != focus || view.rotation != rotation)) {
            view.lastRequest = nil
        }
        view.lastDisplaySize = displaySize; view.lastFocus = focus
        view.state = state; view.pages = pages; view.page = page; view.location = location; view.image = image; view.pageBounds = pageBounds
        view.imageCollection = imageCollection
        view.renderingReady = readingReady
        view.viewportTileSize = viewportTileSize
        view.readingReady = readingReady && viewportTileSize == nil
        view.pixelWidth = pixelWidth; view.tileResolution = tileResolution
        view.pdfStyle = pdfStyle
        view.scrollRequest = $request
        view.cancelNavigation = cancelNavigation
        view.didResizeViewport = didResizeViewport
        view.didPaint = didPaint
        view.didPaintMatch = didPaintMatch
        view.imageBounds = imageBounds
        view.pageBoxes = pageBoxes
        view.contentBounds = contentBounds
        view.visibleBounds = visibleBounds
        view.selections = selections
        if view.bounds.width > 0, view.bounds.height > 0 { selections.visibleBounds[location] = view.visibleRect.applying(view.pageTransform.inverted()) }
        if let scroll = view.enclosingScrollView, case .pages(let current) = state.document?.content, current === pages {
            state.readerScrollView = scroll
            let documentID = state.document?.id
            if pages.isPDF {
                state.nativePDFInverseSearchPosition = { [weak scroll, weak state] in
                    guard state?.document?.id == documentID, let scroll, scroll.window != nil else { return nil }
                    return Canvas.pasteTarget(in: scroll)
                }
                state.nativePDFCursorPosition = { [weak scroll, weak state] point in
                    guard state?.document?.id == documentID, let scroll, scroll.window != nil else { return nil }
                    return Canvas.cursorPosition(in: scroll, at: point)
                }
            }
            state.selectionScreenBounds = { [weak scroll, weak state] in
                guard state?.document?.id == documentID, let document = scroll?.documentView else { return nil }
                return Canvas.selectionScreenBounds(in: document)
            }
            // The continuous viewport owns its scrollbar axes and geometry.
            if !(scroll is RasterViewport.Scroll) { ReaderScrollbars.apply(to: scroll, mode: state.scrollbarMode) }
            if page == state.page {
                state.readerFocusView = view
                if state.contentsNeedsFocusTransfer, let window = view.window {
                    state.contentsNeedsFocusTransfer = false
                    if window.firstResponder == nil || window.firstResponder === window {
                        window.makeFirstResponder(view)
                    }
                }
            }
        }
        view.renderRevision = state.renderRevision
        view.pdfAnnotations = pdfAnnotations
        view.pdfLinks = pdfLinks
        view.links = pages.isPDF ? view.navigationLinks.map { RasterLink(uri: $0.actions.first?.uri ?? $0.type, rect: $0.rect) } : links
        view.match = match; view.rotation = rotation; view.needsDisplay = true; view.needsLayout = true
        view.updateTiles()
        view.updateReadingAccessibility()
        view.restoreReaderFocus()
        if imageChanged, readingReady { NativeReadingPerformance.mark("canvas-image", pages: pages, revision: state.renderRevision, page: page) }
        view.updateLinkHints()
        let keyboard = state.keyboardLinkFollowing || state.keyboardTextSelection
        if keyboard, page == state.page, !view.keyboardActive {
            DispatchQueue.main.async { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
        }
        view.keyboardActive = keyboard
        if state.speechFollow, selections.speechPage == location, let first = selections.speechRects[location]?.first {
            view.scrollToVisible(first.applying(view.pageTransform).insetBy(dx: -12, dy: -12))
        }
        if !state.speechRequested, selections.keyboardFocus?.page == location, let selected = selections.caretRect {
            if view.scrollToVisible(selected.applying(view.pageTransform).insetBy(dx: -12, dy: -12)), state.isNativeReflow {
                cancelNavigation()
            }
        }
        let explicitRequest = request
        var requested = explicitRequest?.position
        if let focus, (explicitRequest == nil && view.lastRequest == nil) || explicitRequest?.position.page == page {
            let transform = RasterLayout.transform(bounds: visibleBounds, size: displaySize, rotation: rotation)
            let point = focus.applying(transform).origin.applying(transform.inverted())
            var focused = explicitRequest?.position ?? ReadingPosition(page: page)
            focused.x = focused.x ?? Double(point.x); focused.y = focused.y ?? Double(point.y)
            requested = focused
        }
        if explicitRequest?.toBottom == true {
            view.schedulePosition()
        } else if !(view.enclosingScrollView is RasterViewport.Scroll),
           let requested, requested.page == page,
           (explicitRequest != nil || requested != view.lastRequest), readingReady {
            view.lastRequest = requested
            DispatchQueue.main.async { [weak view] in
                guard request == explicitRequest, let view, view.page == page, view.lastRequest == requested else { return }
                guard let scroll = view.enclosingScrollView, let document = scroll.documentView else { return }
                scroll.layoutSubtreeIfNeeded(); document.layoutSubtreeIfNeeded()
                guard request == explicitRequest, view.page == page, view.location == location,
                      view.lastRequest == requested, view.enclosingScrollView === scroll,
                      view.readingReady, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
                let clip = scroll.contentView, visible = clip.safeAreaRect
                var bounds = clip.bounds
                // An unanchored page starts at its displayed top-left,
                // which differs from the source top-left after rotation.
                let origin = view.bounds.origin.applying(view.pageTransform.inverted())
                let point = CGPoint(x: requested.x ?? Double(origin.x), y: requested.y ?? Double(origin.y))
                let target = view.convert(point.applying(view.pageTransform), to: document)
                let targetInClip = clip.convert(target, from: document)
                // SwiftUI may extend the clip beneath the window toolbar.
                // Place the requested point at the unobscured origin.
                bounds.origin = CGPoint(x: targetInClip.x - (visible.minX - bounds.minX),
                                        y: targetInClip.y - (visible.minY - bounds.minY))
                clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(clip)
                if explicitRequest != nil { request = nil }
            }
        }
    }
    final class Canvas: NSView, NSUserInterfaceValidations {
        struct FinitePredictionToken: Equatable {
            let document: UUID?
            let source: PageLocation
            let render: String
            fileprivate let request: RasterPage.FinitePrediction
        }
        static func find(in view: NSView) -> Canvas? {
            if let canvas = view as? Canvas { return canvas }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        static func isVisible(_ location: PageLocation, in view: NSView) -> Bool {
            if let canvas = view as? Canvas, canvas.location == location,
               canvas.window != nil, !canvas.isHiddenOrHasHiddenAncestor {
                let viewport = canvas.enclosingScrollView.map { $0.contentView.convert($0.contentView.safeAreaRect, to: canvas) } ?? canvas.visibleRect
                return canvas.visibleRect.intersection(canvas.bounds).intersects(viewport)
            }
            return view.subviews.contains { isVisible(location, in: $0) }
        }
        // DisplayModel::CvtFromScreen uses the nearest page, including a cursor
        // in a page gap. Inverting the display transform gives MuPDF points:
        // PDF CropBox, intrinsic Rotate and UserUnit are already applied.
        static func cursorPosition(in view: NSView, at windowPoint: CGPoint) -> CGPoint? {
            var nearest: (distance: CGFloat, point: CGPoint)?
            func visit(_ view: NSView) {
                if let canvas = view as? Canvas, canvas.window != nil,
                   !canvas.isHiddenOrHasHiddenAncestor, !canvas.visibleRect.isEmpty {
                    let point = canvas.convert(windowPoint, from: nil), visible = canvas.visibleRect
                    let dx = max(visible.minX - point.x, 0, point.x - visible.maxX)
                    let dy = max(visible.minY - point.y, 0, point.y - visible.maxY)
                    let distance = dx * dx + dy * dy
                    if nearest == nil || distance < nearest!.distance {
                        nearest = (distance, point.applying(canvas.pageTransform.inverted()))
                    }
                }
                for child in view.subviews { visit(child) }
            }
            visit(view)
            return nearest?.point
        }
        // Sumatra TryPasteCopiedAnnotation / SetPointToVisiblePage: use the
        // mouse's page, otherwise the center of the first visible page.
        static func pasteTarget(in view: NSView) -> (page: Int, point: CGPoint)? {
            var fallback: (page: Int, point: CGPoint)?
            func visit(_ view: NSView) -> (page: Int, point: CGPoint)? {
                if let canvas = view as? Canvas, let window = canvas.window, !canvas.visibleRect.isEmpty {
                    let visible = canvas.visibleRect
                    let point = canvas.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    if visible.contains(point) { return (canvas.page, point.applying(canvas.pageTransform.inverted())) }
                    if fallback == nil || canvas.page < fallback!.page {
                        fallback = (canvas.page, CGPoint(x: visible.midX, y: visible.midY).applying(canvas.pageTransform.inverted()))
                    }
                }
                for child in view.subviews { if let result = visit(child) { return result } }
                return nil
            }
            return visit(view) ?? fallback
        }
        static func selectionScreenBounds(in view: NSView) -> CGRect? {
            var result = CGRect.null
            if let canvas = view as? Canvas, let window = canvas.window {
                for rect in canvas.selections?.values[canvas.location]?.bounds ?? [] {
                    result = result.union(window.convertToScreen(canvas.convert(rect.applying(canvas.pageTransform), to: nil)))
                }
            }
            for child in view.subviews {
                if let bounds = selectionScreenBounds(in: child) { result = result.union(bounds) }
            }
            return result.isNull || result.isEmpty ? nil : result
        }
        weak var state: ReaderState?
        fileprivate weak var selections: RasterSelections?
        var pages: Pages?, page = 0, pageBounds = CGRect.zero, visibleBounds = CGRect.zero, rotation = 0
        var image: CGImage? {
            didSet { if image !== oldValue { traceFirstPaint = true; hasPaintedPreview = false } }
        }
        private(set) var hasPaintedPreview = false
        var finitePredictionToken: FinitePredictionToken?
        var renderPredictedPage: (@MainActor () async throws -> Void)?
        private var finitePredictionStarted: FinitePredictionToken?
        private var finitePredictionTask: Task<Void, Never>?
        private var traceFirstPaint = false
        var location = PageLocation(page: 0)
        var imageCollection = false
        var pixelWidth = 0, tileResolution = 0
        var viewportTileSize: CGSize?
        var tileDocumentID: UUID?
        var renderingReady = false
        var pdfStyle: PDFColors.Style? {
            didSet { if oldValue != pdfStyle { previewTask?.cancel(); preview?.close() } }
        }
        private struct TileKey: Equatable {
            let location: PageLocation
            let revision: Int, rotation: Int, width: Int, resolution: Int
            let transparent: Bool
            let viewportTileSize: CGSize?
            let pdfStyle: PDFColors.Style?
            let pageBounds: CGRect
        }
        private var tileKey: TileKey?
        private var tileImages = [RasterLayout.Tile: CGImage]()
        private var previousTiles: (key: TileKey, images: [RasterLayout.Tile: CGImage],
                                    transform: CGAffineTransform, origin: CGPoint)?
        private var paintedTileGeometry: (transform: CGAffineTransform, origin: CGPoint)?
        private var paintedTiles = Set<RasterLayout.Tile>()
        private var tileTasks = [RasterLayout.Tile: Task<Void, Never>]()
        private var tilePredictionTask: Task<Void, Never>?
        private var tilePredictionPriority: ReaderRenderPriority?
        private var tilePredictionTile: RasterLayout.Tile?
        private var tilePredictionDirection = 1
        fileprivate var scrollRequest: Binding<RasterScrollRequest?>?
        var cancelNavigation: (() -> Void)?
        var didPaint: (() -> Void)?
        var didPaintMatch: ((RasterMatch) -> Void)?
        var didResizeViewport: ((CGSize) -> Void)?
        var imageBounds = [CGRect]()
        var pageBoxes = [CGRect?]()
        var contentBounds: CGRect?
        var links = [RasterLink](), match: RasterMatch?
        var pdfAnnotations = [PDFAnnotationSnapshot]()
        var pdfLinks = [PDFLinkSnapshot]()
        var navigationLinks: [PDFLinkSnapshot] {
            pdfLinks.filter { NativePDFActions.canFollow($0) && (state?.annotationsVisible == true || $0.type != "FileAttachment") }
        }
        private var annotationDrag: (selection: NativePDFSelection, start: CGPoint, corner: Int?, bounds: CGRect, revision: Int)?
        private var erasePoints = [CGPoint]()
        private weak var activeAnnotationTool: NativePDFAnnotationTool?
        private var formEditor: NativePDFFormEditor?
        private var formWidget: PDFAnnotationSnapshot?
        private var formTask: Task<Void, Never>?
        var lastRequest: ReadingPosition?
        var renderRevision = 0
        var lastDisplaySize = CGSize.zero
        var lastFocus: CGRect?
        var keyboardActive = false
        private var scrollObserver: NSObjectProtocol?
        private var positionScheduled = false
        private var start: (page: PageLocation, point: CGPoint)?
        private var selectionMode: Int32 = 0
        private var areaStart: CGPoint?
        private weak var selectionScroll: NSScrollView?
        private var lastClick: CGPoint?
        private var panStart: (point: CGPoint, origin: CGPoint)?
        private var linkDigits = ""
        private var linkInputHint: String { "Link \(linkDigits) · Return to follow" }
        private func clearLinkInput() {
            // A file watcher or another action may have replaced this hint.
            if state?.status == linkInputHint { state?.status = "" }
            linkDigits = ""
        }
        private var linkTracking = [NSTrackingArea]()
        private var preview: NSPopover?, previewTask: Task<Void, Never>?
        var comment: NSPopover?
        private var commentTask: Task<Void, Never>?
        var commentDocumentID: UUID?
        private var embeddedData: (data: Data, documentID: UUID)?
        var readingReady = false
        private let readingAccessibility = NativeReadingAccessibilityPage()
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityChildren() -> [Any]? {
            let controls = super.accessibilityChildren() ?? []
            return readingAccessibility.isAccessibilityElement() ? [readingAccessibility] + controls : controls
        }
        func updateReadingAccessibility() {
            readingAccessibility.view = self
            readingAccessibility.transform = pageTransform
            readingAccessibility.pageLabel = "\(L("Page")) \(page + 1)"
            guard let pages, let state else { readingAccessibility.clear(); return }
            let allowed = !pages.isPDF || state.nativePDFInfo?.permissions.accessibility == true
            guard allowed else { readingAccessibility.clear(); return }
            let documentID = state.document?.id, revision = renderRevision, location = location
            // Reflow geometry can still describe the outgoing natural chapter
            // after a mode change removes its viewport tiling metadata.
            let region = state.reflowable ? visibleRect.applying(pageTransform.inverted()).intersection(pageBounds) : nil
            let identity = NativeReadingAccessibilityPage.Identity(pages: ObjectIdentifier(pages), document: documentID, location: location, revision: revision, region: region)
            readingAccessibility.invalidate(unless: identity)
            guard readingReady, window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return }
            readingAccessibility.update(identity: identity, allowed: allowed, words: {
                try Task.checkCancellation()
                let started = DispatchTime.now().uptimeNanoseconds
                NativeReadingPerformance.mark("ax-text-entry", pages: pages, revision: revision,
                    page: location.page, size: region?.size ?? .zero, flags: region == nil ? 0 : 1)
                let words: [RasterWord]
                if let region { words = try await pages.selection(areas: [location: region])[location]?.words ?? [] }
                else { words = try await pages.words(location) }
                NativeReadingPerformance.mark("ax-text-return", pages: pages, revision: revision,
                    page: location.page, started: started, size: region?.size ?? .zero, flags: region == nil ? 0 : 1)
                return words
            }, failure: { [weak state] error in
                guard state?.document?.id == documentID, state?.renderRevision == revision else { return }
                state?.error = error.localizedDescription
            })
        }
        static func hasReadingAccessibilityFocus(in view: NSView) -> Bool {
            if let canvas = view as? Canvas, canvas.readingAccessibility.isAccessibilityFocused() { return true }
            return view.subviews.contains { hasReadingAccessibilityFocus(in: $0) }
        }
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        var pageTransform: CGAffineTransform { RasterLayout.transform(bounds: visibleBounds, size: bounds.size, rotation: rotation) }
        private var annotationScale: CGFloat { max(0.01, hypot(pageTransform.a, pageTransform.b)) }
        private func annotationCorners(_ rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        }
        private func annotation(at point: CGPoint) -> NativePDFSelection? {
            guard state?.annotationsVisible == true else { return nil }
            if let annotation = pdfAnnotations.last(where: { $0.type != "Widget" && $0.flags & 35 == 0 && $0.bounds.contains(point) }) {
                return .annotation(page: page, annotation)
            }
            return pdfLinks.last(where: { $0.type == "Link" && $0.flags & 35 == 0 && $0.bounds.contains(point) }).map { .link(page: page, $0) }
        }
        private func annotationMouseDown(_ event: NSEvent, point: CGPoint) -> Bool {
            guard let state, state.canEditPDF, state.nativePDFInfo?.permissions.annotate == true,
                  let tool = state.nativePDFAnnotationTool else { return false }
            window?.makeFirstResponder(self)
            activeAnnotationTool = tool
            if tool.kind == "highlightBrush" { return false }
            if tool.kind == "editMode" {
                guard state.annotationsVisible else { return true }
                var selected = state.nativePDFSelection.flatMap { $0.page == page ? $0 : nil }, corner: Int?
                if let selected, selected.resizable {
                    corner = annotationCorners(selected.bounds).firstIndex { hypot($0.x-point.x, $0.y-point.y) * annotationScale <= 8 }
                }
                if corner == nil { selected = annotation(at: point) }
                state.nativePDFSelection = selected
                selections?.clear(state); state.selectedText = ""
                if let selected, selected.editable {
                    if event.clickCount > 1 { state.send(.annotate("edit")) }
                    else if selected.movable {
                        annotationDrag = (selected, point, corner, selected.bounds, state.editRevision)
                    }
                }
                needsDisplay = true; return true
            }
            if !tool.points.isEmpty, tool.page != page { cancelOperation(nil); return true }
            tool.use(self, page: page)
            let point = tool.constrained(point, shift: event.modifierFlags.contains(.shift))
            tool.end = point
            if tool.kind == "eraser" {
                guard state.annotationsVisible else { return true }
                erasePoints = [point]
            }
            else if tool.isPoint || tool.kind == "ink" { tool.points = [point]; tool.finishes = true }
            else if tool.isPoly {
                if tool.points.last != point { tool.points.append(point) }
                let close = event.modifierFlags.contains(.control) && tool.points.count > 2
                if close, let first = tool.points.first { tool.points.append(first); tool.end = first }
                tool.finishes = close || event.clickCount > 1
            } else if tool.points.isEmpty { tool.points = [point] }
            else { tool.finishes = true }
            selections?.clear(state); state.selectedText = ""
            needsDisplay = true; return true
        }
        private func annotationMouseDragged(_ event: NSEvent) -> Bool {
            guard let state, state.canEditPDF, let tool = state.nativePDFAnnotationTool, tool === activeAnnotationTool else {
                annotationDrag = nil; erasePoints = []; return false
            }
            let point = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
            if ["ink", "eraser"].contains(tool.kind), !pageBounds.contains(point) { return true }
            if var drag = annotationDrag {
                if let corner = drag.corner {
                    let fixed = annotationCorners(drag.selection.bounds)[3-corner]
                    drag.bounds = CGRect(x: min(fixed.x, point.x), y: min(fixed.y, point.y),
                        width: max(1, abs(point.x-fixed.x)), height: max(1, abs(point.y-fixed.y)))
                } else { drag.bounds = drag.selection.bounds.offsetBy(dx: point.x-drag.start.x, dy: point.y-drag.start.y) }
                annotationDrag = drag
            } else if tool.kind == "eraser" { tool.end = point; if erasePoints.last != point { erasePoints.append(point) } }
            else if tool.isPlacement {
                tool.end = tool.constrained(point, shift: event.modifierFlags.contains(.shift))
                if tool.kind == "ink", let end = tool.end, tool.points.last != end { tool.points.append(end) }
                if !tool.isPoint && !tool.isPoly && tool.kind != "line" { tool.finishes = true }
            } else { return tool.kind == "editMode" }
            needsDisplay = true; return true
        }
        private func annotationMouseUp(_ event: NSEvent) -> Bool {
            guard let state, let pages, state.canEditPDF, let tool = state.nativePDFAnnotationTool, tool === activeAnnotationTool else {
                annotationDrag = nil; erasePoints = []; return false
            }
            if let drag = annotationDrag {
                annotationDrag = nil; needsDisplay = true
                guard drag.bounds != drag.selection.bounds else { return true }
                let documentID = state.document?.id, page = page
                Task {
                    do {
                        guard state.document?.id == documentID, state.canEditPDF, state.editRevision == drag.revision else { return }
                        switch drag.selection {
                        case .annotation(_, let annotation):
                            var properties = PDFAnnotationProperties(annotation); properties.bounds = drag.bounds
                            try await pages.pdfEditAnnotation(page: page, id: annotation.id, edits: properties.edits(from: annotation))
                        case .link(_, let link):
                            try await pages.pdfEditLink(page: page, id: link.id, bounds: drag.bounds, uri: nil)
                        }
                        guard state.document?.id == documentID else { return }
                        try await NativePDFAnnotations.refresh(page: page, id: drag.selection.id, link: drag.selection.type == "Link", state: state, pages: pages)
                    } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
                }
                return true
            }
            if tool.kind == "eraser" {
                let points = erasePoints, radius = 10 / annotationScale, page = page, documentID = state.document?.id
                erasePoints = []; tool.clearPreview(); needsDisplay = true
                if !points.isEmpty {
                    Task {
                        do {
                            guard state.document?.id == documentID, state.canEditPDF else { return }
                            let changed = try await pages.pdfEraseInk(page: page, points: points, radius: radius)
                            guard state.document?.id == documentID else { return }
                            if changed { state.nativePDFSelection = nil; try await state.nativePDFDidChange(pages) }
                        } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
                    }
                }
                return true
            }
            if tool.isPlacement {
                let point = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
                if tool.kind != "ink", !pageBounds.contains(point) { cancelOperation(nil); return true }
                if tool.finishes {
                    if tool.isPoly { tool.end = tool.points.last }
                    else { _ = annotationMouseDragged(event) }
                    finishAnnotationPlacement(tool)
                }
                return true
            }
            return tool.kind == "editMode"
        }
        private func finishAnnotationPlacement(_ tool: NativePDFAnnotationTool) {
            guard let state, let pages, state.canEditPDF, tool === state.nativePDFAnnotationTool,
                  tool.page == page else { return }
            if tool.isPoly { tool.end = tool.points.last }
            guard let item = tool.creation(scale: annotationScale) else { return }
            let documentID = state.document?.id
            tool.clearPreview()
            if !tool.isPersistent { state.nativePDFAnnotationTool = nil; state.status = "" }
            needsDisplay = true
            Task {
                defer { withExtendedLifetime(tool) {} }
                do {
                    guard state.document?.id == documentID, state.canEditPDF else { return }
                    if let uri = tool.uri {
                        let id = try await pages.pdfCreateLink(page: item.page, bounds: item.bounds, uri: uri)
                        guard state.document?.id == documentID else { return }
                        try await NativePDFAnnotations.refresh(page: item.page, id: id, link: true, state: state, pages: pages)
                    } else { try await NativePDFAnnotations.finish([item], preset: tool.preset, state: state, pages: pages) }
                } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
            }
        }
        private func drawAnnotationPreview(_ context: CGContext) {
            guard let tool = state?.nativePDFAnnotationTool, tool.host === self, tool.page == page else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / annotationScale)
            if tool.kind == "eraser", let end = tool.end {
                let radius = 10 / annotationScale
                context.strokeEllipse(in: CGRect(x: end.x-radius, y: end.y-radius, width: radius*2, height: radius*2)); return
            }
            guard let box = tool.bounds else { return }
            if tool.kind == "ink" {
                var color = SIMD3<Float>(1, 1, 0), alpha: Float = 0.4, width: Float = 3
                for edit in tool.edits {
                    switch edit {
                    case .color(let value, let interior) where !interior: color = value ?? .zero
                    case .opacity(let value): alpha = value
                    case .border(let value, _, _): width = value
                    default: break
                    }
                }
                let ink = NSColor(deviceRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(alpha)).cgColor
                context.setStrokeColor(ink); context.setFillColor(ink); context.setLineWidth(CGFloat(width)); context.setLineCap(.round); context.setLineJoin(.round)
                if tool.points.count == 1, let point = tool.points.first {
                    let radius = CGFloat(width) / 2
                    context.fillEllipse(in: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2)); return
                }
            } else { context.setLineDash(phase: 0, lengths: [4 / annotationScale, 3 / annotationScale]) }
            if tool.isPoly || tool.kind == "line" || tool.kind == "ink" {
                let points = tool.isPoly || tool.kind == "ink" ? tool.points + (tool.end.map { [$0] } ?? []) : [tool.points.first ?? box.origin, tool.end ?? box.origin]
                if let first = points.first {
                    context.move(to: first)
                    for point in points.dropFirst() { context.addLine(to: point) }
                    if tool.kind == "polygon" { context.closePath() }
                    context.strokePath()
                }
            } else if tool.kind == "circle" { context.strokeEllipse(in: box) }
            else { context.stroke(box) }
        }
        override func mouseMoved(with event: NSEvent) {
            guard let tool = state?.nativePDFAnnotationTool, tool.isPlacement || tool.kind == "eraser" else { super.mouseMoved(with: event); return }
            guard tool.points.isEmpty || tool.page == page else { return }
            tool.use(self, page: page)
            let point = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
            tool.end = tool.constrained(point, shift: event.modifierFlags.contains(.shift)); needsDisplay = true
        }
        override func cancelOperation(_ sender: Any?) {
            state?.nativePDFAnnotationTool = nil; state?.nativePDFSelection = nil; state?.status = ""
            annotationDrag = nil; erasePoints = []; needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        func clearTiles(retainingOutput: Bool = false) {
            // RenderCache::PaintTile keeps the old pixels behind a replacement.
            // Natural chapters have no whole-page preview, so retain one tile
            // generation until the new visible tiles have actually drawn.
            if retainingOutput, previousTiles == nil, let tileKey, let paintedTileGeometry,
               !paintedTiles.isEmpty, viewportTileSize != nil {
                previousTiles = (tileKey, tileImages, paintedTileGeometry.transform, paintedTileGeometry.origin)
            } else if !retainingOutput { previousTiles = nil }
            for task in tileTasks.values { task.cancel() }
            tilePredictionTask = nil; tilePredictionPriority = nil; tilePredictionTile = nil
            tileTasks.removeAll(); tileImages.removeAll(); paintedTiles.removeAll(); tileKey = nil
            paintedTileGeometry = nil
            if viewportTileSize != nil { readingReady = false; traceFirstPaint = true }
        }
        private func updateViewportReadingReady() {
            guard let viewportTileSize else { return }
            let visible = visibleRect.applying(pageTransform.inverted())
            let requested = RasterLayout.tiles(bounds: pageBounds, pixelWidth: pixelWidth, resolution: tileResolution,
                visible: visible, maximumSize: viewportTileSize)
            let ready = renderingReady && !requested.isEmpty && requested.allSatisfy {
                tileImages[$0] != nil && paintedTiles.contains($0)
            }
            let changed = readingReady != ready
            readingReady = ready
            if ready { previousTiles = nil }
            if changed, ready { updateReadingAccessibility(); restoreReaderFocus() }
        }
        func updateTiles() {
            guard window != nil, !isHiddenOrHasHiddenAncestor,
                  let pages, let state, case .pages(let current) = state.document?.content, current === pages,
                  bounds.width > 0, bounds.height > 0 else { clearTiles(); return }
            guard tileResolution > 0 else { clearTiles(retainingOutput: viewportTileSize != nil); return }
            let key = TileKey(location: location, revision: renderRevision, rotation: rotation,
                width: pixelWidth, resolution: tileResolution, transparent: imageCollection && state.showTransparencyGrid, viewportTileSize: viewportTileSize, pdfStyle: pdfStyle, pageBounds: pageBounds)
            if tileKey != key { clearTiles(retainingOutput: viewportTileSize != nil); tileKey = key }
            let visible = visibleRect.applying(pageTransform.inverted())
            let requested = RasterLayout.tiles(bounds: pageBounds, pixelWidth: pixelWidth, resolution: tileResolution, visible: visible, maximumSize: viewportTileSize)
            let wanted = Set(requested)
            let predicted = viewportTileSize == nil ? Set<RasterLayout.Tile>() : Set(predictionTiles(direction: tilePredictionDirection))
            // RenderCache::RequestRendering preserves the same tile request as
            // it enters the viewport; pixel scrolling does not change its key.
            if let tile = tilePredictionTile,
               window?.inLiveResize == true || (!wanted.contains(tile) && !predictionTiles(direction: tilePredictionDirection).contains(tile)) {
                cancelTilePrediction()
            }
            if let tile = tilePredictionTile, wanted.contains(tile) { tilePredictionPriority?.promote() }
            for (tile, task) in tileTasks where !wanted.contains(tile) && tile != tilePredictionTile { task.cancel() }
            tileTasks = tileTasks.filter { wanted.contains($0.key) || $0.key == tilePredictionTile }
            let pixelScale = CGFloat(pixelWidth) / pageBounds.width
            let pixels = visible.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)
                .applying(CGAffineTransform(scaleX: pixelScale, y: pixelScale))
            // RenderCache::FreeNotVisible / IsTileVisible(fuzz: 2): keep
            // completed neighboring tiles so a short reverse scroll reuses them.
            // Keep the predicted viewport too: a short chapter-tail tile can
            // lie beyond its own one-tile margin and otherwise be evicted here.
            // Bound retained pixels by bytes, without evicting visible output.
            var bytes = tileImages.reduce(0) { $0 + (wanted.contains($1.key) ? $1.value.bytesPerRow * $1.value.height : 0) }
            tileImages = tileImages.filter { tile, image in
                if wanted.contains(tile) { return true }
                let cost = image.bytesPerRow * image.height
                guard !visible.isEmpty, bytes + cost <= 64 * 1024 * 1024,
                      predicted.contains(tile) || (viewportTileSize == nil && tileResolution == 1) || tile.rect.insetBy(dx: -CGFloat(tile.width), dy: -CGFloat(tile.height)).intersects(pixels) else { return false }
                bytes += cost
                return true
            }
            paintedTiles.formIntersection(tileImages.keys)
            updateViewportReadingReady()
            let documentID = state.document?.id
            for tile in requested where tileImages[tile] == nil && tileTasks[tile] == nil {
                tileTasks[tile] = Task { [weak self] in
                    do {
                        let bitmap = try await pages.image(key.location, width: key.width, transparent: key.transparent, region: tile.rect, pdfStyle: key.pdfStyle)
                        guard !Task.isCancelled, let self, self.tileKey == key,
                              self.state?.document?.id == documentID else { return }
                        self.tileImages[tile] = bitmap
                        self.tileTasks.removeValue(forKey: tile)
                        self.updateTiles()
                        self.needsDisplay = true
                    } catch {
                        guard !Task.isCancelled, let self, self.tileKey == key,
                              self.state?.document?.id == documentID else { return }
                        self.state?.error = error.localizedDescription
                    }
                }
            }
        }
        private func predictionTiles(direction: Int) -> [RasterLayout.Tile] {
            let next = visibleRect.offsetBy(dx: 0, dy: CGFloat(direction) * visibleRect.height)
                .applying(pageTransform.inverted())
            let tiles = RasterLayout.tiles(bounds: pageBounds, pixelWidth: pixelWidth, resolution: tileResolution,
                visible: next, maximumSize: viewportTileSize)
            return direction > 0 ? tiles : tiles.reversed().map { $0 }
        }
        private func cancelTilePrediction() {
            if let tile = tilePredictionTile { tileTasks.removeValue(forKey: tile)?.cancel() }
            tilePredictionTask = nil; tilePredictionPriority = nil; tilePredictionTile = nil
        }
        func updatePredictionDirection(_ direction: Int) {
            tilePredictionDirection = direction
            guard let tile = tilePredictionTile else { return }
            let visible = RasterLayout.tiles(bounds: pageBounds, pixelWidth: pixelWidth, resolution: tileResolution,
                visible: visibleRect.applying(pageTransform.inverted()), maximumSize: viewportTileSize)
            if !visible.contains(tile) && !predictionTiles(direction: direction).contains(tile) { cancelTilePrediction() }
        }
        func predictViewportTile(direction: Int) {
            updatePredictionDirection(direction)
            guard viewportTileSize != nil, readingReady, !visibleRect.isEmpty,
                  window?.inLiveResize == false, let key = tileKey, let pages, let state,
                  tilePredictionTask == nil else { return }
            let candidates = predictionTiles(direction: direction)
            guard let tile = candidates.first(where: { tileImages[$0] == nil && tileTasks[$0] == nil }) else { return }
            let bytes = tileImages.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            guard bytes + tile.width * tile.height * 4 <= 64 * 1024 * 1024 else { return }
            tilePredictionTile = tile; tilePredictionDirection = direction
            let documentID = state.document?.id
            let priority = ReaderRenderPriority(visible: false)
            tilePredictionPriority = priority
            let task = Task(priority: .utility) { [weak self] in
                NativeReadingPerformance.mark("tile-prediction-start", pages: pages, revision: key.revision, page: self?.page ?? -1)
                do {
                    let bitmap = try await pages.image(key.location, width: key.width, transparent: key.transparent,
                        region: tile.rect, pdfStyle: key.pdfStyle, priority: priority)
                    guard !Task.isCancelled, let self, self.tileKey == key,
                          self.tilePredictionTile == tile, self.state?.document?.id == documentID else { return }
                    self.tileImages[tile] = bitmap; self.tileTasks.removeValue(forKey: tile)
                    self.tilePredictionTask = nil; self.tilePredictionPriority = nil; self.tilePredictionTile = nil
                    NativeReadingPerformance.mark("tile-prediction-ready", pages: pages, revision: key.revision, page: self.page)
                    self.updateTiles(); self.needsDisplay = true
                } catch {
                    if !Task.isCancelled, let self, self.tileKey == key, self.tilePredictionTile == tile {
                        self.tileTasks.removeValue(forKey: tile); self.tilePredictionTask = nil; self.tilePredictionPriority = nil; self.tilePredictionTile = nil
                        let visible = RasterLayout.tiles(bounds: self.pageBounds, pixelWidth: self.pixelWidth, resolution: self.tileResolution,
                            visible: self.visibleRect.applying(self.pageTransform.inverted()), maximumSize: self.viewportTileSize)
                        if visible.contains(tile) { self.state?.error = error.localizedDescription }
                    }
                }
            }
            tilePredictionTask = task; tileTasks[tile] = task
        }
        func cancelFinitePrediction() {
            finitePredictionTask?.cancel(); finitePredictionTask = nil; finitePredictionStarted = nil
        }
        private func predictFinitePage() {
            guard viewportTileSize == nil, readingReady, hasPaintedPreview,
                  let token = finitePredictionToken, finitePredictionStarted != token,
                  let state, let pages, let scroll = enclosingScrollView,
                  !(scroll is RasterViewport.Scroll), let document = scroll.documentView,
                  window != nil, window?.inLiveResize == false,
                  scrollRequest?.wrappedValue == nil,
                  case .pages(let current) = state.document?.content, current === pages,
                  state.document?.id == token.document, state.renderRevision == renderRevision,
                  let render = renderPredictedPage else { return }
            var missing = token.request.visible
            func check(_ view: NSView) -> Bool {
                if let canvas = view as? Canvas, missing.contains(canvas.location), canvas.pages === pages {
                    guard canvas.window != nil, canvas.readingReady, canvas.hasPaintedPreview else { return false }
                    missing.remove(canvas.location)
                }
                return view.subviews.allSatisfy(check)
            }
            guard check(document), missing.isEmpty else { return }
            finitePredictionStarted = token
            let revision = renderRevision, target = state.pageNumber(token.request.target)
            finitePredictionTask = Task(priority: .utility) { [weak self] in
                NativeReadingPerformance.mark("page-prediction-start", pages: pages, revision: revision, page: target)
                do {
                    try await render()
                    guard !Task.isCancelled, let self, self.finitePredictionToken == token,
                          self.state?.document?.id == token.document else { return }
                    self.finitePredictionTask = nil
                    NativeReadingPerformance.mark("page-prediction-ready", pages: pages, revision: revision, page: target)
                } catch {
                    if let self, self.finitePredictionToken == token { self.finitePredictionTask = nil }
                }
            }
        }
        private func predictFiniteRowAfterPainting() {
            guard let document = enclosingScrollView?.documentView else { return }
            func visit(_ view: NSView) {
                if let canvas = view as? Canvas, canvas.finitePredictionToken != nil { canvas.predictFinitePage() }
                for child in view.subviews { visit(child) }
            }
            visit(document)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard image != nil || viewportTileSize != nil,
                  let context = NSGraphicsContext.current?.cgContext, pageBounds.width > 0 else { return }
            if state?.showTransparencyGrid == true, imageCollection || pages?.isPDF == true { ReaderPageGrid.checkerboard(in: context, rect: pageBounds.applying(pageTransform)) }
            context.saveGState(); context.concatenate(pageTransform)
            if let image {
                NSImage(cgImage: image, size: pageBounds.size).draw(in: pageBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                hasPaintedPreview = true
            } else {
                context.setFillColor(ReaderTheme.color(state?.palette.background ?? 0xffffff).cgColor)
                context.fill(pageBounds)
            }
            context.restoreGState()
            func paintTiles(_ images: [RasterLayout.Tile: CGImage], width: Int, page: CGRect,
                            transform: CGAffineTransform, current: Bool) {
                let pixelScale = CGFloat(width) / page.width
                for (tile, bitmap) in images {
                    let rect = CGRect(x: page.minX + CGFloat(tile.x) / pixelScale,
                                      y: page.minY + CGFloat(tile.y) / pixelScale,
                                      width: CGFloat(tile.width) / pixelScale, height: CGFloat(tile.height) / pixelScale)
                    guard rect.applying(transform).intersects(dirtyRect) else { continue }
                    context.saveGState(); context.clip(to: rect.applying(transform))
                    if state?.showTransparencyGrid == true, imageCollection || pages?.isPDF == true { ReaderPageGrid.checkerboard(in: context, rect: page.applying(transform)) }
                    context.concatenate(transform); context.interpolationQuality = .none
                    NSImage(cgImage: bitmap, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    context.restoreGState()
                    if current { paintedTiles.insert(tile) }
                }
            }
            if let previousTiles {
                // Reflow can move the source passage to a different chapter Y.
                // Keep the old painted viewport anchored there while its new
                // geometry arrives, using the old tile scale and transform.
                var transform = previousTiles.transform
                transform.tx += visibleRect.minX - previousTiles.origin.x
                transform.ty += visibleRect.minY - previousTiles.origin.y
                paintTiles(previousTiles.images, width: previousTiles.key.width, page: previousTiles.key.pageBounds,
                           transform: transform, current: false)
            }
            paintTiles(tileImages, width: pixelWidth, page: pageBounds, transform: pageTransform, current: true)
            if !paintedTiles.isEmpty { paintedTileGeometry = (pageTransform, visibleRect.origin) }
            updateViewportReadingReady()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.predictFiniteRowAfterPainting()
                if let scroll = self.enclosingScrollView as? RasterViewport.Scroll {
                    scroll.predictNaturalTileAfterPainting()
                    scroll.predictPages()
                }
            }
            if traceFirstPaint, readingReady, window != nil, !visibleRect.isEmpty {
                traceFirstPaint = false
                NativeReadingPerformance.mark("canvas-first-draw", pages: pages, revision: renderRevision, page: page)
                let documentID = state?.document?.id, revision = renderRevision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, self.state?.document?.id == documentID,
                          self.renderRevision == revision, self.readingReady else { return }
                    self.didPaint?()
                }
            }
            if let state, !imageCollection {
                ReaderPageGrid.draw(in: context, bounds: pageBounds, visible: visibleRect.applying(pageTransform.inverted()).intersection(visibleBounds), transform: pageTransform, state: state)
            }
            context.saveGState(); context.concatenate(pageTransform)
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.35).cgColor)
            for rect in selections?.searchRects[page] ?? [] { context.fill(rect) }
            context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.5).cgColor)
            for rect in match?.rects(on: page) ?? [] { context.fill(rect) }
            if let match, didPaintMatch != nil, readingReady, window != nil,
               match.rects(on: page).contains(where: {
                   $0.applying(pageTransform).intersects(visibleRect.intersection(dirtyRect))
               }) {
                let documentID = state?.document?.id, revision = renderRevision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, self.state?.document?.id == documentID,
                          self.renderRevision == revision, self.readingReady, self.match == match,
                          match.rects(on: self.page).contains(where: {
                              $0.applying(self.pageTransform).intersects(self.visibleRect)
                          }) else { return }
                    self.didPaintMatch?(match)
                }
            }
            context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor)
            for rect in selections?.values[location]?.bounds ?? [] { context.fill(rect) }
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.5).cgColor)
            for rect in selections?.speechRects[location] ?? [] { context.fill(rect) }
            if state?.keyboardTextSelection == true, selections?.keyboardFocus?.page == location, let caret = selections?.caretRect {
                context.setFillColor(NSColor.labelColor.cgColor); context.fill(caret)
            }
            if state?.showLinks == true {
                context.setStrokeColor(NSColor.systemOrange.cgColor)
                context.setLineWidth(1 / max(0.01, abs(pageTransform.a)+abs(pageTransform.b)))
                for link in links { context.stroke(link.bounds) }
            }
            if state?.showImageBounds == true {
                context.setStrokeColor(NSColor.systemPink.cgColor)
                context.setLineWidth(1 / max(0.01, hypot(pageTransform.a, pageTransform.b)))
                for rect in imageBounds { context.stroke(rect) }
            }
            if state?.highlightFormFields == true {
                context.setFillColor(NSColor(calibratedRed: 166/255, green: 202/255, blue: 240/255, alpha: 96/255).cgColor)
                for field in pdfAnnotations where field.isEmptyFormField && field.id != formWidget?.id {
                    context.fill(field.bounds)
                }
            }
            if let selected = state?.nativePDFSelection, selected.page == page,
               state?.annotationsVisible == true {
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(1 / max(0.01, hypot(pageTransform.a, pageTransform.b)))
                let rect = annotationDrag?.bounds ?? selected.bounds
                context.stroke(rect)
                if state?.nativePDFAnnotationTool?.kind == "editMode", selected.resizable {
                    context.setFillColor(NSColor.controlAccentColor.cgColor)
                    let radius = 3 / annotationScale
                    for corner in annotationCorners(rect) { context.fill(CGRect(x: corner.x-radius, y: corner.y-radius, width: radius*2, height: radius*2)) }
                }
            }
            drawAnnotationPreview(context)
            context.restoreGState()
            if state?.showPageBoxes == true {
                // Canvas::PaintPdfPageBoxes: separate coincident outlines and
                // pin the five labels to different corners of the visible box.
                let kinds: [(String, UInt32)] = [("media", 0x202020), ("crop", 0xc02020),
                    ("bleed", 0x2040c0), ("trim", 0x109020), ("art", 0xc08000)]
                let viewport = visibleRect.intersection(bounds)
                context.setLineWidth(1)
                for (kind, entry) in pageBoxes.enumerated() {
                    guard let box = entry else { continue }
                    let rect = box.applying(pageTransform).insetBy(dx: CGFloat(kind), dy: CGFloat(kind))
                    let visible = rect.intersection(viewport)
                    guard rect.width >= 2, rect.height >= 2, !visible.isEmpty, !visible.isNull else { continue }
                    let (name, rgb) = kinds[kind], color = ReaderTheme.color(rgb)
                    context.setStrokeColor(color.cgColor); context.stroke(rect)
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: color, .backgroundColor: NSColor.white]
                    let size = (name as NSString).size(withAttributes: attributes)
                    var label = CGRect(origin: CGPoint(x: visible.minX + 3, y: visible.minY + 3), size: size)
                    if kind == 1 || kind == 3 { label.origin.x = visible.maxX - 3 - size.width }
                    if kind == 2 || kind == 3 { label.origin.y = visible.maxY - 3 - size.height }
                    if kind == 4 { label.origin.x = visible.midX - size.width / 2 }
                    label.size.width = min(label.width, viewport.width); label.size.height = min(label.height, viewport.height)
                    label.origin.x = min(max(viewport.minX, label.minX), viewport.maxX - label.width)
                    label.origin.y = min(max(viewport.minY, label.minY), viewport.maxY - label.height)
                    (name as NSString).draw(in: label, withAttributes: attributes)
                }
            }
            if state?.showFitContentArea == true {
                let content = contentBounds.flatMap { $0.isEmpty ? nil : $0 } ?? pageBounds
                context.setStrokeColor(NSColor.red.cgColor)
                context.setLineWidth(2)
                context.stroke(content.applying(pageTransform))
            }
            if state?.keyboardLinkFollowing == true {
                for (index, target) in visibleLinkTargets.enumerated() where target.canvas === self {
                    let rect = links[target.index].bounds.applying(pageTransform)
                    guard visibleRect.intersects(rect) else { continue }
                    (String(index+1) as NSString).draw(at: rect.origin, withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.black, .backgroundColor: NSColor.systemYellow])
                }
            }
        }
        override func scrollWheel(with event: NSEvent) {
            if state?.isNativeReflow == true, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                cancelNavigation?()
            }
            super.scrollWheel(with: event)
        }
        override func mouseDown(with event: NSEvent) {
            closeComment()
            let point = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
            if pages?.isPDF == true, event.buttonNumber == 0, event.clickCount == 2,
               event.modifierFlags.contains([.command, .shift]) {
                state?.inverseSearch(page: page, point: point); return
            }
            if event.buttonNumber == 0, annotationMouseDown(event, point: point) { return }
            if event.buttonNumber == 0, state?.freePan != true, state?.rectangularSelection != true,
               let field = pdfAnnotations.last(where: { $0.type == "Widget" && $0.flags & 35 == 0 && $0.bounds.contains(point) }),
               activateWidget(field) { return }
            window?.makeFirstResponder(self)
            selectionScroll = enclosingScrollView
            if event.buttonNumber == 2 || state?.freePan == true && state?.rectangularSelection != true &&
                !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) {
                cancelNavigation?()
                if let clip = enclosingScrollView?.contentView { panStart = (event.locationInWindow, clip.bounds.origin) }
                return
            }
            start = (location, convert(event.locationInWindow, from: nil).applying(pageTransform.inverted()))
            if pages?.isPDF == true {
                state?.nativePDFSelection = annotation(at: point)
            }
            lastClick = start?.point
            selectionMode = state?.rectangularSelection == true || event.modifierFlags.contains(.option) ? 3 : 0
            areaStart = selectionMode == 3 ? enclosingScrollView?.documentView?.convert(event.locationInWindow, from: nil) : nil
            selections?.clear(state); state?.selectedText = ""; state?.hasSelection = false; needsDisplay = true
            if let start { selections?.cursor = start }
            if selectionMode == 0, event.clickCount >= 2, let start { select(from: start, to: start, mode: event.clickCount == 2 ? 1 : 2) }
        }
        @discardableResult private func activateWidget(_ field: PDFAnnotationSnapshot) -> Bool {
            guard let state, let pages, pages.isPDF, state.canEditPDF,
                  state.nativePDFInfo?.permissions.form == true, field.readOnly == false,
                  let kind = field.fieldType, [2, 3, 4, 5, 7].contains(kind) || field.isUnsignedSignature else { return false }
            // Pushbuttons keep their link action path. Unsigned signature
            // widgets use the existing signing dialog (FormFields.cpp).
            // Like FormFields.cpp, only the active text/choice widget has a view.
            guard formTask == nil else { return true }
            let documentID = state.document?.id, page = page
            formTask = Task { [weak self] in
                guard let self else { return }
                defer { formTask = nil }
                do {
                    try await state.nativePDFFormEditor?.commit()
                    guard state.document?.id == documentID, state.nativePDF === pages,
                          state.canEditPDF, self.page == page, window != nil else { return }
                    let fields = try await pages.pdfAnnotations(page)
                    guard state.document?.id == documentID, state.canEditPDF,
                          state.nativePDF === pages, state.nativePDFFormEditor == nil,
                          self.page == page, window != nil,
                          let current = fields.first(where: { $0.id == field.id }), current.readOnly == false else { return }
                    if current.fieldType == 6 {
                        guard current.isUnsignedSignature else { return }
                        state.nativePDFSelection = .annotation(page: page, current)
                        state.performPDFTool(.sign)
                        return
                    }
                    if current.fieldType == 2 || current.fieldType == 5 {
                        try await pages.pdfToggleWidget(page: page, id: current.id)
                        try await state.nativePDFDidChange(pages)
                        return
                    }
                    formWidget = current
                    let editor = NativePDFFormEditor(widget: current, host: self, frame: current.bounds.applying(pageTransform),
                        commitValue: { [weak state] value in
                            guard let state, state.document?.id == documentID, state.nativePDF === pages,
                                  state.pdfEditingEnabled else { throw CancellationError() }
                            try await pages.pdfSetWidgetValue(page: page, id: current.id, value: value)
                            try await state.nativePDFDidChange(pages)
                        }, didClose: { [weak self, weak state] in
                            guard let self else { return }
                            if state?.nativePDFFormEditor === formEditor {
                                state?.nativePDFFormEditor = nil; state?.nativePDFFormPage = nil
                            }
                            formEditor = nil; formWidget = nil; needsDisplay = true
                        }, advance: { [weak self] backwards in self?.advanceWidget(from: current.id, backwards: backwards) },
                        failure: { [weak state] error in
                            if state?.document?.id == documentID { state?.error = error.localizedDescription }
                        })
                    formEditor = editor; state.nativePDFFormEditor = editor; state.nativePDFFormPage = page
                    needsDisplay = true
                } catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
            }
            return true
        }
        private func advanceWidget(from id: Int32, backwards: Bool) {
            // Upstream's adjacent-widget walk remains on the same page.
            let fields = pdfAnnotations.filter {
                $0.type == "Widget" && $0.readOnly == false && $0.flags & 35 == 0 &&
                    $0.fieldType.map { [3, 4, 7].contains($0) } == true
            }
            guard let index = fields.firstIndex(where: { $0.id == id }), fields.count > 1 else { return }
            let next = fields[(index + (backwards ? -1 : 1) + fields.count) % fields.count]
            scrollToVisible(next.bounds.applying(pageTransform))
            activateWidget(next)
        }
        override func mouseDragged(with event: NSEvent) {
            if let panStart, let scroll = enclosingScrollView ?? selectionScroll {
                cancelNavigation?()
                var bounds = scroll.contentView.bounds
                bounds.origin = CGPoint(x: panStart.origin.x + panStart.point.x-event.locationInWindow.x,
                                        y: panStart.origin.y + event.locationInWindow.y-panStart.point.y)
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(scroll.contentView); return
            }
            if annotationMouseDragged(event) { return }
            guard let start else { return }
            // Virtualization can remove the starting page while dragging. The
            // existing scroll view still owns the document-space gesture.
            let scroll = enclosingScrollView ?? selectionScroll
            if (scroll?.documentView ?? self).autoscroll(with: event), pages?.isMarkdown == true {
                cancelNavigation?()
            }
            if selectionMode == 3, let areaStart, let pages, let state,
               let scroll, let document = scroll.documentView {
                let end = document.convert(event.locationInWindow, from: nil)
                let rect = CGRect(x: min(areaStart.x, end.x), y: min(areaStart.y, end.y),
                    width: abs(end.x-areaStart.x), height: abs(end.y-areaStart.y))
                let areas: [PageLocation: CGRect]
                if let scroll = scroll as? RasterViewport.Scroll { areas = scroll.selectionAreas(in: rect) }
                else {
                    var found = [PageLocation: CGRect]()
                    func visit(_ view: NSView) {
                        if let canvas = view as? Canvas {
                            let intersection = canvas.convert(rect, from: document).intersection(canvas.bounds)
                            if !intersection.isNull, !intersection.isEmpty {
                                found[canvas.location] = intersection.applying(canvas.pageTransform.inverted())
                            }
                        } else { for child in view.subviews { visit(child) } }
                    }
                    visit(document); areas = found
                }
                selections?.select(pages: pages, state: state, first: start.page, start: nil,
                    last: start.page, end: nil, mode: 3, areas: areas)
                return
            }
            let canvas = canvas(at: event.locationInWindow)
            select(from: start, to: (canvas.location, canvas.convert(event.locationInWindow, from: nil).applying(canvas.pageTransform.inverted())), mode: selectionMode)
        }
        private func canvas(at point: CGPoint) -> Canvas {
            var closest = self, distance = CGFloat.infinity
            func visit(_ view: NSView) {
                if let canvas = view as? Canvas {
                    let p = canvas.convert(point, from: nil), r = canvas.bounds
                    let dx = max(max(r.minX-p.x, 0), p.x-r.maxX), dy = max(max(r.minY-p.y, 0), p.y-r.maxY)
                    let value = dx*dx + dy*dy
                    if value < distance { closest = canvas; distance = value }
                } else { for child in view.subviews { visit(child) } }
            }
            if let document = (enclosingScrollView ?? selectionScroll)?.documentView { visit(document) }
            return closest
        }
        private func select(from start: (page: PageLocation, point: CGPoint), to end: (page: PageLocation, point: CGPoint), mode: Int32 = 0) {
            guard let pages, let state, let selections else { return }
            selections.select(pages: pages, state: state, first: start.page, start: start.point, last: end.page, end: end.point, mode: mode)
        }
        override func mouseUp(with event: NSEvent) {
            defer { start = nil; areaStart = nil; selectionScroll = nil; panStart = nil }
            guard panStart == nil else { return }
            if annotationMouseUp(event) { return }
            if let tool = state?.nativePDFAnnotationTool, tool.kind == "highlightBrush" {
                state?.send(.annotate("highlight", preset: tool.preset)); return
            }
            guard let start else { return }
            let end = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
            if selectionMode == 0, event.clickCount == 1, start.page == location,
               hypot(end.x-start.point.x, end.y-start.point.y) < 3,
               state?.nativePDFAnnotationTool == nil, !event.modifierFlags.contains(.control),
               case .annotation(_, let annotation) = annotation(at: end), annotation.type != "FileAttachment",
               !annotation.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showComment(annotation); return
            }
            if selectionMode == 0, state?.disableLinks != true, event.clickCount == 1, start.page == location,
               hypot(end.x-start.point.x, end.y-start.point.y) < 3, let index = links.lastIndex(where: { $0.bounds.contains(end) }) {
                followLink(at: index, newWindow: event.modifierFlags.contains(.command))
            }
        }
        override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { mouseDown(with: event) } else { super.otherMouseDown(with: event) } }
        override func otherMouseDragged(with event: NSEvent) { if event.buttonNumber == 2 { mouseDragged(with: event) } else { super.otherMouseDragged(with: event) } }
        override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { mouseUp(with: event) } else { super.otherMouseUp(with: event) } }
        override func rightMouseDown(with event: NSEvent) {
            if let tool = state?.nativePDFAnnotationTool, tool.isPoly { finishAnnotationPlacement(tool); return }
            guard let pages, let state else { return }
            let point = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
            if pages.isPDF, state.annotationsVisible {
                state.nativePDFSelection = annotation(at: point)
            }
            selections?.cursor = (location, point)
            let location = location
            guard let documentID = state.document?.id else { return }
            Task {
                let image: Data?
                do { image = try await pages.embeddedImage(location, at: point) }
                catch {
                    image = nil
                    if state.document?.id == documentID { state.error = error.localizedDescription }
                }
                guard state.document?.id == documentID else { return }
                embeddedData = image.map { ($0, documentID) }
                defer { embeddedData = nil }
                if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let pages, let state, let documentID = state.document?.id else { return nil }
            let point = convert(event.locationInWindow, from: nil).applying(pageTransform.inverted())
            let menu = NSMenu()
            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: L(title), action: action, keyEquivalent: ""); item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            menu.autoenablesItems = false
            let canCopy = !pages.isPDF || state.nativePDFInfo?.permissions.copy == true
            let canPrint = !pages.isPDF || state.nativePDFInfo?.permissions.print == true
            if let link = links.last(where: { $0.bounds.contains(point) }),
               !pages.isPDF || navigationLinks.last(where: { $0.bounds.contains(point) })?.actions.first?.uri != nil {
                add("Copy Link Address", #selector(copyContextText(_:)), enabled: canCopy)
                // Menu.cpp::CleanupURLForClipbardCopyTemp.
                let prefix = ["file:", "mailto:"].first(where: link.uri.hasPrefix)
                menu.items.last?.representedObject = (documentID, String(link.uri.dropFirst(prefix?.count ?? 0)))
            }
            if case .annotation(_, let annotation) = annotation(at: point),
               !annotation.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add("Copy Comment", #selector(copyContextText(_:)), enabled: canCopy)
                menu.items.last?.representedObject = (documentID, annotation.contents)
                add("Show Comment", #selector(showContextComment(_:)))
                menu.items.last?.representedObject = (documentID, annotation)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            add("Copy", #selector(copySelection), enabled: canCopy && (state.hasSelection || NativePDFClipboard.canCopy(state)))
            add("Copy Selection as Image", #selector(copySelectionImage), enabled: canCopy && state.hasSelection)
            add("Save Selection…", #selector(saveSelection), enabled: canCopy && state.hasSelection)
            add("Print Selection…", #selector(printSelection), enabled: canPrint && state.hasSelection)
            add("Search Selection with Google Lens", #selector(searchSelection), enabled: canCopy && state.hasSelection)
            if embeddedData?.documentID == documentID {
                menu.addItem(.separator())
                add("Copy Embedded Image", #selector(copyEmbeddedImage)); add("Save Embedded Image…", #selector(saveEmbeddedImage))
                add("Crop Image…", #selector(cropEmbeddedImage)); add("Resize Image…", #selector(resizeEmbeddedImage))
                add("Convert Image to PDF…", #selector(convertEmbeddedImage))
                add("Search Image with Google Lens", #selector(searchEmbeddedImage))
            }
            if let selected = state.nativePDFSelection, selected.page == page {
                menu.addItem(.separator())
                let editable = state.canEditPDF && state.nativePDFInfo?.permissions.annotate == true && selected.editable
                add("Annotation Properties…", #selector(editSelectedAnnotation), enabled: editable)
                add("Delete Annotation", #selector(deleteSelectedAnnotation), enabled: editable)
                add("Copy Annotation", #selector(copySelectedAnnotation), enabled: NativePDFClipboard.canCopy(state))
                add("Cut Annotation", #selector(cut(_:)), enabled: NativePDFClipboard.canCopy(state, cut: true))
            }
            if pages.isPDF {
                add("Paste Annotation", #selector(paste(_:)), enabled: NativePDFClipboard.canPaste(state))
                menu.items.last?.representedObject = ReadingPosition(page: page, x: Double(point.x), y: Double(point.y))
            }
            return menu
        }
        @objc private func copyContextText(_ sender: NSMenuItem) {
            guard let (documentID, text) = sender.representedObject as? (UUID, String),
                  state?.document?.id == documentID,
                  pages?.isPDF != true || state?.nativePDFInfo?.permissions.copy == true else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        @objc private func showContextComment(_ sender: NSMenuItem) {
            guard let (documentID, annotation) = sender.representedObject as? (UUID, PDFAnnotationSnapshot),
                  state?.document?.id == documentID else { return }
            showComment(annotation)
        }
        func closeComment() {
            commentTask?.cancel(); commentTask = nil
            comment?.close(); comment = nil; commentDocumentID = nil
        }
        private func showComment(_ annotation: PDFAnnotationSnapshot) {
            guard let state, let pages, state.annotationsVisible else { return }
            closeComment()
            let documentID = state.document?.id, page = page
            commentDocumentID = documentID
            commentTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await state.nativePDFFormEditor?.commit()
                    guard !Task.isCancelled, state.document?.id == documentID, state.nativePDF === pages,
                          self.page == page, window != nil, state.annotationsVisible else { return }
                    let annotations = try await pages.pdfAnnotations(page)
                    guard !Task.isCancelled, state.document?.id == documentID, state.nativePDF === pages,
                          self.page == page, window != nil, state.annotationsVisible,
                          let current = annotations.first(where: { $0.id == annotation.id }),
                          !current.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    // AnnotTextPopup.cpp: a selectable, read-only comment card;
                    // reading a long note never requires enabling PDF editing.
                    let scroll = NSTextView.scrollableTextView()
                    scroll.frame.size = CGSize(width: 360, height: 240)
                    guard let text = scroll.documentView as? NSTextView else { return }
                    text.isRichText = false; text.isEditable = false
                    text.isSelectable = state.nativePDFInfo?.permissions.copy == true
                    text.font = .systemFont(ofSize: 14); text.string = current.contents
                    text.textContainerInset = CGSize(width: 8, height: 8)
                    text.setAccessibilityLabel(L("Comment"))
                    let controller = NSViewController(); controller.view = scroll
                    let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
                    previewTask?.cancel(); preview?.close()
                    comment = popover
                    popover.show(relativeTo: current.bounds.applying(pageTransform), of: self, preferredEdge: .maxY)
                } catch { if !Task.isCancelled, state.document?.id == documentID { state.error = error.localizedDescription } }
            }
        }
        @objc private func copySelection() { state?.send(.copy) }
        @objc private func copySelectedAnnotation() { state?.send(.annotate("copy")) }
        @objc func copy(_ sender: Any?) { state?.send(.copy) }
        @objc func cut(_ sender: Any?) { state?.send(.annotate("cut")) }
        @objc func paste(_ sender: Any?) {
            state?.send(.annotate("paste", at: (sender as? NSMenuItem)?.representedObject as? ReadingPosition))
        }
        @objc private func editSelectedAnnotation() { state?.send(.annotate("edit")) }
        @objc private func deleteSelectedAnnotation() { state?.send(.deleteAnnotation) }
        @objc private func copySelectionImage() { state?.send(.copySelectionImage) }
        @objc private func saveSelection() { state?.send(.saveSelection) }
        @objc private func printSelection() { state?.send(.printSelection) }
        @objc private func searchSelection() { state?.send(.searchSelectionWithLens) }
        @objc private func searchEmbeddedImage() { outputEmbeddedImage(.searchSelectionWithLens) }
        @objc private func copyEmbeddedImage() { outputEmbeddedImage(.copyImage) }
        @objc private func saveEmbeddedImage() { outputEmbeddedImage(.saveSelection) }
        @objc private func cropEmbeddedImage() { editEmbeddedImage(.crop) }
        @objc private func resizeEmbeddedImage() { editEmbeddedImage(.resize) }
        @objc private func convertEmbeddedImage() { editEmbeddedImage(.pdf) }
        private func outputEmbeddedImage(_ action: ReaderAction) {
            guard let state, let embeddedData else { return }
            Task {
                guard state.document?.id == embeddedData.documentID else { return }
                do {
                    if action == .searchSelectionWithLens { try ReaderImages.searchWithLens(embeddedData.data, state: state) }
                    else { try await ReaderImages.outputEmbedded(embeddedData.data, action: action, state: state) }
                } catch { if state.document?.id == embeddedData.documentID { state.error = error.localizedDescription } }
            }
        }
        private func editEmbeddedImage(_ mode: ReaderImages.Mode) {
            guard let state, let embeddedData else { return }
            Task {
                guard state.document?.id == embeddedData.documentID else { return }
                do { try await ReaderImages.editEmbedded(embeddedData.data, state: state, mode: mode) }
                catch { if state.document?.id == embeddedData.documentID { state.error = error.localizedDescription } }
            }
        }
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": copy(nil); return
                case "x" where pages?.isPDF == true: cut(nil); return
                case "v" where pages?.isPDF == true: paste(nil); return
                default: break
                }
            }
            if let tool = state?.nativePDFAnnotationTool {
                if event.keyCode == 53 { cancelOperation(nil); return }
                if [36, 49, 76].contains(event.keyCode), tool.isPoly { finishAnnotationPlacement(tool); return }
                if [36, 76].contains(event.keyCode), tool.kind == "highlightBrush" { cancelOperation(nil); return }
                if tool.isPlacement { return }
            }
            if pages?.isPDF == true, state?.canEditPDF == true,
               [51, 117].contains(event.keyCode), !event.modifierFlags.contains(.command),
               state?.nativePDFSelection?.page == page {
                state?.send(.deleteAnnotation); return
            }
            let key = event.charactersIgnoringModifiers ?? ""
            if state?.keyboardLinkFollowing == true, !event.modifierFlags.contains(.command) {
                if key.count == 1, key.allSatisfy(\.isNumber) { linkDigits += key; state?.status = linkInputHint; return }
                if event.keyCode == 36 {
                    let targets = visibleLinkTargets
                    if let index = Int(linkDigits), targets.indices.contains(index-1), state?.disableLinks != true {
                        let target = targets[index-1]; target.canvas.followLink(at: target.index)
                    }
                    clearLinkInput(); return
                }
                if event.keyCode == 53 { state?.keyboardLinkFollowing = false; clearLinkInput(); return }
            }
            if state?.keyboardTextSelection == true, event.keyCode == 53 {
                state?.keyboardTextSelection = false; selections?.keyboardFocus = nil; selections?.keyboardAnchor = nil
                selections?.caretRect = nil; needsDisplay = true; return
            }
            if state?.keyboardTextSelection == true, [123,124,125,126].contains(event.keyCode),
               !event.modifierFlags.contains(.command), let pages, let state {
                selections?.moveCaret(pages: pages, state: state, at: lastClick, backwards: event.keyCode == 123 || event.keyCode == 126,
                    byWord: event.modifierFlags.contains(.option), byLine: event.keyCode == 125 || event.keyCode == 126, extend: event.modifierFlags.contains(.shift))
            } else if event.charactersIgnoringModifiers == "a", event.modifierFlags.contains(.command) { state?.send(.selectAll) }
            else { super.keyDown(with: event) }
        }
        // FollowKeyboardLinkTarget numbers links across the visible page set,
        // rather than restarting at one for each view in a facing row.
        private var visibleLinkTargets: [(canvas: Canvas, index: Int)] {
            guard let root = enclosingScrollView?.documentView else { return [] }
            var visible = [Canvas]()
            func visit(_ view: NSView) {
                if let canvas = view as? Canvas {
                    if canvas.window != nil, !canvas.visibleRect.isEmpty { visible.append(canvas) }
                } else { for child in view.subviews { visit(child) } }
            }
            visit(root)
            return visible.sorted { $0.page < $1.page }.flatMap { canvas in
                canvas.links.indices.filter { canvas.visibleRect.intersects(canvas.links[$0].bounds.applying(canvas.pageTransform)) }
                    .map { (canvas, $0) }
            }
        }
        private func followLink(at index: Int, newWindow: Bool = false) {
            guard let state, let pages, !state.disableLinks, links.indices.contains(index) else { return }
            let navigationLinks = navigationLinks
            if pages.isPDF, navigationLinks.indices.contains(index) {
                let link = navigationLinks[index], page = page
                let point = link.bounds.applying(pageTransform).origin
                Task { await NativePDFActions.follow(link, page: page, pages: pages, state: state, in: self, at: point, newWindow: newWindow) }
            } else { state.navigate(.href(links[index].uri)) }
        }
        func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(cut(_:)) { return state.map { NativePDFClipboard.canCopy($0, cut: true) } ?? false }
            if item.action == #selector(paste(_:)) { return state.map { NativePDFClipboard.canPaste($0) } ?? false }
            if item.action == #selector(copy(_:)), pages?.isPDF == true { return state?.nativePDFInfo?.permissions.copy == true }
            return true
        }
        private var hintedLinks: [RasterLink] {
            viewportTileSize == nil ? links : links.filter { visibleRect.intersects($0.bounds.applying(pageTransform)) }
        }
        func updateLinkHints() {
            removeAllToolTips()
            if state?.hoverPreview == true {
                for link in hintedLinks { addToolTip(link.bounds.applying(pageTransform), owner: link.uri as NSString, userData: nil) }
            }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }
        override func updateTrackingAreas() {
            for area in linkTracking { removeTrackingArea(area) }; linkTracking = []
            if state?.nativePDFAnnotationTool != nil {
                let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
                addTrackingArea(area); linkTracking.append(area)
            }
            if state?.hoverPreview == true {
                for link in hintedLinks where !["http", "https", "mailto", "ftp"].contains(URL(string: link.uri)?.scheme?.lowercased() ?? "") && (pages?.isPDF != true || link.uri.hasPrefix("#")) {
                    let area = NSTrackingArea(rect: link.bounds.applying(pageTransform), options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["uri": link.uri])
                    addTrackingArea(area); linkTracking.append(area)
                }
            } else { previewTask?.cancel(); preview?.close() }
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) {
            guard comment?.isShown != true, state?.hoverPreview == true, let uri = event.trackingArea?.userInfo?["uri"] as? String, let pages,
                  let link = links.first(where: { $0.uri == uri }) else { return }
            previewTask?.cancel()
            let rect = link.bounds.applying(pageTransform)
            let sourcePage = page, style = pdfStyle, documentID = state?.document?.id
            previewTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 350_000_000)
                    guard let image = try await pages.previewImage(uri, from: sourcePage, pdfStyle: style) else { return }
                    guard !Task.isCancelled, window != nil, state?.document?.id == documentID else { return }
                    let size = CGSize(width: 320, height: min(440, 320 * CGFloat(image.height) / CGFloat(image.width)))
                    let view = NSImageView(frame: CGRect(origin: .zero, size: size)); view.imageScaling = .scaleProportionallyDown
                    view.image = NSImage(cgImage: image, size: .zero)
                    let controller = NSViewController(); controller.view = view
                    let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
                    preview?.close(); preview = popover; popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
                } catch { if !Task.isCancelled, state?.document?.id == documentID { state?.status = error.localizedDescription } }
            }
        }
        override func mouseExited(with event: NSEvent) { previewTask?.cancel(); preview?.close() }
        override func resetCursorRects() {
            if let tool = state?.nativePDFAnnotationTool, tool.isPlacement || tool.kind == "eraser" { addCursorRect(bounds, cursor: .crosshair) }
            else if state?.rectangularSelection == true { addCursorRect(bounds, cursor: .crosshair) }
            else if state?.freePan == true { addCursorRect(bounds, cursor: .openHand) }
            else if state?.disableLinks != true { for link in links { addCursorRect(link.bounds.applying(pageTransform), cursor: .pointingHand) } }
        }
        static func recordPosition(in view: NSView) {
            if let scroll = view.enclosingScrollView as? RasterViewport.Scroll { scroll.recordPosition(); return }
            if let canvas = view as? Canvas { canvas.scrolled() }
            for child in view.subviews { recordPosition(in: child) }
        }
        override func layout() {
            super.layout()
            if window?.inLiveResize == true { cancelFinitePrediction() }
            if let field = formWidget { formEditor?.updateFrame(field.bounds.applying(pageTransform)) }
            schedulePosition()
        }
        private func applyBottomRequest() {
            guard let request = scrollRequest?.wrappedValue, request.toBottom,
                  let state, let pages, case .pages(let current) = state.document?.content, current === pages,
                  let scroll = enclosingScrollView, !(scroll is RasterViewport.Scroll),
                  let document = scroll.documentView, window != nil, !isHiddenOrHasHiddenAncestor else { return }
            scroll.layoutSubtreeIfNeeded(); document.layoutSubtreeIfNeeded()
            guard scrollRequest?.wrappedValue == request else { return }
            // DisplayModel::GoToPrevPage uses the whole row's canvas height.
            // A representable update can precede its actual frame assignment;
            // keep the request until the following native layout is ready.
            let expected = Set(state.visiblePages.map { state.pageLocation($0) })
            var ready = Set<PageLocation>()
            func collect(_ node: NSView) {
                if let canvas = node as? Canvas, canvas.pages === pages,
                   expected.contains(canvas.location), canvas.readingReady,
                   abs(canvas.bounds.width - canvas.lastDisplaySize.width) < 1,
                   abs(canvas.bounds.height - canvas.lastDisplaySize.height) < 1 {
                    ready.insert(canvas.location)
                }
                for child in node.subviews { collect(child) }
            }
            collect(document)
            guard ready == expected else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = document.isFlipped ? document.bounds.maxY : document.bounds.minY - bounds.height
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            lastRequest = request.position
            scrollRequest?.wrappedValue = nil
        }
        func schedulePosition() {
            guard !positionScheduled else { return }
            positionScheduled = true
            // HostingScrollView can also notify bounds changes inside a SwiftUI
            // update. Read live geometry after it, never a captured old position.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.positionScheduled = false
                // Scrollers reduce the clip size; SwiftUI may also extend it
                // beneath the toolbar. Fit and the minimum canvas frame share
                // the actual unobscured area, including visibility changes.
                if self.window != nil, let scroll = self.enclosingScrollView,
                   self.state?.readerScrollView === scroll,
                   case .pages(let current) = self.state?.document?.content, current === self.pages {
                    let size = scroll.contentView.safeAreaRect.size
                    if size.width > 0, size.height > 0 { self.didResizeViewport?(size) }
                }
                self.applyBottomRequest()
                self.scrolled()
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }; scrollObserver = nil
            guard window != nil, let scroll = enclosingScrollView else { return }
            if let state, case .pages(let current) = state.document?.content, current === pages {
                state.readerScrollView = scroll
                if !(scroll is RasterViewport.Scroll) { ReaderScrollbars.apply(to: scroll, mode: state.scrollbarMode) }
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePosition() }
            }
            schedulePosition()
            restoreReaderFocus()
        }
        func restoreReaderFocus() {
            guard readingReady, page == state?.page else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let selections = self.selections, selections.pendingReaderFocus,
                      let state = self.state, self.page == state.page, self.readingReady,
                      case .pages(let current) = state.document?.content, current === self.pages,
                      let window = self.window else { return }
                selections.pendingReaderFocus = false
                if window.firstResponder == nil || window.firstResponder === window || window.firstResponder is Canvas {
                    window.makeFirstResponder(self)
                }
            }
        }
        private func scrolled() {
            updateTiles()
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            updateReadingAccessibility()
            if viewportTileSize != nil { updateLinkHints() }
            selections?.visibleBounds[location] = visibleRect.applying(pageTransform.inverted())
            if let scroll = enclosingScrollView as? RasterViewport.Scroll { scroll.recordPosition(); return }
            guard scrollRequest?.wrappedValue == nil, let state,
                  state.pageLocation(page) == location,
                  case .pages(let current) = state.document?.content, current === pages,
                  let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            var point = convert(clip.safeAreaRect.origin, from: clip)
            guard state.page == page else { return }
            point = point.applying(pageTransform.inverted())
            state.readerFocusView = self
            let extent = bounds.height - clip.bounds.height
            let offset = convert(clip.bounds.origin, from: clip).y - bounds.minY
            let fraction = state.continuousReflow ? (extent > 0 ? Double(min(1, max(0, offset / extent))) : 1) : nil
            state.updatePosition(.init(page: state.pageNumber(location), scrollFraction: fraction, x: Double(point.x), y: Double(point.y),
                anchor: state.reflowable ? state.chapterLayout?.bookmark(location) : nil), preservingNativePassage: true)
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                cancelFinitePrediction()
                if window?.firstResponder === self { selections?.pendingReaderFocus = true }
                readingAccessibility.clear()
                closeComment()
                clearTiles()
                if state?.readerFocusView === self { state?.readerFocusView = nil }
                previewTask?.cancel(); preview?.close()
                selections?.visibleBounds.removeValue(forKey: location)
                if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }; scrollObserver = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

#endif
