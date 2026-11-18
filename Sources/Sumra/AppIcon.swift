#if os(macOS)
import AppKit

enum AppIconStyle: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var label: String { self == .light ? "Light" : "Dark" }

    fileprivate var resourceName: String {
        self == .light ? "ViraReader-Light" : "ViraReader-Dark"
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

    static func documentImage(for url: URL) -> NSImage? {
        guard let names = Bundle.main.object(forInfoDictionaryKey: "ViraDocumentIconNames") as? [String: String],
              let name = names[url.pathExtension.lowercased()],
              let resource = Bundle.main.url(forResource: name, withExtension: "icns"),
              (try? url.resourceValues(forKeys: [.customIconKey]).customIcon) == nil,
              let image = NSImage(contentsOf: resource) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
#endif
