#!/usr/bin/env swift
// Add reviewed upstream translations without replacing existing catalog values.
import Foundation
import CryptoKit
let sourceURL = URL(string: "https://www.apptranslator.org/api/dltranshist?app=SumatraPDF&size=0")!
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Sumra/Resources/Localizations")
let languages =
[
    "be": "by", "ca-ES-valencia": "ca-xv", "ckb": "ku", "cs": "cz",
    "da": "dk", "fy": "fy-nl", "hy": "am", "ko": "kr", "ms": "my",
    "my": "mm", "nb": "no", "pt-BR": "br", "pt-PT": "pt",
    "sr-Cyrl": "sr-rs", "sr-Latn": "sp-rs", "vi": "vn", "zh-Hant": "tw",
]
let exact = [
    "# History", "* Annotations", "= Settings", "> Commands", "@ Tabs",
    "Clear History", "Document Properties", "Dots", "Dotted lines",
    "Frequently Read", "Open", "Pin", "Recently Opened", "Redo",
    "Restore Tab Group", "Save Tab Group", "Search", "Set", "Solid lines",
    "Translate", "Undo", "Unpin", "Zoom",
    "Bold", "Circle", "Contribute Translation", "Delete Pages", "Extract Pages", "Extract Text",
    "Italic", "None", "Search Image with Google Lens", "Square", "Underline",
    "Page scaling", "Update EU Trusted List",
]
let aliasPairs = [
    ("Appearance", "Appearance:"),
    ("Automatically check for updates", "Automatically check for &updates"),
    ("Cursor Position", "Cursor position:"),
    ("Default layout", "Default &Layout:"),
    ("From", "From:"),
    ("Go to Page", "Go to page"),
    ("Loading…", "Loading..."),
    ("Margin", "Margin:"),
    ("Open in New Tab", "open in new tab"),
    ("Pages", "Pages:"),
    ("Rename", "Re&name..."),
    ("Rename File", "Rename File..."),
    ("Subdivisions", "Subdivisions:"),
    ("Thumbnails", "& Thumbnails"),
    ("To", "To:"),
    ("Translate Selection", "Translate Selection..."),
    ("Translate Selection…", "Translate Selection..."),
    ("Unsaved Changes", "Unsaved changes"),
    // Annotation property controls: AnnotEditToolbar.cpp, especially its hover
    // rows at 3136–3187. Contents here is the annotation body, not the book's TOC.
    ("Author", "Author:"),
    ("Border width", "Border Width"),
    ("Line end", "Line End"),
    ("Line start", "Line Start"),
    ("Text color", "Text Color"),
    ("Text size", "Text Size"),
    ("Annotation contents", "Contents:"),
    ("Comment", "Contents:"),
    ("Copy Link Address", "Copy Link &Address"),
    ("Copy Comment", "Copy Co&mment"),
    ("Show Comment", "Sho&w Comment"),
    ("Alignment", "Text Alignment"),
    ("Font family", "Text Font:"),
    ("Background", "Background Color"),
    // These are the same signature fields and appearance checkboxes as
    // SignDocumentDialog.cpp:780–809, including the optional reason/location.
    ("Labels", "Show &labels"),
    ("Name", "Show &name"),
    ("Distinguished name", "Show &DN"),
    ("Date", "Show da&te"),
    ("Graphic name", "Show name as &graphic"),
    ("Certificate password", "&Password:"),
    ("Reason", "&Reason (optional):"),
    ("Location", "&Location (optional):"),
    ("Digital Signature", "Sign Document"),
    ("Page", "Page:"),
    ("Go", "Go to page"),
    ("Go to Page…", "Go to Page..."),
    ("Extract", "Extract Pages"),
    ("Discard", "Discard changes"),
    ("Save…", "Save..."),
    // Menu.cpp routes these image commands to the clicked image, including PDF
    // page elements; the more explicit reader labels do not change their action.
    ("Copy Embedded Image", "Copy Image"),
    ("Save Embedded Image…", "Save Image..."),
    ("Crop Embedded Image…", "Crop Image..."),
    ("Resize Embedded Image…", "Resize Image..."),
    ("Convert Embedded Image to PDF…", "Convert Image To PDF..."),
    ("Save Selection…", "Save As Image..."),
    // Commands.cpp display names, matched to the existing command consumers.
    ("Reload", "Reload Document"),
    ("Open without History…", "Open File Without History..."),
    ("Remove Missing Files", "Remove Deleted Files From History"),
    ("Forget", "Remove Selected Document From History"),
    ("Search Selection in Wikipedia", "Search Selection with Wikipedia"),
    ("Search Selection in Google Scholar", "Search Selection with Google Scholar"),
    ("Scroll Up a Page", "Scroll Up By Page"),
    ("Scroll Down a Page", "Scroll Down By Page"),
    ("Scroll Up Half a Page", "Scroll Up By Half Page"),
    ("Scroll Down Half a Page", "Scroll Down By Half Page"),
    ("Generate Contents from Headings", "Generate Table Of Contents"),
    ("Open Source at Reading Position", "Invoke Inverse Search"),
    ("Page Information Overlay", "Toggle Page Info"),
    ("Show PDF Page Boxes", "Toggle Page Boxes"),
    ("Show Page Grid", "Toggle Page Grid"),
    ("Read from Cursor", "Start Reading From Cursor Position"),
    ("Read Selection", "Start Reading Selection"),
    ("Add File Attachment…", "Create File Attachment Annotation"),
    ("Digitally Sign PDF…", "Sign Document..."),
    ("Fit Page in Single Page View", "Zoom: Fit Page and Single Page"),
    ("Fit Width in Continuous View", "Zoom: Fit Width And Continuous"),
    ("Page Thumbnails", "& Thumbnails"),
    ("Expand All Contents", "Expand All"),
    ("Collapse All Contents", "Collapse All"),
    ("Sort Bookmarks by Name", "Sort By Name"),
    ("Annotation List", "Annotations"),
    // ReaderView's Previous/Next buttons perform the same page turns as the
    // upstream toolbar. Plain headings omit the palette's visible prefix.
    ("Previous", "Previous Page"),
    ("Next", "Next Page"),
    ("History", "# History"),
    ("Commands", "> Commands"),
    ("Tabs", "@ Tabs"),
    ("Open without History", "Open File Without History..."),
    // PrintWin11.cpp kScaleItems: these labels share the actual print policies.
    ("Shrink pages to printable area", "&Shrink pages to printable area"),
    ("Fit pages to printable area", "&Fit pages to printable area"),
    ("Stretch pages to fill paper", "S&tretch pages to fill paper"),
    ("Actual size (1:1)", "A&ctual size (1:1)"),
    ("Rotate printout:", "&Rotate printout:"),
    ("Center page horizontally on the paper", "Center page hori&zontally on the paper"),
]
let sourceOrder = exact + aliasPairs.map { $0.0 }
var sources = Dictionary(uniqueKeysWithValues: exact.map { ($0, $0) })
sources.merge(aliasPairs) { _, new in new }
let entry = try NSRegularExpression(pattern: #"^\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");\s*$"#, options: .anchorsMatchLines)
func replace(_ value: String, _ pattern: String, _ replacement: String) -> String {
    value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
}
func label(_ key: String, _ source: String, _ original: String) -> String {
    var value = replace(original, #"[（(]&[A-Za-z0-9][）)]"#, "").trimmingCharacters(in: .whitespacesAndNewlines)
    if source.contains("&") && source != "& Thumbnails" {
        value = value.replacingOccurrences(of: "&", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if source == "& Thumbnails" && value.hasPrefix("&") {
        value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if source.hasSuffix(":") && !key.hasSuffix(":") {
        while let last = value.last, " :：\u{00a0}".contains(last) { value.removeLast() }
    }
    if source.hasSuffix("...") {
        value = replace(value, #"(?:\.\.\.|…)\s*$"#, "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix("…") { value += "…" }
    }
    let prefixes = ["# ", "* ", "= ", "> ", "@ "]
    for prefix in prefixes where source.hasPrefix(prefix) && !key.hasPrefix(prefix) && value.hasPrefix(prefix) {
        value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let prefix = prefixes.first(where: { key.hasPrefix($0) }), !value.hasPrefix(prefix) { value = prefix + value }
    return value
}
func quoted(_ value: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}
func unquoted(_ value: String) throws -> String {
    try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as! String
}
// CSV supports quoted commas, newlines and doubled quotes in upstream history.
func csv(_ text: String) -> [[String]] {
    var rows = [[String]](), row = [String](), field = "", quoted = false
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if character == "\"" {
            if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                field.append("\""); index += 1
            } else if quoted || field.isEmpty { quoted.toggle() }
            else { field.append(character) }
        } else if character == "," && !quoted {
            row.append(field); field = ""
        } else if (character == "\n" || character == "\r\n" || character == "\r") && !quoted {
            row.append(field); rows.append(row); row = []; field = ""
        } else { field.append(character) }
        index += 1
    }
    if !row.isEmpty || !field.isEmpty { row.append(field); rows.append(row) }
    return rows
}
struct TranslationKey: Hashable { let language: String; let source: String }
struct ImportError: Error, CustomStringConvertible { let description: String }
func updateCatalogs(_ translations: [TranslationKey: String], at root: URL) throws {
    var totalAdded = 0, totalEntries = 0
    let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "lproj" }.sorted { $0.path < $1.path }
    for directory in directories {
        let language = directory.deletingPathExtension().lastPathComponent
        if language == "en" || language == "zh-Hans" { continue }
        let path = directory.appendingPathComponent("Localizable.strings")
        if !FileManager.default.fileExists(atPath: path.path) { continue }
        let original = try String(contentsOf: path, encoding: .utf8)
        let ns = original as NSString
        var entries = [String: String]()
        for match in entry.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
            let key = try unquoted(ns.substring(with: match.range(at: 1)))
            guard entries[key] == nil else { throw ImportError(description: "Duplicate catalog keys: \(path.path)") }
            entries[key] = try unquoted(ns.substring(with: match.range(at: 2)))
        }
        var available = [String: String]()
        for key in sourceOrder {
            if let value = entries[key], let source = sources[key] { available[source] = value }
        }
        var additions = [String: String](), missing = [String]()
        for key in sourceOrder {
            if entries[key] != nil { continue }
            let source = sources[key]!
            let value = translations[TranslationKey(language: languages[language] ?? language, source: source)]
                ?? available[source] ?? entries[source] ?? ""
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(key); continue }
            additions[key] = label(key, source, value)
        }
        if !additions.isEmpty {
            let lines = try additions.keys.sorted().map { try "\(quoted($0)) = \(quoted(additions[$0]!));" }
            try (replace(original, #"\s+$"#, "") + "\n" + lines.joined(separator: "\n") + "\n")
                .write(to: path, atomically: false, encoding: .utf8)
        }
        let count = entries.count + additions.count
        totalAdded += additions.count; totalEntries += count
        let missingJSON = try JSONSerialization.data(withJSONObject: missing, options: .withoutEscapingSlashes)
        print("\(language): added \(additions.count), total \(count), missing \(String(decoding: missingJSON, as: UTF8.self))")
    }
    print("Total: added \(totalAdded), entries \(totalEntries)")
}
func main() throws {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Data, Error>!
    var request = URLRequest(url: sourceURL); request.timeoutInterval = 60
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { result = .failure(error) }
        else if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            result = .failure(ImportError(description: "Translation server returned HTTP \(status)"))
        } else { result = .success(data!) }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    let data = try result.get()
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    print("Source: \(sourceURL)\nBytes: \(data.count)\nSHA-256: \(digest)")
    let text = String(decoding: data, as: UTF8.self)
    var translations = [TranslationKey: String]()
    let wanted = Set(sources.values)
    // Oldest-first history: an explicitly empty final record removes the value.
    for row in csv(text) where row.count == 6 && row[0] == "t" && wanted.contains(row[4]) {
        translations[TranslationKey(language: row[3], source: row[4])] = row[5]
    }
    guard !translations.isEmpty else { throw ImportError(description: "No reviewed translation records in the server response") }
    try updateCatalogs(translations, at: root)
}
do { try main() } catch { FileHandle.standardError.write(Data("Localizations: \(error)\n".utf8)); exit(1) }
