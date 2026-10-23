import AppKit
import Quartz

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let image = QuickLookPageView()
    private let label = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "‹", target: nil, action: nil)
    private let next = NSButton(title: "›", target: nil, action: nil)
    private var book: QuickLookBook?
    private var rendering: Task<Void, Never>?

    override func loadView() {
        let root = PreviewKeys()
        root.step = { [weak self] in self?.step($0) }
        view = root
        let controls = NSStackView(views: [previous, label, next])
        controls.alignment = .centerY; controls.spacing = 16
        let stack = NSStackView(views: [image, controls])
        stack.orientation = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            image.widthAnchor.constraint(equalTo: stack.widthAnchor),
            image.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        image.setContentHuggingPriority(.defaultLow, for: .vertical)
        image.setAccessibilityElement(true)
        image.setAccessibilityRole(.image)
        image.setAccessibilityLabel("Page preview")
        previous.target = self; previous.action = #selector(goPrevious)
        next.target = self; next.action = #selector(goNext)
        previous.setAccessibilityLabel("Previous page"); next.setAccessibilityLabel("Next page")
        preferredContentSize = NSSize(width: 640, height: 800)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        rendering?.cancel()
        _ = view
        let document = try QuickLookBook(url: url)
        let page = try await document.image(maximum: CGSize(width: 1200, height: 1600))
        try Task.checkCancellation()
        book = document; display(page)
    }

    @objc private func goPrevious() { step(-1) }
    @objc private func goNext() { step(1) }

    private func step(_ direction: Int) {
        guard let book, rendering == nil, direction < 0 ? previous.isEnabled : next.isEnabled else { return }
        previous.isEnabled = false; next.isEnabled = false
        rendering = Task { [weak self] in
            defer { self?.rendering = nil }
            do {
                let page = try await book.image(maximum: CGSize(width: 1200, height: 1600), direction: direction)
                try Task.checkCancellation()
                self?.display(page)
            } catch is CancellationError {} catch { self?.label.stringValue = error.localizedDescription }
        }
    }

    private func display(_ page: QuickLookBook.Page) {
        image.image = page.image
        label.stringValue = page.label
        previous.isEnabled = page.hasPrevious; next.isEnabled = page.hasNext
    }

    override func viewDidDisappear() {
        super.viewDidDisappear(); rendering?.cancel(); rendering = nil; book = nil; image.image = nil
    }
}

// Draw into the actual remote-view bounds. NSImageView's intrinsic bitmap size
// can exceed the Finder host's allocated area and clip the preview at Retina sizes.
final class QuickLookPageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: QuickLookBook.fitted(CGSize(width: image.width, height: image.height), in: bounds.size))
    }
}

private final class PreviewKeys: NSView {
    var step: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { step?(-1) }
        else if event.keyCode == 124 { step?(1) }
        else { super.keyDown(with: event) }
    }
}
