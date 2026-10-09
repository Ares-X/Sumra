import Foundation
import XCTest
@testable import SumraCore

final class ArchivePasswordTests: XCTestCase {
    func testEncryptedArchiveRequiresCorrectPasswordAndRewindKeepsIt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { throw XCTSkip("zip fixture generator unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first".utf8).write(to: root.appendingPathComponent("1.png"))
        try Data("second".utf8).write(to: root.appendingPathComponent("2.png"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-P", "fixture-password", "comic.cbz", "1.png", "2.png"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let url = root.appendingPathComponent("comic.cbz")
        XCTAssertThrowsError(try Archive(url)) { XCTAssertTrue($0 is PasswordRequired) }
        let archive = try Archive(url, password: "fixture-password")
        XCTAssertEqual(try archive.data("1.png"), Data("first".utf8))
        XCTAssertEqual(try archive.data("2.png"), Data("second".utf8))
        XCTAssertEqual(try archive.data("1.png"), Data("first".utf8))
        XCTAssertThrowsError(try Archive(url, password: "wrong").data("1.png"))
    }

    func testImageMagicChoosesNativeDecoderForMislabeledFile() {
        XCTAssertEqual(Format.imageEngine("wrong.png", prefix: Data([0xff,0x0a])), "JPEGXL")
        XCTAssertEqual(Format.resolve("picture.jxr", prefix: Data([0x49,0x49,0xbc,1])), .mupdf)
        XCTAssertTrue(Format.isComicImage("p.svg"))
        XCTAssertFalse(Format.isComicImage("notes.txt"))
    }
}
