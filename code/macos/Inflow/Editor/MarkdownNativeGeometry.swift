import AppKit
import CoreText

enum MarkdownNativeTypography {
    static func paragraphStyle(font: NSFont, lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = max(font.pointSize * lineHeight,
            ceil(font.ascender - font.descender + font.leading))
        return style
    }
}

/// TextKit places extra minimum-line-height space above the baseline. Keep the
/// actual glyph metrics (including CJK/emoji fallback fonts) centered in the
/// used line box, leaving paragraph gaps and overlay anchors unchanged.
@MainActor
final class MarkdownCenteredLineLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    func layoutManager(
        _ manager: NSLayoutManager,
        shouldSetLineFragmentRect line: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect used: UnsafeMutablePointer<NSRect>,
        baselineOffset baseline: UnsafeMutablePointer<CGFloat>,
        in container: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard used.pointee.height > 1, glyphRange.length > 0,
              let storage = manager.textStorage else { return false }
        let range = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard NSMaxRange(range) <= storage.length else { return false }
        let text = storage.attributedSubstring(from: range)
        // Attachments carry their own baseline and height. Display-only overlay
        // anchors and collapsed Markdown markers must keep their native layout.
        var hasAttachment = false
        var visibleFontSize: CGFloat = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            hasAttachment = hasAttachment || attributes[.attachment] != nil
            visibleFontSize = max(visibleFontSize, (attributes[.font] as? NSFont)?.pointSize ?? 0)
        }
        guard !hasAttachment, visibleFontSize > 1 else { return false }
        let shapedLine = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(shapedLine, &ascent, &descent, nil)
        guard ascent + descent > 1 else { return false }
        baseline.pointee = used.pointee.minY - line.pointee.minY
            + (used.pointee.height + ascent - descent) / 2
        return true
    }
}

@MainActor
enum RenderedMarkdownLinkActivation {
    static func shouldNavigate(
        for modifierFlags: NSEvent.ModifierFlags,
        preference: LinkActivationPreference,
        isEditing: Bool = false
    ) -> Bool {
        guard preference == .singleClick else { return false }
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editingModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
        return modifiers.intersection(editingModifiers).isEmpty
            && (!isEditing || modifiers.contains(.command))
    }
}

enum RenderedMarkdownCaretStyleResolver {
    @MainActor
    static func insertionRect(_ nativeRect: NSRect, in textView: NSTextView, font: NSFont) -> NSRect {
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            return adjustedInsertionRect(nativeRect, font: font)
        }
        let location = min(textView.selectedRange().location, textView.string.utf16.count)
        let length = textView.string.utf16.count
        let line: NSRect
        if location == length, manager.extraLineFragmentTextContainer === container {
            line = manager.extraLineFragmentRect
        } else if length > 0 {
            var character = min(location, length - 1)
            // A soft-wrap boundary has two insertion positions. Preserve AppKit's
            // affinity instead of moving an upstream caret onto the next line.
            if textView.selectionAffinity == .upstream, location > 0, location < length,
               !isLineEnding((textView.string as NSString).character(at: location - 1)) {
                character = location - 1
            }
            let glyph = manager.glyphIndexForCharacter(at: character)
            guard glyph < manager.numberOfGlyphs else { return adjustedInsertionRect(nativeRect, font: font) }
            // The full fragment includes paragraphSpacing below the text. Using
            // it moves heading/list carets down as block spacing increases.
            line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        } else { return adjustedInsertionRect(nativeRect, font: font) }
        guard line.height > 0 else { return adjustedInsertionRect(nativeRect, font: font) }
        return adjustedInsertionRect(NSRect(x: nativeRect.minX, y: textView.textContainerOrigin.y + line.minY,
            width: nativeRect.width, height: line.height), font: font)
    }

    static func visibleAttributeLocation(
        forInsertionLocation insertion: Int,
        text: String,
        hiddenRanges: [NSRange]
    ) -> Int? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let insertion = min(max(0, insertion), source.length)
        let line = source.lineRange(for: NSRange(location: insertion, length: 0))
        guard line.length > 0 else { return nil }
        let location = min(insertion, NSMaxRange(line) - 1)
        if !isHidden(location, in: hiddenRanges), !isLineEnding(source.character(at: location)) {
            return location
        }
        if let hidden = hiddenRanges.first(where: { NSLocationInRange(location, $0) }),
           let forward = firstVisibleLocation(
               from: NSMaxRange(hidden),
               through: NSMaxRange(line),
               direction: 1,
               source: source,
               hiddenRanges: hiddenRanges
           )
        {
            return forward
        }
        return firstVisibleLocation(
            from: min(insertion - 1, source.length - 1),
            through: line.location - 1,
            direction: -1,
            source: source,
            hiddenRanges: hiddenRanges
        )
    }

    static func adjustedInsertionRect(
        _ rect: NSRect,
        font: NSFont?,
        baselineY: CGFloat? = nil
    ) -> NSRect {
        guard let font else { return rect }
        let fontHeight = ceil(font.ascender - font.descender + font.leading)
        let height = max(1, fontHeight)
        let proposedY = baselineY.map { $0 - font.ascender } ?? (rect.midY - height / 2)
        // Preserve the line centre even when AppKit supplies a transient short rectangle.
        let originY = proposedY
        return NSRect(
            x: rect.origin.x,
            y: originY,
            width: max(1, rect.width),
            height: height
        )
    }

    private static func firstVisibleLocation(
        from start: Int,
        through limit: Int,
        direction: Int,
        source: NSString,
        hiddenRanges: [NSRange]
    ) -> Int? {
        var location = start
        while direction > 0 ? location < limit : location > limit {
            if location >= 0,
               location < source.length,
               !isHidden(location, in: hiddenRanges),
               !isLineEnding(source.character(at: location))
            {
                return location
            }
            location += direction
        }
        return nil
    }

    private static func isHidden(_ location: Int, in ranges: [NSRange]) -> Bool {
        ranges.contains(where: { NSLocationInRange(location, $0) })
    }

    private static func isLineEnding(_ value: unichar) -> Bool {
        value == 0x0A || value == 0x0D
    }
}

enum RenderedMarkdownQuoteGeometry {
    static func contiguousRanges(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else { result.append(range) }
        }
        return result
    }

    static func barRect(
        lineFragment: NSRect,
        textContainerOrigin: NSPoint,
        font: NSFont,
        baselineOffset: CGFloat
    ) -> NSRect {
        let textHeight = max(1, font.ascender - font.descender)
        let fontBoxMinY = textContainerOrigin.y
            + lineFragment.minY
            + baselineOffset
            - font.ascender
        return NSRect(
            x: textContainerOrigin.x + lineFragment.minX + 4,
            y: fontBoxMinY,
            width: 3,
            height: textHeight
        )
    }
}

enum RenderedMarkdownInlineCodeGeometry {
    static func backgroundRect(
        glyphRect: NSRect,
        lineFragment: NSRect,
        textContainerOrigin: NSPoint,
        font: NSFont,
        baselineOffset: CGFloat
    ) -> NSRect {
        let horizontalPadding = MarkdownRenderMetrics.inlineCodeHorizontalPadding
        let verticalPadding = MarkdownRenderMetrics.inlineCodeVerticalPadding
        let textHeight = max(1, ceil(font.ascender - font.descender))
        let textMinY = textContainerOrigin.y
            + lineFragment.minY
            + baselineOffset
            - font.ascender
        return NSRect(
            x: textContainerOrigin.x + glyphRect.minX - horizontalPadding,
            y: textMinY - verticalPadding,
            width: max(1, glyphRect.width + horizontalPadding * 2),
            height: textHeight + verticalPadding * 2
        )
    }
}

enum RenderedMarkdownMarkerTypography {
    static func font(for kind: RenderedMarkdownMarkerKind, baseFont: NSFont) -> NSFont {
        if kind == .footnoteReference {
            return .systemFont(
                ofSize: max(9, baseFont.pointSize * 0.72),
                weight: .medium
            )
        }
        if kind == .unorderedList {
            return .systemFont(
                ofSize: baseFont.pointSize * MarkdownRenderMetrics.unorderedListMarkerScale,
                weight: .semibold
            )
        }
        return baseFont
    }

    static func originY(
        for kind: RenderedMarkdownMarkerKind,
        font: NSFont,
        baseFont: NSFont,
        lineRect: NSRect,
        baselineOffset: CGFloat? = nil
    ) -> CGFloat {
        let baseline = baselineOffset.map { lineRect.minY + $0 } ?? {
            let baseHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
            return lineRect.minY
                + max(0, (lineRect.height - baseHeight) / 2)
                + baseFont.ascender
        }()
        let footnoteLift = kind == .footnoteReference ? lineRect.height * 0.22 : 0
        return baseline - font.ascender - footnoteLift
    }
}
