#if os(macOS)
import XCTest
import PDFKit
import AppKit
import SumraCore
@testable import Sumra

@MainActor
final class ReaderPrintingTests: XCTestCase {
    func testLazyMarkdownPrintViewRequestsOnlyNeededPageAndCachesItsPDF() throws {
        let bytes = fixture(widths: [120], rotations: [0])
        var requested = [Int]()
        let view = try ReaderPrinting.PDFPrintView(pageCount: 32_092) { page in
            requested.append(page)
            return bytes
        }
        var range = NSRange()
        XCTAssertTrue(view.knowsPageRange(&range))
        XCTAssertEqual(range, NSRange(location: 1, length: 32_092))
        XCTAssertTrue(requested.isEmpty, "Opening the print panel must not export the book")

        let last = view.rectForPage(32_092)
        XCTAssertEqual(last.size, CGSize(width: 120, height: 200))
        XCTAssertEqual(requested, [32_092], "A late-page request must skip all preceding pages")
        XCTAssertTrue(PDFDocument(data: view.dataWithPDF(inside: last))?.string?.contains("FIRST PRINT") == true)
        XCTAssertEqual(requested, [32_092], "Preview drawing must reuse the requested page")
        XCTAssertEqual(view.rectForPage(32_092), last)
        XCTAssertEqual(requested, [32_092])
        _ = view.rectForPage(1)
        XCTAssertEqual(requested, [32_092, 1])
        XCTAssertNil(view.error)
    }

    func testMarkdownPrintOperationAcceptsLatePageRangeWithoutLoadingPages() throws {
        let count = 1_374_508
        var requests = 0
        let view = try ReaderPrinting.PDFPrintView(pageCount: count) { _ in
            requests += 1
            return Data()
        }
        let sourceInfo = NSPrintInfo()
        sourceInfo.printSettings["SumraPrintScaling"] = ReaderPrinting.Scaling.fit.rawValue
        sourceInfo.printSettings["SumraPrintRotation"] = 90
        let operation = try ReaderPrinting.makePrintOperation(view, info: sourceInfo, title: "Large Markdown",
                                                               preferences: nil, markdownPageCount: count)
        let settings = OpaquePointer(operation.printInfo.pmPrintSettings())
        var minimum: UInt32 = 0, maximum: UInt32 = 0
        XCTAssertEqual(PMGetPageRange(settings, &minimum, &maximum), noErr)
        XCTAssertEqual(minimum, 1)
        XCTAssertEqual(maximum, UInt32(count))

        // The accessory edits the print job itself, including a seven-digit
        // selection, without asking the view to produce any page.
        let accessory = try XCTUnwrap(operation.printPanel.accessoryControllers.first as? ReaderPrinting.Options)
        accessory.representedObject = NSPrintInfo()
        XCTAssertTrue(accessory.printAllPages)
        XCTAssertEqual(accessory.firstPrintPage, 1)
        XCTAssertEqual(accessory.lastPrintPage, count)
        accessory.printAllPages = false
        accessory.firstPrintPage = count - 31
        // The previewless panel resets these standard keys when it closes.
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = Int32.max
        try accessory.applyExtendedRange(to: operation.printInfo)
        var first: UInt32 = 0, last: UInt32 = 0
        XCTAssertEqual(PMGetFirstPage(settings, &first), noErr)
        XCTAssertEqual(PMGetLastPage(settings, &last), noErr)
        XCTAssertEqual(first, UInt32(count - 31))
        XCTAssertEqual(last, UInt32(count))
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] as? Bool, false)
        accessory.firstPrintPage = count + 1
        accessory.lastPrintPage = count - 32
        XCTAssertEqual(accessory.firstPrintPage, count - 31)
        XCTAssertEqual(accessory.lastPrintPage, count)
        XCTAssertEqual(operation.printInfo.printSettings["SumraPrintScaling"] as? Int, ReaderPrinting.Scaling.fit.rawValue)
        XCTAssertEqual(operation.printInfo.printSettings["SumraPrintRotation"] as? Int, 90)
        accessory.printAllPages = true
        try accessory.applyExtendedRange(to: operation.printInfo)
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] as? Bool, true)
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? Int, 1)
        XCTAssertEqual(operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] as? Int, count)
        XCTAssertEqual(requests, 0)

        let selectedInfo = NSPrintInfo()
        selectedInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        selectedInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = count - 2
        selectedInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = count
        let selected = try ReaderPrinting.makePrintOperation(view, info: selectedInfo, title: "Selected Markdown",
                                                              preferences: nil, markdownPageCount: count)
        let selectedAccessory = try XCTUnwrap(selected.printPanel.accessoryControllers.first as? ReaderPrinting.Options)
        XCTAssertFalse(selectedAccessory.printAllPages)
        XCTAssertEqual(selectedAccessory.firstPrintPage, count - 2)
        XCTAssertEqual(selectedAccessory.lastPrintPage, count)
        selected.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        selected.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        selected.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = Int32.max
        try selectedAccessory.applyExtendedRange(to: selected.printInfo)
        XCTAssertEqual(selected.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] as? Bool, false)
        XCTAssertEqual(selected.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? Int, count - 2)
        XCTAssertEqual(selected.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] as? Int, count)

        let ordinary = try ReaderPrinting.makePrintOperation(view, info: sourceInfo, title: "PDF", preferences: nil)
        var ordinaryMin: UInt32 = 0, ordinaryMax: UInt32 = 0
        var sourceMin: UInt32 = 0, sourceMax: UInt32 = 0
        XCTAssertEqual(PMGetPageRange(OpaquePointer(ordinary.printInfo.pmPrintSettings()), &ordinaryMin, &ordinaryMax), noErr)
        XCTAssertEqual(PMGetPageRange(OpaquePointer(sourceInfo.pmPrintSettings()), &sourceMin, &sourceMax), noErr)
        XCTAssertEqual(ordinaryMin, sourceMin)
        XCTAssertEqual(ordinaryMax, sourceMax)
        XCTAssertEqual(requests, 0)
    }

    func testLazyMarkdownPrintViewRetainsOriginalPageFailure() throws {
        let expected = ReadError("The Markdown layout changed while printing")
        var requests = 0
        let view = try ReaderPrinting.PDFPrintView(pageCount: 2) { _ in
            requests += 1
            throw expected
        }
        XCTAssertEqual(view.rectForPage(2), .zero)
        XCTAssertEqual(view.error?.localizedDescription, expected.localizedDescription)
        XCTAssertEqual(view.rectForPage(2), .zero)
        XCTAssertEqual(requests, 1, "A failed print must not retry an uncertain page")
    }

    func testMarkdownSavePDFPreservesNativeTextAndLoadsOnlyTheSelectedLatePage() throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let temporary = try TemporaryDirectory()
        let markdown = temporary.url.appendingPathComponent("Unicode.md")
        let input = "# Hindi\n\n普通汉字 一二三 田 ⼀⼆⼃⽥ office affine fi fl ﬁ ﬂ\n\nUNIQUE END77"
        try input.write(to: markdown, atomically: true, encoding: .utf8)
        let file = try NativeFile(markdown, engine: .mupdf)
        let nativePDF = temporary.url.appendingPathComponent("Native.pdf")
        XCTAssertTrue(try file.exportPDF(to: nativePDF, selectedPages: [0]))
        let bytes = try Data(contentsOf: nativePDF)
        let original = try XCTUnwrap(PDFDocument(data: bytes)?.string)
        func characters(_ text: String) -> String {
            let expanded = text.replacingOccurrences(of: "ﬁ", with: "fi").replacingOccurrences(of: "ﬂ", with: "fl")
            return String(String.UnicodeScalarView(expanded.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }))
        }

        // This is an actual local AppKit save job, with the panel suppressed.
        // Selecting its last page must not enumerate a million-page book.
        let count = 1_374_508
        for (angle, percentage) in [(0, 1.0), (90, 1.25)] {
            var requests = [Int]()
            let view = try ReaderPrinting.PDFPrintView(pageCount: count, preservePrintText: true) { page in
                requests.append(page)
                return bytes
            }
            let output = temporary.url.appendingPathComponent("Saved-\(angle).pdf")
            let info = NSPrintInfo()
            info.paperSize = CGSize(width: 595, height: 842)
            info.scalingFactor = percentage
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = count
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = count
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            info.printSettings["SumraPrintRotation"] = angle
            let operation = try ReaderPrinting.makePrintOperation(view, info: info, title: "Unicode save",
                preferences: nil, markdownPageCount: count)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            XCTAssertTrue(operation.run())
            XCTAssertNil(view.error)
            let before = try XCTUnwrap(CGPDFDocument(output as CFURL))
            let beforePage = try XCTUnwrap(before.page(at: 1))
            let media = beforePage.getBoxRect(.mediaBox)
            let beforeInk = try printInk(beforePage)
            try view.finishSavedPrint(operation)
            let saved = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertEqual(saved.pageCount, 1)
            XCTAssertEqual(characters(try XCTUnwrap(saved.string)), characters(original))
            XCTAssertEqual(saved.findString("⼀⼆⼃⽥", withOptions: []).count, 1)
            XCTAssertEqual(saved.findString("END77", withOptions: []).count, 1)
            XCTAssertEqual(requests, [count])
            let afterPage = try XCTUnwrap(CGPDFDocument(output as CFURL)?.page(at: 1))
            XCTAssertEqual(afterPage.getBoxRect(.mediaBox), media)
            let afterInk = try printInk(afterPage)
            XCTAssertFalse(beforeInk.isEmpty)
            XCTAssertGreaterThan(Double(beforeInk.intersection(afterInk).count) /
                                 Double(beforeInk.union(afterInk).count), 0.98,
                                 "Preserving text must retain AppKit's scaled and rotated ink placement")
        }
        XCTAssertEqual(try Data(contentsOf: nativePDF), bytes)
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), input)
    }

    func testMarkdownPrintPageUsesLiveLayoutAndRejectsLaterChanges() async throws {
        try requireMuPDF()
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("print.md")
        try "Print 中文 ⼀⼆⼃\n".write(to: source, atomically: true, encoding: .utf8)
        let pages = try Pages(source, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        let snapshot = try await pages.prepareMarkdownPrint()
        let output = try await pages.markdownPrintPage(0, snapshot: snapshot)
        XCTAssertEqual(PDFDocument(data: output)?.pageCount, 1)
        XCTAssertTrue(PDFDocument(data: output)?.string?.contains("中文") == true)

        _ = try await pages.relayout(fontSize: 20, lineHeight: 1.6, margin: 0, font: "system", theme: "light")
        do {
            _ = try await pages.markdownPrintPage(0, snapshot: snapshot)
            XCTFail("A stale layout must not print")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("layout changed"))
        }
        let revised = try await pages.prepareMarkdownPrint()
        try "Changed source\n".write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await pages.markdownPrintPage(0, snapshot: revised)
            XCTFail("A changed source must not print")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("source changed"))
        }
    }

    func testNativePrintRequestsOnlyTheCurrentPageAndRetainsItsBytesAcrossScratchChanges() throws {
        try requireMuPDF()
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("book.pdf")
        let bytes = fixture(widths: [100, 180], rotations: [0, 0])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        let view = try ReaderPrinting.PDFPrintView(file: file, temporary: temporary, scaling: .fit)
        let scratch = temporary.url.appendingPathComponent("PrintPage.pdf")
        var range = NSRange()
        XCTAssertTrue(view.knowsPageRange(&range)); XCTAssertEqual(range, NSRange(location: 1, length: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "Counting print pages must not generate a page")

        let last = view.rectForPage(2)
        XCTAssertEqual(last.size, CGSize(width: 180, height: 200))
        let output = try XCTUnwrap(PDFDocument(data: Data(contentsOf: scratch)))
        XCTAssertEqual(output.pageCount, 1)
        XCTAssertTrue(output.string?.contains("SECOND PRINT") == true)
        XCTAssertFalse(output.string?.contains("FIRST PRINT") == true, "A late-page request must not generate preceding pages")
        let changedScratch = Data("Scratch no longer contains a PDF".utf8)
        try changedScratch.write(to: scratch)
        XCTAssertEqual(view.rectForPage(2), last)
        let cached = view.dataWithPDF(inside: last)
        XCTAssertTrue(PDFDocument(data: cached)?.string?.contains("SECOND PRINT") == true)
        XCTAssertEqual(try Data(contentsOf: scratch), changedScratch, "Repeated drawing must reuse the current page")

        let first = view.rectForPage(1)
        XCTAssertEqual(first.size, CGSize(width: 100, height: 200))
        let firstData = view.dataWithPDF(inside: first)
        XCTAssertTrue(PDFDocument(data: firstData)?.string?.contains("FIRST PRINT") == true)
        XCTAssertFalse(PDFDocument(data: firstData)?.string?.contains("SECOND PRINT") == true)
        let again = view.rectForPage(2)
        XCTAssertTrue(PDFDocument(data: view.dataWithPDF(inside: again))?.string?.contains("SECOND PRINT") == true)
        XCTAssertNil(view.error)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testNativeSelectionMapsSourcePagesAndAppliesRotationOnce() throws {
        try requireMuPDF()
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("book.pdf")
        try fixture(widths: [100, 180], rotations: [0, 0]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        // Fitz uses the normalized page's top-left origin. Both bands and
        // the complete line of text cross this area; 10/70 of its width is red.
        let area = CGRect(x: 20, y: 60, width: 70, height: 80)
        let view = try ReaderPrinting.PDFPrintView(file: file, temporary: temporary, scaling: .fit,
            selectedPages: [1, 0], regions: [[area], [area]], rotation: 90)
        for (index, text) in [(1, "SECOND PRINT"), (2, "FIRST PRINT")] {
            let rect = view.rectForPage(index)
            XCTAssertEqual(rect.size, CGSize(width: 80, height: 70), "The baked native rotation must not be applied twice")
            let data = view.dataWithPDF(inside: rect)
            XCTAssertTrue(PDFDocument(data: data)?.string?.contains(text) == true)
            let document = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
            let colors = try colorCoverage(XCTUnwrap(document.page(at: 1)))
            XCTAssertEqual(Double(colors.red) / Double(colors.red + colors.green), 1.0 / 7, accuracy: 0.02)
        }
        XCTAssertNil(view.error)
    }

    func testNativePageFailureIsRetainedAndMarksThePrintSessionFailed() throws {
        try requireMuPDF()
        _ = NSApplication.shared
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("book.pdf")
        try fixture(widths: [100], rotations: [0]).write(to: source)
        let file = try NativeFile(source, engine: .mupdf), scratchDirectory = try TemporaryDirectory()
        let view = try ReaderPrinting.PDFPrintView(file: file, temporary: scratchDirectory)
        try FileManager.default.removeItem(at: scratchDirectory.url)
        let previous = NSPrintOperation.current, operation = NSPrintOperation(view: view, printInfo: NSPrintInfo())
        NSPrintOperation.current = operation
        defer { NSPrintOperation.current = previous }
        XCTAssertEqual(view.rectForPage(1), .zero)
        let failure = try XCTUnwrap(view.error)
        XCTAssertFalse(failure.localizedDescription.isEmpty)
        XCTAssertEqual(PMSessionError(OpaquePointer(operation.printInfo.pmPrintSession())), OSStatus(kPMGeneralError))
        try FileManager.default.createDirectory(at: scratchDirectory.url, withIntermediateDirectories: false)
        XCTAssertEqual(view.rectForPage(1), .zero, "A failed operation must not resume as a partial success")
        XCTAssertEqual(view.error?.localizedDescription, failure.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDirectory.url.appendingPathComponent("PrintPage.pdf").path))
    }

    func testPrintViewPreservesExportedPageOrderPhysicalSizesAndSource() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let source = temporary.url.appendingPathComponent("book.pdf")
        let bytes = fixture(widths: [100, 180], rotations: [0, 90])
        try bytes.write(to: source)
        let view = try ReaderPrinting.PDFPrintView(url: source, scaling: .fit)
        var range = NSRange()
        XCTAssertTrue(view.knowsPageRange(&range)); XCTAssertEqual(range, NSRange(location: 1, length: 2))
        XCTAssertEqual(view.rectForPage(0), .zero); XCTAssertEqual(view.rectForPage(3), .zero)
        for (index, size) in [CGSize(width: 100, height: 200), CGSize(width: 200, height: 180)].enumerated() {
            let rect = view.rectForPage(index + 1)
            XCTAssertEqual(rect.size, size)
            let data = view.dataWithPDF(inside: rect)
            let pdf = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
            XCTAssertEqual(pdf.numberOfPages, 1)
            XCTAssertEqual(try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox).size, size)
            // PDFKit is an independent text decoder here, never a print owner.
            XCTAssertTrue(PDFDocument(data: data)?.string?.contains(index == 0 ? "FIRST PRINT" : "SECOND PRINT") == true)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSelectionClipsOffsetPagesAndPreservesVectorTextAcrossRotations() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let source = temporary.url.appendingPathComponent("book.pdf")
        let area = CGRect(x: 60, y: 80, width: 60, height: 80)
        for pageRotation in [0, 90, 180, 270] {
            let bytes = fixture(widths: [100], rotations: [pageRotation])
            try bytes.write(to: source)
            for rotation in [0, 90, 180, 270] {
                let view = try ReaderPrinting.PDFPrintView(url: source, scaling: .fit, regions: [[area]], rotation: rotation)
                let rotated = (pageRotation + rotation) % 180 != 0
                let size = rotated ? CGSize(width: 80, height: 60) : area.size
                let rectangle = view.rectForPage(1)
                XCTAssertEqual(rectangle.size, size)
                let data = view.dataWithPDF(inside: rectangle)
                let document = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
                let page = try XCTUnwrap(document.page(at: 1))
                XCTAssertEqual(page.getBoxRect(.mediaBox).size, size)
                XCTAssertTrue(PDFDocument(data: data)?.string?.contains("FIRST PRINT") == true,
                              "Selection printing must retain searchable vector text")
                let colors = try colorCoverage(page)
                // The original red band is 30 points wide, but this region
                // intersects only its last 10 of 60 points. All rotations must
                // crop the same artwork rather than squeeze the whole page.
                XCTAssertEqual(Double(colors.red) / Double(colors.red + colors.green), 1.0 / 6, accuracy: 0.02)
                XCTAssertGreaterThan(colors.red + colors.green, Int(size.width * size.height * 0.95))
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testSelectionRejectsMissingAndOutsideRegions() throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let source = temporary.url.appendingPathComponent("book.pdf")
        try fixture(widths: [100], rotations: [0]).write(to: source)
        XCTAssertThrowsError(try ReaderPrinting.PDFPrintView(url: source, scaling: .fit, regions: []))
        XCTAssertThrowsError(try ReaderPrinting.PDFPrintView(url: source, scaling: .fit,
            regions: [[CGRect(x: 500, y: 500, width: 10, height: 10)]]))
        let partial = try ReaderPrinting.PDFPrintView(url: source, scaling: .fit,
            regions: [[CGRect(x: 30, y: 10, width: 30, height: 40)]])
        XCTAssertEqual(partial.rectForPage(1).size, CGSize(width: 20, height: 30))
    }

    func testDisjointSelectionLeavesUnselectedInkBlankAcrossRotations() throws {
        try requireMuPDF()
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("selection.pdf")
        let bytes = fixture(widths: [100], rotations: [0])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        // Two diagonal quadrants span the whole page, leaving half its ink unselected.
        let pdfAreas = [CGRect(x: 40, y: 120, width: 30, height: 100), CGRect(x: 70, y: 20, width: 70, height: 100)]
        let nativeAreas = [CGRect(x: 0, y: 0, width: 30, height: 100), CGRect(x: 30, y: 100, width: 70, height: 100)]
        for rotation in [0, 90, 180, 270] {
            let views = [
                try ReaderPrinting.PDFPrintView(url: source, scaling: .fit, regions: [pdfAreas], rotation: rotation),
                try ReaderPrinting.PDFPrintView(file: file, temporary: temporary, scaling: .fit,
                    selectedPages: [0], regions: [nativeAreas], rotation: rotation)
            ]
            for view in views {
                let data = view.dataWithPDF(inside: view.rectForPage(1))
                let document = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
                let colors = try colorCoverage(XCTUnwrap(document.page(at: 1)))
                XCTAssertEqual(Double(colors.red + colors.green), 10_000, accuracy: 200,
                               "The unselected half inside the bounding rectangle must remain blank")
                XCTAssertEqual(Double(colors.red) / Double(colors.red + colors.green), 0.3, accuracy: 0.02)
                XCTAssertNil(view.error)
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSelectionStretchPreservesAspectRatio() throws {
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("selection.pdf")
        try fixture(widths: [100], rotations: [0]).write(to: source)
        let view = try ReaderPrinting.PDFPrintView(url: source, scaling: .stretch,
            regions: [[CGRect(x: 40, y: 20, width: 100, height: 200)]])
        let info = BorderlessPrintInfo()
        info.paperSize = CGSize(width: 400, height: 400)
        info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
        let output = try render(view, info: info, to: temporary.url.appendingPathComponent("printed.pdf"))
        let colors = try colorCoverage(XCTUnwrap(output.page(at: 1)))
        XCTAssertEqual(Double(colors.red + colors.green), 80_000, accuracy: 1600,
                       "Selection stretch uses the uniform fit, as in Print.cpp")
    }

    func testWideSelectionKeepsReadingOrientationOnBothPaperOrientations() throws {
        try requireMuPDF()
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("selection.pdf")
        let bytes = fixture(widths: [100], rotations: [0])
        try bytes.write(to: source)
        let file = try NativeFile(source, engine: .mupdf)
        // The same horizontal text band in PDF bottom-left and Fitz top-left space.
        let pdfArea = CGRect(x: 50, y: 90, width: 90, height: 30)
        let nativeArea = CGRect(x: 10, y: 100, width: 90, height: 30)
        for landscape in [false, true] {
            for readingRotation in [0, 90] {
                for extraRotation in [0, 90, 180] {
                    let info = BorderlessPrintInfo()
                    info.paperSize = landscape ? CGSize(width: 400, height: 300) : CGSize(width: 300, height: 400)
                    info.orientation = landscape ? .landscape : .portrait
                    info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
                    info.printSettings["SumraPrintRotation"] = extraRotation
                    let views = [
                        try ReaderPrinting.PDFPrintView(url: source, regions: [[pdfArea]], rotation: readingRotation),
                        try ReaderPrinting.PDFPrintView(file: file, temporary: temporary,
                            selectedPages: [0], regions: [[nativeArea]], rotation: readingRotation)
                    ]
                    for (route, view) in views.enumerated() {
                        let output = temporary.url.appendingPathComponent("selected-\(landscape)-\(readingRotation)-\(extraRotation)-\(route).pdf")
                        let document = try render(view, info: info, to: output)
                        let colors = try colorCoverage(XCTUnwrap(document.page(at: 1)))
                        let angle = (readingRotation + extraRotation) % 360
                        let expected = angle % 180 == 0 ? CGSize(width: 90, height: 30) : CGSize(width: 30, height: 90)
                        let red = angle % 180 == 0 ? CGSize(width: 20, height: 30) : CGSize(width: 30, height: 20)
                        let ink = colors.redBounds.union(colors.greenBounds)
                        XCTAssertEqual(ink.size, expected,
                                       "Selection orientation follows the reader and explicit rotation, independent of paper")
                        XCTAssertEqual(colors.redBounds.size, red)
                        if angle == 0 { XCTAssertEqual(colors.redBounds.minX, ink.minX) }
                        else if angle == 180 { XCTAssertEqual(colors.redBounds.maxX, ink.maxX) }
                        XCTAssertTrue(PDFDocument(url: output)?.string?.contains("FIRST PRINT") == true)
                    }
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testPrintScalingModesRetainVectorTextAndExpectedArtworkSize() throws {
        let temporary = try TemporaryDirectory(), input = temporary.url.appendingPathComponent("small.pdf")
        defer { withExtendedLifetime(temporary) {} }
        let bytes = fixture(widths: [100], rotations: [0])
        try bytes.write(to: input)
        for (mode, paintedArea) in [(ReaderPrinting.Scaling.actual, 20_000), (.shrink, 20_000), (.fit, 80_000), (.stretch, 160_000)] {
            let view = try ReaderPrinting.PDFPrintView(url: input, scaling: mode)
            let output = temporary.url.appendingPathComponent("\(mode.rawValue).pdf")
            var paper = CGRect(x: 0, y: 0, width: 400, height: 400)
            let writer = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &paper, nil))
            writer.beginPDFPage(nil)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: writer, flipped: false)
            view.frame = paper; view.draw(paper)
            NSGraphicsContext.current = previous
            writer.endPDFPage(); writer.closePDF()
            let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL)), page = try XCTUnwrap(pdf.page(at: 1))
            let colors = try colorCoverage(page)
            XCTAssertEqual(Double(colors.red + colors.green), Double(paintedArea), accuracy: Double(paintedArea) * 0.02)
            XCTAssertEqual(Double(colors.red) / Double(colors.red + colors.green), 0.3, accuracy: 0.02)
            XCTAssertTrue(PDFDocument(url: output)?.string?.contains("FIRST PRINT") == true)
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testActualSizeUsesPaperOriginWhileSelectionUsesPrintableOriginAndPanelScale() throws {
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("actual.pdf")
        defer { withExtendedLifetime(temporary) {} }
        try fixture(widths: [100], rotations: [0]).write(to: source)
        let info = BorderlessPrintInfo()
        info.paperSize = CGSize(width: 400, height: 400); info.orientation = .portrait
        info.leftMargin = 40; info.rightMargin = 30; info.bottomMargin = 60; info.topMargin = 10
        info.scalingFactor = 2
        for (selection, centered, redX, redWidth, greenX) in [
            (false, false, CGFloat(40), CGFloat(20), CGFloat(60)), // Paper x=0: the left 40pt are unprintable.
            (false, true, CGFloat(100), CGFloat(60), CGFloat(160)), // The 200pt-wide printout is centered on 400pt paper.
            (true, false, CGFloat(40), CGFloat(60), CGFloat(100)) // A selection begins at the printable top-left.
        ] {
            info.printSettings["SumraPrintCenter"] = centered
            let view = try ReaderPrinting.PDFPrintView(url: source, scaling: .actual, selection: selection)
            let output = temporary.url.appendingPathComponent("actual-\(selection)-\(centered).pdf")
            let document = try render(view, info: info, to: output)
            let colors = try colorCoverage(XCTUnwrap(document.page(at: 1)))
            XCTAssertEqual(colors.redBounds.minX, redX, accuracy: 1)
            XCTAssertEqual(colors.redBounds.size, CGSize(width: redWidth, height: 330))
            XCTAssertEqual(colors.greenBounds.minX, greenX, accuracy: 1)
            XCTAssertEqual(colors.greenBounds.size, CGSize(width: 140, height: 330))
            XCTAssertEqual(view.bounds.size, CGSize(width: 165, height: 165))
        }
    }

    func testPrintRotationUsesPaperOrientationAndAppliesExtraRotation() throws {
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("rotation.pdf")
        defer { withExtendedLifetime(temporary) {} }
        // /Rotate 90 gives a 200x100 landscape page whose red band is at the top.
        try fixture(widths: [100], rotations: [90]).write(to: source)
        let info = BorderlessPrintInfo()
        info.paperSize = CGSize(width: 300, height: 400); info.orientation = .portrait
        // A landscape printable area inside portrait paper must not decide
        // auto-rotation. Print.cpp first rotates the page back by 270 degrees.
        info.leftMargin = 20; info.rightMargin = 20; info.bottomMargin = 150; info.topMargin = 150
        for rotation in [0, 180] {
            info.printSettings["SumraPrintRotation"] = rotation
            let view = try ReaderPrinting.PDFPrintView(url: source, scaling: .fit)
            let output = temporary.url.appendingPathComponent("rotation-\(rotation).pdf")
            let pdf = try render(view, info: info, to: output), page = try XCTUnwrap(pdf.page(at: 1))
            let red = try colorCoverage(page).redBounds
            XCTAssertEqual(red.width, 15, accuracy: 1)
            XCTAssertEqual(red.height, 100, accuracy: 1)
            XCTAssertEqual(red.minX, rotation == 0 ? 125 : 160, accuracy: 1)
            XCTAssertTrue(PDFDocument(url: output)?.string?.contains("FIRST PRINT") == true)
        }
    }

    func testContentFitRetainsPageMarginsAndMovesInkInsideAsymmetricPrintableArea() throws {
        let temporary = try TemporaryDirectory(), source = temporary.url.appendingPathComponent("content.pdf")
        defer { withExtendedLifetime(temporary) {} }
        var paper = CGRect(x: 0, y: 0, width: 400, height: 400)
        let writer = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &paper, nil))
        writer.beginPDFPage(nil); writer.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        writer.fill(CGRect(x: 10, y: 100, width: 200, height: 200)); writer.endPDFPage(); writer.closePDF()
        let info = BorderlessPrintInfo()
        info.paperSize = paper.size; info.orientation = .portrait
        info.leftMargin = 80; info.rightMargin = 20; info.bottomMargin = 30; info.topMargin = 10
        for mode in [ReaderPrinting.Scaling.shrink, .fit] {
            let view = try ReaderPrinting.PDFPrintView(url: source, scaling: mode,
                contentBounds: [CGRect(x: 10, y: 100, width: 200, height: 200)])
            let output = temporary.url.appendingPathComponent("content-\(mode.rawValue).pdf")
            let pdf = try render(view, info: info, to: output)
            let red = try colorCoverage(XCTUnwrap(pdf.page(at: 1))).redBounds
            // The physical page limits fit to 1:1; its left content edge then
            // moves from x=10 to the printable x=80, without shrinking ink.
            XCTAssertEqual(red, CGRect(x: 80, y: 100, width: 200, height: 200))
        }
        XCTAssertThrowsError(try ReaderPrinting.PDFPrintView(url: source, contentBounds: []))
    }

    func testPrintAccessoryNotifiesSummaryAndPreviewWhenSettingsChange() throws {
        _ = NSApplication.shared
        let options = ReaderPrinting.Options(), info = NSPrintInfo()
        info.printSettings["SumraPrintScaling"] = ReaderPrinting.Scaling.shrink.rawValue
        info.printSettings["SumraPrintRotation"] = 0; info.printSettings["SumraPrintCenter"] = false
        options.representedObject = info
        _ = options.view
        let observer = PrintObserver()
        let paths = options.keyPathsForValuesAffectingPreview().union(["localizedSummaryItems"])
        for path in paths { options.addObserver(observer, forKeyPath: path, options: [], context: nil) }
        defer { for path in paths { options.removeObserver(observer, forKeyPath: path) } }
        for (key, setting, value) in [("scaling", "SumraPrintScaling", ReaderPrinting.Scaling.actual.rawValue as Any),
                                      ("rotation", "SumraPrintRotation", 90 as Any), ("center", "SumraPrintCenter", true as Any)] {
            observer.paths.removeAll()
            options.setValue(value, forKey: key)
            XCTAssertTrue(observer.paths.contains("localizedSummaryItems"))
            XCTAssertTrue(observer.paths.contains(key))
            XCTAssertEqual(info.printSettings[setting] as? NSNumber, value as? NSNumber)
        }
        let summaries = options.localizedSummaryItems()
        XCTAssertEqual(summaries[0][.itemDescription], L(ReaderPrinting.Scaling.actual.title))
        XCTAssertEqual(summaries[1][.itemDescription], "90°")
        XCTAssertEqual(summaries[2][.itemDescription], L("Yes"))
    }

    private final class BorderlessPrintInfo: NSPrintInfo {
        override var imageablePageBounds: NSRect { CGRect(origin: .zero, size: paperSize) }
    }

    private func requireMuPDF() throws {
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("MuPDF engine is required") }
    }

    private final class PrintObserver: NSObject {
        var paths = Set<String>()
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            MainActor.assumeIsolated { if let keyPath { paths.insert(keyPath) } }
        }
    }

    private func render(_ view: ReaderPrinting.PDFPrintView, info: NSPrintInfo, to output: URL) throws -> CGPDFDocument {
        _ = NSApplication.shared
        let previousOperation = NSPrintOperation.current, previousContext = NSGraphicsContext.current
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.printInfo = info
        NSPrintOperation.current = operation
        defer { NSGraphicsContext.current = previousContext; NSPrintOperation.current = previousOperation }
        var paper = CGRect(origin: .zero, size: info.paperSize)
        let writer = try XCTUnwrap(CGContext(output as CFURL, mediaBox: &paper, nil))
        writer.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: writer, flipped: false)
        let rect = view.rectForPage(1), placement = view.locationOfPrintRect(rect)
        // AppKit's documented pagination placement and separate panel scale.
        writer.translateBy(x: placement.x, y: placement.y)
        writer.scaleBy(x: info.scalingFactor, y: info.scalingFactor)
        view.draw(rect)
        writer.endPDFPage(); writer.closePDF()
        return try XCTUnwrap(CGPDFDocument(output as CFURL))
    }

    private func colorCoverage(_ page: CGPDFPage) throws -> (red: Int, green: Int, redBounds: CGRect, greenBounds: CGRect) {
        let box = page.getBoxRect(.mediaBox), width = Int(box.width), height = Int(box.height)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.drawPDFPage(page)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0, green = 0, redBounds = CGRect.null, greenBounds = CGRect.null
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let pixel = CGRect(x: (offset / 4) % width, y: (offset / 4) / width, width: 1, height: 1)
            if bytes[offset] > 200, bytes[offset + 1] < 80, bytes[offset + 2] < 80 { red += 1; redBounds = redBounds.union(pixel) }
            if bytes[offset] < 80, bytes[offset + 1] > 200, bytes[offset + 2] < 80 { green += 1; greenBounds = greenBounds.union(pixel) }
        }
        return (red, green, redBounds, greenBounds)
    }

    private func printInk(_ page: CGPDFPage) throws -> Set<Int> {
        let box = page.getBoxRect(.mediaBox), width = Int(box.width), height = Int(box.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.drawPDFPage(page)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Set((0..<width * height).filter { pixel in
            let offset = pixel * 4
            return bytes[offset] < 128 && bytes[offset + 1] < 128 && bytes[offset + 2] < 128
        })
    }

    private func fixture(widths: [Int], rotations: [Int]) -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(widths.indices.map { "\(4 + $0 * 2) 0 R" }.joined(separator: " "))] /Count \(widths.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
        for (index, width) in widths.enumerated() {
            let contents = "1 0 0 rg 40 20 30 200 re f 0 1 0 rg 70 20 \(width - 30) 200 re f " +
                "0 g BT /F1 7 Tf 1 0 0 1 75 100 Tm (\(index == 0 ? "FIRST PRINT" : "SECOND PRINT")) Tj ET\n"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [40 20 \(40 + width) 220] /Rotate \(rotations[index]) /Resources << /Font << /F1 3 0 R >> >> /Contents \(5 + index * 2) 0 R >>")
            objects.append("<< /Length \(contents.utf8.count) >>\nstream\n\(contents)endstream")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
#endif
