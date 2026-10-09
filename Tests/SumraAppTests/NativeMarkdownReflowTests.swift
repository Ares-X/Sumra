#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class NativeMarkdownReflowTests: XCTestCase {
    func testMarkdownPDFSubsetsSelectedGlyphsWithoutChangingTextOrPaint() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Subset.md")
        let output = temporary.url.appendingPathComponent("Selected.pdf")
        let body = "# 阅读指南\n\n"
            + String(repeating: "普通汉字 一二三田 ⼀⼆⼃⽥ office affine fi fl ﬁ ﬂ\n\n", count: 160)
            + "文末 UNIQUE END77"
        let bytes = Data(body.utf8)
        try bytes.write(to: input)
        let source = try NativeFile(input, engine: .mupdf)
        XCTAssertGreaterThan(source.count, 1)
        let selected = [0, source.count - 1]
        XCTAssertTrue(try source.exportPDF(to: output, selectedPages: selected))
        let exported = try NativeFile(output, engine: .mupdf)
        let system = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(exported.count, selected.count)
        XCTAssertEqual(system.pageCount, selected.count)
        // Embedding the entire installed CJK font made even tiny outputs
        // roughly 20 MB. This budget permits ordinary selected-page metadata.
        XCTAssertLessThan(try Data(contentsOf: output).count, 2 * 1_048_576)
        func characters(_ text: String) -> String {
            let expanded = text.replacingOccurrences(of: "ﬁ", with: "fi").replacingOccurrences(of: "ﬂ", with: "fl")
            return String(String.UnicodeScalarView(expanded.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }))
        }
        for (index, page) in selected.enumerated() {
            let original = try XCTUnwrap(source.text(page))
            XCTAssertEqual(try exported.text(index), original)
            XCTAssertEqual(characters(try XCTUnwrap(system.page(at: index)?.string)), characters(original))
            let before = try source.image(page, width: 840, transparent: true)
            let after = try exported.image(index, width: 840, transparent: true)
            XCTAssertEqual(after.width, before.width)
            XCTAssertEqual(after.height, before.height)
            XCTAssertEqual(after.dataProvider?.data as Data?, before.dataProvider?.data as Data?)
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testDeferredMarkdownAppliesFirstReaderLayoutBeforePageAndOutlineUse() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let markdown = temporary.url.appendingPathComponent("FirstLayout.md")
        let body = "# First heading\n\n"
            + String(repeating: "Café text stays readable at large type.\n\n", count: 24)
            + "# Last heading\n\nTerminal marker END77"
        try body.write(to: markdown, atomically: true, encoding: .utf8)

        let eager = try NativeFile(markdown, engine: .mupdf)
        XCTAssertGreaterThan(eager.count, 0, "Existing direct opens still provide pages immediately")

        let pages = try Pages(markdown, format: .markdown, deferReflowLayout: true)
        let firstLayout = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0,
                                                  font: "system", theme: "light", textZoom: 6)
        let enlarged = try XCTUnwrap(firstLayout)
        XCTAssertGreaterThan(enlarged, eager.count, "The first reader layout must use its requested text size")
        let count = await pages.count
        XCTAssertEqual(count, enlarged)
        let outline = try await pages.prepare().outline
        XCTAssertTrue(outline.contains { $0.title == "First heading" })
        XCTAssertTrue(outline.contains { $0.title == "Last heading" })
        var ending = ""
        for page in max(0, count - 8)..<count { ending += try await pages.text(page) }
        XCTAssertTrue(ending.filter { !$0.isWhitespace }.hasSuffix("TerminalmarkerEND77"))

        let html = temporary.url.appendingPathComponent("Ordinary.html")
        try "<html><body><p>Other reflowable input</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let ordinary = try NativeFile(html, engine: .mupdf)
        XCTAssertGreaterThan(ordinary.count, 0, "Other reflowable documents retain eager opening")
        let ordinaryText = try ordinary.text(0)
        XCTAssertTrue(ordinaryText?.contains("Other reflowable input") == true)
    }

    @MainActor
    func testPageFittingAndPresetRestorationKeepMarkdownTextSize() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Fit.md")
        try "Text size remains independent of page fitting.".write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        let defaults = UserDefaults.standard
        let saved = ["fit", "flow"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }

        state.setZoom(6)
        state.setFit("width")
        XCTAssertEqual(state.zoom, 6, "Fitting a page must not change Markdown typography")
        state.setFit("page")
        XCTAssertEqual(state.zoom, 6)
        state.toggleFitPreset(continuous: true)
        XCTAssertEqual(state.flow, "continuous")
        XCTAssertEqual(state.zoom, 6)
        state.setZoom(1.5)
        state.toggleFitPreset(continuous: true)
        XCTAssertEqual(state.flow, "paged")
        XCTAssertEqual(state.fit, "page")
        XCTAssertEqual(state.zoom, 1.5, "Restoring a layout preset must retain the reader's current text size")
        state.setFit("custom")
        state.toggleFitPreset(continuous: false)
        state.setZoom(2)
        state.toggleFitPreset(continuous: false)
        XCTAssertEqual(state.fit, "custom")
        XCTAssertEqual(state.zoom, 2)
    }

    @MainActor
    func testActualSizeResetsMarkdownTextZoomAndEmitsReflowCommand() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("ActualSize.md")
        try "Actual size resets Markdown typography to its base size.".write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        let state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        let defaults = UserDefaults.standard
        let savedFit = defaults.object(forKey: "fit")
        defer { defaults.set(savedFit, forKey: "fit") }

        state.zoom = 6
        state.setActualSize()

        XCTAssertEqual(state.fit, "actual")
        XCTAssertEqual(state.zoom, 1, "Actual Size returns Markdown to its base typography")
        XCTAssertEqual(state.command.action, .zoom(1), "Markdown must receive a reflow command, not a page-fit command")

        state.setZoom(1.5)
        state.toggleFitPreset(continuous: true)
        XCTAssertEqual(state.flow, "continuous")
        XCTAssertEqual(state.zoom, 1.5)
        state.toggleFitPreset(continuous: true)
        XCTAssertEqual(state.fit, "actual")
        XCTAssertEqual(state.zoom, 1.5, "Restoring a preset must not reapply Actual Size's one-time text reset")
    }

    @MainActor
    func testScrollSnapshotKeepsSourcePassageWhenWindowClosesImmediately() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Scroll.md")
        try String(repeating: "A repeated paragraph with stable source identity.\n\n", count: 120).write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light")
        let state = ReaderState()
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.font = "system"; state.theme = "light"; state.zoom = 1
        state.reflowable = true; state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        let key = "position:" + input.standardizedFileURL.path, modeKey = key + ":markdown:paged"
        let defaults = UserDefaults.standard, disabled = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer { defaults.set(disabled, forKey: "disableReadingState"); defaults.removeObject(forKey: key); defaults.removeObject(forKey: modeKey) }
        state.updatePosition(.init(page: 1, x: 20, y: 80))
        XCTAssertNil(state.currentPosition.nativePassage, "The real scroll callback first supplies page geometry")
        state.windowClosed()
        var saved: ReadingPosition?
        for _ in 0..<100 {
            saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ReadingPosition.self, from: $0) }
            if saved?.nativePassage != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let passage = try XCTUnwrap(saved?.nativePassage)
        XCTAssertEqual(saved?.page, 1)
        let mode = try JSONDecoder().decode(ReadingPosition.self, from: XCTUnwrap(defaults.data(forKey: modeKey)))
        XCTAssertEqual(mode.nativePassage, passage)
        let reopened = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await reopened.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", textZoom: 1.5)
        var zoomed = mode; zoomed.zoom = 1.5
        let restored = try await reopened.restore(zoomed, theme: "light")
        XCTAssertEqual(restored.nativePassage?.source, passage.source, "Reopen at a different text size must restore the same source glyph")
        let restoredWords = try await reopened.words(restored.page)
        XCTAssertTrue(restoredWords.contains { $0.source == passage.source })
        _ = try await reopened.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light", textZoom: 1)
        let returned = await reopened.layoutPosition
        XCTAssertEqual(returned.nativePassage?.source, passage.source, "Repeated reflow must not drift from a margin point to another glyph")
    }

    func testFontZoomPreservesSourcePassageAndRepeatedTextSelection() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Repeated.md")
        let phrase = "Repeated passage 一二三 ⼀⼆⼃."
        let body = (0..<80).map { "# Section \($0)\n\n" + String(repeating: phrase + " More wrapping words. ", count: 10) }.joined(separator: "\n\n")
        try body.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let originalCount = await pages.count
        let targetPage = originalCount / 2
        let words = try await pages.words(targetPage)
        let text = words.map(\.text).joined() as NSString
        let range = text.range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound)
        let selected = try await pages.selection(targetPage, range: range)
        let start = try XCTUnwrap(selected.sourceStart), end = try XCTUnwrap(selected.sourceEnd)
        let first = try XCTUnwrap(selected.words?.first { $0.source != nil && !$0.bounds.isEmpty })
        let original = try await pages.position(page: targetPage, x: Double(first.bounds.minX+1), y: Double(first.bounds.minY+1))
        let passage = try XCTUnwrap(original.nativePassage)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", textZoom: 1.5)
        let zoomedCount = await pages.count
        XCTAssertGreaterThan(zoomedCount, originalCount, "Text zoom must reflow instead of enlarging a bitmap")
        let restored = await pages.layoutPosition
        XCTAssertEqual(restored.nativePassage?.source, passage.source, "The same source glyph must stay at the reading position")
        let restoredSelection = try await pages.selection(from: start, to: end)
        let values = restoredSelection.keys.sorted().compactMap { restoredSelection[$0] }
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.first?.sourceStart, start)
        XCTAssertEqual(values.last?.sourceEnd, end)
        XCTAssertEqual(values.map(\.text).joined(separator: "\n").filter { !$0.isWhitespace }, phrase.filter { !$0.isWhitespace })
        let restoredWords = values.flatMap { $0.words ?? [] }
        XCTAssertGreaterThan(try XCTUnwrap(restoredWords.first { $0.source == first.source }).bounds.height, first.bounds.height)
        let limit = try await pages.zoomLimit(rotation: 0, maximumZoom: 8)
        XCTAssertEqual(limit, 8, "The text zoom range must not inherit the continuous bitmap canvas limit")
    }

    func testFindLeftEdgePassageSurvivesWhitespaceWrappingAtExtremeZoom() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("FindBoundary.md")
        try (0..<400).map { "Boundary paragraph \(String(format: "%06d", $0)).\n\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let count = await pages.count, page = count / 2
        let words = try await pages.words(page)
        let digit = try XCTUnwrap(words.first { $0.text == "0" && $0.source != nil })
        // Find scrolls to the match's exact left edge. The preceding space
        // touches that same point and becomes an invisible line break at 600%.
        let original = try await pages.position(page: page, x: Double(digit.bounds.minX), y: Double(digit.bounds.minY))
        let passage = try XCTUnwrap(original.nativePassage)
        XCTAssertEqual(passage.source, digit.source)
        for zoom in [6.0, 1.0] {
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", textZoom: zoom)
            let restored = await pages.layoutPosition
            XCTAssertEqual(restored.nativePassage?.source, passage.source)
            let currentWords = try await pages.words(restored.page)
            XCTAssertTrue(currentWords.contains { $0.source == passage.source && $0.text == "0" })
        }
        let returned = await pages.layoutPosition
        XCTAssertEqual(returned.page, original.page)
        XCTAssertEqual(returned.nativePassage, passage, "A visible-character passage must remain unchanged")

        let space = try XCTUnwrap(words.last { $0.text == " " && $0.bounds.minY == digit.bounds.minY && $0.bounds.minX < digit.bounds.minX })
        var legacy = original
        legacy.nativePassage = NativePassage(source: try XCTUnwrap(space.source),
            offsetX: Double(digit.bounds.minX - space.bounds.minX), offsetY: Double(digit.bounds.minY - space.bounds.minY),
            sourceRevision: passage.sourceRevision, styleSignature: passage.styleSignature)
        legacy.zoom = 1
        let record = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(legacy))
        let migrated = try await pages.restore(record)
        XCTAssertEqual(migrated.nativePassage?.source, digit.source, "Restore must normalize only the old whitespace passage")
        XCTAssertEqual(migrated.x, original.x)
        XCTAssertEqual(migrated.y, original.y)
        for zoom in [6.0, 1.0] {
            _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", textZoom: zoom)
            let restored = await pages.layoutPosition
            XCTAssertEqual(restored.nativePassage?.source, digit.source, "The serialized legacy record must survive later reflow")
        }
    }

    func testPositionAnchorIsNotReusedAfterSourceReplacement() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Book.md")
        try String(repeating: "Original words.\n\n", count: 100).write(to: input, atomically: true, encoding: .utf8)
        let first = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await first.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let position = try await first.position(page: 1, x: 20, y: 80)
        let passage = try XCTUnwrap(position.nativePassage)
        try String(repeating: "Replaced different words.\n\n", count: 100).write(to: input, atomically: true, encoding: .utf8)
        let second = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await second.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let restored = try await second.restore(position)
        XCTAssertNotEqual(restored.nativePassage?.sourceRevision, passage.sourceRevision)
        let replacedText = try await second.text(restored.page)
        XCTAssertTrue(replacedText.contains("Replaced"))
    }

    func testReaderTypographyKeepsPassageWhileUserStylesInvalidateIt() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Typography.md")
        try String(repeating: "Repeated words with a stable source passage.\n\n", count: 100).write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let original = try await pages.position(page: 1, x: 20, y: 80)
        let passage = try XCTUnwrap(original.nativePassage)
        _ = try await pages.relayout(fontSize: 20, lineHeight: 1.2, margin: 0, font: "serif", theme: "dark",
                                    pageMargins: PageMargins(cssValues: [20]), textZoom: 1.5)
        let changed = await pages.layoutPosition
        XCTAssertEqual(changed.nativePassage?.source, passage.source)
        let changedWords = try await pages.words(changed.page)
        XCTAssertTrue(changedWords.contains { $0.source == passage.source })
        _ = try await pages.relayout(fontSize: 20, lineHeight: 1.2, margin: 0, font: "serif", theme: "dark",
                                    userCSS: "p { text-transform: uppercase; }", pageMargins: PageMargins(cssValues: [20]), textZoom: 1.5)
        let restyled = await pages.layoutPosition
        XCTAssertNotEqual(restyled.nativePassage?.styleSignature, passage.styleSignature)
    }

    func testExtremeTextZoomKeepsMarkdownPageGeometryAndTerminalText() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("LargeType.md")
        let body = String(repeating: "Readable Markdown should wrap at the larger font size.\n\n", count: 12)
            + "Unique terminal marker END77"
        try body.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let ordinaryCount = await pages.count
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", textZoom: 6)
        let enlargedCount = await pages.count
        XCTAssertGreaterThan(enlargedCount, ordinaryCount)
        XCTAssertLessThan(enlargedCount, 500, "Default em margins must not consume the page at large text zoom")
        let bounds = try await pages.bounds(0)
        XCTAssertEqual(bounds.width, 420, accuracy: 0.1)
        XCTAssertEqual(bounds.height, 595, accuracy: 0.1)
        var terminal = [String]()
        for page in max(0, enlargedCount - 8)..<enlargedCount {
            terminal.append(try await pages.text(page))
        }
        XCTAssertTrue(terminal.joined().filter { !$0.isWhitespace }.hasSuffix("UniqueterminalmarkerEND77"),
                      "The terminal character sequence must survive long-word line breaks")
    }

    func testLargeTextWrapsLongWordsWithoutLosingSelectionAndHonorsUserCSS() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("LongWord.md")
        let word = String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 3)
        try ("<p lang='en'>" + word + "</p>").write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let originalWords = try await pages.words(0)
        let originalText = originalWords.map(\.text).joined() as NSString
        let selected = try await pages.selection(0, range: NSRange(location: 0, length: originalText.length))
        let start = try XCTUnwrap(selected.sourceStart), end = try XCTUnwrap(selected.sourceEnd)
        XCTAssertEqual(selected.text.filter { !$0.isWhitespace }, word)

        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", textZoom: 6)
        let enlargedCount = await pages.count
        let selection = try await pages.selection(from: start, to: end)
        let ordered = selection.keys.sorted().compactMap { selection[$0] }
        XCTAssertEqual(ordered.map(\.text).joined().filter { !$0.isWhitespace }, word)
        for glyph in ordered.flatMap({ $0.words ?? [] }) where glyph.source != nil && !glyph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            XCTAssertLessThanOrEqual(glyph.bounds.maxX, 420.1, "Default Markdown wrapping must keep enlarged word glyphs on the page")
        }
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let returned = try await pages.selection(from: start, to: end)
        XCTAssertEqual(returned.keys.sorted().compactMap { returned[$0]?.text }.joined().filter { !$0.isWhitespace }, word)

        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light",
                                    userCSS: "p { overflow-wrap: normal; }", textZoom: 6)
        let authoredCount = await pages.count
        XCTAssertLessThan(authoredCount, enlargedCount, "An explicit user wrapping rule must override the Markdown default")
    }

    func testMarkdownCopyUsesParsedFlowSemanticsAcrossPages() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("SemanticCopy.md")
        let repeatedWrapText = String(repeating: "wrapword ", count: 2_400)
        let longWord = String(repeating: "hyphenless", count: 36)
        let body = repeatedWrapText + "\n\nHard break one  \nHard break two\n\n"
            + "Paragraph one with Café, 東京, literal-hyphen, and soft\u{00ad}hyphen.\n\nParagraph two follows.\n\n"
            + longWord + "\n\n"
            + "- list alpha\n- list beta\n\n```text\ncode alpha\ncode beta\n```\n\n"
            + "Repeated phrase ends here.\n\nRepeated phrase ends here."
        try body.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let pageCount = await pages.count
        XCTAssertGreaterThan(pageCount, 1)
        let firstWords = try await pages.words(0)
        let firstWord = try XCTUnwrap(firstWords.first { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
        let lastWords = try await pages.words(pageCount - 1)
        let lastWord = try XCTUnwrap(lastWords.last { $0.source != nil && !$0.text.allSatisfy(\.isWhitespace) })
        let selected = try await pages.selection(from: XCTUnwrap(firstWord.source), to: XCTUnwrap(lastWord.source))
        XCTAssertGreaterThan(selected.count, 1, "The source selection must cross a page boundary")
        let copiedText = try await pages.markdownCopyText(selected)
        let copied = try XCTUnwrap(copiedText)

        XCTAssertTrue(copied.hasPrefix("wrapword wrapword"))
        XCTAssertFalse(copied.contains("wrapword\nwrapword"), "Visual page and line wraps must not become copied line breaks")
        XCTAssertTrue(copied.contains(longWord), "Overflow wrapping must not split a word or insert a visual hyphen")
        XCTAssertTrue(copied.contains("Hard break one\nHard break two"))
        XCTAssertTrue(copied.contains("Paragraph one with Café, 東京, literal-hyphen, and soft\u{00ad}hyphen.\nParagraph two follows."))
        XCTAssertTrue(copied.contains("list alpha\nlist beta"))
        XCTAssertTrue(copied.contains("code alpha\ncode beta"))
        XCTAssertEqual(copied.components(separatedBy: "Repeated phrase ends here.").count - 1, 2,
                       "Repeated text must remain tied to its selected source identities")

        let tailText = lastWords.map(\.text).joined() as NSString
        let phrase = "Repeated phrase ends here."
        let phraseRange = tailText.range(of: phrase)
        XCTAssertNotEqual(phraseRange.location, NSNotFound)
        let narrow = try await pages.selection(pageCount - 1, range: phraseRange)
        let narrowCopyText = try await pages.markdownCopyText([PageLocation(page: pageCount - 1): narrow])
        let narrowCopy = try XCTUnwrap(narrowCopyText)
        XCTAssertEqual(narrowCopy, phrase, "Repeated wording must be selected by source identity, not text search")
    }

    func testMarkdownCopyOmitsAutoHyphensAndKeepsNarrowRTLSourceOrder() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("HyphenRTL.md")
        let hyphenated = Array(repeating: "representation", count: 8).joined(separator: " ")
        let rtl = String(repeating: "שלום", count: 32)
        let body = "<p lang=\"en\" style=\"hyphens: auto; width: 90px\">\(hyphenated)</p>\n\n"
            + "<div lang=\"he\" dir=\"rtl\" style=\"width: 90px\">\(rtl)</div>"
        try body.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light",
                                     userCSS: "p, div { width: 90px; }", textZoom: 6)
        let pageCount = await pages.count
        XCTAssertGreaterThan(pageCount, 1, "The narrow RTL word should overflow onto multiple pages")
        var allWords = [RasterWord]()
        for page in 0..<pageCount { allWords += try await pages.words(page) }
        let rtlWords = allWords.filter { $0.text.unicodeScalars.contains { (0x0590...0x05ff).contains(Int($0.value)) } }
        let rtlAnchors = rtlWords.compactMap(\.source)
        XCTAssertEqual(rtlAnchors.count, rtl.unicodeScalars.count)
        XCTAssertEqual(Set(rtlAnchors.map(\.node)).count, 1, "The overflow fragments should retain one source-node identity")
        var selected = [PageLocation: RasterSelection]()
        for page in 0..<pageCount {
            let pageText = (try await pages.text(page) ?? "") as NSString
            if pageText.length > 0 {
                let pageSelection = try await pages.selection(page, range: NSRange(location: 0, length: pageText.length))
                selected[PageLocation(page: page)] = pageSelection
            }
        }
        let selectedRTLCount = selected.values.flatMap { $0.words ?? [] }
            .filter { $0.text.unicodeScalars.contains { (0x0590...0x05ff).contains(Int($0.value)) } }.count
        XCTAssertEqual(selectedRTLCount, rtl.unicodeScalars.count, "Select the full rendered RTL token across its physical pages")
        let copiedText = try await pages.markdownCopyText(selected)
        let copied = try XCTUnwrap(copiedText)

        XCTAssertTrue(copied.contains(hyphenated), "CSS hyphens:auto must not insert generated soft hyphens into copied source text")
        XCTAssertTrue(copied.contains(rtl), "RTL overflow fragments sharing a source node must copy once in source order")
    }

    func testNativeMarkdownPDFExportPreservesOrdinaryChineseAndRadicals() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Unicode.md"), output = temporary.url.appendingPathComponent("Unicode.pdf")
        let expected = "普通汉字 一二三 田 ⼀⼆⼃⽥ office affine fi fl ﬁ ﬂ 😀"
        try expected.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light", textZoom: 1.5)
        let readingText = try await pages.text(0)
        XCTAssertTrue(readingText.filter { !$0.isWhitespace }.contains("⼀⼆⼃⽥"))
        try await pages.exportPDF(to: output)
        let reopened = try NativeFile(output, engine: .mupdf)
        // MuPDF expands typographic fi/fl ligatures in both source and PDF text
        // extraction. Other codepoints remain exact in both independent readers.
        XCTAssertEqual(try XCTUnwrap(reopened.text(0)).filter { !$0.isWhitespace }, readingText.filter { !$0.isWhitespace })
        let systemPDF = try XCTUnwrap(PDFDocument(url: output))
        // PDFKit also expands these presentation ligatures, including in a
        // minimal Type1 PDF. Verify their original codepoints in the actual
        // ToUnicode streams below; keep other characters exact in both readers.
        let systemExpected = expected.replacingOccurrences(of: "ﬁ", with: "fi").replacingOccurrences(of: "ﬂ", with: "fl")
        XCTAssertEqual(try XCTUnwrap(systemPDF.string).filter { !$0.isWhitespace }, systemExpected.filter { !$0.isWhitespace })
        let rawPDF = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let firstPage = try XCTUnwrap(rawPDF.page(at: 1))
        var resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(firstPage.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Font", &fonts))
        let mappings = NSMutableArray()
        CGPDFDictionaryApplyFunction(try XCTUnwrap(fonts), { _, value, context in
            guard let context else { return }
            var font: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .dictionary, &font), let font,
                  CGPDFDictionaryGetStream(font, "ToUnicode", &stream), let stream else { return }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format),
                  let text = String(data: data as Data, encoding: .ascii) else { return }
            Unmanaged<NSMutableArray>.fromOpaque(context).takeUnretainedValue().add(text)
        }, Unmanaged.passUnretained(mappings).toOpaque())
        let decodedMappings = mappings.compactMap { $0 as? String }.joined(separator: "\n")
        for scalar in ["fb01", "fb02"] {
            XCTAssertNotNil(decodedMappings.range(of: "<[0-9a-f]+>\\s*<" + scalar + ">", options: [.regularExpression, .caseInsensitive]),
                            "The PDF must retain the original ligature in ToUnicode")
        }
    }

    func testShapedThaiExportRetainsSourceTextAndVisualContinuationGlyphs() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let input = temporary.url.appendingPathComponent("Thai.md"), output = temporary.url.appendingPathComponent("Thai.pdf")
        let expected = "กำ น้ำ คำ จำ ยำ นำ ภาษาไทย กำลัง น้ำตาล สำคัญ"
        try expected.write(to: input, atomically: true, encoding: .utf8)
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let sourceText = try await pages.text(0)
        let sourceImage = try await pages.image(0, width: 840)
        try await pages.exportPDF(to: output)
        let exported = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(try exported.text(0), sourceText)
        // PDFKit introduces word-segmentation spaces in Thai. The character
        // sequence must still retain the original precomposed U+0E33 scalars.
        let systemText = try XCTUnwrap(PDFDocument(url: output)?.string)
        XCTAssertEqual(systemText.filter { !$0.isWhitespace }, expected.filter { !$0.isWhitespace })
        let exportedImage = try exported.image(0, width: 840)
        XCTAssertEqual(exportedImage.width, sourceImage.width)
        XCTAssertEqual(exportedImage.height, sourceImage.height)
        func ink(_ image: CGImage) throws -> [Bool] {
            var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) < 245 * 3 }
        }
        let originalInk = try ink(sourceImage), resultInk = try ink(exportedImage)
        let union = zip(originalInk, resultInk).filter { $0 || $1 }.count
        let intersection = zip(originalInk, resultInk).filter { $0 && $1 }.count
        XCTAssertGreaterThan(union, 0)
        // Outlined continuation glyphs use different raster hinting from live
        // font glyphs; retain their painted shapes without requiring identical AA.
        XCTAssertGreaterThan(Double(intersection) / Double(max(1, union)), 0.95)
    }
}
#endif
