import AppKit
import XCTest
@testable import SumraQuickLook

final class QuickLookBookTests: XCTestCase {
    private func archive(_ files: [String: Data], suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-QuickLook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, bytes) in files {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-r", "fixture." + suffix] + files.keys.sorted()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return root.appendingPathComponent("fixture." + suffix)
    }

    private func png(_ width: Int, _ height: Int, red: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }

    func testComicUsesNaturalOrderAndFitsWithoutStretching() async throws {
        let url = try archive(["10.png": png(80, 40, red: 0.5), "2.png": png(20, 40, red: 1)], suffix: "cbz")
        let book = try QuickLookBook(url: url)
        let first = try await book.image(maximum: CGSize(width: 100, height: 100))
        XCTAssertEqual(first.label, "1/2"); XCTAssertFalse(first.hasPrevious); XCTAssertTrue(first.hasNext)
        XCTAssertEqual(CGFloat(first.image.width) / CGFloat(first.image.height), 0.5, accuracy: 0.01)
        let next = try await book.image(maximum: CGSize(width: 100, height: 100), direction: 1)
        XCTAssertEqual(next.label, "2/2"); XCTAssertFalse(next.hasNext)
        XCTAssertEqual(CGFloat(next.image.width) / CGFloat(next.image.height), 2, accuracy: 0.01)
        let back = try await book.image(maximum: CGSize(width: 100, height: 100), direction: -1)
        XCTAssertEqual(back.label, first.label)
        XCTAssertEqual(QuickLookBook.fitted(CGSize(width: 100, height: 200), in: CGSize(width: 300, height: 300)),
                       CGRect(x: 75, y: 0, width: 150, height: 300))
    }

    func testEPUBRendersSVGAndNavigatesSpineUsingBundledEngine() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appendingPathComponent("build/engines/MuPDF.dylib")
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build the existing native engine first") }
        let strings = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "book.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title>Preview</dc:title><meta property='rendition:layout'>pre-paginated</meta></metadata><manifest><item id='cover' href='cover.xhtml' media-type='application/xhtml+xml'/><item id='body' href='body.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='cover'/><itemref idref='body'/></spine></package>",
            "cover.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><meta name='viewport' content='width=200,height=400'/></head><body style='margin:0'><svg xmlns='http://www.w3.org/2000/svg' width='200' height='400'><rect width='200' height='400' fill='red'/></svg></body></html>",
            "body.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><meta name='viewport' content='width=400,height=200'/></head><body><p>中文 Preview second chapter</p></body></html>"
        ]
        let url = try archive(strings.mapValues { Data($0.utf8) }, suffix: "epub")
        let before = try Data(contentsOf: url)
        let book = try QuickLookBook(url: url, engineURL: engine)
        let first = try await book.image(maximum: CGSize(width: 200, height: 400))
        XCTAssertEqual(first.label, "1/2 · 1/1")
        XCTAssertEqual(CGFloat(first.image.width) / CGFloat(first.image.height), 0.5, accuracy: 0.01)
        let second = try await book.image(maximum: CGSize(width: 400, height: 200), direction: 1)
        XCTAssertEqual(second.label, "2/2 · 1/1")
        XCTAssertEqual(CGFloat(second.image.width) / CGFloat(second.image.height), 2, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
