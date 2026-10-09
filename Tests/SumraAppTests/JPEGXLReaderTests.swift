#if os(macOS)
import AppKit
import ImageIO
import XCTest
@testable import Sumra

final class JPEGXLReaderTests: XCTestCase {
    // Unmodified fixtures (base64 representation only) from the JPEG XL Project
    // testdata 73695d303670c90e4d506ea89d9901b081385089, jxl/blending/ and
    // jxl/pq_gradient.jxl. CC BY 4.0; supplied as-is, without warranties.
    // https://github.com/libjxl/testdata/tree/73695d303670c90e4d506ea89d9901b081385089
    // https://creativecommons.org/licenses/by/4.0/
    // Expected four composited PNG pages also exercise libjxl BlendingTest.Crops.
    private let animation = "/wp4AmIIArAmCJAAAAAPaTBLAACAAADMB0soMd2M9cFnMDuvEBAQOAICAkqygEgkQpnxZ/J3cfNd5FmmVeGO6IjYGGOMJGXhFsYYr7LhsL6A8AAAlAkAxo7sDCNY4ychjsBv9r6Ggj75aTdLv3jcDamgEA53I7CZzPYAesB4clKVBpp3XCQMxyk4gv74gcHHDsiEikXH5VSfhsUpAWyVVosYP2EDamKmng0vCZHULfDKGS/QFqSqDiCsM05EoUfY01UwwJRcpAxABC9/GI6B0Jv/ad5CeXAkZ+nInMHrzzbGysrJre/uj+fzMXrjX3cUOklccb7SgSCyauQ4t+hCQaLqFBSdHyq0LQrbo+AJlZlndSIqpL6F7uj7H0rkDWdgtw06WNL9FTd8No2QYgwm8hEP8MGOwYfzuxzq1hIPMP5PftgYUj8QuXYkq3ekrjqyzdWEFxQA3Yd1hlzsQyqZiH4tjLJAfHZQOPjMeK20/WQizwMpqD32CncQWHTlH/PETmRUVqsXPG0MTcmQ1eSo1jFBDCAaw9NHgZXEFWkbW6Q4BELD3mFwPDD3iNlyemYZKbbM/7SazisWNf0WV+H/7XzKs33j3x0QTThtnKHRMCzWJBUTmIlCMDmphVIbD/9nkv7hUFRk0tgO6dZTElXpzoHtOKo0m4OUUqtqHVuAgWYRi+VJ6N8dfZdkRbEIkJAARQYaIpFkAgD4AEsShQIFiHBuG2OwvLuACACOOs8KdUcCMRuvPX6qSctq8H7Pm0I5A1+5rf1L2GSEYmsZ/VI+0xXHy7N4AKgDCJCQYEEGVCLRLAEAAAIAXAFLEoUCBQA1yYkxTv4FZACIaJcScNgSeADk4gHgyJPR4PUaRUV+zcAqfp3+4nw7q2YP8XZQDHIMRPEccb3+00/dgCcgGxnw/5FaQAnDk5JpbgWj0zkOPl0IkJAARQY3IpFkAQAsAUsShQIFiHCWFGOwmvkLyADg+8ULaRMQ/qJSRZbLmABbNcsHLjCpT5UH7v0EywWHChcfNLsKmJsIjQhHaWadgROz3LxL4/AGKuJNBQ=="
    private let gradient = "/wr4gX6IgB+g6BGHAwAAAEAIBAEA1AAAAIAFYAACSzhpmMqD90tImAIFjhs3xt0Yg7GtvABEAIAzAQAAADRUL7z00gsvvfTSCy+99MJLL73w0gujRK8FwC6n+g+DbRD4wkeQGZQZ/FYGAxRaAKDYDexyqv8w2AaBL3wEmUGZwW9lAxgPBNAzCwA="
    private let expectedPNG = [
        "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"
    ]

    private func fixture(_ base64: String) throws -> URL {
        let engine = try NativeFile.libraryURL(for: .jpegXL)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build the JPEG XL engine before native integration tests") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-JPEGXL-" + UUID().uuidString + ".jxl")
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func rgba(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Data(bytes)
    }

    func testCompositedAnimationPagesMatchUpstreamPNGAfterRandomAccessAndSourceRemoval() throws {
        let url = try fixture(animation), file = try NativeFile(url, engine: .jpegXL)
        XCTAssertEqual(file.count, 4)
        // Reading keeps its original source bytes; later frames do not reopen it.
        try FileManager.default.removeItem(at: url)
        for index in [3, 0, 2, 1, 3] {
            let bytes = try XCTUnwrap(Data(base64Encoded: expectedPNG[index]))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(try file.bounds(index), CGRect(x: 0, y: 0, width: 50, height: 80))
            let actual = try file.image(index, width: 0)
            XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try rgba(actual), try rgba(expected), "Composited frame \(index)")
        }
    }

    func testNarrowRenderKeepsNonzeroHeightAndIncludesLastPartialPixel() throws {
        for data in [animation, gradient] {
            let file = try NativeFile(fixture(data), engine: .jpegXL)
            let bounds = try XCTUnwrap(file.bounds(0))
            let image = try file.image(0, width: 1)
            XCTAssertEqual(image.width, 1)
            XCTAssertEqual(image.height, max(1, Int(ceil(bounds.height / bounds.width))))
        }
    }

    func testDecodedImageCarriesActualICCProfileInsteadOfDefaultSRGB() throws {
        let file = try NativeFile(fixture(gradient), engine: .jpegXL)
        let image = try file.image(0, width: 0)
        let space = try XCTUnwrap(image.colorSpace)
        let profile = try XCTUnwrap(space.copyICCData()) as Data
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        XCTAssertNotEqual(profile, sRGB, "PQ gradient must retain its decoded-data color profile")
        // pq_gradient is monochrome: keep its gray PQ profile and alpha,
        // rather than assigning an RGB profile to expanded decoder samples.
        XCTAssertEqual(space.numberOfComponents, 1)
        XCTAssertEqual(image.bitsPerPixel, 16)
        XCTAssertEqual(image.bytesPerRow, image.width * 2)
    }

    func testInvalidPageAndTruncatedFileReportErrorsWithoutBreakingValidPage() throws {
        let url = try fixture(animation), file = try NativeFile(url, engine: .jpegXL)
        XCTAssertThrowsError(try file.image(-1, width: 0))
        XCTAssertThrowsError(try file.image(file.count, width: 0))
        XCTAssertThrowsError(try file.bounds(file.count))
        XCTAssertEqual(try file.image(0, width: 0).height, 80)
        try Data(try XCTUnwrap(Data(base64Encoded: animation)).prefix(100)).write(to: url)
        XCTAssertThrowsError(try NativeFile(url, engine: .jpegXL)) { XCTAssertTrue($0.localizedDescription.contains("JPEG XL")) }
    }

    func testMissingAndEmptyFileKeepSpecificReadFailure() throws {
        let url = try fixture("")
        XCTAssertThrowsError(try NativeFile(url, engine: .jpegXL)) { XCTAssertTrue($0.localizedDescription.contains("empty")) }
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try NativeFile(url, engine: .jpegXL)) { XCTAssertTrue($0.localizedDescription.contains("Cannot open JPEG XL")) }
    }
}
#endif
