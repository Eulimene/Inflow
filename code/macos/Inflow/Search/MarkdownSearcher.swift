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
        guard InflowCoreBridge.isCompatible else {
            throw MarkdownSearchError.coreFailure
        }

        let sourceUTF8 = Data(source.utf8)
        let queryUTF8 = Data(query.utf8)
        let result: InflowSearchResult = sourceUTF8.withUnsafeBytes { sourceBuffer in
            queryUTF8.withUnsafeBytes { queryBuffer in
                inflow_document_search(
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(sourceBuffer.count),
                    queryBuffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(queryBuffer.count),
                    caseSensitive ? 1 : 0
                )
            }
        }
        defer {
            inflow_owned_search_matches_free(result.matches.data, result.matches.length)
        }

        guard result.status == INFLOW_STATUS_OK else {
            throw MarkdownSearchError.coreFailure
        }

        let count = try checkedInt(result.matches.length)
        guard count == 0 || result.matches.data != nil else {
            throw MarkdownSearchError.invalidCoreResult
        }

        let rawMatches = UnsafeBufferPointer(start: result.matches.data, count: count)
        var matches: [DocumentSearchMatch] = []
        matches.reserveCapacity(count)
        var matchedTextCounts: [Data: Int] = [:]
        var previousEnd = 0

        for rawMatch in rawMatches {
            let start = try checkedInt(rawMatch.source_start)
            let end = try checkedInt(rawMatch.source_end)
            guard start >= previousEnd,
                  start < end,
                  end <= sourceUTF8.count,
                  MarkdownSourceRange.navigationTarget(
                      forUTF8Range: start..<end,
                      in: source
                  ) != nil
            else {
                throw MarkdownSearchError.invalidCoreResult
            }

            let matchedUTF8 = sourceUTF8.subdata(in: start..<end)
            matches.append(
                DocumentSearchMatch(
                    utf8Range: start..<end,
                    matchedUTF8: matchedUTF8
                )
            )
            matchedTextCounts[matchedUTF8, default: 0] += 1
            previousEnd = end
        }

        return DocumentSearchResult(
            matches: matches,
            matchedTextCounts: matchedTextCounts
        )
    }

    private static func checkedInt<T: BinaryInteger>(_ value: T) throws -> Int {
        guard let value = Int(exactly: value) else {
            throw MarkdownSearchError.invalidCoreResult
        }
        return value
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
