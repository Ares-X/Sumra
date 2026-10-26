import AppKit
import QuickLookThumbnailing

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        Task {
            do {
                let book = try QuickLookBook(url: request.fileURL)
                let page = try await book.image(maximum: CGSize(width: request.maximumSize.width * request.scale,
                                                                height: request.maximumSize.height * request.scale))
                let size = Self.contextSize(for: page.image, maximum: request.maximumSize)
                handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                    Self.draw(page.image, in: size)
                    return true
                }), nil)
            } catch { handler(nil, error) }
        }
    }

    // Finder builds the document frame around this canvas. Use the page's
    // proportions so a portrait page does not receive a square document frame.
    static func contextSize(for image: CGImage, maximum: CGSize) -> CGSize {
        QuickLookBook.fitted(CGSize(width: image.width, height: image.height), in: maximum).size
    }

    // AppKit draws in points and applies Quick Look's Retina scale. The raw
    // CGContext reply uses a scaled bitmap, so point-sized drawing occupies
    // only its lower-left portion on a Retina display.
    static func draw(_ image: CGImage, in size: CGSize) {
        let imageSize = CGSize(width: image.width, height: image.height)
        NSImage(cgImage: image, size: imageSize).draw(in: QuickLookBook.fitted(imageSize, in: size))
    }
}
