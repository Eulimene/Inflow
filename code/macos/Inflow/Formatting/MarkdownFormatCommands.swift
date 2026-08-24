import SwiftUI

@MainActor
final class MarkdownFormatCommandActions {
    let canFormat: Bool
    let apply: (MarkdownFormatCommand) -> Void

    init(canFormat: Bool, apply: @escaping (MarkdownFormatCommand) -> Void) {
        self.canFormat = canFormat
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

            Button(MarkdownInlineFormat.strikethrough.label) {
                actions?.apply(.inline(.strikethrough))
            }
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
        }
    }
}
