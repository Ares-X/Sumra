#!/usr/bin/env swift
// Inventory and archive corresponding source and the candidate app; never sign or publish.
import Foundation
import CryptoKit
import Darwin

struct PackagingError: Error, CustomStringConvertible { let description: String; init(_ message: String) { description = message } }
let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
func fail(_ message: String) throws -> Never { throw PackagingError(message) }
func run(_ args: [String], directory: URL? = nil, environment: [String: String]? = nil) throws -> (Data, Data) {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = args
    process.currentDirectoryURL = directory; process.environment = environment
    // File-backed output avoids deadlock when inventory commands produce large output.
    let temporary = fm.temporaryDirectory.appendingPathComponent("sumra-package-process-" + UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: temporary) }
    let output = temporary.appendingPathComponent("out"), error = temporary.appendingPathComponent("err")
    fm.createFile(atPath: output.path, contents: nil); fm.createFile(atPath: error.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: error)
    process.standardOutput = stdout; process.standardError = stderr
    try process.run(); process.waitUntilExit(); try stdout.close(); try stderr.close()
    let data = try Data(contentsOf: output), errors = try Data(contentsOf: error)
    if process.terminationStatus != 0 { try fail("\(args.first ?? "command") failed (\(process.terminationStatus)): \(String(decoding: errors, as: UTF8.self))") }
    return (data, errors)
}
func text(_ args: [String], directory: URL? = nil) throws -> String { String(decoding: try run(args, directory: directory).0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
    while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func attributes(_ url: URL) throws -> [FileAttributeKey: Any] { try fm.attributesOfItem(atPath: url.path) }
func mode(_ url: URL) throws -> Int { (try attributes(url)[.posixPermissions] as! NSNumber).intValue }
func json(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
func equal(_ lhs: Any?, _ rhs: Any?) -> Bool { NSDictionary(dictionary: ["value": lhs ?? NSNull()]).isEqual(to: ["value": rhs ?? NSNull()]) }
func writeJSON(_ value: [String: Any], to url: URL, exclusive: Bool = false) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]); data.append(10)
    try data.write(to: url, options: exclusive ? [.withoutOverwriting] : [])
}
func walk(_ directory: URL, _ visit: (URL, String, FileAttributeType) throws -> Void) throws {
    func descend(_ parent: URL, _ prefix: String) throws {
        for name in try fm.contentsOfDirectory(atPath: parent.path).sorted() {
            let path = parent.appendingPathComponent(name), relative = prefix + name
            let kind = try attributes(path)[.type] as! FileAttributeType
            try visit(path, relative, kind)
            if kind == .typeDirectory { try descend(path, relative + "/") }
        }
    }
    try descend(directory, "")
}
func appInventory(_ app: URL) throws -> [String: Any] {
    var files = [String: String](), links = [String: String](), modes = [String: Int](), directories = ["": try mode(app)]
    try walk(app) { path, name, kind in
        switch kind {
        case .typeSymbolicLink: links[name] = try fm.destinationOfSymbolicLink(atPath: path.path)
        case .typeRegular: files[name] = try digest(path); modes[name] = try mode(path)
        case .typeDirectory: directories[name] = try mode(path)
        default: try fail("Unexpected candidate app entry: \(path.path)")
        }
    }
    return ["app_files": files, "app_symlinks": links, "app_modes": modes, "app_directories": directories]
}

// macOS ships libarchive. Read entries directly rather than parsing human-oriented listings.
final class ArchiveReader {
    let library: UnsafeMutableRawPointer
    let create: @convention(c) () -> OpaquePointer?
    let supportFilter: @convention(c) (OpaquePointer?) -> Int32
    let supportFormat: @convention(c) (OpaquePointer?) -> Int32
    let open: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    let next: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    let read: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    let free: @convention(c) (OpaquePointer?) -> Int32
    let pathname: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let permissions: @convention(c) (OpaquePointer?) -> UInt32
    let filetype: @convention(c) (OpaquePointer?) -> UInt32
    let symlink: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let hardlink: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let error: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    let format: @convention(c) (OpaquePointer?) -> Int32
    let filter: @convention(c) (OpaquePointer?, Int32) -> Int32
    init() throws {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW) else { try fail("Cannot open macOS libarchive") }; library = handle
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T { guard let value = dlsym(handle, name) else { try fail("Missing libarchive symbol: \(name)") }; return unsafeBitCast(value, to: type) }
        create = try symbol("archive_read_new", type(of: create)); supportFilter = try symbol("archive_read_support_filter_all", type(of: supportFilter)); supportFormat = try symbol("archive_read_support_format_all", type(of: supportFormat)); open = try symbol("archive_read_open_filename", type(of: open)); next = try symbol("archive_read_next_header", type(of: next)); read = try symbol("archive_read_data", type(of: read)); free = try symbol("archive_read_free", type(of: free)); pathname = try symbol("archive_entry_pathname", type(of: pathname)); permissions = try symbol("archive_entry_perm", type(of: permissions)); filetype = try symbol("archive_entry_filetype", type(of: filetype)); symlink = try symbol("archive_entry_symlink", type(of: symlink)); hardlink = try symbol("archive_entry_hardlink", type(of: hardlink)); error = try symbol("archive_error_string", type(of: error))
        format = try symbol("archive_format", type(of: format)); filter = try symbol("archive_filter_code", type(of: filter))
    }
    deinit { dlclose(library) }
    func verify(_ url: URL, files: [String: String], links: [String: String], modes: [String: Int], directories: [String: Int] = [:], gzipTar: Bool = false) throws {
        let archive = create(); defer { _ = free(archive) }; _ = supportFilter(archive); _ = supportFormat(archive)
        func check(_ result: Int32) throws { if result < 0 { try fail("Archive read failed: \(error(archive).map { String(cString: $0) } ?? url.path)") } }
        try check(url.path.withCString { open(archive, $0, 1024 * 1024) })
        let expected = Set(files.keys).union(links.keys).union(directories.keys); var seen = Set<String>()
        var entry: OpaquePointer?; var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let status = next(archive, &entry); if status == 1 { break }; try check(status)
            if gzipTar && (format(archive) & 0xff0000 != 0x30000 || filter(archive, 0) != 1) { try fail("Expected a gzip source tar archive") }
            let name = String(cString: pathname(entry)!)
            guard expected.contains(name), seen.insert(name).inserted else { try fail("Unexpected or duplicate archived entry: \(name)") }
            let kind = filetype(entry), entryMode = Int(permissions(entry))
            if let expectedMode = directories[name] {
                guard kind == UInt32(S_IFDIR), entryMode == expectedMode else { try fail("Archived app directory changed during packaging: \(name)") }
            } else if let expectedHash = files[name] {
                guard kind == UInt32(S_IFREG), hardlink(entry) == nil else { try fail("Archived source/app is not a regular file: \(name)") }
                guard entryMode == modes[name] else { try fail("Archived permissions changed during packaging: \(name)") }
                var hash = SHA256()
                while true {
                    let count = read(archive, &buffer, buffer.count)
                    if count < 0 { try fail("Cannot read archived bytes: \(name)") }; if count == 0 { break }
                    hash.update(data: Data(buffer.prefix(count)))
                }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else { try fail("Archived bytes changed during packaging: \(name)") }
            } else {
                guard kind == UInt32(S_IFLNK), symlink(entry).map({ String(cString: $0) }) == links[name] else { try fail("Archived link changed during packaging: \(name)") }
            }
        }
        guard seen == expected else { try fail("Missing archived entry: \(expected.subtracting(seen).sorted().joined(separator: ", "))") }
    }
}
func verifySourceArchive(_ path: URL, _ files: [String: [String: Any]], _ links: [String: String]) throws {
    let prefix = "Sumra-source/"
    try ArchiveReader().verify(path, files: Dictionary(uniqueKeysWithValues: files.map { (prefix + $0.key, $0.value["sha256"] as! String) }), links: Dictionary(uniqueKeysWithValues: links.map { (prefix + $0.key, $0.value) }), modes: Dictionary(uniqueKeysWithValues: files.map { (prefix + $0.key, ($0.value["mode"] as! NSNumber).intValue) }), gzipTar: true)
}
func verifyAppArchive(_ path: URL, _ appName: String, _ inventory: [String: Any]) throws {
    let prefix = appName + "/"
    try verifyZipDirectory(path, prefix, inventory)
    try ArchiveReader().verify(path, files: Dictionary(uniqueKeysWithValues: (inventory["app_files"] as! [String: String]).map { (prefix + $0.key, $0.value) }), links: Dictionary(uniqueKeysWithValues: (inventory["app_symlinks"] as! [String: String]).map { (prefix + $0.key, $0.value) }), modes: Dictionary(uniqueKeysWithValues: (inventory["app_modes"] as! [String: Int]).map { (prefix + $0.key, $0.value) }), directories: Dictionary(uniqueKeysWithValues: (inventory["app_directories"] as! [String: Int]).map { (prefix + $0.key + ($0.key.isEmpty ? "" : "/"), $0.value) }))
}
// ZIP readers normalize trailing-slash entries to directories. Check the stored
// central-directory attributes too, so a mistyped directory cannot pass.
func verifyZipDirectory(_ path: URL, _ prefix: String, _ inventory: [String: Any]) throws {
    let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
    let length = try handle.seekToEnd(), tailSize = min(length, 65557)
    try handle.seek(toOffset: length - tailSize)
    let tail = try handle.readToEnd()!
    func number(_ data: Data, _ offset: Int, _ size: Int) -> UInt64 {
        (0..<size).reduce(UInt64(0)) { $0 | (UInt64(data[data.startIndex + offset + $1]) << ($1 * 8)) }
    }
    guard tail.count >= 22, let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { number(tail, $0, 4) == 0x06054b50 && $0 + 22 + Int(number(tail, $0 + 20, 2)) == tail.count }) else { try fail("Missing ZIP central directory") }
    var count = number(tail, end + 10, 2), offset = number(tail, end + 16, 4)
    func read(_ size: Int) throws -> Data {
        let data = try handle.read(upToCount: size) ?? Data(); guard data.count == size else { try fail("Truncated ZIP central directory") }; return data
    }
    if count == 0xffff || offset == 0xffffffff {
        let endOffset = length - tailSize + UInt64(end)
        guard endOffset >= 20 else { try fail("Missing ZIP64 locator") }
        try handle.seek(toOffset: endOffset - 20); let locator = try read(20)
        guard number(locator, 0, 4) == 0x07064b50 else { try fail("Missing ZIP64 locator") }
        try handle.seek(toOffset: number(locator, 8, 8)); let record = try read(56)
        guard number(record, 0, 4) == 0x06064b50 else { try fail("Missing ZIP64 central directory") }
        count = number(record, 32, 8); offset = number(record, 48, 8)
    }
    let files = inventory["app_files"] as! [String: String], links = inventory["app_symlinks"] as! [String: String], modes = inventory["app_modes"] as! [String: Int], directories = inventory["app_directories"] as! [String: Int]
    let expected = Set(files.keys.map { prefix + $0 }).union(links.keys.map { prefix + $0 }).union(directories.keys.map { prefix + $0 + ($0.isEmpty ? "" : "/") })
    var seen = Set<String>(); try handle.seek(toOffset: offset)
    for _ in 0..<count {
        let header = try read(46); guard number(header, 0, 4) == 0x02014b50 else { try fail("Invalid ZIP central directory entry") }
        let nameData = try read(Int(number(header, 28, 2))), name = String(decoding: nameData, as: UTF8.self)
        _ = try read(Int(number(header, 30, 2) + number(header, 32, 2)))
        guard expected.contains(name), seen.insert(name).inserted else { try fail("Unexpected or duplicate archived app file: \(name)") }
        let rawMode = UInt32(number(header, 38, 4) >> 16), kind = rawMode & UInt32(S_IFMT), storedMode = Int(rawMode & 0o7777)
        guard number(header, 5, 1) == 3 else { try fail("Archived app entry lacks POSIX attributes: \(name)") }
        let relative = String(name.dropFirst(prefix.count)), directoryName = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
        if let expectedMode = directories[directoryName], name.hasSuffix("/") {
            guard kind == UInt32(S_IFDIR), storedMode == expectedMode else { try fail("Archived app directory changed during packaging: \(name)") }
        } else if files[relative] != nil {
            guard kind == UInt32(S_IFREG), storedMode == modes[relative] else { try fail("Archived app file type or permissions changed during packaging: \(name)") }
        } else { guard kind == UInt32(S_IFLNK) else { try fail("Archived app link type changed during packaging: \(name)") } }
    }
    guard seen == expected else { try fail("Missing archived app file") }
}
func archiveApp(_ app: URL, _ archive: URL) throws {
    try walk(app) { path, _, kind in
        if kind == .typeRegular {
            let fd = Darwin.open(path.path + "/..namedfork/rsrc", O_RDONLY)
            if fd >= 0 { defer { Darwin.close(fd) }; var byte: UInt8 = 0; let count = Darwin.read(fd, &byte, 1); if count > 0 { try fail("Candidate has an unarchived resource fork: \(path.path)") }; if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) } }
            else if errno != ENOENT && errno != ENOTDIR { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        }
    }
    _ = try run(["ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noacl", "--noqtn", app.path, archive.path])
}
func appMetadata(_ app: URL) throws -> [String: Any] {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    let signature = String(decoding: try run(["codesign", "--display", "--verbose=4", app.path]).1, as: UTF8.self)
    let fields: Set<String> = ["Identifier", "Format", "CodeDirectory", "Signature", "Authority", "TeamIdentifier", "Timestamp", "CDHash", "Runtime Version"]
    var signing = [String: [String]]()
    for line in signature.split(separator: "\n").map(String.init) {
        if line.hasPrefix("CodeDirectory ") { signing["CodeDirectory", default: []].append(String(line.dropFirst(14))); continue }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 && fields.contains(String(parts[0])) { signing[String(parts[0]), default: []].append(String(parts[1])) }
    }
    let keys = ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks"]
    return ["info_plist": Dictionary(uniqueKeysWithValues: keys.map { ($0, info[$0] ?? NSNull()) }), "architectures": try text(["lipo", "-archs", app.appendingPathComponent("Contents/MacOS/Sumra").path]).split(separator: " ").map(String.init), "signature": signing, "gatekeeper_public_acceptance": "not_exercised"]
}
func validateFrozenSource(_ sourcePath: URL, _ manifest: [String: Any]) throws -> [String: Any] {
    let source = try json(sourcePath)
    for key in ["origins", "files", "symlinks", "project_revision", "source_build_match"] { if !equal(source[key], manifest[key]) { try fail("Frozen source receipt does not match current allowlisted source: \(key)") } }
    return source
}
func recordBuild(_ destination: URL, _ sourcePath: URL, _ manifest: [String: Any], _ app: URL) throws {
    _ = try validateFrozenSource(sourcePath, manifest)
    _ = try run(["codesign", "--verify", "--deep", "--strict", app.path])
    let sourceHash = try digest(sourcePath)
    try writeJSON(["source_inputs_sha256": sourceHash, "final_source_inputs_sha256": sourceHash, "build_exit": 0, "project_revision": manifest["project_revision"]!, "recorded_at": ISO8601DateFormatter().string(from: Date()), "bundle": try appInventory(app), "metadata": try appMetadata(app)], to: destination, exclusive: true)
}
func validateFrozenReceipts(_ sourcePath: URL, _ buildPath: URL, _ manifest: [String: Any], _ bundle: [String: Any], _ metadata: [String: Any]) throws -> [String: Any] {
    let source = try validateFrozenSource(sourcePath, manifest), build = try json(buildPath), sourceHash = try digest(sourcePath)
    guard build["source_inputs_sha256"] as? String == sourceHash, build["final_source_inputs_sha256"] as? String == sourceHash else { try fail("Build receipt does not bind to the supplied frozen source receipt") }
    guard (build["build_exit"] as? NSNumber)?.intValue == 0 else { try fail("Build receipt reports an unsuccessful build") }
    guard equal(build["bundle"], bundle) else { try fail("Current app does not match frozen build receipt: bundle inventory") }
    guard equal(build["metadata"], metadata) else { try fail("Current app metadata does not match frozen build receipt") }
    return ["source_receipt_sha256": sourceHash, "build_receipt_sha256": try digest(buildPath), "source_origins": source["origins"]!, "source_files": source["files"]!, "source_symlinks": source["symlinks"]!, "app_bundle": build["bundle"]!, "app_metadata": build["metadata"]!, "source_build_match": "matches_frozen_build_receipt", "claim_limit": "Receipt correspondence only; not reproducibility, redistribution, or signing proof."]
}
struct SourceInput {
    let path: URL?
    let generated: Data?
    init(path: URL) { self.path = path; generated = nil }
    init(data: Data) { path = nil; generated = data }
}
func inventory() throws -> ([String: SourceInput], [String: String], [String: Any]) {
    var files = [String: SourceInput](), origins = [[String: Any]](), revisions = [String: String](), links = [(URL, String)]()
    let skip: Set<String> = [".git", ".DS_Store", "__pycache__", ".serena", ".swiftpm"]
    let products: Set<String> = ["o", "a", "so", "dylib", "pyc", "pyo"]
    func add(_ path: URL, _ destination: String) throws {
        let kind = try attributes(path)[.type] as! FileAttributeType
        if kind == .typeSymbolicLink { links.append((path, destination)) }
        else if kind == .typeRegular { files[destination] = SourceInput(path: path) }
        else { try fail("Missing source input: \(path.path)") }
    }
    func tree(_ directory: URL, _ destination: String, archive: Bool = false) throws {
        func descend(_ parent: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: parent.path).sorted() where !skip.contains(name) {
                let path = parent.appendingPathComponent(name), relative = prefix + name
                let kind = try attributes(path)[.type] as! FileAttributeType
                if kind == .typeDirectory { try descend(path, relative + "/") }
                else if kind == .typeSymbolicLink || (!products.contains(path.pathExtension) && !(archive && name == "clit")) { try add(path, destination + "/" + relative) }
            }
        }
        try descend(directory, "")
    }
    func git(_ directory: URL, _ args: [String]) throws -> String { try text(["git", "-C", directory.path] + args) }
    func repository(_ directory: URL, _ destination: String, _ expected: String? = nil) throws {
        let revision = try git(directory, ["rev-parse", "HEAD"])
        if let expected, revision != expected { try fail("Unexpected source revision: \(directory.path): \(revision), expected \(expected)") }
        origins.append(["path": destination, "revision": revision]); revisions[destination] = revision
        let entries = String(decoding: try run(["git", "-C", directory.path, "ls-files", "--stage", "-z"]).0, as: UTF8.self).split(separator: "\0")
        for entry in entries {
            let parts = entry.split(separator: "\t", maxSplits: 1), metadata = parts[0].split(separator: " "), name = String(parts[1])
            guard metadata[2] == "0" else { try fail("Unmerged source input: \(directory.appendingPathComponent(name).path)") }
            if name.split(separator: "/").contains(where: { skip.contains(String($0)) }) { continue }
            if metadata[0] == "160000" { try repository(directory.appendingPathComponent(name), destination + "/" + name, String(metadata[1])) }
            else { try add(directory.appendingPathComponent(name), destination + "/" + name) }
        }
    }
    for name in ["LICENSE", "THIRD_PARTY.md", "README.md", "README.zh-CN.md", "Package.swift", "Package.resolved", ".gitignore"] { try add(root.appendingPathComponent(name), name) }
    for name in ["Sources", "Tests", "Native", "scripts", "Assets", "Licenses", "docs"] { try tree(root.appendingPathComponent(name), name) }
    if fm.fileExists(atPath: root.appendingPathComponent(".github/workflows").path) { try tree(root.appendingPathComponent(".github/workflows"), ".github/workflows") }
    try repository(root.appendingPathComponent("build/deps/mupdf"), "build/deps/mupdf", "f030eda1e472268667805f438e38cee8f1da61f8")
    try repository(root.appendingPathComponent("build/deps/mupdf/thirdparty/jpegxr"), "build/deps/mupdf/thirdparty/jpegxr", "71ff24a9eb9a5c8dd70e1fd97a5316e06b0b0791")
    let pin = (try json(root.appendingPathComponent("Package.resolved"))["pins"] as! [[String: Any]]).first { $0["identity"] as? String == "sparkle" }!
    let state = pin["state"] as! [String: String]
    try repository(root.appendingPathComponent(".build/checkouts/Sparkle"), "upstream/Sparkle", state["revision"]!)
    origins[origins.count - 1]["url"] = pin["location"]; origins[origins.count - 1]["version"] = state["version"]
    let expression = try NSRegularExpression(pattern: "^source_archive (\\S+) (\\S+) ([0-9a-f]{64}) (\\d+)$", options: .anchorsMatchLines)
    for script in ["build-engines.sh", "build-codecs.sh"] {
        let scriptText = try String(contentsOf: root.appendingPathComponent("scripts/" + script), encoding: .utf8)
        for match in expression.matches(in: scriptText, range: NSRange(scriptText.startIndex..., in: scriptText)) {
            let values = (1...4).map { String(scriptText[Range(match.range(at: $0), in: scriptText)!]) }
            let directory = root.appendingPathComponent("build/deps/" + values[0])
            guard try String(contentsOf: directory.appendingPathComponent(".leaf-source"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == values[2] else { try fail("Unexpected archive source marker: \(directory.path)") }
            let destination = "build/deps/" + values[0]
            origins.append(["path": destination, "url": values[1], "archive_sha256": values[2], "strip_components": Int(values[3])!]); try tree(directory, destination, archive: true)
        }
    }
    let syncRevision = "012d997f6a3a5c5c97b878e1a340db3bffde8c0e", syncPath = "build/deps/synctex-012d997f6a3a5c5c97b878e1a340db3bffde8c0e"
    for name in ["synctex_parser.c", "synctex_parser_utils.c", "synctex_parser.h", "synctex_parser_advanced.h", "synctex_parser_utils.h", "synctex_version.h", "LICENSE"] { try add(root.appendingPathComponent(syncPath + "/" + name), syncPath + "/" + name) }
    origins.append(["path": syncPath, "revision": syncRevision, "url": "https://github.com/sumatrapdfreader/sumatrapdf/tree/\(syncRevision)/ext/synctex"])
    var symlinks = [String: String]()
    for (path, destination) in links {
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: resolved.path) else { try fail("Source link escapes the allowlist: \(path.path)") }
        let matches = files.filter { _, input in input.path == resolved || input.path?.path.hasPrefix(resolved.path + "/") == true }.sorted { $0.key < $1.key }
        guard let match = matches.first, let source = match.value.path else { try fail("Source link escapes the allowlist: \(path.path)") }
        var target = match.key
        if try attributes(resolved)[.type] as! FileAttributeType == .typeDirectory {
            for _ in source.path.dropFirst(resolved.path.count + 1).split(separator: "/") { target = (target as NSString).deletingLastPathComponent }
        }
        let parentParts = (destination as NSString).deletingLastPathComponent.split(separator: "/"), targetParts = target.split(separator: "/")
        var common = 0; while common < min(parentParts.count, targetParts.count) && parentParts[common] == targetParts[common] { common += 1 }
        symlinks[destination] = (Array(repeating: "..", count: parentParts.count - common) + targetParts.dropFirst(common).map(String.init)).joined(separator: "/")
    }
    for (destination, revision) in revisions { files[destination + "/.sumra-source-revision"] = SourceInput(data: Data((revision + "\n").utf8)) }
    files["SOURCE_PACKAGE_BUILD.md"] = SourceInput(data: Data(sourceBuildNotes.utf8))
    var records = [String: [String: Any]]()
    for (name, input) in files {
        if let generated = input.generated { records[name] = ["sha256": digest(generated), "bytes": generated.count, "mode": 0o644, "generated": true] }
        else { let path = input.path!; records[name] = ["sha256": try digest(path), "bytes": try attributes(path)[.size]!, "mode": try mode(path)] }
    }
    return (files, symlinks, ["origins": origins, "files": records, "symlinks": symlinks])
}
let sourceBuildNotes = """
# Building the exported Sumra source

This is the release source snapshot with the existing patches applied.
Its provenance records exact upstream revisions and the actual file hashes.
See provenance.json for frozen build-receipt correspondence and the
bounded source/notice review status. Receipt matching is not reproducibility.

After verifying SHA256SUMS, extract into a new empty directory with
`tar -xkzf Sumra-corresponding-source.tar.gz -C <empty-directory>`.
Compare extracted file SHA256 values and relative symlink targets to
the `files` and `symlinks` objects in the accompanying provenance.json.

Run from Sumra-source on macOS with the build prerequisites listed in README.md:

- `./scripts/build-engines.sh` rebuilds the four native engines and ConvertLIT.
- `./scripts/build-app.sh --release` builds and packages the GUI app.
- `./scripts/check-source.sh` runs the unified source and test checks.

MuPDF and JPEGXR have no Git metadata in this export. Matching
`.sumra-source-revision` markers tell the existing build script to use the
included source and recursive submodules without checking out over them.
Archive-source dependencies retain their verified `.leaf-source` markers.
Both kinds of markers identify provenance; file hashes identify the patched bytes.

SwiftPM continues to resolve the pinned Sparkle binary framework. Its matching
upstream source is included under upstream/Sparkle. This does not change
the dependency strategy or establish a complete offline SwiftPM build.
No private signing identity or update keys are supplied. The default result
is an ad-hoc signed, nonnotarized local application.

"""
func archiveSource(_ archive: URL, _ files: [String: SourceInput], _ links: [String: String]) throws {
    let staging = fm.temporaryDirectory.appendingPathComponent("sumra-package-source-" + UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false); defer { try? fm.removeItem(at: staging) }
    for (name, input) in files {
        let target = staging.appendingPathComponent("Sumra-source/" + name)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = input.generated { try data.write(to: target); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path) }
        else { try fm.copyItem(at: input.path!, to: target) }
    }
    for (name, link) in links {
        let target = staging.appendingPathComponent("Sumra-source/" + name)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
    }
    let list = staging.appendingPathComponent("entries")
    try Data((files.keys.sorted() + links.keys.sorted()).map { "Sumra-source/" + $0 + "\0" }.joined().utf8).write(to: list)
    var environment = ProcessInfo.processInfo.environment; environment["COPYFILE_DISABLE"] = "1"
    _ = try run(["tar", "--no-mac-metadata", "--uid", "0", "--gid", "0", "--uname", "", "--gname", "", "-czf", archive.path, "-C", staging.path, "--no-recursion", "--null", "-T", list.path], environment: environment)
}
func packageArtifacts(_ app: URL, _ output: URL, _ files: [String: SourceInput], _ links: [String: String], _ provenance: [String: Any], appArchive: URL? = nil, receipts: Bool = false) throws {
    guard !fm.fileExists(atPath: output.path) else { try fail("Output directory already exists: \(output.path)") }
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard Darwin.mkdir(output.path, 0o755) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    let sourceTar = output.appendingPathComponent("Sumra-corresponding-source.tar.gz")
    try archiveSource(sourceTar, files, links); try verifySourceArchive(sourceTar, provenance["files"] as! [String: [String: Any]], links)
    let version = ((provenance["app_metadata"] as! [String: Any])["info_plist"] as! [String: Any])["CFBundleShortVersionString"] as! String
    let appZip = output.appendingPathComponent("Sumra-\(version)-macOS-arm64.zip")
    if let appArchive { try fm.linkItem(at: appArchive.resolvingSymlinksInPath(), to: appZip) } else { try archiveApp(app, appZip) }
    try verifyAppArchive(appZip, app.lastPathComponent, provenance)
    let manifest = output.appendingPathComponent("provenance.json"), notes = output.appendingPathComponent("README.txt")
    try writeJSON(provenance, to: manifest)
    let correspondence = receipts ? "Source and app match the frozen build receipts embedded in provenance.json.\nThis establishes receipt correspondence, not reproducibility.\n" : "Source/build matching is not attested.\n"
    let noteText = "Sumra \(version) — nonnotarized community release artifacts\n\n" + correspondence + """
The bounded source/notice review found no demonstrated missing inputs.
This archive does not establish Developer ID, notarization or Gatekeeper acceptance.

Verify from this directory: shasum -a 256 -c SHA256SUMS
Extract sources into a new empty directory:
  mkdir source-extraction
  tar -xkzf Sumra-corresponding-source.tar.gz -C source-extraction
Source file hashes and relative link targets are listed in provenance.json.
The packager verifies complete file/link membership, types, file modes, bytes and link
targets against that inventory before success.
Project sources retain all local patches, resources, licenses and build scripts.
Public upstream test fixtures are included as part of upstream source trees.
The allowlist excludes repository metadata, session data and local build/test evidence.
See Sumra-source/README.md for macOS build prerequisites. Sparkle's matching
source is in upstream/Sparkle; SwiftPM resolves the existing pinned binary framework.

"""
    try noteText.write(to: notes, atomically: false, encoding: .utf8)
    let sums = try [sourceTar, appZip, manifest, notes].map { try digest($0) + "  " + $0.lastPathComponent + "\n" }.joined()
    try sums.write(to: output.appendingPathComponent("SHA256SUMS"), atomically: false, encoding: .utf8)
}
func packageMain() throws {
    let known: Set<String> = ["--inventory", "--app", "--app-archive", "--output", "--source-receipt", "--build-receipt", "--record-build"]
    var arguments = [String: URL](); let args = Array(CommandLine.arguments.dropFirst()); var index = 0
    while index < args.count {
        if args[index] == "--help" || args[index] == "-h" { print("Usage: package-release.swift [--inventory FILE] [--app APP --output NEW_DIRECTORY] [--app-archive ZIP] [--source-receipt JSON --build-receipt JSON]\n       package-release.swift --record-build FILE --source-receipt JSON --app APP\nInventory and archive the release app and corresponding source; never sign or publish."); return }
        guard known.contains(args[index]), index + 1 < args.count else { try fail("Unknown option or missing value: \(args[index])") }
        arguments[args[index]] = URL(fileURLWithPath: args[index + 1]); index += 2
    }
    let appArgument = arguments["--app"], output = arguments["--output"], sourceReceipt = arguments["--source-receipt"], buildReceipt = arguments["--build-receipt"], recordDestination = arguments["--record-build"]
    if recordDestination != nil {
        guard appArgument != nil, sourceReceipt != nil, output == nil, buildReceipt == nil, arguments["--app-archive"] == nil, arguments["--inventory"] == nil else { try fail("--record-build requires --source-receipt and --app only") }
    } else {
        guard (appArgument == nil) == (output == nil) else { try fail("--app and --output must be supplied together") }
        guard (sourceReceipt == nil) == (buildReceipt == nil) else { try fail("--source-receipt and --build-receipt must be supplied together") }
    }
    guard arguments["--app-archive"] == nil || appArgument != nil else { try fail("--app-archive requires --app and --output") }
    guard sourceReceipt == nil || appArgument != nil else { try fail("frozen receipts require --app and --output") }
    let (files, links, source) = try inventory(); var provenance = source
    provenance["status"] = "nonnotarized-release-artifacts"; provenance["redistribution_audit"] = "bounded_review_no_demonstrated_missing_inputs"; provenance["source_build_match"] = "not_attested"
    provenance["project_revision"] = try text(["git", "-C", root.path, "rev-parse", "HEAD"])
    let bytes = (provenance["files"] as! [String: [String: Any]]).values.reduce(Int64(0)) { $0 + ($1["bytes"] as! NSNumber).int64Value }
    print("Allowlisted \(files.count) source files, \(links.count) relative links; \(bytes) bytes.")
    if let destination = arguments["--inventory"] { try writeJSON(provenance, to: destination, exclusive: true) }
    guard let appArgument else { return }
    let app = appArgument.resolvingSymlinksInPath()
    guard app.pathExtension == "app", fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Sumra").path) else { try fail("Expected a packaged Sumra.app") }
    if let recordDestination, let sourceReceipt {
        try recordBuild(recordDestination, sourceReceipt, provenance, app)
        print("Recorded verified build receipt in \(recordDestination.path).")
        return
    }
    guard let output else { return }
    _ = try run(["codesign", "--verify", "--deep", "--strict", app.path])
    let candidate = try appInventory(app), metadata = try appMetadata(app)
    provenance.merge(candidate) { _, new in new }; provenance["app_metadata"] = metadata
    if let sourceReceipt, let buildReceipt { provenance["frozen_build_receipts"] = try validateFrozenReceipts(sourceReceipt, buildReceipt, provenance, candidate, metadata); provenance["source_build_match"] = "matches_frozen_build_receipt" }
    let swiftVersion = try run(["swift", "--version"])
    provenance["build_host"] = ["macos": try text(["sw_vers"]), "swift_toolchain": String(decoding: swiftVersion.0 + swiftVersion.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]
    try packageArtifacts(app, output, files, links, provenance, appArchive: arguments["--app-archive"], receipts: sourceReceipt != nil)
    print("Created verified release artifacts in \(output.path); publication is a separate action. The app is not notarized.")
}
#if !PACKAGING_TESTS
do { try packageMain() } catch { fputs("package-release: \(error)\n", stderr); exit(1) }
#endif
