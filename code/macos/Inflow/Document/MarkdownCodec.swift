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
        do {
            return try EditorEngineDocumentCodec.decodeSynchronously(data)
        } catch EditorEngineDocumentCodecError.invalidUTF8 {
            throw MarkdownCodecError.invalidUTF8
        } catch EditorEngineDocumentCodecError.mixedLineEndings {
            throw MarkdownCodecError.mixedLineEndings
        } catch {
            throw MarkdownCodecError.coreFailure
        }
    }

    static func encode(
        _ text: String,
        properties: MarkdownFileProperties
    ) throws -> Data {
        guard !properties.requiresLineEndingChoice else {
            throw MarkdownCodecError.mixedLineEndings
        }
        do {
            return try EditorEngineDocumentCodec.encodeSynchronously(
                text,
                properties: properties
            )
        } catch {
            throw MarkdownCodecError.coreFailure
        }
    }
}
