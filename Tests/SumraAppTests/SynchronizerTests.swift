#if os(macOS)
import Foundation
import CoreGraphics
import XCTest
@testable import Sumra

final class SynchronizerTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/source-fixtures/TeX Project", isDirectory: true)
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)

    private func point(_ record: Int, _ x: Double, _ y: Double) -> String {
        "p \(record) \(Int(x * 65781.76)) \(Int(y * 65781.76))"
    }

    func testPDFSyncFileScopesDoNotLeakSameLineRecordsAcrossSources() throws {
        let index = try PDFSyncIndex(text: """
        main
        version 1
        l 1 20
        ("chapters/Second*File"
        l 2 20
        )
        s 1
        \(point(2, 100, 200))
        """, directory: directory, pageCount: 1)
        let result = try index.inverse(page: 0, point: CGPoint(x: 100, y: 200), bounds: bounds)
        XCTAssertEqual(result.sourceURL, directory.appendingPathComponent("chapters/Second File.tex"))
        XCTAssertEqual(result.line, 20)
        XCTAssertEqual(result.column, 0)
    }

    func testPDFSyncInverseUsesVerticalFallbackAndRejectsFarPoints() throws {
        let index = try PDFSyncIndex(text: """
        main
        version 1
        l 1 10
        l 2 30
        s 1
        \(point(1, 100, 200))
        \(point(2, 300, 210))
        """, directory: directory, pageCount: 1)
        let result = try index.inverse(page: 0, point: CGPoint(x: 1000, y: 210), bounds: bounds)
        XCTAssertEqual(result.line, 30)
        XCTAssertThrowsError(try index.inverse(page: 0, point: CGPoint(x: 1000, y: 250), bounds: bounds))
    }

    func testPDFSyncRejectsVersionAndIgnoresMarksForInvalidPages() throws {
        XCTAssertThrowsError(try PDFSyncIndex(text: "main\nversion 2", directory: directory, pageCount: 1))
        let index = try PDFSyncIndex(text: "main\nversion 1\nl 1 20\ns 9\n" + point(1, 100, 200),
                                     directory: directory, pageCount: 1)
        XCTAssertThrowsError(try index.inverse(page: 0, point: CGPoint(x: 100, y: 200), bounds: bounds))
    }

    func testBundledSyncTeXReadsPlainAndGzipWithPDFCoordinates() async throws {
        try requireSyncTeX()
        for compressed in [false, true] {
            let temporary = try TemporaryDirectory()
            defer { withExtendedLifetime(temporary) {} }
            let (pdf, source) = try makePDF(in: temporary.url)
            let index = pdf.deletingPathExtension().appendingPathExtension(compressed ? "synctex.gz" : "synctex")
            let bytes = compressed ? try XCTUnwrap(Data(base64Encoded: Self.gzipIndex)) : Data(Self.index.utf8)
            try bytes.write(to: index)
            let location = try await Synchronizer.inverse(pdf: pdf, page: 0, point: CGPoint(x: 170, y: 535))
            XCTAssertEqual(location.sourceURL, source)
            XCTAssertEqual(location.line, 42)
            XCTAssertEqual(location.column, 0)
            XCTAssertEqual(try Data(contentsOf: index), bytes)
        }
    }

    func testSyncTeXKeepsLegacyQuotedIndexFilenameUnchanged() async throws {
        try requireSyncTeX()
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let (pdf, source) = try makePDF(in: temporary.url)
        let index = temporary.url.appendingPathComponent("\"book with spaces\".synctex")
        let bytes = Data(Self.index.utf8)
        try bytes.write(to: index)
        let result = try await Synchronizer.inverse(pdf: pdf, page: 0, point: CGPoint(x: 170, y: 535))
        XCTAssertEqual(result.sourceURL, source)
        XCTAssertEqual(result.line, 42)
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.deletingPathExtension().appendingPathExtension("synctex").path))
    }

    func testSyncTeXReportsMissingMalformedAndInvalidPages() throws {
        try requireSyncTeX()
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let (pdf, _) = try makePDF(in: temporary.url)
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        let pageBounds = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        func inverse(_ page: Int = 0) throws {
            _ = try Synchronizer.syncTeXInverse(pdf: pdf, page: page, point: CGPoint(x: 170, y: 535), bounds: pageBounds)
        }
        XCTAssertThrowsError(try inverse())
        let index = pdf.deletingPathExtension().appendingPathExtension("synctex")
        try Data("SyncTeX Version:1\n".utf8).write(to: index)
        XCTAssertThrowsError(try inverse()) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("preamble"))
        }
        try Data(Self.index.utf8).write(to: index)
        XCTAssertThrowsError(try inverse(1))
        XCTAssertThrowsError(try inverse(Int.max))
    }

    private func requireSyncTeX() throws {
        let library = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: library.path) else { throw XCTSkip("Build the bundled SyncTeX parser before native integration tests") }
    }

    private func makePDF(in directory: URL) throws -> (URL, URL) {
        let pdf = directory.appendingPathComponent("book with spaces.pdf")
        let source = directory.appendingPathComponent("chapters/second 'quoted': 中文*.tex")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Source line 42".utf8).write(to: source)
        // PDFKit rebases a newly created PDFPage to zero when writing it.
        // Quartz preserves the offset MediaBox needed to exercise SyncTeX mapping.
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        var box = CGRect(x: 20, y: 30, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        try (bytes as Data).write(to: pdf)
        XCTAssertEqual(CGPDFDocument(pdf as CFURL)?.page(at: 1)?.getBoxRect(.mediaBox), box)
        return (pdf, source)
    }

    // Tiny valid index uses the upstream scanner's documented box grammar.
    // Positions are TeX units (65781.76 per PDF point); no TeX tool is needed.
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
