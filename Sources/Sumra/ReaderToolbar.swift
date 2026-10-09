#if os(macOS)
import SwiftUI
import AppKit
import Darwin
import SumraCore

// AppKit owns the actual toolbar field editor, including programmatic focus.
@MainActor struct ReaderPageInput: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let finished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: state.pageLabel)
        field.alignment = .center; field.bezelStyle = .roundedBezel
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        state.pageInputField = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        state.pageInputField = field
        field.isEnabled = state.count > 0
        field.toolTip = state.positionLabel
        field.setAccessibilityLabel(L("Go to Page"))
        if let editor = field.currentEditor() as? NSTextView {
            // Focus alone must not freeze the page label; actual input owns its draft.
            guard !context.coordinator.hasDraft, !editor.hasMarkedText(), editor.string != state.pageLabel else { return }
            let selection = editor.selectedRange()
            let selectedAll = selection == NSRange(location: 0, length: (editor.string as NSString).length)
            field.stringValue = state.pageLabel
            editor.string = state.pageLabel
            let length = (editor.string as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(selectedAll ? NSRange(location: 0, length: length)
                : NSRange(location: location, length: min(selection.length, length - location)))
        } else { field.stringValue = state.pageLabel }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.abortEditing()
        if coordinator.parent.state.pageInputField === field { coordinator.parent.state.pageInputField = nil }
        field.delegate = nil
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReaderPageInput
        var hasDraft = false
        init(_ parent: ReaderPageInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { hasDraft = false }
        func controlTextDidChange(_ notification: Notification) { hasDraft = true }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.state.go(textView.string) }
            else if selector != #selector(NSResponder.cancelOperation(_:)) { return false }
            parent.finished()
            return true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            hasDraft = false
            (notification.object as? NSTextField)?.stringValue = parent.state.pageLabel
        }
    }
}

/// A toolbar entry refers to an existing command owner. It introduces no new
/// executable command syntax. Like Sumatra, an SVG takes precedence over text.
struct ReaderToolbarButton: Codable, Equatable {
    var command: String?
    var external: String?
    var custom: String?
    var text: String?
    var symbol: String?
    var svg: String?

    @MainActor static func read(_ json: String) throws -> [Self] {
        let entries = try JSONDecoder().decode([Self].self, from: Data(json.utf8))
        guard entries.count <= 127 else { throw ReadError("The toolbar supports up to 127 custom buttons") }
        for entry in entries {
            guard [entry.command, entry.external, entry.custom].compactMap({ $0 }).count == 1 else { throw ReadError("Each toolbar button needs exactly one command, external or custom reference") }
            if let command = entry.command, ReaderMenuCommand(rawValue: command) == nil { throw ReadError("Unknown toolbar command: \(command)") }
            if let external = entry.external, external.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ReadError("External toolbar commands need a name") }
            if let custom = entry.custom, custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ReadError("Custom toolbar commands need a name") }
            if let symbol = entry.symbol, !symbol.isEmpty, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
                throw ReadError("Unknown system symbol: \(symbol)")
            }
        }
        return entries
    }
}

@MainActor struct ReaderToolbarButtons: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    let open: () -> Void
    @AppStorage("toolbarButtons") private var configuration = "[]"
    @AppStorage("externalCommands") private var externalCommands = "[]"
    @AppStorage("customCommands") private var customCommands = "[]"

    var body: some View {
        let _ = language
        let external = (try? ExternalReaderCommand.read(externalCommands)) ?? []
        let custom = (try? ReaderConfiguredCommand.read(customCommands)) ?? []
        if let entries = try? ReaderToolbarButton.read(configuration) {
            HStack(spacing: 10) {
                if entries.isEmpty { Text(L("Custom Buttons")).foregroundStyle(.secondary) }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    let command = entry.command.flatMap(ReaderMenuCommand.init(rawValue:))
                    let externalCommand = external.first { $0.name == entry.external }
                    let customCommand = custom.first { $0.name == entry.custom }
                    let label = entry.text.flatMap { $0.isEmpty ? nil : $0 } ?? command?.title ?? entry.external ?? entry.custom ?? ""
                    Button {
                        if let command { if command == .open { open() } else { command.run(state) } }
                        else if let externalCommand { externalCommand.run(state) }
                        else { customCommand?.run(state) }
                    } label: {
                        if let svg = entry.svg, !svg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ReaderToolbarSVG(source: svg)
                        } else if let symbol = entry.symbol, !symbol.isEmpty { Image(systemName: symbol) }
                        else { Text(label) }
                    }
                    .disabled(!(command?.enabled(state) ?? externalCommand?.enabled(state) ?? customCommand?.enabled(state) ?? false))
                    .foregroundStyle(command?.checked(state) == true ? Color.accentColor : Color.primary)
                    .help(label)
                    .accessibilityLabel(label)
                    .accessibilityValue(command?.checked(state) == true ? L("On") : "")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Custom Buttons"))
        } else {
            Image(systemName: "exclamationmark.triangle").help(L("Invalid toolbar configuration. Open Settings → Toolbar."))
        }
    }
}

@MainActor private struct ReaderToolbarSVG: View {
    let source: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var error = ""
    private var content: String { source.replacingOccurrences(of: "currentColor", with: scheme == .dark ? "#ffffff" : "#000000") }
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: scale).resizable().frame(width: 20, height: 20) }
            else { Image(systemName: "exclamationmark.triangle").help(error) }
        }
        .task(id: content + "\(scale)") {
            let content = content, size = max(1, Int((20 * scale).rounded(.up)))
            image = nil; error = ""
            do {
                let result = try await Task.detached(priority: .userInitiated) { try ReaderToolbarSVGRenderer.render(content, size: size) }.value
                guard !Task.isCancelled else { return }; image = result
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

enum ReaderToolbarSVGRenderer {
    private typealias Render = @convention(c) (UnsafePointer<UInt8>, Int, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
    private static let renderer: Result<Render, Error> = Result {
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(url.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load MuPDF for SVG icons: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
        }
        guard let symbol = dlsym(library, "lf_svg_icon") else { dlclose(library); throw ReadError("The MuPDF engine does not support toolbar SVG icons") }
        // This process-wide function pointer keeps its one library handle alive.
        return unsafeBitCast(symbol, to: Render.self)
    }

    static func render(_ source: String, size: Int = 40) throws -> CGImage {
        guard (1...256).contains(size), !source.isEmpty else { throw ReadError("Invalid SVG icon dimensions") }
        let render = try renderer.get(), bytes = Array(source.utf8)
        var error = [CChar](repeating: 0, count: 512)
        guard let pointer = render(bytes, bytes.count, Int32(size), &error) else {
            throw ReadError(error.first == 0 ? "Cannot render SVG icon" : String(cString: error))
        }
        let data = Data(bytesNoCopy: pointer, count: size * size * 4, deallocator: .free)
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ReadError("Cannot create SVG icon image") }
        return image
    }
}

@MainActor struct ReaderToolbarSettings: View {
    @AppStorage("language") private var language = "system"
    @AppStorage("toolbarButtons") private var configuration = "[]"
    @AppStorage("externalCommands") private var externalCommands = "[]"
    @AppStorage("customCommands") private var customCommands = "[]"
    @State private var draft = ""
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        let _ = language
        VStack(alignment: .leading) {
            Text(L("Custom Toolbar Buttons")).font(.headline)
            Text(L("Buttons use existing command IDs or a named custom or external command. Optional text, symbol and svg customize their appearance. Drag the Custom Buttons group in Customize Toolbar to move or hide it.")).font(.caption).foregroundStyle(.secondary)
            Menu(L("Add Command")) {
                ForEach(ReaderMenuCommand.allCases) { command in Button(command.title) { add(.init(command: command.rawValue)) } }
                if let custom = try? ReaderConfiguredCommand.read(customCommands), !custom.isEmpty {
                    Divider()
                    ForEach(custom) { command in Button(command.name) { add(.init(custom: command.name)) } }
                }
                if let external = try? ExternalReaderCommand.read(externalCommands), !external.isEmpty {
                    Divider()
                    ForEach(external) { command in Button(command.name) { add(.init(external: command.name)) } }
                }
            }
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(minHeight: 200)
            Text("[{\"command\":\"print\",\"symbol\":\"printer\"},{\"external\":\"Preview\",\"text\":\"Preview\"}]").font(.caption).textSelection(.enabled)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            Button(L("Save")) { save() }.disabled(saving)
        }.padding().onAppear { draft = configuration }
    }

    private func add(_ button: ReaderToolbarButton) {
        do {
            var entries = try ReaderToolbarButton.read(draft)
            entries.append(button)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            draft = String(decoding: try encoder.encode(entries), as: UTF8.self); error = ""
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            let entries = try ReaderToolbarButton.read(draft), external = try ExternalReaderCommand.read(externalCommands), custom = try ReaderConfiguredCommand.read(customCommands)
            for entry in entries {
                if let name = entry.external, !external.contains(where: { $0.name == name }) { throw ReadError("Unknown external command: \(name)") }
                if let name = entry.custom, !custom.contains(where: { $0.name == name }) { throw ReadError("Unknown custom command: \(name)") }
            }
            let value = draft, icons = entries.compactMap(\.svg).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await Task.detached { for svg in icons { _ = try ReaderToolbarSVGRenderer.render(svg.replacingOccurrences(of: "currentColor", with: "#000000")) } }.value
                    configuration = value; error = ""
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
#endif
