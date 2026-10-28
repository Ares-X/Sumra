#if os(macOS)
import AppKit
import SumraCore
import WebKit
import XCTest
@testable import Sumra

final class NativeRootMarginsTests: XCTestCase {
    func testExplicitMarginsReplaceRootWhitespaceButRetainSemanticIndentAndUserCSS() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("RootMargins.html")
        try """
            <html><head><style>
            @page{margin:44pt}html{margin:11pt;padding:13pt;width:220pt;max-width:220pt}
            body{margin:47pt;padding:29pt;width:180pt;max-width:180pt}
            p{margin:0}blockquote{margin:0 0 0 23pt}
            </style></head><body><p>ANCHOR</p><blockquote>QUOTE</blockquote>
            <p>\(String(repeating: "Wrapping words remain readable across the available width. ", count: 12))</p>
            </body></html>
            """.write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        func layout(_ margins: PageMargins?, css: String = "") throws -> CGFloat {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "serif", theme: "light",
                userCSS: css, pageMargins: margins, pageSize: CGSize(width: 640, height: 0))
            return try XCTUnwrap(file.matches("ANCHOR", page: 0).first?.rects.first).minX
        }
        let publisherLeft = try layout(nil)
        var narrowLeft: CGFloat?
        for preset in ReaderMarginPreset.allCases {
            let left = try layout(PageMargins(cssValues: [preset.margin]))
            if let narrowLeft { XCTAssertEqual(left - narrowLeft, CGFloat(preset.margin - 8), accuracy: 0.1) }
            else { narrowLeft = left }
            XCTAssertEqual(left, CGFloat(preset.margin), accuracy: 1)
            let quoteLeft = try XCTUnwrap(file.matches("QUOTE", page: 0).first?.rects.first).minX
            XCTAssertEqual(quoteLeft - left, 23, accuracy: 0.1, "Blockquote indentation belongs to the content")
            XCTAssertGreaterThan(try file.words(0).map(\.bounds.maxX).max() ?? 0, 500,
                                 "Root width locks must not leave most of the viewport unused")
        }
        let overridden = try layout(PageMargins(cssValues: [16]), css: "body{margin-left:19pt!important}")
        XCTAssertEqual(overridden - (try XCTUnwrap(narrowLeft)), 27, accuracy: 0.1,
                       "Explicit user CSS remains after the margin preset")
        XCTAssertEqual(try layout(nil), publisherLeft, accuracy: 0.1,
                       "Clearing the override restores publisher root whitespace")
    }

    func testNativeMarkdownPresetDoesNotAddTheDefaultBodyMargin() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let input = directory.url.appendingPathComponent("RootMargins.md")
        try "ANCHOR\n\n> QUOTE\n".write(to: input, atomically: true, encoding: .utf8)
        let file = try NativeFile(input, engine: .mupdf, deferReflowLayout: true)
        for preset in ReaderMarginPreset.allCases {
            _ = try file.relayout(fontSize: 17, lineHeight: 1.6, font: "serif", theme: "light",
                pageMargins: PageMargins(cssValues: [preset.margin]), pageSize: CGSize(width: 640, height: 400))
            let anchor = try XCTUnwrap(file.matches("ANCHOR", page: 0).first?.rects.first)
            XCTAssertEqual(anchor.minX, CGFloat(preset.margin), accuracy: 1)
            XCTAssertGreaterThan(try XCTUnwrap(file.matches("QUOTE", page: 0).first?.rects.first).minX, anchor.minX)
        }
    }
}

@MainActor
final class BrowserRootMarginsTests: XCTestCase {
    func testExplicitMarginsFillWideMarkdownWithoutChangingContentOrNilStyles() async throws {
        let fixture = try Fixture(name: "RootMargins.md", text: "# Title\n\nANCHOR\n\n> QUOTE\n\n![Art](art.svg)", width: 1400)
        defer { fixture.close() }
        try await fixture.load()
        let publisher = try await fixture.geometry()
        XCTAssertLessThan(try XCTUnwrap(publisher["bodyWidth"]), 1100)
        let markup = try await fixture.evaluate("return document.body.innerHTML") as? String
        for preset in ReaderMarginPreset.allCases {
            try await fixture.style(margins: PageMargins(cssValues: [preset.margin]))
            let actual = try await fixture.geometry()
            XCTAssertEqual(try XCTUnwrap(actual["bodyWidth"]), 1400, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(actual["bodyLeft"]), 0, accuracy: 0.1)
            XCTAssertEqual(try XCTUnwrap(actual["padding"]), preset.margin * 96 / 72, accuracy: 0.1)
            XCTAssertGreaterThan(try XCTUnwrap(actual["quoteMargin"]) + XCTUnwrap(actual["quotePadding"]), 0)
            XCTAssertEqual(try XCTUnwrap(actual["imageWidth"]), 50, accuracy: 0.1)
            let currentMarkup = try await fixture.evaluate("return document.body.innerHTML") as? String
            XCTAssertEqual(currentMarkup, markup)
        }
        try await fixture.style(margins: nil)
        let restored = try await fixture.geometry()
        XCTAssertEqual(restored["bodyWidth"], publisher["bodyWidth"])
        XCTAssertEqual(restored["padding"], publisher["padding"])
    }

    func testHTMLRootLocksClearWhileNestedGeometryAndUserCSSRemain() async throws {
        let fixture = try Fixture(name: "RootMargins.html", text: """
            <html><head><style>html{margin:31px;padding:17px;width:600px;max-width:600px}
            body{margin:49px;padding:53px;width:400px;max-width:400px}
            blockquote{margin-left:37px}#art{width:50px;height:20px}</style></head>
            <body><p>ANCHOR</p><blockquote>QUOTE</blockquote><img id="art" src="art.svg"></body></html>
            """, width: 1400)
        defer { fixture.close() }
        try await fixture.load()
        let publisher = try await fixture.geometry()
        try await fixture.style(margins: PageMargins(cssValues: [16]))
        let actual = try await fixture.geometry()
        XCTAssertEqual(try XCTUnwrap(actual["bodyWidth"]), 1400, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(actual["bodyLeft"]), 0, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(actual["quoteMargin"]), 37, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(actual["imageWidth"]), 50, accuracy: 0.1)
        try await fixture.style(margins: PageMargins(cssValues: [16]), css: "body{max-width:700px!important;margin-left:19px!important}")
        let custom = try await fixture.geometry()
        XCTAssertEqual(try XCTUnwrap(custom["bodyWidth"]), 700, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(custom["bodyLeft"]), 19, accuracy: 0.1)
        try await fixture.style(margins: nil)
        let restored = try await fixture.geometry()
        XCTAssertEqual(restored["bodyWidth"], publisher["bodyWidth"])
        XCTAssertEqual(restored["bodyLeft"], publisher["bodyLeft"])
    }

    @MainActor private final class Fixture {
        let directory: TemporaryDirectory
        let state: ReaderState
        let coordinator: BrowserReader.Coordinator
        let view: WKWebView
        let window: NSWindow

        init(name: String, text: String, width: CGFloat) throws {
            _ = NSApplication.shared
            directory = try TemporaryDirectory()
            let input = directory.url.appendingPathComponent(name)
            try text.write(to: input, atomically: true, encoding: .utf8)
            try "<svg xmlns='http://www.w3.org/2000/svg' width='50' height='20'><rect width='50' height='20' fill='red'/></svg>"
                .write(to: directory.url.appendingPathComponent("art.svg"), atomically: true, encoding: .utf8)
            let source = try MarkupSource(input)
            state = ReaderState(recordsHistory: false)
            state.document = ReadingDocument(url: input, content: .browser(source), temporary: directory)
            state.font = "serif"; state.fontSize = 17; state.lineHeight = 1.6; state.margin = 32
            state.pageMargins = nil; state.theme = "light"; state.userCSS = ""; state.useDocumentCSS = true
            state.flow = "continuous"; state.spread = false; state.zoom = 1
            coordinator = BrowserReader.Coordinator(state: state, source: source)
            view = coordinator.makeView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
            window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
        }

        func load() async throws {
            coordinator.load(view)
            let deadline = Date().addingTimeInterval(15)
            while !coordinator.ready, coordinator.readerError == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if let error = coordinator.readerError { throw error }
            XCTAssertTrue(coordinator.ready)
            _ = try await evaluate("await Promise.all([...document.images].map(image=>image.decode()))")
        }

        func evaluate(_ script: String) async throws -> Any? {
            try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "SumraMarkup"))
        }

        func style(margins: PageMargins?, css: String = "") async throws {
            state.pageMargins = margins; state.userCSS = css
            let arguments = coordinator.styleArguments()
            _ = try await view.callAsyncJavaScript("await window.leafCommand({...command,name:'style'});return true",
                arguments: ["command": arguments], in: nil, contentWorld: .world(name: "SumraMarkup"))
        }

        func geometry() async throws -> [String: Double] {
            let value = try await evaluate("""
                const body=document.body,style=getComputedStyle(body),rect=body.getBoundingClientRect();
                return {bodyWidth:rect.width,bodyLeft:rect.left,padding:parseFloat(style.paddingLeft),
                    quoteMargin:parseFloat(getComputedStyle(document.querySelector('blockquote')).marginLeft),
                    quotePadding:parseFloat(getComputedStyle(document.querySelector('blockquote')).paddingLeft),
                    imageWidth:document.querySelector('img').getBoundingClientRect().width};
                """) as? [String: Double]
            return try XCTUnwrap(value)
        }

        func close() {
            BrowserReader.dismantleNSView(view, coordinator: coordinator)
            state.windowClosed(); window.contentView = nil; window.close()
        }
    }
}
#endif
