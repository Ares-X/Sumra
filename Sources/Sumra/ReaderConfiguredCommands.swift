#if os(macOS)
import SwiftUI
import SumraCore

// Typed options for the reachable Sumatra custom-command arguments. Execution
// stays at the existing reader owners; this is not a command language.
struct ReaderCommandArguments: Codable, Equatable {
    var n: Int?
    var level: String?
    var theme: String?
    var state: Bool?
    var file: String?
    var page: Int?
    var mode: String?
    var annotation: PDFAnnotationPreset?

    func validate(for command: ReaderMenuCommand) throws {
        if let n, n < 0 || ![.next, .previous, .scrollUp, .scrollDown].contains(command) { throw ReadError("n requires a page or vertical scroll command and a nonnegative count") }
        if let level {
            guard command == .customZoom else { throw ReadError("level requires customZoom") }
            if ReadingZoom.fitTitles[level] == nil { _ = try ReadingZoom.parsePercent(level, limit: ReadingZoom.absoluteMaximum) }
        }
        if let theme, command != .setTheme || (theme != "system" && !ReaderTheme.all.contains { $0.id == theme }) { throw ReadError("Unknown theme or command") }
        if state != nil, ![.continuous, .toolbar, .fullscreen, .presentation, .bookmarks, .contents].contains(command) { throw ReadError("state requires a supported toggle command") }
        if file != nil || page != nil {
            guard [.open, .openNoHistory].contains(command), let file, !file.isEmpty, !file.contains("\0"), page.map({ $0 >= 1 }) ?? true else { throw ReadError("file and one-based page require an open command") }
        }
        if let mode, command != .palette || ![">", "@", "#", "$", "%", "&", "*", "="].contains(mode) { throw ReadError("Unknown palette mode") }
        if let annotation {
            guard command.annotationKind != nil else { throw ReadError("annotation options require an annotation creation command") }
            try annotation.validate()
        }
    }

    @MainActor func run(_ command: ReaderMenuCommand, in reader: ReaderState) {
        if let file {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            if command == .openNoHistory { reader.openWithoutHistory(url, at: page.map { ReadingPosition(page: $0 - 1) }) }
            else if let page { reader.open(url, at: ReadingPosition(page: page - 1)) }
            else { reader.open(url) }
        } else if let n {
            switch command {
            case .next: reader.turn(1, count: n)
            case .previous: reader.turn(-1, count: n)
            case .scrollUp: if n > 0 { reader.scroll(.up, count: n) }
            case .scrollDown: if n > 0 { reader.scroll(.down, count: n) }
            default: break
            }
        } else if let level {
            if ReadingZoom.fitTitles[level] != nil { reader.setFit(level) }
            else { do { reader.setZoom(try ReadingZoom.parsePercent(level, limit: reader.configuredZoomMaximum)) } catch { reader.error = error.localizedDescription } }
        } else if let theme { reader.setTheme(theme) }
        else if let state {
            if command == .continuous { reader.setFlow(state ? "continuous" : "paged") }
            else if command.checked(reader) != state { command.run(reader) }
        } else if let mode { reader.paletteMode = mode + " "; reader.showPalette = true }
        else if let annotation, let kind = command.annotationKind { reader.send(.annotate(kind, preset: annotation)) }
        else if command == .open {
            chooseDocuments { urls in
                ReaderWindows.open(urls, in: reader) { reader.createWindow?($0) }
            }
        } else { command.run(reader) }
    }
}

extension ReaderMenuCommand {
    var annotationKind: String? {
        switch self {
        case .highlight, .underline, .strike, .squiggly, .note, .freeText, .ink, .line, .square, .circle, .link, .caret, .stamp, .polygon, .polyline, .attachment: return rawValue
        case .redactMark: return "redact"
        default: return nil
        }
    }
}

struct ReaderConfiguredCommand: Codable, Identifiable {
    var name: String
    var command: ReaderMenuCommand
    var arguments: ReaderCommandArguments?
    var shortcut: String?
    var id: String { name }

    static func read(_ json: String) throws -> [Self] {
        let commands = try JSONDecoder().decode([Self].self, from: Data(json.utf8))
        var names = Set<String>()
        for entry in commands {
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, names.insert(entry.name).inserted else { throw ReadError("Custom commands need unique names") }
            try entry.arguments?.validate(for: entry.command)
            if let shortcut = entry.shortcut, !readerShortcutBindings(shortcut).allSatisfy({ readerShortcut($0) != nil }) { throw ReadError("Invalid shortcut for \(entry.name)") }
        }
        return commands
    }

    @MainActor func enabled(_ state: ReaderState?) -> Bool { state != nil && command.enabled(state) }
    @MainActor func run(_ state: ReaderState) {
        guard enabled(state) else { return }
        (arguments ?? ReaderCommandArguments()).run(command, in: state)
    }
}

struct ReaderConfiguredCommandMenu: View {
    @FocusedObject private var state: ReaderState?
    @AppStorage("customCommands") private var commands = "[]"
    @AppStorage("language") private var language = "system"
    var body: some View {
        let _ = language
        if let entries = try? ReaderConfiguredCommand.read(commands), !entries.isEmpty {
            Menu(L("Custom Commands")) {
                ForEach(entries) { entry in Button(entry.name) { if let state { entry.run(state) } }.disabled(!entry.enabled(state)) }
            }
        }
    }
}

struct ReaderConfiguredCommandSettings: View {
    @AppStorage("customCommands") private var commands = "[]"
    @AppStorage("language") private var language = "system"
    @State private var draft = ""
    @State private var error = ""
    var body: some View {
        let _ = language
        VStack(alignment: .leading) {
            Text(L("Named commands reuse existing actions. Optional arguments set page/scroll counts, zoom, theme, toggle state, file/page, palette mode or annotation defaults.")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced))
            Text("[{\"name\":\"Next 3 pages\",\"command\":\"next\",\"arguments\":{\"n\":3},\"shortcut\":\"alt+right\"}]").font(.caption).textSelection(.enabled)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            Button(L("Save")) { do { _ = try ReaderConfiguredCommand.read(draft); commands = draft; error = "" } catch { self.error = error.localizedDescription } }
        }.padding().onAppear { draft = commands }
    }
}
#endif
