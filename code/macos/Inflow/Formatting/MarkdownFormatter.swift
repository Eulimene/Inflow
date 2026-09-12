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

enum MarkdownHeadingLevel: UInt8, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5
    case six = 6

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .one: "一级标题"
        case .two: "二级标题"
        case .three: "三级标题"
        case .four: "四级标题"
        case .five: "五级标题"
        case .six: "六级标题"
        }
    }
}

enum MarkdownListFormat: UInt8, CaseIterable, Identifiable, Sendable {
    case ordered = 2
    case unordered = 1
    case task = 3

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .ordered: "有序"
        case .unordered: "无序"
        case .task: "任务"
        }
    }

    var coreValue: UInt8 {
        switch self {
        case .ordered: UInt8(INFLOW_LIST_FORMAT_ORDERED)
        case .unordered: UInt8(INFLOW_LIST_FORMAT_UNORDERED)
        case .task: UInt8(INFLOW_LIST_FORMAT_TASK)
        }
    }
}

enum MarkdownFormatCommand: Equatable, Sendable {
    case inline(MarkdownInlineFormat)
    case inlineCode
    case codeBlock
    case heading(MarkdownHeadingLevel)
    case blockQuote
    case list(MarkdownListFormat)
    case clear

    var undoActionName: String {
        switch self {
        case let .inline(format): format.undoActionName
        case .inlineCode: "行内代码格式"
        case .codeBlock: "代码块格式"
        case .heading: "标题格式"
        case .blockQuote: "引用格式"
        case .list: "列表格式"
        case .clear: "清除格式标记"
        }
    }
}

extension MarkdownFormatCommand {
    var engineOperation: EditorEngineFormatOperation {
        switch self {
        case let .inline(format):
            switch format {
            case .bold: return .bold
            case .italic: return .italic
            case .strikethrough: return .strikethrough
            }
        case .inlineCode: return .inlineCode
        case .codeBlock: return .codeBlock
        case .heading(let level): return .heading(level: level.rawValue)
        case .blockQuote: return .blockQuote
        case .list(let format):
            let style: String
            switch format {
            case .ordered: style = "ordered"
            case .unordered: style = "unordered"
            case .task: style = "task"
            }
            return .list(style: style)
        case .clear: return .clear
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
    case invalidDestination
    case invalidSelection
    case invalidCoreResult
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .ambiguousSelection:
            "当前选区包含部分或混合格式，或无法形成有效的 Markdown 结构。请调整选区后重试。"
        case .invalidDestination:
            "链接地址不能为空，也不能包含换行、控制字符、尖括号或反斜杠。正文未被修改。"
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
    static func canClearFormat(
        source: String,
        selectedUTF16Range: NSRange
    ) -> Bool {
        EditorEngineSynchronousCommands.canClearFormat(
            source: source,
            selectedUTF16Range: selectedUTF16Range
        )
    }

    static func mermaidPlan(
        source: String,
        selectedUTF16Range: NSRange
    ) throws -> MarkdownFormatPlan {
        try enginePlan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            operation: .mermaid
        )
    }

    static func mathPlan(
        source: String,
        selectedUTF16Range: NSRange
    ) throws -> MarkdownFormatPlan {
        try enginePlan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            operation: .math
        )
    }

    static func footnotePlan(
        source: String,
        selectedUTF16Range: NSRange
    ) throws -> MarkdownFormatPlan {
        try enginePlan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            operation: .footnote
        )
    }

    static func horizontalRulePlan(
        source: String,
        selectedUTF16Range: NSRange
    ) throws -> MarkdownFormatPlan {
        try enginePlan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            operation: .horizontalRule
        )
    }

    static func tablePlan(
        source: String,
        selectedUTF16Range: NSRange
    ) throws -> MarkdownFormatPlan {
        try enginePlan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            operation: .table
        )
    }

    static func linkPlan(
        source: String,
        selectedUTF16Range: NSRange,
        destination: String
    ) throws -> MarkdownFormatPlan {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty,
              !destination.unicodeScalars.contains(where: {
                  $0.value < 0x20
                      || $0.value == 0x7F
                      || $0 == "<"
                      || $0 == ">"
                      || $0 == "\\"
              })
        else {
            throw MarkdownFormatError.invalidDestination
        }
        do {
            return try enginePlan(
                source: source,
                selectedUTF16Range: selectedUTF16Range,
                operation: .link(destination: destination)
            )
        } catch MarkdownFormatError.invalidSelection {
            throw MarkdownFormatError.invalidDestination
        }
    }

    static func imagePlan(
        source: String,
        selectedUTF16Range: NSRange,
        destination: String,
        defaultAlternative: String
    ) throws -> MarkdownFormatPlan {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultAlternative = defaultAlternative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty,
              !defaultAlternative.isEmpty,
              !destination.unicodeScalars.contains(where: {
                  $0.value < 0x20
                      || $0.value == 0x7F
                      || $0 == "<"
                      || $0 == ">"
                      || $0 == "\\"
              }),
              !defaultAlternative.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            throw MarkdownFormatError.invalidDestination
        }
        do {
            return try enginePlan(
                source: source,
                selectedUTF16Range: selectedUTF16Range,
                operation: .image(
                    destination: destination,
                    defaultAlternative: defaultAlternative
                )
            )
        } catch MarkdownFormatError.invalidSelection {
            throw MarkdownFormatError.invalidDestination
        }
    }

    static func plan(
        source: String,
        selectedUTF16Range: NSRange,
        format: MarkdownInlineFormat
    ) throws -> MarkdownFormatPlan {
        try plan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            command: .inline(format)
        )
    }

    static func plan(
        source: String,
        selectedUTF16Range: NSRange,
        heading: MarkdownHeadingLevel
    ) throws -> MarkdownFormatPlan {
        try plan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            command: .heading(heading)
        )
    }

    static func plan(
        source: String,
        selectedUTF16Range: NSRange,
        command: MarkdownFormatCommand
    ) throws -> MarkdownFormatPlan {
        try enginePlan(
            source: source,
            selectedUTF16Range: selectedUTF16Range,
            operation: command.engineOperation
        )
    }

    private static func enginePlan(
        source: String,
        selectedUTF16Range: NSRange,
        operation: EditorEngineFormatOperation
    ) throws -> MarkdownFormatPlan {
        do {
            let mutation = try EditorEngineSynchronousCommands.format(
                source: source,
                selectedUTF16Range: selectedUTF16Range,
                operation: operation
            )
            return MarkdownFormatPlan(
                sourceSnapshot: mutation.sourceSnapshot,
                replaceUTF8Range: mutation.replaceUTF8Range,
                replacement: mutation.replacement,
                resultingSource: mutation.resultingSource,
                selectionUTF8Range: mutation.selectionUTF8Range
            )
        } catch EditorEngineSynchronousCommandError.invalidSelection {
            throw MarkdownFormatError.invalidSelection
        } catch EditorEngineSynchronousCommandError.ambiguousFormat {
            throw MarkdownFormatError.ambiguousSelection
        } catch EditorEngineSynchronousCommandError.invalidResponse {
            throw MarkdownFormatError.invalidCoreResult
        } catch {
            throw MarkdownFormatError.coreFailure
        }
    }

}
