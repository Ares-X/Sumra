#if os(macOS)
import AppKit
import Foundation
import PDFKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class BrowserReaderTests: XCTestCase {
    private func system(_ records: [(UInt16, Data)]) -> Data {
        var result = Data([3, 0, 0, 0])
        for (type, bytes) in records {
            let length = UInt16(bytes.count)
            result.append(contentsOf: [UInt8(truncatingIfNeeded: type), UInt8(type >> 8),
                UInt8(truncatingIfNeeded: length), UInt8(length >> 8)])
            result.append(bytes)
        }
        return result
    }

    func testSystemCodepageAndDefaultTopicAreDecodedTogether() {
        let data = system([(4, Data([4, 8, 0, 0])), // Chinese LCID 2052
                           (2, Data([0xb2, 0xe2, 0xca, 0xd4, 0x2e, 0x68, 0x74, 0x6d, 0])),
                           (0, Data("toc.hhc\0".utf8))])
        let metadata = CHMMetadata(system: data)
        XCTAssertEqual(metadata.home, "测试.htm")
        XCTAssertEqual(metadata.toc, "toc.hhc")
        XCTAssertEqual(CFStringConvertNSStringEncodingToEncoding(metadata.encoding.rawValue),
                       CFStringConvertWindowsCodepageToEncoding(936))
    }

    func testWindowsMetadataPrecedesSystemAndRejectsInvalidOffsets() {
        var windows = Data(repeating: 0, count: 196)
        windows[0] = 1
        windows[4] = 188
        windows[8 + 0x68] = 1
        windows[8 + 0x60] = 255 // no string at this offset
        let metadata = CHMMetadata(system: system([(2, Data("fallback.htm\0".utf8)),
                                                  (0, Data("toc.hhc\0".utf8))]),
                                   windows: windows, strings: Data("\0home.htm\0".utf8))
        XCTAssertEqual(metadata.home, "home.htm")
        XCTAssertEqual(metadata.toc, "toc.hhc")
    }

    func testTruncatedRecordDoesNotReadPastItsPayload() {
        let metadata = CHMMetadata(system: Data([3, 0, 0, 0, 2, 0, 20, 0, 65]))
        XCTAssertTrue(metadata.home.isEmpty)
    }

    @MainActor
    private func javascript(_ assertions: String) async throws -> Any {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Sumra/Resources/Reader/chm.js"))
            .replacingOccurrences(of: "export ", with: "")
        let view = WKWebView(frame: .zero)
        return try await evaluate(source + "\n" + assertions, in: view)
    }

    @MainActor
    private func evaluate(_ source: String, in view: WKWebView, arguments: [String: Any] = [:]) async throws -> Any {
        return try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .world(name: "SumraMarkup")) { result in
                continuation.resume(with: result)
                _ = view // retain until the WebKit callback
            }
        }
    }

    @MainActor
    func testHHCHierarchyIncludesTitleOnlyGroupsAndSiblingLists() async throws {
        let result = try await javascript("""
        const doc = parse(`<ul><li><object type="text/sitemap"><param name="Name" value="Part"></object></li>
        <ul><li><object type="text/sitemap"><param name="Name" value="Chapter"><param name="Local" value="CHAPTER.HTM#one"></object></li></ul>
        <li><object type="text/sitemap"><param name="Name" value="End"><param name="Local" value="/end.htm"></object></li></ul>`);
        return flatten(hhcContents(doc, 'leaf://book/entry/toc.hhc'));
        """) as? [[String: Any]]
        XCTAssertEqual(result?.compactMap { $0["title"] as? String }, ["Part", "Chapter", "End"])
        XCTAssertEqual(result?.compactMap { $0["depth"] as? Int }, [0, 1, 0])
        XCTAssertEqual(result?[0]["target"] as? String, "")
        XCTAssertEqual(result?[2]["target"] as? String, "leaf://book/entry/end.htm")
    }

    @MainActor
    func testExplicitMarkupCharsetOverridesSystemCodepage() async throws {
        let result = try await javascript("""
        const text = '<meta charset="utf-8"><p>测试</p>';
        return decodeHTML(new TextEncoder().encode(text).buffer, 'windows-1252');
        """) as? String
        XCTAssertEqual(result, "<meta charset=\"utf-8\"><p>测试</p>")
    }

    @MainActor
    func testDefaultTopicThenTOCThenUnlistedPagesAndCaseInsensitiveLinks() async throws {
        let result = try await javascript("""
        const toc = '<ul><li><object type="text/sitemap"><param name="Name" value="Group"></object><ul><li><object><param name="Name" value="Chapter"><param name="Local" value="CHAPTER.HTM#named"></object></li><li><object><param name="Name" value="Cover"><param name="Local" value="COVER.GIF"></object></li></ul></li></ul>';
        return await indexCHM({ home:'home.htm', toc:'toc.hhc', tocData:btoa(toc), charset:'utf-8',
            entries:['extra.txt','chapter.htm','home.htm','cover.gif','inline.png','toc.hhc'].map(filename => ({filename})) });
        """) as? [String: Any]
        XCTAssertEqual(result?["pages"] as? [String], ["home.htm", "chapter.htm", "cover.gif", "extra.txt"].map { "leaf://book/entry/" + $0 })
        let toc = result?["toc"] as? [[String: Any]]
        XCTAssertEqual(toc?.compactMap { $0["depth"] as? Int }, [0, 1, 1])
        XCTAssertEqual(toc?[1]["target"] as? String, "leaf://book/entry/chapter.htm#named")
        XCTAssertEqual(toc?[1]["page"] as? Int, 1)
    }

    @MainActor
    func testLargeCHMOutlineRetainsTopicOrderingForRepeatedDestinations() async throws {
        let result = try await javascript("""
        const count = 3000;
        const entries = Array.from({length:count}, (_, index) => `topic-${index}.htm`);
        const items = entries.map((path, index) => `<li><object><param name=Name value="Chapter ${index}"><param name=Local value="${path}"></object></li>`);
        items.push('<li><object><param name=Name value="Repeated first topic"><param name=Local value="TOPIC-0.HTM#second"></object></li>');
        const indexed = await indexCHM({home:entries[1024], toc:'toc.hhc',
            tocData:btoa('<ul>' + items.join('') + '</ul>'), charset:'utf-8',
            entries:[...entries, entries[0], 'toc.hhc'].map(filename => ({filename}))});
        return {pages:indexed.pages.length, indexes:indexed.toc.map(item => item.page), last:indexed.toc.at(-1).target};
        """) as? [String: Any]
        XCTAssertEqual(result?["pages"] as? Int, 3000)
        let expected = (0..<3000).map { $0 == 1024 ? 0 : ($0 < 1024 ? $0 + 1 : $0) } + [1]
        XCTAssertEqual(result?["indexes"] as? [Int], expected)
        XCTAssertEqual(result?["last"] as? String, "leaf://book/entry/topic-0.htm#second")
    }

    @MainActor
    private func bridgeFixture(topic: (path: String, data: Data)? = nil, home: String? = nil,
                               additionalTopics: [(path: String, data: Data)] = [], lcid: UInt32 = 1033) throws -> (ReaderState, BrowserReader.Coordinator, WKWebView) {
        let engine = try NativeFile.libraryURL(for: .chm)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build CHMLib before native CHM bridge integration tests") }
        // Base fixture: unmodified Sumatra 012d997f tests/issue-2737.chm (GPLv3), stored
        // as its header/tail around the original zero-filled directory padding.
        // https://github.com/sumatrapdfreader/sumatrapdf/blob/012d997f6a3a5c5c97b878e1a340db3bffde8c0e/tests/issue-2737-make.ts
        var bytes = Data(repeating: 0, count: 2354)
        let header = try XCTUnwrap(Data(base64Encoded: "SVRTRgMAAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAAAAAAABUCAAAAAAAALQIAAAAAAAASVRTUAEAAABUAAAAAAAAAAAIAAAAAAAAAAAAAP////8AAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUE1HTNEHAAAAAAAA//////////8ILyNTWVNURU0AACMLL2luZGV4Lmh0bWwAI1s="))
        let tail = try XCTUnwrap(Data(base64Encoded: "AwAAAAIADAAvaW5kZXguaHRtbAADAAsASXNzdWUgMjczNwA8aHRtbD48Ym9keT48Zm9udCBmYWNlPSJDb3VyaWVyIE5ldyI+Q0hNIGZvbnQgb3ZlcnJpZGUgcmVncmVzc2lvbiB0ZXN0PC9mb250PjwvYm9keT48L2h0bWw+"))
        bytes.replaceSubrange(0..<227, with: header)
        bytes.replaceSubrange(2228..<2354, with: tail)
        for index in 0..<4 { bytes[20 + index] = UInt8(truncatingIfNeeded: lcid >> (index * 8)) }
        // Append uncompressed topics using the upstream fixture's PMGL entry
        // format. Cwords contain most-significant seven-bit groups first.
        func cword(_ number: Int) -> Data {
            var value = number, groups = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 { groups.insert(UInt8(value & 0x7f) | 0x80, at: 0); value >>= 7 }
            return Data(groups)
        }
        var directory = Data()
        for topic in ([topic].compactMap { $0 } + additionalTopics).sorted(by: { $0.path < $1.path }) {
            directory.append(cword(topic.path.utf8.count)); directory.append(Data(topic.path.utf8))
            directory.append(0); directory.append(cword(bytes.count - 2228)); directory.append(cword(topic.data.count))
            bytes.append(topic.data)
        }
        guard directory.count < 2001 else { throw NSError(domain: "BrowserReaderTests", code: 2) }
        bytes.replaceSubrange(227..<(227 + directory.count), with: directory)
        let unused = 2001 - directory.count
        for index in 0..<4 { bytes[184 + index] = UInt8(truncatingIfNeeded: unused >> (index * 8)) }
        if let home {
            // Keep the original #SYSTEM record size and subsequent offsets.
            let path = try XCTUnwrap(home.utf8.count == 11 ? Data(home.utf8) : nil)
            bytes.replaceSubrange(2236..<2247, with: path)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-CHM-" + UUID().uuidString + ".chm")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let source = try CHMSource(url), state = ReaderState(), view = WKWebView(frame: .zero)
        state.document = .init(url: url, content: .browser(source))
        state.flow = "continuous"; state.spread = false
        state.browserView = view
        return (state, BrowserReader.Coordinator(state: state, source: source), view)
    }

    @MainActor
    private func loadedReaderFixture(topic: (path: String, data: Data)? = nil, home: String? = nil,
                                     additionalTopics: [(path: String, data: Data)] = [],
                                     position: ReadingPosition? = nil, lcid: UInt32 = 1033) async throws -> (ReaderState, WKWebView) {
        let (state, coordinator, _) = try bridgeFixture(topic: topic, home: home, additionalTopics: additionalTopics, lcid: lcid)
        state.theme = "light"; state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 700, height: 500), position: position)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        addTeardownBlock { @MainActor in
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            let path = state.document?.url.path
            state.windowClosed()
            if let path { UserDefaults.standard.removeObject(forKey: "position:" + path) }
            window.contentView = nil; window.close()
        }
        coordinator.load(view)
        try await waitUntil { coordinator.ready || coordinator.readerError != nil }
        if let error = coordinator.readerError { throw error }
        _ = try XCTUnwrap(coordinator.ready ? true : nil, "Reader did not become ready")
        return (state, view)
    }

    @MainActor
    func testNativeHoverPreviewHandlesTopicLinksAndRestoresPublisherTitles() async throws {
        let html = """
        <a href="index.html" title="Next topic">Next</a>
        <a href="#local" title="Local heading">Local</a>
        <a href="#missing" title="Missing heading">Missing</a>
        <p id="local">Preview text</p>
        """
        let (state, view) = try await loadedReaderFixture(topic: ("/links.html", Data(html.utf8)), home: "/links.html")
        let result = try await evaluate("""
        const doc = document;
        const titles = () => [...doc.querySelectorAll('a[href]')].map(a => a.title);
        await window.leafCommand({ name: 'interaction', flags: { hoverPreview: true } });
        const previews = [...doc.querySelectorAll('a[href]')].map(link => {
            link.dispatchEvent(new PointerEvent('pointerover', {bubbles:true}));
            const title = link.title;
            link.dispatchEvent(new PointerEvent('pointerout', {bubbles:true}));
            return title;
        });
        await window.leafCommand({ name: 'interaction', flags: { hoverPreview: false } });
        return { previews, restored: titles() };
        """, in: view) as? [String: Any]
        XCTAssertEqual(result?["previews"] as? [String], ["leaf://book/entry/index.html", "Preview text", "leaf://book/entry/links.html#missing"])
        XCTAssertEqual(result?["restored"] as? [String], ["Next topic", "Local heading", "Missing heading"])
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        state.hoverPreview = true
        coordinator.updateInteraction(view)
        state.send(.href("leaf://book/entry/index.html"))
        let navigation = state.command
        coordinator.command = navigation.revision
        coordinator.deliver(navigation, to: view)
        try await waitUntil { state.page == 1 || state.error != nil }
        XCTAssertEqual(state.page, 1, "A link preview must not prevent ordinary topic navigation")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeTOCPreservesLiteralPercentAndDecodesValidEscapes() async throws {
        let toc = """
        <ul><li><object type="text/sitemap"><param name="Name" value="Literal percent"><param name="Local" value="rate%.txt"></object></li>
        <li><object type="text/sitemap"><param name="Name" value="Encoded space"><param name="Local" value="space%20name.txt"></object></li></ul>
        """
        let (state, view) = try await loadedReaderFixture(additionalTopics: [
            ("/rate%.txt", Data("Literal percentage chapter".utf8)),
            ("/space name.txt", Data("Encoded space chapter".utf8)),
            ("/toc.hhc", Data(toc.utf8)),
        ])
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        XCTAssertTrue(coordinator.ready)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.outline.map(\.title), ["Literal percent", "Encoded space"])
        XCTAssertEqual(state.outline.map(\.target), ["leaf://book/entry/rate%25.txt", "leaf://book/entry/space%20name.txt"])
        for (index, expected) in ["Literal percentage chapter", "Encoded space chapter"].enumerated() {
            let target = try XCTUnwrap(state.outline.indices.contains(index) ? state.outline[index].target : nil)
            let previous = state.command.revision
            state.send(.href(target))
            try await waitForNextCommand(state, after: previous)
            coordinator.command = state.command.revision
            coordinator.deliver(state.command, to: view)
            try await waitUntil { state.page == index + 1 || state.error != nil }
            let shown = try await evaluate("return document.body.textContent", in: view) as? String
            XCTAssertEqual(shown, expected)
            XCTAssertNil(state.error)
        }
    }

    @MainActor
    func testNativeHomeAndTOCAcceptExistingTopicsWithoutAnHTMLExtension() async throws {
        let toc = "<ul><li><object><param name=Name value=Chapter><param name=Local value=topic.></object></li></ul>"
        let (state, view) = try await loadedReaderFixture(home: "/startpage.", additionalTopics: [
            ("/startpage.", Data("<p>Extensionless home</p>".utf8)),
            ("/toc.hhc", Data(toc.utf8)),
            ("/topic.", Data("<p>Explicit topic</p>".utf8)),
            ("/unused.bin", Data([0, 1, 2, 3])),
        ])
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        XCTAssertTrue(coordinator.ready)
        XCTAssertEqual(state.count, 3)
        let initial = try await evaluate("""
        return { paths: window.sumraDocument.pages.map(page => new URL(page).pathname.slice(7)),
                 text: document.body.textContent };
        """, in: view) as? [String: Any]
        XCTAssertEqual(initial?["paths"] as? [String], ["startpage.", "topic.", "index.html"])
        XCTAssertEqual(initial?["text"] as? String, "Extensionless home")
        let target = try XCTUnwrap(state.outline.first?.target)
        XCTAssertEqual(target, "leaf://book/entry/topic.")
        state.send(.href(target))
        coordinator.command = state.command.revision
        coordinator.deliver(state.command, to: view)
        try await waitUntil { state.page == 1 || state.error != nil }
        let shown = try await evaluate("return document.body.textContent", in: view) as? String
        XCTAssertEqual(shown, "Explicit topic")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeNavigationAndSearchReachPlainTextCHMTopics() async throws {
        let text = "测试\r\n<script>not code</script>\r\n1 < 2 & 3"
        let (state, view) = try await loadedReaderFixture(topic: ("/plain.txt", Data(text.utf8)))
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.page, 0)
        state.send(.href("leaf://book/entry/PLAIN.TXT")); let navigation = state.command
        state.send(.find("测试"))
        coordinator.command = navigation.revision
        coordinator.deliver(navigation, to: view)
        try await waitForNextCommand(state, after: navigation.revision)
        try await waitUntil { state.page == 1 || state.error != nil }
        let shown = try await evaluate(#"""
        await window.leafCommand({ name: 'style', text: 'system|17|1.6|32|system', useDocumentCSS: false });
        const doc = document;
        return { text: doc.body.textContent, scripts: doc.body.querySelectorAll('script').length,
                 whiteSpace: doc.defaultView.getComputedStyle(doc.querySelector('pre')).whiteSpace };
        """#, in: view) as? [String: Any]
        XCTAssertEqual(shown?["text"] as? String, text.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertEqual(shown?["scripts"] as? Int, 0)
        XCTAssertEqual(shown?["whiteSpace"] as? String, "pre-wrap")
        let search = state.command
        XCTAssertEqual(search.action, .find("测试", options: .init()))
        coordinator.command = search.revision
        coordinator.deliver(search, to: view)
        try await waitUntil { state.searchResults.count == 1 && state.selectedSearchTarget != nil || state.error != nil }
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertNotNil(state.selectedSearchTarget)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testPlainTextCHMUsesReaderTypographyAndWrapsAcrossReadingModes() async throws {
        let text = "Opening line\n\n" + String(repeating: "Readable words stay searchable. ", count: 400) + "\n\nFinal line"
        let (_, view) = try await loadedReaderFixture(topic: ("/topic1.txt", Data(text.utf8)), home: "/topic1.txt")
        let result = try await evaluate("""
        const pre = document.querySelector('pre');
        const metrics = () => {
            const body = getComputedStyle(document.body), style = getComputedStyle(pre), box = pre.getBoundingClientRect();
            return {viewport:innerWidth, width:box.width, scrollWidth:pre.scrollWidth,
                bodyFont:body.fontSize, font:style.fontSize, family:style.fontFamily,
                line:style.lineHeight, padding:body.paddingLeft, whiteSpace:style.whiteSpace,
                columns:getComputedStyle(document.body).columnCount};
        };
        const narrow = metrics();
        await window.leafCommand({name:'style',flow:'paged',spread:false});
        const single = metrics();
        await window.leafCommand({name:'style',flow:'paged',spread:true});
        const spread = metrics();
        await window.leafCommand({name:'style',flow:'continuous',spread:false});
        await window.leafCommand({name:'style',text:'serif|24|1.5|48|light'});
        const enlarged = metrics();
        return {contentType:document.contentType, text:pre.textContent, narrow,single,spread,enlarged};
        """, in: view) as? [String: Any]
        XCTAssertEqual(result?["contentType"] as? String, "text/plain")
        XCTAssertEqual(result?["text"] as? String, text)
        for (key, columns) in [("narrow", "auto"), ("single", "1"), ("spread", "2")] {
            let mode = try XCTUnwrap(result?[key] as? [String: Any])
            let width = try XCTUnwrap(mode["width"] as? Double)
            let viewport = try XCTUnwrap(mode["viewport"] as? Double)
            XCTAssertGreaterThan(width, viewport * (key == "spread" ? 0.35 : 0.8), key)
            XCTAssertLessThanOrEqual(try XCTUnwrap(mode["scrollWidth"] as? Double), width + 2, key)
            XCTAssertEqual(mode["bodyFont"] as? String, "17px", key)
            XCTAssertEqual(mode["font"] as? String, "17px", key)
            XCTAssertEqual(mode["padding"] as? String, "32px", key)
            XCTAssertEqual(mode["whiteSpace"] as? String, "pre-wrap", key)
            XCTAssertEqual(mode["columns"] as? String, columns, key)
        }
        let enlarged = try XCTUnwrap(result?["enlarged"] as? [String: Any])
        XCTAssertEqual(enlarged["font"] as? String, "24px")
        XCTAssertEqual(enlarged["line"] as? String, "36px")
        XCTAssertEqual(enlarged["family"] as? String, "serif")
        XCTAssertEqual(enlarged["padding"] as? String, "48px")
    }

    @MainActor
    func testSourceWrappedCHMParagraphGapsIgnoreExcessBlankRowsAndRetainFindOffsets() async throws {
        let full = String(repeating: "中", count: 35)
        let paragraphs = (0..<4).map { "\(full)\n收尾第\($0)段文字。" }
        let separators = ["\n\n", String(repeating: "\n", count: 10), "\n \t\n\n"]
        let text = paragraphs.enumerated().map { index, paragraph in
            paragraph + (index < separators.count ? separators[index] : "")
        }.joined() + "\n\n\n\n    let value = 1\n    print(value)"
        let (_, view) = try await loadedReaderFixture(topic: ("/topic1.txt", Data(text.utf8)), home: "/topic1.txt")
        func sample() async throws -> [String: Any] {
            let value = try await evaluate("""
            const pre = document.querySelector('pre');
            const prose = [...pre.querySelectorAll('.sumra-chm-prose')];
            const gaps = [...pre.querySelectorAll('.sumra-chm-paragraph-gap')];
            const indexed = window.__sumatraFind.textFromBody(document.body);
            const edge = (span, last) => {
                const node = last ? span.lastChild : span.firstChild, range = document.createRange();
                const offset = last ? node.length - 1 : 0;
                range.setStart(node, offset); range.setEnd(node, offset + 1);
                return range.getBoundingClientRect();
            };
            return {source:pre.textContent, searchable:indexed.text,
                separators:gaps.map(gap => gap.textContent),
                offsets:gaps.map(gap => {
                    const prefix = document.createRange(); prefix.selectNodeContents(pre);
                    prefix.setEnd(gap.firstChild, 0); return prefix.toString().length;
                }),
                distances:gaps.map((gap, index) => edge(prose[index + 1], false).top - edge(prose[index], true).bottom),
                heights:gaps.map(gap => gap.getBoundingClientRect().height),
                fontSize:parseFloat(getComputedStyle(pre).fontSize)};
            """, in: view) as? [String: Any]
            return try XCTUnwrap(value)
        }
        let continuous = try await sample()
        XCTAssertEqual(continuous["source"] as? String, text)
        XCTAssertEqual(continuous["searchable"] as? String, text)
        XCTAssertEqual(continuous["separators"] as? [String], separators)
        let offsets = separators.indices.map { index in
            paragraphs.prefix(index + 1).reduce(0) { $0 + ($1 as NSString).length }
                + separators.prefix(index).reduce(0) { $0 + ($1 as NSString).length }
        }
        XCTAssertEqual(continuous["offsets"] as? [Int], offsets)
        let distances = try XCTUnwrap(continuous["distances"] as? [Double])
        XCTAssertEqual(distances.count, 3)
        for distance in distances.dropFirst() {
            XCTAssertEqual(distance, distances[0], accuracy: 1, "Source blank-row count must not enlarge recognized prose gaps")
        }
        let fontSize = try XCTUnwrap(continuous["fontSize"] as? Double)
        for height in try XCTUnwrap(continuous["heights"] as? [Double]) {
            XCTAssertEqual(height, fontSize / 2, accuracy: 1)
        }
        let needle = "收尾第1段文字。" + separators[1] + "中"
        _ = try await evaluate("""
        await window.__sumatraFind.start(needle,true,false,1);
        await window.leafCommand({name:'style',flow:'paged',spread:true,text:'serif|24|1.5|40|light'});
        """, in: view, arguments: ["needle": needle])
        let after = try await evaluate("""
        const range = window.__sumatraFind.currentRange();
        return {source:document.querySelector('pre').textContent,
            searchable:window.__sumatraFind.textFromBody(document.body).text,
            selected:range?.toString(), connected:range?.startContainer.isConnected && range?.endContainer.isConnected};
        """, in: view) as? [String: Any]
        XCTAssertEqual(after?["source"] as? String, text)
        XCTAssertEqual(after?["searchable"] as? String, text)
        XCTAssertEqual(after?["selected"] as? String, needle)
        XCTAssertEqual(after?["connected"] as? Bool, true)
        let paged = try await sample()
        for height in try XCTUnwrap(paged["heights"] as? [Double]) {
            XCTAssertEqual(height, 12, accuracy: 1)
        }
    }

    @MainActor
    func testSourceWrappedCHMProseFlowsWithoutChangingTextOrUnrelatedLineBreaks() async throws {
        let full = String(repeating: "中", count: 35)
        let paragraphs = (0..<4).map { "\(full)\n收尾第\($0)段文字。" }
        let ascii = (0..<3).map { String(repeating: "X", count: 35) + "\nrow-\($0)" }.joined(separator: "\n\n")
        let text = paragraphs.joined(separator: "\n\n") + "\n\n" + ascii +
            "\n\n    let value = 1\n    print(value)\n\n春风\n秋月"
        let (_, view) = try await loadedReaderFixture(topic: ("/topic1.txt", Data(text.utf8)), home: "/topic1.txt")
        func sample() async throws -> [String: Any] {
            let value = try await evaluate("""
            const pre = document.querySelector('pre'), spans = [...pre.querySelectorAll('.sumra-chm-prose')];
            const lineTops = node => {
                const newline = node.data.indexOf('\\n'), range = document.createRange();
                range.setStart(node, 0); range.setEnd(node, 1); const first = range.getBoundingClientRect().top;
                range.setStart(node, newline + 1); range.setEnd(node, newline + 2);
                return [first, range.getBoundingClientRect().top];
            };
            const proseGeometry = span => {
                const before = span.firstChild, after = span.lastChild, range = document.createRange();
                range.setStart(before, 0); range.setEnd(before, 1);
                const first = range.getBoundingClientRect();
                range.setStart(before, before.length - 1); range.setEnd(before, before.length);
                const lastBefore = range.getBoundingClientRect();
                range.setStart(after, 0); range.setEnd(after, 1);
                const second = range.getBoundingClientRect();
                return {tops:[first.top, second.top], gap:second.left - lastBefore.right};
            };
            const code = [...pre.childNodes].find(node => node.nodeType === Node.TEXT_NODE && node.data.includes('let value'));
            const poem = [...pre.childNodes].find(node => node.nodeType === Node.TEXT_NODE && node.data.includes('春风'));
            const ascii = [...pre.childNodes].find(node => node.nodeType === Node.TEXT_NODE && node.data.includes('row-0'));
            const indexed = window.__sumatraFind.textFromBody(document.body);
            const softBreak = spans[2]?.querySelector('.sumra-chm-softbreak')?.firstChild;
            return {source:pre.textContent, searchable:indexed.text,
                proseCount:spans.length, firstStyle:spans[0] && getComputedStyle(spans[0]).whiteSpace,
                softBreaks:spans.map(span => [...span.querySelectorAll('.sumra-chm-softbreak')].map(node => node.textContent)),
                breakIndex:softBreak && (() => {
                    const prefix = document.createRange(); prefix.selectNodeContents(pre);
                    prefix.setEnd(softBreak, 0); return prefix.toString().length;
                })(),
                width:innerWidth, prose:spans[0] && proseGeometry(spans[0]), code:code && lineTops(code),
                poem:poem && lineTops(poem), ascii:ascii && lineTops(ascii)};
            """, in: view) as? [String: Any]
            return try XCTUnwrap(value)
        }
        try XCTUnwrap(view.window).setContentSize(CGSize(width: 1400, height: 500))
        let wide = try await sample()
        XCTAssertEqual(wide["source"] as? String, text)
        XCTAssertEqual(wide["searchable"] as? String, text)
        XCTAssertEqual(wide["proseCount"] as? Int, 4)
        XCTAssertEqual(wide["firstStyle"] as? String, "normal")
        XCTAssertEqual(wide["softBreaks"] as? [[String]], Array(repeating: ["\n"], count: 4))
        XCTAssertEqual(try XCTUnwrap(wide["breakIndex"] as? Int), (text as NSString).range(of: "\n收尾第2段文字").location)
        let wideProse = try XCTUnwrap(wide["prose"] as? [String: Any])
        let wideTops = try XCTUnwrap(wideProse["tops"] as? [Double])
        XCTAssertEqual(wideTops[0], wideTops[1], accuracy: 1, "Source line break should flow within the wide paragraph")
        XCTAssertEqual(try XCTUnwrap(wideProse["gap"] as? Double), 0, accuracy: 1,
            "A source hard wrap must not render a space between adjacent Han glyphs")
        for key in ["code", "poem", "ascii"] {
            let tops = try XCTUnwrap(wide[key] as? [Double])
            XCTAssertGreaterThan(tops[1], tops[0], key)
        }
        try XCTUnwrap(view.window).setContentSize(CGSize(width: 420, height: 500))
        let narrow = try await sample()
        XCTAssertEqual(narrow["source"] as? String, text)
        XCTAssertEqual(narrow["searchable"] as? String, text)
        let narrowProse = try XCTUnwrap(narrow["prose"] as? [String: Any])
        let narrowTops = try XCTUnwrap(narrowProse["tops"] as? [Double])
        XCTAssertGreaterThan(narrowTops[1], narrowTops[0], "Prose should wrap at the narrow viewport")
        _ = try await evaluate("""
        await window.__sumatraFind.start('中\\n收尾第2段文字',true,false,1);
        await window.leafCommand({name:'style',flow:'paged',spread:true,text:'serif|24|1.5|40|light'});
        """, in: view)
        let after = try await evaluate("""
        const range = window.__sumatraFind.currentRange();
        return {source:document.querySelector('pre').textContent,
            searchable:window.__sumatraFind.textFromBody(document.body).text,
            selected:range?.toString(), connected:range?.startContainer.isConnected && range?.endContainer.isConnected,
            startOffset:range?.startOffset, startText:range?.startContainer.data,
            endOffset:range?.endOffset, endText:range?.endContainer.data,
            columns:getComputedStyle(document.body).columnCount};
        """, in: view) as? [String: Any]
        XCTAssertEqual(after?["source"] as? String, text)
        XCTAssertEqual(after?["searchable"] as? String, text)
        XCTAssertEqual(after?["selected"] as? String, "中\n收尾第2段文字")
        XCTAssertEqual(after?["connected"] as? Bool, true)
        XCTAssertEqual(after?["startOffset"] as? Int, 34)
        XCTAssertEqual(after?["startText"] as? String, full)
        XCTAssertEqual(after?["endOffset"] as? Int, 7)
        XCTAssertEqual(after?["endText"] as? String, "收尾第2段文字。")
        XCTAssertEqual(after?["columns"] as? String, "2")
    }

    @MainActor
    func testIndentedDecoratedCHMTitleStaysCenteredInNarrowSpreadWithSourceOffsets() async throws {
        let indent = String(repeating: "\u{3000}", count: 14)
        let title = "【冲动的惩罚】"
        let ordinary = "\u{3000}\u{3000}普通段落仍有缩进。"
        let text = "\(indent)\(title)\n\n\n作者：不详\n\n\(ordinary)\n\n    let value = 1\n\n\u{3000}\u{3000}春风\n\u{3000}\u{3000}秋月"
        let (_, view) = try await loadedReaderFixture(topic: ("/topic1.txt", Data(text.utf8)), home: "/topic1.txt")
        try XCTUnwrap(view.window).setContentSize(CGSize(width: 700, height: 500))
        let result = try await evaluate("""
        await window.leafCommand({name:'style',flow:'paged',spread:true});
        const pre=document.querySelector('pre'), title=pre.querySelector('.sumra-chm-title');
        const indent=title?.querySelector('.sumra-chm-title-indent');
        const textNode=title?.lastChild, range=document.createRange();
        range.setStart(textNode,0);range.setEnd(textNode,1);
        const first=range.getBoundingClientRect();
        range.setStart(textNode,textNode.length-1);range.setEnd(textNode,textNode.length);
        const last=range.getBoundingClientRect();
        range.selectNodeContents(textNode);
        const glyphs=range.getBoundingClientRect(), box=title.getBoundingClientRect();
        const indexed=window.__sumatraFind.textFromBody(document.body);
        await window.__sumatraFind.start('【冲动的惩罚】',true,false,1);
        const match=window.__sumatraFind.currentRange();
        const ordinary=[...pre.childNodes].find(node=>node.nodeType===Node.TEXT_NODE && node.data.includes('普通段落'));
        range.setStart(ordinary,0);range.setEnd(ordinary,2);
        const ordinaryIndent=range.getBoundingClientRect();
        return {source:pre.textContent,searchable:indexed.text,
            titles:pre.querySelectorAll('.sumra-chm-title').length,indent:indent?.textContent,
            indentDisplay:indent && getComputedStyle(indent).display,
            columns:getComputedStyle(document.body).columnCount,font:getComputedStyle(pre).fontSize,
            titleWidth:box.width,viewport:innerWidth,centerGap:(glyphs.left+glyphs.right-box.left-box.right)/2,
            firstTop:first.top,lastTop:last.top,ordinaryIndentWidth:ordinaryIndent.width,
            selected:match?.toString(),startIndex:match && (() => {
                const prefix=document.createRange();prefix.selectNodeContents(pre);
                prefix.setEnd(match.startContainer,match.startOffset);return prefix.toString().length;
            })(),
            endOffset:match?.endOffset};
        """, in: view) as? [String: Any]
        XCTAssertEqual(result?["source"] as? String, text)
        XCTAssertEqual(result?["searchable"] as? String, text)
        XCTAssertEqual(result?["titles"] as? Int, 1)
        XCTAssertEqual(result?["indent"] as? String, indent)
        XCTAssertEqual(result?["indentDisplay"] as? String, "none")
        XCTAssertEqual(result?["columns"] as? String, "2")
        XCTAssertEqual(result?["font"] as? String, "17px")
        XCTAssertLessThan(try XCTUnwrap(result?["titleWidth"] as? Double), try XCTUnwrap(result?["viewport"] as? Double) / 2)
        XCTAssertEqual(try XCTUnwrap(result?["centerGap"] as? Double), 0, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(result?["firstTop"] as? Double), try XCTUnwrap(result?["lastTop"] as? Double), accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(result?["ordinaryIndentWidth"] as? Double), 20)
        XCTAssertEqual(result?["selected"] as? String, title)
        XCTAssertEqual(result?["startIndex"] as? Int, (text as NSString).range(of: title).location)
        XCTAssertEqual(result?["endOffset"] as? Int, (title as NSString).length)
    }

    @MainActor
    func testProseCHMWidthFitsViewportWithoutChangingAuthoredControls() async throws {
        let prose = String(repeating: "A long paragraph of words. ", count: 90)
        let html = """
        <meta charset=utf-8><style>body{width:500px;margin:12px;font:20px serif}
        #chapter{width:500px} p{font-size:22px}</style>
        <div id=chapter><h1>Chapter</h1><p>\(prose)</p></div>
        <form id=controls style="width:360px"><input value="Keep editing"></form>
        <table id=diagram style="width:360px"><tr><td>Diagram</td></tr></table>
        """
        let (_, view) = try await loadedReaderFixture(topic: ("/topic1.htm", Data(html.utf8)), home: "/topic1.htm")
        let result = try await evaluate("""
        const chapter = document.getElementById('chapter'), form = document.getElementById('controls');
        const table = document.getElementById('diagram');
        const sample = () => ({viewport:innerWidth, body:document.body.getBoundingClientRect().width,
            chapter:parseFloat(getComputedStyle(chapter).width), font:getComputedStyle(chapter.querySelector('p')).fontSize,
            form:form.getBoundingClientRect().width, table:table.getBoundingClientRect().width});
        const continuous = sample();
        await window.leafCommand({name:'style',flow:'paged',spread:false});
        const paged = sample();
        await window.leafCommand({name:'style',flow:'continuous',spread:false});
        return {continuous,paged,sameNode:chapter===document.getElementById('chapter'),
            input:form.querySelector('input').value};
        """, in: view) as? [String: Any]
        for key in ["continuous", "paged"] {
            let mode = try XCTUnwrap(result?[key] as? [String: Any])
            let viewport = try XCTUnwrap(mode["viewport"] as? Double)
            XCTAssertGreaterThan(try XCTUnwrap(mode["chapter"] as? Double), viewport * 0.8, key)
            XCTAssertLessThanOrEqual(try XCTUnwrap(mode["chapter"] as? Double), viewport, key)
            XCTAssertEqual(mode["font"] as? String, "22px", key)
            XCTAssertEqual(try XCTUnwrap(mode["form"] as? Double), 360, accuracy: 1, key)
            XCTAssertEqual(try XCTUnwrap(mode["table"] as? Double), 360, accuracy: 1, key)
        }
        XCTAssertEqual(result?["sameNode"] as? Bool, true)
        XCTAssertEqual(result?["input"] as? String, "Keep editing")
    }

    @MainActor
    func testChangingCHMFontOverridesDocumentStylesAndKeepsVisiblePassage() async throws {
        let chapters = (0..<25).map { index in
            "<p id=p\(index)>Passage \(index). " + String(repeating: "Words remain at the reading position. ", count: 15) + "</p>"
        }.joined()
        let html = "<style>body{font:11px monospace}</style>" + chapters
        let (state, view) = try await loadedReaderFixture(topic: ("/topic1.htm", Data(html.utf8)), home: "/topic1.htm")
        let before = try await evaluate("""
        document.getElementById('p12').scrollIntoView();
        return {font:getComputedStyle(document.body).fontSize,
            visible:document.getElementById('p12').getBoundingClientRect().top < innerHeight};
        """, in: view) as? [String: Any]
        XCTAssertEqual(before?["font"] as? String, "11px")
        XCTAssertEqual(before?["visible"] as? Bool, true)
        state.font = "serif"; state.fontSize = 28; state.lineHeight = 1.5
        state.applyTypography(overrideDocumentStyles: true)
        XCTAssertFalse(state.useDocumentCSS)
        let style = state.command
        XCTAssertEqual(style.action, .style)
        state.send(.copy)
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        coordinator.command = style.revision
        coordinator.deliver(style, to: view)
        try await waitForNextCommand(state, after: style.revision)
        let after = try await evaluate("""
        const passage = document.getElementById('p12'), body = getComputedStyle(document.body);
        const rect = passage.getBoundingClientRect();
        return {font:body.fontSize,family:body.fontFamily,line:body.lineHeight,
            visible:rect.bottom>0&&rect.top<innerHeight, sameNode:passage.isConnected};
        """, in: view) as? [String: Any]
        XCTAssertEqual(after?["font"] as? String, "28px")
        XCTAssertEqual(after?["family"] as? String, "serif")
        XCTAssertEqual(after?["line"] as? String, "42px")
        XCTAssertEqual(after?["visible"] as? Bool, true)
        XCTAssertEqual(after?["sameNode"] as? Bool, true)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSearchReusesReflowedCurrentCHMTopicAndNavigatesSiblingMatch() async throws {
        let full = String(repeating: "中", count: 35)
        let text = (0..<4).map { "\(full)\n收尾第\($0)段文字。" }.joined(separator: "\n\n")
        let needle = "中\n收尾第2段文字。"
        let (state, view) = try await loadedReaderFixture(topic: ("/active.txt", Data(text.utf8)),
            home: "/ACTIVE.TXT", additionalTopics: [("/sibling.txt", Data(needle.utf8))])
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        let result = try await evaluate("""
        const fetched = [], originalFetch = window.fetch;
        window.fetch = (...args) => { fetched.push(new URL(args[0],location.href).pathname); return originalFetch(...args); };
        try {
            await window.leafCommand({name:'find',text:needle,matchCase:true});
            return {fetched, prose:document.querySelectorAll('.sumra-chm-prose').length,
                source:document.querySelector('pre').textContent,
                match:window.__sumatraFind.currentRange()?.toString()};
        } finally { window.fetch = originalFetch; }
        """, in: view, arguments: ["needle": needle]) as? [String: Any]
        XCTAssertEqual(result?["prose"] as? Int, 4)
        XCTAssertEqual(result?["source"] as? String, text)
        XCTAssertEqual(result?["match"] as? String, needle)
        let fetched = try XCTUnwrap(result?["fetched"] as? [String])
        XCTAssertFalse(fetched.contains("/entry/active.txt"))
        XCTAssertEqual(fetched.filter { $0 == "/entry/sibling.txt" }.count, 1)
        try await waitUntil { state.searchResults.count == 2 || state.error != nil }
        XCTAssertEqual(state.searchResults.count, 2)
        let target = try XCTUnwrap(state.searchResults.first { $0.target.contains("sibling.txt") }?.target)
        XCTAssertTrue(target.contains("#sumra-search="))
        state.send(.href(target))
        let navigation = state.command
        coordinator.command = navigation.revision
        coordinator.deliver(navigation, to: view)
        try await waitUntil { coordinator.ready && coordinator.displayedURL?.path == "/entry/sibling.txt" || state.error != nil }
        let navigatedMatch = try await evaluate("return window.__sumatraFind.currentRange()?.toString()", in: view) as? String
        XCTAssertEqual(navigatedMatch, needle)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testCrossTopicSearchUsesDeclaredEncodingAndLiteralPlainText() async throws {
        let encoded = Data("<meta charset='windows-1252'><p>".utf8) + Data([0x63,0x61,0x66,0xe9]) + Data("</p>".utf8)
        let chinese = Data("<meta charset='gbk'><p>".utf8) + Data([0xb2,0xe2,0xca,0xd4]) + Data("</p>".utf8)
        let (state, view) = try await loadedReaderFixture(home: "/LEGACY.HTM", additionalTopics: [
            ("/legacy.htm", encoded), ("/chinese.htm", chinese), ("/literal.txt", Data("Keep <literal> intact".utf8))
        ])
        _ = try await evaluate("""
        window.searchFetches = [];
        const originalFetch = window.fetch;
        window.fetch = (...args) => { window.searchFetches.push(new URL(args[0],location.href).pathname); return originalFetch(...args); };
        """, in: view)
        _ = try await evaluate("await window.leafCommand({name:'find',text:'café'})", in: view)
        try await waitUntil { state.searchResults.count == 1 || state.error != nil }
        XCTAssertTrue(state.searchResults.first?.title.contains("café") == true)
        XCTAssertTrue(state.searchResults.first?.target.contains("legacy.htm") == true)
        _ = try await evaluate("await window.leafCommand({name:'find',text:'测试'})", in: view)
        try await waitUntil { state.searchResults.first?.target.contains("chinese.htm") == true || state.error != nil }
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertTrue(state.searchResults.first?.title.contains("测试") == true)
        _ = try await evaluate("await window.leafCommand({name:'find',text:'<literal>'})", in: view)
        try await waitUntil { state.searchResults.first?.target.contains("literal.txt") == true || state.error != nil }
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertTrue(state.searchResults.first?.title.contains("<literal>") == true)
        let fetched = try await evaluate("return window.searchFetches", in: view) as? [String]
        XCTAssertFalse(try XCTUnwrap(fetched).contains("/entry/legacy.htm"))
        XCTAssertEqual(fetched?.filter { $0 == "/entry/chinese.htm" }.count, 3)
        XCTAssertEqual(fetched?.filter { $0 == "/entry/literal.txt" }.count, 3)
        XCTAssertNil(state.error)
    }

    @MainActor
    func testCodepageFallbackIgnoresCharsetTextOutsideRealDeclarations() async throws {
        let word = Data([0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2]) // Привет, Windows-1251
        let html = Data("<p>charset=windows-1252</p><!-- <meta charset=windows-1252> --><script>window.example='<meta charset=windows-1252><?xml encoding=\"windows-1252\"?>'</script><p>".utf8) + word + Data("</p>".utf8)
        let toc = Data("<!-- <meta charset=windows-1252> --><ul><li><object><param name=Name value='".utf8) + word + Data("'><param name=Local value='topic.html'></object></ul>".utf8)
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", html), home: "/topic.html",
            additionalTopics: [("/other.html", html), ("/toc.hhc", toc)], lcid: 1049)
        guard case .browser(let source) = state.document?.content else { return XCTFail("Expected CHM reader") }
        let response = try await source.response(URL(string: "leaf://book/entry/topic.html")!)
        XCTAssertEqual(response.0, html, "Encoding detection must preserve original author bytes")
        let shown = try await evaluate("return document.body.innerText", in: view) as? String
        XCTAssertTrue(shown?.contains("Привет") == true, "Actual WebKit display must retain the CHM codepage")
        XCTAssertEqual(state.outline.first?.title, "Привет")
        _ = try await evaluate("await window.leafCommand({name:'find',text:'Привет'})", in: view)
        try await waitUntil { state.searchResults.count == 2 || state.error != nil }
        XCTAssertEqual(state.searchResults.count, 2, "Current and fetched topics must decode identically")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeNavigationLoadsAnImageTopicFromTheCHMResourceHandler() async throws {
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAP8AAP///ywAAAAAAQABAAACAkQBADs="))
        let (state, view) = try await loadedReaderFixture(topic: ("/photo0.gif", gif), home: "/photo0.gif")
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        XCTAssertEqual(state.count, 2)
        state.send(.page(1)); let page = state.command
        state.send(.href("leaf://book/entry/PHOTO0.GIF"))
        coordinator.command = page.revision; coordinator.deliver(page, to: view)
        try await waitForNextCommand(state, after: page.revision)
        try await waitUntil { state.page == 1 || state.error != nil }
        let image = state.command
        coordinator.command = image.revision; coordinator.deliver(image, to: view)
        try await waitUntil { state.page == 0 || state.error != nil }
        let shown = try await evaluate(#"""
        const doc = document;
        const image = doc.querySelector('img');
        await image.decode();
        return { source: image.src, width: image.naturalWidth, height: image.naturalHeight, text: doc.body.textContent };
        """#, in: view) as? [String: Any]
        XCTAssertEqual(shown?["source"] as? String, "leaf://book/entry/photo0.gif")
        XCTAssertEqual(shown?["width"] as? Int, 1)
        XCTAssertEqual(shown?["height"] as? Int, 1)
        XCTAssertEqual(shown?["text"] as? String, "")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testCurrentTopicRetainsPublisherLayoutAndReaderThemeDuringPrintPreparation() async throws {
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAP8AAP///ywAAAAAAQABAAACAkQBADs="))
        let html = """
        <link rel="stylesheet" href="styles/book.css"><body style="margin:11px 13px;padding:7px 9px">
        <p class="published">Current topic</p>
        <input id="field" value="original"><script>document.body.dataset.codeRan='yes'</script>
        <img id="loaded" src="data:image/gif;base64,R0lGODlhAQABAIAAAP8AAP///ywAAAAAAQABAAACAkQBADs=">
        <div style="height:100000px"></div><img id="deferred" loading="LaZy" src="images/print.gif" width="1" height="1">
        """
        let css = """
        body{font-family:serif;font-size:23px;line-height:1.25;color:rgb(40,50,60);background:rgb(240,230,220)}
        .published{font-size:29px;color:rgb(10,20,30)}
        img[loading="lazy" i]{width:24px;height:18px;background:blue}
        img[loading="eager" i]{width:80px;height:60px;background:red}
        """
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html",
            additionalTopics: [
                ("/styles/book.css", Data(css.utf8)),
                ("/images/print.gif", gif),
                ("/unopened.html", Data("<p>Unopened topic</p>".utf8))
            ])
        let result = try await evaluate("""
        const bodyStyle = () => {
            const css = getComputedStyle(document.body);
            return { font:css.fontFamily, size:css.fontSize, line:css.lineHeight, margin:css.margin,
                padding:css.padding, color:css.color, background:css.backgroundColor };
        };
        const imageStyle = item => {
            const css = getComputedStyle(item);
            return { loading:item.getAttribute('loading'), width:css.width, height:css.height, background:css.backgroundColor };
        };
        const loaded = document.getElementById('loaded');
        await loaded.decode();
        loaded.setAttribute('loading', 'LaZy');
        const loadedBefore = imageStyle(loaded);
        document.getElementById('field').value = 'edited';
        scrollTo(0, 200);
        const before = performance.getEntriesByType('resource').map(entry => entry.name);
        const image = document.getElementById('deferred');
        const deferred = { offscreen:image.getBoundingClientRect().top > innerHeight, loaded:image.complete, y:scrollY, style:imageStyle(image) };
        window.leafCapturePrintViewport();
        await window.leafPreparePrint();
        const original = { font:getComputedStyle(document.querySelector('.published')).fontSize,
            color:getComputedStyle(document.querySelector('.published')).color,
            value:document.getElementById('field').value, executed:document.body.dataset.codeRan === 'yes',
            before, after:performance.getEntriesByType('resource').map(entry => entry.name), body:bodyStyle(),
            deferred, loadedBefore, loadedAfter:imageStyle(loaded),
            printedImage:{ loaded:image.complete, width:image.naturalWidth, height:image.naturalHeight, y:scrollY, style:imageStyle(image) } };
        const viewportRestored = await window.leafRestorePrintViewport();
        const restoredImages = { loaded:imageStyle(loaded), deferred:imageStyle(image), y:scrollY };
        await window.leafCommand({ name:'style', text:'monospace|20|1.5|24|light', useDocumentCSS:false });
        const reading = bodyStyle();
        await window.leafCommand({ name:'style', useDocumentCSS:true, pageMargins:[3,6,9,12] });
        const margins = bodyStyle();
        await window.leafCommand({ name:'style', pageMargins:[], userCSS:customCSS });
        const custom = bodyStyle();
        const customPublishedColor = getComputedStyle(document.querySelector('.published')).color;
        await window.leafCommand({ name:'style', userCSS:lightCSS });
        return { ...original, viewportRestored, restoredImages, reading, margins, custom, customPublishedColor, restored:bodyStyle() };
        """, in: view, arguments: [
            "lightCSS": ReaderTheme.all[0].css,
            "customCSS": try XCTUnwrap(ReaderTheme.resolve("dark")).css + "\nbody{font-size:27px!important;padding:5px!important;color:rgb(50,60,70)!important}.published{color:rgb(70,80,90)!important}"
        ]) as? [String: Any]
        XCTAssertEqual(result?["font"] as? String, "29px")
        XCTAssertEqual(result?["color"] as? String, "rgb(0, 0, 0)", "Reader theme overrides publisher text colors while preserving its font size")
        XCTAssertEqual(result?["value"] as? String, "edited")
        XCTAssertEqual(result?["executed"] as? Bool, true)
        XCTAssertEqual(result?["before"] as? [String], (result?["after"] as? [String])?.filter { !$0.hasSuffix("/images/print.gif") })
        XCTAssertFalse((result?["after"] as? [String] ?? []).contains { $0.contains("unopened.html") })
        let deferred = result?["deferred"] as? [String: Any], printedImage = result?["printedImage"] as? [String: Any]
        XCTAssertEqual(deferred?["offscreen"] as? Bool, true)
        XCTAssertEqual(deferred?["loaded"] as? Bool, false)
        XCTAssertEqual(printedImage?["loaded"] as? Bool, true)
        XCTAssertEqual(printedImage?["width"] as? Int, 1)
        XCTAssertEqual(printedImage?["height"] as? Int, 1)
        XCTAssertEqual(printedImage?["y"] as? Double, deferred?["y"] as? Double, "Preparing a lazy image must not move the reading viewport")
        let imageStyle = ["loading": "LaZy", "width": "24px", "height": "18px", "background": "rgba(0, 0, 0, 0)"]
        XCTAssertEqual(result?["loadedBefore"] as? [String: String], imageStyle)
        XCTAssertEqual(result?["loadedAfter"] as? [String: String], imageStyle, "A completed image retains its authored attribute and geometry with the reader theme")
        XCTAssertEqual(deferred?["style"] as? [String: String], imageStyle)
        XCTAssertEqual(printedImage?["style"] as? [String: String], imageStyle, "Starting a deferred request retains its authored attribute and geometry with the reader theme")
        XCTAssertEqual(result?["viewportRestored"] as? Bool, true)
        let restoredImages = result?["restoredImages"] as? [String: Any]
        XCTAssertEqual(restoredImages?["loaded"] as? [String: String], imageStyle)
        XCTAssertEqual(restoredImages?["deferred"] as? [String: String], imageStyle)
        XCTAssertEqual(restoredImages?["y"] as? Double, deferred?["y"] as? Double)
        let authored = result?["body"] as? [String: String]
        XCTAssertEqual(authored, ["font": "serif", "size": "23px", "line": "28.75px", "margin": "11px 13px",
                                  "padding": "7px 9px", "color": "rgb(0, 0, 0)", "background": "rgb(255, 255, 255)"])
        let reading = result?["reading"] as? [String: String]
        XCTAssertEqual(reading?["font"], "monospace")
        XCTAssertEqual(reading?["size"], "20px")
        XCTAssertEqual(reading?["line"], "30px")
        XCTAssertEqual(reading?["padding"], "24px")
        let margins = result?["margins"] as? [String: String]
        XCTAssertEqual(margins?["size"], "23px")
        XCTAssertEqual(margins?["margin"], "11px 13px")
        XCTAssertEqual(margins?["padding"], "4px 8px 12px 16px")
        let custom = result?["custom"] as? [String: String]
        XCTAssertEqual(custom?["font"], "serif")
        XCTAssertEqual(custom?["size"], "27px")
        XCTAssertEqual(custom?["padding"], "5px")
        XCTAssertEqual(custom?["color"], "rgb(50, 60, 70)")
        XCTAssertEqual(custom?["background"], "rgb(0, 0, 0)")
        XCTAssertEqual(result?["customPublishedColor"] as? String, "rgb(70, 80, 90)", "Explicit user CSS takes precedence over the reader palette")
        XCTAssertEqual(result?["restored"] as? [String: String], authored)
        XCTAssertTrue(state.isCHM)
        XCTAssertTrue(state.supportsPagination)
    }

    @MainActor
    func testPrintPreparationPreservesAuthoredLoadingChangeWhileImageLoads() async throws {
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAP8AAP///ywAAAAAAQABAAACAkQBADs="))
        let html = """
        <div style="height:100000px"></div><img id="deferred" loading="LaZy" src="images/authored.gif">
        """
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html",
            additionalTopics: [("/images/authored.gif", gif)])
        let result = try await evaluate("""
        const image = document.getElementById('deferred');
        const before = image.complete;
        image.addEventListener('load', () => image.setAttribute('loading', 'eager'), { once:true });
        window.leafCapturePrintViewport();
        await window.leafPreparePrint();
        const prepared = image.getAttribute('loading');
        const restored = await window.leafRestorePrintViewport();
        return { before, prepared, restored, after:image.getAttribute('loading'), width:image.naturalWidth, height:image.naturalHeight };
        """, in: view) as? [String: Any]
        XCTAssertEqual(result?["before"] as? Bool, false)
        XCTAssertEqual(result?["width"] as? Int, 1)
        XCTAssertEqual(result?["height"] as? Int, 1)
        XCTAssertEqual(result?["prepared"] as? String, "eager")
        XCTAssertEqual(result?["restored"] as? Bool, true)
        XCTAssertEqual(result?["after"] as? String, "eager", "Print cleanup must not overwrite an authored change made while loading")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testAuthorScriptsToggleContentWithoutAccessToTheNativeBridge() async throws {
        let html = """
        <button id="toggle" onclick="document.getElementById('details').hidden=!document.getElementById('details').hidden">Toggle</button>
        <div id="details" hidden>Expanded topic</div>
        <a id="script-link" href="javascript:void(document.getElementById('details').hidden=true)">Collapse</a>
        <script src="scripts/book.js"></script>
        <script>
        try {
            window.webkit.messageHandlers.leaf.postMessage({type:'status',message:'Author reached native bridge'});
            document.body.dataset.bridge='reachable';
        } catch { document.body.dataset.bridge='isolated'; }
        </script>
        """
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html",
            additionalTopics: [("/scripts/book.js", Data("document.body.dataset.externalScript='loaded'".utf8))])
        let result = try await evaluate("""
        const details=document.getElementById('details');
        const before=details.hidden;
        document.getElementById('toggle').click();
        const after=details.hidden;
        document.getElementById('script-link').click();
        return { before,after,bridge:document.body.dataset.bridge,external:document.body.dataset.externalScript };
        """, in: view) as? [String: Any]
        XCTAssertEqual(result?["before"] as? Bool, true)
        XCTAssertEqual(result?["after"] as? Bool, false)
        XCTAssertEqual(result?["bridge"] as? String, "isolated")
        XCTAssertEqual(result?["external"] as? String, "loaded")
        XCTAssertNotEqual(state.status, "Author reached native bridge")
        let collapsed = try await evaluate("return document.getElementById('details').hidden", in: view) as? Bool
        XCTAssertEqual(collapsed, true)
        _ = try await evaluate("""
        await window.leafCommand({name:'interaction',flags:{disableLinks:true}});
        document.getElementById('toggle').click();
        document.getElementById('script-link').click();
        """, in: view)
        let disabled = try await evaluate("return document.getElementById('details').hidden", in: view) as? Bool
        XCTAssertEqual(disabled, false, "Disable Links also stops author javascript links")
    }

    @MainActor
    func testFramesKeepNativeTargetsRelativeResourcesFocusAndContainerIdentity() async throws {
        let html = "<frameset cols='*'><frame name='topic' src='parts/body.html'></frameset>"
        let (state, view) = try await loadedReaderFixture(topic: ("/frame.html", Data(html.utf8)), home: "/frame.html",
            additionalTopics: [
                ("/parts/body.html", Data("<link rel='stylesheet' href='topic.css'><p>Frame body</p><a href='next.html'>Next frame</a>".utf8)),
                ("/parts/next.html", Data("<p id='text'>Current frame topic</p><input id='field'>".utf8)),
                ("/parts/topic.css", Data("p{font-size:27px}".utf8))
            ])
        let original = try XCTUnwrap(state.document)
        let first = try await evaluate("""
        const doc = document.querySelector('frame').contentDocument;
        return { text:doc.querySelector('p').textContent, font:doc.defaultView.getComputedStyle(doc.querySelector('p')).fontSize };
        """, in: view) as? [String: Any]
        XCTAssertEqual(first?["text"] as? String, "Frame body")
        XCTAssertEqual(first?["font"] as? String, "27px")
        _ = try await evaluate("""
        const frame = document.querySelector('frame');
        await new Promise(resolve => { frame.addEventListener('load', resolve, {once:true}); frame.contentDocument.querySelector('a').click(); });
        await frame.contentWindow.leafPreparePrint();
        frame.contentDocument.getElementById('field').focus();
        """, in: view)
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        try await waitUntil { coordinator.textInputFocused }
        XCTAssertEqual(view.url?.path, "/entry/frame.html")
        XCTAssertEqual(state.page, 0)
        XCTAssertEqual(state.document?.id, original.id)
        XCTAssertEqual(state.document?.url, original.url)
        let printedTopic = try await evaluate("""
        await window.leafPreparePrint();
        return document.querySelector('frame').contentDocument.getElementById('text').textContent;
        """, in: view) as? String
        XCTAssertEqual(printedTopic, "Current frame topic", "Printing retains the currently navigated frame, not its original src")
        _ = try await evaluate("""
        const frame = document.querySelector('frame'), doc = frame.contentDocument, text = doc.getElementById('text');
        text.tabIndex = 0; text.focus();
        const range = doc.createRange(); range.selectNodeContents(text);
        frame.contentWindow.getSelection().removeAllRanges(); frame.contentWindow.getSelection().addRange(range);
        """, in: view)
        try await waitUntil { state.hasSelection }
        let selected = try await state.selectionText()
        XCTAssertEqual(selected, "Current frame topic")
        let documentText = try await state.documentText()
        XCTAssertEqual(documentText, selected, "Document actions must consume the focused child frame's selection")
        let retained = try await evaluate("""
        document.body.tabIndex = 0; document.body.focus();
        return document.activeElement === document.body && !document.querySelector('frame').contentWindow.getSelection().isCollapsed;
        """, in: view) as? Bool
        XCTAssertEqual(retained, true, "Returning focus to the container must retain the child frame's selection")
        let unfocusedSelection = try await state.selectionText()
        XCTAssertEqual(unfocusedSelection, selected)
        let unfocusedDocumentText = try await state.documentText()
        XCTAssertEqual(unfocusedDocumentText, selected)
        _ = try await evaluate("document.querySelector('frame').contentWindow.getSelection().removeAllRanges()", in: view)
        try await waitUntil { !state.hasSelection }
    }

    @MainActor
    func testTopicRestoreUsesBrowserCoordinatesAndOldCFIFallsBackToItsTopic() async throws {
        let text = (0..<150).map { "<p>Line \($0)</p>" }.joined()
        let (state, view) = try await loadedReaderFixture(topic: ("/second.htm", Data(text.utf8)))
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        state.restore(.init(page: 1, x: 0, y: 430, anchor: "leaf://book/entry/second.htm"))
        let command = state.command
        state.send(.selectAll)
        coordinator.command = command.revision; coordinator.deliver(command, to: view)
        try await waitForNextCommand(state, after: command.revision)
        XCTAssertTrue(coordinator.ready)
        XCTAssertEqual(state.page, 1)
        let y = try await evaluate("return scrollY", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(y), 430, accuracy: 2)
        coordinator.deliver(state.command, to: view)
        try await waitUntil { state.hasSelection }
        let selected = try await state.selectionText()
        XCTAssertTrue(selected.contains("Line 149"))
        XCTAssertEqual(state.document?.url.pathExtension, "chm")
        BrowserReader.dismantleNSView(view, coordinator: coordinator)
        let fallback = BrowserReader.Coordinator(state: state, source: coordinator.source)
        let reopened = fallback.makeView(frame: view.frame, position: .init(page: 1, anchor: "epubcfi(/6/4!/4/2)"))
        defer { BrowserReader.dismantleNSView(reopened, coordinator: fallback) }
        fallback.load(reopened)
        try await waitUntil { fallback.ready || fallback.readerError != nil }
        XCTAssertNil(fallback.readerError)
        XCTAssertEqual(reopened.url?.path, "/entry/second.htm")
    }

    @MainActor
    func testExplicitFragmentsAndCachedHistoryLeaveAuthorNavigationAndUserScrollAvailable() async throws {
        let paragraphs = (0..<80).map { "<p>Paragraph \($0) of the surrounding text.</p>" }.joined()
        let topic = "<title>First</title>" + paragraphs + "<a id='middle'></a><h2>Middle</h2>"
            + paragraphs + "<h2 id='later'>Later</h2>" + paragraphs
        let second = "<title>Second</title>" + paragraphs + "<h2 id='middle'>Second middle</h2>" + paragraphs
        let firstURL = "leaf://book/entry/first.html"
        let (state, view) = try await loadedReaderFixture(topic: ("/first.html", Data(topic.utf8)), home: "/first.html",
            additionalTopics: [("/second.htm", Data(second.utf8))],
            position: .init(page: 0, x: 0, y: 5, anchor: firstURL + "#middle"))
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        func finishCommand() async throws {
            let command = state.command
            state.send(.none)
            coordinator.command = command.revision
            coordinator.deliver(command, to: view)
            try await waitForNextCommand(state, after: command.revision)
            XCTAssertTrue(coordinator.ready)
            XCTAssertNil(state.error)
            coordinator.deliver(state.command, to: view)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        XCTAssertNil(view.url?.fragment, "An explicit initial fragment is carried by the reading position")
        let initialTop = try await evaluate("return document.getElementById('middle').getBoundingClientRect().top", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(initialTop), 0, accuracy: 2)
        let requestedAuthorY = try await evaluate("window.cacheMarker='first'; const y=scrollY+document.getElementById('later').getBoundingClientRect().top; location.hash='#later'; return y", in: view) as? Double
        let authorY = try XCTUnwrap(requestedAuthorY)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - authorY) < 2 }
        let authorTop = try await evaluate("return document.getElementById('later').getBoundingClientRect().top", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(authorTop), 0, accuracy: 2, "Manual history restoration must retain ordinary fragment navigation")
        _ = try await evaluate("scrollTo(0,200)", in: view)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - 200) < 2 }
        state.navigate(.href("leaf://book/entry/second.htm#middle"))
        try await finishCommand()
        XCTAssertEqual(view.url?.path, "/entry/second.htm")
        XCTAssertNil(view.url?.fragment)
        let secondTop = try await evaluate("return document.getElementById('middle').getBoundingClientRect().top", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(secondTop), 0, accuracy: 2)
        _ = try await evaluate("window.cacheMarker='second'; scrollTo(0,600)", in: view)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - 600) < 2 }
        state.navigateHistory(-1)
        try await finishCommand()
        let back = try await evaluate("return {marker:window.cacheMarker,y:scrollY}", in: view) as? [String: Any]
        XCTAssertEqual(back?["marker"] as? String, "first")
        XCTAssertEqual(try XCTUnwrap(back?["y"] as? Double), 200, accuracy: 2, "A cached native hash must not overwrite saved coordinates")
        state.navigateHistory(1)
        try await finishCommand()
        let forward = try await evaluate("return {marker:window.cacheMarker,y:scrollY}", in: view) as? [String: Any]
        XCTAssertEqual(forward?["marker"] as? String, "second")
        XCTAssertEqual(try XCTUnwrap(forward?["y"] as? Double), 600, accuracy: 2)
        state.restore(.init(page: 0, x: 0, y: 5, anchor: firstURL + "#middle", zoom: 1.3))
        try await finishCommand()
        let restoredTop = try await evaluate("const offset=visualViewport.offsetTop; return document.getElementById('middle').getBoundingClientRect().top-offset", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(restoredTop), 0, accuracy: 2, "An explicit fragment must win over the cached item's hash and coordinates")
        XCTAssertEqual(view.pageZoom, 1.3, accuracy: 0.001)
        // The cached URL already has #later. An author setting the same hash is
        // a no-op; visit another fragment before checking author navigation again.
        _ = try await evaluate("""
        await new Promise(resolve => {
            addEventListener('hashchange', resolve, { once: true });
            location.hash = '#middle';
        });
        """, in: view)
        let laterY = try await evaluate("const y=visualViewport.pageTop-visualViewport.offsetTop+document.getElementById('later').getBoundingClientRect().top; location.hash='#later'; return y", in: view) as? Double
        let restoredAuthorY = try XCTUnwrap(laterY)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - restoredAuthorY) < 2 }
        let laterTop = try await evaluate("return document.getElementById('later').getBoundingClientRect().top", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(laterTop), 0, accuracy: 2)
        _ = try await evaluate("scrollTo(0,300)", in: view)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - 300) < 2 }
    }

    @MainActor
    func testHomeThumbnailRendersCHMWithoutSavingThePreviewPosition() async throws {
        let (state, coordinator, view) = try bridgeFixture()
        defer { BrowserReader.dismantleNSView(view, coordinator: coordinator) }
        let url = try XCTUnwrap(state.document?.url), key = "position:" + url.path
        let defaults = UserDefaults.standard, saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        let preferences: [String: Any] = ["theme": "dark", "fontSize": 36.0, "zoom": 4.0,
            "userCSS": "html{visibility:hidden!important}", "useDocumentCSS": false]
        let previous = preferences.keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (name, value) in previous { defaults.set(value, forKey: name) } }
        for (name, value) in preferences { defaults.set(value, forKey: name) }
        let sentinel = Data("saved reading position".utf8)
        defaults.set(sentinel, forKey: key)
        let rendered = try await BrowserReader.thumbnail(coordinator.source, size: CGSize(width: 136, height: 168))
        let image = try XCTUnwrap(rendered), pixels = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(image.width, 136)
        XCTAssertEqual(image.height, 168)
        var hasText = false
        for y in 0..<pixels.pixelsHigh {
            for x in 0..<pixels.pixelsWide {
                if let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.9,
                   min(color.redComponent, min(color.greenComponent, color.blueComponent)) < 0.7 { hasText = true; break }
            }
            if hasText { break }
        }
        XCTAssertTrue(hasText, "The home topic must be painted, not a blank browser surface")
        XCTAssertEqual(defaults.data(forKey: key), sentinel)
        XCTAssertEqual(defaults.string(forKey: "userCSS"), preferences["userCSS"] as? String,
            "Preview overrides must not modify reader preferences")
        let background = try XCTUnwrap(pixels.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(min(background.redComponent, min(background.greenComponent, background.blueComponent)), 0.9)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ReadError("Reader did not complete the expected operation")
    }

    @MainActor
    func testBrowserSearchPreservesSelectionAndUsesClickedResultAsNextOrigin() async throws {
        let (state, view) = try await loadedReaderFixture()
        let selected = try await evaluate("""
        const range = document.createRange(); range.selectNodeContents(document.querySelector('font'));
        window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
        await window.leafCommand({name:'find', text:'o'});
        return window.getSelection().toString();
        """, in: view) as? String
        try await waitUntil { state.searchResults.count == 3 || state.error != nil }
        let targets = state.searchResults.map(\.target)
        _ = try XCTUnwrap(targets.count == 3 ? true : nil)
        _ = try await evaluate("await window.leafCommand({name:'href',text:target})", in: view, arguments: ["target": targets[1]])
        try await waitUntil { state.selectedSearchTarget == targets[1] }
        let after = try await evaluate("return window.getSelection().toString()", in: view) as? String
        XCTAssertEqual(after, selected, "Search highlighting must not replace the user's selected text")
        _ = try await evaluate("await window.leafCommand({name:'find',text:'o'})", in: view)
        try await waitUntil { state.selectedSearchTarget == targets[2] }
        _ = try await evaluate("await window.leafCommand({name:'find',text:'o',backwards:true})", in: view)
        try await waitUntil { state.selectedSearchTarget == targets[1] }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSharedBrowserSearchPublishesAndClearsCappedCounts() async throws {
        let html = "<p>" + String(repeating: "needle ", count: 5001) + "rare</p>"
        let (state, view) = try await loadedReaderFixture(topic: ("/first.html", Data(html.utf8)), home: "/first.html")
        _ = try await evaluate("""
        await window.leafCommand({name:'find',text:'needle'});
        """, in: view)
        try await waitUntil { state.searchResults.count == 5000 && state.selectedSearchTarget != nil }
        XCTAssertTrue(state.searchCountCapped)
        XCTAssertEqual(state.searchCountText, "1 / 5000+")
        XCTAssertEqual(state.status, "1 / 5000+ matches")
        _ = try await evaluate("await window.leafCommand({name:'toc'})", in: view)
        try await waitUntil { state.searchResults.isEmpty }
        XCTAssertFalse(state.searchCountCapped)
        _ = try await evaluate("await window.leafCommand({name:'find',text:'rare'})", in: view)
        try await waitUntil { state.searchResults.count == 1 && state.selectedSearchTarget != nil }
        XCTAssertFalse(state.searchCountCapped)
        XCTAssertEqual(state.searchCountText, "1 / 1")
        XCTAssertEqual(state.status, "1 / 1 matches")
        XCTAssertNil(state.error)
    }

    @MainActor
    func testSearchCancellationLeavesTheBrowserReadyForANewQuery() async throws {
        let (state, view) = try await loadedReaderFixture()
        _ = try await evaluate("""
        window.originalSearchAll = window.__sumatraFind.searchAll;
        window.__sumatraFind.searchAll = async (...args) => {
            window.pendingSearchGeneration = args[4];
            await new Promise(resolve => { window.continueSearch = resolve; });
            return await window.originalSearchAll(...args);
        };
        window.pendingSearch = window.leafCommand({name:'find',text:'o'});
        """, in: view)
        _ = try await evaluate("""
        await window.leafCommand({name:'toc'});
        window.continueSearch(); await window.pendingSearch;
        window.__sumatra__.notify('findAllResult', window.pendingSearchGeneration, 1, '1\\x1f0\\x1fstale', true);
        window.__sumatraFind.searchAll = window.originalSearchAll;
        """, in: view)
        try await waitUntil { state.searchResults.isEmpty && state.selectedSearchTarget == nil }
        XCTAssertFalse(state.searchCountCapped)
        _ = try await evaluate("await window.leafCommand({name:'find',text:'o'})", in: view)
        try await waitUntil { state.searchResults.count == 3 && state.selectedSearchTarget != nil }
        XCTAssertNil(state.error)
    }

    @MainActor
    func testNativeTypingGuardUsesCurrentWebFocusAndIgnoresStaleReaders() throws {
        let (state, coordinator, view) = try bridgeFixture()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.navigationDelegate = coordinator
        defer {
            window.makeFirstResponder(nil)
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            window.contentView = nil; window.close()
        }
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertFalse(ReaderWindows.isTyping(in: window, state: state))
        coordinator.textInputFocused = true
        XCTAssertTrue(ReaderWindows.isTyping(in: window, state: state), "HTML input must retain typing and middle-button events")
        coordinator.textInputFocused = false
        XCTAssertFalse(ReaderWindows.isTyping(in: window, state: state), "Body reading retains navigation keys")
        coordinator.textInputFocused = true
        coordinator.active = false
        XCTAssertFalse(ReaderWindows.isTyping(in: window, state: state))
    }

    @MainActor
    private func waitForNextCommand(_ state: ReaderState, after revision: Int) async throws {
        for _ in 0..<200 {
            if state.command.revision != revision { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ReadError("CHM command did not acknowledge its completion")
    }

    @MainActor
    func testPrintPreparationRetainsEachActionAndFailureReleasesNextPrint() async throws {
        let (state, coordinator, view) = try bridgeFixture()
        defer { BrowserReader.dismantleNSView(view, coordinator: coordinator) }
        _ = try await evaluate("window.leafCapturePrintViewport = () => {}; window.leafRestorePrintViewport = () => true; window.leafPreparePrint = () => new Promise((resolve, reject) => { window.rejectPrint = reject });", in: view)
        state.send(.print); let first = state.command
        state.send(.print); state.send(.copy)
        coordinator.command = first.revision
        coordinator.deliver(first, to: view)
        XCTAssertEqual(coordinator.printJob?.command.action, .print)
        XCTAssertEqual(state.command.revision, first.revision)
        _ = try await evaluate("window.rejectPrint(new Error('Fixture print failed'));", in: view)
        try await waitForNextCommand(state, after: first.revision)
        XCTAssertEqual(state.command.action, .print)
        XCTAssertTrue(state.error?.contains("Fixture print failed") == true)
        XCTAssertNil(coordinator.printJob)
        coordinator.completeCommand(first.revision, error: NSError(domain: "Stale failure", code: 1))
        XCTAssertTrue(state.error?.contains("Fixture print failed") == true)

        _ = try await evaluate("window.leafPreparePrint = async () => { throw Error('Second print failed') };", in: view)
        let second = state.command
        coordinator.command = second.revision
        coordinator.deliver(second, to: view)
        XCTAssertEqual(coordinator.printJob?.command.action, .print)
        try await waitForNextCommand(state, after: second.revision)
        XCTAssertEqual(state.command.action, .copy)
        XCTAssertTrue(state.error?.contains("Second print failed") == true)
        XCTAssertNil(coordinator.printJob)
    }

    @MainActor
    func testBrowserPDFOutputContainsLiveTopicAndPrintStylesBeforeReleasingQueue() async throws {
        let html = """
        <meta charset="utf-8">
        <style>.print-only {display:none} @media print {
          .screen-only {display:none} .print-only {display:block}
        }</style>
        <div style="break-after:page"><p>First topic 目入文门 ⽬⼊⽂⻔</p><input id="field" value="original">
        <iframe id="child" src="child.htm"></iframe>
        <p class="screen-only">Screen only text</p><p class="print-only">Printed stylesheet</p></div>
        <p>End of topic</p>
        """
        let child = "<p>子页目入文门</p><input id=field value=original>"
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(936)))
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html",
            additionalTopics: [("/child.htm", try XCTUnwrap(child.data(using: encoding)))], lcid: 2052)
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        _ = try XCTUnwrap(view.window)
        let captured = try await evaluate("""
        const frame = document.getElementById('child');
        if (frame.contentDocument.readyState !== 'complete') await new Promise(resolve => frame.addEventListener('load', resolve, {once:true}));
        document.getElementById('field').value = 'Edited live value';
        frame.contentDocument.getElementById('field').value = 'Edited child field';
        window.leafCapturePrintViewport(); await window.leafPreparePrint();
        return window.leafPrintSnapshot();
        """, in: view)
        let snapshot = try JSONDecoder().decode(BrowserPrintSnapshot.self, from: JSONSerialization.data(withJSONObject: captured))
        guard case .browser(let source) = state.document?.content else { return XCTFail("Expected browser source") }
        let directory = try TemporaryDirectory()
        let prepared = try await snapshot.makePDF(source: source, directory: directory.url)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-browser-print-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        state.send(.exportPDF); let command = state.command
        state.send(.copy)
        coordinator.command = command.revision
        let info = state.printInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let job = BrowserReader.Coordinator.PrintJob(command: command, url: view.url, info: info)
        coordinator.printJob = job
        coordinator.runPreparedPrint(prepared.url, count: prepared.count, directory: directory, info: info, in: view, job: job)
        try await waitForNextCommand(state, after: command.revision)
        XCTAssertNil(coordinator.printJob)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.command.action, .copy)
        let pdf = try NativeFile(output, engine: .mupdf)
        XCTAssertEqual(pdf.count, 2)
        let first = try XCTUnwrap(pdf.text(0)), last = try XCTUnwrap(pdf.text(1))
        XCTAssertTrue(first.contains("First topic"), first)
        XCTAssertTrue(first.contains("Edited live value"), first)
        XCTAssertTrue(first.contains("Printed stylesheet"), first)
        XCTAssertFalse(first.contains("Screen only text"), first)
        XCTAssertTrue(last.contains("End of topic"), last)
        XCTAssertTrue(first.contains("目入文门"), first)
        XCTAssertTrue(first.contains("⽬⼊⽂⻔"), first)
        XCTAssertTrue(first.contains("子页目入文门"), first)
        XCTAssertTrue(first.contains("Edited child field"), first)
        let copied = try XCTUnwrap(PDFDocument(url: output)?.string)
        XCTAssertTrue(copied.contains("目入文门"), copied)
        XCTAssertTrue(copied.contains("⽬⼊⽂⻔"), copied)
    }

    @MainActor
    func testInvalidatedBrowserPrintKeepsQueueUntilNativeCompletion() async throws {
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data("<p>Started topic</p>".utf8)), home: "/topic.html")
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        let captured = try await evaluate("window.leafCapturePrintViewport(); await window.leafPreparePrint(); return window.leafPrintSnapshot()", in: view)
        let snapshot = try JSONDecoder().decode(BrowserPrintSnapshot.self, from: JSONSerialization.data(withJSONObject: captured))
        guard case .browser(let source) = state.document?.content else { return XCTFail("Expected browser source") }
        let directory = try TemporaryDirectory()
        let prepared = try await snapshot.makePDF(source: source, directory: directory.url)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-browser-print-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        state.send(.exportPDF); let command = state.command
        state.send(.print)
        coordinator.command = command.revision
        let info = state.printInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let job = BrowserReader.Coordinator.PrintJob(command: command, url: view.url, info: info)
        coordinator.printJob = job
        coordinator.runPreparedPrint(prepared.url, count: prepared.count, directory: directory, info: info, in: view, job: job)
        coordinator.finishPrint(job, error: ReadError("The displayed topic changed before printing completed."), restore: false)
        XCTAssertEqual(state.command.revision, command.revision, "An invalidated job must still prevent a second print from starting")
        try await waitForNextCommand(state, after: command.revision)
        XCTAssertEqual(state.command.action, .print)
        XCTAssertTrue(state.error?.contains("topic changed") == true)
        XCTAssertNil(coordinator.printOperation)
        let pdf = try NativeFile(output, engine: .mupdf)
        XCTAssertTrue(try XCTUnwrap(pdf.text(0)).contains("Started topic"))
    }

    @MainActor
    func testPrintCancellationRestoresLiveMainAndFrameViewportBeforeQueuedScroll() async throws {
        let html = """
        <body style="width:1600px"><input id="field" value="original">
        <iframe id="child" src="child.htm" style="width:500px;height:220px"></iframe>
        <div style="height:3200px"></div><p>End of topic</p>
        """
        let child = "<body><div style='width:1200px;height:1800px'></div><p>End of frame</p></body>"
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html",
            additionalTopics: [("/child.htm", Data(child.utf8))])
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        view.pageZoom = 1.5
        let beforeValue = try await evaluate("""
        const frame = document.getElementById('child');
        await new Promise(resolve => { if (frame.contentDocument?.readyState === 'complete') resolve();
            else frame.addEventListener('load', resolve, {once:true}); });
        document.getElementById('field').value = 'edited';
        scrollTo(150, 900); frame.contentWindow.scrollTo(80, 420);
        const viewport = win => [win.visualViewport.pageLeft - win.visualViewport.offsetLeft,
            win.visualViewport.pageTop - win.visualViewport.offsetTop];
        return {main:viewport(window), child:viewport(frame.contentWindow), childURL:frame.contentWindow.location.href};
        """, in: view)
        let before = try XCTUnwrap(beforeValue as? [String: Any])
        let main = try XCTUnwrap(before["main"] as? [Double]), frame = try XCTUnwrap(before["child"] as? [Double])
        XCTAssertGreaterThan(main[0], 0); XCTAssertGreaterThan(main[1], 0)
        XCTAssertGreaterThan(frame[0], 0); XCTAssertGreaterThan(frame[1], 0)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - main[1]) < 2 }

        state.send(.print); let printing = state.command
        state.send(.scroll(.down, .page))
        coordinator.command = printing.revision
        let job = BrowserReader.Coordinator.PrintJob(command: printing, url: view.url, info: state.printInfo)
        coordinator.printJob = job
        _ = try await evaluate("window.leafCapturePrintViewport(); await window.leafPreparePrint(); return true", in: view)
        _ = try await evaluate("scrollTo(0, 1800); document.getElementById('child').contentWindow.scrollTo(0, 1000); return true", in: view)
        XCTAssertEqual(state.command.revision, printing.revision)
        XCTAssertEqual(state.currentPosition.y ?? 0, main[1], accuracy: 2, "Print-time movement must not become reading state")
        coordinator.finishPrint(job)
        try await waitForNextCommand(state, after: printing.revision)
        let restoredValue = try await evaluate("""
        const frame = document.getElementById('child'), viewport = win => [win.visualViewport.pageLeft - win.visualViewport.offsetLeft,
            win.visualViewport.pageTop - win.visualViewport.offsetTop];
        return {main:viewport(window), child:viewport(frame.contentWindow),
            childURL:frame.contentWindow.location.href, field:document.getElementById('field').value};
        """, in: view)
        let restored = try XCTUnwrap(restoredValue as? [String: Any])
        let restoredMain = try XCTUnwrap(restored["main"] as? [Double])
        let restoredFrame = try XCTUnwrap(restored["child"] as? [Double])
        for index in 0..<2 {
            XCTAssertEqual(restoredMain[index], main[index], accuracy: 2)
            XCTAssertEqual(restoredFrame[index], frame[index], accuracy: 2)
        }
        XCTAssertEqual(restored["childURL"] as? String, before["childURL"] as? String)
        XCTAssertEqual(restored["field"] as? String, "edited")
        XCTAssertEqual(state.command.action, .scroll(.down, .page))
        let scrolling = state.command
        coordinator.command = scrolling.revision
        coordinator.deliver(scrolling, to: view)
        try await waitUntil { (state.currentPosition.y ?? 0) > main[1] + 100 }
    }

    @MainActor
    func testPrintRestoreWaitsForScreenMediaBeforeReleasingQueuedScroll() async throws {
        let html = "<div style='height:2800px'></div><p>End of topic</p>"
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html")
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        view.pageZoom = 1.5
        _ = try await evaluate("""
        scrollTo(0, 550);
        const realMedia = window.matchMedia.bind(window), printMedia = new EventTarget();
        printMedia.matches = true;
        const add = printMedia.addEventListener.bind(printMedia);
        printMedia.addEventListener = (type, listener) => { window.printWaitObserved = true; add(type, listener); };
        window.matchMedia = query => query === 'print' ? printMedia : realMedia(query);
        window.finishPrintMedia = () => { printMedia.matches = false; printMedia.dispatchEvent(new Event('change')); };
        return true;
        """, in: view)
        try await waitUntil { (state.currentPosition.y ?? 0) > 500 }
        let originalY = state.currentPosition.y ?? 0
        state.send(.print); let printing = state.command
        state.send(.scroll(.down, .page))
        coordinator.command = printing.revision
        let job = BrowserReader.Coordinator.PrintJob(command: printing, url: view.url, info: state.printInfo)
        coordinator.printJob = job
        _ = try await evaluate("window.leafCapturePrintViewport(); scrollTo(0, 1200); return true", in: view)
        coordinator.finishPrint(job)
        var observed = false
        for _ in 0..<100 {
            observed = (try await evaluate("return window.printWaitObserved === true", in: view) as? Bool) == true
            if observed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observed, "The native print completion must await the screen-media transition")
        XCTAssertEqual(state.command.revision, printing.revision)
        XCTAssertEqual(state.currentPosition.y ?? 0, originalY, accuracy: 2)
        _ = try await evaluate("window.finishPrintMedia(); return true", in: view)
        try await waitForNextCommand(state, after: printing.revision)
        let restoredValue = try await evaluate("return visualViewport.pageTop - visualViewport.offsetTop", in: view)
        let restoredY = try XCTUnwrap(restoredValue as? Double)
        XCTAssertEqual(restoredY, originalY, accuracy: 2)
        let scrolling = state.command
        XCTAssertEqual(scrolling.action, .scroll(.down, .page))
        coordinator.command = scrolling.revision
        coordinator.deliver(scrolling, to: view)
        try await waitUntil { (state.currentPosition.y ?? 0) > originalY + 100 }
    }

    @MainActor
    func testPrintRestoreWaitReleasesQueueWhenDocumentLeaves() async throws {
        let (state, view) = try await loadedReaderFixture()
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        _ = try await evaluate("""
        const realMedia = window.matchMedia.bind(window), printMedia = new EventTarget();
        printMedia.matches = true;
        window.matchMedia = query => query === 'print' ? printMedia : realMedia(query);
        return true;
        """, in: view)
        state.send(.print); let printing = state.command
        state.send(.copy)
        coordinator.command = printing.revision
        let job = BrowserReader.Coordinator.PrintJob(command: printing, url: view.url, info: state.printInfo)
        coordinator.printJob = job
        _ = try await evaluate("window.leafCapturePrintViewport(); return true", in: view)
        coordinator.finishPrint(job)
        _ = try await evaluate("window.dispatchEvent(new Event('pagehide')); return true", in: view)
        try await waitForNextCommand(state, after: printing.revision)
        XCTAssertEqual(state.command.action, .copy)
        XCTAssertTrue(state.error?.contains("topic changed") == true)
    }

    @MainActor
    func testAbandonedPrintSnapshotDoesNotSilenceSameDocumentScroll() async throws {
        let html = "<div style='height:2000px'></div><p>End of topic</p>"
        let (state, view) = try await loadedReaderFixture(topic: ("/topic.html", Data(html.utf8)), home: "/topic.html")
        let restored = try await evaluate("""
        scrollTo(0, 200);
        const realMedia = window.matchMedia.bind(window), printMedia = new EventTarget();
        printMedia.matches = true;
        window.matchMedia = query => query === 'print' ? printMedia : realMedia(query);
        window.leafCapturePrintViewport();
        const pending = window.leafRestorePrintViewport();
        history.replaceState(null, '', '#changed-after-print');
        printMedia.matches = false; printMedia.dispatchEvent(new Event('change'));
        return await pending;
        """, in: view) as? Bool
        XCTAssertEqual(restored, false)
        _ = try await evaluate("scrollTo(0, 450); return true", in: view)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - 450) < 2 }
    }

    @MainActor
    func testPrintFailureKeepsOriginalCauseWhenViewportRestoreAlsoFails() async throws {
        let (state, coordinator, view) = try bridgeFixture()
        defer { BrowserReader.dismantleNSView(view, coordinator: coordinator) }
        _ = try await evaluate("window.leafRestorePrintViewport = () => { throw Error('Restore failed') }; return true", in: view)
        state.send(.exportPDF); let command = state.command
        state.send(.copy)
        coordinator.command = command.revision
        let job = BrowserReader.Coordinator.PrintJob(command: command, url: view.url, info: state.printInfo)
        coordinator.printJob = job
        coordinator.finishPrint(job, error: ReadError("Export failed first"))
        try await waitForNextCommand(state, after: command.revision)
        XCTAssertEqual(state.command.action, .copy)
        XCTAssertTrue(state.error?.contains("Export failed first") == true)
        XCTAssertFalse(state.error?.contains("Restore failed") == true)
    }

    @MainActor
    func testNavigationCancelsPreparationBeforePrintingAnotherTopic() async throws {
        let first = "<div style='height:2400px'></div><p>First topic</p>"
        let (state, view) = try await loadedReaderFixture(topic: ("/first.html", Data(first.utf8)), home: "/first.html",
            additionalTopics: [("/second.htm", Data("<p>Second topic</p>".utf8))])
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        _ = try await evaluate("scrollTo(0, 400); return true", in: view)
        try await waitUntil { (state.currentPosition.y ?? 0) > 300 }
        _ = try await evaluate("window.leafPreparePrint = () => new Promise(() => {});", in: view)
        state.send(.print); let command = state.command
        state.send(.selectAll)
        coordinator.command = command.revision; coordinator.deliver(command, to: view)
        view.load(URLRequest(url: URL(string: "leaf://book/entry/second.htm")!))
        try await waitForNextCommand(state, after: command.revision)
        try await waitUntil { coordinator.ready && coordinator.displayedURL?.path == "/entry/second.htm" }
        XCTAssertNil(coordinator.printJob)
        XCTAssertTrue(state.error?.contains("topic changed") == true)
        XCTAssertEqual(state.command.action, .selectAll)
        coordinator.command = state.command.revision; coordinator.deliver(state.command, to: view)
        try await waitUntil { state.hasSelection }
        let selected = try await state.selectionText()
        XCTAssertEqual(selected, "Second topic")
        _ = try XCTUnwrap(view.goBack())
        try await waitUntil { coordinator.ready && coordinator.displayedURL?.path == "/entry/first.html" }
        _ = try await evaluate("scrollTo(0, 600); return true", in: view)
        try await waitUntil { abs((state.currentPosition.y ?? 0) - 600) < 2 }
    }

    @MainActor
    func testSelectionCommandWaitsForJavaScriptPromiseAndFindOnlyWaitsForLaunch() async throws {
        let (state, coordinator, view) = try bridgeFixture()
        defer { BrowserReader.dismantleNSView(view, coordinator: coordinator) }
        _ = try await evaluate("window.leafCommand = () => new Promise(resolve => { window.finishCommand = resolve });", in: view)
        state.send(.selectAll); let first = state.command
        state.send(.find("needle")); state.send(.toc)
        coordinator.command = first.revision
        coordinator.deliver(first, to: view)
        _ = try await evaluate("return typeof window.finishCommand === 'function';", in: view)
        XCTAssertEqual(state.command.action, .selectAll)
        _ = try await evaluate("window.finishCommand();", in: view)
        try await waitForNextCommand(state, after: first.revision)
        XCTAssertEqual(state.command.action, .find("needle", options: .init()))
        let search = state.command
        coordinator.command = search.revision
        coordinator.deliver(search, to: view)
        try await waitForNextCommand(state, after: search.revision)
        XCTAssertEqual(state.command.action, .toc, "TOC can cancel a search before all chapters finish")
    }

    @MainActor
    func testNavigationFailureAcknowledgesPendingCommandAndStaleFailureIsIgnored() async throws {
        for terminated in [false, true] {
            let (state, coordinator, view) = try bridgeFixture()
            defer { BrowserReader.dismantleNSView(view, coordinator: coordinator) }
            state.send(.print); let first = state.command
            state.send(.toc)
            coordinator.command = first.revision
            coordinator.pending = [first]
            var readyError: Error?
            coordinator.readyHandler = { readyError = $0 }
            if terminated { coordinator.webViewWebContentProcessDidTerminate(view) }
            else {
                coordinator.webView(view, didFailProvisionalNavigation: nil,
                                    withError: NSError(domain: "Fixture navigation failed", code: 1))
            }
            try await waitForNextCommand(state, after: first.revision)
            XCTAssertEqual(state.command.action, .toc)
            XCTAssertTrue(coordinator.pending.isEmpty)
            XCTAssertNotNil(coordinator.readerError)
            XCTAssertNotNil(readyError)
            let error = state.error
            coordinator.active = false
            coordinator.webView(view, didFail: nil, withError: NSError(domain: "Stale document failure", code: 2))
            XCTAssertEqual(state.error, error)
        }
    }

    @MainActor
    func testDismantlingCancelsPrintPreparationAndReleasesItsQueuedCommand() async throws {
        let (state, coordinator, view) = try bridgeFixture()
        _ = try await evaluate("window.leafCapturePrintViewport = () => {}; window.leafPreparePrint = () => new Promise(() => {});", in: view)
        state.send(.exportPDF); let first = state.command
        state.send(.copy)
        coordinator.command = first.revision
        coordinator.deliver(first, to: view)
        XCTAssertEqual(coordinator.printJob?.command.action, .exportPDF)
        BrowserReader.dismantleNSView(view, coordinator: coordinator)
        try await waitForNextCommand(state, after: first.revision)
        XCTAssertEqual(state.command.action, .copy)
        XCTAssertNil(coordinator.printJob)
        XCTAssertFalse(coordinator.active)
    }
}
#endif
