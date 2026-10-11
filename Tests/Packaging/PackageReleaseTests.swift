// Behavior tests for release archive correspondence and frozen receipts.
struct FixtureEntry {
    var name: String
    var kind: UInt32 = UInt32(S_IFREG)
    var data: Data
    var mode: Int = 0o644
}
var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { try fail("Test failed: " + message) }; checks += 1
}
func rejected(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { checks += 1; return }
    try fail("Expected rejection: " + message)
}
func little(_ value: UInt32, _ width: Int = 4) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
func crc(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xffffffff
    for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xedb88320) } }
    return value ^ 0xffffffff
}
func fixtureZip(_ entries: [FixtureEntry], _ url: URL) throws {
    var local = Data(), central = Data()
    func join(_ parts: [Data]) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    for entry in entries {
        let name = Data(entry.name.utf8), content = entry.data, checksum = crc(content), offset = UInt32(local.count)
        local += join([little(0x04034b50), little(20, 2), little(0, 2), little(0, 2), little(0, 2), little(0, 2), little(checksum), little(UInt32(content.count)), little(UInt32(content.count)), little(UInt32(name.count), 2), little(0, 2), name, content])
        central += join([little(0x02014b50), little(0x0314, 2), little(20, 2), little(0, 2), little(0, 2), little(0, 2), little(0, 2), little(checksum), little(UInt32(content.count)), little(UInt32(content.count)), little(UInt32(name.count), 2), little(0, 2), little(0, 2), little(0, 2), little(0, 2), little((entry.kind | UInt32(entry.mode)) << 16), little(offset), name])
    }
    let end = join([little(0x06054b50), little(0, 2), little(0, 2), little(UInt32(entries.count), 2), little(UInt32(entries.count), 2), little(UInt32(central.count)), little(UInt32(local.count)), little(0, 2)])
    try (local + central + end).write(to: url)
}
func fixtureTar(_ entries: [FixtureEntry], _ url: URL) throws {
    var data = Data()
    for entry in entries {
        var header = [UInt8](repeating: 0, count: 512)
        func field(_ value: String, _ offset: Int, _ length: Int) { for (index, byte) in value.utf8.prefix(length).enumerated() { header[offset + index] = byte } }
        field(entry.name, 0, 100); field(String(format: "%07o", entry.mode), 100, 8); field("0000000", 108, 8); field("0000000", 116, 8)
        let content = entry.kind == UInt32(S_IFLNK) ? Data() : entry.data
        field(String(format: "%011o", content.count), 124, 12); field("00000000000", 136, 12)
        for index in 148..<156 { header[index] = 32 }
        header[156] = entry.kind == UInt32(S_IFLNK) ? 50 : 48
        if entry.kind == UInt32(S_IFLNK) { field(String(decoding: entry.data, as: UTF8.self), 157, 100) }
        field("ustar", 257, 6); field("00", 263, 2)
        field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148, 8)
        data += Data(header); data += content
        data += Data(repeating: 0, count: (512 - content.count % 512) % 512)
    }
    data += Data(repeating: 0, count: 1024); try data.write(to: url)
}
func packagingTests() throws {
    let temporary = fm.temporaryDirectory.appendingPathComponent("sumra-package-test-" + UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false); defer { try? fm.removeItem(at: temporary) }
    let entries = [FixtureEntry(name: "run.sh", data: Data("#!/bin/sh\nexit 0\n".utf8), mode: 0o755), FixtureEntry(name: "file.txt", data: Data("expected".utf8)), FixtureEntry(name: "alias", kind: UInt32(S_IFLNK), data: Data("file.txt".utf8), mode: 0o777)]
    let files = Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == UInt32(S_IFREG) }.map { ($0.name, ["sha256": digest($0.data), "mode": $0.mode, "bytes": $0.data.count] as [String: Any]) })
    let links = ["alias": "file.txt"]
    let inventory: [String: Any] = ["app_files": files.mapValues { $0["sha256"] as! String }, "app_modes": files.mapValues { $0["mode"] as! Int }, "app_symlinks": links, "app_directories": ["": 0o755]]
    func verify(_ values: [FixtureEntry], _ format: String, directories: [FixtureEntry]? = nil) throws {
        let path = temporary.appendingPathComponent("fixture." + format)
        if format == "tar" {
            try fixtureTar(values.map { var e = $0; e.name = "Sumra-source/" + e.name; return e }, path)
            let compressed = try run(["gzip", "-c", path.path]).0; try compressed.write(to: path)
            try verifySourceArchive(path, files, links)
        }
        else {
            let directory = FixtureEntry(name: "Sumra.app/", kind: UInt32(S_IFDIR), data: Data(), mode: 0o755)
            try fixtureZip((directories ?? [directory]) + values.map { var e = $0; e.name = "Sumra.app/" + e.name; return e }, path)
            try verifyAppArchive(path, "Sumra.app", inventory)
        }
    }
    for format in ["tar", "zip"] {
        try verify(entries, format); checks += 1
        for name in ["file.txt", "alias"] { try rejected("missing \(name) \(format)") { try verify(entries.filter { $0.name != name }, format) } }
        for extra in [FixtureEntry(name: "extra", data: Data("unexpected".utf8)), entries[0]] { try rejected("extra/duplicate \(format)") { try verify(entries + [extra], format) } }
        for name in ["file.txt", "alias"] {
            var changed = entries; let index = changed.firstIndex { $0.name == name }!
            changed[index].kind = name == "alias" ? UInt32(S_IFREG) : UInt32(S_IFLNK)
            try rejected("type substitution \(format)") { try verify(changed, format) }
            changed = entries; changed[index].data = Data("changed".utf8)
            try rejected("changed bytes/link \(format)") { try verify(changed, format) }
        }
        var changed = entries; changed[0].mode = 0o644
        try rejected("lost executable bit \(format)") { try verify(changed, format) }
    }
    let directory = FixtureEntry(name: "Sumra.app/", kind: UInt32(S_IFDIR), data: Data(), mode: 0o755)
    for name in ["outside/", "Sumra.app/", "Sumra.app/run.sh/"] {
        try rejected("extra/duplicate directory") { try verify(entries, "zip", directories: [directory, FixtureEntry(name: name, kind: UInt32(S_IFDIR), data: Data(), mode: 0o755)]) }
    }
    try rejected("missing directory") { try verify(entries, "zip", directories: []) }
    for (kind, mode) in [(UInt32(S_IFLNK), 0o755), (UInt32(S_IFDIR), 0o700)] {
        try rejected("mistyped/changed directory") { try verify(entries, "zip", directories: [FixtureEntry(name: "Sumra.app/", kind: kind, data: Data("run.sh".utf8), mode: mode)]) }
    }
    let app = temporary.appendingPathComponent("Sumra.app"), executable = app.appendingPathComponent("Contents/MacOS/Sumra")
    try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try entries[0].data.write(to: executable); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try fm.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Current").path, withDestinationPath: "MacOS")
    let snapshot = try appInventory(app), archive = temporary.appendingPathComponent("ditto.zip")
    try archiveApp(app, archive); try verifyAppArchive(archive, app.lastPathComponent, snapshot); checks += 1
    _ = try run(["xattr", "-w", "com.sumra.packaging-test", "benign", executable.path])
    let metadataArchive = temporary.appendingPathComponent("metadata-free.zip")
    try archiveApp(app, metadataArchive); try verifyAppArchive(metadataArchive, app.lastPathComponent, snapshot)
    try expect(equal(try appInventory(app), snapshot), "archive preserves app inventory")
    try expect(try text(["xattr", "-p", "com.sumra.packaging-test", executable.path]) == "benign", "archive preserves original xattrs")
    _ = try run(["xattr", "-w", "-x", "com.apple.ResourceFork", "7265736f75726365", executable.path])
    let lossy = temporary.appendingPathComponent("lossy.zip")
    try rejected("resource fork") { try archiveApp(app, lossy) }
    try expect(!fm.fileExists(atPath: lossy.path), "fork rejection creates no archive")
    try expect(try Data(contentsOf: executable) == entries[0].data, "fork rejection preserves product bytes")
    try expect(try text(["xattr", "-p", "-x", "com.apple.ResourceFork", executable.path]).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") == "7265736F75726365", "fork rejection preserves resource bytes")
    _ = try run(["xattr", "-d", "com.apple.ResourceFork", executable.path])
    let sourceFile = temporary.appendingPathComponent("run.sh"); try entries[0].data.write(to: sourceFile); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourceFile.path)
    let inputs = ["run.sh": SourceInput(path: sourceFile), "file.txt": SourceInput(data: Data("expected".utf8))]
    var provenance: [String: Any] = ["files": files, "symlinks": links, "origins": [], "app_metadata": ["info_plist": ["CFBundleShortVersionString": "0.2.0"]]]
    provenance.merge(snapshot) { _, new in new }
    let output = temporary.appendingPathComponent("candidate")
    try packageArtifacts(app, output, inputs, links, provenance)
    try verifySourceArchive(output.appendingPathComponent("Sumra-corresponding-source.tar.gz"), files, links)
    try verifyAppArchive(output.appendingPathComponent("Sumra-0.2.0-macOS-arm64.zip"), app.lastPathComponent, snapshot); checks += 1
    for line in try String(contentsOf: output.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n") {
        let parts = line.components(separatedBy: "  "); try expect(try digest(output.appendingPathComponent(parts[1])) == parts[0], "artifact SHA256 matches")
    }
    try rejected("existing output") { try packageArtifacts(app, output, inputs, links, provenance) }
    let reuse = temporary.appendingPathComponent("reuse")
    try packageArtifacts(app, reuse, inputs, links, provenance, appArchive: archive)
    try expect(try digest(reuse.appendingPathComponent("Sumra-0.2.0-macOS-arm64.zip")) == digest(archive), "reuse preserves archive bytes")
    let sourcePath = temporary.appendingPathComponent("source.json"), buildPath = temporary.appendingPathComponent("build.json")
    var source: [String: Any] = ["status": "nonnotarized-local-candidate", "redistribution_audit": "pending", "source_build_match": "not_attested", "origins": [["path": "project", "revision": "abc123"]], "project_revision": "abc123", "files": files, "symlinks": links]
    try writeJSON(source, to: sourcePath)
    let metadata: [String: Any] = ["identifier": "fixture.app"]
    var build: [String: Any] = ["build_exit": 0, "source_inputs_sha256": try digest(sourcePath), "final_source_inputs_sha256": try digest(sourcePath), "bundle": snapshot, "metadata": metadata]
    try writeJSON(build, to: buildPath)
    let result = try validateFrozenReceipts(sourcePath, buildPath, source, snapshot, metadata)
    try expect(result["source_build_match"] as? String == "matches_frozen_build_receipt", "matching frozen receipts")
    try expect(result["source_receipt_sha256"] as? String == digest(sourcePath), "source receipt digest")
    try expect(result["build_receipt_sha256"] as? String == digest(buildPath), "build receipt digest")
    try expect((result["claim_limit"] as! String).contains("not reproducibility"), "receipt claim scope")
    source.removeValue(forKey: "status"); source.removeValue(forKey: "redistribution_audit"); try writeJSON(source, to: sourcePath)
    build["source_inputs_sha256"] = try digest(sourcePath); build["final_source_inputs_sha256"] = try digest(sourcePath); try writeJSON(build, to: buildPath)
    _ = try validateFrozenReceipts(sourcePath, buildPath, source, snapshot, metadata); checks += 1
    var changedSource = source; changedSource["files"] = ["run.sh": ["sha256": String(repeating: "0", count: 64)]]
    try rejected("changed source receipt") { _ = try validateFrozenReceipts(sourcePath, buildPath, changedSource, snapshot, metadata) }
    try Data("changed".utf8).write(to: executable)
    try rejected("changed app bytes") { _ = try validateFrozenReceipts(sourcePath, buildPath, source, try appInventory(app), metadata) }
    try entries[0].data.write(to: executable)
    try fm.removeItem(at: app.appendingPathComponent("Contents/Current")); try fm.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Current").path, withDestinationPath: "Missing")
    try rejected("changed app link") { _ = try validateFrozenReceipts(sourcePath, buildPath, source, try appInventory(app), metadata) }
    build["source_inputs_sha256"] = "wrong"; try writeJSON(build, to: buildPath)
    try rejected("unbound receipt") { _ = try validateFrozenReceipts(sourcePath, buildPath, source, snapshot, metadata) }
    build["source_inputs_sha256"] = try digest(sourcePath); build["build_exit"] = 1; try writeJSON(build, to: buildPath)
    try rejected("failed build receipt") { _ = try validateFrozenReceipts(sourcePath, buildPath, source, snapshot, metadata) }
    build["build_exit"] = 0; try writeJSON(build, to: buildPath)
    try rejected("changed metadata receipt") { _ = try validateFrozenReceipts(sourcePath, buildPath, source, snapshot, ["identifier": "changed"]) }
    print("Packaging behavior checks passed: \(checks)")
}
do { try packagingTests() } catch { fputs("\(error)\n", stderr); exit(1) }
