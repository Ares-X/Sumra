#!/usr/bin/env swift
// Bundle runtime dylibs and generate Info.plist for the local app.
import Foundation
import Security

let files = FileManager.default
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let contents = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let frameworks = contents.appendingPathComponent("Frameworks")
let licenses = contents.appendingPathComponent("Resources/Licenses")
let environment = ProcessInfo.processInfo.environment
let identity = environment["SUMRA_CODE_SIGN_IDENTITY"] ?? "-"
let keychain = environment["SUMRA_CODE_SIGN_KEYCHAIN"] ?? ""
let timestamp = environment["SUMRA_CODE_SIGN_TIMESTAMP"] ?? ""
let version = environment["SUMRA_VERSION"] ?? "0.2.20"
let buildVersion = environment["SUMRA_BUILD_VERSION"] ?? "22"

func fail(_ message: String) throws -> Never {
    throw NSError(domain: "Sumra.Bundle", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

@discardableResult
func run(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        try fail("\(arguments.joined(separator: " ")) exited with status \(process.terminationStatus).")
    }
    return String(decoding: data, as: UTF8.self)
}

func sign(_ path: URL, entitlements: String? = nil) throws {
    var arguments = ["codesign", "--force", "--sign", identity]
    if identity != "-" {
        arguments += ["--options", "runtime", timestamp.isEmpty ? "--timestamp" : "--timestamp=\(timestamp)"]
        if !keychain.isEmpty { arguments += ["--keychain", keychain] }
    }
    if let entitlements { arguments += ["--entitlements", entitlements] }
    try run(arguments + [path.path])
}

func matches(_ pattern: String, in text: String) throws -> [[String]] {
    let expression = try NSRegularExpression(pattern: pattern)
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
        (1..<match.numberOfRanges).map { String(text[Range(match.range(at: $0), in: text)!]) }
    }
}

func macho(_ source: URL, arch: String? = nil) throws -> (rpaths: [String], dependencies: [String]) {
    let archArguments = arch.map { ["-arch", $0] } ?? []
    let identifiers = Set(try run(["otool", "-D"] + archArguments + [source.path]).components(separatedBy: "\n").dropFirst())
    let commands = try run(["otool", "-l"] + archArguments + [source.path])
    let rpaths = try matches(#"cmd LC_RPATH\n.*?\n\s*path (.+?) \(offset"#, in: commands).map { $0[0] }
    let dependencies = try run(["otool", "-L"] + archArguments + [source.path])
        .components(separatedBy: "\n").dropFirst().compactMap { line -> String? in
            let dependency = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " (compatibility")[0]
            if dependency.isEmpty || identifiers.contains(dependency) || dependency.hasPrefix("/usr/lib/") || dependency.hasPrefix("/System/Library/") { return nil }
            return dependency
        }
    return (rpaths, dependencies)
}

func resolve(_ source: URL, dependency: String, rpaths: [String]) -> URL? {
    let executableDirectory = source.path.hasPrefix(contents.appendingPathComponent("PlugIns").path + "/")
        && source.deletingLastPathComponent().lastPathComponent == "MacOS"
        ? source.deletingLastPathComponent() : contents.appendingPathComponent("MacOS")
    func expand(_ value: String) -> URL {
        URL(fileURLWithPath: value.replacingOccurrences(of: "@loader_path", with: source.deletingLastPathComponent().path)
            .replacingOccurrences(of: "@executable_path", with: executableDirectory.path))
    }
    let candidates = dependency.hasPrefix("@rpath/")
        ? rpaths.map { expand($0).appendingPathComponent(String(dependency.dropFirst("@rpath/".count))) }
        : [expand(dependency)]
    return candidates.first { path in
        var isDirectory: ObjCBool = false
        return files.fileExists(atPath: path.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

var copied: [URL: URL] = [:]
func bundle(_ input: URL) throws -> URL {
    let source = input.resolvingSymlinksInPath().standardizedFileURL
    if let target = copied[source] { return target }
    let target = frameworks.appendingPathComponent(source.lastPathComponent)
    if files.fileExists(atPath: target.path) { try fail("Duplicate dylib name: \(source.lastPathComponent)") }
    copied[source] = target
    try files.copyItem(at: source, to: target)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    let (rpaths, dependencies) = try macho(source)
    for dependency in dependencies {
        guard let resolved = resolve(source, dependency: dependency, rpaths: rpaths) else {
            try fail("Cannot resolve \(dependency) from \(source.path)")
        }
        let child = try bundle(resolved)
        try run(["install_name_tool", "-change", dependency, "@loader_path/" + child.lastPathComponent, target.path])
    }
    try run(["install_name_tool", "-id", "@rpath/" + target.lastPathComponent, target.path])
    return target
}

func macOSVersion(_ value: String) -> [Int] {
    let parts = value.split(separator: ".").map { Int($0)! }
    return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
}

// One registration list supplies the host app and both Quick Look extensions.
// The imported CBZ identifiers are also used by other readers/archive apps;
// Finder may already have assigned one of them to an existing comic.
func quickLookRegistration() -> (exported: [[String: Any]], imported: [[String: Any]], contentTypes: [String]) {
    let exported = [
        ("dev.aresx.leaf.cbz", "Comic ZIP", ["cbz"], "public.zip-archive"),
        ("dev.aresx.leaf.cbr", "Comic RAR", ["cbr"], "public.archive"),
        ("dev.aresx.leaf.cbt", "Comic TAR", ["cbt"], "public.archive"),
        ("dev.aresx.leaf.cb7", "Comic 7-Zip", ["cb7"], "public.archive"),
        ("dev.aresx.leaf.mobi", "Mobipocket ebook", ["mobi", "prc"], "public.data"),
        ("dev.aresx.leaf.kindle", "Kindle ebook", ["azw", "azw3"], "public.data"),
        ("dev.aresx.leaf.fb2", "FictionBook ebook", ["fb2"], "public.data")
    ]
    let imported = [
        ("com.bandisoft.cbz", "Comic ZIP", ["cbz"], "public.zip-archive"),
        ("public.cbz-archive", "Comic ZIP", ["cbz"], "public.zip-archive"),
        ("org.fictionbook.fb2", "FictionBook ebook", ["fb2"], "public.data")
    ]
    func declarations(_ types: [(String, String, [String], String)]) -> [[String: Any]] {
        types.map { id, title, suffixes, parent in [
            "UTTypeIdentifier": id, "UTTypeDescription": title,
            "UTTypeConformsTo": parent == "public.archive" ? [parent, "public.data", "public.content"] : [parent, "public.content"],
            "UTTypeTagSpecification": ["public.filename-extension": suffixes]
        ] }
    }
    return (declarations(exported), declarations(imported),
            ["org.idpf.epub-container"] + (exported + imported).map { $0.0 })
}

func package() throws {
    // The certificate and its existing private key can live in different
    // Keychains. Unlock the configured key owner only for this signing run.
    var unlockedKeychain: SecKeychain?
    defer {
        if let unlockedKeychain {
            let status = SecKeychainLock(unlockedKeychain)
            if status != errSecSuccess {
                fputs("Cannot relock signing Keychain: \(status)\n", stderr)
                exit(1)
            }
        }
    }
    if identity != "-", let passwordFile = environment["SUMRA_CODE_SIGN_PASSWORD_FILE"] {
        let unlockPath = environment["SUMRA_CODE_SIGN_UNLOCK_KEYCHAIN"] ?? keychain
        var signingKeychain: SecKeychain?
        let opened = SecKeychainOpen(unlockPath, &signingKeychain)
        guard opened == errSecSuccess, let signingKeychain else { try fail("Cannot open signing Keychain: \(opened)") }
        var status: SecKeychainStatus = 0
        let inspected = SecKeychainGetStatus(signingKeychain, &status)
        guard inspected == errSecSuccess else { try fail("Cannot read signing Keychain status: \(inspected)") }
        if status & SecKeychainStatus(kSecUnlockStateStatus) == 0 {
            let password = try String(contentsOfFile: passwordFile, encoding: .utf8).trimmingCharacters(in: .newlines)
            let result = password.withCString { SecKeychainUnlock(signingKeychain, UInt32(password.utf8.count), $0, true) }
            guard result == errSecSuccess else { try fail("Cannot unlock signing Keychain: \(result)") }
            unlockedKeychain = signingKeychain
        }
    }
    try files.createDirectory(at: frameworks, withIntermediateDirectories: true)
    try files.createDirectory(at: licenses, withIntermediateDirectories: true)
    let updates = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Assets/Updates.json"))) as! [String: String]
    let updateFeed = environment["SUMRA_UPDATE_FEED_URL"] ?? updates["feed_url"]!
    let updateKey = environment["SUMRA_UPDATE_PUBLIC_KEY"] ?? updates["public_key"]!
    if updateFeed.isEmpty != updateKey.isEmpty { try fail("Set SUMRA_UPDATE_FEED_URL and SUMRA_UPDATE_PUBLIC_KEY together.") }
    try files.copyItem(at: root.appendingPathComponent("LICENSE"), to: licenses.appendingPathComponent("Sumra-AGPL-3.0.txt"))
    try files.copyItem(at: root.appendingPathComponent("THIRD_PARTY.md"), to: licenses.appendingPathComponent("THIRD_PARTY.md"))
    for notice in try files.contentsOfDirectory(at: root.appendingPathComponent("Licenses"), includingPropertiesForKeys: nil) where notice.pathExtension == "txt" {
        try files.copyItem(at: notice, to: licenses.appendingPathComponent(notice.lastPathComponent))
    }

    // Ship SwiftPM's pinned runtime and installer helpers; headers/modules and
    // sandbox-only XPC services are unused.
    let artifacts = root.appendingPathComponent(".build/artifacts/sparkle")
    let sparkleSources = try files.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: nil)
        .map { $0.appendingPathComponent("Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework") }
        .filter { files.fileExists(atPath: $0.path) }
    guard sparkleSources.count == 1 else { try fail("Build the package first to resolve the pinned Sparkle framework.") }
    let sparkle = frameworks.appendingPathComponent("Sparkle.framework")
    try files.copyItem(at: sparkleSources[0], to: sparkle)
    for name in ["Headers", "PrivateHeaders", "Modules", "XPCServices"] {
        try files.removeItem(at: sparkle.appendingPathComponent(name))
        try files.removeItem(at: sparkle.appendingPathComponent("Versions/B/" + name))
    }
    // Installer helpers must share the app's signing identity, including ad-hoc.
    for helper in ["Autoupdate", "Updater.app"] { try sign(sparkle.appendingPathComponent("Versions/B/" + helper)) }
    try sign(sparkle)

    let notices = [
        ("synctex-012d997f6a3a5c5c97b878e1a340db3bffde8c0e/LICENSE", "SyncTeX-MIT.txt"),
        ("djvulibre-3.5.30/COPYING", "DjVuLibre-GPL-2.0.txt"),
        ("chmlib-0.40/COPYING", "CHMLib-LGPL-2.1.txt"),
        ("libjxl-0.12.0/LICENSE", "JPEGXL-BSD-3-Clause.txt"),
        ("libjxl-0.12.0/PATENTS", "JPEGXL-PATENTS.txt"),
        ("highway-457c891775a7397bdb0376bb1031e6e027af1c48/LICENSE", "Highway-Apache-2.0.txt"),
        ("highway-457c891775a7397bdb0376bb1031e6e027af1c48/LICENSE-BSD3", "Highway-BSD-3-Clause.txt"),
        ("mupdf/thirdparty/brotli/LICENSE", "Brotli-MIT.txt"),
        ("mupdf/thirdparty/libjpeg/README", "IJG-JPEG.txt"),
        ("mupdf/thirdparty/jpegxr/Software/COPYRIGHT.txt", "JPEGXR-Reference-Copyright.txt"),
        ("mupdf/COPYING", "MuPDF-AGPL-3.0.txt"),
        ("mupdf/thirdparty/cmark-gfm/COPYING", "CMark-GFM.txt"),
        ("mupdf/thirdparty/freetype/LICENSE.TXT", "FreeType-License.txt"),
        ("mupdf/thirdparty/freetype/docs/FTL.TXT", "FreeType-FTL.txt"),
        ("mupdf/thirdparty/harfbuzz/COPYING", "HarfBuzz.txt"),
        ("mupdf/thirdparty/harfbuzz/src/ms-use/COPYING", "HarfBuzz-MS-USE.txt"),
        ("mupdf/thirdparty/gumbo-parser/doc/COPYING", "Gumbo-Apache-2.0.txt"),
        ("mupdf/thirdparty/jbig2dec/COPYING", "JBIG2Dec-AGPL-3.0.txt"),
        ("mupdf/thirdparty/jbig2dec/LICENSE", "JBIG2Dec-Notice.txt"),
        ("mupdf/thirdparty/lcms2/LICENSE", "LittleCMS.txt"),
        ("mupdf/thirdparty/mujs/COPYING", "MuJS-ISC.txt"),
        ("mupdf/thirdparty/openjpeg/LICENSE", "OpenJPEG.txt"),
        ("mupdf/thirdparty/zlib/LICENSE", "Zlib.txt"),
        ("mupdf/resources/fonts/sil/OFL.txt", "Charis-SIL-OFL.txt"),
        ("mupdf/resources/fonts/urw/OFL.txt", "URW-Fonts-OFL.txt"),
        ("mupdf/resources/fonts/han/LICENSE.txt", "Source-Han-Serif-SIL-OFL.txt"),
        ("mupdf/resources/fonts/noto/COPYING", "Noto-Fonts.txt"),
        ("mupdf/resources/fonts/droid/NOTICE", "Droid-Fonts-Notice.txt"),
        ("convertlit-1.8/clit18/COPYING", "ConvertLIT-GPL-2.0.txt"),
        ("libtommath-1.3.0/LICENSE", "LibTomMath-Unlicense.txt")
    ]
    for (source, name) in notices {
        try files.copyItem(at: root.appendingPathComponent("build/deps/" + source), to: licenses.appendingPathComponent(name))
    }
    for name in ["MuPDF", "DjVu", "CHM", "JPEGXL"] { _ = try bundle(root.appendingPathComponent("build/engines/\(name).dylib")) }

    let tool = contents.appendingPathComponent("Resources/Tools/clit")
    let (rpaths, dependencies) = try macho(tool)
    for dependency in dependencies {
        guard let resolved = resolve(tool, dependency: dependency, rpaths: rpaths) else {
            try fail("Cannot resolve \(dependency) from \(tool.path)")
        }
        let child = try bundle(resolved)
        try run(["install_name_tool", "-change", dependency, "@loader_path/../../Frameworks/" + child.lastPathComponent, tool.path])
    }
    try sign(tool)

    let format = try String(contentsOf: root.appendingPathComponent("Sources/SumraCore/Format.swift"), encoding: .utf8)
    let groups = try matches(#"\(\.(\w+),\s*"([^"]+)"\)"#, in: format)
    let suffixes = groups.flatMap { $0[1].split(separator: " ").map(String.init) }
    // Keep the installed identity so preferences, recent documents and macOS
    // restoration survive the product rename.
    var info: [String: Any] = [
        "CFBundleName": "Sumra", "CFBundleDisplayName": "Sumra", "CFBundleExecutable": "Sumra",
        "CFBundleIdentifier": "dev.aresx.leaf", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": buildVersion,
        "CFBundleGetInfoString": "Sumra " + version, "NSHumanReadableCopyright": "© 2026 Sumra contributors",
        "LSApplicationCategoryType": "public.app-category.productivity",
        "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": true,
        "CFBundleDocumentTypes": [[
            "CFBundleTypeName": "Readable documents", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
            "CFBundleTypeExtensions": Set(suffixes).sorted()
        ]],
        "CFBundleURLTypes": [[
            "CFBundleURLName": "dev.aresx.leaf.synctex", "CFBundleTypeRole": "Viewer",
            "CFBundleURLSchemes": ["sumra"]
        ]],
        "LSSupportsOpeningDocumentsInPlace": true, "LSMultipleInstancesProhibited": true,
        "CFBundleIconFile": "Sumra-Light.icns"
    ]
    // Dedicated book/comic UTIs keep ordinary ZIP/RAR/7z archives out of Quick Look.
    let quickLook = quickLookRegistration()
    info["UTExportedTypeDeclarations"] = quickLook.exported
    info["UTImportedTypeDeclarations"] = quickLook.imported
    var documentTypes = info["CFBundleDocumentTypes"] as! [[String: Any]]
    documentTypes.append([
        "CFBundleTypeName": "Ebooks and comics", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
        "LSItemContentTypes": quickLook.contentTypes
    ])
    info["CFBundleDocumentTypes"] = documentTypes
    if !updateFeed.isEmpty {
        info["SUFeedURL"] = updateFeed
        info["SUPublicEDKey"] = updateKey
        info["SUEnableAutomaticChecks"] = true
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))

    let contentTypes = quickLook.contentTypes
    var extensions = [URL]()
    for (kind, point, principal) in [("Thumbnail", "thumbnail", "ThumbnailProvider"), ("Preview", "preview", "PreviewViewController")] {
        let bundle = contents.appendingPathComponent("PlugIns/Sumra\(kind).appex")
        let extensionInfo: [String: Any] = [
            "CFBundleName": "Sumra \(kind)", "CFBundleExecutable": "SumraQuickLook",
            "CFBundleIdentifier": "dev.aresx.leaf.\(point)", "CFBundlePackageType": "XPC!",
            "CFBundleShortVersionString": version, "CFBundleVersion": buildVersion,
            "LSMinimumSystemVersion": "13.0",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.quicklook.\(point)",
                "NSExtensionPrincipalClass": principal,
                "NSExtensionAttributes": ["QLSupportedContentTypes": contentTypes,
                    "QLThumbnailMinimumDimension": 0, "QLSupportsSearchableItems": false, "QLIsDataBasedPreview": false]]
        ]
        try PropertyListSerialization.data(fromPropertyList: extensionInfo, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        extensions.append(bundle)
    }

    // Check the finished payload, including SwiftPM's executable and Sparkle's
    // nested updater binaries. Decoder checks cannot cover those inputs.
    let targetMacOS = macOSVersion("13.0")
    let magic: Set<Data> = [
        Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xcf, 0xfa, 0xed, 0xfe]),
        Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
        Data([0xca, 0xfe, 0xba, 0xbf]), Data([0xbf, 0xba, 0xfe, 0xca])
    ]
    let enumerator = files.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
    for case let path as URL in enumerator {
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isRegularFile != true || values.isSymbolicLink == true { continue }
        let handle = try FileHandle(forReadingFrom: path)
        let prefix = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        if !magic.contains(prefix) { continue }
        if !(try run(["lipo", "-archs", path.path]).split(whereSeparator: { $0.isWhitespace }).contains("arm64")) {
            try fail("\(path.path) has no arm64 slice.")
        }
        let commands = try run(["otool", "-l", "-arch", "arm64", path.path])
        let minimums = try matches(#"cmd LC_BUILD_VERSION\n\s*cmdsize \d+\n\s*platform 1\n\s*minos ([\d.]+)"#, in: commands)
            + matches(#"cmd LC_VERSION_MIN_MACOSX\n\s*cmdsize \d+\n\s*version ([\d.]+)"#, in: commands)
        if minimums.isEmpty { try fail("\(path.path) has no macOS deployment target.") }
        for minimum in minimums where targetMacOS.lexicographicallyPrecedes(macOSVersion(minimum[0])) {
            try fail("\(path.path) requires macOS \(minimum[0]), above the app's macOS 13.0 target.")
        }
        let (rpaths, dependencies) = try macho(path, arch: "arm64")
        for dependency in dependencies {
            guard let resolved = resolve(path, dependency: dependency, rpaths: rpaths),
                  resolved.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(contents.path + "/") else {
                try fail("\(path.path) has an unbundled dependency: \(dependency)")
            }
        }
    }
    for target in copied.values {
        try run(["strip", "-x", target.path])
        try sign(target)
    }
    for path in extensions {
        try sign(path, entitlements: root.appendingPathComponent("Assets/QuickLook.entitlements").path)
    }
    try sign(contents.deletingLastPathComponent(), entitlements: environment["SUMRA_CODE_SIGN_ENTITLEMENTS"])
    print("\(copied.count) decoder dylibs bundled.")
}

#if !BUNDLE_METADATA_TESTS
do { try package() }
catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
#endif
