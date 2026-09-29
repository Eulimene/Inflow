import AppKit

/// Attribute-only rendering policy. It has no editor, Engine, selection or async
/// tasks; themes and new Markdown styles can evolve without changing input flow.
@MainActor
struct MarkdownNativeStyleSheet {
    let baseFont: NSFont
    let palette: MarkdownRenderPalette
    let sourceAppearance: SourceEditorAppearance
    let isEditable: Bool

    func hideRenderedMarker(
        _ range: NSRange,
        storage: NSTextStorage,
        reservedAdvance: CGFloat = 0
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let collapsedFont = NSFont.systemFont(ofSize: 0.1)
        storage.addAttributes(
            [
                .font: collapsedFont,
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
                .baselineOffset: 0,
                // Keep the Markdown source byte-for-byte intact while making each marker's
                // layout advance effectively zero. Using the marker's visible font here made
                // inline-code backticks and heading markers distort both wrapping and carets.
                .kern: -collapsedFont.pointSize,
            ],
            range: range
        )
        if reservedAdvance > 0 {
            storage.addAttribute(
                .kern,
                value: reservedAdvance - collapsedFont.pointSize,
                range: NSRange(location: range.location, length: 1)
            )
        }
    }

    func applyRenderedReplacement(
        _ marker: RenderedMarkdownMarker,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        let range = marker.sourceRange.utf16Range
        guard let replacement = marker.replacementText,
              range.length > 0,
              NSMaxRange(range) <= storage.length
        else { return }
        let font = RenderedMarkdownMarkerTypography.font(
            for: marker.kind,
            baseFont: baseFont
        )
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .kern: 0,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
            ],
            range: range
        )
        let markerSpacing = switch marker.kind {
        case .unorderedList, .taskList:
            MarkdownRenderMetrics.listMarkerExtraSpacing
        default:
            CGFloat.zero
        }
        let width = ceil((replacement as NSString).size(withAttributes: [.font: font]).width)
            + markerSpacing
        storage.addAttribute(
            .kern,
            value: max(1, width),
            range: NSRange(location: range.location, length: 1)
        )
    }

    func applyRenderedRule(
        _ range: NSRange,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .kern: 0,
            ],
            range: range
        )
        let paragraph = (
            storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(paragraph.minimumLineHeight, baseFont.pointSize * 1.4)
        storage.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: range.location, length: 1)
        )
    }

    func applyRenderedAttributes(
        for kind: RenderedMarkdownContentStyleKind,
        range: NSRange,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        switch kind {
        case .paragraph:
            break
        case .unorderedListItem, .orderedListItem, .taskListItem:
            let paragraphRange = storage.mutableString.paragraphRange(for: range)
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacing = max(paragraph.paragraphSpacing,
                MarkdownRenderMetrics.listItemGap * baseFont.pointSize / CGFloat(MarkdownRenderMetrics.bodyFontSize))
            storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        case let .heading(level):
            let metrics = MarkdownRenderMetrics.heading(level: level)
            let paragraphRange = storage.mutableString.paragraphRange(for: range)
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.minimumLineHeight = baseFont.pointSize * CGFloat(metrics.scale * MarkdownRenderMetrics.headingLineHeight(level: level))
            // Fallback glyphs (especially Chinese headings) may need a taller
            // line than the Latin font. Do not clip them to a fixed line box.
            paragraph.maximumLineHeight = 0
            paragraph.lineHeightMultiple = 1
            paragraph.paragraphSpacingBefore = baseFont.pointSize * CGFloat(metrics.spacingBefore)
            paragraph.paragraphSpacing = baseFont.pointSize * CGFloat(metrics.spacingAfter)
            storage.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: paragraphRange
            )
            storage.addAttributes(
                [
                    .font: NSFontManager.shared.convert(
                        NSFont(descriptor: baseFont.fontDescriptor, size: baseFont.pointSize * CGFloat(metrics.scale)) ?? baseFont,
                        toHaveTrait: .boldFontMask
                    ),
                    .foregroundColor: level == 6
                        ? palette.secondaryTextColor
                        : palette.headingColor,
                ],
                range: range
            )
        case .emphasis:
            storage.addAttribute(.obliqueness, value: 0.18, range: range)
        case .strong:
            transformFonts(in: range, storage: storage) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        case .strikethrough:
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .inlineCode:
            transformFonts(in: range, storage: storage) { font in
                NSFont.monospacedSystemFont(
                    ofSize: max(
                        13,
                        font.pointSize * CGFloat(MarkdownRenderMetrics.inlineCodeScale)
                    ),
                    weight: .regular
                )
            }
            storage.addAttributes(
                [
                    .baselineOffset: 0,
                    .foregroundColor: palette.textColor,
                    // Attribute backgrounds use the line box and make the
                    // smaller monospace font look vertically displaced. The
                    // text view draws a glyph-bound rounded background instead.
                    .backgroundColor: NSColor.clear,
                ],
                range: range
            )
        case .inlineMath:
            storage.addAttributes(
                [
                    .font: NSFont(name: "Times New Roman", size: baseFont.pointSize)
                        ?? NSFont.systemFont(ofSize: baseFont.pointSize),
                    .foregroundColor: palette.headingColor,
                ],
                range: range
            )
        case .displayMath:
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, 8)
            paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, 8)
            storage.addAttributes(
                [
                    .font: NSFont(name: "Times New Roman", size: baseFont.pointSize + 1)
                        ?? NSFont.systemFont(ofSize: baseFont.pointSize + 1),
                    .foregroundColor: palette.headingColor,
                    .paragraphStyle: paragraph,
                ],
                range: range
            )
        case .blockQuote:
            let paragraphStyle = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent += 16
            paragraphStyle.headIndent += 16
            paragraphStyle.paragraphSpacingBefore = 0
            paragraphStyle.paragraphSpacing = 0
            let paragraphRange = storage.mutableString.paragraphRange(for: range)
            storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraphRange)
            storage.addAttribute(
                .foregroundColor,
                value: palette.secondaryTextColor,
                range: range
            )
        case .tableHeader:
            transformFonts(in: range, storage: storage) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            applyRenderedTableRow(
                range: range,
                storage: storage,
                backgroundColor: palette.mutedSurfaceColor
            )
        case let .tableBody(alternating):
            applyRenderedTableRow(
                range: range,
                storage: storage,
                backgroundColor: alternating
                    ? palette.tableStripeColor
                    : palette.canvasColor
            )
        case .link:
            storage.addAttributes(
                MarkdownLinkVisualStyle.restingAttributes(
                    foregroundColor: palette.accentColor
                ),
                range: range
            )
        }
    }

    private func applyRenderedTableRow(
        range: NSRange,
        storage: NSTextStorage,
        backgroundColor: NSColor
    ) {
        storage.addAttribute(.backgroundColor, value: backgroundColor, range: range)
        guard range.length > 0 else { return }
        let paragraphStyle = (
            storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 1
        paragraphStyle.paragraphSpacingBefore = 1
        paragraphStyle.lineHeightMultiple = max(paragraphStyle.lineHeightMultiple, 1.25)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
    }

    private func transformFonts(
        in range: NSRange,
        storage: NSTextStorage,
        transform: (NSFont) -> NSFont
    ) {
        guard range.length > 0 else { return }
        var replacements: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, effectiveRange, _ in
            let font = value as? NSFont ?? baseFont
            replacements.append((effectiveRange, transform(font)))
        }
        for (effectiveRange, font) in replacements {
            storage.addAttribute(.font, value: font, range: effectiveRange)
        }
    }

    func collapseBlankLines(_ ranges: [NSRange], storage: NSTextStorage) {
        for range in ranges {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 0.001
            paragraph.maximumLineHeight = 0.001
            paragraph.lineHeightMultiple = 0.001
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear, .paragraphStyle: paragraph], range: range)
        }
    }

    /// Semantic block separation is independent of optional source blank lines.
    /// Apply after overlay layout so tables/diagrams retain the same outer gap.
    func applyBlockSpacing(_ boundaries: [NSRange], storage: NSTextStorage) {
        let gap = MarkdownRenderMetrics.paragraphGap * baseFont.pointSize
            / CGFloat(MarkdownRenderMetrics.bodyFontSize)
        for block in boundaries.dropFirst() where block.length > 0 && block.location < storage.length {
            let range = storage.mutableString.paragraphRange(for: NSRange(location: block.location, length: 0))
            let paragraph = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, gap)
            // Overlay anchors intentionally use a different style from the rest
            // of their source paragraph. Only update its leading attribute run.
            var effectiveRange = NSRange()
            _ = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: &effectiveRange)
            storage.addAttribute(.paragraphStyle, value: paragraph,
                range: NSIntersectionRange(range, effectiveRange))
        }
    }

    func applyCompactParagraphGaps(_ blankLines: [NSRange], storage: NSTextStorage) {
        // Editable blank lines are caret destinations, not display-only paragraph gaps.
        guard !isEditable else { return }
        for paragraph in blankLines {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = MarkdownRenderMetrics.paragraphGap * CGFloat(sourceAppearance.fontSize / MarkdownRenderMetrics.bodyFontSize)
            style.maximumLineHeight = style.minimumLineHeight
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
            storage.addAttributes(
                [
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: style,
                ],
                range: paragraph
            )
        }
    }

}
