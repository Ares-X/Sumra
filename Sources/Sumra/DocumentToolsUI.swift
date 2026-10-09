#if os(macOS)
import AppKit
import SumraCore
import Security
import SecurityInterface
import SwiftUI

enum PDFDocumentTool: String {
    case text, outline, xmp, attachments, extract, delete, merge, encrypt, decrypt, flatten
    case compress, decompress, bake, redact, sign, render
}

@MainActor
struct PDFEditingBar: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"

    var body: some View {
        let _ = language
        HStack(spacing: 8) {
            tool(.highlightBrush, symbol: "highlighter")
            tool(.note, symbol: "note.text")
            tool(.freeText, symbol: "textformat")
            tool(.ink, symbol: "pencil.tip.crop.circle")
            Menu {
                commands([.line, .square, .circle, .polygon, .polyline, .link])
                Divider()
                commands([.highlight, .underline, .squiggly, .strike, .inkEraser])
                Divider()
                commands([.stamp, .caret, .insertImage, .attachment, .redactMark])
                Divider()
                commands([.editAnnotations, .editAnnotation, .annotations])
            } label: { Label(L("Annotations"), systemImage: "square.on.circle") }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton).fixedSize()
            .help(L("Annotations"))
            Divider().frame(height: 18)
            Button {
                changeHistory(redo: false)
            } label: { Label(L("Undo"), systemImage: "arrow.uturn.backward") }
            .labelStyle(.iconOnly).help(L("Undo"))
            .disabled((state.nativePDFInfo?.undoPosition ?? 0) <= 0)
            Button {
                changeHistory(redo: true)
            } label: { Label(L("Redo"), systemImage: "arrow.uturn.forward") }
            .labelStyle(.iconOnly).help(L("Redo"))
            .disabled((state.nativePDFInfo?.undoPosition ?? 0) >= (state.nativePDFInfo?.undoSteps ?? 0))
            Spacer(minLength: 8)
            Button { ReaderMenuCommand.save.run(state) } label: {
                Label(L("Save"), systemImage: "square.and.arrow.down")
            }
            .disabled(!ReaderMenuCommand.save.enabled(state))
        }
        .controlSize(.small)
        .disabled(!state.canEditPDF)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Annotations"))
    }

    private func tool(_ command: ReaderMenuCommand, symbol: String) -> some View {
        Button { command.run(state) } label: { Label(command.title, systemImage: symbol) }
            .labelStyle(.iconOnly).help(command.title)
            .tint(command.checked(state) == true ? Color.accentColor : nil)
            .disabled(!command.enabled(state))
    }

    private func changeHistory(redo: Bool) {
        let documentID = state.document?.id
        Task {
            do { try await state.changeNativePDFHistory(redo: redo) }
            catch { if state.document?.id == documentID { state.error = error.localizedDescription } }
        }
    }

    private func commands(_ commands: [ReaderMenuCommand]) -> some View {
        ForEach(commands) { command in
            Button { command.run(state) } label: {
                if command.checked(state) == true { Label(command.title, systemImage: "checkmark") }
                else { Text(command.title) }
            }
            .disabled(!command.enabled(state))
        }
    }
}

@MainActor
private func toolInput(_ title: String, message: String = "", secure: Bool = false, initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = L(title)
    alert.informativeText = message
    let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
    field.stringValue = initial
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: L("Continue"))
    alert.addButton(withTitle: L("Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
}

private struct SignatureOptions {
    var identity: NativePDFTools.SigningIdentity
    var field: String, page: Int, bounds: CGRect, reason: String, location: String
    var boundsInPDFSpace: Bool
    var image: URL?
    var appearance: PDFSignatureAppearance

    @MainActor static func choose(fields: [PDFSignatureInfo.Field], page: Int, count: Int, selection: (page: Int, bounds: CGRect)?, selectedField: String?, selectionInPDFSpace: Bool = true, isCurrent: () -> Bool = { true }) throws -> Self? {
        guard count > 0 else { throw ReadError("Open and unlock the PDF before signing") }
        let source = NSAlert(); source.messageText = L("Signing Identity")
        source.addButton(withTitle: L("Choose from Keychain…")); source.addButton(withTitle: L("Choose PKCS#12 File…")); source.addButton(withTitle: L("Cancel"))
        var identity: NativePDFTools.SigningIdentity
        let response = source.runModal()
        guard isCurrent() else { return nil }
        switch response {
        case .alertFirstButtonReturn:
            let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecAttrCanSign: true, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else {
                if status == errSecItemNotFound { throw ReadError("No signing identities were found in your keychains. Choose a PKCS#12 file instead.") }
                throw ReadError(SecCopyErrorMessageString(status, nil) as String? ?? "Cannot read signing identities (\(status))")
            }
            guard let identities = result as? [SecIdentity], !identities.isEmpty else { throw ReadError("No signing identities were found") }
            guard let picker = SFChooseIdentityPanel.shared(),
                  picker.runModal(forIdentities: identities, message: L("Choose the identity to sign this PDF")) == NSApplication.ModalResponse.OK.rawValue,
                  isCurrent(), let selected = picker.identity()?.takeUnretainedValue() else { return nil }
            identity = .keychain(selected)
        case .alertSecondButtonReturn:
            let panel = NSOpenPanel(); panel.allowedFileTypes = ["p12", "pfx"]
            guard panel.runModal() == .OK, isCurrent(), let url = panel.url else { return nil }
            identity = .pkcs12(url, password: "")
        default: return nil
        }
        let unsigned = fields.filter { !$0.isSigned && !$0.readOnly }
        let preferred = unsigned.first { $0.name == selectedField }
        let page = selection?.page ?? preferred?.page ?? page
        let alert = NSAlert(); alert.messageText = L("Digital Signature")
        let password = NSSecureTextField(), field = NSComboBox(), pageField = NSTextField(string: String(page + 1))
        let bounds = NSTextField(), reason = NSTextField(), location = NSTextField()
        field.addItems(withObjectValues: unsigned.map(\.name))
        field.stringValue = preferred.flatMap { $0.page == page ? $0.name : nil } ?? unsigned.first(where: { $0.page == page })?.name ?? "Signature"
        bounds.placeholderString = L("x,y,width,height; empty reuses field or is invisible")
        var rows: [[NSView]] = [[NSTextField(labelWithString: L("Field (existing or new)")), field], [NSTextField(labelWithString: L("Page")), pageField], [NSTextField(labelWithString: L("Bounds (top-left pt)")), bounds], [NSTextField(labelWithString: L("Reason")), reason], [NSTextField(labelWithString: L("Location")), location]]
        if case .pkcs12 = identity { rows.insert([NSTextField(labelWithString: L("Certificate password")), password], at: 0) }
        let grid = NSGridView(views: rows)
        let selectedBounds = NSButton(checkboxWithTitle: String(format: L("Use selected rectangle on page %d"), page + 1), target: nil, action: nil)
        selectedBounds.state = selection == nil ? .off : .on
        let choices: [(String, PDFSignatureAppearance)] = [("Labels", .labels), ("Name", .textName), ("Date", .date), ("Distinguished name", .distinguishedName), ("Graphic name", .graphicName), ("Logo", .logo)]
        let flags = choices.map { title, flag in
            let button = NSButton(checkboxWithTitle: L(title), target: nil, action: nil)
            button.state = PDFSignatureAppearance.standard.contains(flag) ? .on : .off
            return button
        }
        let image = NSButton(checkboxWithTitle: L("Choose a signature image…"), target: nil, action: nil)
        var views: [NSView] = [grid]
        if selection != nil { views.append(selectedBounds) }
        views += flags; views.append(image)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        alert.accessoryView = stack
        alert.addButton(withTitle: L("Continue")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, isCurrent() else { return nil }
        guard let page = Int(pageField.stringValue), (1...count).contains(page) else { throw ReadError("Choose a page within the document") }
        let useSelection = selectedBounds.state == .on
        var rectangle = CGRect.zero
        if !useSelection, !bounds.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = bounds.stringValue.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4 else { throw ReadError("Signature bounds require four coordinates") }
            let values = fields.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw ReadError("Signature bounds require x,y,width,height with positive dimensions")
            }
            rectangle = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        if useSelection, let selection {
            guard page - 1 == selection.page else { throw ReadError("The selected rectangle belongs to page \(selection.page + 1)") }
            if let existing = unsigned.first(where: { $0.name == field.stringValue }), existing.page != selection.page {
                throw ReadError("Choose a signature field on the selected page, or use a new field name")
            }
            rectangle = selection.bounds
        }
        if case .pkcs12(let url, _) = identity { identity = .pkcs12(url, password: password.stringValue) }
        var appearance: PDFSignatureAppearance = []
        for (button, choice) in zip(flags, choices) where button.state == .on { appearance.insert(choice.1) }
        var imageURL: URL?
        if image.state == .on {
            let panel = NSOpenPanel(); panel.allowedFileTypes = ["png", "jpg", "jpeg", "tiff", "bmp"]
            guard panel.runModal() == .OK, isCurrent() else { return nil }
            imageURL = panel.url
        }
        return .init(identity: identity, field: field.stringValue, page: page - 1, bounds: rectangle, reason: reason.stringValue, location: location.stringValue, boundsInPDFSpace: useSelection && selectionInPDFSpace, image: imageURL, appearance: appearance)
    }
}

extension ReaderState {
    func exportDocumentText() {
        if isPDF { performPDFTool(.text); return }
        guard let reading = document else { return }
        Task {
            do {
                let text = try await documentText(entireDocument: true)
                guard document?.id == reading.id else { return }
                try saveDocumentExport(Data(text.utf8), extension: "txt")
            } catch { if document?.id == reading.id { self.error = error.localizedDescription } }
        }
    }

    func exportDocumentOutline() {
        if isPDF { performPDFTool(.outline); return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try saveDocumentExport(encoder.encode(outline), extension: "json")
        } catch { self.error = error.localizedDescription }
    }

    private func saveDocumentExport(_ data: Data, extension suffix: String) throws {
        guard let reading = document else { return }
        let save = NSSavePanel(); save.allowedFileTypes = [suffix]
        save.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + "." + suffix
        guard save.runModal() == .OK, let url = save.url else { return }
        guard !PDFTools.sameFile(url, reading.url) else { throw ReadError("Choose a different file for document output") }
        try data.write(to: url, options: .atomic)
    }

    func showPDFResourceInformation() {
        guard let reading = document, let pages = nativePDF else { return }
        let password = documentPassword
        let current = { self.document?.id == reading.id && self.nativePDF === pages }
        Task {
            defer { withExtendedLifetime(reading) {} }
            do {
                let source = pages.pdfSourceURL
                guard current() else { return }
                let report = try await Task.detached { try NativePDFTools.resourceReport(source: source, password: password) }.value
                guard current() else { return }
                ReaderHelp.show(title: L("PDF Resource Information…"), text: L("Saved source file; unsaved edits are not included.") + "\n\n" + report)
            } catch { if current() { self.error = error.localizedDescription } }
        }
    }

    func showAttachments(selected: PDFTools.Attachment? = nil) {
        guard let reading = document, let pages = nativePDF else { return }
        let current = { self.document?.id == reading.id && self.nativePDF === pages }
        Task {
            defer { withExtendedLifetime(reading) {} }
            do {
                try await nativePDFFormEditor?.commit()
                guard current() else { return }
                let files: [PDFTools.Attachment]
                if let selected {
                    guard try await pages.pdfInfo()?.permissions.copy == true else { throw ReadError("This PDF does not allow attachment extraction") }
                    guard current() else { return }
                    files = [selected]
                } else { files = try await pages.pdfAttachments() }
                let source = pages.pdfSourceURL
                guard current() else { return }
                guard !files.isEmpty else { status = L("This PDF has no embedded files"); return }
                let alert = NSAlert(); alert.messageText = L("Embedded Files")
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 26))
                picker.addItems(withTitles: files.map { $0.name + " (" + ByteCountFormatter.string(fromByteCount: Int64($0.data.count), countStyle: .file) + ")" })
                alert.accessoryView = selected == nil ? picker : NSTextField(labelWithString: files[0].name)
                alert.addButton(withTitle: L("Open in New Tab"))
                alert.addButton(withTitle: L("Save…"))
                alert.addButton(withTitle: L("Cancel"))
                let answer = alert.runModal()
                guard current(), files.indices.contains(picker.indexOfSelectedItem) else { return }
                let file = files[picker.indexOfSelectedItem]
                if answer == .alertFirstButtonReturn {
                    try openEmbeddedFile(file)
                } else if answer == .alertSecondButtonReturn {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = file.name
                    guard panel.runModal() == .OK, current(), let destination = panel.url else { return }
                    guard ![reading.url, source].contains(where: { PDFTools.sameFile(destination, $0) }) else {
                        throw ReadError("Choose a different location for the attachment")
                    }
                    try await Task.detached { try file.data.write(to: destination, options: .atomic) }.value
                }
            } catch { if current() { self.error = error.localizedDescription } }
        }
    }

    func openEmbeddedFile(_ file: PDFTools.Attachment, at position: ReadingPosition? = nil) throws {
        let temporary = try TemporaryDirectory()
        let url = temporary.url.appendingPathComponent(file.name)
        try file.data.write(to: url)
        if let createWindow {
            createWindow(WindowPayload(path: url.path, position: position, tabWith: window?.windowNumber, temporary: temporary, recordsHistory: false))
        } else { openTemporary(url, keeping: temporary, at: position) }
    }

    func showGeneratedHTML() {
        guard let reading = document else { return }
        let currentPage = page
        Task {
            do {
                let html: String
                switch reading.content {
                case .pages(let pages):
                    guard let source = try await pages.htmlSource() else { throw ReadError("This document has no generated HTML source") }
                    html = source
                case .browser(let source as MarkupSource):
                    let url = source.pages.indices.contains(currentPage) ? source.pages[currentPage] : source.startURL
                    html = String(decoding: try await source.response(url).0, as: UTF8.self)
                default: throw ReadError("This document has no generated HTML source")
                }
                guard document?.id == reading.id, document?.url == reading.url else { return }
                let alert = NSAlert(); alert.messageText = L("Generated HTML")
                let scroll = NSTextView.scrollableTextView(); scroll.frame.size = NSSize(width: 640, height: 440)
                if let text = scroll.documentView as? NSTextView {
                    text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.string = html
                }
                alert.accessoryView = scroll
                alert.addButton(withTitle: L("Close")); alert.addButton(withTitle: L("Save…"))
                if alert.runModal() == .alertSecondButtonReturn {
                    let panel = NSSavePanel(); panel.allowedFileTypes = ["html"]; panel.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + ".html"
                    guard panel.runModal() == .OK, let destination = panel.url else { return }
                    guard !PDFTools.sameFile(destination, reading.url) else { throw ReadError("Choose a different location for generated HTML") }
                    try html.write(to: destination, atomically: true, encoding: .utf8)
                }
            } catch { if document?.id == reading.id, document?.url == reading.url { self.error = error.localizedDescription } }
        }
    }

    func showSignatures() {
        guard let reading = document, let pages = nativePDF else { return }
        let current = { self.document?.id == reading.id && self.document?.url == reading.url }
        status = L("Checking digital signatures…")
        Task {
            defer { withExtendedLifetime(reading) {} }
            do {
                let info = try await pages.pdfSignatureInfo()
                guard current() else { return }
                status = ""
                try presentSignatureInfo(info, unsaved: modified, current: current)
            } catch { if current() { status = ""; self.error = error.localizedDescription } }
        }
    }

    private func presentSignatureInfo(_ info: PDFSignatureInfo, unsaved: Bool, current: @escaping () -> Bool) throws {
        let alert = NSAlert(); alert.messageText = L("Digital Signatures")
        alert.addButton(withTitle: L("OK"))
        var listDetails = [String]()
        do {
            if let list = try ReaderCertificateList.read() {
                listDetails.append(String(format: L("EU Trusted List: %ld certificates from %ld national lists; updated %@."),
                    list.fingerprints.count, list.nationalLists, list.updated.formatted()))
                for field in info.signatures {
                    for signer in field.signers {
                        if let certificate = signer.certificateDER?.first, list.contains(certificate) {
                            listDetails.append(field.name + " — " + (signer.name ?? L("Unknown")) + ": " + L("Listed in the EU Trusted List"))
                        }
                        if (signer.timestampCertificateDER ?? []).contains(where: list.contains) {
                            listDetails.append(field.name + ": " + L("An included timestamp certificate is listed in the EU Trusted List"))
                        }
                    }
                }
                listDetails.append(L("List membership does not change the system certificate trust result."))
            } else { listDetails.append(L("EU Trusted List has not been downloaded.")) }
        } catch {
            ReaderHelp.recordError(error.localizedDescription)
            listDetails.append(L("Cannot read the cached EU Trusted List") + ": " + error.localizedDescription)
        }
        let scroll = NSTextView.scrollableTextView(); scroll.frame.size = CGSize(width: 520, height: 340)
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false; view.font = .systemFont(ofSize: 12)
            view.string = (unsaved ? L("Signature digests verify saved bytes. Current unsaved edits are not covered.") + "\n\n" : "") + info.report + "\n\n" + listDetails.joined(separator: "\n")
        }
        let signers = info.signatures.flatMap { field in field.signers.flatMap { signer -> [(String, [Data])] in
            let title = field.name + " — " + (signer.name ?? L("Unknown"))
            var entries = [(String, [Data])]()
            if let certificates = signer.certificateDER, !certificates.isEmpty { entries.append((title, certificates)) }
            if let certificates = signer.timestampCertificateDER, !certificates.isEmpty {
                entries.append((title + " — " + L("Timestamp Certificate"), certificates))
            }
            return entries
        } }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 26))
        if signers.isEmpty { alert.accessoryView = scroll }
        else {
            alert.addButton(withTitle: L("View Certificate…"))
            picker.addItems(withTitles: signers.map(\.0))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 378))
            scroll.frame.origin.y = 38; content.addSubview(scroll); content.addSubview(picker)
            alert.accessoryView = content
        }
        alert.addButton(withTitle: L("Update EU Trusted List"))
        while current() {
            let response = alert.runModal()
            guard current() else { return }
            if response == (signers.isEmpty ? .alertSecondButtonReturn : .alertThirdButtonReturn) {
                status = L("Updating EU Trusted List…")
                Task {
                    do {
                        let result = try await ReaderCertificateList.update()
                        for failure in result.failures { ReaderHelp.recordError(failure) }
                        guard current() else { return }
                        status = ""; showSignatures()
                    } catch { if current() { status = ""; self.error = error.localizedDescription } }
                }
                return
            }
            guard response == .alertSecondButtonReturn, signers.indices.contains(picker.indexOfSelectedItem) else { return }
            let certificates = try signers[picker.indexOfSelectedItem].1.map { der in
                guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw ReadError("Invalid signing certificate") }
                return certificate
            }
            guard let revocation = SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationUseAnyAvailableMethod | kSecRevocationNetworkAccessDisabled)) else {
                throw ReadError("Cannot create certificate display policy")
            }
            var trust: SecTrust?
            let policies = [SecPolicyCreateBasicX509(), revocation] as CFArray
            guard SecTrustCreateWithCertificates(certificates as CFArray, policies, &trust) == errSecSuccess,
                  let trust, SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  let panel = SFCertificatePanel.shared() else { throw ReadError("Cannot open certificate details") }
            // This is a read-only certificate inspector. PDF digest and
            // signature trust remain the preceding verifier's results.
            panel.certificateView()?.setEditableTrust(false)
            panel.certificateView()?.setDisplayTrust(false)
            panel.certificateView()?.setDisplayDetails(true)
            _ = panel.runModal(for: trust, showGroup: true)
        }
    }

    func performPDFTool(_ tool: PDFDocumentTool) {
        guard let pages = nativePDF else { return }
        switch tool {
        case .extract, .delete, .merge, .compress, .decompress, .encrypt, .decrypt, .flatten, .bake, .redact:
            performNativePDFOutputTool(tool, pages: pages)
        case .text, .outline, .xmp, .attachments, .render:
            performNativePDFExportTool(tool, pages: pages)
        case .sign:
            performNativePDFSign(pages)
        }
    }

    private func performNativePDFExportTool(_ tool: PDFDocumentTool, pages: Pages) {
        guard let reading = document, nativePDF === pages else { return }
        let current = { self.document?.id == reading.id && self.nativePDF === pages }
        Task {
            defer { withExtendedLifetime(reading) {} }
            var completedImages = 0
            do {
                try await nativePDFFormEditor?.commit()
                guard current(), let info = try await pages.pdfInfo(), current() else { return }
                if [.text, .render, .attachments].contains(tool), !info.permissions.copy {
                    throw ReadError("This PDF does not allow copying")
                }
                let sourceURL = pages.pdfSourceURL
                guard current() else { return }
                let sources = [reading.url, sourceURL]
                if tool == .attachments {
                    let attachments = try await pages.pdfAttachments()
                    guard current() else { return }
                    guard !attachments.isEmpty else { status = L("This PDF has no embedded files"); return }
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, current(), let folder = panel.url else { return }
                    var completed = 0
                    for attachment in attachments {
                        let save = NSSavePanel()
                        save.directoryURL = folder; save.nameFieldStringValue = attachment.name
                        let response = save.runModal()
                        guard current() else { return }
                        guard response == .OK, let destination = save.url else { continue }
                        guard !sources.contains(where: { PDFTools.sameFile($0, destination) }) else {
                            throw ReadError("Choose a different file for attachment output")
                        }
                        try await Task.detached(priority: .userInitiated) { try attachment.data.write(to: destination, options: .atomic) }.value
                        guard current() else { return }
                        completed += 1
                    }
                    if completed > 0 { status = L("Attachments exported") }
                    return
                }
                var indices = [Int]()
                if tool == .text || tool == .render {
                    guard let range = toolInput(tool == .text ? "Extract Text" : "Export Pages as Images",
                        message: L("Pages: 1,3-5,N,8-"), initial: "1-N"), current() else { return }
                    indices = try PDFTools.parsePages(range, count: info.pageCount)
                }
                if tool == .render {
                    guard let resolution = toolInput("Image Resolution", message: L("Dots per inch"), initial: "144"), current() else { return }
                    guard let dpi = Double(resolution), dpi.isFinite, dpi > 0 else { throw ReadError("DPI must be positive") }
                    let rotation = self.rotation
                    let save = NSSavePanel()
                    save.allowedFileTypes = ["png", "jpg", "jpeg", "tif", "tiff", "bmp"]
                    save.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + (indices.count > 1 ? "-%d.png" : ".png")
                    guard save.runModal() == .OK, current(), let template = save.url else { return }
                    let destinations = try PDFTools.imageDestinations(pages: indices, template: template, sources: sources)
                    let existing = destinations.filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !existing.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = String(format: L("Replace %d existing images?"), existing.count)
                        alert.informativeText = existing.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
                        alert.addButton(withTitle: L("Replace")); alert.addButton(withTitle: L("Cancel"))
                        guard alert.runModal() == .alertFirstButtonReturn, current() else { return }
                    }
                    for (page, destination) in zip(indices, destinations) {
                        let data = try await pages.pdfRenderedImage(page: page, dpi: dpi,
                            type: PDFTools.imageType(for: destination), rotation: rotation)
                        guard current() else { return }
                        try await Task.detached(priority: .userInitiated) { try data.write(to: destination, options: .atomic) }.value
                        guard current() else { return }
                        completedImages += 1
                    }
                    status = String(format: L("Exported %d page images"), completedImages)
                    return
                }
                let suffix = tool == .text ? "txt" : tool == .outline ? "json" : "xmp"
                let panel = NSSavePanel()
                panel.allowedFileTypes = [suffix]
                panel.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + "-" + tool.rawValue + "." + suffix
                guard panel.runModal() == .OK, current(), let destination = panel.url else { return }
                guard !sources.contains(where: { PDFTools.sameFile($0, destination) }) else { throw ReadError("Choose a different file for tool output") }
                if tool == .text { try await pages.pdfExportText(indices, to: destination) }
                else {
                    let data: Data
                    if tool == .outline {
                        let outline = try await pages.pdfOutline()
                        guard current() else { return }
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        data = try encoder.encode(outline)
                    } else {
                        guard let xmp = try await pages.pdfXMP(), current() else {
                            if current() { throw ReadError("This PDF has no XMP metadata") }
                            return
                        }
                        data = xmp
                    }
                    try await Task.detached(priority: .userInitiated) { try data.write(to: destination, options: .atomic) }.value
                }
                if current() { status = String(format: L("Saved %@"), destination.lastPathComponent) }
            } catch {
                if current() {
                    self.error = tool == .render
                        ? String(format: L("Exported %d page images before failure: %@"), completedImages, error.localizedDescription)
                        : error.localizedDescription
                }
            }
        }
    }

    private func performNativePDFSign(_ pages: Pages) {
        guard let reading = document, nativePDF === pages else { return }
        guard canEditPDF else { error = L("Enable PDF editing first"); return }
        let current = { self.document?.id == reading.id && self.nativePDF === pages }
        let selectedField: String?
        if case .annotation(_, let annotation) = nativePDFSelection, annotation.type == "Widget", annotation.fieldType == 6 {
            selectedField = annotation.fieldName
        } else { selectedField = nil }
        Task {
            defer { withExtendedLifetime(reading) {} }
            do {
                try await nativePDFFormEditor?.commit()
                guard current(), canEditPDF else { return }
                guard let info = try await pages.pdfInfo() else { throw ReadError("Document is not a PDF") }
                guard current(), canEditPDF else { return }
                guard info.permissions.form else { throw ReadError("This PDF does not permit signing form fields") }
                let signatures = try await pages.pdfSignatureInfo()
                let source = pages.pdfSourceURL
                guard current(), canEditPDF else { return }
                let selection = try await nativePDFSignatureSelection?()
                guard current(), canEditPDF else { return }
                guard let options = try SignatureOptions.choose(fields: signatures.signatures, page: page,
                    count: info.pageCount, selection: selection, selectedField: selectedField,
                    selectionInPDFSpace: false, isCurrent: current), current(), canEditPDF else { return }
                let panel = NSSavePanel(); panel.allowedFileTypes = ["pdf"]
                panel.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + "-signed.pdf"
                panel.message = L("Creates a signed copy with the current unsaved edits. Existing signatures retain their original signed byte ranges. The open document is unchanged.")
                guard panel.runModal() == .OK, current(), canEditPDF, let destination = panel.url else { return }
                guard ![reading.url, source].contains(where: { PDFTools.sameFile($0, destination) }) else {
                    throw ReadError("Choose a different file for tool output")
                }
                status = L("Signing PDF…")
                try await pages.pdfSignCopy(to: destination, password: documentPassword, identity: options.identity,
                    fieldName: options.field, page: options.page, bounds: options.bounds,
                    reason: options.reason, location: options.location, image: options.image, appearance: options.appearance)
                if current() { status = String(format: L("Saved %@"), destination.lastPathComponent) }
            } catch { if current() { status = ""; self.error = error.localizedDescription } }
        }
    }

    private func performNativePDFOutputTool(_ tool: PDFDocumentTool, pages: Pages) {
        guard let reading = document, nativePDF === pages else { return }
        let current = { self.document?.id == reading.id && self.nativePDF === pages }
        Task {
            defer { withExtendedLifetime(reading) {} }
            do {
                try await nativePDFFormEditor?.commit()
                guard current() else { return }
                guard let info = try await pages.pdfInfo() else { throw ReadError("Document is not a PDF") }
                guard current() else { return }
                if [.extract, .delete, .merge].contains(tool), !info.permissions.copy {
                    throw ReadError("This PDF does not allow content extraction")
                }
                let sourceURL = pages.pdfSourceURL
                guard current() else { return }
                var password = documentPassword
                var sources = [reading.url, sourceURL]
                let operation: NativePDFOutput.Operation
                if tool == .merge {
                    let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedFileTypes = ["pdf"]
                    guard panel.runModal() == .OK, current(), !panel.urls.isEmpty else { return }
                    var additional = [(url: URL, password: String)]()
                    for url in panel.urls {
                        var supplied: String? = nil
                        let other: PDFDocumentInfo?
                        do {
                            other = try await Task.detached(priority: .userInitiated) {
                                try NativeFile(url, engine: .mupdf).pdfInfo()
                            }.value
                        } catch is PasswordRequired {
                            guard current(), let value = toolInput("PDF Password", message: url.lastPathComponent, secure: true), current() else { return }
                            supplied = value
                            other = try await Task.detached(priority: .userInitiated) {
                                try NativeFile(url, engine: .mupdf, password: value).pdfInfo()
                            }.value
                        }
                        // Reuse the decoder's authentication and permissions,
                        // without a PDFKit copy or a second persistent document.
                        guard current() else { return }
                        guard other?.permissions.copy == true else { throw ReadError("This PDF does not allow content extraction") }
                        additional.append((url, supplied ?? "")); sources.append(url)
                    }
                    operation = .merge(additional)
                } else if tool == .extract || tool == .delete {
                    guard let specification = toolInput(tool == .extract ? "Extract Pages" : "Delete Pages",
                        message: L("Pages: 1,3-5,N,8-"), initial: String(page + 1)), current() else { return }
                    let selected = try PDFTools.parsePages(specification, count: info.pageCount)
                    var annotationsOnly = false
                    if tool == .extract {
                        let alert = NSAlert(); alert.messageText = L("Extract Selected Pages")
                        let checkbox = NSButton(checkboxWithTitle: L("Only pages with annotations"), target: nil, action: nil)
                        alert.accessoryView = checkbox
                        alert.addButton(withTitle: L("Extract")); alert.addButton(withTitle: L("Cancel"))
                        guard alert.runModal() == .alertFirstButtonReturn, current() else { return }
                        annotationsOnly = checkbox.state == .on
                    }
                    operation = tool == .extract ? .extract(selected, annotationsOnly: annotationsOnly) : .delete(selected, count: info.pageCount)
                } else {
                    // All file rewrites use the existing native owner-password
                    // boundary. Save Copy keeps the original encryption, so an
                    // owner supplied here authenticates the same copied graph.
                    if !info.ownerAuthenticated {
                        guard let supplied = toolInput("PDF Owner Password", secure: true), current() else { return }
                        password = supplied
                    }
                    if tool == .encrypt {
                        guard let owner = toolInput("Output Owner Password", secure: true), current(),
                              let user = toolInput("Output Open Password", message: L("Leave empty to allow opening without a password."), secure: true), current() else { return }
                        try NativePDFTools.validatePasswords(owner: owner, user: user)
                        operation = .encrypt(owner: owner, user: user)
                    } else if tool == .decrypt { operation = .decrypt }
                    else if let value = PDFAdvancedOperation(rawValue: tool.rawValue) { operation = .transform(value) }
                    else { return }
                }
                let panel = NSSavePanel(); panel.allowedFileTypes = ["pdf"]
                panel.nameFieldStringValue = reading.url.deletingPathExtension().lastPathComponent + "-" + tool.rawValue + ".pdf"
                switch tool {
                case .merge:
                    panel.message = L("Creates an unencrypted PDF. Page content, external links, and outlines are retained. Annotations, forms, internal links, and document scripts are not merged.")
                case .extract, .delete:
                    panel.message = L("Creates a separate PDF. Page annotations and retained link destinations are preserved. Interactive forms, document scripts, and document structure are removed. Existing encryption is kept.")
                case .flatten:
                    panel.message = L("Creates a copy with annotations baked into page content. Form fields remain editable. Existing encryption is kept.")
                case .bake:
                    panel.message = L("Creates a copy with annotations and form fields baked into page content. They can no longer be edited separately. Existing encryption is kept.")
                case .redact:
                    panel.message = L("Applies the current redaction marks to the output copy, permanently removing the covered content. The open document is unchanged. Existing encryption is kept.")
                case .encrypt:
                    panel.message = L("Creates a copy with the chosen passwords and the original permission settings.")
                case .decrypt:
                    panel.message = L("Creates an unencrypted copy. The original file is unchanged.")
                default:
                    panel.message = L("Creates a separate PDF with the current unsaved edits. Existing encryption and permission settings are kept.")
                }
                let removeSignatures = NSButton(checkboxWithTitle: L("Remove existing digital signatures from the rewritten copy"), target: nil, action: nil)
                panel.accessoryView = removeSignatures
                guard panel.runModal() == .OK, current(), let destination = panel.url else { return }
                guard !sources.contains(where: { PDFTools.sameFile($0, destination) }) else {
                    throw ReadError("Choose a different file for tool output")
                }
                let invalidateSignatures = removeSignatures.state == .on, originalSources = sources, inputPassword = password
                let temporary = try TemporaryDirectory(), snapshot = temporary.url.appendingPathComponent("current.pdf")
                defer { withExtendedLifetime(temporary) {} }
                try await pages.pdfSaveCopy(to: snapshot)
                guard current() else { return }
                try await Task.detached(priority: .userInitiated) {
                    try NativePDFOutput.write(snapshot: snapshot, password: inputPassword, operation: operation, to: destination,
                        originalSources: originalSources, invalidateSignatures: invalidateSignatures)
                }.value
                if current() { status = String(format: L("Saved %@"), destination.lastPathComponent) }
            } catch { if current() { self.error = error.localizedDescription } }
        }
    }
}
#endif
