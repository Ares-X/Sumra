#if os(macOS)
import AppKit
import SumraCore

// Display-only adaptation of Sumatra's active bitmap recoloring/CAD paths.
// NativeFile/Pages use the live MuPDF document and its retained display list.
enum PDFColors {
    enum Mode: Int32, Hashable, Sendable { case off, smart, legacy }
    struct Style: Hashable, Sendable {
        var mode: Mode = .off
        var text: UInt32 = 0
        var background: UInt32 = 0xffffff
        var link: UInt32 = 0
        var preserveImages = true
        var engineering = false
        var rasterEngineering = false
        var hairlineEngineering = false
        var transparent = false
        var grayscale = false
        var showImageBounds = false
        var isActive: Bool { mode != .off || engineering || transparent || grayscale || showImageBounds }
        var nativeValues: [Int32] {
            [mode.rawValue, preserveImages ? 1 : 0, engineering ? 1 : 0,
             rasterEngineering ? 1 : 0, hairlineEngineering ? 1 : 0,
             transparent ? 1 : 0, grayscale ? 1 : 0, showImageBounds ? 1 : 0]
        }
        var nativeColors: [UInt32] { [text, background, link] }
    }
    struct Engineering: Equatable, Sendable {
        var enabled = false
        var raster = false
        var hairline = false
    }
}

extension ReaderState {
    var pdfColorStyle: PDFColors.Style {
        var style = PDFColors.Style()
        style.mode = documentColors == "legacy" ? .legacy : documentColors == "smart" ? .smart : .off
        let followsTheme = style.mode != .off
        style.text = customTextColor ?? (followsTheme ? palette.text : 0)
        style.background = customBackgroundColor ?? (followsTheme ? palette.background : 0xffffff)
        style.link = followsTheme ? palette.link : 0x0020a0
        if invertColors { swap(&style.text, &style.background) }
        if style.mode == .off, invertColors || customTextColor != nil || customBackgroundColor != nil { style.mode = .smart }
        style.preserveImages = preservePDFImages
        style.engineering = engineeringEnhance == "on"
        style.transparent = showTransparencyGrid
        style.showImageBounds = showImageBounds
        style.grayscale = grayscale
        return style
    }
}
#endif
