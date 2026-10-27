import Foundation
import CoreFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Palm/TCR layout and AZW4 Print Replica extraction follow SumatraPDF.
/// MobiDoc.cpp/PalmDbReader.cpp are Simplified BSD, Copyright 2022 the
/// SumatraPDF project authors; Teal HTML conversion from EbookDoc.cpp and
/// image placement from EbookFormatter.cpp are GPLv3. Translated from
/// 012d997f6a3a5c5c97b878e1a340db3bffde8c0e.
/// See THIRD_PARTY.md for pinned source revisions and notices.
public enum LegacyText{
    private static let kindleEmbeds = try! NSRegularExpression(pattern: "kindle:embed:([0-9a-v]+)", options: .caseInsensitive)
    private static let markupAttributes = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9:_-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)

    public static func tcr(_ data:Data)throws->Data{
        let b=[UInt8](data);guard b.starts(with:Array("!!8-Bit!!".utf8))else{throw ReadError("Invalid TCR header")}
        var p=9,dict:[ArraySlice<UInt8>]=[]
        for _ in 0..<256{guard p<b.count else{throw ReadError("Truncated TCR dictionary")};let n=Int(b[p]);p+=1;guard n<=b.count-p else{throw ReadError("Truncated TCR entry")};dict.append(b[p..<p+n]);p+=n}
        var out=Data();for i in b[p...]{out.append(contentsOf: dict[Int(i)])};return out
    }

    public static func palmPDF(_ data: Data) throws -> Data {
        try palmPDF(PalmDatabase(data))
    }

    private static func palmPDF(_ database: PalmDatabase) throws -> Data {
        let header = database.record(0)
        if try be(header, 12, 2) != 0 { throw ReadError("Encrypted Kindle document") }
        var flags = 0
        if database.creator == "BOOKMOBI" {
            let info = try MobiHeader(header)
            // Print Replica version 4 can have a long MOBI header without
            // valid trailer flags (MobiDoc.cpp PrintReplicaTrailerInfo).
            if info.length >= 228, try be(header, 16 + 88, 4) >= 5 { flags = info.flags }
        }
        return try printReplica(database.text(flags: flags, recover: false))
    }

    /// EngineCreate also recognizes Print Replica inside .mobi/.prc/.azw.
    /// Inspect the actual type/record marker before attempting PDF extraction.
    public static func mobiPDF(_ data: Data) throws -> Data? {
        let database = try PalmDatabase(data)
        guard database.creator == "BOOKMOBI", database.count > 1 else { return nil }
        let header = database.record(0), info = try MobiHeader(header)
        let type = info.length >= 116 ? try be(header, 24, 4) : 0
        guard type == 8 || database.record(1).starts(with: Data("%MOP".utf8)) else { return nil }
        return try palmPDF(database)
    }

    /// Inspect only the PDB header and record table for ambiguous PDF/MOBI
    /// signatures. A 16-bit record count bounds the read to about 512 KiB.
    static func isMobiContainer(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let length = Int(exactly: try handle.seekToEnd()) else { return false }
        try handle.seek(toOffset: 0)
        var header = try handle.read(upToCount: 78) ?? Data()
        guard header.count == 78, header[60..<68].elementsEqual("BOOKMOBI".utf8) else { return false }
        let minimum = 78 + (try be(header, 76, 2)) * 8
        guard minimum <= length else { return false }
        if minimum > 78 { header.append(try handle.read(upToCount: minimum - 78) ?? Data()) }
        return (try? PalmDatabase.recordOffsets(header, length: length)) != nil
    }

    public struct MobiContent: Sendable {
        /// First authored HTML document, followed by the remaining KF8 spine.
        public let html: Data
        public let additionalParts: [Data]
        public let resources: [String: Data]
        public let outline: [(title: String, target: String, level: Int)]
    }

    /// MobiDoc's real image record indexes, KindleEmbedToRecIndex and
    /// MaybeSynthesizeImagePages. MuPDF owns HTML and EPUB spine rendering.
    /// Reuse decoded HTML for ordinary books as well as HUFF/CDIC and trailer
    /// variants. Returning it avoids decoding the same Palm records in MuPDF.
    /// Containers without the supported MOBI header stay on the native path.
    public static func mobiContent(_ data: Data) throws -> MobiContent? {
        let database = try PalmDatabase(data)
        guard database.creator == "BOOKMOBI" else { return nil }
        let header = database.record(0), info = try MobiHeader(header)
        guard info.length >= 116 else { return nil }
        let first = try be(header, 16 + 92, 4)
        // Binary Print Replica is never interpreted as HTML.
        if try be(header, 24, 4) == 8 { return nil }
        if database.count > 1, database.record(1).prefix(4) == Data("%MOP".utf8) { return nil }
        var images = [Int: Data]()
        let metadata = ["FLIS", "FCIS", "FDST", "DATP", "SRCS", "VIDE", "RESC"].map { Data($0.utf8) }
        for record in (first > 0 && first < database.count ? first : database.count)..<database.count {
            let bytes = database.record(record)
            if bytes.count < 4 || bytes == Data([0xe9, 0x8e, 0x0d, 0x0a]) { break }
            if metadata.contains(Data(bytes.prefix(4))) { continue }
            if Format.sniff(bytes.prefix(256)) == .image || Format.imageEngine("", prefix: bytes.prefix(32)) != nil {
                images[record - first + 1] = bytes
            }
        }
        var raw = try database.text(flags: info.flags, imageFallback: images.count >= 2)
        for index in raw.indices where raw[index] == 0 { raw[index] = 32 }
        let codepage = try be(header, 28, 4)
        let encoding: String.Encoding
        if codepage == 65001 { encoding = .utf8 }
        else {
            let cfEncoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codepage == 0 ? 1252 : codepage))
            guard cfEncoding != kCFStringEncodingInvalidId else { throw ReadError("Unsupported MOBI text codepage \(codepage)") }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        }
        var flowResources = [String: Data]()
        let navigation: (parts: [Data], outline: [(title: String, target: String, level: Int)])
        let isKF8 = info.length >= 248 ? try be(header, 36, 4) == 8 : false
        if isKF8 {
            let content = try kindleContent(raw, header: header, database: database)
            navigation = (content.parts, content.outline); flowResources = content.resources
        } else {
            let content = try mobiNavigation(raw, encoding: encoding)
            navigation = ([content.data], content.outline)
        }
        var documents = try navigation.parts.map { bytes -> String in
            guard let text = encoding == .utf8 ? String(decoding: bytes, as: UTF8.self) : String(data: bytes, encoding: encoding) else {
                throw ReadError("Invalid MOBI text for codepage \(codepage)")
            }
            return text
        }
        let html = documents.joined()
        let cover = try coverIndex(header, info: info)
        let string = html as NSString
        let indexes = kindleEmbeds.matches(in: html, range: NSRange(location: 0, length: string.length)).compactMap {
            Int(string.substring(with: $0.range(at: 1)), radix: 32).flatMap { $0 > 0 ? $0 : nil }
        }
        var pages = [Int]()
        // A reconstructed KF8 spine already owns its content order, including
        // images referenced by SVG/CSS flows outside the HTML documents.
        if !isKF8, images.count >= 2, html.range(of: "recindex", options: .caseInsensitive) == nil {
            let fixed = html.range(of: "name=\"viewport\"", options: .caseInsensitive) != nil || html.range(of: "name='viewport'", options: .caseInsensitive) != nil
            if indexes.count >= 2, fixed { pages = indexes }
            else if indexes.count < 2 {
                let threshold = (images.values.map(\.count).max() ?? 0) / 8
                let retained = images.keys.sorted().filter { $0 != cover && images[$0]!.count >= threshold }
                if retained.count >= 2 { pages = retained }
            }
        }
        func page(_ index: Int) -> String { "<div data-sumra-image-page=\"yes\"><img src=\"\(imageName(index))\"></div>" }
        let pageBreak = "<div style=\"page-break-before:always\"></div>"
        if !pages.isEmpty {
            if images[cover] != nil { pages.insert(cover, at: 0) }
            documents = ["<!doctype html><html><body>" + pages.map(page).joined(separator: pageBreak) + "</body></html>"]
        } else {
            for index in documents.indices {
                var html = try rewriteMobiImages(documents[index])
                let breaks = try NSRegularExpression(pattern: #"<mbp:pagebreak\b[^>]*>"#, options: .caseInsensitive)
                html = breaks.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html), withTemplate: pageBreak)
                if index == 0, images[cover] != nil {
                    let body = try NSRegularExpression(pattern: #"<body\b[^>]*>"#, options: .caseInsensitive)
                    if let match = body.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)), let range = Range(match.range, in: html) {
                        html.insert(contentsOf: page(cover) + pageBreak, at: range.upperBound)
                    } else { html = page(cover) + pageBreak + html }
                }
                documents[index] = html
            }
        }
        var resources = Dictionary(uniqueKeysWithValues: images.map { (imageName($0.key), $0.value) })
        resources.merge(flowResources) { _, flow in flow }
        return MobiContent(html: Data(documents[0].utf8), additionalParts: documents.dropFirst().map { Data($0.utf8) }, resources: resources, outline: pages.isEmpty ? navigation.outline : [])
    }

    private static func imageName(_ index: Int) -> String { String(format: "%05d", index) }

    // KF8 stores XHTML skeletons, insertion fragments and CSS/SVG flows in the
    // same decoded stream. Reconstruct that stream before translating links;
    // fragment IDs are indexes in the division table, not byte offsets.
    // Format reference: calibre's GPLv3 mobi8.py/index.py (Kovid Goyal, 2012).
    private static func kindleContent(_ raw: Data, header: Data, database: PalmDatabase) throws
        -> (parts: [Data], resources: [String: Data], outline: [(title: String, target: String, level: Int)]) {
        func record(_ index: Int, signature: String) throws -> Data {
            guard index > 0, index < database.count else { throw ReadError("Invalid KF8 \(signature) record") }
            let bytes = database.record(index)
            guard bytes.starts(with: signature.utf8) else { throw ReadError("Invalid KF8 \(signature) record") }
            return bytes
        }
        func slice(_ start: Int, _ length: Int, in bytes: Data) throws -> Data {
            guard start <= bytes.count, length <= bytes.count - start else { throw ReadError("Invalid KF8 content range") }
            return bytes.subdata(in: start..<start + length)
        }
        func variable(_ bytes: Data, _ cursor: inout Int) throws -> Int {
            var value = 0
            while cursor < bytes.count {
                let byte = bytes[cursor]; cursor += 1
                guard value <= Int.max >> 7 else { throw ReadError("KF8 index integer overflow") }
                value = (value << 7) | Int(byte & 0x7f)
                if byte & 0x80 != 0 { return value }
            }
            throw ReadError("Truncated KF8 index integer")
        }
        func index(_ number: Int) throws -> [(name: String, tags: [Int: [Int]])] {
            let top = try record(number, signature: "INDX")
            let tagStart = try be(top, 4, 4), records = try be(top, 24, 4)
            guard records < database.count - number else { throw ReadError("Invalid KF8 index record count") }
            let tagx = try slice(tagStart, top.count - min(tagStart, top.count), in: top)
            guard tagx.starts(with: "TAGX".utf8) else { throw ReadError("Missing KF8 TAGX") }
            let tagEnd = try be(tagx, 4, 4), controls = try be(tagx, 8, 4)
            guard tagEnd >= 12, tagEnd <= tagx.count, (tagEnd - 12) % 4 == 0 else { throw ReadError("Invalid KF8 TAGX size") }
            var result = [(String, [Int: [Int]])]()
            for r in 0..<records {
                let bytes = try record(number + r + 1, signature: "INDX")
                let idxt = try be(bytes, 20, 4), count = try be(bytes, 24, 4)
                guard try slice(idxt, 4, in: bytes) == Data("IDXT".utf8) else { throw ReadError("Missing KF8 IDXT") }
                guard count <= (bytes.count - idxt - 4) / 2 else { throw ReadError("Truncated KF8 IDXT") }
                var offsets = try (0..<count).map { try be(bytes, idxt + 4 + $0 * 2, 2) }
                offsets.append(idxt)
                for entry in 0..<count {
                    let start = offsets[entry], end = offsets[entry + 1]
                    guard start < end, end <= idxt else { throw ReadError("Invalid KF8 index entry") }
                    let item = bytes.subdata(in: start..<end), nameLength = Int(item[0])
                    let name = String(decoding: try slice(1, nameLength, in: item), as: UTF8.self)
                    let controlStart = 1 + nameLength
                    _ = try slice(controlStart, controls, in: item)
                    var cursor = controlStart + controls, control = controlStart
                    var pending = [(tag: Int, count: Int?, bytes: Int?, values: Int)]()
                    for t in stride(from: 12, to: tagEnd, by: 4) {
                        let tag = Int(tagx[t]), values = Int(tagx[t + 1]), mask = tagx[t + 2]
                        if tagx[t + 3] == 1 { control += 1; continue }
                        guard control < controlStart + controls else { throw ReadError("Invalid KF8 control byte") }
                        let value = item[control] & mask
                        if value == 0 { continue }
                        if value == mask, mask.nonzeroBitCount > 1 {
                            pending.append((tag, nil, try variable(item, &cursor), values))
                        } else {
                            pending.append((tag, value == mask ? 1 : Int(value >> mask.trailingZeroBitCount), nil, values))
                        }
                    }
                    var tags = [Int: [Int]]()
                    for p in pending {
                        var values = [Int]()
                        if let count = p.count {
                            for _ in 0..<count * p.values { values.append(try variable(item, &cursor)) }
                        } else if let length = p.bytes {
                            guard length <= item.count - cursor else { throw ReadError("Truncated KF8 index values") }
                            let end = cursor + length
                            while cursor < end { values.append(try variable(item, &cursor)) }
                            guard cursor == end else { throw ReadError("Invalid KF8 index value size") }
                        }
                        tags[p.tag] = values
                    }
                    result.append((name, tags))
                }
            }
            return result
        }
        let fdstIndex = try be(header, 192, 4)
        var flows = [raw]
        if fdstIndex != 0xffff_ffff {
            let fdst = try record(fdstIndex, signature: "FDST")
            let start = try be(fdst, 4, 4), count = try be(fdst, 8, 4)
            guard count > 0, start <= fdst.count, count <= (fdst.count - start) / 8 else { throw ReadError("Invalid KF8 flow table") }
            flows = try (0..<count).map {
                let from = try be(fdst, start + $0 * 8, 4), to = try be(fdst, start + $0 * 8 + 4, 4)
                guard from <= to else { throw ReadError("Invalid KF8 flow range") }
                return try slice(from, to - from, in: raw)
            }
        }
        let skeletons = try index(be(header, 252, 4)), fragments = try index(be(header, 248, 4))
        guard !skeletons.isEmpty else { throw ReadError("KF8 document has no content parts") }
        var data = Data(), positions = [Int: Int](), partStarts = [Int](), fragment = 0
        for skeleton in skeletons {
            guard let counts = skeleton.tags[1], let range = skeleton.tags[6], !counts.isEmpty, range.count >= 2 else { throw ReadError("Invalid KF8 skeleton") }
            let start = range[0], length = range[1]
            var part = try slice(start, length, in: flows[0]), cursor = start + length
            for _ in 0..<counts[0] {
                guard fragment < fragments.count, let insertion = Int(fragments[fragment].name),
                      let range = fragments[fragment].tags[6], range.count >= 2,
                      insertion >= start, insertion - start <= part.count else { throw ReadError("Invalid KF8 fragment") }
                let offset = insertion - start, bytes = try slice(cursor, range[1], in: flows[0])
                part.insert(contentsOf: bytes, at: offset)
                positions[fragment] = insertion
                cursor += range[1]; fragment += 1
            }
            // Skeleton positions include their following fragment bytes. Keeping
            // their original lengths preserves the position vocabulary of KF8.
            guard data.count == start else { throw ReadError("Invalid KF8 skeleton order") }
            partStarts.append(data.count)
            data.append(part)
        }
        guard fragment == fragments.count else { throw ReadError("Unreferenced KF8 fragments") }
        var resources = [String: Data]()
        let flowNames = flows.enumerated().map { number, bytes in
            "kf8-flow-\(number)" + (String(decoding: bytes, as: UTF8.self).range(of: "<svg", options: .caseInsensitive) != nil ? ".svg" : ".css")
        }
        let resourceLinks = try NSRegularExpression(pattern: #"kindle:(flow|embed):([0-9a-v]+)(?:\?mime=[^\s\"'<>)]*)?"#, options: .caseInsensitive)
        func expand(_ bytes: Data, embeds: Bool = false) throws -> Data {
            var text = String(decoding: bytes, as: UTF8.self)
            for match in resourceLinks.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed() {
                let source = text as NSString, kind = source.substring(with: match.range(at: 1)).lowercased()
                if kind == "embed", !embeds { continue }
                guard let number = Int(source.substring(with: match.range(at: 2)), radix: 32), number > 0 else { throw ReadError("Invalid KF8 resource reference") }
                let name: String
                if kind == "embed" { name = imageName(number) }
                else {
                    guard number < flowNames.count else { throw ReadError("Invalid KF8 flow reference") }
                    name = flowNames[number]
                }
                text.replaceSubrange(Range(match.range, in: text)!, with: name)
            }
            return Data(text.utf8)
        }
        // Link positions refer to pre-expansion bytes; navigation inserts anchors
        // first, then resource URI expansion may freely change string lengths.
        let navigation = try mobiNavigation(data, encoding: .utf8, kindlePositions: positions, partStarts: partStarts)
        let boundaries = navigation.partStarts + [navigation.data.count]
        var parts = try zip(boundaries, boundaries.dropFirst()).map { try expand(navigation.data.subdata(in: $0..<$1)) }
        var outline = navigation.outline
        if parts.count > 1 {
            // Keep each authored head/body and its stylesheet context in the
            // existing EPUB spine renderer. Only source-offset links change.
            let anchors = try NSRegularExpression(pattern: #"<a id="(mobi-filepos-[0-9]+)"></a>"#)
            var targets = [String: String]()
            for (index, part) in parts.enumerated() {
                let text = String(decoding: part, as: UTF8.self), source = text as NSString
                for match in anchors.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                    let anchor = source.substring(with: match.range(at: 1))
                    targets["#" + anchor] = MobiContent.partName(index) + "#" + anchor
                }
            }
            let links = try NSRegularExpression(pattern: #"href="(#mobi-filepos-[0-9]+)""#)
            parts = parts.map { part in
                var text = String(decoding: part, as: UTF8.self)
                for match in links.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed() {
                    let value = (text as NSString).substring(with: match.range(at: 1))
                    if let target = targets[value] { text.replaceSubrange(Range(match.range(at: 1), in: text)!, with: target) }
                }
                return Data(text.utf8)
            }
            outline = outline.map { ($0.title, targets[$0.target] ?? $0.target, $0.level) }
        }
        for number in 1..<flows.count { resources[flowNames[number]] = try expand(flows[number], embeds: true) }
        return (parts, resources, outline)
    }

    /// MobiDoc::FindMobiTocFilepos/ParseToc and EngineMobi::GetNamedDest use
    /// offsets in the original decompressed bytes, before codepage conversion.
    /// Translate only those offsets to HTML anchors; MuPDF still owns layout.
    private static func mobiNavigation(_ raw: Data, encoding: String.Encoding, kindlePositions: [Int: Int] = [:], partStarts: [Int] = []) throws
        -> (data: Data, outline: [(title: String, target: String, level: Int)], partStarts: [Int]) {
        let byteText = String(data: raw, encoding: .isoLatin1)!, source = byteText as NSString
        let tags = try NSRegularExpression(pattern: #"<!--[\s\S]*?-->|<![^>]*>|</?([A-Za-z][A-Za-z0-9:_-]*)\b(?:[^\"'>]|\"[^\"]*\"|'[^']*')*>"#)
        let matches = tags.matches(in: byteText, range: NSRange(location: 0, length: source.length))
        var targets = Set<Int>(), toc: Int?
        var edits = [(range: NSRange, data: Data)]()
        // MOBI 6 often puts many visible lines in one paragraph with <br>.
        // Keep short source lines for the chapter detector and retain their
        // original byte offsets for native destinations.
        var sourceLines = [(text: String, offset: Int)]()
        var line: (anchor: Int, textStart: Int, plain: Bool)?
        func recordLine(until end: Int) {
            guard let line else { return }
            let text: String
            if line.plain, line.textStart <= end {
                text = String(data: raw.subdata(in: line.textStart..<end), encoding: encoding)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } else { text = "body" }
            sourceLines.append((text.count <= 80 && text.rangeOfCharacter(from: .newlines) == nil ? text : "body", line.anchor))
        }
        func position(_ value: String?) -> Int? {
            guard let value, !value.isEmpty else { return nil }
            let offset: Int
            if value.lowercased().hasPrefix("kindle:pos:fid:") {
                let fields = value.split(separator: ":")
                guard fields.count == 6, fields[4].lowercased() == "off",
                      let fid = Int(fields[3], radix: 32), let start = kindlePositions[fid],
                      let displacement = Int(fields[5], radix: 32), displacement >= 0, displacement <= raw.count - start else { return nil }
                offset = start + displacement
            } else {
                guard value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value) else { return nil }
                offset = number
            }
            return offset <= raw.count ? offset : nil
        }
        func attributes(_ tag: String) -> [String: String] {
            let string = tag as NSString
            var values = [String: String]()
            for match in markupAttributes.matches(in: tag, range: NSRange(location: 0, length: string.length)) {
                let key = string.substring(with: match.range(at: 1)).lowercased()
                let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
                if values[key] == nil { values[key] = string.substring(with: range) }
            }
            return values
        }
        for match in matches where match.range(at: 1).location != NSNotFound {
            let original = source.substring(with: match.range)
            let closing = original.hasPrefix("</")
            let name = source.substring(with: match.range(at: 1)).lowercased()
            if name == "p" {
                recordLine(until: match.range.location)
                line = closing ? nil : (match.range.location, NSMaxRange(match.range), true)
            } else if name == "br" {
                if !closing || line?.textStart != match.range.location { recordLine(until: match.range.location) }
                if line != nil { line = (NSMaxRange(match.range), NSMaxRange(match.range), true) }
            } else if var current = line {
                // Inline markup makes this line body context, not a title.
                current.plain = false
                line = current
            }
            guard !closing else { continue }
            let values = attributes(original)
            if name == "reference", toc == nil, values["type"]?.lowercased() == "toc" { toc = position(values["filepos"]) }
            guard name == "a", let offset = position(values["filepos"] ?? values["href"]) else { continue }
            targets.insert(offset)
            let changed = NSMutableString(string: original), string = original as NSString
            for attribute in markupAttributes.matches(in: original, range: NSRange(location: 0, length: string.length)).reversed() {
                let key = string.substring(with: attribute.range(at: 1)).lowercased()
                if key == "filepos" || key == "href" { changed.replaceCharacters(in: attribute.range, with: "") }
            }
            changed.insert(" href=\"#mobi-filepos-\(offset)\"", at: changed.length - (original.hasSuffix("/>") ? 2 : 1))
            edits.append((match.range, (changed as String).data(using: .isoLatin1)!))
        }
        if let toc { targets.insert(toc) }
        var matchIndex = 0
        for target in targets.sorted() {
            var offset = target
            while matchIndex < matches.count, NSMaxRange(matches[matchIndex].range) <= offset { matchIndex += 1 }
            // A damaged offset into markup must not split an attribute or a
            // multibyte character and corrupt the rest of the publication.
            if matchIndex < matches.count, matches[matchIndex].range.location < offset { offset = NSMaxRange(matches[matchIndex].range) }
            if encoding == .utf8 { while offset < raw.count, raw[offset] & 0xc0 == 0x80 { offset += 1 } }
            edits.append((NSRange(location: offset, length: 0), Data("<a id=\"mobi-filepos-\(target)\"></a>".utf8)))
        }
        var outline = [(title: String, target: String, level: Int)]()
        if let toc, toc < raw.count {
            let rest = raw.subdata(in: toc..<raw.count)
            if var html = encoding == .utf8 ? String(decoding: rest, as: UTF8.self) : String(data: rest, encoding: encoding) {
                if let pageBreak = html.range(of: "<mbp:pagebreak", options: .caseInsensitive) { html = String(html[..<pageBreak.lowerBound]) }
                do {
                    // Use the system tolerant HTML parser for the small TOC
                    // region. No HTML parser or second book model is added.
                    let document = try XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
                    for case let link as XMLElement in try document.nodes(forXPath: "//*[local-name()='a']") {
                        guard let value = link.attribute(forName: "filepos")?.stringValue ?? link.attribute(forName: "href")?.stringValue,
                              let text = link.stringValue, !text.isEmpty else { continue }
                        let target = position(value).map { "#mobi-filepos-\($0)" } ?? value
                        var level = 0, parent = link.parent
                        while let node = parent {
                            if ["blockquote", "ul", "ol"].contains(node.name?.lowercased() ?? "") { level += 1 }
                            parent = node.parent
                        }
                        outline.append((text, target, level))
                    }
                } catch { NSLog("MOBI table of contents could not be parsed: %@", error.localizedDescription) }
            }
        }
        if outline.isEmpty, !sourceLines.isEmpty {
            let lines = sourceLines.map { $0.text }.joined(separator: "\n")
            for chapter in ChapterDetector.detect(lines) {
                let offset = sourceLines[chapter.line].offset
                outline.append((chapter.title, "#mobi-filepos-\(offset)", chapter.depth))
                if !targets.contains(offset) {
                    edits.append((NSRange(location: offset, length: 0), Data("<a id=\"mobi-filepos-\(offset)\"></a>".utf8)))
                    targets.insert(offset)
                }
            }
        }
        guard !edits.isEmpty else { return (raw, outline, partStarts) }
        edits.sort { $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location }
        var data = Data(), cursor = 0
        for edit in edits {
            data.append(contentsOf: raw[cursor..<edit.range.location])
            data.append(contentsOf: edit.data)
            cursor = NSMaxRange(edit.range)
        }
        data.append(contentsOf: raw[cursor...])
        let boundaries = partStarts.map { start in
            start + edits.filter { $0.range.location < start }.reduce(0) { $0 + $1.data.count - $1.range.length }
        }
        return (data, outline, boundaries)
    }

    private static func coverIndex(_ header: Data, info: MobiHeader) throws -> Int {
        guard info.length >= 116, try be(header, 16 + 112, 4) & 0x40 != 0 else { return 0 }
        let start = 16 + info.length
        guard start <= header.count - 12, header.subdata(in: start..<start + 4) == Data("EXTH".utf8) else { return 0 }
        let length = try be(header, start + 4, 4), count = try be(header, start + 8, 4)
        guard length >= 12, length <= header.count - start else { NSLog("Truncated MOBI EXTH header; ignoring cover metadata"); return 0 }
        var position = start + 12
        for _ in 0..<count {
            guard position <= start + length - 8 else { NSLog("Truncated MOBI EXTH entry; ignoring cover metadata"); return 0 }
            let type = try be(header, position, 4), size = try be(header, position + 4, 4)
            guard size >= 8, size <= start + length - position else { NSLog("Invalid MOBI EXTH entry length; ignoring cover metadata"); return 0 }
            if type == 201, size == 12 { return try be(header, position + 8, 4) + 1 }
            position += size
        }
        return 0
    }

    private static func rewriteMobiImages(_ html: String) throws -> String {
        let tags = try NSRegularExpression(pattern: #"<img\b(?:[^\"'>]|\"[^\"]*\"|'[^']*')*>"#, options: .caseInsensitive)
        let source = html as NSString, result = NSMutableString(string: html)
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            let original = source.substring(with: tag.range), string = original as NSString
            let matches = markupAttributes.matches(in: original, range: NSRange(location: 0, length: string.length))
            var recordIndex: Int?, embeddedIndex: Int?
            var seen = Set<String>()
            for attribute in matches {
                let key = string.substring(with: attribute.range(at: 1)).lowercased()
                guard key == "recindex" || key == "src", seen.insert(key).inserted else { continue }
                let range = (2...4).map { attribute.range(at: $0) }.first { $0.location != NSNotFound }!
                let value = CFXMLCreateStringByUnescapingEntities(nil, string.substring(with: range) as CFString, nil) as String
                if key == "recindex" { recordIndex = Int(value) }
                else if let match = kindleEmbeds.firstMatch(in: value, options: .anchored, range: NSRange(location: 0, length: value.utf16.count)) {
                    embeddedIndex = Int((value as NSString).substring(with: match.range(at: 1)), radix: 32)
                }
            }
            guard let index = recordIndex ?? embeddedIndex, index > 0 else { continue }
            let changed = NSMutableString(string: original)
            // Remove recindex too: MuPDF's MOBI adapter otherwise overwrites
            // src with the original unpadded decimal attribute value.
            for attribute in matches.reversed() {
                let key = string.substring(with: attribute.range(at: 1)).lowercased()
                if key == "recindex" || key == "src" { changed.replaceCharacters(in: attribute.range, with: "") }
            }
            let end = original.hasSuffix("/>") ? changed.length - 2 : changed.length - 1
            changed.insert(" src=\"\(imageName(index))\"", at: end)
            result.replaceCharacters(in: tag.range, with: changed as String)
        }
        return result as String
    }

    private struct MobiHeader {
        let length: Int, compression: Int, flags: Int
        init(_ header: Data) throws {
            guard header.count >= 16 else { throw ReadError("Truncated MOBI PalmDOC header") }
            guard try be(header, 12, 2) == 0 else { throw ReadError("Encrypted MOBI/Kindle DRM is not supported") }
            compression = try be(header, 0, 2)
            guard [1, 2, 17480].contains(compression) else { throw ReadError("Unsupported MOBI compression \(compression)") }
            if header.count == 16 { length = 0; flags = 0; return }
            guard header.count >= 132, header.subdata(in: 16..<20) == Data("MOBI".utf8) else { throw ReadError("Invalid MOBI header") }
            length = try be(header, 20, 4)
            guard length >= 116, length <= header.count - 16 else { throw ReadError("Truncated MOBI header") }
            if length >= 164 {
                let entries = try be(header, 16 + 152, 4)
                if entries != 0, entries != 0xffff_ffff { throw ReadError("MOBI DRM is not supported") }
            }
            flags = length >= 228 ? try be(header, 16 + 226, 2) : 0
        }
    }

    public struct PalmContent: Sendable {
        public let html: Data
        public let bookmarks: [(title: String, fragment: String)]
    }

    /// Sumatra's PalmDoc::Load turns PalmDOC/TealDoc text into static HTML.
    /// Its DataPlkr path uses the same PalmDOC layout; it does not decode the
    /// standard Plucker record-command/image format. Retain that real limit.
    public static func palmContent(_ data: Data) throws -> PalmContent {
        let database = try PalmDatabase(data)
        guard ["TEXtREAd", "TEXtTlDc", "DataPlkr"].contains(database.creator) else { throw ReadError("Unsupported Palm database") }
        var raw: Data
        do { raw = try database.text() }
        catch {
            if database.creator == "DataPlkr" { throw ReadError("This Plucker record format is unsupported: \(error.localizedDescription)") }
            throw error
        }
        // Sumatra issue #2529: ebook text NULs are spaces. Binary Print
        // Replica data intentionally never passes through this HTML path.
        for index in raw.indices where raw[index] == 0 { raw[index] = 32 }
        let text: String
        if let utf8 = String(data: raw, encoding: .utf8) { text = utf8 }
        else {
            var converted: NSString?
            _ = NSString.stringEncoding(for: raw, encodingOptions: [:], convertedString: &converted, usedLossyConversion: nil)
            text = converted as String? ?? String(decoding: raw, as: UTF8.self)
        }
        return try tealHTML(text)
    }

    private static func be(_ data: Data, _ offset: Int, _ size: Int) throws -> Int {
        guard offset >= 0, size <= data.count, offset <= data.count - size else { throw ReadError("Truncated Palm/MOBI record") }
        return data[offset..<offset + size].reduce(0) { ($0 << 8) | Int($1) }
    }
    private struct PalmDatabase {
        let data: Data
        let offsets: [Int]
        let creator: String
        var count: Int { offsets.count - 1 }

        init(_ data: Data) throws {
            let data = data.startIndex == 0 ? data : data.subdata(in: data.startIndex..<data.endIndex)
            guard data.count >= 78 else { throw ReadError("Truncated Palm database") }
            self.data = data
            creator = String(decoding: data[60..<68], as: UTF8.self)
            offsets = try Self.recordOffsets(data, length: data.count)
        }
        static func recordOffsets(_ data: Data, length: Int) throws -> [Int] {
            let count = try be(data, 76, 2), minimum = 78 + count * 8
            guard count > 0, minimum <= data.count, minimum <= length else { throw ReadError("Invalid Palm record table") }
            var offsets = try (0..<count).map { try be(data, 78 + $0 * 8, 4) }
            offsets.append(length)
            guard offsets[0] >= minimum, zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw ReadError("Invalid Palm record offsets") }
            return offsets
        }
        func record(_ index: Int) -> Data { data.subdata(in: offsets[index]..<offsets[index + 1]) }
        func textRecordCount() throws -> Int {
            var records = try be(record(0), 8, 2)
            if records == count { records -= 1 } // Sumatra's issue #2529 compatibility.
            guard records > 0, records < count else { throw ReadError("Invalid Palm text record count") }
            return records
        }
        func text(flags: Int = 0, recover: Bool = true, imageFallback: Bool = false) throws -> Data {
            let header = record(0), compression = try be(header, 0, 2)
            guard header.count >= 16 else { throw ReadError("Truncated PalmDOC header") }
            let records = try textRecordCount()
            let huffman: HuffDictionary?
            if compression == 17480 {
                guard header.count >= 132, header.subdata(in: 16..<20) == Data("MOBI".utf8) else { throw ReadError("HUFF compression requires a MOBI header") }
                let first = try be(header, 16 + 96, 4), number = try be(header, 16 + 100, 4)
                guard number >= 2, number <= 33, first > records, first < count, number <= count - first else { throw ReadError("Invalid MOBI HUFF/CDIC record range") }
                huffman = try HuffDictionary(huff: record(first), dictionaries: (1..<number).map { record(first + $0) })
            } else {
                guard compression == 1 || compression == 2 else { throw ReadError("Unsupported Palm compression \(compression)") }
                huffman = nil
            }
            var output = Data(), failed = 0
            var firstFailure: ReadError?
            for index in 1...records {
                do {
                    let bytes = try strippedRecord(record(index), flags: flags)
                    if let huffman { try huffman.decompress(bytes, into: &output) }
                    else if compression == 2 { try unpackPalm(Array(bytes), into: &output) }
                    else { output.append(contentsOf: bytes) }
                } catch let error as ReadError {
                    guard recover else { throw error }
                    failed += 1
                    if firstFailure == nil { firstFailure = error }
                    NSLog("MOBI text record %d failed; retaining available text: %@", index, error.localizedDescription)
                }
            }
            // MobiDoc::LoadForPdbReader keeps partial text unless more than
            // half the records fail. Only that case requires image fallback.
            if failed > records / 2 {
                guard imageFallback else { throw firstFailure! }
                return Data()
            }
            // The declared length is a capacity hint, not a truncation or
            // minimum-length contract. Preserve all successfully decoded bytes.
            return output
        }
    }

    /// MobiDoc.cpp GetRealRecordSize: trailing entries use reverse variable
    /// width integers; bit zero additionally marks a multibyte overlap suffix.
    private static func strippedRecord(_ bytes: Data, flags: Int) throws -> Data {
        var count = bytes.count
        for _ in 0..<(flags >> 1).nonzeroBitCount {
            guard count >= 4 else { throw ReadError("Truncated MOBI trailing entry") }
            var size = 0
            for byte in bytes[(count - 4)..<count] {
                if byte & 0x80 != 0 { size = 0 }
                size = (size << 7) | Int(byte & 0x7f)
            }
            guard size > 0, size <= count else { throw ReadError("Invalid MOBI trailing entry length") }
            count -= size
        }
        if flags & 1 != 0 {
            guard count > 0 else { throw ReadError("Truncated MOBI multibyte suffix") }
            let size = Int(bytes[count - 1] & 3) + 1
            guard size <= count else { throw ReadError("Invalid MOBI multibyte suffix") }
            count -= size
        }
        return bytes.subdata(in: 0..<count)
    }

    private struct HuffDictionary {
        let cache: [UInt32]
        let base: [UInt32]
        let dictionaries: [Data]
        let codeLength: Int

        init(huff: Data, dictionaries records: [Data]) throws {
            guard huff.count >= 1304, huff.prefix(4) == Data("HUFF".utf8),
                  try be(huff, 4, 4) == 24, try be(huff, 8, 4) == 24,
                  try be(huff, 12, 4) == 1048 else { throw ReadError("Invalid MOBI HUFF tables") }
            cache = try (0..<256).map { UInt32(try be(huff, 24 + $0 * 4, 4)) }
            base = try (0..<64).map { UInt32(try be(huff, 1048 + $0 * 4, 4)) }
            var dictionaries = [Data](), lengths = [Int]()
            for record in records {
                guard record.count >= 16, record.prefix(4) == Data("CDIC".utf8), try be(record, 4, 4) == 16 else { throw ReadError("Invalid MOBI CDIC header") }
                let length = try be(record, 12, 4)
                guard length > 0, length <= 16, record.count - 16 >= 2 * (1 << length) else { throw ReadError("Invalid MOBI CDIC offset table") }
                lengths.append(length); dictionaries.append(record.subdata(in: 16..<record.count))
            }
            guard let length = lengths.min() else { throw ReadError("MOBI has no CDIC dictionary") }
            self.dictionaries = dictionaries; codeLength = length
        }

        func decompress(_ input: Data, into output: inout Data, depth: Int = 0) throws {
            guard depth <= 21 else { throw ReadError("Recursive MOBI HUFF/CDIC dictionary") }
            var position = 0
            while position < input.count * 8 {
                // Zero-padded 32-bit lookahead, as Sumatra's BitReader::Peek.
                // Five byte reads also cover an unaligned starting bit.
                var window: UInt64 = 0
                let byte = position / 8
                for index in byte..<byte + 5 { window = (window << 8) | (index < input.count ? UInt64(input[index]) : 0) }
                let bits = UInt32(truncatingIfNeeded: window >> (8 - position % 8))
                let left = input.count * 8 - position
                if left < 8, bits == 0 { break }
                let entry = cache[Int(bits >> 24)]
                var length = Int(entry & 0x1f)
                guard length > 0 else { throw ReadError("MOBI HUFF code has zero length") }
                let codeMaximum: UInt32
                if entry & 0x80 != 0 { codeMaximum = entry >> 8 }
                else {
                    while length <= 32, base[length * 2 - 2] > bits >> (32 - length) { length += 1 }
                    guard length <= 32 else { throw ReadError("MOBI HUFF code exceeds 32 bits") }
                    codeMaximum = base[length * 2 - 1]
                }
                guard length <= left else { throw ReadError("Truncated MOBI HUFF code") }
                let value = bits >> (32 - length)
                guard value <= codeMaximum else { throw ReadError("Invalid MOBI HUFF code") }
                let code = Int(codeMaximum - value), dictionary = code >> codeLength
                guard dictionary < dictionaries.count else { throw ReadError("MOBI HUFF dictionary index out of range") }
                let data = dictionaries[dictionary], symbol = code & ((1 << codeLength) - 1)
                let offset = try be(data, symbol * 2, 2), size = try be(data, offset, 2)
                let count = size & 0x7fff
                guard offset + 2 <= data.count, count <= data.count - offset - 2 else { throw ReadError("Truncated MOBI CDIC phrase") }
                let bytes = data.subdata(in: (offset + 2)..<(offset + 2 + count))
                if size & 0x8000 != 0 { output.append(contentsOf: bytes) }
                else { try decompress(bytes, into: &output, depth: depth + 1) }
                position += length
            }
        }
    }

    private static func tealHTML(_ text: String) throws -> PalmContent {
        // Only the six TealDoc tags recognized by PalmDoc::HandleTealDocTag
        // are interpreted. Ordinary text and unknown markup stay literal.
        let tags = try NSRegularExpression(pattern: #"<([A-Za-z]+)\b((?:[^\"'>]|\"[^\"]*\"|'[^']*')*)>"#)
        func escape(_ value: String, entities: Bool = false) -> String {
            let escaped = entities ? value : value.replacingOccurrences(of: "&", with: "&amp;")
            return escaped.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func plain(_ value: String) -> String {
            escape(value).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\n<br>")
        }
        let string = text as NSString
        var position = 0, bookmarks = [(title: String, fragment: String)]()
        var output = Data("<!doctype html><html><head><meta charset=\"UTF-8\"></head><body>".utf8)
        for match in tags.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            output.append(contentsOf: plain(string.substring(with: NSRange(location: position, length: match.range.location - position))).utf8)
            let name = string.substring(with: match.range(at: 1)).uppercased()
            let raw = string.substring(with: match.range(at: 2)), attributeString = raw as NSString
            var values = [String: String]()
            for attribute in markupAttributes.matches(in: raw, range: NSRange(location: 0, length: attributeString.length)) {
                let key = attributeString.substring(with: attribute.range(at: 1)).uppercased()
                let range = (2...4).map { attribute.range(at: $0) }.first { $0.location != NSNotFound }!
                if values[key] == nil { values[key] = attributeString.substring(with: range) }
            }
            let markup: String
            switch name {
            case "BOOKMARK" where values["NAME"] != nil:
                let fragment = "ToC!Entry!\(bookmarks.count + 1)"
                let title = CFXMLCreateStringByUnescapingEntities(nil, values["NAME"]! as CFString, ["nbsp": "\u{a0}"] as CFDictionary) as String
                bookmarks.append((title, fragment)); markup = "<a id=\"\(fragment)\"></a>"
            case "HEADER" where values["TEXT"] != nil:
                let level = values["FONT"].map { $0.first == "0" ? 5 : $0.first == "2" ? 1 : 3 } ?? 2
                markup = "<h\(level)>\(escape(values["TEXT"]!, entities: true))</h\(level)>"
            case "HRULE": markup = "<hr>"
            case "LABEL" where values["NAME"] != nil: markup = "<a id=\"\(escape(values["NAME"]!, entities: true))\"></a>"
            case "LINK" where values["TAG"] != nil && values["TEXT"] != nil:
                markup = values["FILE"] == nil ? "<a href=\"#\(escape(values["TAG"]!, entities: true))\">\(escape(values["TEXT"]!, entities: true))</a>" : ""
            case "TEALPAINT": markup = "" // Upstream removed external TealPaint support in r7047.
            default: markup = plain(string.substring(with: match.range))
            }
            output.append(contentsOf: markup.utf8)
            position = NSMaxRange(match.range)
        }
        output.append(contentsOf: plain(string.substring(from: position)).utf8)
        output.append(contentsOf: "</body></html>".utf8)
        return PalmContent(html: output, bookmarks: bookmarks)
    }

    /// Equivalent to Sumatra's ExtractPdfFromMopRaw(): the first section of
    /// the first %MOP table is the embedded PDF. Falling back to %PDF is also
    /// what Sumatra does for old/non-table Print Replica payloads.
    static func printReplica(_ raw:Data)throws->Data{
        guard raw.count>=5 else{throw ReadError("Print Replica payload is empty")}
        if raw.prefix(4) != Data("%MOP".utf8){
            guard let p=raw.range(of:Data("%PDF-".utf8))?.lowerBound else{throw ReadError("Print Replica contains no PDF")}
            return raw.subdata(in:p..<raw.endIndex)
        }
        func be32(_ p:Int)throws->Int{
            guard p+4<=raw.count else{throw ReadError("Truncated %MOP table")}
            return raw[p..<p+4].reduce(0){($0<<8)|Int($1)}
        }
        let tables=try be32(4);guard tables>0,tables<=(raw.count-16)/4 else{throw ReadError("Invalid %MOP table")}
        let p=8+tables*4
        let offset=try be32(p),length=try be32(p+4)
        guard length>=5,offset<=raw.count,length<=raw.count-offset else{throw ReadError("Invalid %MOP PDF section")}
        let pdf=raw.subdata(in:offset..<offset+length)
        guard pdf.starts(with:Data("%PDF-".utf8))else{throw ReadError("First %MOP section is not PDF")}
        return pdf
    }

    // MobiDoc::PalmdocUncompress appends to the document buffer. This also
    // retains a damaged record's valid prefix and permits prior-record refs.
    private static func unpackPalm(_ bytes: [UInt8], into output: inout Data) throws {
        var offset = 0
        while offset < bytes.count {
            let byte = Int(bytes[offset]); offset += 1
            switch byte {
            case 1...8:
                guard byte <= bytes.count - offset else { throw ReadError("Truncated Palm literal") }
                output.append(contentsOf: bytes[offset..<(offset + byte)])
                offset += byte
            case 0, 9...127:
                output.append(UInt8(byte))
            case 128...191:
                guard offset < bytes.count else { throw ReadError("Truncated Palm back-reference") }
                let pair = (byte << 8) | Int(bytes[offset]); offset += 1
                let distance = (pair & 0x3fff) >> 3, count = (pair & 7) + 3
                guard distance > 0, distance <= output.count else { throw ReadError("Invalid Palm back-reference") }
                for _ in 0..<count { output.append(output[output.count - distance]) }
            default:
                output.append(32); output.append(UInt8(byte ^ 128))
            }
        }
    }

}
