#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import SumraCore

struct SettingsView:View{
    @AppStorage("appIcon") private var appIcon = "light"
    @AppStorage("language") private var language = "system"
    @AppStorage("theme") private var theme="system"
    @AppStorage("flow") private var flow="paged"
    @AppStorage("scrollbarMode") private var scrollbarMode = "smart"
    @AppStorage("fit") private var fit="page"
    @AppStorage("zoomLevels") private var zoomLevels = ""
    @AppStorage("zoomIncrement") private var zoomIncrement = 0.0
    @AppStorage("spread") private var spread=false
    @AppStorage("automaticLayout") private var automaticLayout = false
    @AppStorage("pageAspectLayout") private var pageAspectLayout = false
    @AppStorage("landscapeAsSpread") private var landscapeAsSpread = true
    @AppStorage("rtl") private var rtl=false
    @AppStorage("cover") private var cover=false
    @AppStorage("font") private var font="system"
    @AppStorage("fontSize") private var fontSize=17.0
    @AppStorage("lineHeight") private var lineHeight=1.6
    @AppStorage("margin") private var margin=32.0
    @AppStorage("sourceEditor") private var sourceEditor="[]"
    @AppStorage("disableHistory") private var disableHistory = false
    @AppStorage("disableReadingState") private var disableReadingState = false
    @AppStorage("disableTabs") private var disableTabs = false
    @AppStorage("restoreSession") private var restoreSession = false
    @AppStorage("showContentsOnOpen") private var showContentsOnOpen = false
    @AppStorage("contentsDepth") private var contentsDepth = 0
    @AppStorage("sidebarRight") private var sidebarRight = false
    @AppStorage("fullPathTitle") private var fullPathTitle = false
    @AppStorage("pageInTitle") private var pageInTitle = false
    @AppStorage("SUEnableAutomaticChecks") private var checkForUpdates = true
    @AppStorage("updateChannel") private var updateChannel = "stable"
    var body:some View{
        let _ = checkForUpdates
        TabView{Form{
        Section(L("Appearance")){
            Picker(L("App icon"), selection: $appIcon) {
                ForEach(AppIconStyle.allCases) { Text(L($0.label)).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: appIcon) { AppIcon.apply($0) }
            Picker(L("Language"), selection: $language) {
                ForEach(ReaderLocalization.languages, id: \.self) { Text(ReaderLocalization.name($0)).tag($0) }
            }
            Text(L("Untranslated Sumra-specific text uses English.")).font(.caption).foregroundStyle(.secondary)
            Picker(L("Default theme"),selection:$theme){Text(L("System")).tag("system");ForEach(ReaderTheme.all) { Text(L($0.name)).tag($0.id) }}
            Picker(L("Default fit"),selection:$fit) { ForEach(ReadingZoom.fitTitles.keys.sorted(), id: \.self) { Text(L(ReadingZoom.fitTitles[$0]!)).tag($0) } }
            TextField(L("Zoom levels (%)"), text: $zoomLevels)
                .foregroundStyle((try? ReadingZoom.parseLevels(zoomLevels)) != nil ? Color.primary : .red)
            LabeledContent(L("Zoom increment (%)")) { TextField("0", value: $zoomIncrement, format: .number).frame(width: 70) }
            Text(L("Blank levels use the defaults. Zero increment steps through levels; a positive increment changes the current zoom proportionally.")).font(.caption).foregroundStyle(.secondary)
        }
        Section(L("Reading")){
            Toggle(L("Use document's preferred layout"), isOn: $automaticLayout)
            Toggle(L("Choose initial layout from page shape"), isOn: $pageAspectLayout).disabled(automaticLayout)
            Toggle(L("Landscape images occupy a whole spread"), isOn: $landscapeAsSpread)
            Picker(L("Default layout"),selection:$flow){Text(L("Paged")).tag("paged");Text(L("Continuous")).tag("continuous")}
            Picker(L("Scrollbars"), selection: $scrollbarMode) {
                Text(L("Automatic Scrollbars")).tag("smart")
                Text(L("Always Show Scrollbars")).tag("shown")
                Text(L("Hide Scrollbars")).tag("hidden")
            }
            Toggle(L("Open in two-page mode"),isOn:$spread);Toggle(L("Right-to-left by default"),isOn:$rtl)
            Toggle(L("Cover on its own"), isOn: $cover)
            Toggle(L("Remember recent documents"), isOn: Binding(get: { !disableHistory }, set: { disableHistory = !$0 }))
            Toggle(L("Remember reading positions"), isOn: Binding(get: { !disableReadingState }, set: { disableReadingState = !$0 }))
            Toggle(L("Use window tabs"), isOn: Binding(get: { !disableTabs }, set: { disableTabs = !$0 }))
            Toggle(L("Restore windows on launch"), isOn: $restoreSession)
            Toggle(L("Show contents when opening"), isOn: $showContentsOnOpen)
            Picker(L("Contents expansion"), selection: $contentsDepth) {
                Text(L("All levels")).tag(0)
                ForEach(1...3, id: \.self) { Text(String($0)).tag($0) }
            }
            Toggle(L("Sidebar on the right"), isOn: $sidebarRight)
            Toggle(L("Full path in window title"), isOn: $fullPathTitle)
            Toggle(L("Page in window title"), isOn: $pageInTitle)
        }
        Section(L("Updates")) {
            Toggle(L("Automatically check for updates"), isOn: Binding(get: { ReaderHelp.automaticUpdateChecks }, set: { ReaderHelp.setAutomaticUpdateChecks($0) }))
            Picker(L("Update channel"), selection: $updateChannel) {
                Text(L("Stable releases")).tag("stable")
                Text(L("Include prereleases")).tag("prerelease")
            }
            Button(L("Check for Updates…")) { ReaderHelp.checkForUpdates() }
            Text(L("Updates are checked daily. The prerelease channel also checks on startup. Sparkle verifies and installs updates after you approve them."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L("TeX source editor")) {
            Menu(L("Choose Installed Editor")) {
                Button(L("Default Application")) { sourceEditor = "[]" }
                ForEach(installedSourceEditors, id: \.name) { editor in
                    Button(editor.name) { if let data = try? JSONEncoder().encode(editor.arguments) { sourceEditor = String(decoding: data, as: UTF8.self) } }
                }
            }
            TextField(L("JSON argument array"), text: $sourceEditor)
            Text(L("Shift-Command-double-click a PDF to open its source. Use {file}, {line}, {column} in the argument array; [] uses the default app."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L("Default typography")){
            Picker(L("Font"),selection:$font){Text(L("System")).tag("system");Text(L("Serif")).tag("serif");Text(L("Sans Serif")).tag("sans-serif");Text(L("Monospace")).tag("monospace")}
            LabeledContent(L("Font size")){Slider(value:$fontSize,in:10...36,step:1).frame(width:190);Text("\(Int(fontSize)) pt").monospacedDigit().frame(width:45)}
            LabeledContent(L("Line height")){Slider(value:$lineHeight,in:1...2.4,step:0.1).frame(width:190);Text(lineHeight,format:.number.precision(.fractionLength(1))).frame(width:30)}
            LabeledContent(L("Margin")) {
                Slider(value: Binding(get: { margin }, set: { value in
                    margin = value
                    UserDefaults.standard.set(PageMargins(cssValues: [value]).flatMap { try? JSONEncoder().encode($0) }, forKey: "pageMargins")
                }), in: 0...96, step: 8).frame(width: 190)
                Text("\(Int(margin))").monospacedDigit().frame(width: 30)
            }
            Text(L("Adjusting margins overrides document styles on all four sides.")).font(.caption).foregroundStyle(.secondary)
        }
    }.formStyle(.grouped).tabItem { Text(L("Reading")) }
        ShortcutSettings().tabItem { Text(L("Shortcuts")) }
        ReaderConfiguredCommandSettings().tabItem { Text(L("Commands")) }
        ExternalActionSettings().tabItem { Text(L("External")) }
        ReaderToolbarSettings().tabItem { Text(L("Toolbar")) }
        AdvancedSettings().tabItem { Text(L("Advanced")) }
    }.padding().frame(width: 500, height: 540)
        .onChange(of: zoomLevels) { _ in ReaderPreferences.applyZoomDefaults() }
        .onChange(of: zoomIncrement) { _ in ReaderPreferences.applyZoomDefaults() }
        .onChange(of: scrollbarMode) { _ in ReaderPreferences.applyScrollbarDefaults() }
        .onChange(of: updateChannel) { _ in ReaderHelp.updateChannelChanged() }
    }

    private var installedSourceEditors: [(name: String, arguments: [String])] {
        [("Visual Studio Code", "com.microsoft.VSCode", "Contents/Resources/app/bin/code"),
         ("VSCodium", "com.vscodium", "Contents/Resources/app/bin/codium"),
         ("Cursor", "com.todesktop.230313mzl4w4u92", "Contents/Resources/app/bin/cursor")].compactMap { name, identifier, executable in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            let program = app.appendingPathComponent(executable)
            guard FileManager.default.isExecutableFile(atPath: program.path) else { return nil }
            return (name, [program.path, "--goto", "{file}:{line}:{column}"])
        }
    }
}
private struct ShortcutSettings: View {
    @AppStorage("shortcuts") private var shortcuts = "{}"
    @AppStorage("language") private var language = "system"
    private var overrides: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(shortcuts.utf8))) ?? [:]
    }
    var body: some View {
        let _ = language
        VStack(alignment: .leading) {
            Text(L("Use cmd, shift, alt, ctrl plus a letter, arrow, Tab, Home, End, PageUp, PageDown, Delete or F1–F24. Separate bindings with semicolons. Leave blank to disable."))
                .font(.caption).foregroundStyle(.secondary)
            List(ReaderMenuCommand.allCases) { command in
                HStack {
                    Text(command.title)
                    Spacer()
                    TextField(L("Shortcut"), text: Binding(
                        get: { overrides[command.id] ?? command.defaultShortcut },
                        set: { value in
                            var edited = overrides
                            edited[command.id] = value
                            if let data = try? JSONEncoder().encode(edited) { shortcuts = String(decoding: data, as: UTF8.self) }
                        }))
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(readerShortcutBindings(overrides[command.id] ?? command.defaultShortcut).allSatisfy { readerShortcut($0) != nil } ? Color.primary : .red)
                }
            }
            Button(L("Restore Defaults")) { shortcuts = "{}" }
        }.padding()
    }
}

// Export app preferences only. Saved documents, positions and provider state
// are separate user data and do not belong to an editable configuration.
@MainActor
enum ReaderPreferences {
    static let strings: Set<String> = Set(["appIcon", "theme", "flow", "fit", "font", "sourceEditor", "shortcuts", "externalCommands", "translationSource", "translationTarget", "translationEngine", "speechVoice", "userCSS", "language", "formatDefaults", "pageGridStyle", "documentColors", "engineeringEnhance", "zoomLevels", "scrollbarMode", "toolbarButtons", "customCommands", "updateChannel", "homePageViewMode"] + ReaderAIProvider.allCases.flatMap { ["aiModel:" + $0.id, "aiEffort:" + $0.id] })
    static func applyScrollbarDefaults() {
        let mode = UserDefaults.standard.string(forKey: "scrollbarMode") ?? "smart"
        for reader in ReaderWindows.states { reader.scrollbarMode = mode; if reader.isBrowser { reader.send(.style) } }
    }
    static let numbers: Set<String> = ["fontSize", "lineHeight", "margin", "speechRate", "contentsDepth", "sidebarWidth", "pageGridWidth", "pageGridHeight", "pageGridOffsetX", "pageGridOffsetY", "pageGridSubdivisions", "pageGridColor", "zoomIncrement"]
    static let booleans: Set<String> = ["spread", "rtl", "cover", "automaticLayout", "pageAspectLayout", "landscapeAsSpread", "invertColors", "grayscale", "preservePDFImages", "inverseSearchEnabled", "disableHistory", "disableReadingState", "disableTabs", "restoreSession", "useDocumentCSS", "useFixedPageUI", "showContentsOnOpen", "sidebarRight", "fullPathTitle", "pageInTitle", "checkForUpdates", "homePageSortByFrequentlyRead", "findFloating"]
    static var keys: Set<String> { strings.union(numbers).union(booleans) }

    static func boolean(for key: String) -> Bool {
        key == "checkForUpdates" ? ReaderHelp.automaticUpdateChecks : UserDefaults.standard.bool(forKey: key)
    }

    static func applyZoomDefaults() {
        guard let levels = try? ReadingZoom.parseLevels(UserDefaults.standard.string(forKey: "zoomLevels") ?? "") else { return }
        let increment = UserDefaults.standard.double(forKey: "zoomIncrement")
        guard increment.isFinite, increment >= 0 else { return }
        for reader in ReaderWindows.states { reader.zoomLevels = levels; reader.zoomIncrement = increment }
    }

    static func data(matching query: String = "") throws -> Data {
        ReaderHelp.migrateUpdatePreferences()
        var preferences = UserDefaults.standard.dictionaryRepresentation()
        // Preserve the public advanced-settings key while Sparkle owns persistence.
        preferences["checkForUpdates"] = boolean(for: "checkForUpdates")
        let values = preferences.filter {
            keys.contains($0.key) && (query.isEmpty || $0.key.localizedCaseInsensitiveContains(query))
        }
        return try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    }
    static func apply(_ data: Data) throws {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError("Settings must be a JSON object") }
        for (key, value) in values {
            guard keys.contains(key) else { throw ReadError("Unknown setting: \(key)") }
            if strings.contains(key), !(value is String) { throw ReadError("\(key) must be text") }
            if numbers.contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw ReadError("\(key) must be a finite number") }
                let ranges = ["fontSize": 10.0...36.0, "lineHeight": 1.0...2.4, "margin": 0.0...96.0, "speechRate": 90.0...540.0, "contentsDepth": 0.0...3.0, "sidebarWidth": 180.0...360.0, "pageGridWidth": 1.0...720.0, "pageGridHeight": 1.0...720.0, "pageGridOffsetX": -720.0...720.0, "pageGridOffsetY": -720.0...720.0, "pageGridSubdivisions": 1.0...32.0, "pageGridColor": 0.0...16777215.0, "zoomIncrement": 0.0...1000000.0]
                guard ranges[key]?.contains(number.doubleValue) == true else { throw ReadError("\(key) is outside its supported range") }
            }
            if booleans.contains(key), CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() { throw ReadError("\(key) must be true or false") }
            if key == "fit", let fit = value as? String, ReadingZoom.fitTitles[fit] == nil { throw ReadError("Unknown fit mode: \(fit)") }
            if key == "language", let language = value as? String, !ReaderLocalization.languages.contains(language) { throw ReadError("Unknown language: \(language)") }
            if key == "theme", let theme = value as? String, theme != "system", !ReaderTheme.all.contains(where: { $0.id == theme }) { throw ReadError("Unknown theme: \(theme)") }
            if key == "flow", let flow = value as? String, !["paged", "continuous"].contains(flow) { throw ReadError("Unknown layout: \(flow)") }
            let choices = ["appIcon": AppIconStyle.allCases.map(\.rawValue), "pageGridStyle": ["dots", "dotted", "solid"], "documentColors": ["off", "smart", "legacy"], "engineeringEnhance": ["off", "auto", "on"], "scrollbarMode": ["smart", "shown", "hidden"], "updateChannel": ["stable", "prerelease"], "homePageViewMode": ["list", "thumbnails"]]
            if let allowed = choices[key], let choice = value as? String, !allowed.contains(choice) { throw ReadError("Invalid value for \(key)") }
            if key == "zoomLevels", let string = value as? String { _ = try ReadingZoom.parseLevels(string) }
            if key == "sourceEditor", let string = value as? String { _ = try JSONDecoder().decode([String].self, from: Data(string.utf8)) }
            if key == "externalCommands", let string = value as? String { _ = try ExternalReaderCommand.read(string) }
            if key == "toolbarButtons", let string = value as? String { _ = try ReaderToolbarButton.read(string) }
            if key == "customCommands", let string = value as? String { _ = try ReaderConfiguredCommand.read(string) }
            if key == "formatDefaults", let string = value as? String { _ = try JSONDecoder().decode([String: ReadingPosition].self, from: Data(string.utf8)) }
            if key == "shortcuts", let string = value as? String {
                let shortcuts = try JSONDecoder().decode([String: String].self, from: Data(string.utf8))
                for (command, shortcut) in shortcuts {
                    guard ReaderMenuCommand(rawValue: command) != nil, readerShortcutBindings(shortcut).allSatisfy({ readerShortcut($0) != nil }) else { throw ReadError("Invalid shortcut for \(command)") }
                }
            }
        }
        for (key, value) in values {
            if key == "checkForUpdates", let enabled = value as? Bool { ReaderHelp.setAutomaticUpdateChecks(enabled) }
            else { UserDefaults.standard.set(value, forKey: key) }
        }
        if values["updateChannel"] != nil { ReaderHelp.updateChannelChanged() }
        if values["zoomLevels"] != nil || values["zoomIncrement"] != nil { applyZoomDefaults() }
        if values["scrollbarMode"] != nil { applyScrollbarDefaults() }
        if let icon = values["appIcon"] as? String { AppIcon.apply(icon) }
        NSWindow.allowsAutomaticWindowTabbing = !UserDefaults.standard.bool(forKey: "disableTabs")
        for state in ReaderWindows.states { state.window?.tabbingMode = UserDefaults.standard.bool(forKey: "disableTabs") ? .disallowed : .preferred }
    }
}

private struct AdvancedSettings: View {
    @AppStorage("language") private var language = "system"
    @State private var query = ""
    @State private var json = ""
    @State private var message = ""
    var body: some View {
        let _ = language
        VStack(alignment: .leading) {
            TextField(L("Filter setting names"), text: $query).onChange(of: query) { _ in load() }
            TextEditor(text: $json).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.3))
            Text(message.isEmpty ? L("Apply affects saved defaults. Current documents retain their reading settings.") : message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L("Reload"), action: load)
                Button(L("Apply")) { perform { try ReaderPreferences.apply(Data(json.utf8)); message = L("Saved") } }
                Spacer()
                Button(L("Import…")) {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        perform { try ReaderPreferences.apply(Data(contentsOf: url)); load(); message = L("Imported") }
                    }
                }
                Button(L("Export…")) {
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Sumra-settings.json"
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        perform { try ReaderPreferences.data().write(to: url, options: .atomic); message = L("Exported") }
                    }
                }
            }
        }.padding().onAppear(perform: load)
    }
    private func load() { perform { json = String(decoding: try ReaderPreferences.data(matching: query), as: UTF8.self); message = "" } }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
}
#endif
