import Foundation

enum MarkdownInlineFormat: UInt8, CaseIterable, Sendable {
    case bold = 1
    case italic = 2
    case strikethrough = 3

    var label: String {
        switch self {
        case .bold: "粗体"
        case .italic: "斜体"
        case .strikethrough: "删除线"
        }
    }

    var undoActionName: String {
        switch self {
        case .bold: "粗体格式"
        case .italic: "斜体格式"
        case .strikethrough: "删除线格式"
        }
    }

    var coreValue: UInt8 {
        switch self {
        case .bold: UInt8(INFLOW_INLINE_FORMAT_BOLD)
        case .italic: UInt8(INFLOW_INLINE_FORMAT_ITALIC)
        case .strikethrough: UInt8(INFLOW_INLINE_FORMAT_STRIKETHROUGH)
        }
    }
}

struct MarkdownFormatPlan: Sendable {
    let sourceSnapshot: String
    let replaceUTF8Range: Range<Int>
    let replacement: String
    let resultingSource: String
    let selectionUTF8Range: Range<Int>
}

enum MarkdownFormatError: Error, LocalizedError {
    case ambiguousSelection
    case invalidSelection
    case invalidCoreResult
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .ambiguousSelection:
            "当前选区只覆盖了部分或混合格式，或无法形成有效的行内 Markdown。请调整选区后重试。"
        case .invalidSelection:
            "当前选区无法安全映射到完整字符，请调整选区后重试。"
        case .invalidCoreResult:
            "格式计划无效，正文未被修改。"
        case .coreFailure:
            "Markdown 格式功能暂时不可用，正文未被修改。"
        }
    }
}

enum MarkdownFormatter {
    static func plan(
        source: String,
        selectedUTF16Range: NSRange,
        format: MarkdownInlineFormat
    ) throws -> MarkdownFormatPlan {
        guard InflowCoreBridge.isCompatible else {
            throw MarkdownFormatError.coreFailure
        }
        guard let selectedUTF8Range = MarkdownSourceRange.utf8Range(
            forUTF16Range: selectedUTF16Range,
            in: source
        ) else {
            throw MarkdownFormatError.invalidSelection
        }

        let sourceUTF8 = Data(source.utf8)
        let result: InflowMarkdownEditResult = sourceUTF8.withUnsafeBytes { buffer in
            inflow_markdown_format_inline(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count),
                UInt(selectedUTF8Range.lowerBound),
                UInt(selectedUTF8Range.upperBound),
                format.coreValue
            )
        }

        guard result.status == INFLOW_STATUS_OK else {
            inflow_owned_bytes_free(result.replacement.data, result.replacement.length)
            switch result.status {
            case INFLOW_STATUS_AMBIGUOUS_FORMAT:
                throw MarkdownFormatError.ambiguousSelection
            case INFLOW_STATUS_INVALID_ARGUMENT:
                throw MarkdownFormatError.invalidSelection
            default:
                throw MarkdownFormatError.coreFailure
            }
        }

        let replacementData: Data
        do {
            replacementData = try InflowCoreBridge.copyAndFree(result.replacement)
        } catch {
            throw MarkdownFormatError.invalidCoreResult
        }
        guard let replacement = String(data: replacementData, encoding: .utf8),
              let replaceStart = Int(exactly: result.replace_start),
              let replaceEnd = Int(exactly: result.replace_end),
              let selectionStart = Int(exactly: result.selection_start),
              let selectionEnd = Int(exactly: result.selection_end),
              replaceStart >= 0,
              replaceStart <= replaceEnd,
              replaceEnd <= sourceUTF8.count,
              MarkdownSourceRange.navigationTarget(
                  forUTF8Range: replaceStart..<replaceEnd,
                  in: source
              ) != nil
        else {
            throw MarkdownFormatError.invalidCoreResult
        }

        var resultingUTF8 = Data()
        resultingUTF8.reserveCapacity(
            sourceUTF8.count - (replaceEnd - replaceStart) + replacementData.count
        )
        resultingUTF8.append(sourceUTF8.prefix(replaceStart))
        resultingUTF8.append(replacementData)
        resultingUTF8.append(sourceUTF8.suffix(from: replaceEnd))
        guard let resultingSource = String(data: resultingUTF8, encoding: .utf8),
              selectionStart >= 0,
              selectionStart <= selectionEnd,
              selectionEnd <= resultingUTF8.count,
              MarkdownSourceRange.navigationTarget(
                  forUTF8Range: selectionStart..<selectionEnd,
                  in: resultingSource
              ) != nil
        else {
            throw MarkdownFormatError.invalidCoreResult
        }

        return MarkdownFormatPlan(
            sourceSnapshot: source,
            replaceUTF8Range: replaceStart..<replaceEnd,
            replacement: replacement,
            resultingSource: resultingSource,
            selectionUTF8Range: selectionStart..<selectionEnd
        )
    }
}
