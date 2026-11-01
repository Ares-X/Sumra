#if os(macOS)
import AppKit
import Darwin
import XCTest
@testable import Sumra

final class TextThumbnailPrefixTests: XCTestCase {
    func testPrefixMatchesFullDecodeForShortUnicodeAndLegacyText() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let unicode = String(repeating: "👩🏽‍🚀🇨🇳e\u{301}文\n", count: 3_000)
        let splitSurrogate = String(repeating: "🌌", count: 191) + String(repeating: "a", count: 7_808)
            + "🌌" + String(repeating: "後", count: 100)
        let western = String(repeating: "Café déjà vu — a reader’s preview.\n", count: 1_000)
        let japanese = "A" + String(repeating: "日本語の読書プレビュー。", count: 2_000)
        let samples: [(String, Data)] = [
            ("empty", Data()),
            ("short", Data("A short readable text.\nSecond line".utf8)),
            ("utf8-bom", Data([0xef, 0xbb, 0xbf]) + Data(unicode.utf8)),
            ("unicode", Data(unicode.utf8)),
            ("utf16-le", try XCTUnwrap(splitSurrogate.data(using: .utf16))),
            ("utf16-be", Data([0xfe, 0xff]) + (try XCTUnwrap(splitSurrogate.data(using: .utf16BigEndian)))),
            ("utf32", try XCTUnwrap(unicode.data(using: .utf32))),
            ("windows1252", try XCTUnwrap(western.data(using: .windowsCP1252))),
            ("shiftjis-split", try XCTUnwrap(japanese.data(using: .shiftJIS)))
        ]
        for (name, data) in samples {
            let url = directory.url.appendingPathComponent(name + ".txt")
            try data.write(to: url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try ReadingDocument.thumbnailText(handle)
            XCTAssertEqual(prefix, String(ReadingDocument.decode(data).prefix(8_000)), name)
            XCTAssertEqual(try Data(contentsOf: url), data, name)
        }
    }

    func testReadBoundaryDoesNotSplitUTF8OrTheEightThousandthCharacter() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let samples = [
            String(repeating: "a", count: 16_383) + "éZ",
            String(repeating: "a", count: 16_382) + "文Z",
            String(repeating: "a", count: 16_381) + "🌌Z",
            String(repeating: "文", count: 4_192) + String(repeating: "a", count: 3_807) + "éZ",
            String(repeating: "文", count: 4_191) + "é" + String(repeating: "a", count: 3_807) + "文Z",
            String(repeating: "文", count: 4_191) + String(repeating: "a", count: 3_808) + "🌌Z",
            String(repeating: "a", count: 7_999) + "e" + String(repeating: "\u{301}", count: 20_000) + "following",
            String(repeating: "a", count: 7_999) + "👩🏽‍🚀" + "following"
        ]
        for (index, text) in samples.enumerated() {
            let url = directory.url.appendingPathComponent("Boundary\(index).txt")
            try Data(text.utf8).write(to: url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            XCTAssertEqual(try ReadingDocument.thumbnailText(handle), String(text.prefix(8_000)), "sample \(index)")
        }
    }

    func testTextPreviewKeepsSidecarPriorityCacheAndReadOnlyState() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("Book.txt")
        let data = Data("A readable preview.\nSecond line".utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let history = UserDefaults.standard.data(forKey: "documentOpenHistory")
        let positionKey = "position:" + url.path
        let size = CGSize(width: 136, height: 168)
        let textKey = ReadingDocument.thumbnailCacheKey(url, size: size)
        let textImage = try await ReadingDocument.thumbnail(url, size: size)
        XCTAssertEqual(textImage?.width, 136)
        XCTAssertEqual(textImage?.height, 168)

        let png = url.deletingPathExtension().appendingPathExtension("png")
        let jpg = url.deletingPathExtension().appendingPathExtension("jpg")
        try cover(width: 40, height: 80, extension: "png").write(to: png)
        let pngKey = ReadingDocument.thumbnailCacheKey(url, size: size)
        XCTAssertNotEqual(textKey, pngKey)
        let pngPreview = try await ReadingDocument.thumbnail(url, size: size)
        let pngImage = try XCTUnwrap(pngPreview)
        XCTAssertEqual(Double(pngImage.width) / Double(pngImage.height), 0.5, accuracy: 0.02)
        try cover(width: 80, height: 40, extension: "jpg").write(to: jpg)
        XCTAssertNotEqual(pngKey, ReadingDocument.thumbnailCacheKey(url, size: size))
        let jpgPreview = try await ReadingDocument.thumbnail(url, size: size)
        let jpgImage = try XCTUnwrap(jpgPreview)
        XCTAssertEqual(Double(jpgImage.width) / Double(jpgImage.height), 2, accuracy: 0.02)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "documentOpenHistory"), history)
        XCTAssertNil(UserDefaults.standard.object(forKey: positionKey))
    }

    // Real written files, rather than sparse files or repeated in-memory copies.
    // The descriptor position proves that preview source work is independent of
    // file size; the logged render time is useful evidence, not a timing gate.
    func testOneFiftyAndTwoHundredMiBPreviewsReadOnlyTheirTextPrefix() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let block = Data(String(repeating: "A readable preview line.\n", count: 4_096).utf8)
        let expected = String(ReadingDocument.decode(block).prefix(8_000))
        for mebibytes in [1, 50, 200] {
            let url = directory.url.appendingPathComponent("\(mebibytes)MiB.txt")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let output = try FileHandle(forWritingTo: url)
            let size = mebibytes * 1_024 * 1_024
            var written = 0
            while written < size {
                let data = block.prefix(min(block.count, size - written))
                try output.write(contentsOf: data)
                written += data.count
            }
            try output.close()
            let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let input = try FileHandle(forReadingFrom: url)
            let started = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(try ReadingDocument.thumbnailText(input), expected)
            let consumed = try input.offset()
            try input.close()
            XCTAssertEqual(consumed, 16_384, "\(mebibytes) MiB must consume the same source prefix")
            let prefixMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let renderStarted = DispatchTime.now().uptimeNanoseconds
            let image = try await ReadingDocument.thumbnail(url, size: CGSize(width: 136, height: 168))
            XCTAssertNotNil(image)
            let renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - renderStarted) / 1_000_000
            let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            XCTAssertEqual(before.fileSize, size)
            XCTAssertEqual(after.fileSize, before.fileSize)
            XCTAssertEqual(after.contentModificationDate, before.contentModificationDate)
            print("TXT_PREVIEW \(mebibytes)MiB consumed=\(consumed) prefix_ms=\(prefixMilliseconds) thumbnail_ms=\(renderMilliseconds)")
            try FileManager.default.removeItem(at: url)
        }
    }

    // Run each old/new and 1/4-card variant in a fresh XCTest process against
    // an existing fixture. OS caches are warm/uncontrolled; this bypasses Home's
    // bitmap cache and measures its actual detached thumbnail-generation path.
    func testHomeTextThumbnailBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SUMRA_TXT_PREVIEW_BENCHMARK_FILE"] else {
            throw XCTSkip("Set SUMRA_TXT_PREVIEW_BENCHMARK_FILE to an existing TXT fixture")
        }
        guard let cards = Int(environment["SUMRA_TXT_PREVIEW_BENCHMARK_CARDS"] ?? "1"), [1, 4].contains(cards) else {
            XCTFail("SUMRA_TXT_PREVIEW_BENCHMARK_CARDS must be 1 or 4")
            return
        }
        let source = URL(fileURLWithPath: path)
        let bytes = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var baseline = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &baseline), 0)
        print("ISSUE60_HOME_BEGIN process_id=\(getpid()) cards=\(cards) bytes=\(bytes) process_policy=fresh-xctest-per-variant os_cache=warm-uncontrolled bitmap_cache=bypassed baseline_max_rss_bytes=\(baseline.ru_maxrss)")
        for run in 1...3 {
            let started = DispatchTime.now().uptimeNanoseconds
            let tasks = (0..<cards).map { _ in
                Task.detached(priority: .utility) {
                    try await ReadingDocument.thumbnail(source, size: CGSize(width: 136, height: 168))
                }
            }
            var failure: Error?
            // Await every owned task even if one fails, so no detached render
            // survives the benchmark method or affects the following variant.
            for task in tasks {
                do {
                    let image = try await task.value
                    XCTAssertEqual(image?.width, 136)
                    XCTAssertEqual(image?.height, 168)
                } catch { failure = failure ?? error }
            }
            let finished = DispatchTime.now().uptimeNanoseconds
            if let failure { throw failure }
            var usage = rusage()
            XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
            print("ISSUE60_HOME run=\(run) process_id=\(getpid()) cards=\(cards) bytes=\(bytes) total_ms=\(Double(finished - started) / 1_000_000) max_rss_bytes=\(usage.ru_maxrss) max_rss_increase_bytes=\(usage.ru_maxrss - baseline.ru_maxrss)")
        }
    }

    private func cover(width: Int, height: Int, extension ext: String) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try ReaderImages.encoded(XCTUnwrap(context.makeImage()), extension: ext)
    }
}
#endif
