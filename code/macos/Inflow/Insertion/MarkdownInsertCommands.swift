import SwiftUI

@MainActor
final class MarkdownInsertCommandActions {
    let canInsert: Bool
    let insertLink: () -> Void
    let insertTable: () -> Void

    init(
        canInsert: Bool,
        insertLink: @escaping () -> Void,
        insertTable: @escaping () -> Void
    ) {
        self.canInsert = canInsert
        self.insertLink = insertLink
        self.insertTable = insertTable
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
        }
    }
}
