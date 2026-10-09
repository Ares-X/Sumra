import Foundation

public extension Format{
    static func resolve(_ name:String,prefix:Data)->Format{
        let declared=detect(name)
        if let sniffed=sniff(prefix),declared != .replica,declared != .lit{return sniffed}
        return declared
    }
    static func resolve(_ url:URL,prefix:Data)throws->Format{
        try inspect(url, prefix: prefix).format
    }
    static func inspect(_ url:URL, prefix:Data, password:String? = nil)throws->(format:Format, archive:Archive?){
        let basic=resolve(url.lastPathComponent,prefix:prefix)
        // A Palm title can begin with %PDF-, and a PDF comment can contain
        // BOOKMOBI at byte 60. Resolve this collision using the record table.
        if (basic == .pdf || basic == .book), prefix.count >= 68,
           prefix[prefix.startIndex+60..<prefix.startIndex+68].elementsEqual("BOOKMOBI".utf8),
           hasPDFMarker(prefix) {
            return (try LegacyText.isMobiContainer(url) ? .book : .pdf, nil)
        }
        guard basic == .comic,prefix.starts(with:[0x50,0x4b,0x03,0x04]) else{return (basic, nil)}
        let archive=try Archive(url, password:password)
        if archive.contains("META-INF/container.xml") || ((try? archive.data("mimetype")).flatMap{String(data:$0,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)}).map({$0=="application/epub+zip" || $0=="application/x-ibooks+zip"}) == true{return (.book, archive)}
        if archive.contains("_rels/.rels") || archive.contains("_rels/.rels/[0].piece") || archive.contains("_rels/.rels/[0].last.piece"){return (.mupdf, archive)}
        let files=archive.entries.map{$0.lowercased()}
        if files.filter({$0.hasSuffix(".fb2")}).count == 1 && files.allSatisfy({$0.hasSuffix(".fb2") || $0.hasSuffix(".url")}){return (.book, archive)}
        return (basic, archive)
    }

    static func hasPDFMarker(_ prefix:Data)->Bool{
        prefix.range(of:Data("%PDF-".utf8),in:prefix.startIndex..<min(prefix.endIndex,prefix.startIndex+1024)) != nil
    }

    /// Small signature set mirrored from Sumatra's BSD GuessFileType.cpp.
    /// Extension routing still wins for ambiguous containers (ZIP/7z/RAR).
    static func sniff(_ d:Data)->Format?{
        func has(_ bytes:[UInt8],_ off:Int=0)->Bool{off>=0 && d.count>=off+bytes.count && d[d.startIndex+off..<d.startIndex+off+bytes.count].elementsEqual(bytes)}
        func ascii(_ s:String,_ off:Int=0)->Bool{has(Array(s.utf8),off)}
        if ascii("%PDF-"){return .pdf}
        // Print Replica stores a PDF inside BOOKMOBI. Its early PDF marker
        // must reach the container decoder, rather than open as a bare PDF.
        if ascii("BOOKMOBI",60){return .book}
        if hasPDFMarker(d){return .pdf}
        if ascii("Rar!\u{1a}\u{07}\u{00}") || has([0x52,0x61,0x72,0x21,0x1a,0x07,0x01,0x00]) || has([0x37,0x7a,0xbc,0xaf,0x27,0x1c]) || has([0x50,0x4b,0x03,0x04]){return nil}
        if ascii("ITOLITLS"){return .lit}
        if ascii("ITSF"){return .chm}
        if ascii("AT&T"){return .djvu}
        if ascii("TEXtREAd",60) || ascii("TEXtTlDc",60) || ascii("DataPlkr",60){return .palm}
        if let signature = nativeImageSignature(d) { return signature.format }
        if has([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a])||has([0xff,0xd8])||ascii("GIF87a")||ascii("GIF89a")||ascii("BM")||ascii("BA")||has([0,0,1,0])||has([0x4d,0x4d,0,0x2a])||has([0x49,0x49,0x2a,0])||has([0xff,0x4f,0xff,0x51]){return .image}
        if d.count>=12,ascii("RIFF"),ascii("WEBP",8){return .image}
        if d.count>=12,ascii("ftyp",4){let brand=String(decoding:d[d.startIndex+8..<min(d.endIndex,d.startIndex+24)],as:UTF8.self);if brand.contains("heic")||brand.contains("heix")||brand.contains("mif1")||brand.contains("avif"){return .image}}
        if ascii("%!PS-Adobe-") || (ascii("\u{1b}%-12345X@PJL") && String(decoding:d,as:UTF8.self).contains("%!PS-Adobe-")){return .postscript}
        return nil
    }
}
