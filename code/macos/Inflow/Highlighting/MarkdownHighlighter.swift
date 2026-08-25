import Foundation

enum MarkdownSyntaxKind: UInt8, CaseIterable, Equatable, Sendable {
    case heading = 1
    case emphasis = 2
    case strong = 3
    case strikethrough = 4
    case code = 5
    case link = 6
    case image = 7
    case blockQuote = 8
    case list = 9
    case table = 10
    case footnote = 11
    case math = 12
    case raw = 13
    case rule = 14
}

struct MarkdownSyntaxSpan: Equatable, Sendable {
    let kind: MarkdownSyntaxKind
    let utf8Range: Range<Int>
    let utf16Range: NSRange
}

enum MarkdownSyntaxRange {
    static func utf16Range(for utf8Range: Range<Int>, in source: String) -> NSRange? {
        utf16Ranges(for: [utf8Range], in: source)?.first
    }

    static func utf16Ranges(
        for utf8Ranges: [Range<Int>],
        in source: String
    ) -> [NSRange]? {
        if utf8Ranges.isEmpty { return [] }
        guard utf8Ranges.allSatisfy({ range in
            range.lowerBound >= 0
                && range.lowerBound < range.upperBound
                && range.upperBound <= source.utf8.count
        }) else {
            return nil
        }

        let requestedOffsets = Array(
            Set(utf8Ranges.flatMap { [$0.lowerBound, $0.upperBound] })
        ).sorted()
        var offsetMapping: [Int: Int] = [:]
        offsetMapping.reserveCapacity(requestedOffsets.count)
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
                offsetMapping[utf8Offset] = utf16Offset
                requestedIndex += 1
            }
            return true
        }

        guard recordCurrentBoundary() else { return nil }
        for scalar in source.unicodeScalars {
            let value = scalar.value
            let utf8Length: Int
            if value <= 0x7F {
                utf8Length = 1
            } else if value <= 0x7FF {
                utf8Length = 2
            } else if value <= 0xFFFF {
                utf8Length = 3
            } else {
                utf8Length = 4
            }
            utf8Offset += utf8Length
            utf16Offset += value <= 0xFFFF ? 1 : 2
            guard recordCurrentBoundary() else { return nil }
        }
        guard requestedIndex == requestedOffsets.count else { return nil }

        return utf8Ranges.map { range in
            guard let start = offsetMapping[range.lowerBound],
                  let end = offsetMapping[range.upperBound]
            else {
                preconditionFailure("validated syntax boundaries must have UTF-16 offsets")
            }
            return NSRange(location: start, length: end - start)
        }
    }
}

enum MarkdownHighlightError: Error, LocalizedError {
    case invalidCoreResult
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .invalidCoreResult: "Markdown 高亮结果无效。"
        case .coreFailure: "Markdown 语法高亮暂时不可用。"
        }
    }
}

enum MarkdownHighlighter {
    static func spans(in source: String) throws -> [MarkdownSyntaxSpan] {
        guard InflowCoreBridge.isCompatible else {
            throw MarkdownHighlightError.coreFailure
        }

        let sourceUTF8 = Data(source.utf8)
        let result: InflowHighlightResult = sourceUTF8.withUnsafeBytes { buffer in
            inflow_markdown_highlight(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        defer {
            inflow_owned_highlight_spans_free(result.spans.data, result.spans.length)
        }

        guard result.status == INFLOW_STATUS_OK else {
            throw MarkdownHighlightError.coreFailure
        }
        guard let count = Int(exactly: result.spans.length) else {
            throw MarkdownHighlightError.invalidCoreResult
        }
        let maximumCount = sourceUTF8.count.multipliedReportingOverflow(by: 4)
        guard !maximumCount.overflow,
              count <= max(1, maximumCount.partialValue),
              count == 0 || result.spans.data != nil
        else {
            throw MarkdownHighlightError.invalidCoreResult
        }

        let rawSpans = UnsafeBufferPointer(start: result.spans.data, count: count)
        var kinds: [MarkdownSyntaxKind] = []
        var utf8Ranges: [Range<Int>] = []
        kinds.reserveCapacity(count)
        utf8Ranges.reserveCapacity(count)
        for rawSpan in rawSpans {
            guard let kind = MarkdownSyntaxKind(rawValue: rawSpan.kind),
                  let start = Int(exactly: rawSpan.source_start),
                  let end = Int(exactly: rawSpan.source_end),
                  start >= 0,
                  start < end,
                  end <= sourceUTF8.count
            else {
                throw MarkdownHighlightError.invalidCoreResult
            }
            kinds.append(kind)
            utf8Ranges.append(start..<end)
        }
        guard let utf16Ranges = MarkdownSyntaxRange.utf16Ranges(
            for: utf8Ranges,
            in: source
        ) else {
            throw MarkdownHighlightError.invalidCoreResult
        }
        let spans = zip(zip(kinds, utf8Ranges), utf16Ranges).map { element in
            let ((kind, utf8Range), utf16Range) = element
            return MarkdownSyntaxSpan(
                kind: kind,
                utf8Range: utf8Range,
                utf16Range: utf16Range
            )
        }
        return spans.sorted {
            let leftPriority = stylingPriority($0.kind)
            let rightPriority = stylingPriority($1.kind)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            if $0.utf8Range.lowerBound != $1.utf8Range.lowerBound {
                return $0.utf8Range.lowerBound < $1.utf8Range.lowerBound
            }
            return $0.utf8Range.upperBound > $1.utf8Range.upperBound
        }
    }

    private static func stylingPriority(_ kind: MarkdownSyntaxKind) -> Int {
        switch kind {
        case .blockQuote, .list, .table, .rule: 0
        case .heading: 1
        case .emphasis, .strong, .strikethrough: 2
        case .link, .image, .footnote, .math: 3
        case .raw: 4
        case .code: 5
        }
    }
}
