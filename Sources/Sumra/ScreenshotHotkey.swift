#if os(macOS)
import AppKit
import Carbon
import SumraCore

// One system hotkey, registered only when the user chooses it. macOS owns
// dispatch outside Sumra; the existing screenshot action owns capture/output.
@MainActor
enum ScreenshotHotkey {
    struct Binding: Codable, Equatable {
        let code: UInt32, modifiers: UInt32
        let label: String
    }
    static var capture: (() -> Void)?
    private static var handler: EventHandlerRef?
    private static var reference: EventHotKeyRef?
    private static var current: Binding?
    private static var nextID: UInt32 = 0

    static func restore() {
        guard let data = UserDefaults.standard.data(forKey: "screenshotHotkey"),
              let binding = try? JSONDecoder().decode(Binding.self, from: data) else { return }
        do { try register(binding) } catch { ReaderHelp.recordError(error.localizedDescription) }
    }

    private static func register(_ binding: Binding?) throws {
        guard binding != current else { return }
        guard let binding else {
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil; current = nil; return
        }
        if handler == nil {
            var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in ScreenshotHotkey.capture?() }
                return noErr
            }, 1, &kind, nil, &handler)
            guard status == noErr else { throw ReadError("Cannot install screenshot shortcut handler (\(status))") }
        }
        nextID &+= 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.code, binding.modifiers, EventHotKeyID(signature: 0x4c454146, id: nextID), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { throw ReadError("Cannot register \(binding.label). It may be used by another app (\(status)).") }
        if let reference { UnregisterEventHotKey(reference) }
        reference = replacement; current = binding
    }

    static func configure(_ state: ReaderState) {
        let alert = NSAlert(); alert.messageText = L("Global Screenshot Shortcut")
        alert.informativeText = L("Press a shortcut with Command, Control or Option, or a function key. Sumra must be running.")
        let recorder = Recorder(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        recorder.binding = current
        alert.accessoryView = recorder; alert.window.initialFirstResponder = recorder
        alert.addButton(withTitle: L("Apply")); alert.addButton(withTitle: L("Clear")); alert.addButton(withTitle: L("Cancel"))
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn || result == .alertSecondButtonReturn else { return }
        let binding = result == .alertSecondButtonReturn ? nil : recorder.binding
        do {
            try register(binding)
            UserDefaults.standard.set(try binding.map { try JSONEncoder().encode($0) }, forKey: "screenshotHotkey")
        } catch { state.error = error.localizedDescription }
    }

    private final class Recorder: NSView {
        private let label = NSTextField(labelWithString: L("Press shortcut keys…"))
        var binding: Binding? { didSet { label.stringValue = binding?.label ?? L("Press shortcut keys…") } }
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            label.frame = bounds; label.alignment = .center; label.font = .systemFont(ofSize: 17)
            label.autoresizingMask = [.width, .height]; addSubview(label)
        }
        required init?(coder: NSCoder) { return nil }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { NSApp.abortModal(); return }
            let flags = event.modifierFlags
            let character = event.charactersIgnoringModifiers?.unicodeScalars.first
            let function = character.map { (0xf704...0xf71b).contains(Int($0.value)) } ?? false
            guard function || !flags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
            var modifiers: UInt32 = 0, name = ""
            for (flag, carbon, text) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) {
                modifiers |= UInt32(carbon); name += text
            }
            name += function ? "F\(Int(character!.value) - 0xf704 + 1)" : (event.charactersIgnoringModifiers ?? String(event.keyCode)).uppercased()
            binding = .init(code: UInt32(event.keyCode), modifiers: modifiers, label: name)
        }
    }
}
#endif
