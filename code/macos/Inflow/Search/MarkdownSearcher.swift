import Foundation

enum UTF8Text {
    static func isExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count == rhs.utf8.count
            && lhs.utf8.elementsEqual(rhs.utf8)
    }
}

struct DocumentSearchMatch: Identifiable, Equatable, Sendable {
    let utf8Range: Range<Int>
    let matchedUTF8: Data

    var id: Int { utf8Range.lowerBound }
}

struct DocumentSearchResult: Sendable {
    let matches: [DocumentSearchMatch]
    let matchedTextCounts: [Data: Int]
}

enum MarkdownSearchError: Error, LocalizedError {
    case invalidCoreResult
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .invalidCoreResult:
            "查找结果无效。"
        case .coreFailure:
            "当前文档查找暂时不可用。"
        }
    }
}

enum MarkdownSearcher {
    static func matches(
        in source: String,
        query: String,
        caseSensitive: Bool
    ) throws -> [DocumentSearchMatch] {
        try searchResult(
            in: source,
            query: query,
            caseSensitive: caseSensitive
        ).matches
    }

    static func searchResult(
        in source: String,
        query: String,
        caseSensitive: Bool
    ) throws -> DocumentSearchResult {
        guard let result = DocumentSearchResult.searchSynchronously(
            source: source,
            query: query,
            caseSensitive: caseSensitive
        ) else {
            throw MarkdownSearchError.coreFailure
        }
        return result
    }
}

enum DocumentSearchOutcome: Sendable {
    case success(DocumentSearchResult)
    case failure(String)
}

actor DocumentSearchWorker {
    func search(
        source: String,
        query: String,
        caseSensitive: Bool
    ) -> DocumentSearchOutcome? {
        guard !Task.isCancelled else { return nil }
        do {
            let result = try MarkdownSearcher.searchResult(
                in: source,
                query: query,
                caseSensitive: caseSensitive
            )
            guard !Task.isCancelled else { return nil }
            return .success(result)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? MarkdownSearchError.coreFailure.localizedDescription
            return .failure(message)
        }
    }
}
