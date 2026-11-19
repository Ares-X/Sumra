#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard (2...3).contains(arguments.count) else {
    fputs("Usage: rasterize-icon.swift <source.png> <output.iconset> [document-label]\n", stderr)
    exit(2)
}

let source = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)

guard let image = NSImage(contentsOf: source) else {
    fputs("Unable to load icon source: \(source.path)\n", stderr)
    exit(1)
}

let documentLabel = arguments.dropFirst(2).first

try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawDocument(label: String, pixels: Int, context: CGContext) {
    let unit = CGFloat(pixels) / 100
    context.saveGState()
    context.scaleBy(x: unit, y: unit)
    defer { context.restoreGState() }

    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: 20, y: 6))
    paper.line(to: NSPoint(x: 80, y: 6))
    paper.curve(to: NSPoint(x: 85, y: 11), controlPoint1: NSPoint(x: 83, y: 6),
                controlPoint2: NSPoint(x: 85, y: 8))
    paper.line(to: NSPoint(x: 85, y: 71))
    paper.line(to: NSPoint(x: 63, y: 94))
    paper.line(to: NSPoint(x: 20, y: 94))
    paper.curve(to: NSPoint(x: 15, y: 89), controlPoint1: NSPoint(x: 17, y: 94),
                controlPoint2: NSPoint(x: 15, y: 92))
    paper.line(to: NSPoint(x: 15, y: 11))
    paper.curve(to: NSPoint(x: 20, y: 6), controlPoint1: NSPoint(x: 15, y: 8),
                controlPoint2: NSPoint(x: 17, y: 6))
    paper.close()

    let white = NSColor(white: 0.99, alpha: 1)
    let paleGray = NSColor(white: 0.89, alpha: 1)
    NSGradient(starting: paleGray, ending: white)?.draw(in: paper, angle: 90)

    let showLabel = pixels >= 32
    let badgeSize: CGFloat = showLabel ? 65 : 72
    let badgeY: CGFloat = showLabel ? 19 : 13
    image.draw(
        in: NSRect(x: (100 - badgeSize) / 2, y: badgeY, width: badgeSize, height: badgeSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 63, y: 94))
    fold.line(to: NSPoint(x: 63, y: 76))
    fold.curve(to: NSPoint(x: 68, y: 71), controlPoint1: NSPoint(x: 63, y: 73),
               controlPoint2: NSPoint(x: 65, y: 71))
    fold.line(to: NSPoint(x: 85, y: 71))
    fold.close()
    NSGradient(starting: NSColor(white: 0.71, alpha: 1), ending: white)?.draw(in: fold, angle: 95)
    NSColor(white: 0.48, alpha: 0.8).setStroke()
    paper.lineWidth = max(1, 0.6 / unit)
    paper.stroke()

    if showLabel {
        let font = NSFont.systemFont(ofSize: 14, weight: .bold)
        let width = (label as NSString).size(withAttributes: [.font: font]).width
        let fittedFont = NSFont.systemFont(ofSize: font.pointSize * min(1, 62 / width), weight: .bold)
        let title = NSAttributedString(string: label, attributes: [
            .font: fittedFont,
            .foregroundColor: NSColor(white: 0.22, alpha: 1)
        ])
        let bounds = title.size()
        title.draw(at: NSPoint(x: (100 - bounds.width) / 2, y: 10))
    }
}

func writePNG(name: String, pixels: Int) throws {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep)
    else {
        throw NSError(domain: "SumraIconRasterizer", code: 1)
    }

    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    if let documentLabel {
        drawDocument(label: documentLabel, pixels: pixels, context: context.cgContext)
    } else {
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SumraIconRasterizer", code: 2)
    }
    try data.write(to: output.appendingPathComponent(name))
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

// Finder and the titlebar use small representations. Keep the Retina 128-point
// version for document icons, with the full icon set reserved for the app tile.
for (name, pixels) in specs where documentLabel == nil || pixels <= 256 {
    try writePNG(name: name, pixels: pixels)
}
