#if os(macOS)
import Foundation
import SumraCore
import XCTest
@testable import Sumra

final class NativePDFDestinationTests: XCTestCase {
    func testXYZNullAxesSurviveDirectAndNamedLinksAtEveryPageRotation() throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let inputs: [(x: Double?, y: Double?, zoom: Double?)] = [
            (70, 250, 1.25), (nil, 250, 1.25), (70, nil, 1.25), (nil, nil, 1.25),
            (70, 250, nil), (nil, 250, nil), (70, nil, nil), (nil, nil, nil)
        ]
        // PDF point (70,250), CropBox [10,20,210,320], in Fitz's rotated
        // top-left coordinate system. Keep these expected positions explicit.
        let points: [(rotation: Int, x: Double, y: Double)] = [(0, 60, 70), (90, 230, 60), (180, 140, 230), (270, 70, 140)]
        for point in points {
            for named in [false, true] {
                let source = directory.url.appendingPathComponent("xyz-\(point.rotation)-\(named).pdf")
                let data = fixture(rotation: point.rotation,
                    destinations: inputs.map { "/XYZ \(number($0.x)) \(number($0.y)) \(number($0.zoom))" }, named: named)
                try data.write(to: source)
                let file = try NativeFile(source, engine: .mupdf), before = try XCTUnwrap(file.pdfInfo())
                let outline = try file.outline()
                XCTAssertEqual(outline.count, inputs.count)
                for (entry, input) in zip(outline, inputs) {
                    let navigation = try XCTUnwrap(file.pdfResolveDestination(entry.target))
                    let quarterTurn = point.rotation == 90 || point.rotation == 270
                    XCTAssertEqual(navigation.page, 0); XCTAssertEqual(navigation.type, 7)
                    XCTAssertEqual(navigation.x, (quarterTurn ? input.y : input.x) == nil ? nil : point.x,
                                   "\(point.rotation) degrees: \(entry.target)")
                    XCTAssertEqual(navigation.y, (quarterTurn ? input.x : input.y) == nil ? nil : point.y,
                                   "\(point.rotation) degrees: \(entry.target)")
                    XCTAssertEqual(navigation.zoom, input.zoom.map { $0 * 100 })
                    let exported = try XCTUnwrap(file.pdfResolveDestination(entry.target, pdfCoordinates: true))
                    XCTAssertEqual(exported.page, 0); XCTAssertEqual(exported.type, 7)
                    XCTAssertEqual(exported.x, input.x); XCTAssertEqual(exported.y, input.y); XCTAssertEqual(exported.zoom, input.zoom)
                }
                let after = try XCTUnwrap(file.pdfInfo())
                XCTAssertEqual(after.undoPosition, before.undoPosition); XCTAssertEqual(after.dirty, before.dirty)
                XCTAssertEqual(try Data(contentsOf: source), data)
            }
        }
        withExtendedLifetime(directory) {}
    }

    func testFitAxesRotateAndReturnToTheirOriginalPDFTypeAndCoordinate() throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let modes: [(name: String, type: Int, rotatedType: Int, horizontal: Bool)] = [
            ("FitH", 2, 4, true), ("FitBH", 3, 5, true), ("FitV", 4, 2, false), ("FitBV", 5, 3, false)
        ]
        let points: [(rotation: Int, x: Double, y: Double)] = [(0, 60, 70), (90, 230, 60), (180, 140, 230), (270, 70, 140)]
        for point in points {
            for named in [false, true] {
                for specified in [false, true] {
                    let source = directory.url.appendingPathComponent("fit-\(point.rotation)-\(named)-\(specified).pdf")
                    try fixture(rotation: point.rotation, destinations: modes.map {
                        "/\($0.name) \(specified ? ($0.horizontal ? "250" : "70") : "null")"
                    }, named: named).write(to: source)
                    let file = try NativeFile(source, engine: .mupdf), outline = try file.outline()
                    XCTAssertEqual(outline.count, modes.count)
                    for (entry, mode) in zip(outline, modes) {
                        let navigation = try XCTUnwrap(file.pdfResolveDestination(entry.target))
                        let quarterTurn = point.rotation == 90 || point.rotation == 270
                        let horizontal = quarterTurn ? !mode.horizontal : mode.horizontal
                        XCTAssertEqual(navigation.type, quarterTurn ? mode.rotatedType : mode.type)
                        XCTAssertEqual(navigation.x, !horizontal && specified ? point.x : nil)
                        XCTAssertEqual(navigation.y, horizontal && specified ? point.y : nil)
                        XCTAssertNil(navigation.zoom)
                        let exported = try XCTUnwrap(file.pdfResolveDestination(entry.target, pdfCoordinates: true))
                        XCTAssertEqual(exported.type, mode.type)
                        XCTAssertEqual(exported.x, !mode.horizontal && specified ? 70 : nil)
                        XCTAssertEqual(exported.y, mode.horizontal && specified ? 250 : nil)
                        XCTAssertNil(exported.zoom)
                    }
                    XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
                }
            }
        }
        withExtendedLifetime(directory) {}
    }

    func testRemoteDestinationsKeepTheirOwnCoordinatesRegardlessOfLocalPageRotation() throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        let destinations = ["/XYZ null 250 1.25", "/XYZ 70 null 1.25", "/XYZ null null null",
                            "/FitH 250", "/FitBH null", "/FitV 70", "/FitBV null"]
        let expected: [(type: Int, x: Double?, y: Double?, zoom: Double?)] = [
            (7, nil, 250, 1.25), (7, 70, nil, 1.25), (7, nil, nil, nil),
            (2, nil, 250, nil), (3, nil, nil, nil), (4, 70, nil, nil), (5, nil, nil, nil)
        ]
        for rotation in [0, 90, 180, 270] {
            let source = directory.url.appendingPathComponent("remote-\(rotation).pdf")
            try fixture(rotation: rotation, destinations: destinations, remote: true).write(to: source)
            let file = try NativeFile(source, engine: .mupdf), outline = try file.outline()
            XCTAssertEqual(outline.count, expected.count)
            for (entry, value) in zip(outline, expected) {
                XCTAssertTrue(entry.target.hasPrefix("file:"))
                XCTAssertNil(entry.page)
                XCTAssertNil(try file.pdfResolveDestination(entry.target), "Navigation leaves remote documents to the GUI opener")
                let exported = try XCTUnwrap(file.pdfResolveDestination(entry.target, pdfCoordinates: true))
                XCTAssertEqual(exported.page, 2); XCTAssertEqual(exported.type, value.type)
                XCTAssertEqual(exported.x, value.x); XCTAssertEqual(exported.y, value.y); XCTAssertEqual(exported.zoom, value.zoom)
            }
            XCTAssertNil(try file.pdfResolveDestination("file:other.pdf#nameddest=target0", pdfCoordinates: true))
            XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
        }
        withExtendedLifetime(directory) {}
    }

    func testFitPageAndFitContentRemainDistinctThroughURIAndRawDestinationExport() throws {
        try requireMuPDF()
        let directory = try TemporaryDirectory()
        for rotation in [0, 90, 180, 270] {
            for mode in ["direct", "named", "remote"] {
                let source = directory.url.appendingPathComponent("fit-page-content-\(rotation)-\(mode).pdf")
                try fixture(rotation: rotation, destinations: ["/Fit", "/FitB"],
                    named: mode == "named", remote: mode == "remote").write(to: source)
                let file = try NativeFile(source, engine: .mupdf), outline = try file.outline()
                XCTAssertEqual(outline.count, 2)
                for (expectedType, entry) in outline.enumerated() {
                    if mode == "remote" { XCTAssertNil(try file.pdfResolveDestination(entry.target)) }
                    else { XCTAssertEqual(try file.pdfResolveDestination(entry.target)?.type, expectedType) }
                    let exported = try XCTUnwrap(file.pdfResolveDestination(entry.target, pdfCoordinates: true))
                    XCTAssertEqual(exported.type, expectedType)
                    XCTAssertEqual(exported.page, mode == "remote" ? 2 : 0)
                    XCTAssertNil(exported.x); XCTAssertNil(exported.y); XCTAssertNil(exported.zoom)
                }
                XCTAssertFalse(try XCTUnwrap(file.pdfInfo()).dirty)
            }
        }
        withExtendedLifetime(directory) {}
    }

    private func number(_ value: Double?) -> String { value.map { String($0) } ?? "null" }

    private func fixture(rotation: Int, destinations: [String], named: Bool = false, remote: Bool = false) -> Data {
        let names = named ? "/Names << /Dests << /Names [" + destinations.enumerated().map {
            "(target\($0.offset)) [3 0 R \($0.element)]"
        }.joined(separator: " ") + "] >> >>" : ""
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R \(names) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 360] /CropBox [10 20 210 320] /Rotate \(rotation) /Resources << >> >>",
            "<< /Type /Outlines /First 5 0 R /Last \(destinations.count + 4) 0 R /Count \(destinations.count) >>"
        ]
        for (index, destination) in destinations.enumerated() {
            let action = remote ? "/A << /S /GoToR /F (other.pdf) /D [2 \(destination)] >>"
                : named ? "/Dest (target\(index))" : "/Dest [3 0 R \(destination)]"
            let previous = index > 0 ? "/Prev \(index + 4) 0 R" : ""
            let next = index + 1 < destinations.count ? "/Next \(index + 6) 0 R" : ""
            objects.append("<< /Title (Target \(index)) /Parent 4 0 R \(previous) \(next) \(action) >>")
        }
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }

    private func requireMuPDF() throws {
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("MuPDF engine is required") }
    }
}
#endif
