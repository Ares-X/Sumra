#if os(macOS)
import Foundation
import CoreGraphics
import Darwin
import SumraCore

struct SourceLocation: Equatable, Sendable {
    let sourceURL: URL
    let line: Int
    let column: Int
}

// .pdfsync indexing, the 800-point² / 20-point matching rules, moved
// source recovery and the 65781.76 coordinate divisor are translated from
// SumatraPDF src/PdfSync.cpp at 012d997f (GPLv3). PDF geometry uses bottom-left page
// coordinates; Sumatra's display coordinates and SyncTeX are top-left.
struct PDFSyncIndex {
    struct Line {
        let record: Int
        let source: URL
        let line: Int
        let column: Int
    }
    struct Point {
        let record: Int
        let page: Int // zero-based
        let x: Double
        let y: Double
    }
    let lines: [Line]
    let points: [Point]

    init(text: String, directory: URL, pageCount: Int) throws {
        let rows = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" || $0 == "\0" }).map(String.init)
        guard rows.count >= 2, rows[1].split(whereSeparator: \.isWhitespace).map(String.init) == ["version", "1"] else {
            throw ReadError("Invalid .pdfsync preamble: expected version 1")
        }
        var stack = [Synchronizer.sourceURL(rows[0], directory: directory, texExtension: true)]
        var lines: [Line] = [], points: [Point] = []
        var page = 0
        for row in rows.dropFirst(2) {
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard let kind = fields.first else { continue }
            switch kind {
            case "l":
                guard fields.count >= 3, let record = Int(fields[1]), record >= 0,
                      let line = Int(fields[2]), line >= 0 else { continue }
                let column = fields.count > 3 ? Int(fields[3]) ?? 0 : 0
                lines.append(.init(record: record, source: stack.last!, line: line, column: max(0, column)))
            case "s":
                if fields.count > 1, let number = Int(fields[1]), number > 0 { page = number - 1 }
                else { page = -1 }
            case "p", "p*":
                guard fields.count >= 4, let record = Int(fields[1]), record >= 0,
                      let x = Double(fields[2]), let y = Double(fields[3]), x.isFinite, y.isFinite,
                      x >= 0, y >= 0, page >= 0, page < pageCount else { continue }
                points.append(.init(record: record, page: page, x: x / 65781.76, y: y / 65781.76))
            default:
                if row.hasPrefix("(") {
                    let file = Synchronizer.sourceURL(String(row.dropFirst()), directory: directory, texExtension: true)
                    stack.append(file)
                } else if row.hasPrefix(")"), stack.count > 1 { stack.removeLast() }
            }
        }
        self.lines = lines; self.points = points
    }

    func inverse(page: Int, point: CGPoint, bounds: CGRect) throws -> SourceLocation {
        var record: Int?, closest = Double.infinity
        var vertical: (record: Int, dx: Double, dy: Double)?
        let x = Double(point.x - bounds.minX), y = Double(point.y - bounds.minY)
        for mark in points where mark.page == page {
            // The original truncates each scaled coordinate to an integer.
            let dx = abs(x - mark.x.rounded(.towardZero)), dy = abs(y - mark.y.rounded(.towardZero))
            let distance = dx * dx + dy * dy
            if distance < 800, distance < closest { record = mark.record; closest = distance }
            else if record == nil, dy < 20,
                    vertical == nil || dy < vertical!.dy || dy == vertical!.dy && dx < vertical!.dx {
                vertical = (mark.record, dx, dy)
            }
        }
        guard let record = record ?? vertical?.record,
              let line = lines.first(where: { $0.record == record }) else {
            throw ReadError("No .pdfsync record near this PDF location")
        }
        return .init(sourceURL: line.source, line: line.line, column: line.column)
    }
}

enum Synchronizer {
    static func inverse(pdf: URL, page: Int, point: CGPoint, bounds suppliedBounds: CGRect? = nil,
                        pageCount suppliedCount: Int? = nil) async throws -> SourceLocation {
        guard page >= 0, point.x.isFinite, point.y.isFinite else { throw ReadError("Invalid PDF synchronization location") }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let bounds: CGRect, pageCount: Int
            if let suppliedBounds, let suppliedCount {
                guard page < suppliedCount else { throw ReadError("PDF page does not exist") }
                bounds = suppliedBounds; pageCount = suppliedCount
            } else {
                let document = try openPDF(pdf)
                guard page < document.numberOfPages, let selected = document.page(at: page + 1) else { throw ReadError("PDF page does not exist") }
                bounds = selected.getBoxRect(.mediaBox); pageCount = document.numberOfPages
            }
            let indexURL = pdf.deletingPathExtension().appendingPathExtension("pdfsync")
            let location: SourceLocation
            if prefersPDFSync(pdf: pdf, index: indexURL) {
                let index = try PDFSyncIndex(text: ReadingDocument.decode(Data(contentsOf: indexURL)),
                                             directory: indexURL.deletingLastPathComponent(), pageCount: pageCount)
                location = try index.inverse(page: page, point: point, bounds: bounds)
            } else {
                location = try syncTeXInverse(pdf: pdf, page: page, point: point, bounds: bounds)
            }
            let path = location.sourceURL
            // Sumatra TryRecoverMovedSourceFile: only recover when the old path is missing.
            let adjacent = pdf.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent)
            let recovered = !FileManager.default.fileExists(atPath: path.path)
                && FileManager.default.fileExists(atPath: adjacent.path) ? adjacent : path
            return SourceLocation(sourceURL: recovered, line: location.line, column: location.column)
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return result
    }

    private static func prefersPDFSync(pdf: URL, index: URL) -> Bool {
        guard let date = try? index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        let base = pdf.deletingPathExtension()
        let syncDates = [base.appendingPathExtension("synctex"), base.appendingPathExtension("synctex.gz")]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return syncDates.allSatisfy { $0 <= date }
    }

    private static func openPDF(_ url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, document.numberOfPages > 0 else {
            throw ReadError("Cannot read PDF page geometry for synchronization: \(url.lastPathComponent)")
        }
        return document
    }

    static func sourceURL(_ name: String, directory: URL, texExtension: Bool = false) -> URL {
        var path = name
        if texExtension {
            path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            path = path.replacingOccurrences(of: "\\", with: "/")
        }
        if texExtension { path = path.replacingOccurrences(of: "*", with: " ") }
        if texExtension, (path as NSString).pathExtension.isEmpty { path += ".tex" }
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }

    private typealias SyncTeXInverse = @convention(c) (UnsafePointer<CChar>, Int32, Double, Double, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<CChar>) -> UnsafeMutablePointer<CChar>?

    static func syncTeXInverse(pdf: URL, page: Int, point: CGPoint, bounds: CGRect) throws -> SourceLocation {
        guard page >= 0, page < Int(Int32.max), point.x.isFinite, point.y.isFinite else { throw ReadError("Invalid SyncTeX PDF location") }
        let url = try NativeFile.libraryURL(for: .mupdf)
        guard let library = dlopen(url.path, RTLD_LOCAL | RTLD_NOW) else {
            throw ReadError("Cannot load SyncTeX: \(dlerror().map { String(cString: $0) } ?? "unknown loader error")")
        }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "lf_synctex_inverse") else { throw ReadError("The bundled engine does not provide SyncTeX inverse search") }
        let query = unsafeBitCast(symbol, to: SyncTeXInverse.self)
        var location = [Int32](repeating: 0, count: 2), error = [CChar](repeating: 0, count: 512)
        let path = query(pdf.path, Int32(page + 1), Double(point.x - bounds.minX), Double(bounds.maxY - point.y), &location, &error)
        defer { if let path { free(path) } }
        try Task.checkCancellation()
        guard let path else { throw ReadError("SyncTeX (\(pdf.lastPathComponent)): \(String(cString: error))") }
        return .init(sourceURL: sourceURL(String(cString: path), directory: pdf.deletingLastPathComponent()),
                     line: Int(location[0]), column: Int(location[1]))
    }
}
#endif
