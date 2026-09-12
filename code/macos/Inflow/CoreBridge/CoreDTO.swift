import Foundation

struct EditorEngineDerivedContent: Sendable {
    let revision: UInt64
    let sourceSnapshot: String
    let htmlFragment: String
    let previewHTMLFragment: String
    let analysis: DocumentAnalysis
    let syntaxHighlighting: [MarkdownSyntaxSpan]
    let references: [MarkdownReference]
    let renderBlocks: [EditorEngineRenderBlock]
    let nativeRenderPlan: RenderedMarkdownPlan
}

struct EditorEngineRenderBlock: Equatable, Sendable {
    let id: String
    let kind: String
    let sourceUTF8Range: Range<Int>
    let depth: Int
    let parentID: String?
    let visibleText: String
}

struct EditorEngineTextEdit: Equatable, Sendable {
    let start: Int
    let end: Int
    let inserted: String
}

struct EditorEngineMutation: Equatable, Sendable {
    let baseRevision: UInt64
    let revision: UInt64
    let sourceSnapshot: String
    let replaceUTF8Range: Range<Int>
    let replacement: String
    let resultingSource: String
    let selectionUTF8Range: Range<Int>
    let canUndo: Bool
    let canRedo: Bool
}

struct EditorEngineDocumentSnapshot: Equatable, Sendable {
    let revision: UInt64
    let text: String
    let selectionUTF8Range: Range<Int>
    let mode: EditorEngineMode
    let contentHash: String
    let canUndo: Bool
    let canRedo: Bool
    let dirty: Bool
}

enum EditorEngineMode: String, Codable, Equatable, Sendable {
    case editable
    case readOnly = "read_only"
}

struct EditorEngineSavePreparation: Equatable, Sendable {
    let saveID: String
    let revision: UInt64
    let text: String
    let contentHash: String
}

struct EditorEngineHTMLExportPreparation: Equatable, Sendable {
    let html: String
    let warnings: UInt64
}

enum EditorEngineHTMLExportPreparationError: Error, Sendable {
    case outputTooLarge
    case coreFailure
}

enum EditorEngineDocumentCodecError: Error, Sendable {
    case invalidUTF8
    case mixedLineEndings
    case coreFailure
}

enum EditorEngineFormatOperation: Equatable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock
    case clear
    case heading(level: UInt8)
    case blockQuote
    case list(style: String)
    case link(destination: String)
    case image(destination: String, defaultAlternative: String)
    case table(columns: UInt8, rows: UInt8)
    case horizontalRule
    case footnote
    case math
    case mermaid
}

enum EditorEngineTextDiff {
    static func replacement(from old: String, to new: String) -> EditorEngineTextEdit? {
        guard !old.utf8.elementsEqual(new.utf8) else { return nil }

        var oldPrefix = old.startIndex
        var newPrefix = new.startIndex
        while sameNextGrapheme(old, at: oldPrefix, new, at: newPrefix) {
            old.formIndex(after: &oldPrefix)
            new.formIndex(after: &newPrefix)
        }

        var oldSuffix = old.endIndex
        var newSuffix = new.endIndex
        while oldSuffix > oldPrefix, newSuffix > newPrefix {
            let oldPrevious = old.index(before: oldSuffix)
            let newPrevious = new.index(before: newSuffix)
            guard old[oldPrevious..<oldSuffix].utf8.elementsEqual(
                new[newPrevious..<newSuffix].utf8
            ) else { break }
            oldSuffix = oldPrevious
            newSuffix = newPrevious
        }

        let start = old[..<oldPrefix].utf8.count
        return EditorEngineTextEdit(
            start: start,
            end: start + old[oldPrefix..<oldSuffix].utf8.count,
            inserted: String(new[newPrefix..<newSuffix])
        )
    }

    private static func sameNextGrapheme(
        _ old: String,
        at oldIndex: String.Index,
        _ new: String,
        at newIndex: String.Index
    ) -> Bool {
        guard oldIndex < old.endIndex, newIndex < new.endIndex else { return false }
        let oldNext = old.index(after: oldIndex)
        let newNext = new.index(after: newIndex)
        return old[oldIndex..<oldNext].utf8.elementsEqual(new[newIndex..<newNext].utf8)
    }
}
