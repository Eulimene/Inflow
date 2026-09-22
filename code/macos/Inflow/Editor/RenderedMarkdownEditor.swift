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
    case updateCells(row: Int, column: Int, texts: [[String]])
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
            let cell = table.rows[row][column]
            if cell.text == text { break }
            let projection = MarkdownInlineProjection(cell.markdown)
            if projection.text == cell.text,
               let change = EditorEngineTextDiff.replacement(from: cell.text, to: text),
               let visible = MarkdownSourceRange.navigationTarget(forUTF8Range: change.start..<change.end, in: cell.text),
               let target = projection.sourceRange(for: visible.revealRange) {
                rows[row][column] = (cell.markdown as NSString).replacingCharacters(in: target, with: escapedCell(change.inserted, trim: false))
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

/// Clipboard HTML is parsed as inert data. No WebView, script, stylesheet or
/// external entity participates in converting a paste into Markdown.
enum MarkdownClipboardCodec {
    static func markdown(fromHTML html: String) -> String? {
        let inert = html.replacingOccurrences(of: #"(?is)<!DOCTYPE\s+html\s*>"#, with: "", options: .regularExpression)
        guard html.utf8.count <= 1_000_000,
              !inert.localizedCaseInsensitiveContains("<!ENTITY"),
              !inert.localizedCaseInsensitiveContains("<!DOCTYPE"),
              let document = try? XMLDocument(xmlString: inert, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { return nil }
        return render(root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escaped(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_[]~".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func target(_ text: String?) -> String? {
        guard let text, !text.isEmpty, !text.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else { return nil }
        if let scheme = URL(string: text)?.scheme?.lowercased(), !["https", "http", "file", "mailto"].contains(scheme) { return nil }
        return "<" + text.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
    }

    private static func render(_ node: XMLNode, depth: Int = 0) -> String {
        guard depth < 64 else { return escaped(node.stringValue ?? "") }
        if node.kind == .text {
            return escaped((node.stringValue ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
        }
        guard let element = node as? XMLElement else { return "" }
        let name = (element.name ?? "").lowercased()
        if ["head", "script", "style", "iframe", "object", "embed", "form", "input", "noscript"].contains(name) { return "" }
        let children = element.children ?? []
        let content = children.map { render($0, depth: depth + 1) }.joined()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "p", "div", "section", "article": return trimmed.isEmpty ? "" : trimmed + "\n\n"
        case "br": return "\n"
        case "strong", "b": return trimmed.isEmpty ? content : "**" + trimmed + "**"
        case "em", "i": return trimmed.isEmpty ? content : "*" + trimmed + "*"
        case "del", "s", "strike": return trimmed.isEmpty ? content : "~~" + trimmed + "~~"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return String(repeating: "#", count: Int(name.suffix(1)) ?? 1) + " " + trimmed + "\n\n"
        case "blockquote": return trimmed.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "ul", "ol":
            return children.compactMap { $0 as? XMLElement }.filter { $0.name?.lowercased() == "li" }.enumerated().map { index, item in
                let body = render(item, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                let marker = name == "ol" ? "\(index + 1). " : "- "
                return marker + body.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: marker.count))
            }.joined(separator: "\n") + "\n\n"
        case "pre":
            let code = (element.stringValue ?? "").trimmingCharacters(in: .newlines)
            let fence = String(repeating: "`", count: max(3, code.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 3))
            return fence + "\n" + code + "\n" + fence + "\n\n"
        case "code":
            let code = (element.stringValue ?? "").replacingOccurrences(of: "\n", with: " ")
            let fence = String(repeating: "`", count: max(1, code.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 1))
            return fence + " " + code + " " + fence
        case "a":
            guard let url = target(element.attribute(forName: "href")?.stringValue) else { return content }
            return "[" + trimmed + "](" + url + ")"
        case "img":
            let alt = escaped(element.attribute(forName: "alt")?.stringValue ?? "图片")
            guard let url = target(element.attribute(forName: "src")?.stringValue) else { return alt }
            return "![" + alt + "](" + url + ")"
        case "table":
            let rows = ((try? element.nodes(forXPath: ".//tr")) ?? []).compactMap { $0 as? XMLElement }.map { row in
                (row.children ?? []).compactMap { $0 as? XMLElement }.filter { ["th", "td"].contains($0.name?.lowercased() ?? "") }.map {
                    render($0, depth: depth + 1).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
                }
            }.filter { !$0.isEmpty }
            guard let first = rows.first else { return content }
            let count = rows.map(\.count).max() ?? first.count
            func row(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: count - cells.count)).joined(separator: " | ") + " |" }
            return ([row(first), row(Array(repeating: "---", count: count))] + rows.dropFirst().map(row)).joined(separator: "\n") + "\n\n"
        default: return content
        }
    }
}

/// Interpret a gesture before touching TextKit. The resulting source and selection
/// are committed together, so rendering never decides where an edit should land.
enum MarkdownEditingIntent { case paragraphBreak, lineBreak, mergeBackward }

enum MarkdownEditingTransaction {
    static func plan(_ intent: MarkdownEditingIntent, source: String, selection: NSRange,
                     renderPlan: RenderedMarkdownPlan) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let raw = text.substring(with: line).trimmingCharacters(in: .newlines)
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        func replace(_ range: NSRange, _ value: String, caret: Int? = nil) -> MarkdownWritingEdit {
            MarkdownWritingEdit(range: range, text: value,
                selection: NSRange(location: caret ?? range.location + value.utf16.count, length: 0))
        }
        let request = renderPlan.renderRequests.first {
            selection.location >= $0.sourceRange.utf16Range.location
                && selection.location < NSMaxRange($0.sourceRange.utf16Range)
        }
        let protected = renderPlan.localSourceBlocks.contains {
            selection.location >= $0.sourceRange.utf16Range.location
                && selection.location < NSMaxRange($0.sourceRange.utf16Range)
        }
        if intent != .mergeBackward {
            // Complete a newly typed fence in a single undoable transaction.
            if intent == .paragraphBreak, selection.length == 0, before == raw,
               let match = raw.range(of: #"^(`{3,}|~{3,})[A-Za-z0-9_+.#-]*$"#, options: .regularExpression),
               match == raw.startIndex..<raw.endIndex,
               !renderPlan.renderRequests.contains(where: {
                   $0.sourceRange.utf16Range.location < line.location && NSMaxRange($0.sourceRange.utf16Range) >= line.location
               }),
               request == nil || request?.contentRange.utf16Range.length == 0 {
                let fence = String(raw.prefix { $0 == raw.first! })
                return replace(selection, newline + newline + fence, caret: selection.location + newline.utf16.count)
            }
            if intent == .paragraphBreak, selection.length == 0, raw == "$$", before == raw, request == nil {
                return replace(selection, newline + newline + "$$", caret: selection.location + newline.utf16.count)
            }
            if request != nil || protected {
                return replace(selection, newline + String(before.prefix { $0 == " " || $0 == "\t" }))
            }
            let head = prefix(raw)
            if intent == .lineBreak {
                // A continuation belongs to the same quote/list item. Do not copy
                // its bullet or task marker and accidentally create another item.
                let continuation = head.quote + (head.list.isEmpty ? head.indent : head.indent + String(repeating: " ", count: listContentIndent(head.list)))
                return replace(selection, newline + continuation)
            }
            if !head.list.isEmpty {
                let headLength = (head.quote + head.indent + head.list).utf16.count
                let tail = (raw as NSString).substring(from: headLength)
                if selection.length == 0, tail.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !head.indent.isEmpty {
                        return replace(NSRange(location: line.location + head.quote.utf16.count,
                            length: min(2, head.indent.utf16.count)), "", caret: max(line.location, selection.location - min(2, head.indent.utf16.count)))
                    }
                    return replace(NSRange(location: line.location + head.quote.utf16.count, length: head.list.utf16.count), "")
                }
                return replace(selection, newline + head.quote + head.indent + nextListMarker(head.list))
            }
            if let continuation = listContinuation(at: line.location, source: source, plan: renderPlan),
               head.quote == continuation.quote, head.indent.utf16.count >= continuation.width {
                return replace(selection, newline + continuation.quote + continuation.indent + nextListMarker(continuation.list))
            }
            if selection.length == 0,
               let structural = MarkdownWritingRules.edit(.newline, source: source, selection: selection) {
                if !head.list.isEmpty || raw.trimmingCharacters(in: .whitespaces) == head.quote.trimmingCharacters(in: .whitespaces) {
                    return structural
                }
            }
            if !head.quote.isEmpty {
                return replace(selection, newline + head.quote.trimmingCharacters(in: .whitespaces) + newline + head.quote + head.indent)
            }
            return replace(selection, raw.trimmingCharacters(in: .whitespaces).isEmpty ? newline : newline + newline)
        }
        guard selection.length == 0, request == nil, !protected else { return nil }
        let head = prefix(raw)
        if !head.list.isEmpty, selection.location == line.location + (head.quote + head.indent + head.list).utf16.count {
            if !head.indent.isEmpty {
                let count = min(2, head.indent.utf16.count)
                return replace(NSRange(location: line.location + head.quote.utf16.count, length: count), "", caret: selection.location - count)
            }
            return replace(NSRange(location: line.location + head.quote.utf16.count, length: head.list.utf16.count), "")
        }
        if let structural = MarkdownWritingRules.edit(.backwardDelete, source: source, selection: selection) { return structural }
        if selection.location == line.location, selection.location >= newline.utf16.count * 2 {
            let range = NSRange(location: selection.location - newline.utf16.count * 2, length: newline.utf16.count * 2)
            if text.substring(with: range) == newline + newline {
                return replace(range, "")
            }
        }
        return nil
    }

    private static func listContentIndent(_ marker: String) -> Int {
        marker.firstIndex(of: "[").map { marker[..<$0].utf16.count } ?? marker.utf16.count
    }

    private static func nextListMarker(_ marker: String) -> String {
        var result = marker.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        if let range = result.range(of: #"^\d{1,9}"#, options: .regularExpression), let value = Int(result[range]) {
            result.replaceSubrange(range, with: String(value + 1))
        }
        return result
    }

    private static func listContinuation(at location: Int, source: String, plan: RenderedMarkdownPlan)
        -> (quote: String, indent: String, list: String, width: Int)? {
        let text = source as NSString
        guard let marker = plan.markers.last(where: {
            ($0.kind == .unorderedList || $0.kind == .orderedList) && $0.sourceRange.utf16Range.location < location
        }) else { return nil }
        let firstLine = text.lineRange(for: NSRange(location: marker.sourceRange.utf16Range.location, length: 0))
        guard firstLine.location < location else { return nil }
        let head = prefix(text.substring(with: firstLine))
        guard !head.list.isEmpty else { return nil }
        let width = head.indent.utf16.count + listContentIndent(head.list)
        var offset = NSMaxRange(firstLine)
        while offset < location {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let value = text.substring(with: line)
            let next = prefix(value)
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               next.quote != head.quote || next.indent.utf16.count < width || !next.list.isEmpty { return nil }
            offset = NSMaxRange(line)
        }
        return (head.quote, head.indent, head.list, width)
    }

    static func indentList(source: String, selection: NSRange, backwards: Bool) -> MarkdownWritingEdit? {
        let text = source as NSString
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let first = text.lineRange(for: selection)
        let head = prefix(text.substring(with: first))
        guard !head.list.isEmpty, !backwards || !head.indent.isEmpty else { return nil }
        let count = backwards ? min(2, head.indent.utf16.count) : 2
        var end = NSMaxRange(first)
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            let value = text.substring(with: next)
            let nested = prefix(value)
            guard nested.quote == head.quote, nested.indent.count > head.indent.count else { break }
            end = NSMaxRange(next)
        }
        let range = NSRange(location: first.location, length: end - first.location)
        let result = NSMutableString(string: text.substring(with: range))
        var positions: [Int] = []
        var offset = 0
        while offset < result.length {
            let line = result.lineRange(for: NSRange(location: offset, length: 0))
            positions.append(offset + prefix(result.substring(with: line)).quote.utf16.count)
            offset = NSMaxRange(line)
        }
        for position in positions.reversed() {
            result.replaceCharacters(in: NSRange(location: position, length: backwards ? count : 0), with: backwards ? "" : "  ")
        }
        return MarkdownWritingEdit(range: range, text: result as String,
            selection: NSRange(location: max(first.location, selection.location + (backwards ? -count : count)), length: 0))
    }

    private static func prefix(_ line: String) -> (quote: String, indent: String, list: String) {
        let expression = try! NSRegularExpression(pattern: #"^((?: *> ?)*)( *)(?:(?:[-+*]|\d{1,9}[.)]) +(?:\[[ xX]\] +)?)?"#)
        let text = line as NSString
        guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return ("", "", "") }
        let quote = text.substring(with: match.range(at: 1))
        let indent = text.substring(with: match.range(at: 2))
        let listStart = NSMaxRange(match.range(at: 2))
        return (quote, indent, text.substring(with: NSRange(location: listStart, length: NSMaxRange(match.range) - listStart)))
    }
}

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

/// Quoted TSV preserves tabs and line breaks inside cells when copying to spreadsheets.
enum TableClipboard {
    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { value in
                value.contains(where: { "\t\n\r\"".contains($0) })
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> [[String]] {
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], value = ""
        var quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"", quoted {
                if index + 1 < characters.count, characters[index + 1] == "\"" {
                    value.append("\""); index += 1
                } else { quoted = false }
            } else if character == "\"", value.isEmpty { quoted = true }
            else if character == "\t", !quoted { row.append(value); value = "" }
            else if character == "\n", !quoted { row.append(value); rows.append(row); row = []; value = "" }
            else { value.append(character) }
            index += 1
        }
        if !row.isEmpty || !value.isEmpty || rows.isEmpty { row.append(value); rows.append(row) }
        return rows
    }
}
