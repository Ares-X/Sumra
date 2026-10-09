#if os(macOS)
import Foundation
import Darwin
import SumraCore

protocol BrowserSource: Actor {
    nonisolated var url: URL { get }
    nonisolated var startURL: URL { get }
    func response(_ url: URL) async throws -> (Data, String?)
    func properties() -> [String: String]
}

// MarkdownModel::GetDataForUrl / CollectMarkdownFiles, Sumatra 012d997f.
// Each source file is one browser page. WebKit owns layout and scrolling;
// the existing cmark-gfm library owns Markdown parsing.
actor MarkupSource: BrowserSource {
    nonisolated let url: URL
    nonisolated let root: URL
    nonisolated let pages: [URL]
    nonisolated let startURL: URL
    nonisolated let markdown: Bool
    private var headings: [URL: Data]? = [:]
    private var outlineTask: Task<Data, Error>?

    deinit { outlineTask?.cancel() }

    func cancelOutline() { outlineTask?.cancel() }

    init(_ url: URL) throws {
        self.url = url
        let opened = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = opened.deletingLastPathComponent()
        self.root = root
        markdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        let extensions = markdown ? ["md", "markdown"] : ["html", "htm", "xhtml"]
        var files = [URL]()
        var collected = Set<URL>()
        func collect(_ directory: URL, depth: Int) throws {
            for item in try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true, depth < 2 {
                    // An unreadable sibling folder must not prevent opening this file.
                    try? collect(item, depth: depth + 1)
                } else if values.isRegularFile == true, extensions.contains(item.pathExtension.lowercased()) {
                    // Directory enumeration can return /private/var while the
                    // opened URL uses /var. Form relative paths from one spelling.
                    let file = item.standardizedFileURL.resolvingSymlinksInPath()
                    if file.path.hasPrefix(root.path + "/"), collected.insert(file).inserted { files.append(file) }
                }
            }
        }
        try collect(root, depth: 0)
        if collected.insert(opened).inserted { files.append(opened) }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        func virtualURL(_ file: URL) -> URL {
            URL(string: "leaf://book/entry/")!.appendingPathComponent(String(file.path.dropFirst(root.path.count + 1)))
        }
        pages = files.map(virtualURL)
        startURL = virtualURL(opened)
    }

    nonisolated func fileURL(_ resource: URL) throws -> URL {
        guard resource.scheme == "leaf", resource.host == "book", resource.path.hasPrefix("/entry/") else {
            throw ReadError("Invalid document resource URL")
        }
        var file = root.appendingPathComponent(String(resource.path.dropFirst(7)))
            .standardizedFileURL.resolvingSymlinksInPath()
        // MarkdownModel's virtual .html URLs and extensionless links refer to
        // the corresponding Markdown source, preserving encoded #/? filenames.
        if markdown, file.pathExtension.isEmpty || file.pathExtension.lowercased() == "html" {
            let stem = file.pathExtension.isEmpty ? file : file.deletingPathExtension()
            for ext in ["md", "markdown"] {
                let candidate = stem.appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    file = candidate.resolvingSymlinksInPath(); break
                }
            }
        }
        guard file.path.hasPrefix(root.path + "/") else { throw ReadError("Resource is outside the document folder") }
        return file
    }

    nonisolated func pageIndex(_ resource: URL) -> Int? {
        // Keep the collected page identity if its file moves or becomes a
        // symlink. Actual reads still resolve and check containment in fileURL.
        if resource.scheme == "leaf", resource.host == "book",
           let index = pages.firstIndex(where: { $0.path == resource.path }) { return index }
        guard let file = try? fileURL(resource) else { return nil }
        // Collected page URLs already use canonical, root-relative paths.
        let path = "/entry/" + file.path.dropFirst(root.path.count + 1)
        return pages.firstIndex { $0.path == path }
    }

    private func renderedHeadings(_ file: URL) -> Data? { headings?[file] }

    private nonisolated static func convert(_ file: URL, outline: Bool = false, markdown: Bool = true) throws -> (data: Data, headings: Data?) {
        let path = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(path.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load MuPDF: " + (dlerror().map { String(cString: $0) } ?? "unknown loader error"))
        }
        defer { dlclose(library) }
        typealias Convert = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        typealias Render = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                          UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let name = outline ? (markdown ? "lf_markdown_outline" : "lf_html_outline") : "lf_markdown_render"
        guard let symbol = dlsym(library, name) else { throw ReadError("Incompatible MuPDF engine: " + name) }
        var error = [CChar](repeating: 0, count: 512)
        var headingBuffer: UnsafeMutablePointer<CChar>?
        let result = outline ? unsafeBitCast(symbol, to: Convert.self)(file.path, &error)
            : unsafeBitCast(symbol, to: Render.self)(file.path, &headingBuffer, &error)
        guard let result else { throw ReadError(String(cString: error)) }
        let data = Data(bytesNoCopy: result, count: strlen(result), deallocator: .free)
        let headings = headingBuffer.map { Data(bytesNoCopy: $0, count: strlen($0), deallocator: .free) }
        return (data, headings)
    }

    func response(_ resource: URL) async throws -> (Data, String?) {
        try Task.checkCancellation()
        if resource.path == "/outline" {
            if outlineTask == nil {
                let sources = try pages.map { (try fileURL($0), $0) }
                let markdown = markdown
                // MarkdownModel builds the full heading tree away from the
                // browser. A rendered file already supplied its heading data;
                // only unopened siblings need the background parser.
                outlineTask = Task.detached(priority: .utility) { [weak self] in
                    var items = [ContentsItem]()
                    for (page, pair) in sources.enumerated() {
                        try Task.checkCancellation()
                        let (file, url) = pair
                        items.append(.init(title: file.lastPathComponent, target: url.absoluteString, page: page))
                        let known = await self?.renderedHeadings(file)
                        let data = try known ?? Self.convert(file, outline: true, markdown: markdown).data
                        let headings = try JSONDecoder().decode([ContentsItem].self, from: data)
                        for heading in headings {
                            var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                            target.fragment = heading.target.isEmpty ? nil : String(heading.target.dropFirst())
                            items.append(.init(title: heading.title, target: target.url!.absoluteString, depth: heading.depth, page: page))
                        }
                    }
                    return try JSONEncoder().encode(items)
                }
            }
            let task = outlineTask!
            do {
                let data = try await task.value
                // The completed task now owns the combined outline. Per-file
                // headings are useful only until that result succeeds.
                if outlineTask == task { headings = nil }
                return (data, "utf-8")
            } catch {
                // Keep successful work shared, but let a later request recover
                // after a sibling becomes readable. An older failed waiter
                // must not clear a newer attempt started during this await.
                if outlineTask == task { outlineTask = nil }
                throw error
            }
        }
        let file = try fileURL(resource)
        if markdown, ["md", "markdown"].contains(file.pathExtension.lowercased()) {
            let rendered = try Self.convert(file)
            headings?[file] = rendered.headings
            // WebKit owns loaded pages and its back/forward cache. Keep only
            // the small outline here; the scheme request releases the full
            // HTML after delivery instead of retaining every visited/searched
            // book again in the source actor.
            return (rendered.data, "utf-8")
        }
        return (try Data(contentsOf: file, options: .mappedIfSafe), nil)
    }

    func properties() -> [String: String] { ["Format": markdown ? "Markdown" : "HTML", "Files": String(pages.count)] }
}
#endif
