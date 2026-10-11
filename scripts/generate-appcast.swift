#!/usr/bin/env swift
// Generate release metadata with the pinned Sparkle tool and personal Keychain.
import Foundation
let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
struct AppcastError: Error, CustomStringConvertible { let description: String }
func run(_ executable: URL, _ args: [String], capture: Bool = false) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = executable; process.arguments = args
    if capture { process.standardOutput = output }
    try process.run()
    let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AppcastError(description: "\(executable.lastPathComponent) exited \(process.terminationStatus)") }
    return data
}
func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { throw AppcastError(description: "Usage: generate-appcast.swift archive [--output path] [--channel name]") }
    let archive = URL(fileURLWithPath: args.removeFirst()).standardizedFileURL
    var output = root.appendingPathComponent("appcast.xml"), channel: String?
    while !args.isEmpty {
        let option = args.removeFirst()
        guard !args.isEmpty else { throw AppcastError(description: "Missing value for \(option)") }
        let value = args.removeFirst()
        switch option {
        case "--output": output = URL(fileURLWithPath: value)
        case "--channel": channel = value
        default: throw AppcastError(description: "Unknown option: \(option)")
        }
    }
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Assets/Updates.json"))) as! [String: Any]
    let plist = try run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", archive.path, "Sumra.app/Contents/Info.plist"], capture: true)
    let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
    let version = info["CFBundleShortVersionString"] as! String
    let stage = archive.deletingLastPathComponent().appendingPathComponent("Sumra-appcast-\(UUID().uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: stage) }
    try fm.linkItem(at: archive, to: stage.appendingPathComponent(archive.lastPathComponent))
    let feed = stage.appendingPathComponent("appcast.xml"), existing = root.appendingPathComponent("appcast.xml")
    if fm.fileExists(atPath: existing.path) { try fm.copyItem(at: existing, to: feed) }
    var command = ["--account", config["keychain_account"] as! String, "--maximum-deltas", "0",
        "--download-url-prefix", "https://github.com/Ares-X/Sumra/releases/download/v\(version)/",
        "--link", "https://github.com/Ares-X/Sumra/releases", "-o", feed.path]
    if let channel { command += ["--channel", channel] }
    _ = try run(root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin/generate_appcast"), command + [stage.path])
    try Data(contentsOf: feed).write(to: output)
}
do { try main() } catch { FileHandle.standardError.write(Data("Appcast: \(error)\n".utf8)); exit(1) }
