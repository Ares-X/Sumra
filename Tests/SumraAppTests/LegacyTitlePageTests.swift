#if os(macOS)
import AppKit
import CryptoKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class LegacyTitlePageTests: XCTestCase {
    private let sizes = [CGSize(width: 560, height: 720), CGSize(width: 1000, height: 800),
                         CGSize(width: 720, height: 480), CGSize(width: 1200, height: 800),
                         CGSize(width: 360, height: 720), CGSize(width: 1200, height: 360),
                         CGSize(width: 1600, height: 1000), CGSize(width: 720, height: 480)]

    private func picture() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8,
            bytesPerRow: 800, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fb2(_ directory: URL, firstSection: String, css: String = "") throws -> URL {
        let source = directory.appendingPathComponent("title.fb2")
        let image = try picture()
        try """
            <FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0' xmlns:l='http://www.w3.org/1999/xlink'>
            <description><title-info><book-title>Title page</book-title><lang>en</lang></title-info></description>
            <stylesheet type='text/css'>\(css)</stylesheet><body><section>\(firstSection)</section>
            <section><p>FOLLOWING CHAPTER</p><p>LAST TEXT</p></section></body>
            <binary id='art' content-type='image/png'>\(image.base64EncodedString())</binary></FictionBook>
            """.write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private var titleSection: String {
        "<p><strong>VISIBLE TITLE</strong></p><p><image l:href='#art'/></p><p><strong>VISIBLE AUTHOR</strong></p>"
    }

    private func layout(_ file: NativeFile, _ size: CGSize) throws {
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
    }

    private func allImages(_ file: NativeFile) throws -> [CGRect] {
        try (0..<file.count).flatMap { try file.imageBounds($0) }
    }

    private func retain(_ image: CGImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_LEGACY_TITLE_EVIDENCE"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ReaderImages.encoded(image, extension: "png").write(to: directory.appendingPathComponent(name + ".png"))
    }

    func testFB2TitleImageAndAuthorGrowAndCenterTogetherAcrossWindowSizes() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(fb2(directory.url, firstSection: titleSection), engine: .mupdf)
        for size in sizes {
            try layout(file, size)
            let art = try XCTUnwrap(file.imageBounds(0).first)
            let canvas = try XCTUnwrap(file.bounds(0))
            let title = try XCTUnwrap(file.matches("VISIBLE TITLE", page: 0).first).rects.reduce(CGRect.null) { $0.union($1) }
            let firstPageText = try file.text(0) ?? ""
            let author = try XCTUnwrap(file.matches("VISIBLE AUTHOR", page: 0).first, "Author must stay with image at \(size), text: \(firstPageText)").rects.reduce(CGRect.null) { $0.union($1) }
            let group = title.union(author).union(art)
            XCTAssertEqual(try allImages(file).count, 1)
            XCTAssertTrue(canvas.insetBy(dx: -0.05, dy: -0.05).contains(group), "Title, art and author must fit: \(size), \(group)")
            XCTAssertEqual(art.width / art.height, 2.0 / 3.0, accuracy: 0.002)
            let availableHeight = size.height - 6 * 17 - 2 * 17 * 1.2
            let expectedHeight = min((size.width - 4 * 17) * 1.5, availableHeight)
            XCTAssertEqual(art.height, expectedHeight, accuracy: 0.1,
                "Title art must fill the limiting dimension after actual text and page insets")
            XCTAssertEqual(art.midX, canvas.midX, accuracy: 0.05)
            XCTAssertEqual(title.midX, canvas.midX, accuracy: 1)
            XCTAssertEqual(author.midX, canvas.midX, accuracy: 1)
            XCTAssertEqual(group.midY, canvas.midY, accuracy: 14, "The complete title group must be visually centered")
            if size.height >= 800 { XCTAssertGreaterThan(art.height, 400, "Large windows must grow beyond the source's 225pt natural height") }
            let text = try (0..<file.count).map { try file.text($0) ?? "" }.joined()
            for marker in ["VISIBLE TITLE", "VISIBLE AUTHOR", "FOLLOWING CHAPTER", "LAST TEXT"] {
                XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1,
                    "Every title/body marker must appear once at \(size): \(marker)")
            }
            XCTAssertEqual(file.count, 2, "A fitted title must have one following body page without blanks")
            try retain(file.image(0, width: Int(ceil(min(size.width / canvas.width, size.height / canvas.height) * canvas.width))), name: "authored-fb2-\(Int(size.width))x\(Int(size.height))")
        }
        try layout(file, CGSize(width: 720, height: 0))
        XCTAssertEqual(try XCTUnwrap(file.imageBounds(0).first).height, 225, accuracy: 0.05,
            "Continuous FB2 keeps its existing natural image size")
    }

    private struct BodyEvidence: Equatable {
        let bounds: CGRect
        let text: String
        let images: [CGRect]
        let matches: [[CGRect]]
    }

    private func bodyEvidence(_ file: NativeFile, query: String) throws -> [BodyEvidence] {
        try (1..<file.count).map { page in
            BodyEvidence(bounds: try XCTUnwrap(file.bounds(page)), text: try file.text(page) ?? "",
                images: try file.imageBounds(page), matches: try file.matches(query, page: page).map(\.rects))
        }
    }

    private func redBounds(_ image: CGImage) throws -> CGRect {
        // Native RGB pages and AppKit's caching bitmaps have different byte orders.
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var left = image.width, right = -1, top = image.height, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = y * context.bytesPerRow + x * 4
                if bytes[index] > 200 && bytes[index + 1] < 50 && bytes[index + 2] < 50 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(right, left)
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    @MainActor
    func testIntrinsicTitleCanvasFitsArtAndDescendersWithShownAndAutomaticScrollbars() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let section = "<p><strong>Agjpq VISIBLE TITLE</strong></p><p><image l:href='#art'/></p><p><strong>Agjpq VISIBLE AUTHOR</strong></p>"
        let fb2File = try NativeFile(fb2(directory.url, firstSection: section), engine: .mupdf)
        let mobiContent = try XCTUnwrap(LegacyText.mobiContent(mobi(picture())))
        let mobiFile = try NativeFile(mobiContent.materialize(in: directory.url), engine: .mupdf)
        for (format, file) in [("fb2", fb2File), ("mobi", mobiFile)] {
        for mode in ["smart", "shown"] {
            for frame in [CGSize(width: 1000, height: 800), CGSize(width: 560, height: 720),
                          CGSize(width: 360, height: 720), CGSize(width: 1200, height: 360)] {
                let viewport = ReaderScrollbars.initialReadingViewport(in: frame, mode: mode, continuous: false)
                _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light", pageSize: viewport)
                let canvas = try XCTUnwrap(file.bounds(0))
                XCTAssertLessThan(canvas.height, viewport.height, "The default paper insets must not remain in the title canvas")
                let display = RasterLayout.size(page: canvas.size, viewport: viewport, columns: 1,
                    rotation: 0, fit: "page", zoom: 1, origin: canvas.origin)
                let transform = RasterLayout.transform(bounds: canvas, size: display, rotation: 0)
                let art = try XCTUnwrap(file.imageBounds(0).first)
                let words = try file.words(0).filter { !$0.bounds.isEmpty }
                if format == "fb2" { XCTAssertFalse(words.isEmpty) }
                for word in words {
                    XCTAssertTrue(canvas.insetBy(dx: -0.05, dy: -0.05).contains(word.bounds), "Every glyph including descenders must fit: \(word.text)")
                    let displayed = word.bounds.applying(transform)
                    XCTAssertTrue(CGRect(origin: .zero, size: display).insetBy(dx: -0.05, dy: -0.05).contains(displayed))
                    let roundTrip = displayed.applying(transform.inverted())
                    XCTAssertEqual(roundTrip.minX, word.bounds.minX, accuracy: 0.001)
                    XCTAssertEqual(roundTrip.minY, word.bounds.minY, accuracy: 0.001)
                }
                let hits = try file.matches("Agjpq", page: 0)
                XCTAssertEqual(hits.count, format == "fb2" ? 2 : 0, "Title and author search stay on the first page")
                for hit in hits {
                    XCTAssertNotNil(hit.source, "Intrinsic fitting preserves semantic source anchors")
                    for rect in hit.rects {
                        XCTAssertTrue(CGRect(origin: .zero, size: display).insetBy(dx: -0.05, dy: -0.05).contains(rect.applying(transform)))
                    }
                }
                let image = try file.image(0, width: Int(ceil(display.width)))
                let pixels = try redBounds(image)
                let renderedScale = CGFloat(image.width) / canvas.width
                let expected = art.applying(CGAffineTransform(translationX: -canvas.minX, y: -canvas.minY)
                    .concatenating(CGAffineTransform(scaleX: renderedScale, y: renderedScale)))
                XCTAssertEqual(pixels.minX, expected.minX, accuracy: 1.5)
                XCTAssertEqual(pixels.minY, expected.minY, accuracy: 1.5)
                XCTAssertEqual(pixels.width, expected.width, accuracy: 2)
                XCTAssertEqual(pixels.height, expected.height, accuracy: 2)
                XCTAssertEqual(pixels.width / pixels.height, 2.0 / 3.0, accuracy: 0.01)
                XCTAssertLessThanOrEqual(image.height, Int(ceil(viewport.height)) + 2)
                XCTAssertEqual(file.count, 2)
                XCTAssertTrue(try XCTUnwrap(file.text(1)).contains("LAST TEXT"))
                try retain(image, name: "intrinsic-title-\(format)-\(mode)-\(Int(frame.width))x\(Int(frame.height))")
            }
        }
        }
    }

    func testExplicitPublisherAndReaderMarginsKeepTheFullTitlePageCanvas() throws {
        let cssCases = ["@page{margin:3em 2em}", "@page{margin:0}",
            "FictionBook{margin:1em}", "FictionBook{margin:0}",
            "p{margin-top:1em}", "p{margin-top:0}", "p>image{margin:1em 0}", "p>image{margin:0}",
            "section{padding:20px}", "FictionBook{padding:20px}", "body{border:2px solid red}"]
        let viewport = CGSize(width: 1000, height: 800)
        for css in cssCases {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let file = try NativeFile(fb2(directory.url, firstSection: titleSection, css: css), engine: .mupdf)
            try layout(file, viewport)
            XCTAssertEqual(try file.bounds(0), CGRect(origin: .zero, size: viewport), "Authored spacing remains authoritative: \(css)")
        }
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let fb2File = try NativeFile(fb2(directory.url, firstSection: titleSection), engine: .mupdf)
        let mobiContent = try XCTUnwrap(LegacyText.mobiContent(mobi(picture())))
        let mobiFile = try NativeFile(mobiContent.materialize(in: directory.url), engine: .mupdf)
        for file in [fb2File, mobiFile] {
        for margins in [[0.0], [51, 34]] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                pageMargins: PageMargins(cssValues: margins), pageSize: viewport)
            XCTAssertEqual(try file.bounds(0), CGRect(origin: .zero, size: viewport))
        }
        for css in ["body{margin:1em}", "body{margin:0}"] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                userCSS: css, pageSize: viewport)
            XCTAssertEqual(try file.bounds(0), CGRect(origin: .zero, size: viewport))
        }
        }
        _ = try mobiFile.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
            userCSS: "div{margin:0}", pageSize: viewport)
        XCTAssertEqual(try mobiFile.bounds(0), CGRect(origin: .zero, size: viewport))
    }

    @MainActor
    private func renderedTitleCanvas(in view: NSView, pages: Pages, location: PageLocation) -> RasterCanvas.Canvas? {
        if let canvas = view as? RasterCanvas.Canvas, canvas.pages === pages,
           canvas.location == location, canvas.readingReady, canvas.image != nil { return canvas }
        return view.subviews.lazy.compactMap { self.renderedTitleCanvas(in: $0, pages: pages, location: location) }.first
    }

    @MainActor
    private func checkHostedTitle(_ source: URL, mode: String, spread: Bool) async throws {
        let document = try ReadingDocument.open(source, deferReflowLayout: true)
        guard case .pages(let pages) = document.content else { return XCTFail("The title must use native pages") }
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.reflowable = true; state.automaticLayout = false
        state.flow = "paged"; state.spread = spread; state.cover = false; state.fit = "page"; state.zoom = 1
        state.fontSize = 17; state.lineHeight = 1.6; state.font = "system"; state.theme = "light"
        state.margin = 0; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.showContents = false; state.scrollbarMode = mode
        let viewport = ReaderScrollbars.initialReadingViewport(in: CGSize(width: 1000, height: 800), mode: mode, continuous: false)
        let paper = RasterReader.pageSize(in: viewport, spread: spread)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", pageSize: paper)
        state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        state.updatePosition(.init(page: 0))
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        var canvas: RasterCanvas.Canvas?
        let deadline = Date().addingTimeInterval(8)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
            if let candidate = renderedTitleCanvas(in: host, pages: pages, location: state.pageLocation(0)),
               candidate.window != nil,
               !spread || renderedTitleCanvas(in: host, pages: pages, location: state.pageLocation(1)) != nil {
                canvas = candidate; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        let view = try XCTUnwrap(canvas, "Hosted title must render: \(state.error ?? "no error")")
        let bounds = try await pages.bounds(0)
        XCTAssertGreaterThan(bounds.minX, 0, "The hosted test must exercise a nonzero intrinsic page origin")
        let images = try await pages.imageBounds(state.pageLocation(0))
        let art = try XCTUnwrap(images.first)
        let displayed = art.applying(view.pageTransform)
        XCTAssertTrue(view.visibleRect.insetBy(dx: -1, dy: -1).contains(displayed), "Paged and spread modes show the whole title artwork")
        for word in try await pages.words(0) where !word.bounds.isEmpty {
            XCTAssertTrue(view.bounds.insetBy(dx: -0.05, dy: -0.05).contains(word.bounds.applying(view.pageTransform)), "First/last glyphs and descenders remain inside the hosted canvas")
        }
        let hits = try await pages.matches("Agjpq", page: 0)
        if let hit = hits.first {
            XCTAssertNotNil(hit.source)
            view.match = hit
            for rect in hit.rects { XCTAssertTrue(view.bounds.insetBy(dx: -0.05, dy: -0.05).contains(rect.applying(view.pageTransform))) }
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let pixels = try redBounds(image)
        let scale = CGFloat(image.width) / view.bounds.width
        XCTAssertEqual(pixels.width, displayed.width * scale, accuracy: 3)
        XCTAssertEqual(pixels.height, displayed.height * scale, accuracy: 3)
        try retain(image, name: "hosted-\(source.pathExtension)-\(mode)-spread-\(spread)")
    }

    @MainActor
    func testHostedIntrinsicTitlesKeepArtAndSearchInPagedAndSpreadModes() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let preferences = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in preferences { defaults.set(value, forKey: key) } }
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let section = "<p><strong>Agjpq VISIBLE TITLE</strong></p><p><image l:href='#art'/></p><p><strong>Agjpq VISIBLE AUTHOR</strong></p>"
        let fb2Source = try fb2(directory.url, firstSection: section)
        let mobiSource = directory.url.appendingPathComponent("title.mobi")
        try mobi(picture()).write(to: mobiSource)
        for source in [fb2Source, mobiSource] {
            for mode in ["smart", "shown"] {
                for spread in [false, true] { try await checkHostedTitle(source, mode: mode, spread: spread) }
            }
        }
    }

    func testOrdinaryFirstChapterAndAuthoredImageSizesKeepTheirFlow() throws {
        let cases = [
            ("<p>ORDINARY PROSE</p><p><image l:href='#art'/></p>", "", CGFloat(150), CGFloat(225)),
            (titleSection, "image{width:40px;height:auto}", CGFloat(40), CGFloat(60)),
            ("<p><strong>INLINE TITLE <image l:href='#art'/> INLINE AUTHOR</strong></p>", "image{width:20px;height:30px}", CGFloat(20), CGFloat(30))
        ]
        for (section, css, width, height) in cases {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let file = try NativeFile(fb2(directory.url, firstSection: section, css: css), engine: .mupdf)
            try layout(file, CGSize(width: 1200, height: 800))
            let art = try XCTUnwrap(file.imageBounds(0).first)
            XCTAssertEqual(art.width, width, accuracy: 0.05)
            XCTAssertEqual(art.height, height, accuracy: 0.05)
            XCTAssertEqual(file.count, 1, "Ordinary prose and constrained illustrations must not acquire a reader title-page break")
            XCTAssertTrue(try XCTUnwrap(file.text(0)).contains("FOLLOWING CHAPTER"))
        }
    }


    func testPublisherTitleMarginsKeepTheirSpaceIncludingDefaultEquivalentValues() throws {
        func art(_ section: String, css: String) throws -> CGRect {
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let file = try NativeFile(fb2(directory.url, firstSection: section, css: css), engine: .mupdf)
            try layout(file, CGSize(width: 1000, height: 800))
            XCTAssertTrue(try XCTUnwrap(file.text(0)).contains("VISIBLE AUTHOR"))
            return try XCTUnwrap(file.imageBounds(0).first)
        }
        let plain = try art(titleSection, css: "")
        let page = try art(titleSection, css: "@page{margin:51px 34px}")
        XCTAssertEqual(page, plain, "An explicit default-equivalent @page must remain authoritative")
        let book = try art(titleSection, css: "FictionBook{margin:17px}")
        XCTAssertEqual(book.height, plain.height - 34, accuracy: 0.1)
        XCTAssertEqual(book.minY, plain.minY + 17, accuracy: 0.1)

        let firstMargin = titleSection.replacingOccurrences(of: "<p><strong>VISIBLE TITLE",
            with: "<p style='margin-top:40px'><strong>VISIBLE TITLE")
        let defaultBook = try art(firstMargin, css: "")
        let zeroBook = try art(firstMargin, css: "FictionBook{margin:0}")
        XCTAssertEqual(defaultBook, zeroBook,
            "Reclaiming default book insets must preserve an author's collapsed first-paragraph margin")

        let imageZero = try art(titleSection, css: "p>image{display:block;margin:0}")
        let imageMargin = try art(titleSection, css: "p>image{display:block;margin:12px 0}")
        XCTAssertEqual(imageMargin.height, imageZero.height - 24, accuracy: 0.1)
        XCTAssertEqual(imageMargin.minY, imageZero.minY + 12, accuracy: 0.1)
    }

    func testOverfullTitleTextPreservesFollowingChapterWithoutLeakingImageFitting() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let title = String(repeating: "WRAPPED TITLE WORDS ", count: 18)
        let author = (0..<20).map { "<p><strong>AUTHOR LINE \($0)</strong></p>" }.joined()
        let source = try fb2(directory.url, firstSection:
            "<p><strong>\(title)</strong></p><p><image l:href='#art'/></p>" + author)
        let file = try NativeFile(source, engine: .mupdf)
        try layout(file, CGSize(width: 360, height: 360))
        let texts = try (0..<file.count).map { try file.text($0) ?? "" }
        let text = texts.joined()
        for marker in ["WRAPPED TITLE WORDS", "AUTHOR LINE 0", "AUTHOR LINE 19", "FOLLOWING CHAPTER", "LAST TEXT"] {
            XCTAssertTrue(text.contains(marker), "An overfull title section must retain \(marker)")
        }
        XCTAssertEqual(try allImages(file).count, 1)
        let chapterPage = try XCTUnwrap(texts.firstIndex { $0.contains("FOLLOWING CHAPTER") })
        let chapter = try XCTUnwrap(file.matches("FOLLOWING CHAPTER", page: chapterPage).first?.rects.first)
        XCTAssertLessThan(chapter.minX, 100, "An overfull title must not leak centering into ordinary chapter prose")
    }

    private func mobi(_ image: Data) -> Data {
        func put(_ value: Int, _ offset: Int, _ size: Int, _ data: inout Data) {
            for index in 0..<size { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (size - index - 1))) }
        }
        let text = Data("<html><body><p>FOLLOWING CHAPTER</p><p>LAST TEXT</p></body></html>".utf8)
        var header = Data(repeating: 0, count: 268)
        put(1, 0, 2, &header); put(text.count, 4, 4, &header); put(1, 8, 2, &header); put(4096, 10, 2, &header)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(228, 20, 4, &header); put(65001, 28, 4, &header); put(6, 36, 4, &header)
        put(2, 108, 4, &header); put(64, 128, 4, &header); put(0xffff_ffff, 168, 4, &header)
        header.replaceSubrange(244..<248, with: Data("EXTH".utf8))
        put(24, 248, 4, &header); put(1, 252, 4, &header); put(201, 256, 4, &header); put(12, 260, 4, &header)
        let records = [header, text, image]
        var data = Data(repeating: 0, count: 78 + records.count * 8 + 2)
        data.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8)); put(records.count, 76, 2, &data)
        for (index, record) in records.enumerated() { put(data.count, 78 + 8 * index, 4, &data); data.append(record) }
        return data
    }

    func testMetadataMobiCoverFillsAndCentersWithoutChangingAuthoredBody() throws {
        let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
        let content = try XCTUnwrap(LegacyText.mobiContent(mobi(picture())))
        let file = try NativeFile(content.materialize(in: directory.url), engine: .mupdf)
        for size in sizes {
            try layout(file, size)
            let art = try XCTUnwrap(file.imageBounds(0).first), canvas = try XCTUnwrap(file.bounds(0))
            XCTAssertEqual(try allImages(file).count, 1)
            XCTAssertEqual(art.width / art.height, 2.0 / 3.0, accuracy: 0.002)
            XCTAssertEqual(art.midX, canvas.midX, accuracy: 0.05)
            XCTAssertEqual(art.midY, canvas.midY, accuracy: 8)
            XCTAssertTrue(canvas.insetBy(dx: -0.05, dy: -0.05).contains(art))
            if size.height >= 800 { XCTAssertGreaterThan(art.height, 400) }
            XCTAssertEqual(file.count, 2, "The metadata cover must be followed by the authored body without blank pages")
            XCTAssertTrue(try XCTUnwrap(file.text(1)).contains("LAST TEXT"))
            try retain(file.image(0, width: Int(ceil(min(size.width / canvas.width, size.height / canvas.height) * canvas.width))), name: "authored-mobi-\(Int(size.width))x\(Int(size.height))")
        }
    }

    func testOriginalAliceFirstPageFitsAndCentersAcrossWindowSizes() throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_LEGACY_TITLE_SAMPLES"] else {
            throw XCTSkip("Set SUMRA_LEGACY_TITLE_SAMPLES to the original Alice FB2/MOBI directory")
        }
        for suffix in ["fb2", "mobi"] {
            let source = URL(fileURLWithPath: path).appendingPathComponent("AlicesAdventuresinWonderland_Chapter1." + suffix)
            let bytes = try Data(contentsOf: source), before = SHA256.hash(data: bytes)
            let directory = try TemporaryDirectory(); defer { withExtendedLifetime(directory) {} }
            let input = suffix == "mobi" ? try XCTUnwrap(LegacyText.mobiContent(bytes)).materialize(in: directory.url) : source
            let file = try NativeFile(input, engine: .mupdf)
            for size in sizes {
                try layout(file, size)
                let art = try XCTUnwrap(file.imageBounds(0).first), canvas = try XCTUnwrap(file.bounds(0))
                XCTAssertEqual(art.width / art.height, 440.0 / 633, accuracy: 0.002)
                XCTAssertEqual(art.midX, canvas.midX, accuracy: 0.1)
                XCTAssertTrue(canvas.insetBy(dx: -0.1, dy: -0.1).contains(art))
                if size.height >= 800 { XCTAssertGreaterThan(art.height, 475, "Original Alice art must grow beyond natural raster size") }
                if suffix == "fb2" {
                    let text = try XCTUnwrap(file.text(0))
                    XCTAssertTrue(text.contains("Lewis Carroll"))
                    let lineCount = text.split(separator: "\n").count
                    let expectedHeight = min((size.width - 4 * 17) * 633 / 440,
                        size.height - 6 * 17 - CGFloat(lineCount) * 17 * 1.2)
                    XCTAssertEqual(art.height, expectedHeight, accuracy: 0.1,
                        "Original Alice must fill the available title canvas at \(size)")
                }
                XCTAssertEqual(try allImages(file).count, 4, "The four original illustrations must each occur once")
                try retain(file.image(0, width: Int(ceil(min(size.width / canvas.width, size.height / canvas.height) * canvas.width))), name: "original-\(suffix)-\(Int(size.width))x\(Int(size.height))")
            }
            for viewport in [CGSize(width: 560, height: 720), CGSize(width: 1000, height: 800),
                             CGSize(width: 360, height: 720), CGSize(width: 1200, height: 360),
                             CGSize(width: 720, height: 480), CGSize(width: 1200, height: 800)] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light", pageSize: viewport)
            let intrinsicBounds = try XCTUnwrap(file.bounds(0))
            XCTAssertLessThan(intrinsicBounds.height, viewport.height)
            let bodyBefore = try bodyEvidence(file, query: "Alice")
            let firstImages = try file.imageBounds(0)
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "system", theme: "light",
                userCSS: "@page{margin:51px 34px}", pageSize: viewport)
            XCTAssertEqual(try file.bounds(0), CGRect(origin: .zero, size: viewport))
            XCTAssertEqual(try file.imageBounds(0), firstImages)
            XCTAssertEqual(try bodyEvidence(file, query: "Alice"), bodyBefore,
                "Intrinsic title fitting changes neither body text/images nor any search rectangle: \(suffix)")
            }
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)), before)
        }
    }
}
#endif
