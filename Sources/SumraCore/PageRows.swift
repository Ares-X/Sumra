import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Zero-based Sumatra DisplayModel row grouping and DocumentLayout's
/// CollectFacingRows (012d997f6a3a5c5c97b878e1a340db3bffde8c0e).
public enum PageRows {
    public struct Placement: Equatable {
        public var frame: CGRect
        public let scale: Double
    }
    public struct Layout {
        /// Original page indices; pages outside the paged row are nil.
        public let pages: [Placement?]
        public let canvas: CGSize
        /// The rows actually placed, in document order even in RTL mode.
        public let rows: [Range<Int>]
    }

    /// Continuous pages with one display size need no page or row arrays.
    /// The reader still creates views only for the rows in its viewport.
    public struct UniformLayout {
        public let count: Int
        public let rowCount: Int
        public let canvas: CGSize
        private let singleSize: CGSize, pairSize: CGSize
        private let spread: Bool, cover: Bool, rtl: Bool
        private let columnWidth: CGFloat, firstX: CGFloat, slackX: CGFloat
        private let firstY: CGFloat, pairStride: CGFloat, spacing: CGSize
        private let mirrorWidth: CGFloat

        fileprivate init?(singleSize: CGSize, pairSize: CGSize, count: Int, viewport: CGSize, spread: Bool, cover: Bool,
                          rtl: Bool, freePan: Bool, spacing: CGSize, inset: CGSize) {
            guard count > 0, singleSize.width.isFinite, singleSize.height.isFinite,
                  singleSize.width > 0, singleSize.height > 0,
                  pairSize.width.isFinite, pairSize.height.isFinite,
                  pairSize.width > 0, pairSize.height > 0 else { return nil }
            self.count = count; self.singleSize = singleSize; self.pairSize = pairSize
            self.spread = spread; self.cover = cover; self.rtl = rtl
            self.spacing = spacing
            rowCount = !spread ? count : (cover ? 1 + count / 2 : (count + 1) / 2)
            pairStride = pairSize.height + spacing.height
            let singletonRows = !spread ? count : (cover ? 1 : 0) + ((count - (cover ? 1 : 0)) % 2)
            let pairRows = rowCount - singletonRows
            let firstColumn = !spread ? singleSize.width
                : max(pairRows > 0 ? pairSize.width : 0,
                      (!cover && count % 2 == 1 || cover && count % 2 == 0) ? singleSize.width : 0)
            let secondColumn = spread ? max(pairRows > 0 ? pairSize.width : 0, cover ? singleSize.width : 0) : 0
            // DocumentLayout reserves two facing slots even for a one-page book.
            columnWidth = spread && count == 1 ? max(firstColumn, secondColumn) : firstColumn
            let otherColumn = spread && count == 1 ? columnWidth : secondColumn
            let pageWidth = columnWidth + (spread ? spacing.width + otherColumn : 0)
            let natural = CGSize(width: inset.width * 2 + pageWidth,
                                 height: inset.height * 2 + CGFloat(singletonRows) * singleSize.height
                                    + CGFloat(pairRows) * pairSize.height + CGFloat(rowCount - 1) * spacing.height)
            let base = CGSize(width: max(viewport.width, natural.width), height: max(viewport.height, natural.height))
            let slack = freePan ? CGSize(width: viewport.width / 2, height: viewport.height / 2) : .zero
            canvas = CGSize(width: base.width + 2 * slack.width, height: base.height + 2 * slack.height)
            mirrorWidth = base.width
            slackX = slack.width
            let dx = inset.width + max(0, (viewport.width - natural.width) / 2)
            firstX = dx
            firstY = inset.height + max(0, (viewport.height - natural.height) / 2) + slack.height
        }

        public func range(row: Int) -> Range<Int> {
            guard (0..<rowCount).contains(row) else { return 0..<0 }
            if !spread { return row..<(row + 1) }
            if cover && row == 0 { return 0..<1 }
            let first = cover ? 1 + (row - 1) * 2 : row * 2
            return first..<min(count, first + 2)
        }

        public func row(atY y: CGFloat) -> Int {
            guard y.isFinite else { return 0 }
            if y <= firstY { return 0 }
            if y >= rowY(rowCount - 1) { return rowCount - 1 }
            let candidate: Int
            if spread && cover {
                let afterCover = rowY(1)
                if y < afterCover { return 0 }
                candidate = 1 + Int((y - afterCover) / pairStride)
            } else {
                candidate = Int((y - firstY) / (spread ? pairStride : singleSize.height + spacing.height))
            }
            // Correct rounding at a distant row boundary without a row scan.
            if y < rowY(candidate) { return candidate - 1 }
            if y >= rowY(candidate + 1) { return candidate + 1 }
            return candidate
        }

        private func rowY(_ row: Int) -> CGFloat {
            spread && cover && row > 0
                ? firstY + singleSize.height + spacing.height + CGFloat(row - 1) * pairStride
                : firstY + CGFloat(row) * (spread ? pairStride : singleSize.height + spacing.height)
        }

        public func placement(page: Int) -> Placement? {
            guard (0..<count).contains(page) else { return nil }
            let row = !spread ? page : (cover ? (page == 0 ? 0 : 1 + (page - 1) / 2) : page / 2)
            let range = range(row: row)
            let size = range.count == 1 ? singleSize : pairSize
            let x: CGFloat
            if !spread { x = firstX }
            else if cover && page == 0 || page != range.lowerBound { x = firstX + columnWidth + spacing.width }
            else { x = firstX + columnWidth - size.width }
            let mirroredX = (rtl && spread ? mirrorWidth - x - size.width : x) + slackX
            return Placement(frame: CGRect(origin: CGPoint(x: mirroredX, y: rowY(row)), size: size), scale: 1)
        }
    }

    public static func uniformLayout(singleSize: CGSize, pairSize: CGSize, count: Int, viewport: CGSize,
                                     spread: Bool, cover: Bool, rtl: Bool, freePan: Bool = false,
                                     spacing: CGSize = CGSize(width: 8, height: 8),
                                     inset: CGSize = CGSize(width: 4, height: 4)) -> UniformLayout? {
        UniformLayout(singleSize: singleSize, pairSize: pairSize, count: count, viewport: viewport, spread: spread,
                      cover: cover, rtl: rtl, freePan: freePan, spacing: spacing, inset: inset)
    }

    /// The PDF uniform-width entry point keeps its original per-page scales.
    /// Sizes are already cropped and rotated; all row geometry is shared below.
    public static func layout(sizes: [CGSize], viewport: CGSize, page: Int, continuous: Bool,
                              spread: Bool, cover: Bool, rtl: Bool, zoom: Double,
                              spacing: CGSize = CGSize(width: 8, height: 8),
                              inset: CGSize = CGSize(width: 4, height: 4)) -> Layout {
        guard let first = sizes.first, zoom.isFinite, zoom > 0,
              sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else {
            return Layout(pages: Array(repeating: nil, count: sizes.count), canvas: viewport, rows: [])
        }
        let scales = sizes.map {
            ReadingZoom.pageScale(zoom: zoom, referenceWidth: Double(first.width), pageWidth: Double($0.width), uniform: true)
        }
        let displaySizes = zip(sizes, scales).map { CGSize(width: $0.0.width * CGFloat($0.1), height: $0.0.height * CGFloat($0.1)) }
        let geometry = layout(displaySizes: displaySizes, viewport: viewport, page: page, continuous: continuous,
            spread: spread, cover: cover, rtl: rtl, spacing: spacing, inset: inset)
        let pages = geometry.pages.enumerated().map { index, placement in
            placement.map { Placement(frame: $0.frame, scale: scales[index]) }
        }
        return Layout(pages: pages, canvas: geometry.canvas, rows: geometry.rows)
    }

    /// Translated from DocumentLayout::Relayout, RelayoutFacingWithSpreads and
    /// FinishRelayout. Inputs already include zoom, crop and rotation; the result
    /// uses AppKit points and never measures or renders document pages.
    public static func layout(displaySizes: [CGSize], viewport: CGSize, page: Int, continuous: Bool,
                              spread: Bool, cover: Bool, rtl: Bool, landscape: Set<Int> = [], freePan: Bool = false,
                              spacing: CGSize = CGSize(width: 8, height: 8),
                              inset: CGSize = CGSize(width: 4, height: 4)) -> Layout {
        var pages = [Placement?](repeating: nil, count: displaySizes.count)
        guard !displaySizes.isEmpty,
              displaySizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else {
            return Layout(pages: pages, canvas: viewport, rows: [])
        }
        let rows = continuous ? ranges(count: displaySizes.count, spread: spread, cover: cover, landscape: landscape)
            : [range(page: page, count: displaySizes.count, spread: spread, cover: cover, landscape: landscape)]
        var columns = [CGFloat](repeating: 0, count: spread ? 2 : 1)
        var spreadWidth: CGFloat = 0, y = inset.height
        for row in rows {
            let spansColumns = spread && landscape.contains(row.lowerBound)
            var height: CGFloat = 0
            for (offset, index) in row.enumerated() {
                let size = displaySizes[index]
                pages[index] = Placement(frame: CGRect(origin: CGPoint(x: 0, y: y), size: size), scale: 1)
                if spansColumns { spreadWidth = max(spreadWidth, size.width) }
                else {
                    let column = spread && cover && index == 0 ? 1 : offset
                    columns[column] = max(columns[column], size.width)
                }
                height = max(height, size.height)
            }
            y += height + spacing.height
        }
        // Even a one-page book has two facing slots upstream. A landscape
        // spread itself contributes to the full row, not to either column.
        if spread && displaySizes.count == 1 { columns = [max(columns[0], columns[1]), max(columns[0], columns[1])] }
        let pageWidth = max(columns.reduce(0, +) + (spread ? spacing.width : 0), spreadWidth)
        let natural = CGSize(width: inset.width * 2 + pageWidth, height: y + inset.height - spacing.height)
        var canvas = CGSize(width: max(viewport.width, natural.width), height: max(viewport.height, natural.height))
        let dx = inset.width + max(0, (viewport.width - natural.width) / 2)
        let dy = max(0, (viewport.height - natural.height) / 2)
        let slack = freePan ? CGSize(width: viewport.width / 2, height: viewport.height / 2) : .zero
        for row in rows {
            let spansColumns = spread && landscape.contains(row.lowerBound)
            for (offset, index) in row.enumerated() {
                guard var placement = pages[index] else { continue }
                let width = placement.frame.width
                var x: CGFloat
                if !spread { x = dx + (columns[0] - width) / 2 }
                else if spansColumns || cover && index == 0 && !continuous { x = dx + (pageWidth - width) / 2 }
                else if cover && index == 0 || offset == 1 { x = dx + columns[0] + spacing.width }
                else { x = dx + columns[0] - width }
                if rtl && spread { x = canvas.width - x - width }
                placement.frame.origin = CGPoint(x: x + slack.width, y: placement.frame.minY + dy + slack.height)
                pages[index] = placement
            }
        }
        canvas.width += 2 * slack.width; canvas.height += 2 * slack.height
        return Layout(pages: pages, canvas: canvas, rows: rows)
    }

    public static func range(page: Int, count: Int, spread: Bool, cover: Bool = false, landscape: Set<Int> = []) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let page = min(count - 1, max(0, page))
        guard spread, !(cover && page == 0), !landscape.contains(page) else { return page..<(page+1) }
        // Every full-width landscape row restarts the ordinary two-page pairing.
        let start = max(cover ? 1 : 0, (landscape.lazy.filter { $0 >= 0 && $0 < page }.max() ?? -1) + 1)
        let first = start + (page-start)/2*2
        return first..<rowEnd(first, count: count, spread: spread, cover: cover, landscape: landscape)
    }
    public static func ranges(count: Int, spread: Bool, cover: Bool = false, landscape: Set<Int> = []) -> [Range<Int>] {
        var result = [Range<Int>](), page = 0
        while page < count {
            let end = rowEnd(page, count: count, spread: spread, cover: cover, landscape: landscape)
            result.append(page..<end); page = end
        }
        return result
    }
    private static func rowEnd(_ first: Int, count: Int, spread: Bool, cover: Bool, landscape: Set<Int>) -> Int {
        if !spread || cover && first == 0 || landscape.contains(first) || landscape.contains(first+1) { return first+1 }
        return min(first+2, count)
    }
}
