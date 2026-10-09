#if os(macOS)
import AppKit

// Canvas.cpp::PaintPageGrid and base/Win.cpp::HdcPaintCheckerboard (012d997f).
// Coordinates stay in the original page; only the final drawing is transformed.
enum ReaderPageGrid {
    static func locations(from lower: CGFloat, through upper: CGFloat, origin: CGFloat, step: CGFloat) -> [CGFloat] {
        guard step.isFinite, step > 0, lower.isFinite, upper.isFinite, origin.isFinite, lower <= upper else { return [] }
        let first = origin + floor((lower-origin)/step)*step
        return Array(stride(from: first, through: upper+0.001, by: step))
    }

    @MainActor
    static func draw(in context: CGContext, bounds: CGRect, visible: CGRect, transform: CGAffineTransform, state: ReaderState, topDown: Bool = true) {
        guard state.showPageGrid else { return }
        let visible = visible.intersection(bounds)
        guard !visible.isEmpty, !visible.isNull,
              [state.pageGridWidth, state.pageGridHeight, state.pageGridOffsetX, state.pageGridOffsetY].allSatisfy(\.isFinite) else { return }
        let width = CGFloat(state.pageGridWidth), height = CGFloat(state.pageGridHeight)
        let subdivisions = state.pageGridSubdivisions
        let minorX = width / CGFloat(subdivisions), minorY = height / CGFloat(subdivisions)
        let origin = CGPoint(x: bounds.minX + state.pageGridOffsetX,
                             y: (topDown ? bounds.minY : bounds.maxY) + (topDown ? 1 : -1)*state.pageGridOffsetY)
        let pixel = 1 / max(0.01, hypot(context.ctm.a, context.ctm.b))
        let cell = min(minorX * hypot(transform.a, transform.b), minorY * hypot(transform.c, transform.d)) / pixel
        guard cell * CGFloat(subdivisions) >= 4 else { return }
        var drawMinor = cell >= 6
        let dots = !["solid", "dotted"].contains(state.pageGridStyle)
        func positions() -> (x: [CGFloat], y: [CGFloat]) {
            (locations(from: visible.minX, through: visible.maxX, origin: origin.x, step: drawMinor ? minorX : width),
             locations(from: visible.minY, through: visible.maxY, origin: origin.y, step: drawMinor ? minorY : height))
        }
        var points = positions()
        if drawMinor, (dots ? points.x.count * points.y.count > 8000 : points.x.count + points.y.count > 800) {
            drawMinor = false; points = positions()
        }
        func major(_ value: CGFloat, origin: CGFloat, step: CGFloat) -> Bool {
            !drawMinor || abs(((value-origin)/step).rounded().truncatingRemainder(dividingBy: CGFloat(subdivisions))) < 0.001
        }
        let color = ReaderTheme.color(state.pageGridColor).cgColor
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: visible.applying(transform)); context.setFillColor(color); context.setStrokeColor(color)
        if dots {
            for y in points.y {
                let yMajor = major(y, origin: origin.y, step: minorY)
                for x in points.x {
                    let point = CGPoint(x: x, y: y).applying(transform)
                    let size = (yMajor && major(x, origin: origin.x, step: minorX) ? 3 : 1) * pixel
                    context.fill(CGRect(x: point.x-size/2, y: point.y-size/2, width: size, height: size))
                }
            }
        } else {
            func stroke(_ start: CGPoint, _ end: CGPoint, major: Bool) {
                context.setLineWidth((major && state.pageGridStyle == "solid" ? 2 : 1) * pixel)
                context.setLineDash(phase: 0, lengths: !major && state.pageGridStyle == "dotted" ? [pixel, 2*pixel] : [])
                context.move(to: start.applying(transform)); context.addLine(to: end.applying(transform)); context.strokePath()
            }
            for x in points.x { stroke(CGPoint(x: x, y: visible.minY), CGPoint(x: x, y: visible.maxY), major: major(x, origin: origin.x, step: minorX)) }
            for y in points.y { stroke(CGPoint(x: visible.minX, y: y), CGPoint(x: visible.maxX, y: y), major: major(y, origin: origin.y, step: minorY)) }
        }
    }

    static func checkerboard(in context: CGContext, rect: CGRect) {
        let visible = context.boundingBoxOfClipPath.intersection(rect)
        guard !visible.isNull, !visible.isEmpty else { return }
        let step = 8 / max(0.01, hypot(context.ctm.a, context.ctm.b))
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(visible)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        for y in locations(from: visible.minY, through: visible.maxY, origin: rect.minY, step: step) {
            for x in locations(from: visible.minX, through: visible.maxX, origin: rect.minX, step: step) {
                let row = Int(((y-rect.minY)/step).rounded()), column = Int(((x-rect.minX)/step).rounded())
                if (row+column) % 2 != 0 { context.fill(CGRect(x: x, y: y, width: step, height: step)) }
            }
        }
    }
}
#endif
