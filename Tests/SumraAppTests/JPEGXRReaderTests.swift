#if os(macOS)
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class JPEGXRReaderTests: XCTestCase {
    // Generated with Artifex thirdparty-jpegxr 71ff24a9eb9a5c8dd70e1fd97a5316e06b0b0791,
    // Software/jpegxr -c -q 0 [-a 1 | -a 2] -o output.jxr input.ppm/input.tif.
    // RGB is 17x19: R=x*15, G=y*13, B=(x+y)*7 (P6 PPM).
    // RGBA TIFFs contain red/alpha128 left and green/alpha255 right; split x=8
    // for interleaved 17x19, x=16 for separate 32x32. All use default 96 DPI.
    // TIFF: uncompressed RGB, four 8-bit samples, contiguous, unassociated alpha.
    private let rgb = "SUm8AQgAAAAFAAG8AQAQAAAASgAAAIC8BAABAAAAEQAAAIG8BAABAAAAEwAAAMC8BAABAAAAWgAAAMG8BAABAAAAdQQAAAAAAAAkw91vA07+S7GFPXd2jckNV01QSE9UTwARAcBxABAAEmAAgAgAgAAABG//AAEAAAEA0ZvlR/hBjBAHBXiTnKVYxiQpS8IUQQ4A4GCc8ACgMZGOUvCBEEFANBW2vEQTBANAAvgxii4zjj8ZZBk+HBQWGw58d8MjHEeDrB/x4dceU+I5x4ISLn/jTY8NEw4IaLnmjfHUS8oyd7jnlGb5imkqDOI8OR4aPwemvMeB+yCDGEWDrR6H46PMMnbnZK8x4+CHKM3zbNEyPMPcuySx5Bk/NkJ55hDCRwgEEKOIuwW97gh8Zz6KtLJbyCCAkLLNEnkNxCEKDcGeEAHxnH9KReFt7hABQzD/ihsFoLbucRZJLNXMIWU1wqoIICR5GivOh3EIxDYSJQQQAjxE3zodxCIZIXiCNmiZ/x5hDSzlNXEEbo0TNzXnIabuC8ghhIjkZFhQsLm77j0yRQ8OhUV2qIcULyHTfw5CIb4o0/Fhp6KFft44keFrT0UKJ/eQRNl2v4Rd5cSogAsVOnaJveQROe4KiHFCIOFQ3+nIDfkR4VyCPin8w5AE5CMRpJoJHHydvgAmEQBgGIgEAYzxEApnGNIDABlWAwacQHAAF/slG73NlJx8P3qSgxAQDPaBXddh/aADEBAMOdm2lHjTFTD7QDad5YTfQg8nkCT0ANBaIcnuIJzpcJh0MADQWiDU7ywO+hQJhAwBqdfLIapnGLSVsqtAWDmyQb/gHjk2Eo0VmCAH+AJGv+o5DZ9aAEA33clkMQSePpsbRWFg+nQ0/HJsIjBACADh0NNibzSRKGCIQCAb7uSyGIJMx5rUIdGTEhiYNacmwnmDShIgAEwaTavVrC1CHDggA1ryQKgD45YVKO2B3oAOOahPAAExmN4OEAFO3JApEDCRmN6m+4wokED2jpTFTxRslRIyIRQCl68QT4qERFKGKvtFg0AMwQG9vjfW83xr7flU8hzPIqOrL0jvDMWQY7PBXfXOb0866qk6w0Q4TAYwHJ0heGAw0mLa0dmU08rE4zDgEJgABlG8soYA6808oIjXDWiUBPWn5R95q+olbpTOWIHAeSZDo8819BEiH3mB7mCGVDBBmwovXuMwHFgBgHhBD2soydbWLdDOuyMvLTigUl6OCgCDNmiabG5IiFJpQLolifU5LzC7G01GORPWWfIUcITNAmO8kyMNAnR4QmaBOx4QmjABoE1CGkJhuCYMNAnriTHWihqZxFvRRU46s3igaBMOGkJvoomadUDZjsTvNwFnWt8HgaOyjdaJnUkuNfaVs5O2JNMwvsCQFEoCsGBn8e/dn2xN2iD7QLSAWR9QCUYaEAb7QLSAX6xqiCWeGhAG6D2SGAT1QCUYcIAx9VMiw9S9hYIBwgDdB7JDAPUqwsEAwfdQafx6HQvkTXvleAgP1OvRSMwAA+V4CDrV2RMgzwAAAAD9Tr0UjMAAJSEx1e4UbAAAAAAAAAAAAHjUbwLygKPlNUMRTkax0hMAAPlNUMTeeJ+chQAAAAApyNY6QmAAEPI1mrBoAAAAAAAAAAAAAA=="
    private let interleavedAlpha = "SUm8AQgAAAAFAAG8AQAQAAAASgAAAIC8BAABAAAAEQAAAIG8BAABAAAAEwAAAMC8BAABAAAAWgAAAMG8BAABAAAAXwQAAAAAAAAkw91vA07+S7GFPXd2jckPV01QSE9UTwARAcFxABAAEmAAgAgAgAAAgCAIAAAEb/8AAQAAAQBrFr0Rx8MIDCAQBCY5ykGMdScYcJae9II/S3kAQmiLjGAyH4HCRnvSCKUnABCgAeIYxpngSpbOd++FwQ0YQsQwziCBHyLTImOB8fGF4NuA8EMEELEKIUQQIuQ+fNdBsdjR8k82LwZjaDtTZvE2g/02bywkgT4yDdYSQJ8ZBMtLyo3rwSJEE4Awj4YTYCCXAwh4kwh3SCFIdMdqUwkbEEQmS8EhxBOAII/EE14glwIIgFDCG5MIWx1NOSpRhIwaMIeMkkqmaySqC7VJOC7VJOZvZKpm5NqmbknqY3ZPWCLxBL8YRTBhLMYQMYQWEEjkggKOgwjA2IIHdDYIxEEvhBFUEEtBhBCCCyCR6YQFnQYRjphBOnOwia1RNakx49gmLHuNeoYRLCQQN0AQmjFIxgOFCCLBHowjkQQUYQMQROZyI0xcrhCBDecTwR6II4EEDEEEEETkKwZ6Ymeme7ifCDjEGwdMXaRO8DdA3gYbZMX8Dohhtkz3lwhjWnGauLwAYDAYgEAxgAAMBgMQCAYwABjAAAAAAAAuiJi6ImLoiYvEbq8Ruq1e3XIjdYbNSHOuQ7lyHcuQzFyDcWGwKTzlhsCmbzMuZvM1rU3smta12TXMbu61rZvGJS1qtmsfTeAlrVbNa1qluta1SWWtapLWtapLWPpvAS1qktY+m8BVdgAMBgMQCAYwCeec4Seec4SHIxDkWnnnOB9W0WmpIIdFuJ4v0aFuGO4Y7hbuFu4W4ni/I0LcKaHjuI0LAAAAD9xkMjOJIIZIxIUppwze/GQI9AAGeQlTQH/WmQBHEABOSW2w9qSpBAcGEG8AQGHtSGusZkEAIQQakEC5pLusJg7mku64f9Ia1MQFxIdwBNO78jmEz5ZpPdfFMSIYRB+i80XAhpAUN9TEEseQwmNAEsobVNrVQJZJqBMdAlkBaqqeUtdlylrsuVH6ptjNcJF1gR7Ah0CRjgRBQiAiIwhQR1VduUqrtyuEiLUJAwIbAkXWhEBBEEiRBCwDhrN5URtIJG4MJPACRaG+pMkEi8EEniCRnYJix7BDfrhF8CKHAgcCMYEEdCCFIwgATJix7DhGFCKnAglCCwIzrAgsUoYggQAFcADeJkY4MaGQo9KsCIzCLZBEi5C+wIkgRcoESLeaXCHa7N5pcIchfCDQINRYECjBVXxnI/da7N5pcIfCDQIJBaEEmojdVBCN7CHnfNQsAAMAeAAYMwARgEASkZkCIyAAAAAAAAyUy5KZclMuXdcu6w2BT3WGwKe65zLHTQ6anMsNTQ6ad3PpdWpMBdWpMBdWpMBdWpMBdWpMAPZvGl1akwA9m8aXdSTAXdSTAHZ48UOzx4pd1JMAfTeNDs8eKRvUNqAGIyJSNSMIYG4S7hLuEu4Q7hDQ8f6bC3BaHj/TYW4LuC4nvOGwsT3nBoW4LQ8C6NCxPecGhUbQ+6OY"
    private let separateAlpha = "SUm8AQgAAAAHAAG8AQAQAAAAYgAAAIC8BAABAAAAIAAAAIG8BAABAAAAIAAAAMC8BAABAAAAcgAAAMG8BAABAAAAJgMAAMK8BAABAAAAmAMAAMO8BAABAAAAqwQAAAAAAAAkw91vA07+S7GFPXd2jckPV01QSE9UTwARAcBxAB8AH2AAgAgAgAAABG//AAEAAAEAdkSakYe9qzlKiDCA5R0EIFEUTR+eKblkQrV0U51JQ26Ongf5nijLgy1pKMSy2c798KyD444Hx2puJoOx4IaIYYQsZxBAj5FpkTam4uNBcbcBtB2oNLE0H+h0tQa9RpvGw16jTeJrO/TVtBfSYF9Ds3FAbVgkSIJwBhHwwh5hNhEEuBIwh2kEKQ47G6lMJGpBEMZHAbUOuqAfUOuoddUgY66pA8EXjCKRBL8YQUwlnggkcMIHpBAUdBowjCEEDRzQ3jaG8bazh5CJWwlzECowvIQSQhBiiRIkXkgpezmNc7ElXJK2kgqSAfkbcpaWmNJhktwsFgQycghaPkECn3WQTWMzGnz+ZkE1ye61q83lScyx3EExHzMnMsJiLuZOa5KZYbqSmWG6wSHgR/AnAgRBKhDSCa/CCXEwhbHmbm1LWhIxJUIe0Mim5Nqmbm1LU57ZAKm5NqH3HvpTckjU3JI1NySNTckjU3JIw9PGlrskYeniWCMYEVQILAl9QgmRBLQQSPMICZ0SMIxMYQQ7sEWE7BFhMxADAAAchSFw4hUDkZt+ZblYPr4UUg/JrrF7LhKNQLLBVYlbYK+h3DVQV9DvEh3DVJVQIDyGEGAEBHeJJXXBX0O8SYlLVR2Md5XVr61HY8eiTwAW2j8OtrfVvTab/1bxK3ptPRBLHowmNAEsreJPJtb6t4kxK61Fa7eJPJ9aiteCPaEi4EQQJGQIcbowiARDCFQj9SgSN5DCTwAkX1a+rXgiihF8CCQIHAjH6MIIKMIBCaAABgAfdnUnWcCrxnjZvUx5EV/HJxD9Gz/WGogxVAtNCrEpbSRBAGiCDEECZR/ddIeEo/ut/Y7af2O2qQc9o/sfEot8IQ2wXheBDTU/sdtBpqku5j60oEsk1AmOEEsutKqYOtbKutbKutKqYLxGuV1rZVeDlda2Vda2VcJA0JEUIggQ20CRZsQRAIhBC4B7eTSXWltV4OVbyaSXRt3MaLJBItEEniCRmQRYTIIsJkOEVUIwoQWBBIEZuqgQWMCBIjBXTVBIT1RPABEBwAEAHwAfAIAgCAAABG//AAEAAAEADuE3kntSloI2LTkgwiS4I9GEciCCjCBiCJzORGmLlcIQIbziboG6BxmiE3EvactpI+jjEgwhERHBHsCOIEDgQSBE5C9GemJnpnu4nwg9aIrLF2iHPA1Pc4n6qVn5MV4h3gek3d5rAobZM94HRDDbJvPLhDuC4Ie6bgW4Lgh7puBQBdJdbGushbC2VasCIzCLZBEhORDkQ+EGgQaiwIFGCqrM8jvAW6rclK9P8UthfYIkgi5QRIheeXCHa7Jw5cF3BcJ70boW4DhPejdC2uy4KXAfCDQQTCCQuJZvYSML2EPFtNhbgOJ7yGwKh4tpsKjGUlg5gA=="

    private func fixture(_ base64: String, extension suffix: String = "jxr") throws -> URL {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("Build the MuPDF engine before native integration tests")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-JPEGXR-" + UUID().uuidString + "." + suffix)
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 32)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return (0..<image.height).flatMap { y in
            Array(data[(y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width * 4)])
        }
    }

    func testLosslessRGBAndAllAliasesKeepOpaquePixelsPartialBlocksAndDensity() throws {
        let original = try XCTUnwrap(Data(base64Encoded: rgb))
        var expected = [UInt8]()
        for y in 0..<19 {
            for x in 0..<17 { expected.append(contentsOf: [UInt8(x * 15), UInt8(y * 13), UInt8((x + y) * 7), 255]) }
        }
        for suffix in ["jxr", "hdp", "wdp"] {
            let url = try fixture(rgb, extension: suffix)
            XCTAssertEqual(Format.imageEngine(url.lastPathComponent, prefix: original), "MuPDF")
            let file = try NativeFile(url, engine: .mupdf)
            XCTAssertEqual(file.count, 1)
            XCTAssertEqual(try file.bounds(0), CGRect(x: 0, y: 0, width: 12.75, height: 14.25))
            XCTAssertEqual(try file.imageDimensions(0), CGSize(width: 17, height: 19))
            let image = try file.image(0, width: 17, transparent: true)
            XCTAssertEqual(image.width, 17); XCTAssertEqual(image.height, 19)
            XCTAssertEqual(try pixels(image), expected, suffix)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testInterleavedAndSeparateAlphaUsePremultipliedPixels() throws {
        for (data, width, height, split) in [(interleavedAlpha, 17, 19, 8), (separateAlpha, 32, 32, 16)] {
            let file = try NativeFile(fixture(data), engine: .mupdf)
            let image = try file.image(0, width: width, transparent: true)
            XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
            XCTAssertEqual(image.alphaInfo, .premultipliedLast)
            let expected: [UInt8] = (0..<height).flatMap { _ in (0..<width).flatMap { x in
                x < split ? [128, 0, 0, 128] : [0, 255, 0, 255]
            } }
            XCTAssertEqual(try pixels(image), expected)
        }
    }

    func testMissingContainerMetadataReportsReadFailure() throws {
        let url = try fixture(rgb)
        let original = try XCTUnwrap(Data(base64Encoded: rgb))
        var missingIFD = original
        missingIFD.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        for data in [Data(original.prefix(8)), Data(original.prefix(16)), missingIFD] {
            try data.write(to: url)
            XCTAssertThrowsError(try NativeFile(url, engine: .mupdf).image(0, width: 17))
        }
    }

    @MainActor
    func testImagePDFKeepsNativeJXRPixelsInsteadOfResamplingTo2400() async throws {
        let source = try fixture(rgb)
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let output = directory.url.appendingPathComponent("Image.pdf")
        let pages = try Pages(source, format: .image)
        try await pages.exportPDF(to: output)
        let pdf = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(try pdf.imageDimensions(0), CGSize(width: 17, height: 19))
        XCTAssertEqual(try pdf.bounds(0), CGRect(x: 0, y: 0, width: 12.75, height: 14.25))
        let original = try NativeFile(source, engine: .mupdf).image(0, width: 17, transparent: true)
        XCTAssertEqual(try pixels(pdf.image(0, width: 17, transparent: true)), try pixels(original))
    }

    func testEditableNativeJXRRetainsSourceDensity() async throws {
        let pages = try Pages(fixture(rgb), format: .mupdf)
        let image = try await pages.editableImage(0)
        XCTAssertEqual(image.image.width, 17); XCTAssertEqual(image.image.height, 19)
        XCTAssertEqual(image.dpi, 96, accuracy: 0.0001)
    }
}
#endif
