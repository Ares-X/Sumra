import AppKit
import Quartz

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let image = QuickLookPageView()
    private let label = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
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
        let stack = NSStackView(views: [image, errorLabel, controls])
        stack.orientation = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            image.widthAnchor.constraint(equalTo: stack.widthAnchor),
            image.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            previous.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            previous.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            next.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            next.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        errorLabel.alignment = .center
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.identifier = NSUserInterfaceItemIdentifier("previewError")
        errorLabel.isHidden = true
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
        rendering?.cancel(); rendering = nil
        _ = view
        book = nil; image.image = nil; label.stringValue = ""; errorLabel.isHidden = true
        previous.isEnabled = false; next.isEnabled = false
        let document = try QuickLookBook(url: url)
        book = document
        let page = try await document.image(maximum: CGSize(width: 1200, height: 1600))
        try Task.checkCancellation()
        guard book === document else { throw CancellationError() }
        display(page)
    }

    @objc private func goPrevious() { step(-1) }
    @objc private func goNext() { step(1) }

    private func step(_ direction: Int) {
        guard let book, rendering == nil, direction < 0 ? previous.isEnabled : next.isEnabled else { return }
        let hasPrevious = previous.isEnabled, hasNext = next.isEnabled
        previous.isEnabled = false; next.isEnabled = false
        rendering = Task { [weak self] in
            defer { if self?.book === book { self?.rendering = nil } }
            do {
                let page = try await book.image(maximum: CGSize(width: 1200, height: 1600), direction: direction)
                try Task.checkCancellation()
                guard self?.book === book else { return }
                self?.display(page)
            } catch is CancellationError {} catch {
                guard let self, self.book === book else { return }
                previous.isEnabled = hasPrevious; next.isEnabled = hasNext
                errorLabel.stringValue = error.localizedDescription
                errorLabel.isHidden = false
            }
        }
    }

    private func display(_ page: QuickLookBook.Page) {
        image.image = page.image
        label.stringValue = page.label
        errorLabel.isHidden = true
        previous.isEnabled = page.hasPrevious; next.isEnabled = page.hasNext
    }

    override func viewDidDisappear() {
        super.viewDidDisappear(); rendering?.cancel(); rendering = nil; book = nil; image.image = nil
        previous.isEnabled = false; next.isEnabled = false
    }
}

// Draw into the actual remote-view bounds. NSImageView's intrinsic bitmap size
// can exceed the Finder host's allocated area and clip the preview at Retina sizes.
final class QuickLookPageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    // The clicked page must take keyboard focus, including in a Quick Look panel.
    // Its unhandled keys continue to PreviewKeys through the responder chain.
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
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
