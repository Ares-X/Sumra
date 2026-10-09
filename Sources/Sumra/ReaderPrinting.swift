#if os(macOS)
import AppKit
import SumraCore

private final class PrintPageResult: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Result<Data, Error>?

    func finish(_ result: Result<Data, Error>) {
        lock.lock(); value = result; lock.unlock()
        ready.signal()
    }
    func take() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw ReadError("Cannot read the prepared print page") }
        return try value.get()
    }
}

/// AppKit owns the system print panel and spooling. Native PDFs arrive as
/// MuPDF Print-usage output; other books use their existing vector PDF export.
@MainActor
enum ReaderPrinting {
    enum Scaling: Int {
        case actual, shrink, fit, stretch
        var title: String {
            switch self {
            case .actual: return "Actual size (1:1)"
            case .shrink: return "Shrink pages to printable area"
            case .fit: return "Fit pages to printable area"
            case .stretch: return "Stretch pages to fill paper"
            }
        }
    }
    nonisolated private static let scalingKey = "SumraPrintScaling", rotationKey = "SumraPrintRotation", centerKey = "SumraPrintCenter"

    static func printPDF(_ url: URL, info sourceInfo: NSPrintInfo, title: String,
                         preferences: PDFDocumentInfo.ViewerPreferences? = nil,
                         regions: [[CGRect]]? = nil, rotation: Int = 0,
                         contentBounds: [CGRect]? = nil, selection: Bool = false) throws -> Bool {
        let view = try PDFPrintView(url: url, regions: regions, rotation: rotation, contentBounds: contentBounds, selection: selection)
        return try printPDF(view, info: sourceInfo, title: title, preferences: preferences)
    }

    static func printPDF(_ file: NativeFile, temporary: TemporaryDirectory, info: NSPrintInfo, title: String,
                         preferences: PDFDocumentInfo.ViewerPreferences, selectedPages: [Int]? = nil,
                         regions: [[CGRect]]? = nil, rotation: Int = 0) throws -> Bool {
        let view = try PDFPrintView(file: file, temporary: temporary, selectedPages: selectedPages,
                                   regions: regions, rotation: rotation)
        return try printPDF(view, info: info, title: title, preferences: preferences)
    }

    static func printMarkdown(_ pages: Pages, snapshot: Pages.MarkdownPrintSnapshot,
                              info: NSPrintInfo, title: String, rotation: Int,
                              documentIsCurrent: @escaping () -> Bool) throws -> Bool {
        let view = try PDFPrintView(pageCount: snapshot.count, rotation: rotation, preservePrintText: true) { page in
            guard documentIsCurrent() else { throw ReadError("The document changed while printing") }
            let bytes = try markdownPage(pages, snapshot: snapshot, page: page)
            guard documentIsCurrent() else { throw ReadError("The document changed while printing") }
            return bytes
        }
        return try printPDF(view, info: info, title: title, preferences: nil, markdownPageCount: snapshot.count) {
            guard documentIsCurrent(),
                  NativeFile.FileVersion(pages.pdfSourceURL)?.signature == snapshot.sourceSignature else {
                throw ReadError("The Markdown source changed while printing. The system output was retained.")
            }
        }
    }

    // AppKit requests pages synchronously, while the live decoder belongs to
    // Pages. The worker only asks that actor for one page's PDF bytes; no
    // NativeFile crosses actor boundaries and the main actor never runs MuPDF.
    private static func markdownPage(_ pages: Pages, snapshot: Pages.MarkdownPrintSnapshot, page: Int) throws -> Data {
        let result = PrintPageResult()
        let worker = Task.detached(priority: .userInitiated) {
            do { result.finish(.success(try await pages.markdownPrintPage(page - 1, snapshot: snapshot))) }
            catch { result.finish(.failure(error)) }
        }
        guard result.ready.wait(timeout: .now() + 120) == .success else {
            worker.cancel()
            throw ReadError("Timed out preparing page \(page) for printing")
        }
        return try result.take()
    }

    private static func printPDF(_ view: PDFPrintView, info sourceInfo: NSPrintInfo, title: String,
                                 preferences: PDFDocumentInfo.ViewerPreferences?, markdownPageCount: Int? = nil,
                                 validateSource: (() throws -> Void)? = nil) throws -> Bool {
        let operation = try makePrintOperation(view, info: sourceInfo, title: title,
                                               preferences: preferences, markdownPageCount: markdownPageCount)
        if let markdownPageCount, markdownPageCount > 999_999, operation.showsPrintPanel {
            guard operation.printPanel.runModal(with: operation.printInfo) == NSApplication.ModalResponse.OK.rawValue else {
                return false
            }
            guard let options = operation.printPanel.accessoryControllers.first(where: { $0 is Options }) as? Options else {
                throw ReadError("Cannot read the Markdown print page range")
            }
            try options.applyExtendedRange(to: operation.printInfo)
            operation.showsPrintPanel = false
        }
        let completed = operation.run()
        if let error = view.error { throw error }
        if completed {
            if operation.printInfo.jobDisposition == .save { try validateSource?() }
            try view.finishSavedPrint(operation)
        }
        return completed
    }

    static func makePrintOperation(_ view: PDFPrintView, info sourceInfo: NSPrintInfo, title: String,
                                   preferences: PDFDocumentInfo.ViewerPreferences?, markdownPageCount: Int? = nil) throws -> NSPrintOperation {
        let info = sourceInfo.copy() as! NSPrintInfo
        if preferences?.printScaling == "None" { info.printSettings[scalingKey] = Scaling.actual.rawValue }
        else if info.printSettings[scalingKey] == nil { info.printSettings[scalingKey] = Scaling.shrink.rawValue }
        if info.printSettings[rotationKey] == nil { info.printSettings[rotationKey] = 0 }
        if info.printSettings[centerKey] == nil { info.printSettings[centerKey] = false }
        if let copies = preferences?.numCopies, copies > 0 { info.dictionary()[NSPrintInfo.AttributeKey.copies] = min(copies, 9999) }
        let modes: [String: PMDuplexMode] = ["Simplex": PMDuplexMode(kPMDuplexNone),
            "DuplexFlipShortEdge": PMDuplexMode(kPMDuplexTumble), "DuplexFlipLongEdge": PMDuplexMode(kPMDuplexNoTumble)]
        if let duplex = preferences?.duplex, let mode = modes[duplex],
           PMSetDuplex(OpaquePointer(info.pmPrintSettings()), mode) == noErr { info.updateFromPMPrintSettings() }
        info.horizontalPagination = .clip; info.verticalPagination = .clip
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling])
        let options = Options()
        if let markdownPageCount {
            guard let last = UInt32(exactly: markdownPageCount), last > 0,
                  PMSetPageRange(OpaquePointer(operation.printInfo.pmPrintSettings()), 1, last) == noErr else {
                throw ReadError("Cannot set the Markdown print page range")
            }
            // The system preview eagerly enumerates every page for thumbnails,
            // even when the print view supplies Markdown pages on demand.
            operation.printPanel.options.remove(.showsPreview)
            if markdownPageCount > 999_999 {
                // AppKit's From field rejects seven-digit page numbers. Use
                // the existing accessory to retain the selection until print.
                operation.printPanel.options.remove(.showsPageRange)
                options.configureExtendedRange(count: markdownPageCount, info: operation.printInfo)
            }
        }
        operation.printPanel.addAccessoryController(options)
        operation.pageOrder = .ascendingPageOrder
        return operation
    }

    // SumatraDialogs::Sheet_Print_Advanced_Proc. These are GUI options, not
    // command-line settings. AppKit's printInfo remains their single owner.
    final class Options: NSViewController, NSPrintPanelAccessorizing {
        nonisolated private static let optionKeyPaths: Set<String> = ["scaling", "rotation", "center"]
        nonisolated private static let summaryKeyPaths = optionKeyPaths.union(["printAllPages", "firstPrintPage", "lastPrintPage"])
        private(set) var extendedPageCount: Int?
        // The previewless panel can replace NSPrintInfo's standard range when
        // it closes. Keep the user's choice here until the operation starts.
        private var allValue = true, firstValue = 1, lastValue = 1
        @objc dynamic var printAllPages: Bool {
            get { allValue }
            set { allValue = newValue }
        }
        @objc dynamic var firstPrintPage: Int {
            get { firstValue }
            set {
                guard let count = extendedPageCount, (1...count).contains(newValue), newValue <= lastValue else { return }
                firstValue = newValue
            }
        }
        @objc dynamic var lastPrintPage: Int {
            get { lastValue }
            set {
                guard let count = extendedPageCount, (1...count).contains(newValue), newValue >= firstValue else { return }
                lastValue = newValue
            }
        }
        func configureExtendedRange(count: Int, info: NSPrintInfo) {
            extendedPageCount = count
            allValue = info.dictionary()[NSPrintInfo.AttributeKey.allPages] as? Bool != false
            firstValue = allValue ? 1 : (info.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? Int ?? 1)
            lastValue = allValue ? count : (info.dictionary()[NSPrintInfo.AttributeKey.lastPage] as? Int ?? count)
        }
        func applyExtendedRange(to info: NSPrintInfo) throws {
            guard let count = extendedPageCount, (1...count).contains(firstValue),
                  (firstValue...count).contains(lastValue) else {
                throw ReadError("Choose valid Markdown pages to print")
            }
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = allValue
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = allValue ? 1 : firstValue
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = allValue ? count : lastValue
            _ = info.pmPrintSettings()
        }
        // Dictionary entries do not emit KVO. These observable accessors write
        // the same NSPrintInfo that the preview and print view consume.
        @objc dynamic var scaling: Int {
            get { (representedObject as? NSPrintInfo)?.printSettings[scalingKey] as? Int ?? Scaling.shrink.rawValue }
            set { (representedObject as? NSPrintInfo)?.printSettings[scalingKey] = newValue }
        }
        @objc dynamic var rotation: Int {
            get { (representedObject as? NSPrintInfo)?.printSettings[rotationKey] as? Int ?? 0 }
            set { (representedObject as? NSPrintInfo)?.printSettings[rotationKey] = newValue }
        }
        @objc dynamic var center: Bool {
            get { (representedObject as? NSPrintInfo)?.printSettings[centerKey] as? Bool ?? false }
            set { (representedObject as? NSPrintInfo)?.printSettings[centerKey] = newValue }
        }
        override func loadView() {
            title = "Sumra"
            let scaling = NSPopUpButton()
            for mode in [Scaling.shrink, .fit, .stretch, .actual] {
                scaling.addItem(withTitle: L(mode.title)); scaling.lastItem?.tag = mode.rawValue
            }
            scaling.bind(.selectedTag, to: self, withKeyPath: "scaling", options: nil)
            let rotation = NSPopUpButton()
            for angle in [0, 90, 180, 270] {
                rotation.addItem(withTitle: angle == 0 ? L("None") : "\(angle)°"); rotation.lastItem?.tag = angle
            }
            rotation.bind(.selectedTag, to: self, withKeyPath: "rotation", options: nil)
            let center = NSButton(checkboxWithTitle: L("Center page horizontally on the paper"), target: nil, action: nil)
            center.bind(.value, to: self, withKeyPath: "center", options: nil)
            scaling.setAccessibilityLabel(L("Page scaling")); rotation.setAccessibilityLabel(L("Rotate printout:"))
            let grid = NSGridView(views: [[NSTextField(labelWithString: L("Page scaling")), scaling],
                [NSTextField(labelWithString: L("Rotate printout:")), rotation], [NSGridCell.emptyContentView, center]])
            if let count = extendedPageCount {
                let all = NSButton(checkboxWithTitle: L("All pages"), target: nil, action: nil)
                all.bind(.value, to: self, withKeyPath: "printAllPages", options: nil)
                let formatter = NumberFormatter()
                formatter.numberStyle = .none
                formatter.allowsFloats = false
                formatter.minimum = 1
                formatter.maximum = NSNumber(value: count)
                let first = NSTextField(), last = NSTextField()
                for (field, key) in [(first, "firstPrintPage"), (last, "lastPrintPage")] {
                    field.formatter = formatter
                    field.widthAnchor.constraint(equalToConstant: 100).isActive = true
                    field.bind(.value, to: self, withKeyPath: key, options: nil)
                    field.bind(.enabled, to: self, withKeyPath: "printAllPages",
                               options: [.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName])
                }
                first.setAccessibilityLabel(L("First page")); last.setAccessibilityLabel(L("Last page"))
                grid.addRow(with: [NSGridCell.emptyContentView, all])
                grid.addRow(with: [NSTextField(labelWithString: L("Pages")),
                                   NSStackView(views: [first, NSTextField(labelWithString: L("to")), last])])
            }
            grid.rowSpacing = 10; grid.columnSpacing = 12
            grid.frame.size = grid.fittingSize; view = grid
        }
        func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
            let mode = Scaling(rawValue: scaling) ?? .shrink
            var items: [[NSPrintPanel.AccessorySummaryKey: String]] =
                [[.itemName: L("Page scaling"), .itemDescription: L(mode.title)],
                 [.itemName: L("Rotate printout:"), .itemDescription: "\(rotation)°"],
                 [.itemName: L("Center page horizontally on the paper"), .itemDescription: L(center ? "Yes" : "No")]]
            if extendedPageCount != nil {
                items.append([.itemName: L("Pages"),
                              .itemDescription: printAllPages ? L("All pages") : "\(firstPrintPage)–\(lastPrintPage)"])
            }
            return items
        }
        func keyPathsForValuesAffectingPreview() -> Set<String> {
            Self.optionKeyPaths
        }
        override class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String> {
            let inherited = super.keyPathsForValuesAffectingValue(forKey: key)
            if key == "localizedSummaryItems" { return inherited.union(summaryKeyPaths) }
            if optionKeyPaths.contains(key) { return inherited.union(["representedObject.printSettings"]) }
            return inherited
        }
    }

    // Native PDF output already contains Print appearances and selection
    // clipping. Other books supply optional regions in unrotated PDF coordinates.
    // Quartz handles page rotation; NSView retains the system pagination controls.
    final class PDFPrintView: NSView {
        private struct Page {
            let document: CGPDFDocument
            let page: CGPDFPage
            let region: CGRect
            let clips: [CGRect]?
            let contentBounds: CGRect?
            let sourcePDF: Data?

            func size(rotation: Int) -> CGSize {
                let size = region.size
                return (Int(page.rotationAngle) + rotation) % 180 != 0
                    ? CGSize(width: size.height, height: size.width) : size
            }
        }
        private let pageCount: Int
        private let loadPage: (Int) throws -> Page
        private let scaling: Scaling
        private let selection: Bool
        private let rotation: Int
        private var cachedPage: (index: Int, value: Page)?
        private(set) var error: Error?
        private var pageNumber = 1
        private var placement = NSPoint.zero
        private var preservesPrintText = false
        private var sourcePrintPDF: NativePDFTools.SourcePrintPDF?
        private var lastSourcePrintPage: Int?

        init(url: URL, scaling: Scaling = .shrink, regions requested: [[CGRect]]? = nil, rotation: Int = 0,
             contentBounds: [CGRect]? = nil, selection: Bool = false) throws {
            guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, document.numberOfPages > 0 else {
                throw ReadError("Cannot read the print document")
            }
            guard rotation % 90 == 0 else { throw ReadError("Invalid print rotation") }
            if let requested, requested.count != document.numberOfPages { throw ReadError("Select a page area first") }
            if let contentBounds, contentBounds.count != document.numberOfPages ||
                contentBounds.contains(where: { ![$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }) {
                throw ReadError("Invalid print content dimensions")
            }
            var regions = [CGRect]()
            var clips = [[CGRect]]()
            for index in 1...document.numberOfPages {
                guard let page = document.page(at: index) else { throw ReadError("Cannot read a print page") }
                let box = page.getBoxRect(.mediaBox)
                guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), !box.isEmpty, !box.isNull else {
                    throw ReadError("Invalid print page dimensions")
                }
                let areas = requested?[index - 1]
                if let areas, areas.contains(where: { $0.isEmpty || $0.isNull || ![$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }) {
                    throw ReadError("Invalid print page dimensions")
                }
                let clipped = areas?.map { $0.intersection(page.getBoxRect(.cropBox)).intersection(box) }.filter { !$0.isEmpty && !$0.isNull }
                let region = clipped?.reduce(CGRect.null) { $0.union($1) } ?? box
                guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite), !region.isEmpty, !region.isNull else {
                    throw ReadError("The selection is outside the page")
                }
                regions.append(region)
                clips.append(clipped ?? [])
            }
            pageCount = document.numberOfPages
            loadPage = { index in
                guard let page = document.page(at: index) else { throw ReadError("Cannot read a print page") }
                return Page(document: document, page: page, region: regions[index - 1], clips: requested == nil ? nil : clips[index - 1], contentBounds: contentBounds?[index - 1], sourcePDF: nil)
            }
            self.scaling = scaling; self.rotation = rotation % 360
            self.selection = selection || requested != nil
            super.init(frame: .zero)
            frame.size = try self.page(1).size(rotation: self.rotation)
        }

        init(file: NativeFile, temporary: TemporaryDirectory, scaling: Scaling = .shrink,
             selectedPages: [Int]? = nil, regions: [[CGRect]]? = nil, rotation: Int = 0) throws {
            guard file.engine == .mupdf, file.count > 0, rotation % 90 == 0 else {
                throw ReadError("Invalid PDF print request")
            }
            if let selectedPages, selectedPages.isEmpty || selectedPages.contains(where: { !(0..<file.count).contains($0) }) {
                throw ReadError("Choose valid pages to print")
            }
            let count = selectedPages?.count ?? file.count
            if let regions, regions.count != count { throw ReadError("Select a page area first") }
            pageCount = count; self.scaling = scaling; selection = regions != nil
            // MuPDF emits the requested rotation and selection clipping into
            // each page's vectors. Only panel rotation remains for Quartz.
            self.rotation = 0
            loadPage = { index in
                let sourcePage = selectedPages?[index - 1] ?? index - 1
                let output = temporary.url.appendingPathComponent("PrintPage.pdf")
                let content = try file.printPDF(to: output, selectedPages: [sourcePage],
                    regions: regions.map { [$0[index - 1]] }, rotation: rotation)
                // CGPDF reads streams lazily. Retain this page's immutable
                // bytes in its provider before the scratch file is reused.
                let bytes = try Data(contentsOf: output)
                return try PDFPrintView.singlePage(bytes, contentBounds: content.first)
            }
            // Custom pagination supplies the real size when AppKit requests
            // a page; creating the view must not render the first page.
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        init(pageCount: Int, rotation: Int = 0, preservePrintText: Bool = false,
             pageData: @escaping (Int) throws -> Data) throws {
            guard pageCount > 0, rotation % 90 == 0 else { throw ReadError("Invalid print request") }
            self.pageCount = pageCount; scaling = .shrink; selection = false; self.rotation = rotation % 360
            loadPage = { index in
                try PDFPrintView.singlePage(pageData(index))
            }
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            preservesPrintText = preservePrintText
        }

        private static func singlePage(_ bytes: Data, contentBounds: CGRect? = nil) throws -> Page {
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let document = CGPDFDocument(provider), document.isUnlocked,
                  document.numberOfPages == 1, let page = document.page(at: 1) else {
                throw ReadError("Cannot read the print document")
            }
            let box = page.getBoxRect(.mediaBox)
            guard !box.isEmpty, !box.isNull, [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else {
                throw ReadError("Invalid print page dimensions")
            }
            return Page(document: document, page: page, region: box, clips: nil, contentBounds: contentBounds, sourcePDF: bytes)
        }

        // Quartz may merge distinct font aliases and discard their ToUnicode
        // maps while replaying a PDF. Save jobs retain the original native
        // objects and the exact drawing transform for the selected pages.
        // Physical printing and copying operations keep AppKit's normal path.
        func finishSavedPrint(_ operation: NSPrintOperation) throws {
            guard preservesPrintText, operation.printInfo.jobDisposition == .save else { return }
            let info = operation.printInfo
            let session = OpaquePointer(info.pmPrintSession()), settings = OpaquePointer(info.pmPrintSettings())
            var type = PMDestinationType(kPMDestinationInvalid)
            var location: Unmanaged<CFURL>?, format: Unmanaged<CFString>?
            let typeStatus = PMSessionGetDestinationType(session, settings, &type)
            let locationStatus = PMSessionCopyDestinationLocation(session, settings, &location)
            let formatStatus = PMSessionCopyDestinationFormat(session, settings, &format)
            let destination = location?.takeRetainedValue() as URL?
            let mime = format?.takeRetainedValue() as String?
            guard typeStatus == noErr, type == PMDestinationType(kPMDestinationFile),
                  locationStatus == noErr, formatStatus == noErr, mime == "application/pdf",
                  let output = info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL,
                  let destination, output.standardizedFileURL == destination.standardizedFileURL,
                  let sourcePrintPDF else {
                throw ReadError("Cannot preserve text in this saved print PDF. The system output was retained.")
            }
            try sourcePrintPDF.finish(output)
            self.sourcePrintPDF = nil
        }

        private func page(_ index: Int) throws -> Page {
            if let error { throw error }
            if let cachedPage, cachedPage.index == index { return cachedPage.value }
            cachedPage = nil
            let value = try loadPage(index)
            cachedPage = (index, value)
            return value
        }

        private func fail(_ error: Error) {
            if self.error == nil { self.error = error }
            if let operation = NSPrintOperation.current {
                _ = PMSessionSetError(OpaquePointer(operation.printInfo.pmPrintSession()), OSStatus(kPMGeneralError))
            }
        }
        required init?(coder: NSCoder) { nil }
        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            range.pointee = NSRange(location: 1, length: pageCount); return true
        }
        override func rectForPage(_ page: Int) -> NSRect {
            guard (1...pageCount).contains(page) else { return .zero }
            let value: Page
            do { value = try self.page(page) }
            catch { fail(error); return .zero }
            pageNumber = page
            if let operation = NSPrintOperation.current, !operation.isCopyingOperation {
                let info = operation.printInfo
                let margins = CGRect(x: info.leftMargin, y: info.bottomMargin,
                    width: info.paperSize.width - info.leftMargin - info.rightMargin,
                    height: info.paperSize.height - info.bottomMargin - info.topMargin)
                let printable = margins.intersection(info.imageablePageBounds)
                // Custom pagination uses view coordinates; AppKit applies
                // the panel's separate percentage after drawing the view.
                frame.size = CGSize(width: printable.width / info.scalingFactor, height: printable.height / info.scalingFactor)
                placement = printable.origin
            } else { frame.size = value.size(rotation: rotation); placement = .zero }
            return bounds
        }
        override func locationOfPrintRect(_ rect: NSRect) -> NSPoint { placement }
        override func beginDocument() {
            // AppKit can render a preview before starting the saved document
            // on the same view. Source pages belong to that drawing pass.
            sourcePrintPDF = nil
            lastSourcePrintPage = nil
            super.beginDocument()
        }
        override func draw(_ dirtyRect: NSRect) {
            let operation = NSPrintOperation.current
            let info = operation?.isCopyingOperation == false ? operation?.printInfo : nil
            let current = operation?.isCopyingOperation == false ? operation?.currentPage ?? 0 : 0
            let index = (1...pageCount).contains(current) ? current : pageNumber
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let rawClip = context.boundingBoxOfClipPath
            let value: Page
            do { value = try self.page(index) }
            catch { fail(error); return }
            let page = value.page
            let mode = (info?.printSettings[scalingKey] as? Int).flatMap(Scaling.init(rawValue:)) ?? scaling
            let extraRotation = info?.printSettings[rotationKey] as? Int ?? 0
            let box = page.getBoxRect(.mediaBox), size = value.size(rotation: rotation)
            let paper = info?.paperSize ?? bounds.size
            let landscape = info.map { $0.orientation == .landscape } ?? (paper.width > paper.height)
            // CalculatePrintPageLayout rotates landscape pages anticlockwise
            // onto portrait paper, then adds the paper and user rotations.
            // Print.cpp's selection path keeps the reader rotation instead;
            // a wide selection is not a landscape page.
            let autoRotation = selection ? 0 : ((size.width > size.height ? 270 : 0) + (landscape ? 90 : 0)) % 360
            let printRotation = rotation + autoRotation + extraRotation
            let rotated = (Int(page.rotationAngle) + printRotation) % 180 != 0
            let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let transform = page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: pageSize),
                rotate: Int32(printRotation), preserveAspectRatio: true)
            let region = value.region.applying(transform)
            let panelScale = info?.scalingFactor ?? 1
            let horizontal = bounds.width * panelScale / region.width, vertical = bounds.height * panelScale / region.height
            var content = value.contentBounds.map { $0.applying(transform).intersection(region) } ?? region
            if content.isEmpty || content.isNull { content = region }
            let scale: CGFloat
            switch mode {
            case .actual: scale = 1
            case .stretch: scale = min(horizontal, vertical)
            case .shrink, .fit:
                // CalculatePrintPageLayout: fit the ink inside printable bounds,
                // while retaining the whole page within the physical paper.
                let fitted = selection ? min(horizontal, vertical) :
                    min(bounds.width * panelScale / content.width, bounds.height * panelScale / content.height,
                        paper.width / region.width, paper.height / region.height)
                scale = mode == .shrink ? min(1, fitted) : fitted
            }
            let xScale = mode == .stretch && !selection ? horizontal : scale, yScale = mode == .stretch && !selection ? vertical : scale
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to: bounds)
            if mode == .actual {
                // Actual size starts at the paper's top-left unless the user
                // explicitly requests horizontal centering (Print.cpp).
                let centered = info?.printSettings[centerKey] as? Bool == true
                let x = selection ? -region.minX :
                    ((centered ? (paper.width - region.width * panelScale) / 2 : 0) - placement.x) / panelScale - region.minX
                let y = selection ? bounds.height - region.maxY : (paper.height - placement.y) / panelScale - region.maxY
                context.translateBy(x: x, y: y)
            } else if selection || mode == .stretch {
                context.translateBy(x: bounds.midX, y: bounds.midY)
                context.scaleBy(x: xScale, y: yScale)
                context.translateBy(x: -region.midX, y: -region.midY)
            } else {
                let finalScale = scale * panelScale
                var offset = CGPoint(x: (paper.width - region.width * finalScale) / 2 - region.minX * finalScale,
                                     y: (paper.height - region.height * finalScale) / 2 - region.minY * finalScale)
                let onPaper = content.applying(CGAffineTransform(scaleX: finalScale, y: finalScale)).offsetBy(dx: offset.x, dy: offset.y)
                let printable = CGRect(origin: placement, size: CGSize(width: bounds.width * panelScale, height: bounds.height * panelScale))
                if onPaper.minX < printable.minX { offset.x += printable.minX - onPaper.minX }
                else if onPaper.maxX > printable.maxX { offset.x -= onPaper.maxX - printable.maxX }
                if onPaper.minY < printable.minY { offset.y += printable.minY - onPaper.minY }
                else if onPaper.maxY > printable.maxY { offset.y -= onPaper.maxY - printable.maxY }
                context.translateBy(x: (offset.x - placement.x) / panelScale, y: (offset.y - placement.y) / panelScale)
                context.scaleBy(x: scale, y: scale)
            }
            context.concatenate(transform)
            context.clip(to: value.region)
            if let clips = value.clips { context.clip(to: clips) }
            if preservesPrintText, let operation, !operation.isCopyingOperation,
               info?.jobDisposition == .save {
                do {
                    // Native print-page clips are rectangles and all rotations
                    // are quarter turns. A bounding rectangle cannot describe
                    // arbitrary selection clips or imposed print layouts.
                    let tolerance: CGFloat = 0.01
                    guard value.clips == nil, rawClip.isFinitePrintRect,
                          abs(rawClip.minX - bounds.minX) < tolerance,
                          abs(rawClip.minY - bounds.minY) < tolerance,
                          abs(rawClip.width - bounds.width) < tolerance,
                          abs(rawClip.height - bounds.height) < tolerance,
                          let bytes = value.sourcePDF else {
                        throw ReadError("This print layout cannot preserve searchable text.")
                    }
                    if let lastSourcePrintPage, index < lastSourcePrintPage {
                        throw ReadError("This print page order cannot preserve searchable text.")
                    }
                    if lastSourcePrintPage != index {
                        if sourcePrintPDF == nil { sourcePrintPDF = try NativePDFTools.SourcePrintPDF() }
                        try sourcePrintPDF?.add(bytes, paperSize: paper, transform: context.ctm,
                                                clip: context.boundingBoxOfClipPath)
                        lastSourcePrintPage = index
                    }
                } catch { fail(error); return }
            }
            context.drawPDFPage(page)
        }
    }
}

private extension CGRect {
    var isFinitePrintRect: Bool {
        !isEmpty && !isNull && [minX, minY, width, height].allSatisfy(\.isFinite)
    }
}
#endif
