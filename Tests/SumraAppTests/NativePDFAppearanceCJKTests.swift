#if os(macOS)
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFAppearanceCJKTests: XCTestCase {
    func testAuthoredLanguageCMapCoverageAndSavedAppearances() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let native = root.appendingPathComponent("build/engines")
        let core = root.appendingPathComponent("build/mupdf/libmupdf.a")
        let third = root.appendingPathComponent("build/mupdf/libmupdf-third.a")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let crypto = root.appendingPathComponent("build/native-macos13/openssl-3.5.9-\(architecture)/libcrypto.a")
        let objects = ["MuPDF", "Markdown", "PDFTools", "PDFInfo", "PDFColors", "SyncTeXParser", "SyncTeXUtils", "SyncTeX"]
            .map { native.appendingPathComponent($0 + ".o") }
        guard (objects + [core, third, crypto]).allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Build native engine objects and archives before PDF appearance integration tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let object = directory.url.appendingPathComponent("pdf-appearance-cjk.o")
        let executable = directory.url.appendingPathComponent("pdf-appearance-cjk")
        let commands = [
            ["clang", "-std=c11", "-O1", "-mmacosx-version-min=13.0",
             "-I" + root.appendingPathComponent("build/deps/mupdf/include").path,
             "-c", root.appendingPathComponent("Tests/Native/PDFAppearanceCJK.c").path, "-o", object.path],
            ["clang++", "-mmacosx-version-min=13.0", "-Wl,-dead_strip", object.path] + objects.map(\.path) +
                [core.path, third.path, crypto.path, "-lm", "-lpthread", "-lz",
                 "-framework", "Security", "-framework", "CoreFoundation", "-framework", "CoreText", "-o", executable.path]
        ]
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            try runSumraProcess(process)
            XCTAssertEqual(process.terminationStatus, 0)
            guard process.terminationStatus == 0 else { return }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [directory.url.path]
        try runSumraProcess(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0,
                       "CJK appearance text, existing language encodings, embedded fallback and saved rasters must remain faithful")
    }
}
#endif
