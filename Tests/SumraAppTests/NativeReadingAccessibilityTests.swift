#if os(macOS)
import AppKit
import CoreText
import SumraCore
import SwiftUI
import XCTest
@testable import Sumra

@MainActor
final class NativeReadingAccessibilityTests: XCTestCase {
    func testUTF16RangesAndPaintedWrapsPreserveNativeSequence() throws {
        let words = [word("中", 10, 10), word("😀", 20, 10), word(" ", 0, 0, empty: true),
                     word("文", 10, 30), word("\n", 0, 0, empty: true), word("א", 20, 50), word("ב", 10, 50)]
        // The independently testable snapshot uses the same range/geometry data
        // that the async publisher exposes to AppKit.
        let snapshot = NativeReadingAccessibilitySnapshot(words: words)
        XCTAssertEqual(snapshot.text as String, "中😀 文\nאב")
        XCTAssertEqual(snapshot.lines, [NSRange(location: 0, length: 4), NSRange(location: 4, length: 2), NSRange(location: 6, length: 2)])
        XCTAssertEqual(snapshot.bounds(for: NSRange(location: 1, length: 2)), CGRect(x: 20, y: 10, width: 10, height: 10))
        XCTAssertEqual(snapshot.visibleRange(in: CGRect(x: 0, y: 25, width: 100, height: 20)), NSRange(location: 4, length: 1))
        XCTAssertFalse(snapshot.contains(NSRange(location: Int.max, length: 1)))
        XCTAssertFalse(snapshot.contains(NSRange(location: 0, length: Int.max)))
    }

    func testAppKitNavigableTextUsesUTF16AndScreenGeometry() async throws {
        _ = NSApplication.shared
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 90, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        let page = NativeReadingAccessibilityPage(), token = NSObject()
        page.view = view; page.transform = CGAffineTransform(scaleX: 2, y: 2)
        page.update(identity: identity(token), allowed: true, words: {
            [self.word("中", 10, 10), self.word("😀", 20, 10), self.word("文", 10, 30)]
        }, failure: { XCTFail("\($0)") })
        try await wait { page.isAccessibilityElement() }
        XCTAssertEqual(page.accessibilityValue(), "中😀文")
        XCTAssertEqual(page.accessibilityString(for: NSRange(location: 1, length: 2)), "😀")
        XCTAssertNil(page.accessibilityString(for: NSRange(location: 4, length: 1)))
        XCTAssertEqual(page.accessibilityLine(for: 2), 0)
        XCTAssertEqual(page.accessibilityLine(for: 3), 1)
        XCTAssertEqual(page.accessibilityRange(forLine: 1), NSRange(location: 3, length: 1))
        XCTAssertEqual(page.accessibilityLine(for: 4), NSNotFound)
        XCTAssertEqual(page.accessibilityFrame(for: NSRange(location: 1, length: 2)), window.convertToScreen(view.convert(CGRect(x: 40, y: 20, width: 20, height: 20), to: nil)))
        XCTAssertEqual(page.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: 4))
        XCTAssertEqual(page.accessibilityFrame(for: NSRange(location: 0, length: 0)), .zero)
        page.clear()
    }

    func testLatePagePublicationCannotReplaceNewPageOrReviveDeniedText() async throws {
        let page = NativeReadingAccessibilityPage(), token = NSObject()
        var resume: CheckedContinuation<[RasterWord], Never>?
        page.update(identity: identity(token), allowed: true, words: {
            await withCheckedContinuation { resume = $0 }
        }, failure: { XCTFail("\($0)") })
        try await wait { resume != nil }
        page.update(identity: identity(token, page: 1, revision: 1), allowed: true, words: {
            [self.word("Current page", 10, 10)]
        }, failure: { XCTFail("\($0)") })
        try await wait { page.accessibilityValue() == "Current page" }
        resume?.resume(returning: [word("Obsolete page", 10, 10)])
        await Task.yield()
        XCTAssertEqual(page.accessibilityValue(), "Current page")
        var fetched = false
        page.update(identity: identity(token, page: 1, revision: 1), allowed: false, words: {
            fetched = true; return [self.word("Forbidden", 10, 10)]
        }, failure: { XCTFail("\($0)") })
        await Task.yield()
        XCTAssertFalse(fetched); XCTAssertFalse(page.isAccessibilityElement()); XCTAssertNil(page.accessibilityValue())
        page.update(identity: identity(token, page: 1, revision: 2), allowed: true, words: {
            [self.word("New layout", 10, 10)]
        }, failure: { XCTFail("\($0)") })
        try await wait { page.accessibilityValue() == "New layout" }
        page.invalidate(unless: identity(token, page: 1, revision: 3))
        XCTAssertNil(page.accessibilityValue(), "Invalidate old text while the replacement paint is pending")
        resume = nil
        let oldDocument = NativeReadingAccessibilityPage.Identity(pages: ObjectIdentifier(token), document: UUID(), location: PageLocation(page: 0), revision: 0)
        page.update(identity: oldDocument, allowed: true, words: {
            await withCheckedContinuation { resume = $0 }
        }, failure: { XCTFail("\($0)") })
        try await wait { resume != nil }
        let replacementDocument = NativeReadingAccessibilityPage.Identity(pages: ObjectIdentifier(token), document: UUID(), location: PageLocation(page: 0), revision: 0)
        page.update(identity: replacementDocument, allowed: true, words: {
            [self.word("Replacement document", 10, 10)]
        }, failure: { XCTFail("\($0)") })
        try await wait { page.accessibilityValue() == "Replacement document" }
        resume?.resume(returning: [word("Previous document", 10, 10)])
        await Task.yield()
        XCTAssertEqual(page.accessibilityValue(), "Replacement document")
        page.clear()
    }

    func testMountedNativeReaderExposesOnlyPageLocalText() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), input = directory.url.appendingPathComponent("Reading.md")
        try (0..<1000).map { "Paragraph \($0): 中文😀 accessible native reading with ordinary wrapping.\n\n" }.joined().write(to: input, atomically: true, encoding: .utf8)
        defer { withExtendedLifetime(directory) {} }
        let pages = try Pages(input, format: .markdown, deferReflowLayout: true)
        _ = try await pages.relayout(fontSize: 17, lineHeight: 1.6, margin: 32, font: "system", theme: "light")
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: input, content: .pages(pages), markdownPreference: .paged, markdownRenderer: .paged)
        state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.font = "system"; state.theme = "light"
        state.fit = "custom"; state.zoom = 1; state.flow = "continuous"; state.spread = false
        state.trimEmptyMargins = false; state.uniformPageWidth = false; state.automaticLayout = false
        state.reflowable = true; state.count = await pages.count; state.chapterLayout = await pages.chapterLayout
        XCTAssertGreaterThan(state.count, 10)
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        try await wait(host: host) { !self.readingElements(in: host).isEmpty }
        XCTAssertNil(state.error)
        let initial = readingElements(in: host)
        XCTAssertLessThan(initial.count, 5)
        let expected = try await pages.words(0).map(\.text).joined()
        XCTAssertEqual(initial.first?.accessibilityValue(), expected)
        XCTAssertFalse(initial.contains { $0.accessibilityValue()?.contains("Paragraph 999:") == true })
        // AX focus retention remains bounded, independent of first responder.
        initial.first?.setAccessibilityFocused(true)
        state.navigate(.page(state.count / 2))
        try await wait(host: host) { self.readingElements(in: host).contains { $0.accessibilityValue()?.contains("Paragraph 0:") == false } }
        XCTAssertLessThan(readingElements(in: host).count, 6)
        XCTAssertTrue(readingElements(in: host).contains { $0 === initial.first }, "Retain one focused AX page through offscreen virtualization")
        initial.first?.setAccessibilityFocused(false)
    }

    func testProtectedPDFAllowsReadingWithoutCopyAndPreservesAppKitControls() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), source = directory.url.appendingPathComponent("source.pdf"), protected = directory.url.appendingPathComponent("protected.pdf")
        defer { withExtendedLifetime(directory) {} }
        let consumer = try XCTUnwrap(CGDataConsumer(url: source as CFURL))
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 450)
        let phrase = "Accessible protected PDF"
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: phrase, attributes: [.font: NSFont.systemFont(ofSize: 17)]))
        CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
        try NativePDFTools.encrypt(source: source, destination: protected, ownerPassword: "owner", userPassword: "reader", permissions: 1 | 32)
        let pages = try Pages(protected, format: .pdf, password: "reader")
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: protected, content: .pages(pages))
        state.nativePDFInfo = try await pages.pdfInfo()
        XCTAssertEqual(state.nativePDFInfo?.permissions.copy, false)
        XCTAssertEqual(state.nativePDFInfo?.permissions.accessibility, true)
        state.count = await pages.count; state.fit = "page"; state.flow = "continuous"; state.spread = false
        let host = NSHostingView(rootView: RasterReader(state: state, pages: pages))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { state.windowClosed(); window.contentView = nil; window.close() }
        try await wait(host: host) { self.readingElements(in: host).first?.accessibilityValue()?.contains(phrase) == true }
        let canvas = try XCTUnwrap(state.readerFocusView)
        let control = NSTextField(string: "Form editor")
        control.frame = CGRect(x: 20, y: 20, width: 150, height: 30)
        control.isEditable = true
        canvas.addSubview(control)
        XCTAssertTrue((canvas.accessibilityChildren() ?? []).contains { ($0 as? NSTextFieldCell) === control.cell }, "AX children: \(String(describing: canvas.accessibilityChildren()))")
        state.nativePDFInfo = nil
        try await wait(host: host) { self.readingElements(in: host).isEmpty }
        XCTAssertTrue((canvas.accessibilityChildren() ?? []).contains { ($0 as? NSTextFieldCell) === control.cell }, "AX children: \(String(describing: canvas.accessibilityChildren()))")
        XCTAssertNil(state.error)
    }

    private func word(_ text: String, _ x: Double, _ y: Double, empty: Bool = false) -> RasterWord {
        RasterWord(text: text, rect: empty ? [0, 0, 0, 0] : [x, y, 10, 10])
    }
    private func identity(_ token: NSObject, page: Int = 0, revision: Int = 0) -> NativeReadingAccessibilityPage.Identity {
        .init(pages: ObjectIdentifier(token), document: nil, location: PageLocation(page: page), revision: revision)
    }
    private func readingElements(in view: NSView) -> [NativeReadingAccessibilityPage] {
        let local = (view.accessibilityChildren() ?? []).compactMap { $0 as? NativeReadingAccessibilityPage }
        return local + view.subviews.flatMap { readingElements(in: $0) }
    }
    private func wait(host: NSView? = nil, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate(), Date() < deadline {
            host?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "Timed out waiting for native accessibility text")
    }
}
#endif
