#if os(macOS)
import Foundation
import XCTest
@testable import Sumra

final class HTMLDrawIndexTests: XCTestCase {
    func testPaginatedHTMLDrawingMatchesConservativeTraversalAfterReflow() throws {
        try runNativeFixture("HTMLDrawIndex")
    }

    func testHTMLOutlineTargetsMatchSingleLinkResolverAfterReflow() throws {
        try runNativeFixture("HTMLOutlineTargets")
    }

    func testPoolAllocationsPreserveDataAndCleanupAcrossGrowthAndFailures() throws {
        try runNativeFixture("PoolBehavior")
    }

    func testShapingWordSplitsPreserveMetadataWithinAllocationBounds() throws {
        try runNativeFixture("HTMLFlowMetadata")
    }

    private func runNativeFixture(_ name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let include = root.appendingPathComponent("build/deps/mupdf/include")
        let archive = root.appendingPathComponent("build/mupdf/libmupdf.a")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("Build MuPDF before its native regressions")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let executable = directory.url.appendingPathComponent(name)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-Os", "-mmacosx-version-min=13.0", "-I" + include.path,
            "-I" + root.appendingPathComponent("build/deps/mupdf/source/html").path,
            root.appendingPathComponent("Tests/Native/\(name).c").path,
            archive.path, root.appendingPathComponent("build/mupdf/libmupdf-third.a").path,
            "-lm", "-lpthread", "-lz", "-framework", "CoreFoundation", "-framework", "CoreText",
            "-o", executable.path]
        try runSumraProcess(compiler)
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }
        let process = Process()
        process.executableURL = executable
        try runSumraProcess(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
#endif
