import Foundation
import XCTest
@testable import SumraCore

final class ReaderTests:XCTestCase{
    func testArchiveReadsDeflateZip64WithoutExtraction()throws{
        let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".cbz")
        try Data(base64Encoded:"UEsDBC0AAAAIAAAAIQAjyjke//////////8GABQAMTAucG5nAQAQAAMAAAAAAAAABQAAAAAAAAArSc0DAFBLAwQtAAAACAAAACEAZorKEf//////////BQAUADIucG5nAQAQAAMAAAAAAAAABQAAAAAAAAArKc8HAFBLAwQtAAAACAAAACEA8YZsev//////////BQAUADEucG5nAQAQAAMAAAAAAAAABQAAAAAAAADLz0sFAFBLAwQtAAAACAAAACEAGi8NXv//////////DQAUAC4uL2VzY2FwZS50eHQBABAAFgAAAAAAAAAYAAAAAAAAAEvNKymq1FHISy1LLVJIrSgpSkwuSU0BAFBLAwQtAAAACAAAACEAveldiP//////////FAAUAF9fTUFDT1NYL2lnbm9yZWQucG5nAQAQAAYAAAAAAAAACAAAAAAAAADLyExJSc0DAFBLAQItAy0AAAAIAAAAIQAjyjkeBQAAAAMAAAAGAAAAAAAAAAAAAACAAQAAAAAxMC5wbmdQSwECLQMtAAAACAAAACEAZorKEQUAAAADAAAABQAAAAAAAAAAAAAAgAE9AAAAMi5wbmdQSwECLQMtAAAACAAAACEA8YZsegUAAAADAAAABQAAAAAAAAAAAAAAgAF5AAAAMS5wbmdQSwECLQMtAAAACAAAACEAGi8NXhgAAAAWAAAADQAAAAAAAAAAAAAAgAG1AAAALi4vZXNjYXBlLnR4dFBLAQItAy0AAAAIAAAAIQC96V2ICAAAAAYAAAAUAAAAAAAAAAAAAACAAQwBAABfX01BQ09TWC9pZ25vcmVkLnBuZ1BLBQYAAAAABQAFABcBAABaAQAAAAA=")!.write(to:u);defer{try? FileManager.default.removeItem(at:u)}
        let a=try Archive(u);XCTAssertEqual(a.images,["1.png","2.png","10.png"])
        XCTAssertEqual(try a.data("10.png",prefixBytes:2),Data("te".utf8))
        // ZIP keeps partial reads; advancing skips the remainder. Reading the
        // same entry in full still returns all bytes from its beginning.
        XCTAssertEqual(try a.data("2.png",prefixBytes:1),Data("t".utf8))
        XCTAssertEqual(try a.data("2.png"),Data("two".utf8))
        XCTAssertEqual(try a.data("1.png",prefixBytes:64),Data("one".utf8))
        XCTAssertEqual(try a.data("1.png",prefixBytes:0),Data())
        XCTAssertThrowsError(try a.data("1.png",prefixBytes:-1))
        XCTAssertEqual(try a.data("10.png"),Data("ten".utf8))
        XCTAssertEqual(try a.data("1.png"),Data("one".utf8))
        let moved = u.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: u, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        // Fully read entries retain their bytes, even after leaving the cursor.
        XCTAssertEqual(try a.data("10.png"), Data("ten".utf8))
        XCTAssertEqual(try a.data("2.png", prefixBytes: 1), Data("t".utf8))
        XCTAssertThrowsError(try a.data("missing",prefixBytes:1))
    }

    private func solidArchiveFixture() throws -> URL {
        // p7zip 17.05: three entries, LZMA2, one solid block, timestamps omitted.
        let data = try XCTUnwrap(Data(base64Encoded: "N3q8ryccAAS8BkcSyQAAAAAAAAAgAAAAAAAAACBjLinjAAoAaF0AIO/7v/6jsV7l+D+yqiZV+GhwQXAVD439HkwbikK3GfRpGHGuZiOKik0vow3Zf6bjjCMRU+BZGMV1iuJ3+LaUfwxqwN50SWTi6VxTsgTY90QMq1nkajQzYlbzMC/Ox51Lflhyr0rWUAAAAACBMweuD9ReV/1CFfazRXShe6fRa40QgVHMMcDkBQlBCTvSFNybkxR63xvGtNtYy6mwgZanaUY/JHVVHT/cYPuvU0ugzoam7AzFp27HnbadIi6FEM4PuAAXBnABCVkABwsBAAEjAwEBBV0AEAAADHYKAQoQtE4AAA=="))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".7z")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSolidArchiveReusesVisitedEntriesWithoutMovingTheCursor() throws {
        let url = try solidArchiveFixture(), archive = try Archive(url)
        let first = Data(repeating: 65, count: 131073), second = Data(repeating: 66, count: 65537)
        XCTAssertEqual(try archive.data("1.png", prefixBytes: 2), first.prefix(2))
        // The existing descriptor remains valid, but any re-open would fail.
        let moved = url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: url, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        XCTAssertEqual(try archive.data("1.png", prefixBytes: 8192), first.prefix(8192))
        XCTAssertEqual(try archive.data("1.png", prefixBytes: 1), first.prefix(1))
        XCTAssertEqual(try archive.data("1.png"), first)
        XCTAssertEqual(try archive.data("1.png"), first)
        XCTAssertEqual(try archive.data("2.png", prefixBytes: 3), second.prefix(3))
        XCTAssertEqual(try archive.data("2.png"), second)
        // Returning to an earlier entry uses its complete bytes for both forms.
        XCTAssertEqual(try archive.data("1.png", prefixBytes: 8192), first.prefix(8192))
        XCTAssertEqual(try archive.data("1.png"), first)
        XCTAssertEqual(try archive.data("2.png"), second)
        // Cache hits must leave the actual cursor after entry 2, so the unseen
        // third entry still reads through the original open descriptor.
        XCTAssertEqual(try archive.data("3.png"), Data(repeating: 67, count: 9))
        XCTAssertEqual(try archive.data("1.png"), first)
        XCTAssertEqual(try archive.data("2.png", prefixBytes: 3), second.prefix(3))
    }

    func testPrecancelledArchiveReadPreservesCompletedEntriesAndForwardCursor() async throws {
        let url = try solidArchiveFixture(), archive = try Archive(url)
        XCTAssertEqual(try archive.data("1.png", prefixBytes: 1), Data([65]))
        for name in ["1.png", "2.png"] {
            let read = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try archive.data(name)
            }
            do { _ = try await read.value; XCTFail("A cancelled request must not return a cached or new entry") }
            catch is CancellationError { }
        }
        let moved = url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: url, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        // Cancellation before reading must leave completed bytes and the open
        // solid cursor usable. Reopening the original pathname would fail.
        XCTAssertEqual(try archive.data("1.png"), Data(repeating: 65, count: 131073))
        XCTAssertEqual(try archive.data("2.png", prefixBytes: 1), Data([66]))
        XCTAssertEqual(try archive.data("2.png"), Data(repeating: 66, count: 65537))
        XCTAssertEqual(try archive.data("3.png"), Data(repeating: 67, count: 9))
    }
    func testLegacyTextAndPrintReplica()throws{
        var t=Data("!!8-Bit!!".utf8);for i in 0..<256{t.append(1);t.append(UInt8(i))};t.append(Data("Hello".utf8));XCTAssertEqual(try LegacyText.tcr(t),Data("Hello".utf8))
        XCTAssertEqual(try LegacyText.unpackPalm([97,98,99,128,24]),Array("abcabc".utf8))
        func palm(_ payload:Data)->Data{var b=Data(repeating:0,count:110);func put(_ n:Int,_ p:Int,_ z:Int){for i in 0..<z{b[p+i]=UInt8(truncatingIfNeeded:n>>(8*(z-i-1)))}};b.replaceSubrange(60..<68,with:Data("TEXtREAd".utf8));put(2,76,2);put(94,78,4);put(110,86,4);put(1,94,2);put(payload.count,98,4);put(1,102,2);b.append(payload);return b}
        XCTAssertEqual(try LegacyText.palm(palm(Data("read me".utf8))),Data("read me".utf8))
        var plucker=palm(Data("x".utf8));plucker.replaceSubrange(60..<68,with:Data("DataPlkr".utf8));XCTAssertEqual(try LegacyText.palm(plucker),Data("x".utf8))
        let pdf=Data("%PDF-1.4\nexact\n%%EOF".utf8)
        var mop=Data("%MOP".utf8);for n in [1,1,20,pdf.count]{var x=UInt32(n).bigEndian;withUnsafeBytes(of:&x){mop.append(contentsOf:$0)}};mop.append(pdf)
        XCTAssertEqual(try LegacyText.palm(palm(mop),replica:true),pdf)
    }
    func testDuplicateArchiveNamesDoNotCrash()throws{
        let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".cbz")
        try Data(base64Encoded:"UEsDBBQAAAAAAOJ9PV1X7nGSBQAAAAUAAAAFAAAAMS5wbmdmaXJzdFBLAwQUAAAAAADifT1daREftgYAAAAGAAAABQAAADEucG5nc2Vjb25kUEsBAhQDFAAAAAAA4n09XVfucZIFAAAABQAAAAUAAAAAAAAAAAAAAIABAAAAADEucG5nUEsBAhQDFAAAAAAA4n09XWkRH7YGAAAABgAAAAUAAAAAAAAAAAAAAIABKAAAADEucG5nUEsFBgAAAAACAAIAZgAAAFEAAAAAAA==")!.write(to:u);defer{try? FileManager.default.removeItem(at:u)}
        let a=try Archive(u);XCTAssertEqual(a.images,["1.png"]);XCTAssertEqual(try a.data("1.png"),Data("first".utf8))
    }
    func testArchiveReplacementDoesNotReadAnotherEntryThroughTheOriginalIndex() throws {
        let original = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAAAAIQDxhmx6AwAAAAMAAAAFAAAAMS5wbmdvbmVQSwMEFAAAAAAAAAAhAGaKyhEDAAAAAwAAAAUAAAAyLnBuZ3R3b1BLAwQUAAAAAAAAACEA9djFRgUAAAAFAAAABQAAADMucG5ndGhyZWVQSwECFAMUAAAAAAAAACEA8YZsegMAAAADAAAABQAAAAAAAAAAAAAApIEAAAAAMS5wbmdQSwECFAMUAAAAAAAAACEAZorKEQMAAAADAAAABQAAAAAAAAAAAAAApIEmAAAAMi5wbmdQSwECFAMUAAAAAAAAACEA9djFRgUAAAAFAAAABQAAAAAAAAAAAAAApIFMAAAAMy5wbmdQSwUGAAAAAAMAAwCZAAAAdAAAAAAA"))
        let replacement = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAAAAIQD12MVGBQAAAAUAAAAFAAAAMy5wbmd0aHJlZVBLAwQUAAAAAAAAACEAZorKEQMAAAADAAAABQAAADIucG5ndHdvUEsDBBQAAAAAAAAAIQDxhmx6AwAAAAMAAAAFAAAAMS5wbmdvbmVQSwECFAMUAAAAAAAAACEA9djFRgUAAAAFAAAABQAAAAAAAAAAAAAApIEAAAAAMy5wbmdQSwECFAMUAAAAAAAAACEAZorKEQMAAAADAAAABQAAAAAAAAAAAAAApIEoAAAAMi5wbmdQSwECFAMUAAAAAAAAACEA8YZsegMAAAADAAAABQAAAAAAAAAAAAAApIFOAAAAMS5wbmdQSwUGAAAAAAMAAwCZAAAAdAAAAAAA"))
        for reopen in [false, true] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            defer { try? FileManager.default.removeItem(at: url) }
            try original.write(to: url)
            let archive = try Archive(url)
            if reopen {
                // A partial ZIP read leaves the first entry uncached and makes
                // reading it later reopen the pathname from the beginning.
                XCTAssertEqual(try archive.data("3.png", prefixBytes: 1), Data("t".utf8))
            }
            try replacement.write(to: url, options: .atomic)
            // The replacement has the same names and bytes in a new order.
            // A stale index must never silently label 3.png bytes as 1.png.
            XCTAssertThrowsError(try archive.data("1.PNG")) { error in
                XCTAssertTrue(error is ReadError)
            }
            let refreshed = try Archive(url)
            XCTAssertEqual(try refreshed.data("1.PNG"), Data("one".utf8))
            XCTAssertEqual(try refreshed.data("3.png"), Data("three".utf8))
        }
    }

    func testArchiveNameLookupAndReadShareExactThenCaseInsensitiveResolution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        let moved = url.appendingPathExtension("moved")
        try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwNqTIqDgAAAA4AAAAWAAAATWV0YS1JbmYvQ29udGFpbmVyLnhtbGZpcnN0IHNwZWxsaW5nUEsDBBQAAAAAAAAAIVxOCLLqDgAAAA4AAAAWAAAAbWV0YS1pbmYvY29udGFpbmVyLnhtbGV4YWN0IHNwZWxsaW5nUEsBAhQDFAAAAAAAAAAhXA2pMioOAAAADgAAABYAAAAAAAAAAAAAAICBAAAAAE1ldGEtSW5mL0NvbnRhaW5lci54bWxQSwECFAMUAAAAAAAAACFcTgiy6g4AAAAOAAAAFgAAAAAAAAAAAAAAgIFCAAAAbWV0YS1pbmYvY29udGFpbmVyLnhtbFBLBQYAAAAAAgACAIgAAACEAAAAAAA=" )).write(to: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: moved) }
        let archive = try Archive(url)
        XCTAssertTrue(archive.contains("META-INF/container.xml"))
        XCTAssertEqual(try archive.data("META-INF/container.xml", prefixBytes: 5), Data("first".utf8))
        XCTAssertEqual(try archive.data("META-INF/container.xml"), Data("first spelling".utf8))
        XCTAssertEqual(try archive.data("meta-inf/container.xml"), Data("exact spelling".utf8))
        try FileManager.default.moveItem(at: url, to: moved)
        // Aliases reuse the resolved entry's cache; they do not reopen the file
        // or overwrite a distinct exact-case entry that appears later.
        XCTAssertEqual(try archive.data("META-INF/CONTAINER.XML"), Data("first spelling".utf8))
        XCTAssertEqual(try archive.data("Meta-Inf/Container.xml", prefixBytes: 5), Data("first".utf8))
        XCTAssertEqual(try archive.data("meta-inf/container.xml", prefixBytes: 5), Data("exact".utf8))
        XCTAssertFalse(archive.contains("missing.xml"))
        XCTAssertThrowsError(try archive.data("missing.xml"))
    }

    func testZipSubtypeRouting()throws{
        func fixture(_ base64:String,_ name:String)throws->(URL,Data){
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"-"+name)
            try Data(base64Encoded:base64)!.write(to:url)
            return (url,Data(try Data(contentsOf:url).prefix(2048)))
        }
        let epub=try fixture("UEsDBBQAAAAAAA5UPV2DFtyMAQAAAAEAAAAWAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbHhQSwECFAMUAAAAAAAOVD1dgxbcjAEAAAABAAAAFgAAAAAAAAAAAAAAgAEAAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbFBLBQYAAAAAAQABAEQAAAA1AAAAAAA=","book.zip");defer{try? FileManager.default.removeItem(at:epub.0)}
        XCTAssertEqual(try Format.resolve(epub.0,prefix:epub.1),.book)
        let xps=try fixture("UEsDBBQAAAAAAA5UPV2DFtyMAQAAAAEAAAALAAAAX3JlbHMvLnJlbHN4UEsBAhQDFAAAAAAADlQ9XYMW3IwBAAAAAQAAAAsAAAAAAAAAAAAAAIABAAAAAF9yZWxzLy5yZWxzUEsFBgAAAAABAAEAOQAAACoAAAAAAA==","doc.zip");defer{try? FileManager.default.removeItem(at:xps.0)}
        XCTAssertEqual(try Format.resolve(xps.0,prefix:xps.1),.mupdf)
        let fb2=try fixture("UEsDBBQAAAAAAA5UPV2TflVBDgAAAA4AAAAJAAAAc3RvcnkuZmIyPEZpY3Rpb25Cb29rLz5QSwECFAMUAAAAAAAOVD1dk35VQQ4AAAAOAAAACQAAAAAAAAAAAAAAgAEAAAAAc3RvcnkuZmIyUEsFBgAAAAABAAEANwAAADUAAAAAAA==","story.zip");defer{try? FileManager.default.removeItem(at:fb2.0)}
        XCTAssertEqual(try Format.resolve(fb2.0,prefix:fb2.1),.book)
    }
    func testFormatMatrix(){XCTAssertEqual(Format.detect("BOOK.FB2.ZIP"),.book);XCTAssertEqual(Format.detect("icon.ICO"),.image);XCTAssertEqual(Format.detect("comic.CB7"),.comic);for e in Format.extensions{XCTAssertNotEqual(Format.detect("x."+e),.unknown,e)}}

    func testSignatureSniffing(){
        XCTAssertEqual(Format.sniff(Data("leading bytes\n%PDF-1.7".utf8)), .pdf)
        XCTAssertEqual(Format.resolve("document.p7m", prefix: Data("leading bytes\n%PDF-1.7".utf8)), .pdf)
        XCTAssertEqual(Format.sniff(Data("%PDF-1.7".utf8)),.pdf);XCTAssertEqual(Format.detect("drawing.ai"),.pdf);XCTAssertEqual(Format.sniff(Data("%!PS-Adobe-3.0".utf8)),.postscript)
        var mobi=Data(repeating:0,count:68);mobi.replaceSubrange(60..<68,with:Data("BOOKMOBI".utf8));XCTAssertEqual(Format.sniff(mobi),.book)
        mobi.append(Data("%MOP\n%PDF-1.7\nembedded Print Replica".utf8))
        XCTAssertEqual(Format.sniff(mobi), .book)
        XCTAssertEqual(Format.resolve("print-replica.mobi", prefix: mobi), .book)
        let pdfComment = Data(("%PDF-1.4\n%" + String(repeating: " ", count: 50) + "BOOKMOBI\n").utf8)
        XCTAssertEqual(pdfComment.subdata(in: 60..<68), Data("BOOKMOBI".utf8))
        XCTAssertEqual(Format.sniff(pdfComment), .pdf)
        XCTAssertEqual(Format.sniff(Data("ITSF".utf8)),.chm)
        XCTAssertEqual(Format.sniff(Data("ITOLITLS".utf8)),.lit)
        XCTAssertNil(Format.sniff(Data([0x50,0x4b,0x03,0x04,0,0,0,0])))
        var replica=Data(repeating:0,count:68);replica.replaceSubrange(60..<68,with:Data("BOOKMOBI".utf8))
        XCTAssertEqual(Format.resolve("book.azw4",prefix:replica),.replica)
        XCTAssertEqual(Format.resolve("wrong.txt",prefix:Data("%PDF-1.7".utf8)),.pdf)
    }
    func testAmbiguousPDFMobiSignaturesValidateTheCompleteRecordTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobi")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = 512, minimum = 78 + count * 8
        var database = Data(repeating: 0, count: minimum + 16)
        func put(_ value: Int, at offset: Int, bytes: Int) {
            for index in 0..<bytes { database[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (bytes - index - 1))) }
        }
        database.replaceSubrange(0..<5, with: "%PDF-".utf8)
        database.replaceSubrange(60..<68, with: "BOOKMOBI".utf8)
        put(count, at: 76, bytes: 2)
        for record in 0..<count { put(minimum, at: 78 + record * 8, bytes: 4) }
        func inspect() throws -> Format {
            try database.write(to: url)
            // A slice also exercises nonzero Data indices at the sniff boundary.
            let padded = Data([0]) + database.prefix(2048)
            return try Format.inspect(url, prefix: padded.dropFirst()).format
        }
        XCTAssertEqual(try inspect(), .book, "Record tables larger than the sniff prefix remain valid")
        put(minimum - 1, at: 78, bytes: 4)
        XCTAssertEqual(try inspect(), .pdf, "A record cannot point into the table")
        put(minimum, at: 78, bytes: 4)
        put(database.count + 1, at: 78 + (count - 1) * 8, bytes: 4)
        XCTAssertEqual(try inspect(), .pdf, "A record cannot extend past the file")
        put(minimum, at: 78 + (count - 1) * 8, bytes: 4)
        database.removeSubrange((minimum - 1)..<database.count)
        XCTAssertEqual(try inspect(), .pdf, "A truncated table cannot establish a container")
        put(65535, at: 76, bytes: 2)
        XCTAssertEqual(try inspect(), .pdf, "The maximum record count cannot cause an unbounded read")
    }

    func testChapterDetection(){
        let zh="序章\n\n开始\n\n第一章 初见\n\n正文。\n\n第二章 重逢\n\n正文。\n\n番外一\n"
        XCTAssertEqual(ChapterDetector.detect(zh).map(\.title),["序章","第一章 初见","第二章 重逢","番外一"])
        let en="Prologue\n\nText.\n\nChapter 1 Arrival\n\nText.\n\nChapter 2 Winter\n"
        XCTAssertEqual(ChapterDetector.detect(en).map(\.title),["Prologue","Chapter 1 Arrival","Chapter 2 Winter"])
        let grouped="卷一\n\n第一章卷宗疑云\n\n正文。\n\n第二章 重逢\n"
        let g=ChapterDetector.detect(grouped);XCTAssertEqual(g.map(\.depth),[0,1,1])
        let ja="プロローグ\n\n本文。\n\n第一話 はじまり\n\n本文。\n\n第二話 再会\n";XCTAssertEqual(ChapterDetector.detect(ja).map(\.title),["プロローグ","第一話 はじまり","第二話 再会"])
        let compact="第一章科学边界\n\n正文。\n\n第二章黑暗森林\n\n正文。\n\n第3節危机\n"
        XCTAssertEqual(ChapterDetector.detect(compact).map(\.title),["第一章科学边界","第二章黑暗森林","第3節危机"])
        let jaCompact="第一話始まり\n\n本文。\n\n第二話再会\n"
        XCTAssertEqual(ChapterDetector.detect(jaCompact).map(\.title),["第一話始まり","第二話再会"])
        let prose="他终于读完了第一章，然后睡了。\nThis chapter 1 sentence is prose.\n"
        XCTAssertTrue(ChapterDetector.detect(prose).isEmpty)
    }
}
