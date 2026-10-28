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

    static func current(pageMargins: PageMargins?) -> Self? {
        guard let pageMargins else { return nil }
        return allCases.first { preset in pageMargins.values.allSatisfy { $0 == preset.margin } }
    }
}

@MainActor extension ReaderState {
    var usesReflowMargins: Bool {
        if isText || isBrowser { return true }
        guard case .pages(let pages) = document?.content else { return false }
        return pages.isReflowable
    }

    var extendsReadingUnderChrome: Bool {
        usesFloatingChrome || (usesReflowMargins && marginPreset == .narrow && toolbarDisplayMode != .shown)
    }

    var marginPreset: ReaderMarginPreset? {
        ReaderMarginPreset.current(pageMargins: pageMargins)
    }

    func applyMarginPreset(_ preset: ReaderMarginPreset) {
        captureReflowPosition()
        margin = preset.margin
        pageMargins = PageMargins(cssValues: [preset.margin])
        applyTypography()
    }
}
#endif
