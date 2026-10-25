import Foundation
import XCTest
@testable import SumraCore

final class KindleFormatTests: XCTestCase {
    private func put(_ value: Int, _ offset: Int, _ size: Int = 4, in data: inout Data) {
        for i in 0..<size { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (size - i - 1))) }
    }

    private func variable(_ value: Int) -> Data {
        var bytes = [UInt8(value & 127) | 128], remaining = value >> 7
        while remaining > 0 { bytes.insert(UInt8(remaining & 127), at: 0); remaining >>= 7 }
        return Data(bytes)
    }

    private func index(_ entries: [(String, [Int])], skeleton: Bool) -> [Data] {
        var top = Data(repeating: 0, count: 192), records = Data(repeating: 0, count: 192)
        top.replaceSubrange(0..<4, with: Data("INDX".utf8))
        records.replaceSubrange(0..<4, with: Data("INDX".utf8))
        put(192, 4, in: &top); put(1, 24, in: &top)
        var tagx = Data("TAGX".utf8); tagx.append(Data(repeating: 0, count: 8))
        let tags: [UInt8] = skeleton ? [1, 1, 3, 0, 6, 2, 12, 0, 0, 0, 0, 1]
                                     : [2, 1, 1, 0, 3, 1, 2, 0, 4, 1, 4, 0, 6, 2, 8, 0, 0, 0, 0, 1]
        put(12 + tags.count, 4, in: &tagx); put(1, 8, in: &tagx)
        tagx.append(contentsOf: tags); top.append(tagx)
        var offsets = [Int]()
        for (name, values) in entries {
            offsets.append(records.count)
            records.append(UInt8(name.utf8.count)); records.append(Data(name.utf8))
            records.append(15)
            if skeleton {
                // Real KF8 skeleton tables repeat the first count/range tuple
                // using TAGX byte-count fields; both tuples describe one part.
                let counts = variable(values[0]) + variable(values[0])
                let ranges = variable(values[1]) + variable(values[2]) + variable(values[1]) + variable(values[2])
                records.append(variable(counts.count)); records.append(variable(ranges.count))
                records.append(counts); records.append(ranges)
            } else { for value in values { records.append(variable(value)) } }
        }
        put(records.count, 20, in: &records); put(entries.count, 24, in: &records)
        records.append(Data("IDXT".utf8))
        for offset in offsets { records.append(contentsOf: [UInt8(offset >> 8), UInt8(offset & 255)]) }
        return [top, records]
    }

    private func book(displacement: Int = 0, flow: String = ".chapter { color: #123456; }", svg: Bool = false, image: Data? = nil, mutate: ((inout [Data]) -> Void)? = nil) -> Data {
        let css = Data(flow.utf8)
        var skeleton = "<html><head><title>Chapter metadata</title><link rel='stylesheet' href='kindle:flow:0001?mime=text/css'/></head><body class='book-body'></body></html>"
        if svg { skeleton = "<html><body><img src='kindle:flow:0001?mime=image/svg+xml'/></body></html>" }
        let secondSkeleton = skeleton.replacingOccurrences(of: "</head>", with: "<style>.later { font-weight: bold; }</style></head>")
            .replacingOccurrences(of: "class='book-body'", with: "class='later' style='margin: 0'")
        let insertion = skeleton.range(of: "</body>")!.lowerBound.utf16Offset(in: skeleton)
        let link = "<a href='kindle:pos:fid:0001:off:\(String(displacement, radix: 32))'>Next chapter</a><a href='https://example.org'>External</a>"
        let target = "<h2 class='chapter'>Chapter 二</h2><p>Distinct target passage.</p><!-- <body>comment</body><head>comment</head> --><style>.example::after { content: '<body>'; }</style>"
        let secondInsertion = secondSkeleton.range(of: "</body>")!.lowerBound.utf16Offset(in: secondSkeleton)
        let firstSize = skeleton.utf8.count + link.utf8.count
        let raw = Data((skeleton + link + secondSkeleton + target).utf8)
        let text = raw + css
        var header = Data(repeating: 0, count: 280)
        put(1, 0, 2, in: &header); put(text.count, 4, in: &header); put(1, 8, 2, in: &header)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(264, 20, in: &header); put(65001, 28, in: &header); put(8, 36, in: &header)
        put(0xffff_ffff, 108, in: &header); put(0xffff_ffff, 168, in: &header)
        put(2, 192, in: &header); put(3, 248, in: &header); put(5, 252, in: &header)
        var fdst = Data("FDST".utf8); fdst.append(Data(repeating: 0, count: 24))
        put(12, 4, in: &fdst); put(2, 8, in: &fdst)
        put(0, 12, in: &fdst); put(raw.count, 16, in: &fdst)
        put(raw.count, 20, in: &fdst); put(text.count, 24, in: &fdst)
        var records = [header, text, fdst]
        records += index([(String(insertion), [0, 0, 0, 0, link.utf8.count]),
                          (String(firstSize + secondInsertion), [0, 1, 1, 0, target.utf8.count])], skeleton: false)
        records += index([("first", [1, 0, skeleton.utf8.count]),
                          ("second", [1, firstSize, secondSkeleton.utf8.count])], skeleton: true)
        if let image {
            put(records.count, 108, in: &records[0])
            records.append(image)
        }
        mutate?(&records)
        var pdb = Data(repeating: 0, count: 78 + 8 * records.count + 2)
        pdb.replaceSubrange(60..<68, with: Data("BOOKMOBI".utf8)); put(records.count, 76, 2, in: &pdb)
        for (i, record) in records.enumerated() { put(pdb.count, 78 + i * 8, in: &pdb); pdb.append(record) }
        return pdb
    }

    func testKF8ReassemblesBodySeparatesStylesAndTranslatesFragmentLinks() throws {
        let input = book(), content = try XCTUnwrap(LegacyText.mobiContent(input))
        let html = String(decoding: content.html, as: UTF8.self)
        let second = String(decoding: try XCTUnwrap(content.additionalParts.first), as: UTF8.self)
        XCTAssertEqual(content.additionalParts.count, 1)
        XCTAssertTrue(html.contains("href=\"part-00001.xhtml#mobi-filepos-"), html)
        XCTAssertTrue(html.contains("</a><a href='https://example.org'>External</a></body></html>"))
        XCTAssertTrue(second.contains("</a><h2 class='chapter'>Chapter 二</h2>"))
        XCTAssertTrue(html.contains("<body class='book-body'>"))
        XCTAssertTrue(second.contains("<body class='later' style='margin: 0'>"))
        XCTAssertTrue(second.contains("<!-- <body>comment</body><head>comment</head> -->"))
        XCTAssertTrue(second.contains("<style>.example::after { content: '<body>'; }</style>"))
        XCTAssertFalse(html.contains("font-weight: bold"), "The later part stylesheet must stay out of the earlier document")
        XCTAssertTrue(second.contains("<style>.later { font-weight: bold; }</style>"))
        XCTAssertTrue(second.contains("href='kf8-flow-1.css'"))
        XCTAssertFalse(html.contains("kindle:"))
        XCTAssertFalse(html.contains("color: #123456"), "A flow stylesheet must never become visible book text")
        XCTAssertTrue(html.contains("href='kf8-flow-1.css'"))
        XCTAssertEqual(content.resources["kf8-flow-1.css"], Data(".chapter { color: #123456; }".utf8))
        XCTAssertEqual(second.components(separatedBy: "Distinct target passage.").count - 1, 1)
        XCTAssertEqual(input, book(), "Decoding must not mutate the source bytes")
    }

    func testKF8MaterializesDeterministicEPUBWithSeparateStyleContexts() throws {
        let content = try XCTUnwrap(LegacyText.mobiContent(book()))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try content.materialize(in: directory)
        let first = try Data(contentsOf: url)
        let archive = try Archive(url)
        XCTAssertEqual(archive.entries.first, "mimetype")
        XCTAssertEqual(try archive.data("mimetype"), Data("application/epub+zip".utf8))
        XCTAssertEqual(try archive.data("part-00000.xhtml"), content.html)
        XCTAssertEqual(try archive.data("part-00001.xhtml"), content.additionalParts[0])
        XCTAssertEqual(try archive.data("kf8-flow-1.css"), content.resources["kf8-flow-1.css"])
        XCTAssertEqual(try content.materialize(in: directory), url)
        XCTAssertEqual(try Data(contentsOf: url), first, "Reopening the same source must produce stable archive bytes")
    }

    func testKF8NonzeroFragmentOffsetCannotSplitMarkupOrUTF8() throws {
        for displacement in [2, 29] {
            let content = try XCTUnwrap(LegacyText.mobiContent(book(displacement: displacement)))
            let html = String(decoding: ([content.html] + content.additionalParts).reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
            XCTAssertFalse(html.contains("kindle:pos:"))
            XCTAssertTrue(html.contains("<h2 class='chapter'>"))
            XCTAssertTrue(html.contains("二"), html)
            XCTAssertFalse(html.contains("�"))
            XCTAssertEqual(html.components(separatedBy: "<a id=\"mobi-filepos-").count - 1, 1)
        }
    }

    func testKF8CSSAndSVGFlowsResolveEmbeddedImages() throws {
        let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 0, count: 56)
        let css = ".picture { background-image: url(kindle:embed:0001?mime=image/png); }"
        let styled = try XCTUnwrap(LegacyText.mobiContent(book(flow: css, image: image)))
        XCTAssertEqual(styled.resources["00001"], image)
        XCTAssertEqual(String(decoding: try XCTUnwrap(styled.resources["kf8-flow-1.css"]), as: UTF8.self),
                       ".picture { background-image: url(00001); }")
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><image href='kindle:embed:0001?mime=image/png'/></svg>"
        let illustrated = try XCTUnwrap(LegacyText.mobiContent(book(flow: svg, svg: true, image: image)))
        XCTAssertEqual(illustrated.resources["00001"], image)
        XCTAssertTrue(String(decoding: illustrated.html, as: UTF8.self).contains("src='kf8-flow-1.svg'"))
        XCTAssertEqual(String(decoding: try XCTUnwrap(illustrated.resources["kf8-flow-1.svg"]), as: UTF8.self),
                       "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><image href='00001'/></svg>")
    }

    func testKF8InvalidDisplacementsDoNotCreateOutOfBoundsAnchors() throws {
        for displacement in [-1, 1_000_000] {
            let content = try XCTUnwrap(LegacyText.mobiContent(book(displacement: displacement)))
            let html = String(decoding: ([content.html] + content.additionalParts).reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
            XCTAssertFalse(html.contains("<a id=\"mobi-filepos-"))
            XCTAssertTrue(html.contains("Distinct target passage."))
            XCTAssertTrue(html.contains("href='https://example.org'"))
        }
    }

    func testKF8RejectsTruncatedFlowAndIndexRanges() {
        let corruptions: [(inout [Data]) -> Void] = [
            { self.put(0xffff_ffff, 24, in: &$0[2]) },
            { self.put(0xffff_ffff, 24, in: &$0[4]) },
            { self.put(0xffff_ffff, 4, in: &$0[3]) },
            { self.put(0xffff_ffff, 252, in: &$0[0]) },
            { $0[4].removeLast() }
        ]
        for corrupt in corruptions { XCTAssertThrowsError(try LegacyText.mobiContent(book(mutate: corrupt))) }
    }

    func testKF8RejectsEmptySkeletonAndFragmentTables() {
        // Keep the Palm container, text, FDST and INDX headers intact. An
        // empty top-level index has zero following index records, so neither
        // table contributes entries despite its unused data record remaining.
        let input = book(mutate: { records in
            self.put(0, 24, in: &records[3])
            self.put(0, 24, in: &records[5])
        })
        XCTAssertThrowsError(try LegacyText.mobiContent(input)) { error in
            XCTAssertTrue(error is ReadError, "An empty KF8 spine must be a read failure")
        }
    }
}
