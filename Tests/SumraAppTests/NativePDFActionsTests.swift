#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativePDFActionsTests: XCTestCase {
    func testDestinationModesUseMuPDFCoordinatesAndSumatraZoomSemantics() {
        let current = ReadingPosition(page: 2, x: 11, y: 22, zoom: 1.5, fit: "custom")
        let modes = [0: "page", 1: "content", 2: "width", 3: "visible", 4: "page", 5: "content"]
        for (type, fit) in modes {
            let destination = PDFLinkSnapshot.Destination(page: 4, type: type, x: 30, y: 40, width: 50, height: 60, zoom: 200)
            let result = NativePDFActions.position(for: destination, current: current)
            XCTAssertEqual(result.page, 4)
            XCTAssertEqual(result.fit, fit)
            XCTAssertNil(result.zoom, "A virtual fit mode must not use the numeric zoom operand")
            XCTAssertEqual(result.x, [4, 5].contains(type) ? 30 : nil)
            XCTAssertEqual(result.y, [2, 3].contains(type) ? 40 : nil)
        }
        let xyz = PDFLinkSnapshot.Destination(page: 2, type: 7, x: nil, y: nil, width: nil, height: nil, zoom: 125)
        let position = NativePDFActions.position(for: xyz, current: current)
        XCTAssertEqual(position.x, 11); XCTAssertEqual(position.y, 22)
        XCTAssertEqual(position.zoom, 1.25); XCTAssertEqual(position.fit, "custom")
        let otherPage = PDFLinkSnapshot.Destination(page: 4, type: 7, x: nil, y: nil, width: nil, height: nil, zoom: 0)
        let other = NativePDFActions.position(for: otherPage, current: current)
        XCTAssertEqual(other.x, 11); XCTAssertNil(other.y)
        XCTAssertNil(other.zoom); XCTAssertNil(other.fit)
        let rectangle = PDFLinkSnapshot.Destination(page: 4, type: 6, x: 30, y: 40, width: 50, height: 60, zoom: nil)
        let region = NativePDFActions.position(for: rectangle, current: current)
        XCTAssertEqual(region.x, 30); XCTAssertEqual(region.y, 40)
        XCTAssertNil(region.fit); XCTAssertNil(region.zoom, "Pinned ScrollTo preserves the current zoom for FitR")
    }

    func testRemoteFileTargetsPreserveEncodedDestinationsAndRelativeSourceDirectory() throws {
        let source = URL(fileURLWithPath: "/Books/project/source.pdf")
        let named = try XCTUnwrap(NativePDFActions.fileTarget("file:../Other%20Book.pdf#nameddest=Part%202", relativeTo: source))
        XCTAssertEqual(named.url.path, "/Books/Other Book.pdf")
        XCTAssertEqual(named.fragment, "#nameddest=Part%202")
        let explicit = try XCTUnwrap(NativePDFActions.fileTarget("file:///Books/%23manual.pdf#page=3&view=FitH,40", relativeTo: source))
        XCTAssertEqual(explicit.url.path, "/Books/#manual.pdf")
        XCTAssertEqual(explicit.fragment, "#page=3&view=FitH,40")
        let fallback = try XCTUnwrap(NativePDFActions.fileTarget("file://sibling.pdf", relativeTo: source))
        XCTAssertEqual(fallback.url.path, "/Books/project/sibling.pdf")
        XCTAssertEqual(NativePDFActions.fileTarget("file://localhost/Books/other.pdf", relativeTo: source)?.url.path, "/Books/other.pdf")
        XCTAssertNil(NativePDFActions.fileTarget("https://example.org/book.pdf", relativeTo: source))
        XCTAssertNil(NativePDFActions.fileTarget("#nameddest=Chapter", relativeTo: source))
        XCTAssertNil(NativePDFActions.fileTarget("javascript:alert(1)", relativeTo: source))
    }

    func testAltiumMetadataRemainsTextAndOnlyExplicitExternalURLsOpen() {
        XCTAssertEqual(NativePDFActions.menuURL("Datasheet: https://example.org/a.pdf")?.absoluteString, "https://example.org/a.pdf")
        XCTAssertEqual(NativePDFActions.menuURL(" ftp://example.org/a ")?.scheme, "ftp")
        XCTAssertEqual(NativePDFActions.menuURL("Contact: mailto:parts@example.org")?.scheme, "mailto")
        XCTAssertNil(NativePDFActions.menuURL("Resistance: 10 kΩ"))
        XCTAssertNil(NativePDFActions.menuURL("Open: file:///bin/sh"))
        XCTAssertNil(NativePDFActions.menuURL("Run: javascript:alert(1)"))
    }

    func testUnsupportedPrimaryActionDoesNotExecuteItsNextChain() {
        let unsupported = action(kind: "ResetForm")
        let next = action(index: 1, kind: "GoTo", destination: .init(page: 2, type: 0, x: nil, y: nil, width: nil, height: nil, zoom: nil))
        XCTAssertFalse(NativePDFActions.canFollow(link(actions: [unsupported, next])))
        for flags in [1, 2, 32] {
            XCTAssertFalse(NativePDFActions.canFollow(link(flags: flags, actions: [action(kind: "URI", uri: "https://example.org")])))
        }
        XCTAssertTrue(NativePDFActions.canFollow(link(actions: [action(kind: "Named", destination: next.destination)])))
        XCTAssertFalse(NativePDFActions.canFollow(link(actions: [action(kind: "Named")])))
    }

    func testFollowingLiveLinkKeepsPrimaryZoomAndDoesNotFollowNext() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let url = temporary.url.appendingPathComponent("links.pdf")
        try fixture().write(to: url)
        let pages = try Pages(url, format: .pdf)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: url, content: .pages(pages)); state.count = 3
        defer { state.windowClosed() }
        let links = try await pages.pdfLinks(0)
        let first = try XCTUnwrap(links.first(where: { $0.id == 6 }))
        XCTAssertEqual(first.actions.count, 2)
        XCTAssertFalse(state.pdfEditingEnabled, "Following a link does not require enabling PDF editing")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        await NativePDFActions.follow(first, page: 0, pages: pages, state: state, in: view, at: .zero)
        XCTAssertEqual(state.page, 1)
        XCTAssertEqual(state.zoom, 2)
        XCTAssertEqual(state.fit, "custom")
        XCTAssertEqual(state.currentPosition.x, 20)
        XCTAssertEqual(state.currentPosition.y, 150)
        XCTAssertTrue(state.canNavigateBack)

        state.disableLinks = true
        let last = try XCTUnwrap(links.first(where: { $0.id == 7 }))
        await NativePDFActions.follow(last, page: 0, pages: pages, state: state, in: view, at: .zero)
        XCTAssertEqual(state.page, 1)
        let info = try await pages.pdfInfo()
        XCTAssertEqual(info?.editingEnabled, false)
        XCTAssertEqual(info?.undoSteps, 0, "Navigation must not create a PDF edit")
    }

    func testFormCommitReplacingDocumentCannotNavigateTheNewDocument() async throws {
        let temporary = try TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let url = temporary.url.appendingPathComponent("links.pdf")
        try fixture().write(to: url)
        let pages = try Pages(url, format: .pdf)
        let state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: url, content: .pages(pages)); state.count = 3
        defer { state.windowClosed() }
        let links = try await pages.pdfLinks(0)
        let first = try XCTUnwrap(links.first)
        let replacement = ReadingDocument(url: url, content: .text("replacement"))
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        let widget = PDFAnnotationSnapshot(id: 8, type: "Widget", contents: "", author: "", icon: "", flags: 0,
            rect: [0, 0, 120, 24], color: [], interiorColor: [], opacity: 1, borderWidth: 0, borderStyle: 0,
            alignment: 0, dash: [], font: "Helv", fontSize: 12, textColor: [], line: [], vertices: [],
            lineEnds: [], quads: [], ink: [], fieldName: "name", fieldLabel: nil, value: "value",
            fieldType: 7, fieldFlags: 0, maxLength: 0, readOnly: false, options: [])
        let editor = NativePDFFormEditor(widget: widget, host: host, frame: widget.bounds,
            commitValue: { _ in state.document = replacement }, didClose: { state.nativePDFFormEditor = nil },
            advance: { _ in }, failure: { XCTFail("\($0)") })
        state.nativePDFFormEditor = editor
        let field = try XCTUnwrap(host.subviews.first as? NSTextField)
        field.stringValue = "pending navigation input"
        await NativePDFActions.follow(first, page: 0, pages: pages, state: state, in: host, at: .zero)
        XCTAssertEqual(state.document?.id, replacement.id)
        XCTAssertEqual(state.page, 0)
        XCTAssertFalse(state.canNavigateBack)
        XCTAssertNil(state.error)
    }

    private func action(index: Int = 0, kind: String, uri: String? = nil,
                        destination: PDFLinkSnapshot.Destination? = nil) -> PDFLinkSnapshot.Action {
        .init(index: index, kind: kind, uri: uri, name: "", flags: 0, newWindow: nil, fields: nil, javascript: nil, destination: destination)
    }
    private func link(flags: Int = 0, actions: [PDFLinkSnapshot.Action]) -> PDFLinkSnapshot {
        .init(id: 6, type: "Link", flags: flags, rect: [0, 0, 100, 30], actions: actions)
    }
    private func fixture() -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Annots [6 0 R 7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 200 100 220] /A << /S /GoTo /D [4 0 R /XYZ 20 150 2] /Next << /S /GoTo /D [5 0 R /Fit] >> >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 100 100 120] /A << /S /Named /N /LastPage >> >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
#endif
