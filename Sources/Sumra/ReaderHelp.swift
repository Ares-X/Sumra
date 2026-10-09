#if os(macOS)
import AppKit
import OSLog
import Sparkle

@MainActor
enum ReaderHelp {
    // Verified against this checkout's origin, not Sumatra's release service.
    static let website = URL(string: "https://github.com/Ares-X/Sumra")!
    static let releases = URL(string: "https://github.com/Ares-X/Sumra/releases")!
    private static var panel: NSPanel?
    private static var errors: [String] = []
    private static let logger = Logger(subsystem: "com.leaf.reader", category: "document")

    static func recordError(_ message: String) {
        errors.append(Date().formatted(date: .omitted, time: .standard) + "  " + message)
        if errors.count > 100 { errors.removeFirst(errors.count - 100) }
        logger.error("\(message)")
    }

    static func showErrors() {
        show(title: L("Errors in This Session"), text: errors.isEmpty ? L("No errors recorded in this session.") : errors.joined(separator: "\n\n"))
    }

    static func showLog() {
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.openApplication(at: console, configuration: .init())
        }
        show(title: L("Application Log"), text: L("Sumra reports document errors to macOS Console under subsystem com.leaf.reader.") + "\n\n" + errors.joined(separator: "\n\n"))
    }

    static func showManual() {
        let sections = [
            ("Open and navigate", "Use File → Open to choose documents or folders, or drag files into Sumra. Browse Files and Open Recent find nearby and previously opened documents. Contents, thumbnails and bookmarks navigate the current document."),
            ("Read and search", "Use Navigation for page navigation, View for zoom, rotation and layout, and Edit → Find to search readable text. Match Case and Match Whole Word refine results. Scanned pages without a text layer need OCR before text search."),
            ("Bookmarks and reading position", "Bookmark This Position saves your place. Settings controls recent documents, saved reading positions, tabs and window restoration. Typography and CSS can apply to this document or become your defaults."),
            ("PDF editing", "PDFs open with editing locked. Choose Enable Editing before filling forms or changing annotations. Lock Editing keeps unsaved changes and returns to reading. Tools → Annotations adds notes, text, shapes, highlights and attachments. Select an annotation to edit it. Tools → PDF Tools extracts, merges and exports pages, manages encryption and inspects signatures. Save preserves edits; Save a Copy writes a separate file. Applying redactions permanently removes marked content from the saved result."),
            ("Selection, translation and AI", "Select text to copy, search or translate it. Ask AI uses an installed, signed-in CLI provider. Choose Selection / Current Passage or Entire Document, then Send. The chosen text is sent to that provider, which stores conversation history. Translate Selection sends only selected text."),
            ("Read aloud and presentation", "Navigation → Read Aloud uses macOS voices. The playback controls choose voice and speed, pause or stop. View → Presentation uses full screen; B and W show black or white, L toggles the laser pointer, and Escape leaves presentation."),
            ("Customize", "Settings provides appearance, reading, shortcuts, external commands and advanced JSON preferences. Keyboard Shortcuts lists current bindings, including your overrides. Blank shortcut fields disable a command's binding."),
            ("Document support", "Available actions depend on the document format and its permissions. Password-protected documents require their password. Image-only documents do not provide searchable text. Windows-only shell integrations are replaced by macOS file, print and sharing controls.")
        ]
        show(title: L("Sumra Help"), text: sections.map { L($0.0) + "\n" + L($0.1) }.joined(separator: "\n\n"))
    }

    static func showShortcuts() {
        let data = Data((UserDefaults.standard.string(forKey: "shortcuts") ?? "{}").utf8)
        let overrides = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        let lines = ReaderMenuCommand.allCases.map { command in
            let binding = overrides[command.id] ?? command.defaultShortcut
            return command.title + "\n    " + (binding.isEmpty ? L("Not assigned") : binding)
        }
        let custom = (try? ReaderConfiguredCommand.read(UserDefaults.standard.string(forKey: "customCommands") ?? "[]")) ?? []
        let external = (try? ExternalReaderCommand.read(UserDefaults.standard.string(forKey: "externalCommands") ?? "[]")) ?? []
        let configured = custom.map { ($0.name, $0.shortcut) } + external.map { ($0.name, $0.shortcut) }
        let added = configured.map { $0.0 + "\n    " + ($0.1?.isEmpty == false ? $0.1! : L("Not assigned")) }
        show(title: L("Keyboard Shortcuts"), text: L("These are your current command bindings. Edit them in Settings → Shortcuts.") + "\n\n" + (lines + added).joined(separator: "\n\n"))
    }

    static func contributeTranslation() {
        let alert = NSAlert()
        alert.messageText = L("Contribute Translation")
        alert.informativeText = L("Translations are in Sources/Sumra/Resources/Localizations. Edit the values in your language's Localizable.strings, keeping the English keys and format placeholders unchanged. Send your changes as a pull request to the Sumra repository.")
        alert.addButton(withTitle: L("Visit Website"))
        alert.addButton(withTitle: L("Close"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(website) }
    }

    static func show(title: String, text: String) {
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 400, height: 300)
            created.center()
            panel = created
        }
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isRichText = false
        view.font = .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.string = text
        panel?.title = title
        panel?.contentView = scroll
        panel?.makeKeyAndOrderFront(nil)
    }

    // Sparkle owns update scheduling, validation, installation and relaunching.
    private final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
        func allowedChannels(for updater: SPUUpdater) -> Set<String> {
            UserDefaults.standard.string(forKey: "updateChannel") == "prerelease" ? ["prerelease"] : []
        }
    }
    private static let updateDelegate = UpdateDelegate()
    private static let updaterController: Result<SPUStandardUpdaterController, Error>? = {
        migrateUpdatePreferences()
        guard ["SUFeedURL", "SUPublicEDKey"].allSatisfy({
            (Bundle.main.object(forInfoDictionaryKey: $0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else { return nil }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updateDelegate, userDriverDelegate: nil)
        do {
            // Use the throwing API so an invalid development configuration does not
            // display Sparkle's automatic startup error dialog.
            try controller.updater.start()
            return .success(controller)
        } catch {
            recordError(error.localizedDescription)
            return .failure(error)
        }
    }()

    static func migrateUpdatePreferences(defaults: UserDefaults = .standard) {
        // Keep the existing preference without maintaining a second copy of
        // Sparkle's persisted automatic-check setting.
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
           let enabled = defaults.object(forKey: "checkForUpdates") as? Bool {
            defaults.set(enabled, forKey: "SUEnableAutomaticChecks")
        }
        defaults.removeObject(forKey: "checkForUpdates")
        defaults.removeObject(forKey: "lastUpdateCheck")
    }

    static func checkForUpdatesOnLaunch() {
        guard case .success(let controller)? = updaterController else { return }
        if UserDefaults.standard.string(forKey: "updateChannel") == "prerelease",
           controller.updater.automaticallyChecksForUpdates {
            // Sparkle explicitly supports this immediately after starting the
            // updater; stable builds retain its normal daily schedule.
            controller.updater.checkForUpdatesInBackground()
        }
    }

    static var automaticUpdateChecks: Bool {
        if case .success(let controller)? = updaterController {
            return controller.updater.automaticallyChecksForUpdates
        }
        return UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
    }

    static func setAutomaticUpdateChecks(_ enabled: Bool) {
        if case .success(let controller)? = updaterController {
            controller.updater.automaticallyChecksForUpdates = enabled
        } else {
            // A development build has no running updater, but can retain a choice
            // for the next configured release using the same official key.
            UserDefaults.standard.set(enabled, forKey: "SUEnableAutomaticChecks")
        }
    }

    static func updateChannelChanged() {
        if case .success(let controller)? = updaterController {
            controller.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    static func checkForUpdates() {
        let message: String
        switch updaterController {
        case .success(let controller)?:
            if controller.updater.canCheckForUpdates { controller.checkForUpdates(nil) }
            return
        case .failure(let error)?:
            message = error.localizedDescription
        case nil:
            message = L("This development build of Sumra has no update feed and signing key configured. Open Releases to check for published builds.")
        }
        let alert = NSAlert()
        alert.messageText = L("Updates Are Not Configured")
        alert.informativeText = message
        alert.addButton(withTitle: L("Open Releases"))
        alert.addButton(withTitle: L("Close"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(releases) }
    }
}
#endif
