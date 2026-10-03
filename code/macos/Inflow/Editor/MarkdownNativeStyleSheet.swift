import AppKit

/// Attribute-only rendering policy. It has no editor, Engine, selection or async
/// tasks; themes and new Markdown styles can evolve without changing input flow.
@MainActor
struct MarkdownNativeStyleSheet {
    let baseFont: NSFont
    let palette: MarkdownRenderPalette
    let sourceAppearance: SourceEditorAppearance
    let isEditable: Bool
    var theme: PreviewTheme = .standard

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
        guard let replacement = marker.displayText(styles: theme.styles),
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
            theme.styles.metric("listMarkerExtraSpacing")
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
        defer { applyCSS(kind: kind, range: range, storage: storage, baseFont: baseFont) }
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
                theme.styles.metric("listItemGap") * baseFont.pointSize / CGFloat(MarkdownRenderMetrics.bodyFontSize))
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
                    .font: NativeCSSStyles.font(
                        NSFont(descriptor: baseFont.fontDescriptor, size: baseFont.pointSize * CGFloat(metrics.scale)) ?? baseFont,
                        bold: true
                    ),
                    .foregroundColor: palette.headingColor,
                ],
                range: range
            )
        case .emphasis:
            storage.addAttribute(.obliqueness, value: theme.styles.token("emphasis-slant"), range: range)
        case .strong:
            transformFonts(in: range, storage: storage) { font in
                NativeCSSStyles.font(font, bold: true)
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
                        theme.styles.token("inline-min-size"),
                        theme.styles.length("font-size", on: "code", relativeTo: font.pointSize)
                            ?? font.pointSize * theme.styles.metric("inlineCodeScale")
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
                    .font: theme.styles.font(on: "math", size: baseFont.pointSize, fallback: baseFont),
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
            paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, theme.styles.length("margin-top", on: "math") ?? 0)
            paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, theme.styles.length("margin-bottom", on: "math") ?? 0)
            storage.addAttributes(
                [
                    .font: theme.styles.font(on: "math", size: theme.styles.length("font-size", on: "math", relativeTo: baseFont.pointSize) ?? baseFont.pointSize, fallback: baseFont),
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
            paragraphStyle.firstLineHeadIndent = theme.styles.token("quote-inset")
            paragraphStyle.headIndent = theme.styles.token("quote-inset")
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
                NativeCSSStyles.font(font, bold: true)
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

    private func applyCSS(kind: RenderedMarkdownContentStyleKind, range: NSRange, storage: NSTextStorage, baseFont: NSFont) {
        let element: String
        switch kind {
        case .paragraph: element = "p"
        case .heading(let level): element = "h\(level)"
        case .blockQuote: element = "blockquote"
        case .inlineCode: element = "code"
        case .link: element = "a"
        case .strong: element = "strong"
        case .emphasis: element = "em"
        case .unorderedListItem, .orderedListItem, .taskListItem: element = "li"
        default: return
        }
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let css = theme.styles
        guard css.rules.contains(where: { $0.selector == element || $0.selector == "#write " + element }) else { return }
        let existingFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? baseFont
        let size = kind == .inlineCode ? existingFont.pointSize
            : min(120, max(6, css.length("font-size", on: element, relativeTo: baseFont.pointSize) ?? existingFont.pointSize))
        var font = css.font(on: element, size: size, fallback: NSFont(descriptor: existingFont.fontDescriptor, size: size) ?? existingFont)
        let weight = css.value("font-weight", on: element)
        if weight == "bold" || (Double(weight ?? "") ?? 0) >= 600
            || (weight == nil && NSFontManager.shared.traits(of: existingFont).contains(.boldFontMask)) {
            font = NativeCSSStyles.font(font, bold: true)
        }
        else if weight != nil { font = NativeCSSStyles.font(font, bold: false) }
        if ["font-family", "font-size", "font-weight"].contains(where: { css.value($0, on: element) != nil }) {
            storage.addAttribute(.font, value: font, range: range)
        }
        if let raw = css.value("color", on: element), let color = NativeCSSStyles.color(raw) {
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
        if css.value("text-transform", on: element) == "uppercase" {
            storage.addAttribute(.markdownUppercase, value: true, range: range)
            // Keep one source character per glyph (including fi/fl sequences).
            storage.addAttribute(.ligature, value: 0, range: range)
        }
        if let spacing = css.length("letter-spacing", on: element, relativeTo: size) {
            storage.addAttribute(.kern, value: min(20, max(-2, spacing)), range: range)
        }
        if let style = css.value("font-style", on: element) {
            storage.addAttribute(.obliqueness, value: style == "italic" ? css.token("emphasis-slant") : 0, range: range)
        }
        if let decoration = css.value("text-decoration", on: element) {
            storage.addAttribute(.underlineStyle, value: decoration.contains("underline") ? NSUnderlineStyle.single.rawValue : 0, range: range)
        }
        switch kind { case .inlineCode, .link, .strong, .emphasis: return; default: break }
        let paragraph = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if case .heading(let level) = kind {
            paragraph.minimumLineHeight = size * CGFloat(MarkdownRenderMetrics.headingLineHeight(level: level))
        }
        if let line = css.value("line-height", on: element) {
            let height = Double(line).map { size * CGFloat($0) } ?? css.length("line-height", on: element, relativeTo: size, rootSize: baseFont.pointSize) ?? 0
            if height.isFinite && height > 0 { paragraph.minimumLineHeight = min(240, max(size, height)); paragraph.lineHeightMultiple = 1 }
        }
        if let before = css.length("margin-top", on: element, relativeTo: size, rootSize: baseFont.pointSize) { paragraph.paragraphSpacingBefore = min(200, max(0, before)) }
        if let after = css.length("margin-bottom", on: element, relativeTo: size, rootSize: baseFont.pointSize) { paragraph.paragraphSpacing = min(200, max(0, after)) }
        if let alignment = css.value("text-align", on: element) {
            paragraph.alignment = alignment == "center" ? .center : alignment == "right" ? .right : alignment == "justify" ? .justified : .left
        }
        if case .blockQuote = kind {
            let inset = max(0, min(160, (css.length("margin-left", on: element, relativeTo: size) ?? 0)
                + (css.length("padding-left", on: element, relativeTo: size) ?? css.token("quote-inset"))))
            paragraph.firstLineHeadIndent = inset
            paragraph.headIndent = inset
        }
        if case .heading = kind {
            let start = storage.mutableString.paragraphRange(for: range).location
            let preceding = storage.mutableString.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines)
            var contextualElement: String?
            if preceding.isEmpty { contextualElement = element + ":first-child" }
            else if let line = preceding.components(separatedBy: "\n").last {
                let hashes = line.prefix(while: { $0 == "#" }).count
                if (1...2).contains(hashes), line.dropFirst(hashes).first == " " {
                    contextualElement = "h\(hashes)+" + element
                }
            }
            if let contextualElement, let before = css.length("margin-top", on: contextualElement,
                relativeTo: size, rootSize: baseFont.pointSize) {
                paragraph.paragraphSpacingBefore = min(200, max(0, before))
            }
            paragraph.paragraphSpacingBefore += max(0, min(80, css.length("padding-top", on: element,
                relativeTo: size, rootSize: baseFont.pointSize) ?? 0))
            paragraph.paragraphSpacing += max(0, min(80, css.length("padding-bottom", on: element,
                relativeTo: size, rootSize: baseFont.pointSize) ?? 0))
            if let left = css.length("padding-left", on: element, relativeTo: size, rootSize: baseFont.pointSize) {
                paragraph.firstLineHeadIndent = max(0, min(80, left)); paragraph.headIndent = paragraph.firstLineHeadIndent
            }
            if let right = css.length("padding-right", on: element, relativeTo: size, rootSize: baseFont.pointSize) {
                paragraph.tailIndent = -max(0, min(80, right))
            }
        }
        // TextKit takes alignment from the start of the paragraph, including hidden Markdown markers.
        storage.addAttribute(.paragraphStyle, value: paragraph, range: storage.mutableString.paragraphRange(for: range))
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
        let gap = theme.styles.metric("paragraphGap") * baseFont.pointSize
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
            style.minimumLineHeight = theme.styles.metric("paragraphGap") * CGFloat(sourceAppearance.fontSize / MarkdownRenderMetrics.bodyFontSize)
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
