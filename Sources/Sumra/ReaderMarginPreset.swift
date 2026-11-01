#if os(macOS)
import Foundation
import SumraCore

enum ReaderMarginPreset: String, CaseIterable, Identifiable {
    case narrow, medium, wide

    var id: String { rawValue }
    var margin: Double {
        switch self {
        case .narrow: return 8
        case .medium: return 16
        case .wide: return 24
        }
    }

    var title: String {
        switch self {
        case .narrow: return L("Narrow")
        case .medium: return L("Medium")
        case .wide: return L("Wide")
        }
    }

    // Reflowed pages keep the horizontal breathing room used before the uniform
    // presets: the default 32-point side margin has a 16-point vertical margin.
    func margins(reflow: Bool) -> PageMargins {
        PageMargins(cssValues: reflow ? [margin, margin * 2] : [margin])!
    }

    static func current(pageMargins: PageMargins?, selection: String? = nil) -> Self? {
        if let selection, !selection.isEmpty {
            return Self(rawValue: selection)
        }
        guard let pageMargins else { return nil }
        return allCases.first { preset in
            pageMargins == preset.margins(reflow: true) || pageMargins == preset.margins(reflow: false)
        }
    }
}

@MainActor extension ReaderState {
    var usesReflowMargins: Bool {
        if isText || isBrowser { return true }
        guard case .pages(let pages) = document?.content else { return false }
        return pages.isReflowable
    }

    var extendsReadingUnderChrome: Bool {
        usesCustomChrome || toolbarOverlaysContent
    }

    var marginPreset: ReaderMarginPreset? {
        ReaderMarginPreset.current(pageMargins: pageMargins, selection: marginPresetSelection)
    }

    var contentMargins: PageMargins? {
        if let selection = marginPresetSelection, let preset = ReaderMarginPreset(rawValue: selection) {
            return preset.margins(reflow: usesReflowMargins)
        }
        return pageMargins
    }

    func selectCustomMargins() {
        pageMargins = contentMargins
        marginPresetSelection = "custom"
        applyTypography()
    }

    func setControlMargins(top: Double, bottom: Double) {
        captureReflowPosition()
        controlTopMargin = top
        controlBottomMargin = bottom
        applyTypography()
    }

    func setCustomMargins(_ margins: PageMargins?) {
        captureReflowPosition()
        marginPresetSelection = "custom"
        pageMargins = margins
        if let margins { margin = margins.left }
        applyTypography()
    }

    func applyMarginPreset(_ preset: ReaderMarginPreset) {
        captureReflowPosition()
        marginPresetSelection = preset.rawValue
        margin = usesReflowMargins ? preset.margin * 2 : preset.margin
        pageMargins = preset.margins(reflow: usesReflowMargins)
        applyTypography()
    }
}
#endif
