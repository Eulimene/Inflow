import Foundation

/// Display-only spacing for complete parsed blocks, independent of syntax and focus.
/// Each adjacent run of n blank source lines keeps max(0, n - 1) visible lines.
/// Source editing never applies this plan. New block kinds supply their boundaries
/// to the same initializer; they do not need their own before/after blank-line rules.
struct MarkdownBlockSpacingPlan {
    let blankLines: [NSRange]
    let collapsedLines: [NSRange]

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
        var run: [NSRange] = []
        func finishRun() {
            guard let first = run.first, let last = run.last else { return }
            // A run shared by two blocks is still one separator, not two.
            if ends.contains(first.location) || starts.contains(NSMaxRange(last)) {
                collapsed.append(first)
            }
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
        collapsedLines = collapsed
    }
}

extension RenderedMarkdownPlan {
    /// Syntax adapter only: Setext's underline is part of the heading block.
    /// Tables, quotes and code blocks can supply their complete parsed ranges to
    /// MarkdownBlockSpacingPlan without changing its spacing policy.
    var headingSpacingBoundaries: [NSRange] {
        let text = sourceSnapshot as NSString
        let underlines = Set(markers.compactMap { marker -> Int? in
            guard case .heading = marker.kind else { return nil }
            let raw = text.substring(with: marker.sourceRange.utf16Range)
                .trimmingCharacters(in: .whitespaces)
            return raw.first == "=" || raw.first == "-" ? marker.sourceRange.utf16Range.location : nil
        })
        return contentStyles.compactMap { content in
            guard case .heading = content.kind else { return nil }
            var range = text.paragraphRange(for: content.sourceRange.utf16Range)
            if underlines.contains(NSMaxRange(range)) {
                range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
            }
            return range
        }
    }
}
