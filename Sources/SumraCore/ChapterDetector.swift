import Foundation

public struct DetectedChapter:Sendable,Equatable{
    public let title:String
    public let line:Int
    public let depth:Int
    public init(title:String,line:Int,depth:Int=0){self.title=title;self.line=line;self.depth=depth}
}

/// Lightweight novel TOC detection: structural patterns + line shape + document consistency.
/// It deliberately avoids language models and large rule engines so opening text stays cheap.
public enum ChapterDetector{
    private static let number="〇零一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟0-9０-９"
    private static let patterns:[NSRegularExpression]=[
        try! .init(pattern:"^\\s*第\\s*["+number+"]+\\s*([章节節回卷部篇集节话話])(?:\\s*[-—:：]?\\s*.*)?$",options:.caseInsensitive),
        try! .init(pattern:"^\\s*[卷部篇集]\\s*["+number+"]+(?:\\s+.*)?$",options:.caseInsensitive),
        try! .init(pattern:"^\\s*(?:序章|序言|前言|楔子|引子|终章|終章|尾声|尾聲|后记|後記|番外(?:["+number+"]+)?|プロローグ|エピローグ)(?:\\s+.*)?$",options:.caseInsensitive),
        try! .init(pattern:#"^\s*(?:chapter|part|book)\s+(?:[0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)(?:\b.*)?$"#,options:.caseInsensitive),
        try! .init(pattern:#"^\s*(?:prologue|epilogue|introduction|preface|appendix)(?:\b.*)?$"#,options:.caseInsensitive)
    ]

    private static let titleCharacters=CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"\u{feff}")).inverted
    private static let nonWhitespace=CharacterSet.whitespaces.inverted

    public static func detect(_ text:String)->[DetectedChapter]{index(text).chapters}

    /// Scan line positions and chapter candidates together without retaining a second array of lines.
    public static func index(_ text:String)->(lines:[Int],chapters:[DetectedChapter]){scan(text,chapters:true)}

    private static func scan(_ text:String,chapters:Bool)->(lines:[Int],chapters:[DetectedChapter]){
        let value=text as NSString
        var offsets=[0],end=0,contentsEnd=0,line=0,previousBlank=true
        var candidates:[(Int,String,Int)]=[]
        while end<value.length{
            if Task.isCancelled{return([],[])}
            let start=end
            value.getLineStart(nil,end:&end,contentsEnd:&contentsEnd,for:NSRange(location:start,length:0))
            if chapters{
                let raw=NSRange(location:start,length:contentsEnd-start)
                let blank=value.rangeOfCharacter(from:nonWhitespace,options:[],range:raw).location==NSNotFound
                if blank,let last=candidates.indices.last,candidates[last].0==line-1{candidates[last].2+=1}
                let first=blank ? NSNotFound:value.rangeOfCharacter(from:titleCharacters,options:[],range:raw).location
                if first != NSNotFound{
                    let last=value.rangeOfCharacter(from:titleCharacters,options:.backwards,range:raw)
                    let title=value.substring(with:NSRange(location:first,length:NSMaxRange(last)-first))
                    // Stop after 81 graphemes; a long prose line need not be counted in full.
                    if title.index(title.startIndex,offsetBy:81,limitedBy:title.endIndex)==nil,!endsLikeProse(title){
                        let range=NSRange(title.startIndex..<title.endIndex,in:title)
                        if let family=patterns.firstIndex(where:{$0.firstMatch(in:title,range:range) != nil}){
                            candidates.append((line,title,family*3+(previousBlank ? 1:0)))
                        }
                    }
                }
                previousBlank=blank
            }
            if end<value.length{offsets.append(end)}
            line+=1
        }
        if contentsEnd<value.length{offsets.append(value.length)}
        // The final candidate borders either the end of the document or its empty terminal line.
        if let last=candidates.indices.last,candidates[last].0==line-1{candidates[last].2+=1}
        guard !Task.isCancelled else{return([],[])}
        var families:[Int:Int]=[:]
        for c in candidates{families[c.2/3,default:0]+=1}
        let accepted=candidates.filter{let family=$0.2/3,isolation=$0.2%3;return (families[family] ?? 0)>=2 || isolation==2}
        let grouped=accepted.contains{depth($0.1)==0}
        return (offsets,accepted.map{line,title,_ in DetectedChapter(title:title,line:line,depth:grouped ? depth(title):0)})
    }

    private static func endsLikeProse(_ s:String)->Bool{"。！？!?；;，,".contains(s.last ?? " ")}
    private static func depth(_ s:String)->Int{
        let range=NSRange(s.startIndex..<s.endIndex,in:s),x=s.lowercased()
        if patterns[1].firstMatch(in:s,range:range) != nil || x.hasPrefix("part ") || x.hasPrefix("book "){return 0}
        if let match=patterns[0].firstMatch(in:s,range:range){
            return "卷部篇集".contains((s as NSString).substring(with:match.range(at:1))) ? 0:1
        }
        return 1
    }

    /// Foundation's line boundaries keep TXT navigation consistent with CRLF, CR and Unicode newlines.
    public static func lineOffsets(_ text:String)->[Int]{scan(text,chapters:false).lines}
}
