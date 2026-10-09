#if os(macOS)
import AppKit

enum AppIconStyle: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var label: String { self == .light ? "Light" : "Dark" }

    fileprivate var resourceName: String {
        self == .light ? "Sumra-Light" : "Sumra-Dark"
    }
}

@MainActor
enum AppIcon {
    static func apply(_ value: String) {
        guard let style = AppIconStyle(rawValue: value),
              let image = image(for: style)
        else { return }
        NSApplication.shared.applicationIconImage = image
    }

    static func image(for style: AppIconStyle) -> NSImage? {
        guard let url = Bundle.main.url(forResource: style.resourceName, withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
#endif
