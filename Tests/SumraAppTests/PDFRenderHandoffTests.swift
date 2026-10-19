#if os(macOS)
import AppKit
import XCTest
import SumraCore
@testable import Sumra

final class PDFRenderHandoffTests: XCTestCase {
    func testConcurrentRequestsShareTheSamePDFBitmap() async throws {
        let pages = try Pages(fixture(), format: .pdf)
        let images = try await withThrowingTaskGroup(of: CGImage.self) { group in
            for _ in 0..<8 {
                group.addTask { try await pages.image(0, width: 1_400) }
            }
            var result: [CGImage] = []
            for try await image in group { result.append(image) }
            return result
        }
        let first = try XCTUnwrap(images.first)
        XCTAssertEqual(images.count, 8)
        XCTAssertTrue(images.allSatisfy { $0 === first },
                      "Prediction and visible requests for identical PDF pixels must share one replay")
        let cached = try await pages.image(0, width: 1_400)
        XCTAssertTrue(cached === first)
    }

    func testCancelledPredictionLeavesTheVisibleReplayAvailable() async throws {
        let pages = try Pages(fixture(), format: .pdf)
        let prediction = Task {
            try await pages.image(PageLocation(page: 0), width: 2_000, priority: ReaderRenderPriority(visible: false))
        }
        let visible = Task { try await pages.image(0, width: 2_000) }
        await Task.yield()
        prediction.cancel()
        do { _ = try await prediction.value; XCTFail("A cancelled prediction must discard its result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let image = try await visible.value
        XCTAssertEqual(image.width, 2_000)
        let cached = try await pages.image(0, width: 2_000)
        XCTAssertTrue(cached === image)
    }

    func testCancellingAllSubscribersAllowsANewReplay() async throws {
        let pages = try Pages(fixture(), format: .pdf)
        let abandoned = Task { try await pages.image(0, width: 1_400) }
        await Task.yield()
        abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("A cancelled replay must discard its result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let image = try await pages.image(0, width: 1_400)
        XCTAssertEqual(image.width, 1_400)
    }

    private func fixture() throws -> URL {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("Build MuPDF before PDF handoff tests")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-PDF-handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("vectors.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setLineWidth(0.3)
        // A detailed page keeps the replay active while overlapping callers
        // arrive; the assertion observes output identity, not elapsed time.
        for index in 0..<20_000 {
            let x = CGFloat(index % 600), y = CGFloat(index / 600 * 20)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: 600 - x, y: y + 19))
            context.strokePath()
        }
        context.endPDFPage()
        context.closePDF()
        return source
    }
}
#endif
