#if os(macOS)
import AppKit
import ApplicationServices
import PDFKit
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

final class ReaderAnnotationListTests: XCTestCase {
    @MainActor
    func testAnnotationFiltersResetOnReplacementButSurviveLiveEdits() async throws {
        _ = NSApplication.shared
        func document(_ notes: [(PDFAnnotationSubtype, String)]) throws -> ReadingDocument {
            let pdf = PDFDocument(), page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            for (type, text) in notes {
                let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30),
                                               forType: type, withProperties: nil)
                annotation.contents = text
                page.addAnnotation(annotation)
            }
            pdf.insert(page, at: 0)
            return try nativePDFReadingFixture(pdf)
        }
        NSApp.finishLaunching()
        let first = try document([(.text, "alpha"), (.text, "unmatched"), (.square, "other")])
        let second = try document([(.square, "beta")])
        let state = ReaderState(recordsHistory: false)
        state.document = first
        state.count = 1
        let host = NSHostingView(rootView: AnnotationList(state: state))
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 400, height: 500),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Annotation-Filters-" + UUID().uuidString
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close(); state.windowClosed() }

        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        func accessible(_ element: AXUIElement) -> [AXUIElement] {
            [element] + (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap(accessible)
        }
        func elements() -> [AXUIElement] {
            let app = AXUIElementCreateApplication(getpid())
            guard let target = (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
                attribute($0, kAXTitleAttribute) as? String == window.title
            }) else { return [] }
            return accessible(target)
        }
        func shows(_ text: String) -> Bool {
            elements().contains {
                [kAXStaticTextRole, kAXButtonRole].contains(attribute($0, kAXRoleAttribute) as? String ?? "") &&
                    (attribute($0, kAXValueAttribute) as? String ??
                     attribute($0, kAXDescriptionAttribute) as? String ?? "").contains(text)
            }
        }
        func selectedType() -> String? {
            elements().first { attribute($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole }
                .flatMap { attribute($0, kAXValueAttribute) as? String }
        }
        func waitFor(_ message: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while Date() < deadline && state.error == nil
            XCTFail(state.error ?? "\(message); AX: \(elements().map { [attribute($0, kAXRoleAttribute), attribute($0, kAXValueAttribute), attribute($0, kAXTitleAttribute), attribute($0, kAXDescriptionAttribute)].map { String(describing: $0) }.joined(separator: ": ") })")
        }
        try await waitFor("The first document's annotations did not load") {
            shows("alpha") && shows("unmatched") && shows("other")
        }
        let search = try XCTUnwrap(views(host).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == L("Search annotations") })
        let type = try XCTUnwrap(elements().first { attribute($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole })
        XCTAssertEqual(AXUIElementPerformAction(type, kAXPressAction as CFString), .success)
        try await waitFor("The annotation type menu did not open") {
            accessible(type).contains { attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                attribute($0, kAXTitleAttribute) as? String == "Text" }
        }
        let textType = try XCTUnwrap(accessible(type).first {
            attribute($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                attribute($0, kAXTitleAttribute) as? String == "Text"
        })
        XCTAssertEqual(AXUIElementPerformAction(textType, kAXPressAction as CFString), .success)
        try await waitFor("The annotation type selection was not applied") { selectedType() == "Text" }
        search.stringValue = "alpha"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitFor("The native annotation filters were not applied") {
            shows("alpha") && !shows("unmatched") && !shows("other")
        }
        XCTAssertEqual(selectedType(), "Text")

        let pages = try XCTUnwrap(state.nativePDF)
        try await pages.pdfSetEditing(true)
        let annotations = try await pages.pdfAnnotations(0)
        let annotation = try XCTUnwrap(annotations.first { $0.type == "Text" })
        try await pages.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("alpha edited")])
        try await state.nativePDFDidChange(pages)
        try await waitFor("The edited annotation did not refresh") { shows("alpha edited") }
        XCTAssertEqual(search.stringValue, "alpha")
        XCTAssertEqual(selectedType(), "Text")
        XCTAssertFalse(shows("unmatched"))
        XCTAssertFalse(shows("other"))

        state.document = second
        try await waitFor("The replacement document's annotation stayed filtered out") { shows("beta") }
        XCTAssertEqual(search.stringValue, "")
        XCTAssertEqual(selectedType(), L("All"))
        XCTAssertFalse(shows("alpha"))
        XCTAssertFalse(shows(L("No results")))
    }

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
