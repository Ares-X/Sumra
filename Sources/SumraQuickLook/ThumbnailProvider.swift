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
                handler(QLThumbnailReply(contextSize: request.maximumSize, currentContextDrawing: {
                    Self.draw(page.image, in: request.maximumSize)
                    return true
                }), nil)
            } catch { handler(nil, error) }
        }
    }

    // AppKit draws in points and applies Quick Look's Retina scale. The raw
    // CGContext reply uses a scaled bitmap, so point-sized drawing occupies
    // only its lower-left portion on a Retina display.
    static func draw(_ image: CGImage, in size: CGSize) {
        let imageSize = CGSize(width: image.width, height: image.height)
        NSImage(cgImage: image, size: imageSize).draw(in: QuickLookBook.fitted(imageSize, in: size))
    }
}
