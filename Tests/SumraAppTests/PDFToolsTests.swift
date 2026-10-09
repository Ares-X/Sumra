#if os(macOS)
import AppKit
import CoreText
import ImageIO
import SumraCore
import PDFKit
import XCTest
@testable import Sumra

final class PDFToolsTests: XCTestCase {
    func testOutputBoundaryRecognizesSymbolicAndHardLinks() throws {
        let directory = try TemporaryDirectory()
        let source = directory.url.appendingPathComponent("input.pdf")
        let bytes = Data("Source must survive".utf8)
        try bytes.write(to: source)
        let hardLink = directory.url.appendingPathComponent("hard.pdf")
        let symbolicLink = directory.url.appendingPathComponent("symbolic.pdf")
        try FileManager.default.linkItem(at: source, to: hardLink)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        for alias in [source, hardLink, symbolicLink] {
            XCTAssertThrowsError(try NativePDFTools.validateDestination(source: source, destination: alias))
        }
        XCTAssertNoThrow(try NativePDFTools.validateDestination(source: source, destination: directory.url.appendingPathComponent("new.pdf")))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    private func document(_ count: Int = 3) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<count {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200 + index, height: 300), for: .mediaBox)
            document.insert(page, at: index)
        }
        return document
    }

    func testSumatraPageRangeSyntaxAndInvalidSelections() throws {
        XCTAssertEqual(try PDFTools.parsePages("1, 3-5,N,4,8-", count: 10), [0, 2, 3, 4, 7, 8, 9])
        for invalid in ["", "0", "11", "5-2", "-5", "1,,2", "2-3-4"] {
            XCTAssertThrowsError(try PDFTools.parsePages(invalid, count: 10), invalid)
        }
        XCTAssertThrowsError(try PDFTools.parsePages("1", count: 0))
    }

    @MainActor
    func testOutlineExportPreservesGroupsAndNativeDestinations() async throws {
        try requireMuPDF()
        // PDFKit's RemoteGoTo serializer can emit only /S with no /F or /D.
        // Use actual PDF destinations so this tests the reader, not that writer.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 201 300] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 202 300] >>",
            "<< /Type /Outlines /First 7 0 R /Last 9 0 R /Count 3 >>",
            "<< /Title (Part) /Parent 6 0 R /First 8 0 R /Last 8 0 R /Count 1 /Next 9 0 R >>",
            "<< /Title (Chapter) /Parent 7 0 R /Dest [5 0 R /XYZ 20 200 1.5] >>",
            "<< /Title (Other document) /Parent 6 0 R /Prev 7 0 R /A << /S /GoToR /F (/tmp/other.pdf) /D [1 /XYZ 0 0 null] >> >>",
            "<< /Title (Example) >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R /Info 10 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let directory = try outputDirectory(), url = directory.appendingPathComponent("outline.pdf")
        try bytes.write(to: url)
        let pages = try Pages(url, format: .pdf)
        let entries = try await pages.pdfOutline()
        XCTAssertEqual(entries.map(\.title), ["Part", "Chapter", "Other document"])
        XCTAssertEqual(entries.map(\.depth), [0, 1, 0])
        XCTAssertNil(entries[0].page)
        XCTAssertEqual(entries[1].page, 2)
        XCTAssertEqual(entries[1].x, 20)
        XCTAssertEqual(entries[1].y, 200)
        XCTAssertEqual(entries[1].zoom, 1.5)
        XCTAssertEqual(entries[2].page, 1)
        XCTAssertEqual(entries[2].url, URL(fileURLWithPath: "/tmp/other.pdf").absoluteString)
        let native = try NativeFile(url, engine: .mupdf)
        XCTAssertEqual(try native.metadata()["Title"], "Example")
        let contents = try native.outline()
        XCTAssertEqual(contents.map(\.page), [nil, 2, nil])
        XCTAssertTrue(contents[0].target.isEmpty)
        XCTAssertTrue(contents[2].target.hasPrefix("file:"))
        XCTAssertNil(try native.pdfResolveDestination(contents[2].target))
        let state = ReaderState()
        state.outline = contents; state.page = 2
        XCTAssertEqual(state.currentContentsIndex, 1, "Only local destinations follow this document's reading page")
        XCTAssertFalse(try XCTUnwrap(native.pdfInfo()).dirty)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFontInventoryFindsUsedFontsWithoutDuplicatingPages() throws {
        try requireMuPDF()
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let string = NSAttributedString(string: "Font inventory fixture", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string)
        for _ in 0..<2 {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 300)
            CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF()
        let directory = try outputDirectory(), source = directory.appendingPathComponent("fonts.pdf")
        try (bytes as Data).write(to: source)
        let report = try NativePDFTools.resourceReport(source: source)
        XCTAssertTrue(report.contains("Fonts (1)"))
        XCTAssertTrue(report.contains("Helvetica"))
        XCTAssertEqual(try NativeFile(source, engine: .mupdf).count, 2)
    }

    func testImageConversionUsesActualDPIAndVariablePageSizes() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let converted = try XCTUnwrap(PDFDocument(data: PDFTools.images([image, image], dpi: 100)))
        XCTAssertEqual(converted.pageCount, 2)
        XCTAssertEqual(try XCTUnwrap(converted.page(at: 0)).bounds(for: .mediaBox).width, 144, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(converted.page(at: 0)).bounds(for: .mediaBox).height, 72, accuracy: 0.01)
        XCTAssertThrowsError(try PDFTools.images([image], dpi: 0))
        let streamed = try XCTUnwrap(PDFDocument(data: PDFTools.images(count: 3, dpi: 100) { _ in image }))
        XCTAssertEqual(streamed.pageCount, 3)
        XCTAssertEqual(try XCTUnwrap(streamed.page(at: 2)).bounds(for: .mediaBox).width, 144, accuracy: 0.01)
        XCTAssertThrowsError(try PDFTools.images(count: 1) { _ in throw PDFTools.Failure("Unreadable frame") })
        let directory = try outputDirectory(), output = directory.appendingPathComponent("images.pdf")
        let sizes = [CGSize(width: 144, height: 72), CGSize(width: 72, height: 36)]
        try PDFTools.writeImages(count: 2, to: output, pageSize: { sizes[$0] }) { _ in image }
        let file = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(file.numberOfPages, 2)
        for (index, size) in sizes.enumerated() {
            XCTAssertEqual(try XCTUnwrap(file.page(at: index + 1)).getBoxRect(.mediaBox).size, size)
        }
        XCTAssertThrowsError(try PDFTools.writeImages(count: 1, to: directory) { _ in image })
    }

    private func requireMuPDF() throws {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build MuPDF before PDF integration tests") }
    }

    private func outputDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor
    func testRenderedImagePreservesContentPhysicalSizeAndDPIAcrossFormats() async throws {
        try requireMuPDF()
        let bytes = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 144, height: 72)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(box)
        context.endPDFPage(); context.closePDF()
        let directory = try outputDirectory(), source = directory.appendingPathComponent("image.pdf")
        try (bytes as Data).write(to: source)
        let pages = try Pages(source, format: .pdf)
        let formats: [(NSBitmapImageRep.FileType, String)] = [(.png, "public.png"), (.jpeg, "public.jpeg"), (.tiff, "public.tiff"), (.bmp, "com.microsoft.bmp")]
        for (format, identifier) in formats {
            let data = try await pages.pdfRenderedImage(page: 0, dpi: 144, type: format, rotation: 0)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(try XCTUnwrap(CGImageSourceGetType(decoded)) as String, identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            XCTAssertEqual(image.width, 288); XCTAssertEqual(image.height, 144)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.size.width, 144, accuracy: 1); XCTAssertEqual(bitmap.size.height, 72, accuracy: 1)
            // colorAt returns a calibrated NSColor even for an sRGB bitmap;
            // inspect encoded RGB samples rather than applying a second profile.
            XCTAssertEqual(bitmap.bitsPerSample, 8)
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel, atX: 144, y: 72)
            XCTAssertGreaterThan(pixel[0], 230); XCTAssertLessThan(pixel[1], 26); XCTAssertLessThan(pixel[2], 26)
        }
        let rotatedBytes = try await pages.pdfRenderedImage(page: 0, dpi: 144, type: .png, rotation: 90)
        let rotated = try XCTUnwrap(NSBitmapImageRep(data: rotatedBytes))
        XCTAssertEqual(rotated.pixelsWide, 144); XCTAssertEqual(rotated.pixelsHigh, 288)
        for (page, dpi) in [(-1, 72.0), (0, 0), (0, Double.nan), (0, Double.greatestFiniteMagnitude)] {
            do { _ = try await pages.pdfRenderedImage(page: page, dpi: dpi, type: .png, rotation: 0); XCTFail("Invalid page or DPI accepted") }
            catch { }
        }
        let huge = PDFDocument(), hugePage = PDFPage()
        hugePage.setBounds(CGRect(x: 0, y: 0, width: Double(Int32.max) + 1, height: 1), for: .mediaBox)
        huge.insert(hugePage, at: 0)
        let hugeURL = directory.appendingPathComponent("huge.pdf")
        try XCTUnwrap(huge.dataRepresentation()).write(to: hugeURL)
        let hugePages = try Pages(hugeURL, format: .pdf)
        do { _ = try await hugePages.pdfRenderedImage(page: 0, dpi: 72, type: .png, rotation: 0); XCTFail("Unrepresentable native dimensions accepted") }
        catch { }
        let wide = PDFDocument(), widePage = PDFPage()
        widePage.setBounds(CGRect(x: 0, y: 0, width: 17_000, height: 1), for: .mediaBox)
        wide.insert(widePage, at: 0)
        let wideURL = directory.appendingPathComponent("wide.pdf")
        try XCTUnwrap(wide.dataRepresentation()).write(to: wideURL)
        let widePages = try Pages(wideURL, format: .pdf)
        let wideBytes = try await widePages.pdfRenderedImage(page: 0, dpi: 72, type: .png, rotation: 0)
        let wideBitmap = try XCTUnwrap(NSBitmapImageRep(data: wideBytes))
        XCTAssertEqual(wideBitmap.pixelsWide, 17_000)
        XCTAssertEqual(wideBitmap.pixelsHigh, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes as Data)
    }

    @MainActor
    func testPageImageExportUsesSelectedPageNumbersDPIAndFilenameFormat() async throws {
        try requireMuPDF()
        let directory = try outputDirectory(), source = directory.appendingPathComponent("source.pdf")
        let original = try XCTUnwrap(document().dataRepresentation())
        try original.write(to: source)
        let pdf = try Pages(source, format: .pdf)
        let pages = try PDFTools.parsePages("1,3", count: 3)
        let destinations = try PDFTools.imageDestinations(pages: pages, template: directory.appendingPathComponent("export.png"), sources: [source])
        for (page, destination) in zip(pages, destinations) {
            let image = try await pdf.pdfRenderedImage(page: page, dpi: 144, type: PDFTools.imageType(for: destination), rotation: 0)
            try image.write(to: destination, options: .atomic)
        }
        for (page, width) in [(1, 400), (3, 404)] {
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent("export-\(page).png"))))
            XCTAssertEqual(image.pixelsWide, width); XCTAssertEqual(image.pixelsHigh, 600)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("export-2.png").path))
        let jpegDestinations = try PDFTools.imageDestinations(pages: pages, template: directory.appendingPathComponent("page-%d.JpG"), sources: [source])
        for (page, destination) in zip(pages, jpegDestinations) {
            let image = try await pdf.pdfRenderedImage(page: page, dpi: 72, type: PDFTools.imageType(for: destination), rotation: 0)
            try image.write(to: destination, options: .atomic)
        }
        for page in [1, 3] {
            let data = try Data(contentsOf: directory.appendingPathComponent("page-\(page).JpG"))
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(try XCTUnwrap(CGImageSourceGetType(image)) as String, "public.jpeg")
        }
        let single = try PDFTools.imageDestinations(pages: [1], template: directory.appendingPathComponent("second"), sources: [source])
        XCTAssertEqual(single.map(\.lastPathComponent), ["second.png"])
        let singleImage = try await pdf.pdfRenderedImage(page: 1, dpi: 72, type: PDFTools.imageType(for: single[0]), rotation: 0)
        try singleImage.write(to: single[0], options: .atomic)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: single[0])))
        XCTAssertEqual(image.pixelsWide, 201); XCTAssertEqual(image.pixelsHigh, 300)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPageImageOutputPlanRejectsInputAndOutputAliases() throws {
        let directory = try outputDirectory(), source = directory.appendingPathComponent("source.pdf")
        let original = try XCTUnwrap(document().dataRepresentation()), prior = Data("preserve this input".utf8)
        try original.write(to: source)
        let first = directory.appendingPathComponent("export-1.png"), last = directory.appendingPathComponent("export-3.png")
        try prior.write(to: last)
        let template = directory.appendingPathComponent("export.png")
        XCTAssertThrowsError(try PDFTools.imageDestinations(pages: [0, 2], template: template, sources: [source, last]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path)); XCTAssertEqual(try Data(contentsOf: last), prior)
        try FileManager.default.removeItem(at: last)
        try FileManager.default.createSymbolicLink(at: last, withDestinationURL: source)
        XCTAssertThrowsError(try PDFTools.imageDestinations(pages: [0, 2], template: template, sources: [source]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path)); XCTAssertEqual(try Data(contentsOf: source), original)
        try FileManager.default.removeItem(at: last)
        let shared = directory.appendingPathComponent("shared.png")
        try prior.write(to: shared)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: shared)
        try FileManager.default.createSymbolicLink(at: last, withDestinationURL: shared)
        XCTAssertThrowsError(try PDFTools.imageDestinations(pages: [0, 2], template: template, sources: [source]))
        XCTAssertEqual(try Data(contentsOf: shared), prior); XCTAssertEqual(try Data(contentsOf: source), original)
    }

}
#endif
