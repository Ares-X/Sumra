import Foundation
import XCTest
@testable import SumraCore

final class LegacyBookTests: XCTestCase {
    // Small real-layout PDB/HUFF/CDIC fixtures. They protect decoder behavior
    // without requiring an engine, a compiler subprocess or a sample download.
    private func put(_ value: Int, _ offset: Int, _ size: Int, in data: inout Data) {
        for index in 0..<size { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (size - index - 1))) }
    }
    private func integer(_ data: Data, _ offset: Int, _ size: Int) -> Int {
        data[offset..<offset + size].reduce(0) { ($0 << 8) | Int($1) }
    }
    private func pdb(_ records: [Data], creator: String = "BOOKMOBI") -> Data {
        var data = Data(repeating: 0, count: 78 + records.count * 8 + 2)
        data.replaceSubrange(60..<68, with: Data(creator.utf8))
        put(records.count, 76, 2, in: &data)
        for (index, record) in records.enumerated() {
            put(data.count, 78 + index * 8, 4, in: &data)
            put(0xa000_0000 + index, 82 + index * 8, 4, in: &data)
            data.append(record)
        }
        return data
    }
    private func records(_ data: Data) -> [Data] {
        let count = integer(data, 76, 2)
        let offsets = (0..<count).map { integer(data, 78 + $0 * 8, 4) } + [data.count]
        return (0..<count).map { data.subdata(in: offsets[$0]..<offsets[$0 + 1]) }
    }
    private func huff(terminal: Bool = true) -> Data {
        var data = Data(repeating: 0, count: 1304)
        data.replaceSubrange(0..<4, with: Data("HUFF".utf8))
        put(24, 4, 4, in: &data); put(24, 8, 4, in: &data); put(1048, 12, 4, in: &data)
        // Eight-bit codes: byte FF selects symbol 0, FE selects symbol 1.
        for index in 0..<256 { put((255 << 8) | (terminal ? 0x80 : 0) | 8, 24 + index * 4, 4, in: &data) }
        put(255, 1048 + 15 * 4, 4, in: &data)
        return data
    }
    private func cdic(_ phrases: [(Data, literal: Bool)]) -> Data {
        precondition(phrases.count == 2)
        var body = Data(repeating: 0, count: 4)
        for (index, phrase) in phrases.enumerated() {
            put(body.count, index * 2, 2, in: &body)
            var length = Data(repeating: 0, count: 2)
            put(phrase.0.count | (phrase.literal ? 0x8000 : 0), 0, 2, in: &length)
            body.append(length); body.append(phrase.0)
        }
        var header = Data("CDIC".utf8)
        header.append(Data(repeating: 0, count: 12))
        put(16, 4, 4, in: &header); put(2, 8, 4, in: &header); put(1, 12, 4, in: &header)
        header.append(body)
        return header
    }
    private func book(text: [Data] = [Data([255, 254])], length: Int = 2,
                      compression: Int = 17480, flags: Int = 0,
                      tables: [Data]? = nil, resources: [Data] = [Data("RESOURCE".utf8)],
                      headerLength: Int = 228, headerStorage: Int? = nil) -> Data {
        var header = Data(repeating: 0, count: headerStorage ?? (16 + headerLength))
        put(compression, 0, 2, in: &header); put(length, 4, 4, in: &header)
        put(text.count, 8, 2, in: &header); put(4096, 10, 2, in: &header)
        header.replaceSubrange(16..<20, with: Data("MOBI".utf8))
        put(headerLength, 20, 4, in: &header); put(65001, 28, 4, in: &header)
        put(1 + text.count, 16 + 92, 4, in: &header)
        let dictionaryRecords = compression == 17480 ? tables ?? [huff(), cdic([(Data("A".utf8), true), (Data("B".utf8), true)])] : []
        put(1 + text.count + resources.count, 16 + 96, 4, in: &header)
        put(dictionaryRecords.count, 16 + 100, 4, in: &header)
        if headerLength >= 164 { put(0xffff_ffff, 16 + 152, 4, in: &header) }
        if headerLength >= 228 { put(flags, 16 + 226, 2, in: &header) }
        return pdb([header] + text + resources + dictionaryRecords)
    }
    private func palm(_ text: Data, creator: String = "TEXtTlDc", compression: Int = 1, length: Int? = nil) -> Data {
        var header = Data(repeating: 0, count: 16)
        put(compression, 0, 2, in: &header); put(length ?? text.count, 4, 4, in: &header)
        put(1, 8, 2, in: &header); put(4096, 10, 2, in: &header)
        return pdb([header, text], creator: creator)
    }
    private func image(_ size: Int = 64, marker: UInt8 = 65) -> Data {
        var bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        bytes.append(Data(repeating: marker, count: size - bytes.count))
        return bytes
    }

    func testHuffRepackPreservesResourcesAndRecordIdentity() throws {
        let original = book()
        let rewritten = try LegacyText.mobi(original), before = records(original), after = records(rewritten)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(integer(after[0], 0, 2), 1)
        XCTAssertEqual(integer(after[0], 4, 4), 2)
        XCTAssertEqual(after[1], Data("AB".utf8))
        XCTAssertEqual(Array(after.dropFirst(2)), Array(before.dropFirst(2)))
        for index in after.indices {
            XCTAssertEqual(rewritten.subdata(in: (82 + index * 8)..<(86 + index * 8)), original.subdata(in: (82 + index * 8)..<(86 + index * 8)))
        }
    }

    func testNonterminalAndRecursiveDictionaryPhrases() throws {
        let nested = cdic([(Data([254]), false), (Data("phrase".utf8), true)])
        let output = try LegacyText.mobi(book(text: [Data([255])], length: 6, tables: [huff(terminal: false), nested]))
        XCTAssertEqual(records(output)[1], Data("phrase".utf8))
        let second = cdic([(Data("second".utf8), true), (Data("unused".utf8), true)])
        let multi = try LegacyText.mobi(book(text: [Data([253])], length: 6, tables: [huff(), nested, second]))
        XCTAssertEqual(records(multi)[1], Data("second".utf8))
    }

    func testHuffCannotRecurseOrReadOutsideDictionary() {
        let cyclic = cdic([(Data([255]), false), (Data("B".utf8), true)])
        XCTAssertThrowsError(try LegacyText.mobi(book(text: [Data([255])], length: 1, tables: [huff(), cyclic]))) {
            XCTAssertTrue($0.localizedDescription.contains("Recursive"))
        }
        var corrupt = cdic([(Data("A".utf8), true), (Data("B".utf8), true)])
        put(65535, 16, 2, in: &corrupt)
        XCTAssertThrowsError(try LegacyText.mobi(book(tables: [huff(), corrupt])))
        XCTAssertThrowsError(try LegacyText.mobi(book(text: [Data([252])], length: 1))) {
            XCTAssertTrue($0.localizedDescription.contains("dictionary index"))
        }
    }

    func testTrailerRemovalAndDeclaredHeaderBoundary() throws {
        let original = book(text: [Data("Hello".utf8) + Data([0, 0x80, 0, 0, 0x84])], length: 5, compression: 2, flags: 3)
        let output = records(try LegacyText.mobi(original))
        XCTAssertEqual(output[1], Data("Hello".utf8))
        XCTAssertEqual(integer(output[0], 16 + 226, 2), 0)
        var shortHeader = book(headerLength: 116, headerStorage: 244)
        let first = integer(shortHeader, 78, 4)
        put(0x5678, first + 242, 2, in: &shortHeader)
        XCTAssertEqual(integer(records(try LegacyText.mobi(shortHeader))[0], 242, 2), 0x5678)
        XCTAssertThrowsError(try LegacyText.mobi(book(text: [Data([0, 0, 0, 0xff])], length: 1, compression: 1, flags: 2)))
    }

    func testRepackingKeepsUnusedTextRecordsAndAppPointer() throws {
        var original = book(text: [Data([255]), Data([254]), Data()], length: 2)
        let resourceOffset = integer(original, 78 + 4 * 8, 4)
        put(resourceOffset + 2, 52, 4, in: &original)
        let output = try LegacyText.mobi(original), parts = records(output)
        XCTAssertEqual(parts[1], Data("AB".utf8))
        XCTAssertEqual(parts[2], Data([0]))
        XCTAssertEqual(parts[3], Data([0]))
        XCTAssertEqual(integer(output, 52, 4), integer(output, 78 + 4 * 8, 4) + 2)
        for index in 0..<parts.count - 1 { XCTAssertLessThan(integer(output, 78 + index * 8, 4), integer(output, 78 + (index + 1) * 8, 4)) }
    }

    func testRepackSplitsTextForMuPDFWithoutChangingRecordIndexes() throws {
        let phrase = Data(repeating: 65, count: 1000)
        let output = records(try LegacyText.mobi(book(text: [Data(repeating: 255, count: 3), Data(repeating: 255, count: 2)], length: 5000,
            tables: [huff(), cdic([(phrase, true), (Data("B".utf8), true)])])))
        XCTAssertEqual(output[1], Data(repeating: 65, count: 4096))
        XCTAssertEqual(output[2], Data(repeating: 65, count: 904))
        XCTAssertEqual(output[3], Data("RESOURCE".utf8))
        XCTAssertThrowsError(try LegacyText.mobi(book(text: [Data(repeating: 255, count: 5)], length: 5000,
            tables: [huff(), cdic([(phrase, true), (Data("B".utf8), true)])])))
    }

    func testPassthroughAndRealDRMErrors() throws {
        let ordinary = book(text: [Data("AB".utf8)], compression: 1)
        XCTAssertEqual(try LegacyText.mobi(ordinary), ordinary)
        XCTAssertEqual(try LegacyText.mobi(Data("ordinary EPUB or FB2 bytes".utf8)), Data("ordinary EPUB or FB2 bytes".utf8))
        var zeroDRM = ordinary
        put(0, integer(zeroDRM, 78, 4) + 16 + 152, 4, in: &zeroDRM)
        XCTAssertEqual(try LegacyText.mobi(zeroDRM), zeroDRM)
        for field in [12, 16 + 152] {
            var encrypted = ordinary
            put(2, integer(encrypted, 78, 4) + field, field == 12 ? 2 : 4, in: &encrypted)
            XCTAssertThrowsError(try LegacyText.mobi(encrypted)) { XCTAssertTrue($0.localizedDescription.contains("DRM")) }
        }
        var slice = Data([0, 0]); slice.append(book())
        XCTAssertEqual(records(try LegacyText.mobi(slice.dropFirst(2)))[1], Data("AB".utf8))
    }

    func testPalmDeclaredLengthDoesNotTruncateDecodedText() throws {
        XCTAssertEqual(try LegacyText.palm(palm(Data("short".utf8), length: 9)), Data("short".utf8))
        XCTAssertEqual(try LegacyText.palm(palm(Data("complete".utf8), length: 3)), Data("complete".utf8))
    }

    func testTealMarkupBookmarksAndLiteralText() throws {
        let raw = "plain <script>& text\r\n<BOOKMARK NAME='A &amp; B'><HEADER TEXT=Chapter FONT=2><HRULE>" +
            "<LABEL NAME='end'><LINK TAG='end' TEXT='Jump &amp; Go'><LINK TAG='end' TEXT='External' FILE='Other'><TEALPAINT SRC='Pictures'>结束"
        let content = try LegacyText.palmContent(palm(Data(raw.utf8)))
        let html = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(html.contains("plain &lt;script&gt;&amp; text\n<br>"))
        XCTAssertTrue(html.contains("<h1>Chapter</h1><hr>"))
        XCTAssertTrue(html.contains("<a id=\"end\"></a><a href=\"#end\">Jump &amp; Go</a>"))
        XCTAssertFalse(html.contains("External"))
        XCTAssertFalse(html.contains("Pictures"))
        XCTAssertTrue(html.hasSuffix("结束</body></html>"))
        XCTAssertEqual(content.bookmarks.map(\.title), ["A & B"])
        XCTAssertEqual(content.bookmarks.map(\.fragment), ["ToC!Entry!1"])
        XCTAssertTrue(html.contains("id=\"ToC!Entry!1\""))
        let nul = try LegacyText.palmContent(palm(Data([65, 0, 66])))
        XCTAssertTrue(String(decoding: nul.html, as: UTF8.self).contains("A B"))
    }

    func testPluckerMatchesOnlyTheActualUpstreamPalmDOCLayout() throws {
        let content = try LegacyText.palmContent(palm(Data("static text".utf8), creator: "DataPlkr"))
        XCTAssertTrue(String(decoding: content.html, as: UTF8.self).contains("static text"))
        let standardPluckerRecord = Data(repeating: 0, count: 16)
        XCTAssertThrowsError(try LegacyText.palmContent(pdb([standardPluckerRecord, Data([1, 2, 3])], creator: "DataPlkr"))) {
            XCTAssertTrue($0.localizedDescription.contains("Plucker record format is unsupported"))
            XCTAssertTrue($0.localizedDescription.contains("Invalid Palm text record count"))
        }
    }

    func testKindleReflowKeepsTextAndRealImageRecordIndexes() throws {
        let html = "<html><body><p>before</p><IMG alt=\"src='kindle:embed:02'\" data-src='kindle:embed:02' src='KINDLE:EMBED:04?mime=image/png'/>" +
            "<img src='kindle:embed:01'><p>after</p></body></html>"
        let first = image(), fourth = image(marker: 66)
        let input = book(text: [Data(html.utf8)], length: html.utf8.count, compression: 1,
            resources: [first, Data("FLIS metadata".utf8), Data("unknown record".utf8), fourth])
        let content = try XCTUnwrap(LegacyText.mobiContent(input))
        let result = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(result.contains("<p>before</p>")); XCTAssertTrue(result.contains("<p>after</p>"))
        XCTAssertTrue(result.contains("src=\"00004\"")); XCTAssertTrue(result.contains("src=\"00001\""))
        XCTAssertTrue(result.contains("alt=\"src='kindle:embed:02'\""))
        XCTAssertEqual(Set(content.resources.keys), ["00001", "00004"])
        XCTAssertEqual(content.resources["00001"], first); XCTAssertEqual(content.resources["00004"], fourth)
    }

    func testKindleFixedLayoutUsesEmbedOrderAndKeepsRepeatedPages() throws {
        let html = "<html><head><meta name='viewport' content='width=1200,height=1600'></head><body>" +
            "junk<img src='kindle:embed:03'><img src='kindle:embed:01'><img src='kindle:embed:03'></body></html>"
        let content = try XCTUnwrap(LegacyText.mobiContent(book(text: [Data(html.utf8)], length: html.utf8.count, compression: 1,
            resources: [image(), image(marker: 66), image(marker: 67)])))
        XCTAssertEqual(String(decoding: content.html, as: UTF8.self), "<!doctype html><html><body><img src=\"00003\"><div style=\"page-break-before:always\"></div><img src=\"00001\"><div style=\"page-break-before:always\"></div><img src=\"00003\"></body></html>")
    }

    func testMobiRecoversMinorityFailuresWithoutImageFallback() throws {
        let damaged = Data([0x80])
        let first = Data("<p>first</p>".utf8), last = Data("<p>last</p>".utf8)
        for resources in [[], [image()]] {
            let input = book(text: [first, damaged, last], length: first.count + last.count + 8,
                             compression: 2, resources: resources)
            let content = try XCTUnwrap(LegacyText.mobiContent(input))
            XCTAssertEqual(String(decoding: content.html, as: UTF8.self), "<p>first</p><p>last</p>")
        }
        // Exactly half failing still retains the valid record, as upstream.
        let half = book(text: [damaged, first], length: first.count, compression: 2, resources: [])
        XCTAssertEqual(try XCTUnwrap(LegacyText.mobiContent(half)).html, first)
        XCTAssertThrowsError(try LegacyText.mobiContent(book(text: [damaged, damaged, first], length: first.count,
            compression: 2, resources: []))) { XCTAssertTrue($0.localizedDescription.contains("Truncated Palm back-reference")) }
        XCTAssertThrowsError(try LegacyText.palm(book(text: [Data("%PDF-1.7\n".utf8), damaged], length: 9,
            compression: 2, resources: []), replica: true)) {
            XCTAssertTrue($0.localizedDescription.contains("Truncated Palm back-reference"), "Binary Print Replica must not accept partial record recovery")
        }
    }

    func testMobiKeepsValidPrefixOfFailedRecordAndTreatsLengthAsHint() throws {
        let damaged = Data(Array("prefix".utf8) + [0x80])
        let content = try XCTUnwrap(LegacyText.mobiContent(book(text: [damaged, Data("suffix".utf8)], length: 30,
            compression: 2, resources: [])))
        XCTAssertEqual(String(decoding: content.html, as: UTF8.self), "prefixsuffix")
        for declared in [1, 17] {
            let html = Data("<p>readable</p>".utf8)
            XCTAssertEqual(try XCTUnwrap(LegacyText.mobiContent(book(text: [html], length: declared,
                compression: 1, resources: []))).html, html)
        }
        // The same document buffer supports a back-reference into a prior record.
        var header = Data(repeating: 0, count: 16)
        put(2, 0, 2, in: &header); put(6, 4, 4, in: &header); put(2, 8, 2, in: &header)
        XCTAssertEqual(try LegacyText.palm(pdb([header, Data("abc".utf8), Data([0x80, 24])], creator: "TEXtREAd")), Data("abcabc".utf8))
        let repacked = records(try LegacyText.mobi(book(length: 17)))
        XCTAssertEqual(integer(repacked[0], 4, 4), 2)
        XCTAssertEqual(repacked[1], Data("AB".utf8))
    }

    func testImageFallbackRequiresTwoImagesAndRetainsDecoderFailureBoundary() throws {
        let damaged = Data([0x80, 0]) // PalmDOC zero-distance back-reference.
        let two = book(text: [damaged], length: 16, compression: 2, resources: [image(), image(marker: 66)])
        let content = try XCTUnwrap(LegacyText.mobiContent(two))
        let html = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(html.contains("src=\"00001\"")); XCTAssertTrue(html.contains("src=\"00002\""))
        XCTAssertThrowsError(try LegacyText.mobiContent(book(text: [damaged], length: 16, compression: 2, resources: [image()]))) {
            XCTAssertTrue($0.localizedDescription.contains("Invalid Palm back-reference"))
        }
        let cyclic = cdic([(Data([255]), false), (Data("B".utf8), true)])
        XCTAssertNotNil(try LegacyText.mobiContent(book(text: [Data([255])], length: 1,
            tables: [huff(), cyclic], resources: [image(), image(marker: 66)])))
        XCTAssertThrowsError(try LegacyText.mobiContent(book(tables: [Data("invalid HUFF".utf8), cyclic], resources: [image(), image(marker: 66)])))
    }

    func testImagePageFallbackFiltersThumbnailsPreservesCoverAndStopsAtEOF() throws {
        var input = book(text: [Data()], length: 0, compression: 1,
            resources: [image(128), image(32), image(1024), image(900), Data([0xe9, 0x8e, 0x0d, 0x0a]), image(1024)], headerStorage: 268)
        let first = integer(input, 78, 4)
        put(0x40, first + 16 + 112, 4, in: &input)
        var exth = Data("EXTH".utf8); exth.append(Data(repeating: 0, count: 20))
        put(24, 4, 4, in: &exth); put(1, 8, 4, in: &exth)
        put(201, 12, 4, in: &exth); put(12, 16, 4, in: &exth); put(0, 20, 4, in: &exth)
        input.replaceSubrange((first + 244)..<(first + 268), with: exth)
        let content = try XCTUnwrap(LegacyText.mobiContent(input))
        let html = String(decoding: content.html, as: UTF8.self)
        XCTAssertEqual(html, "<!doctype html><html><body><img src=\"00001\"><div style=\"page-break-before:always\"></div><img src=\"00003\"><div style=\"page-break-before:always\"></div><img src=\"00004\"></body></html>")
        XCTAssertEqual(Set(content.resources.keys), ["00001", "00002", "00003", "00004"])
    }

    func testClassicMobiStaysOnNativePathAndRecindexPrecedesKindleSrc() throws {
        let classic = "<html><body>text<img recindex='1'></body></html>"
        XCTAssertNil(try LegacyText.mobiContent(book(text: [Data(classic.utf8)], length: classic.utf8.count, compression: 1, resources: [image()])))
        let ambiguous = "<html><body><img src='kindle:embed:01' recindex='3' alt='page'></body></html>"
        let content = try XCTUnwrap(LegacyText.mobiContent(book(text: [Data(ambiguous.utf8)], length: ambiguous.utf8.count, compression: 1,
            resources: [image(), Data("FDST metadata".utf8), image(marker: 66)])))
        let html = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(html.contains("src=\"00003\"")); XCTAssertFalse(html.contains("recindex="))
        XCTAssertEqual(Set(content.resources.keys), ["00001", "00003"])
        let overflow = "<img src='kindle:embed:" + String(repeating: "V", count: 128) + "'>"
        XCTAssertNotNil(try LegacyText.mobiContent(book(text: [Data(overflow.utf8)], length: overflow.utf8.count, compression: 1, resources: [image(), image(marker: 66)])))
    }

    func testMobiImageHTMLPreservesDeclaredCodepageAndMarkupBoundaries() throws {
        var html = Data("<html><body>caf".utf8); html.append(0xe9)
        html.append(Data("<img src='kindle:embed:01'><mbp:pagebreak/><img src='kindle:embed:02'></body></html>".utf8))
        var input = book(text: [html], length: html.count, compression: 1, resources: [image(), image(marker: 66)])
        put(1252, integer(input, 78, 4) + 28, 4, in: &input)
        let content = try XCTUnwrap(LegacyText.mobiContent(input))
        let output = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(output.contains("café")); XCTAssertTrue(output.contains("page-break-before:always"))
        XCTAssertFalse(output.contains("mbp:pagebreak"))
        let plain = try LegacyText.palmContent(palm(Data("<LINK data-TAG=x TEXT='literal'>".utf8)))
        XCTAssertTrue(String(decoding: plain.html, as: UTF8.self).contains("&lt;LINK data-TAG=x"))
    }

    func testMobiFilePositionsUseOriginalBytesAndExposeNestedGuideContents() throws {
        var html = "<html><head><guide><reference TYPE='toc' filepos='00000000'/></guide></head><body>" +
            "正文<p id='toc'><a filepos='11111111' href='https://ignored.example'>First &amp; <b>One</b></a>" +
            "<ul><li><a href='22222222'>Second</a></li><li><a href='#named'>Named</a></li></ul>" +
            "<mbp:pagebreak/><p>Chapter 一</p><p id='named'>Chapter Two</p></body></html>"
        let original = Data(html.utf8)
        let toc = try XCTUnwrap(original.range(of: Data("<p id='toc'>".utf8))).lowerBound
        let first = try XCTUnwrap(original.range(of: Data("<p>Chapter".utf8))).lowerBound
        let second = try XCTUnwrap(original.range(of: Data("<p id='named'>".utf8))).lowerBound
        for (marker, offset) in [("00000000", toc), ("11111111", first), ("22222222", second)] {
            html = html.replacingOccurrences(of: marker, with: String(format: "%08d", offset))
        }
        let content = try XCTUnwrap(LegacyText.mobiContent(book(text: [Data(html.utf8)], length: html.utf8.count, compression: 1, resources: [])))
        let result = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(result.contains("正文<a id=\"mobi-filepos-\(toc)\"></a><p id='toc'>"))
        XCTAssertTrue(result.contains("<a id=\"mobi-filepos-\(first)\"></a><p>Chapter 一</p>"))
        XCTAssertTrue(result.contains("href=\"#mobi-filepos-\(first)\""))
        XCTAssertFalse(result.contains("https://ignored.example"))
        XCTAssertEqual(content.outline.map(\.title), ["First & One", "Second", "Named"])
        XCTAssertEqual(content.outline.map(\.target), ["#mobi-filepos-\(first)", "#mobi-filepos-\(second)", "#named"])
        XCTAssertEqual(content.outline.map(\.level), [0, 1, 1])
        XCTAssertTrue(content.resources.isEmpty)
    }

    func testMobiFilePositionCodepageAndMalformedTargetDoNotDamageMarkup() throws {
        var raw = Data("<html><body>caf".utf8); raw.append(0xe9)
        let target = raw.count
        raw.append(Data("<p title='do > not split'><a filepos='\(target)' href='external'>Go</a>".utf8))
        raw.append(Data("<a filepos='\(target + 10)'>Inside tag</a><a filepos='99999999'>Invalid</a></p></body></html>".utf8))
        var input = book(text: [raw], length: raw.count, compression: 1, resources: [])
        put(1252, integer(input, 78, 4) + 28, 4, in: &input)
        let content = try XCTUnwrap(LegacyText.mobiContent(input))
        let html = String(decoding: content.html, as: UTF8.self)
        XCTAssertTrue(html.contains("café<a id=\"mobi-filepos-\(target)\"></a><p title='do > not split'>"))
        XCTAssertTrue(html.contains("<p title='do > not split'><a id=\"mobi-filepos-\(target + 10)\"></a>"))
        XCTAssertTrue(html.contains("filepos='99999999'"))
        XCTAssertFalse(html.contains("mobi-filepos-99999999"))
    }

    func testPrintReplicaDispatchAndVersionFourTrailerBoundary() throws {
        let pdf = Data("%PDF-1.7\nexample".utf8)
        var raw = Data("%MOP".utf8); raw.append(Data(repeating: 0, count: 16))
        put(1, 4, 4, in: &raw); put(1, 8, 4, in: &raw)
        put(20, 12, 4, in: &raw); put(pdf.count, 16, 4, in: &raw); raw.append(pdf)
        var input = book(text: [raw], length: raw.count, compression: 1, flags: 3, resources: [])
        let header = integer(input, 78, 4)
        put(8, header + 24, 4, in: &input); put(4, header + 16 + 88, 4, in: &input)
        XCTAssertEqual(try LegacyText.mobiPDF(input), pdf)
        XCTAssertEqual(try LegacyText.palm(input, replica: true), pdf)
        XCTAssertNil(try LegacyText.mobiPDF(book(text: [Data("text".utf8)], length: 4, compression: 1, resources: [])))
        put(1, header + 12, 2, in: &input)
        XCTAssertThrowsError(try LegacyText.mobiPDF(input))
    }
}
