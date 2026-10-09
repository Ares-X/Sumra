#if os(macOS)
import AppKit
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderAnnotationListTests: XCTestCase {
    @MainActor
    func testAnnotationListReflectsLiveEditsButKeepsRowsWhileReading() async throws {
        _ = NSApplication.shared
        let document = PDFDocument()
        for index in 0..<12 {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .text, withProperties: nil)
            annotation.contents = "Note \(index)"
            page.addAnnotation(annotation)
            document.insert(page, at: index)
        }
        let state = ReaderState(recordsHistory: false)
        state.document = try nativePDFReadingFixture(document)
        let pages = try XCTUnwrap(state.nativePDF)
        state.count = document.pageCount
        let host = NSHostingView(rootView: AnnotationList(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close(); state.windowClosed() }
        func snapshot() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return try XCTUnwrap(image.representation(using: .png, properties: [:]))
        }
        func waitForChange(from previous: Data) async throws -> Data {
            let deadline = Date().addingTimeInterval(3)
            repeat {
                try await Task.sleep(nanoseconds: 10_000_000)
                let image = try snapshot()
                if image != previous { return image }
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "The annotation list did not display the changed rows")
            return previous
        }
        let empty = try snapshot()
        let opened = try await waitForChange(from: empty)
        for page in 0..<document.pageCount {
            state.updatePosition(.init(page: page, y: Double(page * 20)))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(try snapshot(), opened, "Reading must not replace the annotation list with loading or empty rows")
        try await pages.pdfSetEditing(true)
        let annotations = try await pages.pdfAnnotations(0)
        let first = try XCTUnwrap(annotations.first)
        try await pages.pdfEditAnnotation(page: 0, id: first.id, edits: [.contents("The current live annotation changed")])
        try await state.nativePDFDidChange(pages)
        _ = try await waitForChange(from: opened)
    }
}
#endif
