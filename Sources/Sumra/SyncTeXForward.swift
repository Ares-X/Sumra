#if os(macOS)
import AppKit
import Darwin
import SumraCore

// Editor integration uses Launch Services' ordinary URL/document callback.
// File URLs are query-item values, so spaces, Unicode and '&' stay unambiguous.
struct SyncTeXForwardRequest: Equatable, Sendable {
    let pdf: URL
    let source: URL
    let line: Int32
    let column: Int32

    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "sumra", components.host?.lowercased() == "synctex",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty || components.path == "/", components.fragment == nil else {
            throw ReadError("Invalid SyncTeX URL. Use sumra://synctex with pdf, source and line query items.")
        }
        let items = components.queryItems ?? []
        func value(_ name: String) throws -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { throw ReadError("Duplicate SyncTeX URL parameter: \(name)") }
            return matches.first?.value
        }
        func file(_ name: String) throws -> URL {
            guard let text = try value(name), !text.contains("\0"), !text.lowercased().contains("%00"),
                  let file = URL(string: text), file.isFileURL,
                  file.host == nil || file.host == "" || file.host?.lowercased() == "localhost",
                  file.path.hasPrefix("/"), !file.path.contains("\0"), file.query == nil, file.fragment == nil else {
                throw ReadError("SyncTeX \(name) must be an absolute local file URL.")
            }
            return file.standardizedFileURL
        }
        pdf = try file("pdf")
        source = try file("source")
        guard let text = try value("line"), let line = Int32(text), line > 0 else {
            throw ReadError("SyncTeX line must be a positive source line number.")
        }
        let columnText = try value("column") ?? "0"
        guard let column = Int32(columnText), column >= 0 else {
            throw ReadError("SyncTeX column must be zero or a positive source column number.")
        }
        self.line = line; self.column = column
    }

    var identity: String { pdf.resolvingSymlinksInPath().path }
}

enum SyncTeXForward {
    private typealias Query = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, Int32,
        Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<CChar>) -> Int32

    static func position(for request: SyncTeXForwardRequest, pageHint: Int = 0) async throws -> ReadingPosition {
        let worker = Task.detached(priority: .userInitiated) { try query(request, pageHint: pageHint) }
        let position = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return position
    }

    static func query(_ request: SyncTeXForwardRequest, pageHint: Int = 0) throws -> ReadingPosition {
        try Task.checkCancellation()
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(url.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load SyncTeX: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "lf_synctex_forward") else {
            throw ReadError("The bundled engine does not provide SyncTeX forward search")
        }
        let query = unsafeBitCast(symbol, to: Query.self)
        var page: Int32 = 0, point = [Double](repeating: 0, count: 2), error = [CChar](repeating: 0, count: 512)
        let result = query(request.pdf.path, request.source.path, request.line, request.column,
                           Int32(clamping: pageHint), &page, &point, &error)
        try Task.checkCancellation()
        guard result != 0 else { throw ReadError("SyncTeX (\(request.pdf.lastPathComponent)): \(String(cString: error))") }
        // The opened MuPDF document owns page boxes, authentication and
        // rotation. Carry SyncTeX's top-left points until that owner is ready.
        return ReadingPosition(page: Int(page - 1), x: point[0], y: point[1], pdfCoordinateSpace: "synctex")
    }

    @MainActor
    static func reader(for request: SyncTeXForwardRequest, among states: [ReaderState], preferred: NSWindow?) -> ReaderState? {
        let matching = states.filter { state in
            let url = state.document?.url ?? state.restoredPayload?.path.map { URL(fileURLWithPath: $0) }
            return url?.standardizedFileURL.resolvingSymlinksInPath().path == request.identity
        }
        return matching.first(where: { $0.window === preferred }) ?? matching.first
    }
}
#endif
