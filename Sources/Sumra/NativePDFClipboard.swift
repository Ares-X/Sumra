#if os(macOS)
import AppKit
import SumraCore

// Annotation.cpp::CopyAnnotation/PasteCopiedAnnotation: keep a small value
// snapshot, not a serialized document. A cut deletes only after a successful
// paste; same-document paste/delete shares one MuPDF journal operation.
@MainActor
final class NativePDFClipboard {
    static var current: NativePDFClipboard?
    let annotation: PDFAnnotationSnapshot
    let image: URL?
    private let temporary: TemporaryDirectory?
    private weak var cutState: ReaderState?
    private weak var sourcePages: Pages?
    private let documentID: UUID?
    private let sourcePage: Int

    private init(_ annotation: PDFAnnotationSnapshot, page: Int, state: ReaderState, pages: Pages,
                 cut: Bool, image: Data?) throws {
        self.annotation = annotation; sourcePage = page; documentID = state.document?.id
        sourcePages = pages; cutState = cut ? state : nil
        if let image {
            let directory = try TemporaryDirectory(), file = directory.url.appendingPathComponent("stamp.png")
            try image.write(to: file)
            temporary = directory; self.image = file
        } else { temporary = nil; self.image = nil }
    }
    nonisolated static func canCopy(_ type: String) -> Bool {
        ["Text", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Redact", "Stamp", "Caret", "Ink"].contains(type)
    }
    static func canCopy(_ state: ReaderState, cut: Bool = false) -> Bool {
        guard state.nativePDFInfo?.permissions.copy == true,
              case .annotation(_, let selected) = state.nativePDFSelection, canCopy(selected.type) else { return false }
        return !cut || state.canEditPDF && state.nativePDFInfo?.permissions.annotate == true && NativePDFAnnotations.editable(selected)
    }
    static func canPaste(_ state: ReaderState) -> Bool {
        current != nil && state.nativePDF != nil && state.canEditPDF && state.nativePDFInfo?.permissions.annotate == true
    }
    static func copy(state: ReaderState, pages: Pages, cut: Bool) async throws -> Bool {
        guard canCopy(state, cut: cut), case .annotation(let page, let selected) = state.nativePDFSelection else { return false }
        let documentID = state.document?.id, revision = state.editRevision
        let annotations = try await pages.pdfAnnotations(page)
        guard state.document?.id == documentID, state.editRevision == revision,
              let annotation = annotations.first(where: { $0.id == selected.id }) else { return false }
        let image = annotation.type == "Stamp" ? try await pages.pdfStampImage(page: page, id: selected.id) : nil
        guard state.document?.id == documentID, state.nativePDF === pages, state.editRevision == revision,
              !cut || state.canEditPDF else { return false }
        current = try .init(annotation, page: page, state: state, pages: pages, cut: cut, image: image)
        state.status = L(cut ? "Annotation ready to move; paste to finish" : "Annotation copied")
        return true
    }
    func creation(page: Int, at point: CGPoint) -> PDFAnnotationCreation {
        let source = annotation, bounds = source.copyBounds
        let dx = point.x-bounds.minX, dy = point.y-bounds.minY
        func translated(_ values: [Double]) -> CGPoint { CGPoint(x: values[0]+dx, y: values[1]+dy) }
        func rgb(_ values: [Double]) -> SIMD3<Float>? {
            values.count == 3 ? SIMD3(Float(values[0]), Float(values[1]), Float(values[2])) : nil
        }
        var edits: [PDFAnnotationEdit] = [.contents(source.contents)]
        if PDFAnnotationProperties.supportsIcon(source.type) { edits.append(.icon(source.icon)) }
        if PDFAnnotationProperties.supportsColor(source.type) { edits.append(.color(rgb(source.color), interior: false)) }
        if PDFAnnotationProperties.supportsInterior(source.type) { edits.append(.color(rgb(source.interiorColor), interior: true)) }
        if PDFAnnotationProperties.supportsBorder(source.type) {
            edits.append(.border(width: source.borderWidth, style: source.borderStyle, dash: source.dash))
        }
        if source.type == "FreeText" {
            let properties = PDFAnnotationProperties(source)
            edits += [.textAppearance(font: source.font, size: source.fontSize, color: rgb(source.textColor) ?? .zero, alignment: source.alignment),
                      .textStyle(family: properties.fontFamily ?? "Helvetica", style: Int32(source.fontStyle ?? 0))]
        }
        if source.type == "Line", source.line.count == 2 {
            edits.append(.line(from: translated(source.line[0]), to: translated(source.line[1]), start: source.lineEnds.first ?? 0, end: source.lineEnds.last ?? 0))
        }
        if !source.vertices.isEmpty { edits.append(.vertices(source.vertices.map(translated))) }
        if source.type == "PolyLine" { edits.append(.lineEnds(start: source.lineEnds.first ?? 0, end: source.lineEnds.last ?? 0)) }
        if !source.ink.isEmpty { edits.append(.ink(source.ink.map { $0.map(translated) })) }
        if !source.quads.isEmpty {
            edits.append(.quads(source.quads.map { .init(upperLeft: translated($0[0]), upperRight: translated($0[1]),
                                                       lowerLeft: translated($0[2]), lowerRight: translated($0[3])) }))
        }
        if let image { edits.append(.stampImage(image)) }
        if PDFAnnotationProperties.supportsOpacity(source.type) { edits.append(.opacity(source.opacity)) }
        return .init(page: page, type: source.type, bounds: CGRect(origin: point, size: bounds.size), edits: edits)
    }
    func paste(state: ReaderState, pages: Pages, page: Int, at point: CGPoint) async throws {
        guard state.nativePDF === pages, state.canEditPDF, state.nativePDFInfo?.permissions.annotate == true else { return }
        let targetID = state.document?.id
        let source = cutState
        // Claim the cut before suspending: separate windows can paste the
        // same clipboard concurrently. A failed paste leaves the cut pending.
        cutState = nil
        var pasted = false
        defer { if !pasted, let source { cutState = source } }
        var cut: (page: Int, annotation: PDFAnnotationSnapshot, stampImage: URL?)?
        if let source, source.document?.id == documentID, let sourcePages, source.nativePDF === sourcePages,
           source.canEditPDF, source.nativePDFInfo?.permissions.annotate == true {
            cut = (sourcePage, annotation, image)
        }
        guard state.document?.id == targetID, state.nativePDF === pages, state.canEditPDF else { return }
        let sameDocument = sourcePages === pages && source?.document?.id == documentID
        let result = try await pages.pdfPasteAnnotation(creation(page: page, at: point), removing: sameDocument ? cut : nil)
        pasted = true
        if source?.status == L("Annotation ready to move; paste to finish") { source?.status = "" }
        var removedSource = result.removedSource
        if !sameDocument, let cut, let source, let sourcePages,
           source.document?.id == documentID, source.nativePDF === sourcePages, source.canEditPDF {
            do {
                removedSource = try await sourcePages.pdfDeleteAnnotation(page: cut.page, matching: cut.annotation, stampImage: cut.stampImage)
            } catch { throw ReadError("Annotation pasted, but the original could not be removed: " + error.localizedDescription) }
            if removedSource, source.document?.id == documentID {
                source.nativePDFSelection = nil; try await source.nativePDFDidChange(sourcePages)
            }
        }
        if state.document?.id == targetID {
            try await NativePDFAnnotations.refresh(page: page, id: result.id, state: state, pages: pages)
            if state.document?.id == targetID { state.status = L(source != nil && !removedSource ? "Annotation pasted as a copy" : "Annotation pasted") }
        }
    }
}
#endif
