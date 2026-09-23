import AppKit

@MainActor
final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var sourceTextView: NSTextView?
    private var sourceUTF8 = Data()
    private(set) var lineStarts = [0]

    init(textView: NSTextView, scrollView: NSScrollView) {
        sourceTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var lineCount: Int { lineStarts.count }

    func updateText(_ text: String) {
        let utf8 = Data(text.utf8)
        guard utf8 != sourceUTF8 else {
            needsDisplay = true
            return
        }
        sourceUTF8 = utf8
        var starts = [0]
        starts.reserveCapacity(max(1, text.utf8.count / 48))
        var utf16Offset = 0
        var previousWasCarriageReturn = false
        for codeUnit in text.utf16 {
            utf16Offset += 1
            if codeUnit == 0x0D {
                starts.append(utf16Offset)
                previousWasCarriageReturn = true
            } else if codeUnit == 0x0A {
                if previousWasCarriageReturn {
                    starts[starts.count - 1] = utf16Offset
                } else {
                    starts.append(utf16Offset)
                }
                previousWasCarriageReturn = false
            } else {
                previousWasCarriageReturn = false
            }
        }
        lineStarts = starts
        let digitCount = max(2, String(starts.count).count)
        ruleThickness = max(42, CGFloat(digitCount * 9 + 18))
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = sourceTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }

        NSColor.textBackgroundColor.setFill()
        rect.fill()
        layoutManager.ensureLayout(for: textContainer)
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        let visibleCharacters = layoutManager.characterRange(
            forGlyphRange: visibleGlyphs,
            actualGlyphRange: nil
        )
        let firstLine = max(0, insertionIndex(for: visibleCharacters.location) - 1)
        let lastVisibleCharacter = NSMaxRange(visibleCharacters)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        for index in firstLine..<lineStarts.count {
            let characterIndex = lineStarts[index]
            if characterIndex > lastVisibleCharacter && index > firstLine { break }
            guard let lineRect = lineRect(
                forUTF16Location: characterIndex,
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                continue
            }
            let rulerPoint = convert(
                NSPoint(x: 0, y: lineRect.minY),
                from: textView
            )
            let labelRect = NSRect(
                x: 4,
                y: rulerPoint.y + max(0, (lineRect.height - font.ascender + font.descender) / 2),
                width: ruleThickness - 12,
                height: max(font.pointSize + 4, lineRect.height)
            )
            String(index + 1).draw(in: labelRect, withAttributes: attributes)
        }
    }

    private func insertionIndex(for location: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] < location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func lineRect(
        forUTF16Location location: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        if location == textView.string.utf16.count {
            let extra = layoutManager.extraLineFragmentRect
            guard !extra.isEmpty else { return nil }
            return extra.offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
        }
        guard location < textView.string.utf16.count else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        return fragment.offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
    }
}

