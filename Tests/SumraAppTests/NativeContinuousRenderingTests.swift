#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeContinuousRenderingTests: XCTestCase {
    func testNaturalChapterTilesStayWithinTheViewportAndKeepStablePixelEdges() {
        let visible = CGRect(x: 70, y: 50_000_123, width: 500, height: 680)
        let maximum = CGSize(width: 1200, height: 900)
        let chapter = CGRect(x: 0, y: 0, width: 720, height: 100_000_000)
        let tiles = RasterLayout.tiles(bounds: chapter, pixelWidth: 1440, resolution: 1,
            visible: visible, maximumSize: maximum)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.count, 6)
        XCTAssertTrue(tiles.allSatisfy { $0.width <= 1200 && $0.height <= 900 })
        XCTAssertLessThanOrEqual(tiles.reduce(0) { $0 + $1.width * $1.height }, 6 * 1200 * 900)
        let longer = RasterLayout.tiles(bounds: CGRect(x: 0, y: 0, width: 720, height: 200_000_000),
            pixelWidth: 1440, resolution: 1, visible: visible, maximumSize: maximum)
        XCTAssertEqual(tiles, longer, "Chapter length must not change viewport tile size or pixel origins")
        let pixels = CGRect(x: visible.minX * 2, y: visible.minY * 2, width: visible.width * 2, height: visible.height * 2)
        XCTAssertTrue(tiles.reduce(CGRect.null) { $0.union($1.rect) }.contains(pixels))
        for first in tiles {
            for second in tiles where first != second {
                XCTAssertTrue(first.rect.intersection(second.rect).isEmpty, "Neighboring tiles share edges without overlapping pixels")
            }
        }
    }

    func testNaturalReflowSkipsTheChapterPreviewAndRegionTilesPreserveTextAcrossTheirSeam() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let paragraphs = (0..<200).map {
            "Paragraph \($0): Continuous reading preserves the source text while rasterizing only the visible part of this long chapter."
        }
        for suffix in ["html", "md"] {
            let input = directory.url.appendingPathComponent("chapter." + suffix)
            let source = suffix == "md" ? paragraphs.joined(separator: "\n\n")
                : "<html><body>" + paragraphs.map { "<p>\($0)</p>" }.joined() + "</body></html>"
            try source.write(to: input, atomically: true, encoding: .utf8)
            let pages = try Pages(input, format: suffix == "md" ? .markdown : .html)
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 20, font: "system", theme: "light",
                pageSize: CGSize(width: 480, height: 0))
            let viewport = CGSize(width: 480, height: 360)
            let rendered = try await pages.render(0, viewport: viewport, scale: 2, columns: 1,
                rotation: 0, fit: "width", zoom: 1, viewportOnly: true)
            XCTAssertNil(rendered.image, "A continuous chapter must not allocate a whole-chapter preview")
            XCTAssertGreaterThan(rendered.bounds.height, viewport.height * 20)
            XCTAssertEqual(rendered.pixelWidth, 960)
            let count = await pages.count
            XCTAssertEqual(count, 1, "Natural continuous layout keeps the chapter on one canvas")
            let text = try await pages.text(0)
            XCTAssertTrue(text.contains("Paragraph 0:")); XCTAssertTrue(text.contains("Paragraph 199:"))
            let words = try await pages.words(0)
            let glyph = try XCTUnwrap(words.first { $0.bounds.midY > 100 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let scale = CGFloat(rendered.pixelWidth) / rendered.bounds.width
            let seam = Int(((glyph.bounds.midY - rendered.bounds.minY) * scale).rounded())
            let visible = CGRect(x: rendered.bounds.minX,
                y: rendered.bounds.minY + CGFloat(seam - 16) / scale,
                width: rendered.bounds.width, height: 32 / scale)
            let tiles = RasterLayout.tiles(bounds: rendered.bounds, pixelWidth: rendered.pixelWidth,
                resolution: rendered.tileResolution, visible: visible,
                maximumSize: CGSize(width: rendered.pixelWidth, height: seam))
            XCTAssertEqual(tiles.count, 2, "The real text glyph must straddle two adjacent strip renders")
            let reference = try await pages.image(0, width: rendered.pixelWidth,
                region: CGRect(x: 0, y: seam - 16, width: rendered.pixelWidth, height: 32))
            for tile in tiles {
                let bitmap = try await pages.image(0, width: rendered.pixelWidth, region: tile.rect)
                XCTAssertEqual(bitmap.width, tile.width); XCTAssertEqual(bitmap.height, tile.height)
                XCTAssertLessThanOrEqual(bitmap.bytesPerRow * bitmap.height, rendered.pixelWidth * seam * 4)
                let overlap = tile.rect.intersection(CGRect(x: 0, y: seam - 16, width: rendered.pixelWidth, height: 32))
                let actual = try XCTUnwrap(bitmap.cropping(to: overlap.offsetBy(dx: -CGFloat(tile.x), dy: -CGFloat(tile.y))))
                let expected = try XCTUnwrap(reference.cropping(to: overlap.offsetBy(dx: 0, dy: -CGFloat(seam - 16))))
                XCTAssertEqual(try rgba(actual), try rgba(expected), "Text pixels must remain continuous across the viewport strip seam")
            }
        }
    }

    func testNaturalViewportTilesMatchFullChapterRenderingForAuthoredArtworkAndBoundaryText() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<12 {
            for x in 0..<16 {
                let offset = y * 64 + x * 4
                pixels[offset] = UInt8(x * 16); pixels[offset + 1] = UInt8(y * 20)
                pixels[offset + 2] = 180; pixels[offset + 3] = 255
            }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.url.appendingPathComponent("artwork.png"))
        let authoredCSS = """
        @page { margin: 0 13pt !important; }
        html { background-color: #c8b4d8 !important; }
        body { margin: 0; background-color: #f7ecd2 !important; }
        p { margin: 3pt 0; padding: 2pt 5pt; border: 1pt solid #345f82;
            background-color: #e2edd6 !important; }
        .panel { padding: 7pt; border: 3pt double #8c315c; background-color: #eed9e4 !important; }
        table { width: 100%; border-collapse: collapse; margin: 5pt 0; }
        td { padding: 5pt; border: 2pt solid #3b596f; background-color: #dae5f0 !important; }
        img { width: 71pt; height: 53.25pt; }
        """
        let artwork = "<div class='panel'><img src='artwork.png'/><p>Artwork with bordered text and a raised <sup>accent</sup>.</p></div>"
        let table = "<table><tr><td>Left cell<br/>Second line</td><td>Right <sup>high</sup> and <sub>low</sub></td></tr></table>"
        let paragraphs = (0..<140).map { index in
            let paragraph = "<p>Depth \(index): faithful boundary text with <sup>raised</sup> and <sub>lowered</sub> glyphs, ffi, café, 中文, العربية and עברית.</p>"
            return paragraph + (index == 70 || index == 135 ? table + artwork : "")
        }.joined()
        let input = directory.url.appendingPathComponent("artwork.html")
        try ("<html><head><style>" + authoredCSS + "</style></head><body>" + artwork + table + paragraphs + "</body></html>")
            .write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf)
        _ = try file.relayout(fontSize: 14, lineHeight: 1.25, font: "serif", theme: "light",
            userCSS: authoredCSS, pageSize: CGSize(width: 420, height: 0))
        let bounds = try XCTUnwrap(file.bounds(0))
        let width = 631 // The real matrix has a noninteger scale; tiles must retain its raster phase.
        let scale = CGFloat(width) / bounds.width
        let reference = try file.image(0, width: width, transparent: true)
        XCTAssertGreaterThan(reference.height, 2_000)
        let words = try file.words(0)
        let deepGlyph = try XCTUnwrap(words.first {
            $0.text == "D" && $0.bounds.midY > bounds.height * 0.7
        })
        let seam = Int(((deepGlyph.bounds.midY - bounds.minY) * scale).rounded())
        let images = try file.imageBounds(0)
        let image = try XCTUnwrap(images.first)
        let imageCrop = CGRect(x: floor((image.minX - bounds.minX) * scale) + 3,
            y: floor((image.minY - bounds.minY) * scale) + 4,
            width: max(1, floor(image.width * scale) - 6), height: max(1, floor(image.height * scale) - 8))
        let regions = [
            CGRect(x: 0, y: 0, width: width, height: 193),
            CGRect(x: 17, y: 63, width: 193, height: 137),
            imageCrop,
            CGRect(x: 0, y: reference.height / 2, width: width, height: 211),
            CGRect(x: 0, y: seam - 12, width: width, height: 12),
            CGRect(x: 0, y: seam, width: width, height: 13),
            CGRect(x: 0, y: reference.height - 97, width: width, height: 97)
        ]
        // Rendering without a region supplies the existing full-page reference.
        // Compare actual viewport images against crops from that same matrix,
        // including a glyph cut between neighboring strips deep in the chapter.
        for region in regions {
            let tile = try file.image(0, width: width, transparent: true, region: region)
            let expected = try XCTUnwrap(reference.cropping(to: region))
            XCTAssertEqual(tile.width, expected.width); XCTAssertEqual(tile.height, expected.height)
            XCTAssertEqual(try rgba(tile), try rgba(expected), "Authored artwork or boundary text changed in viewport \(region)")
        }
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}
#endif
