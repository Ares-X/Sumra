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
                handler(QLThumbnailReply(contextSize: request.maximumSize, drawing: { context in
                    context.draw(page.image, in: QuickLookBook.fitted(CGSize(width: page.image.width, height: page.image.height), in: request.maximumSize))
                    return true
                }), nil)
            } catch { handler(nil, error) }
        }
    }
}
