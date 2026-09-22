import AppKit
import Foundation

/// Visible characters keep their original source positions so a label edit does
/// not discard its emphasis delimiters or link destination.
struct MarkdownInlineProjection {
    let source: String
    let text: String
    let sourceCharacters: [NSRange]
    let plan: RenderedMarkdownPlan

    init(_ source: String) {
        self.source = source
        plan = RenderedMarkdownEditor.plan(for: source)
        let units = Array(source.utf16)
        let raw = source as NSString
        let hidden = plan.markers.map(\.sourceRange.utf16Range)
        var characters: [UInt16] = [], positions: [NSRange] = []
        var index = 0
        while index < units.count {
            if let marker = hidden.first(where: { $0.length > 0 && NSLocationInRange(index, $0) }) {
                index = NSMaxRange(marker)
                continue
            }
            let tail = raw.substring(from: index)
            if let lineBreak = ["<br>", "<br/>", "<br />"].first(where: { tail.lowercased().hasPrefix($0) }) {
                characters.append(10)
                positions.append(NSRange(location: index, length: lineBreak.utf16.count))
                index += lineBreak.utf16.count
            } else if units[index] == 92, index + 1 < units.count,
                      units[index + 1] < 128, CharacterSet.punctuationCharacters.contains(UnicodeScalar(units[index + 1])!) {
                characters.append(units[index + 1])
                positions.append(NSRange(location: index, length: 2))
                index += 2
            } else {
                characters.append(units[index])
                positions.append(NSRange(location: index, length: 1))
                index += 1
            }
        }
        text = String(decoding: characters, as: UTF16.self)
        sourceCharacters = positions
    }

    func sourceRange(for visible: NSRange) -> NSRange? {
        guard NSMaxRange(visible) <= sourceCharacters.count else { return nil }
        if visible.length == 0 {
            let position = visible.location > 0 ? NSMaxRange(sourceCharacters[visible.location - 1])
                : (sourceCharacters.first?.location ?? 0)
            return NSRange(location: position, length: 0)
        }
        let start = sourceCharacters[visible.location].location
        let end = NSMaxRange(sourceCharacters[NSMaxRange(visible) - 1])
        return NSRange(location: start, length: end - start)
    }

    func visibleRange(for source: NSRange) -> NSRange {
        let start = sourceCharacters.firstIndex { NSMaxRange($0) > source.location } ?? sourceCharacters.count
        guard source.length > 0 else { return NSRange(location: start, length: 0) }
        let end = sourceCharacters.firstIndex { $0.location >= NSMaxRange(source) } ?? sourceCharacters.count
        return NSRange(location: start, length: max(0, end - start))
    }

    @MainActor
    func applyStyles(to output: NSMutableAttributedString, font: NSFont) {
        guard output.string == text else { return }
        for style in plan.contentStyles {
            let indices = sourceCharacters.indices.filter {
                NSIntersectionRange(sourceCharacters[$0], style.sourceRange.utf16Range).length > 0
            }
            guard let first = indices.first, let last = indices.last else { continue }
            let range = NSRange(location: first, length: last - first + 1)
            switch style.kind {
            case .strong, .emphasis:
                var replacements: [(NSRange, NSFont)] = []
                output.enumerateAttribute(.font, in: range) { value, run, _ in
                    replacements.append((run, NSFontManager.shared.convert((value as? NSFont) ?? font,
                        toHaveTrait: style.kind == .strong ? .boldFontMask : .italicFontMask)))
                }
                for (run, value) in replacements { output.addAttribute(.font, value: value, range: run) }
            case .inlineCode:
                output.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor], range: range)
            case .strikethrough:
                output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            default: break
            }
        }
    }
}
