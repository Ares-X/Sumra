import Foundation

// Explicit resource lookup keeps the reader's language choice local to Sumra.
// It does not replace Bundle.main or alter system and provider preferences.
enum ReaderLocalization {
    static var languages: [String] { ["system"] + bundles.keys.sorted() }

    static var language: String {
        let selected = UserDefaults.standard.string(forKey: "language") ?? "system"
        if bundles[selected] != nil { return selected }
        return preferredLanguage(Locale.preferredLanguages)
    }

    static func preferredLanguage(_ preferences: [String]) -> String {
        // Foundation may choose any available language if none match. Always
        // offer English as the final match, preserving region/script matching.
        Bundle.preferredLocalizations(from: Array(bundles.keys), forPreferences: preferences + ["en"]).first ?? "en"
    }

    private static let bundles: [String: Bundle] = {
        let appRoot = Bundle.main.resourceURL?.appendingPathComponent("Localizations")
        let root: URL?
        if let appRoot, FileManager.default.fileExists(atPath: appRoot.path) { root = appRoot }
        else { root = Bundle.module.resourceURL?.appendingPathComponent("Localizations") }
        guard let root else { return [:] }
        var result = [String: Bundle]()
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where folder.pathExtension == "lproj" {
            if let bundle = Bundle(url: folder) { result[folder.deletingPathExtension().lastPathComponent] = bundle }
        }
        return result
    }()

    static func name(_ language: String) -> String {
        language == "system" ? L("System") : Locale(identifier: language).localizedString(forIdentifier: language) ?? language
    }

    static func string(_ value: String) -> String {
        bundles[language]?.localizedString(forKey: value, value: value, table: nil) ?? value
    }
}

func L(_ value: String) -> String { ReaderLocalization.string(value) }

#if os(macOS)
import SwiftUI

struct ReaderLanguage: ViewModifier {
    @AppStorage("language") private var language = "system"

    func body(content: Content) -> some View {
        let _ = language
        let locale = Locale(identifier: ReaderLocalization.language)
        content
            .environment(\.layoutDirection, locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
    }
}
#endif
