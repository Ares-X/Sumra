#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class NativePDFFormAccessibilityTests: XCTestCase {
    func testPaintedFieldsExposeNativeActionsValuesAndKeyboardEntry() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory(), url = directory.url.appendingPathComponent("accessible-form.pdf")
        let original = fixture()
        try original.write(to: url)
        let pages = try Pages(url, format: .pdf), state = ReaderState(recordsHistory: false)
        state.document = ReadingDocument(url: url, content: .pages(pages))
        state.nativePDFInfo = try await pages.pdfInfo()
        let canvas = RasterCanvas.Canvas(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        canvas.state = state; canvas.pages = pages; canvas.pageBounds = canvas.bounds; canvas.visibleBounds = canvas.bounds
        canvas.pdfAnnotations = try await pages.pdfAnnotations(0)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer {
            state.windowClosed(); window.makeFirstResponder(nil); window.contentView = nil; window.close()
            withExtendedLifetime(directory) {}
        }
        func fields() -> [NativePDFFormAccessibilityElement] {
            canvas.accessibilityChildren()?.compactMap { $0 as? NativePDFFormAccessibilityElement } ?? []
        }
        let before = fields()
        XCTAssertEqual(before.compactMap { $0.accessibilityLabel() }, ["Your name", "Password", "Interests", "Subscribe", "Read only"])
        XCTAssertTrue(before.allSatisfy { !$0.isAccessibilityEnabled() })
        XCTAssertEqual(before.first?.accessibilityValue() as? String, "Ada")
        XCTAssertNil(before[1].accessibilityValue(), "Stored PDF passwords must not leak through virtual controls")
        XCTAssertEqual(before[2].accessibilityValue() as? String, "Alpha, Beta")
        XCTAssertEqual(before[3].accessibilityRole(), .checkBox)
        let roleSelector = NSSelectorFromString("accessibilityRole")
        let enabledSelector = NSSelectorFromString("isAccessibilityEnabled")
        XCTAssertTrue(before[3].responds(to: roleSelector))
        XCTAssertTrue(before[3].responds(to: enabledSelector))
        if before[3].responds(to: roleSelector), before[3].responds(to: enabledSelector) {
            XCTAssertEqual(before[3].value(forKey: "accessibilityRole") as? String, NSAccessibility.Role.checkBox.rawValue)
            XCTAssertEqual(before[3].value(forKey: "accessibilityEnabled") as? NSNumber, false)
        }
        XCTAssertEqual(before[3].accessibilityValue() as? NSNumber, false)
        XCTAssertEqual(before[0].accessibilityFrame(), window.convertToScreen(canvas.convert(before[0].widget.bounds.applying(canvas.pageTransform), to: nil)))

        state.setPDFEditingEnabled(true)
        try await wait { state.canEditPDF && !state.busy }
        let unlocked = fields(), name = try XCTUnwrap(unlocked.first)
        XCTAssertTrue(name === before[0], "An unchanged field keeps its AX identity")
        XCTAssertTrue(name.isAccessibilityEnabled()); XCTAssertFalse(unlocked[4].isAccessibilityEnabled())
        if name.responds(to: enabledSelector), unlocked[4].responds(to: enabledSelector) {
            XCTAssertEqual(name.value(forKey: "accessibilityEnabled") as? NSNumber, true)
            XCTAssertEqual(unlocked[4].value(forKey: "accessibilityEnabled") as? NSNumber, false)
        }
        XCTAssertTrue(name.accessibilityPerformPress())
        try await wait { state.nativePDFFormEditor != nil }
        XCTAssertFalse(fields().contains { $0.widget.id == name.widget.id }, "The active native input replaces its virtual control")
        let input = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(input.accessibilityLabel(), "Your name")
        input.stringValue = "Grace"
        try await state.nativePDFFormEditor?.commit()
        canvas.pdfAnnotations = try await pages.pdfAnnotations(0)
        let updated = try XCTUnwrap(fields().first)
        XCTAssertTrue(updated === name); XCTAssertEqual(updated.accessibilityValue() as? String, "Grace")

        window.makeFirstResponder(canvas)
        canvas.keyDown(with: key(48))
        try await wait { state.nativePDFFormEditor != nil }
        XCTAssertEqual(canvas.subviews.compactMap { $0 as? NSTextField }.first?.accessibilityLabel(), "Your name")
        state.nativePDFFormEditor?.cancel()
        canvas.keyDown(with: key(48, modifiers: .shift))
        try await wait { state.nativePDFFormEditor != nil }
        let table = try XCTUnwrap(canvas.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        XCTAssertEqual(table.accessibilityLabel(), "Interests")
        state.nativePDFFormEditor?.cancel()

        let checkbox = try XCTUnwrap(fields().first { $0.widget.fieldName == "subscribe" })
        XCTAssertTrue(checkbox.accessibilityPerformPress())
        try await wait {
            canvas.pdfAnnotations = try await pages.pdfAnnotations(0)
            return canvas.pdfAnnotations.first { $0.fieldName == "subscribe" }?.value == "Yes"
        }
        XCTAssertEqual(fields().first { $0.widget.fieldName == "subscribe" }?.accessibilityValue() as? NSNumber, true)
        state.setPDFEditingEnabled(false)
        try await wait { !state.pdfEditingEnabled && !state.busy }
        XCTAssertTrue(fields().allSatisfy { !$0.isAccessibilityEnabled() })
        XCTAssertFalse(name.accessibilityPerformPress())
        state.annotationsVisible = false
        XCTAssertTrue(fields().isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)!
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTFail("Native form input did not settle")
    }
    private func fixture() -> Data {
        let checkedAppearance = "0 0 20 20 re S\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 11 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Annots [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /TU (Your name) /V (Ada) /Rect [20 400 220 430] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /Ff 8192 /T (password) /TU (Password) /V (topsecret) /Rect [20 350 220 380] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 2097152 /T (interests) /TU (Interests) /V [(a) (b)] /Opt [[(a) (Alpha)] [(b) (Beta)] [(c) (Gamma)]] /Rect [20 210 220 320] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (subscribe) /TU (Subscribe) /V /Off /AS /Off /Rect [20 170 40 190] /F 4 /P 3 0 R /AP << /N << /Off 12 0 R /Yes 13 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /Ff 1 /T (readonly) /TU (Read only) /V (Locked) /Rect [20 110 220 140] /F 4 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (hidden) /V (Hidden) /Rect [20 50 220 80] /F 2 /P 3 0 R /DA (/Helv 12 Tf 0 g) >>",
            "<< /Fields [5 0 R 6 0 R 7 0 R 8 0 R 9 0 R 10 0 R] /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length 0 >>\nstream\n\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Length \(checkedAppearance.utf8.count) >>\nstream\n\(checkedAppearance)endstream"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
#endif
