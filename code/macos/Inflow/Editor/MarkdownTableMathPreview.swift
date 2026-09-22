import AppKit

/// A disposable reading projection. The cell's editable text and source mapping
/// remain untouched; attachments never participate in document edits or history.
@MainActor
final class MarkdownTableMathPreview: NSTextView {
    private var visibleOffsets: [Int] = []
    private var formulaSizes: [(NSTextAttachment, NSSize)] = []
    var activate: ((Int, NSEvent) -> Void)?
    var openLink: ((String, NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { false }

    init?(cell: RenderedMarkdownTableCell, attributedText: NSAttributedString,
          requests: [JavaScriptRenderRequest], results: [String: JavaScriptRenderedOutput], color: NSColor, font: NSFont, maximumWidth: CGFloat) {
        let projection = MarkdownInlineProjection(cell.markdown)
        guard projection.text == cell.text else { return nil }
        let output = NSMutableAttributedString(attributedString: attributedText)
        var offsets = Array(0..<cell.text.utf16.count)
        var count = 0
        var sizes: [(NSTextAttachment, NSSize)] = []
        for request in requests.sorted(by: { $0.sourceRange.utf16Range.location > $1.sourceRange.utf16Range.location }) {
            let raw = request.sourceRange.utf16Range
            guard raw.location >= cell.sourceRange.utf16Range.location,
                  NSMaxRange(raw) <= NSMaxRange(cell.sourceRange.utf16Range),
                  let result = results[request.cacheKey], let svg = result.svg,
                  let original = NSImage(data: result.pdfData ?? Data(svg.utf8)), original.size.height > 0 else { continue }
            let range = projection.visibleRange(for: NSRange(location: raw.location - cell.sourceRange.utf16Range.location, length: raw.length))
            guard range.length > 0, NSMaxRange(range) <= output.length else { continue }
            let scale = font.pointSize / 16
            let size = NSSize(width: max(1, CGFloat(result.width ?? Int(original.size.width)) * scale),
                              height: max(1, CGFloat(result.height ?? Int(original.size.height)) * scale))
            let tinted: NSImage
            if result.pdfData != nil {
                original.size = size
                tinted = original
            } else {
                tinted = NSImage(size: size, flipped: false) { rect in
                    original.draw(in: rect)
                    color.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
            }
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = NSRect(x: 0, y: font.descender, width: size.width, height: size.height)
            sizes.append((attachment, size))
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttribute(.toolTip, value: request.source, range: NSRange(location: 0, length: 1))
            output.replaceCharacters(in: range, with: replacement)
            offsets.replaceSubrange(range.location..<NSMaxRange(range), with: [range.location])
            count += 1
        }
        guard count > 0 else { return nil }
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: maximumWidth, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        visibleOffsets = offsets + [cell.text.utf16.count]
        formulaSizes = sizes
        isEditable = false
        isSelectable = false
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textStorage?.setAttributedString(output)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func height(for width: CGFloat) -> CGFloat {
        for (attachment, size) in formulaSizes {
            let scale = min(1, max(20, width) / size.width)
            attachment.bounds.size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        textContainer?.containerSize = NSSize(width: max(20, width), height: .greatestFiniteMagnitude)
        guard let textContainer, let layoutManager else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = min(characterIndexForInsertion(at: point), visibleOffsets.count - 1)
        if index < (textStorage?.length ?? 0),
           let link = textStorage?.attribute(.link, at: index, effectiveRange: nil) as? String,
           openLink?(link, event) == true { return }
        activate?(visibleOffsets[index], event)
    }
}
