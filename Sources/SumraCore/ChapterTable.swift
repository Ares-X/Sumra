// Copyright 2026 the SumatraPDF project authors (see THIRD_PARTY.md).
// ChapterTable / Location translation from pinned GPLv3 sources.
import Foundation

/// Sumatra ChapterTable / Location (012d997f), translated to zero-based indices.
/// A location survives changes to the flat page numbers of preceding chapters.
public struct PageLocation: Hashable, Codable, Sendable, Comparable {
    public let chapter: Int
    public let page: Int
    public init(chapter: Int = 0, page: Int) { self.chapter = chapter; self.page = page }
    public static func < (a: Self, b: Self) -> Bool {
        a.chapter == b.chapter ? a.page < b.page : a.chapter < b.chapter
    }
}

/// The decoder owner mutates this table; readers receive immutable snapshots.
public struct ChapterTable: Equatable, Sendable {
    private var counts: [Int]
    private var laidOut: [Bool]
    private var ends: [Int]
    public private(set) var generation = 0
    public var chapterCount: Int { counts.count }
    public var totalPages: Int { ends.last ?? 0 }
    public var complete: Bool { laidOut.allSatisfy { $0 } }

    public init(chapters: Int) {
        let n = max(1, chapters)
        counts = Array(repeating: 1, count: n)
        laidOut = Array(repeating: false, count: n)
        ends = Array(1...n)
    }
    public init(pages: Int) {
        self.init(chapters: 1)
        setPageCount(chapter: 0, count: pages)
    }
    public func pageCount(_ chapter: Int) -> Int { counts.indices.contains(chapter) ? counts[chapter] : 0 }
    public func isLaidOut(_ chapter: Int) -> Bool { laidOut.indices.contains(chapter) && laidOut[chapter] }
    public mutating func setPageCount(chapter: Int, count: Int) {
        guard counts.indices.contains(chapter) else { return }
        let count = max(1, count), changed = counts[chapter] != count
        counts[chapter] = count
        laidOut[chapter] = true
        if changed { rebuild(); generation &+= 1 }
    }
    public mutating func reset() {
        counts = Array(repeating: 1, count: counts.count)
        laidOut = Array(repeating: false, count: counts.count)
        rebuild(); generation &+= 1
    }
    private mutating func rebuild() {
        var total = 0
        ends = counts.map { total += $0; return total }
    }
    public func location(page: Int) -> PageLocation? {
        guard page >= 0, page < totalPages else { return nil }
        var lo = 0, hi = ends.count - 1
        while lo < hi {
            let middle = (lo + hi) / 2
            if ends[middle] > page { hi = middle } else { lo = middle + 1 }
        }
        return .init(chapter: lo, page: page - (lo == 0 ? 0 : ends[lo - 1]))
    }
    public func page(for location: PageLocation) -> Int? {
        guard counts.indices.contains(location.chapter) else { return nil }
        return (location.chapter == 0 ? 0 : ends[location.chapter - 1]) + min(max(0, location.page), counts[location.chapter] - 1)
    }
    public func bookmark(_ location: PageLocation) -> String {
        let position = "\(location.chapter):\(location.page)"
        // An unresolved navigation target has no saved pagination to scale.
        return isLaidOut(location.chapter) ? position + ":\(pageCount(location.chapter))" : position
    }
    public static func bookmarkLocation(_ anchor: String) -> (location: PageLocation, count: Int)? {
        let parts = anchor.split(separator: ":")
        guard (2...3).contains(parts.count), let chapter = Int(parts[0]), let page = Int(parts[1]), chapter >= 0, page >= 0,
              let count = parts.count == 3 ? Int(parts[2]) : 0, count >= 0 else { return nil }
        return (.init(chapter: chapter, page: page), count)
    }
    /// EngineBase::LookupBookmark scales the one-based page through reflow.
    public func restored(_ location: PageLocation, savedCount: Int) -> PageLocation {
        let chapter = min(max(0, location.chapter), chapterCount - 1), count = pageCount(chapter)
        let page = savedCount > 0 && savedCount != count
            ? Int(min(Double(count), ((Double(location.page) + 1) * Double(count) / Double(savedCount)).rounded())) - 1
            : location.page
        return .init(chapter: chapter, page: min(max(0, page), count - 1))
    }
}
