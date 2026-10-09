#if os(macOS)
import AppKit
import Darwin
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFDisplayTests: XCTestCase {
    private typealias SearchCancelled = @convention(c) () -> Int32
    private typealias NativeSearch = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<CChar>, Int32,
        Int64, Int64, SearchCancelled, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?

    func testNativeSearchLimitsResultsAndContinuesPastTheSidebarLimitInBothDirections() throws {
        let directory = try directory(), source = directory.appendingPathComponent("dense-search.pdf")
        let count = 1007
        let lines = stride(from: 0, to: count, by: 20).map { first in
            (first..<min(first + 20, count)).map { "\($0) needle" }.joined(separator: " ")
        }
        try searchFixture(lines).write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let text = try XCTUnwrap(file.text(0)) as NSString
        let expected = try NSRegularExpression(pattern: "needle")
            .matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { $0.range.location }
        XCTAssertEqual(expected.count, count)
        guard expected.count == count else { return }
        let search = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_search_options_at")), to: NativeSearch.self)
        for limit in [1000, 999] {
            var error = [CChar](repeating: 0, count: 512)
            let pointer = try XCTUnwrap(search(file.document, 0, 0, "needle", 0, -1, Int64(limit), { 0 }, &error),
                                       String(cString: error))
            defer { free(pointer) }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes: pointer, count: strlen(pointer))) as? [String: Any])
            XCTAssertEqual((json["matches"] as? [[String: Any]])?.count, limit,
                           "The native JSON itself must be bounded, before Swift decodes results")
            let matches = try file.matches("needle", page: 0, maximum: limit)
            XCTAssertEqual(matches.map(\.index), Array(expected.prefix(limit)))
            let next = try XCTUnwrap(file.matches("needle", page: 0, after: expected[limit - 1], maximum: 1).first)
            XCTAssertEqual(next.index, expected[limit])
            XCTAssertTrue(next.context.contains("\(limit) needle"), "The context must describe the continued occurrence")
            XCTAssertFalse(next.rects.isEmpty)
        }
        XCTAssertEqual(try file.matches("needle", page: 0).map(\.index), expected)
        XCTAssertEqual(try file.matches("needle", page: 0, backwards: true).map(\.index), Array(expected.reversed()))
        XCTAssertEqual(try file.matches("needle", page: 0, backwards: true, maximum: 2).map(\.index), Array(expected.suffix(2).reversed()))
        XCTAssertEqual(try file.matches("needle", page: 0, after: expected[1000], backwards: true, maximum: 1).first?.index, expected[999])
        XCTAssertEqual(try file.matches("needle", page: 0, after: text.length, backwards: true, maximum: 1).first?.index, expected.last)
        XCTAssertEqual(try file.matches("needle", page: 0, maximum: 1).first?.index, expected.first)
        XCTAssertTrue(try file.matches("needle", page: 0, after: expected[0], backwards: true, maximum: 1).isEmpty)
        XCTAssertTrue(try file.matches("needle", page: 0, after: expected[count - 1], maximum: 1).isEmpty)
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
    }

    func testNativeSearchCursorsUseUTF16AndApplyCaseAndWordFiltersBeforeTheLimit() throws {
        let directory = try directory(), source = directory.appendingPathComponent("search-filters.pdf")
        // The font's ToUnicode map makes @ a supplementary character. Every
        // following cursor must count its surrogate pair, not its UTF-8 bytes.
        try searchFixture(["@ needle Needle NEEDLE needlex xneedle _needle needle_ needle."]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf), text = try XCTUnwrap(file.text(0)) as NSString
        XCTAssertTrue((text as String).hasPrefix("😀 needle "))
        let policies: [(TextSearchOptions, String, NSRegularExpression.Options, Int)] = [
            (.init(), "needle", .caseInsensitive, 8),
            (.init(caseSensitive: true), "needle", [], 6),
            (.init(wholeWord: true), "(?<![A-Za-z0-9_])needle(?![A-Za-z0-9_])", .caseInsensitive, 4),
            (.init(caseSensitive: true, wholeWord: true), "(?<![A-Za-z0-9_])needle(?![A-Za-z0-9_])", [], 2)
        ]
        for (options, pattern, regexOptions, count) in policies {
            let expected = try NSRegularExpression(pattern: pattern, options: regexOptions)
                .matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { $0.range.location }
            XCTAssertEqual(expected.count, count)
            guard expected.count == count else { continue }
            let matches = try file.matches("needle", page: 0, options: options)
            XCTAssertEqual(matches.map(\.index), expected)
            XCTAssertEqual(matches.first?.index, 3)
            for match in matches {
                guard match.index >= 0, match.index <= text.length - 6 else {
                    XCTFail("Search returned an offset outside the page's UTF-16 text"); continue
                }
                XCTAssertEqual(text.substring(with: NSRange(location: match.index, length: 6)).lowercased(), "needle")
                XCTAssertFalse(match.rects.isEmpty)
            }
            XCTAssertTrue(matches.first?.context.hasPrefix("😀 needle ") == true)
            XCTAssertTrue(matches.last?.context.hasSuffix("needle.") == true)
            XCTAssertEqual(try file.matches("needle", page: 0, options: options, after: expected[0], maximum: 1).first?.index, expected[1])
            XCTAssertEqual(try file.matches("needle", page: 0, options: options, backwards: true, maximum: 1).first?.index, expected.last)
            XCTAssertEqual(try file.matches("needle", page: 0, options: options, after: expected[count - 1], backwards: true, maximum: 1).first?.index, expected[count - 2])
            XCTAssertEqual(try file.matches("needle", page: 0, options: options, backwards: true).map(\.index), Array(expected.reversed()))
        }
    }

    func testNativeSearchUsesDirectionalAnchorsAndUniqueNormalizedResultPositions() throws {
        let directory = try directory()
        for count in [5, 7] {
            let source = directory.appendingPathComponent("search-overlap-\(count).pdf")
            try searchFixture([String(repeating: "a", count: count)]).write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(try file.matches("aaa", page: 0).map(\.index), count == 5 ? [0] : [0, 3])
            XCTAssertEqual(try file.matches("aaa", page: 0, backwards: true).map(\.index), count == 5 ? [2] : [4, 1])
            XCTAssertEqual(try file.matches("aaa", page: 0, backwards: true, maximum: 1).first?.index, count - 3)
            if count == 5 {
                XCTAssertTrue(try file.matches("aaa", page: 0, after: 0, maximum: 1).isEmpty)
                XCTAssertTrue(try file.matches("aaa", page: 0, after: 2, backwards: true, maximum: 1).isEmpty)
                XCTAssertEqual(try file.matches("aaa", page: 0, after: 3, backwards: true, maximum: 1).first?.index, 0)
            } else {
                XCTAssertEqual(try file.matches("aaa", page: 0, after: 4, backwards: true, maximum: 1).first?.index, 1)
                // Switching direction resumes after the selected match's end,
                // rather than filtering the page's original [0, 3] result list.
                XCTAssertEqual(try file.matches("aaa", page: 0, after: 1, maximum: 1).first?.index, 4)
                XCTAssertTrue(try file.matches("aaa", page: 0, after: 2, maximum: 1).isEmpty,
                              "A real prior hit at 2 resumes from its end, even if it was absent from the original forward results")
                XCTAssertEqual(try file.matches("aaa", page: 0, after: 3, backwards: true, maximum: 1).first?.index, 0)
            }
        }
        let phrase = directory.appendingPathComponent("search-overlapping-phrase.pdf")
        try searchFixture(["ab ab ab"]).write(to: phrase)
        let phraseFile = try NativeFile(phrase, engine: .mupdf)
        XCTAssertEqual(try phraseFile.matches("ab ab", page: 0, backwards: true).map(\.index), [3, 0],
                       "A phrase may overlap the previous full match when its first word ends before the reverse cursor")
        XCTAssertEqual(try phraseFile.matches("ab ab", page: 0, after: 3, backwards: true, maximum: 1).first?.index, 0)
        let arbitrary = directory.appendingPathComponent("search-arbitrary-cursor.pdf")
        try searchFixture(["abXabXab"]).write(to: arbitrary)
        XCTAssertEqual(try NativeFile(arbitrary, engine: .mupdf).matches("ab", page: 0, after: 1, maximum: 1).first?.index, 3,
                       "A cursor without a matching hit falls back to the first ordinary result after its position")
        let normalized = directory.appendingPathComponent("search-folded.pdf")
        try searchFixture(["@ @"], mappedCharacter: "00DF").write(to: normalized)
        let file = try NativeFile(normalized, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(file.text(0)).hasPrefix("ß ß"))
        XCTAssertTrue(try file.matches("s", page: 0).isEmpty, "A single s must not match half of a sharp-S unit")
        XCTAssertTrue(try file.matches("s", page: 0, backwards: true).isEmpty)
        XCTAssertEqual(try file.matches("ss", page: 0).map(\.index), [0, 2])
        XCTAssertEqual(try file.matches("ß", page: 0).map(\.index), [0, 2])
        XCTAssertEqual(try file.matches("ss", page: 0, backwards: true).map(\.index), [2, 0])
        XCTAssertEqual(try file.matches("ss", page: 0, after: 0, maximum: 1).first?.index, 2)
        XCTAssertEqual(try file.matches("ss", page: 0, after: 2, backwards: true, maximum: 1).first?.index, 0)
        XCTAssertTrue(try file.matches("s", page: 0, options: .init(caseSensitive: true)).isEmpty)
        let adjacent = directory.appendingPathComponent("search-adjacent-folds.pdf")
        try searchFixture(["S@S @@"], mappedCharacter: "00DF").write(to: adjacent)
        let adjacentFile = try NativeFile(adjacent, engine: .mupdf)
        XCTAssertEqual(try adjacentFile.matches("ss", page: 0).map(\.index), [1, 4, 5],
                       "Rejecting a partial folded hit must not skip the next complete source unit")
        XCTAssertEqual(try adjacentFile.matches("ss", page: 0, backwards: true).map(\.index), [5, 4, 1])
        XCTAssertEqual(try adjacentFile.matches("sss", page: 0).map(\.index), [0])
        XCTAssertEqual(try adjacentFile.matches("sss", page: 0, backwards: true).map(\.index), [1])
        XCTAssertEqual(try adjacentFile.matches("ßs", page: 0).map(\.index), [1],
                       "Sharp-S and ss are whole units, so ßs must not consume Sß")
        XCTAssertEqual(try adjacentFile.matches("sß", page: 0).map(\.index), [0])
        XCTAssertEqual(try adjacentFile.matches("ßß", page: 0).map(\.index), [4])
        let accented = directory.appendingPathComponent("search-accented.pdf")
        try searchFixture(["@ E e"], mappedCharacter: "00E9").write(to: accented)
        let accentFile = try NativeFile(accented, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(accentFile.text(0)).hasPrefix("é E e"))
        XCTAssertEqual(try accentFile.matches("e", page: 0).map(\.index), [0, 2, 4])
        XCTAssertEqual(try accentFile.matches("e", page: 0, backwards: true).map(\.index), [4, 2, 0])
        XCTAssertEqual(try accentFile.matches("e", page: 0, after: 0, maximum: 1).first?.index, 2)
        XCTAssertEqual(try accentFile.matches("e", page: 0, options: .init(caseSensitive: true)).map(\.index), [4])
        XCTAssertEqual(try accentFile.matches("é", page: 0, options: .init(caseSensitive: true)).map(\.index), [0])
    }

    @MainActor func testNativeSearchCancellationDiscardsItsResultsAndAllowsANewQuery() async throws {
        let directory = try directory(), source = directory.appendingPathComponent("search-cancellation.pdf")
        let lines = Array(repeating: String(repeating: "needle ", count: 20), count: 50)
            + [String(repeating: "needle ", count: 7), "fresh query"]
        try searchFixture(lines).write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let search = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_search_options_at")), to: NativeSearch.self)
        for backwards in [false, true] {
            let stopped = Task { @MainActor in
                // Cancel from inside the real C search callback, after it has
                // entered native code. No sleep, shared counter or race is needed.
                let cancelled: SearchCancelled = {
                    if Task<Never, Never>.isCancelled { return 1 }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 0
                }
                var error = [CChar](repeating: 0, count: 512)
                let pointer = search(file.document, 0, 0, "needle", backwards ? 4 : 0, -1, -1, cancelled, &error)
                defer { free(pointer) }
                XCTAssertTrue(Task<Never, Never>.isCancelled)
                XCTAssertNil(pointer, "Cancellation must discard native matches rather than return stale JSON")
                XCTAssertNotEqual(error[0], 0)
                XCTAssertThrowsError(try file.matches("needle", page: 0, backwards: backwards, maximum: 1)) {
                    XCTAssertTrue($0 is CancellationError)
                }
            }
            try await stopped.value
            let fresh = try file.matches("fresh", page: 0, maximum: 1)
            XCTAssertEqual(fresh.count, 1); XCTAssertTrue(fresh.first?.context.contains("fresh query") == true)
            XCTAssertEqual(try file.matches("needle", page: 0, maximum: 1000).count, 1000,
                           "A cancelled search must not poison the live document's text cache")
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
    }

    func testRepeatedUnembeddedFontsKeepSearchMemoryBoundedAndIndependentWidths() throws {
        let directory = try directory(), source = directory.appendingPathComponent("system-fonts.pdf")
        let count = 128
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count \(count) /Kids [\((0..<count).map { "\(3 + $0 * 4) 0 R" }.joined(separator: " "))] >>"]
        for page in 0..<count {
            let first = 3 + page * 4, width = page.isMultiple(of: 2) ? 500 : 900
            let content = "BT /F1 20 Tf 20 100 Td (AAAA) Tj ET"
            objects += [
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 \(first + 1) 0 R >> >> /Contents \(first + 3) 0 R >>",
                "<< /Type /Font /Subtype /TrueType /BaseFont /HelveticaNeue /Encoding /WinAnsiEncoding /FirstChar 65 /LastChar 65 /Widths [\(width)] /FontDescriptor \(first + 2) 0 R >>",
                "<< /Type /FontDescriptor /FontName /HelveticaNeue /Flags 32 /FontBBox [-100 -200 1000 900] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
            ]
        }
        try rawPDF(objects).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let original = try imageBytes(file.image(0, width: 200))
        var before = malloc_statistics_t(), after = malloc_statistics_t()
        malloc_zone_statistics(nil, &before)
        for page in 0..<count {
            try autoreleasepool {
                XCTAssertEqual(try file.matches("AAAA", page: page).count, 1)
                let words = try file.words(page).filter { $0.text == "A" }
                XCTAssertEqual(words.count, 4)
                XCTAssertEqual(try XCTUnwrap(words.last).bounds.minX - XCTUnwrap(words.first).bounds.minX,
                               page.isMultiple(of: 2) ? 30 : 54, accuracy: 0.1)
            }
        }
        malloc_zone_statistics(nil, &after)
        let growth = Int64(after.size_in_use) - Int64(before.size_in_use)
        XCTAssertLessThan(growth, 64 * 1024 * 1024, "Repeated system fonts must not retain another entire font file for every page (live heap growth: \(growth) bytes)")
        XCTAssertEqual(try imageBytes(file.image(0, width: 200)), original,
                       "Sharing font bytes must not share the mutable PDF font widths")
    }

    func testLiveStylesKeepWidgetAndAnnotationOrderAndDoNotEditTheDocument() throws {
        let directory = try directory(), source = directory.appendingPathComponent("display.pdf"), bytes = fixture()
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let original = try file.image(0, width: 200)
        let style = PDFColors.Style(mode: .legacy, text: 0xffffff, background: 0)
        let colored = try file.image(0, width: 200, style: style)
        XCTAssertEqual(try pixel(original, 5, 5), [255, 255, 255, 255])
        XCTAssertEqual(try pixel(colored, 5, 5), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(colored, 20, 180), [255, 255, 255, 255], "Black page content follows the theme")
        XCTAssertEqual(try pixel(colored, 90, 180), [255, 0, 255, 255], "Annotation AP participates in the same upstream page replay")
        XCTAssertEqual(try pixel(colored, 60, 180), [255, 255, 0, 255], "Widgets participate in page replay after annotations")
        XCTAssertEqual(try pixel(colored, 70, 180), [255, 255, 0, 255], "The widget covers the overlapping annotation, matching fz_run_page order")
        for visible in [false, true] {
            try file.pdfSetAnnotationsVisible(visible)
            let image = try file.image(0, width: 200, style: style)
            XCTAssertEqual(try pixel(image, 90, 180), visible ? [255, 0, 255, 255] : [0, 0, 0, 255])
            XCTAssertEqual(try pixel(image, 60, 180), try pixel(colored, 60, 180))
        }
        let restored = try file.image(0, width: 200)
        XCTAssertEqual(try imageBytes(restored), try imageBytes(original))
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.undoSteps, before.undoSteps)
        XCTAssertEqual(after.dirty, before.dirty); XCTAssertFalse(after.editingEnabled)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLiveStyledRenderReflectsUnsavedEditsAndUndoWithoutReopening() throws {
        let directory = try directory(), source = directory.appendingPathComponent("edits.pdf"), bytes = fixture()
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let style = PDFColors.Style(mode: .smart, text: 0xffffff, background: 0)
        let original = try file.image(0, width: 200, style: style)
        try file.pdfSetEditing(true)
        _ = try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 40, y: 10, width: 30, height: 30),
            edits: [.color(SIMD3<Float>(0, 0, 0), interior: true), .border(width: 0, style: 0, dash: [])])
        let changed = try file.image(0, width: 200, style: style)
        XCTAssertEqual(try pixel(original, 55, 25), [0, 0, 0, 255])
        XCTAssertEqual(try pixel(changed, 55, 25), [255, 255, 255, 255])
        XCTAssertTrue(try XCTUnwrap(file.pdfInfo()).dirty)
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try imageBytes(file.image(0, width: 200, style: style)), try imageBytes(original))
        try file.pdfUndo(redo: true)
        XCTAssertEqual(try imageBytes(file.image(0, width: 200, style: style)), try imageBytes(changed))
        XCTAssertEqual(try Data(contentsOf: source), bytes, "The displayed edit has never been serialized to a temporary or source PDF")
    }

    func testLiveSmartArtworkAndPixelRegionsShareTheFullPageReplay() throws {
        let directory = try directory(), source = directory.appendingPathComponent("tiles.pdf")
        try fixture().write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let style = PDFColors.Style(mode: .smart, text: 0xf0f0f0, background: 0x101010)
        let original = try file.image(0, width: 200), full = try file.image(0, width: 200, style: style)
        XCTAssertEqual(try pixel(full, 120, 90), try pixel(original, 120, 90), "Smart mode preserves the author's image pixels")
        XCTAssertEqual(try pixel(full, 5, 5), [16, 16, 16, 255])
        let fullBytes = try imageBytes(full)
        for region in [CGRect(x: 75, y: 45, width: 70, height: 80), CGRect(x: 125, y: 95, width: 50, height: 60)] {
            let tile = try file.image(0, width: 200, region: region, style: style)
            XCTAssertEqual(tile.width, Int(region.width)); XCTAssertEqual(tile.height, Int(region.height))
            let tileBytes = try imageBytes(tile)
            for y in 0..<tile.height {
                let start = (Int(region.minY) + y) * full.bytesPerRow + Int(region.minX) * 4
                let expected = fullBytes.subdata(in: start..<(start + tile.width * 4))
                let row = tileBytes.subdata(in: (y * tile.bytesPerRow)..<(y * tile.bytesPerRow + tile.width * 4))
                XCTAssertEqual(row, expected, "Styled tiles retain the full image's pixel origin, image classification and clipping")
            }
        }
        let distant = try file.image(0, width: 1 << 26,
            region: CGRect(x: (1 << 24) + 1024, y: (1 << 24) + 1024, width: 64, height: 48),
            style: .init(mode: .legacy, text: 0xffffff, background: 0))
        XCTAssertEqual(distant.width, 64); XCTAssertEqual(distant.height, 48)
        XCTAssertEqual(try pixel(distant, 32, 24), [0, 0, 0, 255])
        let transparent = try file.image(0, width: 200, style: .init(transparent: true, grayscale: true))
        XCTAssertEqual(transparent.alphaInfo, .premultipliedLast)
        XCTAssertEqual(try pixel(transparent, 5, 5), [0, 0, 0, 0])
        let gray = try pixel(transparent, 120, 90)
        XCTAssertEqual(gray[0], gray[1]); XCTAssertEqual(gray[1], gray[2]); XCTAssertEqual(gray[3], 255)
    }

    func testNativeStyledCancellationLeavesTheLivePageAndJournalUsable() throws {
        let directory = try directory(), source = directory.appendingPathComponent("cancel.pdf")
        try fixture().write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let style = PDFColors.Style(mode: .smart, text: 0xffffff, background: 0, engineering: true)
        typealias Render = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Int32>?, Int32,
            UnsafePointer<Int32>?, UnsafePointer<UInt32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        let render = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_render_cancelable_at")), to: Render.self)
        var expected: Data?
        for _ in 0..<2 {
            let cancellation = try NativeRenderCancellation(); cancellation.cancel()
            var info = [Int32](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
            let bytes = render(file.document, 0, 0, 200, nil, 0, style.nativeValues, style.nativeColors,
                               cancellation.handle, &info, &error)
            defer { free(bytes) }
            XCTAssertNil(bytes, "The C boundary must reject cancellation before and after the display list is cached")
            XCTAssertThrowsError(try file.image(0, width: 200, style: style, cancellation: cancellation)) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertThrowsError(try file.pdfEngineering(cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
            let pixels = try imageBytes(file.image(0, width: 200, style: style))
            if let expected { XCTAssertEqual(pixels, expected) } else { expected = pixels }
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
    }

    func testLiveEngineeringUsesExistingDetectionAndResetsDrawingParameters() throws {
        let directory = try directory()
        for producer in ["AutoCAD", "Microsoft Word AutoCAD", "Word processor"] {
            let source = directory.appendingPathComponent(producer + ".pdf"), bytes = fixture(producer: producer, cad: true)
            try bytes.write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(try file.pdfEngineering().enabled, producer == "AutoCAD")
            let original = try file.image(0, width: 200)
            let enhanced = try file.image(0, width: 200, style: .init(engineering: true))
            XCTAssertLessThan(try pixel(enhanced, 30, 110)[0], try pixel(original, 30, 110)[0])
            XCTAssertEqual(try pixel(enhanced, 60, 80), try pixel(original, 60, 80), "Large gray fills retain their authored contrast")
            XCTAssertEqual(try imageBytes(file.image(0, width: 200)), try imageBytes(original), "CAD minimum line width must not leak into ordinary renders")
        }
    }

    func testLivePageBoxesUseTheRenderersRotationCropOriginAndUserUnit() throws {
        let directory = try directory(), source = directory.appendingPathComponent("boxes.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300] /CropBox [20 30 180 270] /Rotate 90 >>",
            "<< /Type /Page /Parent 2 0 R /UserUnit 2 /BleedBox [10 20 190 280] /TrimBox [30 40 170 260] /ArtBox [40 50 160 250] >>"
        ]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        XCTAssertEqual(try file.pdfPageBoxes(0), [
            CGRect(x: -60, y: -40, width: 600, height: 400), CGRect(x: 0, y: 0, width: 480, height: 320),
            CGRect(x: -20, y: -20, width: 520, height: 360), CGRect(x: 20, y: 20, width: 440, height: 280),
            CGRect(x: 40, y: 40, width: 400, height: 240)
        ])
        XCTAssertEqual(try file.bounds(0), CGRect(x: 0, y: 0, width: 480, height: 320))
        let rendered = try file.image(0, width: 480)
        XCTAssertEqual(rendered.width, 480); XCTAssertEqual(rendered.height, 320)
        let geometry = try file.pdfPageGeometry(0)
        XCTAssertEqual(CGRect(x: 20, y: 30, width: 160, height: 240).applying(geometry.transform), try file.bounds(0))
        XCTAssertThrowsError(try file.bounds(-1)); XCTAssertThrowsError(try file.bounds(1))
        typealias Bounds = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
        let bounds = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_bounds_at")), to: Bounds.self)
        for (chapter, page): (Int32, Int32) in [(1, 0), (0, -1), (0, 1)] {
            var value = [Float](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(bounds(file.document, chapter, page, &value, &error), 0)
            XCTAssertNotEqual(error[0], 0, "The lightweight PDF geometry path must still reject invalid locations")
        }
        XCTAssertThrowsError(try file.pdfPageBoxes(1))
        XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        let mediaOnly = directory.appendingPathComponent("media-only.pdf")
        try rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 200] /ArtBox [10 10 10 20] >>"
        ]).write(to: mediaOnly)
        XCTAssertEqual(try NativeFile(mediaOnly, engine: .mupdf).pdfPageBoxes(0),
                       [CGRect(x: 0, y: 0, width: 100, height: 200), nil, nil, nil, nil])
    }

    func testContentMeasurementSharesVisibleLiveAppearancesAndSurvivesCancellation() throws {
        let directory = try directory(), source = directory.appendingPathComponent("content.pdf")
        let body = "0 g 20 20 20 20 re f\n", appearance = "0 g 0 0 50 50 re f\n"
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length \(body.utf8.count) >>\nstream\n\(body)endstream",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [100 100 150 150] /AP << /N 6 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 50 50] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        let bodyBounds = CGRect(x: 20, y: 160, width: 20, height: 20)
        let visibleBounds = CGRect(x: 20, y: 50, width: 130, height: 130)
        typealias Measure = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Float>, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> Int32
        let measure = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_content_bounds_at")), to: Measure.self)
        for visible in [true, false, true] {
            try file.pdfSetAnnotationsVisible(visible)
            let cancellation = try NativeRenderCancellation(); cancellation.cancel()
            var value = [Float](repeating: 0, count: 4), error = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(measure(file.document, 0, 0, &value, cancellation.handle, &error), 0)
            XCTAssertThrowsError(try file.contentBounds(0, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try file.contentBounds(0), visible ? visibleBounds : bodyBounds)
            let image = try file.image(0, width: 200)
            XCTAssertEqual(try pixel(image, 125, 75), visible ? [0, 0, 0, 255] : [255, 255, 255, 255])
            XCTAssertEqual(try pixel(image, 30, 170), [0, 0, 0, 255])
        }
        let unchanged = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(unchanged.undoPosition, before.undoPosition); XCTAssertEqual(unchanged.dirty, before.dirty)
        try file.pdfSetEditing(true)
        _ = try file.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 160, y: 10, width: 20, height: 20),
            edits: [.color(SIMD3<Float>(0, 0, 0), interior: true), .border(width: 0, style: 0, dash: [])])
        XCTAssertTrue(try XCTUnwrap(file.contentBounds(0)).contains(CGRect(x: 160, y: 10, width: 20, height: 20)))
        XCTAssertEqual(try pixel(file.image(0, width: 200), 170, 20), [0, 0, 0, 255])
        try file.pdfUndo(redo: false)
        XCTAssertEqual(try file.contentBounds(0), visibleBounds)
        XCTAssertEqual(try pixel(file.image(0, width: 200), 170, 20), [255, 255, 255, 255])
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testRepeatedPointSelectionsKeepPageIdentityAndCancellationDoesNotPoisonText() throws {
        let directory = try directory(), source = directory.appendingPathComponent("selection.pdf")
        let first = "BT /F1 18 Tf 20 100 Td (Alpha beta) Tj ET\n"
        let second = "BT /F1 18 Tf 20 100 Td (Second page) Tj ET\n"
        let bytes = rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 200] /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>", "<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>",
            "<< /Length \(first.utf8.count) >>\nstream\n\(first)endstream",
            "<< /Length \(second.utf8.count) >>\nstream\n\(second)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
        typealias Select = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Float, Float, Float, Float, Int32, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let select = unsafeBitCast(try XCTUnwrap(dlsym(file.library, "lf_select_at")), to: Select.self)
        for page in [0, 0, 1, 1, 0] {
            let cancellation = try NativeRenderCancellation(); cancellation.cancel()
            var error = [CChar](repeating: 0, count: 512)
            let pointer = select(file.document, 0, Int32(page), 0, 0, 200, 200, 3, cancellation.handle, &error)
            free(pointer)
            XCTAssertNil(pointer, "Cancellation must be honored with either a cached or uncached text page")
            XCTAssertThrowsError(try file.selection(page, from: .zero, to: CGPoint(x: 200, y: 200), mode: 3, cancellation: cancellation)) {
                XCTAssertTrue($0 is CancellationError)
            }
            let selected = try file.selection(page, from: .zero, to: CGPoint(x: 200, y: 200), mode: 3)
            XCTAssertEqual(selected.text.trimmingCharacters(in: .whitespacesAndNewlines), page == 0 ? "Alpha beta" : "Second page")
            XCTAssertFalse(selected.words?.isEmpty ?? true)
            let matches = try file.matches(page == 0 ? "Alpha" : "Second", page: page)
            XCTAssertEqual(matches.count, 1, "Search shares the retained text without consuming the next drag's page")
            let again = try file.selection(page, from: .zero, to: CGPoint(x: 200, y: 200), mode: 3)
            XCTAssertEqual(again.text, selected.text); XCTAssertEqual(again.rects, selected.rects)
        }
        let after = try XCTUnwrap(file.pdfInfo())
        XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func searchFixture(_ lines: [String], mappedCharacter: String = "D83DDE00") -> Data {
        let content = "BT /F1 5 Tf 12 TL 20 780 Td\n" + lines.map { "(\($0)) Tj T*" }.joined(separator: "\n") + "\nET\n"
        let cmap = """
        /CIDInit /ProcSet findresource begin 12 dict begin begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /SearchUnicode def /CMapType 2 def
        1 begincodespacerange <00> <FF> endcodespacerange
        2 beginbfrange <20> <3F> <0020> <41> <7E> <0041> endbfrange
        1 beginbfchar <40> <\(mappedCharacter)> endbfchar
        endcmap CMapName currentdict /CMap defineresource pop end end
        """
        return rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 800] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream"
        ])
    }

    private func directory() throws -> URL {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("Build MuPDF before native PDF display tests")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-display-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func imageBytes(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        let bytes = try imageBytes(image), components = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * components
        let color = Array(bytes[offset..<(offset + components)])
        return components == 3 ? color + [255] : color
    }
    private func fixture(producer: String = "", cad: Bool = false) -> Data {
        let colors = "702020205020202080604020401030103050706010203060301010106050703050305070504010104020602060203030>"
        let content = cad ? "0.5 0 0 0.5 0 0 cm .7 g 20 178 100 4 re f 100 200 100 100 re f\n" :
            "0 g 10 10 30 30 re f q 80 0 0 80 80 70 cm /Im Do Q\n"
        func stream(_ body: String, _ entries: String = "") -> String {
            "<< \(entries) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
        }
        let form = "/Type /XObject /Subtype /Form /BBox [0 0 40 40] /Resources << >>"
        return rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R 7 0 R] >>",
            stream(content), stream(colors, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode"),
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (button) /Rect [40 0 80 40] /AP << /N 8 0 R >> >>",
            "<< /Type /Annot /Subtype /Stamp /Name /Custom /Rect [60 0 100 40] /AP << /N 9 0 R >> >>",
            stream("0 0 1 rg 0 0 40 40 re f", form), stream("0 1 0 rg 0 0 40 40 re f", form),
            "<< /Producer (\(producer)) >>"
        ], info: 10)
    }
    private func rawPDF(_ objects: [String], info: Int? = nil) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R \(info.map { "/Info \($0) 0 R" } ?? "") >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
#endif
