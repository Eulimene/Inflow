import SwiftUI

@MainActor
final class MarkdownInsertCommandActions {
    let canInsert: Bool
    let insertLink: () -> Void
    let insertImage: () -> Void
    let insertTable: (_ columns: UInt8, _ rows: UInt8) -> Void
    let presentTableInsertion: () -> Void
    let insertHorizontalRule: () -> Void
    let insertFootnote: () -> Void
    let insertFormula: () -> Void
    let insertDiagram: () -> Void

    init(
        canInsert: Bool,
        insertLink: @escaping () -> Void,
        insertImage: @escaping () -> Void,
        insertTable: @escaping (_ columns: UInt8, _ rows: UInt8) -> Void,
        presentTableInsertion: @escaping () -> Void,
        insertHorizontalRule: @escaping () -> Void,
        insertFootnote: @escaping () -> Void,
        insertFormula: @escaping () -> Void,
        insertDiagram: @escaping () -> Void
    ) {
        self.canInsert = canInsert
        self.insertLink = insertLink
        self.insertImage = insertImage
        self.insertTable = insertTable
        self.presentTableInsertion = presentTableInsertion
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

            Menu("表格") {
                Button("2 列 × 2 行") {
                    actions?.insertTable(2, 2)
                }
                Button("3 列 × 3 行") {
                    actions?.insertTable(3, 3)
                }
                Button("4 列 × 4 行") {
                    actions?.insertTable(4, 4)
                }
                Divider()
                Button("自定义表格…") {
                    actions?.presentTableInsertion()
                }
            }
            .disabled(actions?.canInsert != true)

        }
    }
}
