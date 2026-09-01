import SwiftUI

@MainActor
final class MarkdownFormatCommandActions {
    let canFormat: Bool
    let canClearFormat: Bool
    let apply: (MarkdownFormatCommand) -> Void

    init(
        canFormat: Bool,
        canClearFormat: Bool,
        apply: @escaping (MarkdownFormatCommand) -> Void
    ) {
        self.canFormat = canFormat
        self.canClearFormat = canClearFormat
        self.apply = apply
    }
}

private struct MarkdownFormatActionsFocusedKey: FocusedValueKey {
    typealias Value = MarkdownFormatCommandActions
}

extension FocusedValues {
    var markdownFormatActions: MarkdownFormatCommandActions? {
        get { self[MarkdownFormatActionsFocusedKey.self] }
        set { self[MarkdownFormatActionsFocusedKey.self] = newValue }
    }
}

struct MarkdownFormatCommands: Commands {
    @FocusedValue(\.markdownFormatActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            Button(MarkdownInlineFormat.bold.label) {
                actions?.apply(.inline(.bold))
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(actions?.canFormat != true)

            Button(MarkdownInlineFormat.italic.label) {
                actions?.apply(.inline(.italic))
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(actions?.canFormat != true)

            Menu("标题") {
                ForEach(MarkdownHeadingLevel.allCases) { level in
                    Button(level.label) {
                        actions?.apply(.heading(level))
                    }
                    .disabled(actions?.canFormat != true)
                }
            }

            Button("引用") {
                actions?.apply(.blockQuote)
            }
            .disabled(actions?.canFormat != true)

            Menu("列表") {
                ForEach(MarkdownListFormat.allCases) { format in
                    Button(format.label) {
                        actions?.apply(.list(format))
                    }
                    .disabled(actions?.canFormat != true)
                }
            }

            Button("行内代码") {
                actions?.apply(.inlineCode)
            }
            .disabled(actions?.canFormat != true)

        }
    }
}
