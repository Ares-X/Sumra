#if os(macOS)
import SwiftUI
import SumraCore

extension ReaderPreferences {
    static let typographyKeys: Set<String> = ["font", "fontSize", "lineHeight", "margin", "pageMargins", "userCSS", "useDocumentCSS"]
    private static let savedReadingFields: [String: (inout ReadingPosition) -> Void] = [
        "fit": { $0.fit = nil; $0.zoom = nil }, "flow": { $0.flow = nil },
        "spread": { $0.spread = nil }, "rtl": { $0.rtl = nil }, "cover": { $0.cover = nil },
        "automaticLayout": { $0.automaticLayout = nil }, "scrollbarMode": { $0.scrollbarMode = nil },
        "font": { $0.font = nil }, "fontSize": { $0.fontSize = nil }, "lineHeight": { $0.lineHeight = nil },
        "margin": { $0.margin = nil; $0.pageMargins = nil },
        "pageMargins": { $0.margin = nil; $0.pageMargins = nil },
        "userCSS": { $0.userCSS = nil }, "useDocumentCSS": { $0.useDocumentCSS = nil },
        "invertColors": { $0.invertColors = nil }, "grayscale": { $0.grayscale = nil },
        "documentColors": { $0.documentColors = nil; $0.customTextColor = nil; $0.customBackgroundColor = nil; $0.customLinkColor = nil },
        "enhanceScannedPages": { $0.enhanceScannedPages = nil }, "preservePDFImages": { $0.preservePDFImages = nil },
        "engineeringEnhance": { $0.engineeringEnhance = nil }
    ]
    private static let liveReadingKeys = Set(savedReadingFields.keys).union([
        "landscapeAsSpread", "inverseSearchEnabled", "speechVoice", "speechRate", "contentsDepth", "disableTabs",
        "pageGridWidth", "pageGridHeight", "pageGridOffsetX", "pageGridOffsetY", "pageGridSubdivisions", "pageGridColor", "pageGridStyle"
    ])

    static var readingRevisions: [String: Int] {
        UserDefaults.standard.dictionary(forKey: "readingPreferenceRevisions") as? [String: Int] ?? [:]
    }

    /// Explicit settings edits are global intent. Reader restoration is not.
    static func live<Value>(_ binding: Binding<Value>, keys: Set<String>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: {
            binding.wrappedValue = $0
            applyReadingDefaults(changed: keys)
        })
    }

    static func setMargins(_ value: Double) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: "margin")
        defaults.set(PageMargins(cssValues: [value]).flatMap { try? JSONEncoder().encode($0) }, forKey: "pageMargins")
        applyReadingDefaults(changed: ["margin", "pageMargins"])
    }

    static func applyReadingDefaults(changed requested: Set<String>) {
        var changed = requested.intersection(liveReadingKeys)
        guard !changed.isEmpty else { return }
        let defaults = UserDefaults.standard
        if changed.contains("margin") || changed.contains("pageMargins") {
            // A scalar in an old settings export is not a four-side override.
            // The interactive uniform-margin setter explicitly writes both.
            changed.formUnion(["margin", "pageMargins"])
        }
        var revisions = readingRevisions
        for key in changed where savedReadingFields[key] != nil { revisions[key, default: 0] += 1 }
        defaults.set(revisions, forKey: "readingPreferenceRevisions")

        for reader in ReaderWindows.states { applyReadingDefaults(to: reader, changed: changed) }
        if changed.contains("disableTabs") {
            NSWindow.allowsAutomaticWindowTabbing = !defaults.bool(forKey: "disableTabs")
            for reader in ReaderWindows.states { reader.window?.tabbingMode = defaults.bool(forKey: "disableTabs") ? .disallowed : .preferred }
        }
    }

    private static func applyReadingDefaults(to reader: ReaderState, changed: Set<String>) {
        if !changed.isDisjoint(with: ["fit", "flow", "spread", "rtl", "cover", "automaticLayout"]),
           reader.deferForNativePDFForm({ [weak reader] in
               if let reader { applyReadingDefaults(to: reader, changed: changed) }
           }) { return }
        let defaults = UserDefaults.standard
        let reflow = !changed.isDisjoint(with: typographyKeys.union(["flow", "spread", "rtl", "cover", "fit", "automaticLayout"]))
        if reflow { reader.captureReflowPosition() }
        reader.readPreferences(changed: changed)
        let style = (!changed.isDisjoint(with: typographyKeys.union(["documentColors"])) && (reader.reflowable || reader.isText || reader.isBrowser)) ||
            (changed.contains("flow") && (reader.isText || reader.isBrowser)) ||
            (changed.contains("scrollbarMode") && reader.isBrowser)
        if changed.contains("flow") {
            reader.setFlow(reader.flow, notify: false)
            if changed.contains("automaticLayout") { reader.automaticLayout = defaults.bool(forKey: "automaticLayout") }
        }
        if changed.contains("fit") { reader.setFit(reader.fit, notify: !style) }
        if changed.contains("contentsDepth") { reader.applyContentsDepth() }
        if style { reader.send(.style) }
        reader.persist()
    }

    /// Old files without markers retain their overrides until that exact global
    /// setting is edited. A later per-book edit records the new marker on save.
    static func applicable(_ position: ReadingPosition) -> ReadingPosition {
        var result = position
        let current = readingRevisions
        for (key, clear) in savedReadingFields where (position.preferenceRevisions?[key] ?? 0) != (current[key] ?? 0) {
            clear(&result)
        }
        return result
    }
}
#endif
