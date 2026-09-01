import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DocumentRelocationOperation: String, Sendable {
    case saveAs
    case saveCopy

    var panelTitle: String {
        switch self {
        case .saveAs: "另存 Markdown 文档"
        case .saveCopy: "保存 Markdown 副本"
        }
    }

    var actionTitle: String {
        switch self {
        case .saveAs: "另存为"
        case .saveCopy: "保存副本"
        }
    }

    var nativeOperation: NSDocument.SaveOperationType {
        switch self {
        case .saveAs: .saveAsOperation
        case .saveCopy: .saveToOperation
        }
    }
}

@MainActor
final class DocumentSaveCommandActions {
    let isBusy: Bool
    let canSave: Bool
    let save: () -> Void
    let saveAs: () -> Void
    let showInFinder: (() -> Void)?

    init(
        isBusy: Bool,
        canSave: Bool = true,
        save: @escaping () -> Void,
        saveAs: @escaping () -> Void,
        showInFinder: (() -> Void)?
    ) {
        self.isBusy = isBusy
        self.canSave = canSave
        self.save = save
        self.saveAs = saveAs
        self.showInFinder = showInFinder
    }
}

private struct DocumentSaveActionsFocusedKey: FocusedValueKey {
    typealias Value = DocumentSaveCommandActions
}

extension FocusedValues {
    var documentSaveActions: DocumentSaveCommandActions? {
        get { self[DocumentSaveActionsFocusedKey.self] }
        set { self[DocumentSaveActionsFocusedKey.self] = newValue }
    }
}

struct DocumentSaveCommands: Commands {
    @FocusedValue(\.documentSaveActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("保存") { actions?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(
                    actions == nil || actions?.isBusy == true || actions?.canSave != true
                )

            Button("另存为…") { actions?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions == nil || actions?.isBusy == true)

            Divider()

            Button("在 Finder 中显示") { actions?.showInFinder?() }
                .disabled(actions?.showInFinder == nil)
        }
    }
}

@MainActor
enum NativeDocumentSaveCoordinator {
    static func activeDocument(sourceURL: URL?) -> NSDocument? {
        if let sourceURL,
           let matched = NSDocumentController.shared.documents.first(where: {
               guard let fileURL = $0.fileURL else { return false }
               return DocumentRelocationAnalyzer.isSameFile(fileURL, sourceURL)
           })
        {
            return matched
        }
        return NSDocumentController.shared.currentDocument
            ?? NSApp.keyWindow?.windowController?.document as? NSDocument
    }

    static func documentAlreadyOpen(
        at targetURL: URL,
        excluding currentDocument: NSDocument?
    ) -> NSDocument? {
        NSDocumentController.shared.documents.first { candidate in
            guard candidate !== currentDocument, let fileURL = candidate.fileURL else {
                return false
            }
            return DocumentRelocationAnalyzer.isSameFile(fileURL, targetURL)
        }
    }

    static func represents(_ document: NSDocument, sourceURL: URL?) -> Bool {
        switch (document.fileURL, sourceURL) {
        case (nil, nil): true
        case let (documentURL?, sourceURL?):
            DocumentRelocationAnalyzer.isSameFile(documentURL, sourceURL)
        default: false
        }
    }

    static func save(
        document: NSDocument,
        to targetURL: URL,
        operation: DocumentRelocationOperation
    ) async throws {
        try await save(
            document: document,
            to: targetURL,
            operation: operation.nativeOperation
        )
    }

    static func saveCurrent(document: NSDocument, to targetURL: URL) async throws {
        try await save(document: document, to: targetURL, operation: .saveOperation)
    }

    /// Revert stays on AppKit's document lifecycle path so its change count and
    /// undo ownership are updated by the same document that owns the window.
    static func revert(document: NSDocument, from sourceURL: URL) throws {
        try document.revert(
            toContentsOf: sourceURL,
            ofType: document.fileType ?? UTType.inflowMarkdown.identifier
        )
    }

    private static func save(
        document: NSDocument,
        to targetURL: URL,
        operation: NSDocument.SaveOperationType
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            document.save(
                to: targetURL,
                ofType: document.fileType ?? UTType.inflowMarkdown.identifier,
                for: operation
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
