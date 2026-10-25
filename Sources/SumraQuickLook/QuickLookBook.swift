import AppKit
import ImageIO
import SumraCore

/// Quick Look owns its own read-only document, never a reader session or history.
/// Comics use the shared archive reader; ebooks use the app's bundled MuPDF ABI.
actor QuickLookBook {
    struct Page {
        let image: CGImage
        let label: String
        let hasPrevious, hasNext: Bool
    }
    private let archive: Archive?
    private let images: [String]
    private let document: QuickLookDocument?
    private var chapter = 0, page = 0

    init(url: URL, engineURL: URL? = nil) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: 1024) ?? Data()
        let inspected = try Format.inspect(url, prefix: prefix)
        if inspected.format == .book {
            document = try QuickLookDocument(url: url, prefix: prefix, engineURL: engineURL)
            archive = nil; images = []
        } else {
            let source = try inspected.archive ?? Archive(url)
            let names = source.images
            guard !names.isEmpty else { throw ReadError("This archive has no comic pages.") }
            archive = source; images = names; document = nil
        }
    }

    func image(maximum: CGSize, direction: Int = 0) throws -> Page {
        try Task.checkCancellation()
        if let document {
            if direction > 0 {
                if page + 1 < (try document.pages(chapter)) { page += 1 }
                else if chapter + 1 < document.chapters { chapter += 1; page = 0 }
            } else if direction < 0 {
                if page > 0 { page -= 1 }
                else if chapter > 0 { chapter -= 1; page = try document.pages(chapter) - 1 }
            }
            let count = try document.pages(chapter)
            return try Page(image: document.image(chapter: chapter, page: page, maximum: maximum),
                            label: "\(chapter + 1)/\(document.chapters) · \(page + 1)/\(count)",
                            hasPrevious: chapter > 0 || page > 0,
                            hasNext: chapter + 1 < document.chapters || page + 1 < count)
        }
        page = min(max(0, page + direction), images.count - 1)
        let bytes = try archive!.data(images[page])
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maximum.width, maximum.height)
              ] as CFDictionary) else {
            throw ReadError("Quick Look cannot decode \(images[page]). Open this comic in Sumra.")
        }
        return Page(image: image, label: "\(page + 1)/\(images.count)", hasPrevious: page > 0, hasNext: page + 1 < images.count)
    }

    static func fitted(_ image: CGSize, in available: CGSize) -> CGRect {
        let scale = min(available.width / image.width, available.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (available.width - size.width) / 2, y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// This extension registers ebooks, not PDF. It does not create another PDF model
// or activate scripts. The main app and both extensions share one bundled engine.
private final class QuickLookDocument {
    private typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>, Int32) -> UnsafeMutableRawPointer?
    private typealias Close = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Count = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> Int32
    private typealias Pages = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<CChar>) -> Int32
    private typealias Bounds = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
    private typealias Render = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Int32>?, Int32, UnsafePointer<Int32>?, UnsafePointer<UInt32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
    private let library, document: UnsafeMutableRawPointer
    private let close: Close
    private let pageCount: Pages
    private let bounds: Bounds
    private let render: Render
    let chapters: Int
    private let temporaryDirectory: URL?

    init(url: URL, prefix: Data, engineURL: URL?) throws {
        var source = url, temporaryDirectory: URL?
        var opened = false
        defer { if !opened, let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        if prefix.count >= 68, prefix[60..<68].elementsEqual("BOOKMOBI".utf8),
           let content = try LegacyText.mobiContent(Data(contentsOf: url, options: .mappedIfSafe)) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-QuickLook-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
            source = try content.materialize(in: directory)
        }
        // The extension links the shared engine at process startup. Its sandbox
        // cannot later open a sibling of its .appex with dlopen(path).
        let library = engineURL.map { dlopen($0.path, RTLD_NOW | RTLD_LOCAL) } ?? dlopen(nil, RTLD_NOW | RTLD_LOCAL)
        guard let library else {
            throw ReadError(String(cString: dlerror()))
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw ReadError("Missing MuPDF entry: \(name)") }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            close = try symbol("lf_close", Close.self)
            pageCount = try symbol("lf_chapter_pages", Pages.self)
            bounds = try symbol("lf_bounds_at", Bounds.self)
            render = try symbol("lf_render_cancelable_at", Render.self)
            let open = try symbol("lf_open_classified", Open.self)
            let count = try symbol("lf_chapters", Count.self)
            var error = [CChar](repeating: 0, count: 512), password: Int32 = 0
            guard let document = open(source.path, nil, &password, &error, 0) else {
                throw ReadError(String(cString: error))
            }
            let chapters = count(document, &error)
            guard chapters > 0 else { close(document); throw ReadError(String(cString: error)) }
            self.document = document; self.chapters = Int(chapters); self.library = library
            self.temporaryDirectory = temporaryDirectory; opened = true
        } catch { dlclose(library); throw error }
    }

    deinit {
        close(document); dlclose(library)
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func pages(_ chapter: Int) throws -> Int {
        var error = [CChar](repeating: 0, count: 512)
        let count = pageCount(document, Int32(chapter), &error)
        guard count > 0 else { throw ReadError(String(cString: error)) }
        return Int(count)
    }

    func image(chapter: Int, page: Int, maximum: CGSize) throws -> CGImage {
        var box = [Float](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
        guard bounds(document, Int32(chapter), Int32(page), &box, &error) != 0 else { throw ReadError(String(cString: error)) }
        let width = Int32(max(1, min(maximum.width, maximum.height * CGFloat(box[2] / box[3]))).rounded(.up))
        var info = [Int32](repeating: 0, count: 4)
        guard let bytes = render(document, Int32(chapter), Int32(page), width, nil, 0, nil, nil, nil, &info, &error) else {
            throw ReadError(String(cString: error))
        }
        let data = Data(bytesNoCopy: bytes, count: Int(info[2]) * Int(info[1]), deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: Int(info[0]), height: Int(info[1]), bitsPerComponent: 8,
                bitsPerPixel: Int(info[3]) * 8, bytesPerRow: Int(info[2]), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ReadError("Cannot display the preview page.") }
        return image
    }
}
