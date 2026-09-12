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
        guard let derived = EditorEngineDerivedContent.deriveSynchronously(source: source) else {
            throw MarkdownHighlightError.coreFailure
        }
        return derived.syntaxHighlighting
    }
}
