import AppKit

final class RenderedMarkdownImageView: NSImageView {
    var isDocumentSelected = false {
        didSet { if oldValue != isDocumentSelected { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isDocumentSelected {
            MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme).selectionOverlayColor.setFill()
            bounds.intersection(dirtyRect).fill(using: .sourceOver)
        }
    }

    var renderedTheme = PreviewTheme.standard { didSet { updateDiagramFrame(); needsDisplay = true } }
    var presentsDiagram = false {
        didSet { updateDiagramFrame() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDiagramFrame()
        needsDisplay = true
    }

    private func updateDiagramFrame() {
        guard presentsDiagram else {
            layer?.borderWidth = 0
            layer?.cornerRadius = 0
            layer?.backgroundColor = nil
            return
        }
        let palette = MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme)
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.cornerRadius = 0
        layer?.backgroundColor = palette.canvasColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
