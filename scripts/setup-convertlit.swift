#!/usr/bin/env swift
import Foundation
struct SetupError: Error, CustomStringConvertible { let description: String }
func main() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let tables = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let des = root.appendingPathComponent("lib/des/des.c")
    var text = try String(contentsOf: des, encoding: .utf8)
    let oldInclude = "#include \"spr.h\"", newInclude = "#include \"sumra-des-spr.h\""
    func count(_ needle: String) -> Int { text.components(separatedBy: needle).count - 1 }
    if text.contains(oldInclude) {
        guard count(oldInclude) == 1 else { throw SetupError(description: "Unexpected ConvertLIT DES table includes") }
        text = text.replacingOccurrences(of: oldInclude, with: newInclude)
        try text.write(to: des, atomically: false, encoding: .utf8)
    } else if count(newInclude) != 1 { throw SetupError(description: "Cannot identify the ConvertLIT DES table owner") }
    let table = root.appendingPathComponent("lib/des/sumra-des-spr.h")
    if try !fm.fileExists(atPath: table.path) || Data(contentsOf: table) != tables {
        try tables.write(to: table)
        // The original implicit make rule does not track included headers.
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: des.path)
    }
    for (name, header) in ["clit18/display.c": "string.h", "clit18/explode.c": "sys/stat.h",
        "clit18/hexdump.c": "string.h", "clit18/manifest.c": "string.h",
        "clit18/drm5.c": "ctype.h", "clit18/transmute.c": "string.h",
        "lib/newlzx/lzxglue.c": "string.h", "lib/litsections.c": "lzx/lzx.h"] {
        let path = root.appendingPathComponent(name)
        var source = try String(contentsOf: path, encoding: .utf8)
        let directive = "#include \"\(header)\""
        if !source.contains(directive), let range = source.range(of: "#include ") {
            source.replaceSubrange(range, with: directive + "\n#include ")
            try source.write(to: path, atomically: false, encoding: .utf8)
        }
    }
}
do { try main() } catch { FileHandle.standardError.write(Data("ConvertLIT setup: \(error)\n".utf8)); exit(1) }
