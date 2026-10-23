#if os(macOS)
import AppKit
import CoreGraphics
import SumraCore
import XCTest
@testable import Sumra

final class SyncTeXForwardTests: XCTestCase {
    private func request(pdf: URL, source: URL, line: String = "42", column: String? = nil) throws -> SyncTeXForwardRequest {
        var components = URLComponents()
        components.scheme = "sumra"; components.host = "synctex"
        components.queryItems = [.init(name: "pdf", value: pdf.absoluteString), .init(name: "source", value: source.absoluteString), .init(name: "line", value: line)]
        if let column { components.queryItems?.append(.init(name: "column", value: column)) }
        return try SyncTeXForwardRequest(url: XCTUnwrap(components.url))
    }

    func testEditorURLPreservesEncodedLocalPathsAndSourceCoordinates() throws {
        let pdf = URL(fileURLWithPath: "/TeX Project/中文 & 100%.pdf")
        let source = URL(fileURLWithPath: "/TeX Project/chapters/quote ' & %.tex")
        let result = try request(pdf: pdf, source: source, line: "127", column: "8")
        XCTAssertEqual(result.pdf, pdf); XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.line, 127); XCTAssertEqual(result.column, 8)
        XCTAssertEqual(try request(pdf: pdf, source: source).column, 0)
    }

    func testEditorURLRejectsRemotePathsNulDuplicateAndInvalidCoordinates() throws {
        let base = "sumra://synctex?pdf=file:///tmp/book.pdf&source=file:///tmp/main.tex&line=42"
        for value in [
            base + "&line=43", base + "&column=-1", base + "&column=2147483648",
            base.replacingOccurrences(of: "line=42", with: "line=0"),
            base.replacingOccurrences(of: "line=42", with: "line=2147483648"),
            base.replacingOccurrences(of: "file:///tmp/book.pdf", with: "https://example.com/book.pdf"),
            base.replacingOccurrences(of: "file:///tmp/main.tex", with: "file://remote/tmp/main.tex"),
            base.replacingOccurrences(of: "file:///tmp/main.tex", with: "file:///tmp/main%2500.tex"),
            base.replacingOccurrences(of: "synctex?", with: "synctex/unknown?"),
            base + "#unexpected"
        ] {
            XCTAssertThrowsError(try SyncTeXForwardRequest(url: XCTUnwrap(URL(string: value))), value)
        }
    }

    func testForwardSearchReadsPlainAndGzipIndicesInPDFCoordinates() async throws {
        try requireSyncTeX()
        for compressed in [false, true] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let (pdf, source) = try fixture(directory.url)
            let index = pdf.deletingPathExtension().appendingPathExtension(compressed ? "synctex.gz" : "synctex")
            let bytes = compressed ? try XCTUnwrap(Data(base64Encoded: Self.gzipIndex)) : Data(Self.index.utf8)
            try bytes.write(to: index)
            let position = try await SyncTeXForward.position(for: request(pdf: pdf, source: source))
            XCTAssertEqual(position.page, 0)
            XCTAssertEqual(try XCTUnwrap(position.x), 100, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(position.y), 290, accuracy: 0.01)
            XCTAssertEqual(position.pdfCoordinateSpace, "synctex")
            let pages = try Pages(pdf, format: .pdf)
            let converted = try await ReaderState.restoreSavedPDFPosition(position, pages: pages)
            XCTAssertEqual(try XCTUnwrap(converted.x), 100, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(converted.y), 290, accuracy: 0.01)
            XCTAssertEqual(converted.pdfCoordinateSpace, "fitz")
            XCTAssertEqual(try Data(contentsOf: index), bytes)
        }
    }

    func testForwardSearchReportsMissingAndMalformedIndex() throws {
        try requireSyncTeX()
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let (pdf, source) = try fixture(directory.url)
        let input = try request(pdf: pdf, source: source)
        XCTAssertThrowsError(try SyncTeXForward.query(input))
        try Data("SyncTeX Version:1\n".utf8).write(to: pdf.deletingPathExtension().appendingPathExtension("synctex"))
        XCTAssertThrowsError(try SyncTeXForward.query(input)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("preamble"))
        }
    }

    @MainActor
    func testForwardSearchReusesMatchingPDFAndPrefersItsActiveWindow() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let pdf = directory.url.appendingPathComponent("book.pdf")
        try Data().write(to: pdf)
        let alias = directory.url.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pdf)
        let unrelated = ReaderState(recordsHistory: false), first = ReaderState(recordsHistory: false), active = ReaderState(recordsHistory: false)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        active.window = window
        defer { unrelated.windowClosed(); first.windowClosed(); active.windowClosed(); window.close() }
        unrelated.document = ReadingDocument(url: directory.url.appendingPathComponent("other.pdf"), content: .text(""))
        first.document = ReadingDocument(url: pdf, content: .text(""))
        active.document = ReadingDocument(url: alias, content: .text(""))
        let input = try request(pdf: pdf, source: directory.url.appendingPathComponent("main.tex"))
        XCTAssertTrue(SyncTeXForward.reader(for: input, among: [unrelated, first, active], preferred: window) === active)
        XCTAssertTrue(SyncTeXForward.reader(for: input, among: [unrelated, first], preferred: window) === first)
        XCTAssertNil(SyncTeXForward.reader(for: input, among: [unrelated], preferred: window))
        let dormant = ReaderState(recordsHistory: false, restoring: WindowPayload(path: alias.path))
        defer { dormant.windowClosed() }
        XCTAssertTrue(SyncTeXForward.reader(for: input, among: [unrelated, dormant], preferred: nil) === dormant)
    }

    @MainActor
    func testForwardReloadLoadsCompiledPDFAndConvertsItsNewGeometry() async throws {
        try requireSyncTeX()
        _ = NSApplication.shared
        for (rotation, x, y) in [(0, 100.0, 200.0), (90, 700.0, 100.0)] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let (pdf, _) = try fixture(directory.url)
            let state = ReaderState(recordsHistory: false)
            defer { state.windowClosed() }
            state.openWithoutHistory(pdf)
            try await waitForLoad(state)
            let original = try XCTUnwrap(state.document?.id)
            try writePDF(pdf, box: CGRect(x: 50, y: 60, width: 700, height: 900), pages: 2, rotation: rotation)
            state.reload(at: ReadingPosition(page: 1, x: 100, y: 200, pdfCoordinateSpace: "synctex"))
            try await waitForLoad(state)
            XCTAssertNotEqual(state.document?.id, original)
            let count = await state.nativePDF?.count
            XCTAssertEqual(count, 2); XCTAssertEqual(state.page, 1)
            XCTAssertEqual(try XCTUnwrap(state.currentPosition.x), x, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(state.currentPosition.y), y, accuracy: 0.01)
            XCTAssertEqual(state.currentPosition.pdfCoordinateSpace, "fitz")
        }
    }

    @MainActor
    func testForwardReloadRetainsAuthenticatedPDFPasswordAndGeometry() async throws {
        try requireSyncTeX()
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let (plain, source) = try fixture(directory.url)
        let protected = directory.url.appendingPathComponent("protected.pdf")
        try NativePDFTools.encrypt(source: plain, destination: protected, ownerPassword: "owner", userPassword: "reader", permissions: 1)
        try Data(Self.index.utf8).write(to: protected.deletingPathExtension().appendingPathExtension("synctex"))
        XCTAssertThrowsError(try NativeFile(protected, engine: .mupdf)) { XCTAssertTrue($0 is PasswordRequired) }
        let state = ReaderState(recordsHistory: false)
        defer { state.windowClosed() }
        // Model the existing reader after its normal password dialog succeeds.
        state.document = try ReadingDocument.open(protected, password: "reader")
        state.rememberPassword("reader")
        let before = try XCTUnwrap(state.document?.id)
        let position = try await SyncTeXForward.position(for: request(pdf: protected, source: source))
        state.reload(at: position)
        try await waitForLoad(state)
        XCTAssertNotEqual(state.document?.id, before)
        XCTAssertEqual(state.documentPassword, "reader")
        XCTAssertEqual(state.currentPosition.pdfCoordinateSpace, "fitz")
        XCTAssertEqual(try XCTUnwrap(state.currentPosition.x), 100, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(state.currentPosition.y), 290, accuracy: 0.01)
        let pages = try XCTUnwrap(state.nativePDF)
        do {
            try await pages.pdfSetEditing(true)
            XCTFail("Reader permissions must remain enforced after forward search")
        } catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("does not permit editing")) }
    }

    @MainActor
    private func waitForLoad(_ state: ReaderState) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(state.busy); XCTAssertNil(state.error)
    }

    func testForwardDestinationRejectsAnIndexPageMissingFromTheOpenedPDF() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let (pdf, _) = try fixture(directory.url)
        let pages = try Pages(pdf, format: .pdf)
        do {
            _ = try await ReaderState.restoreSavedPDFPosition(
                ReadingPosition(page: 7, x: 100, y: 200, pdfCoordinateSpace: "synctex"), pages: pages)
            XCTFail("A stale SyncTeX index must not silently navigate to another page")
        } catch { XCTAssertTrue(error.localizedDescription.contains("SyncTeX destination page")) }
    }

    private func requireSyncTeX() throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Build the bundled SyncTeX engine before native tests") }
    }

    private func fixture(_ directory: URL) throws -> (URL, URL) {
        let pdf = directory.appendingPathComponent("book with spaces.pdf")
        let source = directory.appendingPathComponent("chapters/second 'quoted': 中文*.tex")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Source line 42".utf8).write(to: source)
        try writePDF(pdf, box: CGRect(x: 20, y: 30, width: 600, height: 800))
        return (pdf, source)
    }

    private func writePDF(_ pdf: URL, box: CGRect, pages: Int = 1, rotation: Int = 0) throws {
        let children = (0..<pages).map { "\($0 + 3) 0 R" }.joined(separator: " ")
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [\(children)] /Count \(pages) >>"]
        for _ in 0..<pages {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [\(box.minX) \(box.minY) \(box.maxX) \(box.maxY)] /Rotate \(rotation) /Resources << >> >>")
        }
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: pdf)
    }

    private static let index = """
    SyncTeX Version:1
    Input:1:chapters/second 'quoted': 中文*.tex
    Output:pdf
    Magnification:1000
    Unit:1
    X Offset:0
    Y Offset:0
    Content:
    {1
    [1,42:0,52625408:39469056,52625408,0
    (1,42:6578176,19734528:13156352,657818,131564
    h1,42:6578176,19734528:13156352,657818,131564
    )
    ]
    }
    Postamble:
    Count:3
    Post scriptum:
    Magnification:1
    X Offset:0.0pt
    Y Offset:0.0pt

    """
    private static let gzipIndex = "H4sIAAAAAAAC/5WPPU7EMBCF+zlFugVkLf6JnWRaKgq0SPxo0YoiOA4biXXMeiyBEDU34Bb0HAhxDoILWNHRzXvz9PS+s0dvz92yuHTbOIweBRz7kAgF2nUbaHIPo7Oj74rZfRrJdTMsPt7fPl9fDubkHmCR6Dseuh5O2ls/9INtKRdxzuHCD1MVLItF30dHyOHq9zwaPTlPCE8CVoKVEjnT0khd8hpVU5qGa/PjMA57OWR0VYvKMNFUqtSyRqGENkpLlj81y7qE9b/S+3ANz3A6Rmo3N3cOp3Vp2qayVUS7HQKlDf6F3EGb80A7eFl+AYscvCNeAQAA"
}
#endif
