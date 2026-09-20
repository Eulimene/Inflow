import AppKit
import Foundation

/// A source range expressed in both coordinate systems used by Inflow's editor stack.
///
/// Rust parser results use end-exclusive UTF-8 offsets. `NSTextView` and TextKit use
/// UTF-16 `NSRange` values. Keeping the pair together prevents callers from accidentally
/// applying a byte range as a character range.
struct RenderedMarkdownSourceRange: Equatable, Sendable {
    let utf8Range: Range<Int>
    let utf16Range: NSRange
}

enum RenderedMarkdownMarkerKind: Equatable, Sendable {
    case heading(level: Int)
    case emphasis
    case strong
    case strikethrough
    case inlineCode
    case blockQuote
    case unorderedList
    case orderedList
    case taskList
    case tableBoundary
    case tableSeparator
    case tableDelimiterRow
    case referenceDefinition
    case linkDelimiter
    case linkDestination
    case rule
    case footnoteReference
    case footnoteDefinition
    case mathDelimiter
}

struct RenderedMarkdownMarker: Equatable, Sendable {
    let kind: RenderedMarkdownMarkerKind
    let sourceRange: RenderedMarkdownSourceRange
    let replacementText: String?
}

enum RenderedMarkdownContentStyleKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case emphasis
    case strong
    case strikethrough
    case inlineCode
    case blockQuote
    case unorderedListItem
    case orderedListItem
    case taskListItem(isChecked: Bool)
    case tableHeader
    case tableBody(alternating: Bool)
    case link
    case inlineMath
    case displayMath
}

struct RenderedMarkdownContentStyle: Equatable, Sendable {
    let kind: RenderedMarkdownContentStyleKind
    let sourceRange: RenderedMarkdownSourceRange
}

enum RenderedMarkdownLocalSourceReason: Int, CaseIterable, Hashable, Sendable {
    case parserFailure
    case mermaid
    case fencedCode
    case table
    case rawHTML
    case unsupportedSyntax
    case complexOrAmbiguous
}

/// A range which must remain visibly editable as literal Markdown.
///
/// Reasons are retained when several complex constructs occupy the same source block.
/// The array is stable and sorted by enum order so plans are deterministic.
struct RenderedMarkdownLocalSourceBlock: Equatable, Sendable {
    let sourceRange: RenderedMarkdownSourceRange
    let reasons: [RenderedMarkdownLocalSourceReason]
}

struct RenderedMarkdownLink: Equatable, Sendable {
    /// Complete `[text](target)` source range.
    let sourceRange: RenderedMarkdownSourceRange
    /// Visible link text. Command-click activation is intentionally limited to this range.
    let textRange: RenderedMarkdownSourceRange
    /// Literal destination within the Markdown source, excluding optional angle brackets.
    let targetRange: RenderedMarkdownSourceRange
    /// The exact, conservatively accepted destination text from `targetRange`.
    let target: String
}

struct RenderedMarkdownImage: Equatable, Sendable {
    /// Complete `![alternative](target)` source range.
    let sourceRange: RenderedMarkdownSourceRange
    let alternativeRange: RenderedMarkdownSourceRange
    /// Inline targets carry their exact range. Resolved reference-style targets use
    /// a zero-length range at the end of the visible alternative text.
    let targetRange: RenderedMarkdownSourceRange
    let alternative: String
    let target: String
}

enum RenderedMarkdownTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

struct RenderedMarkdownTableCellLink: Equatable, Sendable {
    let visibleRange: NSRange
    let target: String
}

struct RenderedMarkdownTableCell: Equatable, Sendable {
    let sourceRange: RenderedMarkdownSourceRange
    /// Exact Markdown inside the cell, excluding surrounding whitespace and pipes.
    let markdown: String
    let text: String
    let links: [RenderedMarkdownTableCellLink]
}

struct RenderedMarkdownTable: Equatable, Sendable {
    let sourceRange: RenderedMarkdownSourceRange
    let alignments: [RenderedMarkdownTableAlignment]
    let rows: [[RenderedMarkdownTableCell]]
}

/// Strategy object for translating semantic table content into native editor widths.
/// Markdown parsing stays in Rust; this policy owns only platform typography and the
/// currently available viewport width.
protocol RenderedMarkdownTableLayoutStrategy {
    func columnWidths(
        for table: RenderedMarkdownTable,
        font: NSFont,
        availableWidth: CGFloat
    ) -> [CGFloat]
}

struct AdaptiveRenderedMarkdownTableLayoutStrategy: RenderedMarkdownTableLayoutStrategy {
    let minimumColumnWidth: CGFloat = 56
    let minimumPreferredWidth: CGFloat = 72
    let maximumPreferredWidth: CGFloat = 360
    let horizontalCellPadding = MarkdownRenderMetrics.tableCellHorizontalPadding * 2

    func columnWidths(
        for table: RenderedMarkdownTable,
        font: NSFont,
        availableWidth: CGFloat
    ) -> [CGFloat] {
        let columnCount = table.rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return [] }
        var widths = Array(repeating: minimumPreferredWidth, count: columnCount)
        for row in table.rows {
            for (column, cell) in row.enumerated() {
                let measured = (cell.text as NSString).size(withAttributes: [.font: font]).width
                    + horizontalCellPadding
                widths[column] = max(
                    widths[column],
                    min(maximumPreferredWidth, ceil(measured))
                )
            }
        }

        let target = max(1, availableWidth)
        let preferredTotal = widths.reduce(0, +)
        guard preferredTotal > 0 else { return widths }
        if preferredTotal < target {
            let extra = (target - preferredTotal) / CGFloat(columnCount)
            return widths.map { $0 + extra }
        }
        if preferredTotal > target {
            let fittedMinimum = min(minimumColumnWidth, target / CGFloat(columnCount))
            let flexible = widths.map { max(0, $0 - fittedMinimum) }
            let flexibleTotal = flexible.reduce(0, +)
            let remaining = max(0, target - fittedMinimum * CGFloat(columnCount))
            guard flexibleTotal > 0 else {
                return Array(repeating: target / CGFloat(columnCount), count: columnCount)
            }
            return flexible.map { fittedMinimum + remaining * ($0 / flexibleTotal) }
        }
        return widths
    }
}

enum RenderedMarkdownTableEdit: Equatable, Sendable {
    case updateCell(row: Int, column: Int, text: String)
    case insertRow(at: Int)
    case deleteRow(Int)
    case insertColumn(at: Int)
    case deleteColumn(Int)
    case setAlignment(column: Int, alignment: RenderedMarkdownTableAlignment)
}

enum RenderedMarkdownTableEditing {
    static func replacement(
        for table: RenderedMarkdownTable,
        applying edit: RenderedMarkdownTableEdit
    ) -> String? {
        guard !table.rows.isEmpty else { return nil }
        let columnCount = max(
            table.alignments.count,
            table.rows.map(\.count).max() ?? 0
        )
        guard columnCount > 0 else { return nil }
        var rows = table.rows.map { row in
            (0..<columnCount).map { index in index < row.count ? row[index].markdown : "" }
        }
        var alignments = (0..<columnCount).map { index in
            index < table.alignments.count ? table.alignments[index] : .leading
        }

        switch edit {
        case let .updateCell(row, column, text):
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
            rows[row][column] = escapedCell(text)
        case let .insertRow(index):
            guard (0...rows.count).contains(index) else { return nil }
            rows.insert(Array(repeating: "", count: columnCount), at: index)
        case let .deleteRow(index):
            guard rows.count > 1, rows.indices.contains(index) else { return nil }
            rows.remove(at: index)
        case let .insertColumn(index):
            guard (0...columnCount).contains(index) else { return nil }
            rows = rows.map { row in
                var row = row
                row.insert("", at: index)
                return row
            }
            alignments.insert(.leading, at: index)
        case let .deleteColumn(index):
            guard columnCount > 1, (0..<columnCount).contains(index) else { return nil }
            rows = rows.map { row in
                var row = row
                row.remove(at: index)
                return row
            }
            alignments.remove(at: index)
        case let .setAlignment(column, alignment):
            guard alignments.indices.contains(column) else { return nil }
            alignments[column] = alignment
        }

        let header = markdownRow(rows[0])
        let delimiter = markdownRow(alignments.map { alignment in
            switch alignment {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        })
        return ([header, delimiter] + rows.dropFirst().map(markdownRow)).joined(separator: "\n")
    }

    private static func markdownRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    private static func escapedCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

struct RenderedMarkdownMermaidDiagram: Equatable, Sendable {
    let sourceRange: RenderedMarkdownSourceRange
    /// A parser-generated, script-free SVG. The Markdown source remains the editor's model.
    let svg: String
    let intrinsicWidth: Int
    let intrinsicHeight: Int
    let isPlaceholder: Bool
    var pdfData: Data? = nil
}

/// A display-only interpretation of one exact Markdown byte snapshot.
///
/// The plan contains semantic replacements, but never a second editable body. Attribute and
/// source ranges always address the original `sourceSnapshot` directly.
struct RenderedMarkdownPlan: Equatable, Sendable {
    let sourceSnapshot: String
    let sourceUTF8: Data
    let markers: [RenderedMarkdownMarker]
    let contentStyles: [RenderedMarkdownContentStyle]
    let localSourceBlocks: [RenderedMarkdownLocalSourceBlock]
    let links: [RenderedMarkdownLink]
    let images: [RenderedMarkdownImage]
    let tables: [RenderedMarkdownTable]
    let mermaidDiagrams: [RenderedMarkdownMermaidDiagram]
    var renderRequests: [JavaScriptRenderRequest] = []

    func exactlyMatches(_ source: String) -> Bool {
        sourceUTF8 == Data(source.utf8)
    }

    func hasSameNonMermaidProjection(as other: Self) -> Bool {
        sourceUTF8 == other.sourceUTF8
            && markers == other.markers
            && contentStyles == other.contentStyles
            && localSourceBlocks == other.localSourceBlocks
            && links == other.links
            && images == other.images
            && tables == other.tables
    }

    func resolvingMermaid(
        with resolution: EditorEngineMermaidResolution
    ) -> Self? {
        let placeholders = mermaidDiagrams.filter(\.isPlaceholder)
        guard placeholders.count == mermaidDiagrams.count,
              resolution.diagrams.allSatisfy({ !$0.isPlaceholder })
        else { return nil }

        let expected = placeholders.map(\.sourceRange.utf8Range).sorted(by: rangeOrder)
        let received = (
            resolution.diagrams.map(\.sourceRange.utf8Range)
                + resolution.failedSourceRanges.map(\.utf8Range)
        ).sorted(by: rangeOrder)
        guard expected == received else { return nil }

        var resolvedLocals = localSourceBlocks
        for failed in resolution.failedSourceRanges {
            if let index = resolvedLocals.firstIndex(where: {
                $0.sourceRange.utf8Range == failed.utf8Range
            }) {
                var reasons = Set(resolvedLocals[index].reasons)
                reasons.insert(.mermaid)
                resolvedLocals[index] = RenderedMarkdownLocalSourceBlock(
                    sourceRange: resolvedLocals[index].sourceRange,
                    reasons: reasons.sorted { $0.rawValue < $1.rawValue }
                )
            } else {
                resolvedLocals.append(
                    RenderedMarkdownLocalSourceBlock(
                        sourceRange: failed,
                        reasons: [.mermaid]
                    )
                )
            }
        }
        resolvedLocals.sort {
            rangeOrder($0.sourceRange.utf8Range, $1.sourceRange.utf8Range)
        }

        return Self(
            sourceSnapshot: sourceSnapshot,
            sourceUTF8: sourceUTF8,
            markers: markers,
            contentStyles: contentStyles,
            localSourceBlocks: resolvedLocals,
            links: links,
            images: images,
            tables: tables,
            mermaidDiagrams: resolution.diagrams.sorted {
                rangeOrder($0.sourceRange.utf8Range, $1.sourceRange.utf8Range)
            },
            renderRequests: renderRequests
        )
    }

    private func rangeOrder(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        lhs.lowerBound == rhs.lowerBound
            ? lhs.upperBound < rhs.upperBound
            : lhs.lowerBound < rhs.lowerBound
    }
}

enum RenderedMarkdownRefreshDecision: Equatable, Sendable {
    /// Keep the attributes already mounted on the text view. In particular, do not rebuild
    /// the current block while an input method owns marked text.
    case keepCurrentPresentation
    case apply(RenderedMarkdownPlan)
}

enum RenderedMarkdownEditor {
    /// Creates an isolated Engine only for synchronous tooling and unit-test callers.
    /// Production sessions consume the revision-bound plan returned by their existing Engine.
    static func plan(for source: String) -> RenderedMarkdownPlan {
        EditorEngineDerivedContent.deriveSynchronously(source: source)?.nativeRenderPlan
            ?? parserFailurePlan(for: source)
    }

    /// Gives an `NSTextView` host an explicit IME-safe refresh decision.
    static func refreshDecision(
        for source: String,
        hasMarkedText: Bool
    ) -> RenderedMarkdownRefreshDecision {
        guard !hasMarkedText else { return .keepCurrentPresentation }
        return .apply(plan(for: source))
    }

    /// Resolves a normal reading-mode click on visible link text. The source plan must still be
    /// byte-for-byte current; scheme and project-boundary policy remains with navigation.
    static func clickTarget(
        atUTF16Location location: Int,
        currentSource: String,
        plan: RenderedMarkdownPlan
    ) -> RenderedMarkdownLink? {
        guard location >= 0,
              plan.exactlyMatches(currentSource)
        else {
            return nil
        }

        return plan.links.first { link in
            let range = link.textRange.utf16Range
            return location >= range.location && location < NSMaxRange(range)
        }
    }

    /// Resolves a block whose structure cannot be edited safely through its
    /// rendered appearance. Ordinary prose and tables deliberately return nil:
    /// their caret keeps the same font, baseline, and layout used while reading.
    static func sourceEditingBlockRange(
        containingUTF16Location location: Int,
        source: String,
        plan: RenderedMarkdownPlan
    ) -> NSRange? {
        let sourceLength = (source as NSString).length
        guard location >= 0, location <= sourceLength, !source.isEmpty else { return nil }

        let replacementRanges = plan.localSourceBlocks.map(\.sourceRange.utf16Range)
            + plan.mermaidDiagrams.map(\.sourceRange.utf16Range)
            + plan.renderRequests.filter { $0.kind == "math" }.map(\.sourceRange.utf16Range)
            + plan.markers.compactMap { marker in
                marker.replacementText != nil || marker.kind == .rule
                    ? marker.sourceRange.utf16Range
                    : nil
            }
        if let replacement = replacementRanges.first(where: {
            containsCaret(location, in: $0, sourceLength: sourceLength)
        }) {
            return replacement
        }
        return nil
    }

    private static func containsCaret(
        _ location: Int,
        in range: NSRange,
        sourceLength: Int
    ) -> Bool {
        location >= range.location
            && (location < NSMaxRange(range)
                || (location == sourceLength && location == NSMaxRange(range)))
    }

    private static func parserFailurePlan(for source: String) -> RenderedMarkdownPlan {
        let utf8 = Data(source.utf8)
        let localSourceBlocks: [RenderedMarkdownLocalSourceBlock]
        if source.isEmpty {
            localSourceBlocks = []
        } else {
            localSourceBlocks = [
                RenderedMarkdownLocalSourceBlock(
                    sourceRange: RenderedMarkdownSourceRange(
                        utf8Range: 0..<utf8.count,
                        utf16Range: NSRange(location: 0, length: source.utf16.count)
                    ),
                    reasons: [.parserFailure]
                ),
            ]
        }
        return RenderedMarkdownPlan(
            sourceSnapshot: source,
            sourceUTF8: utf8,
            markers: [],
            contentStyles: [],
            localSourceBlocks: localSourceBlocks,
            links: [],
            images: [],
            tables: [],
            mermaidDiagrams: []
        )
    }
}

/// A single source transaction produced by a writing gesture. Offsets are UTF-16.
struct MarkdownWritingEdit: Equatable {
    let range: NSRange
    let text: String
    let selection: NSRange
}

enum MarkdownWritingAction { case newline, backwardDelete, indent, outdent }

/// Lexical editing rules, not a Markdown renderer. The caller excludes code,
/// formulas and unsupported blocks using the authoritative render plan.
enum MarkdownWritingRules {
    private static let prefix = try! NSRegularExpression(
        pattern: #"^( *)((?:> ?)*)(?:([-+*]|\d{1,9}[.)]|#{1,6}) +(\[[ xX]\] +)?)?"#
    )

    static func edit(_ action: MarkdownWritingAction, source: String, selection: NSRange) -> MarkdownWritingEdit? {
        let source = source as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        if selection.length > 0 {
            guard action == .indent || action == .outdent else { return nil }
            // Exclude a following line when a selection ends exactly at its start.
            let range = source.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
            let original = source.substring(with: range) as NSString
            var edits: [MarkdownWritingEdit] = []
            var offset = 0
            while offset < original.length {
                let line = original.lineRange(for: NSRange(location: offset, length: 0))
                if let change = edit(action, source: original.substring(with: line), selection: NSRange(location: 0, length: 0)) {
                    edits.append(MarkdownWritingEdit(range: NSRange(location: offset + change.range.location, length: change.range.length),
                        text: change.text, selection: change.selection))
                }
                offset = NSMaxRange(line)
            }
            guard !edits.isEmpty else { return nil }
            let changed = NSMutableString(string: original)
            for change in edits.reversed() { changed.replaceCharacters(in: change.range, with: change.text) }
            return MarkdownWritingEdit(range: range, text: changed as String,
                selection: NSRange(location: range.location, length: changed.length))
        }
        let line = source.lineRange(for: selection)
        let raw = source.substring(with: line) as NSString
        let body = (raw as String).trimmingCharacters(in: .newlines)
        let offset = selection.location - line.location
        guard let match = prefix.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { return nil }
        guard match.range.length > 0, match.range(at: 2).length > 0 || match.range(at: 3).location != NSNotFound else { return nil }
        let head = raw.substring(with: match.range)
        let indent = raw.substring(with: match.range(at: 1))
        let tail = (body as NSString).substring(from: match.range.length)
        func replacing(_ range: NSRange, _ text: String, caret: Int? = nil) -> MarkdownWritingEdit {
            MarkdownWritingEdit(range: range, text: text, selection: NSRange(location: caret ?? (range.location + text.utf16.count), length: 0))
        }
        switch action {
        case .newline:
            if match.range(at: 3).location != NSNotFound,
               raw.substring(with: match.range(at: 3)).hasPrefix("#") { return nil }
            guard offset >= match.range.length else { return nil }
            if tail.trimmingCharacters(in: .whitespaces).isEmpty {
                // Remove one nesting level at a time, preserving outer quotes.
                if match.range(at: 3).location != NSNotFound {
                    let start = match.range(at: 3).location
                    return replacing(NSRange(location: line.location + start, length: match.range.length - start), "")
                }
                if let last = head.lastIndex(of: ">") {
                    return replacing(NSRange(location: line.location + head[..<last].utf16.count, length: head[last...].utf16.count), "")
                }
                return replacing(NSRange(location: line.location, length: match.range.length), "")
            }
            var next = head
            if match.range(at: 3).location != NSNotFound {
                let marker = raw.substring(with: match.range(at: 3))
                if let number = Int(marker.dropLast()), let suffix = marker.last {
                    let replacement = String(number + 1) + String(suffix)
                    next = (next as NSString).replacingCharacters(in: match.range(at: 3), with: replacement)
                }
                next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
            }
            let newline = (raw as String).hasSuffix("\r\n") ? "\r\n" : "\n"
            return replacing(selection, newline + next)
        case .backwardDelete:
            guard offset == match.range.length else { return nil }
            if !indent.isEmpty {
                let count = min(2, indent.utf16.count)
                return replacing(NSRange(location: line.location, length: count), "", caret: selection.location - count)
            }
            if match.range(at: 3).location != NSNotFound {
                let start = match.range(at: 3).location
                return replacing(NSRange(location: line.location + start, length: match.range.length - start), "")
            }
            if let last = head.lastIndex(of: ">") {
                let start = line.location + head[..<last].utf16.count
                return replacing(NSRange(location: start, length: head[last...].utf16.count), "")
            }
            return replacing(NSRange(location: line.location, length: match.range.length), "")
        case .indent:
            guard match.range(at: 3).location != NSNotFound,
                  !raw.substring(with: match.range(at: 3)).hasPrefix("#") else { return nil }
            return replacing(NSRange(location: line.location, length: 0), "  ", caret: selection.location + 2)
        case .outdent:
            guard match.range(at: 3).location != NSNotFound, !indent.isEmpty,
                  !raw.substring(with: match.range(at: 3)).hasPrefix("#") else { return nil }
            let count = min(2, indent.utf16.count)
            return replacing(NSRange(location: line.location, length: count), "", caret: selection.location - min(offset, count))
        }
    }

    static func pair(_ input: String, source: String, selection: NSRange) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard NSMaxRange(selection) <= text.length,
              let closing = ["(": ")", "[": "]", "{": "}", "`": "`", "*": "*", "_": "_", "~": "~"][input]
        else { return nil }
        if selection.location > 0, text.substring(with: NSRange(location: selection.location - 1, length: 1)) == "\\" { return nil }
        let selected = text.substring(with: selection)
        if selection.length == 0 {
            if ["*", "_", "~"].contains(input) { return nil }
            // Avoid changing words, list markers and existing closing delimiters.
            let before = selection.location == 0 ? "" : text.substring(to: selection.location)
            if input == "`", before.split(separator: "\n", omittingEmptySubsequences: false).last?.trimmingCharacters(in: .whitespaces) == "``" { return nil }
            if ["*", "_", "~"].contains(input), before.last?.isLetter == true { return nil }
            if selection.location < text.length {
                let next = text.substring(from: selection.location).first
                if next?.isLetter == true || next?.isNumber == true { return nil }
            }
        }
        let opening = input == "~" ? "~~" : input
        let ending = input == "~" ? "~~" : closing
        return MarkdownWritingEdit(range: selection, text: opening + selected + ending,
            selection: NSRange(location: selection.location + opening.utf16.count, length: selection.length))
    }

    static func revealedMarkers(plan: RenderedMarkdownPlan, selection: NSRange) -> [NSRange] {
        func touches(_ range: NSRange) -> Bool {
            selection.length == 0
                ? selection.location >= range.location && selection.location <= NSMaxRange(range)
                : NSIntersectionRange(selection, range).length > 0
        }
        var result: [NSRange] = []
        for style in plan.contentStyles {
            let kind: RenderedMarkdownMarkerKind
            switch style.kind {
            case .strong: kind = .strong
            case .emphasis: kind = .emphasis
            case .strikethrough: kind = .strikethrough
            case .inlineCode: kind = .inlineCode
            default: continue
            }
            let content = style.sourceRange.utf16Range
            let adjacent = plan.markers.filter {
                $0.kind == kind && (NSMaxRange($0.sourceRange.utf16Range) == content.location
                    || $0.sourceRange.utf16Range.location == NSMaxRange(content))
            }.map(\.sourceRange.utf16Range)
            let full = adjacent.reduce(content) { NSUnionRange($0, $1) }
            if touches(full) { result += adjacent }
        }
        for link in plan.links where touches(link.sourceRange.utf16Range) {
            result += plan.markers.filter {
                ($0.kind == .linkDelimiter || $0.kind == .linkDestination)
                    && NSIntersectionRange($0.sourceRange.utf16Range, link.sourceRange.utf16Range).length > 0
            }.map(\.sourceRange.utf16Range)
        }
        return result
    }
}
