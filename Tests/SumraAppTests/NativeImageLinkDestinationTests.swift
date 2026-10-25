#if os(macOS)
import AppKit
import CryptoKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Uses the generated issue #42 GUI fixtures without changing their bytes.
/// SUMRA_ISSUE42_GUI_FIXTURES points at build/issue42/gui-fixtures.
@MainActor
final class NativeImageLinkDestinationTests: XCTestCase {
    func testStandaloneImageAnchorsResolveToTheirTopBeforeCaption() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = try EPUBImagePositionFixture.make(in: directory.url, captions: true)
        let file = try NativeFile(input, engine: .mupdf)
        for width in [640.0, 480.0] {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.4, font: "system", theme: "dark",
                pageSize: CGSize(width: width, height: 0))
            for index in 0..<4 {
                let destination = try XCTUnwrap(file.resolve("art.xhtml#art\(index)"))
                let art = try XCTUnwrap(file.imageBounds(destination.page).dropFirst(index).first)
                let y = try XCTUnwrap(destination.y)
                XCTAssertLessThanOrEqual(y, art.minY + 1, "The generated soft break must not resolve at the image bottom")
                XCTAssertLessThanOrEqual(art.minY - y, 6, "Only the authored 5px page inset may precede the image")
            }
        }
    }

    func testImageOnlyParagraphLinkResolvesToFirstImageTopAcrossMobiFB2AndEPUB() async throws {
        let (directory, originals, inputs) = try fixtures()
        defer { unchanged(originals); withExtendedLifetime(directory) {} }
        for input in inputs {
            let document = try ReadingDocument.open(input)
            defer { withExtendedLifetime(document) {} }
            guard case .pages(let pages) = document.content else { return XCTFail("Expected a native document") }
            for width in [640.0, 480.0] {
                _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32,
                    font: "system", theme: "dark", pageSize: CGSize(width: width, height: 0))
                let target = try await pages.resolve(input.pathExtension == "epub" ? "body.xhtml#art" : "#art")
                let destination = try XCTUnwrap(target, input.lastPathComponent)
                let images = try await pages.imageBounds(destination.page)
                let first = try XCTUnwrap(images.first, input.lastPathComponent)
                XCTAssertEqual(images.count, 2, "The natural chapter must retain both authored images")
                let y = try XCTUnwrap(destination.y)
                print("IMAGE-LINK native \(input.lastPathComponent) width=\(width) target=\(destination) first=\(first)")
                XCTAssertLessThanOrEqual(y, first.minY + 1, "The image link must not resolve below its top")
                // These fixtures have no @page CSS. MuPDF's HTML reader uses
                // a 3em top page inset, outside the authored flow coordinates.
                XCTAssertLessThanOrEqual(first.minY - y, 3 * 17 + 1, "Only the page's top inset may precede the image")
                let restored = try await pages.restore(destination)
                XCTAssertEqual(try XCTUnwrap(restored.y), y, accuracy: 1,
                    "Attaching a text/image passage must retain the authored destination coordinate")
            }
        }
    }

    func testContinuousImageLinkClickPlacesFirstImageTopAtViewportAcrossMobiFB2AndEPUB() async throws {
        let (directory, originals, inputs) = try fixtures()
        defer { unchanged(originals); withExtendedLifetime(directory) {} }
        _ = NSApplication.shared
        for input in inputs {
            let document = try ReadingDocument.open(input, deferReflowLayout: true)
            guard case .pages(let pages) = document.content else { return XCTFail("Expected a native document") }
            let prepared = try await pages.prepare(), state = ReaderState(recordsHistory: false)
            state.document = document; state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
            state.flow = "continuous"; state.spread = false; state.cover = false; state.automaticLayout = false
            state.fit = "width"; state.zoom = 1; state.fontSize = 17; state.lineHeight = 1.4
            state.font = "system"; state.theme = "dark"; state.margin = 32; state.pageMargins = nil
            state.userCSS = ""; state.useDocumentCSS = true; state.freePan = false; state.trimEmptyMargins = false
            state.uniformPageWidth = false; state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
            state.showContents = false; state.hoverPreview = false; state.disableLinks = false
            let host = NSHostingView(rootView: ReaderView(state: state))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 740, height: 560),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
            try await settle(host, state: state, pages: pages)
            let canvas = try XCTUnwrap(canvases(in: host).first { !$0.links.isEmpty && $0.readingReady })
            let link = try XCTUnwrap(canvas.links.first { $0.uri.hasSuffix("#art") })
            let point = CGPoint(x: link.bounds.midX, y: link.bounds.midY).applying(canvas.pageTransform)
            let windowPoint = canvas.convert(point, to: nil), content = try XCTUnwrap(window.contentView)
            let target = try XCTUnwrap(content.hitTest(content.convert(windowPoint, from: nil)))
            XCTAssertTrue(target === canvas)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: windowPoint, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                if kind == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
            try await settle(host, state: state, pages: pages, afterJump: true)
            let current = try XCTUnwrap(canvases(in: host).first { $0.readingReady && !$0.visibleRect.isEmpty })
            let images = try await pages.imageBounds(current.location)
            let first = try XCTUnwrap(images.first)
            let visible = current.visibleRect.applying(current.pageTransform.inverted())
            print("IMAGE-LINK hosted \(input.lastPathComponent) position=\(state.currentPosition) first=\(first) visible=\(visible)")
            XCTAssertGreaterThanOrEqual(first.minY - visible.minY, -1,
                "A link to the image-only paragraph must not put the first image above the viewport")
            XCTAssertLessThanOrEqual(first.minY - visible.minY, 3 * 17 + 1,
                "The linked image must start at the viewport's top inset")
            XCTAssertNil(state.error)
        }
    }

    private func settle(_ host: NSView, state: ReaderState, pages: Pages, afterJump: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(10)
        var steady = 0, lastRevision = -1
        repeat {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let revision = await pages.layoutRevision
            let ready = state.error == nil && state.pendingReflowPosition == nil &&
                (!afterJump || (state.currentPosition.y ?? 0) > 200) && canvases(in: host).contains {
                    $0.readingReady && !$0.visibleRect.isEmpty &&
                        RasterReader.pageIsRendered(in: $0, pages: pages, location: $0.location)
                }
            steady = ready && revision == lastRevision ? steady + 1 : 0
            lastRevision = revision
            if steady == 15 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "The generated image-link reader did not settle")
    }

    private func canvases(in view: NSView) -> [RasterCanvas.Canvas] {
        if let canvas = view as? RasterCanvas.Canvas { return [canvas] }
        return view.subviews.flatMap { canvases(in: $0) }
    }

    private struct Checkpoint: Equatable {
        let url: URL
        let size: Int
        let modified: Date
        let digest: String
    }

    private func checkpoint(_ url: URL) throws -> Checkpoint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Checkpoint(url: url, size: try XCTUnwrap(values.fileSize), modified: try XCTUnwrap(values.contentModificationDate),
            digest: SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined())
    }

    private func unchanged(_ originals: [Checkpoint]) {
        for before in originals { XCTAssertEqual(try? checkpoint(before.url), before, before.url.lastPathComponent) }
    }

    private func fixtures() throws -> (TemporaryDirectory, [Checkpoint], [URL]) {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE42_GUI_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("Set SUMRA_ISSUE42_GUI_FIXTURES to the generated GUI fixture directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true), directory = try TemporaryDirectory()
        let mobi = root.appendingPathComponent("image-boundaries.mobi"), fb2 = root.appendingPathComponent("image-boundaries.fb2")
        let originals = try [mobi, fb2, root.appendingPathComponent("edge-markers.png")].map(checkpoint)
        XCTAssertEqual(originals.map(\.digest), [
            "03a22e938c96cca808c49d16a3c98a0c5e1c1183f4af9703e649112762e6ccc1",
            "f25ab8c3088d51eb89a26cd69450b8c66549d72334e9acdfc4011ac207450c10",
            "ddb1ab31a85fc7ccefe1014f2b935ab4037a6f63eb0c038b98a8adc2a10c47a0"
        ])
        let content = try XCTUnwrap(LegacyText.mobiContent(Data(contentsOf: mobi)))
        let html = String(decoding: content.html, as: UTF8.self)
        try html.write(to: directory.url.appendingPathComponent("body.xhtml"), atomically: true, encoding: .utf8)
        for (name, data) in content.resources { try data.write(to: directory.url.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let manifest = content.resources.keys.sorted().enumerated().map {
            "<item id='image-\($0.offset)' href='\($0.element)' media-type='image/png'/>"
        }.joined()
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='book.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "book.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest><item id='body' href='body.xhtml' media-type='application/xhtml+xml'/>\(manifest)</manifest><spine><itemref idref='body'/></spine></package>"
        ]
        for (name, text) in files { try text.write(to: directory.url.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let archive = Process(); archive.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); archive.currentDirectoryURL = directory.url
        archive.arguments = ["-q", "-0", "image-boundaries.epub", "mimetype", "META-INF/container.xml", "book.opf", "body.xhtml"] + content.resources.keys.sorted()
        try runSumraProcess(archive)
        XCTAssertEqual(archive.terminationStatus, 0)
        return (directory, originals, [mobi, fb2, directory.url.appendingPathComponent("image-boundaries.epub")])
    }
}
#endif
