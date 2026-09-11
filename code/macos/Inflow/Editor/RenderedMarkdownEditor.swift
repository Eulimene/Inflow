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
    case referenceDefinition
    case linkDelimiter
    case linkDestination
}

struct RenderedMarkdownMarker: Equatable, Sendable {
    let kind: RenderedMarkdownMarkerKind
    let sourceRange: RenderedMarkdownSourceRange
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
    case link
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

/// A display-only interpretation of one exact Markdown byte snapshot.
///
/// The plan never contains replacement text or a second rendered body. Attribute and local
/// source ranges always address the original `sourceSnapshot` directly.
struct RenderedMarkdownPlan: Equatable, Sendable {
    let sourceSnapshot: String
    let sourceUTF8: Data
    let markers: [RenderedMarkdownMarker]
    let contentStyles: [RenderedMarkdownContentStyle]
    let localSourceBlocks: [RenderedMarkdownLocalSourceBlock]
    let links: [RenderedMarkdownLink]
    let images: [RenderedMarkdownImage]

    func exactlyMatches(_ source: String) -> Bool {
        sourceUTF8 == Data(source.utf8)
    }
}

enum RenderedMarkdownRefreshDecision: Equatable, Sendable {
    /// Keep the attributes already mounted on the text view. In particular, do not rebuild
    /// the current block while an input method owns marked text.
    case keepCurrentPresentation
    case apply(RenderedMarkdownPlan)
}

enum RenderedMarkdownEditor {
    /// Builds a synchronous, display-only plan using the repository's selected Markdown parser.
    /// Parser failure preserves the complete input as a local-source block.
    static func plan(for source: String) -> RenderedMarkdownPlan {
        do {
            return try RenderedMarkdownPlanner(source: source).makePlan()
        } catch {
            return parserFailurePlan(for: source)
        }
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
            images: []
        )
    }
}

private struct RenderedMarkdownPlanner {
    private struct Line {
        let index: Int
        let fullRange: Range<Int>
        let contentRange: Range<Int>
        let isBlank: Bool
    }

    private struct LocalCandidate {
        var utf8Range: Range<Int>
        var reasons: Set<RenderedMarkdownLocalSourceReason>
    }

    private struct PendingMarker: Equatable {
        let kind: RenderedMarkdownMarkerKind
        let utf8Range: Range<Int>
    }

    private struct PendingStyle: Equatable {
        let kind: RenderedMarkdownContentStyleKind
        let utf8Range: Range<Int>
    }

    private struct PendingLink: Equatable {
        let sourceUTF8Range: Range<Int>
        let textUTF8Range: Range<Int>
        let targetUTF8Range: Range<Int>
        let target: String
        let delimiterRanges: [Range<Int>]
        let hiddenDestinationRange: Range<Int>?
    }

    private struct PendingImage: Equatable {
        let sourceUTF8Range: Range<Int>
        let alternativeUTF8Range: Range<Int>
        let targetUTF8Range: Range<Int>
        let alternative: String
        let target: String
    }

    private enum ParsedLine {
        case blank
        case paragraph(content: Range<Int>)
        case heading(
            level: Int,
            openingMarker: Range<Int>,
            content: Range<Int>,
            closingMarker: Range<Int>?
        )
        case blockQuote(marker: Range<Int>, content: Range<Int>)
        case unorderedList(
            marker: Range<Int>,
            taskMarker: Range<Int>?,
            isChecked: Bool?,
            content: Range<Int>
        )
        case orderedList(marker: Range<Int>, content: Range<Int>)
        case ambiguous
    }

    private enum InlineParts {
        case wrapped(
            openingMarker: Range<Int>,
            content: Range<Int>,
            closingMarker: Range<Int>
        )
        case link(PendingLink)
    }

    private let source: String
    private let sourceUTF8: Data
    private let bytes: [UInt8]
    private let spans: [MarkdownSyntaxSpan]
    private let references: [MarkdownReference]
    private let lines: [Line]
    private let semanticKindsByLine: [Set<UInt8>]
    private let semanticRangesByKind: [UInt8: [Range<Int>]]

    init(source: String) throws {
        let parsedBytes = Array(source.utf8)
        let parsedSpans = try MarkdownHighlighter.spans(in: source)
        let parsedReferences = try MarkdownReferenceScanner.references(in: source)
        let parsedLines = Self.makeLines(bytes: parsedBytes)
        self.source = source
        sourceUTF8 = Data(source.utf8)
        bytes = parsedBytes
        spans = parsedSpans
        references = parsedReferences
        lines = parsedLines
        semanticKindsByLine = Self.makeSemanticKindsByLine(
            lines: parsedLines,
            spans: parsedSpans
        )
        semanticRangesByKind = Dictionary(grouping: parsedSpans, by: { $0.kind.rawValue })
            .mapValues { spans in spans.map(\.utf8Range) }
    }

    func makePlan() throws -> RenderedMarkdownPlan {
        guard !bytes.isEmpty else {
            return RenderedMarkdownPlan(
                sourceSnapshot: source,
                sourceUTF8: sourceUTF8,
                markers: [],
                contentStyles: [],
                localSourceBlocks: [],
                links: [],
                images: []
            )
        }

        var localCandidates = initialLocalSourceCandidates()
        addUnsupportedHeadingCandidates(to: &localCandidates)
        addComplexInlineCandidates(to: &localCandidates)
        addAmbiguousLineCandidates(to: &localCandidates)
        let mergedLocalCandidates = mergeLocalCandidates(localCandidates)

        var pendingMarkers: [PendingMarker] = []
        var pendingStyles: [PendingStyle] = []
        addBlockPresentation(
            excluding: mergedLocalCandidates,
            markers: &pendingMarkers,
            styles: &pendingStyles
        )
        addReferenceDefinitionPresentation(
            excluding: mergedLocalCandidates,
            markers: &pendingMarkers
        )

        var pendingLinks: [PendingLink] = []
        addInlinePresentation(
            excluding: mergedLocalCandidates,
            markers: &pendingMarkers,
            styles: &pendingStyles,
            links: &pendingLinks
        )
        var pendingImages: [PendingImage] = []
        addImagePresentation(
            excluding: mergedLocalCandidates,
            images: &pendingImages
        )

        pendingMarkers = sortedUniqueMarkers(pendingMarkers)
        pendingStyles = sortedUniqueStyles(pendingStyles)
        pendingLinks.sort {
            if $0.sourceUTF8Range.lowerBound != $1.sourceUTF8Range.lowerBound {
                return $0.sourceUTF8Range.lowerBound < $1.sourceUTF8Range.lowerBound
            }
            return $0.sourceUTF8Range.upperBound < $1.sourceUTF8Range.upperBound
        }
        pendingImages.sort {
            if $0.sourceUTF8Range.lowerBound != $1.sourceUTF8Range.lowerBound {
                return $0.sourceUTF8Range.lowerBound < $1.sourceUTF8Range.lowerBound
            }
            return $0.sourceUTF8Range.upperBound < $1.sourceUTF8Range.upperBound
        }

        let requestedOffsets = requestedUTF8Offsets(
            localCandidates: mergedLocalCandidates,
            markers: pendingMarkers,
            styles: pendingStyles,
            links: pendingLinks,
            images: pendingImages
        )
        guard let utf16Offsets = mapUTF8OffsetsToUTF16(requestedOffsets) else {
            throw RenderedMarkdownPlanError.invalidSourceRange
        }

        func mappedRange(_ utf8Range: Range<Int>) throws -> RenderedMarkdownSourceRange {
            guard let lower = utf16Offsets[utf8Range.lowerBound],
                  let upper = utf16Offsets[utf8Range.upperBound]
            else {
                throw RenderedMarkdownPlanError.invalidSourceRange
            }
            return RenderedMarkdownSourceRange(
                utf8Range: utf8Range,
                utf16Range: NSRange(location: lower, length: upper - lower)
            )
        }

        let localSourceBlocks = try mergedLocalCandidates.map { candidate in
            RenderedMarkdownLocalSourceBlock(
                sourceRange: try mappedRange(candidate.utf8Range),
                reasons: candidate.reasons.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let markers = try pendingMarkers.map { marker in
            RenderedMarkdownMarker(
                kind: marker.kind,
                sourceRange: try mappedRange(marker.utf8Range)
            )
        }
        let styles = try pendingStyles.map { style in
            RenderedMarkdownContentStyle(
                kind: style.kind,
                sourceRange: try mappedRange(style.utf8Range)
            )
        }
        let links = try pendingLinks.map { link in
            RenderedMarkdownLink(
                sourceRange: try mappedRange(link.sourceUTF8Range),
                textRange: try mappedRange(link.textUTF8Range),
                targetRange: try mappedRange(link.targetUTF8Range),
                target: link.target
            )
        }
        let images = try pendingImages.map { image in
            RenderedMarkdownImage(
                sourceRange: try mappedRange(image.sourceUTF8Range),
                alternativeRange: try mappedRange(image.alternativeUTF8Range),
                targetRange: try mappedRange(image.targetUTF8Range),
                alternative: image.alternative,
                target: image.target
            )
        }

        return RenderedMarkdownPlan(
            sourceSnapshot: source,
            sourceUTF8: sourceUTF8,
            markers: markers,
            contentStyles: styles,
            localSourceBlocks: localSourceBlocks,
            links: links,
            images: images
        )
    }

    private func initialLocalSourceCandidates() -> [LocalCandidate] {
        var candidates: [LocalCandidate] = []
        for span in spans {
            let range = span.utf8Range
            switch span.kind {
            case .table:
                appendLocal(range, reason: .table, to: &candidates)
            case .image:
                if imageParts(in: range) == nil,
                   referenceImageParts(in: range) == nil
                {
                    appendLocal(
                        enclosingParagraphRange(containing: range),
                        reason: .complexOrAmbiguous,
                        to: &candidates
                    )
                }
            case .raw:
                appendLocal(
                    enclosingParagraphRange(containing: range),
                    reason: .rawHTML,
                    to: &candidates
                )
            case .math, .footnote, .rule:
                appendLocal(
                    enclosingParagraphRange(containing: range),
                    reason: .unsupportedSyntax,
                    to: &candidates
                )
            case .code where isBlockCode(range):
                appendLocal(
                    range,
                    reason: isMermaidFence(range) ? .mermaid : .fencedCode,
                    to: &candidates
                )
            case .heading, .emphasis, .strong, .strikethrough, .code, .link,
                 .blockQuote, .list:
                break
            }
        }
        return candidates
    }

    private func addUnsupportedHeadingCandidates(to candidates: inout [LocalCandidate]) {
        for span in spans where span.kind == .heading {
            guard headingParts(in: span.utf8Range) != nil
                    || setextHeadingParts(in: span.utf8Range) != nil
            else {
                appendLocal(
                    enclosingParagraphRange(containing: span.utf8Range),
                    reason: .complexOrAmbiguous,
                    to: &candidates
                )
                continue
            }
        }

        for span in spans where span.kind == .blockQuote {
            let coveredLines = lineIndices(intersecting: span.utf8Range)
            let isSimple = !coveredLines.isEmpty && coveredLines.allSatisfy { index in
                let line = lines[index]
                return line.isBlank || isSimpleBlockQuoteLine(line)
            }
            if !isSimple {
                appendLocal(
                    enclosingBlankSeparatedRange(containing: span.utf8Range),
                    reason: .complexOrAmbiguous,
                    to: &candidates
                )
            }
        }
    }

    private func addComplexInlineCandidates(to candidates: inout [LocalCandidate]) {
        let inlineSpans = spans.filter { span in
            switch span.kind {
            case .emphasis, .strong, .strikethrough, .link:
                true
            case .code:
                !isBlockCode(span.utf8Range)
            default:
                false
            }
        }.sorted {
            if $0.utf8Range.lowerBound != $1.utf8Range.lowerBound {
                return $0.utf8Range.lowerBound < $1.utf8Range.lowerBound
            }
            return $0.utf8Range.upperBound > $1.utf8Range.upperBound
        }

        for span in inlineSpans {
            let parts: InlineParts?
            switch span.kind {
            case .emphasis:
                parts = wrappedParts(in: span.utf8Range, delimiter: [0x2A])
                    ?? wrappedParts(in: span.utf8Range, delimiter: [0x5F])
            case .strong:
                parts = wrappedParts(in: span.utf8Range, delimiter: [0x2A, 0x2A])
                    ?? wrappedParts(in: span.utf8Range, delimiter: [0x5F, 0x5F])
            case .strikethrough:
                parts = wrappedParts(in: span.utf8Range, delimiter: [0x7E, 0x7E])
            case .code:
                parts = inlineCodeParts(in: span.utf8Range)
            case .link:
                parts = (linkParts(in: span.utf8Range)
                    ?? autolinkParts(in: span.utf8Range)
                    ?? referenceLinkParts(in: span.utf8Range)).map(InlineParts.link)
            default:
                parts = nil
            }
            if parts == nil {
                appendLocal(
                    enclosingParagraphRange(containing: span.utf8Range),
                    reason: .complexOrAmbiguous,
                    to: &candidates
                )
            }
        }

        addUnparsedDelimiterCandidates(to: &candidates)
    }

    private func addUnparsedDelimiterCandidates(to candidates: inout [LocalCandidate]) {
        let checks: [([UInt8], Set<MarkdownSyntaxKind>)] = [
            ([0x2A, 0x2A], [.strong]),
            ([0x5F, 0x5F], [.strong]),
            ([0x7E, 0x7E], [.strikethrough]),
            ([0x60], [.code]),
            ([0x5D, 0x28], [.link, .image]),
            ([0x21, 0x5B], [.image]),
        ]

        for line in lines where !line.isBlank {
            for (needle, acceptedKinds) in checks {
                for offset in occurrences(of: needle, in: line.contentRange) {
                    let occurrence = offset..<(offset + needle.count)
                    let isParsed = acceptedKinds.contains { kind in
                        semanticRange(of: kind, covers: occurrence)
                    }
                    let isCombinedEmphasisDelimiter = (needle == [0x2A, 0x2A]
                        || needle == [0x5F, 0x5F])
                        && semanticRange(of: .emphasis, covers: occurrence)
                        && semanticRange(of: .strong, overlaps: occurrence)
                    if !isParsed && !isCombinedEmphasisDelimiter {
                        appendLocal(
                            enclosingParagraphRange(containing: line.contentRange),
                            reason: .complexOrAmbiguous,
                            to: &candidates
                        )
                        break
                    }
                }
            }
        }
    }

    private func addAmbiguousLineCandidates(to candidates: inout [LocalCandidate]) {
        let parsedLines = lines.map(parseLine)
        for (index, parsed) in parsedLines.enumerated() {
            if case .ambiguous = parsed {
                appendLocal(
                    enclosingBlankSeparatedRange(containing: lines[index].contentRange),
                    reason: .complexOrAmbiguous,
                    to: &candidates
                )
            }
        }

        var blockStart = 0
        while blockStart < lines.count {
            while blockStart < lines.count, lines[blockStart].isBlank {
                blockStart += 1
            }
            guard blockStart < lines.count else { break }
            var blockEnd = blockStart
            while blockEnd + 1 < lines.count, !lines[blockEnd + 1].isBlank {
                blockEnd += 1
            }

            let block = parsedLines[blockStart...blockEnd]
            let containsList = block.contains { parsed in
                switch parsed {
                case .unorderedList, .orderedList: true
                default: false
                }
            }
            if containsList {
                let hasIndentedContinuation = (blockStart...blockEnd).contains { index in
                    guard leadingWhitespaceCount(in: lines[index]) > 0 else { return false }
                    switch parsedLines[index] {
                    case .blank: return false
                    default: return true
                    }
                }
                if hasIndentedContinuation {
                    appendLocal(
                        Range(
                            uncheckedBounds: (
                                lower: lines[blockStart].contentRange.lowerBound,
                                upper: lines[blockEnd].contentRange.upperBound
                            )
                        ),
                        reason: .complexOrAmbiguous,
                        to: &candidates
                    )
                }
            }
            blockStart = blockEnd + 1
        }
    }

    private func addBlockPresentation(
        excluding localCandidates: [LocalCandidate],
        markers: inout [PendingMarker],
        styles: inout [PendingStyle]
    ) {
        let setextHeadings = spans.compactMap { span -> SetextHeadingParts? in
            guard span.kind == .heading,
                  !overlapsLocalSource(span.utf8Range, localCandidates: localCandidates)
            else {
                return nil
            }
            return setextHeadingParts(in: span.utf8Range)
        }
        for heading in setextHeadings {
            appendMarker(
                .heading(level: heading.level),
                range: heading.marker,
                to: &markers
            )
            appendStyle(
                .heading(level: heading.level),
                range: heading.content,
                to: &styles
            )
        }

        for line in lines where !line.isBlank {
            guard !overlapsLocalSource(line.contentRange, localCandidates: localCandidates) else {
                continue
            }
            guard !setextHeadings.contains(where: {
                $0.source.lowerBound < line.fullRange.upperBound
                    && $0.source.upperBound > line.fullRange.lowerBound
            }) else {
                continue
            }
            switch parseLine(line) {
            case .blank, .ambiguous:
                break
            case let .paragraph(content):
                appendStyle(.paragraph, range: content, to: &styles)
            case let .heading(level, openingMarker, content, closingMarker):
                appendMarker(.heading(level: level), range: openingMarker, to: &markers)
                if let closingMarker {
                    appendMarker(.heading(level: level), range: closingMarker, to: &markers)
                }
                appendStyle(.heading(level: level), range: content, to: &styles)
            case let .blockQuote(marker, content):
                appendMarker(.blockQuote, range: marker, to: &markers)
                appendStyle(.blockQuote, range: content, to: &styles)
            case let .unorderedList(marker, taskMarker, isChecked, content):
                appendMarker(.unorderedList, range: marker, to: &markers)
                if let taskMarker, let isChecked {
                    appendMarker(.taskList, range: taskMarker, to: &markers)
                    appendStyle(.taskListItem(isChecked: isChecked), range: content, to: &styles)
                } else {
                    appendStyle(.unorderedListItem, range: content, to: &styles)
                }
            case let .orderedList(marker, content):
                appendMarker(.orderedList, range: marker, to: &markers)
                appendStyle(.orderedListItem, range: content, to: &styles)
            }
        }
    }

    private func addReferenceDefinitionPresentation(
        excluding localCandidates: [LocalCandidate],
        markers: inout [PendingMarker]
    ) {
        for range in referenceDefinitionRanges()
        where !overlapsLocalSource(range, localCandidates: localCandidates) {
            appendMarker(.referenceDefinition, range: range, to: &markers)
        }
    }

    private func addInlinePresentation(
        excluding localCandidates: [LocalCandidate],
        markers: inout [PendingMarker],
        styles: inout [PendingStyle],
        links: inout [PendingLink]
    ) {
        for span in spans {
            let range = span.utf8Range
            guard !overlapsLocalSource(range, localCandidates: localCandidates) else { continue }

            let markerKind: RenderedMarkdownMarkerKind
            let styleKind: RenderedMarkdownContentStyleKind
            let parts: InlineParts?
            switch span.kind {
            case .emphasis:
                markerKind = .emphasis
                styleKind = .emphasis
                parts = wrappedParts(in: range, delimiter: [0x2A])
                    ?? wrappedParts(in: range, delimiter: [0x5F])
            case .strong:
                markerKind = .strong
                styleKind = .strong
                parts = wrappedParts(in: range, delimiter: [0x2A, 0x2A])
                    ?? wrappedParts(in: range, delimiter: [0x5F, 0x5F])
            case .strikethrough:
                markerKind = .strikethrough
                styleKind = .strikethrough
                parts = wrappedParts(in: range, delimiter: [0x7E, 0x7E])
            case .code where !isBlockCode(range):
                markerKind = .inlineCode
                styleKind = .inlineCode
                parts = inlineCodeParts(in: range)
            case .link:
                guard let link = linkParts(in: range)
                    ?? autolinkParts(in: range)
                    ?? referenceLinkParts(in: range)
                else {
                    continue
                }
                links.append(link)
                for delimiter in link.delimiterRanges {
                    appendMarker(.linkDelimiter, range: delimiter, to: &markers)
                }
                if let hiddenDestinationRange = link.hiddenDestinationRange {
                    appendMarker(
                        .linkDestination,
                        range: hiddenDestinationRange,
                        to: &markers
                    )
                }
                appendStyle(.link, range: link.textUTF8Range, to: &styles)
                continue
            default:
                continue
            }

            guard case let .wrapped(opening, content, closing) = parts else { continue }
            appendMarker(markerKind, range: opening, to: &markers)
            appendMarker(markerKind, range: closing, to: &markers)
            appendStyle(styleKind, range: content, to: &styles)
        }
    }

    private func addImagePresentation(
        excluding localCandidates: [LocalCandidate],
        images: inout [PendingImage]
    ) {
        for span in spans where span.kind == .image {
            guard !overlapsLocalSource(span.utf8Range, localCandidates: localCandidates),
                  let image = imageParts(in: span.utf8Range)
                    ?? referenceImageParts(in: span.utf8Range)
            else {
                continue
            }
            images.append(image)
        }
    }

    private func parseLine(_ line: Line) -> ParsedLine {
        guard !line.isBlank else { return .blank }
        let range = line.contentRange
        var cursor = range.lowerBound
        var leadingSpaces = 0
        while cursor < range.upperBound, bytes[cursor] == 0x20, leadingSpaces < 4 {
            cursor += 1
            leadingSpaces += 1
        }
        if cursor < range.upperBound, bytes[cursor] == 0x09 {
            return looksLikeBlockPrefix(at: cursor + 1, upperBound: range.upperBound)
                ? .ambiguous
                : .paragraph(content: range)
        }

        if let heading = headingParts(in: range) {
            return .heading(
                level: heading.level,
                openingMarker: heading.openingMarker,
                content: heading.content,
                closingMarker: heading.closingMarker
            )
        }

        if cursor < range.upperBound, bytes[cursor] == 0x3E {
            guard semanticallyCovers(line: line, kind: .blockQuote), leadingSpaces <= 3 else {
                return .paragraph(content: range)
            }
            let markerStart = cursor
            cursor += 1
            if cursor < range.upperBound, matchesHorizontalWhitespace(bytes[cursor]) {
                cursor += 1
            }
            if looksLikeBlockPrefix(at: cursor, upperBound: range.upperBound) {
                return .ambiguous
            }
            return .blockQuote(marker: markerStart..<cursor, content: cursor..<range.upperBound)
        }

        if let list = listPrefix(in: line) {
            guard list.indentation == 0 else { return .ambiguous }
            if looksLikeBlockPrefix(at: list.contentStart, upperBound: range.upperBound) {
                return .ambiguous
            }
            switch list.kind {
            case .unordered:
                if let task = taskPrefix(from: list.contentStart, upperBound: range.upperBound) {
                    return .unorderedList(
                        marker: list.marker,
                        taskMarker: task.marker,
                        isChecked: task.isChecked,
                        content: task.contentStart..<range.upperBound
                    )
                }
                return .unorderedList(
                    marker: list.marker,
                    taskMarker: nil,
                    isChecked: nil,
                    content: list.contentStart..<range.upperBound
                )
            case .ordered:
                return .orderedList(
                    marker: list.marker,
                    content: list.contentStart..<range.upperBound
                )
            }
        }

        return .paragraph(content: range)
    }

    private func headingParts(
        in range: Range<Int>
    ) -> (level: Int, openingMarker: Range<Int>, content: Range<Int>, closingMarker: Range<Int>?)? {
        guard !range.isEmpty,
              !containsLineEnding(in: range),
              let line = line(containing: range.lowerBound),
              semanticallyCovers(line: line, kind: .heading)
        else {
            return nil
        }

        var cursor = line.contentRange.lowerBound
        var spaces = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x20, spaces < 4 {
            cursor += 1
            spaces += 1
        }
        guard spaces <= 3 else { return nil }
        let hashesStart = cursor
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x23 {
            cursor += 1
        }
        let level = cursor - hashesStart
        guard (1...6).contains(level) else { return nil }

        if cursor < line.contentRange.upperBound {
            guard matchesHorizontalWhitespace(bytes[cursor]) else { return nil }
            cursor += 1
        }
        let openingMarker = hashesStart..<cursor
        var contentEnd = line.contentRange.upperBound
        var trailingStart = contentEnd
        while trailingStart > cursor, matchesHorizontalWhitespace(bytes[trailingStart - 1]) {
            trailingStart -= 1
        }
        var hashes = trailingStart
        while hashes > cursor, bytes[hashes - 1] == 0x23 {
            hashes -= 1
        }
        var closingMarker: Range<Int>?
        if hashes < trailingStart, hashes > cursor, matchesHorizontalWhitespace(bytes[hashes - 1]) {
            var markerStart = hashes - 1
            while markerStart > cursor, matchesHorizontalWhitespace(bytes[markerStart - 1]) {
                markerStart -= 1
            }
            contentEnd = markerStart
            closingMarker = markerStart..<line.contentRange.upperBound
        }
        return (level, openingMarker, cursor..<contentEnd, closingMarker)
    }

    private struct SetextHeadingParts {
        let level: Int
        let source: Range<Int>
        let content: Range<Int>
        let marker: Range<Int>
    }

    private func setextHeadingParts(in range: Range<Int>) -> SetextHeadingParts? {
        guard !range.isEmpty,
              let newline = bytes[range].firstIndex(of: 0x0A),
              newline > range.lowerBound,
              newline + 1 < range.upperBound,
              !bytes[(newline + 1)..<range.upperBound].contains(0x0A)
        else {
            return nil
        }

        var contentStart = range.lowerBound
        var leadingSpaces = 0
        while contentStart < newline, bytes[contentStart] == 0x20, leadingSpaces < 4 {
            contentStart += 1
            leadingSpaces += 1
        }
        guard leadingSpaces <= 3 else { return nil }

        var contentEnd = newline
        if contentEnd > contentStart, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
        while contentEnd > contentStart, matchesHorizontalWhitespace(bytes[contentEnd - 1]) {
            contentEnd -= 1
        }
        guard contentStart < contentEnd else { return nil }

        var underlineCursor = newline + 1
        var underlineSpaces = 0
        while underlineCursor < range.upperBound,
              bytes[underlineCursor] == 0x20,
              underlineSpaces < 4
        {
            underlineCursor += 1
            underlineSpaces += 1
        }
        guard underlineSpaces <= 3, underlineCursor < range.upperBound else { return nil }
        let underlineCharacter = bytes[underlineCursor]
        guard underlineCharacter == 0x3D || underlineCharacter == 0x2D else { return nil }
        while underlineCursor < range.upperBound,
              bytes[underlineCursor] == underlineCharacter
        {
            underlineCursor += 1
        }
        while underlineCursor < range.upperBound,
              matchesHorizontalWhitespace(bytes[underlineCursor])
        {
            underlineCursor += 1
        }
        guard underlineCursor == range.upperBound else { return nil }

        return SetextHeadingParts(
            level: underlineCharacter == 0x3D ? 1 : 2,
            source: range,
            content: contentStart..<contentEnd,
            marker: contentEnd..<range.upperBound
        )
    }

    private struct ListPrefix {
        enum Kind { case unordered, ordered }
        let kind: Kind
        let indentation: Int
        let marker: Range<Int>
        let contentStart: Int
    }

    private func listPrefix(in line: Line) -> ListPrefix? {
        var cursor = line.contentRange.lowerBound
        var indentation = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x20, indentation < 4 {
            cursor += 1
            indentation += 1
        }
        let markerStart = cursor
        let kind: ListPrefix.Kind
        if cursor < line.contentRange.upperBound,
           bytes[cursor] == 0x2D || bytes[cursor] == 0x2B || bytes[cursor] == 0x2A
        {
            kind = .unordered
            cursor += 1
        } else {
            let digitsStart = cursor
            while cursor < line.contentRange.upperBound, bytes[cursor].isASCIIDigit {
                cursor += 1
            }
            guard cursor > digitsStart,
                  cursor - digitsStart <= 9,
                  cursor < line.contentRange.upperBound,
                  bytes[cursor] == 0x2E || bytes[cursor] == 0x29
            else {
                return nil
            }
            kind = .ordered
            cursor += 1
        }
        guard cursor < line.contentRange.upperBound, matchesHorizontalWhitespace(bytes[cursor]),
              semanticallyCovers(line: line, kind: .list)
        else {
            return nil
        }
        while cursor < line.contentRange.upperBound, matchesHorizontalWhitespace(bytes[cursor]) {
            cursor += 1
        }
        return ListPrefix(
            kind: kind,
            indentation: indentation,
            marker: markerStart..<cursor,
            contentStart: cursor
        )
    }

    private func taskPrefix(
        from start: Int,
        upperBound: Int
    ) -> (marker: Range<Int>, isChecked: Bool, contentStart: Int)? {
        guard start + 3 <= upperBound,
              bytes[start] == 0x5B,
              bytes[start + 2] == 0x5D,
              bytes[start + 1] == 0x20
                || bytes[start + 1] == 0x78
                || bytes[start + 1] == 0x58
        else {
            return nil
        }
        var cursor = start + 3
        guard cursor == upperBound || matchesHorizontalWhitespace(bytes[cursor]) else { return nil }
        while cursor < upperBound, matchesHorizontalWhitespace(bytes[cursor]) {
            cursor += 1
        }
        return (
            marker: start..<cursor,
            isChecked: bytes[start + 1] != 0x20,
            contentStart: cursor
        )
    }

    private func wrappedParts(
        in range: Range<Int>,
        delimiter: [UInt8]
    ) -> InlineParts? {
        guard range.count >= delimiter.count * 2,
              Array(bytes[range.lowerBound..<(range.lowerBound + delimiter.count)]) == delimiter,
              Array(bytes[(range.upperBound - delimiter.count)..<range.upperBound]) == delimiter
        else {
            return nil
        }
        return .wrapped(
            openingMarker: range.lowerBound..<(range.lowerBound + delimiter.count),
            content: (range.lowerBound + delimiter.count)..<(range.upperBound - delimiter.count),
            closingMarker: (range.upperBound - delimiter.count)..<range.upperBound
        )
    }

    private func inlineCodeParts(in range: Range<Int>) -> InlineParts? {
        guard !range.isEmpty, !containsLineEnding(in: range), bytes[range.lowerBound] == 0x60 else {
            return nil
        }
        var delimiterLength = 0
        while range.lowerBound + delimiterLength < range.upperBound,
              bytes[range.lowerBound + delimiterLength] == 0x60
        {
            delimiterLength += 1
        }
        guard range.count >= delimiterLength * 2 else { return nil }
        let closingStart = range.upperBound - delimiterLength
        guard bytes[closingStart..<range.upperBound].allSatisfy({ $0 == 0x60 }) else {
            return nil
        }
        let rawContent = (range.lowerBound + delimiterLength)..<closingStart
        let trimsPadding = rawContent.count >= 2
            && bytes[rawContent.lowerBound] == 0x20
            && bytes[rawContent.upperBound - 1] == 0x20
            && !bytes[rawContent].allSatisfy({ $0 == 0x20 })
        let content = trimsPadding
            ? (rawContent.lowerBound + 1)..<(rawContent.upperBound - 1)
            : rawContent
        return .wrapped(
            openingMarker: range.lowerBound..<content.lowerBound,
            content: content,
            closingMarker: content.upperBound..<range.upperBound
        )
    }

    private func linkParts(in range: Range<Int>) -> PendingLink? {
        guard range.count >= 4,
              bytes[range.lowerBound] == 0x5B,
              bytes[range.upperBound - 1] == 0x29
        else {
            return nil
        }

        var cursor = range.lowerBound + 1
        let textStart = cursor
        while cursor < range.upperBound {
            if bytes[cursor] == 0x5C || bytes[cursor] == 0x5B {
                return nil
            }
            if bytes[cursor] == 0x5D { break }
            cursor += 1
        }
        guard cursor > textStart,
              cursor + 1 < range.upperBound,
              bytes[cursor] == 0x5D,
              bytes[cursor + 1] == 0x28
        else {
            return nil
        }
        let textRange = textStart..<cursor
        let middleMarkerStart = cursor
        cursor += 2
        let rawDestinationStart = cursor
        let rawDestinationEnd = range.upperBound - 1
        guard rawDestinationStart <= rawDestinationEnd else { return nil }

        let targetRange: Range<Int>
        let middleMarker: Range<Int>
        let closingMarker: Range<Int>
        if rawDestinationStart < rawDestinationEnd,
           bytes[rawDestinationStart] == 0x3C,
           let closingAngle = bytes[(rawDestinationStart + 1)..<rawDestinationEnd]
               .firstIndex(of: 0x3E),
           titleSuffixIsValid((closingAngle + 1)..<rawDestinationEnd)
        {
            targetRange = (rawDestinationStart + 1)..<closingAngle
            middleMarker = middleMarkerStart..<(rawDestinationStart + 1)
            closingMarker = closingAngle..<range.upperBound
        } else {
            var targetEnd = rawDestinationStart
            var depth = 0
            while targetEnd < rawDestinationEnd {
                let byte = bytes[targetEnd]
                if (byte == 0x20 || byte == 0x09) && depth == 0 { break }
                if byte == 0x28 {
                    depth += 1
                } else if byte == 0x29 {
                    guard depth > 0 else { return nil }
                    depth -= 1
                }
                targetEnd += 1
            }
            guard depth == 0,
                  titleSuffixIsValid(targetEnd..<rawDestinationEnd)
            else {
                return nil
            }
            targetRange = rawDestinationStart..<targetEnd
            middleMarker = middleMarkerStart..<rawDestinationStart
            closingMarker = targetEnd..<range.upperBound
        }

        guard destinationIsUnambiguous(targetRange),
              let target = String(bytes: bytes[targetRange], encoding: .utf8)
        else {
            return nil
        }
        return PendingLink(
            sourceUTF8Range: range,
            textUTF8Range: textRange,
            targetUTF8Range: targetRange,
            target: target,
            delimiterRanges: [
                range.lowerBound..<(range.lowerBound + 1),
                middleMarker,
                closingMarker,
            ],
            hiddenDestinationRange: targetRange
        )
    }

    private func autolinkParts(in range: Range<Int>) -> PendingLink? {
        guard range.count >= 3,
              bytes[range.lowerBound] == 0x3C,
              bytes[range.upperBound - 1] == 0x3E
        else {
            return nil
        }
        let targetRange = (range.lowerBound + 1)..<(range.upperBound - 1)
        guard destinationIsUnambiguous(targetRange),
              let target = String(bytes: bytes[targetRange], encoding: .utf8),
              let components = URLComponents(string: target),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }
        return PendingLink(
            sourceUTF8Range: range,
            textUTF8Range: targetRange,
            targetUTF8Range: targetRange,
            target: target,
            delimiterRanges: [
                range.lowerBound..<(range.lowerBound + 1),
                (range.upperBound - 1)..<range.upperBound,
            ],
            hiddenDestinationRange: nil
        )
    }

    private func titleSuffixIsValid(_ range: Range<Int>) -> Bool {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, bytes[lower] == 0x20 || bytes[lower] == 0x09 {
            lower += 1
        }
        while upper > lower, bytes[upper - 1] == 0x20 || bytes[upper - 1] == 0x09 {
            upper -= 1
        }
        guard lower < upper else { return true }
        guard upper - lower >= 2 else { return false }
        let opening = bytes[lower]
        let expectedClosing: UInt8
        switch opening {
        case 0x22: expectedClosing = 0x22
        case 0x27: expectedClosing = 0x27
        case 0x28: expectedClosing = 0x29
        default: return false
        }
        guard bytes[upper - 1] == expectedClosing else { return false }
        return !bytes[(lower + 1)..<(upper - 1)].contains(where: {
            $0 == 0x0A || $0 == 0x0D || $0 < 0x20 || $0 == 0x7F
        })
    }

    private func imageParts(in range: Range<Int>) -> PendingImage? {
        guard range.count >= 5,
              bytes[range.lowerBound] == 0x21,
              let link = linkParts(in: (range.lowerBound + 1)..<range.upperBound),
              let alternative = String(bytes: bytes[link.textUTF8Range], encoding: .utf8)
        else {
            return nil
        }
        return PendingImage(
            sourceUTF8Range: range,
            alternativeUTF8Range: link.textUTF8Range,
            targetUTF8Range: link.targetUTF8Range,
            alternative: alternative,
            target: link.target
        )
    }

    private func referenceLinkParts(in range: Range<Int>) -> PendingLink? {
        guard let reference = references.first(where: {
            $0.kind == .link && $0.sourceUTF8Range == range
        }), let textRange = simpleReferenceLabelRange(in: range, image: false)
        else {
            return nil
        }
        let sourceRange = extendedCollapsedReferenceRange(range)
        let suffixRange = textRange.upperBound..<sourceRange.upperBound
        return PendingLink(
            sourceUTF8Range: sourceRange,
            textUTF8Range: textRange,
            targetUTF8Range: textRange.upperBound..<textRange.upperBound,
            target: reference.target,
            delimiterRanges: [range.lowerBound..<(range.lowerBound + 1)],
            hiddenDestinationRange: suffixRange
        )
    }

    private func referenceImageParts(in range: Range<Int>) -> PendingImage? {
        guard let reference = references.first(where: {
            $0.kind == .image && $0.sourceUTF8Range == range
        }), let alternativeRange = simpleReferenceLabelRange(in: range, image: true),
              let alternative = String(
                  bytes: bytes[alternativeRange],
                  encoding: .utf8
              )
        else {
            return nil
        }
        return PendingImage(
            sourceUTF8Range: extendedCollapsedReferenceRange(range),
            alternativeUTF8Range: alternativeRange,
            targetUTF8Range: alternativeRange.upperBound..<alternativeRange.upperBound,
            alternative: alternative,
            target: reference.target
        )
    }

    private func extendedCollapsedReferenceRange(_ range: Range<Int>) -> Range<Int> {
        guard range.upperBound + 2 <= bytes.count,
              bytes[range.upperBound] == 0x5B,
              bytes[range.upperBound + 1] == 0x5D
        else {
            return range
        }
        return range.lowerBound..<(range.upperBound + 2)
    }

    private func referenceDefinitionRanges() -> [Range<Int>] {
        lines.compactMap { line in
            guard !line.isBlank else { return nil }
            var cursor = line.contentRange.lowerBound
            var indentation = 0
            while cursor < line.contentRange.upperBound,
                  bytes[cursor] == 0x20,
                  indentation < 4
            {
                cursor += 1
                indentation += 1
            }
            guard indentation <= 3,
                  cursor < line.contentRange.upperBound,
                  bytes[cursor] == 0x5B,
                  cursor + 1 < line.contentRange.upperBound,
                  bytes[cursor + 1] != 0x5E
            else {
                return nil
            }

            cursor += 1
            let labelStart = cursor
            var escaped = false
            while cursor < line.contentRange.upperBound {
                let byte = bytes[cursor]
                if escaped {
                    escaped = false
                    cursor += 1
                    continue
                }
                if byte == 0x5C {
                    escaped = true
                    cursor += 1
                    continue
                }
                if byte == 0x5B { return nil }
                if byte == 0x5D { break }
                cursor += 1
            }
            guard cursor > labelStart,
                  cursor + 1 < line.contentRange.upperBound,
                  bytes[cursor] == 0x5D,
                  bytes[cursor + 1] == 0x3A
            else {
                return nil
            }
            cursor += 2
            while cursor < line.contentRange.upperBound,
                  matchesHorizontalWhitespace(bytes[cursor])
            {
                cursor += 1
            }
            guard cursor < line.contentRange.upperBound else { return nil }
            return line.fullRange
        }
    }

    private func simpleReferenceLabelRange(
        in range: Range<Int>,
        image: Bool
    ) -> Range<Int>? {
        let openingLength = image ? 2 : 1
        guard range.count > openingLength + 1,
              (!image || bytes[range.lowerBound] == 0x21),
              bytes[range.lowerBound + openingLength - 1] == 0x5B
        else {
            return nil
        }
        let labelStart = range.lowerBound + openingLength
        var cursor = labelStart
        while cursor < range.upperBound {
            if bytes[cursor] == 0x5C || bytes[cursor] == 0x5B { return nil }
            if bytes[cursor] == 0x5D { break }
            cursor += 1
        }
        guard cursor > labelStart, cursor < range.upperBound else { return nil }
        return labelStart..<cursor
    }

    private func destinationIsUnambiguous(_ range: Range<Int>) -> Bool {
        var parenthesisDepth = 0
        for byte in bytes[range] {
            guard byte >= 0x20,
                  byte != 0x7F,
                  byte != 0x20,
                  byte != 0x09,
                  byte != 0x0A,
                  byte != 0x0D,
                  byte != 0x5C,
                  byte != 0x3C,
                  byte != 0x3E
            else {
                return false
            }
            if byte == 0x28 {
                parenthesisDepth += 1
            } else if byte == 0x29 {
                guard parenthesisDepth > 0 else { return false }
                parenthesisDepth -= 1
            }
        }
        return parenthesisDepth == 0
    }

    private func isBlockCode(_ range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        if containsLineEnding(in: range) { return true }
        guard let line = line(containing: range.lowerBound) else { return false }
        var cursor = line.contentRange.lowerBound
        var spaces = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x20 {
            cursor += 1
            spaces += 1
        }
        if spaces >= 4 { return true }
        guard cursor < line.contentRange.upperBound,
              bytes[cursor] == 0x60 || bytes[cursor] == 0x7E
        else {
            return false
        }
        let fence = bytes[cursor]
        var count = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == fence {
            count += 1
            cursor += 1
        }
        return count >= 3
    }

    private func isMermaidFence(_ range: Range<Int>) -> Bool {
        guard let line = line(containing: range.lowerBound) else { return false }
        var cursor = line.contentRange.lowerBound
        var spaces = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x20, spaces < 4 {
            cursor += 1
            spaces += 1
        }
        guard spaces <= 3,
              cursor < line.contentRange.upperBound,
              bytes[cursor] == 0x60 || bytes[cursor] == 0x7E
        else {
            return false
        }
        let fence = bytes[cursor]
        var count = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == fence {
            cursor += 1
            count += 1
        }
        guard count >= 3 else { return false }
        while cursor < line.contentRange.upperBound, matchesHorizontalWhitespace(bytes[cursor]) {
            cursor += 1
        }
        let infoStart = cursor
        while cursor < line.contentRange.upperBound,
              !matchesHorizontalWhitespace(bytes[cursor])
        {
            cursor += 1
        }
        return bytes[infoStart..<cursor].elementsEqual("mermaid".utf8)
    }

    private func isSimpleBlockQuoteLine(_ line: Line) -> Bool {
        guard !line.isBlank else { return true }
        var cursor = line.contentRange.lowerBound
        var spaces = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x20, spaces < 4 {
            cursor += 1
            spaces += 1
        }
        guard spaces <= 3, cursor < line.contentRange.upperBound, bytes[cursor] == 0x3E else {
            return false
        }
        cursor += 1
        if cursor < line.contentRange.upperBound, matchesHorizontalWhitespace(bytes[cursor]) {
            cursor += 1
        }
        return !looksLikeBlockPrefix(at: cursor, upperBound: line.contentRange.upperBound)
    }

    private func looksLikeBlockPrefix(at offset: Int, upperBound: Int) -> Bool {
        guard offset < upperBound else { return false }
        if bytes[offset] == 0x3E || bytes[offset] == 0x23 { return true }
        if bytes[offset] == 0x2D || bytes[offset] == 0x2B || bytes[offset] == 0x2A {
            return offset + 1 < upperBound && matchesHorizontalWhitespace(bytes[offset + 1])
        }
        var cursor = offset
        while cursor < upperBound, bytes[cursor].isASCIIDigit, cursor - offset < 9 {
            cursor += 1
        }
        return cursor > offset
            && cursor + 1 < upperBound
            && (bytes[cursor] == 0x2E || bytes[cursor] == 0x29)
            && matchesHorizontalWhitespace(bytes[cursor + 1])
    }

    private func semanticallyCovers(line: Line, kind: MarkdownSyntaxKind) -> Bool {
        semanticKindsByLine[line.index].contains(kind.rawValue)
    }

    private func semanticRange(
        of kind: MarkdownSyntaxKind,
        covers requestedRange: Range<Int>
    ) -> Bool {
        guard let ranges = semanticRangesByKind[kind.rawValue], !ranges.isEmpty else {
            return false
        }
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            if ranges[midpoint].lowerBound <= requestedRange.lowerBound {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        guard lower > 0 else { return false }
        let candidate = ranges[lower - 1]
        return candidate.lowerBound <= requestedRange.lowerBound
            && candidate.upperBound >= requestedRange.upperBound
    }

    private func semanticRange(
        of kind: MarkdownSyntaxKind,
        overlaps requestedRange: Range<Int>
    ) -> Bool {
        guard let ranges = semanticRangesByKind[kind.rawValue] else { return false }
        return ranges.contains { range in
            range.lowerBound < requestedRange.upperBound
                && range.upperBound > requestedRange.lowerBound
        }
    }

    private func containsLineEnding(in range: Range<Int>) -> Bool {
        bytes[range].contains(0x0A) || bytes[range].contains(0x0D)
    }

    private func line(containing offset: Int) -> Line? {
        guard let index = Self.lineIndex(containing: offset, lines: lines) else { return nil }
        return lines[index]
    }

    private func lineIndices(intersecting range: Range<Int>) -> [Int] {
        guard !range.isEmpty,
              let first = Self.lineIndex(containing: range.lowerBound, lines: lines),
              let last = Self.lineIndex(containing: range.upperBound - 1, lines: lines),
              first <= last
        else {
            return []
        }
        return Array(first...last)
    }

    private func enclosingParagraphRange(containing range: Range<Int>) -> Range<Int> {
        let indices = lineIndices(intersecting: range)
        guard var first = indices.first, var last = indices.last else { return range }
        let startsWithBlock = isBlockStarter(lines[first])
        if !startsWithBlock {
            while first > 0,
                  !lines[first - 1].isBlank,
                  !isBlockStarter(lines[first - 1])
            {
                first -= 1
            }
            while last + 1 < lines.count,
                  !lines[last + 1].isBlank,
                  !isBlockStarter(lines[last + 1])
            {
                last += 1
            }
        }
        return lines[first].contentRange.lowerBound..<lines[last].contentRange.upperBound
    }

    private func enclosingBlankSeparatedRange(containing range: Range<Int>) -> Range<Int> {
        let indices = lineIndices(intersecting: range)
        guard var first = indices.first, var last = indices.last else { return range }
        while first > 0, !lines[first - 1].isBlank { first -= 1 }
        while last + 1 < lines.count, !lines[last + 1].isBlank { last += 1 }
        return lines[first].contentRange.lowerBound..<lines[last].contentRange.upperBound
    }

    private func isBlockStarter(_ line: Line) -> Bool {
        guard !line.isBlank else { return true }
        var cursor = line.contentRange.lowerBound
        var spaces = 0
        while cursor < line.contentRange.upperBound, bytes[cursor] == 0x20, spaces < 4 {
            cursor += 1
            spaces += 1
        }
        if spaces >= 4 || cursor >= line.contentRange.upperBound { return spaces >= 4 }
        if bytes[cursor] == 0x23 || bytes[cursor] == 0x3E || bytes[cursor] == 0x3C {
            return true
        }
        if bytes[cursor] == 0x60 || bytes[cursor] == 0x7E {
            let marker = bytes[cursor]
            var count = 0
            while cursor < line.contentRange.upperBound, bytes[cursor] == marker {
                count += 1
                cursor += 1
            }
            if count >= 3 { return true }
        }
        return listPrefix(in: line) != nil
    }

    private func leadingWhitespaceCount(in line: Line) -> Int {
        var cursor = line.contentRange.lowerBound
        while cursor < line.contentRange.upperBound,
              bytes[cursor] == 0x20 || bytes[cursor] == 0x09
        {
            cursor += 1
        }
        return cursor - line.contentRange.lowerBound
    }

    private func occurrences(of needle: [UInt8], in range: Range<Int>) -> [Int] {
        guard !needle.isEmpty, range.count >= needle.count else { return [] }
        var result: [Int] = []
        var cursor = range.lowerBound
        while cursor <= range.upperBound - needle.count {
            if bytes[cursor..<(cursor + needle.count)].elementsEqual(needle) {
                result.append(cursor)
                cursor += needle.count
            } else {
                cursor += 1
            }
        }
        return result
    }

    private func appendLocal(
        _ range: Range<Int>,
        reason: RenderedMarkdownLocalSourceReason,
        to candidates: inout [LocalCandidate]
    ) {
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= bytes.count
        else {
            return
        }
        candidates.append(LocalCandidate(utf8Range: range, reasons: [reason]))
    }

    private func mergeLocalCandidates(_ candidates: [LocalCandidate]) -> [LocalCandidate] {
        let sorted = candidates.sorted {
            if $0.utf8Range.lowerBound != $1.utf8Range.lowerBound {
                return $0.utf8Range.lowerBound < $1.utf8Range.lowerBound
            }
            return $0.utf8Range.upperBound < $1.utf8Range.upperBound
        }
        var result: [LocalCandidate] = []
        for candidate in sorted {
            if var previous = result.last,
               candidate.utf8Range.lowerBound <= previous.utf8Range.upperBound
            {
                result.removeLast()
                previous.utf8Range = Range(
                    uncheckedBounds: (
                        lower: previous.utf8Range.lowerBound,
                        upper: max(
                            previous.utf8Range.upperBound,
                            candidate.utf8Range.upperBound
                        )
                    )
                )
                previous.reasons.formUnion(candidate.reasons)
                result.append(previous)
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    private func overlapsLocalSource(
        _ range: Range<Int>,
        localCandidates: [LocalCandidate]
    ) -> Bool {
        localCandidates.contains { local in
            local.utf8Range.lowerBound < range.upperBound
                && local.utf8Range.upperBound > range.lowerBound
        }
    }

    private func appendMarker(
        _ kind: RenderedMarkdownMarkerKind,
        range: Range<Int>,
        to markers: inout [PendingMarker]
    ) {
        guard !range.isEmpty else { return }
        markers.append(PendingMarker(kind: kind, utf8Range: range))
    }

    private func appendStyle(
        _ kind: RenderedMarkdownContentStyleKind,
        range: Range<Int>,
        to styles: inout [PendingStyle]
    ) {
        guard !range.isEmpty else { return }
        styles.append(PendingStyle(kind: kind, utf8Range: range))
    }

    private func sortedUniqueMarkers(_ markers: [PendingMarker]) -> [PendingMarker] {
        var result: [PendingMarker] = []
        for marker in markers.sorted(by: markerSort) where result.last != marker {
            result.append(marker)
        }
        return result
    }

    private func sortedUniqueStyles(_ styles: [PendingStyle]) -> [PendingStyle] {
        var result: [PendingStyle] = []
        for style in styles.sorted(by: styleSort) where result.last != style {
            result.append(style)
        }
        return result
    }

    private func markerSort(_ lhs: PendingMarker, _ rhs: PendingMarker) -> Bool {
        if lhs.utf8Range.lowerBound != rhs.utf8Range.lowerBound {
            return lhs.utf8Range.lowerBound < rhs.utf8Range.lowerBound
        }
        if lhs.utf8Range.upperBound != rhs.utf8Range.upperBound {
            return lhs.utf8Range.upperBound < rhs.utf8Range.upperBound
        }
        return markerRank(lhs.kind) < markerRank(rhs.kind)
    }

    private func styleSort(_ lhs: PendingStyle, _ rhs: PendingStyle) -> Bool {
        if lhs.utf8Range.lowerBound != rhs.utf8Range.lowerBound {
            return lhs.utf8Range.lowerBound < rhs.utf8Range.lowerBound
        }
        if lhs.utf8Range.upperBound != rhs.utf8Range.upperBound {
            return lhs.utf8Range.upperBound > rhs.utf8Range.upperBound
        }
        return styleRank(lhs.kind) < styleRank(rhs.kind)
    }

    private func markerRank(_ kind: RenderedMarkdownMarkerKind) -> Int {
        switch kind {
        case .heading: 0
        case .blockQuote: 1
        case .unorderedList: 2
        case .orderedList: 3
        case .taskList: 4
        case .referenceDefinition: 5
        case .emphasis: 6
        case .strong: 7
        case .strikethrough: 8
        case .inlineCode: 9
        case .linkDelimiter: 10
        case .linkDestination: 11
        }
    }

    private func styleRank(_ kind: RenderedMarkdownContentStyleKind) -> Int {
        switch kind {
        case .paragraph: 0
        case .heading: 1
        case .blockQuote: 2
        case .unorderedListItem: 3
        case .orderedListItem: 4
        case .taskListItem: 5
        case .emphasis: 6
        case .strong: 7
        case .strikethrough: 8
        case .inlineCode: 9
        case .link: 10
        }
    }

    private func requestedUTF8Offsets(
        localCandidates: [LocalCandidate],
        markers: [PendingMarker],
        styles: [PendingStyle],
        links: [PendingLink],
        images: [PendingImage]
    ) -> [Int] {
        var offsets: Set<Int> = [0, bytes.count]
        func insert(_ range: Range<Int>) {
            offsets.insert(range.lowerBound)
            offsets.insert(range.upperBound)
        }
        localCandidates.forEach { insert($0.utf8Range) }
        markers.forEach { insert($0.utf8Range) }
        styles.forEach { insert($0.utf8Range) }
        links.forEach { link in
            insert(link.sourceUTF8Range)
            insert(link.textUTF8Range)
            insert(link.targetUTF8Range)
        }
        images.forEach { image in
            insert(image.sourceUTF8Range)
            insert(image.alternativeUTF8Range)
            insert(image.targetUTF8Range)
        }
        return offsets.sorted()
    }

    private func mapUTF8OffsetsToUTF16(_ requestedOffsets: [Int]) -> [Int: Int]? {
        guard requestedOffsets.allSatisfy({ $0 >= 0 && $0 <= bytes.count }) else { return nil }
        var result: [Int: Int] = [:]
        result.reserveCapacity(requestedOffsets.count)
        var requestedIndex = 0
        var utf8Offset = 0
        var utf16Offset = 0

        func recordCurrentBoundary() -> Bool {
            if requestedIndex < requestedOffsets.count,
               requestedOffsets[requestedIndex] < utf8Offset
            {
                return false
            }
            while requestedIndex < requestedOffsets.count,
                  requestedOffsets[requestedIndex] == utf8Offset
            {
                result[utf8Offset] = utf16Offset
                requestedIndex += 1
            }
            return true
        }

        guard recordCurrentBoundary() else { return nil }
        for scalar in source.unicodeScalars {
            let value = scalar.value
            if value <= 0x7F {
                utf8Offset += 1
            } else if value <= 0x7FF {
                utf8Offset += 2
            } else if value <= 0xFFFF {
                utf8Offset += 3
            } else {
                utf8Offset += 4
            }
            utf16Offset += value <= 0xFFFF ? 1 : 2
            guard recordCurrentBoundary() else { return nil }
        }
        return requestedIndex == requestedOffsets.count ? result : nil
    }

    private static func makeSemanticKindsByLine(
        lines: [Line],
        spans: [MarkdownSyntaxSpan]
    ) -> [Set<UInt8>] {
        var result = Array(repeating: Set<UInt8>(), count: lines.count)
        for span in spans where !span.utf8Range.isEmpty {
            guard let first = lineIndex(
                containing: span.utf8Range.lowerBound,
                lines: lines
            ),
            let last = lineIndex(
                containing: span.utf8Range.upperBound - 1,
                lines: lines
            ) else {
                continue
            }
            for index in first...last {
                result[index].insert(span.kind.rawValue)
            }
        }
        return result
    }

    private static func lineIndex(containing offset: Int, lines: [Line]) -> Int? {
        guard !lines.isEmpty,
              offset >= 0,
              offset <= lines[lines.count - 1].fullRange.upperBound
        else {
            return nil
        }
        if offset == lines[lines.count - 1].fullRange.upperBound {
            return lines.count - 1
        }

        var lower = 0
        var upper = lines.count
        while lower < upper {
            let midpoint = lower + (upper - lower) / 2
            let line = lines[midpoint]
            if offset < line.fullRange.lowerBound {
                upper = midpoint
            } else if offset >= line.fullRange.upperBound {
                lower = midpoint + 1
            } else {
                return midpoint
            }
        }
        return nil
    }

    private static func makeLines(bytes: [UInt8]) -> [Line] {
        guard !bytes.isEmpty else { return [] }
        var result: [Line] = []
        var start = 0
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let fullEnd = newline.map { $0 + 1 } ?? bytes.count
            var contentEnd = newline ?? bytes.count
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D {
                contentEnd -= 1
            }
            let contentRange = start..<contentEnd
            let blank = bytes[contentRange].allSatisfy { byte in
                byte == 0x20 || byte == 0x09
            }
            result.append(
                Line(
                    index: result.count,
                    fullRange: start..<fullEnd,
                    contentRange: contentRange,
                    isBlank: blank
                )
            )
            start = fullEnd
        }
        return result
    }

    private func matchesHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }
}

private enum RenderedMarkdownPlanError: Error {
    case invalidSourceRange
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= 0x30 && self <= 0x39 }
}
