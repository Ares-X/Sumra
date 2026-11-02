#if os(macOS)
import AppKit
import XCTest
@testable import Sumra

@MainActor
final class ReaderInputAlertTests: XCTestCase {
    func testDialogSelectionRetainsContrastWhenMovingBetweenLiteralFields() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let alert = ReaderInputAlert()
            alert.window.appearance = NSAppearance(named: appearance)
            let first = NSTextField(string: "First value"), second = NSTextField(string: "Second value")
            alert.accessoryView = NSStackView(views: [first, second])
            alert.addButton(withTitle: "Cancel")
            RunLoop.main.perform(inModes: [.modalPanel]) {
                MainActor.assumeIsolated {
                    defer { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
                    for field in [first, second] {
                        field.selectText(nil)
                        guard let editor = field.currentEditor() as? NSTextView else {
                            XCTFail("The dialog field must receive its field editor")
                            continue
                        }
                        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: field.stringValue.utf16.count))
                        XCTAssertFalse(editor.usesFontPanel)
                        XCTAssertEqual(editor.selectedTextAttributes[.backgroundColor] as? NSColor, NSColor.selectedContentBackgroundColor)
                        XCTAssertEqual(editor.selectedTextAttributes[.foregroundColor] as? NSColor, NSColor.alternateSelectedControlTextColor)
                    }
                }
            }
            alert.runModal()
        }
    }
}
#endif
