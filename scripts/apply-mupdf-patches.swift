#!/usr/bin/env swift
// Probe only patch-touched files in a temporary tree; never reverse the source.
import Foundation
import CryptoKit

let baseSHA256 = "f6c97f39b585e9165aa4c52b69fcb8f366248428e7f27c166fae7bc41a4e09cf"
let fm = FileManager.default
struct SetupError: Error, CustomStringConvertible { let description: String }
func digest(_ source: URL, _ paths: [String]) throws -> String {
    var hash = SHA256()
    for path in paths {
        hash.update(data: Data((path + "\0").utf8))
        let file = source.appendingPathComponent(path)
        if fm.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            var length = UInt64(data.count).bigEndian
            hash.update(data: withUnsafeBytes(of: &length) { Data($0) })
            hash.update(data: data)
        } else { hash.update(data: Data([0xff])) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func apply(_ source: URL, _ patch: URL, reverse: Bool = false) throws -> String? {
    let process = Process(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", source.path, "apply"] + (reverse ? ["--reverse"] : []) + [patch.path]
    process.standardError = errors
    try process.run()
    let output = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? nil : "\(patch.lastPathComponent): \(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))"
}
func probe(_ source: URL, _ paths: [String], _ patches: [URL], reverse: Bool) throws -> String? {
    let temporary = fm.temporaryDirectory.appendingPathComponent("sumra-mupdf-patches-\(UUID().uuidString)")
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    for path in paths {
        let original = source.appendingPathComponent(path)
        if fm.fileExists(atPath: original.path) {
            let target = temporary.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: original, to: target)
        }
    }
    for patch in reverse ? Array(patches.reversed()) : patches {
        if let error = try apply(temporary, patch, reverse: reverse) { return error }
    }
    if reverse, try digest(temporary, paths) != baseSHA256 { return "reversed source differs from the pinned base" }
    return nil
}
func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 3 else { throw SetupError(description: "Expected MuPDF source and ordered patch paths") }
    let source = URL(fileURLWithPath: args[0])
    let patches = args.dropFirst().map { URL(fileURLWithPath: $0) }
    var touched = Set<String>()
    for patch in patches {
        for line in try String(contentsOf: patch, encoding: .utf8).components(separatedBy: .newlines) {
            if line.hasPrefix("--- a/") || line.hasPrefix("+++ b/") { touched.insert(String(line.dropFirst(6))) }
        }
    }
    let paths = touched.sorted()
    var needed = patches
    if try digest(source, paths) == baseSHA256 {
        if let error = try probe(source, paths, patches, reverse: false) { throw SetupError(description: "Pinned base cannot take the patch sequence: \(error)") }
    } else {
        let completeError = try probe(source, paths, patches, reverse: true)
        if completeError == nil { return }
        var known = false
        for count in stride(from: patches.count - 1, through: 1, by: -1) {
            if try probe(source, paths, Array(patches.prefix(count)), reverse: true) == nil {
                needed = Array(patches.dropFirst(count)); known = true; break
            }
        }
        guard known else { throw SetupError(description: "MuPDF tree is neither the clean pinned source nor a known patched source; preserving its files. \(completeError!)") }
        if let error = try probe(source, paths, needed, reverse: false) { throw SetupError(description: "Pinned patched source cannot take the patch suffix: \(error)") }
    }
    for patch in needed { if let error = try apply(source, patch) { throw SetupError(description: error) } }
}
do { try main() } catch {
    FileHandle.standardError.write(Data("MuPDF patch setup: \(error)\n".utf8)); exit(1)
}
