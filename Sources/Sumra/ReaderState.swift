#if os(macOS)
import Darwin
import SumraCore
import WebKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class PDFCopyFormatPicker: NSObject {
    private weak var panel: NSSavePanel?
    private let sourceExtension: String
    private let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    private var previousOriginalFile = false
    var originalFile: Bool { picker.indexOfSelectedItem == 1 }

    init(panel: NSSavePanel, source: URL) {
        self.panel = panel
        sourceExtension = source.pathExtension
        super.init()
        picker.addItems(withTitles: [L("PDF"), L("Original file (without PDF edits)")])
        picker.setAccessibilityLabel(L("File format"))
        picker.target = self
        picker.action = #selector(formatChanged)
        let label = NSTextField(labelWithString: L("File format"))
        let stack = NSStackView(views: [label, picker])
        stack.orientation = .horizontal
        panel.accessoryView = stack
    }

    @objc private func formatChanged() {
        guard let panel, originalFile != previousOriginalFile else { return }
        let oldExtension = previousOriginalFile ? sourceExtension : "pdf"
        let newExtension = originalFile ? sourceExtension : "pdf"
        var name = panel.nameFieldStringValue
        if !oldExtension.isEmpty, name.lowercased().hasSuffix("." + oldExtension.lowercased()) {
            name.removeLast(oldExtension.count + 1)
        }
        // Let the native panel validate the original extension as well as PDF.
        let type = originalFile ? UTType(filenameExtension: sourceExtension, conformingTo: .data) : .pdf
        panel.allowedContentTypes = type.map { [$0] } ?? []
        panel.allowsOtherFileTypes = originalFile
        if !newExtension.isEmpty, !name.lowercased().hasSuffix("." + newExtension.lowercased()) {
            name += "." + newExtension
        }
        panel.nameFieldStringValue = name
        previousOriginalFile = originalFile
    }
}

enum ReaderAction: Equatable {
    case none, print, style, toc, copy, copyImage, selectAll, selectCurrentPage, readAloud, exportPDF, zoomToSelection
    case copySelectionImage, saveSelection, printSelection, searchSelectionWithLens
    case speechHighlight(location: Int, length: Int)
    case readAloudFromTop, readAloudFromCursor, readAloudSelection
    case page(Int), href(String), zoom(Double), fit(String), rotate(Int)
    case turnPages(Int, toBottom: Bool = false)
    case find(String, backwards: Bool = false, options: TextSearchOptions? = nil, fromSelection: Bool = false, inResults: Bool = false)
    case scroll(ReaderScrollDirection, ReaderScrollAmount, count: Int = 1), location(String)
    case selectAnnotation(page: Int, index: Int)
    case restore(ReadingPosition), annotate(String, preset: PDFAnnotationPreset? = nil, at: ReadingPosition? = nil), deleteAnnotation
    case preservePosition(ReadingPosition)
}

enum ReaderScrollDirection: String { case up, down, left, right }
enum ReaderScrollAmount: String { case line, halfPage, page }

enum CursorPositionUnit: String {
    case points = "pt", millimeters = "mm", inches = "in"
    var pointsPerUnit: CGFloat {
        switch self {
        case .points: return 1
        case .millimeters: return 72 / 25.4
        case .inches: return 72
        }
    }
}

@MainActor
enum ReaderScroll {
    // SumatraPDF.cpp's line/page/half-page command branches. Whether an axis
    // needs scrolling is distinct from whether this particular step can move.
    static func pageTurn(in scroll: NSScrollView?, direction: ReaderScrollDirection, amount: ReaderScrollAmount,
                         fit: String, continuous: Bool, rtl: Bool, count: Int = 1) -> (direction: Int, toBottom: Bool)? {
        guard count != 0 else { return nil }
        let horizontal = direction == .left || direction == .right
        let viewport = scroll?.contentView.safeAreaRect.size ?? .zero
        let canvas = scroll?.documentView?.frame.size ?? .zero
        let needsScroll = horizontal ? canvas.width > viewport.width : canvas.height > viewport.height
        func scrollViewport() -> Bool { perform(in: scroll, direction: direction, amount: amount, count: count) }
        if horizontal {
            // Page-left/right are pure horizontal scrolling commands. Only
            // line-left/right fall through to GoToPageHorizontal (including RTL).
            if amount != .line || needsScroll { _ = scrollViewport(); return nil }
            let forward = (direction == .right) != rtl
            return ((forward == (count > 0)) ? 1 : -1, false)
        }
        switch amount {
        case .line:
            if needsScroll && fit != "content" { _ = scrollViewport(); return nil }
        case .page:
            if fit != "content", scrollViewport() { return nil }
        case .halfPage:
            let moved = scrollViewport()
            guard continuous && !moved else { return nil }
        }
        let step = ((direction == .down) == (count > 0)) ? 1 : -1
        return (step, step < 0 && fit != "content")
    }

    static func perform(in scroll: NSScrollView?, direction: ReaderScrollDirection, amount: ReaderScrollAmount, count: Int = 1) -> Bool {
        guard let scroll, let document = scroll.documentView else { return false }
        let clip = scroll.contentView, original = clip.bounds
        let horizontal = direction == .left || direction == .right
        let visible = clip.safeAreaRect
        let extent = horizontal ? visible.width : visible.height
        let distance = amount == .line ? (horizontal ? scroll.horizontalLineScroll : scroll.verticalLineScroll)
            : amount == .halfPage ? extent / 2 : max(1, extent - (horizontal ? scroll.horizontalPageScroll : scroll.verticalPageScroll))
        let sign: CGFloat = direction == .up || direction == .left ? -1 : 1
        var target = original
        if horizontal { target.origin.x += sign * distance * CGFloat(count) }
        else { target.origin.y += sign * distance * CGFloat(count) * (document.isFlipped ? 1 : -1) }
        target = clip.constrainBoundsRect(target)
        guard abs(target.minX - original.minX) > 0.5 || abs(target.minY - original.minY) > 0.5 else { return false }
        clip.scroll(to: target.origin); scroll.reflectScrolledClipView(clip)
        return true
    }

    static func isAtTextEnd(_ view: NSTextView?) -> Bool {
        // TextKit's canvas height is estimated until its viewport reaches the
        // document endpoint. Read existing layout without forcing more work.
        guard let view, let content = view.textContentStorage,
              let viewport = view.textLayoutManager?.textViewportLayoutController.viewportRange,
              viewport.endLocation.compare(content.documentRange.endLocation) == .orderedSame,
              let clip = view.enclosingScrollView?.contentView,
              clip.bounds.width > 0, clip.bounds.height > 0 else { return false }
        var target = clip.bounds
        target.origin.y += view.isFlipped ? 1 : -1
        return abs(clip.constrainBoundsRect(target).minY - clip.bounds.minY) <= 0.5
    }
}

struct ReaderCommand: Equatable {
    var revision = 0
    var action: ReaderAction = .none
}

struct ContentsItem: Codable {
    let title: String
    let target: String
    var depth = 0
    var page: Int?
    var chapter: Int?
}

// Sumatra RememberFindQuery: one shared, session-only, most-recent-first list.
@MainActor
final class ReaderSearchHistory: ObservableObject {
    static let shared = ReaderSearchHistory()
    @Published private(set) var queries: [String] = []
    func remember(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, queries.first != query else { return }
        queries.removeAll { $0 == query }
        queries.insert(query, at: 0)
        queries = Array(queries.prefix(10))
    }
}

struct MarkdownPassage: Codable, Hashable {
    var path: [Int]
    var offset: Int
    var top: Double
    var text: String
    var end: Bool
}

struct ReadingPosition: Codable, Hashable {
    var page = 0
    var pageCount: Int?
    var x: Double?
    var y: Double?
    var anchor: String?
    var markdownPassage: MarkdownPassage?
    var nativePassage: NativePassage?
    var markdownRenderer: MarkdownRenderer?
    var zoom: Double?
    var fit: String?
    var flow: String?
    var spread: Bool?
    var rtl: Bool?
    var cover: Bool?
    var rotation: Int?
    var font: String?
    var fontSize: Double?
    var lineHeight: Double?
    var margin: Double?
    var theme: String?
    var userCSS: String?
    var useDocumentCSS: Bool?
    var automaticLayout: Bool?
    var invertColors: Bool?
    var grayscale: Bool?
    var documentColors: String?
    var preservePDFImages: Bool?
    var engineeringEnhance: String?
    var customTextColor: UInt32?
    var customBackgroundColor: UInt32?
    var pageMargins: PageMargins?
    var scrollbarMode: String?
    // Only persisted PDF locations need this migration marker. In-memory
    // raster navigation always uses Fitz coordinates, including untagged points.
    var pdfCoordinateSpace: String?

    enum CodingKeys: String, CodingKey {
        case page, pageCount, x, y, anchor, markdownPassage, nativePassage, markdownRenderer, zoom, fit, flow, spread, rtl, cover, rotation, font, fontSize, lineHeight, margin, theme, userCSS, useDocumentCSS, automaticLayout, invertColors, grayscale, documentColors, preservePDFImages, engineeringEnhance, customTextColor, customBackgroundColor, pageMargins, scrollbarMode, pdfCoordinateSpace
    }

    func convertingPDFCoordinates(_ transform: CGAffineTransform) -> ReadingPosition {
        var result = self
        func axis(_ a: CGFloat, _ x: Double?, _ b: CGFloat, _ y: Double?, _ translation: CGFloat) -> Double? {
            guard (a == 0 || x != nil), (b == 0 || y != nil) else { return nil }
            return Double(a) * (x ?? 0) + Double(b) * (y ?? 0) + Double(translation)
        }
        result.x = axis(transform.a, x, transform.c, y, transform.tx)
        result.y = axis(transform.b, x, transform.d, y, transform.ty)
        result.pdfCoordinateSpace = "fitz"
        return result
    }
}

struct ReaderBookmark: Codable, Identifiable {
    var id = UUID()
    var title: String
    var path: String
    var position: ReadingPosition
}

@MainActor
private final class ReaderSpeechDelegate: NSObject, NSSpeechSynthesizerDelegate {
    var finished: ((NSSpeechSynthesizer, Bool) -> Void)?
    var word: ((NSRange) -> Void)?
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of string: String) { word?(characterRange) }
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        finished?(sender, finishedSpeaking)
    }
}

@MainActor
final class ReaderState: ObservableObject {
    @Published var document: ReadingDocument? {
        didSet {
            pdfEditingEnabled = false; nativePDFInfo = nil; nativePDFSelection = nil; nativePDFAnnotationTool = nil
            nativePDFSignatureSelection = nil
            nativePDFFormEditor?.cancel(); nativePDFFormPage = nil; fitPresetRestore = nil
        }
    }
    @Published private(set) var pdfEditingEnabled = false
    @Published var nativePDFInfo: PDFDocumentInfo?
    @Published var nativePDFSelection: NativePDFSelection?
    var nativePDFSignatureSelection: (() async throws -> (page: Int, bounds: CGRect)?)?
    var nativePDFInverseSearchPosition: (() -> (page: Int, point: CGPoint)?)?
    var nativePDFCursorPosition: ((CGPoint) -> CGPoint?)?
    @Published var nativePDFAnnotationTool: NativePDFAnnotationTool? {
        willSet { nativePDFAnnotationTool?.clearPreview() }
    }
    weak var nativePDFFormEditor: NativePDFFormEditor?
    var nativePDFFormPage: Int?
    @Published var busy = false
    @Published var error: String? { didSet { if let error, error != oldValue { ReaderHelp.recordError(error) } } }
    @Published var status = ""
    @Published var page = 0
    @Published var count = 0
    var chapterLayout: ChapterTable?
    private var nativePassageTask: Task<Void, Never>?
    @Published var zoom = 1.0
    @Published var zoomLimit = ReadingZoom.maximum
    @Published var zoomLevels: [Double] = []
    @Published var zoomIncrement = 0.0
    var configuredZoomMaximum: Double { ReadingZoom.maximum(for: zoomLevels) }
    var pageFitZoom: Double?, widthFitZoom: Double?
    var useDocumentOpenAction = false
    @Published var outline: [ContentsItem] = [] {
        didSet {
            // Resolving destinations after the first page must not collapse a
            // branch or clear a selection the reader has already chosen.
            guard outline.count != oldValue.count || zip(outline, oldValue).contains(where: { pair in
                pair.0.title != pair.1.title || pair.0.target != pair.1.target || pair.0.depth != pair.1.depth
            }) else { return }
            let level = UserDefaults.standard.object(forKey: "contentsDepth") as? Int ?? 0
            collapsedContents = level > 0 ? Set(outline.indices.filter { outline[$0].depth >= level - 1 && contentsHasChildren($0) }) : []
            selectedContents = nil
        }
    }
    @Published var collapsedContents = Set<Int>()
    @Published var selectedContents: Int?
    @Published var contentsQuery = ""
    @Published var followContents = true
    @Published var outlineBusy = false
    var generatedContentsTask: Task<Void, Never>?
    @Published var command = ReaderCommand()
    @Published var showContents = false { didSet {
        if showContents { selectSidebar("contents") }
        else { contentsSearchRequested = false }
    } }
    @Published var showFind = false
    @Published private(set) var findFocusRevision = 0
    @Published private(set) var showSearchResults = false
    @Published var findQuery = ""
    @Published private(set) var searchPageRange = ""
    private var pendingFind: Task<Void, Never>?
    private var searchStartMarked = false
    @Published var searchCaseSensitive = false { didSet { if oldValue != searchCaseSensitive, !findQuery.isEmpty { findNext() } } }
    @Published var searchWholeWord = false { didSet { if oldValue != searchWholeWord, !findQuery.isEmpty { findNext() } } }
    @Published var logicalPageLabel: String?
    @Published var spread = false { didSet { if oldValue != spread { fitPresetRestore = nil } } }
    @Published var automaticLayout = false { didSet { if oldValue != automaticLayout { fitPresetRestore = nil } } }
    @Published var landscapeAsSpread = true
    @Published var landscapePages = Set<Int>()
    @Published var rtl = false
    @Published var cover = false { didSet { if oldValue != cover { fitPresetRestore = nil } } }
    @Published var fit = "page" { didSet { if oldValue != fit { fitPresetRestore = nil } } }
    @Published var flow = "paged" { didSet { if oldValue != flow { fitPresetRestore = nil } } }
    private var fitPresetRestore: (fit: String, zoom: Double, flow: String, spread: Bool, automatic: Bool)?
    @Published var scrollbarMode = "smart"
    @Published var font = "system"
    @Published var fontSize = 17.0
    @Published var lineHeight = 1.6
    @Published var margin = 32.0
    @Published var pageMargins: PageMargins?
    @Published var theme = "system"
    @Published var invertColors = false
    @Published var grayscale = false
    @Published var documentColors = "off"
    @Published var preservePDFImages = true
    @Published var engineeringEnhance = "off"
    @Published var customTextColor: UInt32?
    @Published var customBackgroundColor: UInt32?
    @Published var userCSS = ""
    @Published var useDocumentCSS = true
    @Published var typographyForAll = false
    @Published var rotation = 0
    @Published var reflowable = false
    @Published var searchable = false
    @Published var renderRevision = 0
    var location = ReadingPosition()
    @Published var selectedText = ""
    @Published var searchResults: [ContentsItem] = [] {
        didSet { if searchResults.isEmpty { selectedSearchTarget = nil; searchCountCapped = false; searchCounting = false } }
    }
    @Published var selectedSearchTarget: String?
    @Published var searchCountCapped = false
    @Published var searchCounting = false
    var searchCountText: String {
        if searchCounting { return L("Searching…") + " " + String(format: L("%d matches"), searchResults.count) }
        let current = selectedSearchTarget.flatMap { target in searchResults.firstIndex { $0.target == target } }.map { $0 + 1 } ?? 0
        return "\(current) / \(searchResults.count)\(searchCountCapped ? "+" : "")"
    }
    @Published var showThumbnails = false { didSet { if showThumbnails { selectSidebar("thumbnails") } } }
    @Published var showBookmarks = false { didSet { if showBookmarks { selectSidebar("bookmarks") } } }
    @Published var showPalette = false
    @Published var focusCycle = 0
    @Published var paletteMode = "> "
    @Published var paletteContentsVisible = false
    @Published var tabColor: UInt32? { didSet { applyTabColor() } }
    @Published var showAI = false
    @Published var showFiles = false
    @Published var showAnnotations = false { didSet { if showAnnotations { selectSidebar("annotations") } } }
    @Published var annotationsVisible = true
    @Published var highlightFormFields = false
    @Published var showPageBoxes = false
    @Published var showImageBounds = false
    @Published var showFitContentArea = false
    @Published var showPageGrid = false
    @Published var showTransparencyGrid = false
    @Published var pageGridWidth = 72.0
    @Published var pageGridHeight = 72.0
    @Published var pageGridSubdivisions = 4
    @Published var pageGridOffsetX = 0.0
    @Published var pageGridOffsetY = 0.0
    @Published var pageGridColor: UInt32 = 0x8080ff
    @Published var pageGridStyle = "dots"
    @Published var inverseSearchEnabled = UserDefaults.standard.object(forKey: "inverseSearchEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inverseSearchEnabled, forKey: "inverseSearchEnabled") }
    }
    @Published var uniformPageWidth = false
    @Published var trimEmptyMargins = false
    @Published var freePan = false
    @Published var showLinks = false
    @Published var disableLinks = false
    @Published var hoverPreview = true
    @Published var keyboardLinkFollowing = false
    @Published var keyboardTextSelection = false
    @Published var rectangularSelection = false
    @Published var hasSelection = false
    @Published var toolbarVisible = true
    @Published var presentationBlank: String?
    @Published var laserPointer = false
    @Published var readingBar = false
    @Published var readingBarInvert = false
    @Published var readingBarHeight = 36.0
    @Published var showPageInfo = false
    @Published var cursorPositionUnit: CursorPositionUnit?
    func toggleCursorPosition() {
        // Sumatra ToggleCursorPositionInDoc: pt -> mm -> in -> off.
        switch cursorPositionUnit {
        case nil: cursorPositionUnit = .points
        case .points: cursorPositionUnit = .millimeters
        case .millimeters: cursorPositionUnit = .inches
        case .inches: cursorPositionUnit = nil
        }
    }
    @Published var autoScroll = false
    @Published var autoScrollSpeed = 3.0
    @Published var bookmarksByName = false
    @Published var modified = false {
        didSet { if modified { editRevision &+= 1 } }
    }
    @Published var presentation = false
    @Published var bookmarks: [ReaderBookmark] = []
    @Published var speechActive = false
    @Published var speechPaused = false
    @Published var speechRequested = false
    @Published var speechVoice = UserDefaults.standard.string(forKey: "speechVoice") ?? "" {
        didSet { speech.setVoice(speechVoice.isEmpty ? nil : NSSpeechSynthesizer.VoiceName(rawValue: speechVoice)); UserDefaults.standard.set(speechVoice, forKey: "speechVoice") }
    }
    @Published var speechRate = UserDefaults.standard.object(forKey: "speechRate") as? Double ?? 180 {
        didSet { speech.rate = Float(speechRate); UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }
    @Published var speechFollow = true { didSet { if !speechFollow, hasDocument { send(.speechHighlight(location: 0, length: 0)) } } }
    weak var browserView: WKWebView?
    weak var readerScrollView: NSScrollView?
    weak var readerFocusView: NSView?
    weak var contentsFocusView: NSOutlineView?
    weak var contentsSearchField: NSSearchField?
    var contentsSearchRequested = false
    var contentsNeedsFocusTransfer = false
    weak var pageInputField: NSTextField?
    weak var findInputField: NSTextField?
    private var wheelTurnedPage = false
    private var wheelPageTurnTime: TimeInterval?
    weak var window: NSWindow?
    weak var findWindow: NSWindow?
    var createWindow: ((WindowPayload) -> Void)?
    var openAuxiliaryWindow: ((String) -> Void)?
    var browserTemporary: TemporaryDirectory?
    var selectionScreenBounds: (() async -> CGRect?)?

    private var speech = NSSpeechSynthesizer()
    private let speechDelegate = ReaderSpeechDelegate()
    private(set) var speechPage: Int?
    private var speechLocation: PageLocation?
    private var speechNeedsNextPage = false
    private var speechTask: Task<Void, Never>?
    private var speechOffset = 0
    private var speechHighlightEnabled = true
    private var autoScrollTimer: Timer?
    private var history: [ReadingPosition] = []
    private var historyIndex = 0
    private var password: String?
    private var requestedPosition: ReadingPosition?
    private var markdownPositions: [MarkdownRenderer: ReadingPosition] = [:]
    private var recordsHistory = true
    private var requestedHistory: Bool?

    private var pendingActions: [ReaderAction] = []
    private var commandInFlight = false
    private var claimedCommandRevision: Int?
    private(set) var editRevision = 0
    private var loading: Task<Void, Never>?
    private var confirmingClose = false
    private var closeRequestRevision = 0
    private var pdfSaveTask: Task<Bool, Error>?
    private var reloadTask: Task<Void, Never>?
    private var watch: DispatchSourceFileSystemObject?
    private(set) var generation = 0

    init(recordsHistory: Bool = true) {
        self.recordsHistory = recordsHistory
        speech.delegate = speechDelegate
        speechDelegate.word = { [weak self] range in
            guard let self, self.speechFollow, self.speechRequested, self.speechHighlightEnabled else { return }
            self.send(.speechHighlight(location: self.speechOffset + range.location, length: range.length))
        }
        speechDelegate.finished = { [weak self] sender, completed in
            guard let self, sender === self.speech else { return }
            self.speechActive = false
            if completed, let page = self.speechPage {
                if self.speechLocation != nil { self.speechNeedsNextPage = true }
                else { self.speechPage = page + 1 }
                self.readNextPage()
            } else {
                self.speechPaused = false
                self.speechRequested = false
                self.send(.speechHighlight(location: 0, length: 0))
            }
        }
        readPreferences()
        if let data = UserDefaults.standard.data(forKey: "bookmarks"),
           let saved = try? JSONDecoder().decode([ReaderBookmark].self, from: data) { bookmarks = saved }
    }
}

extension ReaderState {
    var isText: Bool {
        if case .text = document?.content { return true }
        return false
    }

    var isPDF: Bool {
        return nativePDF != nil
    }

    var nativePDF: Pages? {
        if case .pages(let pages) = document?.content, pages.isPDF { return pages }
        return nil
    }

    var isFixed: Bool {
        guard let document else { return false }
        switch document.content {
        case .pages: return true
        default: return false
        }
    }

    var isBrowser: Bool {
        if case .browser = document?.content { return true }
        return false
    }

    var isNativeMarkdown: Bool { document?.markdownRenderer == .paged }
    var rasterZoom: Double { isNativeMarkdown ? 1 : zoom }
    var markdownRendererSelection: MarkdownRenderer? { document?.markdownPreference }

    func shouldOpenMarkupSibling(_ url: URL) -> Bool {
        guard case .browser(let source) = document?.content, source is MarkupSource else { return false }
        return ReadingDocument.markupSiblingNeedsDocumentOpen(url)
    }

    var hasTextSelection: Bool { isBrowser ? hasSelection : !selectedText.isEmpty }

    var isCHM: Bool {
        if case .browser(let source) = document?.content { return source is CHMSource }
        return false
    }

    var supportsPagination: Bool { isFixed }

    var supportsSearch: Bool { isPDF || isText || isBrowser || searchable }
    var supportsSearchPageRange: Bool { isFixed && supportsSearch && !reflowable }
    var hasDocument: Bool { document != nil }
    var recordsDocumentHistory: Bool { recordsHistory && !UserDefaults.standard.bool(forKey: "disableHistory") }
    var documentPassword: String { password ?? "" }
    var canGoBackward: Bool { isBrowser ? hasDocument : page > 0 && count > 0 }
    var canGoForward: Bool {
        if isBrowser { return hasDocument }
        return visiblePages.upperBound < count && (!isText || !ReaderScroll.isAtTextEnd(readerFocusView as? NSTextView))
    }
    var visiblePages: Range<Int> { PageRows.range(page: page, count: count, spread: spread && isFixed && !presentation, cover: cover, landscape: landscapeAsSpread ? landscapePages : []) }
    var canSaveCopy: Bool { document?.url.hasDirectoryPath == false }

    var canSave: Bool { isPDF && document?.hasSeparatePDFSource == false }
    var canEditPDF: Bool { pdfEditingEnabled && pdfSaveTask == nil }
    var hasBookmark: Bool { bookmarks.contains { $0.path == document?.url.path } }
    var canNavigateBack: Bool { historyIndex > 0 }
    var canNavigateForward: Bool { historyIndex < history.count - 1 }
    var currentPosition: ReadingPosition {
        var position = location
        if let renderer = document?.markdownRenderer {
            position.markdownRenderer = renderer
            if renderer == .paged { position.markdownPassage = nil }
            else { position.nativePassage = nil }
        }
        position.page = page
        position.pageCount = count > 0 ? count : nil
        position.zoom = zoom
        position.fit = fit
        position.flow = flow
        position.spread = spread
        position.rtl = rtl
        position.cover = cover
        position.rotation = rotation
        position.font = font
        position.fontSize = fontSize
        position.lineHeight = lineHeight
        position.margin = margin
        position.theme = theme
        position.userCSS = userCSS
        position.useDocumentCSS = useDocumentCSS
        position.automaticLayout = automaticLayout
        position.invertColors = invertColors
        position.grayscale = grayscale
        position.documentColors = documentColors
        position.preservePDFImages = preservePDFImages
        position.engineeringEnhance = engineeringEnhance
        position.customTextColor = customTextColor
        position.customBackgroundColor = customBackgroundColor
        position.pageMargins = pageMargins
        position.scrollbarMode = scrollbarMode
        if nativePDF != nil { position.pdfCoordinateSpace = "fitz" }
        return position
    }

    var filePosition: ReadingPosition? {
        guard let document else { return nil }
        var position = currentPosition
        if case .browser(let source as MarkupSource) = document.content {
            let target = position.anchor.flatMap(URL.init(string:))
                ?? (source.pages.indices.contains(position.page) ? source.pages[position.page] : source.startURL)
            // A restore target is not yet the displayed file. Do not pair its
            // coordinates with the old file in preferences, bookmarks or windows.
            guard let file = try? source.fileURL(target),
                  file == document.url.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
            // MarkdownModel::GetDisplayState saves the current file and x/y.
            // Its virtual URL and sibling index belong only to this model's root.
            position.anchor = nil
            position.page = 0
            position.pageCount = nil
        }
        return position
    }

    var pageLabel: String {
        guard count > 0 else { return "—" }
        if let label = logicalPageLabel { return label }
        if reflowable, let anchor = location.anchor, let label = Self.chapterInput(anchor, offset: 1) { return label }
        return String(min(page + 1, count))
    }

    var positionLabel: String {
        guard count > 0 else { return "— / —" }
        if let table = chapterLayout, table.chapterCount > 1 {
            let location = pageLocation(page)
            let pages = table.isLaidOut(location.chapter) ? String(table.pageCount(location.chapter)) : "—"
            return "\(L("Chapter:")) \(location.chapter + 1) / \(table.chapterCount), \(L("Page:")) \(location.page + 1) / \(pages)"
        }
        let physical = "\(min(page + 1, count)) / \(count)"
        return pageLabel == String(page + 1) ? physical : "\(pageLabel) (\(physical))"
    }

    var resolvedTheme: String {
        guard theme == "system" else { return palette.dark ? "dark" : "light" }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    var palette: ReaderTheme {
        let id = theme == "system" ? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light") : theme
        let base = ReaderTheme.all.first { $0.id == id } ?? ReaderTheme.all[0]
        guard customTextColor != nil || customBackgroundColor != nil else { return base }
        return ReaderTheme(id: "custom", name: "Custom", text: customTextColor ?? base.text, background: customBackgroundColor ?? base.background, link: base.link)
    }

    var effectiveUserCSS: String { (palette.id == "light" ? "" : palette.css + "\n") + userCSS }

    var zoomLabel: String {
        if isNativeMarkdown || isText || isBrowser || fit == "custom" || fit == "actual" {
            return String(format: "%.2f%%", zoom * 100).replacingOccurrences(of: ".00%", with: "%")
        }
        return L(ReadingZoom.fitTitles[fit] ?? "Fit Page")
    }
    var canZoomToSelection: Bool {
        isFixed && !isNativeMarkdown && hasSelection
    }
}

extension ReaderState {
    func setPDFEditingEnabled(_ enabled: Bool) {
        guard let pages = nativePDF, (!busy || !enabled), pdfSaveTask == nil, enabled != pdfEditingEnabled else { return }
        let ownsBusy = !busy
        if ownsBusy { busy = true }
        Task {
            defer { if ownsBusy, nativePDF === pages { busy = false } }
            do {
                if !enabled { try await nativePDFFormEditor?.commit() }
                guard nativePDF === pages else { return }
                try await pages.pdfSetEditing(enabled)
                let info = try await pages.pdfInfo()
                guard nativePDF === pages else { return }
                nativePDFInfo = info; pdfEditingEnabled = enabled
                if !enabled { nativePDFSelection = nil; nativePDFAnnotationTool = nil }
            } catch { if nativePDF === pages { self.error = error.localizedDescription } }
        }
    }

    func nativePDFDidChange(_ pages: Pages) async throws {
        let info = try await pages.pdfInfo()
        guard nativePDF === pages else { return }
        nativePDFInfo = info
        if info?.dirty != true { editRevision &+= 1 }
        modified = info?.dirty == true
        renderRevision += 1
    }

    func changeNativePDFHistory(redo: Bool) async throws {
        guard canEditPDF, let pages = nativePDF else { return }
        try await nativePDFFormEditor?.commit()
        guard canEditPDF, nativePDF === pages else { return }
        try await pages.pdfUndo(redo: redo)
        guard nativePDF === pages else { return }
        nativePDFSelection = nil
        try await nativePDFDidChange(pages)
    }

    // Layout changes can remove the input's host before a ReaderCommand runs.
    // Commit at the action boundary so rejected input keeps its original view.
    func deferForNativePDFForm(_ action: @escaping @MainActor () -> Void) -> Bool {
        guard let editor = nativePDFFormEditor else { return false }
        let documentID = document?.id
        Task { [weak self] in
            do {
                try await editor.commit()
                guard let self, self.document?.id == documentID else { return }
                action()
            } catch {
                if self?.document?.id == documentID { self?.error = error.localizedDescription }
            }
        }
        return true
    }

    func send(_ action: ReaderAction) {
        var action = action
        if case .find(let query, let backwards, let options, let selection, let inResults) = action {
            pendingFind?.cancel(); pendingFind = nil
            findQuery = query
            // SearchAndDDE::MarkSearchStart: one return point per find session.
            if selection { searchStartMarked = false }
            if !query.isEmpty, !searchStartMarked {
                recordNavigation()
                searchStartMarked = true
            }
            ReaderSearchHistory.shared.remember(query)
            action = .find(query, backwards: backwards, options: options ?? .init(caseSensitive: searchCaseSensitive, wholeWord: searchWholeWord,
                allowedPages: supportsSearchPageRange ? TextSearchOptions.pages(searchPageRange, count: count) : nil), fromSelection: selection, inResults: inResults)
        }
        if case .page(let page) = action, let table = chapterLayout, table.chapterCount > 1, let location = table.location(page: page) {
            action = .restore(.init(page: page, anchor: table.bookmark(location)))
        }
        if case .pages = document?.content {
            switch action {
            // DisplayModel saves GetScrollState before Relayout. Capture here,
            // before a queued command can observe the newly scaled geometry.
            case .zoom where !isNativeMarkdown: action = .preservePosition(currentPosition)
            case .fit, .rotate: action = .preservePosition(currentPosition)
            default: break
            }
        }
        // Browser zooms are absolute sizes. A newer adjacent pending zoom
        // supersedes the older reflow without changing the in-flight command.
        if (isBrowser || isNativeMarkdown), case .zoom = action, case .zoom? = pendingActions.last {
            pendingActions.removeLast()
        }
        pendingActions.append(action)
        dispatchCommand()
    }

    // A publisher resubscription must not execute an in-flight or completed
    // mutation again. The current document alone may claim its queued command.
    func claimCommand(_ received: ReaderCommand, for pages: Pages) -> Bool {
        guard commandInFlight, command == received, claimedCommandRevision != received.revision,
              case .pages(let current) = document?.content, current === pages else { return false }
        claimedCommandRevision = received.revision
        return true
    }

    func didHandleCommand(_ revision: Int) {
        let documentID = document?.id
        // Defer publication until the representable's update has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.document?.id == documentID, self.command.revision == revision else { return }
            self.commandInFlight = false
            self.dispatchCommand()
        }
    }

    private func dispatchCommand() {
        guard !commandInFlight, !pendingActions.isEmpty else { return }
        commandInFlight = true
        command = .init(revision: command.revision &+ 1, action: pendingActions.removeFirst())
    }

    // Published page numbers are a projection of stable chapter locations.
    // RasterReader is the single consumer of decoder layout notifications.
    func pageLocation(_ page: Int) -> PageLocation { chapterLayout?.location(page: page) ?? .init(page: page) }
    func pageNumber(_ location: PageLocation) -> Int { chapterLayout?.page(for: location) ?? location.page }
    @discardableResult func applyChapterLayout(_ table: ChapterTable) -> Bool {
        guard chapterLayout != table, table.generation >= (chapterLayout?.generation ?? 0) else { return false }
        let old = chapterLayout
        // A one-page chapter changes only laidOut, not Sumatra's generation.
        // A queued earlier snapshot must not undo a newer same-count publication.
        if let old, table.generation == old.generation,
           (0..<old.chapterCount).contains(where: { old.isLaidOut($0) && !table.isLaidOut($0) }) { return false }
        func remap(_ position: ReadingPosition) -> ReadingPosition {
            var position = position
            if let location = position.anchor.flatMap({ ChapterTable.bookmarkLocation($0)?.location }) ?? old?.location(page: position.page),
               let page = table.page(for: location) {
                position.page = page
                position.anchor = position.anchor ?? old?.bookmark(location)
            }
            return position
        }
        let position = remap(currentPosition)
        history = history.map(remap)
        requestedPosition = requestedPosition.map(remap)
        if let old, let speechPage, let location = old.location(page: speechPage) { self.speechPage = table.page(for: location) }
        pendingActions = pendingActions.map { action in
            if case .restore(let position) = action { return .restore(remap(position)) }
            if case .preservePosition(let position) = action { return .preservePosition(remap(position)) }
            if case .page(let page) = action { return .restore(remap(.init(page: page))) }
            return action
        }
        if let old {
            var located = outline, changed = false
            for index in located.indices where located[index].chapter != nil {
                if let page = located[index].page, let location = old.location(page: page), let updated = table.page(for: location), updated != page {
                    located[index].page = updated; changed = true
                }
            }
            if changed { outline = located }
        }
        chapterLayout = table
        count = table.totalPages
        updatePosition(position)
        return true
    }
    func updatePosition(_ position: ReadingPosition, preservingNativePassage: Bool = false) {
        var position = position
        if preservingNativePassage, isNativeMarkdown, position.nativePassage == nil {
            // A restored glyph remains the reflow target when AppKit clamps
            // its viewport point. User input and explicit navigation replace it.
            position.nativePassage = location.nativePassage
        }
        if let renderer = document?.markdownRenderer {
            position.markdownRenderer = renderer
            if renderer == .paged { position.markdownPassage = nil }
            else { position.nativePassage = nil }
        }
        if let table = chapterLayout, let saved = position.anchor.flatMap(ChapterTable.bookmarkLocation), let page = table.page(for: saved.location) {
            position.page = page
        } else if let table = chapterLayout, reflowable, let location = table.location(page: position.page) {
            position.anchor = table.bookmark(location)
        }
        let target = max(0, position.page)
        guard location != position || page != target else { return }
        // DisplayModel::ScrollYTo only notifies chrome when the page changes.
        // Pixel offsets must not rebuild the entire SwiftUI reader on every scroll.
        if page == target, reflowable, location.anchor != position.anchor { objectWillChange.send() }
        location = position
        if page != target { page = target }
        refreshNativePassage()
        // Like DisplayModel/BrowserDocView, scrolling only updates memory.
        // Document/window lifecycle callbacks persist the final position.
    }

    private func refreshNativePassage() {
        nativePassageTask?.cancel(); nativePassageTask = nil
        guard isNativeMarkdown, location.nativePassage == nil,
              case .pages(let pages) = document?.content, let documentID = document?.id else { return }
        let snapshot = currentPosition, revision = renderRevision
        let theme = resolvedTheme, css = effectiveUserCSS
        nativePassageTask = Task {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
                let passage = try await pages.capturePassage(snapshot, theme: theme, userCSS: css)
                guard !Task.isCancelled, document?.id == documentID, renderRevision == revision,
                      page == snapshot.page, location.x == snapshot.x, location.y == snapshot.y,
                      let passage else { return }
                var position = location; position.nativePassage = passage
                updatePosition(position)
            } catch {
                if !Task.isCancelled, document?.id == documentID { self.error = error.localizedDescription }
            }
        }
    }

    func discardNativePassage() {
        guard isNativeMarkdown, location.nativePassage != nil else { return }
        var position = location; position.nativePassage = nil
        updatePosition(position)
    }

    // Translated from Sumatra DisplayModel::AddNavPoint/Navigate: bounded,
    // deduplicated history; a new jump discards the old forward branch.
    func recordNavigation() {
        if historyIndex < history.count { history.removeSubrange(historyIndex..<history.count) }
        let position = currentPosition
        if history.last != position { history.append(position) }
        if history.count > 50 { history.removeFirst() }
        historyIndex = history.count
    }

    func navigate(_ action: ReaderAction) {
        if case .href(let target) = action, searchResults.contains(where: { $0.target == target }) {
            selectedSearchTarget = target
        } else { recordNavigation() }
        send(action)
    }

    func navigateHistory(_ delta: Int) {
        guard delta == -1 ? canNavigateBack : delta == 1 && canNavigateForward else { return }
        if historyIndex == history.count {
            history.append(currentPosition)
            if history.count > 50 { history.removeFirst(); historyIndex -= 1 }
        } else { history[historyIndex] = currentPosition }
        let index = historyIndex + delta
        guard history.indices.contains(index) else { return }
        historyIndex = index
        restore(history[index])
    }

    func restore(_ position: ReadingPosition) {
        if deferForNativePDFForm({ [weak self] in self?.restore(position) }) { return }
        if let renderer = position.markdownRenderer ?? (position.markdownPassage == nil ? nil : .compatible),
           document?.markdownRenderer != nil, renderer != document?.markdownRenderer {
            setMarkdownRenderer(renderer, at: position)
            return
        }
        persist()
        apply(position)
        send(.restore(position))
    }

    // WebKit retains its selection. Transfer text only for a consuming action,
    // rather than copying an entire book on every selection-change notification.
    func selectionText() async throws -> String {
        guard isBrowser else { return selectedText }
        guard let document, let view = browserView,
              let coordinator = view.navigationDelegate as? BrowserReader.Coordinator,
              coordinator.isCurrent, coordinator.ready else { throw ReadError("Browser document is still opening") }
        let url = view.url
        do {
            let text = try await view.callAsyncJavaScript("return window.leafSelectedText()", arguments: [:], in: nil,
                contentWorld: coordinator.scriptWorld) as? String ?? ""
            guard self.document?.id == document.id, browserView === view, view.url == url, coordinator.ready else { throw CancellationError() }
            return text
        } catch {
            guard self.document?.id == document.id, browserView === view, view.url == url, coordinator.ready else { throw CancellationError() }
            throw error
        }
    }

    func documentText(entireDocument: Bool = false) async throws -> String {
        guard let document else { throw ReadError("Open a document first") }
        if let pages = nativePDF {
            guard try await pages.pdfInfo()?.permissions.copy == true else { throw ReadError("This PDF does not allow text extraction") }
            guard self.document?.id == document.id else { throw CancellationError() }
        }
        if !entireDocument, !selectedText.isEmpty { return selectedText }
        switch document.content {
        case .text(let text):
            if entireDocument { return text }
            let string = text as NSString
            guard string.length > 0 else { return "" }
            let offset = min(string.length - 1, max(0, Int(location.anchor ?? "") ?? 0))
            return string.substring(with: string.paragraphRange(for: NSRange(location: offset, length: 0)))
        case .pages(let pages):
            if entireDocument {
                var chunks = [String]()
                let table = try await pages.ensureFullLayout()
                for page in 0..<table.totalPages {
                    try Task.checkCancellation()
                    if let location = table.location(page: page) { chunks.append(try await pages.text(location)) }
                }
                guard self.document?.id == document.id else { throw CancellationError() }
                return chunks.joined(separator: "\n\n")
            }
            let location = pageLocation(page)
            let text = try await pages.text(location)
            guard self.document?.id == document.id else { throw CancellationError() }
            return text
        case .browser:
            guard let view = browserView else { throw ReadError("Browser document is still opening") }
            let text: String = try await withCheckedThrowingContinuation { continuation in
                view.callAsyncJavaScript("return await window.leafText(entireDocument)", arguments: ["entireDocument": entireDocument], in: nil, in: (view.navigationDelegate as? BrowserReader.Coordinator)?.scriptWorld ?? .page) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String ?? "")
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
            guard self.document?.id == document.id else { throw CancellationError() }
            return text
        }
    }

    func readText(_ text: String, page: Int? = nil, startOffset: Int = 0, highlight: Bool = true, location: PageLocation? = nil) {
        stopReading()
        speechPage = page
        if case .pages = document?.content { speechLocation = location ?? page.map(pageLocation) }
        speechOffset = startOffset
        speechHighlightEnabled = highlight
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let page {
                if speechLocation != nil { speechNeedsNextPage = true } else { speechPage = page + 1 }
                speechRequested = true; readNextPage(); return
            }
            status = L("No readable text at this position")
            return
        }
        claimSpeech()
        speechActive = speech.startSpeaking(text)
        speechRequested = speechActive
        if !speechActive { status = L("Cannot start speech synthesis") }
    }

    private func readNextPage() {
        guard speechRequested, !speechPaused, let document, let first = speechPage else { return }
        let location = speechLocation
        let advance = speechNeedsNextPage
        speechTask = Task {
            do {
                if case .pages(let pages) = document.content {
                    if pages.isPDF, try await pages.pdfInfo()?.permissions.copy != true { throw ReadError("This PDF does not allow text extraction") }
                    let result = try await pages.readablePage(from: location ?? pageLocation(first), advance: advance)
                    let table = await pages.chapterLayout
                    guard self.document?.id == document.id, !Task.isCancelled else { return }
                    applyChapterLayout(table)
                    guard let result else {
                        speechPage = nil; speechLocation = nil; speechNeedsNextPage = false
                        speechActive = false; speechPaused = false; speechRequested = false
                        return
                    }
                    speechLocation = result.position.anchor.flatMap { ChapterTable.bookmarkLocation($0)?.location } ?? .init(page: result.position.page)
                    speechNeedsNextPage = false
                    speechPage = speechLocation.map(pageNumber)
                    speechOffset = 0; speechHighlightEnabled = true
                    updatePosition(result.position); send(.restore(result.position))
                    claimSpeech(); speechActive = speech.startSpeaking(result.text)
                    if !speechActive { status = L("Cannot start speech synthesis"); speechPage = nil; speechLocation = nil; speechRequested = false }
                    return
                }
                try Task.checkCancellation()
                guard self.document?.id == document.id else { return }
                if case .browser = document.content, first < count {
                    send(.page(first)); send(.readAloudFromTop)
                    return
                }
                speechPage = nil
                speechActive = false
                speechPaused = false
                speechRequested = false
            } catch {
                guard !Task.isCancelled, self.document?.id == document.id else { return }
                stopReading()
                self.error = error.localizedDescription
            }
        }
    }

    func pauseReading(immediately: Bool = false) {
        guard speechRequested, !speechPaused else { return }
        if speechActive { speech.pauseSpeaking(at: immediately ? .immediateBoundary : .wordBoundary) }
        else { speechTask?.cancel(); speechTask = nil }
        speechPaused = true
    }
    private func claimSpeech() {
        // A new source takes the audible session, while the previous tab keeps
        // its native synthesizer's resume position. Merely switching tabs does
        // not interrupt reading.
        for reader in ReaderWindows.states where reader !== self && reader.speechRequested && !reader.speechPaused {
            reader.pauseReading(immediately: true)
        }
    }
    func continueReading() {
        guard speechRequested, speechPaused else { return }
        claimSpeech()
        speechPaused = false
        if speechActive { speech.continueSpeaking() }
        else { readNextPage() }
    }
    func stopReading() {
        speechPage = nil; speechLocation = nil; speechNeedsNextPage = false
        speechTask?.cancel()
        speechTask = nil
        speech.delegate = nil
        speech.stopSpeaking()
        speech = NSSpeechSynthesizer()
        speech.delegate = speechDelegate
        speech.setVoice(speechVoice.isEmpty ? nil : NSSpeechSynthesizer.VoiceName(rawValue: speechVoice))
        speech.rate = Float(speechRate)
        speechActive = false
        speechPaused = false
        speechRequested = false
        if hasDocument { send(.speechHighlight(location: 0, length: 0)) }
    }

    func setAutoScroll(_ enabled: Bool) {
        autoScrollTimer?.invalidate(); autoScrollTimer = nil
        autoScroll = enabled && hasDocument
        guard autoScroll else { return }
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1 / autoScrollSpeed, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoScroll, !self.commandInFlight,
                      self.window?.isKeyWindow == true, NSApp.modalWindow == nil else { return }
                self.scroll(.down)
            }
        }
    }

    func changeAutoScrollSpeed(_ factor: Double) {
        autoScrollSpeed = min(30, max(0.25, autoScrollSpeed * factor))
        if autoScroll { setAutoScroll(true) }
    }

    func showFindPanel() {
        searchStartMarked = false
        showFind = true
        findFocusRevision &+= 1
        selectSidebar("search")
    }

    func showContentsSearch() {
        contentsSearchRequested = true
        showContents = true
        if let field = contentsSearchField, field.window != nil {
            contentsSearchRequested = false
            field.selectText(nil)
        }
    }

    private func selectSidebar(_ panel: String) {
        showSearchResults = panel == "search"
        if panel != "contents", showContents { showContents = false }
        if panel != "thumbnails", showThumbnails { showThumbnails = false }
        if panel != "bookmarks", showBookmarks { showBookmarks = false }
        if panel != "annotations", showAnnotations { showAnnotations = false }
    }

    func closeSidebar() { selectSidebar("") }

    func closeFind() {
        searchStartMarked = false
        pendingFind?.cancel(); pendingFind = nil
        showFind = false
        showSearchResults = false
        status = ""
        send(.toc)
    }

    func updateFindQuery(_ query: String, refresh: Bool = false) {
        guard query != findQuery || refresh else { return }
        pendingFind?.cancel(); pendingFind = nil
        let replacesSearch = !findQuery.isEmpty && findQuery != query
        findQuery = query
        guard showFind, let documentID = document?.id else { return }
        searchResults = []; status = ""
        if query.isEmpty {
            findNext()
            return
        }
        if replacesSearch { send(.toc) }
        // Like Sumatra's find bar, short queries wait longer to avoid starting
        // a document-wide search on every initial keystroke. Enter searches now.
        pendingFind = Task { [weak self] in
            try? await Task.sleep(nanoseconds: query.count < 3 ? 1_000_000_000 : 500_000_000)
            guard !Task.isCancelled, let self, self.document?.id == documentID,
                  self.showFind, self.findQuery == query else { return }
            self.pendingFind = nil
            self.findNext()
        }
    }

    func findNext(backwards: Bool = false, fromSelection: Bool = false, inResults: Bool? = nil) {
        let results = inResults ?? (findWindow?.isKeyWindow == true)
        let perform: (String) -> Void = { [self] text in
            let query = fromSelection ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
            guard !fromSelection || !query.isEmpty else { status = "Select text to find"; return }
            send(.find(query, backwards: backwards, fromSelection: fromSelection, inResults: results))
        }
        if fromSelection, isBrowser {
            Task {
                do { perform(try await selectionText()) }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        } else { perform(fromSelection ? selectedText : findQuery) }
    }

    func setSearchPageRange(_ value: String) {
        guard value != searchPageRange else { return }
        searchPageRange = value
        if !findQuery.isEmpty { send(.toc); updateFindQuery(findQuery, refresh: true) }
    }
    func firstPage() {
        if isBrowser { navigate(.location("first")) }
        else { recordNavigation(); updatePosition(.init(page: 0)); send(.page(0)) }
    }
    func lastPage() {
        guard count > 0 else { return }
        if isBrowser || (chapterLayout?.chapterCount ?? 1) > 1 { navigate(.location("last")) }
        else { recordNavigation(); updatePosition(.init(page: count - 1)); send(.page(count - 1)) }
    }
    func scroll(_ direction: ReaderScrollDirection, amount: ReaderScrollAmount = .line, count: Int = 1) { send(.scroll(direction, amount, count: count)) }

    func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) ||
            (event.phase.isEmpty && event.momentumPhase.isEmpty) { wheelTurnedPage = false }
        guard case .pages(let pages) = document?.content,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let scroll = readerScrollView, let window = scroll.window, event.window === window,
              window.attachedSheet == nil, !scroll.isHiddenOrHasHiddenAncestor,
              let canvas = scroll.documentView else { return false }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return false }
        let clip = scroll.contentView
        // AppKit keeps momentum routed to the gesture's original view even
        // when its reported pointer position has moved outside that view.
        if !event.momentumPhase.isEmpty { return (flow != "continuous" || presentation) && wheelTurnedPage }
        guard clip.safeAreaRect.contains(clip.convert(event.locationInWindow, from: nil)) else { return false }
        // Cover the whole reader, including page margins, without stealing a
        // form editor's nested scroll view or the native scrollbar itself.
        let point = scroll.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = scroll.hitTest(point), hit === scroll || hit.enclosingScrollView === scroll else { return false }
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 { discardNativePassage() }
        guard flow != "continuous" || presentation else { return false }
        guard event.scrollingDeltaY != 0, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
        if wheelTurnedPage { return true }
        let direction: ReaderScrollDirection = event.scrollingDeltaY > 0 ? .up : .down
        var probe = clip.bounds
        probe.origin.y += (direction == .up ? -1 : 1) * (canvas.isFlipped ? 1 : -1)
        if fit != "content", abs(clip.constrainBoundsRect(probe).minY - clip.bounds.minY) > 0.5 { return false }
        // CanvasOnMouseWheel turns only after page scrolling reaches its edge.
        // The existing page command also owns previous-page-at-bottom and form
        // commits. One touch gesture may turn once; its inertia must not skip pages.
        wheelTurnedPage = !event.phase.isEmpty
        guard !commandInFlight else { return true }
        // Sumatra WheelMayTurnPage waits for a slow comic page to be available
        // and a 250 ms gap, so queued wheel notches cannot skip unread images.
        if pages.isImageCollection {
            guard wheelPageTurnTime.map({ event.timestamp - $0 >= 0.25 }) ?? true,
                  RasterReader.pageIsRendered(in: readerFocusView, pages: pages, location: pageLocation(page)) else { return true }
        }
        wheelPageTurnTime = event.timestamp
        self.scroll(direction, amount: .page)
        return true
    }

    static func chapterInput(_ value: String, offset: Int) -> String? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || (offset > 0 && fields.count == 3), let chapter = Int(fields[0]), let page = Int(fields[1]),
              chapter >= (offset < 0 ? 1 : 0), page >= (offset < 0 ? 1 : 0),
              chapter <= Int(Int32.max) - 1, page <= Int(Int32.max) - 1 else { return nil }
        return "\(chapter + offset):\(page + offset)"
    }

    func turn(_ delta: Int, count steps: Int = 1) {
        guard steps > 0 else { return }
        if isBrowser || (chapterLayout?.chapterCount ?? 1) > 1 {
            send(.turnPages(delta > 0 ? steps : -steps))
            return
        }
        guard count > 0 else { return }
        var range = visiblePages
        for _ in 0..<min(steps, count) {
            let target = delta > 0 ? min(count - 1, range.upperBound) : max(0, range.lowerBound - 1)
            let next = PageRows.range(page: target, count: count, spread: spread && isFixed && !presentation, cover: cover, landscape: landscapeAsSpread ? landscapePages : [])
            if next == range { break }; range = next
        }
        updatePosition(.init(page: range.lowerBound))
        send(.page(page))
    }

    func requestPageInput() {
        guard hasDocument, count > 0 else { return }
        window?.makeKeyAndOrderFront(nil)
        // OnMenuGoToPage selects the live toolbar edit control when visible.
        if toolbarVisible, !presentation, let field = pageInputField,
           field.window === window, !field.isHiddenOrHasHiddenAncestor, !field.visibleRect.isEmpty {
            if let editor = field.currentEditor() { editor.selectAll(nil) }
            else { field.selectText(nil) }
        } else {
            showGoToPageDialog()
            if let target = (browserView as NSView?) ?? readerFocusView { target.window?.makeFirstResponder(target) }
        }
    }

    func showGoToPageDialog() {
        guard let document, count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = L("Go to Page…")
        alert.informativeText = positionLabel
        let input = NSTextField(string: pageLabel)
        input.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: L("Go")); alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, self.document?.id == document.id else { return }
        go(input.stringValue)
    }

    func go(_ value: String) {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if reflowable || isBrowser, Self.chapterInput(input, offset: -1) != nil {
            navigate(.location(input)); return
        }
        if let pages = nativePDF {
            if nativePDFInfo?.hasPageLabels == false { goToPhysicalPage(input); return }
            let documentID = document?.id
            Task {
                do {
                    let label = try await pages.pdfPageForLabel(input)
                    guard document?.id == documentID else { return }
                    if let label { navigate(.page(label)) }
                    else { goToPhysicalPage(input) }
                } catch { if document?.id == documentID { self.error = error.localizedDescription } }
            }
            return
        }
        goToPhysicalPage(input)
    }

    private func goToPhysicalPage(_ input: String) {
        guard let value = Double(input), value.isFinite else { status = "Page or label not found"; return }
        let target = Int(max(0, min(Double(max(0, count - 1)), value - 1)))
        if isBrowser { navigate(.page(target)); return }
        recordNavigation()
        updatePosition(.init(page: target))
        send(.page(page))
    }

    var printInfo: NSPrintInfo {
        NSPrintInfo.shared.copy() as! NSPrintInfo
    }

    func printDocument() {
        send(.print)
    }

    func inverseSearch(page: Int, point: CGPoint) {
        guard inverseSearchEnabled, let pages = nativePDF else { return }
        let documentID = document?.id
        Task {
            do {
                let geometry = try await pages.pdfPageGeometry(page)
                let sourceURL = pages.pdfSourceURL
                guard documentID == document?.id else { return }
                let source = try await Synchronizer.inverse(pdf: sourceURL, page: page,
                    point: point.applying(geometry.transform.inverted()), bounds: geometry.mediaBox, pageCount: count)
                guard documentID == document?.id else { return }
                let configured = UserDefaults.standard.string(forKey: "sourceEditor") ?? "[]"
                let arguments = try JSONDecoder().decode([String].self, from: Data(configured.utf8))
                if let executable = arguments.first {
                    let process = Process()
                    let program = (executable as NSString).expandingTildeInPath
                    let expanded = ExternalReaderCommand.expand(Array(arguments.dropFirst()), replacements: ["{file}": source.sourceURL.path, "{line}": String(source.line), "{column}": String(source.column)])
                    process.executableURL = URL(fileURLWithPath: program.contains("/") ? program : "/usr/bin/env")
                    process.arguments = program.contains("/") ? expanded : [program] + expanded
                    process.currentDirectoryURL = source.sourceURL.deletingLastPathComponent()
                    process.terminationHandler = { [weak self] child in
                        guard child.terminationStatus != 0 else { return }
                        Task { @MainActor in
                            if self?.document?.id == documentID { self?.error = "Source editor exited with status \(child.terminationStatus)" }
                        }
                    }
                    try process.run()
                } else if !NSWorkspace.shared.open(source.sourceURL) { throw ReadError("Cannot open source file") }
                status = "\(source.sourceURL.lastPathComponent):\(source.line)"
            } catch { if documentID == document?.id { self.error = error.localizedDescription } }
        }
    }

    func inverseSearchAtCurrentPosition() {
        if let target = nativePDFInverseSearchPosition?() { inverseSearch(page: target.page, point: target.point) }
    }

    func fitPresetSelected(continuous: Bool) -> Bool {
        isFixed && !spread && flow == (continuous ? "continuous" : "paged") && fit == (continuous ? "width" : "page")
    }

    // SumatraPDF.cpp::ChangeZoomLevel: the two toolbar presets share one
    // return point. Normal layout/fit changes discard it; fitted zoom updates do not.
    func toggleFitPreset(continuous: Bool) {
        guard isFixed else { return }
        if deferForNativePDFForm({ [weak self] in self?.toggleFitPreset(continuous: continuous) }) { return }
        if fitPresetSelected(continuous: continuous) {
            guard let previous = fitPresetRestore else { return }
            fitPresetRestore = nil
            spread = previous.spread
            setFlow(previous.flow)
            automaticLayout = previous.automatic
            if isNativeMarkdown { setFit(previous.fit) }
            else if previous.fit == "custom" { setZoom(previous.zoom) }
            else { setFit(previous.fit) }
        } else {
            let previous = fitPresetRestore ?? (fit, zoom, flow, spread, automaticLayout)
            spread = false
            setFlow(continuous ? "continuous" : "paged")
            setFit(continuous ? "width" : "page")
            fitPresetRestore = previous
        }
    }

    func setZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoom = ReadingZoom.clamp(value, limit: isNativeMarkdown ? configuredZoomMaximum : zoomLimit)
        if !isNativeMarkdown { fit = "custom" }
        send(.zoom(zoom))
    }

    func setFit(_ value: String) {
        guard value == "custom" || ReadingZoom.fitTitles[value] != nil else { return }
        fit = value
        if !isNativeMarkdown { zoom = 1 }
        UserDefaults.standard.set(value, forKey: "fit")
        send(.fit(value))
    }
    func setActualSize() {
        if isNativeMarkdown {
            fit = "actual"
            UserDefaults.standard.set("actual", forKey: "fit")
            setZoom(1)
        } else {
            setFit("actual")
        }
    }
    func zoomStep(_ direction: Int) {
        let step = ReadingZoom.nextStep(from: zoom, direction: direction,
            pageFit: isNativeMarkdown ? nil : pageFitZoom, widthFit: isNativeMarkdown ? nil : widthFitZoom,
            limit: isNativeMarkdown ? configuredZoomMaximum : zoomLimit,
            levels: zoomLevels.isEmpty ? ReadingZoom.levels : zoomLevels, increment: zoomIncrement)
        guard step.fit != nil || abs(step.zoom - zoom) > 0.0001 else { return }
        if let mode = step.fit { setFit(mode) }
        else { setZoom(step.zoom) }
    }
    func customZoom() {
        let documentID = document?.id
        let alert = NSAlert(); alert.messageText = L("Zoom")
        let maximum = isNativeMarkdown ? configuredZoomMaximum : min(configuredZoomMaximum, zoomLimit)
        alert.informativeText = String(format: L("Enter a percentage from 8.33%% to %g%%."), maximum * 100)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(format: "%.2f%%", zoom * 100)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("Zoom")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, documentID == document?.id else { return }
        do { setZoom(try ReadingZoom.parsePercent(field.stringValue, limit: maximum)) }
        catch { self.error = error.localizedDescription }
    }
    func zoomToSelection() { if canZoomToSelection { send(.zoomToSelection) } }

    func setFlow(_ value: String) {
        if deferForNativePDFForm({ [weak self] in self?.setFlow(value) }) { return }
        automaticLayout = false
        flow = value
        UserDefaults.standard.set(value, forKey: "flow")
        if isBrowser { send(.style) }
    }

    func applyTypography() {
        persist()
        if typographyForAll {
        let defaults = UserDefaults.standard
        defaults.set(font, forKey: "font")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(lineHeight, forKey: "lineHeight")
        defaults.set(margin, forKey: "margin")
        defaults.set(pageMargins.flatMap { try? JSONEncoder().encode($0) }, forKey: "pageMargins")
        defaults.set(userCSS, forKey: "userCSS")
        defaults.set(useDocumentCSS, forKey: "useDocumentCSS")
        }
        send(.style)
    }

    func setTheme(_ value: String) {
        theme = value
        UserDefaults.standard.set(value, forKey: "theme")
        if value != "system" { UserDefaults.standard.set(value, forKey: palette.dark ? "lastDarkTheme" : "lastLightTheme") }
        if isText || isBrowser || reflowable { send(.style) }
    }

    func toggleLightDarkTheme() {
        let key = palette.dark ? "lastLightTheme" : "lastDarkTheme"
        setTheme(UserDefaults.standard.string(forKey: key) ?? (palette.dark ? "light" : "dark"))
    }

    func rotate(_ degrees: Int) {
        rotation = (rotation + degrees + 360) % 360
        send(.rotate(degrees))
    }
}

extension ReaderState {
    private func savedMarkdownPosition(_ renderer: MarkdownRenderer, for url: URL) -> ReadingPosition? {
        if let position = markdownPositions[renderer] { return position }
        guard recordsHistory, !UserDefaults.standard.bool(forKey: "disableReadingState") else { return nil }
        let key = "position:" + url.standardizedFileURL.path + ":markdown:" + renderer.rawValue
        return UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReadingPosition.self, from: $0) }
    }

    func setMarkdownRenderer(_ preference: MarkdownRenderer, at position: ReadingPosition? = nil) {
        guard !busy, let document, document.markdownRenderer != nil else { return }
        do {
            switchMarkdownRenderer(preference, effective: try preference.effective(for: document.url),
                                   at: position, rememberPreference: true)
        } catch { self.error = error.localizedDescription }
    }

    /// Browser layout failed in automatic mode; keep that policy so a later
    /// explicit Compatible choice remains authoritative.
    @discardableResult func escalateMarkdownLayoutLimit() -> Bool {
        guard !busy, document?.markdownPreference == .automatic,
              document?.markdownRenderer == .compatible, let document,
              MarkdownRenderer.rememberLayoutLimit(for: document.url,
                                                   openedSignature: document.markdownSourceSignature) else { return false }
        switchMarkdownRenderer(.automatic, effective: .paged, at: nil, rememberPreference: false)
        return true
    }

    private func switchMarkdownRenderer(_ preference: MarkdownRenderer, effective: MarkdownRenderer,
                                        at position: ReadingPosition?, rememberPreference: Bool) {
        guard let document, let current = document.markdownRenderer else { return }
        guard current != effective || document.markdownPreference != preference || position != nil else { return }
        if let saved = filePosition { markdownPositions[current] = saved }
        let destination = Self.markdownRendererDestination(effective,
            saved: position ?? savedMarkdownPosition(effective, for: document.url) ?? ReadingPosition(),
            readingSettings: rememberPreference ? nil : currentPosition)
        requestedPosition = destination
        load(document.url, reloading: true, password: password,
             markdownRenderer: rememberPreference ? preference : effective,
             retainedMarkdownPreference: rememberPreference ? nil : preference,
             rememberMarkdownPreference: rememberPreference)
    }

    static func markdownRendererDestination(_ effective: MarkdownRenderer, saved: ReadingPosition,
                                            readingSettings: ReadingPosition? = nil) -> ReadingPosition {
        var destination = readingSettings ?? saved
        if readingSettings != nil {
            // Automatic takeover continues the same reading session. Keep its
            // settings while the destination mode owns its own coordinates.
            destination.page = saved.page; destination.pageCount = saved.pageCount
            destination.x = saved.x; destination.y = saved.y; destination.anchor = saved.anchor
            destination.markdownPassage = saved.markdownPassage; destination.nativePassage = saved.nativePassage
            destination.pdfCoordinateSpace = saved.pdfCoordinateSpace
        }
        destination.markdownRenderer = effective
        if effective == .paged { destination.markdownPassage = nil }
        else { destination.nativePassage = nil }
        return destination
    }

    func open(_ url: URL) {
        afterDiscard {
            self.requestedHistory = !UserDefaults.standard.bool(forKey: "disableHistory")
            self.requestedPosition = nil
            self.load(url.standardizedFileURL, reloading: false)
        }
    }

    func openWithoutHistory(_ url: URL, at position: ReadingPosition? = nil) {
        afterDiscard {
            self.requestedHistory = false
            self.requestedPosition = position
            self.load(url.standardizedFileURL, reloading: false)
        }
    }

    func openTemporary(_ url: URL, keeping directory: TemporaryDirectory, at position: ReadingPosition? = nil) {
        afterDiscard {
            self.requestedHistory = false
            self.requestedPosition = position
            self.load(url.standardizedFileURL, reloading: false, temporary: directory)
        }
    }

    func open(_ url: URL, at position: ReadingPosition) {
        afterDiscard {
            self.requestedHistory = !UserDefaults.standard.bool(forKey: "disableHistory")
            self.requestedPosition = position
            self.load(url.standardizedFileURL, reloading: false)
        }
    }

    func close() { afterDiscard { self.closeDocument() } }

    private func closeDocument() {
        ReaderWindows.rememberClosed(self)
        generation += 1
        requestedPosition = nil
        persist()
        loading?.cancel()
        loading = nil
        stopWatch()
        resetDocumentTransientState()
        document = nil
        password = nil
        busy = false
        error = nil
        page = 0
        status = ""
        location = ReadingPosition()
        presentation = false
        presentationBlank = nil
        laserPointer = false
        history = []
        historyIndex = 0
        markdownPositions = [:]
    }

    func reload() {
        guard !busy, let url = document?.url else { return }
        afterDiscard { self.load(url, reloading: true, password: self.password) }
    }

    func rememberPassword(_ value: String) { password = value }

    func didDisplayMarkupFile(_ url: URL) {
        guard var reading = document, case .browser(let source) = reading.content,
              source is MarkupSource,
              reading.url.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() else { return }
        // MarkdownModel::OnDocumentComplete keeps GetFilePath on the displayed
        // source. Save the departing file before changing its identity;
        // filePosition rejects a restore already targeting the new file.
        persist()
        markdownPositions = [:]
        reading.retargetSource(to: url)
        document = reading
        if reading.markdownRenderer == nil {
            location.markdownRenderer = nil
            location.markdownPassage = nil
            location.nativePassage = nil
        }
        watchFile(url)
    }

    func persist() {
        guard !UserDefaults.standard.bool(forKey: "disableReadingState"), recordsHistory, let document,
              let position = filePosition, let data = try? JSONEncoder().encode(position) else { return }
        UserDefaults.standard.set(data, forKey: "position:" + document.url.standardizedFileURL.path)
        if let renderer = document.markdownRenderer {
            let key = "position:" + document.url.standardizedFileURL.path + ":markdown:" + renderer.rawValue
            UserDefaults.standard.set(data, forKey: key)
            markdownPositions[renderer] = position
        }
        // Closing a window can precede the debounced scroll capture. Retain the
        // decoder just for this source lookup, and upgrade only this snapshot.
        if isNativeMarkdown, position.nativePassage == nil, case .pages(let pages) = document.content {
            let theme = resolvedTheme, css = effectiveUserCSS
            let key = "position:" + document.url.standardizedFileURL.path
            Task {
                do {
                    guard let passage = try await pages.capturePassage(position, theme: theme, userCSS: css) else { return }
                    var exact = position; exact.nativePassage = passage
                    let upgraded = try JSONEncoder().encode(exact)
                    if UserDefaults.standard.data(forKey: key) == data { UserDefaults.standard.set(upgraded, forKey: key) }
                    let modeKey = key + ":markdown:paged"
                    if UserDefaults.standard.data(forKey: modeKey) == data { UserDefaults.standard.set(upgraded, forKey: modeKey) }
                    if self.document?.url.standardizedFileURL == document.url.standardizedFileURL,
                       self.markdownPositions[.paged] == position { self.markdownPositions[.paged] = exact }
                } catch {
                    if self.document?.id == document.id { self.error = error.localizedDescription }
                }
            }
        }
    }

    func sibling(_ delta: Int) {
        guard let url = document?.url, let list = try? Self.folderDocuments(url.deletingLastPathComponent()) else { return }
        guard let index = list.firstIndex(of: url), list.indices.contains(index + delta) else { return }
        open(list[index + delta])
    }

    static func folderDocuments(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { Format.detect($0.lastPathComponent) != .unknown }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func discardChanges() {
        guard modified, let reading = document, !busy else { return }
        let alert = NSAlert(); alert.messageText = L("Discard PDF changes?")
        alert.informativeText = L("Unsaved annotations and form values will be replaced by the file on disk.")
        alert.addButton(withTitle: L("Discard")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,
              document?.id == reading.id, document?.url == reading.url else { return }
        nativePDFFormEditor?.cancel()
        load(reading.url, reloading: true, password: password)
    }

    func renameFile() {
        guard let reading = document, !reading.url.hasDirectoryPath, !busy else { return }
        let alert = NSAlert(); alert.messageText = L("Rename File")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = reading.url.lastPathComponent
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: L("Rename")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, document?.id == reading.id, document?.url == reading.url else { return }
        let name = field.stringValue
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { error = L("Enter a filename without path separators"); return }
        let destination = reading.url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != reading.url else { return }
        afterDiscard { [self] in
        do {
            let renamedPosition = filePosition
            stopWatch()
            try FileManager.default.moveItem(at: reading.url, to: destination)
            if case .browser(let source) = reading.content, source is MarkupSource {
                requestedPosition = renamedPosition
            }
            document?.url = destination
            let defaults = UserDefaults.standard, oldKey = "position:" + reading.url.path
            if let position = defaults.data(forKey: oldKey) { defaults.set(position, forKey: "position:" + destination.path); defaults.removeObject(forKey: oldKey) }
            for index in bookmarks.indices where bookmarks[index].path == reading.url.path { bookmarks[index].path = destination.path }
            saveBookmarks()
            ReaderFiles.replaceHistory(reading.url, with: destination)
            // Preserve the current position, but reload the engine's source URL
            // so subsequent encrypted/signature operations use the renamed file.
            load(destination, reloading: true, password: password)
        } catch { watchFile(reading.url); self.error = error.localizedDescription }
        }
    }

    func trashFile(openNext: Bool) {
        guard let reading = document, !reading.url.hasDirectoryPath, !busy else { return }
        let alert = NSAlert(); alert.messageText = String(format: L("Move %@ to Trash?"), reading.url.lastPathComponent)
        alert.addButton(withTitle: L("Move to Trash")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, document?.id == reading.id, document?.url == reading.url else { return }
        afterDiscard { [self] in
        let files = (try? Self.folderDocuments(reading.url.deletingLastPathComponent())) ?? []
        let next = files.firstIndex(of: reading.url).flatMap { index -> URL? in
            if files.indices.contains(index + 1) { return files[index + 1] }
            return index > 0 ? files[index - 1] : nil
        }
        do {
            stopWatch()
            try FileManager.default.trashItem(at: reading.url, resultingItemURL: nil)
            modified = false
            closeDocument()
            ReaderFiles.forget(reading.url)
            if openNext, let next { open(next) }
        } catch { watchFile(reading.url); self.error = error.localizedDescription }
        }
    }

    func saveCopy(completion: (() -> Void)? = nil) {
        if let pages = nativePDF {
            Task {
                defer { completion?() }
                await saveNativePDFCopy(pages)
            }
            return
        }
        var waitingForPanel = false
        defer { if !waitingForPanel { completion?() } }
        let documentID = document?.id
        guard let reading = document, !reading.url.hasDirectoryPath else {
            error = "Save a Copy is only available for files."
            return
        }
        let sourceURL = reading.url
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        waitingForPanel = true
        panel.begin { result in
            Task { @MainActor in
                defer { withExtendedLifetime(reading) {}; completion?() }
                guard result == .OK, let destinationURL = panel.url else { return }
                do {
                    try await reading.saveCopy(to: destinationURL)
                } catch {
                    if self.document?.id == documentID { self.error = error.localizedDescription }
                }
            }
        }
    }

    func copyPath() {
        guard let path = document?.url.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func bookmark() {
        guard let reading = document, let position = filePosition else { return }
        let url = reading.url
        let alert = NSAlert()
        alert.messageText = L("Add Bookmark")
        let field = NSTextField(string: "\(url.deletingPathExtension().lastPathComponent) — \(positionLabel)")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, document?.id == reading.id, document?.url == url else { return }
        let title = field.stringValue, theme = resolvedTheme, css = effectiveUserCSS
        guard reading.markdownRenderer == .paged, case .pages(let pages) = reading.content else {
            bookmarks.append(.init(title: title, path: url.path, position: position))
            saveBookmarks(); showBookmarks = true
            return
        }
        Task {
            var position = position
            do {
                position.nativePassage = try await pages.capturePassage(position, theme: theme, userCSS: css)
                guard document?.id == reading.id, document?.url == url else { return }
                bookmarks.append(.init(title: title, path: url.path, position: position))
                saveBookmarks(); showBookmarks = true
            } catch { if document?.id == reading.id { self.error = error.localizedDescription } }
        }
    }

    func openBookmark(_ bookmark: ReaderBookmark) {
        if bookmark.path == document?.url.path {
            if let target = bookmark.position.markdownRenderer
                ?? (bookmark.position.markdownPassage == nil ? nil : .compatible),
               document?.markdownRenderer != nil, target != document?.markdownRenderer {
                setMarkdownRenderer(target, at: bookmark.position)
                return
            }
            if let pages = nativePDF {
                let documentID = document?.id
                Task {
                    do {
                        let position = try await Self.restoreSavedPDFPosition(bookmark.position, pages: pages)
                        guard document?.id == documentID else { return }
                        recordNavigation(); restore(position)
                    } catch { if document?.id == documentID { self.error = error.localizedDescription } }
                }
                return
            }
            var position = bookmark.position
            if case .browser(let source as MarkupSource) = document?.content {
                let file = URL(fileURLWithPath: bookmark.path).standardizedFileURL.resolvingSymlinksInPath()
                guard let page = source.pages.firstIndex(where: { (try? source.fileURL($0)) == file }) else { return }
                position.page = page
                position.anchor = source.pages[page].absoluteString
            }
            recordNavigation(); restore(position)
        }
        else {
            open(URL(fileURLWithPath: bookmark.path), at: bookmark.position)
        }
    }

    // Called only when reading a saved position/bookmark, never for current
    // selection, link or scroll requests. MuPDF owns crop/rotation/UserUnit.
    static func restoreSavedPDFPosition(_ saved: ReadingPosition, pages: Pages) async throws -> ReadingPosition {
        guard pages.isPDF, saved.pdfCoordinateSpace != "fitz", saved.x != nil || saved.y != nil else { return saved }
        let count = await pages.count
        let geometry = try await pages.pdfPageGeometry(min(max(0, saved.page), max(0, count - 1)))
        return saved.convertingPDFCoordinates(geometry.transform)
    }

    func deleteBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    func savePDF() {
        guard canSave else { saveCopy(); return }
        let documentID = document?.id, loadGeneration = generation, closeRevision = closeRequestRevision
        Task {
            do {
                guard document?.id == documentID, generation == loadGeneration else { return }
                guard try await saveCurrentPDF(), !modified,
                      document?.id == documentID, generation == loadGeneration, let url = document?.url else { return }
                // Sumatra ReloadDocument follows an ordinary save. Confirmation
                // callers instead continue their already-approved close/switch.
                if closeRequestRevision == closeRevision { load(url, reloading: true, password: password) }
            } catch {
                if document?.id == documentID, generation == loadGeneration { self.error = error.localizedDescription }
            }
        }
    }

    private func saveCurrentPDF() async throws -> Bool {
        if let operation = pdfSaveTask { return try await operation.value }
        guard let reading = document else { return false }
        let loadGeneration = generation
        let operation = Task { try await writeCurrentPDF(reading, generation: loadGeneration) }
        pdfSaveTask = operation
        defer { pdfSaveTask = nil }
        return try await operation.value
    }

    private func writeCurrentPDF(_ reading: ReadingDocument, generation loadGeneration: Int) async throws -> Bool {
        guard canSave, document?.id == reading.id, document?.url == reading.url, generation == loadGeneration else { return false }
        try await commitPDFForm()
        guard document?.id == reading.id, generation == loadGeneration else { return false }
        guard modified else { status = "No unsaved changes"; return false }
        stopWatch()
        defer {
            if document?.id == reading.id, generation == loadGeneration { watchFile(reading.url) }
        }
        if case .pages(let pages) = reading.content, pages.isPDF {
            try await pages.pdfSave(to: reading.url)
            guard document?.id == reading.id, generation == loadGeneration else { return false }
            try await nativePDFDidChange(pages)
            guard document?.id == reading.id, generation == loadGeneration else { return false }
        } else { return false }
        status = L("Saved")
        return !modified
    }

    private func saveNativePDFCopy(_ pages: Pages) async {
        guard let reading = document, nativePDF === pages else { return }
        let loadGeneration = generation
        do {
            try await commitPDFForm()
            guard document?.id == reading.id, generation == loadGeneration else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsOtherFileTypes = false
            panel.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + ".pdf"
            let formatPicker = reading.hasSeparatePDFSource ? PDFCopyFormatPicker(panel: panel, source: reading.url) : nil
            defer { withExtendedLifetime(formatPicker) {} }
            guard document?.id == reading.id, generation == loadGeneration else { return }
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let destination = panel.url,
                  document?.id == reading.id, generation == loadGeneration else { return }
            // A save panel runs the event loop; commit any input entered since
            // it opened before serializing the current document.
            try await commitPDFForm()
            guard document?.id == reading.id, generation == loadGeneration else { return }
            try await reading.saveCopy(to: destination, originalFile: formatPicker?.originalFile == true)
        } catch {
            if document?.id == reading.id, generation == loadGeneration { self.error = error.localizedDescription }
        }
    }

    private func commitPDFForm() async throws {
        try await nativePDFFormEditor?.commit()
    }

    func showProperties() {
        guard let document else { return }
        let currentPage = page
        let password = documentPassword
        Task {
        var rows = ["File: " + document.url.path, "Pages: \(count)"]
        if let values = try? document.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            if let size = values.fileSize { rows.append("Size: " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
            if let date = values.contentModificationDate { rows.append("Modified: " + date.formatted()) }
        }
        if case .pages(let pages) = document.content {
            do {
                let attributes = try await pages.metadata()
                rows += attributes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                let bounds = try await pages.bounds(currentPage)
                rows.append(String(format: "Page %d bounds: %.2f × %.2f", currentPage + 1, bounds.width, bounds.height))
                if pages.isPDF {
                    let info = try await pages.pdfInfo()
                    let annotations = try await pages.pdfAnnotations(currentPage)
                    rows.append("Copying: \(info?.permissions.copy == true ? "allowed" : "restricted")")
                    rows.append("Printing: \(info?.permissions.print == true ? "allowed" : "restricted")")
                    rows.append("Annotations: \(annotations.count)")
                    let source = pages.pdfSourceURL
                    let details = try await Task.detached {
                        let information = try NativePDFTools.information(source: source, password: password)
                        let resources = try NativePDFTools.resourceReport(source: source, password: password)
                        return (information, resources)
                    }.value
                    rows.append(L("Saved source file; unsaved edits are not included."))
                    rows += details.0.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
                    rows.append(details.1)
                }
            } catch { rows.append("Metadata: " + error.localizedDescription) }
        } else if case .browser(let source) = document.content {
            rows += await source.properties().sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        } else if case .text(let text) = document.content {
            rows.append("Characters: \(text.count)")
        }
        guard self.document?.id == document.id, self.document?.url == document.url else { return }
        let alert = NSAlert()
        alert.messageText = L("Document Properties")
        let scroll = NSTextView.scrollableTextView(); scroll.frame.size = CGSize(width: 440, height: 280)
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false; text.font = .systemFont(ofSize: 12); text.string = rows.joined(separator: "\n")
        }
        alert.accessoryView = scroll
        alert.runModal()
        }
    }

    func confirmClose() async -> Bool {
        await withCheckedContinuation { continuation in
            confirmClose { continuation.resume(returning: $0) }
        }
    }

    // AppKit callbacks can complete immediately for an unchanged document, but
    // native form validation and disk writes must finish before approving close.
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        guard !confirmingClose else { completion(false); return }
        closeRequestRevision &+= 1
        confirmingClose = true
        let documentID = document?.id, sourceURL = document?.url, loadGeneration = generation
        let finish: (Bool) -> Void = { [self] allowed in
            confirmingClose = false
            completion(allowed && document?.id == documentID && document?.url == sourceURL && generation == loadGeneration)
        }
        let prompt: () -> Void = { [self] in
            guard document?.id == documentID, document?.url == sourceURL, generation == loadGeneration else { finish(false); return }
            guard modified else { finish(true); return }
            let alert = NSAlert()
            alert.messageText = L("Save PDF changes?")
            alert.informativeText = L("This document has unsaved annotations or form changes.")
            alert.addButton(withTitle: L(canSave ? "Save" : "Cancel"))
            alert.addButton(withTitle: L("Discard"))
            if canSave { alert.addButton(withTitle: L("Cancel")) }
            let response = alert.runModal()
            guard document?.id == documentID, document?.url == sourceURL, generation == loadGeneration else { finish(false); return }
            if response == .alertSecondButtonReturn { finish(true); return }
            guard response == .alertFirstButtonReturn, canSave else { finish(false); return }
            Task {
                do {
                    _ = try await saveCurrentPDF()
                    finish(!modified)
                }
                catch {
                    if document?.id == documentID, document?.url == sourceURL, generation == loadGeneration { self.error = error.localizedDescription }
                    finish(false)
                }
            }
        }
        if nativePDFFormEditor != nil || pdfSaveTask != nil {
            let editor = nativePDFFormEditor, saving = pdfSaveTask
            Task {
                do {
                    try await editor?.commit()
                    if let saving { _ = try await saving.value }
                    prompt()
                }
                catch {
                    if document?.id == documentID, document?.url == sourceURL, generation == loadGeneration { self.error = error.localizedDescription }
                    finish(false)
                }
            }
        } else { prompt() }
    }

    private func afterDiscard(_ action: @escaping () -> Void) {
        confirmClose { allowed in if allowed { action() } }
    }

    func windowClosed() {
        persist()
        generation += 1
        loading?.cancel()
        loading = nil
        stopWatch()
        resetDocumentTransientState()
        document = nil
        window = nil
    }
}

private extension ReaderState {
    // Only state owned by the outgoing document. Reading preferences, position,
    // presentation and navigation history have different close/reload semantics.
    func resetDocumentTransientState() {
        nativePassageTask?.cancel(); nativePassageTask = nil
        searchStartMarked = false
        pendingFind?.cancel(); pendingFind = nil
        generatedContentsTask?.cancel(); generatedContentsTask = nil
        setAutoScroll(false)
        stopReading()
        // stopReading may publish the final highlight clear to the outgoing reader.
        command = ReaderCommand(revision: command.revision)
        pendingActions = []
        commandInFlight = false
        browserTemporary = nil; selectionScreenBounds = nil; nativePDFSignatureSelection = nil; nativePDFInverseSearchPosition = nil; nativePDFCursorPosition = nil
        readerScrollView = nil
        readerFocusView = nil
        wheelTurnedPage = false
        wheelPageTurnTime = nil
        zoomLimit = configuredZoomMaximum
        pageFitZoom = nil; widthFitZoom = nil
        fitPresetRestore = nil
        showFitContentArea = false
        findQuery = ""
        searchPageRange = ""
        logicalPageLabel = nil
        chapterLayout = nil
        contentsQuery = ""
        contentsSearchRequested = false
        outline = []
        landscapePages = []
        outlineBusy = false
        showFind = false
        searchResults = []
        showSearchResults = false
        selectedText = ""
        hasSelection = false
        modified = false
        count = 0
        reflowable = false
        searchable = false
        renderRevision = 0
    }

    func load(_ url: URL, reloading: Bool, password requestPassword: String? = nil, temporary: TemporaryDirectory? = nil,
              markdownRenderer requestedRenderer: MarkdownRenderer? = nil,
              retainedMarkdownPreference: MarkdownRenderer? = nil,
              rememberMarkdownPreference: Bool = false) {
        persist()
        if !reloading { markdownPositions = [:] }
        generation &+= 1
        let currentGeneration = generation
        let openingPosition = requestedPosition
        let openingRenderer = requestedRenderer ?? openingPosition?.markdownRenderer
            ?? (openingPosition?.markdownPassage == nil ? nil : .compatible)
        let openingHistory = requestedHistory ?? recordsHistory
        let openingEditRevision = editRevision
        let sourceTemporary = temporary ?? (reloading ? document?.sourceTemporary : nil)
        requestedPosition = nil
        requestedHistory = nil
        loading?.cancel()
        reloadTask?.cancel()
        reloadTask = nil
        busy = true
        error = nil
        status = reloading ? L("Reloading…") : String(format: L("Opening %@…"), url.lastPathComponent)

        loading = Task {
            let worker = Task.detached(priority: .userInitiated) {
                var opened = try ReadingDocument.open(url, password: requestPassword, deferReflowLayout: true,
                                                       markdownRenderer: openingRenderer)
                if opened.markdownRenderer != nil, let retainedMarkdownPreference {
                    opened.markdownPreference = retainedMarkdownPreference
                }
                opened.sourceTemporary = sourceTemporary
                try Task.checkCancellation()
                return opened
            }
            do {
                let opened = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: { worker.cancel() }
                )
                var firstPageBounds: CGRect?
                if !reloading, UserDefaults.standard.bool(forKey: "pageAspectLayout") {
                    switch opened.content {
                    case .pages(let pages) where pages.isPDF || ["xps", "oxps", "djvu", "djv", "ps", "eps"].contains(opened.url.pathExtension.lowercased()):
                        firstPageBounds = try await pages.bounds(0)
                    default: break
                    }
                }
                guard !Task.isCancelled, currentGeneration == generation else { return }

                // Normalize persisted PDFKit coordinates before publishing the
                // replacement. In-memory native requests never enter this path.
                var restoredPosition: ReadingPosition?
                if !reloading {
                    let data = UserDefaults.standard.bool(forKey: "disableReadingState") || !openingHistory ? nil : UserDefaults.standard.data(forKey: "position:" + opened.url.path)
                    let legacy = data.flatMap { try? JSONDecoder().decode(ReadingPosition.self, from: $0) }
                    if let renderer = opened.markdownRenderer {
                        let matchingExplicit = openingPosition.flatMap { position -> ReadingPosition? in
                            let mode = position.markdownRenderer ?? (position.markdownPassage == nil ? nil : .compatible)
                            return mode == nil || mode == renderer ? position : nil
                        }
                        restoredPosition = matchingExplicit ?? savedMarkdownPosition(renderer, for: opened.url)
                        if restoredPosition == nil, renderer == .compatible, legacy?.markdownRenderer == nil {
                            restoredPosition = legacy
                        }
                    } else { restoredPosition = openingPosition ?? legacy }
                    if let position = restoredPosition, case .pages(let pages) = opened.content, pages.isPDF {
                        restoredPosition = try await Self.restoreSavedPDFPosition(position, pages: pages)
                        guard !Task.isCancelled, currentGeneration == generation else { return }
                    }
                }

                // Editing remains available while the replacement loads. Commit a
                // form field and protect only edits made after the initial decision.
                try await commitPDFForm()
                guard !Task.isCancelled, currentGeneration == generation else { return }
                if editRevision != openingEditRevision {
                    let hadChanges = modified
                    let previousURL = document?.url
                    let discard = await confirmClose()
                    guard !Task.isCancelled, currentGeneration == generation else { return }
                    if !discard {
                        busy = false
                        loading = nil
                        status = ""
                        return
                    }
                    // A Save decision may have replaced the very file that the
                    // worker already opened. Read its committed bytes again.
                    if hadChanges, !modified, let previousURL, PDFTools.sameFile(previousURL, url) {
                        requestedPosition = openingPosition
                        requestedHistory = openingHistory
                        load(url, reloading: reloading, password: password, temporary: sourceTemporary,
                             markdownRenderer: requestedRenderer,
                             retainedMarkdownPreference: retainedMarkdownPreference,
                             rememberMarkdownPreference: rememberMarkdownPreference)
                        return
                    }
                }

                // The old document stays readable while loading. A different
                // Markdown renderer gets only its own coordinate system.
                let changedMarkdownRenderer = reloading && document?.markdownRenderer != opened.markdownRenderer
                    && (document?.markdownRenderer != nil || opened.markdownRenderer != nil)
                let reloadedPosition: ReadingPosition?
                if changedMarkdownRenderer {
                    if let renderer = opened.markdownRenderer {
                        let explicit = openingPosition.flatMap { position -> ReadingPosition? in
                            let mode = position.markdownRenderer ?? (position.markdownPassage == nil ? nil : .compatible)
                            return mode == renderer ? position : nil
                        }
                        reloadedPosition = explicit ?? savedMarkdownPosition(renderer, for: opened.url) ?? ReadingPosition()
                    } else { reloadedPosition = ReadingPosition() }
                } else if reloading, let openingPosition {
                    reloadedPosition = openingPosition
                } else if reloading, case .browser(let source) = document?.content, source is MarkupSource {
                    reloadedPosition = filePosition
                } else { reloadedPosition = nil }
                persist()
                if !reloading {
                    if document != nil { ReaderWindows.rememberClosed(self) }
                    markdownPositions = [:]
                    recordsHistory = openingHistory
                    readPreferences()
                    location = ReadingPosition()
                    zoom = 1
                    rotation = 0
                    page = 0
                    let formatDefaults = UserDefaults.standard.string(forKey: "formatDefaults") ?? "{}"
                    if let defaults = try? JSONDecoder().decode([String: ReadingPosition].self, from: Data(formatDefaults.utf8)), let position = defaults[opened.settingsFormat] { apply(position) }
                    let restored = restoredPosition
                    useDocumentOpenAction = restored == nil
                    if let position = restored {
                        apply(position)
                    } else if !automaticLayout, let bounds = firstPageBounds, bounds.width > 0, bounds.height > 0 {
                        spread = false
                        flow = bounds.width > bounds.height ? "paged" : "continuous"
                        fit = bounds.width > bounds.height ? "page" : "width"
                    }
                    requestedPosition = nil
                    history = []
                    historyIndex = 0
                } else { useDocumentOpenAction = false }
                let restorePDFEditing = reloading && pdfEditingEnabled
                resetDocumentTransientState()
                document = opened
                if opened.markdownRenderer == .paged { zoomLimit = configuredZoomMaximum }
                if changedMarkdownRenderer {
                    location = ReadingPosition(); page = 0; zoom = 1; fit = "page"; flow = "paged"
                    history = []; historyIndex = 0
                }
                if let position = reloadedPosition { apply(position) }
                if opened.markdownRenderer != nil, rememberMarkdownPreference,
                   let preference = opened.markdownPreference {
                    UserDefaults.standard.set(preference.rawValue, forKey: MarkdownRenderer.preferenceKey(for: opened.url))
                }
                password = requestPassword
                if !hasBookmark,
                   let legacy = UserDefaults.standard.data(forKey: "bookmark:" + opened.url.path),
                   let position = try? JSONDecoder().decode(ReadingPosition.self, from: legacy) {
                    bookmarks.append(.init(title: opened.url.lastPathComponent, path: opened.url.path, position: position))
                    saveBookmarks()
                    UserDefaults.standard.removeObject(forKey: "bookmark:" + opened.url.path)
                }
                busy = false
                status = ""
                loading = nil
                watchFile(opened.url)
                if restorePDFEditing { setPDFEditingEnabled(true) }
                if !reloading { ReaderFiles.recordOpen(opened, recordsHistory: recordsHistory) }
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                busy = false
                status = ""
                loading = nil
                if let required = error as? PasswordRequired {
                    requestedPosition = openingPosition
                    requestedHistory = openingHistory
                    let alert = NSAlert()
                    alert.messageText = L("Document Password")
                    alert.informativeText = required.localizedDescription
                    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                    alert.accessoryView = field
                    alert.addButton(withTitle: L("Open"))
                    alert.addButton(withTitle: L("Cancel"))
                    let response = alert.runModal()
                    guard !Task.isCancelled, currentGeneration == generation else { return }
                    if response == .alertFirstButtonReturn {
                        load(url, reloading: reloading, password: field.stringValue, temporary: sourceTemporary,
                             markdownRenderer: requestedRenderer,
                             retainedMarkdownPreference: retainedMarkdownPreference,
                             rememberMarkdownPreference: rememberMarkdownPreference)
                        return
                    }
                } else { self.error = error.localizedDescription }
                // Atomic replacement may have invalidated the previous file descriptor.
                if let url = document?.url { watchFile(url) }
            }
        }
    }

    internal func apply(_ position: ReadingPosition) {
        var position = position
        if let saved = position.anchor.flatMap(ChapterTable.bookmarkLocation), let page = chapterLayout?.page(for: saved.location) {
            position.page = page
        }
        location = position
        page = max(0, position.page)
        if let value = position.zoom { zoom = ReadingZoom.clamp(value, limit: configuredZoomMaximum) }
        if let value = position.fit { fit = value }
        if let value = position.flow { flow = value }
        if let value = position.scrollbarMode { scrollbarMode = value }
        if let value = position.spread { spread = value }
        if let value = position.automaticLayout { automaticLayout = value }
        if let value = position.invertColors { invertColors = value }
        if let value = position.grayscale { grayscale = value }
        if let value = position.documentColors { documentColors = value }
        if let value = position.preservePDFImages { preservePDFImages = value }
        if let value = position.engineeringEnhance { engineeringEnhance = value }
        if position.documentColors != nil || position.customTextColor != nil || position.customBackgroundColor != nil {
            customTextColor = position.customTextColor; customBackgroundColor = position.customBackgroundColor
        }
        if position.margin != nil || position.pageMargins != nil { pageMargins = position.pageMargins }
        if let value = position.rtl { rtl = value }
        if let value = position.cover { cover = value }
        if let value = position.rotation { rotation = (value % 360 + 360) % 360 }
        if let value = position.font { font = value }
        if let value = position.fontSize { fontSize = value }
        if let value = position.lineHeight { lineHeight = value }
        if let value = position.margin { margin = value }
        if let value = position.theme { theme = value }
        if let value = position.userCSS { userCSS = value }
        if let value = position.useDocumentCSS { useDocumentCSS = value }
    }

    func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: "bookmarks")
        for reader in ReaderWindows.states where reader !== self { reader.bookmarks = bookmarks }
    }

    func readPreferences() {
        let defaults = UserDefaults.standard
        zoomLevels = (try? ReadingZoom.parseLevels(defaults.string(forKey: "zoomLevels") ?? "")) ?? []
        zoomIncrement = max(0, defaults.double(forKey: "zoomIncrement"))
        zoomLimit = configuredZoomMaximum
        fit = defaults.string(forKey: "fit") ?? "page"
        if ReadingZoom.fitTitles[fit] == nil { fit = "page" }
        flow = defaults.string(forKey: "flow") ?? "paged"
        scrollbarMode = defaults.string(forKey: "scrollbarMode") ?? "smart"
        spread = defaults.bool(forKey: "spread")
        automaticLayout = defaults.bool(forKey: "automaticLayout")
        invertColors = defaults.bool(forKey: "invertColors")
        grayscale = defaults.bool(forKey: "grayscale")
        documentColors = defaults.string(forKey: "documentColors") ?? "off"
        preservePDFImages = defaults.object(forKey: "preservePDFImages") as? Bool ?? true
        engineeringEnhance = defaults.string(forKey: "engineeringEnhance") ?? "off"
        customTextColor = nil; customBackgroundColor = nil
        pageMargins = defaults.data(forKey: "pageMargins").flatMap { try? JSONDecoder().decode(PageMargins.self, from: $0) }
        inverseSearchEnabled = defaults.object(forKey: "inverseSearchEnabled") as? Bool ?? true
        landscapeAsSpread = defaults.object(forKey: "landscapeAsSpread") as? Bool ?? true
        rtl = defaults.bool(forKey: "rtl")
        cover = defaults.bool(forKey: "cover")
        showContents = defaults.bool(forKey: "showContentsOnOpen")
        font = defaults.string(forKey: "font") ?? "system"
        theme = defaults.string(forKey: "theme") ?? "system"
        userCSS = defaults.string(forKey: "userCSS") ?? ""
        useDocumentCSS = defaults.object(forKey: "useDocumentCSS") as? Bool ?? true
        fontSize = defaults.object(forKey: "fontSize") == nil ? 17 : defaults.double(forKey: "fontSize")
        lineHeight = defaults.object(forKey: "lineHeight") == nil ? 1.6 : defaults.double(forKey: "lineHeight")
        margin = defaults.object(forKey: "margin") == nil ? 32 : defaults.double(forKey: "margin")
        pageGridWidth = defaults.object(forKey: "pageGridWidth") as? Double ?? 72
        pageGridHeight = defaults.object(forKey: "pageGridHeight") as? Double ?? 72
        pageGridOffsetX = defaults.double(forKey: "pageGridOffsetX")
        pageGridOffsetY = defaults.double(forKey: "pageGridOffsetY")
        pageGridSubdivisions = defaults.object(forKey: "pageGridSubdivisions") as? Int ?? 4
        pageGridColor = UInt32(clamping: defaults.object(forKey: "pageGridColor") as? Int ?? 0x8080ff)
        pageGridStyle = defaults.string(forKey: "pageGridStyle") ?? "dots"
    }

    func watchFile(_ url: URL) {
        stopWatch()
        guard !url.hasDirectoryPath else { return }
        let fileDescriptor = Darwin.open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        watch = source
        let watchedSource = ObjectIdentifier(source as AnyObject)
        source.setEventHandler { [weak self] in
            guard let self,
                  !self.busy,
                  let source = self.watch,
                  ObjectIdentifier(source as AnyObject) == watchedSource,
                  self.document?.url == url
            else { return }

            let event = source.data
            self.status = "File changed on disk"
            self.reloadTask?.cancel()
            self.reloadTask = nil
            guard !self.modified else {
                self.status = "File changed on disk; unsaved edits remain open"
                // Atomic replacement leaves the open PDF on its retained stream,
                // but future disk changes belong to the new inode at this path.
                if event.contains(.delete) || event.contains(.rename) { self.watchFile(url) }
                return
            }
            self.reloadTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, !self.busy, self.document?.url == url else { return }
                if event.contains(.delete) || event.contains(.rename) {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        self.status = "File moved or deleted"
                        self.stopWatch()
                        return
                    }
                }
                self.reload()
            }
        }
        source.setCancelHandler { Darwin.close(fileDescriptor) }
        source.resume()
    }

    func stopWatch() {
        reloadTask?.cancel()
        reloadTask = nil
        watch?.cancel()
        watch = nil
    }
}

#endif
