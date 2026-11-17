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
    #if DEBUG
    @MainActor
    func testSameDocumentRowsRemainVisibleDuringRefreshAndReplacementHidesOldRows() async throws {
        let fixture = try AnnotationSidebarFixture(pageCount: 12)
        defer { fixture.close() }
        try await fixture.waitFor("initial annotation")
        try await fixture.waitForRenderChange(from: fixture.initialBitmap)
        let opened = try fixture.snapshot()
        let pages = try XCTUnwrap(fixture.state.nativePDF)
        let reads = AnnotationPageReads()
        await pages.observePDFAnnotationReads { reads.read($0) }
        defer { reads.release() }
        try await pages.pdfSetEditing(true)
        let annotations = try await pages.pdfAnnotations(0)
        let annotation = try XCTUnwrap(annotations.first)
        try await pages.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("edited annotation")])
        reads.reset(block: true)
        try await fixture.state.nativePDFDidChange(pages)
        try await fixture.waitUntil { reads.count > 0 }
        XCTAssertEqual(try fixture.snapshot(), opened, "The rendered same-document rows must stay visible while the changed page is being read")

        let replacement = try nativePDFReadingFixture(pageCount: 2)
        fixture.state.document = replacement
        try await fixture.waitUntil { fixture.loaded.completions == 2 }
        try await fixture.waitForRenderChange(from: opened)
        reads.release()
        _ = await pages.count
        await Task.yield()
        XCTAssertEqual(fixture.loaded.completions, 2)
        XCTAssertTrue(fixture.loaded.rows.isEmpty, "An old document's suspended refresh must not publish into its replacement")
    }

    @MainActor
    func testCoalescedPageEditsKeepOrderAndUndoRebuildsAnnotationRows() async throws {
        let fixture = try AnnotationSidebarFixture(pageCount: 12)
        defer { fixture.close() }
        try await fixture.waitFor("initial annotation")
        try await fixture.waitForRenderChange(from: fixture.initialBitmap)
        let opened = try fixture.snapshot()
        let pages = try XCTUnwrap(fixture.state.nativePDF)
        try await pages.pdfSetEditing(true)
        let reads = AnnotationPageReads()
        await pages.observePDFAnnotationReads { reads.read($0) }
        let annotations = try await pages.pdfAnnotations(0)
        let first = try XCTUnwrap(annotations.first)
        reads.reset()
        _ = try await pages.pdfCreateAnnotation(page: 8, type: "Text", bounds: CGRect(x: 20, y: 20, width: 30, height: 30), edits: [.contents("later page annotation")])
        try await pages.pdfEditAnnotation(page: 0, id: first.id, edits: [.contents("first page edited")])
        try await fixture.state.nativePDFDidChange(pages)
        try await fixture.waitFor("later page annotation")
        XCTAssertEqual(reads.pages, [0, 8], "Coalesced mutations must reread all changed pages once, in document order")
        XCTAssertTrue(fixture.shows("first page edited"))
        XCTAssertEqual(fixture.loaded.rows.map(\.page), [0, 8])
        try await fixture.waitForRenderChange(from: opened)
        let edited = try fixture.snapshot()

        reads.reset()
        try await pages.pdfUndo()
        try await fixture.state.nativePDFDidChange(pages)
        try await fixture.waitFor("initial annotation")
        XCTAssertEqual(reads.count, 12, "Undo has unknown page scope and must rebuild all rows")
        XCTAssertEqual(reads.pages.first, 0)
        XCTAssertEqual(reads.pages.last, 11)
        XCTAssertFalse(fixture.shows("first page edited"))
        XCTAssertTrue(fixture.shows("later page annotation"))
        try await fixture.waitForRenderChange(from: edited)
    }

    @MainActor
    func testSparsePDFSinglePageEditReadCountsAt1000_5000_10000Pages() async throws {
        for count in [1_000, 5_000, 10_000] {
            let fixture = try AnnotationSidebarFixture(pageCount: count)
            defer { fixture.close() }
            let pages = try XCTUnwrap(fixture.state.nativePDF)
            let reads = AnnotationPageReads()
            await pages.observePDFAnnotationReads { reads.read($0) }
            let started = Date()
            try await fixture.waitFor("initial annotation", timeout: 30)
            try await fixture.waitForRenderChange(from: fixture.initialBitmap)
            let opened = try fixture.snapshot()
            let initialTime = Date().timeIntervalSince(started)
            XCTAssertEqual(reads.count, count)
            try await pages.pdfSetEditing(true)
            let annotations = try await pages.pdfAnnotations(0)
            let annotation = try XCTUnwrap(annotations.first)
            reads.reset()
            let edited = Date()
            try await pages.pdfEditAnnotation(page: 0, id: annotation.id, edits: [.contents("edited annotation")])
            try await fixture.state.nativePDFDidChange(pages)
            try await fixture.waitFor("edited annotation", timeout: 30)
            try await fixture.waitForRenderChange(from: opened)
            print("ANNOTATION_SIDEBAR pages=\(count) initial_reads=\(count) initial_seconds=\(initialTime) edit_reads=\(reads.count) edit_seconds=\(Date().timeIntervalSince(edited))")
            XCTAssertEqual(reads.count, 1, "A one-page annotation edit must not scan the entire PDF")
            XCTAssertEqual(reads.pages.first, 0)
        }
    }
    #endif
}
#endif

#if os(macOS) && DEBUG
private final class AnnotationPageReads: @unchecked Sendable {
    private let condition = NSCondition()
    private var recorded = [Int]()
    private var blocked = false
    var pages: [Int] { condition.lock(); defer { condition.unlock() }; return recorded }
    var count: Int { pages.count }
    func reset(block: Bool = false) {
        condition.lock(); defer { condition.unlock() }
        recorded = []; blocked = block
    }
    func read(_ page: Int) {
        condition.lock(); defer { condition.unlock() }
        recorded.append(page)
        while blocked { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        blocked = false; condition.broadcast()
    }
}

@MainActor
private final class AnnotationRowsLoaded {
    var rows = [(page: Int, index: Int, type: String, text: String)]()
    var completions = 0
}

@MainActor
private final class AnnotationSidebarFixture {
    let state = ReaderState(recordsHistory: false)
    let host: NSHostingView<AnnotationList>
    let window: NSWindow
    let loaded: AnnotationRowsLoaded
    var initialBitmap = Data()
    init(pageCount: Int) throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let pdf = PDFDocument()
        for index in 0..<pageCount {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            if index == 0 {
                let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .text, withProperties: nil)
                annotation.contents = "initial annotation"
                page.addAnnotation(annotation)
            }
            pdf.insert(page, at: index)
        }
        state.document = try nativePDFReadingFixture(pdf)
        state.count = pageCount
        let loaded = AnnotationRowsLoaded()
        self.loaded = loaded
        host = NSHostingView(rootView: AnnotationList(state: state, didLoadForTesting: { rows in
            loaded.rows = rows; loaded.completions += 1
        }))
        window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 400, height: 500), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Annotation-Refresh-" + UUID().uuidString
        window.contentView = host
        window.orderBack(nil)
        initialBitmap = try snapshot()
    }
    func close() { window.contentView = nil; window.close(); state.windowClosed() }
    func snapshot() throws -> Data {
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
    func shows(_ text: String) -> Bool { loaded.rows.contains { $0.text.contains(text) } }
    func waitForRenderChange(from previous: Data) async throws {
        let deadline = Date().addingTimeInterval(3)
        while try snapshot() == previous, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard try snapshot() != previous else {
            throw NSError(domain: "AnnotationSidebarTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The native annotation sidebar did not render its published rows"])
        }
    }
    func waitFor(_ text: String, timeout: TimeInterval = 3) async throws {
        try await waitUntil(timeout: timeout) { self.shows(text) }
    }
    func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline, state.error == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        guard predicate() else {
            throw NSError(domain: "AnnotationSidebarTests", code: 2, userInfo: [NSLocalizedDescriptionKey: state.error ?? "Annotation sidebar did not reach the expected state; published rows: \(loaded.rows)"])
        }
    }
}
#endif
