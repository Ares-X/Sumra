#if os(macOS)
import AppKit
import SwiftUI
import SumraCore
import XCTest
@testable import Sumra

@MainActor
final class ReaderNumericInputTests: XCTestCase {
    func testNumericTypingCommitsWholeValueOnEndEditing() {
        var value = 17.0
        let binding = Binding(get: { value }, set: { value = $0 })
        let coordinator = ReaderNumericField.Coordinator(value: binding, range: 10...36)
        let field = NSTextField()
        field.stringValue = "2"
        XCTAssertEqual(value, 17, "Typing an unfinished value must not relayout the document")
        field.stringValue = "23.5"
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(value, 23.5)
        XCTAssertEqual(field.stringValue, ReaderNumericField.Coordinator.string(23.5))
    }

    func testInvalidNumericDraftRestoresAcceptedValueAndRangeEndpointsCommit() {
        var value = 1.6
        let coordinator = ReaderNumericField.Coordinator(value: Binding(get: { value }, set: { value = $0 }), range: 1...2.4)
        let field = NSTextField()
        for invalid in ["", "1abc", "0.9", "2.41", "nan", "inf"] {
            field.stringValue = invalid
            coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            XCTAssertEqual(value, 1.6, invalid)
            XCTAssertEqual(field.stringValue, ReaderNumericField.Coordinator.string(1.6), invalid)
        }
        for accepted in [1.0, 2.4] {
            field.stringValue = String(accepted)
            coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
            XCTAssertEqual(value, accepted)
        }
    }

    func testAcceptedDraftSurvivesDeferredBindingPublicationAndRepeatedEndEditing() {
        var publishedValue = 32.0
        var acceptedValue = publishedValue
        var submissions: [Double] = []
        let binding = Binding(get: { publishedValue }, set: {
            acceptedValue = $0
            submissions.append($0)
        })
        let coordinator = ReaderNumericField.Coordinator(value: binding, range: 0...200)
        let field = NSTextField()
        field.stringValue = "15.25"
        let endEditing = Notification(name: NSControl.textDidEndEditingNotification, object: field)

        coordinator.controlTextDidEndEditing(endEditing)
        XCTAssertEqual(acceptedValue, 15.25)
        XCTAssertEqual(binding.wrappedValue, 32, "The owner's published snapshot can lag behind its setter")
        XCTAssertEqual(field.stringValue, ReaderNumericField.Coordinator.string(15.25))

        coordinator.controlTextDidEndEditing(endEditing)
        XCTAssertEqual(acceptedValue, 15.25, "A later focus change must not resubmit the old published value")
        XCTAssertEqual(submissions, [15.25, 15.25])

        publishedValue = acceptedValue
        field.stringValue = "invalid"
        coordinator.controlTextDidEndEditing(endEditing)
        XCTAssertEqual(field.stringValue, ReaderNumericField.Coordinator.string(15.25))
        XCTAssertEqual(submissions, [15.25, 15.25], "Invalid drafts must not write to the owner")
    }

    func testExplicitCustomSurvivesMatchingPresetAndPositionRoundTrip() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.typographyForAll = false
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/margins.txt"), content: .text("Text"))
        state.applyMarginPreset(.medium)
        XCTAssertEqual(state.contentMargins?.values, [16, 32, 16, 32])
        state.selectCustomMargins()
        XCTAssertNil(state.marginPreset)
        XCTAssertEqual(state.contentMargins?.values, [16, 32, 16, 32])
        state.setCustomMargins(ReaderMarginPreset.medium.margins(reflow: true))
        let saved = try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(state.currentPosition))
        XCTAssertEqual(saved.marginPresetSelection, "custom")
        state.applyMarginPreset(.wide)
        state.restore(saved)
        XCTAssertNil(state.marginPreset)
        XCTAssertEqual(state.contentMargins?.values, [16, 32, 16, 32])
    }

    func testNamedPresetAdaptsToFixedPagesButLegacyAndCustomValuesStayExact() throws {
        _ = NSApplication.shared
        let state = ReaderState(recordsHistory: false)
        state.typographyForAll = false
        state.marginPresetSelection = "medium"
        state.pageMargins = ReaderMarginPreset.medium.margins(reflow: true)
        XCTAssertEqual(state.contentMargins?.values, [16, 16, 16, 16])
        state.document = ReadingDocument(url: URL(fileURLWithPath: "/margins.txt"), content: .text("Text"))
        XCTAssertEqual(state.contentMargins?.values, [16, 32, 16, 32])
        state.marginPresetSelection = nil
        state.pageMargins = PageMargins(cssValues: [16])
        XCTAssertEqual(state.contentMargins?.values, [16, 16, 16, 16], "A pre-existing exact override keeps its saved geometry")
        state.marginPresetSelection = "custom"
        state.pageMargins = PageMargins(cssValues: [3, 7, 11, 13])
        state.document = nil
        XCTAssertEqual(state.contentMargins?.values, [3, 7, 11, 13])
    }
}
#endif
