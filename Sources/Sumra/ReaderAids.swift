#if os(macOS)
import SwiftUI
import SumraCore

extension ReaderState {
    func configureDocumentColors() {
        let alert = NSAlert(); alert.messageText = L("Custom Document Colors…")
        let text = NSColorWell(), background = NSColorWell()
        text.color = ReaderTheme.color(palette.text); background.color = ReaderTheme.color(palette.background)
        let grid = NSGridView(views: [[NSTextField(labelWithString: L("Text")), text], [NSTextField(labelWithString: L("Background")), background]])
        grid.column(at: 1).width = 160; grid.rowSpacing = 8
        alert.accessoryView = grid
        alert.addButton(withTitle: L("Apply")); alert.addButton(withTitle: L("Use Theme")); alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            customTextColor = ReaderTheme.rgb(text.color); customBackgroundColor = ReaderTheme.rgb(background.color)
            documentColors = "smart"
        } else if response == .alertSecondButtonReturn { customTextColor = nil; customBackgroundColor = nil }
        else { return }
        if isText || isBrowser || reflowable { send(.style) }
    }

    func configurePageGrid() {
        let alert = NSAlert(); alert.messageText = L("Configure Page Grid…")
        alert.informativeText = L("Dimensions accept pt, in or mm (72 pt = 1 in).")
        let values = [pageGridWidth, pageGridHeight, pageGridOffsetX, pageGridOffsetY, Double(pageGridSubdivisions)]
        let fields = values.map { NSTextField(string: String(format: "%g", $0)) }
        let names = ["Width", "Height", "Horizontal offset", "Vertical offset", "Subdivisions"]
        var rows: [[NSView]] = zip(names, fields).map { [NSTextField(labelWithString: L($0.0)), $0.1] }
        let style = NSPopUpButton(); style.addItems(withTitles: ["Dots", "Dotted lines", "Solid lines"].map(L))
        let styles = ["dots", "dotted", "solid"]
        style.selectItem(at: styles.firstIndex(of: pageGridStyle) ?? 0)
        let color = NSColorWell(); color.color = ReaderTheme.color(pageGridColor)
        rows += [[NSTextField(labelWithString: L("Style")), style], [NSTextField(labelWithString: L("Color")), color]]
        let grid = NSGridView(views: rows); grid.rowSpacing = 8; grid.columnSpacing = 12
        grid.column(at: 1).width = 180
        alert.accessoryView = grid; alert.addButton(withTitle: L("Apply")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func points(_ field: NSTextField) -> Double? {
            var input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var factor = 1.0
            for (unit, scale) in [("pt", 1.0), ("in", 72.0), ("mm", 72.0 / 25.4)] where input.hasSuffix(unit) {
                input.removeLast(unit.count); factor = scale; break
            }
            return Double(input.trimmingCharacters(in: .whitespaces)).map { $0 * factor }
        }
        guard let width = points(fields[0]), let height = points(fields[1]),
              let x = points(fields[2]), let y = points(fields[3]),
              let subdivisions = Int(fields[4].stringValue),
              (1...720).contains(width), (1...720).contains(height),
              (-720...720).contains(x), (-720...720).contains(y), (1...32).contains(subdivisions),
              let rgb = color.color.usingColorSpace(.sRGB) else {
            error = L("Grid dimensions must be 1–720 pt, offsets −720–720 pt and subdivisions 1–32."); return
        }
        pageGridWidth = width; pageGridHeight = height; pageGridOffsetX = x; pageGridOffsetY = y
        pageGridSubdivisions = subdivisions; pageGridStyle = styles[style.indexOfSelectedItem]
        pageGridColor = ReaderTheme.rgb(rgb) ?? 0x8080ff
        let defaults = UserDefaults.standard
        for (key, value) in ["pageGridWidth": width, "pageGridHeight": height, "pageGridOffsetX": x, "pageGridOffsetY": y] { defaults.set(value, forKey: key) }
        defaults.set(subdivisions, forKey: "pageGridSubdivisions"); defaults.set(Int(pageGridColor), forKey: "pageGridColor")
        defaults.set(pageGridStyle, forKey: "pageGridStyle"); showPageGrid = true
    }

    func applyPreferredLayout(_ layout: ReadingPosition) async throws {
        let documentID = document?.id
        try await nativePDFFormEditor?.commit()
        guard documentID == document?.id, automaticLayout else { return }
        if let value = layout.flow { flow = value }
        if let value = layout.spread { spread = value }
        if let value = layout.cover { cover = value }
        if let value = layout.rtl { rtl = value }
    }

    func toggleAutomaticLayout() {
        automaticLayout.toggle()
    }

    func generateContents() {
        guard let reading = document, isPDF else { return }
        generatedContentsTask?.cancel()
        outlineBusy = true; showContents = true
        generatedContentsTask = Task {
            defer {
                if !Task.isCancelled, document?.id == reading.id { outlineBusy = false; generatedContentsTask = nil }
            }
            do {
                let contents: [ContentsItem]
                if case .pages(let pages) = reading.content { contents = try await ReaderOutline.generate(pages) }
                else { return }
                guard !Task.isCancelled, document?.id == reading.id else { return }
                outline = contents
                if contents.isEmpty { status = "No numbered chapter headings found" }
            } catch is CancellationError {} catch {
                if document?.id == reading.id { self.error = error.localizedDescription }
            }
        }
    }

    func saveFormatDefaults(clear: Bool = false) {
        guard let document else { return }
        do {
            let input = UserDefaults.standard.string(forKey: "formatDefaults") ?? "{}"
            var formats = try JSONDecoder().decode([String: ReadingPosition].self, from: Data(input.utf8))
            if clear { formats.removeValue(forKey: document.settingsFormat) }
            else {
                var defaults = currentPosition
                defaults.page = 0; defaults.pageCount = nil; defaults.x = nil; defaults.y = nil; defaults.anchor = nil; defaults.rotation = nil
                defaults.markdownPassage = nil
                formats[document.settingsFormat] = defaults
            }
            let data = try JSONEncoder().encode(formats)
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "formatDefaults")
            status = clear ? "Format defaults cleared" : "Saved defaults for " + document.settingsFormat.uppercased()
        } catch { self.error = error.localizedDescription }
    }

    func clearChapterContentsPages() {
        var located = outline, changed = false
        for index in located.indices where located[index].chapter != nil && located[index].page != nil {
            located[index].page = nil; changed = true
        }
        if changed { outline = located }
    }

    func cacheContentsPosition(_ position: ReadingPosition, target: String) {
        guard let saved = position.anchor.flatMap(ChapterTable.bookmarkLocation) else { return }
        var located = outline, changed = false
        for index in located.indices where located[index].target == target {
            located[index].chapter = saved.location.chapter
            located[index].page = pageNumber(saved.location)
            changed = true
        }
        if changed { outline = located }
    }

    var currentContentsIndex: Int? {
        // Sumatra TableOfContents.cpp visitTree: outlines need not be in page
        // order. Select the nearest preceding destination, stopping at an exact match.
        if let table = chapterLayout, table.chapterCount > 1, let location = table.location(page: page) {
            var best: Int?, bestPage = -1
            for index in outline.indices where outline[index].chapter == location.chapter {
                if best == nil { best = index }
                if let target = outline[index].page, target <= page, target >= bestPage {
                    best = index; bestPage = target
                    if target == page { break }
                }
            }
            return best
        }
        var best = outline.indices.first, bestPage = -1
        for index in outline.indices {
            let item = outline[index]
            let targetPage = item.page
            if let targetPage, targetPage >= 0, targetPage <= page, targetPage >= bestPage {
                best = index; bestPage = targetPage
                if targetPage == page { break }
            }
        }
        return best
    }

    func contentsHasChildren(_ index: Int) -> Bool {
        outline.indices.contains(index + 1) && outline[index + 1].depth > outline[index].depth
    }

    // TableOfContents::TocTreeSelectionChanged: keyboard selection follows
    // local destinations; opening an external target requires a mouse action.
    func activateContents(_ index: Int, allowExternal: Bool) {
        guard outline.indices.contains(index) else { return }
        if selectedContents != index { selectedContents = index }
        let target = outline[index].target
        guard !target.isEmpty else { return }
        if !allowExternal {
            if isPDF, !target.hasPrefix("#") { return }
            if let scheme = URL(string: target)?.scheme, scheme != "leaf" { return }
        }
        navigate(.href(target))
    }

    // Sumatra TableOfContents.cpp: expand to a level, with a useful single root.
    func expandContents(to level: Int) {
        collapsedContents = Set(outline.indices.filter { outline[$0].depth >= level - 1 && contentsHasChildren($0) })
        if level == 1, outline.filter({ $0.depth == 0 }).count == 1 { collapsedContents.remove(0) }
        showContents = true
    }

    func revealCurrentContents() {
        guard let index = currentContentsIndex else { return }
        var collapsed = collapsedContents
        var depth = outline[index].depth
        var ancestor = index - 1
        while depth > 0, ancestor >= 0 {
            if outline[ancestor].depth < depth {
                collapsed.remove(ancestor); depth = outline[ancestor].depth
            }
            ancestor -= 1
        }
        if collapsedContents != collapsed { collapsedContents = collapsed }
        if selectedContents != index { selectedContents = index }
    }

    func collapseContentsSiblings() {
        let index = selectedContents ?? 0
        guard outline.indices.contains(index) else { return }
        let depth = outline[index].depth
        let first = (outline.indices.prefix(index).last { outline[$0].depth < depth }).map { $0 + 1 } ?? 0
        let end = outline.indices.dropFirst(index + 1).first { outline[$0].depth < depth } ?? outline.count
        for sibling in first..<end where outline[sibling].depth == depth && contentsHasChildren(sibling) { collapsedContents.insert(sibling) }
    }

    private func bookmarkLocation(_ position: ReadingPosition, path: String) -> (PageLocation, Double, Double) {
        let format = Format.detect(path)
        if (format == .markdown || format == .html), position.page == 0,
           position.anchor == nil, position.pageCount == nil {
            return (.init(page: 0), position.y ?? 0, position.x ?? 0)
        }
        guard let saved = position.anchor.flatMap(ChapterTable.bookmarkLocation) else {
            return (.init(page: position.page), 0, 0)
        }
        if path == document?.url.path, let table = chapterLayout, table.isLaidOut(saved.location.chapter) {
            return (table.restored(saved.location, savedCount: saved.count), 0, 0)
        }
        return (saved.location, 0, 0)
    }

    var sortedBookmarks: [ReaderBookmark] {
        // Use one ordering for each file. Legacy pixel-only bookmarks retain
        // their ordering until they are renewed with a semantic reading point.
        let groups = Dictionary(grouping: bookmarks, by: \.path)
        let semanticPaths = Set(groups.keys.filter { Format.detect($0) == .markdown && groups[$0]!.allSatisfy { $0.position.markdownPassage != nil } })
        return bookmarks.sorted {
            if bookmarksByName { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if $0.path != $1.path { return $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return bookmarkPrecedes($0.position, $1.position, path: $0.path, semantic: semanticPaths.contains($0.path))
        }
    }

    private func semanticBookmarks(at path: String) -> Bool {
        Format.detect(path) == .markdown && bookmarks.filter { $0.path == path }.allSatisfy { $0.position.markdownPassage != nil }
    }

    private func bookmarkPrecedes(_ first: ReadingPosition, _ second: ReadingPosition, path: String, semantic: Bool) -> Bool {
        if semantic, let a = first.markdownPassage, let b = second.markdownPassage {
            if a.end != b.end { return !a.end }
            if !a.end {
                if a.path != b.path { return a.path.lexicographicallyPrecedes(b.path) }
                if a.offset != b.offset { return a.offset < b.offset }
            }
            return bookmarkHorizontal(first) < bookmarkHorizontal(second)
        }
        return bookmarkLocation(first, path: path) < bookmarkLocation(second, path: path)
    }

    private func bookmarkHorizontal(_ position: ReadingPosition) -> Double {
        position.x.flatMap { $0.isFinite ? $0 : nil } ?? 0
    }

    func toggleBookmark() {
        guard let path = document?.url.path, let position = filePosition else { return }
        let current = bookmarkLocation(position, path: path)
        if let existing = bookmarks.first(where: {
            guard $0.path == path else { return false }
            if Format.detect(path) == .markdown, let a = $0.position.markdownPassage, let b = position.markdownPassage {
                return a.end == b.end && (a.end || a.path == b.path && a.offset == b.offset) && bookmarkHorizontal($0.position) == bookmarkHorizontal(position)
            }
            let target = bookmarkLocation($0.position, path: path)
            if chapterLayout != nil { return target == current }
            return $0.position.page == position.page && $0.position.anchor == position.anchor && target == current
        }) { deleteBookmark(existing.id) }
        else { bookmark() }
    }

    func moveBookmark(_ direction: Int) {
        guard let path = document?.url.path, let position = filePosition else { return }
        let semantic = position.markdownPassage != nil && semanticBookmarks(at: path)
        let items = bookmarks.filter { $0.path == path }.sorted {
            bookmarkPrecedes($0.position, $1.position, path: path, semantic: semantic)
        }
        let next = direction > 0 ? items.first { bookmarkPrecedes(position, $0.position, path: path, semantic: semantic) } ?? items.first
            : items.last { bookmarkPrecedes($0.position, position, path: path, semantic: semantic) } ?? items.last
        if let next { openBookmark(next) }
    }

    func copyLocation() {
        guard let document else { return }
        NSPasteboard.general.clearContents()
        let position = location.anchor ?? String(page + 1)
        NSPasteboard.general.setString(document.url.path + "#" + position, forType: .string)
    }

    func cycleZoom() {
        setFit(fit == "actual" ? "page" : fit == "page" ? "width" : "actual")
    }

    func editTypography() {
        let alert = NSAlert(); alert.messageText = L("Typography and CSS")
        let fonts = NSComboBox(); fonts.addItems(withObjectValues: ["system", "serif", "sans-serif", "monospace"] + NSFontManager.shared.availableFontFamilies.sorted())
        fonts.stringValue = font; fonts.frame.size = NSSize(width: 420, height: 26)
        let documentCSS = NSButton(checkboxWithTitle: L("Use document styles"), target: nil, action: nil); documentCSS.state = useDocumentCSS ? .on : .off
        if isCHM {
            fonts.isEnabled = !useDocumentCSS
            documentCSS.bind(.value, to: fonts, withKeyPath: #keyPath(NSControl.isEnabled),
                             options: [.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName])
        }
        defer { documentCSS.unbind(.value) }
        let margins = NSTextField(string: pageMargins.map { "\($0.top) \($0.right) \($0.bottom) \($0.left)" } ?? "")
        margins.placeholderString = L("Margins: top right bottom left (blank uses document default)")
        let defaults = NSButton(checkboxWithTitle: L("Use these typography settings as defaults"), target: nil, action: nil); defaults.state = typographyForAll ? .on : .off
        let scroll = NSTextView.scrollableTextView(); scroll.frame.size = NSSize(width: 420, height: 230)
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.string = userCSS
        let stack = NSStackView(views: [fonts, margins, documentCSS, NSTextField(labelWithString: L("Custom CSS (books and CHM)")), scroll, defaults])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.frame.size = NSSize(width: 420, height: 384)
        margins.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
        alert.accessoryView = stack; alert.addButton(withTitle: L("Apply")); alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = margins.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, PageMargins(cssValues: value) == nil { error = L("Margins must contain 1, 2 or 4 values between 0 and 200."); return }
        pageMargins = value.isEmpty ? nil : PageMargins(cssValues: value)
        font = fonts.stringValue.isEmpty ? "system" : fonts.stringValue
        userCSS = editor.string; useDocumentCSS = documentCSS.state == .on; typographyForAll = defaults.state == .on
        applyTypography()
    }
}

struct ContentsTree: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    var body: some View {
        let _ = language
        VStack(spacing: 0) {
            ContentsSearchInput(state: state).frame(height: 24).padding(8)
            NativeContentsTree(state: state)
        }
            .onChange(of: state.page) { _ in
                followCurrentPage()
            }
            .onAppear { followCurrentPage() }
    }
    private func followCurrentPage() {
        if state.followContents, state.contentsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.revealCurrentContents()
        }
    }
}

struct ContentsSearchInput: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        state.contentsSearchField = field
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        state.contentsSearchField = field
        field.placeholderString = L("Search Contents")
        field.setAccessibilityLabel(L("Search Contents"))
        if field.stringValue != state.contentsQuery { field.stringValue = state.contentsQuery }
        context.coordinator.updateFocus(field)
    }
    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        field.delegate = nil
        field.target = nil; field.action = nil
        field.abortEditing()
        if coordinator.state.contentsSearchField === field { coordinator.state.contentsSearchField = nil }
    }
    final class Field: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (delegate as? Coordinator)?.updateFocus(self)
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        let state: ReaderState
        init(state: ReaderState) { self.state = state }
        func updateFocus(_ field: NSSearchField) {
            guard state.contentsSearchRequested, field.window != nil else { return }
            state.contentsSearchRequested = false
            field.selectText(nil)
        }
        @objc func search(_ field: NSSearchField) {
            if state.contentsQuery != field.stringValue { state.contentsQuery = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)), !state.contentsQuery.isEmpty {
                state.contentsQuery = ""
                return true
            }
            if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertNewline(_:)),
               let tree = state.contentsFocusView as? NativeContentsTree.OutlineView,
               let coordinator = tree.delegate as? NativeContentsTree.Coordinator {
                return coordinator.focusSearchResult(tree)
            }
            return false
        }
    }
}

// AppKit owns hierarchy, keyboard movement, disclosure and row accessibility.
// ReaderState remains the owner of expansion, selection and navigation.
struct NativeContentsTree: NSViewRepresentable {
    @ObservedObject var state: ReaderState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSScrollView {
        let tree = OutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("contents"))
        tree.addTableColumn(column); tree.outlineTableColumn = column
        tree.headerView = nil; tree.style = .sourceList
        tree.allowsMultipleSelection = false; tree.allowsEmptySelection = true
        tree.usesAutomaticRowHeights = true; tree.rowHeight = 24
        tree.indentationPerLevel = 12
        tree.delegate = context.coordinator; tree.dataSource = context.coordinator
        tree.target = context.coordinator; tree.action = #selector(Coordinator.activateClickedRow(_:))
        tree.setAccessibilityLabel(L("Contents"))
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.delegate = context.coordinator; tree.menu = menu
        let scroll = ScrollView(); scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.documentView = tree
        context.coordinator.emptyLabel = scroll.emptyLabel
        state.contentsFocusView = tree
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tree = scroll.documentView as! OutlineView
        context.coordinator.update(tree)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if coordinator.state.contentsFocusView === scroll.documentView { coordinator.state.contentsFocusView = nil }
    }

    final class ScrollView: NSScrollView {
        let emptyLabel = NSTextField(wrappingLabelWithString: "")
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            emptyLabel.setAccessibilityRole(.staticText)
            emptyLabel.alignment = .center; emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            addSubview(emptyLabel)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            // NSScrollView tiles its own subviews. Size the overlay with that
            // layout so it stays readable and centered as the sidebar resizes.
            let area = contentView.frame
            let width = max(0, area.width - 16)
            let height = emptyLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0,
                width: width, height: .greatestFiniteMagnitude)).height ?? 0
            emptyLabel.frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                width: width, height: height)
        }
    }

    final class OutlineView: NSOutlineView {
        var mouseClickCount = 0
        var contextRow = -1
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window?.firstResponder === self {
                // The replacement reader may not have mounted yet. Transfer
                // only focus lost with this tree, not every unfocused window.
                (delegate as? Coordinator)?.state.contentsNeedsFocusTransfer = true
            }
            super.viewWillMove(toWindow: newWindow)
        }
        override func mouseDown(with event: NSEvent) {
            mouseClickCount = event.clickCount
            defer { mouseClickCount = 0 }
            super.mouseDown(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            contextRow = event.type == .keyDown ? selectedRow : row(at: convert(event.locationInWindow, from: nil))
            return menu
        }
    }

    final class Node: NSObject {
        let index: Int
        let title: String, target: String
        let depth: Int
        var children: [Node] = []
        var visibleChildren: [Node] = []
        var matchesQuery = true
        init(index: Int, item: ContentsItem) {
            self.index = index; title = item.title; target = item.target; depth = item.depth
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        let state: ReaderState
        private var nodes: [Node] = [], roots: [Node] = [], visibleRoots: [Node] = []
        private var documentID: UUID?
        private var query: String?
        private var updating = false
        weak var emptyLabel: NSTextField?
        init(state: ReaderState) { self.state = state }

        func update(_ tree: OutlineView) {
            updating = true
            defer { updating = false }
            // Stable item identities let AppKit retain its rows across page and
            // destination-resolution updates. Only a changed outline is rebuilt.
            let outlineChanged = documentID != state.document?.id || nodes.count != state.outline.count ||
                zip(nodes, state.outline).contains(where: { $0.title != $1.title || $0.target != $1.target || $0.depth != $1.depth })
            if outlineChanged {
                documentID = state.document?.id
                nodes = state.outline.enumerated().map { Node(index: $0.offset, item: $0.element) }
                roots = []
                var ancestors: [Node] = []
                for node in nodes {
                    while let last = ancestors.last, last.depth >= node.depth { ancestors.removeLast() }
                    if let parent = ancestors.last { parent.children.append(node) }
                    else { roots.append(node) }
                    ancestors.append(node)
                }
            }
            let search = state.contentsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if outlineChanged || query != search {
                query = search
                // Keep original nodes and destinations. Work from leaves to
                // roots so matches retain their ancestors in a single pass.
                for node in nodes.reversed() {
                    node.matchesQuery = search.isEmpty || node.title.range(of: search,
                        options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
                    node.visibleChildren = node.children.filter { $0.matchesQuery || !$0.visibleChildren.isEmpty }
                }
                visibleRoots = roots.filter { $0.matchesQuery || !$0.visibleChildren.isEmpty }
                tree.reloadData()
            }
            let noMatches = visibleRoots.isEmpty && !search.isEmpty
            emptyLabel?.stringValue = noMatches ? L("No matching chapters") : ""
            emptyLabel?.isHidden = !noMatches
            emptyLabel?.setAccessibilityElement(noMatches)
            emptyLabel?.superview?.needsLayout = true
            for node in nodes where !node.visibleChildren.isEmpty {
                let expanded = !search.isEmpty || !state.collapsedContents.contains(node.index)
                if tree.isItemExpanded(node) != expanded {
                    if expanded { tree.expandItem(node) } else { tree.collapseItem(node) }
                }
            }
            let row = state.selectedContents.flatMap { nodes.indices.contains($0) ? tree.row(forItem: nodes[$0]) : nil } ?? -1
            if tree.selectedRow != row {
                if row >= 0 {
                    tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    tree.scrollRowToVisible(row)
                } else { tree.deselectAll(nil) }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.visibleChildren.count ?? visibleRoots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Node)?.visibleChildren ?? visibleRoots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).visibleChildren.isEmpty }
        func focusSearchResult(_ tree: NSOutlineView) -> Bool {
            guard let row = (0..<tree.numberOfRows).first(where: { (tree.item(atRow: $0) as? Node)?.matchesQuery == true }),
                  let node = tree.item(atRow: row) as? Node,
                  tree.window?.makeFirstResponder(tree) == true else { return false }
            updating = true
            tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tree.scrollRowToVisible(row)
            updating = false
            state.activateContents(node.index, allowExternal: false)
            return true
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("heading")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = id
                let text = NSTextField(wrappingLabelWithString: "")
                text.font = .systemFont(ofSize: NSFont.systemFontSize); text.maximumNumberOfLines = 2
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text); cell.textField = text
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                    text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)])
            }
            let title = (item as! Node).title
            cell.textField?.stringValue = title; cell.toolTip = title
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let tree = notification.object as? OutlineView else { return }
            guard let node = tree.item(atRow: tree.selectedRow) as? Node else {
                state.selectedContents = nil; return
            }
            // The native click action also fires for an already-selected row.
            // Let it own mouse navigation so changed selections execute only once.
            if tree.mouseClickCount > 0 { state.selectedContents = node.index }
            else { state.activateContents(node.index, allowExternal: false) }
        }
        @objc func activateClickedRow(_ tree: OutlineView) {
            guard tree.mouseClickCount < 2, let node = tree.item(atRow: tree.clickedRow) as? Node else { return }
            state.activateContents(node.index, allowExternal: true)
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !updating, query?.isEmpty != false, let node = notification.userInfo?["NSObject"] as? Node else { return }
            state.collapsedContents.remove(node.index)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !updating, query?.isEmpty != false, let node = notification.userInfo?["NSObject"] as? Node else { return }
            state.collapsedContents.insert(node.index)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            for (title, action) in [("Expand All", #selector(expandAll)), ("Collapse All", #selector(collapseAll)),
                                    ("Collapse Siblings", #selector(collapseSiblings)), ("Follow Current Page", #selector(toggleFollow))] {
                let item = NSMenuItem(title: L(title), action: action, keyEquivalent: "")
                item.target = self
                if action != #selector(toggleFollow) { item.isEnabled = query?.isEmpty != false }
                if action == #selector(toggleFollow) { item.state = state.followContents ? .on : .off }
                menu.addItem(item)
            }
        }
        @objc private func expandAll() { state.expandContents(to: .max) }
        @objc private func collapseAll() { state.expandContents(to: 1) }
        @objc private func collapseSiblings() {
            if let tree = state.contentsFocusView as? OutlineView,
               let node = tree.item(atRow: tree.contextRow) as? Node { state.selectedContents = node.index }
            state.collapseContentsSiblings()
        }
        @objc private func toggleFollow() { state.followContents.toggle() }
    }
}

struct BookmarkBrowser: View {
    @AppStorage("bookmarks") private var data = Data()
    @AppStorage("language") private var language = "system"
    @State private var query = ""
    @Environment(\.openWindow) private var openWindow
    private var items: [ReaderBookmark] {
        ((try? JSONDecoder().decode([ReaderBookmark].self, from: data)) ?? [])
            .filter { query.isEmpty || ($0.title + " " + $0.path).localizedCaseInsensitiveContains(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        let _ = language
        VStack {
            TextField(L("Search Bookmarks"), text: $query).textFieldStyle(.roundedBorder)
            List(items) { bookmark in
                Button { openWindow(id: "reader", value: WindowPayload(path: bookmark.path, position: bookmark.position)) } label: {
                    VStack(alignment: .leading) {
                        Text(bookmark.title)
                        Text(URL(fileURLWithPath: bookmark.path).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }.padding().frame(minWidth: 320, minHeight: 240)
        .navigationTitle(L("Bookmarks"))
    }
}

struct SpeechControls: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    var body: some View {
        let _ = language
        HStack {
            Button(L(state.speechPaused ? "Continue Reading" : "Pause Reading")) { if state.speechPaused { state.continueReading() } else { state.pauseReading() } }
                .disabled(!state.speechRequested)
            Button(L("Stop"), action: state.stopReading)
            Picker(L("Voice"), selection: $state.speechVoice) {
                Text(L("System")).tag("")
                ForEach(NSSpeechSynthesizer.availableVoices, id: \.rawValue) { voice in
                    Text(NSSpeechSynthesizer.attributes(forVoice: voice)[.name] as? String ?? voice.rawValue).tag(voice.rawValue)
                }
            }.frame(maxWidth: 220)
            Slider(value: $state.speechRate, in: 90...540).frame(maxWidth: 120).accessibilityLabel(L("Reading speed"))
            Text("\(state.speechRate / 180, specifier: "%.1f")×").monospacedDigit()
            Toggle(L("Follow words"), isOn: $state.speechFollow)
        }.controlSize(.small).padding(6)
    }
}

struct AnnotationList: View {
    @ObservedObject var state: ReaderState
    @AppStorage("language") private var language = "system"
    @State private var query = ""
    @State private var kind = "All"
    private struct Row: Identifiable {
        let page: Int, index: Int, type: String, text: String
        var id: String { "\(page):\(index)" }
    }
    @State private var rows = (revision: "", values: [Row]())
    var body: some View {
        let _ = language
        let revision = "\(state.document?.id.uuidString ?? ""):\(state.editRevision)"
        let all = rows.revision == revision ? rows.values : []
        VStack {
            TextField(L("Search annotations"), text: $query).padding([.top, .horizontal], 8)
            Picker(L("Type"), selection: $kind) { Text(L("All")).tag("All"); ForEach(Array(Set(all.map(\.type))).sorted(), id: \.self) { Text($0).tag($0) } }.padding(.horizontal, 8)
            List(all.filter { (kind == "All" || $0.type == kind) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }) { row in
                Button { state.send(.selectAnnotation(page: row.page, index: row.index)) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: L("Page %d"), row.page + 1) + " · " + row.type).font(.caption).foregroundStyle(.secondary)
                        Text(row.text.isEmpty ? row.type : row.text).lineLimit(4)
                    }
                }.buttonStyle(.plain)
            }.listStyle(.sidebar)
        }
        .task(id: revision) {
            if let pages = state.nativePDF {
                let documentID = state.document?.id, editRevision = state.editRevision
                do {
                    var collected = [Row]()
                    let count = await pages.count
                    for page in 0..<count {
                        try Task.checkCancellation()
                        let annotations = try await pages.pdfAnnotations(page)
                        guard state.document?.id == documentID, state.editRevision == editRevision else { return }
                        collected += annotations.filter { $0.type != "Widget" && $0.type != "Link" }.map {
                            Row(page: page, index: Int($0.id), type: $0.type,
                                text: [$0.author, $0.contents].filter { !$0.isEmpty }.joined(separator: " — "))
                        }
                    }
                    if !Task.isCancelled, state.document?.id == documentID, state.editRevision == editRevision {
                        rows = (revision, collected)
                    }
                } catch { if !Task.isCancelled, state.document?.id == documentID { state.error = error.localizedDescription } }
            }
        }
    }
}

// A tracking-only overlay leaves document hit testing and native gestures with
// their existing reader. Reading guides never become annotations or saved data.
struct ReaderGuides: NSViewRepresentable {
    @ObservedObject var state: ReaderState
    func makeNSView(context: Context) -> GuideView { GuideView() }
    func updateNSView(_ view: GuideView, context: Context) { view.state = state; view.needsDisplay = true }
    final class GuideView: NSView {
        weak var state: ReaderState?
        var pointer = NSPoint.zero
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            guard let state else { return }
            if state.readingBar {
                let y = min(bounds.height, max(0, pointer.y))
                let height = CGFloat(state.readingBarHeight)
                if state.readingBarInvert {
                    NSColor.black.withAlphaComponent(0.45).setFill()
                    NSRect(x: 0, y: 0, width: bounds.width, height: max(0, y - height / 2)).fill()
                    NSRect(x: 0, y: y + height / 2, width: bounds.width, height: max(0, bounds.height - y - height / 2)).fill()
                } else {
                    NSColor.systemYellow.withAlphaComponent(0.25).setFill()
                    NSRect(x: 0, y: y - height / 2, width: bounds.width, height: height).fill()
                }
            }
            if state.laserPointer { NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: pointer.x - 5, y: pointer.y - 5, width: 10, height: 10)).fill() }
            if let unit = state.cursorPositionUnit {
                var point: CGPoint?, physical = true
                if state.nativePDF != nil {
                    point = state.nativePDFCursorPosition?(convert(pointer, to: nil))
                } else { point = pointer; physical = false }
                guard let point else { return }
                // FormatCursorPositionTemp: engine coordinates / fileDPI,
                // then pt/mm/in. MuPDF PDF coordinates have fileDPI 72.
                let format = unit == .inches ? "%@: %.2f × %.2f %@" : "%@: %.1f × %.1f %@"
                let text = physical ? String(format: format, L("Cursor Position"), max(0, point.x) / unit.pointsPerUnit,
                    max(0, point.y) / unit.pointsPerUnit, unit.rawValue) : String(format: "View: %.1f, %.1f", point.x, point.y)
                (text as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.windowBackgroundColor])
            }
        }
    }
}
#endif
