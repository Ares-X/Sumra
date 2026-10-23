#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Sumra

final class ShortcutSettingsTests: XCTestCase {
    func testConflictsCompareParsedBindingsAndModifierOrder() {
        let overrides = [ReaderMenuCommand.open.id: "shift+cmd+x;cmd+shift+x",
                         ReaderMenuCommand.save.id: "CMD+SHIFT+X",
                         ReaderMenuCommand.print.id: "cmd+x"]
        let conflicts = ReaderShortcutSettings.conflicts(overrides: overrides)
        XCTAssertEqual(conflicts[.open], [.save])
        XCTAssertEqual(conflicts[.save], [.open])
        XCTAssertNil(conflicts[.print])
    }

    func testConflictIncludesOtherCommandsDefaultAndAdditionalBindings() {
        let conflicts = ReaderShortcutSettings.conflicts(overrides: [ReaderMenuCommand.save.rawValue: "alt+f24;cmd+o"])
        XCTAssertTrue(conflicts[.save]?.contains(.open) == true)
        XCTAssertTrue(conflicts[.open]?.contains(.save) == true)
    }

    func testDisabledBindingDoesNotConflictAndRemovingOverrideRestoresDefault() {
        var overrides = [ReaderMenuCommand.open.id: "", ReaderMenuCommand.save.id: "cmd+o"]
        XCTAssertEqual(ReaderShortcutSettings.binding(for: .open, overrides: overrides), "")
        XCTAssertNil(ReaderShortcutSettings.conflicts(overrides: overrides)[.save])
        overrides.removeValue(forKey: ReaderMenuCommand.open.id)
        XCTAssertEqual(ReaderShortcutSettings.binding(for: .open, overrides: overrides), ReaderMenuCommand.open.defaultShortcut)
        XCTAssertEqual(ReaderShortcutSettings.binding(for: .save, overrides: overrides), "cmd+o")
        XCTAssertTrue(ReaderShortcutSettings.conflicts(overrides: overrides)[.save]?.contains(.open) == true)
    }

    @MainActor func testRecorderConvertsNativeKeysToExistingShortcutSyntax() throws {
        let letter = try event(keyCode: 0, characters: "A", modifiers: [.command, .shift])
        let binding = try XCTUnwrap(ShortcutRecorderButton.binding(for: letter))
        let shortcut = try XCTUnwrap(readerShortcut(binding))
        XCTAssertEqual(shortcut.key.character, "a")
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
        let arrow = try event(keyCode: 123, characters: String(KeyEquivalent.leftArrow.character), modifiers: [.option])
        XCTAssertEqual(ShortcutRecorderButton.binding(for: arrow), "alt+left")
        let function = try event(keyCode: 97, characters: String(UnicodeScalar(0xF709)!), modifiers: [])
        XCTAssertEqual(ShortcutRecorderButton.binding(for: function), "f6")
    }

    @MainActor private func event(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode))
    }
}
#endif
