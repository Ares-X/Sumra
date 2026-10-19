#if os(macOS)
import AppKit
import ImageIO
import XCTest
import SumraCore
@testable import Sumra

final class ComicDecodeConcurrencyTests: XCTestCase {
    func testOverlappingComicRequestsSharePixelsWithoutMixingPagesOrWidths() async throws {
        let pages = try Pages(fixture(), format: .comic)
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for index in 0..<8 {
                let page = index % 2
                group.addTask { (page, try await pages.image(page, width: 900)) }
            }
            var result: [(Int, CGImage)] = []
            for try await image in group { result.append(image) }
            return result
        }
        let first = try XCTUnwrap(images.first { $0.0 == 0 }?.1)
        let second = try XCTUnwrap(images.first { $0.0 == 1 }?.1)
        XCTAssertFalse(first === second)
        for (page, image) in images {
            XCTAssertTrue(image === (page == 0 ? first : second))
            XCTAssertEqual(image.width, 900)
        }
        let firstBytes = try XCTUnwrap(first.dataProvider?.data) as Data
        let secondBytes = try XCTUnwrap(second.dataProvider?.data) as Data
        XCTAssertNotEqual(firstBytes, secondBytes)
        let resized = try await pages.image(0, width: 600)
        XCTAssertEqual(resized.width, 600)
        XCTAssertFalse(resized === first)
    }

    func testCancelledComicPredictionDoesNotPoisonTheVisiblePage() async throws {
        let pages = try Pages(fixture(), format: .comic)
        let prediction = Task {
            try await pages.image(PageLocation(page: 0), width: 1_800, priority: ReaderRenderPriority(visible: false))
        }
        let visible = Task { try await pages.image(0, width: 1_800) }
        await Task.yield()
        prediction.cancel()
        do { _ = try await prediction.value; XCTFail("A cancelled prediction must discard its result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let image = try await visible.value
        XCTAssertEqual(image.width, 1_800)
        let cached = try await pages.image(0, width: 1_800)
        XCTAssertTrue(cached === image)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-comic-decode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for page in 0..<2 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1_800, height: 2_600, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(page == 0 ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1_800, height: 2_600))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(page).png") as CFURL,
                "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let archive = directory.appendingPathComponent("pages.cbz")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory; zip.arguments = ["-q", "-0", archive.lastPathComponent, "0.png", "1.png"]
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return archive
    }
}
#endif
