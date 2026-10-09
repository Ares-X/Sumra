import Foundation
import XCTest
@testable import SumraCore

final class BoundarySimplificationTests: XCTestCase {
    private func archiveFixture() throws -> (Archive, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("book.cbt")
        try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAC/+3Xv07EIADHcR7FF5A/bYX54nxxcHFrsJAeSUMbSn1+2yYm2kW9C9zA77NAWFj4BqCUjUucnbF08j1Jgq9k0+zj6jhyXn2bb+uC13VFHjjJYJmjDuv2pEw6dBf3YR+DHXRcJwSKwvT7PA5LTJj/Vf03HP3n7P/rGKCIshgXGKXM+YRPgF/7F/LYvxIN+s/Zv7dztAY9lIayYez0kPD2/0v/Tz/750oqif5z9r+fAuRQXv8XZ4z19+2fq2P/Sgr0n4Pr/Rhw8Rerbc+n55fXN0bbSfdpfgD/7l9sHwD0j/4BAAAAAAAAAOBWn5vvloEAKAAA"))!.write(to: url)
        return (try Archive(url), root)
    }

    func testArchiveNamesReadOnlyStoredBytes() throws {
        let (archive, root) = try archiveFixture()
        let outside = root.appendingPathComponent("outside.png")
        try Data("filesystem-sentinel".utf8).write(to: outside)
        for (name, expected) in [("../outside.png", "archive-relative"), ("/absolute.png", "archive-absolute"),
                                 ("dir/../inside.png", "archive-nested"), ("./local.png", "archive-local")] {
            XCTAssertEqual(try archive.data(name), Data(expected.utf8))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("filesystem-sentinel".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["book.cbt", "outside.png"])
    }

    func testMissingArchiveNameNeverFallsBackToDisk() throws {
        let (archive, root) = try archiveFixture()
        let secret = root.appendingPathComponent("not-in-archive.png")
        try Data("must-not-be-returned".utf8).write(to: secret)
        XCTAssertThrowsError(try archive.data(secret.path))
        XCTAssertThrowsError(try archive.data("not-in-archive.png"))
        XCTAssertThrowsError(try archive.data("../not-in-archive.png"))
    }

    func testUnusualNamesAreListedButHiddenMetadataIsNot() throws {
        let (archive, _) = try archiveFixture()
        XCTAssertEqual(Set(archive.images), ["../outside.png", "/absolute.png", "dir/../inside.png", "./local.png"])
    }

    private func word(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private func replica(tables: Int) -> Data {
        let pdf = Data("%PDF-1.4\nfixture\n%%EOF".utf8)
        var data = Data("%MOP".utf8) + word(UInt32(tables))
        for _ in 0..<tables { data.append(word(1)) }
        for i in 0..<tables {
            data.append(word(UInt32(8 + 12 * tables + i * pdf.count)))
            data.append(word(UInt32(pdf.count)))
        }
        for _ in 0..<tables { data.append(pdf) }
        return data
    }
    func testPrintReplicaAllowsMoreThan32RealTables() throws {
        XCTAssertEqual(try LegacyText.printReplica(replica(tables: 64)), Data("%PDF-1.4\nfixture\n%%EOF".utf8))
    }
    func testPrintReplicaRejectsTableCountBeyondPayload() {
        for count: UInt32 in [0, 33, .max] {
            XCTAssertThrowsError(try LegacyText.printReplica(Data("%MOP".utf8) + word(count) + Data(repeating: 0, count: 12)))
        }
    }
    func testPrintReplicaRejectsOutOfBoundsSection() {
        var data = replica(tables: 1)
        data.replaceSubrange(12..<16, with: word(.max))
        XCTAssertThrowsError(try LegacyText.printReplica(data))
        data = replica(tables: 1)
        data.replaceSubrange(16..<20, with: word(.max))
        XCTAssertThrowsError(try LegacyText.printReplica(data))
    }
    func testPrintReplicaStillRequiresPDFData() {
        var data = replica(tables: 1)
        data[20] = 0
        XCTAssertThrowsError(try LegacyText.printReplica(data))
    }
    func testMalformedLegacyStreamsRemainErrors() {
        XCTAssertThrowsError(try LegacyText.tcr(Data("!!8-Bit!!".utf8)))
        XCTAssertThrowsError(try LegacyText.unpackPalm([128, 0]))
        XCTAssertThrowsError(try LegacyText.palm(Data(repeating: 0, count: 77)))
    }
}
