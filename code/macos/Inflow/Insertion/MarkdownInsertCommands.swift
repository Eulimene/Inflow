import SwiftUI

@MainActor
final class MarkdownInsertCommandActions {
    let canInsert: Bool
    let insertLink: () -> Void
    let insertTable: () -> Void
    let insertHorizontalRule: () -> Void

    init(
        canInsert: Bool,
        insertLink: @escaping () -> Void,
        insertTable: @escaping () -> Void,
        insertHorizontalRule: @escaping () -> Void
    ) {
        self.canInsert = canInsert
        self.insertLink = insertLink
        self.insertTable = insertTable
        self.insertHorizontalRule = insertHorizontalRule
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

            Button("表格") {
                actions?.insertTable()
            }
            .disabled(actions?.canInsert != true)

            Button("分隔线") {
                actions?.insertHorizontalRule()
            }
            .disabled(actions?.canInsert != true)
        }
    }
}
