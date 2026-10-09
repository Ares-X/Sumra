#if os(macOS)
import AppKit
import SumraCore

// A color well may normalize a transparent imported color for display. Only
// its user action writes back a color; opening or saving the dialog retains the
// PDF value. Clear is explicit on every supported macOS version.
@MainActor
final class PDFAnnotationColorControl: NSObject {
    let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 90, height: 25))
    let view: NSView
    private(set) var color: NSColor

    init(_ color: NSColor, allowsClear: Bool) {
        self.color = color
        let clear = NSButton(title: L("Clear"), target: nil, action: nil)
        view = allowsClear ? NSStackView(views: [well, clear]) : well
        super.init()
        well.colorWellStyle = .minimal
        well.color = color
        well.target = self
        well.action = #selector(changeColor(_:))
        clear.target = self
        clear.action = #selector(clearColor(_:))
    }

    @objc private func changeColor(_ sender: NSColorWell) { color = sender.color }
    @objc private func clearColor(_ sender: NSButton) {
        color = .clear
        well.color = .clear
    }
}

// One value model and AppKit dialog for the live MuPDF document.
// Native edits remain setters on the existing document, in its caller's journal.
@MainActor
struct PDFAnnotationProperties: Equatable {
    var contents: String
    var color: NSColor
    var borderWidth: CGFloat
    var fontSize: CGFloat?
    var fontColor: NSColor?
    var bounds: NSRect
    var url: URL?
    var author: String
    var opacity: CGFloat
    var interiorColor: NSColor?
    var icon: String
    var fontFamily: String?
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var alignment: Int
    var startStyle: String
    var endStyle: String
    var vertices: [CGFloat]

    mutating func apply(_ preset: PDFAnnotationPreset, type: String) {
        func color(_ value: UInt32) -> NSColor { value == .max ? .clear : ReaderTheme.color(value) }
        if let value = preset.color {
            if type == "FreeText" { fontColor = value == .max ? .black : color(value) }
            else {
                self.color = color(value)
                if value != .max { opacity = 1 }
                else if Self.isTextMarkup(type) { opacity = 0 }
            }
        }
        if type == "FreeText" {
            if let value = preset.bgColor { self.color = color(value) }
            if let size = preset.textSize { fontSize = CGFloat(size > 0 ? size : 12) }
            if let value = preset.alignment { alignment = ["left", "center", "right"].firstIndex(of: value.lowercased()) ?? 0 }
        }
        if let value = preset.interiorColor, ["Circle", "Line", "PolyLine", "Polygon", "Square"].contains(type) {
            interiorColor = value == .max ? nil : color(value)
        }
        if let value = preset.opacity { opacity = CGFloat(min(100, max(0, value))) / 100 }
        if let value = preset.borderWidth, ["FreeText", "Ink", "Line", "Square", "Circle", "Polygon", "PolyLine"].contains(type) {
            borderWidth = CGFloat(value)
        }
    }

    // Annotation.cpp's explicit subtype lists keep controls and setters aligned.
    static func supportsBorder(_ type: String) -> Bool { ["FreeText", "Ink", "Line", "Square", "Circle", "Polygon", "PolyLine"].contains(type) }
    static func supportsInterior(_ type: String) -> Bool { ["Circle", "Line", "PolyLine", "Polygon", "Square"].contains(type) }
    static func supportsIcon(_ type: String) -> Bool { ["Text", "Stamp", "FileAttachment", "Sound"].contains(type) }
    static func supportsColor(_ type: String) -> Bool { supportsBorder(type) || isTextMarkup(type) || ["Stamp", "Text", "FileAttachment", "Sound", "Caret"].contains(type) }
    static func supportsOpacity(_ type: String) -> Bool { supportsColor(type) && type != "Sound" || type == "Redact" }
    static func isTextMarkup(_ type: String) -> Bool { ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(type) }
    static func canMove(_ type: String) -> Bool {
        ["Text", "FreeText", "Square", "Circle", "Redact", "Stamp", "Caret", "FileAttachment", "Sound", "Movie", "3D", "RichMedia", "Line", "Polygon", "PolyLine", "Ink"].contains(type)
    }
    static func canResize(_ type: String) -> Bool { canMove(type) && !["Text", "Caret", "FileAttachment", "Sound", "Ink"].contains(type) }
    private static let lineStyles = ["None", "Square", "Circle", "Diamond", "OpenArrow", "ClosedArrow", "Butt", "ROpenArrow", "RClosedArrow", "Slash"]
    private static func lineStyle(_ value: Int32?) -> String { value.flatMap { lineStyles.indices.contains(Int($0)) ? lineStyles[Int($0)] : nil } ?? "None" }
    private static func color(_ values: [Double]) -> NSColor? {
        guard values.count == 3 else { return nil }
        return NSColor(deviceRed: CGFloat(values[0]), green: CGFloat(values[1]), blue: CGFloat(values[2]), alpha: 1)
    }
    private static func rgb(_ color: NSColor?) -> SIMD3<Float>? {
        guard let color = color?.usingColorSpace(.deviceRGB), color.alphaComponent > 0 else { return nil }
        return SIMD3(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
    }
    private static func fontFamily(_ font: String) -> String {
        ["Cour": "Courier", "Helv": "Helvetica", "TiRo": "Times"][font] ?? (font.isEmpty ? "Helvetica" : font)
    }
    private var fontStyle: Int32 { (bold ? 1 : 0) | (italic ? 2 : 0) | (underline ? 4 : 0) }
    private var textAppearance: PDFAnnotationEdit {
        let font = ["Courier": "Cour", "Helvetica": "Helv", "Times": "TiRo"][fontFamily ?? "Helvetica"] ?? "Helv"
        return .textAppearance(font: font, size: Float(fontSize ?? 12), color: Self.rgb(fontColor) ?? .zero, alignment: Int32(alignment))
    }

    // Diff only edited properties: untouched imported colors, border dashes and
    // custom appearances stay in the live object instead of being rewritten.
    func edits(from source: PDFAnnotationSnapshot) throws -> [PDFAnnotationEdit] {
        let initial = Self(source), type = source.type
        var edits = [PDFAnnotationEdit]()
        if contents != initial.contents { edits.append(.contents(contents)) }
        if author != initial.author { edits.append(.author(author)) }
        if icon != initial.icon, Self.supportsIcon(type) { edits.append(.icon(icon)) }
        if Self.supportsColor(type), color != initial.color { edits.append(.color(Self.rgb(color), interior: false)) }
        if Self.supportsInterior(type), interiorColor != initial.interiorColor { edits.append(.color(Self.rgb(interiorColor), interior: true)) }
        // SetColor's no-color sentinel must really hide text markup; other
        // types keep their fill/text visible. An explicit opacity wins last.
        var alpha = opacity
        if color != initial.color, opacity == initial.opacity {
            if color.alphaComponent > 0 { alpha = color.alphaComponent }
            else if Self.isTextMarkup(type) { alpha = 0 }
        }
        if Self.supportsOpacity(type), alpha != initial.opacity { edits.append(.opacity(Float(alpha))) }
        if Self.supportsBorder(type), borderWidth != initial.borderWidth {
            edits.append(.border(width: Float(borderWidth), style: source.borderStyle, dash: source.dash))
        }
        if type == "FreeText" {
            if fontSize != initial.fontSize || fontColor != initial.fontColor || alignment != initial.alignment { edits.append(textAppearance) }
            if fontFamily != initial.fontFamily || fontStyle != initial.fontStyle {
                edits.append(.textStyle(family: fontFamily ?? "Helvetica", style: fontStyle))
            }
        }
        let geometryChanged = bounds != initial.bounds
        if geometryChanged {
            guard Self.canMove(type), Self.canResize(type) || bounds.size == initial.bounds.size else {
                throw ReadError("This annotation's geometry cannot be resized")
            }
        }
        func point(_ values: [Double]) throws -> CGPoint {
            guard values.count == 2 else { throw ReadError("Invalid annotation points") }
            let point = CGPoint(x: values[0], y: values[1])
            guard geometryChanged else { return point }
            guard initial.bounds.width > 0, initial.bounds.height > 0 else { throw ReadError("Invalid annotation bounds") }
            return CGPoint(x: bounds.minX + (point.x - initial.bounds.minX) * bounds.width / initial.bounds.width,
                           y: bounds.minY + (point.y - initial.bounds.minY) * bounds.height / initial.bounds.height)
        }
        if type == "Line", geometryChanged || startStyle != initial.startStyle || endStyle != initial.endStyle {
            guard source.line.count == 2 else { throw ReadError("Invalid annotation line") }
            edits.append(.line(from: try point(source.line[0]), to: try point(source.line[1]),
                start: Int32(Self.lineStyles.firstIndex(of: startStyle) ?? 0), end: Int32(Self.lineStyles.firstIndex(of: endStyle) ?? 0)))
        } else if ["Polygon", "PolyLine"].contains(type), geometryChanged || vertices != initial.vertices {
            guard vertices.count >= (type == "Polygon" ? 6 : 4), vertices.count.isMultiple(of: 2), vertices.allSatisfy(\.isFinite) else {
                throw ReadError("Invalid annotation vertices")
            }
            edits.append(.vertices(try stride(from: 0, to: vertices.count, by: 2).map { try point([Double(vertices[$0]), Double(vertices[$0+1])]) }))
        } else if type == "Redact", !source.quads.isEmpty, geometryChanged {
            edits.append(.quads(try source.quads.map { quad in
                guard quad.count == 4 else { throw ReadError("Invalid annotation quadrilateral") }
                return .init(upperLeft: try point(quad[0]), upperRight: try point(quad[1]),
                             lowerLeft: try point(quad[2]), lowerRight: try point(quad[3]))
            }))
        } else if geometryChanged {
            if type == "Ink" { edits.append(.move(CGSize(width: bounds.minX - initial.bounds.minX, height: bounds.minY - initial.bounds.minY))) }
            else { edits.append(.rect(bounds)) }
        }
        if type == "PolyLine", startStyle != initial.startStyle || endStyle != initial.endStyle {
            edits.append(.lineEnds(start: Int32(Self.lineStyles.firstIndex(of: startStyle) ?? 0),
                                   end: Int32(Self.lineStyles.firstIndex(of: endStyle) ?? 0)))
        }
        return edits
    }

    static func edits(for preset: PDFAnnotationPreset?, type: String, selectedText: String? = nil) throws -> [PDFAnnotationEdit] {
        guard let preset else { return [] }
        try preset.validate()
        // MuPDF's create defaults; emit only explicit preset properties.
        var properties = Self(contents: "", color: .clear, borderWidth: 0, fontSize: type == "FreeText" ? 12 : nil,
            fontColor: .black, bounds: .zero, url: nil, author: "", opacity: 1, interiorColor: nil, icon: "",
            fontFamily: "Helvetica", bold: false, italic: false, underline: false, alignment: 0,
            startStyle: "None", endStyle: "None", vertices: [])
        properties.apply(preset, type: type)
        var edits = [PDFAnnotationEdit]()
        if preset.setContent == true, let selectedText { edits.append(.contents(selectedText)) }
        if type == "FreeText" {
            if preset.color != nil || preset.textSize != nil || preset.alignment != nil { edits.append(properties.textAppearance) }
            if preset.bgColor != nil { edits.append(.color(Self.rgb(properties.color), interior: false)) }
        } else if preset.color != nil, supportsColor(type) { edits.append(.color(Self.rgb(properties.color), interior: false)) }
        if preset.interiorColor != nil, supportsInterior(type) { edits.append(.color(Self.rgb(properties.interiorColor), interior: true)) }
        if preset.borderWidth != nil, supportsBorder(type) { edits.append(.border(width: Float(properties.borderWidth), style: 0, dash: [])) }
        if supportsOpacity(type), preset.opacity != nil || preset.color != nil && type != "FreeText" {
            edits.append(.opacity(Float(properties.opacity)))
        }
        return edits
    }

    static func text(_ initial: String, isCurrent: () -> Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = L("Annotation")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 140)
        guard let text = scroll.documentView as? NSTextView else { return nil }
        text.isRichText = false
        text.font = .systemFont(ofSize: 14)
        text.string = initial
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn, isCurrent() else { return nil }
        return text.string
    }

    func edit(type: String, flags: Int, isCurrent: () -> Bool) -> Self? {
        let initial = self
        let nativeLink = type == "Link"
        let alert = NSAlert()
        alert.messageText = L("Edit Annotation")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        let scroll = NSTextView.scrollableTextView()
        scroll.frame.size = NSSize(width: 350, height: 120)
        guard let text = scroll.documentView as? NSTextView else { return nil }
        text.isRichText = false
        text.font = .systemFont(ofSize: 14)
        text.string = initial.contents
        text.isEditable = flags & 512 == 0
        let color = PDFAnnotationColorControl(initial.color, allowsClear: true)
        let border = NSTextField(string: String(Double(initial.borderWidth)))
        let x = NSTextField(string: String(Double(initial.bounds.minX)))
        let y = NSTextField(string: String(Double(initial.bounds.minY)))
        let width = NSTextField(string: String(Double(initial.bounds.width)))
        let height = NSTextField(string: String(Double(initial.bounds.height)))
        x.isEnabled = Self.canMove(type) || nativeLink
        y.isEnabled = x.isEnabled
        width.isEnabled = Self.canResize(type) || nativeLink
        height.isEnabled = width.isEnabled
        let link = NSTextField(string: initial.url?.absoluteString ?? "")
        let author = NSTextField(string: initial.author)
        let opacity = NSTextField(string: String(Double(initial.opacity)))
        let interior = PDFAnnotationColorControl(initial.interiorColor ?? .clear, allowsClear: true)
        let icon = NSTextField(string: initial.icon)
        let fontFamily = NSComboBox(); fontFamily.addItems(withObjectValues: NSFontManager.shared.availableFontFamilies); fontFamily.stringValue = initial.fontFamily ?? "Helvetica"
        let bold = NSButton(checkboxWithTitle: L("Bold"), target: nil, action: nil); bold.state = initial.bold ? .on : .off
        let italic = NSButton(checkboxWithTitle: L("Italic"), target: nil, action: nil); italic.state = initial.italic ? .on : .off
        let underline = NSButton(checkboxWithTitle: L("Underline"), target: nil, action: nil); underline.state = initial.underline ? .on : .off
        let alignment = NSPopUpButton(); alignment.addItems(withTitles: ["Left", "Center", "Right"].map(L)); alignment.selectItem(at: min(2, max(0, initial.alignment)))
        let lineStyles = Self.lineStyles
        let startStyle = NSPopUpButton(); startStyle.addItems(withTitles: lineStyles.map(L)); startStyle.selectItem(at: lineStyles.firstIndex(of: initial.startStyle) ?? 0)
        let endStyle = NSPopUpButton(); endStyle.addItems(withTitles: lineStyles.map(L)); endStyle.selectItem(at: lineStyles.firstIndex(of: initial.endStyle) ?? 0)
        let vertices = NSTextField(string: initial.vertices.map { String(Double($0)) }.joined(separator: ", "))
        var rows: [[NSView]] = [[NSTextField(labelWithString: L("Annotation contents")), scroll],
            [NSTextField(labelWithString: L("Author")), author]]
        if nativeLink { rows = [] }
        if Self.supportsColor(type) {
            rows.append([NSTextField(labelWithString: L(initial.fontSize == nil ? "Color" : "Background")), color.view])
        }
        if Self.supportsOpacity(type) { rows.append([NSTextField(labelWithString: L("Opacity (0–1)")), opacity]) }
        let hasBorder = Self.supportsBorder(type)
        let hasInterior = Self.supportsInterior(type)
        let hasIcon = Self.supportsIcon(type)
        if hasInterior { rows.append([NSTextField(labelWithString: L("Fill (clear for none)")), interior.view]) }
        if hasIcon { rows.append([NSTextField(labelWithString: L("Icon / stamp name")), icon]) }
        if hasBorder { rows.append([NSTextField(labelWithString: L("Border width")), border]) }
        if type == "Line" || type == "PolyLine" {
            rows += [[NSTextField(labelWithString: L("Line start")), startStyle], [NSTextField(labelWithString: L("Line end")), endStyle]]
        }
        if !initial.vertices.isEmpty { rows.append([NSTextField(labelWithString: L("Vertices (x, y pairs)")), vertices]) }
        if type == "Link" { rows.append([NSTextField(labelWithString: L("Link URL")), link]) }
        let fontSize = NSTextField(string: String(Double(initial.fontSize ?? 14)))
        let fontColor = PDFAnnotationColorControl(initial.fontColor ?? .black, allowsClear: false)
        if let size = initial.fontSize {
            fontSize.stringValue = String(Double(size))
            rows.append([NSTextField(labelWithString: L("Text size")), fontSize])
            rows.append([NSTextField(labelWithString: L("Text color")), fontColor.view])
            rows.append([NSTextField(labelWithString: L("Font family")), fontFamily])
            rows.append([NSTextField(labelWithString: L("Font style")), NSStackView(views: [bold, italic, underline])])
            rows.append([NSTextField(labelWithString: L("Alignment")), alignment])
        }
        rows += [[NSTextField(labelWithString: L("X (PDF points)")), x],
                 [NSTextField(labelWithString: L("Y (PDF points)")), y],
                 [NSTextField(labelWithString: L("Width")), width],
                 [NSTextField(labelWithString: L("Height")), height]]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 350).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let propertiesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: min(540, CGFloat(rows.count) * 34 + 100)))
        propertiesScroll.hasVerticalScroller = true
        grid.frame.size = grid.fittingSize
        propertiesScroll.documentView = grid
        alert.accessoryView = propertiesScroll
        alert.window.initialFirstResponder = nativeLink ? link : text
        func number(_ field: NSTextField) -> CGFloat? {
            guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
            return CGFloat(value)
        }
        while alert.runModal() == .alertFirstButtonReturn {
            guard isCurrent() else { return nil }
            guard let px = number(x), let py = number(y), let w = number(width), let h = number(height),
                  let lineWidth = number(border), let size = number(fontSize), let alpha = number(opacity), w > 0, h > 0,
                  lineWidth >= 0, size > 0, (0...1).contains(alpha) else {
                alert.informativeText = L("Enter finite coordinates, positive dimensions and text size, and a nonnegative border width.")
                continue
            }
            var properties = initial
            if type == "Link", link.stringValue != (initial.url?.absoluteString ?? "") {
                let value = link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, let url = URL(string: value),
                      nativeLink || ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                    alert.informativeText = L("Enter a valid link")
                    continue
                }
                properties.url = url
            }
            properties.contents = text.string
            properties.author = author.stringValue
            properties.opacity = alpha
            if hasInterior { properties.interiorColor = interior.color.alphaComponent == 0 ? nil : interior.color }
            if hasIcon { properties.icon = icon.stringValue }
            properties.startStyle = lineStyles[startStyle.indexOfSelectedItem]; properties.endStyle = lineStyles[endStyle.indexOfSelectedItem]
            if !initial.vertices.isEmpty {
                let parts = vertices.stringValue.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                let points = parts.compactMap { Double($0) }.filter(\.isFinite)
                guard points.count == parts.count, points.count >= (type == "Polygon" ? 6 : 4), points.count.isMultiple(of: 2) else {
                    alert.informativeText = String(format: L("Enter at least %d finite x, y pairs."), type == "Polygon" ? 3 : 2)
                    continue
                }
                properties.vertices = points.map { CGFloat($0) }
            }
            properties.color = color.color
            if hasBorder { properties.borderWidth = lineWidth }
            properties.bounds = NSRect(x: px, y: py, width: w, height: h)
            if initial.fontSize != nil {
                properties.fontSize = size; properties.fontColor = fontColor.color; properties.fontFamily = fontFamily.stringValue
                properties.bold = bold.state == .on; properties.italic = italic.state == .on; properties.underline = underline.state == .on
                properties.alignment = alignment.indexOfSelectedItem
            }
            return properties
        }
        return nil
    }
}

extension PDFAnnotationProperties {
    init(_ link: PDFLinkSnapshot) {
        self.init(contents: "", color: .clear, borderWidth: 0, fontSize: nil, fontColor: nil,
                  bounds: link.bounds, url: link.actions.first?.uri.flatMap(URL.init(string:)), author: "", opacity: 1,
                  interiorColor: nil, icon: "", fontFamily: nil, bold: false, italic: false, underline: false,
                  alignment: 0, startStyle: "None", endStyle: "None", vertices: [])
    }
    init(_ annotation: PDFAnnotationSnapshot) {
        contents = annotation.contents; author = annotation.author; icon = annotation.icon
        bounds = annotation.copyBounds; url = nil
        color = Self.color(annotation.color) ?? .clear
        interiorColor = Self.color(annotation.interiorColor)
        opacity = CGFloat(annotation.opacity); borderWidth = CGFloat(annotation.borderWidth)
        fontSize = annotation.type == "FreeText" ? CGFloat(annotation.fontSize) : nil
        fontColor = annotation.type == "FreeText" ? Self.color(annotation.textColor) ?? .black : nil
        fontFamily = annotation.type == "FreeText" ? annotation.fontFamily ?? Self.fontFamily(annotation.font) : nil
        let style = annotation.fontStyle ?? 0
        bold = style & 1 != 0; italic = style & 2 != 0; underline = style & 4 != 0
        alignment = Int(annotation.alignment)
        startStyle = Self.lineStyle(annotation.lineEnds.first)
        endStyle = Self.lineStyle(annotation.lineEnds.last)
        vertices = annotation.vertices.flatMap { $0.map { CGFloat($0) } }
    }
}
#endif
