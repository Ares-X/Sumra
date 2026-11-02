// Run through the existing metadata-test harness, without building or registering Sumra.
let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let catalogs = URL(fileURLWithPath: CommandLine.arguments[2])
let registration = try localizationRegistration(in: catalogs)
let languages = registration["CFBundleLocalizations"] as! [String]
let catalogNames = try files.contentsOfDirectory(at: catalogs, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "lproj" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
precondition(languages == catalogNames)
precondition(languages.contains("en") && languages.contains("zh-Hans") && languages.contains("fr"))
precondition(registration["CFBundleDevelopmentRegion"] as? String == "en")
let probeSource = scratch.appendingPathComponent("LocaleProbe.swift")
try """
import AppKit
NSApplication.shared.setActivationPolicy(.prohibited)
let result = ["preferred": Bundle.main.preferredLocalizations.first ?? "", "open": NSOpenPanel().prompt ?? "", "save": NSSavePanel().prompt ?? "", "colors": NSColorPanel.shared.title]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
""".write(to: probeSource, atomically: true, encoding: .utf8)
let app = scratch.appendingPathComponent("LocaleProbe.app")
let macOS = app.appendingPathComponent("Contents/MacOS")
try files.createDirectory(at: macOS, withIntermediateDirectories: true)
let executable = macOS.appendingPathComponent("LocaleProbe")
try run(["swiftc", probeSource.path, "-o", executable.path])
var info = registration
info["CFBundleExecutable"] = "LocaleProbe"
info["CFBundleIdentifier"] = "dev.aresx.sumra.test.locale"
info["CFBundlePackageType"] = "APPL"
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: app.appendingPathComponent("Contents/Info.plist"))
var panelStrings = [String: [String]]()
for (preference, expected) in [("zh-Hans", "zh-Hans"), ("en", "en"), ("fr", "fr"), ("eo", "en")] {
    // This argument affects only the probe process; no user or global defaults change.
    let output = try run([executable.path, "-AppleLanguages", "(\(preference))", "-language", "zh-Hans"])
    let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: String]
    precondition(result["preferred"] == expected, "\(preference): \(output)")
    let strings = ["open", "save", "colors"].map { result[$0]! }
    precondition(strings.allSatisfy { !$0.isEmpty }, "\(preference): \(output)")
    panelStrings[preference] = strings
}
// Apple owns the translations and may revise their wording between OS releases.
// Check language negotiation against this runtime's English result instead.
precondition(panelStrings["eo"] == panelStrings["en"])
precondition(panelStrings["zh-Hans"] != panelStrings["en"])
precondition(panelStrings["fr"] != panelStrings["en"])
print("Localization registration and nonvisible AppKit panels passed: Chinese, English, French, unsupported-language English fallback; in-app override leaves AppKit unchanged.")
