#if os(macOS)
import Foundation
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import SumraCore

struct BrowserPrintSnapshot: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        let url: URL
        let path: String
    }
    let html: String
    let resources: [Resource]

    func makePDF(source: any BrowserSource, directory: URL) async throws -> (url: URL, count: Int) {
        if !resources.isEmpty {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("resources"),
                                                    withIntermediateDirectories: false)
        }
        for resource in resources {
            try Task.checkCancellation()
            let data: Data
            switch resource.url.scheme {
            case "leaf": data = try await source.response(resource.url).0
            case "data":
                let value = resource.url.absoluteString
                guard let comma = value.firstIndex(of: ",") else { throw ReadError("Invalid embedded print resource") }
                let payload = String(value[value.index(after: comma)...])
                if value[..<comma].hasSuffix(";base64") {
                    guard let decoded = Data(base64Encoded: payload) else { throw ReadError("Invalid embedded print resource") }
                    data = decoded
                } else {
                    guard let decoded = payload.removingPercentEncoding else { throw ReadError("Invalid embedded print resource") }
                    data = Data(decoded.utf8)
                }
            case "https", "http":
                let result = try await URLSession.shared.data(from: resource.url)
                guard let response = result.1 as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw ReadError("Cannot read print resource: " + resource.url.absoluteString)
                }
                data = result.0
            default: throw ReadError("Unsupported print resource: " + resource.url.absoluteString)
            }
            try data.write(to: directory.appendingPathComponent(resource.path))
        }
        let input = directory.appendingPathComponent("Topic.html")
        let output = directory.appendingPathComponent("Topic.pdf")
        try Data(html.utf8).write(to: input)
        try Task.checkCancellation()
        let file = try NativeFile(input, engine: .mupdf)
        try file.exportPDF(to: output)
        return (output, file.count)
    }
}

// #SYSTEM/#WINDOWS records and LCID mapping translated from SumatraPDF
// src/ChmFile.cpp, revision 012d997f (GPLv3); DOM parsing remains WebKit's job.
struct CHMMetadata {
    var title = ""
    var home = ""
    var toc = ""
    var encoding: String.Encoding = .windowsCP1252

    var charset: String {
        let value = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        return CFStringConvertEncodingToIANACharSetName(value).map { $0 as String } ?? "windows-1252"
    }

    init(system: Data?, windows: Data? = nil, strings: Data? = nil, lcid: UInt32 = 1033) {
        func uint(_ data: Data, _ offset: Int, _ size: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count, size <= data.count - offset else { return nil }
            return data[offset..<(offset + size)].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        // Windows code pages from Sumatra's LcidToCodepage; Western locales use 1252.
        let codepages: [UInt32: UInt32] = [1025:1256, 2052:936, 1028:950, 1029:1250,
            1032:1253, 1037:1255, 1038:1250, 1041:932, 1042:949, 1045:1250,
            1049:1251, 1051:1250, 1060:1250, 1055:1254, 1026:1251, 4:936,
            1058:1251, 1059:1251, 3098:1251, 2074:1251, 1071:1251, 1087:1251,
            1088:1251, 1092:1251, 1104:1251, 2092:1251]
        var records: [UInt32: Data] = [:]
        if let system {
            var offset = 4 // version DWORD
            while let type = uint(system, offset, 2), let length = uint(system, offset + 2, 2) {
                let start = offset + 4, end = start + Int(length)
                guard end <= system.count else { break }
                if records[type] == nil { records[type] = Data(system[start..<end]) }
                offset = end
            }
        }
        let language = records[4].flatMap { uint($0, 0, 4) } ?? lcid
        let value = CFStringConvertWindowsCodepageToEncoding(codepages[language] ?? 1252)
        encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        func text(_ data: Data?, at offset: Int = 0) -> String {
            guard let data, offset >= 0, offset < data.count else { return "" }
            guard let end = data[offset...].firstIndex(of: 0) else { return "" }
            let bytes = data[offset..<end]
            return String(data: Data(bytes), encoding: .utf8)
                ?? String(data: Data(bytes), encoding: encoding) ?? ""
        }
        // #WINDOWS takes precedence, as in Sumatra; offsets point into #STRINGS.
        if let windows, let strings, let count = uint(windows, 0, 4),
           let recordSize = uint(windows, 4, 4), recordSize >= 188 {
            var offset = 8
            for _ in 0..<min(Int(count), max(0, (windows.count - 8) / Int(recordSize))) {
                for (field, delta) in [("title", 0x14), ("toc", 0x60), ("home", 0x68)] {
                    guard let stringOffset = uint(windows, offset + delta, 4) else { continue }
                    let string = text(strings, at: Int(stringOffset))
                    switch field {
                    case "title": if title.isEmpty { title = string }
                    case "toc": if toc.isEmpty { toc = string }
                    default: if home.isEmpty { home = string }
                    }
                }
                offset += Int(recordSize)
            }
        }
        if toc.isEmpty { toc = text(records[0]) }
        if home.isEmpty { home = text(records[2]) }
        if title.isEmpty { title = text(records[3]) }
    }
}

actor CHMSource: BrowserSource {
    nonisolated let startURL: URL
    let url: URL
    private let entries: [String]
    private let metadata: CHMMetadata
    private let chm: NativeFile
    private let index: [String: Int]
    private nonisolated let names: [String: String]

    init(_ url: URL) throws {
        self.url = url
        let chm = try NativeFile(url, engine: .chm)
        self.chm = chm
        var raw: [(Data, Int)] = []
        var special: [String: Data] = [:]
        for i in 0..<chm.count {
            let path = try chm.rawPath(i)
            raw.append((path, i))
            if let name = String(data: path, encoding: .utf8)?.lowercased(),
               ["/#system", "/#windows", "/#strings"].contains(name) {
                special[name] = try chm.data(i)
            }
        }
        let header = try FileHandle(forReadingFrom: url)
        defer { try? header.close() }
        let bytes = try header.read(upToCount: 24) ?? Data()
        let lcid = bytes.count == 24 ? bytes[20..<24].enumerated().reduce(UInt32(0)) {
            $0 | UInt32($1.element) << ($1.offset * 8)
        } : 1033
        let metadata = CHMMetadata(system: special["/#system"], windows: special["/#windows"],
                                   strings: special["/#strings"], lcid: lcid)
        self.metadata = metadata
        var index: [String: Int] = [:], entries: [String] = []
        for (bytes, i) in raw {
            guard let decoded = String(data: bytes, encoding: .utf8)
                    ?? String(data: bytes, encoding: metadata.encoding) else { continue }
            let path = String(decoded.drop(while: { $0 == "/" })).replacingOccurrences(of: "\\", with: "/")
            // These three metadata streams have already been decoded above.
            guard !["#system", "#windows", "#strings"].contains(path.lowercased()) else { continue }
            if index[path.lowercased()] == nil {
                index[path.lowercased()] = i
                entries.append(path)
            }
        }
        self.index = index
        self.entries = entries
        names = Dictionary(uniqueKeysWithValues: entries.map { ($0.lowercased(), $0) })
        let home = metadata.home.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // HHC may name extensionless/image topics. The single index pass
        // chooses the actual first page before this URL is ever loaded.
        let path = names[home.lowercased()] ?? entries.first
        guard let path else { throw ReadError("This CHM contains no readable topics") }
        startURL = URL(string: "leaf://book/entry/")!.appendingPathComponent(path)
    }

    nonisolated func canonicalURL(_ url: URL) -> URL? {
        guard url.scheme == "leaf", url.host == "book", url.path.hasPrefix("/entry/"),
              let name = names[String(url.path.dropFirst(7)).lowercased()] else { return nil }
        var target = URLComponents(url: URL(string: "leaf://book/entry/")!.appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        target.fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
        return target.url
    }

    func response(_ url: URL) throws -> (Data, String?) {
        try Task.checkCancellation()
        if url.path == "/meta" {
            let tocPath = entries.first { $0.lowercased() == metadata.toc.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() }
                ?? entries.first { $0.lowercased().hasSuffix(".hhc") }
            let toc = try tocPath.flatMap { index[$0.lowercased()] }.map { try chm.data($0).base64EncodedString() }
            let data = try JSONSerialization.data(withJSONObject: [
                "name": metadata.title.isEmpty ? self.url.lastPathComponent : metadata.title,
                "home": metadata.home, "toc": tocPath ?? "", "tocData": toc ?? "", "charset": metadata.charset,
                "entries": entries.map { ["filename": $0] }
            ])
            return (data, "utf-8")
        }
        guard url.path.hasPrefix("/entry/"),
              let index = index[String(url.path.dropFirst("/entry/".count)).lowercased()] else {
            throw ReadError("CHM resource not found")
        }
        // Preserve original bytes. WebKit/TextDecoder honors charset declarations first.
        let textual = ["", "html", "htm", "xhtml", "xht", "hhc", "hhk", "txt", "css", "svg"]
            .contains(url.pathExtension.lowercased())
        let data = try chm.data(index)
        guard textual else { return (data, nil) }
        // Keep BOM/HTML declarations ahead of #SYSTEM's fallback encoding,
        // matching ChmFile plus the browser's normal encoding detection.
        let prefix = String(decoding: data.prefix(1024), as: UTF8.self)
        let ext = url.pathExtension.lowercased()
        let xmlDeclaration = prefix.range(of: #"^\s*<\?xml\s[^>]*encoding\s*=\s*["'][^"']+["']"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let html = ["", "html", "htm", "xhtml", "xht", "hhc", "hhk"].contains(ext)
        // A literal charset= in prose, comments or scripts is not a declaration.
        // Reuse Foundation's tolerant parser for this bounded prefix; WebKit
        // still receives the original bytes and owns actual HTML decoding.
        let document = html ? try? XMLDocument(xmlString: prefix,
            options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) : nil
        let metas = (try? document?.nodes(forXPath: "//meta")) ?? []
        let metaDeclaration = metas.contains { node in
            guard let element = node as? XMLElement else { return false }
            if element.attribute(forName: "charset")?.stringValue?.isEmpty == false { return true }
            return element.attribute(forName: "http-equiv")?.stringValue?.lowercased() == "content-type"
                && element.attribute(forName: "content")?.stringValue?.range(of: #"charset\s*="#,
                    options: [.regularExpression, .caseInsensitive]) != nil
        }
        let cssDeclaration = ext == "css" && prefix.range(of: #"^@charset\s+["'][^"']+["']"#,
            options: [.regularExpression, .caseInsensitive]) != nil
        let declared = metaDeclaration || cssDeclaration || (ext != "txt" && xmlDeclaration)
        if declared || data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return (data, nil) }
        return (data, String(data: data, encoding: .utf8) != nil ? "utf-8" : metadata.charset)
    }
    func properties() -> [String: String] {
        ["Title": metadata.title, "Character Set": metadata.charset, "Home": metadata.home, "Contents": metadata.toc]
            .filter { !$0.value.isEmpty }
    }
}

@MainActor
struct BrowserReader: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    let source: any BrowserSource

    func makeCoordinator() -> Coordinator { Coordinator(state: state, source: source) }

    // ChmModel::CreateThumbnail renders the home topic in a temporary browser.
    // Reuse this reader's resource/theme owner without a document state
    // that could persist the preview's position or add it to recent files.
    static func thumbnail(_ source: any BrowserSource, size: CGSize) async throws -> CGImage? {
        let state = ReaderState(recordsHistory: false)
        state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 24
        state.theme = "light"; state.zoom = 1
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        let coordinator = Coordinator(state: state, source: source)
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 600, height: size.height * 600 / size.width))
        defer { dismantleNSView(view, coordinator: coordinator) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                @MainActor func finish(_ result: Result<CGImage?, Error>) {
                    guard coordinator.readyHandler != nil else { return }
                    coordinator.readyHandler = nil
                    continuation.resume(with: result)
                }
                coordinator.readyHandler = { error in
                    if let error { finish(.failure(error)); return }
                    // Keep cancellation connected until the snapshot completes.
                    coordinator.readyHandler = { error in
                        if let error { finish(.failure(error)) }
                    }
                    let snapshot = WKSnapshotConfiguration()
                    snapshot.snapshotWidth = NSNumber(value: Double(size.width))
                    view.takeSnapshot(with: snapshot) { image, error in
                        guard coordinator.readyHandler != nil else { return }
                        if let error { finish(.failure(error)); return }
                        do {
                            let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                            // snapshotWidth is in points; home cards request pixels.
                            let result = try pixels.map { try ReaderImages.resized($0, width: Int(size.width), height: Int(size.height)) }
                            finish(.success(result))
                        } catch { finish(.failure(error)) }
                    }
                }
                coordinator.load(view)
            }
        } onCancel: {
            Task { @MainActor in coordinator.readyHandler?(CancellationError()) }
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let view = coordinator.makeView(position: state.currentPosition)
        state.selectionScreenBounds = { [weak view, weak coordinator] in
            guard let view, coordinator?.isCurrent == true, coordinator?.ready == true, let window = view.window else { return nil }
            do {
                guard let rect = try await view.callAsyncJavaScript("return window.leafSelectionBounds()", arguments: [:], in: nil, contentWorld: coordinator?.scriptWorld ?? .page) as? [Double],
                      rect.count == 4, coordinator?.isCurrent == true else { return nil }
                let scale = view.pageZoom
                let box = CGRect(x: rect[0] * scale, y: rect[1] * scale, width: rect[2] * scale, height: rect[3] * scale)
                let local = view.isFlipped ? box : CGRect(x: box.minX, y: view.bounds.height-box.maxY, width: box.width, height: box.height)
                return window.convertToScreen(view.convert(local, to: nil))
            } catch { if coordinator?.isCurrent == true { coordinator?.state.error = error.localizedDescription }; return nil }
        }
        coordinator.load(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.updateInteraction(view)
        guard coordinator.isCurrent, coordinator.command != state.command.revision else { return }
        coordinator.command = state.command.revision
        if let error = coordinator.readerError { coordinator.completeCommand(state.command.revision, error: error) }
        else if coordinator.ready { coordinator.deliver(state.command, to: view) }
        else { coordinator.pending.append(state.command) }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        if let job = coordinator.printJob { coordinator.finishPrint(job, restore: false) }
        else if let revision = coordinator.command { coordinator.completeCommand(revision) }
        coordinator.clearRangeHighlights()
        coordinator.active = false
        if let markup = coordinator.markup { Task { await markup.cancelOutline() } }
        if coordinator.state.browserView === view { coordinator.state.browserView = nil }
        coordinator.requests.values.forEach { $0.cancel() }
        coordinator.requests.removeAll()
        coordinator.pending.removeAll()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leaf", contentWorld: coordinator.scriptWorld)
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
        let state: ReaderState
        let source: any BrowserSource
        let documentID: UUID?
        var active = true
        var command: Int?
        var ready = false
        var initialPosition: ReadingPosition?
        var pagePositions = [Int: ReadingPosition]()
        var displayedURL: URL?
        var restoringNavigation = false
        var navigationRevision: Int?
        var markup: MarkupSource? { source as? MarkupSource }
        var chm: CHMSource? { source as? CHMSource }
        let scriptWorld = WKContentWorld.world(name: "SumraMarkup")
        var pages = [URL]()
        var outline = [ContentsItem]()
        var readyHandler: ((Error?) -> Void)?
        var textInputFocused = false
        var interactionKey = ""
        var readerError: Error?
        var pending: [ReaderCommand] = []
        var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
        struct PrintJob {
            let command: ReaderCommand
            let url: URL?
            let info: NSPrintInfo
            var exporting: Bool { command.action == .exportPDF }
        }
        var printJob: PrintJob?
        var printOperation: NSPrintOperation?
        var printPreparation: Task<Void, Never>?
        var printDirectory: TemporaryDirectory?
        var printCompletionError: Error?
        var printMayRestore = true
        var savePanel: NSSavePanel?
        var rangeHighlightView: BrowserRangeHighlightView?
        var isCurrent: Bool { active && state.document?.id == documentID }
        var usesTextZoom: Bool { markup?.markdown == true }
        func pageZoom(_ zoom: Double) -> Double { usesTextZoom ? 1 : zoom }
        func styleArguments(zoom: Double? = nil) -> [String: Any] {
            let zoom = zoom ?? state.zoom
            let size = state.fontSize * (usesTextZoom ? zoom : 1)
            return ["text": "\(state.font)|\(size)|\(state.lineHeight)|\(state.margin)|\(state.resolvedTheme)",
                "zoom": pageZoom(zoom), "userCSS": state.effectiveUserCSS,
                "useDocumentCSS": state.useDocumentCSS, "pageMargins": state.pageMargins?.values ?? []]
        }

        init(state: ReaderState, source: any BrowserSource) {
            self.state = state
            self.source = source
            documentID = state.document?.id
            pages = (source as? MarkupSource)?.pages ?? []
        }

        func pageIndex(_ url: URL) -> Int? {
            if let markup { return markup.pageIndex(url) }
            guard let canonical = chm?.canonicalURL(url) else { return nil }
            return pages.firstIndex { $0.path == canonical.path }
        }

        static var resources: URL {
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("Reader")
            return bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? Bundle.module.url(forResource: "Reader", withExtension: nil)!
        }

        func makeView(frame: CGRect = .zero, position: ReadingPosition? = nil) -> WKWebView {
            initialPosition = position
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(self, forURLScheme: "leaf")
            configuration.userContentController.add(self, contentWorld: scriptWorld, name: "leaf")
            let view = WKWebView(frame: frame, configuration: configuration)
            view.pageZoom = pageZoom(state.zoom)
            view.navigationDelegate = self
            state.browserView = view
            return view
        }

        func installScripts(_ controller: WKUserContentController) {
            controller.removeAllUserScripts()
            let values: [String: Any] = ["pages": pages.map(\.absoluteString),
                "page": pageIndex(source.startURL) ?? 0, "markdown": markup?.markdown ?? false,
                "chm": chm != nil, "initial": styleArguments(),
                "outline": outline.map { item -> [String: Any] in
                    ["title": item.title, "target": item.target, "depth": item.depth, "page": item.page ?? 0]
                }]
            do {
                let data = try JSONSerialization.data(withJSONObject: values)
                controller.addUserScript(WKUserScript(source: "window.sumraDocument=\(String(decoding: data, as: UTF8.self));",
                    injectionTime: .atDocumentStart, forMainFrameOnly: false, in: scriptWorld))
                for resource in (chm != nil || markup?.markdown == false ? ["chm.js"] : []) + ["sumatra-find.js", "markdown.js"] {
                    let script = try String(contentsOf: Self.resources.appendingPathComponent(resource), encoding: .utf8)
                    controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                        forMainFrameOnly: false, in: scriptWorld))
                }
            } catch { readerFailed(error) }
        }

        func clearRangeHighlights() {
            rangeHighlightView?.removeFromSuperview()
            rangeHighlightView = nil
        }

        func updateRangeHighlights(_ body: [String: Any], in view: WKWebView) {
            let rectangles = BrowserRangeHighlightView.rectangles(body, zoom: view.pageZoom, size: view.bounds.size)
            guard !rectangles.isEmpty else { clearRangeHighlights(); return }
            let overlay = rangeHighlightView ?? BrowserRangeHighlightView(frame: view.bounds)
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.rectangles = rectangles
            if overlay.superview !== view { view.addSubview(overlay, positioned: .above, relativeTo: nil) }
            rangeHighlightView = overlay
        }

        func load(_ view: WKWebView) {
            clearRangeHighlights()
            if chm != nil, pages.isEmpty {
                // Use this view's native HTML parser once for the CHM index;
                // the same view then displays the selected topic directly.
                Task {
                    do {
                        let (data, _) = try await source.response(URL(string: "leaf://book/meta")!)
                        guard isCurrent, view === state.browserView else { return }
                        let metadata = try JSONSerialization.jsonObject(with: data)
                        let script = try String(contentsOf: Self.resources.appendingPathComponent("chm.js"), encoding: .utf8)
                        let value = try await view.callAsyncJavaScript(script + "\nreturn await indexCHM(meta);",
                            arguments: ["meta": metadata], in: nil, contentWorld: scriptWorld)
                        guard isCurrent, view === state.browserView else { return }
                        guard let book = value as? [String: Any], let urls = book["pages"] as? [String], !urls.isEmpty else {
                            throw ReadError("Cannot read the CHM topic index")
                        }
                        pages = urls.compactMap(URL.init(string:))
                        let items = try JSONSerialization.data(withJSONObject: book["toc"] ?? [])
                        outline = try JSONDecoder().decode([ContentsItem].self, from: items)
                        load(view)
                    } catch { if isCurrent { readerFailed(error) } }
                }
                return
            }
            let saved = initialPosition?.anchor.flatMap(URL.init(string:))
            let fallback = chm != nil ? pages.first ?? source.startURL : source.startURL
            let topic = chm != nil ? initialPosition.flatMap { pages.indices.contains($0.page) ? pages[$0.page] : nil } : nil
            let url = saved.flatMap { pageIndex($0) == nil ? nil : $0 }
                ?? topic ?? fallback
            if let page = pageIndex(url) {
                var target = initialPosition ?? .init(page: page)
                target.page = page; target.anchor = url.absoluteString
                initialPosition = target
            }
            // Keep the explicit fragment in initialPosition only. Loading it
            // in WebKit's URL would start a second scroll after our activation.
            var requestURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            requestURL.fragment = nil
            view.load(URLRequest(url: requestURL.url!))
        }

        func position(_ value: ReadingPosition) -> [String: Any] {
            var result: [String: Any] = ["page": value.page]
            if let anchor = value.anchor { result["anchor"] = anchor }
            if let x = value.x { result["x"] = x }
            if let y = value.y { result["y"] = y }
            if let passage = value.markdownPassage, let data = try? JSONEncoder().encode(passage),
               let object = try? JSONSerialization.jsonObject(with: data) { result["markdownPassage"] = object }
            return result
        }
        var interactionFlags: [String: Any] {
            ["showLinks": state.showLinks, "disableLinks": state.disableLinks,
                         "hoverPreview": state.hoverPreview, "keyboardLinks": state.keyboardLinkFollowing,
                         "keyboardSelection": state.keyboardTextSelection, "speechFollow": state.speechFollow,
                         "scrollbars": state.scrollbarMode,
                         "outlineRequested": state.showContents || state.paletteContentsVisible]
        }
        func updateInteraction(_ view: WKWebView) {
            guard isCurrent, ready else { return }
            let flags = interactionFlags
            let key = flags.keys.sorted().map { "\($0):\(flags[$0]!)" }.joined()
            guard key != interactionKey else { return }; interactionKey = key
            view.callAsyncJavaScript("return await window.leafCommand(command)", arguments: ["command": ["name": "interaction", "flags": flags]], in: nil, in: scriptWorld) { [weak self] result in
                if case .failure(let error) = result, self?.isCurrent == true { self?.state.error = error.localizedDescription }
            }
        }

        func deliver(_ command: ReaderCommand, to view: WKWebView) {
            guard isCurrent else { return }
            switch command.action {
            case .zoom(let zoom): clearRangeHighlights(); view.pageZoom = pageZoom(zoom)
            case .restore: clearRangeHighlights(); view.pageZoom = pageZoom(state.zoom)
            case .style: clearRangeHighlights()
            default: break
            }
            var payload: [String: Any]
            switch command.action {
            case .turnPages(let count, _): payload = ["name": "turnPages", "count": count]
            case .page(let value): payload = ["name": "page", "number": value]
            case .location(let value): payload = ["name": "location", "text": value]
            case .scroll(let direction, let amount, let count): payload = ["name": "scroll", "direction": direction.rawValue, "amount": amount.rawValue, "count": count]
            case .restore(let value):
                payload = styleArguments(); payload["name"] = "restore"; payload["position"] = position(value)
            case .href(let value): payload = ["name": "href", "text": value]
            case .zoom(let value):
                payload = styleArguments(zoom: value); payload["name"] = "zoom"; payload["number"] = pageZoom(value)
            case .style: payload = styleArguments(); payload["name"] = "style"
            case .toc: payload = ["name": "toc"]
            case .find(let value, let backwards, let options, let selection, _):
                let options = options ?? .init()
                payload = ["name": "find", "text": value, "backwards": backwards, "matchCase": options.caseSensitive, "matchWholeWords": options.wholeWord, "fromSelection": selection]
            case .copy: payload = ["name": "copy"]
            case .selectAll: payload = ["name": "selectAll"]
            case .selectCurrentPage: payload = ["name": "selectCurrentPage"]
            case .readAloud: payload = ["name": "readAloud"]
            case .readAloudFromTop: payload = ["name": "readAloud", "source": "visible"]
            case .readAloudFromCursor: payload = ["name": "readAloud", "source": "cursor"]
            case .readAloudSelection: payload = ["name": "readAloud", "source": "selection"]
            case .speechHighlight(let location, let length): payload = ["name": "speechHighlight", "location": location, "length": length]
            case .print, .exportPDF:
                preparePrint(view, command: command)
                return
            default: completeCommand(command.revision); return
            }
            // A search is cancellable by a later find/TOC command. Acknowledge its
            // launch rather than waiting for every chapter; other commands await
            // their navigation/selection/reflow promise before advancing Swift's queue.
            let script = payload["name"] as? String == "find"
                ? "void window.leafCommand(command)" : "return await window.leafCommand(command)"
            view.callAsyncJavaScript(script, arguments: ["command": payload], in: nil, in: scriptWorld) { [weak self] result in
                guard let self, self.isCurrent, self.state.command.revision == command.revision else { return }
                switch result {
                case .failure(let error): self.completeCommand(command.revision, error: error)
                case .success(let value):
                    if let result = value as? [String: Any],
                       let target = result["navigation"] as? String, let url = URL(string: target) {
                        self.navigationRevision = command.revision
                        self.ready = false
                        self.clearRangeHighlights()
                        if case .restore(let position) = command.action {
                            self.initialPosition = position
                            self.restoringNavigation = true
                        } else if let page = self.pageIndex(url) {
                            var position = self.pagePositions[page] ?? .init(page: page)
                            position.anchor = url.absoluteString
                            self.initialPosition = position
                            self.restoringNavigation = true
                        }
                        // ReaderState owns navigation history. All in-book
                        // revisits reuse the native page; activation applies the
                        // requested position or fragment to its cached realm.
                        let list = view.backForwardList
                        let candidates = Array(list.backList.reversed()).enumerated().map { ($0.offset, $0.element) }
                            + list.forwardList.enumerated().map { ($0.offset, $0.element) }
                        if let page = self.pageIndex(url),
                           let item = candidates.filter({ self.pageIndex($0.1.url) == page })
                                .min(by: { $0.0 < $1.0 })?.1 {
                            if view.go(to: item) != nil { return }
                        }
                        var requestURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                        if self.pageIndex(url) != nil { requestURL.fragment = nil }
                        view.load(URLRequest(url: requestURL.url!))
                    } else { self.completeCommand(command.revision) }
                }
            }
        }

        func completeCommand(_ revision: Int, error: Error? = nil) {
            guard isCurrent, state.command.revision == revision else { return }
            if let error {
                let description = error.localizedDescription
                let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                state.error = detail.map { $0 == description ? description : description + "\n" + $0 } ?? description
            }
            state.didHandleCommand(revision)
        }

        func isPrintCurrent(_ job: PrintJob, view: WKWebView? = nil) -> Bool {
            isCurrent && state.command.revision == job.command.revision
                && printJob?.command.revision == job.command.revision
                && state.browserView?.url == job.url
                && (view == nil || view === state.browserView)
        }

        func finishPrint(_ job: PrintJob, error: Error? = nil, restore: Bool = true) {
            guard printJob?.command.revision == job.command.revision else { return }
            // Navigation/teardown can invalidate the topic while AppKit is still
            // printing. Keep the operation and queue owned until its callback.
            if printOperation != nil {
                printCompletionError = printCompletionError ?? error
                printMayRestore = printMayRestore && restore
                return
            }
            let view = state.browserView
            let shouldRestore = restore && view.map { isPrintCurrent(job, view: $0) } == true
            printJob = nil
            printPreparation?.cancel()
            printPreparation = nil
            printDirectory = nil
            printCompletionError = nil
            printMayRestore = true
            let panel = savePanel
            savePanel = nil
            panel?.cancel(nil)
            guard shouldRestore, let view else { completeCommand(job.command.revision, error: error); return }
            // The print operation may have changed the live viewport. Restore it
            // before releasing a queued reading command, which must win afterward.
            view.callAsyncJavaScript("return window.leafRestorePrintViewport()", arguments: [:], in: nil, in: scriptWorld) { [weak self, weak view] result in
                guard let self else { return }
                guard let view, self.isCurrent, self.state.browserView === view,
                      self.state.command.revision == job.command.revision,
                      view.url == job.url, self.displayedURL == job.url else {
                    self.completeCommand(job.command.revision, error: error ?? ReadError("The displayed topic changed before printing completed."))
                    return
                }
                switch result {
                case .failure(let restoreError): self.completeCommand(job.command.revision, error: error ?? restoreError)
                case .success(let restored):
                    self.completeCommand(job.command.revision, error: error ?? ((restored as? Bool) == true ? nil : ReadError("Browser position could not be restored after printing.")))
                }
            }
        }

        func preparePrint(_ view: WKWebView, command: ReaderCommand) {
            let job = PrintJob(command: command, url: view.url, info: state.printInfo)
            printJob = job
            // Capture the live topic, then let MuPDF own its printable PDF.
            // WebKit remains the reader; its PDF writer loses source Unicode.
            view.callAsyncJavaScript("window.leafCapturePrintViewport(); await window.leafPreparePrint(); return window.leafPrintSnapshot()", arguments: [:], in: nil, in: scriptWorld) { [weak self, weak view] result in
                guard let self, let view, self.isPrintCurrent(job, view: view) else { return }
                self.printPreparation = Task { [weak self, weak view] in
                    guard let self, let view else { return }
                    do {
                        let value = try result.get()
                        let snapshot = try JSONDecoder().decode(BrowserPrintSnapshot.self,
                            from: JSONSerialization.data(withJSONObject: value))
                        let directory = try TemporaryDirectory()
                        let pdf = try await snapshot.makePDF(source: self.source, directory: directory.url)
                        try Task.checkCancellation()
                        guard self.isPrintCurrent(job, view: view) else { return }
                        self.printDirectory = directory
                        self.presentPrint(pdf.url, count: pdf.count, directory: directory, in: view, job: job)
                    } catch {
                        self.finishPrint(job, error: error)
                    }
                }
            }
        }

        func presentPrint(_ pdf: URL, count: Int, directory: TemporaryDirectory, in view: WKWebView, job: PrintJob) {
            if job.exporting {
                let panel = NSSavePanel()
                self.savePanel = panel
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = (self.state.document?.url.deletingPathExtension().lastPathComponent ?? "Book") + ".pdf"
                panel.begin { [weak self, weak view] response in
                    guard let self, let view, self.isPrintCurrent(job, view: view) else { return }
                    self.savePanel = nil
                    guard response == .OK, let url = panel.url else { self.finishPrint(job); return }
                    guard self.state.document.map({ !PDFTools.sameFile(url, $0.url) }) == true else {
                        self.finishPrint(job, error: ReadError("Choose a different location for Export PDF."))
                        return
                    }
                    let info = job.info
                    info.jobDisposition = .save
                    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                    self.runPreparedPrint(pdf, count: count, directory: directory, info: info, in: view, job: job)
                }
            } else {
                runPreparedPrint(pdf, count: count, directory: directory, info: job.info, in: view, job: job)
            }
        }

        func runPreparedPrint(_ pdf: URL, count: Int, directory: TemporaryDirectory, info: NSPrintInfo,
                              in view: WKWebView, job: PrintJob) {
            do {
                let printView = try ReaderPrinting.PDFPrintView(pageCount: count, preservePrintText: true) { index in
                    let page = directory.url.appendingPathComponent("PrintPage.pdf")
                    try NativePDFTools.selectPages(source: pdf, destination: page, pages: [index - 1])
                    return try Data(contentsOf: page)
                }
                let operation = try ReaderPrinting.makePrintOperation(printView, info: info,
                    title: state.document?.url.lastPathComponent ?? "Book", preferences: nil)
                operation.showsPrintPanel = !job.exporting
                runPrint(operation, in: view, job: job)
            } catch { finishPrint(job, error: error) }
        }

        func runPrint(_ operation: NSPrintOperation, in view: WKWebView, job: PrintJob) {
            guard isPrintCurrent(job, view: view) else { return }
            guard let window = view.window else {
                finishPrint(job, error: ReadError("Browser printing requires an open reader window."))
                return
            }
            printOperation = operation
            operation.runModal(for: window, delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }

        @objc nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            // AppKit may call the delegate from its printing thread.
            Task { @MainActor [weak self] in
                guard let self, self.printOperation === operation, let job = self.printJob else { return }
                self.printOperation = nil
                var error = self.printCompletionError
                if let printView = operation.view as? ReaderPrinting.PDFPrintView {
                    error = error ?? printView.error
                    if success, printView.error == nil {
                        do { try printView.finishSavedPrint(operation) }
                        catch let saveError { error = error ?? saveError }
                    }
                }
                if !success, self.isPrintCurrent(job) {
                    if job.exporting { error = error ?? ReadError("Browser Export PDF did not complete.") }
                    else { self.state.status = "Browser printing was cancelled or did not complete." }
                }
                self.finishPrint(job, error: error, restore: self.printMayRestore)
            }
        }

        func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard isCurrent, view === state.browserView else { return }
            ready = false
            clearRangeHighlights()
        }

        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(view, error: error)
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(view, error: error)
        }

        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            navigationFailed(view, error: NSError(domain: WKErrorDomain, code: WKError.Code.webContentProcessTerminated.rawValue))
        }

        func navigationFailed(_ view: WKWebView, error: Error) {
            guard isCurrent else { return }
            if view === state.browserView { readerFailed(error) }
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard isCurrent, view === state.browserView,
                  let url = view.url, pageIndex(url) != nil else { return }
            // Activate new and cached documents at navigation completion, as
            // BrowserDocView does. JS restore owns the current item's position.
            activateDocument(view)
        }

        func readerFailed(_ error: Error) {
            clearRangeHighlights()
            ready = false; readerError = error
            navigationRevision = nil
            state.error = error.localizedDescription
            pending.removeAll()
            if let job = printJob { finishPrint(job, error: error, restore: false) }
            else if let revision = command { completeCommand(revision, error: error) }
            readyHandler?(error)
        }

        func activateDocument(_ view: WKWebView) {
            clearRangeHighlights()
            let revision = navigationRevision, url = view.url
            do {
                if let url, let markup { state.didDisplayMarkupFile(try markup.fileURL(url)) }
            } catch { readerFailed(error); return }
            let flags = interactionFlags
            var payload = styleArguments()
            payload.merge(["name": "activate", "position": initialPosition.map(position) ?? [:],
                "flags": flags, "search": ["text": state.findQuery,
                    "matchCase": state.searchCaseSensitive, "matchWholeWords": state.searchWholeWord,
                    "enabled": state.showFind || !state.searchResults.isEmpty],
                "searchResults": state.searchResults.map { item -> [String: Any] in
                    ["title": item.title, "target": item.target, "depth": item.depth, "page": item.page ?? 0]
                }, "searchCountCapped": state.searchCountCapped,
                "selectedSearchTarget": state.selectedSearchTarget ?? "",
                "outline": state.outline.map { item -> [String: Any] in
                    ["title": item.title, "target": item.target, "depth": item.depth, "page": item.page ?? 0]
                }]) { _, value in value }
            view.pageZoom = pageZoom(state.zoom)
            view.callAsyncJavaScript("return await window.leafCommand(command)", arguments: ["command": payload],
                in: nil, in: scriptWorld) { [weak self, weak view] result in
                guard let self, let view, self.isCurrent, view === self.state.browserView,
                      view.url == url, self.navigationRevision == revision else { return }
                switch result {
                case .failure(let error): self.readerFailed(error)
                case .success(let value):
                    self.interactionKey = flags.keys.sorted().map { "\($0):\(flags[$0]!)" }.joined()
                    self.finishReady(view)
                    if let result = value as? [String: Any], let rectangles = result["rangeHighlights"] as? [String: Any] {
                        self.updateRangeHighlights(rectangles, in: view)
                    }
                }
            }
        }

        func finishReady(_ view: WKWebView) {
            readerError = nil
            ready = true
            displayedURL = view.url
            // UI demand may change while activation is awaiting fonts/frames.
            updateInteraction(view)
            if markup?.markdown == true { renderMermaid(view) }
            if let revision = navigationRevision {
                navigationRevision = nil
                completeCommand(revision)
            }
            for command in pending { deliver(command, to: view) }
            pending.removeAll()
            readyHandler?(nil)
        }

        func webView(_ view: WKWebView, start task: WKURLSchemeTask) {
            let id = ObjectIdentifier(task)
            requests[id] = Task { @MainActor in
                defer { requests.removeValue(forKey: id) }
                do {
                    guard let url = task.request.url else { throw ReadError("Missing resource URL") }
                    let data: Data, encoding: String?
                    if url.host == "reader" {
                        let root = Self.resources.standardizedFileURL.resolvingSymlinksInPath()
                        let file = root.appendingPathComponent(String(url.path.dropFirst()))
                            .standardizedFileURL.resolvingSymlinksInPath()
                        guard file.path.hasPrefix(root.path + "/") else { throw ReadError("Invalid reader resource path") }
                        data = try await Task.detached { try Data(contentsOf: file) }.value
                        encoding = "utf-8"
                    } else if url.host == "book" {
                        (data, encoding) = try await source.response(url)
                    } else { throw ReadError("Unknown resource host") }
                    guard !Task.isCancelled, requests[id] != nil, active else { return }
                    let fileType = UTType(filenameExtension: url.pathExtension)
                    let htmlPage = url.host == "book" && url.path.hasPrefix("/entry/")
                        && (["md", "markdown", "html", "htm", "xhtml", "xht"].contains(url.pathExtension.lowercased())
                            || markup != nil && pageIndex(url) != nil
                            || chm != nil && url.pathExtension.lowercased() != "txt" && fileType?.conforms(to: .image) != true && pageIndex(url) != nil)
                    let mime = htmlPage ? "text/html" : ["js": "text/javascript", "hhc": "text/html", "hhk": "text/html",
                                "xht": "application/xhtml+xml", "xhtml": "application/xhtml+xml"][url.pathExtension.lowercased()]
                        ?? (["/meta", "/outline"].contains(url.path) ? "application/json" : nil)
                        ?? fileType?.preferredMIMEType ?? "application/octet-stream"
                    let contentType = mime + (encoding.map { "; charset=" + $0 } ?? "")
                    var headers = ["Content-Type": contentType, "Content-Length": String(data.count),
                                   "Access-Control-Allow-Origin": "*"]
                    if htmlPage {
                        // ChmModel preserves local author scripts. They stay in the
                        // page world; the app bridge exists only in SumraMarkup.
                        let scripts = chm != nil ? "'unsafe-inline' leaf://book" : "'none'"
                        headers["Content-Security-Policy"] = "script-src \(scripts); object-src 'none'; frame-src leaf://book"
                    }
                    guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                        // The reader and book have separate origins. These read-only
                        // resources are scoped to this web view's scheme handler.
                        headerFields: headers) else {
                        throw ReadError("Cannot construct browser resource response")
                    }
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                } catch {
                    if !Task.isCancelled, requests[id] != nil, active {
                        // WebKit serializes userInfo, not Swift's LocalizedError provider.
                        let failure = error as NSError
                        var userInfo = failure.userInfo
                        userInfo[NSLocalizedDescriptionKey] = failure.localizedDescription
                        task.didFailWithError(NSError(domain: failure.domain, code: failure.code, userInfo: userInfo))
                    }
                }
            }
        }

        func webView(_ view: WKWebView, stop task: WKURLSchemeTask) {
            requests.removeValue(forKey: ObjectIdentifier(task))?.cancel()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isCurrent, message.frameInfo.request.url?.host == "book",
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if !message.frameInfo.isMainFrame, !["selection", "inputFocus", "navigate", "external", "copy", "readAloud", "status", "error", "keyboardMode"].contains(type) { return }
            switch type {
            case "layoutLimit":
                guard ready, state.document?.markdownRenderer != nil, let markup, markup.markdown,
                      let sender = message.frameInfo.request.url, let current = state.browserView?.url,
                      let page = pageIndex(current), pageIndex(sender) == page,
                      let file = try? markup.fileURL(current), file == state.document?.url.standardizedFileURL.resolvingSymlinksInPath() else { return }
                if !state.escalateMarkdownLayoutLimit() {
                    state.status = "This document exceeds compatibility mode’s layout limit. Choose Paged Markdown to reach the end."
                }
            case "rangeHighlights":
                guard ready, let view = message.webView, view === state.browserView,
                      let sender = message.frameInfo.request.url, let current = view.url,
                      let displayed = displayedURL else { return }
                func documentURL(_ url: URL) -> URL? {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.fragment = nil
                    return components?.url
                }
                guard let currentDocument = documentURL(current),
                      documentURL(sender) == currentDocument,
                      documentURL(displayed) == currentDocument else { return }
                updateRangeHighlights(body, in: view)
            case "searchHit":
                state.selectedSearchTarget = body["target"] as? String
            case "toc", "results":
                if type == "toc" {
                    guard let sender = message.frameInfo.request.url, let current = state.browserView?.url,
                          let page = pageIndex(current), pageIndex(sender) == page else { return }
                }
                if let items = body["items"], let data = try? JSONSerialization.data(withJSONObject: items),
                   let decoded = try? JSONDecoder().decode([ContentsItem].self, from: data) {
                    if type == "toc" { state.outline = decoded }
                    else {
                        if body["append"] as? Bool == true { state.searchResults.append(contentsOf: decoded) }
                        else { state.searchResults = decoded }
                        state.searchCountCapped = !state.searchResults.isEmpty && body["capped"] as? Bool == true
                    }
                }
            case "position":
                if let page = body["page"] as? Int {
                    let count = body["count"] as? Int ?? 0, label = body["label"] as? String
                    if state.count != count { state.count = count }
                    if state.logicalPageLabel != label { state.logicalPageLabel = label }
                    var position = ReadingPosition(page: page, x: body["x"] as? Double, y: body["y"] as? Double, anchor: body["anchor"] as? String)
                    if let passage = body["markdownPassage"] as? [String: Any],
                       let data = try? JSONSerialization.data(withJSONObject: passage) {
                        position.markdownPassage = try? JSONDecoder().decode(MarkdownPassage.self, from: data)
                    }
                    pagePositions[page] = position
                    state.updatePosition(position)
                }
            case "navigate":
                if let href = body["href"] as? String { state.navigate(.href(href)) }
            case "selection":
                let selected = body["selected"] as? Bool == true
                if state.hasSelection != selected { state.hasSelection = selected }
            case "inputFocus": textInputFocused = body["focused"] as? Bool ?? false
            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "readAloud": state.readText(body["text"] as? String ?? "", page: body["page"] as? Int, startOffset: body["startOffset"] as? Int ?? 0)
            case "keyboardMode": state.keyboardLinkFollowing = body["links"] as? Bool ?? false
            case "status": state.status = body["message"] as? String ?? ""
            case "error", "outlineError":
                // Leaving a page cancels its outstanding outline fetch. That
                // old realm's rejection must not fail the incoming document.
                guard let sender = message.frameInfo.request.url, let current = state.browserView?.url,
                      let page = pageIndex(current), pageIndex(sender) == page else { return }
                let error = ReadError(body["message"] as? String ?? "Unable to render book")
                if type == "outlineError" || ready { state.error = error.localizedDescription }
                else { readerFailed(error) }
            case "external":
                if let href = body["href"] as? String, let url = URL(string: href),
                   ["https", "http", "mailto"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            default: break
            }
        }

        func renderMermaid(_ view: WKWebView) {
            view.callAsyncJavaScript("return !!document.querySelector('code[class~=\"language-mermaid\" i], pre.mermaid:not([data-processed=\"true\"])')",
                arguments: [:], in: nil, in: scriptWorld) { [weak self, weak view] result in
                guard case .success(let value) = result, value as? Bool == true,
                      let self, let view, self.isCurrent else { return }
                let url = view.url
                let resource = Self.resources.appendingPathComponent("mermaid.min.js")
                Task {
                    do {
                        let script = try await Task.detached {
                            try String(contentsOf: resource, encoding: .utf8)
                        }.value
                        guard self.isCurrent, view.url == url else { return }
                        // The library's final expression is its function-bearing API.
                        // Keep that value in JavaScript instead of bridging it to Swift.
                        _ = try await view.evaluateJavaScript(script + "\nvoid 0;", in: nil, contentWorld: self.scriptWorld)
                        guard self.isCurrent, view.url == url else { return }
                        _ = try await view.callAsyncJavaScript("await window.sumraRenderMermaid();",
                            arguments: [:], in: nil, contentWorld: self.scriptWorld)
                    } catch { if self.isCurrent, view.url == url { self.state.error = error.localizedDescription } }
                }
            }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            if action.targetFrame?.isMainFrame != false, let url {
                if chm != nil, url.scheme == "javascript" { decisionHandler(.allow); return }
                if ["https", "http", "mailto"].contains(url.scheme) {
                    if action.navigationType == .linkActivated || navigationRevision != nil { NSWorkspace.shared.open(url) }
                    if let revision = navigationRevision { navigationRevision = nil; ready = true; completeCommand(revision) }
                    decisionHandler(.cancel); return
                }
                if pageIndex(url) != nil {
                    if let markup, let file = try? markup.fileURL(url), state.shouldOpenMarkupSibling(file) {
                        if let job = printJob { finishPrint(job, error: ReadError("The displayed topic changed before printing completed."), restore: false) }
                        if let revision = navigationRevision { navigationRevision = nil; ready = true; completeCommand(revision) }
                        decisionHandler(.cancel)
                        state.open(file)
                        return
                    }
                    if let job = printJob {
                        finishPrint(job, error: ReadError("The displayed topic changed before printing completed."), restore: false)
                    }
                    if action.navigationType == .linkActivated { state.recordNavigation() }
                    // A new file starts at its own origin; an explicit restore
                    // carries x/y. Hash destinations always take precedence.
                    // WKWebView.url can already be the requested URL here;
                    // compare the document that actually reached ready.
                    if displayedURL?.path != url.path {
                        ready = false
                        if displayedURL != nil, !restoringNavigation {
                            let page = pageIndex(url) ?? 0
                            var target = pagePositions[page] ?? .init(page: page)
                            target.anchor = url.absoluteString
                            initialPosition = target
                        }
                        restoringNavigation = false
                        // Install before allowing a new file, including the first
                        // load after CHM indexing. Same-file reloads retain these scripts.
                        installScripts(view.configuration.userContentController)
                    }
                    decisionHandler(.allow); return
                }
                let followsLink = action.navigationType == .linkActivated || navigationRevision != nil
                if let revision = navigationRevision { navigationRevision = nil; ready = true; completeCommand(revision) }
                decisionHandler(.cancel)
                if followsLink, let markup {
                    do { state.open(try markup.fileURL(url)) }
                    catch { state.error = error.localizedDescription }
                }
                return
            }
            // Frames remain native browser documents. Their navigation must not
            // replace the main topic's position or the CHM container identity.
            let allowed = ["leaf", "about", "data"].contains(url?.scheme ?? "") || chm != nil && url?.scheme == "javascript"
            decisionHandler(allowed ? .allow : .cancel)
        }

    }
}
#endif
