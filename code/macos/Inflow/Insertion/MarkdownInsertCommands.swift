import SwiftUI

@MainActor
final class MarkdownInsertCommandActions {
    let canInsert: Bool
    let insertLink: () -> Void
    let insertImage: () -> Void
    let insertTable: () -> Void
    let insertHorizontalRule: () -> Void
    let insertFootnote: () -> Void
    let insertFormula: () -> Void
    let insertDiagram: () -> Void

    init(
        canInsert: Bool,
        insertLink: @escaping () -> Void,
        insertImage: @escaping () -> Void,
        insertTable: @escaping () -> Void,
        insertHorizontalRule: @escaping () -> Void,
        insertFootnote: @escaping () -> Void,
        insertFormula: @escaping () -> Void,
        insertDiagram: @escaping () -> Void
    ) {
        self.canInsert = canInsert
        self.insertLink = insertLink
        self.insertImage = insertImage
        self.insertTable = insertTable
        self.insertHorizontalRule = insertHorizontalRule
        self.insertFootnote = insertFootnote
        self.insertFormula = insertFormula
        self.insertDiagram = insertDiagram
    }
}

private struct MarkdownInsertActionsFocusedKey: FocusedValueKey {
    typealias Value = MarkdownInsertCommandActions
}

extension FocusedValues {
    var markdownInsertActions: MarkdownInsertCommandActions? {
        get { self[MarkdownInsertActionsFocusedKey.self] }
        set { self[MarkdownInsertActionsFocusedKey.self] = newValue }
    }
}

struct MarkdownInsertCommands: Commands {
    @FocusedValue(\.markdownInsertActions) private var actions

    var body: some Commands {
        CommandMenu("插入") {
            Button("链接…") {
                actions?.insertLink()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(actions?.canInsert != true)

            Button("图片…") {
                actions?.insertImage()
            }
            .disabled(actions?.canInsert != true)

            Button("表格") {
                actions?.insertTable()
            }
            .disabled(actions?.canInsert != true)

        }
    }
}
