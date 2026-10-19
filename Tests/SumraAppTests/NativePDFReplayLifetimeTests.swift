#if os(macOS)
import AppKit
import Darwin
import XCTest
@testable import Sumra

final class NativePDFReplayLifetimeTests: XCTestCase {
    func testNativeSnapshotReplaysAfterDocumentCloseAndFailedReplay() throws {
        let path = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Build MuPDF before replay lifetime tests") }
        let library = try XCTUnwrap(dlopen(path.path, RTLD_LOCAL | RTLD_NOW))
        defer { dlclose(library) }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            unsafeBitCast(try XCTUnwrap(dlsym(library, name)), to: T.self)
        }
        typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<CChar>, Int32) -> UnsafeMutableRawPointer?
        typealias Close = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias Prepare = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<Int32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        typealias Render = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafePointer<Int32>?, Int32, UnsafePointer<Int32>?, UnsafePointer<UInt32>?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        let open = try symbol("lf_open_classified", Open.self), close = try symbol("lf_close", Close.self)
        let prepare = try symbol("lf_pdf_render_snapshot_at", Prepare.self)
        let render = try symbol("lf_pdf_render_snapshot_image", Render.self)
        let drop = try symbol("lf_pdf_render_snapshot_drop", Close.self)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-replay-lifetime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("page.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let writer = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        writer.beginPDFPage(nil)
        writer.setFillColor(CGColor(gray: 0, alpha: 1)); writer.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        writer.endPDFPage(); writer.closePDF()

        var error = [CChar](repeating: 0, count: 512), info = [Int32](repeating: 0, count: 4)
        var document = source.path.withCString { open($0, nil, nil, &error, 1) }
        defer { if let document { close(document) } }
        let snapshot = try XCTUnwrap(prepare(try XCTUnwrap(document), 0, 0, nil, nil, &error))
        defer { drop(snapshot) }
        // Bypass NativePDFRenderSnapshot's retained Swift owner: the native
        // document and its lock reference really are released here.
        close(try XCTUnwrap(document)); document = nil
        XCTAssertNil(render(snapshot, 0, nil, 0, nil, nil, nil, &info, &error))
        XCTAssertFalse(String(cString: error).isEmpty)
        let output = try XCTUnwrap(render(snapshot, 240, nil, 0, nil, nil, nil, &info, &error))
        defer { free(output) }
        XCTAssertEqual(info[0], 240); XCTAssertEqual(info[1], 240)
        XCTAssertGreaterThan(info[2], 0)
    }
}
#endif
