#if os(macOS)
import AppKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class MarkupReaderTests: XCTestCase {
    @MainActor
    func testScrolledFilePositionsSurviveSiblingNavigationAndWindowClose() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer { defaults.set(previous, forKey: "disableReadingState") }
        let body = String(repeating: "A paragraph to scroll.\n\n", count: 200)
        let (state, coordinator, view) = try await reader([
            "A.md": "# First\n\n" + body, "B.md": "# Second\n\n" + body
        ], opened: "A.md")
        let first = try XCTUnwrap(state.document?.url)
        _ = try await evaluate("window.scrollTo(0, 350)", view)
        try await wait { state.currentPosition.y == 350 }
        state.go("2")
        try await completeCurrentCommand(state, coordinator, view)
        let second = try XCTUnwrap(state.document?.url)
        XCTAssertNotEqual(first, second)
        let savedFirst = try JSONDecoder().decode(ReadingPosition.self,
            from: XCTUnwrap(defaults.data(forKey: "position:" + first.path)))
        XCTAssertEqual(savedFirst.y, 350)
        XCTAssertNil(savedFirst.anchor)
        _ = try await evaluate("window.scrollTo(0, 620)", view)
        try await wait { state.currentPosition.y == 620 }
        state.navigate(.href("leaf://book/entry/A.md"))
        try await completeCurrentCommand(state, coordinator, view)
        let savedSecond = try JSONDecoder().decode(ReadingPosition.self,
            from: XCTUnwrap(defaults.data(forKey: "position:" + second.path)))
        XCTAssertEqual(savedSecond.y, 620)
        XCTAssertNil(savedSecond.anchor)
        let returned = try XCTUnwrap(state.document?.url)
        XCTAssertEqual(returned.resolvingSymlinksInPath(), first.resolvingSymlinksInPath())
        _ = try await evaluate("window.scrollTo(0, 950)", view)
        try await wait { state.currentPosition.y == 950 }
        state.windowClosed()
        let savedAtClose = try JSONDecoder().decode(ReadingPosition.self,
            from: XCTUnwrap(defaults.data(forKey: "position:" + returned.path)))
        XCTAssertEqual(savedAtClose.y, 950)
        XCTAssertNil(savedAtClose.anchor)
        let unchangedSecond = try JSONDecoder().decode(ReadingPosition.self,
            from: XCTUnwrap(defaults.data(forKey: "position:" + second.path)))
        XCTAssertEqual(unchangedSecond, savedSecond)
    }

    @MainActor
    func testSavedMarkdownPassageSurvivesDifferentViewportOnReopen() async throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "disableReadingState")
        defaults.set(false, forKey: "disableReadingState")
        defer { defaults.set(previous, forKey: "disableReadingState") }
        let body = (0..<180).map { "Paragraph \($0). " + String(repeating: "Surrounding words wrap across the reading viewport. ", count: 12) }.joined(separator: "\n\n")
        let (state, coordinator, view) = try await reader(["Book.md": body], opened: "Book.md", position: .init(zoom: 1))
        try await completeCurrentCommand(state, coordinator, view)
        let initial = try await evaluate("""
            const p=document.querySelectorAll('p')[90];scrollTo({top:p.getBoundingClientRect().top+scrollY,behavior:'instant'});
            return {y:scrollY,top:p.getBoundingClientRect().top};
            """, view) as? [String: Double]
        let savedY = try XCTUnwrap(initial?["y"]), initialTop = try XCTUnwrap(initial?["top"])
        try await wait { state.currentPosition.y == savedY }
        let source = try XCTUnwrap(state.document?.url)
        state.windowClosed()
        let data = try XCTUnwrap(defaults.data(forKey: "position:" + source.path))
        let saved = try JSONDecoder().decode(ReadingPosition.self, from: data)
        XCTAssertEqual(saved.y, savedY)
        XCTAssertNil(saved.anchor, "The per-file saved position must not retain a model's virtual page URL")
        for width: CGFloat in [430, 900] {
            let (reopened, newCoordinator, newView) = try await reader(["Book.md": body], opened: "Book.md", position: saved, viewportWidth: width)
            try await completeCurrentCommand(reopened, newCoordinator, newView)
            let restored = try await evaluate("return {y:scrollY,top:document.querySelectorAll('p')[90].getBoundingClientRect().top}", newView) as? [String: Double]
            XCTAssertEqual(try XCTUnwrap(restored?["top"]), initialTop, accuracy: 2,
                "A persisted passage must survive reopening at width \(width), rather than replaying an obsolete pixel offset")
            XCTAssertEqual(newView.pageZoom, 1)
        }
    }

    @MainActor
    func testSavedMarkdownPassageFallsBackAndKeepsExplicitTargets() async throws {
        let body = "# Book\n\n" + (0..<100).map { "Paragraph \($0). " + String(repeating: "Words to wrap around. ", count: 12) }.joined(separator: "\n\n") + "\n\n## Destination\n\nFinal needle.\n\n" + String(repeating: "Following paragraph with room to align the destination.\n\n", count: 30)
        let (state, coordinator, view) = try await reader(["Book.md": body], opened: "Book.md", position: .init(zoom: 1))
        try await completeCurrentCommand(state, coordinator, view)
        let y = try await evaluate("const p=document.querySelectorAll('p')[50];scrollTo(0,scrollY+p.getBoundingClientRect().top);return scrollY", view) as? Double
        try await wait { state.currentPosition.y == y && state.currentPosition.markdownPassage != nil }
        let passage = try XCTUnwrap(state.currentPosition.markdownPassage)
        let saved = try XCTUnwrap(state.filePosition)
        XCTAssertEqual(try JSONDecoder().decode(ReadingPosition.self, from: JSONEncoder().encode(saved)).markdownPassage, passage)
        _ = try await evaluate("window.savedMarkup=document.body.innerHTML;const p=document.querySelectorAll('p')[2];const r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r)", view)
        state.restore(.init(x: 0, y: 230))
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertEqual(try XCTUnwrap(state.currentPosition.y), 230, accuracy: 1, "Legacy coordinates remain supported")
        var stale = passage; stale.text = "Text that is absent from this source"
        for invalid in [stale, MarkdownPassage(path: [999999], offset: 0, top: 0, text: "", end: false),
                        MarkdownPassage(path: passage.path, offset: Int.max, top: 0, text: "", end: false)] {
            state.restore(.init(x: 0, y: 350, markdownPassage: invalid))
            try await completeCurrentCommand(state, coordinator, view)
            XCTAssertEqual(try XCTUnwrap(state.currentPosition.y), 350, accuracy: 1, "Stale or invalid DOM locations fall back to stored coordinates")
        }
        state.restore(.init(x: 0, y: 0, anchor: "leaf://book/entry/Book.md#destination", markdownPassage: passage))
        try await completeCurrentCommand(state, coordinator, view)
        let top = try await evaluate("return document.getElementById('destination').getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(top), 0, accuracy: 2, "Authored fragments override a saved passage")
        let selected = try await evaluate("return getSelection().toString()", view) as? String
        XCTAssertNotEqual(selected, "")
        let unchanged = try await evaluate("return document.body.innerHTML===window.savedMarkup", view) as? Bool
        XCTAssertEqual(unchanged, true, "Position persistence must retain the publication DOM and selection")
        let options = try JSONSerialization.data(withJSONObject: ["text": "needle", "index": 0, "matchCase": false, "matchWholeWords": false])
        let query = try XCTUnwrap(String(decoding: options, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        state.restore(.init(x: 0, y: 0, anchor: "leaf://book/entry/Book.md#sumra-search=" + query, markdownPassage: passage))
        try await completeCurrentCommand(state, coordinator, view)
        let match = try await evaluate("const r=window.__sumatraFind.currentRange();return {text:r?.toString(),top:r?.getBoundingClientRect().top,bottom:r?.getBoundingClientRect().bottom,height:innerHeight}", view) as? [String: Any]
        XCTAssertEqual(match?["text"] as? String, "needle", "An explicit search target overrides the saved passage")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(match?["top"] as? Double), 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(match?["bottom"] as? Double), try XCTUnwrap(match?["height"] as? Double))
        let end = MarkdownPassage(path: [], offset: 0, top: 0, text: "", end: true)
        state.restore(.init(x: 0, y: 0, markdownPassage: end))
        try await completeCurrentCommand(state, coordinator, view)
        let remaining = try await evaluate("return document.documentElement.scrollHeight-document.documentElement.clientHeight-scrollY", view) as? Double
        XCTAssertEqual(try XCTUnwrap(remaining), 0, accuracy: 1)
        XCTAssertEqual(state.currentPosition.markdownPassage, end)
        let (htmlState, htmlCoordinator, html) = try await reader(["Book.html": "<p>HTML text</p><div style='height:3000px'></div>"], opened: "Book.html")
        try await completeCurrentCommand(htmlState, htmlCoordinator, html)
        htmlState.restore(.init(x: 0, y: 220, markdownPassage: passage))
        try await completeCurrentCommand(htmlState, htmlCoordinator, html)
        let htmlY = try await evaluate("return scrollY", html) as? Double
        XCTAssertEqual(try XCTUnwrap(htmlY), 220, accuracy: 1, "HTML retains ordinary coordinate restoration")
        XCTAssertNil(htmlState.currentPosition.markdownPassage)
    }

    func testFixedPageLayoutIsExplicitlyOptedIntoLikeSumatra() throws {
        let defaults = UserDefaults.standard, previous = defaults.object(forKey: "useFixedPageUI")
        defer { if let previous { defaults.set(previous, forKey: "useFixedPageUI") } else { defaults.removeObject(forKey: "useFixedPageUI") } }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        for name in ["book.md", "book.html"] {
            let url = directory.url.appendingPathComponent(name)
            try "Some readable text".write(to: url, atomically: true, encoding: .utf8)
            defaults.set(true, forKey: "useFixedPageUI")
            if case .pages = try ReadingDocument.open(url, deferReflowLayout: true).content {} else { XCTFail("Explicit fixed-page mode must use MuPDF") }
            defaults.set(false, forKey: "useFixedPageUI")
            if case .browser = try ReadingDocument.open(url).content {} else { XCTFail("Default markup reading must use the browser") }
        }
    }

    @MainActor
    private func reader(_ files: [String: String], opened: String,
                        position: ReadingPosition? = nil, unreadableSibling: String? = nil,
                        showContents: Bool = false, encodedFiles: [String: Data] = [:],
                        viewportWidth: CGFloat = 700) async throws -> (ReaderState, BrowserReader.Coordinator, WKWebView) {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        for (name, text) in files {
            let url = directory.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = encodedFiles[name] { try data.write(to: url) }
            else { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        let state = ReaderState()
        state.document = try ReadingDocument.open(directory.url.appendingPathComponent(opened))
        state.showContents = showContents
        guard case .browser(let source) = state.document?.content else { XCTFail("Expected browser reading"); throw NSError(domain: "MarkupReaderTests", code: 1) }
        if let position { state.restore(position) }
        let coordinator = BrowserReader.Coordinator(state: state, source: source)
        state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.theme = "light"
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: viewportWidth, height: 500), position: position)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        addTeardownBlock { @MainActor in
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            state.windowClosed()
            window.contentView = nil; window.close()
            for name in files.keys {
                let url = directory.url.appendingPathComponent(name)
                for path in Set([url.path, url.resolvingSymlinksInPath().path]) {
                    UserDefaults.standard.removeObject(forKey: "position:" + path)
                }
            }
            withExtendedLifetime(directory) {}
        }
        if let unreadableSibling {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.url.appendingPathComponent(unreadableSibling).path)
        }
        coordinator.load(view)
        try await wait { coordinator.ready || coordinator.readerError != nil }
        if let error = coordinator.readerError { throw error }
        return (state, coordinator, view)
    }

    @MainActor
    private func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        _ = try XCTUnwrap(predicate() ? true : nil, "Browser operation did not complete", line: line)
    }

    @MainActor
    private func evaluate(_ script: String, _ view: WKWebView) async throws -> Any? {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "SumraMarkup"))
    }

    @MainActor
    private func completeCurrentCommand(_ state: ReaderState, _ coordinator: BrowserReader.Coordinator,
                                        _ view: WKWebView, line: UInt = #line) async throws {
        let command = state.command
        state.send(.none)
        coordinator.deliver(command, to: view)
        try await wait(line: line) { state.command.revision > command.revision || state.error != nil }
        if let error = state.error { throw ReadError(error) }
        coordinator.deliver(state.command, to: view)
        // The sentinel's acknowledgement is dispatched to this same main queue.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testSearchWithoutCustomHighlightAPIsKeepsRangesNavigationAndSelection() async throws {
        let (state, coordinator, view) = try await reader(["Book.html": """
            <!doctype html><p id="selection">Keep selection</p><p> Needle needlework </p>
            <div style="height:3000px"></div><p id="last">Final needle</p>
            """], opened: "Book.html")
        _ = try await evaluate("""
            window.savedHighlight = window.Highlight; window.savedHighlightRegistry = CSS.highlights;
            window.originalBody = document.body.innerHTML;
            const range = document.createRange(); range.selectNodeContents(document.getElementById('selection'));
            getSelection().removeAllRanges(); getSelection().addRange(range);
            """, view)
        for feature in ["constructor", "registry"] {
            _ = try await evaluate("""
                await window.leafCommand({name:'find', text:''}); window.scrollTo(0,0);
                window.Highlight = window.savedHighlight;
                Object.defineProperty(CSS, 'highlights', {configurable:true, value:window.savedHighlightRegistry});
                if ('\(feature)' === 'constructor') window.Highlight = undefined;
                else Object.defineProperty(CSS, 'highlights', {configurable:true, value:undefined});
                await window.leafCommand({name:'find', text:'needle', matchWholeWords:true});
                """, view)
            try await wait { !state.searchResults.isEmpty || state.error != nil }
            XCTAssertNil(state.error)
            XCTAssertEqual(state.searchResults.count, 2, feature)
            try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
            let first = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
            XCTAssertEqual(first, "Needle", feature)
            _ = try await evaluate("window.__sumatraFind.gotoMatch(1)", view)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(state.selectedSearchTarget, state.searchResults.last?.target)
            let last = try await evaluate("""
                const range = window.__sumatraFind.currentRange(), rect = range?.getBoundingClientRect();
                return {text:range?.toString(), visible:!!rect && rect.top >= 0 && rect.bottom <= innerHeight,
                    selection:getSelection().toString()};
                """, view) as? [String: Any]
            XCTAssertEqual(last?["text"] as? String, "needle", feature)
            XCTAssertEqual(last?["visible"] as? Bool, true, feature)
            XCTAssertEqual(last?["selection"] as? String, "Keep selection", feature)
            let expected = try await evaluate("return window.leafRangeHighlights().current[0]", view) as? [Double]
            try await wait {
                guard let rect = coordinator.rangeHighlightView?.rectangles.current.first, let y = expected?[1] else { return false }
                return abs(rect.minY - y) < 1
            }
            let painted = try XCTUnwrap(coordinator.rangeHighlightView?.rectangles.current.first)
            XCTAssertEqual(painted.minX, try XCTUnwrap(expected?[0]), accuracy: 1)
            XCTAssertEqual(painted.width, try XCTUnwrap(expected?[2]), accuracy: 1)
            let unchanged = try await evaluate("return document.body.innerHTML === window.originalBody", view) as? Bool
            XCTAssertEqual(unchanged, true)
            XCTAssertEqual(state.status, "2 / 2 matches", feature)
            XCTAssertNil(state.error)
            _ = try await evaluate("await window.leafCommand({name:'find',text:''})", view)
            try await wait { coordinator.rangeHighlightView == nil }
        }
    }

    @MainActor
    func testShortSpeechSelectionsVisitOnlyTheirPassageAndPreserveUTF16Offsets() async throws {
        let surrounding = String(repeating: "<p>Unselected passage.</p>", count: 2000)
        let (state, _, view) = try await reader(["Book.html": """
            <!doctype html><meta charset="utf-8">\(surrounding)
            <p id="start">Skip A😀<b>B</b><span style="display:none">HIDDEN</span><script>SCRIPT</script><style>STYLE</style><textarea>TEXTAREA</textarea>C</p>
            <p id="end">D😀E</p>\(surrounding)
            """], opened: "Book.html")
        let result = try await evaluate("""
            const start=document.getElementById('start'),end=document.getElementById('end'),selection=getSelection();
            const walk=document.createTreeWalker,handler=window.webkit.messageHandlers.leaf,post=handler.postMessage;
            let visited=0,spoken;
            document.createTreeWalker=function(...args){const walker=walk.apply(this,args),next=walker.nextNode.bind(walker);
                walker.nextNode=()=>{visited++;return next()};return walker};
            handler.postMessage=body=>{if(body.type==='readAloud')spoken=body.text;else post.call(handler,body)};
            const before=document.body.innerHTML,rows=[];
            try {
                window.Highlight=undefined;
                start.scrollIntoView({block:'center',behavior:'instant'});
                for(const elements of [false,true]) {
                    const range=document.createRange();
                    range.setStart(elements?start:start.firstChild,elements?0:5);
                    range.setEnd(elements?end:end.firstChild,elements?end.childNodes.length:3);
                    selection.removeAllRanges();selection.addRange(range);
                    const selected=selection.toString();visited=0;spoken=undefined;
                    await window.leafCommand({name:'readAloud',source:'selection'});
                    rows.push({spoken,visited,selectionUnchanged:selection.toString()===selected});
                    if(!elements) {
                        await window.leafCommand({name:'speechHighlight',location:6,length:2});
                        const emoji=document.createRange();emoji.setStart(end.firstChild,1);emoji.setEnd(end.firstChild,3);
                        const r=emoji.getBoundingClientRect();
                        rows[0].expected=[r.x,r.y,r.width,r.height];
                        rows[0].painted=window.leafRangeHighlights().speech;
                    }
                }
                return {rows,bodyUnchanged:before===document.body.innerHTML};
            } finally {document.createTreeWalker=walk;handler.postMessage=post;}
            """, view) as? [String: Any]
        let rows = try XCTUnwrap(result?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for (row, expected) in zip(rows, ["A😀BCD😀", "Skip A😀BCD😀E"]) {
            XCTAssertEqual(row["spoken"] as? String, expected)
            XCTAssertLessThan(try XCTUnwrap(row["visited"] as? Int), 30, "A short selected passage must not visit thousands of unrelated nodes")
            XCTAssertEqual(row["selectionUnchanged"] as? Bool, true)
        }
        let expected = try XCTUnwrap(rows[0]["expected"] as? [Double])
        let painted = try XCTUnwrap((rows[0]["painted"] as? [[Double]])?.first)
        XCTAssertEqual(painted.count, expected.count)
        for (actual, coordinate) in zip(painted, expected) { XCTAssertEqual(actual, coordinate, accuracy: 1) }
        XCTAssertEqual(result?["bodyUnchanged"] as? Bool, true)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testLargeSpeechAndRangeTextDoNotCompareEveryNodeWithDistantBoundaries() async throws {
        let paragraphCount = 4000
        let body = String(repeating: "<p>A😀<b>B</b>C</p>", count: paragraphCount)
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><meta charset=\"utf-8\">" + body], opened: "Book.html")
        let result = try await evaluate("""
            const selection=getSelection(),before=document.body.innerHTML,rows=[];
            const handler=window.webkit.messageHandlers.leaf,post=handler.postMessage;
            const compare=Range.prototype.comparePoint,intersects=Range.prototype.intersectsNode;
            let comparisons=0,spoken;
            Range.prototype.comparePoint=function(...args){comparisons++;return compare.apply(this,args)};
            Range.prototype.intersectsNode=function(...args){comparisons++;return intersects.apply(this,args)};
            handler.postMessage=body=>{if(body.type==='readAloud')spoken=body.text;else post.call(handler,body)};
            try {
                const all=document.createRange();all.selectNodeContents(document.body);
                selection.removeAllRanges();selection.addRange(all);const selected=selection.toString();
                comparisons=0;await window.leafCommand({name:'readAloud',source:'selection'});
                rows.push({text:spoken,comparisons,selectionUnchanged:selection.toString()===selected});
                comparisons=0;
                const text=window.__sumatraFind.textFromRange(all);
                rows.push({text,comparisons,selectionUnchanged:selection.toString()===selected});
                const cursor=document.createRange();cursor.setStart(document.body.firstChild.firstChild,1);cursor.collapse(true);
                selection.removeAllRanges();selection.addRange(cursor);comparisons=0;spoken=undefined;
                await window.leafCommand({name:'readAloud',source:'cursor'});
                rows.push({text:spoken,comparisons,selectionUnchanged:selection.isCollapsed &&
                    selection.anchorNode===cursor.startContainer && selection.anchorOffset===cursor.startOffset});
                return {rows,bodyUnchanged:before===document.body.innerHTML};
            } finally {Range.prototype.comparePoint=compare;Range.prototype.intersectsNode=intersects;handler.postMessage=post;}
            """, view) as? [String: Any]
        let rows = try XCTUnwrap(result?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        let fullText = String(repeating: "A😀BC", count: paragraphCount)
        for (row, expected) in zip(rows, [fullText, fullText, String(fullText.dropFirst())]) {
            XCTAssertEqual(row["text"] as? String, expected)
            XCTAssertLessThan(try XCTUnwrap(row["comparisons"] as? Int), 20,
                "Reading a large passage must resolve its boundaries once instead of comparing every node with distant endpoints")
            XCTAssertEqual(row["selectionUnchanged"] as? Bool, true)
        }
        XCTAssertEqual(result?["bodyUnchanged"] as? Bool, true)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testLargeSpeechHighlightsLocateUTF16WordsWithoutScanningThePassage() async throws {
        let paragraphCount = 4000
        let body = String(repeating: "<p>A😀<b>中B</b>C</p>", count: paragraphCount)
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><meta charset=\"utf-8\">" + body], opened: "Book.html")
        let result = try await evaluate("""
            const selection=getSelection(),before=document.body.innerHTML;
            const handler=window.webkit.messageHandlers.leaf,post=handler.postMessage,push=Array.prototype.push;
            const highlight=window.Highlight,registry=Object.getOwnPropertyDescriptor(CSS,'highlights');
            let spoken,offsetReads=0;
            handler.postMessage=body=>{if(body.type==='readAloud')spoken=body.text;else post.call(handler,body)};
            Array.prototype.push=function(...items) {
                for(const item of items) if(item?.node?.nodeType===Node.TEXT_NODE && typeof item.start==='number') {
                    const start=item.start;Object.defineProperty(item,'start',{get(){offsetReads++;return start}});
                }
                return push.apply(this,items);
            };
            try {
                const all=document.createRange();all.selectNodeContents(document.body);
                selection.removeAllRanges();selection.addRange(all);const selected=selection.toString();
                await window.leafCommand({name:'readAloud',source:'selection'});
                Array.prototype.push=push;
                await window.leafCommand({name:'interaction',flags:{speechFollow:false}});
                // Capture the real DOM Ranges on older WebKit too. Existing
                // fallback tests separately exercise native overlay painting.
                window.Highlight=class extends Set {constructor(range){super([range])}};
                Object.defineProperty(CSS,'highlights',{configurable:true,value:new Map()});
                const rows=[],total=spoken.length,cases=[[total-1,1,'C'],[0,1,'A'],[1,2,'😀'],[3,2,'中B'],
                    [1,4,'😀中B'],[5,2,'CA'],[total/2+1,2,'😀'],[total,1,''],[0,0,'']];
                for(const [location,length,expected] of cases) {
                    offsetReads=0;await window.leafCommand({name:'speechHighlight',location,length});
                    const ranges=CSS.highlights.get('sumra-speech');
                    rows.push({text:ranges?[...ranges].map(range=>range.toString()).join(''):'',expected,offsetReads});
                }
                return {rows,spoken,selectionUnchanged:selected===selection.toString(),bodyUnchanged:before===document.body.innerHTML};
            } finally {
                Array.prototype.push=push;handler.postMessage=post;window.Highlight=highlight;
                if(registry)Object.defineProperty(CSS,'highlights',registry);else delete CSS.highlights;
            }
            """, view) as? [String: Any]
        let rows = try XCTUnwrap(result?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 9)
        for row in rows {
            XCTAssertEqual(row["text"] as? String, row["expected"] as? String)
            XCTAssertLessThan(try XCTUnwrap(row["offsetReads"] as? Int), 80,
                "Each spoken word must use bounded offset lookup even near the beginning or end of a large passage")
        }
        XCTAssertEqual(result?["spoken"] as? String, String(repeating: "A😀中BC", count: paragraphCount))
        XCTAssertEqual(result?["selectionUnchanged"] as? Bool, true)
        XCTAssertEqual(result?["bodyUnchanged"] as? Bool, true)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSpeechAndRangeTextRespectElementAndTextEndBoundaries() async throws {
        let (state, _, view) = try await reader(["Book.html": """
            <!doctype html><meta charset="utf-8"><p id="a">A😀<b>B</b>C</p><p id="b">D<span>EF</span>G</p><script>SCRIPT</script><style>STYLE</style><p id="c">H</p>
            """], opened: "Book.html")
        let result = try await evaluate("""
            const a=document.getElementById('a'),b=document.getElementById('b'),c=document.getElementById('c');
            const handler=window.webkit.messageHandlers.leaf,post=handler.postMessage,selection=getSelection();
            let spoken;handler.postMessage=body=>{if(body.type==='readAloud')spoken=body.text;else post.call(handler,body)};
            const before=document.body.innerHTML,rows=[];
            try {
                const cases=[[a,1,b,1],[a.firstChild,1,b,b.childNodes.length],[b.firstChild,0,c,0],
                    [a.firstChild,a.firstChild.length,b.firstChild,1],[a,a.childNodes.length,b,b.childNodes.length],
                    [a.firstChild,0,b.firstChild,0]];
                for(const [start,from,end,to] of cases) {
                    const range=document.createRange();range.setStart(start,from);range.setEnd(end,to);
                    selection.removeAllRanges();selection.addRange(range);const selected=selection.toString();spoken=undefined;
                    const text=window.__sumatraFind.textFromRange(range);
                    await window.leafCommand({name:'readAloud',source:'selection'});
                    rows.push({text,spoken,selectionUnchanged:selection.toString()===selected});
                }
                const cursor=document.createRange();cursor.setStart(a.firstChild,a.firstChild.length);cursor.collapse(true);
                selection.removeAllRanges();selection.addRange(cursor);spoken=undefined;
                await window.leafCommand({name:'readAloud',source:'cursor'});
                return {rows,cursorText:spoken,cursorUnchanged:selection.isCollapsed &&
                    selection.anchorNode===cursor.startContainer && selection.anchorOffset===cursor.startOffset,
                    bodyUnchanged:before===document.body.innerHTML};
            } finally {handler.postMessage=post;}
            """, view) as? [String: Any]
        let rows = try XCTUnwrap(result?["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 6)
        for (row, expected) in zip(rows, ["BCD", "😀BCDEFG", "DEFG", "BCD", "DEFG", "A😀BC"]) {
            XCTAssertEqual(row["text"] as? String, expected)
            XCTAssertEqual(row["spoken"] as? String, expected)
            XCTAssertEqual(row["selectionUnchanged"] as? Bool, true)
        }
        XCTAssertEqual(result?["cursorText"] as? String, "BCDEFGH")
        XCTAssertEqual(result?["cursorUnchanged"] as? Bool, true)
        XCTAssertEqual(result?["bodyUnchanged"] as? Bool, true)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSpeechSelectionWithAnHTMLBoundaryIncludesOnlyBodyText() async throws {
        let (state, _, view) = try await reader(["Book.html": """
            <!doctype html><html><head><meta charset="utf-8"><title>HEAD_ONLY</title></head><body><p>A😀<b>B</b></p><p>C</p></body></html>
            """], opened: "Book.html")
        let result = try await evaluate("""
            const handler=window.webkit.messageHandlers.leaf,post=handler.postMessage;
            let spoken;handler.postMessage=body=>{if(body.type==='readAloud')spoken=body.text;else post.call(handler,body)};
            try {
                const range=document.createRange();range.selectNodeContents(document.documentElement);
                const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
                const before=selection.toString();await window.leafCommand({name:'readAloud',source:'selection'});
                return {spoken,selectionUnchanged:before===selection.toString()};
            } finally {handler.postMessage=post;}
            """, view) as? [String: Any]
        XCTAssertEqual(result?["spoken"] as? String, "A😀BC")
        XCTAssertEqual(result?["selectionUnchanged"] as? Bool, true)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSpeechFollowWithoutCustomHighlightsPreservesTheUserSelection() async throws {
        let (state, coordinator, view) = try await reader(["Book.html": """
            <!doctype html><p id="selection">Keep selection</p><p>Reading begins here.</p>
            <div style="height:3000px"></div><p id="last">FINALWORD</p>
            """], opened: "Book.html")
        let result = try await evaluate("""
            window.Highlight = undefined;
            const all = document.createRange(); all.selectNodeContents(document.body);
            getSelection().removeAllRanges(); getSelection().addRange(all);
            await window.leafCommand({name:'interaction', flags:{speechFollow:true}});
            await window.leafCommand({name:'readAloud', source:'selection'});
            const selectionRange = document.createRange(); selectionRange.selectNodeContents(document.getElementById('selection'));
            getSelection().removeAllRanges(); getSelection().addRange(selectionRange);
            // Speech's offsets refer to its text walker, excluding whitespace-only
            // nodes with no painted rectangles, rather than body.textContent.
            const walker = window.__sumatraFind.textWalker(document.body);
            let node, text = '';
            while ((node = walker.nextNode())) {
                const range = document.createRange(); range.selectNodeContents(node);
                if (range.getClientRects().length) text += node.data;
            }
            await window.leafCommand({name:'speechHighlight', location:text.indexOf('FINALWORD'), length:9});
            const rect = document.getElementById('last').getBoundingClientRect();
            return {scrolled:scrollY > 0, visible:rect.top >= 0 && rect.bottom <= innerHeight,
                selection:getSelection().toString()};
            """, view) as? [String: Any]
        XCTAssertEqual(result?["scrolled"] as? Bool, true)
        XCTAssertEqual(result?["visible"] as? Bool, true)
        XCTAssertEqual(result?["selection"] as? String, "Keep selection")
        try await wait { coordinator.rangeHighlightView?.rectangles.speech.isEmpty == false }
        let speech = try XCTUnwrap(coordinator.rangeHighlightView?.rectangles.speech.first)
        XCTAssertGreaterThanOrEqual(speech.minY, 0)
        XCTAssertLessThanOrEqual(speech.maxY, view.bounds.height)
        _ = try await evaluate("await window.leafCommand({name:'speechHighlight',location:0,length:0})", view)
        try await wait { coordinator.rangeHighlightView == nil }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeHighlightsRespectOverflowClippingAndHiddenText() async throws {
        let (state, coordinator, view) = try await reader(["Book.html": """
            <!doctype html><div id="viewport" style="height:20px;overflow:hidden;border:5px solid transparent">
            <p style="margin:0;height:80px">A needle inside the clipped passage.</p></div>
            <p style="visibility:hidden">A needle hidden from view.</p><p>Visible text after the container.</p>
            """], opened: "Book.html")
        _ = try await evaluate("window.Highlight=undefined;await window.leafCommand({name:'find',text:'needle'})", view)
        try await wait { state.searchResults.count == 2 && coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        let value = try await evaluate("""
            const box=document.getElementById('viewport'),rect=box.getBoundingClientRect();
            return {top:rect.top+box.clientTop,bottom:rect.top+box.clientTop+box.clientHeight};
            """, view) as? [String: Double]
        let clip = try XCTUnwrap(value), overlay = try XCTUnwrap(coordinator.rangeHighlightView)
        XCTAssertEqual(overlay.rectangles.find.count, 1, "Hidden text retains its match but has no visible highlight")
        let current = try XCTUnwrap(overlay.rectangles.current.first)
        XCTAssertGreaterThanOrEqual(current.minY, try XCTUnwrap(clip["top"]))
        XCTAssertLessThanOrEqual(current.maxY, try XCTUnwrap(clip["bottom"]))
        XCTAssertLessThan(current.height, 20.5, "Only the visible portion of the glyph rectangle is painted")
        XCTAssertEqual(state.searchResults.count, 2)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeRangeHighlightsTrackZoomAndViewportWithoutChangingDocumentCSS() async throws {
        let (state, coordinator, view) = try await reader(["Book.html": """
            <!doctype html><style>body > p { color:rgb(1,2,3) } p + p { padding-top:18px }</style>
            <p>Context above.</p><p id="query">A needle in the passage.</p>
            """], opened: "Book.html")
        _ = try await evaluate("""
            window.originalBody = document.body.innerHTML;
            window.Highlight = undefined;
            await window.leafCommand({name:'find',text:'needle'});
            """, view)
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        state.zoom = 1.5; state.send(.zoom(1.5))
        try await completeCurrentCommand(state, coordinator, view)
        let value = try await evaluate("return window.leafRangeHighlights().current[0]", view) as? [Double]
        let expected = try XCTUnwrap(value)
        try await wait {
            guard let rect = coordinator.rangeHighlightView?.rectangles.current.first else { return false }
            return abs(rect.minY - expected[1] * 1.5) < 1 && abs(rect.width - expected[2] * 1.5) < 1
        }
        let rect = try XCTUnwrap(coordinator.rangeHighlightView?.rectangles.current.first)
        XCTAssertEqual(rect.minX, expected[0] * 1.5, accuracy: 1)
        XCTAssertEqual(rect.height, expected[3] * 1.5, accuracy: 1)
        let fidelity = try await evaluate("""
            return {unchanged:document.body.innerHTML === window.originalBody,
                color:getComputedStyle(document.getElementById('query')).color,
                padding:getComputedStyle(document.getElementById('query')).paddingTop};
            """, view) as? [String: Any]
        XCTAssertEqual(fidelity?["unchanged"] as? Bool, true)
        XCTAssertEqual(fidelity?["color"] as? String, "rgb(1, 2, 3)")
        XCTAssertEqual(fidelity?["padding"] as? String, "18px")
        XCTAssertNil(coordinator.rangeHighlightView?.hitTest(.zero))
        state.closeFind(); try await completeCurrentCommand(state, coordinator, view)
        try await wait { coordinator.rangeHighlightView == nil }
    }

    @MainActor
    func testCachedSearchRestoresNativeHighlightsAfterNavigation() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md":"# First\n\nA needle.", "B.md":"# Second\n\nB needle."
        ], opened:"A.md")
        _ = try await evaluate("window.Highlight=undefined;window.cacheMarker='original'", view)
        state.showFindPanel()
        state.send(.find("needle", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 2 && coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        state.navigate(.href("leaf://book/entry/B.md"))
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertTrue(view.url?.path.hasSuffix("B.md") == true)
        _ = try await evaluate("window.Highlight=undefined", view)
        coordinator.activateDocument(view)
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        _ = try await evaluate("await window.leafCommand({name:'find',text:''})", view)
        try await wait { coordinator.rangeHighlightView == nil }
        state.navigateHistory(-1)
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertTrue(view.url?.path.hasSuffix("A.md") == true)
        let restored = try await evaluate("return {marker:window.cacheMarker,range:window.__sumatraFind.currentRange()?.toString()}", view) as? [String: Any]
        XCTAssertEqual(restored?["marker"] as? String, "original")
        XCTAssertEqual(restored?["range"] as? String, "needle")
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        state.closeFind(); try await completeCurrentCommand(state, coordinator, view)
        try await wait { coordinator.rangeHighlightView == nil }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testMarkdownUsesBrowserWithUpstreamAnchorsAndRelativeResources() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# Another file\n\nOnly in the other file.",
            "C#1.md": "# adc_intr_ctl . TRANS_EN\n\n## 中文标题\n\n[Local](sub/next.md#next)\n\n![diagram](pic.svg)\n\n末",
            "sub/next.md": "# Next\n\nSecond document.",
            "pic.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"23\" height=\"19\"><rect width=\"23\" height=\"19\" fill=\"red\"/></svg>"
        ], opened: "C#1.md", showContents: true)
        XCTAssertTrue(state.isBrowser)
        try await wait { state.outline.contains { $0.title == "Next" } }
        XCTAssertEqual(state.count, 3)
        XCTAssertTrue(state.outline.contains { $0.title == "中文标题" })
        let result = try await evaluate("""
            await Promise.all(Array.from(document.images, image => image.complete ? Promise.resolve() : new Promise(resolve => { image.onload=resolve; image.onerror=resolve; })));
            return {anchor: !!document.getElementById('adc_intr_ctl--trans_en'),
                image: document.images[0].naturalWidth, text: document.body.innerText,
                readyToPrint: (await window.leafPreparePrint(), true)};
            """, view) as? [String: Any]
        XCTAssertEqual(result?["anchor"] as? Bool, true)
        XCTAssertEqual(result?["image"] as? Int, 23)
        XCTAssertTrue((result?["text"] as? String ?? "").contains("末"))
        XCTAssertEqual(result?["readyToPrint"] as? Bool, true)
        XCTAssertNil(coordinator.readerError)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testBrowserSelectionConsumersResolveTheCurrentFullText() async throws {
        let fullSelection = String(repeating: "Selected content · ", count: 5_000) + "最后"
        let (state, coordinator, view) = try await reader(["Book.html": """
            <!doctype html><meta charset="utf-8"><h1>Whole document heading</h1><p id="selected">\(fullSelection)</p>
            <p id="query">  Find needle  </p><p>Outside selection text</p>
            """], opened: "Book.html")
        _ = try await evaluate("""
            const range = document.createRange(); range.selectNodeContents(document.getElementById('selected'));
            getSelection().removeAllRanges(); getSelection().addRange(range);
            """, view)
        try await wait { state.hasSelection }
        XCTAssertTrue(state.hasTextSelection)
        let selected = try await state.selectionText()
        XCTAssertTrue(selected == fullSelection, "Selection extraction must preserve the complete UTF-8 text")
        let documentSelection = try await state.documentText()
        XCTAssertTrue(documentSelection == fullSelection, "Document actions must consume the full current selection")
        let wholeDocument = try await state.documentText(entireDocument: true)
        XCTAssertTrue(wholeDocument.contains(fullSelection))
        XCTAssertTrue(wholeDocument.contains("Outside selection text"))

        // Browser Copy uses the system pasteboard. Retain every existing format
        // and restore it immediately after checking the copied selection.
        do {
            let pasteboard = NSPasteboard.general
            let saved = try (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { copy.setData(try XCTUnwrap(item.data(forType: type)), forType: type) }
                return copy
            }
            defer { pasteboard.clearContents(); if !saved.isEmpty { pasteboard.writeObjects(saved) } }
            state.send(.copy)
            try await completeCurrentCommand(state, coordinator, view)
            try await wait { pasteboard.string(forType: .string) == fullSelection }
            XCTAssertTrue(pasteboard.string(forType: .string) == fullSelection, "Copy must preserve the complete selected text")
        }

        _ = try await evaluate("""
            const range = document.createRange(); range.selectNodeContents(document.getElementById('query'));
            getSelection().removeAllRanges(); getSelection().addRange(range);
            """, view)
        state.findNext(fromSelection: true)
        try await wait {
            if case .find(let query, _, _, _, _) = state.command.action { return query == "Find needle" }
            return false
        }
        XCTAssertEqual(state.findQuery, "Find needle")
        XCTAssertEqual(ReaderSearchHistory.shared.queries.first, "Find needle")
        if case .find(let query, _, _, let fromSelection, _) = state.command.action {
            XCTAssertEqual(query, "Find needle"); XCTAssertTrue(fromSelection)
        } else { XCTFail("Find from selection must issue the selected query") }
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { !state.searchResults.isEmpty }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testBrowserSelectionJSONCommandWritesTheCurrentSelection() async throws {
        let selected = "A \"quoted\" & <literal>\n中文 ${userlang}"
        let (state, _, view) = try await reader(["Book.html": """
            <!doctype html><meta charset="utf-8"><pre id="selected">A &quot;quoted&quot; &amp; &lt;literal&gt;
            中文 ${userlang}</pre><p>Unselected text</p>
            """], opened: "Book.html")
        _ = try await evaluate("""
            const range = document.createRange(); range.selectNodeContents(document.getElementById('selected'));
            getSelection().removeAllRanges(); getSelection().addRange(range);
            """, view)
        try await wait { state.hasSelection }
        let temporary = try TemporaryDirectory(), output = temporary.url.appendingPathComponent("selection.json")
        defer { withExtendedLifetime(temporary) {} }
        let configuration = try JSONSerialization.data(withJSONObject: [[
            "name": "Selection JSON fixture", "needsSelection": false,
            "arguments": ["/bin/sh", "-c", "printf '%s' \"$1\" > \"$2.tmp\" && /bin/mv \"$2.tmp\" \"$2\"",
                          "sumra-selection-fixture", "\"${selectionjson}\"", output.path]
        ] as [String: Any]])
        let command = try XCTUnwrap(ExternalReaderCommand.read(String(decoding: configuration, as: UTF8.self)).first)
        XCTAssertTrue(command.enabled(state))
        command.run(state)
        try await wait { FileManager.default.fileExists(atPath: output.path) || state.error != nil }
        XCTAssertNil(state.error)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: output), options: .fragmentsAllowed) as? String
        XCTAssertEqual(written, selected, "Selection JSON must carry the browser's current text without recursive substitution")
    }

    @MainActor
    func testPendingSelectionExtractionCannotReturnTextFromAReplacedDocument() async throws {
        let (state, _, view) = try await reader(["Book.md": "# Original\n\nOriginal selection."], opened: "Book.md")
        _ = try await evaluate("""
            window.selectionStarted = new Promise(started => {
                window.leafSelectedText = () => new Promise(resolve => {
                    window.finishSelection = resolve; started();
                });
            });
            """, view)
        let extraction = Task { try await state.selectionText() }
        _ = try await evaluate("await window.selectionStarted; return true", view)
        state.document = ReadingDocument(url: try XCTUnwrap(state.document?.url), content: .text("Replacement text"))
        _ = try await evaluate("window.finishSelection('Original selection')", view)
        do {
            _ = try await extraction.value
            XCTFail("A replaced document must cancel its pending selection extraction")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testBrowserScrollRestoreAndFindKeepUserSelection() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) has searchable text.\n\n" }.joined()
        let (state, _, view) = try await reader(["Book.md": "# Title\n\n\(paragraphs)"], opened: "Book.md")
        let result = try await evaluate("""
            const p = document.querySelector('p'); const range = document.createRange(); range.selectNodeContents(p);
            window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
            const selected = window.getSelection().toString();
            await window.leafCommand({name:'find', text:'searchable', matchCase:false, matchWholeWords:true});
            await window.leafCommand({name:'find', text:'searchable', matchCase:false, matchWholeWords:true});
            await window.leafCommand({name:'toc'});
            await window.leafCommand({name:'restore', position:{page:0,x:0,y:700}});
            return {selected, after:window.getSelection().toString(), y:window.scrollY};
            """, view) as? [String: Any]
        XCTAssertEqual(result?["selected"] as? String, result?["after"] as? String)
        XCTAssertEqual(try XCTUnwrap(result?["y"] as? Double), 700, accuracy: 2)
        try await wait { (state.currentPosition.y ?? 0) > 650 }
        XCTAssertFalse(state.currentPosition.anchor?.contains("#") == true)
    }

    @MainActor
    func testSearchUsesTheDisplayedCurrentPageWithoutLoadingASecondDocument() async throws {
        let (state, _, view) = try await reader(["Book.md": "# Title\n\nSource text"], opened: "Book.md")
        // Reader transformations such as Mermaid rendering change the live DOM.
        // The search results must describe the same text as the current ranges.
        _ = try await evaluate("""
            document.querySelector('p').textContent = 'Displayed needle';
            await window.leafCommand({name:'find', text:'needle', matchCase:true});
            """, view)
        try await wait { state.searchResults.count == 1 }
        XCTAssertTrue(state.searchResults[0].title.contains("Displayed needle"))
        let result = try await evaluate("""
            return [...(CSS.highlights.get('sumatra-find') || [])].map(range => range.toString());
            """, view) as? [String]
        XCTAssertEqual(result, ["needle"])
        // A subsequent query must use the new live text, not retain an earlier
        // extraction when a reader transformation replaces DOM nodes.
        _ = try await evaluate("""
            await window.leafCommand({name:'find', text:''});
            document.querySelector('p').textContent = 'Updated needle and needle';
            await window.leafCommand({name:'find', text:'needle', matchCase:true});
            """, view)
        try await wait { state.searchResults.count == 2 }
        XCTAssertTrue(state.searchResults.allSatisfy { $0.title.contains("Updated needle and needle") })
        let updated = try await evaluate("""
            return [...(CSS.highlights.get('sumatra-find') || [])].map(range => range.toString());
            """, view) as? [String]
        XCTAssertEqual(updated, ["needle", "needle"])
    }

    @MainActor
    func testHTMLDocumentCannotReplaceTheIsolatedReaderBridge() async throws {
        let (_, _, view) = try await reader(["Book.html": """
            <!doctype html><title>HTML</title><h1 id="heading">Heading</h1><p>Readable</p>
            <script>document.body.textContent='executed';window.leafCommand=()=>{throw Error('replaced')};</script>
            """], opened: "Book.html")
        let text = try await evaluate("return await window.leafText(false)", view) as? String
        XCTAssertTrue(text?.contains("Readable") == true)
        XCTAssertFalse(text?.contains("executed") == true)
    }

    @MainActor
    func testLinkPreviewsOnlyTouchTheHoveredLinkAndRestoreAuthoredTitles() async throws {
        let (_, _, view) = try await reader(["Book.html": """
            <!doctype html><title>Links</title>
            <a id="absent" href="#destination"><span>Without title</span><em>nested text</em></a>
            <a id="empty" href="#destination" title="">Empty title</a>
            <a id="authored" href="#destination" title="Author tooltip">Authored title</a>
            <p id="destination">Preview target text</p>
            """], opened: "Book.html")
        let result = try await evaluate("""
            const links = ['absent','empty','authored'].map(id => document.getElementById(id));
            const original = [null, '', 'Author tooltip'];
            const restored = () => links.every((link, index) => link.getAttribute('title') === original[index]);
            const mutations = [];
            const observer = new MutationObserver(records => mutations.push(...records));
            observer.observe(document.body, {attributes:true, subtree:true});
            await window.leafCommand({name:'interaction', flags:{hoverPreview:true}});
            await Promise.resolve();
            mutations.push(...observer.takeRecords());
            const untouched = restored() && mutations.length === 0;
            observer.disconnect();
            let previews = true, leaves = true, disabled = true, onlyHovered = true, nested = true;
            for (const [index, link] of links.entries()) {
                const child = link.firstElementChild || link;
                child.dispatchEvent(new PointerEvent('pointerover', {bubbles:true, relatedTarget:document.body}));
                previews &&= link.title === 'Preview target text';
                onlyHovered &&= links.every((other, i) => i === index || other.getAttribute('title') === original[i]);
                if (link.lastElementChild && link.lastElementChild !== child) {
                    child.dispatchEvent(new PointerEvent('pointerout', {bubbles:true, relatedTarget:link.lastElementChild}));
                    link.lastElementChild.dispatchEvent(new PointerEvent('pointerover', {bubbles:true, relatedTarget:child}));
                    nested &&= link.title === 'Preview target text';
                }
                link.dispatchEvent(new PointerEvent('pointerout', {bubbles:true, relatedTarget:document.body}));
                leaves &&= restored();
                link.dispatchEvent(new PointerEvent('pointerover', {bubbles:true, relatedTarget:document.body}));
                await window.leafCommand({name:'interaction', flags:{hoverPreview:false}});
                disabled &&= restored();
                link.dispatchEvent(new PointerEvent('pointerover', {bubbles:true, relatedTarget:document.body}));
                disabled &&= restored();
                await window.leafCommand({name:'interaction', flags:{hoverPreview:true}});
            }
            return {untouched, previews, onlyHovered, nested, leaves, disabled};
            """, view) as? [String: Bool]
        for key in ["untouched", "previews", "onlyHovered", "nested", "leaves", "disabled"] {
            XCTAssertEqual(result?[key], true, key)
        }
    }

    @MainActor
    func testKeyboardLinkHintsFollowTheViewportWithoutRewritingUnchangedStyles() async throws {
        let (_, _, view) = try await reader(["Book.html": """
            <!doctype html><title>Keyboard links</title>
            <p><a id="first" href="#target">First link</a></p>
            <div style="height:1600px"></div>
            <p><a id="last" href="#target">Last link</a></p>
            <p id="target">Destination</p>
            """], opened: "Book.html")
        let result = try await evaluate("""
            const first = document.getElementById('first'), last = document.getElementById('last');
            const flags = {keyboardLinks:true, showLinks:true, scrollbars:'shown'};
            await window.leafCommand({name:'interaction', flags});
            const initial = first.dataset.sumraLink === '1' && !last.hasAttribute('data-sumra-link');
            const observer = new MutationObserver(() => {});
            observer.observe(document.head, {childList:true, characterData:true, subtree:true});
            for (let i = 0; i < 5; i++) window.dispatchEvent(new Event('scroll'));
            const unchanged = observer.takeRecords().length === 0;
            observer.disconnect();
            scrollTo(0, document.documentElement.scrollHeight);
            window.dispatchEvent(new Event('scroll'));
            const moved = !first.hasAttribute('data-sumra-link') && last.dataset.sumraLink === '1';
            const shown = getComputedStyle(last).outlineStyle === 'solid' && getComputedStyle(document.documentElement).overflow === 'scroll';
            await window.leafCommand({name:'interaction', flags:{...flags, showLinks:false, scrollbars:'hidden'}});
            const hidden = getComputedStyle(last).outlineStyle === 'none' && getComputedStyle(document.documentElement).scrollbarWidth === 'none';
            document.body.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));
            const disabled = !document.querySelector('a[data-sumra-link]');
            return {initial, unchanged, moved, shown, hidden, disabled};
            """, view) as? [String: Bool]
        for key in ["initial", "unchanged", "moved", "shown", "hidden", "disabled"] {
            XCTAssertEqual(result?[key], true, key)
        }
    }

    @MainActor
    func testRapidMarkdownZoomKeepsLatestPendingSizeAndSelection() async throws {
        let body = (0..<300).map { "Paragraph \($0): Keep this reading passage and selection.\n\n" }.joined()
        let (state, coordinator, view) = try await reader(["Book.md": body], opened: "Book.md", position: .init(zoom: 1))
        try await completeCurrentCommand(state, coordinator, view)
        _ = try await evaluate("""
            window.originalMarkup = document.body.innerHTML;
            const selectionRange = document.createRange();
            selectionRange.selectNodeContents(document.querySelector('p'));
            getSelection().removeAllRanges(); getSelection().addRange(selectionRange);
            window.originalSelection = getSelection().toString();
            scrollTo(0, 1000);
            window.deliveredZooms = [];
            const originalCommand = window.leafCommand;
            window.leafCommand = async command => {
                if (command.name === 'zoom') window.deliveredZooms.push(command.text);
                return await originalCommand(command);
            };
            """, view)
        try await wait { state.currentPosition.y == 1000 }
        for zoom in [1.1, 1.2, 1.3, 1.4, 1.5] { state.setZoom(zoom) }
        state.send(.none)
        var deliveries = 0
        while state.command.action != .none, deliveries < 10 {
            let command = state.command
            coordinator.deliver(command, to: view)
            try await wait { state.command.revision > command.revision || state.error != nil }
            XCTAssertNil(state.error)
            deliveries += 1
        }
        coordinator.deliver(state.command, to: view)
        let result = try await evaluate("""
            return {zooms:window.deliveredZooms.map(text => Number(text.split('|')[1])),
                font:getComputedStyle(document.body).fontSize,
                markupUnchanged:document.body.innerHTML === window.originalMarkup,
                selectionUnchanged:getSelection().toString() === window.originalSelection,
                scrolled:scrollY > 0};
            """, view) as? [String: Any]
        let sizes = try XCTUnwrap(result?["zooms"] as? [Double])
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes.first ?? 0, 18.7, accuracy: 0.001)
        XCTAssertEqual(sizes.last ?? 0, 25.5, accuracy: 0.001)
        XCTAssertEqual(result?["font"] as? String, "25.5px")
        XCTAssertEqual(view.pageZoom, 1)
        XCTAssertEqual(state.zoom, 1.5)
        for key in ["markupUnchanged", "selectionUnchanged", "scrolled"] { XCTAssertEqual(result?[key] as? Bool, true, key) }
    }

    @MainActor
    func testPendingBrowserZoomDoesNotCrossCommandBarriers() async throws {
        let (state, _, _) = try await reader(["Book.html": "<p>Browser command ordering</p>"], opened: "Book.html")
        state.send(.copy)
        let inFlight = state.command
        for action: ReaderAction in [.zoom(1.1), .zoom(1.2), .style, .zoom(1.3), .zoom(1.4), .page(0), .zoom(1.5), .none, .zoom(1.6)] {
            state.send(action)
        }
        XCTAssertEqual(state.command, inFlight, "Pending changes must not replace a published command")
        state.send(.selectAll)
        let expected: [ReaderAction] = [.copy, .zoom(1.2), .style, .zoom(1.4), .page(0), .zoom(1.5), .none, .zoom(1.6)]
        var delivered: [ReaderAction] = []
        while state.command.action != .selectAll, delivered.count < 20 {
            delivered.append(state.command.action)
            let revision = state.command.revision
            state.didHandleCommand(revision)
            try await wait { state.command.revision > revision }
        }
        XCTAssertEqual(delivered, expected)
        state.didHandleCommand(state.command.revision)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        state.send(.selectAll)
        XCTAssertEqual(state.command.action, .selectAll, "The final acknowledgement must release the queue")
    }

    @MainActor
    func testRestoreLeavesUnchangedStylesAloneAndStyleChangesStillApply() async throws {
        let (_, _, view) = try await reader(["Book.html": """
            <!doctype html><title>Styles</title><style id="publisher">#inline { color:rgb(12,34,56) }</style>
            <p id="inline" style="font-size:19px">Styled paragraph</p>
            """], opened: "Book.html")
        let result = try await evaluate("""
            const base = {...window.sumraDocument.initial};
            const inline = document.getElementById('inline'), publisher = document.getElementById('publisher');
            const mutations = [];
            const observer = new MutationObserver(records => mutations.push(...records));
            observer.observe(document.documentElement, {attributes:true, childList:true, characterData:true, subtree:true});
            for (let i = 0; i < 3; i++) await window.leafCommand({...base, name:'restore', position:{page:0,x:0,y:0}});
            await Promise.resolve(); mutations.push(...observer.takeRecords());
            const unchanged = mutations.length === 0;
            observer.disconnect();
            await window.leafCommand({...base, name:'style', text:'system|23|1.6|32|light', userCSS:'#inline { letter-spacing:3px }'});
            const updated = getComputedStyle(document.body).fontSize === '23px' && getComputedStyle(inline).letterSpacing === '3px';
            await window.leafCommand({name:'style', useDocumentCSS:false});
            const disabled = publisher.media === 'not all' && !inline.hasAttribute('style');
            await window.leafCommand({name:'style', useDocumentCSS:true});
            const restored = publisher.media === '' && inline.getAttribute('style') === 'font-size:19px'
                && getComputedStyle(inline).fontSize === '19px' && getComputedStyle(inline).color === 'rgb(12, 34, 56)';
            return {unchanged, updated, disabled, restored};
            """, view) as? [String: Bool]
        for key in ["unchanged", "updated", "disabled", "restored"] {
            XCTAssertEqual(result?[key], true, key)
        }
    }

    @MainActor
    func testCrossFileCommandWaitsForTheNewDocument() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First\n\nOld file text.", "B.md": "# Second\n\nNew file text."
        ], opened: "A.md")
        state.send(.page(1))
        state.send(.selectAll)
        let revision = state.command.revision
        coordinator.deliver(state.command, to: view)
        try await wait { state.command.revision > revision || state.error != nil }
        XCTAssertNil(state.error)
        XCTAssertTrue(coordinator.ready, "The next command must wait for the navigation, not the old JS result")
        XCTAssertTrue(view.url?.path.hasSuffix("B.md") == true)
        coordinator.deliver(state.command, to: view)
        try await wait { state.hasSelection }
        let selected = try await state.selectionText()
        XCTAssertTrue(selected.contains("New file text"))
        XCTAssertFalse(selected.contains("Old file text"))
    }

    @MainActor
    func testApplicationHistoryReusesCachedPagesAndFinishesBeforeSelection() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) fills this document.\n\n" }.joined()
        let sources = [
            "A.md": "# First document\n\n" + paragraphs,
            "B.md": "# Second document\n\n" + paragraphs + "## Late heading\n\n" + paragraphs
        ]
        let (state, coordinator, view) = try await reader(sources, opened: "A.md")
        func assertDisplayedSource(_ name: String, line: UInt = #line) throws {
            let document = try XCTUnwrap(state.document, line: line)
            XCTAssertEqual(document.url.lastPathComponent, name, line: line)
            let destination = document.url.deletingLastPathComponent().appendingPathComponent("saved-copy.bin")
            defer { try? FileManager.default.removeItem(at: destination) }
            try document.copySource(to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), Data(try XCTUnwrap(sources[name]).utf8), line: line)
        }
        _ = try await evaluate("window.cacheMarker='first'; scrollTo(0,450)", view)
        try await wait { abs((state.currentPosition.y ?? 0) - 450) < 2 }
        state.navigate(.href("leaf://book/entry/B.md#late-heading"))
        try await completeCurrentCommand(state, coordinator, view)
        try assertDisplayedSource("B.md")
        _ = try await evaluate("window.cacheMarker='second'; scrollTo(0,900)", view)
        try await wait { abs((state.currentPosition.y ?? 0) - 900) < 2 }
        state.navigate(.href("leaf://book/entry/A.md"))
        try await completeCurrentCommand(state, coordinator, view)
        try assertDisplayedSource("A.md")
        let revisitedFirst = try await evaluate("return {marker:window.cacheMarker, y:scrollY}", view) as? [String: Any]
        XCTAssertEqual(revisitedFirst?["marker"] as? String, "first", "A link revisit must reuse the existing document realm")
        XCTAssertEqual(try XCTUnwrap(revisitedFirst?["y"] as? Double), 450, accuracy: 2)
        XCTAssertEqual(view.backForwardList.backList.count, 0)
        XCTAssertEqual(view.backForwardList.forwardList.count, 1)
        state.navigate(.href("leaf://book/entry/B.md#late-heading"))
        try await completeCurrentCommand(state, coordinator, view)
        try assertDisplayedSource("B.md")
        let revisitedSecond = try await evaluate("return {marker:window.cacheMarker, y:scrollY, headingTop:document.getElementById('late-heading').getBoundingClientRect().top}", view) as? [String: Any]
        XCTAssertEqual(revisitedSecond?["marker"] as? String, "second")
        XCTAssertEqual(try XCTUnwrap(revisitedSecond?["headingTop"] as? Double), 0, accuracy: 2,
                       "An authored fragment must override the cached file's saved scroll position")
        XCTAssertGreaterThan(try XCTUnwrap(revisitedSecond?["y"] as? Double), 900)
        XCTAssertEqual(view.backForwardList.backList.count, 1)
        XCTAssertEqual(view.backForwardList.forwardList.count, 0)
        _ = try await evaluate("scrollTo(0,900)", view)
        try await wait { abs((state.currentPosition.y ?? 0) - 900) < 2 }
        for _ in 0..<2 {
            state.navigateHistory(-1)
            try await completeCurrentCommand(state, coordinator, view)
            XCTAssertTrue(coordinator.ready)
            try assertDisplayedSource("A.md")
            let first = try await evaluate("return {marker:window.cacheMarker, y:scrollY}", view) as? [String: Any]
            XCTAssertEqual(first?["marker"] as? String, "first", "Back must reuse the existing document realm")
            XCTAssertEqual(try XCTUnwrap(first?["y"] as? Double), 450, accuracy: 2)
            XCTAssertEqual(view.backForwardList.backList.count, 0)
            XCTAssertEqual(view.backForwardList.forwardList.count, 1)
            state.navigateHistory(1)
            try await completeCurrentCommand(state, coordinator, view)
            try assertDisplayedSource("B.md")
            let second = try await evaluate("return {marker:window.cacheMarker, y:scrollY}", view) as? [String: Any]
            XCTAssertEqual(second?["marker"] as? String, "second")
            XCTAssertEqual(try XCTUnwrap(second?["y"] as? Double), 900, accuracy: 2,
                           "The cached item's old heading hash must not override the saved coordinates")
            XCTAssertEqual(view.backForwardList.backList.count, 1)
            XCTAssertEqual(view.backForwardList.forwardList.count, 0)
        }
        state.navigateHistory(-1)
        state.send(.selectAll)
        let revision = state.command.revision
        coordinator.deliver(state.command, to: view)
        try await wait { state.command.revision > revision || state.error != nil }
        XCTAssertNil(state.error)
        XCTAssertTrue(coordinator.ready)
        coordinator.deliver(state.command, to: view)
        try await wait { state.hasSelection }
        let selected = try await state.selectionText()
        XCTAssertTrue(selected.contains("First document"))
        XCTAssertFalse(selected.contains("Second document"))
    }

    @MainActor
    func testPageLocationAndBoundaryTurnsReuseVisitedDocuments() async throws {
        let paragraphs = (0..<100).map { "Paragraph \($0) fills this document.\n\n" }.joined()
        let (state, coordinator, view) = try await reader([
            "A.md": "# First document\n\n" + paragraphs,
            "B.md": "# Second document\n\n" + paragraphs
        ], opened: "A.md")
        _ = try await evaluate("window.cacheMarker='first'", view)
        state.navigate(.page(1))
        try await completeCurrentCommand(state, coordinator, view)
        _ = try await evaluate("window.cacheMarker='second'", view)

        func navigate(_ action: ReaderAction, page: Int, atEnd: Bool = false, line: UInt = #line) async throws {
            state.navigate(action)
            try await completeCurrentCommand(state, coordinator, view, line: line)
            let displayed = try await evaluate("return {marker:window.cacheMarker, y:scrollY, end:document.documentElement.scrollHeight-innerHeight}", view) as? [String: Any]
            XCTAssertEqual(displayed?["marker"] as? String, page == 0 ? "first" : "second",
                           "Returning through a page command must preserve the visited document", line: line)
            XCTAssertEqual(state.page, page, line: line)
            XCTAssertEqual(view.backForwardList.backList.count, page, line: line)
            XCTAssertEqual(view.backForwardList.forwardList.count, 1 - page, line: line)
            if atEnd {
                XCTAssertEqual(try XCTUnwrap(displayed?["y"] as? Double), try XCTUnwrap(displayed?["end"] as? Double), accuracy: 2, line: line)
            }
        }
        try await navigate(.page(0), page: 0)
        try await navigate(.location("last"), page: 1, atEnd: true)
        try await navigate(.location("first"), page: 0)
        try await navigate(.location("2"), page: 1)
        _ = try await evaluate("scrollTo(0,0)", view)
        try await wait { (state.currentPosition.y ?? -1) == 0 }
        try await navigate(.turnPages(-1), page: 0, atEnd: true)
        try await navigate(.turnPages(1), page: 1)
    }

    @MainActor
    func testCurrentPageBridgeErrorsRemainVisible() async throws {
        let (state, coordinator, view) = try await reader(["book.md": "# Current page"], opened: "book.md")
        _ = try await evaluate("window.webkit.messageHandlers.leaf.postMessage({type:'error',message:'Current page failure'})", view)
        try await wait { state.error != nil }
        XCTAssertEqual(state.error, "Current page failure")
        XCTAssertTrue(coordinator.ready, "An action error must not discard a readable page")
    }

    @MainActor
    func testCommandQueuedDuringActivationRunsAfterReadiness() async throws {
        let (state, coordinator, view) = try await reader(["A.md": "# First\n\nReadable text."], opened: "A.md")
        _ = try await evaluate("""
            const original = window.leafCommand;
            window.activationEntered = new Promise(entered => {
                window.leafCommand = async command => {
                    if (command.name === 'activate') {
                        entered();
                        await new Promise(resolve => { window.releaseActivation = resolve; });
                    }
                    return await original(command);
                };
            });
            """, view)
        coordinator.ready = false
        coordinator.activateDocument(view)
        _ = try await evaluate("await window.activationEntered; return true", view)
        state.fontSize = 23
        state.send(.style)
        let command = state.command
        // The representable queues commands while activation awaits fonts.
        coordinator.command = command.revision
        coordinator.pending.append(command)
        state.send(.none)
        _ = try await evaluate("window.releaseActivation()", view)
        try await wait { (coordinator.ready && state.command.revision > command.revision) || state.error != nil }
        XCTAssertNil(state.error)
        XCTAssertTrue(coordinator.ready)
        XCTAssertTrue(coordinator.pending.isEmpty)
        let font = try await evaluate("return getComputedStyle(document.body).fontSize", view) as? String
        XCTAssertEqual(font, "23px")
        coordinator.deliver(state.command, to: view)
    }

    @MainActor
    func testCachedPagesReceiveCurrentSearchAndDoNotReviveClosedFind() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First\n\noldterm first. newterm first. newterm again.",
            "B.md": "# Second\n\noldterm second. newterm second."
        ], opened: "A.md")
        _ = try await evaluate("window.cacheMarker='first'", view)
        state.showFindPanel()
        state.send(.find("oldterm", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 2 }
        let fetches = try await evaluate("return performance.getEntriesByType('resource').filter(e => e.initiatorType === 'fetch' && new URL(e.name).pathname.startsWith('/entry/')).length", view) as? Int
        state.navigate(.href("leaf://book/entry/B.md"))
        try await completeCurrentCommand(state, coordinator, view)
        _ = try await evaluate("window.cacheMarker='second'", view)
        state.send(.find("newterm", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 3 && state.searchResults.allSatisfy { $0.target.contains("newterm") } }
        state.navigateHistory(-1)
        try await completeCurrentCommand(state, coordinator, view)
        let active = try await evaluate("""
            return {marker:window.cacheMarker,
                matches:[...(CSS.highlights.get('sumatra-find') || [])].map(range => range.toString()),
                currentStart:window.__sumatraFind.currentRange()?.startOffset,
                firstStart:document.querySelector('p').textContent.indexOf('newterm'),
                fetches:performance.getEntriesByType('resource').filter(e => e.initiatorType === 'fetch' && new URL(e.name).pathname.startsWith('/entry/')).length};
            """, view) as? [String: Any]
        XCTAssertEqual(active?["marker"] as? String, "first")
        XCTAssertEqual(active?["matches"] as? [String], ["newterm", "newterm"])
        XCTAssertEqual(active?["currentStart"] as? Int, try XCTUnwrap(active?["firstStart"] as? Int))
        XCTAssertEqual(active?["fetches"] as? Int, try XCTUnwrap(fetches), "Cache activation must not rescan sibling files")
        XCTAssertEqual(state.searchResults.count, 3)
        XCTAssertEqual(state.selectedSearchTarget, state.searchResults[0].target,
                       "Back must synchronize the selected global result with the restored current Range")
        XCTAssertEqual(state.searchCountText, "1 / 3")
        XCTAssertEqual(state.status, "1 / 3 matches")
        state.send(.find("newterm", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertEqual(state.selectedSearchTarget, state.searchResults[1].target)
        XCTAssertEqual(state.searchCountText, "2 / 3")
        XCTAssertEqual(state.status, "2 / 3 matches")
        let next = try await evaluate("""
            return {currentStart:window.__sumatraFind.currentRange()?.startOffset,
                secondStart:document.querySelector('p').textContent.lastIndexOf('newterm'),
                fetches:performance.getEntriesByType('resource').filter(e => e.initiatorType === 'fetch' && new URL(e.name).pathname.startsWith('/entry/')).length};
            """, view) as? [String: Any]
        XCTAssertEqual(next?["currentStart"] as? Int, try XCTUnwrap(next?["secondStart"] as? Int))
        XCTAssertEqual(next?["fetches"] as? Int, try XCTUnwrap(fetches))
        state.closeFind()
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.isEmpty }
        state.navigateHistory(1)
        try await completeCurrentCommand(state, coordinator, view)
        let closed = try await evaluate("return {marker:window.cacheMarker, matches:CSS.highlights.get('sumatra-find')?.size || 0}", view) as? [String: Any]
        XCTAssertEqual(closed?["marker"] as? String, "second")
        XCTAssertEqual(closed?["matches"] as? Int, 0)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNil(state.selectedSearchTarget)
    }

    @MainActor
    func testMarkdownZoomReflowsTextWithoutScalingImagesOrViewport() async throws {
        let (state, coordinator, view) = try await reader(["Book.md": """
            # Heading

            ![Diagram](pic.svg)

            A paragraph with ordinary words that wrap across the reading viewport. A paragraph with ordinary words that wrap across the reading viewport.
            """, "pic.svg": "<svg xmlns='http://www.w3.org/2000/svg' width='80' height='40'><rect width='80' height='40' fill='red'/></svg>"], opened: "Book.md")
        _ = try await evaluate("await document.querySelector('img').decode()", view)
        let geometry = """
            const p=document.querySelector('p:last-child'), range=document.createRange();range.selectNodeContents(p);
            return {font:parseFloat(getComputedStyle(document.body).fontSize),
                padding:parseFloat(getComputedStyle(document.body).paddingLeft),
                image:document.querySelector('img').getBoundingClientRect().width,
                viewport:innerWidth,lines:range.getClientRects().length};
            """
        let beforeValue = try await evaluate(geometry, view)
        let before = try XCTUnwrap(beforeValue as? [String: Double])
        state.setZoom(1.5)
        try await completeCurrentCommand(state, coordinator, view)
        let enlargedValue = try await evaluate(geometry, view)
        let enlarged = try XCTUnwrap(enlargedValue as? [String: Double])
        XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(enlarged["font"]), 25.5, accuracy: 0.01)
        XCTAssertEqual(enlarged["padding"], before["padding"])
        XCTAssertEqual(enlarged["image"], before["image"])
        XCTAssertEqual(enlarged["viewport"], before["viewport"])
        XCTAssertGreaterThan(try XCTUnwrap(enlarged["lines"]), try XCTUnwrap(before["lines"]))
        state.fontSize = 20; state.send(.style)
        try await completeCurrentCommand(state, coordinator, view)
        let resizedValue = try await evaluate(geometry, view)
        let resized = try XCTUnwrap(resizedValue as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(resized["font"]), 30, accuracy: 0.01)
        state.setZoom(1)
        try await completeCurrentCommand(state, coordinator, view)
        let restoredValue = try await evaluate(geometry, view)
        let restored = try XCTUnwrap(restoredValue as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(restored["font"]), 20, accuracy: 0.01)
    }

    @MainActor
    func testMarkdownTextZoomKeepsTheReadingPassageAndSelection() async throws {
        let paragraphs = (0..<180).map { "Paragraph \($0). " + String(repeating: "Surrounding words wrap across the reading viewport. ", count: 12) }.joined(separator: "\n\n")
        let (state, coordinator, view) = try await reader(["Book.md": paragraphs], opened: "Book.md")
        _ = try await evaluate("""
            const p=document.querySelectorAll('p')[90];
            window.scrollTo({top:p.getBoundingClientRect().top+scrollY,behavior:'instant'});
            const r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,12);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """, view)
        let before = try await evaluate("return document.querySelectorAll('p')[90].getBoundingClientRect().top", view) as? Double
        state.setZoom(1.5)
        try await completeCurrentCommand(state, coordinator, view)
        let after = try await evaluate("return document.querySelectorAll('p')[90].getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 2,
            "Changing text size must keep the same passage at the reading position")
        state.fontSize = 20; state.send(.style)
        try await completeCurrentCommand(state, coordinator, view)
        let restyled = try await evaluate("return document.querySelectorAll('p')[90].getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(restyled), try XCTUnwrap(after), accuracy: 2,
            "The font-size setting must preserve the passage too")
        let selected = try await evaluate("return getSelection().toString()", view) as? String
        XCTAssertEqual(selected, "Paragraph 90")
        let scrolled = try await evaluate("""
            const fonts=document.fonts;let release;
            Object.defineProperty(fonts,'ready',{configurable:true,value:new Promise(resolve=>release=resolve)});
            try {
                const pending=window.leafCommand({name:'zoom',number:1,zoom:1,text:'system|31|1.6|32|light'});
                window.scrollBy({top:300,behavior:'instant'});const requested=scrollY;
                release();await pending;return [requested,scrollY];
            } finally {release();delete fonts.ready}
            """, view) as? [Double]
        let coordinates = try XCTUnwrap(scrolled)
        XCTAssertEqual(coordinates[0], coordinates[1], accuracy: 1,
            "A scroll during font loading must take precedence over the earlier reading anchor")
    }

    @MainActor
    func testMarkdownShrinkingTypographyKeepsPassageAfterAutomaticScrollClamp() async throws {
        let paragraphs = (0..<180).map { "Paragraph \($0). " + String(repeating: "Surrounding words wrap across the reading viewport. ", count: 12) }.joined(separator: "\n\n")
        let (state, coordinator, view) = try await reader(["Book.md": paragraphs], opened: "Book.md", position: .init(zoom: 1))
        try await completeCurrentCommand(state, coordinator, view)
        for zoom in [true, false] {
            if zoom { state.setZoom(4) }
            else { state.fontSize = 68; state.send(.style) }
            try await completeCurrentCommand(state, coordinator, view)
            let beforeValue = try await evaluate("""
                const p=document.querySelectorAll('p')[90];
                scrollTo({top:p.getBoundingClientRect().top+scrollY,behavior:'instant'});
                window.shrinkAnchor=document.caretRangeFromPoint(40,1);window.shrinkAnchor.collapse(true);
                const r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,12);
                getSelection().removeAllRanges();getSelection().addRange(r);
                return {top:window.shrinkAnchor.getBoundingClientRect().top,y:scrollY,
                    remaining:document.documentElement.scrollHeight-document.documentElement.clientHeight-scrollY};
                """, view)
            let before = try XCTUnwrap(beforeValue as? [String: Double])
            XCTAssertGreaterThan(try XCTUnwrap(before["remaining"]), 1, "The control must start away from the true end")
            if zoom { state.setZoom(1) }
            else { state.fontSize = 17; state.send(.style) }
            try await completeCurrentCommand(state, coordinator, view)
            let afterValue = try await evaluate("""
                return {top:window.shrinkAnchor.getBoundingClientRect().top,y:scrollY,
                    maximum:document.documentElement.scrollHeight-document.documentElement.clientHeight};
                """, view)
            let after = try XCTUnwrap(afterValue as? [String: Double])
            let beforeTop = try XCTUnwrap(before["top"]), afterTop = try XCTUnwrap(after["top"])
            let desired = try XCTUnwrap(after["y"]) + afterTop - beforeTop
            XCTAssertGreaterThan(try XCTUnwrap(before["y"]), try XCTUnwrap(after["maximum"]),
                "Shrinking this non-end passage must require an automatic scroll clamp")
            XCTAssertGreaterThanOrEqual(desired, 0)
            XCTAssertLessThan(desired, try XCTUnwrap(after["maximum"]), "The same passage remains reachable after shrinking")
            XCTAssertEqual(afterTop, beforeTop, accuracy: 2,
                "A layout clamp must not replace the reading passage with the document end (zoom: \(zoom))")
            let selected = try await evaluate("return getSelection().toString()", view) as? String
            XCTAssertEqual(selected, "Paragraph 90")
            XCTAssertEqual(view.pageZoom, 1)
        }
        let scrolled = try await evaluate("""
            await window.leafCommand({name:'style',text:'system|68|1.6|32|light',zoom:1});
            const p=document.querySelectorAll('p')[90];scrollTo({top:p.getBoundingClientRect().top+scrollY,behavior:'instant'});
            const fonts=document.fonts;let release,waiting=false;
            const loading=new Promise(resolve=>release=resolve);
            Object.defineProperty(fonts,'ready',{configurable:true,get(){waiting=true;return loading}});
            try {
                const old=scrollY,pending=window.leafCommand({name:'style',text:'system|17|1.6|32|light',zoom:1});
                const deadline=Date.now()+1000;
                while(!waiting && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,0));
                if(!waiting)throw Error('Typography did not wait for fonts');
                const clamped=scrollY;scrollTo({top:clamped/2,behavior:'instant'});const requested=scrollY;
                release();await pending;return {old,clamped,requested,final:scrollY};
            } finally {release?.();delete fonts.ready}
            """, view)
        let coordinates = try XCTUnwrap(scrolled as? [String: Double])
        XCTAssertGreaterThan(try XCTUnwrap(coordinates["old"]), try XCTUnwrap(coordinates["clamped"]))
        XCTAssertEqual(try XCTUnwrap(coordinates["requested"]), try XCTUnwrap(coordinates["final"]), accuracy: 1,
            "A later scroll during font loading must still win after an automatic clamp")
    }

    @MainActor
    func testMarkdownTypographyKeepsTrueEndAndRespectsLaterScroll() async throws {
        let paragraphs = (0..<180).map { "Paragraph \($0). " + String(repeating: "Surrounding words wrap across the reading viewport. ", count: 12) }.joined(separator: "\n\n")
        let (state, coordinator, view) = try await reader(["Book.md": paragraphs + "\n\nUnique final suffix."], opened: "Book.md")
        state.userCSS = "html{overflow:scroll}::-webkit-scrollbar{width:30px;height:30px}body{min-width:1200px}"
        state.send(.style)
        try await completeCurrentCommand(state, coordinator, view)
        _ = try await evaluate("""
            const p=document.querySelector('p:last-child'),r=document.createRange();r.selectNodeContents(p);
            getSelection().removeAllRanges();getSelection().addRange(r);
            scrollTo({left:50,top:document.documentElement.scrollHeight,behavior:'instant'});
            """, view)
        try await wait { (state.currentPosition.y ?? 0) > 0 }
        let geometry = """
            const root=document.documentElement;
            return {remaining:root.scrollHeight-root.clientHeight-scrollY,x:scrollX,
                scrollbar:innerHeight-root.clientHeight};
            """
        for action in 0..<3 {
            if action == 0 { state.setZoom(1.5) }
            else if action == 1 { state.fontSize = 20; state.send(.style) }
            else { state.setZoom(1) }
            try await completeCurrentCommand(state, coordinator, view)
            let value = try await evaluate(geometry, view)
            let actual = try XCTUnwrap(value as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(actual["remaining"]), 0, accuracy: 1,
                "A reader at the true end must stay there when typography grows or shrinks")
            XCTAssertEqual(actual["scrollbar"], 30)
            XCTAssertEqual(actual["x"], 50)
            let selected = try await evaluate("return getSelection().toString()", view) as? String
            XCTAssertEqual(selected, "Unique final suffix.")
            XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
        }
        let beforeValue = try await evaluate("""
            const root=document.documentElement;
            scrollTo({left:50,top:root.scrollHeight-root.clientHeight-15,behavior:'instant'});
            window.typographyAnchor=document.caretRangeFromPoint(40,1);
            return {top:window.typographyAnchor.getBoundingClientRect().top,
                remaining:root.scrollHeight-root.clientHeight-scrollY};
            """, view)
        let before = try XCTUnwrap(beforeValue as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(before["remaining"]), 15, accuracy: 1)
        state.fontSize = 21; state.send(.style)
        try await completeCurrentCommand(state, coordinator, view)
        let afterValue = try await evaluate("""
            return {top:window.typographyAnchor.getBoundingClientRect().top,
                remaining:document.documentElement.scrollHeight-document.documentElement.clientHeight-scrollY};
            """, view)
        let after = try XCTUnwrap(afterValue as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(after["top"]), try XCTUnwrap(before["top"]), accuracy: 2)
        XCTAssertGreaterThan(try XCTUnwrap(after["remaining"]), 1,
            "Classic scrollbar space must not classify a near-end passage as the true end")
        let scrolled = try await evaluate("""
            scrollTo({top:document.documentElement.scrollHeight,behavior:'instant'});
            const fonts=document.fonts;let release,waiting=false;
            const loading=new Promise(resolve=>release=resolve);
            Object.defineProperty(fonts,'ready',{configurable:true,get(){waiting=true;return loading}});
            try {
                const pending=window.leafCommand({name:'style',text:'system|22|1.6|32|light',zoom:1});
                const deadline=Date.now()+1000;
                while(!waiting && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,0));
                if(!waiting)throw Error('Typography did not wait for fonts');
                scrollBy({top:-300,behavior:'instant'});const requested=scrollY;
                release();await pending;return [requested,scrollY];
            } finally {release();delete fonts.ready}
            """, view) as? [Double]
        let coordinates = try XCTUnwrap(scrolled)
        XCTAssertEqual(coordinates[0], coordinates[1], accuracy: 1,
            "A later scroll during font loading must win over the earlier end position")
    }

    @MainActor
    func testMarkdownResizeKeepsTheReadingPassageAndSelection() async throws {
        let paragraphs = (0..<180).map { "Paragraph \($0). " + String(repeating: "Surrounding words wrap across the reading viewport. ", count: 12) }.joined(separator: "\n\n")
        let (state, _, view) = try await reader(["Book.md": paragraphs], opened: "Book.md")
        _ = try await evaluate("""
            const p=document.querySelectorAll('p')[90];
            scrollTo({top:p.getBoundingClientRect().top+scrollY,behavior:'instant'});
            const r=document.createRange();r.setStart(p.firstChild,0);r.setEnd(p.firstChild,12);
            getSelection().removeAllRanges();getSelection().addRange(r);
            """, view)
        try await wait { (state.currentPosition.y ?? 0) > 0 }
        let before = try await evaluate("return document.querySelectorAll('p')[90].getBoundingClientRect().top", view) as? Double
        view.setFrameSize(NSSize(width: 440, height: 500))
        _ = try await evaluate("await new Promise(resolve=>setTimeout(resolve,40))", view)
        let narrowed = try await evaluate("return document.querySelectorAll('p')[90].getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(narrowed), try XCTUnwrap(before), accuracy: 2,
            "Opening a sidebar must preserve the reading passage")
        view.setFrameSize(NSSize(width: 700, height: 500))
        _ = try await evaluate("await new Promise(resolve=>setTimeout(resolve,40))", view)
        let widened = try await evaluate("return document.querySelectorAll('p')[90].getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(widened), try XCTUnwrap(before), accuracy: 2,
            "Closing the sidebar must preserve the reading passage too")
        let selected = try await evaluate("return getSelection().toString()", view) as? String
        XCTAssertEqual(selected, "Paragraph 90")
    }

    @MainActor
    func testMarkdownResizeKeepsTheEndAndFindDestination() async throws {
        let paragraphs = (0..<180).map { "Paragraph \($0). " + String(repeating: "Surrounding words wrap across the reading viewport. ", count: 12) }.joined(separator: "\n\n")
        let (state, _, view) = try await reader(["Book.md": paragraphs + "\n\nUnique final suffix."], opened: "Book.md")
        _ = try await evaluate("scrollTo({top:document.documentElement.scrollHeight,behavior:'instant'})", view)
        try await wait { (state.currentPosition.y ?? 0) > 0 }
        _ = try await evaluate("await window.leafCommand({name:'location',text:'last'})", view)
        for width in [440.0, 700.0] {
            view.setFrameSize(NSSize(width: width, height: 500))
            _ = try await evaluate("await new Promise(resolve=>setTimeout(resolve,40))", view)
            let remaining = try await evaluate("return document.documentElement.scrollHeight-innerHeight-scrollY", view) as? Double
            XCTAssertEqual(try XCTUnwrap(remaining), 0, accuracy: 1,
                "A reader already at the document end must remain there after resizing")
        }
        view.setFrameSize(NSSize(width: 440, height: 500))
        _ = try await evaluate("await window.leafCommand({name:'find',text:'Paragraph 20.'});await new Promise(resolve=>setTimeout(resolve,40))", view)
        let matched = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
        XCTAssertEqual(matched, "Paragraph 20.")
        let foundTop = try await evaluate("return window.__sumatraFind.currentRange()?.getBoundingClientRect().top", view) as? Double
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(foundTop), -1)
        XCTAssertLessThan(try XCTUnwrap(foundTop), 500,
            "An explicit Find destination must take precedence over the old reading anchor")
        _ = try await evaluate("await window.leafCommand({name:'find',text:'Paragraph 20.'})", view)
        view.setFrameSize(NSSize(width: 700, height: 500))
        _ = try await evaluate("await new Promise(resolve=>setTimeout(resolve,40))", view)
        let repeatedTop = try await evaluate("return window.__sumatraFind.currentRange()?.getBoundingClientRect().top", view) as? Double
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(repeatedTop), -1)
        XCTAssertLessThan(try XCTUnwrap(repeatedTop), 500,
            "A repeated Find with no scroll event must still preserve its reading passage on resize")
    }

    @MainActor
    func testMarkdownResizeDistinguishesTheEndFromScrollbarSpace() async throws {
        let css = "html{overflow:scroll}::-webkit-scrollbar{width:30px;height:30px}body{min-width:1200px}p{height:50px;margin:0}"
        let paragraphs = (0..<40).map { "Paragraph \($0) with a fixed height." }.joined(separator: "\n\n")
        let (state, coordinator, view) = try await reader(["Book.md": paragraphs], opened: "Book.md")
        state.userCSS = css; state.send(.style)
        try await completeCurrentCommand(state, coordinator, view)
        let beforeValue = try await evaluate("""
            const root=document.documentElement;
            scrollTo({left:50,top:root.scrollHeight-root.clientHeight-15,behavior:'instant'});
            return {y:scrollY,x:scrollX,remaining:root.scrollHeight-root.clientHeight-scrollY,
                scrollbar:innerHeight-root.clientHeight};
            """, view)
        let before = try XCTUnwrap(beforeValue as? [String: Double])
        XCTAssertEqual(before["scrollbar"], 30, "The control must have a classic horizontal scrollbar")
        XCTAssertEqual(try XCTUnwrap(before["remaining"]), 15, accuracy: 1)
        try await wait { (state.currentPosition.y ?? 0) > 0 }
        view.setFrameSize(NSSize(width: 600, height: 450))
        _ = try await evaluate("await new Promise(resolve=>setTimeout(resolve,40))", view)
        let afterValue = try await evaluate("return {y:scrollY,x:scrollX,remaining:document.documentElement.scrollHeight-document.documentElement.clientHeight-scrollY}", view)
        let after = try XCTUnwrap(afterValue as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(after["y"]), try XCTUnwrap(before["y"]), accuracy: 2,
            "Scrollbar space must not classify a near-end reading passage as the actual end")
        XCTAssertEqual(after["x"], before["x"])
        XCTAssertGreaterThan(try XCTUnwrap(after["remaining"]), 15)
        _ = try await evaluate("await window.leafCommand({name:'location',text:'last'})", view)
        view.setFrameSize(NSSize(width: 700, height: 480))
        _ = try await evaluate("await new Promise(resolve=>setTimeout(resolve,40))", view)
        let remaining = try await evaluate("return document.documentElement.scrollHeight-document.documentElement.clientHeight-scrollY", view) as? Double
        XCTAssertEqual(try XCTUnwrap(remaining), 0, accuracy: 1,
            "A reader at the real end must still remain there with classic scrollbars")
    }

    @MainActor
    func testHTMLZoomKeepsWholePageScaling() async throws {
        let (state, coordinator, view) = try await reader(["Book.html": "<p>Ordinary HTML text.</p>"], opened: "Book.html")
        state.setZoom(1.5)
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertEqual(view.pageZoom, 1.5, accuracy: 0.001)
        let font = try await evaluate("return parseFloat(getComputedStyle(document.body).fontSize)", view) as? Double
        XCTAssertEqual(try XCTUnwrap(font), 17, accuracy: 0.01)
        let completed = try await evaluate("""
            const fonts=document.fonts;let release,finished=false;
            Object.defineProperty(fonts,'ready',{configurable:true,value:new Promise(resolve=>release=resolve)});
            try {
                const pending=window.leafCommand({name:'zoom',number:1.5,zoom:1.5,text:'system|17|1.6|32|light'}).then(()=>finished=true);
                await new Promise(resolve=>setTimeout(resolve,0));const completedBeforeFonts=finished;
                release();await pending;return completedBeforeFonts;
            } finally {release();delete fonts.ready}
            """, view) as? Bool
        XCTAssertEqual(completed, true, "HTML page zoom must not wait for unrelated webfont loading")
    }

    @MainActor
    func testCachedRestoreAppliesCurrentStyleAndRequestedCoordinatesOrFragment() async throws {
        let paragraphs = (0..<80).map { "Paragraph \($0) of the surrounding text.\n\n" }.joined()
        let anchor = "leaf://book/entry/A.md#middle"
        let (state, coordinator, view) = try await reader([
            "A.md": "# First\n\n[Link](#middle \"Authored tooltip\")\n\n" + paragraphs + "## Middle\n\n" + paragraphs,
            "B.md": "# Second\n\n" + paragraphs
        ], opened: "A.md", position: .init(page: 0, x: 0, y: 5, anchor: anchor))
        let initialTop = try await evaluate("return document.getElementById('middle').getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(initialTop), 0, accuracy: 2, "An initial fragment must take precedence over x/y")
        try await completeCurrentCommand(state, coordinator, view)
        _ = try await evaluate("window.cacheMarker='first'", view)
        state.navigate(.href("leaf://book/entry/B.md"))
        try await completeCurrentCommand(state, coordinator, view)
        state.restore(.init(page: 0, x: 0, y: 430, anchor: "leaf://book/entry/A.md",
                            zoom: 1.3, fontSize: 23, theme: "light", userCSS: "p { letter-spacing:3px }"))
        state.hoverPreview = false
        try await completeCurrentCommand(state, coordinator, view)
        let restored = try await evaluate("""
            const link = document.querySelector('a[href]');
            link.dispatchEvent(new PointerEvent('pointerover', {bubbles:true}));
            return {marker:window.cacheMarker, y:scrollY, font:getComputedStyle(document.body).fontSize,
                spacing:getComputedStyle(document.querySelector('p')).letterSpacing,
                fontsReady:document.fonts.status === 'loaded', title:link.title};
            """, view) as? [String: Any]
        XCTAssertEqual(restored?["marker"] as? String, "first")
        XCTAssertEqual(try XCTUnwrap(restored?["y"] as? Double), 430, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(Double((restored?["font"] as? String ?? "").replacingOccurrences(of: "px", with: ""))), 23 * 1.3, accuracy: 0.01)
        XCTAssertEqual(restored?["spacing"] as? String, "3px")
        XCTAssertEqual(restored?["fontsReady"] as? Bool, true)
        XCTAssertEqual(restored?["title"] as? String, "Authored tooltip", "Cache activation must apply the current interaction flags")
        XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
        state.restore(.init(page: 0, x: 0, y: 5, anchor: anchor))
        try await completeCurrentCommand(state, coordinator, view)
        let headingTop = try await evaluate("return document.getElementById('middle').getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(headingTop), 0, accuracy: 2)
    }

    @MainActor
    func testFragmentRestoreWaitsForFontsBeforeAcknowledgingTheNextCommand() async throws {
        let paragraphs = (0..<80).map { "Paragraph \($0) of the surrounding text.\n\n" }.joined()
        let (state, coordinator, view) = try await reader([
            "Book.md": "# Title\n\n" + paragraphs + "## Middle\n\n" + paragraphs
        ], opened: "Book.md")
        _ = try await evaluate("""
            const pendingFonts = new Promise(resolve => { window.finishFontLoading = resolve; });
            Object.defineProperty(document.fonts, 'ready', {configurable:true, get() {
                window.waitingForFonts = true; return pendingFonts;
            }});
            """, view)
        state.restore(.init(page: 0, x: 0, y: 5, anchor: "leaf://book/entry/Book.md#middle", fontSize: 23))
        let command = state.command
        state.send(.selectAll)
        coordinator.deliver(command, to: view)
        _ = try await evaluate("""
            const deadline = Date.now()+15000;
            while (!window.waitingForFonts && Date.now()<deadline) await new Promise(resolve => setTimeout(resolve, 0));
            if (!window.waitingForFonts) throw Error('Restoration did not wait for fonts');
            return true;
            """, view)
        XCTAssertEqual(state.command.revision, command.revision, "Font loading must retain the restoration command")
        XCTAssertFalse(state.hasSelection)
        _ = try await evaluate("delete document.fonts.ready; window.finishFontLoading()", view)
        try await wait { state.command.revision > command.revision || state.error != nil }
        XCTAssertNil(state.error)
        let top = try await evaluate("return document.getElementById('middle').getBoundingClientRect().top", view) as? Double
        XCTAssertEqual(try XCTUnwrap(top), 0, accuracy: 2)
        coordinator.deliver(state.command, to: view)
        try await wait { state.hasSelection }
        let selected = try await state.selectionText()
        XCTAssertTrue(selected.contains("Middle"))
    }

    @MainActor
    func testSearchAcrossFilesReusesResultsAndContinuesFromTheChosenMatch() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First\n\nneedle one. needle two.", "B.md": "# Second\n\nneedle three. needle four."
        ], opened: "A.md")
        _ = try await evaluate("await window.leafCommand({name:'find',text:'needle'})", view)
        try await wait { state.searchResults.count == 4 }
        let target = state.searchResults[2].target
        state.navigate(.href(target))
        coordinator.deliver(state.command, to: view)
        try await wait { coordinator.ready && view.url?.path.hasSuffix("B.md") == true && state.selectedSearchTarget == target }
        XCTAssertEqual(state.searchResults.count, 4)
        let fetchedBooks = try await evaluate("return performance.getEntriesByType('resource').filter(e => e.initiatorType === 'fetch' && new URL(e.name).pathname.startsWith('/entry/')).length", view) as? Int
        XCTAssertEqual(fetchedBooks, 0, "A result jump must only rebuild current-page highlights, not fetch every file again")
        XCTAssertEqual(state.status, "3 / 4 matches", "The restored hit status must agree with the selected global result")
        _ = try await evaluate("await window.leafCommand({name:'find',text:'needle'})", view)
        try await wait { state.selectedSearchTarget == state.searchResults.last?.target }
        _ = try await evaluate("await window.leafCommand({name:'find',text:'three'})", view)
        try await wait { state.searchResults.count == 1 }
        XCTAssertTrue(state.searchResults[0].title.contains("three"))
    }

    @MainActor
    func testHTMLSearchAndWholeDocumentTextKeepDeclaredEncodingsAndBOM() async throws {
        let utf16 = try XCTUnwrap("<meta charset='windows-1252'><p>测试 café</p>".data(using: .utf16LittleEndian))
        let utf16BE = try XCTUnwrap("<meta charset='windows-1252'><p>测试 café</p>".data(using: .utf16BigEndian))
        let unlabeledText = try XCTUnwrap(String(data: Data("测试 café 😀".utf8), encoding: .windowsCP1252))
        let cases: [(String, String, Data)] = [
            ("windows-1252", "café", Data("<meta charset='windows-1252'><p>caf".utf8) + Data([0xe9]) + Data("</p>".utf8)),
            ("gbk", "测试", Data("<meta http-equiv='content-type' content='text/html; charset=gbk'><p>".utf8) + Data([0xb2, 0xe2, 0xca, 0xd4]) + Data("</p>".utf8)),
            ("UTF-16 BOM", "测试 café", Data([0xff, 0xfe]) + utf16),
            ("UTF-16 BE BOM", "测试 café", Data([0xfe, 0xff]) + utf16BE),
            ("UTF-8 BOM", "测试 café", Data([0xef, 0xbb, 0xbf]) + Data("<meta charset='windows-1252'><p>测试 café</p>".utf8)),
            ("unlabeled UTF-8 bytes use the HTML fallback", unlabeledText, Data("<p>测试 café 😀</p>".utf8)),
            ("unlabeled windows-1252", "café", Data("<p>caf".utf8) + Data([0xe9]) + Data("</p>".utf8))
        ]
        for (label, text, bytes) in cases {
            let (state, coordinator, view) = try await reader([
                "A.html": "<meta charset='utf-8'><p>\(text)</p>", "B.html": ""
            ], opened: "A.html", encodedFiles: ["B.html": bytes])
            let fullText = try await evaluate("return await window.leafText(true)", view) as? String
            XCTAssertEqual(fullText, text + "\n\n" + text, label)
            _ = try await view.callAsyncJavaScript("await window.leafCommand({name:'find',text:term})",
                arguments: ["term": text], in: nil, contentWorld: .world(name: "SumraMarkup"))
            try await wait { !state.searchCounting && !state.searchResults.isEmpty }
            XCTAssertEqual(state.searchResults.count, 2, label)
            XCTAssertTrue(state.searchResults.contains { $0.target.contains("/entry/B.html#") }, label)
            state.navigate(.href("leaf://book/entry/B.html"))
            try await completeCurrentCommand(state, coordinator, view)
            let liveText = try await evaluate("return document.body.textContent", view) as? String
            let fullTextAfterNavigation = try await evaluate("return await window.leafText(true)", view) as? String
            XCTAssertEqual(liveText, text, label)
            XCTAssertEqual(fullTextAfterNavigation, text + "\n\n" + text, label)
            XCTAssertNil(state.error, label)
        }
    }

    @MainActor
    func testHTMLDeclaredUTF16WithoutBOMKeepsLiveUTF8Text() async throws {
        let text = "测试 café 😀"
        let (state, coordinator, view) = try await reader([
            "A.html": "<meta charset='utf-8'><p>\(text)</p>",
            "B.html": "<meta charset='utf-16'><p>\(text)</p>"
        ], opened: "A.html")
        let fullText = try await evaluate("return await window.leafText(true)", view) as? String
        XCTAssertEqual(fullText, text + "\n\n" + text)
        state.navigate(.href("leaf://book/entry/B.html"))
        try await completeCurrentCommand(state, coordinator, view)
        let liveText = try await evaluate("return document.body.textContent", view) as? String
        XCTAssertEqual(liveText, text)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSupersededHTMLSearchSkipsDecodingAnAlreadyReceivedBody() async throws {
        let (state, _, view) = try await reader([
            "A.html": "<meta charset='utf-8'><p>needle here.</p>",
            "B.html": "<meta charset='utf-8'><p>replacement here.</p>"
        ], opened: "A.html")
        let outcome = try await evaluate("""
            const originalFetch=window.fetch, originalParse=DOMParser.prototype.parseFromString;
            let started, releaseBody, signal, intercepted=false, obsoleteParses=0;
            const pending=new Promise(resolve=>{started=resolve});
            DOMParser.prototype.parseFromString=function(text,type){
                if(text.includes('obsolete encoded body'))obsoleteParses++;
                return originalParse.call(this,text,type);
            };
            window.fetch=async(url,options)=>{
                if(!intercepted&&new URL(url,location.href).pathname.endsWith('/B.html')){
                    intercepted=true;signal=options?.signal;
                    const body=bytes=>{started();return new Promise(resolve=>{
                        releaseBody=()=>resolve(bytes?new TextEncoder().encode('<meta charset="utf-8"><p>obsolete encoded body</p>').buffer:'<p>obsolete encoded body</p>');
                    })};
                    return {ok:true,headers:new Headers({'content-type':'text/html'}),
                        text:()=>body(false),arrayBuffer:()=>body(true)};
                }
                return originalFetch(url,options);
            };
            try{
                const old=window.leafCommand({name:'find',text:'needle'});
                await pending;await window.leafCommand({name:'find',text:'replacement'});
                const aborted=signal?.aborted===true;releaseBody();await old;
                return {aborted,obsoleteParses};
            }finally{window.fetch=originalFetch;DOMParser.prototype.parseFromString=originalParse}
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["aborted"] as? Bool, true)
        XCTAssertEqual(outcome?["obsoleteParses"] as? Int, 0)
        try await wait { !state.searchResults.isEmpty && !state.searchCounting }
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertTrue(state.searchResults[0].title.contains("replacement here"))
        XCTAssertNil(state.error)
    }

    @MainActor
    func testGlobalSearchStopsSiblingScanningAtRemainingResultBudget() async throws {
        let siblingParagraph = "<p>needle " + String(repeating: "B", count: 96) + ".</p>"
        let (state, _, view) = try await reader([
            "A.html": "<p>" + String(repeating: "needle ", count: 4999) + "</p>",
            "B.html": "<body id='remaining-budget'>" + String(repeating: siblingParagraph, count: 6000) + "</body>",
            "C.html": "<p>needle in a later file</p>"
        ], opened: "A.html")
        let outcome = try await evaluate("""
            const createWalker = Document.prototype.createTreeWalker, fetchPage = window.fetch;
            let visited = 0, fetched = [];
            Document.prototype.createTreeWalker = function(...args) {
                const walker = createWalker.apply(this, args);
                if (this.body?.id === 'remaining-budget') {
                    const next = walker.nextNode.bind(walker);
                    walker.nextNode = () => { visited++; return next(); };
                }
                return walker;
            };
            window.fetch = (url, ...args) => {
                const path = new URL(url, location.href).pathname;
                if (path.startsWith('/entry/')) fetched.push(path);
                return fetchPage(url, ...args);
            };
            try {
                await window.leafCommand({name:'find', text:'needle'});
                return {visited, fetched};
            } finally {
                Document.prototype.createTreeWalker = createWalker; window.fetch = fetchPage;
            }
            """, view) as? [String: Any]
        try await wait { state.searchResults.count == 5000 && state.searchCountCapped }
        XCTAssertEqual(state.searchCountText, "1 / 5000+")
        XCTAssertEqual(outcome?["fetched"] as? [String], ["/entry/B.html"])
        XCTAssertGreaterThan(outcome?["visited"] as? Int ?? 0, 0)
        XCTAssertLessThan(outcome?["visited"] as? Int ?? 6000, 1000,
            "A sibling with one remaining result must stop after bounded context, not scan thousands of unused matches")
        let last = try XCTUnwrap(state.searchResults.last)
        XCTAssertEqual(last.title, "needle " + String(repeating: "B", count: 39) + "...")
        let target = try XCTUnwrap(URLComponents(string: last.target))
        let fragment = try XCTUnwrap(target.fragment)
        XCTAssertTrue(fragment.hasPrefix("sumra-search="))
        let match = try JSONSerialization.jsonObject(with: Data(fragment.dropFirst("sumra-search=".count).utf8)) as? [String: Any]
        XCTAssertEqual(target.path, "/entry/B.html")
        XCTAssertEqual(match?["index"] as? Int, 0)
        XCTAssertEqual(match?["text"] as? String, "needle")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testGlobalSearchCapSurvivesResultJumpsAndCachedBackWithoutRescanning() async throws {
        let (state, coordinator, view) = try await reader([
            "A.html": "<p>" + String(repeating: "needle ", count: 2000) + "rare</p>",
            "B.html": "<p>" + String(repeating: "needle ", count: 4000) + "</p>",
            "C.html": "<p>" + String(repeating: "needle ", count: 100) + "</p>"
        ], opened: "A.html")
        let trackFetches = """
            window.searchFetches = [];
            const originalFetch = window.fetch;
            window.fetch = (url, ...args) => {
                const path = new URL(url, location.href).pathname;
                if (path.startsWith('/entry/')) window.searchFetches.push(path);
                return originalFetch(url, ...args);
            };
            """
        _ = try await evaluate(trackFetches + "window.cacheMarker='first'", view)
        state.showFindPanel(); state.findQuery = "needle"
        state.send(.find("needle", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 5000 && state.selectedSearchTarget != nil && state.status == "1 / 5000+ matches" }
        XCTAssertTrue(state.searchCountCapped)
        XCTAssertEqual(state.searchCountText, "1 / 5000+")
        XCTAssertEqual(state.status, "1 / 5000+ matches")
        let fetched = try await evaluate("return window.searchFetches", view) as? [String]
        XCTAssertEqual(fetched, ["/entry/B.html"], "Once the global boundary is reached, later files must remain unscanned")

        let target = state.searchResults[2500].target
        state.navigate(.href(target))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { view.url?.path.hasSuffix("B.html") == true && state.selectedSearchTarget == target && state.status == "2501 / 5000+ matches" }
        XCTAssertEqual(state.searchCountText, "2501 / 5000+")
        XCTAssertEqual(state.status, "2501 / 5000+ matches", "An uncapped local page must retain the global cap")
        state.send(.find("needle", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertEqual(state.searchCountText, "2502 / 5000+")
        state.send(.find("needle", backwards: true))
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertEqual(state.searchCountText, "2501 / 5000+")
        state.navigateHistory(-1)
        try await completeCurrentCommand(state, coordinator, view)
        let marker = try await evaluate("return window.cacheMarker", view) as? String
        XCTAssertEqual(marker, "first")
        XCTAssertEqual(state.searchCountText, "1 / 5000+")
        XCTAssertEqual(state.status, "1 / 5000+ matches")
        let returnedFetches = try await evaluate("return window.searchFetches", view) as? [String]
        XCTAssertEqual(returnedFetches, fetched)
        state.findQuery = "rare"; state.send(.find("rare", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 1 && state.selectedSearchTarget != nil && state.status == "1 / 1 matches" }
        XCTAssertFalse(state.searchCountCapped)
        XCTAssertEqual(state.searchCountText, "1 / 1")
        XCTAssertEqual(state.status, "1 / 1 matches")
        state.closeFind()
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertFalse(state.searchCountCapped)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testFullTextAndSiblingSearchAgreeWithLiveCrossNodeMatches() async throws {
        let page = "<!doctype html><p>Emoji &#x1F600; <span>NEED</span><em>le</em></p>"
            + "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>Visible SVG</text>"
            + "<style>hidden style</style><script>hidden script</script></svg>"
            + "<noscript>hidden noscript</noscript><textarea>hidden textarea</textarea>"
        let (state, coordinator, view) = try await reader(["A.html": page, "B.html": page], opened: "A.html")
        let extracted = try await evaluate("return await window.leafText(true)", view) as? String
        XCTAssertEqual(extracted, "Emoji 😀 NEEDleVisible SVG\n\nEmoji 😀 NEEDleVisible SVG")

        _ = try await evaluate("await window.leafCommand({name:'find',text:'needle'})", view)
        try await wait { state.searchResults.count == 2 }
        XCTAssertTrue(state.searchResults.allSatisfy { $0.title.contains("Emoji 😀 NEEDle") })
        let live = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
        XCTAssertEqual(live, "NEEDle")

        let sibling = state.searchResults[1].target
        state.navigate(.href(sibling))
        coordinator.deliver(state.command, to: view)
        try await wait { coordinator.ready && view.url?.path.hasSuffix("B.html") == true && state.selectedSearchTarget == sibling }
        let restored = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
        XCTAssertEqual(restored, "NEEDle")
        let extractedAfterNavigation = try await evaluate("return await window.leafText(true)", view) as? String
        XCTAssertEqual(extractedAfterNavigation, extracted)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testClosingFindCanInterruptTheCurrentPageTextScan() async throws {
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            const hidden = document.createElement('div'); hidden.style.display = 'none';
            const nodes = Array.from({length:64}, () => document.createTextNode('x'.repeat(65536)));
            hidden.append(...nodes); document.body.replaceChildren(hidden);
            const data = Object.getOwnPropertyDescriptor(CharacterData.prototype, 'data');
            let lateReads = 0, closedBeforeCompletion = false, finished = false;
            Object.defineProperty(nodes.at(-1), 'data', {get() { lateReads++; return data.get.call(this) }});
            const clock = Object.getOwnPropertyDescriptor(performance, 'now'); let ticks = 0;
            Object.defineProperty(performance, 'now', {configurable:true, value:() => (++ticks < 4 ? 0 : ticks * 10)});
            let close;
            const closed = new Promise(resolve => { close = resolve });
            const timer = setTimeout(async () => {
                closedBeforeCompletion = !finished;
                await window.leafCommand({name:'toc'}); close();
            }, 0);
            try {
                await window.leafCommand({name:'find',text:'absent'}); finished = true;
                await closed;
                return {closedBeforeCompletion, lateReads, ranges:window.__sumatraFind.highlightRanges().length,
                    current:window.__sumatraFind.currentRange()?.toString() || ''};
            } finally {
                clearTimeout(timer);
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["closedBeforeCompletion"] as? Bool, true,
            "A queued close must run while the current page is still being scanned")
        XCTAssertEqual(outcome?["lateReads"] as? Int, 0, "Cancelled scans must leave later text unread")
        XCTAssertEqual(outcome?["ranges"] as? Int, 0)
        XCTAssertEqual(outcome?["current"] as? String, "")
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testReplacementFindOwnsResultsAfterTheOldLocalScanYields() async throws {
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            const hidden = document.createElement('div'); hidden.style.display = 'none';
            hidden.append(...Array.from({length:64}, () => document.createTextNode('x'.repeat(65536))));
            const heading = document.createElement('p'); heading.textContent = 'needle replacement';
            document.body.replaceChildren(heading, hidden);
            const createWalker = document.createTreeWalker;
            let walkers = 0, oldVisits = 0, replacement, oldFinished = false, replacedBeforeCompletion = false;
            document.createTreeWalker = function(...args) {
                const walker = createWalker.apply(this, args), id = ++walkers, next = walker.nextNode;
                if (id === 1) walker.nextNode = function() { oldVisits++; return next.call(this) };
                return walker;
            };
            const clock = Object.getOwnPropertyDescriptor(performance, 'now'); let ticks = 0;
            Object.defineProperty(performance, 'now', {configurable:true, value:() => (++ticks < 4 ? 0 : ticks * 10)});
            let replace;
            const replaced = new Promise(resolve => { replace = resolve });
            const timer = setTimeout(() => {
                replacedBeforeCompletion = !oldFinished;
                replacement = window.leafCommand({name:'find',text:'replacement'}); replace();
            }, 0);
            try {
                await window.leafCommand({name:'find',text:'needle'}); oldFinished = true;
                await replaced; await replacement;
                return {replacedBeforeCompletion, oldVisits, current:window.__sumatraFind.currentRange()?.toString()};
            } finally {
                clearTimeout(timer); document.createTreeWalker = createWalker;
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["replacedBeforeCompletion"] as? Bool, true)
        XCTAssertLessThan(outcome?["oldVisits"] as? Int ?? 100, 64, "The old scanner must stop traversing")
        XCTAssertEqual(outcome?["current"] as? String, "replacement")
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertTrue(state.searchResults.first?.title.contains("replacement") == true)
        XCTAssertEqual(state.selectedSearchTarget, state.searchResults.first?.target)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testClosingFindReleasesAScanWaitingForItsMessageTask() async throws {
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            const hidden = document.createElement('div'); hidden.style.display = 'none';
            hidden.textContent = 'x'.repeat(262144); document.body.replaceChildren(hidden);
            const Channel = window.MessageChannel, clock = Object.getOwnPropertyDescriptor(performance, 'now');
            let release, waiting, finished = false, ticks = 0;
            const paused = new Promise(resolve => { waiting = resolve });
            window.MessageChannel = function() {
                const channel = new Channel(), post = channel.port2.postMessage;
                channel.port2.postMessage = (...args) => { release = () => post.apply(channel.port2, args); waiting() };
                return channel;
            };
            Object.defineProperty(performance, 'now', {configurable:true, value:() => (++ticks < 4 ? 0 : ticks * 10)});
            try {
                const old = window.leafCommand({name:'find',text:'absent'}).then(() => { finished = true });
                await paused;
                await window.leafCommand({name:'toc'});
                await new Promise(resolve => setTimeout(resolve, 0));
                const beforeDelivery = finished;
                release(); await old;
                return {beforeDelivery, current:window.__sumatraFind.currentRange()?.toString() || ''};
            } finally {
                window.MessageChannel = Channel;
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["beforeDelivery"] as? Bool, true,
            "Closing Find must release pending scan work even if WebKit delays its message task")
        XCTAssertEqual(outcome?["current"] as? String, "")
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testClosingFindCanInterruptDenseMatchesInOneTextNode() async throws {
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            document.body.replaceChildren(document.createTextNode('a'.repeat(6000)));
            const createRange = document.createRange;
            let created = 0, finished = false, closedBeforeCompletion = false;
            document.createRange = function() { created++; return createRange.call(this) };
            const clock = Object.getOwnPropertyDescriptor(performance, 'now'); let ticks = 0;
            Object.defineProperty(performance, 'now', {configurable:true, value:() => (++ticks < 4 ? 0 : ticks * 10)});
            let close; const closed = new Promise(resolve => { close = resolve });
            const timer = setTimeout(async () => {
                closedBeforeCompletion = !finished; await window.leafCommand({name:'toc'}); close();
            }, 0);
            try {
                await window.leafCommand({name:'find',text:'a'}); finished = true; await closed;
                return {closedBeforeCompletion, created, current:window.__sumatraFind.currentRange()?.toString() || ''};
            } finally {
                clearTimeout(timer); document.createRange = createRange;
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["closedBeforeCompletion"] as? Bool, true)
        XCTAssertGreaterThan(outcome?["created"] as? Int ?? 0, 0, "Cancellation occurs after matching starts")
        XCTAssertLessThan(outcome?["created"] as? Int ?? 5000, 5000, "Dense matching must yield before its cap")
        XCTAssertEqual(outcome?["current"] as? String, "")
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testClosingFindCanInterruptFirstVisibleMatchGeometry() async throws {
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            document.body.replaceChildren(document.createTextNode('a'.repeat(6000)));
            const geometry = window.leafFindRangeRect, clock = Object.getOwnPropertyDescriptor(performance, 'now');
            let reads = 0, ticks = 0, finished = false, closedBeforeCompletion = false, timer;
            let close; const closed = new Promise(resolve => { close = resolve });
            Object.defineProperty(performance, 'now', {configurable:true, value:() => reads ? ++ticks * 10 : 0});
            window.leafFindRangeRect = () => {
                if (++reads === 1) timer = setTimeout(async () => {
                    closedBeforeCompletion = !finished; await window.leafCommand({name:'toc'}); close();
                }, 0);
                return {left:0,right:1,top:-2,bottom:-1,width:1,height:1};
            };
            try {
                await window.leafCommand({name:'find',text:'a'}); finished = true; await closed;
                return {reads, closedBeforeCompletion, current:window.__sumatraFind.currentRange()?.toString() || ''};
            } finally {
                clearTimeout(timer); window.leafFindRangeRect = geometry;
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["closedBeforeCompletion"] as? Bool, true)
        XCTAssertGreaterThan(outcome?["reads"] as? Int ?? 0, 0)
        XCTAssertLessThan(outcome?["reads"] as? Int ?? 5000, 5000,
            "Closing Find must stop layout traversal when every capped match is above the viewport")
        XCTAssertEqual(outcome?["current"] as? String, "")
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testReplacementFindOwnsResultsAfterFirstVisibleGeometryYields() async throws {
        let (state, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            document.body.replaceChildren(document.createTextNode('a'.repeat(6000) + ' replacement'));
            const geometry = window.leafFindRangeRect, clock = Object.getOwnPropertyDescriptor(performance, 'now');
            let oldReads = 0, ticks = 0, finished = false, replacedBeforeCompletion = false, timer, replacement;
            let replace; const replaced = new Promise(resolve => { replace = resolve });
            Object.defineProperty(performance, 'now', {configurable:true, value:() => oldReads ? ++ticks * 10 : 0});
            window.leafFindRangeRect = range => {
                if (range.toString() === 'a') {
                    if (++oldReads === 1) timer = setTimeout(() => {
                        replacedBeforeCompletion = !finished;
                        replacement = window.leafCommand({name:'find',text:'replacement'}); replace();
                    }, 0);
                    return {left:0,right:1,top:-2,bottom:-1,width:1,height:1};
                }
                return geometry(range);
            };
            try {
                await window.leafCommand({name:'find',text:'a'}); finished = true; await replaced; await replacement;
                return {oldReads, replacedBeforeCompletion, current:window.__sumatraFind.currentRange()?.toString()};
            } finally {
                clearTimeout(timer); window.leafFindRangeRect = geometry;
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["replacedBeforeCompletion"] as? Bool, true)
        XCTAssertLessThan(outcome?["oldReads"] as? Int ?? 5000, 5000)
        XCTAssertEqual(outcome?["current"] as? String, "replacement")
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertTrue(state.searchResults.first?.title.contains("replacement") == true)
        XCTAssertEqual(state.selectedSearchTarget, state.searchResults.first?.target)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testFirstVisibleFindKeepsDOMOrderForNonmonotonicGeometry() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let outcome = try await evaluate("""
            const node = document.createTextNode('aaaa'); document.body.replaceChildren(node);
            const finder = window.__sumatraFind, geometry = window.leafFindRangeRect;
            const clock = Object.getOwnPropertyDescriptor(performance, 'now'); let ticks = 0;
            Object.defineProperty(performance, 'now', {configurable:true, value:() => ++ticks * 10});
            let bottoms = [-1, 2, -1, 2];
            window.leafFindRangeRect = range => ({left:0,right:1,top:0,bottom:bottoms[range.startOffset],width:1,height:1});
            try {
                await finder.start('a', true, false, 801, -1, false);
                const first = finder.currentRange()?.startOffset;
                bottoms = [-1, -1, -1, -1];
                await finder.start('a', true, false, 802, -1, false);
                const wrapped = finder.currentRange()?.startOffset;
                await finder.start('a', true, false, 803, 3, false);
                return {first, wrapped, explicit:finder.currentRange()?.startOffset};
            } finally {
                window.leafFindRangeRect = geometry;
                if (clock) Object.defineProperty(performance, 'now', clock); else delete performance.now;
            }
            """, view) as? [String: Int]
        XCTAssertEqual(outcome?["first"], 1, "CSS can make match rectangles nonmonotonic in DOM order")
        XCTAssertEqual(outcome?["wrapped"], 0, "When every match is above the viewport, retain the first match")
        XCTAssertEqual(outcome?["explicit"], 3, "An explicit result target keeps its index")
    }

    @MainActor
    func testOlderSearchRestoreCannotPublishWhileANewerRestoreIsPending() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><p>First second</p>"], opened: "Book.html")
        let outcome = try await evaluate("""
            const finder = window.__sumatraFind, start = finder.start;
            const handler = window.webkit.messageHandlers.leaf, post = handler.postMessage;
            let first, second, positions = 0;
            handler.postMessage = body => { if (body.type === 'position') positions++; post.call(handler, body) };
            finder.start = term => new Promise(resolve => { if (term === 'First') first = resolve; else second = resolve });
            const target = text => location.href.split('#')[0] + '#sumra-search=' + encodeURIComponent(JSON.stringify({text,index:0}));
            try {
                const old = window.leafCommand({name:'restore',position:{anchor:target('First')}});
                while (!first) await Promise.resolve();
                const newer = window.leafCommand({name:'restore',position:{anchor:target('second')}});
                while (!second) await Promise.resolve();
                first(); await old;
                const before = positions;
                second(); await newer;
                return {before, after:positions};
            } finally { finder.start = start; handler.postMessage = post }
            """, view) as? [String: Int]
        XCTAssertEqual(outcome?["before"], 0, "An older restore cannot end the newer position barrier")
        XCTAssertEqual(outcome?["after"], 1)
    }

    @MainActor
    func testOlderActivationCannotPublishAfterANewerActivationStarts() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><p>First second</p>"], opened: "Book.html")
        let outcome = try await evaluate("""
            const finder = window.__sumatraFind, start = finder.start;
            const handler = window.webkit.messageHandlers.leaf, post = handler.postMessage;
            let first, second, outlines = 0;
            handler.postMessage = body => { if (body.type === 'toc') outlines++; post.call(handler, body) };
            finder.start = term => new Promise(resolve => { if (term === 'First') first = resolve; else second = resolve });
            const target = text => location.href.split('#')[0] + '#sumra-search=' + encodeURIComponent(JSON.stringify({text,index:0}));
            try {
                const old = window.leafCommand({name:'activate',position:{anchor:target('First')}});
                while (!first) await Promise.resolve();
                const newer = window.leafCommand({name:'activate',position:{anchor:target('second')}});
                while (!second) await Promise.resolve();
                first(); await old;
                const before = outlines;
                second(); await newer;
                return {before, after:outlines};
            } finally { finder.start = start; handler.postMessage = post }
            """, view) as? [String: Int]
        XCTAssertEqual(outcome?["before"], 0, "Only the current activation may publish readiness")
        XCTAssertEqual(outcome?["after"], 1)
    }

    @MainActor
    func testFindAcrossTextWindowKeepsNodeEndpointsAndSnippetContext() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let result = try await evaluate("""
            const hidden = document.createElement('span');
            hidden.style.display = 'none';
            hidden.textContent = 'x'.repeat(65534) + ' ';
            const a = document.createTextNode('A'), empty = document.createTextNode('');
            const b = document.createTextNode('B'), c = document.createTextNode('C');
            const tail = document.createTextNode(' ' + 'q'.repeat(50));
            const script = document.createElement('script'), style = document.createElement('style');
            script.textContent = 'ABC'; style.textContent = 'ABC';
            document.body.replaceChildren(hidden, a, empty, b, c, tail, script, style);
            const finder = window.__sumatraFind;
            const snippets = await finder.start('ABC', true, true, 101, 0, true);
            const range = finder.currentRange();
            const joined = {text:range?.toString(), start:range?.startContainer === a,
                startOffset:range?.startOffset, end:range?.endContainer === c, endOffset:range?.endOffset};
            await finder.start('B', true, false, 102, 0, false);
            const single = finder.currentRange();
            return {snippets, joined, emptyBoundary:single?.startContainer === b && single?.endContainer === b};
            """, view) as? [String: Any]
        let snippets = try XCTUnwrap(result?["snippets"] as? [String])
        XCTAssertEqual(snippets, ["..." + String(repeating: "x", count: 39) + " ABC " + String(repeating: "q", count: 39) + "..."])
        let joined = try XCTUnwrap(result?["joined"] as? [String: Any])
        XCTAssertEqual(joined["text"] as? String, "ABC")
        XCTAssertEqual(joined["start"] as? Bool, true)
        XCTAssertEqual(joined["startOffset"] as? Int, 0)
        XCTAssertEqual(joined["end"] as? Bool, true)
        XCTAssertEqual(joined["endOffset"] as? Int, 1)
        XCTAssertEqual(result?["emptyBoundary"] as? Bool, true)
    }

    @MainActor
    func testWholeWordSearchKeepsSupplementaryLetterAndNumberBoundariesAcrossFiles() async throws {
        let page = "<!doctype html><meta charset=\"utf-8\"><p>𐐀needle needle𐐀 𝟎needle needle𝟎 😀needle😀 needle.</p>"
        let (state, coordinator, view) = try await reader(["A.html": page, "B.html": page], opened: "A.html")
        _ = try await evaluate("await window.leafCommand({name:'find',text:'needle',matchWholeWords:true})", view)
        try await wait { !state.searchResults.isEmpty }
        XCTAssertEqual(state.searchResults.count, 4, "Letters and numbers join a word; emoji and punctuation separate words")
        let live = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
        XCTAssertEqual(live, "needle")
        let sibling = try XCTUnwrap(state.searchResults.first { $0.target.contains("/B.html") }?.target)
        state.navigate(.href(sibling))
        coordinator.deliver(state.command, to: view)
        try await wait { coordinator.ready && view.url?.path.hasSuffix("B.html") == true && state.selectedSearchTarget == sibling }
        let restored = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
        XCTAssertEqual(restored, "needle")
        XCTAssertEqual(state.searchResults.count, 4)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testWholeWordSearchKeepsSplitSurrogatesAndChunkBoundaries() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let rows = try await evaluate(#"""
            const finder = window.__sumatraFind, rows = [];
            for (const padding of [0, 65533, 65534, 65535, 65536, 131069]) {
                const fragments = ['x'.repeat(padding) + ' \ud801', '\udc00', 'nee', 'dle ',
                    'nee', 'dle\ud801', '\udc00 ', '\ud835', '\udfce', 'needle ',
                    'needle\ud835', '\udfce ', '\ud83d', '\ude00', 'nee', 'dle',
                    '\ud83d', '\ude00 ', 'needle.'];
                document.body.replaceChildren(...fragments.map(text => document.createTextNode(text)));
                const before = document.body.textContent;
                const whole = await finder.start('needle', true, true, padding + 700, 0, true);
                const first = finder.currentRange();
                const exact = first?.startContainer === document.body.childNodes[14]
                    && first?.endContainer === document.body.childNodes[15]
                    && first.startOffset === 0 && first.endOffset === 3;
                finder.gotoMatch(1);
                const last = finder.currentRange()?.toString();
                const partial = await finder.start('needle', true, false, padding + 701, 0, true);
                rows.push({padding, whole:whole.length, partial:partial.length, exact, last,
                    unchanged:document.body.textContent === before});
            }
            return rows;
            """#, view) as? [[String: Any]]
        for row in try XCTUnwrap(rows) {
            let label = "padding \(row["padding"] ?? "unknown")"
            XCTAssertEqual(row["whole"] as? Int, 2, label)
            XCTAssertEqual(row["partial"] as? Int, 6, label)
            XCTAssertEqual(row["exact"] as? Bool, true, label)
            XCTAssertEqual(row["last"] as? String, "needle", label)
            XCTAssertEqual(row["unchanged"] as? Bool, true, label)
        }
    }

    @MainActor
    func testFindKeepsTheFiveThousandMatchLimit() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let result = try await evaluate("""
            const reports = [];
            window.__sumatra__.notify = (...args) => reports.push(args);
            const finder = window.__sumatraFind;
            const boundary = [];
            for (const count of [4999, 5000]) {
                document.body.replaceChildren(document.createTextNode('a'.repeat(count)));
                await finder.start('a', true, false, count, -1, true);
                boundary.push({count:reports.at(-1)[3], capped:reports.at(-1)[4] === true});
            }
            const node = document.createTextNode('a'.repeat(5001));
            document.body.replaceChildren(node);
            const snippets = await finder.start('a', true, false, 103, 4999, true);
            const last = finder.currentRange();
            finder.report();
            const capped = reports.at(-1)[4] === true;
            finder.clear();
            finder.report();
            return {boundary, count:snippets.length, start:last?.startOffset, end:last?.endOffset,
                capped, clearedCount:reports.at(-1)[3], clearedCap:reports.at(-1)[4] === true};
            """, view) as? [String: Any]
        let boundary = try XCTUnwrap(result?["boundary"] as? [[String: Any]])
        XCTAssertEqual(boundary.map { $0["count"] as? Int }, [4999, 5000])
        XCTAssertEqual(boundary.map { $0["capped"] as? Bool }, [false, true], "Reaching the boundary cannot attest an exact total")
        XCTAssertEqual(result?["count"] as? Int, 5000)
        XCTAssertEqual(result?["start"] as? Int, 4999)
        XCTAssertEqual(result?["end"] as? Int, 5000)
        XCTAssertEqual(result?["capped"] as? Bool, true)
        XCTAssertEqual(result?["clearedCount"] as? Int, 0)
        XCTAssertEqual(result?["clearedCap"] as? Bool, false)
    }

    @MainActor
    func testLongLiteralSearchAcrossWindowsWhenWebKitAcceptsIt() async throws {
        let (_, _, view) = try await reader(["Book.html": "<!doctype html><body></body>"], opened: "Book.html")
        let result = try await evaluate("""
            const term = 'A'.repeat(70000);
            try {
                if (!new RegExp(term, 'g').exec(term)) return {accepted:false, reason:'native RegExp did not match'};
            } catch (error) {
                return {accepted:false, reason:String(error).slice(0, 100)};
            }
            const hidden = document.createElement('span');
            hidden.style.display = 'none';
            hidden.textContent = 'x'.repeat(150000) + ' ' + term + ' ' + 'q'.repeat(50);
            document.body.replaceChildren(hidden);
            const snippets = await window.__sumatraFind.start(term, true, true, 104, 0, true);
            return {accepted:true, count:snippets.length, rangeLength:window.__sumatraFind.currentRange()?.toString().length};
            """, view) as? [String: Any]
        if result?["accepted"] as? Bool == false {
            throw XCTSkip("WebKit native RegExp rejects a 70k literal: \(result?["reason"] ?? "unknown")")
        }
        XCTAssertEqual(result?["accepted"] as? Bool, true)
        XCTAssertEqual(result?["count"] as? Int, 1)
        XCTAssertEqual(result?["rangeLength"] as? Int, 70000)
    }

    @MainActor
    func testClosedContentsLeavesUnreadableSiblingAloneAndOpeningCanRetry() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First heading\n\nReadable page.",
            "B.md": "# Second heading\n\nSibling page."
        ], opened: "A.md", unreadableSibling: "B.md")
        try await wait { !view.isLoading && state.outline.count >= 2 }
        _ = try await evaluate("""
            window.outlineRequests = 0;
            const originalFetch = window.fetch;
            window.fetch = (url, options) => {
                if (String(url) === 'leaf://book/outline') window.outlineRequests++;
                return originalFetch(url, options);
            };
            """, view)
        state.closeFind()
        try await completeCurrentCommand(state, coordinator, view)
        XCTAssertTrue(coordinator.ready)
        XCTAssertNil(state.error, "Reading or closing Find must not read unopened siblings for a hidden Contents panel")
        XCTAssertEqual(state.outline.map(\.title), ["A.md", "B.md"])
        let closedRequests = try await evaluate("return window.outlineRequests", view) as? Int
        XCTAssertEqual(closedRequests, 0)

        state.showContents = true
        coordinator.updateInteraction(view)
        try await wait { state.error != nil }
        XCTAssertTrue(coordinator.ready, "An outline failure must leave the readable document usable")
        state.showLinks.toggle()
        coordinator.updateInteraction(view)
        let requestsAfterFlagChange = try await evaluate("return window.outlineRequests", view) as? Int
        XCTAssertEqual(requestsAfterFlagChange, 1, "An unrelated setting must not retry a failed directory read")
        let sibling = try XCTUnwrap(state.document?.url).deletingLastPathComponent().appendingPathComponent("B.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sibling.path)
        state.error = nil
        state.showContents = false
        coordinator.updateInteraction(view)
        state.showContents = true
        coordinator.updateInteraction(view)
        try await wait { state.outline.contains { $0.title == "Second heading" } }
        XCTAssertEqual(state.outline.map(\.title), ["A.md", "First heading", "B.md", "Second heading"])
        let retriedRequests = try await evaluate("return window.outlineRequests", view) as? Int
        XCTAssertEqual(retriedRequests, 2)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testContentsPaletteReadsHeadingsWithoutOpeningTheSidebar() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First heading\n\nReadable page.", "B.md": "# Palette heading\n\nSibling page."
        ], opened: "A.md")
        state.paletteContentsVisible = true
        coordinator.updateInteraction(view)
        try await wait { state.outline.contains { $0.title == "Palette heading" } }
        XCTAssertFalse(state.showContents)
        XCTAssertNil(state.error)
        state.paletteContentsVisible = false
        coordinator.updateInteraction(view)
    }

    @MainActor
    func testContentsOpenedWhileActivationWaitsIsNotLost() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First heading\n\nReadable page.", "B.md": "# Delayed heading\n\nSibling page."
        ], opened: "A.md")
        _ = try await evaluate("""
            const original = window.leafCommand;
            window.leafCommand = command => command.name === 'activate'
                ? new Promise(resolve => { window.releaseActivation = async () => resolve(await original(command)); })
                : original(command);
            """, view)
        coordinator.ready = false // Navigation suppresses UI delivery until activation completes.
        coordinator.activateDocument(view)
        var waiting = false
        let end = Date().addingTimeInterval(15)
        repeat {
            waiting = try await evaluate("return typeof window.releaseActivation === 'function'", view) as? Bool == true
            if !waiting { try await Task.sleep(nanoseconds: 20_000_000) }
        } while !waiting && Date() < end
        XCTAssertTrue(waiting)
        XCTAssertFalse(coordinator.ready)
        state.showContents = true
        coordinator.updateInteraction(view)
        _ = try await evaluate("await window.releaseActivation()", view)
        try await wait { coordinator.ready && state.outline.contains { $0.title == "Delayed heading" } }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testRecoveredOutlineSurvivesReturningToTheCachedFailedPage() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First heading\n\nFirst page.", "B.md": "# Restored heading\n\nSecond page."
        ], opened: "A.md", unreadableSibling: "B.md", showContents: true)
        try await wait { state.error != nil }
        _ = try await evaluate("window.outlineCacheMarker = 'failed-page'", view)
        let sibling = try XCTUnwrap(state.document?.url).deletingLastPathComponent().appendingPathComponent("B.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sibling.path)
        state.error = nil
        state.navigate(.href("leaf://book/entry/B.md"))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.outline.contains { $0.title == "Restored heading" } }
        let titles = ["A.md", "First heading", "B.md", "Restored heading"]
        XCTAssertEqual(state.outline.map(\.title), titles)
        state.navigateHistory(-1)
        try await completeCurrentCommand(state, coordinator, view)
        let marker = try await evaluate("return window.outlineCacheMarker", view) as? String
        XCTAssertEqual(marker, "failed-page")
        XCTAssertEqual(state.outline.map(\.title), titles)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSearchReportsAnUnreadableSiblingAndCanRetryTheSameQuery() async throws {
        let (state, _, view) = try await reader([
            "A.md": "# First\n\nneedle one. needle two.", "B.md": "# Second\n\nneedle three."
        ], opened: "A.md")
        let sibling = try XCTUnwrap(state.document?.url).deletingLastPathComponent().appendingPathComponent("B.md")
        try FileManager.default.removeItem(at: sibling)
        _ = try await evaluate("await window.leafCommand({name:'find',text:'needle'})", view)
        try await wait { state.error != nil || !state.searchResults.isEmpty }
        XCTAssertNotNil(state.error, "An unreadable page must not produce a complete document match count")
        XCTAssertTrue(state.error?.contains("B.md") == true)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertNil(state.selectedSearchTarget)

        try "# Second\n\nneedle three.".write(to: sibling, atomically: true, encoding: .utf8)
        state.error = nil
        _ = try await evaluate("await window.leafCommand({name:'find',text:'needle'})", view)
        try await wait { state.error != nil || state.searchResults.count == 3 }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.searchResults.count, 3)
        XCTAssertTrue(state.searchResults.last?.title.contains("needle three") == true)
    }

    @MainActor
    func testEmptyCurrentFileKeepsSearchingUntilSiblingSearchCompletes() async throws {
        for query in ["needle", "absent"] {
            let (state, _, view) = try await reader([
                "A.md": "# First\n\nAn ordinary paragraph.",
                "B.md": "# Second\n\nneedle in the other file."
            ], opened: "A.md")
            _ = try await view.callAsyncJavaScript("""
                const originalFetch = window.fetch;
                let started, release, intercepted = false;
                const waiting = new Promise(resolve => { started = resolve });
                window.fetch = async (...args) => {
                    const response = await originalFetch(...args);
                    if (!intercepted && new URL(args[0], location.href).pathname.endsWith('/B.md')) {
                        intercepted = true;
                        await new Promise(resolve => { release = resolve; started() });
                    }
                    return response;
                };
                window.pendingSiblingSearch = window.leafCommand({name:'find', text:query});
                window.finishSiblingSearch = async () => {
                    try { release(); await window.pendingSiblingSearch }
                    finally { window.fetch = originalFetch }
                };
                await waiting;
                """, arguments: ["query": query], in: nil, contentWorld: .world(name: "SumraMarkup"))
            try await wait { !state.status.isEmpty }
            XCTAssertEqual(state.status, "Searching…", "The current file cannot decide that the whole search has no matches")
            _ = try await evaluate("await window.finishSiblingSearch()", view)
            if query == "needle" {
                try await wait { state.searchResults.count == 1 && state.selectedSearchTarget != nil }
                XCTAssertEqual(state.status, "1 / 1 matches")
                XCTAssertTrue(state.searchResults.first?.title.contains("needle in the other file") == true)
            } else {
                try await wait { state.status == "No matches" }
                XCTAssertTrue(state.searchResults.isEmpty)
                XCTAssertNil(state.selectedSearchTarget)
            }
            XCTAssertNil(state.error)
        }
    }

    @MainActor
    func testSupersededSearchFailureCannotClearTheNewQuery() async throws {
        let (state, _, view) = try await reader([
            "A.md": "# First\n\nneedle one.", "B.md": "# Second\n\nneedle two. replacement result."
        ], opened: "A.md")
        _ = try await evaluate("""
            const originalFetch = window.fetch;
            let rejectOld, started, intercepted = false;
            const pending = new Promise(resolve => { started = resolve });
            window.fetch = (...args) => {
                if (!intercepted && new URL(args[0], location.href).pathname.endsWith('/B.md')) {
                    intercepted = true;
                    return new Promise((resolve, reject) => { rejectOld = reject; started() });
                }
                return originalFetch(...args);
            };
            try {
                const old = window.leafCommand({name:'find',text:'needle'});
                await pending;
                await window.leafCommand({name:'find',text:'replacement'});
                rejectOld(Error('Superseded resource failure'));
                await old;
            } finally { window.fetch = originalFetch }
            """, view)
        try await wait { state.error != nil || state.searchResults.count == 1 }
        XCTAssertNil(state.error)
        XCTAssertEqual(state.searchResults.count, 1)
        let hit = try XCTUnwrap(state.searchResults.first)
        XCTAssertTrue(hit.title.contains("replacement result"))
        XCTAssertEqual(state.selectedSearchTarget, hit.target)
    }

    @MainActor
    func testSupersededSearchSkipsAnAlreadyReceivedObsoleteBody() async throws {
        let (state, _, view) = try await reader([
            "A.md": "# First\n\nneedle here.", "B.md": "# Second\n\nreplacement here."
        ], opened: "A.md")
        let outcome = try await evaluate("""
            const originalFetch = window.fetch, originalParse = DOMParser.prototype.parseFromString;
            let bodyStarted, releaseBody, oldSignal, intercepted = false, obsoleteParses = 0;
            const pendingBody = new Promise(resolve => { bodyStarted = resolve });
            DOMParser.prototype.parseFromString = function(text, type) {
                if (text.includes('obsolete body marker')) obsoleteParses++;
                return originalParse.call(this, text, type);
            };
            window.fetch = async (url, options) => {
                if (!intercepted && new URL(url, location.href).pathname.endsWith('/B.md')) {
                    intercepted = true;
                    oldSignal = options?.signal;
                    return {ok: true, headers: new Headers({'content-type': 'text/html'}),
                        text: () => { bodyStarted(); return new Promise(resolve => {
                            releaseBody = () => resolve('<p>obsolete body marker</p>');
                        }); }};
                }
                return originalFetch(url, options);
            };
            try {
                const old = window.leafCommand({name:'find', text:'needle'});
                await pendingBody;
                await window.leafCommand({name:'find', text:'replacement'});
                const aborted = oldSignal?.aborted === true;
                releaseBody();
                await old;
                return {aborted, obsoleteParses};
            } finally {
                window.fetch = originalFetch;
                DOMParser.prototype.parseFromString = originalParse;
            }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["aborted"] as? Bool, true, "The obsolete fetch must receive cancellation")
        XCTAssertEqual(outcome?["obsoleteParses"] as? Int, 0,
                       "A superseded response must skip HTML parsing after its body arrives")
        XCTAssertNil(state.error)
        XCTAssertEqual(state.searchResults.count, 1)
    }

    @MainActor
    func testSupersededSearchSkipsBodyReadAfterDelayedHeaders() async throws {
        let (state, _, view) = try await reader([
            "A.md": "# First\n\nneedle here.", "B.md": "# Second\n\nreplacement here."
        ], opened: "A.md")
        let outcome = try await evaluate("""
            const originalFetch = window.fetch;
            let started, releaseHeaders, oldSignal, bodyReads = 0, intercepted = false;
            const pending = new Promise(resolve => { started = resolve });
            window.fetch = (url, options) => {
                if (!intercepted && new URL(url, location.href).pathname.endsWith('/B.md')) {
                    intercepted = true;
                    oldSignal = options?.signal;
                    return new Promise(resolve => {
                        releaseHeaders = () => resolve({ok: true, headers: new Headers({'content-type': 'text/html'}),
                            text: async () => { bodyReads++; return '<p>obsolete body</p>'; }});
                        started();
                    });
                }
                return originalFetch(url, options);
            };
            try {
                const old = window.leafCommand({name:'find', text:'needle'});
                await pending;
                await window.leafCommand({name:'find', text:'replacement'});
                const aborted = oldSignal?.aborted === true;
                releaseHeaders();
                await old;
                return {aborted, bodyReads};
            } finally { window.fetch = originalFetch; }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["aborted"] as? Bool, true)
        XCTAssertEqual(outcome?["bodyReads"] as? Int, 0)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.searchResults.count, 1)
    }

    @MainActor
    func testRestoredSearchCancelsPendingSiblingFetch() async throws {
        let (state, _, view) = try await reader([
            "A.md": "# First\n\nneedle and replacement here.", "B.md": "# Second\n\nneedle here."
        ], opened: "A.md")
        let outcome = try await evaluate("""
            const originalFetch = window.fetch;
            let started, releaseHeaders, oldSignal, bodyReads = 0, intercepted = false;
            const pending = new Promise(resolve => { started = resolve });
            window.fetch = (url, options) => {
                if (!intercepted && new URL(url, location.href).pathname.endsWith('/B.md')) {
                    intercepted = true;
                    oldSignal = options?.signal;
                    return new Promise(resolve => {
                        releaseHeaders = () => resolve({ok: true, headers: new Headers({'content-type': 'text/html'}),
                            text: async () => { bodyReads++; return '<p>obsolete needle</p>'; }});
                        started();
                    });
                }
                return originalFetch(url, options);
            };
            try {
                const old = window.leafCommand({name:'find', text:'needle'});
                await pending;
                const target = location.href.split('#')[0] + '#sumra-search=' +
                    encodeURIComponent(JSON.stringify({text:'replacement',index:0}));
                await window.leafCommand({name:'restore',position:{page:0,anchor:target}});
                const aborted = oldSignal?.aborted === true;
                releaseHeaders();
                await old;
                return {aborted, bodyReads, current: window.__sumatraFind.currentRange()?.toString()};
            } finally { window.fetch = originalFetch; }
            """, view) as? [String: Any]
        XCTAssertEqual(outcome?["aborted"] as? Bool, true)
        XCTAssertEqual(outcome?["bodyReads"] as? Int, 0)
        XCTAssertEqual(outcome?["current"] as? String, "replacement")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSupersededFindNextCannotAdvanceAReplacementWithTheSameQuery() async throws {
        let (state, _, view) = try await reader([
            "A.md": "# First\n\nneedle one. needle two. replacement result.",
            "B.md": "# Second\n\nneedle three."
        ], opened: "A.md")
        _ = try await evaluate("""
            const originalFetch = window.fetch;
            let releaseOld, started, intercepted = false;
            const pending = new Promise(resolve => { started = resolve });
            window.fetch = (...args) => {
                if (!intercepted && new URL(args[0], location.href).pathname.endsWith('/B.md')) {
                    intercepted = true;
                    return new Promise(resolve => {
                        releaseOld = () => resolve({ok: true, headers: new Headers({'content-type': 'text/html'}),
                            text: async () => '<p>needle from an obsolete response</p>'});
                        started();
                    });
                }
                return originalFetch(...args);
            };
            const old = window.leafCommand({name:'find',text:'needle'});
            await pending;
            const oldNext = window.leafCommand({name:'find',text:'needle'});
            await window.leafCommand({name:'find',text:'replacement'});
            await window.leafCommand({name:'find',text:'needle'});
            window.releaseSupersededFind = async () => {
                try { await releaseOld(); await Promise.all([old, oldNext]); }
                finally { window.fetch = originalFetch; delete window.releaseSupersededFind; }
            };
            """, view)
        try await wait { state.searchResults.count == 3 && state.selectedSearchTarget == state.searchResults.first?.target }
        let selected = try XCTUnwrap(state.selectedSearchTarget)
        _ = try await evaluate("await window.releaseSupersededFind()", view)
        // Await a bridge round trip so any stale searchHit/status messages have
        // reached the native owner before checking the replacement search.
        _ = try await evaluate("window.__sumatraFind.report()", view)
        XCTAssertEqual(state.selectedSearchTarget, selected)
        XCTAssertEqual(state.status, "1 / 3 matches")
        XCTAssertEqual(state.searchResults.count, 3)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSVGSearchAndDocumentTextExcludeStylesAndScripts() async throws {
        let (state, _, view) = try await reader(["Diagram.html": """
            <!doctype html><p>Before diagram</p>
            <svg xmlns="http://www.w3.org/2000/svg" width="400" height="60">
              <style>/* SVG_STYLE_ONLY */ text { fill: black; }</style>
              <script>const SVG_SCRIPT_ONLY = 'not reader text';</script>
              <text x="10" y="30">Visible diagram label</text>
            </svg>
            <p>After diagram</p>
            """], opened: "Diagram.html")
        let text = try await evaluate("""
            const parsed = new DOMParser().parseFromString(document.documentElement.outerHTML, 'text/html');
            return {live: await window.leafText(true), parsed: window.__sumatraFind.textFromBody(parsed.body).text};
            """, view) as? [String: String]
        for source in ["live", "parsed"] {
            let extracted = try XCTUnwrap(text?[source])
            XCTAssertTrue(extracted.contains("Visible diagram label"), source)
            XCTAssertFalse(extracted.contains("SVG_STYLE_ONLY"), source)
            XCTAssertFalse(extracted.contains("SVG_SCRIPT_ONLY"), source)
        }
        let viewport = try await state.documentText()
        XCTAssertTrue(viewport.contains("Visible diagram label"))
        XCTAssertFalse(viewport.contains("SVG_STYLE_ONLY"))
        XCTAssertFalse(viewport.contains("SVG_SCRIPT_ONLY"))
        for query in ["SVG_STYLE_ONLY", "SVG_SCRIPT_ONLY"] {
            _ = try await evaluate("await window.leafCommand({name:'find', text:'\(query)'})", view)
            _ = try await evaluate("window.__sumatraFind.report()", view)
            XCTAssertTrue(state.searchResults.isEmpty, query)
            XCTAssertEqual(state.status, "No matches", query)
        }
        _ = try await evaluate("await window.leafCommand({name:'find', text:'Visible diagram label'})", view)
        try await wait { state.searchResults.count == 1 && state.selectedSearchTarget != nil }
        XCTAssertTrue(state.searchResults[0].title.contains("Visible diagram label"))
        XCTAssertFalse(state.searchResults[0].title.contains("SVG_STYLE_ONLY"))
        XCTAssertFalse(state.searchResults[0].title.contains("SVG_SCRIPT_ONLY"))
        XCTAssertNil(state.error)
        let selection = try await evaluate("""
            const range = document.createRange(); range.selectNodeContents(document.body);
            getSelection().removeAllRanges(); getSelection().addRange(range);
            return {native: getSelection().toString(), reader: await window.leafText(false), dom: range.toString()};
            """, view) as? [String: String]
        XCTAssertEqual(selection?["native"], selection?["reader"])
        XCTAssertTrue(selection?["native"]?.contains("Visible diagram label") == true)
        XCTAssertFalse(selection?["native"]?.contains("SVG_STYLE_ONLY") == true)
        XCTAssertFalse(selection?["native"]?.contains("SVG_SCRIPT_ONLY") == true)
        XCTAssertTrue(selection?["dom"]?.contains("SVG_STYLE_ONLY") == true)
        XCTAssertTrue(selection?["dom"]?.contains("SVG_SCRIPT_ONLY") == true)
    }

    @MainActor
    func testFindPositionsEachMatchImmediatelyWithAuthoredSmoothScrolling() async throws {
        let (_, _, view) = try await reader(["Smooth.html": """
            <!doctype html><html style="scroll-behavior:smooth"><body>
            <p id="kept">Preserved selection.</p><div style="height:1600px"></div>
            <p id="first">Needle first</p><div style="height:1600px"></div>
            <p id="last">Needle last</p><div style="height:1600px"></div>
            </body></html>
            """], opened: "Smooth.html")
        let result = try await evaluate("""
            const selection=getSelection(), kept=document.createRange();
            kept.selectNodeContents(document.getElementById('kept'));
            selection.removeAllRanges(); selection.addRange(kept);
            const visible=id=>{const r=document.getElementById(id).getBoundingClientRect();
                return r.top>=0 && r.bottom<=innerHeight;};
            await window.__sumatraFind.start('Needle',false,false,501,0,false);
            const firstVisible=visible('first');
            window.__sumatraFind.gotoMatch(1);
            const lastVisible=visible('last'), lastY=scrollY;
            await new Promise(resolve=>setTimeout(resolve,60));
            return {firstVisible,lastVisible,lastStillVisible:visible('last'),lastY,settledY:scrollY,
                selected:selection.toString(),current:window.__sumatraFind.currentRange()?.toString(),
                scrollBehavior:getComputedStyle(document.documentElement).scrollBehavior};
            """, view) as? [String: Any]
        XCTAssertEqual(result?["firstVisible"] as? Bool, true)
        XCTAssertEqual(result?["lastVisible"] as? Bool, true)
        XCTAssertEqual(result?["lastStillVisible"] as? Bool, true)
        XCTAssertEqual(result?["lastY"] as? Double, result?["settledY"] as? Double)
        XCTAssertEqual(result?["selected"] as? String, "Preserved selection.")
        XCTAssertEqual(result?["current"] as? String, "Needle")
        XCTAssertEqual(result?["scrollBehavior"] as? String, "smooth", "Find must preserve authored CSS")
    }

    @MainActor
    func testSVGFindPaintsThroughNativeOverlayWithCustomHighlights() async throws {
        let (state, coordinator, view) = try await reader(["Diagram.html": """
            <!doctype html><p>Ordinary HTML match</p><div style="height:1800px"></div>
            <svg xmlns="http://www.w3.org/2000/svg" width="420" height="80">
              <text x="12" y="40" style="fill:currentColor;font-size:24px">Needle in diagram</text>
            </svg><div style="height:1800px"></div>
            """], opened: "Diagram.html")
        let supported = try await evaluate("return !!window.Highlight && !!CSS.highlights", view) as? Bool
        guard supported == true else { throw XCTSkip("Custom Highlights unavailable") }

        state.showFindPanel()
        state.send(.find("Needle", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 1 }
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        let selected = try await evaluate("""
            const range=window.__sumatraFind.currentRange(),rect=range.getBoundingClientRect();
            const text=range.startContainer.parentElement,ctm=text.getScreenCTM();
            const first=text.getExtentOfChar(range.startOffset),last=text.getExtentOfChar(range.endOffset-1);
            const glyphTop=new DOMPoint(first.x,first.y).matrixTransform(ctm).y;
            const glyphBottom=new DOMPoint(last.x+last.width,last.y+last.height).matrixTransform(ctm).y;
            return {text:range.toString(),parent:range.startContainer.parentElement.localName,
                rect:[rect.x,rect.y,rect.width,rect.height],glyph:[glyphTop,glyphBottom],scrollY};
            """, view) as? [String: Any]
        XCTAssertEqual(selected?["text"] as? String, "Needle")
        XCTAssertEqual(selected?["parent"] as? String, "text")
        XCTAssertGreaterThan(selected?["scrollY"] as? Double ?? 0, 0)
        let glyph = try XCTUnwrap(selected?["glyph"] as? [Double])
        let current = try XCTUnwrap(coordinator.rangeHighlightView?.rectangles.current.first)
        XCTAssertEqual(current.minY, glyph[0], accuracy: 2, "Native overlay must follow the SVG glyph, not the Range box")
        XCTAssertEqual(current.maxY, glyph[1], accuracy: 2)
        let scroll = try await evaluate("""
            const range=window.__sumatraFind.currentRange(),text=range.startContainer.parentElement;
            const bottom=()=>{const e=text.getExtentOfChar(range.endOffset-1),p=text.getScreenCTM();
                return new DOMPoint(e.x+e.width,e.y+e.height).matrixTransform(p).y};
            scrollBy(0,range.getBoundingClientRect().bottom-innerHeight+3);
            const before=bottom(); window.__sumatraFind.gotoMatch(0); return [before,bottom(),innerHeight];
            """, view) as? [Double]
        let scrollResult = try XCTUnwrap(scroll)
        XCTAssertGreaterThan(scrollResult[0], scrollResult[2], "Fixture must expose the Range/SVG scroll gap")
        XCTAssertLessThanOrEqual(scrollResult[1], scrollResult[2], "Find must scroll the actual glyph into view")
        _ = try await evaluate("""
            CSS.highlights.set('sumra-speech', new Highlight(window.__sumatraFind.currentRange()));
            window.leafPublishRangeHighlights(true);
            """, view)
        try await wait { coordinator.rangeHighlightView?.rectangles.speech.isEmpty == false }
        _ = try await evaluate("CSS.highlights.delete('sumra-speech'); window.leafPublishRangeHighlights(true)", view)
        try await wait { coordinator.rangeHighlightView?.rectangles.speech.isEmpty == true }

        state.zoom = 1.5; state.send(.zoom(1.5))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        let zoomed = try await evaluate("return window.leafRangeHighlights().current[0]", view) as? [Double]
        let zoomedShape = try XCTUnwrap(zoomed)
        let zoomedOverlay = try XCTUnwrap(coordinator.rangeHighlightView?.rectangles.current.first)
        let zoomedGlyphY = try await evaluate("""
            const node=window.__sumatraFind.currentRange().startContainer,text=node.parentElement;
            const glyph=text.getExtentOfChar(0);
            return new DOMPoint(glyph.x,glyph.y).matrixTransform(text.getScreenCTM()).y;
            """, view) as? Double
        XCTAssertEqual(zoomedShape[1], try XCTUnwrap(zoomedGlyphY), accuracy: 2)
        XCTAssertEqual(zoomedOverlay.minY, zoomedShape[1] * 1.5, accuracy: 2)
        _ = try await evaluate("window.scrollBy(0, 60); window.leafPublishRangeHighlights(true)", view)
        try await wait {
            guard let rect = coordinator.rangeHighlightView?.rectangles.current.first else { return false }
            return rect.minY < zoomedOverlay.minY - 20
        }

        state.send(.find("Ordinary", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 1 && state.searchResults.first?.title.contains("Ordinary") == true }
        try await wait { coordinator.rangeHighlightView == nil }
        let htmlOnly = try await evaluate("""
            const range=window.__sumatraFind.currentRange(),original=Range.prototype.getBoundingClientRect;
            let geometryCalls=0;
            Range.prototype.getBoundingClientRect=function(){ geometryCalls++; return original.call(this) };
            CSS.highlights.set('sumra-speech',new Highlight(range));
            try { window.leafPublishRangeHighlights(true); window.leafRangeHighlights(); }
            finally { Range.prototype.getBoundingClientRect=original; CSS.highlights.delete('sumra-speech') }
            return geometryCalls;
            """, view) as? Int
        XCTAssertEqual(htmlOnly, 0, "Ordinary HTML Find and speech stay on the Custom Highlights path")
        XCTAssertNil(coordinator.rangeHighlightView)
        state.send(.find("Needle", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        state.closeFind(); try await completeCurrentCommand(state, coordinator, view)
        try await wait { coordinator.rangeHighlightView == nil }
    }

    @MainActor
    func testFindRevealsHorizontalTextAndSVGGlyphsWithoutMovingVisibleAxes() async throws {
        let wide = String(repeating: "W", count: 180)
        let (state, coordinator, view) = try await reader(["Wide.html": """
            <!doctype html><style>html{scroll-behavior:smooth}</style>
            <div style="position:relative;width:3000px;height:2000px">
              <span id="selection">Keep selection</span>
              <span style="position:absolute;left:1250px;top:200px;white-space:nowrap">HorizontalTarget</span>
              <svg xmlns="http://www.w3.org/2000/svg" width="800" height="100" style="position:absolute;left:1550px;top:700px;font:24px system-ui">
                <text x="12" y="40">😀<tspan>Glyph</tspan><tspan>Target</tspan></text>
              </svg>
              <span style="position:absolute;left:900px;top:1100px;white-space:nowrap">\(wide)</span>
            </div>
            """], opened: "Wide.html")
        state.zoom = 1.5; state.send(.zoom(1.5))
        try await completeCurrentCommand(state, coordinator, view)
        let result = try await evaluate("""
            const wide='W'.repeat(180);
            const selected=document.createRange();selected.selectNodeContents(document.getElementById('selection'));
            getSelection().removeAllRanges();getSelection().addRange(selected);
            const css=document.querySelector('style').textContent;
            const rect=()=>{const r=window.leafFindRangeRect(window.__sumatraFind.currentRange());
                return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,x:scrollX,y:scrollY,width:innerWidth,height:innerHeight}};
            scrollTo({left:0,top:100,behavior:'instant'});
            const initialY=scrollY;
            await window.leafCommand({name:'find',text:'HorizontalTarget'});
            const horizontal=rect();window.__sumatraFind.gotoMatch(0);const repeated=rect();
            scrollTo({left:horizontal.x,top:900,behavior:'instant'});
            window.__sumatraFind.gotoMatch(0);const vertical=rect();
            scrollTo({left:0,top:1500,behavior:'instant'});
            await window.leafCommand({name:'find',text:'GlyphTarget'});const svg=rect();
            await window.leafCommand({name:'find',text:wide});const oversized=rect();
            window.__sumatraFind.gotoMatch(0);const oversizedRepeated=rect();
            return {initialY,horizontal,repeated,vertical,svg,oversized,oversizedRepeated,
                selection:getSelection().toString(),cssUnchanged:document.querySelector('style').textContent===css};
            """, view) as? [String: Any]
        let values = try XCTUnwrap(result)
        for name in ["horizontal", "repeated", "vertical", "svg"] {
            let rect = try XCTUnwrap(values[name] as? [String: Double])
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(rect["left"]), -1, name)
            XCTAssertLessThanOrEqual(try XCTUnwrap(rect["right"]), try XCTUnwrap(rect["width"]) + 1, name)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(rect["top"]), -1, name)
            XCTAssertLessThanOrEqual(try XCTUnwrap(rect["bottom"]), try XCTUnwrap(rect["height"]) + 1, name)
        }
        let horizontal = try XCTUnwrap(values["horizontal"] as? [String: Double])
        let repeated = try XCTUnwrap(values["repeated"] as? [String: Double])
        let vertical = try XCTUnwrap(values["vertical"] as? [String: Double])
        XCTAssertEqual(horizontal["y"], values["initialY"] as? Double)
        XCTAssertEqual(repeated["x"], horizontal["x"])
        XCTAssertEqual(repeated["y"], horizontal["y"])
        XCTAssertEqual(vertical["x"], horizontal["x"])
        let oversized = try XCTUnwrap(values["oversized"] as? [String: Double])
        let oversizedRepeated = try XCTUnwrap(values["oversizedRepeated"] as? [String: Double])
        XCTAssertGreaterThan(try XCTUnwrap(oversized["right"]), try XCTUnwrap(oversized["width"]))
        XCTAssertEqual(try XCTUnwrap(oversized["left"]), 0, accuracy: 2 / view.pageZoom)
        XCTAssertEqual(oversizedRepeated["x"], oversized["x"])
        XCTAssertEqual(oversizedRepeated["y"], oversized["y"])
        XCTAssertEqual(values["selection"] as? String, "Keep selection")
        XCTAssertEqual(values["cssUnchanged"] as? Bool, true)
    }

    @MainActor
    func testFindKeepsMatchesAboveViewportScrollbarsInStandardAndQuirksDocuments() async throws {
        for (doctype, mode) in [("<!doctype html>", "CSS1Compat"), ("", "BackCompat")] {
            let (state, coordinator, view) = try await reader(["Edges.html": """
                \(doctype)<style>html{overflow:scroll}::-webkit-scrollbar{width:30px;height:30px}</style>
                <div id="body" style="position:relative;width:1800px;height:1800px">
                  <span id="edge" style="position:absolute;white-space:nowrap">Edge</span>
                </div>
                """], opened: "Edges.html")
            view.window?.setContentSize(NSSize(width: 280.5, height: 360))
            state.zoom = 1.5; state.send(.zoom(1.5))
            try await completeCurrentCommand(state, coordinator, view)
            let result = try await evaluate("""
                const viewport=document.compatMode==='BackCompat'?document.body:document.documentElement;
                const edge=document.getElementById('edge'),origin=document.getElementById('body').getBoundingClientRect();
                const initial=edge.getBoundingClientRect();
                edge.style.left=(viewport.clientWidth-initial.width/2-origin.left)+'px';
                edge.style.top=(viewport.clientHeight-initial.height/2-origin.top)+'px';
                const before=edge.getBoundingClientRect();
                const fixture={right:before.right,bottom:before.bottom,width:viewport.clientWidth,height:viewport.clientHeight,
                    innerWidth,innerHeight,mode:document.compatMode};
                await window.leafCommand({name:'find',text:'Edge'});
                const after=window.__sumatraFind.currentRange().getBoundingClientRect();
                return {fixture,left:after.left,top:after.top,right:after.right,bottom:after.bottom};
                """, view) as? [String: Any]
            let values = try XCTUnwrap(result), fixture = try XCTUnwrap(values["fixture"] as? [String: Any])
            XCTAssertEqual(fixture["mode"] as? String, mode)
            let width = try XCTUnwrap(fixture["width"] as? Double), height = try XCTUnwrap(fixture["height"] as? Double)
            XCTAssertLessThan(width, try XCTUnwrap(fixture["innerWidth"] as? Double))
            XCTAssertLessThan(height, try XCTUnwrap(fixture["innerHeight"] as? Double))
            XCTAssertGreaterThan(try XCTUnwrap(fixture["right"] as? Double), width)
            XCTAssertGreaterThan(try XCTUnwrap(fixture["bottom"] as? Double), height)
            XCTAssertLessThanOrEqual(try XCTUnwrap(fixture["right"] as? Double), try XCTUnwrap(fixture["innerWidth"] as? Double))
            XCTAssertLessThanOrEqual(try XCTUnwrap(fixture["bottom"] as? Double), try XCTUnwrap(fixture["innerHeight"] as? Double))
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["left"] as? Double), -1)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["top"] as? Double), -1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(values["right"] as? Double), width + 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(values["bottom"] as? Double), height + 1)
        }
    }

    @MainActor
    func testFindRevealsTextAcrossNegativeRTLScrollCoordinates() async throws {
        let (_, _, view) = try await reader(["RTL.html": """
            <!doctype html><html dir="rtl"><style>html{scroll-behavior:smooth}</style>
            <div style="position:relative;width:2300px;height:1200px">
              <span style="position:absolute;left:30px;top:200px">RTLTarget</span>
            </div></html>
            """], opened: "RTL.html")
        let result = try await evaluate("""
            scrollTo({left:0,top:100,behavior:'instant'});
            const originalY=scrollY;
            const r=document.createRange();r.selectNodeContents(document.querySelector('span'));
            const before=r.getBoundingClientRect().left;
            await window.leafCommand({name:'find',text:'RTLTarget'});
            const rect=window.__sumatraFind.currentRange().getBoundingClientRect();
            return {before,x:scrollX,y:scrollY,originalY,left:rect.left,right:rect.right,width:innerWidth};
            """, view) as? [String: Double]
        let values = try XCTUnwrap(result)
        XCTAssertLessThan(try XCTUnwrap(values["before"]), 0)
        XCTAssertLessThan(try XCTUnwrap(values["x"]), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["left"]), -1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values["right"]), try XCTUnwrap(values["width"]) + 1)
        XCTAssertEqual(values["y"], values["originalY"])
    }

    @MainActor
    func testSVGFindInFrameClearsNativeOverlayWhenClosed() async throws {
        let (_, coordinator, view) = try await reader([
            "A.html": "<!doctype html><iframe src='B.html' width='420' height='180'></iframe>",
            "B.html": "<!doctype html><svg xmlns='http://www.w3.org/2000/svg' width='400' height='80'><text x='12' y='40'>Needle in frame</text></svg>"
        ], opened: "A.html")
        let supported = try await evaluate("return !!window.Highlight && !!CSS.highlights", view) as? Bool
        guard supported == true else { throw XCTSkip("Custom Highlights unavailable") }
        _ = try await evaluate("""
            const frame=document.querySelector('iframe');
            if(!frame.contentWindow?.leafCommand) await new Promise(resolve=>frame.addEventListener('load',resolve,{once:true}));
            await frame.contentWindow.leafCommand({name:'find',text:'Needle'});
            """, view)
        try await wait { coordinator.rangeHighlightView?.rectangles.current.isEmpty == false }
        _ = try await evaluate("await document.querySelector('iframe').contentWindow.leafCommand({name:'toc'})", view)
        try await wait { coordinator.rangeHighlightView == nil }
    }

    @MainActor
    func testSVGFindOverlaySettlesAfterZoomedScrollClampInHiddenWindow() async throws {
        let (state, coordinator, view) = try await reader(["Glyphs.html": """
            <!doctype html><meta charset="utf-8"><div style="height:1050px"></div>
            <svg xmlns="http://www.w3.org/2000/svg" width="600" height="460" style="font:24px system-ui">
              <text x="12" y="40">GlyphToken</text>
              <text x="12" y="100">   GlyphToken  suffix</text>
              <text x="12" y="160">abc   GlyphToken</text>
              <text x="12" y="220">GlyphToken suffix</text>
              <text x="12" y="280">😀<tspan>Glyph</tspan><tspan>Token</tspan></text>
              <text x="12" y="340" xml:space="preserve">   GlyphToken  suffix</text>
              <text x="12" y="400" fill="#d00000" style="white-space:pre">   GlyphToken  suffix</text>
            </svg><p>End of glyph fixture.</p>
            """], opened: "Glyphs.html")
        XCTAssertFalse(view.window?.isVisible ?? true)
        let supported = try await evaluate("return !!window.Highlight && !!CSS.highlights", view) as? Bool
        guard supported == true else { throw XCTSkip("Custom Highlights unavailable") }

        state.zoom = 1.5; state.send(.zoom(1.5))
        try await completeCurrentCommand(state, coordinator, view)
        state.showFindPanel()
        state.send(.find("GlyphToken", backwards: false))
        try await completeCurrentCommand(state, coordinator, view)
        try await wait { state.searchResults.count == 7 }
        _ = try await evaluate("""
            setTimeout(() => { window.scrollTo(0, 1030); window.__sumatraFind.gotoMatch(6); }, 0);
            return true;
            """, view)
        let snapshot = WKSnapshotConfiguration()
        snapshot.afterScreenUpdates = true
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            view.takeSnapshot(with: snapshot) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? NSError(domain: "MarkupReaderTests", code: 2)) }
            }
        }
        let final = try await evaluate("""
            const text=document.querySelectorAll('svg text')[6],rect=text.getBoundingClientRect();
            return {scrollY, rect:[rect.left,rect.top,rect.right,rect.bottom]};
            """, view) as? [String: Any]
        let settled = try XCTUnwrap(final)
        XCTAssertGreaterThan(settled["scrollY"] as? Double ?? 0, 1000)
        let currentText = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", view) as? String
        XCTAssertEqual(currentText, "GlyphToken")
        let textRect = try XCTUnwrap(settled["rect"] as? [Double])
        try await wait {
            guard let native = coordinator.rangeHighlightView?.rectangles.current.first else { return false }
            return abs(native.minY - textRect[1] * view.pageZoom) < 2
        }
        let native = try XCTUnwrap(coordinator.rangeHighlightView?.rectangles.current.first)
        XCTAssertEqual(native.minY, textRect[1] * view.pageZoom, accuracy: 2,
            "Native overlay must follow the settled SVG text bounds")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        var redRows = [Int]()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.5 && color.greenComponent < 0.25 && color.blueComponent < 0.25 {
                    redRows.append(y); break
                }
            }
        }
        XCTAssertFalse(redRows.isEmpty, "WebKit snapshot must contain the final red SVG glyph")
        if let first = redRows.min() {
            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            let paintedY = CGFloat(first) / scale
            XCTAssertLessThan(abs(paintedY - textRect[1] * view.pageZoom), 18)
            XCTAssertLessThan(abs(paintedY - native.minY), 18,
                "Native overlay must follow the painted red glyph in WebKit's snapshot")
        }
    }

    @MainActor
    func testSVGFindGlyphGeometryMapsWhitespaceEmojiAndSplitSpans() async throws {
        let (_, _, view) = try await reader(["Glyphs.html": """
            <!doctype html><meta charset="utf-8"><div style="height:800px"></div>
            <svg xmlns="http://www.w3.org/2000/svg" width="600" height="460" style="fill:currentColor;font:24px system-ui">
              <text x="12" y="40">GlyphToken</text>
              <text x="12" y="100">   GlyphToken  suffix</text>
              <text x="12" y="160">abc   GlyphToken</text>
              <text x="12" y="220">
                GlyphToken  suffix
              </text>
              <text x="12" y="280">😀<tspan>Glyph</tspan><tspan>Token</tspan></text>
              <text x="12" y="340" xml:space="preserve">   GlyphToken  suffix</text>
              <text x="12" y="400" style="white-space:pre">   GlyphToken  suffix</text>
            </svg>
            """], opened: "Glyphs.html")
        let supported = try await evaluate("return !!window.Highlight && !!CSS.highlights", view) as? Bool
        guard supported == true else { throw XCTSkip("Custom Highlights unavailable") }
        let cases = try await evaluate("""
            const finder=window.__sumatraFind;
            await finder.start('GlyphToken',false,false,1,-1,false);
            const starts=[0,0,4,0,2,3,3],result=[];
            const texts=[...document.querySelectorAll('svg text')];
            for(let i=0;i<texts.length;i++) {
                finder.gotoMatch(i);
                const range=finder.currentRange(),text=texts[i],matrix=text.getScreenCTM();
                let left=Infinity,top=Infinity,right=-Infinity,bottom=-Infinity;
                for(let j=starts[i];j<starts[i]+10;j++) {
                    const glyph=text.getExtentOfChar(j);
                    for(const [x,y] of [[glyph.x,glyph.y],[glyph.x+glyph.width,glyph.y+glyph.height]]) {
                        const point=new DOMPoint(x,y).matrixTransform(matrix);
                        left=Math.min(left,point.x);top=Math.min(top,point.y);
                        right=Math.max(right,point.x);bottom=Math.max(bottom,point.y);
                    }
                }
                const actual=window.leafFindRangeRect(range);
                const shapes=window.leafRangeHighlights().current;
                result.push({text:range.toString(),expected:[left,top,right,bottom],
                    actual:[actual.left,actual.top,actual.right,actual.bottom],
                    shapes:shapes.length,chars:text.getNumberOfChars()});
            }
            return result;
            """, view) as? [[String: Any]]
        let observed = try XCTUnwrap(cases)
        XCTAssertEqual(observed.count, 7)
        for (index, item) in observed.enumerated() {
            XCTAssertEqual(item["text"] as? String, "GlyphToken", "case \(index)")
            let expected = try XCTUnwrap(item["expected"] as? [Double])
            let actual = try XCTUnwrap(item["actual"] as? [Double])
            for coordinate in 0..<4 {
                XCTAssertEqual(actual[coordinate], expected[coordinate], accuracy: 2, "case \(index), coordinate \(coordinate)")
            }
            XCTAssertGreaterThan(item["shapes"] as? Int ?? 0, 0, "case \(index) should paint")
        }
        let unsupported = try await evaluate("""
            const text=document.querySelectorAll('svg text')[6],finder=window.__sumatraFind;
            text.style.whiteSpace='pre-line'; finder.gotoMatch(6);
            const modern=window.leafRangeHighlights().current.length;
            const saved=window.Highlight;
            try {
                window.Highlight=undefined;
                await finder.start('GlyphToken',false,false,2,6,false);
                return [modern,window.leafRangeHighlights().current.length];
            } finally { window.Highlight=saved; }
            """, view) as? [Int]
        XCTAssertEqual(unsupported, [0, 0], "Unmapped SVG glyphs must not paint an inaccurate Range box")
    }

    @MainActor
    func testFilteredRangeTextPreservesPartialAndElementEndpoints() async throws {
        let (_, _, view) = try await reader(["Ranges.html": """
            <!doctype html><div id="range"><p id="first">012firstABC</p><svg xmlns="http://www.w3.org/2000/svg"><style>/* HIDDEN_STYLE */</style><text>VISIBLE</text></svg><p id="last">defLAST789</p></div><p>Outside range</p>
            """], opened: "Ranges.html")
        let text = try await evaluate("""
            const first = document.getElementById('first').firstChild;
            const last = document.getElementById('last').firstChild;
            const range = document.createRange();
            range.setStart(first, 3); range.setEnd(first, 8);
            const single = window.__sumatraFind.textFromRange(range);
            range.setEnd(last, 7);
            const across = window.__sumatraFind.textFromRange(range);
            range.setStart(document.getElementById('range'), 1);
            range.setEnd(document.getElementById('range'), 2);
            const element = window.__sumatraFind.textFromRange(range);
            range.collapse(true);
            return {single, across, element, collapsed: window.__sumatraFind.textFromRange(range),
                missing: window.__sumatraFind.textFromRange(null)};
            """, view) as? [String: String]
        XCTAssertEqual(text?["single"], "first")
        XCTAssertEqual(text?["across"], "firstABCVISIBLEdefLAST")
        XCTAssertEqual(text?["element"], "VISIBLE")
        XCTAssertEqual(text?["collapsed"], "")
        XCTAssertEqual(text?["missing"], "")
    }

    @MainActor
    func testMermaidUsesTheBundledUpstreamRenderer() async throws {
        let (state, _, view) = try await reader([
            "Diagram.md": "# Diagram\n\n```MERMAID\nflowchart TD\n    A --> B\n```"
        ], opened: "Diagram.md")
        let end = Date().addingTimeInterval(15)
        var rendered = false
        repeat {
            rendered = try await evaluate("return !!document.querySelector('pre.mermaid svg')", view) as? Bool == true
            if rendered || state.error != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < end
        XCTAssertNil(state.error)
        XCTAssertTrue(rendered)
        let text = try await evaluate("return await window.leafText(true)", view) as? String
        XCTAssertFalse(text?.contains("mermaid-") == true)
        _ = try await evaluate("await window.leafCommand({name:'find', text:'mermaid-'})", view)
        _ = try await evaluate("window.__sumatraFind.report()", view)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertEqual(state.status, "No matches")
        _ = try await evaluate("await window.leafCommand({name:'find', text:'A', matchCase:true})", view)
        try await wait { state.searchResults.count == 1 && state.selectedSearchTarget != nil }
        XCTAssertFalse(state.searchResults[0].title.contains("mermaid-"))
    }

    @MainActor
    func testMarkdownOpeningRendersMermaidAlongsideFileLinks() async throws {
        let (state, coordinator, view) = try await reader([
            "Release-check.md": """
                # Sumra release check

                Search marker: orbit verification.

                ## Second heading

                A local [sibling file](Sibling.md#destination) and a Mermaid diagram.

                ```mermaid
                flowchart LR
                  Open --> Read --> Save
                ```

                ## Final heading

                True tail: release acceptance.
                """,
            "Sibling.md": "# Destination\n\nSibling document."
        ], opened: "Release-check.md", showContents: true)
        try await wait {
            state.error != nil || view.isLoading == false && coordinator.ready
        }
        let end = Date().addingTimeInterval(15)
        var labels = ""
        repeat {
            labels = try await evaluate("return document.querySelector('pre.mermaid[data-processed=\"true\"] svg')?.textContent || ''", view) as? String ?? ""
            if !labels.isEmpty || state.error != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < end
        XCTAssertNil(state.error)
        for label in ["Open", "Read", "Save"] { XCTAssertTrue(labels.contains(label)) }
        XCTAssertTrue(state.outline.contains { $0.title == "Final heading" })
    }

    @MainActor
    func testCachedPageCompletesItsUnrenderedMermaid() async throws {
        let (state, coordinator, view) = try await reader([
            "A.md": "# First\n\nA document with an unfinished diagram.",
            "B.md": "# Second\n\nAnother document."
        ], opened: "A.md")
        // Initial activation has no diagram. Leave an unprocessed block in the
        // cached DOM, as when navigation interrupts the asynchronous loader.
        _ = try await evaluate("""
            window.cacheMarker = 'unfinished';
            const pre = document.createElement('pre'), code = document.createElement('code');
            code.className = 'language-mermaid'; code.textContent = 'flowchart TD; A --> B';
            pre.append(code); document.body.append(pre);
            """, view)
        state.navigate(.href("leaf://book/entry/B.md"))
        try await completeCurrentCommand(state, coordinator, view)
        state.navigateHistory(-1)
        try await completeCurrentCommand(state, coordinator, view)
        let marker = try await evaluate("return window.cacheMarker", view) as? String
        XCTAssertEqual(marker, "unfinished", "The diagram must finish in the existing cached document")
        let end = Date().addingTimeInterval(15)
        var rendered = false
        repeat {
            rendered = try await evaluate("return !!document.querySelector('pre.mermaid[data-processed=\"true\"] svg')", view) as? Bool == true
            if rendered || state.error != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < end
        XCTAssertNil(state.error)
        XCTAssertTrue(rendered)
    }

    @MainActor
    func testFindSessionHasOneBackDestinationAcrossQueriesAndResults() throws {
        let state = ReaderState()
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("search-session.txt")
        defer { UserDefaults.standard.removeObject(forKey: "position:" + url.path); withExtendedLifetime(directory) {} }
        state.document = ReadingDocument(url: url, content: .text("words"))
        let origin = ReadingPosition(page: 0, anchor: "18")
        state.updatePosition(origin)
        state.showFindPanel()
        state.send(.find("word", backwards: false))
        state.updatePosition(.init(page: 0, anchor: "200"))
        state.send(.find("word", backwards: false))
        state.send(.toc)
        state.send(.find("different", backwards: false))
        state.searchResults = [.init(title: "match", target: "text:500:5")]
        state.navigate(.href("text:500:5"))
        state.updatePosition(.init(page: 0, anchor: "500"))
        state.navigateHistory(-1)
        XCTAssertEqual(state.currentPosition.anchor, origin.anchor)
        XCTAssertFalse(state.canNavigateBack)
    }
}
#endif
