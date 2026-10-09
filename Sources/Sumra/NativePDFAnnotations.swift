#if os(macOS)
import AppKit
import SumraCore
import UniformTypeIdentifiers

@MainActor
enum NativePDFSelection {
    case annotation(page: Int, PDFAnnotationSnapshot)
    case link(page: Int, PDFLinkSnapshot)
    var page: Int { switch self { case .annotation(let page, _), .link(let page, _): return page } }
    var id: Int32 { switch self { case .annotation(_, let value): return value.id; case .link(_, let value): return value.id } }
    var bounds: CGRect { switch self { case .annotation(_, let value): return value.copyBounds; case .link(_, let value): return value.bounds } }
    var type: String { switch self { case .annotation(_, let value): return value.type; case .link(_, let value): return value.type } }
    var editable: Bool {
        switch self {
        case .annotation(_, let value): return NativePDFAnnotations.editable(value)
        case .link(_, let value): return value.type == "Link" && value.flags & (64 | 128) == 0
        }
    }
    var movable: Bool { editable && (type == "Link" || PDFAnnotationProperties.canMove(type)) }
    var resizable: Bool { editable && (type == "Link" || PDFAnnotationProperties.canResize(type)) }
}

// AnnotPlacement.cpp (Sumatra 012d997f): preview point, line and polygon
// placement in page coordinates; only the completed gesture edits the PDF.
@MainActor
final class NativePDFAnnotationTool {
    let kind: String
    let type: String
    let preset: PDFAnnotationPreset?
    var size = CGSize(width: 24, height: 24)
    var edits = [PDFAnnotationEdit]()
    var uri: String?
    var temporary: TemporaryDirectory?
    weak var host: NSView?
    var page: Int?
    var points = [CGPoint]()
    var end: CGPoint?
    var finishes = false

    init(_ kind: String, type: String = "", preset: PDFAnnotationPreset? = nil) {
        self.kind = kind; self.type = type; self.preset = preset
    }
    var isPoint: Bool { ["note", "freeText", "stamp", "caret", "attachment", "image", "pasteImage"].contains(kind) }
    var isPoly: Bool { kind == "polygon" || kind == "polyline" }
    var isPlacement: Bool { !["highlightBrush", "editMode", "eraser"].contains(kind) }
    var isPersistent: Bool { ["ink", "highlightBrush", "editMode", "eraser"].contains(kind) }
    func clearPreview() {
        host?.needsDisplay = true
        if let host { host.window?.invalidateCursorRects(for: host) }
        host = nil; page = nil; points = []; end = nil; finishes = false
    }
    func use(_ view: NSView, page: Int) {
        if host !== view { host?.needsDisplay = true; host = view }
        self.page = page
    }
    func constrained(_ point: CGPoint, shift: Bool) -> CGPoint {
        guard shift, kind != "ink", let start = isPoly ? points.last : points.first else { return point }
        let dx = point.x - start.x, dy = point.y - start.y
        if isPoly || kind == "line" {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), length = hypot(dx, dy)
            return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
        }
        let length = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -length : length), y: start.y + (dy < 0 ? -length : length))
    }
    var bounds: CGRect? {
        guard let end else { return nil }
        if isPoint {
            return CGRect(x: end.x, y: end.y - (kind == "caret" ? size.height / 2 : 0), width: size.width, height: size.height)
        }
        let vertices = isPoly || kind == "ink" ? points + [end] : [points.first ?? end, end]
        guard let first = vertices.first else { return nil }
        return vertices.dropFirst().reduce(CGRect(origin: first, size: .zero)) { box, point in
            CGRect(x: min(box.minX, point.x), y: min(box.minY, point.y),
                   width: max(box.maxX, point.x) - min(box.minX, point.x), height: max(box.maxY, point.y) - min(box.minY, point.y))
        }
    }
    func creation(scale: CGFloat) -> PDFAnnotationCreation? {
        guard let page, var bounds else { return nil }
        if isPoly, points.count < (kind == "polygon" ? 3 : 2) { return nil }
        if kind == "ink", points.isEmpty { return nil }
        if kind == "line", points.isEmpty || hypot(bounds.width, bounds.height) * scale < 2 { return nil }
        if !isPoint && !isPoly && kind != "line" && kind != "ink", min(bounds.width, bounds.height) * scale < 4 { return nil }
        var edits = edits
        if kind == "line", let first = points.first, let end { edits.append(.line(from: first, to: end, start: 0, end: 0)) }
        else if isPoly { edits.append(.vertices(points)) }
        else if kind == "ink" { edits.append(.ink([points])) }
        if isPoly || kind == "line" || kind == "ink" { bounds = bounds.insetBy(dx: -1, dy: -1) }
        return PDFAnnotationCreation(page: page, type: type, bounds: bounds, edits: edits)
    }
}

@MainActor
enum NativePDFAnnotations {
    // Annotation.cpp::InkStrokeHit: erase whole touched strokes, keeping
    // the remaining strokes in the same annotation and one undo operation.
    nonisolated static func strokeHit(_ points: [CGPoint], point: CGPoint, radius: CGFloat) -> Bool {
        guard var previous = points.first else { return false }
        for next in points {
            let dx = next.x-previous.x, dy = next.y-previous.y, length = dx*dx + dy*dy
            let t = length > 0 ? min(1, max(0, ((point.x-previous.x)*dx + (point.y-previous.y)*dy) / length)) : 0
            if hypot(point.x-previous.x-t*dx, point.y-previous.y-t*dy) <= radius { return true }
            previous = next
        }
        return false
    }
    nonisolated static func editable(_ annotation: PDFAnnotationSnapshot) -> Bool {
        annotation.type != "Widget" && annotation.type != "Popup" && annotation.flags & (64 | 128) == 0
    }
    static func editSelected(state: ReaderState, pages: Pages) async throws {
        guard let selected = state.nativePDFSelection, state.canEditPDF else { return }
        let documentID = state.document?.id, revision = state.editRevision
        let current = { state.document?.id == documentID && state.nativePDF === pages && state.canEditPDF && state.editRevision == revision }
        switch selected {
        case .annotation:
            let annotations = try await pages.pdfAnnotations(selected.page)
            guard current(), let annotation = annotations.first(where: { $0.id == selected.id }), editable(annotation) else { return }
            guard let edited = PDFAnnotationProperties(annotation).edit(type: annotation.type, flags: annotation.flags, isCurrent: current) else { return }
            let edits = try edited.edits(from: annotation)
            guard current(), !edits.isEmpty else { return }
            try await pages.pdfEditAnnotation(page: selected.page, id: annotation.id, edits: edits)
        case .link:
            let links = try await pages.pdfLinks(selected.page)
            guard current(), let link = links.first(where: { $0.id == selected.id }), link.flags & (64 | 128) == 0 else { return }
            let initial = PDFAnnotationProperties(link)
            guard let edited = initial.edit(type: "Link", flags: link.flags, isCurrent: current), current(), edited != initial else { return }
            try await pages.pdfEditLink(page: selected.page, id: link.id, bounds: edited.bounds,
                                       uri: edited.url == initial.url ? nil : edited.url?.absoluteString)
        }
        guard state.document?.id == documentID else { return }
        try await refresh(page: selected.page, id: selected.id, link: selected.type == "Link", state: state, pages: pages)
    }
    static func refresh(page: Int, id: Int32, link: Bool = false, state: ReaderState, pages: Pages) async throws {
        let documentID = state.document?.id
        try await state.nativePDFDidChange(pages)
        let selected: NativePDFSelection?
        if link { selected = try await pages.pdfLinks(page).first(where: { $0.id == id }).map { .link(page: page, $0) } }
        else { selected = try await pages.pdfAnnotations(page).first(where: { $0.id == id }).map { .annotation(page: page, $0) } }
        guard state.nativePDF === pages, state.document?.id == documentID else { return }
        state.nativePDFSelection = selected
    }
    static func finish(_ items: [PDFAnnotationCreation], preset: PDFAnnotationPreset?, selectedText: String? = nil,
                       state: ReaderState, pages: Pages) async throws {
        guard state.nativePDF === pages, state.canEditPDF, !items.isEmpty else { return }
        let documentID = state.document?.id
        let ids = try await pages.pdfCreateAnnotations(items)
        guard state.document?.id == documentID, let last = ids.last, let item = items.last else { return }
        try await refresh(page: item.page, id: last, state: state, pages: pages)
        guard state.document?.id == documentID else { return }
        if preset?.copyToClipboard == true, state.nativePDFInfo?.permissions.copy == true, let selectedText {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string)
        }
        if preset?.openEdit == true {
            state.nativePDFAnnotationTool = NativePDFAnnotationTool("editMode")
            try await editSelected(state: state, pages: pages)
        }
    }
    // Returns true only when a selection was consumed by a completed mutation.
    static func perform(_ kind: String, preset: PDFAnnotationPreset?, selection: [Int: RasterSelection],
                        state: ReaderState, pages: Pages, pasteTarget: (page: Int, point: CGPoint)? = nil) async throws -> Bool {
        try preset?.validate()
        if kind == "copy" || kind == "cut" {
            _ = try await NativePDFClipboard.copy(state: state, pages: pages, cut: kind == "cut")
            return false
        }
        guard state.canEditPDF, state.nativePDFInfo?.permissions.annotate == true else { return false }
        if kind == "paste" {
            if let clipboard = NativePDFClipboard.current, let target = pasteTarget {
                try await clipboard.paste(state: state, pages: pages, page: target.page, at: target.point)
            }
            return false
        }
        let documentID = state.document?.id
        let current = { state.document?.id == documentID && state.nativePDF === pages && state.canEditPDF }
        if kind == "edit" { try await editSelected(state: state, pages: pages); return false }
        let type = ["highlight": "Highlight", "highlightBrush": "Highlight", "underline": "Underline", "strike": "StrikeOut",
                    "squiggly": "Squiggly", "note": "Text", "freeText": "FreeText", "ink": "Ink", "line": "Line",
                    "square": "Square", "circle": "Circle", "link": "Link", "caret": "Caret", "stamp": "Stamp",
                    "image": "Stamp", "pasteImage": "Stamp", "polygon": "Polygon", "polyline": "PolyLine",
                    "attachment": "FileAttachment", "redact": "Redact"][kind] ?? ""
        let tool = NativePDFAnnotationTool(kind, type: type, preset: preset)
        if tool.isPersistent {
            let active = state.nativePDFAnnotationTool
            if active?.kind == kind && active?.preset == preset { state.nativePDFAnnotationTool = nil; state.status = ""; return false }
            if kind == "ink" { tool.edits = [.color(SIMD3(1, 1, 0), interior: false), .opacity(0.4), .border(width: 3, style: 0, dash: [])] }
            tool.edits += try PDFAnnotationProperties.edits(for: preset, type: type)
        } else if PDFAnnotationProperties.isTextMarkup(type) || kind == "redact" && !selection.isEmpty {
            let text = selection.keys.sorted().compactMap { selection[$0]?.text }.joined(separator: "\n")
            guard !text.isEmpty || kind == "redact" else { state.status = L("Select text to annotate"); return false }
            let items = try selection.keys.sorted().compactMap { page -> PDFAnnotationCreation? in
                guard let selected = selection[page], !selected.bounds.isEmpty else { return nil }
                let quads: [PDFAnnotationEdit.Quad]
                if let original = selected.quads {
                    quads = original.map { quad in
                        func point(_ i: Int) -> CGPoint { CGPoint(x: quad[i][0], y: quad[i][1]) }
                        return .init(upperLeft: point(0), upperRight: point(1), lowerLeft: point(2), lowerRight: point(3))
                    }
                } else {
                    quads = selected.bounds.map { rect in
                        .init(upperLeft: CGPoint(x: rect.minX, y: rect.minY), upperRight: CGPoint(x: rect.maxX, y: rect.minY),
                              lowerLeft: CGPoint(x: rect.minX, y: rect.maxY), lowerRight: CGPoint(x: rect.maxX, y: rect.maxY))
                    }
                }
                return .init(page: page, type: type, bounds: selected.bounds.reduce(.null) { $0.union($1) },
                    edits: [.quads(quads)] + (try PDFAnnotationProperties.edits(for: preset, type: type, selectedText: text)))
            }
            try await finish(items, preset: preset, selectedText: text, state: state, pages: pages)
            return !items.isEmpty && current()
        } else {
            guard !type.isEmpty || kind == "replaceAttachment" else { return false }
            if kind == "note" || kind == "freeText" || kind == "link" {
                guard let text = PDFAnnotationProperties.text(kind == "link" ? "https://" : state.selectedText, isCurrent: current) else { return false }
                if kind == "link" {
                    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                          ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                        state.status = L("Enter an HTTP, HTTPS or mailto link"); return false
                    }
                    tool.uri = url.absoluteString
                } else {
                    let content = preset?.setContent == true ? state.selectedText : text
                    tool.edits.append(.contents(content))
                    if kind == "freeText" {
                        let requested = preset?.textSize ?? 12
                        let size = CGFloat(requested > 0 ? requested : 12), padding = CGFloat(max(0, preset?.borderWidth ?? 0)) * 2
                        let font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
                        let measured = (content as NSString).size(withAttributes: [.font: font])
                        tool.size = CGSize(width: measured.width * 1.02 + padding * 2 + 2, height: max(measured.height, size * 1.2) + padding * 2)
                    }
                }
            }
            if kind == "stamp" { tool.size = CGSize(width: 190, height: 50) }
            if kind == "caret" { tool.size = CGSize(width: 18, height: 15) }
            if kind == "attachment" { tool.size = CGSize(width: 16, height: 16) }
            var asset: URL?
            if ["image", "attachment", "replaceAttachment"].contains(kind) {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                if kind == "image" { panel.allowedContentTypes = [.image] }
                guard panel.runModal() == .OK, current(), let url = panel.url else { return false }
                asset = url
            } else if kind == "pasteImage" {
                guard let image = NSImage(pasteboard: .general), let data = image.tiffRepresentation else { state.status = L("Copy an image first"); return false }
                let temporary = try TemporaryDirectory(), url = temporary.url.appendingPathComponent("clipboard.tiff")
                try data.write(to: url); tool.temporary = temporary; asset = url
            }
            if let asset {
                if kind == "image" || kind == "pasteImage" {
                    guard let image = NSImage(contentsOf: asset), image.size.width > 0, image.size.height > 0 else { throw ReadError("Cannot read annotation image") }
                    tool.size = image.size
                    tool.edits.append(.stampImage(asset))
                } else {
                    let edit = PDFAnnotationEdit.attachment(asset, filename: asset.lastPathComponent, mime: UTType(filenameExtension: asset.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                    if kind == "replaceAttachment" {
                        guard case .annotation(let page, let annotation) = state.nativePDFSelection,
                              annotation.type == "FileAttachment", editable(annotation) else {
                            state.status = L("Select a file attachment"); return false
                        }
                        try await pages.pdfEditAnnotation(page: page, id: annotation.id, edits: [edit])
                        guard current() else { return false }
                        try await refresh(page: page, id: annotation.id, state: state, pages: pages)
                        return false
                    }
                    tool.edits += [edit, .contents(asset.lastPathComponent)]
                }
            }
            tool.edits += try PDFAnnotationProperties.edits(for: preset, type: type, selectedText: state.selectedText)
        }
        guard current() else { return false }
        state.nativePDFSelection = nil; state.nativePDFAnnotationTool = tool
        state.keyboardTextSelection = false; state.keyboardLinkFollowing = false
        state.status = L(tool.isPoint ? "Click to place; Escape to cancel" : tool.isPoly
            ? "Click vertices; double-click, right-click or Return to finish; Control-click to close; Shift snaps; Escape cancels"
            : kind == "line" ? "Click both line endpoints; Shift snaps; Escape cancels"
            : kind == "editMode" ? "Drag annotations or their corner handles; press Escape to finish"
            : kind == "highlightBrush" ? "Select text to highlight; press Escape to finish"
            : kind == "ink" ? "Draw on a page; press Escape to finish"
            : kind == "eraser" ? "Erase ink strokes; press Escape to finish"
            : "Drag or click opposite corners; Shift constrains proportions; Escape cancels")
        if let view = state.readerFocusView { view.window?.makeFirstResponder(view); view.window?.invalidateCursorRects(for: view) }
        return false
    }
}
#endif
