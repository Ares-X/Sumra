#if os(macOS)
import AppKit
import CryptoKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

/// Opt in with SUMRA_ISSUE42_FIXTURES pointing at the original formatsampler
/// directory. Inputs are read in place; converted resources stay in Sumra's
/// ordinary temporary document directory.
@MainActor
final class Issue42OriginalSampleTests: XCTestCase {
    func testOriginalAZW3AllSixteenLinksResolveToChapterBodyAndCSSStaysOutOfText() async throws {
        let originals = try fixtureCheckpoints()
        defer { assertUnchanged(originals) }
        let source = try XCTUnwrap(originals.first { $0.url.pathExtension == "azw3" }?.url)
        let content = try XCTUnwrap(LegacyText.mobiContent(Data(contentsOf: source)))
        let authored = try ([content.html] + content.additionalParts).flatMap { try chapterLinks($0) }
        XCTAssertEqual(authored.map(\.chapter), Array(1...8) + Array(1...8))
        XCTAssertEqual(authored.prefix(8).map(\.href), authored.suffix(8).map(\.href))
        XCTAssertEqual(Set(authored.map(\.href)).count, 8)

        let document = try ReadingDocument.open(source)
        defer { withExtendedLifetime(document) {} }
        guard case .pages(let pages) = document.content else { return XCTFail("AZW3 must use the native reader") }
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.4, margin: 32, font: "system", theme: "light",
            pageSize: CGSize(width: 420, height: 595))
        let count = await pages.count
        var links = [RasterLink]()
        var pageTexts = [String]()
        for page in 0..<count {
            links += try await pages.links(page)
            pageTexts.append(try await pages.text(page))
        }
        XCTAssertEqual(links.count, 16, "Both authored eight-entry TOCs must remain clickable")
        XCTAssertEqual(links.map { $0.uri.hasPrefix("/") ? String($0.uri.dropFirst()) : $0.uri }.sorted(), authored.map(\.href).sorted())
        var resolved = [ReadingPosition]()
        for expected in authored {
            let position = try await pages.resolve(expected.href)
            let destination = try XCTUnwrap(position, "Unresolved \(expected.href)")
            let text = try await pages.text(destination.page)
            XCTAssertTrue(text.contains("Chapter \(expected.chapter)"), text)
            XCTAssertTrue(text.contains("Lorem ipsum"), "The destination must contain chapter body text, not just a TOC title")
            resolved.append(destination)
        }
        XCTAssertEqual(resolved.prefix(8).map(\.page), resolved.suffix(8).map(\.page))
        XCTAssertEqual(resolved.prefix(8).map(\.y), resolved.suffix(8).map(\.y))
        for (before, after) in zip(resolved.prefix(7), resolved.dropFirst().prefix(7)) {
            XCTAssertTrue(before.page < after.page || before.page == after.page && (before.y ?? 0) < (after.y ?? 0),
                "Chapter destinations must progress through the book")
        }
        let liveTOCs = pageTexts.filter { $0.contains("Chapter 1") && !$0.contains("Lorem ipsum") }
        XCTAssertEqual(liveTOCs.count, 2)
        let numberedTOC = try XCTUnwrap(liveTOCs.first)
        XCTAssertNotNil(numberedTOC.range(of: #"1\.\s*Chapter\s+1"#, options: .regularExpression), numberedTOC)
        XCTAssertNotNil(numberedTOC.range(of: #"8\.\s*Chapter\s+8"#, options: .regularExpression), numberedTOC)
        XCTAssertNil(liveTOCs.last?.range(of: #"1\.\s*Chapter\s+1"#, options: .regularExpression), "The inline TOC's list-style:none must remain local to its spine part")
        let bookText = pageTexts.joined(separator: "\n")
        for chapter in 1...8 {
            let title = try NSRegularExpression(pattern: "\\bChapter\\s*\(chapter)\\b")
            XCTAssertEqual(title.numberOfMatches(in: bookText, range: NSRange(bookText.startIndex..<bookText.endIndex, in: bookText)), 3,
                "Chapter \(chapter) should appear in two live TOCs and its body heading, without a leaked document title")
        }
        XCTAssertTrue(bookText.contains("Chapter 8"))
        XCTAssertTrue(bookText.contains("Lorem ipsum"))
        let lastPage = try XCTUnwrap(pageTexts.last)
        XCTAssertTrue(lastPage.contains("Chapter 8") || lastPage.contains("Lorem ipsum"),
            "The final page must contain the authored TOC or chapter body: \(lastPage)")
        for (page, text) in pageTexts.enumerated() {
            for css in [".calibre", "display:", "@page", "list-style-type", "margin-bottom:", "a:hover"] {
                XCTAssertFalse(text.contains(css), "A CSS flow leaked into text page \(page + 1): \(css)")
            }
        }
    }

    func testOriginalAZW3LinkedPassageSurvivesHostedModesAndResize() async throws {
        let originals = try fixtureCheckpoints()
        defer { assertUnchanged(originals) }
        let source = try XCTUnwrap(originals.first { $0.url.pathExtension == "azw3" }?.url)
        let content = try XCTUnwrap(LegacyText.mobiContent(Data(contentsOf: source)))
        let authored = try ([content.html] + content.additionalParts).flatMap { try chapterLinks($0) }
        let target = try XCTUnwrap(authored.first { $0.chapter == 8 }?.href)
        let document = try ReadingDocument.open(source, deferReflowLayout: true)
        guard case .pages(let pages) = document.content else { return XCTFail("AZW3 must use the native reader") }
        let prepared = try await pages.prepare()
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let preferences = ["flow", "spread"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in preferences { defaults.set(value, forKey: key) } }
        let state = ReaderState(recordsHistory: false)
        state.document = document; state.reflowable = prepared.reflowable; state.searchable = prepared.searchable
        state.flow = "paged"; state.spread = false; state.cover = false; state.automaticLayout = false
        state.fit = "page"; state.zoom = 1; state.fontSize = 17; state.lineHeight = 1.4
        state.font = "system"; state.theme = "light"; state.margin = 32; state.pageMargins = nil
        state.userCSS = ""; state.useDocumentCSS = true; state.freePan = false; state.trimEmptyMargins = false
        state.uniformPageWidth = false; state.landscapeAsSpread = false; state.scrollbarMode = "hidden"
        state.showContents = false; state.hoverPreview = false; state.disableLinks = false
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        try await settle(host, state: state, pages: pages)
        state.navigate(.href(target))
        try await settle(host, state: state, pages: pages, chapter: "Chapter 8")
        let passage = try XCTUnwrap(state.currentPosition.nativePassage?.source)
        XCTAssertNil(state.linkDestinationHint)

        let stages: [(ReaderMenuCommand, CGSize)] = [
            (.twoPages, CGSize(width: 920, height: 560)),
            (.continuous, CGSize(width: 520, height: 620)),
            (.paged, CGSize(width: 640, height: 480))
        ]
        for (command, size) in stages {
            let modeRevision = await pages.layoutRevision
            command.run(state)
            try await settle(host, state: state, pages: pages, chapter: "Chapter 8", after: modeRevision)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, passage,
                "The linked source passage must survive \(state.flow), spread \(state.spread)")
            let resizeRevision = await pages.layoutRevision
            window.setContentSize(size)
            try await settle(host, state: state, pages: pages, chapter: "Chapter 8", after: resizeRevision)
            XCTAssertEqual(state.currentPosition.nativePassage?.source, passage,
                "The linked source passage must survive \(state.flow), spread \(state.spread), resize \(size)")
            XCTAssertNil(state.linkDestinationHint)
            for expected in authored {
                let position = try await pages.resolve(expected.href)
                let destination = try XCTUnwrap(position, "Unresolved \(expected.href) in \(state.flow)")
                let text = try await pages.text(destination.page)
                XCTAssertTrue(text.contains("Chapter \(expected.chapter)") && text.contains("Lorem ipsum"), text)
            }
        }
        XCTAssertNil(state.error)
    }

    private func settle(_ host: NSView, state: ReaderState, pages: Pages,
                        chapter: String? = nil, after revision: Int? = nil) async throws {
        let deadline = Date().addingTimeInterval(15)
        var steady = 0, lastRevision = -1
        repeat {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let current = await pages.layoutRevision
            let rendered = canvases(in: host).filter {
                state.visiblePages.contains($0.page) && !$0.visibleRect.isEmpty &&
                    RasterReader.pageIsRendered(in: $0, pages: pages, location: $0.location)
            }
            var ready = state.error == nil && state.pendingReflowPosition == nil && !rendered.isEmpty &&
                (revision.map { current > $0 } ?? true)
            if let chapter, ready {
                var visibleText = ""
                for canvas in rendered {
                    let visible = canvas.visibleRect.applying(canvas.pageTransform.inverted()).intersection(canvas.pageBounds)
                    let selections = try await pages.selection(areas: [canvas.location: visible])
                    visibleText += selections[canvas.location]?.text ?? ""
                }
                ready = visibleText.contains(chapter) && visibleText.contains("Lorem ipsum")
            }
            steady = ready && current == lastRevision ? steady + 1 : 0
            lastRevision = current
            if steady == 10 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline && state.error == nil
        XCTFail(state.error ?? "Original AZW3 did not paint the expected linked passage in \(state.flow), spread \(state.spread)")
    }

    private func canvases(in view: NSView) -> [RasterCanvas.Canvas] {
        if let canvas = view as? RasterCanvas.Canvas { return [canvas] }
        return view.subviews.flatMap { canvases(in: $0) }
    }

    private func chapterLinks(_ html: Data) throws -> [(href: String, chapter: Int)] {
        let string = String(decoding: html, as: UTF8.self) as NSString
        let links = try NSRegularExpression(pattern: #"<a\b[^>]*\bhref="([^"]+)"[^>]*>Chapter ([1-8])</a>"#)
        return links.matches(in: string as String, range: NSRange(location: 0, length: string.length)).map {
            (string.substring(with: $0.range(at: 1)), Int(string.substring(with: $0.range(at: 2)))!)
        }
    }

    private struct Checkpoint: Equatable {
        let url: URL
        let size: Int
        let modified: Date
        let sha256: String
    }

    private func checkpoint(_ url: URL) throws -> Checkpoint {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        return Checkpoint(url: url, size: try XCTUnwrap(values.fileSize),
            modified: try XCTUnwrap(values.contentModificationDate), sha256: digest)
    }

    private func fixtureCheckpoints() throws -> [Checkpoint] {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_ISSUE42_FIXTURES"], !path.isEmpty else {
            throw XCTSkip("Set SUMRA_ISSUE42_FIXTURES to the original formatsampler directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let expected: [(String, Int, String)] = [
            ("sample_comic.cbr", 7_234_403, "9de19d3c796b4d84748bd8c08c7180959820b8c1f63701980358dc673338ba51"),
            ("sample_comic.cbz", 7_254_180, "c71bcc7bbc4bcc8778c2a3c443ecb8d2d130e145c56e3301ed38a2fe98faaa9a"),
            ("sample_illustrated.azw3", 68_714, "d4f2dd94f7b4208849b75ef564eec16481554ee501fcbf50ab29486773f46825"),
            ("sample_illustrated.epub", 6_229, "672d0f8c8c95557b86086ea92e0211428ae2db2519e49054e3aa34e92ea9d6f1"),
            ("sample_illustrated.fb2", 6_054, "408877f31fc9ad017ae061d94db3e8d3b810a148e40f53afa3b8cc28cc5fbac6"),
            ("sample_illustrated.mobi", 64_566, "287543513806133a5772e3fa2d01d5448d9d14ad85d7ffa8bc5176724e4694ad")
        ]
        return try expected.map { name, size, digest in
            let result = try checkpoint(directory.appendingPathComponent(name))
            XCTAssertEqual(result.size, size, name)
            XCTAssertEqual(result.sha256, digest, "Use the original issue #42 sample bytes: \(name)")
            return result
        }
    }

    private func assertUnchanged(_ originals: [Checkpoint], file: StaticString = #filePath, line: UInt = #line) {
        for before in originals {
            XCTAssertEqual(try? checkpoint(before.url), before, "Source bytes, size or mtime changed: \(before.url.lastPathComponent)", file: file, line: line)
        }
    }
}
#endif
