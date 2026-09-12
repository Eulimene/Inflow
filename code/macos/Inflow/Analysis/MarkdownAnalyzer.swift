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
        guard let derived = EditorEngineDerivedContent.deriveSynchronously(source: markdown) else {
            throw MarkdownAnalysisError.coreFailure
        }
        return derived.analysis
    }
}
