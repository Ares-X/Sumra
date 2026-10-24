#if os(macOS)
import Foundation
import CoreGraphics
import ImageIO
import SumraCore
@testable import Sumra

// Four independently authored placements, optionally sharing the same raster.
// The UI variant uses distinct colors to verify the actual painted viewport.
enum EPUBImagePositionFixture {
    static func make(in directory: URL, repeatedImage: Bool = false, captions: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        let colors: [[CGFloat]] = [[1,0,0,1], [0,1,0,1], [0,0,1,1], [1,0,1,1], [0.5,0.5,0.5,1]]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ReadError("Cannot create sRGB image position fixture") }
        for (index, color) in colors.enumerated() {
            guard let context = CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 800,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let fill = CGColor(colorSpace: space, components: color) else { throw ReadError("Cannot create image position fixture") }
            context.setFillColor(fill); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            guard let image = context.makeImage(),
                  let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("art\(index).png") as CFURL, "public.png" as CFString, 1, nil) else { throw ReadError("Cannot write image position fixture") }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw ReadError("Cannot finish image position fixture") }
        }
        let pictures = (0..<4).map { index in
            "<div><p><a id='art\(index)'/><img src='art\(repeatedImage ? 0 : index).png'/></p>" +
                (captions ? "<p>CAPTION_IMAGE_\(index)</p>" : "") + "</div>"
        }.joined()
        let files = [
            "mimetype": "application/epub+zip",
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles></container>",
            "content.opf": "<package version='3.0'><metadata><meta name='cover' content='cover-image'/></metadata><manifest><item id='cover' href='cover.xhtml' media-type='application/xhtml+xml'/><item id='art' href='art.xhtml' media-type='application/xhtml+xml'/><item id='body' href='body.xhtml' media-type='application/xhtml+xml'/><item id='cover-image' href='art4.png' media-type='image/png'/></manifest><spine><itemref idref='cover'/><itemref idref='art'/><itemref idref='body'/></spine><guide><reference type='cover' href='cover.xhtml'/></guide></package>",
            "cover.xhtml": "<html><body><img src='art4.png'/></body></html>",
            "art.xhtml": "<html><head><style>@page{margin:5px}body{margin:0 5px}p{margin:17px 0}img{width:auto;height:auto}div{page-break-inside:avoid}</style></head><body>\(pictures)</body></html>",
            "body.xhtml": "<html><body><p>FOLLOWING TEXT CHAPTER must not replace the illustration being read.</p></body></html>"
        ]
        for (name, text) in files { try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "-0", "image-position.epub"] + files.keys.sorted() + (0..<5).map { "art\($0).png" }
        try runSumraProcess(zip)
        guard zip.terminationStatus == 0 else { throw ReadError("Cannot create EPUB image position fixture") }
        return directory.appendingPathComponent("image-position.epub")
    }
}
#endif
