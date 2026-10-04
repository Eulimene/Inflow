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
    var contextualElement: String? = nil
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
@MainActor
protocol RenderedMarkdownTableLayoutStrategy {
    func columnWidths(
        for table: RenderedMarkdownTable,
        font: NSFont,
        availableWidth: CGFloat
    ) -> [CGFloat]
}

struct AdaptiveRenderedMarkdownTableLayoutStrategy: RenderedMarkdownTableLayoutStrategy {
    var horizontalCellPadding: CGFloat = CGFloat(MarkdownRenderMetrics.tableCellHorizontalPadding * 2)

    func columnWidths(for table: RenderedMarkdownTable, font: NSFont, availableWidth: CGFloat) -> [CGFloat] {
        let count = table.rows.map(\.count).max() ?? 0
        guard count > 0 else { return [] }
        var measurements = Array(repeating: 0.0, count: count)
        for (index, row) in table.rows.enumerated() {
            let cellFont = index == 0 ? NativeCSSStyles.font(font, bold: true) : font
            for (column, cell) in row.enumerated() {
                measurements[column] = max(measurements[column], Double((cell.text as NSString).size(withAttributes: [.font: cellFont]).width))
            }
        }
        // One batch of native font measurements; Rust owns column allocation.
        return (try? EditorEnginePresentation.layoutTable(CoreTableMeasurements(
            columns: measurements, availableWidth: Double(availableWidth),
            horizontalPadding: Double(horizontalCellPadding))))?.map { CGFloat($0) }
            // Preserve safe cell geometry if the core cannot provide a plan.
            // This is the host measurement, not a second allocation algorithm.
            ?? measurements.map { CGFloat(max(1, $0)) }
    }

}

enum RenderedMarkdownTableEdit: Equatable, Sendable {
    case resize(rows: Int, columns: Int)
    case deleteTable
    case updateCell(row: Int, column: Int, text: String)
    case updateCells(row: Int, column: Int, texts: [[String]])
    case insertRow(at: Int)
    case deleteRow(Int)
    case insertColumn(at: Int)
    case deleteColumn(Int)
    case setAlignment(column: Int, alignment: RenderedMarkdownTableAlignment)
}

enum RenderedMarkdownTableEditing {
    static func isValidSize(rows: Int, columns: Int) -> Bool {
        (1...1_000).contains(rows) && (1...100).contains(columns) && rows * columns <= 10_000
    }

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
        case .deleteTable: return ""
        case let .resize(rowCount, columns):
            guard isValidSize(rows: rowCount, columns: columns) else { return nil }
            rows = (0..<rowCount).map { row in
                (0..<columns).map { column in
                    row < table.rows.count && column < table.rows[row].count ? table.rows[row][column].markdown : ""
                }
            }
            alignments = (0..<columns).map { $0 < table.alignments.count ? table.alignments[$0] : .leading }
        case let .updateCell(row, column, text):
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
            let cell = table.rows[row][column]
            if cell.text == text { break }
            if text.isEmpty { rows[row][column] = ""; break }
            let projection = MarkdownInlineProjection(cell.markdown)
            if projection.text == cell.text,
               let change = EditorEngineTextDiff.replacement(from: cell.text, to: text),
               let visible = MarkdownSourceRange.navigationTarget(forUTF8Range: change.start..<change.end, in: cell.text),
               let target = projection.sourceRange(for: visible.revealRange) {
                let candidate = (cell.markdown as NSString).replacingCharacters(in: target, with: escapedCell(change.inserted, trim: false))
                // A replacement spanning delimiter pairs can orphan a wrapper.
                // Keep a valid, exact visible value instead of writing malformed Markdown.
                let rendered = RenderedMarkdownEditor.plan(for: "| Value |\n| --- |\n| " + candidate + " |").tables.first?.rows.last?.first?.text
                rows[row][column] = rendered == text ? candidate : escapedCell(text)
            } else {
                rows[row][column] = escapedCell(text)
            }
        case let .updateCells(row, column, texts):
            guard row >= 0, column >= 0, !texts.isEmpty,
                  texts.allSatisfy({ !$0.isEmpty }), row <= rows.count, column < columnCount else { return nil }
            let newColumnCount = max(columnCount, column + (texts.map(\.count).max() ?? 0))
            if newColumnCount > columnCount {
                rows = rows.map { $0 + Array(repeating: "", count: newColumnCount - columnCount) }
                alignments += Array(repeating: .leading, count: newColumnCount - columnCount)
            }
            while rows.count < row + texts.count { rows.append(Array(repeating: "", count: newColumnCount)) }
            for (r, values) in texts.enumerated() {
                for (c, value) in values.enumerated() {
                    rows[row + r][column + c] = escapedCell(value)
                }
            }
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

    private static func escapedCell(_ text: String, trim: Bool = true) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
        return trim ? escaped.trimmingCharacters(in: .whitespaces) : escaped
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
    /// Complete top-level blocks from the canonical parser, in TextKit coordinates.
    /// Nested paragraphs/items remain inside their owning quote/list/code block.
    var blockSpacingBoundaries: [NSRange] = []

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
            && blockSpacingBoundaries == other.blockSpacingBoundaries
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
            renderRequests: renderRequests,
            blockSpacingBoundaries: blockSpacingBoundaries
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
    /// Isolated native layout derivation for tooling and explicit structural edits.
    /// Sessions cache this result; ordinary document derivation uses their Engine.
    static func plan(for source: String, configuration: PreviewAppearanceConfiguration = .default) -> RenderedMarkdownPlan {
        EditorEngineDerivedContent.deriveSynchronously(source: source, configuration: configuration, includeHTML: false)?.nativeRenderPlan
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

        // Ordinary fenced code remains rendered while editing its body. Only
        // the language/fence lines need the literal-source presentation.
        let bodyCode = plan.renderRequests.first {
            $0.kind == "code" && containsCaret(location, in: $0.contentRange.utf16Range, sourceLength: sourceLength)
        }
        let replacementRanges = plan.localSourceBlocks.filter {
            !($0.reasons == [.fencedCode] && $0.sourceRange == bodyCode?.sourceRange)
        }.map(\.sourceRange.utf16Range)
            + plan.mermaidDiagrams.map(\.sourceRange.utf16Range)
            + plan.renderRequests.filter { $0.kind == "math" }.map(\.sourceRange.utf16Range)
            + plan.markers.compactMap { marker in
                marker.kind == .rule
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

/// Attribute projection is computed off-screen. Only changed runs invalidate TextKit layout.
enum RenderedAttributePatch {
    @discardableResult
    static func apply(_ projection: NSAttributedString, to storage: NSTextStorage) -> [NSRange] {
        guard UTF8Text.isExactlyEqual(projection.string, storage.string) else { return [] }
        var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
        var offset = 0
        while offset < storage.length {
            var oldRange = NSRange(), newRange = NSRange()
            let old = storage.attributes(at: offset, effectiveRange: &oldRange)
            let new = projection.attributes(at: offset, effectiveRange: &newRange)
            let end = min(NSMaxRange(oldRange), NSMaxRange(newRange))
            let range = NSRange(location: offset, length: end - offset)
            if !NSDictionary(dictionary: old).isEqual(to: new) { changes.append((range, new)) }
            offset = end
        }
        storage.beginEditing()
        for (range, attributes) in changes { storage.setAttributes(attributes, range: range) }
        storage.endEditing()
        return changes.map(\.0)
    }
}

@MainActor
extension RenderedMarkdownMarker {
    func displayText(styles: NativeCSSStyles) -> String? {
        if kind == .unorderedList, styles.value("list-style-type", on: "ul") == "square" { return "▪" }
        return replacementText
    }
}
