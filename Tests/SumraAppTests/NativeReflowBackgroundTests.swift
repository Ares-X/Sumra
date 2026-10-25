#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeReflowBackgroundTests: XCTestCase {
    func testNativePageAndTileMarginsFollowEveryPaletteWithoutChangingPassageIdentity() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let file = try NativeFile(fixture(in: directory.url), engine: .mupdf)
        let palettes = ReaderTheme.builtins + [ReaderTheme(id: "custom-test", name: "Custom", text: 0xf0e0d0,
            background: 0x182c3d, link: 0x91c9ff)]
        var sourceRevision: String?
        var styleSignature: String?
        var originalPassage: NativePassage?
        var imageColor: UInt32?
        for height in [CGFloat(480), 0] {
            for palette in palettes {
                _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "serif", theme: palette.dark ? "dark" : "light",
                    userCSS: palette.css + "\n", pageMargins: PageMargins(cssValues: [48]), pageSize: CGSize(width: 420, height: height))
                let passage = try XCTUnwrap(file.passage(0, at: CGPoint(x: 60, y: 180)))
                if let sourceRevision { XCTAssertEqual(passage.sourceRevision, sourceRevision, "A palette change must retain source identity") }
                else { sourceRevision = passage.sourceRevision }
                if let styleSignature { XCTAssertEqual(passage.styleSignature, styleSignature, "Palette colors must not invalidate saved passages") }
                else { styleSignature = passage.styleSignature; originalPassage = passage }
                XCTAssertNotNil(try file.position(for: XCTUnwrap(originalPassage)))
                let full = try file.image(0, width: 420)
                let sample = try rgb(full, x: 4, y: 4)
                XCTAssertEqual(sample, palette.background, "Full page margin: palette=\(palette.id), height=\(height)")
                let tile = try file.image(0, width: 420, region: CGRect(x: 0, y: 0, width: 24, height: 24))
                XCTAssertEqual(try rgb(tile, x: 4, y: 4), palette.background,
                    "Viewport tile margin: palette=\(palette.id), height=\(height)")
                let art = try XCTUnwrap(file.imageBounds(0).first)
                let color = try rgb(full, x: Int(art.midX), y: Int(art.midY))
                if let imageColor { XCTAssertEqual(color, imageColor, "Changing paper color must preserve authored image pixels") }
                else { imageColor = color; XCTAssertGreaterThan(color >> 16, 240); XCTAssertLessThan(color & 0xffff, 0x4000) }
            }
        }
    }

    func testHostedFB2MarginsStayDarkAfterPageTurnsAndContinuousMode() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = try fixture(in: directory.url)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        let defaults = UserDefaults.standard, keys = ["flow", "spread"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.theme = "dark"; state.flow = "paged"; state.spread = true; state.fit = "page"
        state.automaticLayout = false; state.cover = false; state.rotation = 0; state.zoom = 1
        state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.4
        state.margin = 48; state.pageMargins = PageMargins(cssValues: [48])
        state.userCSS = ""; state.useDocumentCSS = true; state.scrollbarMode = "hidden"
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.colorSpace = .sRGB; window.contentView = host
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            withExtendedLifetime(directory) {}
        }
        func rendered(in view: NSView) -> Bool {
            RasterReader.pageIsRendered(in: view, pages: pages, location: state.pageLocation(state.page)) ||
                view.subviews.contains { rendered(in: $0) }
        }
        func settle(after previousPage: Int? = nil) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if state.reflowable, rendered(in: host), state.pendingReflowPosition == nil,
                   previousPage == nil || state.page != previousPage { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "FB2 reader failed to paint")
        }
        func assertMargins(_ stage: String, line: UInt = #line) throws {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            for fraction in [0.01, 0.99] {
                let color = try rgb(image, x: Int(Double(image.width) * fraction), y: image.height / 2)
                XCTAssertLessThan(color, 0x404040,
                    "\(stage): theme=\(state.theme), resolved=\(state.resolvedTheme), palette=\(String(state.palette.background, radix: 16)), sample=\(String(color, radix: 16)), scrollDrawsBackground=\(String(describing: state.readerScrollView?.drawsBackground)), clipDrawsBackground=\(String(describing: state.readerScrollView?.contentView.drawsBackground))", line: line)
            }
        }
        try await settle()
        XCTAssertEqual(state.palette.background, 0x000000); XCTAssertEqual(state.resolvedTheme, "dark")
        try assertMargins("facing")
        let firstPage = state.page
        state.turn(1)
        try await settle(after: firstPage)
        XCTAssertGreaterThan(state.page, firstPage)
        try assertMargins("next facing row")
        state.setFlow("continuous")
        try await settle()
        let naturalPage = try await pages.bounds(0)
        XCTAssertGreaterThan(naturalPage.height, 1000)
        try assertMargins("continuous")
    }

    private func fixture(in directory: URL) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let paragraphs = (0..<100).map { "<p>Paragraph \($0) keeps authored text visible while the theme and reading mode change.</p>" }.joined()
        let xml = """
        <FictionBook xmlns='http://www.gribuser.ru/xml/fictionbook/2.0' xmlns:l='http://www.w3.org/1999/xlink'>
        <description><title-info><book-title>Reader paper</book-title><lang>en</lang></title-info></description>
        <body><section><image l:href='#art'/>\(paragraphs)</section></body>
        <binary id='art' content-type='image/png'>\((data as Data).base64EncodedString())</binary></FictionBook>
        """
        let file = directory.appendingPathComponent("paper.fb2")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> UInt32 {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let space = try XCTUnwrap(image.colorSpace)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
    }
}
#endif
