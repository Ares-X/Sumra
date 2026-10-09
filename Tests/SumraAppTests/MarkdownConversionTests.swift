#if os(macOS)
import Foundation
import AppKit
import SumraCore
import XCTest
@testable import Sumra

final class MarkdownConversionTests: XCTestCase {
    func testNativeMarkdownConversionReleasesParseStorageAndPreservesFailures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mupdf = root.appendingPathComponent("build/deps/mupdf")
        let core = root.appendingPathComponent("build/mupdf/libmupdf.a")
        let thirdParty = root.appendingPathComponent("build/mupdf/libmupdf-third.a")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let crypto = root.appendingPathComponent("build/native-macos13/openssl-3.5.9-\(architecture)/libcrypto.a")
        guard [core, thirdParty, crypto].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Build the native engine archives before converter ownership tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let object = directory.url.appendingPathComponent("lifetime.o")
        let executable = directory.url.appendingPathComponent("markdown-lifetime")
        let includes = ["include", "source/html", "thirdparty/cmark-gfm/src",
                        "thirdparty/cmark-gfm/extensions", "scripts/cmark-gfm"].map {
            "-I" + mupdf.appendingPathComponent($0).path
        }
        let commands = [
            ["clang", "-std=c11", "-O1", "-mmacosx-version-min=13.0", "-DCMARK_GFM_STATIC_DEFINE",
             "-DFZ_ENABLE_OCR_OUTPUT=0", "-DFZ_ENABLE_ODT_OUTPUT=0"] + includes +
                ["-c", root.appendingPathComponent("Tests/Native/MarkdownLifetime.c").path, "-o", object.path],
            ["clang++", "-mmacosx-version-min=13.0", "-Wl,-dead_strip", object.path,
             core.path, thirdParty.path, crypto.path, "-lm", "-lpthread", "-lz",
             "-framework", "Security", "-framework", "CoreFoundation", "-framework", "CoreText",
             "-o", executable.path]
        ]
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            try runSumraProcess(process)
            XCTAssertEqual(process.terminationStatus, 0)
            guard process.terminationStatus == 0 else { return }
        }
        let process = Process()
        process.executableURL = executable
        try runSumraProcess(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, "Detached output and allocation-failure cleanup must survive parse teardown")
    }

    func testConcurrentMarkdownConversionsKeepGFMInlineSemantics() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Native/MarkdownConcurrent.c")
        let executable = directory.url.appendingPathComponent("markdown-concurrent")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-pthread", source.path, "-o", executable.path]
        try runSumraProcess(compiler)
        XCTAssertEqual(compiler.terminationStatus, 0)
        let fixture = directory.url.appendingPathComponent("concurrent.md")
        try Data("""
            # Heading

            ~~deleted~~ https://example.com

            - [x] done

            | Name | Value |
            | --- | --- |
            | entry | 42 |

            """.utf8).write(to: fixture)
        let process = Process()
        process.executableURL = executable
        process.arguments = [try NativeFile.libraryURL(for: .mupdf).path, fixture.path]
        try runSumraProcess(process)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, "Concurrent conversions must retain GFM markup and headings")
    }

    func testExitKeepsExtensionsAliveForInFlightConversions() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Native/MarkdownExit.c")
        let executable = directory.url.appendingPathComponent("markdown-exit")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-pthread", source.path, "-o", executable.path]
        try runSumraProcess(compiler)
        XCTAssertEqual(compiler.terminationStatus, 0)
        let library = try NativeFile.libraryURL(for: .mupdf)
        for mode in ["render", "outline"] {
            let process = Process()
            process.executableURL = executable
            process.arguments = [library.path, mode, directory.url.appendingPathComponent(mode).path]
            try runSumraProcess(process)
            XCTAssertEqual(process.terminationReason, .exit, mode)
            XCTAssertEqual(process.terminationStatus, 0, mode)
        }
    }

    func testPageLookupResolvesVirtualAliasesAndRejectsEscapingSymlinks() throws {
        let directory = try TemporaryDirectory(), outside = try TemporaryDirectory()
        defer { withExtendedLifetime((directory, outside)) {} }
        let file = directory.url.appendingPathComponent("C#1?.md")
        try Data("# Chapter".utf8).write(to: file)
        let source = try MarkupSource(file)
        let virtual = URL(string: "leaf://book/entry/")!
        for name in ["C#1?.md", "C#1?.html", "C#1?"] {
            let url = virtual.appendingPathComponent(name)
            XCTAssertEqual(source.pageIndex(url), 0)
            XCTAssertEqual(try source.fileURL(url), file.resolvingSymlinksInPath())
        }
        let alias = directory.url.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertEqual(source.pageIndex(virtual.appendingPathComponent("alias.md")), 0)
        let escaped = outside.url.appendingPathComponent("outside.md")
        try Data("outside".utf8).write(to: escaped)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: escaped)
        for name in ["alias.md", "alias.html", "alias"] {
            XCTAssertThrowsError(try source.fileURL(virtual.appendingPathComponent(name)))
            XCTAssertNil(source.pageIndex(virtual.appendingPathComponent(name)))
        }
        // A collected URL keeps its page identity, but never grants permission
        // to read a replacement symlink outside the book folder.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: escaped)
        XCTAssertEqual(source.pageIndex(source.startURL), 0)
        XCTAssertThrowsError(try source.fileURL(source.startURL))
        XCTAssertNil(source.pageIndex(URL(string: "https://book/entry/C%231%3F.md")!))
    }

    func testCollectedPagesKeepCanonicalIdentitySortingAndOpenedHiddenFile() throws {
        for ext in ["md", "html"] {
            let directory = try TemporaryDirectory(), outside = try TemporaryDirectory()
            defer { withExtendedLifetime((directory, outside)) {} }
            let names = [".opened.\(ext)", "Book 2.\(ext)", "Book 10.\(ext)", "C#1?.\(ext)",
                         "chapters/part.\(ext)", "chapters/deep/tail.\(ext)"]
            for name in names + [".unopened.\(ext)", "chapters/deep/beyond/excluded.\(ext)"] {
                let file = directory.url.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("heading".utf8).write(to: file)
            }
            let target = directory.url.appendingPathComponent("Book 2.\(ext)")
            try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("alias.\(ext)"), withDestinationURL: target)
            try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("loop"), withDestinationURL: directory.url)
            let escaped = outside.url.appendingPathComponent("outside.\(ext)")
            try Data("outside".utf8).write(to: escaped)
            try FileManager.default.createSymbolicLink(at: directory.url.appendingPathComponent("escape.\(ext)"), withDestinationURL: escaped)

            let opened = directory.url.appendingPathComponent(names[0])
            let source = try MarkupSource(opened)
            let files = try source.pages.map { try source.fileURL($0) }
            let expected = names.map { directory.url.appendingPathComponent($0).resolvingSymlinksInPath() }
            XCTAssertEqual(files.count, expected.count, "Aliases must not duplicate collected pages")
            XCTAssertEqual(Set(files), Set(expected), "Keep the opened hidden file, depth limit and folder boundary")
            XCTAssertLessThan(try XCTUnwrap(files.firstIndex(of: target.resolvingSymlinksInPath())),
                              try XCTUnwrap(files.firstIndex(of: directory.url.appendingPathComponent("Book 10.\(ext)").resolvingSymlinksInPath())))
            XCTAssertEqual(try source.fileURL(source.startURL), opened.resolvingSymlinksInPath())
            XCTAssertNotNil(source.pageIndex(source.startURL))
        }
    }

    private func browserSource(_ markdown: String) throws -> (MarkupSource, TemporaryDirectory) {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("Build the MuPDF engine before native integration tests")
        }
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("source.md")
        try Data(markdown.utf8).write(to: url)
        return (try MarkupSource(url), directory)
    }

    private func generatedHTML(_ markdown: String, extension fileExtension: String = "md") throws -> String {
        let engine = try NativeFile.libraryURL(for: .mupdf)
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw XCTSkip("Build the MuPDF engine before native integration tests")
        }
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("source." + fileExtension)
        let original = Data(markdown.utf8)
        try original.write(to: url)
        // Source conversion does not require pagination, including an empty document.
        let document = try NativeFile(url, engine: .mupdf, deferReflowLayout: true)
        let html = try XCTUnwrap(document.htmlSource())
        XCTAssertEqual(try Data(contentsOf: url), original)
        return html
    }

    func testLongMarkdownExtensionDoesNotDependOnHeadingSniffing() throws {
        XCTAssertEqual(try generatedHTML("Ordinary **prose**.", extension: "markdown"), "<p>Ordinary <strong>prose</strong>.</p>\n")
    }

    @MainActor
    func testPDFContentKeepsPriorityOverMarkdownFilenameAndLeadingHeading() throws {
        let fixture = try nativePDFReadingFixture()
        let directory = try XCTUnwrap(fixture.temporary)
        defer { withExtendedLifetime(fixture) {} }
        let bytes = Data("# Leading heading\n".utf8) + (try Data(contentsOf: fixture.url))
        for suffix in ["md", "markdown"] {
            let url = directory.url.appendingPathComponent("misnamed." + suffix)
            try bytes.write(to: url)
            XCTAssertEqual(Format.resolve(url.lastPathComponent, prefix: bytes.prefix(2048)), .pdf)
            let document = try NativeFile(url, engine: .mupdf)
            XCTAssertNotNil(try document.pdfInfo(), "Opening must preserve the PDF recognized from its content")
            XCTAssertEqual(document.count, 1)
        }
    }

    func testFixedMarkdownResolvesImagesRelativeToItsSourceDirectory() throws {
        let (_, directory) = try browserSource("Intro\n\n![swatch](images/red.png)\n")
        defer { withExtendedLifetime(directory) {} }
        let images = directory.url.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: images.appendingPathComponent("red.png"))
        let document = try NativeFile(directory.url.appendingPathComponent("source.md"), engine: .mupdf)
        let rendered = NSBitmapImageRep(cgImage: try document.image(0, width: 420))
        var redPixels = 0
        for y in 0..<rendered.pixelsHigh { for x in 0..<rendered.pixelsWide {
            if let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 { redPixels += 1 }
        } }
        XCTAssertGreaterThan(redPixels, 100, "The relative image must actually render, not a missing-image placeholder")
    }

    func testMalformedInlineCommentsDoNotHideFollowingMarkdown() throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let url = directory.url.appendingPathComponent("inline-comments.md")
        try Data("""
            Before <!-- ^TTT ><!-- TTT$ >

            ## Last heading

            VisibleTailMarker <i>still italic</i> <!-- HiddenComment --> after.
            """.utf8).write(to: url)
        let document = try NativeFile(url, engine: .mupdf)
        let text = try XCTUnwrap(document.text(0))
        XCTAssertTrue(text.contains("VisibleTailMarker"))
        XCTAssertTrue(text.contains("TTT"), "Malformed inline comments are ordinary Markdown text")
        XCTAssertTrue(text.contains("still italic"), "Valid inline HTML remains supported")
        XCTAssertFalse(text.contains("HiddenComment"), "Valid comments remain hidden")
        XCTAssertTrue(try document.outline().contains { $0.title == "Last heading" })
        let html = try XCTUnwrap(document.htmlSource())
        XCTAssertTrue(html.contains("<i>still italic</i>"))
        XCTAssertTrue(html.contains("<!-- HiddenComment -->"))
    }

    func testEmptyMarkdownProducesEmptyHTML() throws {
        XCTAssertEqual(try generatedHTML(""), "")
    }

    func testSingleByteMarkdownKeepsItsCharacter() throws {
        XCTAssertEqual(try generatedHTML("x"), "<p>x</p>\n")
    }

    func testFinalMultibyteCharacterIsNotTruncated() throws {
        for text in ["末", "tailé", "tail🙂"] {
            XCTAssertEqual(try generatedHTML(text), "<p>\(text)</p>\n", text)
        }
    }

    func testFinalMarkdownDelimiterWithoutNewlineIsPreserved() throws {
        let expected = "<p><strong>complete</strong></p>\n"
        XCTAssertEqual(try generatedHTML("**complete**"), expected)
        XCTAssertEqual(try generatedHTML("**complete**\n"), expected)
    }

    func testBrowserMarkdownKeepsChunkBoundaryUTF8LongLinesAndExtensions() async throws {
        let prefix = "# Chunked\n\n"
        // One small 64 KiB fixture, with the first emoji split across feeds.
        let longLine = String(repeating: "x", count: 65_535 - prefix.utf8.count) + "🙂tail **complete**"
        let markdown = prefix + longLine + "\n\n## 中文标题\n\n| A | B |\n| - | - |\n| one | two |\n\n- [x] Task\n\n~~gone~~\n\n末🙂"
        let (source, directory) = try browserSource(markdown)
        defer { withExtendedLifetime(directory) {} }
        let (data, encoding) = try await source.response(source.startURL)
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(encoding, "utf-8")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.hasSuffix("</body></html>"))
        XCTAssertTrue(html.contains(longLine.replacingOccurrences(of: "**complete**", with: "<strong>complete</strong>")))
        XCTAssertTrue(html.contains("<a id=\"chunked\"></a>"))
        XCTAssertTrue(html.contains("<a id=\"中文标题\"></a>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("<p>末🙂</p>"))
        let (outline, _) = try await source.response(URL(string: "leaf://book/outline")!)
        let items = try JSONDecoder().decode([ContentsItem].self, from: outline)
        XCTAssertEqual(items.map(\.title), ["source.md", "Chunked", "中文标题"])
        XCTAssertEqual(items.map(\.depth), [0, 1, 2])
        XCTAssertTrue(items[1].target.hasSuffix("#chunked"))
        XCTAssertEqual(try Data(contentsOf: source.url), Data(markdown.utf8))
    }

    func testOutlineCanRetryAfterAnUnreadableSiblingIsRestored() async throws {
        for ext in ["md", "html"] {
            let directory = try TemporaryDirectory()
            defer { withExtendedLifetime(directory) {} }
            let first = directory.url.appendingPathComponent("A.\(ext)")
            let sibling = directory.url.appendingPathComponent("B.\(ext)")
            func heading(_ text: String) -> Data {
                Data((ext == "md" ? "# \(text)\n\nText" : "<!DOCTYPE html><h1 id='heading'>\(text)</h1><p>Text</p>").utf8)
            }
            try heading("First heading").write(to: first)
            try heading("Original sibling heading").write(to: sibling)
            let source = try MarkupSource(first)
            _ = try await source.response(source.startURL)
            try FileManager.default.removeItem(at: sibling)
            let request = URL(string: "leaf://book/outline")!
            do {
                _ = try await source.response(request)
                XCTFail("The missing sibling must report its read failure: \(ext)")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            try heading("Restored sibling heading").write(to: sibling)
            let (data, _) = try await source.response(request)
            let items = try JSONDecoder().decode([ContentsItem].self, from: data)
            XCTAssertEqual(items.map(\.title), ["A.\(ext)", "First heading", "B.\(ext)", "Restored sibling heading"])
            XCTAssertEqual(items.map(\.page), [0, 0, 1, 1])
            let (cached, _) = try await source.response(request)
            XCTAssertEqual(cached, data)
        }
    }

    func testOutlineKeepsRenderedHeadingsAfterTheSourceBecomesUnavailable() async throws {
        let (source, directory) = try browserSource("# Loaded heading\n\nText")
        defer { withExtendedLifetime(directory) {} }
        let (data, _) = try await source.response(source.startURL)
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("id=\"loaded-heading\""))
        try FileManager.default.removeItem(at: source.url)
        let (outline, _) = try await source.response(URL(string: "leaf://book/outline")!)
        let items = try JSONDecoder().decode([ContentsItem].self, from: outline)
        XCTAssertEqual(items.map(\.title), ["source.md", "Loaded heading"])
        XCTAssertEqual(items[1].depth, 1)
        XCTAssertTrue(items[1].target.hasSuffix("#loaded-heading"))
    }

    func testCompletedOutlineSurvivesLaterRenderingAndUnavailableSources() async throws {
        let directory = try TemporaryDirectory()
        defer { withExtendedLifetime(directory) {} }
        let first = directory.url.appendingPathComponent("A.md")
        let second = directory.url.appendingPathComponent("B.md")
        try Data("# First heading\n\nFirst text".utf8).write(to: first)
        try Data("# Second heading\n\nSecond text".utf8).write(to: second)
        let source = try MarkupSource(first)
        _ = try await source.response(source.startURL)
        let request = URL(string: "leaf://book/outline")!
        let (outline, _) = try await source.response(request)
        let items = try JSONDecoder().decode([ContentsItem].self, from: outline)
        XCTAssertEqual(items.map(\.title), ["A.md", "First heading", "B.md", "Second heading"])
        let secondURL = try XCTUnwrap(source.pages.last)
        let (rendered, _) = try await source.response(secondURL)
        XCTAssertTrue(try XCTUnwrap(String(data: rendered, encoding: .utf8)).contains("id=\"second-heading\""))
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        let (cached, _) = try await source.response(request)
        XCTAssertEqual(cached, outline)
    }
}
#endif
