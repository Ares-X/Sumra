#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeLinkHoverLifecycleTests: XCTestCase {
    func testSpreadHandoffAndBlankMovementDismissWithoutMouseExit() async throws {
        let reader = try await makeReader()
        defer { reader.close() }
        let (left, right) = try spreadCanvases(reader)
        try move(to: left.links[0], in: left, reader: reader)
        let first = try await preview(reader)

        // No mouseExited is delivered to the first page. The next page must
        // still take ownership of the reader's one hover image.
        try move(to: right.links[0], in: right, reader: reader)
        XCTAssertNil(first.parent)
        let second = try await preview(reader)
        XCTAssertFalse(second === first)
        XCTAssertEqual(previews(reader).count, 1)

        try move(to: blankPoint(in: right), in: right, reader: reader)
        XCTAssertNil(second.parent)
        try await assertNoPreview(reader)
        XCTAssertFalse(reader.window.isVisible)
    }

    func testRepeatedDestinationAnchorsPreviewAtTheHoveredOccurrence() async throws {
        let reader = try await makeReader()
        defer { reader.close() }
        let (left, _) = try spreadCanvases(reader)
        let destination = try XCTUnwrap(left.links.first?.uri)
        let repeated = left.links.filter { $0.uri == destination }.sorted { $0.bounds.minY < $1.bounds.minY }
        XCTAssertEqual(repeated.count, 2)
        let source = try XCTUnwrap(repeated.last)
        try move(to: source, in: left, reader: reader)
        let panel = try await preview(reader)
        let anchor = reader.window.convertToScreen(left.convert(source.bounds.applying(left.pageTransform), to: nil))
        let belowGap = anchor.minY - panel.frame.maxY
        let aboveGap = panel.frame.minY - anchor.maxY
        XCTAssertTrue(abs(belowGap - 8) < 1 || abs(aboveGap - 8) < 1,
            "Preview must adjoin the hovered occurrence, rather than the first link with the same destination: \(anchor), \(panel.frame)")
        XCTAssertFalse(panel.frame.intersects(anchor))
    }

    func testPointerDepartureDuringDelayDoesNotRequireAnExitEvent() async throws {
        let reader = try await makeReader()
        defer { reader.close() }
        let (left, _) = try spreadCanvases(reader)
        try move(to: left.links[0], in: left, reader: reader)
        // Simulate leaving while rendering is pending, without any tracking
        // callback. Presentation must use the actual current pointer position.
        reader.window.pointer = left.convert(try blankPoint(in: left), to: nil)
        try await assertNoPreview(reader)
        try move(to: left.links[0], in: left, reader: reader)
        _ = try await preview(reader)
    }

    func testStationaryTrackingRebuildPreservesHoverAndSourceReplacementDismissesIt() async throws {
        let reader = try await makeReader()
        defer { reader.close() }
        let (left, _) = try spreadCanvases(reader)
        let source = left.links[0]
        try move(to: source, in: left, reader: reader)
        let panel = try await preview(reader)
        left.updateTrackingAreas()
        left.updateLinkHints()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(panel.parent === reader.window,
            "An unchanged source under a stationary pointer must survive tracking maintenance")
        XCTAssertTrue(previews(reader).first === panel)

        left.links.removeAll { $0.uri == source.uri && $0.bounds == source.bounds }
        left.updateLinkHints()
        XCTAssertNil(panel.parent, "Replacing the source invalidates its displayed preview")
        try await assertNoPreview(reader)
    }

    func testSourceReplacementCancelsPendingHover() async throws {
        let reader = try await makeReader()
        defer { reader.close() }
        let (left, _) = try spreadCanvases(reader)
        let source = left.links[0]
        try move(to: source, in: left, reader: reader)
        left.links.removeAll { $0.uri == source.uri && $0.bounds == source.bounds }
        left.updateLinkHints()
        try await assertNoPreview(reader)
    }

    func testKeyLossClosesShownAndPendingPreviewsWithoutRevival() async throws {
        let reader = try await makeReader()
        defer { reader.close() }
        let (left, _) = try spreadCanvases(reader)
        let source = left.links[0]
        try move(to: source, in: left, reader: reader)
        let panel = try await preview(reader)
        reader.window.simulatedKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: reader.window)
        XCTAssertNil(panel.parent)
        reader.window.simulatedKey = true
        try await assertNoPreview(reader)

        try move(to: source, in: left, reader: reader)
        reader.window.simulatedKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: reader.window)
        reader.window.simulatedKey = true
        try await assertNoPreview(reader)
        XCTAssertNil(reader.state.error)
    }

    @MainActor private struct Reader {
        let directory: TemporaryDirectory
        let state: ReaderState
        let host: NSHostingView<RasterReader>
        let window: HoverLifecycleWindow

        func close() {
            window.simulatedKey = false
            state.windowClosed()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            withExtendedLifetime(directory) {}
        }
    }

    private func makeReader() async throws -> Reader {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = try makeEPUB(in: directory.url)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.flow = "paged"; state.spread = true; state.cover = false; state.automaticLayout = false
        state.fit = "page"; state.zoom = 1; state.fontSize = 17; state.lineHeight = 1.4
        state.font = "system"; state.theme = "light"; state.margin = 24; state.pageMargins = nil
        state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.rectangularSelection = false; state.disableLinks = false
        state.keyboardLinkFollowing = false; state.keyboardTextSelection = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.landscapeAsSpread = false
        state.hoverPreview = true; state.showContents = false; state.scrollbarMode = "hidden"
        let prepared = try await pages.prepare()
        state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 24, font: "system", theme: "light",
            pageSize: CGSize(width: 448, height: 560))
        _ = state.applyChapterLayout(await pages.chapterLayout)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let screen: NSScreen?
        if let display = ProcessInfo.processInfo.environment["SUMRA_TEST_DISPLAY_NAME"] {
            screen = try XCTUnwrap(NSScreen.screens.first { $0.localizedName == display },
                "Requested test display is unavailable")
        } else { screen = NSScreen.main }
        let origin = screen.map { CGPoint(x: $0.visibleFrame.midX - 450, y: $0.visibleFrame.midY - 280) } ?? .zero
        let window = HoverLifecycleWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 900, height: 560)),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; state.window = window
        let reader = Reader(directory: directory, state: state, host: host, window: window)
        let deadline = Date().addingTimeInterval(10)
        var stableSince: Date?
        var previousRevision = -1
        repeat {
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            let visible = canvases(in: host).filter { $0.readingReady && !$0.visibleRect.isEmpty && !$0.links.isEmpty }
            let revision = await pages.layoutRevision
            if visible.count >= 2, state.pendingReflowPosition == nil,
               visible.contains(where: { $0.links.count == 2 }), visible.contains(where: { $0.links.count == 1 }) {
                if previousRevision == revision {
                    if let stableSince, Date().timeIntervalSince(stableSince) >= 0.2 {
                        let source = try XCTUnwrap(visible.first?.links.first)
                        let image = try await pages.previewImage(source.uri, from: visible[0].page)
                        XCTAssertNotNil(image, "The fixture destination must have a renderable hover image")
                        XCTAssertFalse(window.isVisible, "Hosted lifecycle tests must not display a reader window")
                        return reader
                    }
                    if stableSince == nil { stableSince = Date() }
                } else { stableSince = nil }
            } else { stableSince = nil }
            previousRevision = revision
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        print("Hover fixture setup: reflowable=\(state.reflowable), spread=\(state.spread), pages=\(await pages.count), visible=\(state.visiblePages), error=\(state.error ?? "nil"), canvases=\(canvases(in: host).map { "page=\($0.page), links=\($0.links.count), ready=\($0.readingReady), bounds=\($0.bounds), visible=\($0.visibleRect)" })")
        reader.close()
        throw NSError(domain: "NativeLinkHoverLifecycleTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: state.error ?? "Two-page hover fixture did not render its three authored links"])
    }

    private func makeEPUB(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        func chapter(_ body: String) -> String {
            "<html xmlns='http://www.w3.org/1999/xhtml'><head><style>@page{margin:0}body{margin:24px}p{margin:0}.repeated{margin-top:140px}</style></head><body>\(body)</body></html>"
        }
        // Separate spine parts provide two visible reader pages without making
        // hover lifecycle coverage depend on CSS forced-break behavior.
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "book.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='2.0'><metadata/><manifest><item id='left' href='left.xhtml' media-type='application/xhtml+xml'/><item id='right' href='right.xhtml' media-type='application/xhtml+xml'/><item id='destination' href='destination.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='left'/><itemref idref='right'/><itemref idref='destination'/></spine></package>",
            "left.xhtml": chapter("<p><a href='destination.xhtml#destination'>First left source</a></p><p class='repeated'><a href='destination.xhtml#destination'>Second left source</a></p>"),
            "right.xhtml": chapter("<p><a href='destination.xhtml#destination'>Right page source</a></p>"),
            "destination.xhtml": chapter("<h1 id='destination'>Destination</h1><p>Preview destination body.</p>")
        ]
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "hover-spread.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        XCTAssertEqual(zip.terminationStatus, 0)
        return directory.appendingPathComponent("hover-spread.epub")
    }

    private func spreadCanvases(_ reader: Reader) throws -> (RasterCanvas.Canvas, RasterCanvas.Canvas) {
        let visible = canvases(in: reader.host).filter { $0.readingReady && !$0.visibleRect.isEmpty && !$0.links.isEmpty }
        return (try XCTUnwrap(visible.first { $0.links.count == 2 }), try XCTUnwrap(visible.first { $0.links.count == 1 }))
    }

    private func canvases(in view: NSView) -> [RasterCanvas.Canvas] {
        if let canvas = view as? RasterCanvas.Canvas { return [canvas] }
        return view.subviews.flatMap { canvases(in: $0) }
    }

    private func move(to link: RasterLink, in canvas: RasterCanvas.Canvas, reader: Reader) throws {
        let bounds = link.bounds.applying(canvas.pageTransform)
        try move(to: CGPoint(x: bounds.midX, y: bounds.midY), in: canvas, reader: reader)
    }

    private func move(to point: CGPoint, in canvas: RasterCanvas.Canvas, reader: Reader) throws {
        let windowPoint = canvas.convert(point, to: nil)
        reader.window.pointer = windowPoint
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reader.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let content = try XCTUnwrap(reader.window.contentView)
        let target = content.hitTest(content.convert(windowPoint, from: nil))
        XCTAssertTrue(target === canvas, "The dispatched pointer must hit its real hosted page")
        try XCTUnwrap(target).mouseMoved(with: event)
    }

    private func blankPoint(in canvas: RasterCanvas.Canvas) throws -> CGPoint {
        let visible = canvas.visibleRect.intersection(canvas.bounds)
        for point in [CGPoint(x: visible.midX, y: visible.midY),
                      CGPoint(x: visible.maxX - 12, y: visible.maxY - 12)] {
            if !canvas.links.contains(where: { $0.bounds.applying(canvas.pageTransform).contains(point) }) { return point }
        }
        throw NSError(domain: "NativeLinkHoverLifecycleTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The fixture needs a blank pointer destination"])
    }

    private func previews(_ reader: Reader) -> [NSWindow] {
        reader.window.childWindows?.filter { $0.contentView is NSImageView } ?? []
    }

    private func preview(_ reader: Reader) async throws -> NSWindow {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let panel = previews(reader).first { return panel }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && reader.state.error == nil
        return try XCTUnwrap(previews(reader).first, reader.state.error ?? "A hovered link did not create its preview")
    }

    private func assertNoPreview(_ reader: Reader, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(previews(reader).isEmpty, "The reader retained or revived a stale hover image", file: file, line: line)
    }
}

@MainActor
private final class HoverLifecycleWindow: NSWindow {
    var simulatedKey = true
    var pointer = CGPoint(x: -1, y: -1)
    override var isKeyWindow: Bool { simulatedKey }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}
#endif
