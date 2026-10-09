#if os(macOS)
import AppKit
import ImageIO
import SumraCore
import UniformTypeIdentifiers

// ImageSaveCropResize.cpp (Sumatra 012d997f): preserve original bytes when the
// bitmap is unchanged and the extension matches; otherwise encode the edit.
enum ReaderImages {
    enum Mode { case save, crop, resize, pdf }

    static func matchingExtension(_ first: String, _ second: String) -> Bool {
        func canonical(_ value: String) -> String {
            switch value.lowercased() { case "jpeg", "jfif": return "jpg"; case "tiff": return "tif"; default: return value.lowercased() }
        }
        return !first.isEmpty && canonical(first) == canonical(second)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else { throw ReadError("Choose positive image dimensions") }
        if width == image.width, height == image.height { return image }
        let colorSpace = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ReadError("Cannot allocate resized image") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ReadError("Cannot resize image") }
        return result
    }

    // PdfCreator::AddPageFromGdiplusBitmap uses the bitmap's horizontal DPI.
    // Keep that density through edits; output pixels determine physical size.
    static func imageDPI(_ properties: [CFString: Any]?) -> Double {
        guard let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi.isFinite, dpi > 0 else { return 72 }
        return dpi
    }

    static func encoded(_ image: CGImage, extension ext: String, dpi: Double = 72) throws -> Data {
        if ext.lowercased() == "pdf" {
            return try PDFTools.images([image], dpi: dpi)
        }
        if ext.lowercased() == "webp" {
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data as CFMutableData, "org.webmproject.webp" as CFString, 1, nil) else { throw ReadError("This system does not provide a WebP encoder") }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw ReadError("Cannot encode WebP image") }
            return data as Data
        }
        let type: NSBitmapImageRep.FileType = ext.lowercased() == "gif" ? .gif : try PDFTools.imageType(for: URL(fileURLWithPath: "image." + ext))
        return try encoded(image, type: type, dpi: dpi)
    }

    static func encoded(_ image: CGImage, type: NSBitmapImageRep.FileType, dpi: Double) throws -> Data {
        guard dpi.isFinite, dpi > 0 else { throw ReadError("Choose a positive image DPI") }
        let identifiers: [NSBitmapImageRep.FileType: String] = [.png: "public.png", .jpeg: "public.jpeg", .tiff: "public.tiff", .bmp: "com.microsoft.bmp", .gif: "com.compuserve.gif"]
        let data = NSMutableData()
        guard let identifier = identifiers[type],
              let output = CGImageDestinationCreateWithData(data as CFMutableData, identifier as CFString, 1, nil) else { throw ReadError("Cannot create image encoder") }
        CGImageDestinationAddImage(output, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ReadError("Cannot encode image") }
        return data as Data
    }

    static func dataForSave(_ image: CGImage, original: (data: Data, filename: String)?, extension ext: String, dpi: Double = 72) throws -> Data {
        if ext.lowercased() != "pdf", let original, matchingExtension(ext, (original.filename as NSString).pathExtension) { return original.data }
        return try encoded(image, extension: ext, dpi: dpi)
    }

    static func embeddedType(_ data: Data) throws -> UTType {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else {
            throw ReadError("Cannot identify embedded image")
        }
        return type
    }

    @MainActor
    static func outputEmbedded(_ data: Data, action: ReaderAction, state: ReaderState) async throws {
        let type = try embeddedType(data)
        if action == .saveSelection {
            guard let document = state.document else { return }
            let source = sourceURL(document)
            guard state.document?.id == document.id else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [type]
            panel.nameFieldStringValue = "Image." + (type.preferredFilenameExtension ?? "png")
            guard panel.runModal() == .OK, let destination = panel.url,
                  state.document?.id == document.id else { return }
            guard ![document.url, source].contains(where: { PDFTools.sameFile(destination, $0) }) else { throw ReadError("Choose a different location for the image") }
            try data.write(to: destination, options: .atomic)
        } else if action == .copyImage {
            let png: Data
            if type == .png { png = data }
            else {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError("Cannot decode embedded image") }
                png = try encoded(image, extension: "png")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .init(type.identifier))
            if type != .png { NSPasteboard.general.setData(png, forType: .png) }
        } else { throw ReadError("Unsupported embedded image action") }
    }

    @MainActor
    static func edit(_ state: ReaderState, mode: Mode = .crop) {
        guard let document = state.document else { return }
        let page = state.page
        let rotation = state.rotation
        Task {
            do {
                let input = try await image(document, page: page)
                let source = sourceURL(document)
                guard state.document?.id == document.id else { return }
                let bitmap = try RasterLayout.image(input.image, bounds: CGRect(x: 0, y: 0, width: input.image.width, height: input.image.height), crop: nil, rotation: rotation)
                try edit(bitmap, original: rotation % 360 == 0 ? input.original : nil,
                         filename: document.url.deletingPathExtension().lastPathComponent + "-\(page + 1).png",
                         dpi: input.dpi, document: document, sourceURL: source, state: state, mode: mode)
            } catch { if state.document?.id == document.id { state.error = error.localizedDescription } }
        }
    }

    @MainActor
    static func editEmbedded(_ data: Data, state: ReaderState, mode: Mode) async throws {
        guard let document = state.document else { return }
        switch document.content {
        case .pages(let pages):
            if pages.isPDF {
                guard try await pages.pdfInfo()?.permissions.copy == true else { throw ReadError("This PDF does not allow copying images") }
            }
        default: throw ReadError("Choose an image or document page")
        }
        let fileURL = sourceURL(document)
        guard state.document?.id == document.id else { return }
        let type = try embeddedType(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError("Cannot decode embedded image") }
        let filename = "Image." + (type.preferredFilenameExtension ?? "png")
        let dpi = imageDPI(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        try edit(image, original: (data, filename), filename: filename, dpi: dpi, document: document, sourceURL: fileURL, state: state, mode: mode)
    }

    @MainActor
    private static func sourceURL(_ document: ReadingDocument) -> URL {
        switch document.content {
        case .pages(let pages): return pages.pdfSourceURL
        default: return document.url
        }
    }

    @MainActor
    private static func edit(_ image: CGImage, original: (data: Data, filename: String)?, filename: String,
                             dpi: Double, document: ReadingDocument, sourceURL: URL, state: ReaderState, mode: Mode) throws {
        let controls = ImageEditView(image: image, mode: mode)
        let alert = NSAlert(); alert.messageText = L("Image")
        alert.accessoryView = controls
        alert.addButton(withTitle: L("Save…")); alert.addButton(withTitle: L("Copy")); alert.addButton(withTitle: L("Cancel"))
        let answer = alert.runModal()
        guard state.document?.id == document.id,
              answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn else { return }
        let output = try controls.result()
        if answer == .alertSecondButtonReturn { try PDFTools.outputImage(output, action: .copyImage, state: state); return }
        let original = controls.modified ? nil : original
        let panel = NSSavePanel()
        var extensions = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "pdf"]
        if (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains("org.webmproject.webp") { extensions.append("webp") }
        if let original { extensions.append((original.filename as NSString).pathExtension) }
        panel.allowedFileTypes = Array(Set(extensions.filter { !$0.isEmpty })).sorted()
        let name = original?.filename ?? filename
        panel.nameFieldStringValue = mode == .pdf ? (name as NSString).deletingPathExtension + ".pdf" : name
        guard panel.runModal() == .OK, let destination = panel.url, state.document?.id == document.id else { return }
        guard ![document.url, sourceURL].contains(where: { PDFTools.sameFile(destination, $0) }) else { throw ReadError("Choose a different location for the edited image") }
        let bytes = try dataForSave(output, original: original, extension: destination.pathExtension, dpi: dpi)
        try bytes.write(to: destination, options: .atomic)
        state.status = String(format: L("Saved %@"), destination.lastPathComponent)
    }

    @MainActor
    static func image(_ document: ReadingDocument, page: Int) async throws -> (image: CGImage, original: (data: Data, filename: String)?, dpi: Double) {
        switch document.content {
        case .pages(let pages): return try await pages.editableImage(page)
        default: throw ReadError("Choose an image or document page")
        }
    }

    @MainActor
    static func openClipboard(_ state: ReaderState) {
        do {
            for (type, name) in [(NSPasteboard.PasteboardType.png, "Clipboard.png"), (.tiff, "Clipboard.tiff")] {
                if let data = NSPasteboard.general.data(forType: type) {
                    let directory = try TemporaryDirectory(), file = directory.url.appendingPathComponent(name)
                    try data.write(to: file); open(file, temporary: directory, state: state); return
                }
            }
            guard let image = NSImage(pasteboard: .general), let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ReadError("The clipboard has no image") }
            let directory = try TemporaryDirectory(), file = directory.url.appendingPathComponent("Clipboard.png")
            try encoded(bitmap, extension: "png").write(to: file)
            open(file, temporary: directory, state: state)
        } catch { state.error = error.localizedDescription }
    }

    // GoogleLens.cpp::WriteGoogleLensPage: the explicit menu action submits an
    // ordinary multipart form in the user's browser. No upload runs at startup.
    static func lensHTML(_ png: Data) -> String {
        return """
        <!doctype html><meta charset="utf-8"><title>Google Lens</title>
        <p>Opening Google Lens…</p><script>
        const b=atob('\(png.base64EncodedString())');const a=Uint8Array.from(b,c=>c.charCodeAt(0));
        const f=new File([a],'sumra.png',{type:'image/png'});
        const i=document.createElement('input');i.type='file';i.name='encoded_image';
        const d=new DataTransfer();d.items.add(f);i.files=d.files;
        const form=document.createElement('form');form.method='post';form.enctype='multipart/form-data';
        form.action='https://lens.google.com/v3/upload?ep=cntpubb&re=df&s=4';
        form.appendChild(i);document.body.appendChild(form);form.submit();</script>
        """
    }

    @MainActor
    static func searchWithLens(_ images: [CGImage], state: ReaderState) throws {
        try searchWithLens(encoded(RasterLayout.join(images), extension: "png"), state: state)
    }

    @MainActor
    static func searchWithLens(_ data: Data, state: ReaderState) throws {
        let png: Data
        if try embeddedType(data) == .png { png = data }
        else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError("Cannot decode embedded image") }
            png = try encoded(image, extension: "png")
        }
        let html = lensHTML(png), directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent("Google Lens.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        guard NSWorkspace.shared.open(file) else { throw ReadError("Cannot open Google Lens in the browser") }
        state.browserTemporary = directory
    }

    @MainActor
    static func searchPageWithLens(_ state: ReaderState) {
        guard let document = state.document else { return }
        let page = state.page
        let rotation = state.rotation
        Task {
            do {
                let input = try await image(document, page: page)
                guard state.document?.id == document.id else { return }
                let bitmap = try RasterLayout.image(input.image, bounds: CGRect(x: 0, y: 0, width: input.image.width, height: input.image.height), crop: nil, rotation: rotation)
                try searchWithLens([bitmap], state: state)
            } catch { if state.document?.id == document.id { state.error = error.localizedDescription } }
        }
    }

    @MainActor
    static func capture(_ state: ReaderState) {
        do {
            let directory = try TemporaryDirectory(), file = directory.url.appendingPathComponent("Screenshot.png")
            let process = Process(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", file.path]; process.standardError = errors
            process.terminationHandler = { process in
                let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    if FileManager.default.fileExists(atPath: file.path) { open(file, temporary: directory, state: state) }
                    else if !details.isEmpty { state.error = details }
                    // Escape cancels the system capture without creating a file.
                }
            }
            try process.run()
        } catch { state.error = error.localizedDescription }
    }

    @MainActor
    private static func open(_ file: URL, temporary: TemporaryDirectory, state: ReaderState) {
        if let createWindow = state.createWindow { createWindow(WindowPayload(path: file.path, tabWith: state.window?.windowNumber, temporary: temporary, recordsHistory: false)) }
        else { state.openTemporary(file, keeping: temporary) }
    }
}

@MainActor
private final class ImageEditView: NSStackView, NSTextFieldDelegate {
    let canvas: ImageCropView
    let width = NSTextField(), height = NSTextField()
    let aspect = NSButton(checkboxWithTitle: L("Keep proportions"), target: nil, action: nil)
    let crop: NSButton
    private var changing = false

    init(image: CGImage, mode: ReaderImages.Mode) {
        canvas = ImageCropView(image: image)
        crop = NSButton(checkboxWithTitle: L("Crop (drag edges or draw a rectangle; arrow keys move, Shift resizes)"), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        orientation = .vertical; alignment = .leading; spacing = 8
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(canvas)
        canvas.widthAnchor.constraint(equalToConstant: 640).isActive = true
        canvas.heightAnchor.constraint(equalToConstant: 400).isActive = true
        crop.state = mode == .crop ? .on : .off; crop.target = self; crop.action = #selector(toggleCrop)
        canvas.cropping = crop.state == .on
        addArrangedSubview(crop)
        width.stringValue = String(image.width); height.stringValue = String(image.height)
        width.delegate = self; height.delegate = self
        width.setAccessibilityLabel(L("Output width in pixels")); height.setAccessibilityLabel(L("Output height in pixels"))
        width.widthAnchor.constraint(equalToConstant: 85).isActive = true
        height.widthAnchor.constraint(equalToConstant: 85).isActive = true
        aspect.state = .on
        addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: L("Pixels")), width, NSTextField(labelWithString: "×"), height, aspect]))
        canvas.changed = { [weak self] in self?.resetSize() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleCrop() { canvas.cropping = crop.state == .on; resetSize() }
    private func resetSize() { width.stringValue = String(Int(canvas.selected.width)); height.stringValue = String(Int(canvas.selected.height)) }
    func controlTextDidChange(_ notification: Notification) {
        guard !changing, aspect.state == .on, let field = notification.object as? NSTextField,
              let value = Int(field.stringValue), value > 0 else { return }
        changing = true; defer { changing = false }
        let selected = canvas.selected
        let proportional = field === width ? Double(value) * selected.height / selected.width : Double(value) * selected.width / selected.height
        guard proportional.isFinite, proportional < Double(Int.max) else { return }
        (field === width ? height : width).stringValue = String(max(1, Int(proportional.rounded())))
    }
    var modified: Bool { canvas.selected != canvas.imageBounds || width.integerValue != canvas.image.width || height.integerValue != canvas.image.height }
    func result() throws -> CGImage {
        guard let w = Int(width.stringValue), let h = Int(height.stringValue) else { throw ReadError("Enter whole pixel dimensions") }
        let source = try RasterLayout.image(canvas.image, bounds: canvas.imageBounds, crop: canvas.selected, rotation: 0)
        return try ReaderImages.resized(source, width: w, height: h)
    }
}

@MainActor
private final class ImageCropView: NSView {
    let image: CGImage
    var changed: (() -> Void)?
    var cropping = false { didSet { needsDisplay = true } }
    private var rectangle: CGRect
    private var start = CGPoint.zero, original = CGRect.zero
    private var moving = false
    private var edgeX = 0, edgeY = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    var selected: CGRect { cropping ? rectangle : imageBounds }
    private var display: CGRect {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    init(image: CGImage) { self.image = image; rectangle = CGRect(x: 0, y: 0, width: image.width, height: image.height); super.init(frame: .zero); setAccessibilityLabel(L("Image crop area")); setAccessibilityRole(.image) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSImage(cgImage: image, size: .zero).draw(in: display, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard cropping else { return }
        let scale = display.width / CGFloat(image.width)
        let box = CGRect(x: display.minX+rectangle.minX*scale, y: display.minY+rectangle.minY*scale, width: rectangle.width*scale, height: rectangle.height*scale)
        let shade = NSBezierPath(rect: display); shade.appendRect(box); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill(); shade.fill()
        NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect: box); outline.lineWidth = 2; outline.stroke()
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let value = convert(event.locationInWindow, from: nil), scale = CGFloat(image.width)/display.width
        return CGPoint(x: min(CGFloat(image.width), max(0, (value.x-display.minX)*scale)), y: min(CGFloat(image.height), max(0, (value.y-display.minY)*scale)))
    }
    override func mouseDown(with event: NSEvent) {
        guard cropping else { return }
        window?.makeFirstResponder(self); start = point(event); original = rectangle
        let tolerance = 7 * CGFloat(image.width) / display.width
        let touches = rectangle.insetBy(dx: -tolerance, dy: -tolerance).contains(start)
        edgeX = touches && abs(start.x-rectangle.minX) < tolerance ? -1 : touches && abs(start.x-rectangle.maxX) < tolerance ? 1 : 0
        edgeY = touches && abs(start.y-rectangle.minY) < tolerance ? -1 : touches && abs(start.y-rectangle.maxY) < tolerance ? 1 : 0
        moving = edgeX == 0 && edgeY == 0 && rectangle != imageBounds && rectangle.contains(start)
    }
    override func mouseDragged(with event: NSEvent) {
        guard cropping else { return }
        let end = point(event)
        if moving { rectangle.origin = CGPoint(x: min(CGFloat(image.width)-rectangle.width, max(0, original.minX+end.x-start.x)).rounded(), y: min(CGFloat(image.height)-rectangle.height, max(0, original.minY+end.y-start.y)).rounded()) }
        else if edgeX != 0 || edgeY != 0 {
            let left = edgeX == -1 ? min(end.x, original.maxX-1).rounded() : original.minX
            let top = edgeY == -1 ? min(end.y, original.maxY-1).rounded() : original.minY
            let right = edgeX == 1 ? max(end.x, original.minX+1).rounded() : original.maxX
            let bottom = edgeY == 1 ? max(end.y, original.minY+1).rounded() : original.maxY
            rectangle = CGRect(x: left, y: top, width: right-left, height: bottom-top)
        } else {
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: max(1, abs(start.x-end.x)), height: max(1, abs(start.y-end.y))).integral.intersection(imageBounds)
            guard !box.isEmpty else { return }
            rectangle = box
        }
        updated()
    }
    override func keyDown(with event: NSEvent) {
        guard cropping, [123,124,125,126].contains(event.keyCode) else { super.keyDown(with: event); return }
        let dx: CGFloat = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : 0
        let dy: CGFloat = event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : 0
        if event.modifierFlags.contains(.shift) { rectangle.size = CGSize(width: min(CGFloat(image.width)-rectangle.minX, max(1, rectangle.width+dx)), height: min(CGFloat(image.height)-rectangle.minY, max(1, rectangle.height+dy))) }
        else { rectangle.origin = CGPoint(x: min(CGFloat(image.width)-rectangle.width, max(0, rectangle.minX+dx)), y: min(CGFloat(image.height)-rectangle.height, max(0, rectangle.minY+dy))) }
        updated()
    }
    private func updated() {
        needsDisplay = true; changed?()
        setAccessibilityValue(String(format: L("x %d, y %d, width %d, height %d"),
            Int(rectangle.minX), Int(rectangle.minY), Int(rectangle.width), Int(rectangle.height)))
    }
}
#endif
