#if os(macOS)
import AppKit
import Darwin
import SumraCore
import SwiftUI

// Structured argv follows the existing source-editor contract. Substitution
// never passes a document title or selection through an implicit shell.
struct ExternalReaderCommand: Codable, Identifiable {
    var name: String
    var arguments: [String]
    var extensions: [String]?
    var needsSelection: Bool?
    var filter: String?
    var shortcut: String?
    var url: String?
    var method: String?
    var body: String?
    var contentType: String?
    var headers: [String: String]?
    var id: String { name }
    private var sendMethod: String { method?.uppercased() ?? "GET" }
    private var templates: [String] { arguments + [url, body].compactMap { $0 } }

    private enum CodingKeys: String, CodingKey {
        case name, arguments, extensions, needsSelection, filter, shortcut, url, method, body, contentType, headers
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        extensions = try values.decodeIfPresent([String].self, forKey: .extensions)
        needsSelection = try values.decodeIfPresent(Bool.self, forKey: .needsSelection)
        filter = try values.decodeIfPresent(String.self, forKey: .filter)
        shortcut = try values.decodeIfPresent(String.self, forKey: .shortcut)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        method = try values.decodeIfPresent(String.self, forKey: .method)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        headers = try values.decodeIfPresent([String: String].self, forKey: .headers)
    }

    static func read(_ json: String) throws -> [Self] {
        let commands = try JSONDecoder().decode([Self].self, from: Data(json.utf8))
        var names = Set<String>()
        for command in commands {
            guard !command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  names.insert(command.name).inserted else { throw ReadError("External commands need unique, nonempty names") }
            if let shortcut = command.shortcut,
               readerShortcutBindings(shortcut).contains(where: { readerShortcut($0) == nil }) {
                throw ReadError("Invalid keyboard shortcut for \(command.name)")
            }
            if let url = command.url {
                guard !url.isEmpty, command.arguments.isEmpty,
                      ["GET", "POST", "POST-VIA-BROWSER"].contains(command.sendMethod) else {
                    throw ReadError("A selection handler needs a URL and GET, POST or POST-VIA-BROWSER; use arguments for an executable instead")
                }
                if command.sendMethod != "POST", command.headers?.isEmpty == false {
                    throw ReadError("Custom headers require POST; a browser form cannot set request headers")
                }
            } else {
                guard let executable = command.arguments.first, !executable.isEmpty,
                      command.arguments.allSatisfy({ !$0.contains("\0") }) else {
                    throw ReadError("External programs need a nonempty argument array")
                }
            }
        }
        return commands
    }

    func matches(_ file: URL) -> Bool {
        guard extensions?.isEmpty != false || extensions!.contains(where: { $0.caseInsensitiveCompare(file.pathExtension) == .orderedSame }) else { return false }
        guard let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty, filter != "*" else { return true }
        return filter.split(separator: ";").contains {
            let pattern = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return fnmatch(pattern, file.lastPathComponent.lowercased(), 0) == 0
        }
    }
    @MainActor func enabled(_ state: ReaderState?) -> Bool {
        guard let state, let file = state.document?.url else { return false }
        return (needsSelection != true && url == nil || state.hasTextSelection) && matches(file)
    }

    @MainActor func run(_ state: ReaderState) {
        guard enabled(state), let document = state.document else { return }
        let file = document.url, documentID = document.id
        let selection = state.isBrowser ? nil : state.selectedText
        let page = state.page, zoom = state.fit == "custom" ? state.zoom * 100 : 100
        let x = state.location.x ?? 0, y = state.location.y ?? 0
        let language = ReaderLocalization.language, screenBounds = state.selectionScreenBounds
        Task { @MainActor [weak state] in
            do {
                guard let state, state.document?.id == documentID else { return }
                let text: String
                if let selection { text = selection }
                else if needsSelection == true || url != nil || uses("selection") || uses("selectionjson") || uses("selectionfile") {
                    text = try await state.selectionText()
                } else { text = "" }
                guard needsSelection != true && url == nil || !text.isEmpty else { state.status = "No text in the selection"; return }
                let position = uses("selectionposition") ? await screenBounds?() : nil
                guard state.document?.id == documentID else { return }
                var temporary: TemporaryDirectory?
                var selectionFile = ""
                if uses("selectionfile") {
                    let directory = try TemporaryDirectory(), path = directory.url.appendingPathComponent("Selection.txt")
                    try text.write(to: path, atomically: true, encoding: .utf8)
                    temporary = directory; selectionFile = path.path
                }
                let variables = try Self.variables(file: file, page: page, selection: text, zoom: zoom, x: x, y: y,
                                                  language: language, selectionFile: selectionFile, selectionPosition: position)
                if let url {
                    let target = try Self.handlerURL(url, variables: variables)
                    if sendMethod == "POST-VIA-BROWSER" {
                        let html = Self.formHTML(url: target, body: body ?? "text=${selection}", variables: variables)
                        let directory = try temporary ?? TemporaryDirectory(), path = directory.url.appendingPathComponent("Selection.html")
                        try html.write(to: path, atomically: true, encoding: .utf8)
                        guard NSWorkspace.shared.open(path) else { throw ReadError("Cannot open the selection handler in the browser") }
                        state.browserTemporary = directory
                    } else if sendMethod == "POST" {
                        let request = Self.postRequest(url: target, body: body, contentType: contentType, headers: headers, variables: variables)
                        let session = URLSession(configuration: .ephemeral)
                        defer { session.invalidateAndCancel(); withExtendedLifetime(temporary) {} }
                        let (stream, response) = try await session.bytes(for: request)
                        var bytes = Data()
                        for try await byte in stream.prefix(4096) { bytes.append(byte) }
                        guard state.document?.id == documentID else { return }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let detail = String(String(decoding: bytes, as: UTF8.self).prefix(300))
                        let message = "\(name): HTTP \(status)" + (detail.isEmpty ? "" : "\n" + detail)
                        if (200..<300).contains(status) { state.status = message } else { state.error = message }
                    } else {
                        guard NSWorkspace.shared.open(target) else { throw ReadError("Cannot open the selection handler URL") }
                        if let temporary { state.browserTemporary = temporary }
                    }
                } else {
                    let argv = Self.expand(arguments, replacements: variables)
                    let process = Process(), program = (argv[0] as NSString).expandingTildeInPath
                    if program.contains("/") { process.executableURL = URL(fileURLWithPath: program); process.arguments = Array(argv.dropFirst()) }
                    else { process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = argv }
                    process.currentDirectoryURL = file.deletingLastPathComponent()
                    process.terminationHandler = { [weak state, temporary] process in
                        withExtendedLifetime(temporary) {}
                        guard process.terminationStatus != 0 else { return }
                        Task { @MainActor in
                            guard state?.document?.id == documentID else { return }
                            state?.error = "\(name) exited with status \(process.terminationStatus)"
                        }
                    }
                    try process.run()
                }
            } catch { if state?.document?.id == documentID { state?.error = error.localizedDescription } }
        }
    }

    private func uses(_ key: String) -> Bool {
        templates.contains { $0.range(of: "{\(key)}", options: .caseInsensitive) != nil }
    }
    static func variables(file: URL, page: Int, selection: String, zoom: Double = 100, x: Double = 0, y: Double = 0,
                          language: String = "en", selectionFile: String = "", selectionPosition: CGRect? = nil) throws -> [String: String] {
        let json = String(decoding: try JSONEncoder().encode(selection), as: UTF8.self)
        let position = selectionPosition.map { [ $0.minX, $0.minY, $0.width, $0.height ].map { String(Int($0.rounded())) }.joined(separator: ",") } ?? ""
        let values = ["file": file.path, "folder": file.deletingLastPathComponent().path, "page": String(page+1),
                      "zoom": String(zoom), "x": String(x), "y": String(y), "selection": selection,
                      "selectionjson": String(json.dropFirst().dropLast()), "selectionfile": selectionFile,
                      "userlang": language, "selectionposition": position]
        var result = [String: String]()
        for (key, value) in values { result["{\(key)}"] = value; result["${\(key)}"] = value }
        for (token, key) in ["%1": "file", "%d": "folder", "%p": "page", "%z": "zoom", "%x": "x", "%y": "y"] { result[token] = values[key] }
        result["%%"] = "%"
        return result
    }
    static func expand(_ arguments: [String], replacements: [String: String]) -> [String] {
        let pattern = try! NSRegularExpression(pattern: replacements.keys.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"), options: .caseInsensitive)
        return arguments.map { argument in
            let original = argument as NSString, result = NSMutableString(string: argument)
            for match in pattern.matches(in: argument, range: NSRange(location: 0, length: original.length)).reversed() {
                result.replaceCharacters(in: match.range, with: replacements[original.substring(with: match.range).lowercased()]!)
            }
            return String(result)
        }
    }
    static func handlerURL(_ template: String, variables: [String: String]) throws -> URL {
        var variables = variables
        // Every substituted value is data in a URL, including paths and JSON.
        // Encode before the single substitution pass; keep the user's URL and
        // separators intact rather than reparsing the resulting selected text.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for (key, value) in variables where key != "%%" {
            variables[key] = value.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        let text = expand([template.contains("://") ? template : "https://" + template], replacements: variables)[0]
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw ReadError("The selection handler needs a valid HTTP or HTTPS URL") }
        return url
    }
    static func postRequest(url: URL, body: String?, contentType: String?, headers: [String: String]?, variables: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(expand([body ?? "${selection}"], replacements: variables)[0].utf8)
        request.setValue(contentType ?? "text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
    static func formHTML(url: URL, body: String, variables: [String: String]) -> String {
        // SelectionHandlers.cpp splits the form template before substitution so
        // selected '&' and '=' characters cannot create additional form fields.
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\r", with: "&#13;")
        }
        let fields = body.split(separator: "&").compactMap { field -> String? in
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let value = expand([parts.count == 2 ? String(parts[1]) : ""], replacements: variables)[0]
            return "<input type=\"hidden\" name=\"\(escape(String(name)))\" value=\"\(escape(value))\">"
        }.joined()
        return "<!doctype html><meta charset=\"utf-8\"><title>Send Selection</title><body onload=\"document.forms[0].submit()\"><form method=\"post\" accept-charset=\"utf-8\" action=\"\(escape(url.absoluteString))\">\(fields)<noscript><button type=\"submit\">Continue</button></noscript></form></body>"
    }
}

// SelectionTranslate.cpp's popular-language list and browser URL workflow.
// Language codes remain compatible with the existing external-action settings.
enum ReaderTranslation {
    static let languages: [(name: String, code: String)] = [
        ("English", "en"), ("Chinese (Simplified)", "zh-CN"), ("Chinese (Traditional)", "zh-TW"),
        ("Spanish", "es"), ("Arabic", "ar"), ("Hindi", "hi"), ("Portuguese", "pt"), ("Bengali", "bn"),
        ("Russian", "ru"), ("Japanese", "ja"), ("Punjabi", "pa"), ("German", "de"), ("French", "fr"),
        ("Korean", "ko"), ("Turkish", "tr"), ("Vietnamese", "vi"), ("Italian", "it"), ("Polish", "pl"),
        ("Ukrainian", "uk"), ("Dutch", "nl"), ("Thai", "th"), ("Indonesian", "id"), ("Czech", "cs"),
        ("Swedish", "sv"), ("Romanian", "ro"), ("Greek", "el"), ("Hebrew", "he"), ("Danish", "da"),
        ("Finnish", "fi"), ("Norwegian", "no"), ("Hungarian", "hu"), ("Slovak", "sk")
    ]
    static var targetLanguage: String {
        resolvedTarget(UserDefaults.standard.string(forKey: "translationTarget"), preferredLanguages: Locale.preferredLanguages)
    }
    static func resolvedTarget(_ saved: String?, preferredLanguages: [String]) -> String {
        let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return languageCode(saved, source: false) }
        let system = languageCode(preferredLanguages.first ?? "en", source: false)
        let base = system.split(separator: "-").first.map { String($0) }
        return languages.first(where: { $0.code == base })?.code ?? system
    }
    static func engine(_ requested: String?, saved: String?) -> String {
        (requested ?? saved)?.caseInsensitiveCompare("deepl") == .orderedSame ? "deepl" : "google"
    }
    static func languageCode(_ value: String, source: Bool) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.caseInsensitiveCompare("auto") == .orderedSame || value == L("Auto") { return source ? "auto" : "en" }
        if let language = languages.first(where: {
            value.caseInsensitiveCompare($0.name) == .orderedSame || value.caseInsensitiveCompare($0.code) == .orderedSame || value == L($0.name)
        }) { return language.code }
        let code = value.replacingOccurrences(of: "_", with: "-").lowercased(), parts = code.split(separator: "-")
        if parts.first == "zh" { return parts.contains(where: { ["hant", "tw", "hk", "mo"].contains(String($0)) }) ? "zh-TW" : "zh-CN" }
        if parts.first == "nb" || parts.first == "nn" { return "no" }
        // Keep user-entered ISO codes supported by a browser but absent from
        // the short popular-language list. Unknown names use upstream defaults.
        if let base = parts.first, Locale.isoLanguageCodes.contains(String(base)),
           parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) } }) { return code }
        return source ? "auto" : "en"
    }
    static func languageName(_ code: String) -> String {
        code == "auto" ? L("Auto") : languages.first(where: { $0.code == code }).map { L($0.name) } ?? code
    }
    static func canTranslate(text: String, source: String, target: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (source == "auto" || source != target)
    }
    static func url(provider: String, source: String, target: String, text: String) -> URL? {
        var source = languageCode(source, source: true), target = languageCode(target, source: false)
        guard canTranslate(text: text, source: source, target: target) else { return nil }
        if provider == "deepl" {
            if source.hasPrefix("zh") { source = "zh" }
            if target.hasPrefix("zh") { target = "zh" }
            var components = URLComponents(string: "https://www.deepl.com/translator")!
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
            components.percentEncodedFragment = [source, target, text].map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
            return components.url
        }
        var components = URLComponents(string: "https://translate.google.com/")!
        components.queryItems = [.init(name: "op", value: "translate"), .init(name: "sl", value: source), .init(name: "tl", value: target), .init(name: "text", value: text)]
        return components.url
    }
}

@MainActor private final class SelectionTranslationDialog: NSObject, NSTextViewDelegate, NSComboBoxDelegate {
    private let alert = NSAlert(), source = NSComboBox(), target = NSComboBox()
    private let engine = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scroll = NSTextView.scrollableTextView()
    private let translate = NSButton(), status = NSTextField(wrappingLabelWithString: "")
    private var editor: NSTextView { scroll.documentView as! NSTextView }

    init(text: String, provider: String?) {
        super.init()
        alert.messageText = L("Translate"); alert.alertStyle = .informational
        engine.addItems(withTitles: ["Google", "DeepL"])
        let preferred = ReaderTranslation.engine(provider, saved: UserDefaults.standard.string(forKey: "translationEngine"))
        engine.selectItem(at: preferred == "deepl" ? 1 : 0)
        source.addItems(withObjectValues: [L("Auto")] + ReaderTranslation.languages.map { L($0.name) })
        target.addItems(withObjectValues: ReaderTranslation.languages.map { L($0.name) })
        source.stringValue = ReaderTranslation.languageName(ReaderTranslation.languageCode(UserDefaults.standard.string(forKey: "translationSource") ?? "auto", source: true))
        target.stringValue = ReaderTranslation.languageName(ReaderTranslation.targetLanguage)
        source.delegate = self; target.delegate = self
        source.setAccessibilityLabel(L("From")); target.setAccessibilityLabel(L("To")); engine.setAccessibilityLabel(L("Engine"))
        editor.isRichText = false; editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.string = text; editor.delegate = self
        editor.setAccessibilityLabel(L("Original text"))
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Engine")), engine],
            [NSTextField(labelWithString: L("From")), source],
            [NSTextField(labelWithString: L("To")), target]
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 12
        source.widthAnchor.constraint(equalToConstant: 340).isActive = true
        target.widthAnchor.constraint(equalTo: source.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
        translate.title = L("Translate"); translate.bezelStyle = .rounded
        translate.target = self; translate.action = #selector(openTranslation); translate.keyEquivalent = "\r"
        translate.keyEquivalentModifierMask = [.command]
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [NSTextField(labelWithString: L("Original text")), scroll, grid, translate, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame.size = NSSize(width: 460, height: 420)
        status.widthAnchor.constraint(equalToConstant: 460).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: L("Close")).keyEquivalent = "\u{1b}"
        updateButton()
    }
    func show(over window: NSWindow?) {
        alert.window.initialFirstResponder = editor
        if let window { alert.beginSheetModal(for: window) { [self] _ in withExtendedLifetime(self) {} } }
        else { alert.runModal() }
    }
    func textDidChange(_ notification: Notification) { updateButton() }
    func controlTextDidChange(_ notification: Notification) { updateButton() }
    func comboBoxSelectionDidChange(_ notification: Notification) { updateButton() }
    private func updateButton() {
        let from = ReaderTranslation.languageCode(source.stringValue, source: true)
        let to = ReaderTranslation.languageCode(target.stringValue, source: false)
        translate.isEnabled = ReaderTranslation.canTranslate(text: editor.string, source: from, target: to)
    }
    @objc private func openTranslation() {
        let provider = engine.indexOfSelectedItem == 1 ? "deepl" : "google"
        let from = ReaderTranslation.languageCode(source.stringValue, source: true)
        let to = ReaderTranslation.languageCode(target.stringValue, source: false)
        guard let url = ReaderTranslation.url(provider: provider, source: from, target: to, text: editor.string) else { return }
        UserDefaults.standard.set(provider, forKey: "translationEngine")
        UserDefaults.standard.set(from, forKey: "translationSource")
        UserDefaults.standard.set(to, forKey: "translationTarget")
        status.stringValue = NSWorkspace.shared.open(url) ? "" : L("Cannot open the translator in the browser.")
    }
}

extension ReaderState {
    // URL templates follow SumatraPDF.cpp selection handlers and
    // SelectionTranslate.cpp::BuildTranslateUrlTemp; Foundation owns escaping.
    func searchSelection(_ provider: String) {
        let urls = ["google": "https://www.google.com/search", "bing": "https://www.bing.com/search", "wikipedia": "https://wikipedia.org/w/index.php", "scholar": "https://scholar.google.com/scholar"]
        guard let base = urls[provider], var components = URLComponents(string: base) else { return }
        Task {
            do {
                let text = try await selectionText()
                guard !text.isEmpty else { status = "No text in the selection"; return }
                components.queryItems = [URLQueryItem(name: provider == "wikipedia" ? "search" : "q", value: text)]
                if let url = components.url { NSWorkspace.shared.open(url) }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func translateSelection(_ provider: String? = nil) {
        Task {
            do {
                let text = try await selectionText()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "No text in the selection"; return }
                SelectionTranslationDialog(text: text, provider: provider).show(over: window)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ExternalCommandMenu: View {
    @FocusedObject private var state: ReaderState?
    @AppStorage("externalCommands") private var commands = "[]"
    @AppStorage("language") private var language = "system"
    var body: some View {
        let _ = language
        Menu(L("External Commands")) {
            if let entries = try? ExternalReaderCommand.read(commands), !entries.isEmpty {
                ForEach(entries) { command in Button(command.name) { if let state { command.run(state) } }.disabled(!command.enabled(state)) }
            } else { Text(L("Configure in Settings → External")) }
        }
    }
}

struct ExternalActionSettings: View {
    @AppStorage("externalCommands") private var commands = "[]"
    @AppStorage("language") private var language = "system"
    @AppStorage("translationSource") private var source = "auto"
    @AppStorage("translationTarget") private var target = ""
    @State private var draft = ""
    @State private var error = ""
    var body: some View {
        let _ = language
        VStack(alignment: .leading) {
            TextField(L("Source language code (auto detects)"), text: $source)
            TextField(L("Target language code"), text: $target)
            Text(L("Blank follows the system language")).font(.caption).foregroundStyle(.secondary)
            Text(L("External commands")).font(.headline)
            Text(L("Use {file}, {folder}, {page}, {zoom}, {x}, {y}, {selection}, {selectionjson}, {selectionfile}, {selectionposition} or {userlang}. Optional extensions, wildcard filter and needsSelection control availability; shortcut uses the keyboard shortcut syntax.")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced))
            Text(L("Example:") + " [{\"name\":\"Preview\",\"arguments\":[\"/usr/bin/open\",\"-a\",\"Preview\",\"{file}\"],\"extensions\":[\"pdf\"]}]").font(.caption).textSelection(.enabled)
            Text(L("URL handler:") + " [{\"name\":\"Search\",\"url\":\"https://www.google.com/search?q=${selection}\"}]\n" + L("POST supports body, contentType and headers; POST-VIA-BROWSER sends body as form fields.") + " (text=${selection}&lang=${userlang})").font(.caption).textSelection(.enabled)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            Button(L("Save")) { do { _ = try ExternalReaderCommand.read(draft); commands = draft; error = "" } catch { self.error = error.localizedDescription } }
        }.padding().onAppear { draft = commands }
    }
}
#endif
