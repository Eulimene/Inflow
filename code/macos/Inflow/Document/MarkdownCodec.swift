import Foundation

enum MarkdownLineEnding: UInt8, Equatable, Sendable {
    case lf = 0
    case crlf = 1

    var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        }
    }
}

struct MarkdownFileProperties: Equatable, Sendable {
    var hasUTF8BOM: Bool
    var lineEnding: MarkdownLineEnding
    var requiresLineEndingChoice: Bool

    init(
        hasUTF8BOM: Bool,
        lineEnding: MarkdownLineEnding,
        requiresLineEndingChoice: Bool = false
    ) {
        self.hasUTF8BOM = hasUTF8BOM
        self.lineEnding = lineEnding
        self.requiresLineEndingChoice = requiresLineEndingChoice
    }

    static let newDocument = MarkdownFileProperties(
        hasUTF8BOM: false,
        lineEnding: .lf,
        requiresLineEndingChoice: false
    )
}

struct DecodedMarkdown: Equatable, Sendable {
    var text: String
    var properties: MarkdownFileProperties
}

enum MarkdownCodecError: Error, Equatable, LocalizedError {
    case invalidArgument
    case invalidUTF8
    case mixedLineEndings
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .invalidArgument:
            "无法读取该 Markdown 文件。"
        case .invalidUTF8:
            "该文件不是可编辑的 UTF-8 文本。原文件未被修改。"
        case .mixedLineEndings:
            "该文件同时包含 LF 和 CRLF 换行。选择统一换行方式前不会写回原文件。"
        case .coreFailure:
            "Markdown 核心暂时无法处理该文件。原文件未被修改。"
        }
    }
}

enum MarkdownCodec {
    static func decode(_ data: Data) throws -> DecodedMarkdown {
        let result: InflowDocumentOpenResult = data.withUnsafeBytes { buffer in
            inflow_document_open(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        guard result.status == INFLOW_STATUS_OK else {
            throw error(for: result.status)
        }

        let decodedData: Data
        do {
            decodedData = try InflowCoreBridge.copyAndFree(result.utf8)
        } catch {
            throw MarkdownCodecError.coreFailure
        }
        guard let text = String(data: decodedData, encoding: .utf8) else {
            throw MarkdownCodecError.coreFailure
        }
        guard let lineEnding = MarkdownLineEnding(rawValue: result.line_ending) else {
            throw MarkdownCodecError.coreFailure
        }

        return DecodedMarkdown(
            text: text,
            properties: MarkdownFileProperties(
                hasUTF8BOM: result.has_utf8_bom != 0,
                lineEnding: lineEnding,
                requiresLineEndingChoice: result.requires_line_ending_choice != 0
            )
        )
    }

    static func encode(
        _ text: String,
        properties: MarkdownFileProperties
    ) throws -> Data {
        guard !properties.requiresLineEndingChoice else {
            throw MarkdownCodecError.mixedLineEndings
        }
        let utf8 = Data(text.utf8)
        let result: InflowEncodeResult = utf8.withUnsafeBytes { buffer in
            inflow_document_encode(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count),
                properties.hasUTF8BOM ? 1 : 0,
                properties.lineEnding.rawValue
            )
        }
        guard result.status == INFLOW_STATUS_OK else {
            throw error(for: result.status)
        }

        do {
            return try InflowCoreBridge.copyAndFree(result.bytes)
        } catch {
            throw MarkdownCodecError.coreFailure
        }
    }

    private static func error(for status: InflowStatus) -> MarkdownCodecError {
        switch status {
        case INFLOW_STATUS_INVALID_ARGUMENT:
            .invalidArgument
        case INFLOW_STATUS_INVALID_UTF8:
            .invalidUTF8
        case INFLOW_STATUS_MIXED_LINE_ENDINGS:
            .mixedLineEndings
        default:
            .coreFailure
        }
    }
}
