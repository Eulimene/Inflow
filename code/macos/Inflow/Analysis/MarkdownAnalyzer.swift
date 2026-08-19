import Foundation

struct DocumentHeading: Identifiable, Equatable, Sendable {
    let level: Int
    let title: String
    let sourceUTF8Range: Range<Int>

    var id: Int { sourceUTF8Range.lowerBound }

    var displayTitle: String {
        title.isEmpty ? "未命名标题" : title
    }
}

struct DocumentAnalysis: Equatable, Sendable {
    let headings: [DocumentHeading]
    let wordCount: Int
    let characterCountIncludingSpaces: Int
    let characterCountExcludingSpaces: Int

    static let empty = DocumentAnalysis(
        headings: [],
        wordCount: 0,
        characterCountIncludingSpaces: 0,
        characterCountExcludingSpaces: 0
    )
}

enum DocumentAnalysisState: Equatable, Sendable {
    case updating(previous: DocumentAnalysis)
    case ready(DocumentAnalysis)
    case failed(previous: DocumentAnalysis, message: String)

    var displayedAnalysis: DocumentAnalysis {
        switch self {
        case let .updating(previous), let .failed(previous, _):
            previous
        case let .ready(analysis):
            analysis
        }
    }

    var allowsNavigation: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum MarkdownAnalysisError: Error, LocalizedError {
    case invalidUTF8
    case invalidCoreResult
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "统计输入不是有效的 UTF-8 文本。"
        case .invalidCoreResult:
            "Markdown 分析结果无效。"
        case .coreFailure:
            "Markdown 结构分析暂时不可用。"
        }
    }
}

enum MarkdownAnalyzer {
    static func analyze(_ markdown: String) throws -> DocumentAnalysis {
        guard InflowCoreBridge.isCompatible else {
            throw MarkdownAnalysisError.coreFailure
        }

        let utf8 = Data(markdown.utf8)
        let result: InflowAnalysisResult = utf8.withUnsafeBytes { buffer in
            inflow_document_analyze(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        defer {
            inflow_owned_headings_free(result.headings.data, result.headings.length)
            inflow_owned_bytes_free(
                result.heading_text_utf8.data,
                result.heading_text_utf8.length
            )
        }

        guard result.status == INFLOW_STATUS_OK else {
            if result.status == INFLOW_STATUS_INVALID_UTF8 {
                throw MarkdownAnalysisError.invalidUTF8
            }
            throw MarkdownAnalysisError.coreFailure
        }

        let headingCount = try checkedInt(result.headings.length)
        guard headingCount == 0 || result.headings.data != nil else {
            throw MarkdownAnalysisError.invalidCoreResult
        }

        let titleData = try copy(result.heading_text_utf8)
        let rawHeadings = UnsafeBufferPointer(
            start: result.headings.data,
            count: headingCount
        )
        var headings: [DocumentHeading] = []
        headings.reserveCapacity(headingCount)

        for rawHeading in rawHeadings {
            let level = Int(rawHeading.level)
            guard (1...6).contains(level) else {
                throw MarkdownAnalysisError.invalidCoreResult
            }

            let sourceRange = try checkedRange(
                start: rawHeading.source_start,
                end: rawHeading.source_end,
                upperBound: utf8.count
            )
            let titleRange = try checkedRange(
                start: rawHeading.title_start,
                length: rawHeading.title_length,
                upperBound: titleData.count
            )
            guard let title = String(data: titleData.subdata(in: titleRange), encoding: .utf8) else {
                throw MarkdownAnalysisError.invalidCoreResult
            }

            headings.append(
                DocumentHeading(
                    level: level,
                    title: title,
                    sourceUTF8Range: sourceRange
                )
            )
        }

        return DocumentAnalysis(
            headings: headings,
            wordCount: try checkedInt(result.word_count),
            characterCountIncludingSpaces: try checkedInt(
                result.character_count_with_spaces
            ),
            characterCountExcludingSpaces: try checkedInt(
                result.character_count_without_spaces
            )
        )
    }

    private static func copy(_ bytes: InflowOwnedBytes) throws -> Data {
        let count = try checkedInt(bytes.length)
        guard count > 0 else { return Data() }
        guard let pointer = bytes.data else {
            throw MarkdownAnalysisError.invalidCoreResult
        }
        return Data(bytes: pointer, count: count)
    }

    private static func checkedRange(
        start: UInt,
        end: UInt,
        upperBound: Int
    ) throws -> Range<Int> {
        guard start <= end else {
            throw MarkdownAnalysisError.invalidCoreResult
        }
        return try checkedRange(
            start: start,
            length: end - start,
            upperBound: upperBound
        )
    }

    private static func checkedRange(
        start: UInt,
        length: UInt,
        upperBound: Int
    ) throws -> Range<Int> {
        let start = try checkedInt(start)
        let length = try checkedInt(length)
        let (end, overflow) = start.addingReportingOverflow(length)
        guard !overflow, start <= end, end <= upperBound else {
            throw MarkdownAnalysisError.invalidCoreResult
        }
        return start..<end
    }

    private static func checkedInt<T: BinaryInteger>(_ value: T) throws -> Int {
        guard let value = Int(exactly: value) else {
            throw MarkdownAnalysisError.invalidCoreResult
        }
        return value
    }
}
