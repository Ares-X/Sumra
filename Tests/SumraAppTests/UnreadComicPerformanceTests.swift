#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import XCTest
@testable import Sumra

/// Opt-in diagnosis: every scenario opens a fresh document and visits only
/// previously unread pages. OS file caching is intentionally not controlled.
final class UnreadComicPerformanceTests: XCTestCase {
    private func input() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SUMRA_UNREAD_COMIC"], !path.isEmpty else {
            throw XCTSkip("Set SUMRA_UNREAD_COMIC to a local comic archive")
        }
        return URL(fileURLWithPath: path)
    }

    private func elapsed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private func emit(_ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("SUMRA_UNREAD " + String(decoding: data, as: UTF8.self))
    }

    func testColdArchiveStages() throws {
        let url = try input()
        let count = try Archive(url).images.count
        XCTAssertGreaterThan(count, 0)
        let scenarios: [(String, [Int])] = [
            ("sequential", Array(0..<min(count, 32))),
            ("middle-jump", Array((count / 2)..<min(count, count / 2 + 4))),
            ("tail-jump", Array(max(0, count - 4)..<count))
        ]
        for (scenario, indices) in scenarios {
            let (archive, opening) = try elapsed { try Archive(url) }
            let (names, sorting) = elapsed { archive.images }
            try emit(["owner": "archive", "scenario": scenario, "open_ms": opening, "sort_ms": sorting,
                      "pages": names.count])
            for page in indices {
                let (header, prefix) = try elapsed { try archive.data(names[page], prefixBytes: 1024) }
                let (bytes, full) = try elapsed { try archive.data(names[page]) }
                let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary))
                let (image, decoding) = elapsed {
                    CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2800,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }
                let bitmap = try XCTUnwrap(image)
                try emit(["owner": "archive", "scenario": scenario, "page": page,
                          "archive_index": try XCTUnwrap(archive.entries.firstIndex(of: names[page])),
                          "prefix_ms": prefix, "full_ms": full, "decode_ms": decoding,
                          "prefix_bytes": header.count, "bytes": bytes.count,
                          "width": bitmap.width, "height": bitmap.height])
            }
        }
    }

    func testColdReaderRendering() async throws {
        let url = try input()
        let count = try Archive(url).images.count
        XCTAssertGreaterThan(count, 0)
        let scenarios: [(String, [Int])] = [
            ("sequential", Array(0..<min(count, 32))),
            ("middle-jump", Array((count / 2)..<min(count, count / 2 + 4))),
            ("tail-jump", Array(max(0, count - 4)..<count))
        ]
        for (scenario, indices) in scenarios {
            let pages = try Pages(url, format: .comic)
            for page in indices {
                let started = DispatchTime.now().uptimeNanoseconds
                let result = try await pages.render(page, viewport: CGSize(width: 1400, height: 900),
                    scale: 2, columns: 1, rotation: 0, fit: "width", zoom: 1)
                let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                let image = try XCTUnwrap(result.image)
                try emit(["owner": "reader", "scenario": scenario, "page": page, "render_ms": duration,
                          "width": image.width, "height": image.height])
            }
        }
    }
}
#endif
