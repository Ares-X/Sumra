#if os(macOS)
import AppKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class BrowserPrintSnapshotTests: XCTestCase {
    @MainActor
    private func reader(_ files: [String: Data], opened: String = "topic.html") async throws -> WKWebView {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        for (name, data) in files {
            let url = directory.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let state = ReaderState()
        state.document = try ReadingDocument.open(directory.url.appendingPathComponent(opened))
        guard case .browser(let source) = state.document?.content else { throw ReadError("Expected browser fixture") }
        state.font = "system"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32; state.theme = "light"
        state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        let coordinator = BrowserReader.Coordinator(state: state, source: source)
        let view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
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
        coordinator.load(view)
        let end = Date().addingTimeInterval(15)
        while !coordinator.ready, coordinator.readerError == nil, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        if let error = coordinator.readerError { throw error }
        XCTAssertTrue(coordinator.ready, "Browser fixture did not become ready")
        return view
    }

    @MainActor
    private func evaluate(_ script: String, in view: WKWebView) async throws -> [String: Any] {
        let result = try await view.callAsyncJavaScript(script, arguments: [:], in: nil,
            contentWorld: .world(name: "SumraMarkup"))
        return try XCTUnwrap(result as? [String: Any])
    }

    @MainActor
    func testPrintMediaGeneratedTextTransformsAndLiveFormValues() async throws {
        let html = """
        <meta charset="utf-8">
        <link rel="stylesheet" href="css/print.css" media="print">
        <style>
        @media screen {.print-only{display:none}}
        @media print {.screen-only{display:none}.print-only{display:block}}
        .label{text-transform:uppercase}.label::before{content:"Before "}.label::after{content:attr(data-after)}
        .counted{counter-increment:part}.counted::before{content:counter(part) ". "}
        .quoted{quotes:"«" "»"}.quoted::before{content:open-quote}.quoted::after{content:close-quote}
        </style>
        <p>正文 中文 Ω ﬃ</p><p class="screen-only">Screen only</p><p class="print-only">Print only</p>
        <p class="from-sheet">External print sheet</p><p class="label" data-after=" after">mixed Case</p>
        <input id="text" value="original"><textarea id="area">old</textarea>
        <select id="choice"><option>old choice</option><option>Chosen 中文</option></select>
        <input id="check" type="checkbox"><input id="radio" type="radio" checked>
        <input type="hidden" value="Hidden value"><input type="password" value="secret">
        <section style="counter-reset:part"><p class="counted">Counter one</p><p class="counted">Counter two</p></section>
        <p class="quoted">Quoted text</p><p id="pageBreak" style="break-before:page">New page</p>
        """
        let view = try await reader(["topic.html": Data(html.utf8), "css/print.css": Data(".from-sheet{text-transform:uppercase}".utf8)])
        let result = try await evaluate("""
        document.getElementById('text').value = 'Edited 中文';
        document.getElementById('area').value = 'Live first\\nLive second';
        document.getElementById('choice').selectedIndex = 1;
        document.getElementById('check').checked = true;
        document.getElementById('radio').checked = false;
        window.leafCapturePrintViewport(); await window.leafPreparePrint();
        const snapshot = window.leafPrintSnapshot();
        const doc = new DOMParser().parseFromString(snapshot.html, 'text/html');
        await window.leafRestorePrintViewport();
        return {text:doc.body.textContent, resources:snapshot.resources,
            pageBreak:doc.getElementById('pageBreak').style.pageBreakBefore,
            media:document.querySelector('link').media, screen:getComputedStyle(document.querySelector('.screen-only')).display,
            print:getComputedStyle(document.querySelector('.print-only')).display,
            original:document.getElementById('text').value};
        """, in: view)
        let text = try XCTUnwrap(result["text"] as? String)
        for expected in ["正文 中文 Ω ﬃ", "Print only", "EXTERNAL PRINT SHEET", "BEFORE MIXED CASE AFTER", "Edited 中文", "Live first\nLive second", "Chosen 中文", "☑", "☐", "••••••", "1. Counter one", "2. Counter two", "«Quoted text»"] {
            XCTAssertTrue(text.contains(expected), text)
        }
        for omitted in ["Screen only", "original", "old choice", "Hidden value", "secret"] { XCTAssertFalse(text.contains(omitted), text) }
        XCTAssertEqual(result["media"] as? String, "print")
        XCTAssertNotEqual(result["screen"] as? String, "none")
        XCTAssertEqual(result["print"] as? String, "none")
        XCTAssertEqual(result["original"] as? String, "Edited 中文")
        XCTAssertEqual(result["pageBreak"] as? String, "always")
        XCTAssertEqual((result["resources"] as? [[String: String]])?.count, 0)
    }

    @MainActor
    func testLoadedLegacyFrameAndNestedLiveValuesKeepBothViewports() async throws {
        let html = """
        <meta charset="utf-8">
        <body style="width:1600px"><iframe id="child" src="chapters/child.htm" style="width:500px;height:230px"></iframe>
        <div style="height:2600px"></div><p>Main end</p></body>
        """
        let child = """
        <meta charset="windows-1252"><body style="width:1200px"><p>Café £ déjà</p><input id="field" value="old">
        <iframe id="nested" src="nested.html"></iframe><div style="height:2200px"></div><p>Frame end</p></body>
        """
        let view = try await reader(["topic.html": Data(html.utf8),
            "chapters/child.htm": try XCTUnwrap(child.data(using: .windowsCP1252)),
            "chapters/nested.html": Data("<meta charset=utf-8><p>Nested 中文</p><textarea id='nestedField'>old</textarea>".utf8)])
        let result = try await evaluate("""
        const frame = document.getElementById('child');
        const loaded = async frame => { if (frame.contentDocument?.readyState !== 'complete')
            await new Promise(resolve => frame.addEventListener('load', resolve, {once:true})); };
        await loaded(frame); const child = frame.contentWindow;
        const nested = child.document.getElementById('nested'); await loaded(nested);
        child.document.getElementById('field').value = 'Edited frame';
        nested.contentDocument.getElementById('nestedField').value = 'Edited nested';
        scrollTo(150, 700); child.scrollTo(80, 350);
        const positions = () => [scrollX,scrollY,child.scrollX,child.scrollY];
        const before = positions(), markup = document.documentElement.outerHTML;
        window.leafCapturePrintViewport(); await window.leafPreparePrint();
        const snapshot = window.leafPrintSnapshot(), after = positions();
        const text = new DOMParser().parseFromString(snapshot.html, 'text/html').body.textContent;
        const unchanged = markup === document.documentElement.outerHTML;
        await window.leafRestorePrintViewport();
        return {text,before,after,unchanged,charset:child.document.characterSet,
            field:child.document.getElementById('field').value};
        """, in: view)
        let text = try XCTUnwrap(result["text"] as? String)
        for expected in ["Café £ déjà", "Edited frame", "Edited nested", "Nested 中文", "Frame end", "Main end"] { XCTAssertTrue(text.contains(expected), text) }
        XCTAssertEqual(result["charset"] as? String, "windows-1252")
        XCTAssertEqual(result["before"] as? [Double], result["after"] as? [Double])
        XCTAssertEqual(result["unchanged"] as? Bool, true)
        XCTAssertEqual(result["field"] as? String, "Edited frame")
    }

    @MainActor
    func testPrintedImageResourcesUseCurrentSourceCanvasAndSVGWithoutNavigationAssets() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8S0AAAAASUVORK5CYII="))
        let html = """
        <meta charset="utf-8">
        <style>.background{background-image:url(images/background.png)}.hidden{display:none}</style>
        <picture><source srcset="images/selected.png"><img id="picture" src="images/fallback.png"></picture>
        <div class="background">Background text</div><img class="hidden" src="images/hidden.png">
        <a href="unopened.html">Navigation link</a><canvas id="canvas" width="20" height="10"></canvas>
        <svg width="80" height="30" xmlns="http://www.w3.org/2000/svg"><text x="2" y="20">SVG 中文</text></svg>
        """
        let view = try await reader(["topic.html": Data(html.utf8), "images/selected.png": png,
            "images/fallback.png": png, "images/background.png": png, "images/hidden.png": png])
        let result = try await evaluate("""
        const canvas = document.getElementById('canvas'); const context = canvas.getContext('2d');
        context.fillStyle = 'red'; context.fillRect(0,0,20,10);
        window.leafCapturePrintViewport(); await window.leafPreparePrint();
        const snapshot = window.leafPrintSnapshot();
        const doc = new DOMParser().parseFromString(snapshot.html, 'text/html');
        await window.leafRestorePrintViewport();
        return {html:snapshot.html, resources:snapshot.resources, source:document.getElementById('picture').currentSrc,
            images:[...doc.images].map(image => image.getAttribute('src')),
            navigation:doc.querySelector('a').getAttribute('href'), canvas:canvas.toDataURL()};
        """, in: view)
        let resources = try XCTUnwrap(result["resources"] as? [[String: String]])
        let urls = resources.compactMap { $0["url"] }, paths = resources.compactMap { $0["path"] }
        XCTAssertTrue(urls.contains(try XCTUnwrap(result["source"] as? String)))
        XCTAssertTrue(urls.contains("leaf://book/entry/images/background.png"))
        XCTAssertFalse(urls.contains { $0.contains("hidden.png") || $0.contains("fallback.png") || $0.contains("unopened.html") })
        XCTAssertTrue(urls.contains(try XCTUnwrap(result["canvas"] as? String)))
        let svg = try XCTUnwrap(urls.first { $0.hasPrefix("data:image/svg+xml;") })
        XCTAssertTrue(try XCTUnwrap(svg.removingPercentEncoding).contains("SVG 中文"))
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertTrue(try XCTUnwrap(result["images"] as? [String]).allSatisfy { paths.contains($0) })
        XCTAssertEqual(result["navigation"] as? String, "leaf://book/entry/unopened.html")
        let snapshot = try JSONDecoder().decode(BrowserPrintSnapshot.self,
            from: JSONSerialization.data(withJSONObject: result))
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        let directory = try TemporaryDirectory()
        let prepared = try await snapshot.makePDF(source: coordinator.source, directory: directory.url)
        let pdf = try NativeFile(prepared.url, engine: .mupdf)
        let text = try XCTUnwrap(pdf.text(0))
        XCTAssertTrue(text.contains("Background text"), text)
        let svgResource = try XCTUnwrap(snapshot.resources.first { $0.path.hasSuffix(".svg") })
        XCTAssertTrue(try String(contentsOf: directory.url.appendingPathComponent(svgResource.path)).contains("SVG 中文"))
        // SVG is an image in MuPDF's HTML model. Validate its image output;
        // text inside that image does not become selectable HTML text.
        XCTAssertGreaterThanOrEqual(try pdf.imageBounds(0).count, 3, "The chosen image, canvas and SVG must reach native PDF output")
    }

    @MainActor
    func testCaptureFailureRestoresPrintMediaAndReadingViewport() async throws {
        let html = """
        <meta charset="utf-8">
        <style>@media print {body{width:300px}}</style>
        <body style="width:1500px"><canvas id="canvas" width="20" height="10"></canvas><div style="height:2400px"></div></body>
        """
        let view = try await reader(["topic.html": Data(html.utf8)])
        let result = try await evaluate("""
        scrollTo(100,500); const before=[scrollX,scrollY], markup=document.documentElement.outerHTML;
        document.getElementById('canvas').toDataURL = () => { throw Error('Fixture canvas read failed'); };
        window.leafCapturePrintViewport(); await window.leafPreparePrint();
        let error=''; try { window.leafPrintSnapshot(); } catch (failure) { error=failure.message; }
        const after=[scrollX,scrollY], unchanged=markup===document.documentElement.outerHTML;
        await window.leafRestorePrintViewport(); return {before,after,unchanged,error};
        """, in: view)
        XCTAssertTrue((result["error"] as? String)?.contains("Fixture canvas read failed") == true)
        XCTAssertEqual(result["before"] as? [Double], result["after"] as? [Double])
        XCTAssertEqual(result["unchanged"] as? Bool, true)
    }
}
#endif
