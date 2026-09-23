import AppKit

/// Input attributes are a separate projection of semantic styles. Display-only
/// marker hiding, attachments, token colours and collapsed rows never enter it.
@MainActor
final class MarkdownTypingStyleProjection {
    private var storage: NSMutableAttributedString?
    private var hiddenRanges: [NSRange] = []
    private var protectedRanges: [NSRange] = []
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]

    func reset() {
        storage = nil
        hiddenRanges = []
        protectedRanges = []
        baseAttributes = [:]
    }

    func install(semanticText: NSAttributedString, plan: RenderedMarkdownPlan,
                 baseAttributes: [NSAttributedString.Key: Any]) {
        guard plan.exactlyMatches(semanticText.string) else { return }
        self.baseAttributes = baseAttributes
        let projection = NSMutableAttributedString(string: semanticText.string)
        semanticText.enumerateAttributes(in: NSRange(location: 0, length: semanticText.length)) { attributes, range, _ in
            projection.setAttributes(self.inputAttributes(from: attributes), range: range)
        }
        storage = projection
        hiddenRanges = plan.markers.map(\.sourceRange.utf16Range)
        protectedRanges = plan.localSourceBlocks.map(\.sourceRange.utf16Range)
            + plan.renderRequests.map(\.sourceRange.utf16Range)
    }

    func attributes(in source: String, selection: NSRange) -> [NSAttributedString.Key: Any]? {
        guard storage != nil else { return nil }
        synchronizeNativeText(source)
        guard let storage, UTF8Text.isExactlyEqual(storage.string, source),
              selection.location <= storage.length else { return nil }
        guard storage.length > 0 else { return baseAttributes }
        let line = (source as NSString).lineRange(for: NSRange(location: selection.location, length: 0))
        let empty = (source as NSString).substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty, !protectedRanges.contains(where: { NSLocationInRange(selection.location, $0) }) {
            return baseAttributes
        }
        let location = RenderedMarkdownCaretStyleResolver.visibleAttributeLocation(
            forInsertionLocation: selection.location, text: source, hiddenRanges: hiddenRanges
        ) ?? min(selection.location, storage.length - 1)
        return inputAttributes(from: storage.attributes(at: location, effectiveRange: nil))
    }

    /// Ordinary typing rebases the semantic projection with one UTF-8-safe edit.
    /// It does not invoke the parser, and never reads display NSTextStorage.
    private func synchronizeNativeText(_ source: String) {
        guard let storage, let edit = EditorEngineTextDiff.replacement(from: storage.string, to: source),
              let target = MarkdownSourceRange.navigationTarget(forUTF8Range: edit.start..<edit.end, in: storage.string)
        else { return }
        let range = target.revealRange
        let attributes: [NSAttributedString.Key: Any]
        if storage.length > 0 {
            let location = RenderedMarkdownCaretStyleResolver.visibleAttributeLocation(
                forInsertionLocation: range.location, text: storage.string, hiddenRanges: hiddenRanges
            ) ?? min(range.location, storage.length - 1)
            attributes = inputAttributes(from: storage.attributes(at: location, effectiveRange: nil))
        } else { attributes = baseAttributes }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: edit.inserted, attributes: attributes))
        let insertedLength = edit.inserted.utf16.count
        hiddenRanges = Self.rebased(hiddenRanges, replacing: range, insertedLength: insertedLength)
        protectedRanges = Self.rebased(protectedRanges, replacing: range, insertedLength: insertedLength,
            preservesContainingRange: true)
    }

    private func inputAttributes(from attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = baseAttributes
        for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
            if let value = attributes[key] { result[key] = value }
        }
        if (result[.font] as? NSFont)?.pointSize ?? 0 < 1 { result[.font] = baseAttributes[.font] }
        if (result[.foregroundColor] as? NSColor)?.alphaComponent == 0 {
            result[.foregroundColor] = baseAttributes[.foregroundColor]
        }
        return result
    }

    private static func rebased(_ ranges: [NSRange], replacing edit: NSRange, insertedLength: Int,
                                preservesContainingRange: Bool = false) -> [NSRange] {
        let delta = insertedLength - edit.length
        return ranges.compactMap { range in
            if NSMaxRange(range) <= edit.location { return range }
            if range.location >= NSMaxRange(edit) {
                return NSRange(location: range.location + delta, length: range.length)
            }
            if preservesContainingRange, range.location <= edit.location, NSMaxRange(range) >= NSMaxRange(edit) {
                return NSRange(location: range.location, length: range.length + delta)
            }
            return nil
        }
    }
}
