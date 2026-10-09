import Foundation

// Sumatra DisplayModel.cpp (012d997f): default percentage stops, virtual fit
// modes, and the canvas extent that bounds layout arithmetic. Values here are
// scale factors (1 = 100%); persisted positions and readers share them.
public enum ReadingZoom {
    public static let minimum = 8.33 / 100
    public static let maximum = 64.0
    public static let absoluteMaximum = 10_000.0
    public static let maximumCanvasExtent = Double(1 << 29)
    public static let levels = [8.33, 12.5, 18, 25, 33.33, 50, 66.67, 75, 100, 125, 150, 200, 300, 400, 600, 800, 1000, 1200, 1600, 2000, 2400, 3200, 4800, 6400].map { $0 / 100 }
    public static let fitTitles = ["page": "Fit Page", "width": "Fit Width", "height": "Fit Height", "orientation": "Fit by Orientation", "shrink": "Shrink to Fit", "content": "Fit Content", "visible": "Fit Visible Content", "actual": "Actual Size"]
    public static func usesContent(_ mode: String) -> Bool { mode == "content" || mode == "visible" }

    /// DisplayModel::ZoomRealFromVirtualForPage: percentage zoom normalizes each
    /// page to the first page's rotated width, independently of the viewport.
    public static func pageScale(zoom: Double, referenceWidth: Double, pageWidth: Double, uniform: Bool) -> Double {
        guard uniform, referenceWidth.isFinite, pageWidth.isFinite, referenceWidth > 0, pageWidth > 0 else { return zoom }
        return zoom * referenceWidth / pageWidth
    }

    public static func maximum(for levels: [Double]) -> Double {
        max(maximum, levels.filter { $0.isFinite && $0 <= absoluteMaximum }.max() ?? maximum)
    }
    public static func parseLevels(_ text: String) throws -> [Double] {
        let values = try text.split { $0.isWhitespace || $0 == "," }.map { try parsePercent(String($0), limit: absoluteMaximum) }
        return Array(Set(values)).sorted()
    }

    public static func clamp(_ scale: Double, limit: Double = maximum) -> Double {
        let maximum = limit.isFinite && limit > 0 ? min(absoluteMaximum, limit) : Self.maximum
        return min(maximum, max(minimum, scale.isFinite ? scale : 1))
    }
    public static func documentLimit(totalHeight: Double, maximumWidth: Double, maximumZoom: Double = maximum) -> Double {
        let longest = max(1, totalHeight, maximumWidth * 2)
        return longest.isFinite ? min(clamp(maximumZoom, limit: absoluteMaximum), maximumCanvasExtent / longest) : Double.leastNormalMagnitude
    }
    public static func documentLimit(pageCount: Int, uniform: Bool, maximumZoom: Double = maximum,
                                     pageSize: (Int) throws -> (width: Double, height: Double)?) rethrows -> Double {
        var height = 0.0, width = 0.0, referenceWidth = 0.0
        for index in 0..<pageCount {
            guard let size = try pageSize(index) else { continue }
            if index == 0 { referenceWidth = size.width }
            let ratio = pageScale(zoom: 1, referenceWidth: referenceWidth, pageWidth: size.width, uniform: uniform)
            height += size.height * ratio
            width = max(width, size.width * ratio)
        }
        return documentLimit(totalHeight: height, maximumWidth: width, maximumZoom: maximumZoom)
    }
    public static func parsePercent(_ text: String, limit: Double = maximum) throws -> Double {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("%") { text.removeLast() }
        let maximum = min(absoluteMaximum, limit)
        guard let percent = Double(text), percent.isFinite, percent / 100 >= minimum, percent / 100 <= maximum else {
            throw ReadError("Zoom must be between 8.33% and \(maximum * 100)%")
        }
        return percent / 100
    }
    public static func fitScale(width: Double, height: Double, viewportWidth: Double, viewportHeight: Double, mode: String) -> Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 1 }
        let horizontal = max(1, viewportWidth) / width, vertical = max(1, viewportHeight) / height
        let mode = mode == "orientation" ? (viewportWidth > viewportHeight ? "width" : "page") : mode
        switch mode {
        case "actual": return 1
        case "width", "visible": return horizontal
        case "height": return vertical
        case "shrink": return min(1, horizontal, vertical)
        default: return min(horizontal, vertical)
        }
    }
    public static func nextStep(from current: Double, direction: Int, pageFit: Double? = nil, widthFit: Double? = nil, limit: Double = maximum, levels: [Double] = ReadingZoom.levels, increment: Double = 0) -> (zoom: Double, fit: String?) {
        let maximum = clamp(absoluteMaximum, limit: limit)
        let current = current.isFinite && current > 0 ? min(current, maximum) : clamp(current, limit: limit), fuzz = 0.0001
        guard direction != 0 else { return (current, nil) }
        let boundary = direction > 0 ? maximum : min(current, clamp(minimum, limit: limit))
        // MaybeGetNextZoomByIncrement precedes fixed and fit stops upstream.
        if increment.isFinite, increment > 0 {
            let factor = 1 + increment / 100
            return (direction > 0 ? min(current * factor, boundary) : max(current / factor, boundary), nil)
        }
        var stops = (levels.isEmpty ? Self.levels : levels).filter { $0.isFinite && $0 >= minimum && $0 <= maximum }.map { ($0, Optional<String>.none) }
        for (value, mode) in [(pageFit, "page"), (widthFit, "width")] {
            if let value, value.isFinite, value >= minimum, value <= maximum,
               !stops.contains(where: { abs($0.0 - value) <= fuzz }) { stops.append((value, mode)) }
        }
        stops.sort { $0.0 < $1.0 }
        let stop = direction > 0 ? stops.first { $0.0 > current + fuzz } : stops.last { $0.0 < current - fuzz }
        return stop.map { ($0.0, $0.1) } ?? (boundary, nil)
    }
}
