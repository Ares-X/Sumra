#if os(macOS)
import AppKit
import Foundation
import SumraCore
import SwiftUI
import WebKit
import XCTest
@testable import Sumra

final class Issue136CHMHomeTests: XCTestCase {
    // Upstream Sumatra issue-2737.chm, with one uncompressed topic appended to
    // its PMGL directory. Its fixed-size #SYSTEM home record is 11 bytes.
    @MainActor
    private func open(home: String, position: ReadingPosition? = nil) async throws -> (ReaderState, BrowserReader.Coordinator, WKWebView) {
        _ = NSApplication.shared
        let engine = try NativeFile.libraryURL(for: .chm)
        guard FileManager.default.fileExists(atPath: engine.path) else { throw XCTSkip("Build CHMLib before CHM integration tests") }
        let homeBytes = try XCTUnwrap(home.utf8.count == 11 ? Data(home.utf8) : nil)
        var bytes = Data(repeating: 0, count: 2354)
        let header = try XCTUnwrap(Data(base64Encoded: "SVRTRgMAAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAAAAAAABUCAAAAAAAALQIAAAAAAAASVRTUAEAAABUAAAAAAAAAAAIAAAAAAAAAAAAAP////8AAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUE1HTNEHAAAAAAAA//////////8ILyNTWVNURU0AACMLL2luZGV4Lmh0bWwAI1s="))
        let tail = try XCTUnwrap(Data(base64Encoded: "AwAAAAIADAAvaW5kZXguaHRtbAADAAsASXNzdWUgMjczNwA8aHRtbD48Ym9keT48Zm9udCBmYWNlPSJDb3VyaWVyIE5ldyI+Q0hNIGZvbnQgb3ZlcnJpZGUgcmVncmVzc2lvbiB0ZXN0PC9mb250PjwvYm9keT48L2h0bWw+"))
        bytes.replaceSubrange(0..<227, with: header)
        bytes.replaceSubrange(2228..<2354, with: tail)
        bytes.replaceSubrange(2236..<2247, with: homeBytes)
        let paragraphs = (0..<100).map { "<p>Reading line \($0)</p>" }.joined()
        let html = Data(("<html><body>" + paragraphs + "<h2 id='mid2'>Middle</h2><h2 id='mi'>Encoded</h2>" + paragraphs + "</body></html>").utf8)
        func cword(_ number: Int) -> Data {
            var value = number, groups = [UInt8(value & 0x7f)]
            value >>= 7
            while value > 0 { groups.insert(UInt8(value & 0x7f) | 0x80, at: 0); value >>= 7 }
            return Data(groups)
        }
        let path = "/a.htm"
        var directory = cword(path.utf8.count)
        directory.append(Data(path.utf8)); directory.append(0)
        directory.append(cword(bytes.count - 2228)); directory.append(cword(html.count))
        bytes.append(html)
        bytes.replaceSubrange(227..<(227 + directory.count), with: directory)
        let unused = 2001 - directory.count
        for index in 0..<4 { bytes[184 + index] = UInt8(truncatingIfNeeded: unused >> (index * 8)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sumra-CHM-home-" + UUID().uuidString + ".chm")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let source = try CHMSource(url)
        let (metadata, _) = try await source.response(URL(string: "leaf://book/meta")!)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(meta["home"] as? String, home, "CHMLib must read the fixture's actual #SYSTEM home")
        let state = ReaderState()
        state.document = .init(url: url, content: .browser(source))
        state.flow = "continuous"; state.spread = false
        state.theme = "light"; state.userCSS = ""; state.useDocumentCSS = true; state.pageMargins = nil
        state.useDocumentOpenAction = position == nil
        if let position { _ = state.apply(position) }
        let frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserReader(state: state, source: source))
        addTeardownBlock { @MainActor in
            window.contentView = nil
            state.windowClosed()
            UserDefaults.standard.removeObject(forKey: "position:" + url.path)
            window.close()
        }
        for _ in 0..<500 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let coordinator = state.browserView?.navigationDelegate as? BrowserReader.Coordinator,
               coordinator.ready || coordinator.readerError != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let view = try XCTUnwrap(state.browserView)
        let coordinator = try XCTUnwrap(view.navigationDelegate as? BrowserReader.Coordinator)
        if let error = coordinator.readerError { throw error }
        XCTAssertTrue(coordinator.ready)
        return (state, coordinator, view)
    }

    @MainActor
    private func evaluate(_ script: String, in view: WKWebView) async throws -> Any {
        try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .world(name: "SumraMarkup"))
    }

    @MainActor
    func testHomeFragmentReachesHeadingOnFirstActivation() async throws {
        for (home, id) in [("/a.htm#mid2", "mid2"), ("/a.htm#m%69", "mi")] {
            let (state, coordinator, view) = try await open(home: home)
            XCTAssertEqual(view.url?.path, "/entry/a.htm")
            XCTAssertNil(view.url?.fragment)
            XCTAssertEqual(state.page, 0)
            XCTAssertEqual(coordinator.pages.first?.fragment, nil)
            let top = try await evaluate("return document.getElementById('\(id)').getBoundingClientRect().top", in: view) as? Double
            XCTAssertEqual(try XCTUnwrap(top), 0, accuracy: 2)
        }
    }

    @MainActor
    func testSavedPositionWinsOverHomeFragment() async throws {
        let position = ReadingPosition(page: 0, x: 0, y: 430, anchor: "leaf://book/entry/a.htm")
        let (_, _, view) = try await open(home: "/a.htm#mid2", position: position)
        let y = try await evaluate("return scrollY", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(y), 430, accuracy: 2)
    }

    @MainActor
    func testHomeWithoutFragmentStartsAtTop() async throws {
        let (_, _, view) = try await open(home: "/index.html")
        XCTAssertEqual(view.url?.path, "/entry/index.html")
        let y = try await evaluate("return scrollY", in: view) as? Double
        XCTAssertEqual(try XCTUnwrap(y), 0, accuracy: 2)
    }
}
#endif
