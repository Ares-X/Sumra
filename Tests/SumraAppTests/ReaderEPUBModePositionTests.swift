#if os(macOS)
import AppKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class ReaderEPUBModePositionTests: XCTestCase {
    func testFindNearChapterEndStaysAtTheSameBodyPassageAcrossReadingModes() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), token = "TAIL_SOURCE_0185"
        let input = try epub(in: directory.url, token: token)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = false; state.searchable = false; state.automaticLayout = false
        state.flow = "continuous"; state.spread = false; state.fit = "page"; state.zoom = 1
        state.fontSize = 17; state.lineHeight = 1.4; state.font = "serif"; state.theme = "light"
        state.margin = 32; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "smart"
        let defaults = UserDefaults.standard
        let oldPreferences = ["flow", "spread", "findFloating"].map { ($0, defaults.object(forKey: $0)) }
        defaults.set(false, forKey: "findFloating")
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 926, height: 770),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            for (key, value) in oldPreferences { defaults.set(value, forKey: key) }
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func visibleText(_ view: NSView) -> String {
            let local = (view.accessibilityChildren() ?? []).compactMap { $0 as? NativeReadingAccessibilityPage }
                .compactMap { $0.accessibilityValue() }.joined(separator: "\n")
            return ([local] + view.subviews.map(visibleText)).joined(separator: "\n")
        }
        func paintedReadingText(target: PageLocation, continuousReflow: Bool) -> String? {
            guard let scroll = state.readerScrollView, let document = scroll.documentView,
                  document.window != nil,
                  String(reflecting: type(of: scroll)).contains("RasterViewport") == continuousReflow else { return nil }
            var targetReady = false
            var text = [String]()
            let visible = Set(state.visiblePages.map(state.pageLocation))
            func visit(_ view: NSView) {
                for child in view.accessibilityChildren() ?? [] {
                    guard let page = child as? NativeReadingAccessibilityPage, page.view === view,
                          view.window != nil, !view.visibleRect.isEmpty, !view.isHiddenOrHasHiddenAncestor else { continue }
                    if RasterReader.pageIsRendered(in: view, pages: pages, location: target) { targetReady = true }
                    if visible.contains(where: { RasterReader.pageIsRendered(in: view, pages: pages, location: $0) }),
                       let value = page.accessibilityValue() { text.append(value) }
                }
                for child in view.subviews { visit(child) }
            }
            visit(document)
            return targetReady ? text.joined(separator: "\n") : nil
        }
        func viewportPositionIsRecorded(at location: PageLocation) -> Bool {
            guard let visible = RasterReader.visiblePageBounds(in: state.readerFocusView, pages: pages, location: location),
                  let y = state.currentPosition.y else { return false }
            return abs(y - Double(visible.minY)) < 1
        }
        var transition = "initial continuous layout"
        func waitFor(line: UInt = #line, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if try await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            let nativePosition = await pages.layoutPosition, nativeTable = await pages.chapterLayout
            let nativeRevision = await pages.layoutRevision
            XCTFail("\(state.error ?? "The EPUB reader did not settle"); transition=\(transition), mode=\(state.flow), spread=\(state.spread), pending reflow=\(String(describing: state.pendingReflowPosition)), UI=\(state.currentPosition), native=\(nativePosition), UI table=\(String(describing: state.chapterLayout)), native table=\(nativeTable), native revision=\(nativeRevision), command=\(state.command), visible text=\(visibleText(host).prefix(800))", line: line)
            throw CancellationError()
        }
        func chapter(_ position: ReadingPosition) -> Int? {
            position.anchor.flatMap(ChapterTable.bookmarkLocation)?.location.chapter
        }
        try await waitFor {
            guard state.reflowable, state.searchable, state.count > 0, state.chapterLayout != nil,
                  let scroll = state.readerScrollView else { return false }
            let viewport = scroll.contentView.safeAreaRect.size
            guard viewport.width > 0, viewport.height > 0 else { return false }
            let bounds = try await pages.bounds(PageLocation(chapter: 0, page: 0))
            let table = await pages.chapterLayout
            return table.pageCount(0) == 1 && bounds.width == viewport.width && bounds.height > viewport.height * 10 &&
                RasterReader.pageIsRendered(in: state.readerFocusView, pages: pages, location: .init(chapter: 0, page: 0))
        }
        state.showFind = true
        state.findQuery = token
        state.findNext()
        try await waitFor { !state.searchCounting && visibleText(host).contains(token) }
        XCTAssertEqual(chapter(state.currentPosition), 0)
        let bodyBounds = try await pages.bounds(PageLocation(chapter: 0, page: 0))
        XCTAssertGreaterThan(try XCTUnwrap(state.currentPosition.y), Double(bodyBounds.height) * 0.8,
                             "Find must move the actual viewport near the end of the first chapter")
        XCTAssertGreaterThan(Double(bodyBounds.height) - (try XCTUnwrap(state.currentPosition.y)), Double(host.bounds.height),
                             "The fixture must leave a full viewport after the found passage so the chapter end does not clamp its position")
        state.closeFind()
        try await waitFor {
            !state.showFind && visibleText(host).contains(token)
        }

        let foundSource = try XCTUnwrap(state.currentPosition.nativePassage).source
        var singlePageNumber: Int?
        for mode in [ReaderMenuCommand.paged, .twoPages, .continuous, .paged, .twoPages, .continuous] {
            var oldPosition = ReadingPosition()
            var viewportWord = ""
            var revision = 0
            try await waitFor {
                guard state.pendingReflowPosition == nil,
                      let location = state.currentPosition.anchor.flatMap(ChapterTable.bookmarkLocation)?.location,
                      viewportPositionIsRecorded(at: location) else { return false }
                let currentRevision = await pages.layoutRevision
                RasterReader.recordPosition(in: state.readerScrollView?.documentView)
                let current = state.currentPosition
                guard current.anchor.flatMap(ChapterTable.bookmarkLocation)?.location == location,
                      viewportPositionIsRecorded(at: location),
                      paintedReadingText(target: location, continuousReflow: state.flow == "continuous")?.contains(token) == true else { return false }
                // Use the same immediate viewport capture as a menu click, then
                // issue the command before another layout callback can move it.
                state.captureReflowPosition()
                oldPosition = try XCTUnwrap(state.pendingReflowPosition)
                XCTAssertEqual(oldPosition, current)
                viewportWord = token
                revision = currentRevision
                transition = "to \(mode), old viewport=\(oldPosition), original word=\(viewportWord)"
                mode.run(state)
                return true
            }
            let oldLocation = try XCTUnwrap(oldPosition.anchor.flatMap(ChapterTable.bookmarkLocation)?.location)
            XCTAssertEqual(oldLocation.chapter, 0)
            try await waitFor {
                let table = await pages.chapterLayout, newRevision = await pages.layoutRevision
                let expectedMode = mode == .continuous ? state.flow == "continuous" && !state.spread
                    : state.flow == "paged" && state.spread == (mode == .twoPages)
                let expectedCount = mode == .continuous ? table.pageCount(0) == 1 : table.pageCount(0) > 10
                return expectedMode && expectedCount && newRevision > revision
            }
            // Users can switch again once the restored source is painted,
            // while background search and chapter publication still run.
            var paintedText = ""
            try await waitFor {
                let table = await pages.chapterLayout, position = await pages.layoutPosition
                let location = position.anchor.flatMap(ChapterTable.bookmarkLocation)?.location
                guard state.chapterLayout == table, state.page == position.page, let location,
                      viewportPositionIsRecorded(at: location),
                      let text = paintedReadingText(target: location, continuousReflow: mode == .continuous),
                      text.contains(viewportWord) else { return false }
                paintedText = text
                return true
            }
            let nativePosition = await pages.layoutPosition
            XCTAssertEqual(nativePosition.nativePassage?.source, foundSource, "Page-edge clamping must retain the authoritative source through the next mode change")
            XCTAssertEqual(chapter(nativePosition), 0, "The decoder must retain the body chapter rather than a later TOC or QR chapter")
            XCTAssertEqual(chapter(state.currentPosition), 0, "The UI projection must retain the stable chapter identity")
            XCTAssertTrue(paintedText.contains(viewportWord), "The original viewport's unique source word must remain in the painted viewport")
            XCTAssertFalse(paintedText.contains("LATER_TOC"))
            XCTAssertFalse(paintedText.contains("LATER_QR"))
            if mode == .paged && singlePageNumber == nil {
                singlePageNumber = state.page
                XCTAssertGreaterThan(state.page, 10, "The next transition must start from a high paginated page number")
            }
            if mode == .continuous {
                XCTAssertEqual(state.page, 0, "Natural layout changes the flat page projection while keeping the original passage")
                // A second reflow can keep the chapter count unchanged while
                // invalidating its measured height, as native scrollers do.
                let resizedRevision = await pages.layoutRevision
                let width: CGFloat = host.bounds.width > 920 ? 912 : 926
                window.setContentSize(CGSize(width: width, height: 770))
                transition = "continuous width change after \(transition)"
                try await waitFor {
                    let revision = await pages.layoutRevision
                    let bounds = try await pages.bounds(PageLocation(chapter: 0, page: 0))
                    let actualWidth = state.readerScrollView?.contentView.safeAreaRect.width
                    let text = paintedReadingText(target: .init(chapter: 0, page: 0), continuousReflow: true)
                    return revision > resizedRevision && bounds.width == actualWidth &&
                        text?.contains(viewportWord) == true
                }
                XCTAssertEqual(chapter(state.currentPosition), 0)
                XCTAssertFalse(visibleText(host).contains("LATER_QR"))
            }
            XCTAssertNil(state.error)
        }
        let finalRevision = state.command.revision
        state.send(.none)
        transition = "final command drain after two complete reading-mode cycles"
        try await waitFor {
            state.command.revision > finalRevision && state.command.action == .none && !state.searchCounting
        }
        XCTAssertEqual(chapter(state.currentPosition), 0)
        let finalPosition = await pages.layoutPosition
        XCTAssertEqual(chapter(finalPosition), 0)
    }

    func testImagePassagesStayOnTheirIllustrationAcrossReadingModesAndPageEdges() async throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("MuPDF engine is required") }
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let input = try EPUBImagePositionFixture.make(in: directory.url)
        let pages = try Pages(input, format: .mupdf, deferReflowLayout: true)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages))
        state.reflowable = false; state.searchable = false; state.automaticLayout = false
        state.flow = "paged"; state.spread = false; state.fit = "page"; state.zoom = 1
        state.fontSize = 17; state.lineHeight = 1.2; state.font = "system"; state.theme = "light"
        state.margin = 0; state.pageMargins = nil; state.userCSS = ""; state.useDocumentCSS = true
        state.freePan = false; state.trimEmptyMargins = false; state.uniformPageWidth = false
        state.landscapeAsSpread = false; state.scrollbarMode = "smart"
        let defaults = UserDefaults.standard
        let oldPreferences = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 926, height: 770),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            for (key, value) in oldPreferences { defaults.set(value, forKey: key) }
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        var paintDiagnostic = "No illustration bitmap inspected"
        func paintedIllustration(_ image: Int, location: PageLocation, nativeBounds: CGRect) -> Bool {
            var diagnostics = [String]()
            func visit(_ view: NSView) -> Bool {
                let rendered = RasterReader.pageIsRendered(in: view, pages: pages, location: location)
                let name = String(reflecting: type(of: view))
                if name.contains("Canvas") {
                    diagnostics.append("\(name): targetReady=\(rendered), window=\(view.window != nil), hidden=\(view.isHiddenOrHasHiddenAncestor), bounds=\(view.bounds), visible=\(view.visibleRect), pageVisible=\(String(describing: RasterReader.visiblePageBounds(in: view, pages: pages, location: location)))")
                }
                if view.window != nil, !view.visibleRect.isEmpty, !view.isHiddenOrHasHiddenAncestor, rendered,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) {
                    view.cacheDisplay(in: view.visibleRect, to: bitmap)
                    var identities = [Int](repeating: 0, count: 4)
                    var coloredSamples = [String]()
                    var paintedBounds = CGRect.null
                    let step = 4
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                            if let identity = illustrationIdentity(red: r, green: g, blue: b) {
                                identities[identity] += 1
                                if identity == image { paintedBounds = paintedBounds.union(CGRect(x: x, y: y, width: step, height: step)) }
                            }
                            if coloredSamples.count < 4, max(r, g, b) - min(r, g, b) > 0.2 {
                                coloredSamples.append(String(format: "%.3f/%.3f/%.3f", Double(r), Double(g), Double(b)))
                            }
                        }
                    }
                    if let canvas = view as? RasterCanvas.Canvas {
                        let visible = view.visibleRect
                        let artwork = nativeBounds.applying(canvas.pageTransform)
                        if state.flow == "paged", state.fit == "page", !visible.insetBy(dx: -1, dy: -1).contains(artwork) {
                            diagnostics.append("fit-page illustration clipped: artwork=\(artwork), visible=\(visible)")
                            return false
                        }
                        let expected = artwork.intersection(visible)
                        let pixels = CGRect(x: (expected.minX - visible.minX) * CGFloat(bitmap.pixelsWide) / visible.width,
                                            y: (expected.minY - visible.minY) * CGFloat(bitmap.pixelsHigh) / visible.height,
                                            width: expected.width * CGFloat(bitmap.pixelsWide) / visible.width,
                                            height: expected.height * CGFloat(bitmap.pixelsHigh) / visible.height)
                        // Sampled edges allow two sample intervals for antialiasing.
                        // Count/identity alone previously let a tiny painted stamp pass.
                        let tolerance = CGFloat(step * 2)
                        if !paintedBounds.isNull, !pixels.isEmpty,
                           abs(paintedBounds.minX - pixels.minX) <= tolerance,
                           abs(paintedBounds.minY - pixels.minY) <= tolerance,
                           abs(paintedBounds.width - pixels.width) <= tolerance,
                           abs(paintedBounds.height - pixels.height) <= tolerance { return true }
                        diagnostics.append("painted=\(paintedBounds), expected=\(pixels)")
                    }
                    diagnostics.append("bitmap=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), identities=\(identities), coloredSamples=\(coloredSamples)")
                }
                return view.subviews.contains(where: visit)
            }
            guard let document = state.readerScrollView?.documentView else {
                paintDiagnostic = "No reader scroll document; focus=\(String(describing: state.readerFocusView))"
                return false
            }
            let painted = visit(document)
            paintDiagnostic = "target=\(image) location=\(location), document=\(type(of: document)), scrollBounds=\(String(describing: state.readerScrollView?.contentView.bounds)); " + diagnostics.joined(separator: "; ")
            return painted
        }
        var transition = "initial image layout"
        func waitFor(line: UInt = #line, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            repeat {
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                if try await condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            let native = await pages.layoutPosition
            XCTFail("\(state.error ?? "The image reader did not settle"); transition=\(transition), UI=\(state.currentPosition), native=\(native), pending=\(String(describing: state.pendingReflowPosition)); paint=\(paintDiagnostic)", line: line)
            throw CancellationError()
        }
        try await waitFor {
            let table = await pages.chapterLayout
            return state.reflowable && state.chapterLayout == table && table.pageCount(1) == 4 && state.pendingReflowPosition == nil
        }
        var sources = Set<NativeSourceAnchor>()
        for image in [0, 2, 3] {
            transition = "Go to illustration \(image + 1)"
            state.go("2:\(image + 1)")
            let single = PageLocation(chapter: 1, page: image)
            try await waitFor {
                let bounds = try await pages.imageBounds(single)
                return state.pendingReflowPosition == nil && state.currentPosition.anchor.flatMap(ChapterTable.bookmarkLocation)?.location == single &&
                    state.currentPosition.nativePassage != nil && bounds.count == 1 && paintedIllustration(image, location: single, nativeBounds: bounds[0])
            }
            let source = try XCTUnwrap(state.currentPosition.nativePassage).source
            sources.insert(source)
            for mode in [ReaderMenuCommand.continuous, .paged, .twoPages, .continuous, .paged] {
                RasterReader.recordPosition(in: state.readerScrollView?.documentView)
                state.captureReflowPosition()
                let revision = await pages.layoutRevision
                transition = "illustration \(image + 1) to \(mode)"
                mode.run(state)
                let expected = PageLocation(chapter: 1, page: mode == .continuous ? 0 : image)
                try await waitFor {
                    let newRevision = await pages.layoutRevision, table = await pages.chapterLayout
                    let position = await pages.layoutPosition
                    let expectedMode = mode == .continuous ? state.flow == "continuous" && !state.spread
                        : state.flow == "paged" && state.spread == (mode == .twoPages)
                    let bounds = try await pages.imageBounds(expected)
                    let art = mode == .continuous ? image : 0
                    return expectedMode && newRevision > revision && state.pendingReflowPosition == nil &&
                        state.chapterLayout == table && table.pageCount(1) == (mode == .continuous ? 1 : 4) &&
                        position.anchor.flatMap(ChapterTable.bookmarkLocation)?.location == expected &&
                        state.currentPosition.anchor.flatMap(ChapterTable.bookmarkLocation)?.location == expected &&
                        position.nativePassage?.source == source && state.currentPosition.nativePassage?.source == source &&
                        bounds.indices.contains(art) && paintedIllustration(image, location: expected, nativeBounds: bounds[art])
                }
                XCTAssertNil(state.error)
            }
            for size in [CGSize(width: 926, height: 620), CGSize(width: 640, height: 620),
                         CGSize(width: 640, height: 900), CGSize(width: 926, height: 770)] {
                RasterReader.recordPosition(in: state.readerScrollView?.documentView)
                state.captureReflowPosition()
                let revision = await pages.layoutRevision
                transition = "illustration \(image + 1) resized to \(size)"
                window.setContentSize(size)
                try await waitFor {
                    let newRevision = await pages.layoutRevision, table = await pages.chapterLayout
                    let position = await pages.layoutPosition, bounds = try await pages.imageBounds(single)
                    return newRevision > revision && state.pendingReflowPosition == nil && state.chapterLayout == table &&
                        table.pageCount(1) == 4 && position.nativePassage?.source == source &&
                        state.currentPosition.nativePassage?.source == source &&
                        state.currentPosition.anchor.flatMap(ChapterTable.bookmarkLocation)?.location == single &&
                        bounds.count == 1 && paintedIllustration(image, location: single, nativeBounds: bounds[0])
                }
                XCTAssertNil(state.error)
            }
        }
        XCTAssertEqual(sources.count, 3, "The first, third and last illustration must retain their own source across the complete mode cycle")
    }

    private func illustrationIdentity(red: CGFloat, green: CGFloat, blue: CGFloat) -> Int? {
        // Identify the fixture, not its color accuracy. AppKit's observed red
        // retained a minimum channel gap of 0.651 after profile conversion.
        // A 0.4 gap separates these four saturated colors from neutral pixels.
        if red - max(green, blue) > 0.4 { return 0 }
        if green - max(red, blue) > 0.4 { return 1 }
        if blue - max(red, green) > 0.4 { return 2 }
        if min(red, blue) - green > 0.4 { return 3 }
        return nil
    }

    private func epub(in directory: URL, token: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        var files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container'><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package xmlns='http://www.idpf.org/2007/opf' version='3.0'><metadata/><manifest><item id='body' href='body.xhtml' media-type='application/xhtml+xml'/><item id='toc' href='toc.xhtml' media-type='application/xhtml+xml'/><item id='qr' href='qr.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='body'/><itemref idref='toc'/><itemref idref='qr'/></spine></package>"
        ]
        let body = (0..<200).map { index in
            let marker = index == 185 ? token : String(format: "BODY_SOURCE_%04d", index)
            let prose = "Original body text keeps the same source passage while page width and natural chapter height change. Every paragraph remains ordinary readable prose."
            let words = prose.split(separator: " ").enumerated().map { offset, word in "\(word)_\(index)_\(offset)" }.joined(separator: " ")
            return "<p>\(marker): \(words)</p>"
        }.joined()
        files["body.xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><body>\(body)</body></html>"
        files["toc.xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>LATER_TOC: This separate chapter must not replace the original body passage.</p></body></html>"
        files["qr.xhtml"] = "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>LATER_QR: This final chapter is not the passage being read.</p></body></html>"
        for (name, content) in files { try content.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "book.epub", "mimetype"] + files.keys.filter { $0 != "mimetype" }.sorted()
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create the EPUB reading-mode fixture") }
        return directory.appendingPathComponent("book.epub")
    }
}
#endif
