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
        XCTAssertEqual(ThumbnailProvider.contextSize(for: next.image, maximum: CGSize(width: 200, height: 200)),
                       CGSize(width: 200, height: 100), "Landscape comic covers keep their authored proportions")
        let back = try await book.image(maximum: CGSize(width: 100, height: 100), direction: -1)
        XCTAssertEqual(back.label, first.label)
        XCTAssertEqual(QuickLookBook.fitted(CGSize(width: 100, height: 200), in: CGSize(width: 300, height: 300)),
                       CGRect(x: 75, y: 0, width: 150, height: 300))
    }

    func testComicForwardFailureKeepsLastSuccessfulCursor() async throws {
        let size = CGSize(width: 100, height: 100)
        let url = try archive(["01.png": png(20, 40, red: 1), "02.png": Data("broken image".utf8),
                               "03.png": png(80, 40, red: 0.5)], suffix: "cbz")
        let book = try QuickLookBook(url: url)
        let first = try await book.image(maximum: size)
        do {
            _ = try await book.image(maximum: size, direction: 1)
            XCTFail("The corrupt middle page must fail decoding")
        } catch { XCTAssertTrue(error.localizedDescription.contains("02.png")) }
        let afterForwardFailure = try await book.image(maximum: size)
        XCTAssertEqual(afterForwardFailure.label, first.label)
        XCTAssertFalse(afterForwardFailure.hasPrevious); XCTAssertTrue(afterForwardFailure.hasNext)

    }

    func testComicBackwardFailureKeepsLastSuccessfulCursor() async throws {
        let size = CGSize(width: 100, height: 100)
        let url = try archive(["01.png": png(20, 40, red: 1), "02.png": Data("broken image".utf8),
                               "03.png": png(80, 40, red: 0.5)], suffix: "cbz")
        let book = try QuickLookBook(url: url)
        // Direct model navigation selects the good page beyond the bad entry.
        let last = try await book.image(maximum: size, direction: 2)
        XCTAssertEqual(last.label, "3/3")
        do {
            _ = try await book.image(maximum: size, direction: -1)
            XCTFail("Backward decoding must report the corrupt page too")
        } catch { XCTAssertTrue(error.localizedDescription.contains("02.png")) }
        let afterFailure = try await book.image(maximum: size)
        XCTAssertEqual(afterFailure.label, last.label)
        XCTAssertTrue(afterFailure.hasPrevious); XCTAssertFalse(afterFailure.hasNext)
        let recovered = try await book.image(maximum: size, direction: -2)
        XCTAssertEqual(recovered.label, "1/3")
    }

    @MainActor
    private func previewControls(_ controller: PreviewViewController) throws -> (NSButton, NSTextField, NSButton, QuickLookPageView) {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.view)
        return (try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "‹" }),
                try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first),
                try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "›" }),
                try XCTUnwrap(views.compactMap { $0 as? QuickLookPageView }.first))
    }

    @MainActor
    private func waitForPreview(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), description)
    }

    @MainActor
    func testPreviewButtonsAndKeyboardRecoverAfterCorruptPage() async throws {
        _ = NSApplication.shared
        let url = try archive(["01.png": png(20, 40, red: 1), "02.png": png(80, 40, red: 0.5),
                               "03.png": Data("broken image".utf8)], suffix: "cbz")
        let controller = PreviewViewController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { controller.viewDidDisappear(); window.contentViewController = nil; window.close() }
        try await controller.preparePreviewOfFile(at: url)
        let (previous, label, next, pageView) = try previewControls(controller)
        XCTAssertFalse(previous.isEnabled); XCTAssertTrue(next.isEnabled)
        next.performClick(nil)
        try await waitForPreview("Next button must display page 2") { label.stringValue == "2/3" }
        let lastImage = try XCTUnwrap(pageView.image)
        XCTAssertTrue(previous.isEnabled); XCTAssertTrue(next.isEnabled)
        next.performClick(nil)
        try await waitForPreview("Decode failure must be visible") { label.stringValue.contains("03.png") }
        XCTAssertTrue(pageView.image === lastImage, "A failed page must retain the successful bitmap")
        XCTAssertTrue(previous.isEnabled); XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(controller.view))
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}",
            isARepeat: false, keyCode: 123))
        try XCTUnwrap(window.firstResponder).keyDown(with: left)
        try await waitForPreview("Left key must return from the failed page to page 1") { label.stringValue == "1/3" }
        XCTAssertFalse(previous.isEnabled); XCTAssertTrue(next.isEnabled)
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}",
            isARepeat: false, keyCode: 124))
        try XCTUnwrap(window.firstResponder).keyDown(with: right)
        try await waitForPreview("Right key remains usable after recovery") { label.stringValue == "2/3" }
        previous.performClick(nil)
        try await waitForPreview("Previous button remains usable after recovery") { label.stringValue == "1/3" }
    }

    @MainActor
    func testFirstPageFailureAndReplacementDoNotLockNavigation() async throws {
        _ = NSApplication.shared
        let first = try archive(["01.png": png(20, 40, red: 1), "02.png": Data("broken image".utf8)], suffix: "cbz")
        let replacement = try archive(["01.png": png(80, 40, red: 0.5), "02.png": png(40, 40, red: 0.2)], suffix: "cbz")
        let controller = PreviewViewController()
        defer { controller.viewDidDisappear() }
        try await controller.preparePreviewOfFile(at: first)
        let (previous, label, next, pageView) = try previewControls(controller)
        let firstImage = try XCTUnwrap(pageView.image)
        next.performClick(nil)
        try await waitForPreview("The bad second image must report its name") { label.stringValue.contains("02.png") }
        XCTAssertTrue(pageView.image === firstImage)
        XCTAssertFalse(previous.isEnabled); XCTAssertTrue(next.isEnabled)
        next.performClick(nil)
        // Replace while a navigation task is still outstanding on the main actor.
        try await controller.preparePreviewOfFile(at: replacement)
        XCTAssertEqual(label.stringValue, "1/2")
        XCTAssertFalse(previous.isEnabled); XCTAssertTrue(next.isEnabled)
        next.performClick(nil)
        try await waitForPreview("Replacement navigation must not be blocked or overwritten by the cancelled task") { label.stringValue == "2/2" }
        XCTAssertTrue(previous.isEnabled); XCTAssertFalse(next.isEnabled)
        previous.performClick(nil)
        controller.viewDidDisappear()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(pageView.image, "A disappearing preview must not be repopulated by cancelled navigation")
        try await controller.preparePreviewOfFile(at: replacement)
        next.performClick(nil)
        try await waitForPreview("A reused controller must retain navigation after disappearance") { label.stringValue == "2/2" }
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
        // The native engine rejects this bitmap width before allocating pixels.
        // Force a real render error after crossing the spine, not a mock failure.
        let rejectedSize = CGSize(width: 1_000_000_000, height: 2_000_000_000)
        do {
            _ = try await book.image(maximum: rejectedSize, direction: 1)
            XCTFail("The native bitmap-size guard must reject the render")
        } catch { XCTAssertEqual(error.localizedDescription, "Page bitmap is too large") }
        let afterForwardFailure = try await book.image(maximum: CGSize(width: 200, height: 400))
        XCTAssertEqual(afterForwardFailure.label, first.label)
        XCTAssertFalse(afterForwardFailure.hasPrevious); XCTAssertTrue(afterForwardFailure.hasNext)
        let second = try await book.image(maximum: CGSize(width: 400, height: 200), direction: 1)
        XCTAssertEqual(second.label, "2/2 · 1/1")
        XCTAssertEqual(CGFloat(second.image.width) / CGFloat(second.image.height), 2, accuracy: 0.01)
        XCTAssertEqual(ThumbnailProvider.contextSize(for: second.image, maximum: CGSize(width: 200, height: 200)),
                       CGSize(width: 200, height: 100), "Fixed-layout ebooks keep landscape page proportions")
        do {
            _ = try await book.image(maximum: rejectedSize, direction: -1)
            XCTFail("The backward chapter render must reject the bitmap too")
        } catch { XCTAssertEqual(error.localizedDescription, "Page bitmap is too large") }
        let afterBackwardFailure = try await book.image(maximum: CGSize(width: 400, height: 200))
        XCTAssertEqual(afterBackwardFailure.label, second.label)
        XCTAssertTrue(afterBackwardFailure.hasPrevious); XCTAssertFalse(afterBackwardFailure.hasNext)
        let recovered = try await book.image(maximum: CGSize(width: 200, height: 400), direction: -1)
        XCTAssertEqual(recovered.label, first.label)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testOriginalIssue42SamplesRenderAndNavigateWithoutRenaming() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE42_FIXTURES"] else {
            throw XCTSkip("Set SUMRA_ISSUE42_FIXTURES to the reporter's extracted formatsampler directory")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = root.appendingPathComponent("build/engines/MuPDF.dylib")
        for name in ["sample_comic.cbz", "sample_comic.cbr", "sample_illustrated.epub", "sample_illustrated.mobi", "sample_illustrated.azw3", "sample_illustrated.fb2"] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            let original = try Data(contentsOf: url)
            let book = try QuickLookBook(url: url, engineURL: engine)
            let first = try await book.image(maximum: CGSize(width: 600, height: 800))
            XCTAssertGreaterThan(first.image.width, 100, name)
            XCTAssertGreaterThan(first.image.height, 100, name)
            if ["epub", "mobi", "azw3", "fb2"].contains(url.pathExtension) {
                let canvas = ThumbnailProvider.contextSize(for: first.image, maximum: CGSize(width: 256, height: 256))
                XCTAssertLessThan(canvas.width, canvas.height, "\(name) must give its generated first page a portrait document frame")
                XCTAssertEqual(canvas.width / canvas.height, 420.0 / 595.0, accuracy: 0.01, name)
            }
            let bitmap = NSBitmapImageRep(cgImage: first.image)
            var ink = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 { ink += 1 }
                }
            }
            // Authored title-only pages are valid; reject blank output, not sparse typography.
            XCTAssertGreaterThan(ink, 0, "\(name) must contain visible page content")
            XCTAssertTrue(first.hasNext, name)
            let second = try await book.image(maximum: CGSize(width: 600, height: 800), direction: 1)
            XCTAssertNotEqual(second.label, first.label, name)
            let back = try await book.image(maximum: CGSize(width: 600, height: 800), direction: -1)
            XCTAssertEqual(back.label, first.label, name)
            XCTAssertEqual(try Data(contentsOf: url), original, name)
        }
    }

}
