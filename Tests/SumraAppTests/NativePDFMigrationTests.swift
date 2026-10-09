#if os(macOS)
import AppKit
import Combine
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativePDFMigrationTests: XCTestCase {
    func testCursorUsesPhysicalPageCoordinatesAfterPDFAndViewerRotation() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("cursor.pdf")
        try fixture(rotation: 90).write(to: source)
        let pages = try Pages(source, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: source, content: .pages(pages)); state.count = 2
        state.flow = "paged"; state.spread = false; state.fit = "page"; state.rotation = 90
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.automaticLayout = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            state.windowClosed(); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        let deadline = Date().addingTimeInterval(5)
        while (state.nativePDFCursorPosition == nil || !RasterReader.pageIsRendered(in: state.readerFocusView,
                   pages: pages, location: .init(page: 0)))
            && state.error == nil && Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let canvas = try XCTUnwrap(state.readerFocusView), cursor = try XCTUnwrap(state.nativePDFCursorPosition)
        XCTAssertGreaterThan(canvas.bounds.width, 0); XCTAssertGreaterThan(canvas.bounds.height, 0)
        // /CropBox [10 20 210 320], /Rotate 90 and /UserUnit 2 put raw
        // PDF (70,250) at MuPDF (460,120) on a 600x400 point page. A further
        // viewer rotation puts it at (280,460) on the displayed 400x600 page.
        let displayed = CGPoint(x: canvas.bounds.width * 280 / 400, y: canvas.bounds.height * 460 / 600)
        let position = try XCTUnwrap(cursor(canvas.convert(displayed, to: nil)))
        XCTAssertEqual(position.x, 460, accuracy: 0.01); XCTAssertEqual(position.y, 120, accuracy: 0.01)
        ReaderMenuCommand.cursorPosition.run(state)
        XCTAssertEqual(state.cursorPositionUnit, .points)
        ReaderMenuCommand.cursorPosition.run(state)
        XCTAssertEqual(state.cursorPositionUnit, .millimeters)
        XCTAssertEqual(72 / (try XCTUnwrap(state.cursorPositionUnit)).pointsPerUnit, 25.4, accuracy: 0.001)
        ReaderMenuCommand.cursorPosition.run(state)
        XCTAssertEqual(state.cursorPositionUnit, .inches)
        XCTAssertEqual(72 / (try XCTUnwrap(state.cursorPositionUnit)).pointsPerUnit, 1)
        ReaderMenuCommand.cursorPosition.run(state)
        XCTAssertNil(state.cursorPositionUnit)
        state.windowClosed()
        XCTAssertNil(state.nativePDFCursorPosition)
        XCTAssertNil(cursor(canvas.convert(displayed, to: nil)), "A retired reader must not answer for a different document")
    }

    func testLegacyBookmarksConvertOnceWithCropRotationAndUserUnit() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let expected: [(Int, Double, Double)] = [(0, 120, 140), (90, 460, 120), (180, 280, 460), (270, 140, 280)]
        for (rotation, x, y) in expected {
            let source = directory.url.appendingPathComponent("page-\(rotation).pdf")
            try fixture(rotation: rotation).write(to: source)
            let pages = try Pages(source, format: .pdf)
            let original = ReadingPosition(page: 0, x: 70, y: 250, zoom: 1.25, fit: "custom")
            let restored = try await ReaderState.restoreSavedPDFPosition(original, pages: pages)
            XCTAssertEqual(restored.x, x); XCTAssertEqual(restored.y, y)
            XCTAssertEqual(restored.zoom, original.zoom); XCTAssertEqual(restored.fit, original.fit)
            XCTAssertEqual(restored.pdfCoordinateSpace, "fitz")
            let encoded = try JSONEncoder().encode(restored)
            let reopened = try await ReaderState.restoreSavedPDFPosition(JSONDecoder().decode(ReadingPosition.self, from: encoded), pages: pages)
            XCTAssertEqual(reopened, restored, "Reopening a migrated bookmark must not convert it twice")
            var partial = original; partial.x = nil
            let converted = try await ReaderState.restoreSavedPDFPosition(partial, pages: pages)
            XCTAssertEqual(converted.x, rotation == 90 || rotation == 270 ? x : nil)
            XCTAssertEqual(converted.y, rotation == 90 || rotation == 270 ? nil : y)
            let geometry = try await pages.pdfPageGeometry(0)
            XCTAssertEqual(geometry.mediaBox, CGRect(x: 0, y: 0, width: 240, height: 360))
            let raw = CGPoint(x: x, y: y).applying(geometry.transform.inverted())
            XCTAssertEqual(raw.x, 70, accuracy: 0.001); XCTAssertEqual(raw.y, 250, accuracy: 0.001)
        }
    }

    func testOpenActionOnlyResolvesLocalPageDestinations() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let cases: [(String, Int?)] = [
            ("/OpenAction [4 0 R /Fit]", 1),
            ("/OpenAction << /S /GoTo /D (chapter) >> /Names << /Dests << /Names [(chapter) [4 0 R /Fit]] >> >>", 1),
            ("/OpenAction << /S /Named /N /FirstPage >>", 0),
            ("/OpenAction << /S /Named /N /LastPage >>", 1),
            ("/OpenAction << /S /URI /URI (https://example.org) >>", nil),
            ("/OpenAction << /S /JavaScript /JS (this.pageNum=1) >>", nil)
        ]
        for (index, entry) in cases.enumerated() {
            let source = directory.url.appendingPathComponent("open-\(index).pdf")
            try fixture(catalog: entry.0).write(to: source)
            let file = try NativeFile(source, engine: .mupdf)
            XCTAssertEqual(try file.pdfInitialPage(), entry.1)
            XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        }
    }

    func testPageLabelCommandAndGeneratedContentsUseTheLiveDocument() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("headings.pdf")
        defer { withExtendedLifetime(directory) {} }
        try fixture(catalog: "/PageLabels << /Nums [0 << /S /r >>] >>").write(to: source)
        let pages = try Pages(source, format: .pdf)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: source, content: .pages(pages)); state.count = 2
        defer { state.windowClosed() }
        let navigated = expectation(description: "Logical page label navigates")
        let observer = state.$command.sink { if case .page(1) = $0.action { navigated.fulfill() } }
        state.go("ii")
        await fulfillment(of: [navigated], timeout: 3)
        withExtendedLifetime(observer) {}
        let contents = try await ReaderOutline.generate(pages)
        XCTAssertEqual(contents.map(\.title), ["1. Introduction", "1.1. Details"])
        XCTAssertEqual(contents.map(\.depth), [0, 1])
        let first = try XCTUnwrap(contents.first)
        let destination = try await pages.resolve(first.target)
        XCTAssertEqual(destination?.page, 0)
        XCTAssertNotNil(destination?.y)
        let info = try await pages.pdfInfo()
        XCTAssertFalse(info?.dirty == true)
    }

    func testSavedPositionLoadAndSameDocumentBookmarkRetainTheirCoordinates() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("saved.pdf")
        defer { withExtendedLifetime(directory) {} }
        try fixture(rotation: 90).write(to: source)
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        let opened = expectation(description: "Native PDF opened")
        let observer = state.$document.sink { if $0 != nil { opened.fulfill() } }
        state.openWithoutHistory(source, at: ReadingPosition(page: 0, x: 70, y: 250))
        await fulfillment(of: [opened], timeout: 3)
        withExtendedLifetime(observer) {}
        XCTAssertEqual(state.currentPosition.x, 460); XCTAssertEqual(state.currentPosition.y, 120)
        XCTAssertEqual(state.filePosition?.pdfCoordinateSpace, "fitz")
        let restored = expectation(description: "Old bookmark restored")
        let command = state.$command.sink { if case .restore = $0.action { restored.fulfill() } }
        state.openBookmark(.init(title: "Old bookmark", path: source.path, position: ReadingPosition(page: 0, x: 70, y: 250)))
        await fulfillment(of: [restored], timeout: 3)
        withExtendedLifetime(command) {}
        XCTAssertEqual(state.currentPosition.x, 460); XCTAssertEqual(state.currentPosition.y, 120)
    }

    func testNativeDestinationPayloadDoesNotLookLikeAnOldPDFKitBookmark() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("link.pdf")
        defer { withExtendedLifetime(directory) {} }
        try fixture(rotation: 90).write(to: source)
        let pages = try Pages(source, format: .pdf)
        let destination = PDFLinkSnapshot.Destination(page: 0, type: 7, x: 460, y: 120, width: nil, height: nil, zoom: 125)
        let position = NativePDFActions.position(for: destination, current: .init())
        let payload = WindowPayload(path: source.path, position: position)
        let data = try JSONEncoder().encode(payload)
        let restored = try JSONDecoder().decode(WindowPayload.self, from: data)
        let migrated = try await ReaderState.restoreSavedPDFPosition(XCTUnwrap(restored.position), pages: pages)
        XCTAssertEqual(migrated.x, 460); XCTAssertEqual(migrated.y, 120)
        XCTAssertEqual(migrated.zoom, 1.25)
    }

    func testNativeDocumentTextHonorsCopyPermissionBeforeReturningASelection() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf")
        defer { withExtendedLifetime(directory) {} }
        try fixture().write(to: source)
        let encrypted = directory.url.appendingPathComponent("restricted.pdf")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 0)
        let pages = try Pages(encrypted, format: .pdf, password: "reader")
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: encrypted, content: .pages(pages)); state.selectedText = "A former selection"
        defer { state.windowClosed() }
        do { _ = try await state.documentText(); XCTFail("Copy-restricted PDF text must not be exported") }
        catch { XCTAssertTrue(error.localizedDescription.contains("text extraction")) }
    }

    func testNativeInverseSearchUsesLiveGeometryWithoutReopeningAnEncryptedPDF() async throws {
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf")
        defer { withExtendedLifetime(directory) {} }
        try fixture(rotation: 90).write(to: source)
        let encrypted = directory.url.appendingPathComponent("encrypted.pdf")
        try NativePDFTools.encrypt(source: source, destination: encrypted, ownerPassword: "owner", userPassword: "reader", permissions: 0)
        let pages = try Pages(encrypted, format: .pdf, password: "reader")
        let geometry = try await pages.pdfPageGeometry(0)
        let raw = CGPoint(x: 460, y: 120).applying(geometry.transform.inverted())
        let index = "main\nversion 1\nl 1 42 3\ns 1\np 1 \(70 * 65781.76) \(250 * 65781.76)\n"
        try Data(index.utf8).write(to: encrypted.deletingPathExtension().appendingPathExtension("pdfsync"))
        let result = try await Synchronizer.inverse(pdf: encrypted, page: 0, point: raw, bounds: geometry.mediaBox, pageCount: 2)
        XCTAssertEqual(result.sourceURL.lastPathComponent, "main.tex")
        XCTAssertEqual(result.line, 42); XCTAssertEqual(result.column, 3)
    }

    private func fixture(rotation: Int = 0, catalog: String = "") -> Data {
        let content = "BT /F1 12 Tf 30 280 Td (1. Introduction) Tj 0 -20 Td (1.1. Details) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R \(catalog) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 360] /CropBox [10 20 210 320] /Rotate \(rotation) /UserUnit 2 /Resources << /Font << /F1 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 360] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010ld 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
#endif
