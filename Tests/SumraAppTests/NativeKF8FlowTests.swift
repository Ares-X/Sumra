#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import XCTest
@testable import Sumra

final class NativeKF8FlowTests: XCTestCase {
    func testExtractedSVGFlowPaintsEmbeddedImageAndPreservesSurroundingText() throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("svg-flow.azw3")
        let original = try book()
        try original.write(to: source)
        defer {
            XCTAssertEqual(try? Data(contentsOf: source), original, "Opening and rendering must preserve the KF8 source")
            withExtendedLifetime(directory) {}
        }

        let document = try ReadingDocument.open(source, deferReflowLayout: true)
        defer { withExtendedLifetime(document) {} }
        guard case .pages = document.content else { return XCTFail("KF8 must open in the native reader") }
        let converted = try XCTUnwrap(document.temporary).url.appendingPathComponent("document.mobihtml")
        let file = try NativeFile(converted, engine: .mupdf)
        for size in [CGSize(width: 640, height: 480), CGSize(width: 360, height: 480)] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
            XCTAssertEqual(file.count, 1, "The illustration and both paragraphs fit one page")
            let text = try XCTUnwrap(file.text(0))
            XCTAssertTrue(text.contains("BEFORE SVG IMAGE"), text)
            XCTAssertTrue(text.contains("AFTER SVG IMAGE"), text)
            let bounds = try XCTUnwrap(file.bounds(0))
            let images = try file.imageBounds(0)
            XCTAssertEqual(images.count, 1, "The SVG's extracted PNG must render exactly once")
            let image = try XCTUnwrap(images.first)
            XCTAssertGreaterThan(image.width, 100)
            XCTAssertEqual(image.width, image.height, accuracy: 0.1)
            XCTAssertTrue(bounds.insetBy(dx: -0.03, dy: -0.03).contains(image), "The complete SVG must remain inside the page")

            let rendered = try file.image(0, width: Int(size.width))
            let painted = try redBounds(NSBitmapImageRep(cgImage: rendered))
            let scaleX = CGFloat(rendered.width) / bounds.width
            let scaleY = CGFloat(rendered.height) / bounds.height
            let expected = CGRect(x: (image.minX - bounds.minX) * scaleX, y: (image.minY - bounds.minY) * scaleY,
                                  width: image.width * scaleX, height: image.height * scaleY)
            XCTAssertEqual(painted.minX, expected.minX, accuracy: 2)
            XCTAssertEqual(painted.maxX, expected.maxX, accuracy: 2)
            XCTAssertEqual(painted.minY, expected.minY, accuracy: 2)
            XCTAssertEqual(painted.maxY, expected.maxY, accuracy: 2)
            XCTAssertEqual(painted.width, painted.height, accuracy: 2, "The colored artwork must remain square and unclipped")
        }
    }

    func testMultiPartKF8IsolatesLaterListStylesRendersSVGAndReopensSourcePassage() throws {
        let directory = try TemporaryDirectory()
        let original = try book(multipleParts: true)
        let content = try XCTUnwrap(LegacyText.mobiContent(original))
        XCTAssertEqual(content.additionalParts.count, 1)
        let source = try content.materialize(in: directory.url)
        let file = try NativeFile(source, engine: .mupdf)
        let size = CGSize(width: 640, height: 600)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
        XCTAssertEqual(file.count, 2)
        let first = try XCTUnwrap(file.text(0)), second = try XCTUnwrap(file.text(1))
        XCTAssertNotNil(first.range(of: #"1\.\s*EARLIER LIST"#, options: .regularExpression), first)
        XCTAssertTrue(second.contains("LATER LIST"), second)
        XCTAssertNil(second.range(of: #"1\.\s*LATER LIST"#, options: .regularExpression), second)
        for page in 0..<2 {
            XCTAssertEqual(try file.imageBounds(page).count, 1)
            _ = try redBounds(NSBitmapImageRep(cgImage: file.image(page, width: 640)))
        }
        let image = try XCTUnwrap(file.imageBounds(1).first)
        let passage = try XCTUnwrap(file.passage(1, at: CGPoint(x: image.midX, y: image.midY)))
        let reopenedDirectory = try TemporaryDirectory()
        let reopenedSource = try XCTUnwrap(LegacyText.mobiContent(original)).materialize(in: reopenedDirectory.url)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: reopenedSource))
        let reopened = try NativeFile(reopenedSource, engine: .mupdf)
        _ = try reopened.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: size)
        XCTAssertNotNil(try reopened.position(for: passage), "A fresh materialization must retain the same source identity")
        withExtendedLifetime((directory, reopenedDirectory)) {}
    }

    func testKF8TwoPNGResourcesInSVGPreserveAuthoredTextAndSpine() throws {
        let directory = try TemporaryDirectory()
        let original = try book(multipleParts: true, twoImages: true)
        let content = try XCTUnwrap(LegacyText.mobiContent(original))
        XCTAssertEqual(content.additionalParts.count, 1, "SVG image resources must not replace the authored KF8 spine with image-only pages")
        for (index, name) in ["00001", "00002"].enumerated() {
            let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(content.resources[name])))
            XCTAssertEqual(image.pixelsWide, 64)
            XCTAssertEqual(image.pixelsHigh, 64)
            let colors = try colorCounts(try XCTUnwrap(image.cgImage))
            XCTAssertGreaterThan(index == 0 ? colors.red : colors.green, 100, "The source PNG must have its authored color")
            XCTAssertEqual(index == 0 ? colors.green : colors.red, 0)
        }
        let source = try content.materialize(in: directory.url)
        let file = try NativeFile(source, engine: .mupdf)
        _ = try file.relayout(fontSize: 17, lineHeight: 1.2, font: "system", theme: "light", pageSize: CGSize(width: 640, height: 600))
        XCTAssertEqual(file.count, 2)
        let first = try XCTUnwrap(file.text(0)), second = try XCTUnwrap(file.text(1))
        XCTAssertTrue(first.contains("BEFORE SVG IMAGE") && first.contains("AFTER SVG IMAGE"), first)
        XCTAssertTrue(second.contains("LATER LIST"), second)
        for page in 0..<file.count {
            let rendered = try file.image(page, width: 640)
            let colors = try colorCounts(rendered)
            XCTAssertGreaterThan(colors.red, 100, "The first real PNG must paint through its SVG flow; sRGB red maximum \(colors.redMaximum)")
            XCTAssertGreaterThan(colors.green, 100, "The second real PNG must paint through its SVG flow; sRGB green maximum \(colors.greenMaximum)")
        }
        withExtendedLifetime(directory) {}
    }

    private func colorCounts(_ image: CGImage) throws -> (red: Int, green: Int, redMaximum: UInt8, greenMaximum: UInt8) {
        // Compare source and page pixels in the same explicit color space.
        // AppKit's deviceRGB conversion changes saturated channel values.
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0, green = 0, redMaximum: UInt8 = 0, greenMaximum: UInt8 = 0
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let pixel = pixels + y * context.bytesPerRow + x * 4
                if Int(pixel[0]) > 2 * Int(pixel[1]) && Int(pixel[0]) > 2 * Int(pixel[2]) {
                    redMaximum = max(redMaximum, pixel[0])
                    if pixel[0] > 204 { red += 1 }
                }
                if Int(pixel[1]) > 2 * Int(pixel[0]) && Int(pixel[1]) > 2 * Int(pixel[2]) {
                    greenMaximum = max(greenMaximum, pixel[1])
                    if pixel[1] > 204 { green += 1 }
                }
            }
        }
        return (red, green, redMaximum, greenMaximum)
    }

    private func redBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        var left = bitmap.pixelsWide, top = bitmap.pixelsHigh, right = -1, bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.7, color.redComponent > color.greenComponent * 1.6, color.redComponent > color.blueComponent * 1.6 else { continue }
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left else { throw ReadError("The native KF8 page did not paint the embedded red image") }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private func png(red: CGFloat = 1, green: CGFloat = 0) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func put(_ value: Int, at offset: Int, size: Int = 4, in data: inout Data) {
        for i in 0..<size { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (size - i - 1))) }
    }

    private func variable(_ value: Int) -> Data {
        var bytes = [UInt8(value & 127) | 128], remaining = value >> 7
        while remaining > 0 { bytes.insert(UInt8(remaining & 127), at: 0); remaining >>= 7 }
        return Data(bytes)
    }

    // A real one-entry TAGX/INDX pair for either the skeleton or division table.
    private func index(name: String, values: [Int], skeleton: Bool, additional: [(String, [Int])] = []) -> [Data] {
        var top = Data(repeating: 0, count: 192), entries = Data(repeating: 0, count: 192)
        top.replaceSubrange(0..<4, with: Data("INDX".utf8))
        entries.replaceSubrange(0..<4, with: Data("INDX".utf8))
        put(192, at: 4, in: &top); put(1, at: 24, in: &top)
        var tagx = Data("TAGX".utf8) + Data(repeating: 0, count: 8)
        let tags: [UInt8] = skeleton ? [1, 1, 1, 0, 6, 2, 2, 0, 0, 0, 0, 1]
                                     : [2, 1, 1, 0, 3, 1, 2, 0, 4, 1, 4, 0, 6, 2, 8, 0, 0, 0, 0, 1]
        put(12 + tags.count, at: 4, in: &tagx); put(1, at: 8, in: &tagx)
        tagx.append(contentsOf: tags); top.append(tagx)
        var offsets = [Int]()
        for (name, values) in [(name, values)] + additional {
            offsets.append(entries.count)
            entries.append(UInt8(name.utf8.count)); entries.append(Data(name.utf8))
            entries.append(skeleton ? 3 : 15)
            for value in values { entries.append(variable(value)) }
        }
        put(entries.count, at: 20, in: &entries); put(offsets.count, at: 24, in: &entries)
        entries.append(Data("IDXT".utf8))
        for offset in offsets { entries.append(contentsOf: [UInt8(offset >> 8), UInt8(offset & 255)]) }
        return [top, entries]
    }

    private func book(multipleParts: Bool = false, twoImages: Bool = false) throws -> Data {
        let skeleton = "<html><head><style>@page{margin:0}body{margin:16px}p{margin:12px 0}</style></head><body></body></html>"
        let fragment = (multipleParts ? "<ol><li>EARLIER LIST</li></ol>" : "") + "<p>BEFORE SVG IMAGE</p><p><img width='180' height='180' src='kindle:flow:0001?mime=image/svg+xml'/></p><p>AFTER SVG IMAGE</p>"
        let images = twoImages
            ? "<image href='kindle:embed:0001?mime=image/png' width='90' height='180'/><image href='kindle:embed:0002?mime=image/png' x='90' width='90' height='180'/>"
            : "<image href='kindle:embed:0001?mime=image/png' width='180' height='180'/>"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180' viewBox='0 0 180 180'>" + images + "</svg>"
        let laterSkeleton = "<html><head><title>Later list</title><style>li{list-style-type:none}</style></head><body class='later' style='margin:16px'></body></html>"
        let laterFragment = "<ol><li>LATER LIST</li></ol><img width='180' height='180' src='kindle:flow:0001?mime=image/svg+xml'/>"
        let laterStart = skeleton.utf8.count + fragment.utf8.count
        let laterInsertion = laterStart + laterSkeleton.range(of: "</body>")!.lowerBound.utf16Offset(in: laterSkeleton)
        let raw = Data((skeleton + fragment + (multipleParts ? laterSkeleton + laterFragment : "")).utf8), text = raw + Data(svg.utf8)
        let insertion = skeleton.range(of: "</body>")!.lowerBound.utf16Offset(in: skeleton)
        var header = Data(repeating: 0, count: 280)
        put(1, at: 0, size: 2, in: &header); put(text.count, at: 4, in: &header); put(1, at: 8, size: 2, in: &header)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(264, at: 20, in: &header); put(65001, at: 28, in: &header); put(8, at: 36, in: &header)
        put(7, at: 108, in: &header); put(0xffff_ffff, at: 168, in: &header)
        put(2, at: 192, in: &header); put(3, at: 248, in: &header); put(5, at: 252, in: &header)
        var fdst = Data("FDST".utf8) + Data(repeating: 0, count: 24)
        put(12, at: 4, in: &fdst); put(2, at: 8, in: &fdst)
        put(0, at: 12, in: &fdst); put(raw.count, at: 16, in: &fdst)
        put(raw.count, at: 20, in: &fdst); put(text.count, at: 24, in: &fdst)
        var records = [header, text, fdst]
        records += index(name: String(insertion), values: [0, 0, 0, 0, fragment.utf8.count], skeleton: false,
            additional: multipleParts ? [(String(laterInsertion), [0, 1, 1, 0, laterFragment.utf8.count])] : [])
        records += index(name: "part", values: [1, 0, skeleton.utf8.count], skeleton: true,
            additional: multipleParts ? [("later", [1, laterStart, laterSkeleton.utf8.count])] : [])
        records.append(try png())
        if twoImages { records.append(try png(red: 0, green: 1)) }
        var pdb = Data(repeating: 0, count: 78 + 8 * records.count + 2)
        pdb.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8)); put(records.count, at: 76, size: 2, in: &pdb)
        for (i, record) in records.enumerated() { put(pdb.count, at: 78 + i * 8, in: &pdb); pdb.append(record) }
        return pdb
    }
}
#endif
