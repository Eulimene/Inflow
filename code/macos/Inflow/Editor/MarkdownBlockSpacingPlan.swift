import Foundation

/// Display-only spacing for complete parsed blocks, independent of syntax and focus.
/// Each adjacent run of n blank source lines keeps max(0, n - 1) visible lines.
/// Source editing never applies this plan. New block kinds supply their boundaries
/// to the same initializer; they do not need their own before/after blank-line rules.
struct MarkdownBlockSpacingPlan {
    let blankLines: [NSRange]
    /// Only whitespace outside complete blocks participates in block spacing.
    let separatorLines: [NSRange]
    let collapsedLines: [NSRange]
    /// The last blank immediately before each block. Editing can reuse this line
    /// while retaining the new separator next to the block, where it stays folded.
    let leadingBlankLines: [NSRange]

    init(source: String, blockRanges: [NSRange]) {
        let text = source as NSString
        let blocks = blockRanges.filter {
            $0.location != NSNotFound && $0.location >= 0 && $0.length > 0
                && $0.location <= text.length && $0.length <= text.length - $0.location
        }.map { text.paragraphRange(for: $0) }
        let starts = Set(blocks.map(\.location))
        let ends = Set(blocks.map { NSMaxRange($0) })
        var blanks: [NSRange] = []
        var collapsed: [NSRange] = []
        var separators: [NSRange] = []
        var leading: [NSRange] = []
        var run: [NSRange] = []
        func finishRun() {
            guard let first = run.first, let last = run.last else { return }
            // A run shared by two blocks is still one separator, not two.
            if ends.contains(first.location) || starts.contains(NSMaxRange(last)) {
                separators.append(contentsOf: run)
                collapsed.append(first)
            }
            if starts.contains(NSMaxRange(last)) { leading.append(last) }
            run.removeAll(keepingCapacity: true)
        }
        var location = 0
        while location < text.length {
            let line = text.paragraphRange(for: NSRange(location: location, length: 0))
            // Markdown blanks contain only spaces, tabs and line endings. Other
            // Unicode whitespace can be meaningful prose and must remain visible.
            let isBlank = (line.location..<NSMaxRange(line)).allSatisfy {
                [0x20, 0x09, 0x0A, 0x0D].contains(text.character(at: $0))
            }
            if isBlank {
                blanks.append(line)
                run.append(line)
            } else {
                finishRun()
            }
            location = NSMaxRange(line)
        }
        finishRun()
        blankLines = blanks
        separatorLines = separators
        collapsedLines = collapsed
        leadingBlankLines = leading
    }
}

extension RenderedMarkdownPlan {
    var blockSpacing: MarkdownBlockSpacingPlan {
        MarkdownBlockSpacingPlan(source: sourceSnapshot, blockRanges: blockSpacingBoundaries)
    }
}
