#if os(macOS)
import AppKit
import ImageIO
import PDFKit
import SumraCore
import XCTest
@testable import Sumra

final class ReaderImageTests: XCTestCase {
    func testMarkupUsesOnlySiblingCoverForHomeThumbnailInBothReaders() async throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "useFixedPageUI")
        defer { defaults.set(previous, forKey: "useFixedPageUI") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for paged in [false, true] {
            defaults.set(paged, forKey: "useFixedPageUI")
            for ext in ["md", "html"] {
                let url = directory.url.appendingPathComponent("Book.\(ext)")
                try "A readable document".write(to: url, atomically: true, encoding: .utf8)
                let preview = try await ReadingDocument.thumbnail(url, size: CGSize(width: 136, height: 168))
                XCTAssertNil(preview, "Home previews must not load a whole markup document in either renderer")
                let cover = url.deletingPathExtension().appendingPathExtension("png")
                try ReaderImages.encoded(fixture(), extension: "png").write(to: cover)
                let covered = try await ReadingDocument.thumbnail(url, size: CGSize(width: 136, height: 168))
                let image = try XCTUnwrap(covered)
                XCTAssertEqual(Double(image.width) / Double(image.height), 2, accuracy: 0.02)
                try FileManager.default.removeItem(at: cover)
            }
        }
    }

    func testAutomaticLargeMarkdownHomeThumbnailSkipsBookLayout() async throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "useFixedPageUI")
        defaults.set(false, forKey: "useFixedPageUI")
        defer { defaults.set(previous, forKey: "useFixedPageUI") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("Large.md")
        let paragraph = "A repeated paragraph in a large book.\n\n"
        let text = String(repeating: paragraph, count: MarkdownRenderer.largeDocumentThreshold / paragraph.utf8.count + 1)
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try MarkdownRenderer.automatic.effective(for: url), .paged)
        let preview = try await ReadingDocument.thumbnail(url, size: CGSize(width: 136, height: 168))
        XCTAssertNil(preview)
    }

    @MainActor
    func testPDFWithMarkupExtensionStillHasPageThumbnail() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pdf = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: NSImage(cgImage: try fixture(), size: CGSize(width: 80, height: 40))))
        pdf.insert(page, at: 0)
        let data = try XCTUnwrap(pdf.dataRepresentation())
        for ext in ["md", "html"] {
            let url = directory.url.appendingPathComponent("ActuallyPDF.\(ext)")
            try data.write(to: url)
            let preview = try await ReadingDocument.thumbnail(url, size: CGSize(width: 136, height: 168))
            XCTAssertNotNil(preview)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testEPUBThumbnailUsesDeclaredCoverAndThenSiblingCover() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let content = directory.url.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("OPS/images"), withIntermediateDirectories: true)
        let cover = try ReaderImages.encoded(fixture(), extension: "png")
        try cover.write(to: content.appendingPathComponent("OPS/images/cover art.png"))
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
          <rootfile full-path="OPS/package%20one.opf"/>
        </rootfiles></container>
        """.utf8).write(to: content.appendingPathComponent("META-INF/container.xml"))
        for version in [2, 3] {
            let metadata = version == 2 ? "<p:meta name=\"cover\" content=\"art\"/>" : ""
            let properties = version == 3 ? " properties=\"other cover-image\"" : ""
            try Data("""
            <p:package xmlns:p="http://www.idpf.org/2007/opf"><p:metadata>\(metadata)</p:metadata><p:manifest>
              <p:item id="chapter" media-type="application/xhtml+xml" href="chapter.xhtml"/>
              <p:item id="art" media-type="image/png" href="images/cover%20art.png"\(properties)/>
            </p:manifest></p:package>
            """.utf8).write(to: content.appendingPathComponent("OPS/package one.opf"))
            let file = directory.url.appendingPathComponent("Book\(version).epub")
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = content; zip.arguments = ["-q", "-r", file.path, "."]
            try runSumraProcess(zip); XCTAssertEqual(zip.terminationStatus, 0)
            XCTAssertEqual(try ReadingDocument.epubCover(file), cover)
            let rendered = try await ReadingDocument.thumbnail(file, size: CGSize(width: 136, height: 168))
            let image = try XCTUnwrap(rendered)
            XCTAssertEqual(Double(image.width) / Double(image.height), 2, accuracy: 0.02)
            let sibling = file.deletingPathExtension().appendingPathExtension("png")
            try ReaderImages.encoded(ReaderImages.resized(fixture(), width: 40, height: 80), extension: "png").write(to: sibling)
            let sidecar = try await ReadingDocument.thumbnail(file, size: CGSize(width: 136, height: 168))
            let preferred = try XCTUnwrap(sidecar)
            XCTAssertEqual(Double(preferred.width) / Double(preferred.height), 0.5, accuracy: 0.02)
        }
    }

    func testTextAndImageThumbnailsDoNotChangeReadingHistoryOrSource() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let text = directory.url.appendingPathComponent("Text.txt")
        let picture = directory.url.appendingPathComponent("Picture.png")
        let content = Data("A document preview\nSecond line".utf8)
        try content.write(to: text)
        let png = try ReaderImages.encoded(fixture(), extension: "png")
        try png.write(to: picture)
        let history = UserDefaults.standard.data(forKey: "documentOpenHistory")
        for url in [text, picture] {
            let key = "position:" + url.path
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
            let preview = try await ReadingDocument.thumbnail(url, size: CGSize(width: 136, height: 168))
            XCTAssertNotNil(preview)
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
        }
        XCTAssertEqual(UserDefaults.standard.data(forKey: "documentOpenHistory"), history)
        XCTAssertEqual(try Data(contentsOf: text), content)
        XCTAssertEqual(try Data(contentsOf: picture), png)
    }

    @MainActor
    func testImagePDFKeepsCompressedJPEGFramesAndOriginalResolution() async throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Build MuPDF before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let jpeg = try ReaderImages.encoded(fixture(), extension: "jpg")
        let first = directory.url.appendingPathComponent("First.jpg"), frames = directory.url.appendingPathComponent("Frames.tiff")
        try jpeg.write(to: first)
        let bytes = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes as CFMutableData, "public.tiff" as CFString, 2, nil))
        let density = [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary
        CGImageDestinationAddImage(encoder, try ReaderImages.resized(fixture(), width: 40, height: 20), density)
        CGImageDestinationAddImage(encoder, try ReaderImages.resized(fixture(), width: 20, height: 30), density)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        try (bytes as Data).write(to: frames)
        for (source, sizes) in [(first, [CGSize(width: 80, height: 40)]),
                                (frames, [CGSize(width: 40, height: 20), CGSize(width: 20, height: 30)])] {
            let output = source.deletingPathExtension().appendingPathExtension("pdf")
            let pages = try Pages(source, format: .image)
            try await pages.exportPDF(to: output)
            if source == first { XCTAssertNotNil(try Data(contentsOf: output).range(of: jpeg)) }
            let pdf = try NativeFile(output, engine: .mupdf)
            XCTAssertEqual(pdf.count, sizes.count)
            for (page, size) in sizes.enumerated() {
                XCTAssertEqual(try pdf.imageDimensions(page), size)
                XCTAssertEqual(try pdf.bounds(page)?.size, size)
            }
        }
        XCTAssertEqual(try Data(contentsOf: first), jpeg)
        XCTAssertEqual(try Data(contentsOf: frames), bytes as Data)
    }

    @MainActor
    func testImagePDFPreservesEncryptionAndFailedOutputBoundaries() async throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Build MuPDF before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = directory.url.appendingPathComponent("Image.png"), output = directory.url.appendingPathComponent("Images.pdf")
        let snapshot = directory.url.appendingPathComponent("snapshot.pdf")
        let bytes = try ReaderImages.encoded(fixture(), extension: "png")
        try bytes.write(to: source)
        let pages = try Pages(source, format: .image)
        try await pages.exportPDF(to: snapshot)
        try NativePDFTools.encrypt(source: snapshot, destination: output, ownerPassword: "owner-secret", userPassword: "reader-secret")
        let protected = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(protected.isEncrypted); XCTAssertTrue(protected.isLocked)
        XCTAssertTrue(protected.unlock(withPassword: "reader-secret"))
        XCTAssertEqual(protected.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 80, height: 40))
        let previous = try Data(contentsOf: output)
        XCTAssertThrowsError(try NativePDFTools.encrypt(source: directory.url.appendingPathComponent("Missing.pdf"),
            destination: output, ownerPassword: "owner-secret"))
        XCTAssertEqual(try Data(contentsOf: output), previous)
        do {
            try await pages.exportPDF(to: output, selectedPages: [1])
            XCTFail("An invalid page must not replace the existing output")
        } catch is ReadError {}
        XCTAssertEqual(try Data(contentsOf: output), previous)
        do {
            try await pages.exportPDF(to: source)
            XCTFail("Image conversion must not overwrite its source")
        } catch is ReadError {}
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).contains { $0.hasPrefix(".Sumra-export-") })
    }

    func testImagePDFUsesFrameDPIAndPreservesDensityThroughPixelEdits() async throws {
        let image = try fixture(), bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes as CFMutableData, "public.tiff" as CFString, 2, nil))
        for dpi in [144, 288] {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let directory = try TemporaryDirectory(), file = directory.url.appendingPathComponent("Frames.tiff")
        defer { withExtendedLifetime(directory) {} }
        try (bytes as Data).write(to: file)
        let pages = try Pages(file, format: .image)
        let first = try await pages.editableImage(0), second = try await pages.editableImage(1)
        XCTAssertEqual(first.dpi, 144, accuracy: 0.01); XCTAssertEqual(second.dpi, 288, accuracy: 0.01)
        func size(_ image: CGImage, dpi: Double, original: (data: Data, filename: String)? = nil) throws -> CGSize {
            let data = try ReaderImages.dataForSave(image, original: original, extension: "pdf", dpi: dpi)
            return try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)).bounds(for: .mediaBox).size
        }
        XCTAssertEqual(try size(first.image, dpi: first.dpi, original: first.original), CGSize(width: 40, height: 20))
        XCTAssertEqual(try size(second.image, dpi: second.dpi, original: second.original), CGSize(width: 20, height: 10))
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
        let rotated = try RasterLayout.image(first.image, bounds: bounds, crop: nil, rotation: 90)
        XCTAssertEqual(try size(rotated, dpi: first.dpi), CGSize(width: 20, height: 40))
        let cropped = try RasterLayout.image(first.image, bounds: bounds, crop: CGRect(x: 40, y: 0, width: 40, height: 40), rotation: 0)
        XCTAssertEqual(try size(cropped, dpi: first.dpi), CGSize(width: 20, height: 20))
        let resized = try ReaderImages.resized(cropped, width: 20, height: 30)
        XCTAssertEqual(try size(resized, dpi: first.dpi), CGSize(width: 10, height: 15))
        XCTAssertEqual(try Data(contentsOf: file), bytes as Data)
    }
    func testMissingOrInvalidImageDensityFallsBackTo72DPI() throws {
        XCTAssertEqual(ReaderImages.imageDPI(nil), 72)
        let invalid: [Any] = [0.0, -1.0, Double.nan, Double.infinity, "bad"]
        for value in invalid {
            XCTAssertEqual(ReaderImages.imageDPI([kCGImagePropertyDPIWidth: value]), 72)
        }
        XCTAssertEqual(ReaderImages.imageDPI([kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 288]), 144)
        let image = try fixture(), png = try ReaderImages.encoded(image, extension: "png")
        let data = try ReaderImages.dataForSave(image, original: (png, "Misnamed.pdf"), extension: "pdf")
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)).bounds(for: .mediaBox).size, CGSize(width: 80, height: 40))
    }
    @MainActor
    func testNativePDFImageConversionKeepsPhysicalPageDimensions() async throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Build MuPDF before PDF integration tests") }
        let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 100), for: .mediaBox)
        let source = PDFDocument(); source.insert(page, at: 0)
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("Source.pdf")
        try XCTUnwrap(source.dataRepresentation()).write(to: url)
        let reading = try ReadingDocument.open(url)
        let input = try await ReaderImages.image(reading, page: 0)
        XCTAssertEqual(input.dpi, 144)
        let data = try ReaderImages.dataForSave(input.image, original: nil, extension: "pdf", dpi: input.dpi)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)).bounds(for: .mediaBox).size, CGSize(width: 200, height: 100))
    }
    func testImageCollectionPDFKeepsCompressedJPEGAndOriginalPixels() async throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let folder = directory.url.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let jpeg = try ReaderImages.encoded(fixture(), extension: "jpg")
        let png = try ReaderImages.encoded(ReaderImages.resized(fixture(), width: 40, height: 20), extension: "png")
        try jpeg.write(to: folder.appendingPathComponent("1.jpg")); try png.write(to: folder.appendingPathComponent("2.png"))
        let pages = try Pages(folder, format: .comic), output = directory.url.appendingPathComponent("Images.pdf")
        try await pages.exportPDF(to: output)
        XCTAssertNotNil(try Data(contentsOf: output).range(of: jpeg))
        let pdf = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(pdf.count, 2)
        XCTAssertEqual(try pdf.imageDimensions(0), CGSize(width: 80, height: 40))
        XCTAssertEqual(try pdf.imageDimensions(1), CGSize(width: 40, height: 20))
        let selected = directory.url.appendingPathComponent("Selected.pdf")
        try await pages.exportPDF(to: selected, selectedPages: [1, 0])
        let selectedPDF = try NativeFile(selected, engine: .mupdf)
        XCTAssertEqual(selectedPDF.count, 2)
        XCTAssertEqual(try selectedPDF.imageDimensions(0), CGSize(width: 40, height: 20))
        XCTAssertEqual(try selectedPDF.imageDimensions(1), CGSize(width: 80, height: 40))
        XCTAssertNotNil(try Data(contentsOf: selected).range(of: jpeg))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("1.jpg")), jpeg)
    }
    func testSelectedImageFramesExportOriginalSizeInRequestedOrder() async throws {
        let image = try fixture(), bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes as CFMutableData, "public.tiff" as CFString, 2, nil))
        let density = [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary
        CGImageDestinationAddImage(destination, image, density)
        CGImageDestinationAddImage(destination, try ReaderImages.resized(image, width: 40, height: 60), density)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let directory = try TemporaryDirectory(), file = directory.url.appendingPathComponent("Frames.tiff")
        defer { withExtendedLifetime(directory) {} }
        try (bytes as Data).write(to: file)
        let pages = try Pages(file, format: .image), output = directory.url.appendingPathComponent("Selected.pdf")
        try await pages.exportPDF(to: output, selectedPages: [1, 0])
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 40, height: 60))
        XCTAssertEqual(pdf.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 80, height: 40))
        XCTAssertEqual(try Data(contentsOf: file), bytes as Data)
    }
    func testEmbeddedJPEGKeepsOriginalBytesAndPageTransformsUseCorrectPixels() throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("MuPDF engine must be built before native integration tests") }
        let jpeg = try ReaderImages.encoded(fixture(), extension: "jpg")
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for (name, matrix, size) in [("original", "80 0 0 40 0 0", CGSize(width: 80, height: 40)),
                                     ("mirror", "-80 0 0 40 80 0", CGSize(width: 80, height: 40)),
                                     ("rotate", "0 80 -40 0 40 0", CGSize(width: 40, height: 80))] {
            let url = directory.url.appendingPathComponent(name + ".pdf")
            try embeddedPDF(jpeg, matrix: matrix, size: size).write(to: url)
            let source = try NativeFile(url, engine: .mupdf)
            let data = try XCTUnwrap(source.embeddedImage(0, at: CGPoint(x: size.width/2, y: size.height/2)))
            if name == "original" { XCTAssertEqual(data, jpeg) }
            else { XCTAssertEqual(try ReaderImages.embeddedType(data).identifier, "public.png") }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, Int(size.width)); XCTAssertEqual(bitmap.pixelsHigh, Int(size.height))
            if name != "original" {
                let blue = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(blue.blueComponent, 0.9); XCTAssertLessThan(blue.redComponent, 0.1)
            }
            let bounds = try XCTUnwrap(source.imageBounds(0).first)
            XCTAssertEqual(bounds.size, size)
        }
        let masked = directory.url.appendingPathComponent("mask.pdf")
        try embeddedPDF(jpeg, matrix: "80 0 0 40 0 0", size: CGSize(width: 80, height: 40), mask: Data([0])).write(to: masked)
        let maskedSource = try NativeFile(masked, engine: .mupdf)
        let maskedBytes = try XCTUnwrap(maskedSource.embeddedImage(0, at: CGPoint(x: 20, y: 20)))
        let white = try XCTUnwrap(NSBitmapImageRep(data: maskedBytes)?.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(white.redComponent, 0.99); XCTAssertGreaterThan(white.greenComponent, 0.99); XCTAssertGreaterThan(white.blueComponent, 0.99)
    }
    func testUnmodifiedOriginalRetainsBytesAndMetadata() throws {
        let image = try fixture(), png = try ReaderImages.encoded(image, extension: "png")
        let original = png + Data("original metadata".utf8)
        XCTAssertEqual(try ReaderImages.dataForSave(image, original: (original, "Original.PNG"), extension: "png"), original)
        XCTAssertTrue(ReaderImages.matchingExtension("jpg", "JPEG"))
        XCTAssertTrue(ReaderImages.matchingExtension("tiff", "TIF"))
        let converted = try ReaderImages.dataForSave(image, original: (original, "Original.png"), extension: "jpg")
        XCTAssertNotEqual(converted, original)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(converted as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertEqual(try ReaderImages.embeddedType(converted).identifier, "public.jpeg")
        XCTAssertEqual(try ReaderImages.embeddedType(png).identifier, "public.png")
    }

    @MainActor
    func testNativePDFImageToolsReadLiveEditsAndRespectCopyPermission() async throws {
        guard FileManager.default.fileExists(atPath: try NativeFile.libraryURL(for: .mupdf).path) else {
            throw XCTSkip("MuPDF engine must be built before native integration tests")
        }
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("Image.pdf")
        defer { withExtendedLifetime(directory) {} }
        let jpeg = try ReaderImages.encoded(fixture(), extension: "jpg")
        let bytes = embeddedPDF(jpeg, matrix: "80 0 0 40 0 0", size: CGSize(width: 80, height: 40))
        try bytes.write(to: source)
        let pages = try Pages(source, format: .pdf), reading = ReadingDocument(url: source, content: .pages(pages))
        let extracted = try await pages.embeddedImage(0, at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(extracted, jpeg)
        let before = try await ReaderImages.image(reading, page: 0)
        XCTAssertEqual(before.dpi, 144); XCTAssertNil(before.original)
        try await pages.pdfSetEditing(true)
        _ = try await pages.pdfCreateAnnotation(page: 0, type: "Square", bounds: CGRect(x: 5, y: 5, width: 20, height: 20),
            edits: [.color(SIMD3(1, 0, 0), interior: true)])
        let after = try await ReaderImages.image(reading, page: 0)
        func pixels(_ image: CGImage) throws -> Data {
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        XCTAssertNotEqual(try pixels(before.image), try pixels(after.image))
        try await pages.pdfUndo()
        let undone = try await ReaderImages.image(reading, page: 0)
        XCTAssertEqual(try pixels(before.image), try pixels(undone.image))

        let protected = directory.url.appendingPathComponent("NoCopy.pdf")
        try NativePDFTools.encrypt(source: source, destination: protected, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        let restricted = try Pages(protected, format: .pdf, password: "reader")
        do {
            _ = try await ReaderImages.image(ReadingDocument(url: protected, content: .pages(restricted)), page: 0)
            XCTFail("Image tools must not extract a copy-restricted PDF")
        } catch is ReadError {}
        let unavailable = try await restricted.embeddedImage(0, at: CGPoint(x: 10, y: 10))
        XCTAssertNil(unavailable)
        let display = try await restricted.image(0, width: 80)
        XCTAssertEqual(display.width, 80, "Copy restrictions do not prevent reading")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testResizeAndCropProduceExactPixelDimensionsWithoutChangingInput() throws {
        let input = try fixture()
        let crop = try RasterLayout.image(input, bounds: CGRect(x: 0, y: 0, width: 80, height: 40), crop: CGRect(x: 40, y: 0, width: 40, height: 40), rotation: 0)
        let resized = try ReaderImages.resized(crop, width: 20, height: 30)
        XCTAssertEqual(resized.width, 20); XCTAssertEqual(resized.height, 30)
        XCTAssertEqual(input.width, 80); XCTAssertEqual(input.height, 40)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: resized).colorAt(x: 10, y: 15)?.usingColorSpace(.sRGB))
        let original = try XCTUnwrap(NSBitmapImageRep(cgImage: input).colorAt(x: 60, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, original.redComponent, accuracy: 1.0 / 255)
        XCTAssertEqual(color.greenComponent, original.greenComponent, accuracy: 1.0 / 255)
        XCTAssertEqual(color.blueComponent, original.blueComponent, accuracy: 1.0 / 255)
        XCTAssertThrowsError(try ReaderImages.resized(input, width: 0, height: 20))
        XCTAssertThrowsError(try ReaderImages.resized(input, width: Int.max, height: 20))
    }

    func testImageEncodersPreserveDimensionsAndPDFIsReadable() throws {
        let input = try fixture()
        for ext in ["png", "jpg", "tiff", "bmp", "gif"] {
            let data = try ReaderImages.encoded(input, extension: ext)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, input.width); XCTAssertEqual(image.height, input.height)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: ReaderImages.encoded(input, extension: "pdf")))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 80, height: 40))
        let crop = try RasterLayout.image(input, bounds: CGRect(x: 0, y: 0, width: 80, height: 40), crop: CGRect(x: 40, y: 0, width: 40, height: 40), rotation: 0)
        let resized = try ReaderImages.resized(crop, width: 20, height: 30)
        let editedPDF = try XCTUnwrap(PDFDocument(data: ReaderImages.dataForSave(resized, original: nil, extension: "pdf")))
        XCTAssertEqual(editedPDF.pageCount, 1)
        XCTAssertEqual(editedPDF.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 20, height: 30))
        XCTAssertThrowsError(try ReaderImages.encoded(input, extension: "exe"))
    }

    func testLensHTMLUsesOnlyBase64Image() throws {
        let bytes = Data([0, 255, 42, 60, 47, 115, 99, 114, 105, 112, 116, 62])
        let html = ReaderImages.lensHTML(bytes)
        let token = try XCTUnwrap(html.components(separatedBy: "atob('").dropFirst().first?.components(separatedBy: "')").first)
        XCTAssertEqual(Data(base64Encoded: token), bytes)
        XCTAssertTrue(html.contains("multipart/form-data"))
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        return try XCTUnwrap(context.makeImage())
    }

    private func embeddedPDF(_ jpeg: Data, matrix: String, size: CGSize, mask: Data? = nil) -> Data {
        func stream(_ data: Data, attributes: String = "") -> Data {
            Data("<< /Length \(data.count) \(attributes) >>\nstream\n".utf8) + data + Data("\nendstream".utf8)
        }
        var objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(size.width) \(size.height)] /Resources << /XObject << /Im 5 0 R >> >> /Contents 4 0 R >>".utf8),
            stream(Data("q \(matrix) cm /Im Do Q".utf8)),
            stream(jpeg, attributes: "/Type /XObject /Subtype /Image /Width 80 /Height 40 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode \(mask == nil ? "" : "/SMask 6 0 R")")]
        if let mask { objects.append(stream(mask, attributes: "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8")) }
        var output = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(output.count)
            output += Data("\(index+1) 0 obj\n".utf8) + object + Data("\nendobj\n".utf8)
        }
        let xref = output.count
        output += Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8)
        for offset in offsets { output += Data(String(format: "%010d 00000 n \n", offset).utf8) }
        output += Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return output
    }
}
#endif
