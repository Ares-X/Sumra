#if os(macOS)
import AppKit
import SumraCore

// Adapted from pinned SumatraPDF EngineMupdf.cpp, LinkFollow.cpp and
// MainWindow.cpp (GPL-3.0). MuPDF remains the action/destination parser.
@MainActor
enum NativePDFActions {
    // EngineMupdf::HandleLink follows the primary destination. /Next is kept
    // in the live PDF and its snapshots; it is not a navigation execution loop.
    nonisolated static func canFollow(_ link: PDFLinkSnapshot) -> Bool {
        guard link.flags & (1 | 2 | 32) == 0 else { return false }
        if link.type == "FileAttachment" { return true }
        guard let action = link.actions.first, action.index == 0 else { return false }
        switch action.kind {
        case "GoTo", "Named": return action.destination != nil
        case "URI", "GoToR", "Launch":
            guard let uri = action.uri else { return false }
            return externalURL(uri) != nil || fileTarget(uri, relativeTo: URL(fileURLWithPath: "/document.pdf")) != nil
        case "JavaScript":
            guard let script = action.javascript else { return false }
            return !PDFJavaScriptMenu.items(in: script).isEmpty || PDFJavaScriptMenu.calledFunction(in: script) != nil
        default: return false
        }
    }

    static func follow(_ link: PDFLinkSnapshot, page: Int, pages: Pages, state: ReaderState,
                       in view: NSView, at point: CGPoint, newWindow: Bool = false) async {
        guard let document = state.document, state.nativePDF === pages, !state.disableLinks, canFollow(link) else { return }
        func isCurrent() -> Bool { !Task.isCancelled && state.document?.id == document.id && state.nativePDF === pages && !state.disableLinks }
        do {
            try await state.nativePDFFormEditor?.commit()
            guard isCurrent() else { return }
            // LinkFollow::FollowKeyboardLinkTarget re-resolves a cached target.
            // Field scripts/undo may have changed its action while committing.
            guard let link = try await pages.pdfLinks(page).first(where: { $0.id == link.id }), isCurrent(), canFollow(link) else { return }
            if link.type == "FileAttachment" {
                let attachment = try await pages.pdfAttachment(page: page, id: link.id)
                guard isCurrent() else { return }
                try state.openEmbeddedFile(attachment)
                return
            }
            guard let action = link.actions.first else { return }
            if action.kind == "JavaScript", let script = action.javascript {
                let items = try await pages.pdfJavaScriptMenu(script)
                guard isCurrent(), !items.isEmpty else { return }
                let target = MenuTarget(state: state, documentID: document.id)
                let menu = NSMenu(); menu.autoenablesItems = false
                for title in items {
                    if title == "-" { menu.addItem(.separator()); continue }
                    let item = NSMenuItem(title: title, action: #selector(MenuTarget.open(_:)), keyEquivalent: "")
                    item.target = target; item.representedObject = title; menu.addItem(item)
                }
                withExtendedLifetime(target) { _ = menu.popUp(positioning: nil, at: point, in: view) }
            } else if let destination = action.destination {
                let position = position(for: destination, current: state.currentPosition)
                if newWindow, let create = state.createWindow {
                    create(WindowPayload(path: document.url.path, position: position, temporary: document.sourceTemporary, recordsHistory: state.recordsDocumentHistory))
                } else {
                    state.recordNavigation()
                    state.restore(position)
                }
            } else if let uri = action.uri {
                if let url = externalURL(uri) {
                    guard NSWorkspace.shared.open(url) else { throw ReadError("Cannot open link") }
                } else if let target = fileTarget(uri, relativeTo: document.url) {
                    try await openFile(target, state: state, newWindow: newWindow || action.newWindow == true, isCurrent: isCurrent)
                }
            }
        } catch {
            if isCurrent() { state.error = error.localizedDescription }
        }
    }

    // LinkHandler::LaunchFile, shared by page links and Contents targets:
    // supported documents stay in the reader; unknown files are revealed.
    static func openFile(_ target: (url: URL, fragment: String?), state: ReaderState,
                         newWindow: Bool = false, isCurrent: () -> Bool) async throws {
        guard let document = state.document, isCurrent() else { return }
        let supported = try await Task.detached {
            let metadata = try target.url.resourceValues(forKeys: [.isDirectoryKey])
            if metadata.isDirectory == true { return false }
            let file = try FileHandle(forReadingFrom: target.url)
            defer { try? file.close() }
            return Format.resolve(target.url.lastPathComponent, prefix: try file.read(upToCount: 2048) ?? Data()) != .unknown
        }.value
        guard isCurrent() else { return }
        if !supported { NSWorkspace.shared.activateFileViewerSelecting([target.url]); return }
        let position = target.fragment.map { ReadingPosition(anchor: $0) }
        let temporary = [document.sourceTemporary, document.temporary].compactMap { $0 }.first {
            target.url.path.hasPrefix($0.url.standardizedFileURL.path + "/")
        }
        if newWindow, let create = state.createWindow {
            create(WindowPayload(path: target.url.path, position: position, temporary: temporary, recordsHistory: state.recordsDocumentHistory))
        } else if let temporary { state.openTemporary(target.url, keeping: temporary, at: position) }
        else if !state.recordsDocumentHistory { state.openWithoutHistory(target.url, at: position) }
        else if let position { state.open(target.url, at: position) }
        else { state.open(target.url) }
    }

    // Direct mapping of EngineMupdf::DestFromFzLinkDest (Fitz link.h enum).
    // The pinned DisplayModel::ScrollTo uses FitR's rectangle for scrolling,
    // without changing zoom. Missing XYZ coordinates retain the same-page
    // offset, but a different target page starts at its top.
    nonisolated static func position(for destination: PDFLinkSnapshot.Destination, current: ReadingPosition) -> ReadingPosition {
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        var result = ReadingPosition(page: destination.page, x: finite(destination.x), y: finite(destination.y))
        result.pdfCoordinateSpace = "fitz"
        switch destination.type {
        case 0: result.fit = "page"; result.x = nil; result.y = nil // Fit
        case 1: result.fit = "content"; result.x = nil; result.y = nil // FitB
        case 2: result.fit = "width"; result.x = nil // FitH
        case 3: result.fit = "visible"; result.x = nil // FitBH
        case 4: result.fit = "page"; result.y = nil // FitV
        case 5: result.fit = "content"; result.y = nil // FitBV
        case 6: break // FitR
        default:
            if let zoom = finite(destination.zoom), zoom > 0 { result.zoom = zoom / 100; result.fit = "custom" }
            if result.x == nil { result.x = current.x }
            if result.y == nil, result.page == current.page { result.y = current.y }
        }
        return result
    }

    nonisolated static func externalURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https", "mailto", "ftp"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    // MuPDF emits file:relative/path and file:///absolute/path; its URI/Base
    // fallback also emits file://relative/path. Preserve the encoded fragment
    // for MuPDF to resolve after opening the destination document.
    nonisolated static func fileTarget(_ uri: String, relativeTo source: URL) -> (url: URL, fragment: String?)? {
        let parts = uri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        var path = String(first)
        if path.lowercased().hasPrefix("file:") {
            path.removeFirst(5)
            if path.lowercased().hasPrefix("//localhost/") { path.removeFirst(11) }
            else if path.hasPrefix("//") { path.removeFirst(2) }
        } else if URLComponents(string: path)?.scheme != nil { return nil }
        guard !path.isEmpty else { return nil }
        path = (path.removingPercentEncoding ?? path).replacingOccurrences(of: "\\", with: "/")
        let url = (path as NSString).isAbsolutePath ? URL(fileURLWithPath: path) : source.deletingLastPathComponent().appendingPathComponent(path)
        let fragment = parts.count == 2 && !parts[1].isEmpty ? "#" + parts[1] : nil
        return (url.standardizedFileURL, fragment)
    }

    // LinkHandler::GotoLink(kindDestinationJsMenu): metadata remains text.
    // Only an explicit external URL, optionally following "Label: ", opens.
    nonisolated static func menuURL(_ title: String) -> URL? {
        let value = title.range(of: ": ").map { String(title[$0.upperBound...]) } ?? title
        return externalURL(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor private final class MenuTarget: NSObject {
        weak var state: ReaderState?
        let documentID: UUID
        init(state: ReaderState, documentID: UUID) { self.state = state; self.documentID = documentID }
        @objc func open(_ sender: NSMenuItem) {
            guard let state, state.document?.id == documentID, !state.disableLinks,
                  let title = sender.representedObject as? String, let url = NativePDFActions.menuURL(title) else { return }
            if !NSWorkspace.shared.open(url) { state.error = "Cannot open link" }
        }
    }
}
#endif
