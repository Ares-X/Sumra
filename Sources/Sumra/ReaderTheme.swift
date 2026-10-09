#if os(macOS)
import AppKit

// Base palettes from Sumatra Theme.cpp at 012d997f (GPLv3).
// AppKit still owns native controls; one palette drives reader text and paper.
struct ReaderTheme: Identifiable {
    let id: String, name: String
    let text: UInt32, background: UInt32, link: UInt32
    static let all: [Self] = [
        .init(id: "light", name: "Light", text: 0x000000, background: 0xf2f2f2, link: 0x0020a0),
        .init(id: "dark", name: "Dark", text: 0xF9FAFB, background: 0x000000, link: 0x6B7280),
        .init(id: "light-warm", name: "Light Warm", text: 0x333333, background: 0xebe6da, link: 0x0020a0),
        .init(id: "dark-from-3-5", name: "Dark from 3.5", text: 0xbac9d0, background: 0x263238, link: 0x8aa3b0),
        .init(id: "charcoal", name: "Charcoal", text: 0xffffff, background: 0x2d2d30, link: 0x9999a0),
        .init(id: "solarized-light", name: "Solarized Light", text: 0x212323, background: 0xfdf6e3, link: 0x268bd2),
        .init(id: "solarized-dark", name: "Solarized Dark", text: 0x839496, background: 0x002b36, link: 0x268bd2),
        .init(id: "dracula", name: "Dracula", text: 0xf8f8f2, background: 0x282a36, link: 0x8be9fd),
        .init(id: "nebula", name: "Nebula", text: 0xCBE3E7, background: 0x100E23, link: 0x91DDFF),
        .init(id: "greeny", name: "Greeny", text: 0xFDD085, background: 0x4F6232, link: 0xA2E53B),
        .init(id: "choco", name: "Choco", text: 0xD7AD62, background: 0x2A1104, link: 0xE8CD12),
        .init(id: "purpy", name: "Purpy", text: 0xE2C3C3, background: 0x20222A, link: 0xEFF0B8),
        .init(id: "one-dark", name: "One Dark", text: 0xabb2bf, background: 0x282c34, link: 0x61afef),
        .init(id: "monokai", name: "Monokai", text: 0xf8f8f2, background: 0x272822, link: 0x66d9ef),
        .init(id: "nord", name: "Nord", text: 0xd8dee9, background: 0x2e3440, link: 0x88c0d0),
        .init(id: "github-dark", name: "GitHub Dark", text: 0xe6edf3, background: 0x0d1117, link: 0x2f81f7),
        .init(id: "catppuccin-mocha", name: "Catppuccin Mocha", text: 0xcdd6f4, background: 0x1e1e2e, link: 0x89b4fa),
        .init(id: "tokyo-night", name: "Tokyo Night", text: 0xc0caf5, background: 0x1a1b26, link: 0x7aa2f7),
        .init(id: "gruvbox", name: "Gruvbox", text: 0xebdbb2, background: 0x282828, link: 0x83a598),
        .init(id: "night-owl", name: "Night Owl", text: 0xd6deeb, background: 0x011627, link: 0x82aaff),
        .init(id: "ayu", name: "Ayu", text: 0xbfbdb6, background: 0x0b0e14, link: 0x59c2ff),
        .init(id: "palenight", name: "Palenight", text: 0xa6accd, background: 0x292d3e, link: 0x82aaff),
    ]
    static func color(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func rgb(_ color: NSColor) -> UInt32? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func component(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return component(rgb.redComponent) << 16 | component(rgb.greenComponent) << 8 | component(rgb.blueComponent)
    }
    var dark: Bool { 0.2126 * Double((background >> 16) & 255) + 0.7152 * Double((background >> 8) & 255) + 0.0722 * Double(background & 255) < 128 }
    var css: String {
        let fg = String(format: "#%06x", text), bg = String(format: "#%06x", background), href = String(format: "#%06x", link)
        return "*{color:\(fg) !important;background-color:transparent !important;} html,body{background-color:\(bg) !important;color:\(fg) !important;} a,a *{color:\(href) !important;}"
    }
}
#endif
