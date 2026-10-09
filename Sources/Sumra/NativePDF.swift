#if os(macOS)
import AppKit
import Darwin
import SumraCore

// Value snapshots for the GUI. The NativeFile owned by Pages is the live PDF;
// MuPDF owns permissions, form calculations, annotation objects and undo.
struct PDFDocumentInfo: Decodable, Sendable {
    struct Permissions: Decodable, Sendable {
        let copy, print, printHighQuality, annotate, form, assemble, edit, accessibility: Bool
    }
    struct ViewerPreferences: Decodable, Sendable {
        let direction, printScaling, duplex: String?
        let pickTrayByPDFSize: Bool?
        let numCopies: Int?
    }
    let pageCount: Int
    let permissions: Permissions
    let ownerAuthenticated, editingEnabled, hasPageLabels: Bool
    let layout, pageMode: String?
    let viewerPreferences: ViewerPreferences
    let dirty: Bool
    let undoPosition, undoSteps: Int
    let undoTitle, redoTitle: String?
}

struct PDFAnnotationSnapshot: Decodable, Identifiable, Equatable, Sendable {
    struct Choice: Decodable, Equatable, Sendable { let label, value: String }
    let id: Int32
    let type, contents, author, icon: String
    let flags: Int
    let rect, color, interiorColor: [Double]
    var designRect: [Double]? = nil
    let opacity, borderWidth: Float
    let borderStyle, alignment: Int32
    let dash: [Float]
    let font: String
    let fontSize: Float
    var fontFamily: String? = nil
    var fontStyle: Int? = nil
    let textColor: [Double]
    let line, vertices: [[Double]]
    let lineEnds: [Int32]
    let quads, ink: [[[Double]]]
    let fieldName, fieldLabel, value: String?
    let fieldType, fieldFlags, maxLength: Int?
    let readOnly: Bool?
    let options: [Choice]?
    var isSigned: Bool? = nil
    var bounds: CGRect { CGRect(raster: rect) }
    var copyBounds: CGRect { designRect.map { CGRect(raster: $0) } ?? bounds }
    var isUnsignedSignature: Bool { type == "Widget" && fieldType == 6 && isSigned == false }
    // EngineMupdf::GetFormFieldHighlightRects / FormFieldValueIsEmpty.
    var isEmptyFormField: Bool {
        guard type == "Widget", readOnly == false, flags & 35 == 0 else { return false }
        switch fieldType {
        case 6: return isUnsignedSignature
        case 2, 5: return value == nil || value == "" || value == "Off"
        case 3, 4, 7: return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        default: return false
        }
    }
}

struct PDFLinkSnapshot: Decodable, Sendable {
    struct Destination: Decodable, Sendable {
        let page, type: Int
        let x, y, width, height, zoom: Double?
    }
    struct Action: Decodable, Sendable {
        let index: Int
        let kind: String
        let uri: String?
        let name: String
        let flags: Int
        let newWindow: Bool?
        let fields: [String]?
        let javascript: String?
        let destination: Destination?
    }
    let id: Int32
    let type: String
    let flags: Int
    let rect: [Double]
    let actions: [Action]
    var bounds: CGRect { CGRect(raster: rect) }
}

// A user edit crosses the actor once. Its setters run in one MuPDF journal
// operation, including form scripts; there is no await inside an operation.
enum PDFAnnotationEdit: Sendable {
    case rect(CGRect), contents(String), author(String), icon(String)
    case move(CGSize), stampImage(URL), attachment(URL, filename: String, mime: String)
    case color(SIMD3<Float>?, interior: Bool), opacity(Float)
    case border(width: Float, style: Int32, dash: [Float])
    case textAppearance(font: String, size: Float, color: SIMD3<Float>, alignment: Int32)
    case textStyle(family: String, style: Int32)
    case quads([Quad]), vertices([CGPoint]), ink([[CGPoint]])
    case line(from: CGPoint, to: CGPoint, start: Int32, end: Int32)
    case lineEnds(start: Int32, end: Int32)

    struct Quad: Sendable {
        let upperLeft, upperRight, lowerLeft, lowerRight: CGPoint
        var points: [CGPoint] { [upperLeft, upperRight, lowerLeft, lowerRight] }
    }
}

struct PDFAnnotationCreation: Sendable {
    let page: Int
    let type: String
    let bounds: CGRect
    let edits: [PDFAnnotationEdit]
}

struct PDFInkEdit: Sendable {
    let id: Int32
    let strokes: [[CGPoint]]
}

extension NativeFile {
    private typealias PDFAction = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> Int32
    private typealias PDFInteger = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<CChar>) -> Int32
    private typealias PDFString = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
    private typealias AnnotationAction = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<CChar>) -> Int32
    private typealias AnnotationString = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
    private typealias AnnotationFloat = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Float, UnsafeMutablePointer<CChar>) -> Int32
    private typealias AnnotationPoints = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Float>?, UnsafeMutablePointer<CChar>) -> Int32

    @discardableResult private func pdfCall<T>(_ name: String, _ type: T.Type,
                                              _ call: (T, inout [CChar]) -> Int32) throws -> Int32 {
        guard let function = symbol(name, type) else { throw ReadError("Incompatible MuPDF engine: " + name) }
        var error = [CChar](repeating: 0, count: 512)
        let result = call(function, &error)
        guard result > 0 else { throw Self.failure(error, "Cannot edit PDF") }
        return result
    }

    private func pdfTransaction<T>(_ title: String, _ action: () throws -> T) throws -> T {
        try pdfCall("lf_pdf_live_begin", PDFString.self) { $0(document, title, &$1) }
        defer { invalidatePDFCaches() }
        do {
            let result = try action()
            try pdfCall("lf_pdf_live_end", PDFAction.self) { $0(document, &$1) }
            return result
        } catch {
            let original = error
            do { try pdfCall("lf_pdf_live_abort", PDFAction.self) { $0(document, &$1) } }
            catch { throw ReadError(original.localizedDescription + "\nCannot undo the failed PDF edit: " + error.localizedDescription) }
            throw original
        }
    }

    func pdfInfo() throws -> PDFDocumentInfo? {
        guard engine == .mupdf else { return nil }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let get = symbol("lf_pdf_document_info", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_document_info") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, &error), error: error, as: PDFDocumentInfo?.self)
    }

    func pdfSignatureInfo() throws -> PDFSignatureInfo {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let get = symbol("lf_pdf_live_signature_info", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_signature_info") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, &error), error: error, as: PDFSignatureInfo.self)
    }

    // Pages serializes this whole output operation. A failed signature never
    // changes the live field tree, MuJS state, undo history, or saved position.
    func pdfSignCopy(to destination: URL, sourceURL: URL, password: String,
                     identity: NativePDFTools.SigningIdentity, fieldName: String, page: Int,
                     bounds: CGRect, reason: String = "", location: String = "", image: URL? = nil,
                     appearance: PDFSignatureAppearance = .standard) throws {
        try NativePDFTools.validateDestination(source: sourceURL, destination: destination)
        try NativePDFTools.validateSignature(fieldName: fieldName, page: page, bounds: bounds)
        try Task.checkCancellation()
        try validatePDFSource()
        let temporary = try TemporaryDirectory(), snapshot = temporary.url.appendingPathComponent("current.pdf")
        defer { withExtendedLifetime(temporary) {} }
        try pdfCall("lf_pdf_live_signing_snapshot", PDFString.self) { $0(document, snapshot.path, &$1) }
        try validatePDFSource()
        try Task.checkCancellation()
        try NativePDFTools.sign(source: snapshot, destination: destination, identity: identity,
            fieldName: fieldName, page: page, bounds: bounds, documentPassword: password,
            reason: reason, location: location, image: image, appearance: appearance)
    }

    func pdfPageLabel(_ page: Int) throws -> String {
        guard let get = symbol("lf_pdf_page_label", PageJSON.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_page_label") }
        var error = [CChar](repeating: 0, count: 512)
        guard let value = get(document, Int32(page), &error) else { throw Self.failure(error, "Cannot read PDF page label") }
        defer { free(value) }
        return String(cString: value)
    }

    func pdfPageGeometry(_ page: Int) throws -> (transform: CGAffineTransform, mediaBox: CGRect) {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
        var matrix = [Float](repeating: 0, count: 6), box = [Float](repeating: 0, count: 4)
        try pdfCall("lf_pdf_live_page_geometry", Get.self) { $0(document, Int32(page), &matrix, &box, &$1) }
        return (CGAffineTransform(a: CGFloat(matrix[0]), b: CGFloat(matrix[1]), c: CGFloat(matrix[2]), d: CGFloat(matrix[3]),
                                  tx: CGFloat(matrix[4]), ty: CGFloat(matrix[5])), CGRect(raster: box.map(Double.init)))
    }

    func pdfInitialPage() throws -> Int? {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> Int32
        var page: Int32 = -1
        try pdfCall("lf_pdf_live_initial_page", Get.self) { $0(document, &page, &$1) }
        return page < 0 ? nil : Int(page)
    }

    func pdfTextLines(_ page: Int) throws -> [RasterWord] {
        guard let get = symbol("lf_pdf_live_text_lines", PageJSON.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_text_lines") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, Int32(page), &error), error: error, as: [RasterWord].self)
    }

    func pdfAnnotations(_ page: Int) throws -> [PDFAnnotationSnapshot] {
        guard let get = symbol("lf_pdf_live_annotations", PageJSON.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_annotations") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, Int32(page), &error), error: error, as: [PDFAnnotationSnapshot].self)
    }

    // Media, Crop, Bleed, Trim, Art in Fitz coordinates; absent boxes stay nil.
    func pdfPageBoxes(_ page: Int) throws -> [CGRect?] {
        guard let get = symbol("lf_pdf_live_page_boxes", PageJSON.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_page_boxes") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, Int32(page), &error), error: error, as: [[Double]?].self).map { $0.map { CGRect(raster: $0) } }
    }

    func pdfEngineering(cancellation: NativeRenderCancellation? = nil) throws -> PDFColors.Engineering {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        typealias Detect = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>) -> Int32
        guard let detect = symbol("lf_pdf_live_engineering", Detect.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_engineering") }
        var values = [Int32](repeating: 0, count: 3), error = [CChar](repeating: 0, count: 512)
        let success = detect(document, &values, cancellation?.handle, &error)
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard success != 0 else { throw Self.failure(error, "Cannot inspect PDF engineering content") }
        return PDFColors.Engineering(enabled: values[0] != 0, raster: values[1] != 0, hairline: values[2] != 0)
    }

    func pdfLinks(_ page: Int) throws -> [PDFLinkSnapshot] {
        guard let get = symbol("lf_pdf_live_links", PageJSON.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_links") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, Int32(page), &error), error: error, as: [PDFLinkSnapshot].self)
    }

    func pdfResolveDestination(_ uri: String, pdfCoordinates: Bool = false) throws -> PDFLinkSnapshot.Destination? {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let get = symbol("lf_pdf_live_resolve_destination", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_resolve_destination") }
        var error = [CChar](repeating: 0, count: 512)
        return try decode(get(document, uri, pdfCoordinates ? 1 : 0, &error), error: error, as: PDFLinkSnapshot.Destination?.self)
    }

    func pdfAttachment(page: Int, id: Int32) throws -> PDFTools.Attachment {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Int>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        guard let get = symbol("lf_pdf_live_attachment", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_attachment") }
        var error = [CChar](repeating: 0, count: 512), length = 0
        var name: UnsafeMutablePointer<CChar>?, description: UnsafeMutablePointer<CChar>?
        guard let bytes = get(document, Int32(page), id, &length, &name, &description, &error) else {
            throw Self.failure(error, "Cannot read PDF attachment")
        }
        defer { free(name); free(description) }
        return Self.pdfAttachment(name: name.map { String(cString: $0) }, description: description.map { String(cString: $0) },
                                  data: Data(bytesNoCopy: bytes, count: length, deallocator: .free))
    }

    private static func pdfAttachment(name: String?, description: String?, data: Data) -> PDFTools.Attachment {
        let rawName = name ?? "attachment"
        let filename = (rawName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        return .init(name: filename.isEmpty || filename == "." || filename == ".." ? "attachment" : filename,
                     description: description, data: data)
    }

    func pdfXMP() throws -> Data? {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        guard let get = symbol("lf_pdf_live_xmp", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_xmp") }
        var error = [CChar](repeating: 0, count: 512), length = 0
        guard let bytes = get(document, &length, &error) else {
            if error[0] != 0 { throw Self.failure(error, "Cannot read XMP metadata") }
            return nil
        }
        return Data(bytesNoCopy: bytes, count: length, deallocator: .free)
    }

    func pdfAttachments() throws -> [PDFTools.Attachment] {
        typealias Output = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int) -> Void
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Output, UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>) -> Int32
        var attachments = [PDFTools.Attachment]()
        _ = try withUnsafeMutablePointer(to: &attachments) { result in
            try pdfCall("lf_pdf_live_attachments", Get.self) { get, error in
                get(document, { result, name, description, bytes, length in
                    let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
                    result.assumingMemoryBound(to: [PDFTools.Attachment].self).pointee.append(NativeFile.pdfAttachment(
                        name: name.map { String(cString: $0) }, description: description.map { String(cString: $0) }, data: data))
                }, result, &error)
            }
        }
        return attachments
    }

    func pdfStampImage(page: Int, id: Int32) throws -> Data? {
        typealias Get = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Int>, UnsafeMutablePointer<CChar>) -> UnsafeMutableRawPointer?
        guard let get = symbol("lf_pdf_live_stamp_image", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_stamp_image") }
        var error = [CChar](repeating: 0, count: 512), length = 0
        guard let bytes = get(document, Int32(page), id, &length, &error) else {
            if error[0] != 0 { throw Self.failure(error, "Cannot copy stamp image") }
            return nil
        }
        return Data(bytesNoCopy: bytes, count: length, deallocator: .free)
    }

    func pdfJavaScriptMenu(_ script: String) throws -> [String] {
        let items = PDFJavaScriptMenu.items(in: script)
        if !items.isEmpty { return items }
        guard let name = PDFJavaScriptMenu.calledFunction(in: script) else { return [] }
        typealias Get = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        guard let get = symbol("lf_pdf_live_named_javascript", Get.self) else { throw ReadError("Incompatible MuPDF engine: lf_pdf_live_named_javascript") }
        var error = [CChar](repeating: 0, count: 512)
        guard let body = get(document, name, &error) else { throw Self.failure(error, "Cannot read PDF menu") }
        defer { free(body) }
        return PDFJavaScriptMenu.items(in: String(cString: body))
    }

    func pdfSetEditing(_ enabled: Bool) throws {
        try pdfCall("lf_pdf_live_set_editing", PDFInteger.self) { $0(document, enabled ? 1 : 0, &$1) }
    }

    func pdfSetAnnotationsVisible(_ visible: Bool) throws {
        try pdfCall("lf_pdf_set_annotations_visible", PDFInteger.self) { $0(document, visible ? 1 : 0, &$1) }
    }

    func pdfUndo(redo: Bool) throws {
        defer { invalidatePDFCaches() }
        try pdfCall("lf_pdf_live_undo", PDFInteger.self) { $0(document, redo ? 1 : 0, &$1) }
    }

    @discardableResult func pdfWrite(to destination: URL) throws -> Bool {
        // Output reads the private immutable input and the same live journal.
        try validatePDFSource()
        let fullWrite = try pdfCall("lf_pdf_live_write", PDFString.self) { $0(document, destination.path, &$1) } == 2
        // The caller still owns a temporary output. Catch source changes during
        // lazy stream reads before that output can replace the chosen file.
        try validatePDFSource()
        return fullWrite
    }

    func pdfMarkSaved() throws {
        try pdfCall("lf_pdf_live_mark_saved", PDFAction.self) { $0(document, &$1) }
    }

    func pdfCreateAnnotation(page: Int, type: String, bounds: CGRect, edits: [PDFAnnotationEdit]) throws -> Int32 {
        try pdfTransaction("Add annotation") {
            typealias Create = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafePointer<CChar>, UnsafePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
            let id = try pdfCall("lf_pdf_live_create", Create.self) { $0(document, Int32(page), type, bounds.raster.map(Float.init), &$1) }
            try pdfApply(edits, page: page, id: id)
            // PasteCopiedAnnotation sets the stamp rect last: its initial
            // Draft appearance can otherwise impose the rubber-stamp aspect.
            if type == "Stamp" { try pdfApply([.rect(bounds)], page: page, id: id) }
            return id
        }
    }

    func pdfCreateAnnotations(_ items: [PDFAnnotationCreation]) throws -> [Int32] {
        try pdfTransaction("Add annotations") {
            try items.map { try pdfCreateAnnotation(page: $0.page, type: $0.type, bounds: $0.bounds, edits: $0.edits) }
        }
    }

    func pdfPasteAnnotation(_ item: PDFAnnotationCreation, removing: (page: Int, id: Int32)? = nil) throws -> Int32 {
        try pdfTransaction("Paste annotation") {
            let id = try pdfCreateAnnotation(page: item.page, type: item.type, bounds: item.bounds, edits: item.edits)
            if let removing { try pdfDeleteAnnotation(page: removing.page, id: removing.id) }
            return id
        }
    }

    func pdfEraseInk(page: Int, edits: [PDFInkEdit]) throws {
        try pdfTransaction("Erase ink") {
            for edit in edits {
                if edit.strokes.isEmpty { try pdfDeleteAnnotation(page: page, id: edit.id) }
                else { try pdfApply([.ink(edit.strokes)], page: page, id: edit.id) }
            }
        }
    }

    func pdfCreateLink(page: Int, bounds: CGRect, uri: String) throws -> Int32 {
        defer { invalidatePDFCaches() }
        typealias Create = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafePointer<Float>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
        return try pdfCall("lf_pdf_live_create_link", Create.self) { $0(document, Int32(page), bounds.raster.map(Float.init), uri, &$1) }
    }

    func pdfEditLink(page: Int, id: Int32, bounds: CGRect, uri: String?) throws {
        defer { invalidatePDFCaches() }
        typealias Edit = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<Float>, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>) -> Int32
        try pdfCall("lf_pdf_live_edit_link", Edit.self) { edit, error in
            let rect = bounds.raster.map(Float.init)
            if let uri { return uri.withCString { edit(document, Int32(page), id, rect, $0, &error) } }
            return edit(document, Int32(page), id, rect, nil, &error)
        }
    }

    func pdfDeleteLink(page: Int, id: Int32) throws {
        defer { invalidatePDFCaches() }
        try pdfCall("lf_pdf_live_delete_link", AnnotationAction.self) { $0(document, Int32(page), id, &$1) }
    }

    func pdfEditAnnotation(page: Int, id: Int32, edits: [PDFAnnotationEdit]) throws {
        try pdfTransaction("Edit annotation") { try pdfApply(edits, page: page, id: id) }
    }

    func pdfDeleteAnnotation(page: Int, id: Int32) throws {
        defer { invalidatePDFCaches() }
        try pdfCall("lf_pdf_live_delete", AnnotationAction.self) { $0(document, Int32(page), id, &$1) }
    }

    func pdfSetWidgetValue(page: Int, id: Int32, value: String) throws {
        defer { invalidatePDFCaches() }
        try pdfCall("lf_pdf_live_widget_value", AnnotationString.self) { $0(document, Int32(page), id, value, &$1) }
    }

    func pdfToggleWidget(page: Int, id: Int32) throws {
        defer { invalidatePDFCaches() }
        try pdfCall("lf_pdf_live_widget_toggle", AnnotationAction.self) { $0(document, Int32(page), id, &$1) }
    }

    private func pdfApply(_ edits: [PDFAnnotationEdit], page: Int, id: Int32) throws {
        let page = Int32(page)
        func points(_ values: [CGPoint]) -> [Float] { values.flatMap { [Float($0.x), Float($0.y)] } }
        func text(_ name: String, _ value: String) throws {
            try pdfCall(name, AnnotationString.self) { $0(document, page, id, value, &$1) }
        }
        for edit in edits {
            switch edit {
            case .rect(let value):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<Float>, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_rect", Set.self) { $0(document, page, id, value.raster.map(Float.init), &$1) }
            case .move(let offset):
                typealias Move = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Float, Float, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_move", Move.self) { $0(document, page, id, Float(offset.width), Float(offset.height), &$1) }
            case .stampImage(let url): try text("lf_pdf_live_set_stamp_image", url.path)
            case .attachment(let url, let filename, let mime):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_attachment", Set.self) { $0(document, page, id, url.path, filename, mime, &$1) }
            case .contents(let value): try text("lf_pdf_live_set_contents", value)
            case .author(let value): try text("lf_pdf_live_set_author", value)
            case .icon(let value): try text("lf_pdf_live_set_icon", value)
            case .opacity(let value):
                try pdfCall("lf_pdf_live_set_opacity", AnnotationFloat.self) { $0(document, page, id, value, &$1) }
            case .color(let value, let interior):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, Int32, UnsafePointer<Float>?, UnsafeMutablePointer<CChar>) -> Int32
                let rgb = value.map { [$0.x, $0.y, $0.z] } ?? []
                try pdfCall("lf_pdf_live_set_color", Set.self) { $0(document, page, id, interior ? 1 : 0, Int32(rgb.count), rgb, &$1) }
            case .border(let width, let style, let dash):
                try pdfCall("lf_pdf_live_set_border", AnnotationFloat.self) { $0(document, page, id, width, &$1) }
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, Int32, UnsafePointer<Float>?, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_border_style", Set.self) { $0(document, page, id, style, Int32(dash.count), dash, &$1) }
            case .textAppearance(let font, let size, let color, let alignment):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<CChar>, Float, UnsafePointer<Float>, Int32, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_default_appearance", Set.self) { $0(document, page, id, font, size, [color.x, color.y, color.z], alignment, &$1) }
            case .textStyle(let family, let style):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<CChar>, Int32, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_text_style", Set.self) { $0(document, page, id, family, style, &$1) }
            case .quads(let values):
                let coordinates = points(values.flatMap(\.points))
                try pdfCall("lf_pdf_live_set_quads", AnnotationPoints.self) { $0(document, page, id, Int32(values.count), coordinates, &$1) }
            case .vertices(let values):
                try pdfCall("lf_pdf_live_set_vertices", AnnotationPoints.self) { $0(document, page, id, Int32(values.count), points(values), &$1) }
            case .ink(let strokes):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, UnsafePointer<Int32>?, UnsafePointer<Float>?, UnsafeMutablePointer<CChar>) -> Int32
                let counts = strokes.map { Int32($0.count) }, coordinates = points(strokes.flatMap { $0 })
                try pdfCall("lf_pdf_live_set_ink", Set.self) { $0(document, page, id, Int32(strokes.count), counts, coordinates, &$1) }
            case .line(let start, let end, let startStyle, let endStyle):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UnsafePointer<Float>, Int32, Int32, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_line", Set.self) { $0(document, page, id, points([start, end]), startStyle, endStyle, &$1) }
            case .lineEnds(let start, let end):
                typealias Set = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int32, Int32, UnsafeMutablePointer<CChar>) -> Int32
                try pdfCall("lf_pdf_live_set_line_ends", Set.self) { $0(document, page, id, start, end, &$1) }
            }
        }
    }
}
#endif
