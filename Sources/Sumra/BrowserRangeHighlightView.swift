#if os(macOS)
import AppKit

// Old WebKit supplies visible Range rectangles instead of Custom Highlights.
// This view only paints them; DOM, matching, selection and scrolling stay in WebKit.
@MainActor
final class BrowserRangeHighlightView: NSView {
    fileprivate struct Shape {
        let points: [CGPoint]
        let bounds: CGRect
        static func rectangle(_ rect: CGRect) -> Shape {
            Shape(points: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)], bounds: rect)
        }
    }

    struct Rectangles {
        fileprivate let findShapes: [Shape]
        fileprivate let currentShapes: [Shape]
        fileprivate let speechShapes: [Shape]
        var find: [CGRect] { findShapes.map(\.bounds) }
        var current: [CGRect] { currentShapes.map(\.bounds) }
        var speech: [CGRect] { speechShapes.map(\.bounds) }
        var isEmpty: Bool { findShapes.isEmpty && currentShapes.isEmpty && speechShapes.isEmpty }
        init(find: [CGRect], current: [CGRect], speech: [CGRect]) {
            self.init(findShapes: find.map(Shape.rectangle), currentShapes: current.map(Shape.rectangle),
                      speechShapes: speech.map(Shape.rectangle))
        }
        fileprivate init(findShapes: [Shape], currentShapes: [Shape], speechShapes: [Shape]) {
            self.findShapes = findShapes; self.currentShapes = currentShapes; self.speechShapes = speechShapes
        }
    }

    var rectangles = Rectangles(find: [], current: [], speech: []) {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityIsIgnored() -> Bool { true }

    static func rectangles(_ body: [String: Any], zoom: CGFloat, size: CGSize) -> Rectangles {
        let viewport = CGRect(origin: .zero, size: size)
        func group(_ name: String) -> [Shape] {
            guard zoom.isFinite, zoom > 0, let rows = body[name] as? [Any] else { return [] }
            // Bound malformed bridge input independently of the search matcher.
            return rows.prefix(5000).compactMap { row in
                guard let numbers = row as? [NSNumber], numbers.count == 4 || numbers.count == 8,
                      numbers.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else { return nil }
                let values = numbers.map { CGFloat($0.doubleValue) * zoom }
                guard values.allSatisfy(\.isFinite) else { return nil }
                if values.count == 4 {
                    guard values[2] > 0, values[3] > 0,
                          (values[0] + values[2]).isFinite, (values[1] + values[3]).isFinite else { return nil }
                    let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]).intersection(viewport)
                    return rect.isNull || rect.isEmpty ? nil : Shape.rectangle(rect)
                }
                var points = stride(from: 0, to: 8, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
                let origin = points[0]
                let area = (1..<3).reduce(CGFloat.zero) { area, i in
                    area + (points[i].x - origin.x) * (points[i + 1].y - origin.y)
                         - (points[i].y - origin.y) * (points[i + 1].x - origin.x)
                }
                guard area.isFinite, area != 0 else { return nil }
                // Clip before constructing the native path, keeping its coordinates
                // bounded even when a transformed frame crosses the viewport.
                for edge in 0..<4 {
                    guard !points.isEmpty else { return nil }
                    let horizontal = edge < 2, boundary = edge == 0 ? viewport.minX
                        : edge == 1 ? viewport.maxX : edge == 2 ? viewport.minY : viewport.maxY
                    func coordinate(_ point: CGPoint) -> CGFloat { horizontal ? point.x : point.y }
                    func inside(_ point: CGPoint) -> Bool {
                        edge == 0 || edge == 2 ? coordinate(point) >= boundary : coordinate(point) <= boundary
                    }
                    var clipped = [CGPoint](), previous = points.last!
                    for point in points {
                        if inside(previous) != inside(point) {
                            let t = (boundary - coordinate(previous)) / (coordinate(point) - coordinate(previous))
                            clipped.append(CGPoint(x: previous.x + (point.x - previous.x) * t,
                                                   y: previous.y + (point.y - previous.y) * t))
                        }
                        if inside(point) { clipped.append(point) }
                        previous = point
                    }
                    points = clipped
                }
                guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
                let xs = points.map(\.x), ys = points.map(\.y)
                let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                return rect.isEmpty ? nil : Shape(points: points, bounds: rect)
            }
        }
        return Rectangles(findShapes: group("find"), currentShapes: group("current"), speechShapes: group("speech"))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Screen aids must never become printed/exported document content.
        guard NSPrintOperation.current == nil else { return }
        func fill(_ shapes: [Shape], color: NSColor) {
            color.setFill()
            for shape in shapes where shape.bounds.intersects(dirtyRect) {
                let path = NSBezierPath()
                path.move(to: shape.points[0])
                for point in shape.points.dropFirst() { path.line(to: point) }
                path.close(); path.fill()
            }
        }
        fill(rectangles.findShapes, color: NSColor(calibratedRed: 1, green: 0.9, blue: 0, alpha: 0.28))
        fill(rectangles.currentShapes, color: NSColor(calibratedRed: 1, green: 0.5, blue: 0, alpha: 0.35))
        fill(rectangles.speechShapes, color: NSColor(calibratedRed: 1, green: 0.9, blue: 0, alpha: 0.28))
    }
}
#endif
