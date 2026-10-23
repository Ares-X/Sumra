#if os(macOS)
import AppKit
import SwiftUI

// Settings uses the same parser and defaults as the menu and keyboard handlers.
enum ReaderShortcutSettings {
    static func binding(for command: ReaderMenuCommand, overrides: [String: String]) -> String {
        overrides[command.id] ?? command.defaultShortcut
    }

    static func conflicts(overrides: [String: String]) -> [ReaderMenuCommand: [ReaderMenuCommand]] {
        var owners: [String: [ReaderMenuCommand]] = [:]
        for command in ReaderMenuCommand.allCases {
            for binding in readerShortcutBindings(binding(for: command, overrides: overrides)) {
                guard let shortcut = readerShortcut(binding) else { continue }
                let signature = "\(shortcut.modifiers.rawValue):\(String(shortcut.key.character).lowercased())"
                if owners[signature]?.contains(command) != true { owners[signature, default: []].append(command) }
            }
        }
        var result: [ReaderMenuCommand: [ReaderMenuCommand]] = [:]
        for commands in owners.values where commands.count > 1 {
            for command in commands {
                for other in commands where other != command && result[command]?.contains(other) != true {
                    result[command, default: []].append(other)
                }
            }
        }
        return result.mapValues { values in ReaderMenuCommand.allCases.filter { values.contains($0) } }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var onRecord: (String) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(title: L("Record…"), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(ShortcutRecorderButton.beginRecording)
        button.setAccessibilityLabel(L("Record shortcut"))
        button.toolTip = L("Click, then press a shortcut. Escape cancels. Recording replaces all bindings for this command.")
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onRecord = onRecord
        if !button.recording { button.title = L("Record…") }
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        if button.window?.firstResponder === button { button.window?.makeFirstResponder(nil) }
    }
}

final class ShortcutRecorderButton: NSButton {
    var onRecord: (String) -> Void = { _ in }
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true
        title = L("Press shortcut…")
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        title = L("Record…")
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        guard let binding = Self.binding(for: event) else { NSSound.beep(); return }
        onRecord(binding)
        window?.makeFirstResponder(nil)
    }

    static func binding(for event: NSEvent) -> String? {
        // Function-key characters are already layout independent. AppKit's
        // modifier conversion turns arrows/F-keys into legacy control codes.
        let unmodified = event.charactersIgnoringModifiers?.first
        let character: Character
        if let unmodified, let scalar = unmodified.unicodeScalars.first,
           (0xF700...0xF8FF).contains(scalar.value) { character = unmodified }
        else if let value = event.characters(byApplyingModifiers: [])?.lowercased().first { character = value }
        else { return nil }
        let special: [Character: String] = [
            KeyEquivalent.leftArrow.character: "left", KeyEquivalent.rightArrow.character: "right",
            KeyEquivalent.upArrow.character: "up", KeyEquivalent.downArrow.character: "down",
            KeyEquivalent.space.character: "space", KeyEquivalent.return.character: "return",
            KeyEquivalent.escape.character: "escape", KeyEquivalent.tab.character: "tab",
            KeyEquivalent.home.character: "home", KeyEquivalent.end.character: "end",
            KeyEquivalent.pageUp.character: "pageup", KeyEquivalent.pageDown.character: "pagedown",
            KeyEquivalent.delete.character: "delete", KeyEquivalent.deleteForward.character: "forwarddelete"
        ]
        let key: String
        if let name = special[character] { key = name }
        else if let scalar = character.unicodeScalars.first, (0xF704...0xF71B).contains(scalar.value) {
            key = "f\(scalar.value - 0xF704 + 1)"
        } else { key = String(character) }
        var parts: [String] = []
        for (flag, name): (NSEvent.ModifierFlags, String) in [(.command, "cmd"), (.control, "ctrl"), (.option, "alt"), (.shift, "shift")] {
            if event.modifierFlags.contains(flag) { parts.append(name) }
        }
        parts.append(key)
        let binding = parts.joined(separator: "+")
        return readerShortcut(binding) == nil ? nil : binding
    }
}
#endif
