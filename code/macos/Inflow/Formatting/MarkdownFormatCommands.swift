import SwiftUI

@MainActor
final class MarkdownFormatCommandActions {
    let canFormat: Bool
    let apply: (MarkdownInlineFormat) -> Void

    init(canFormat: Bool, apply: @escaping (MarkdownInlineFormat) -> Void) {
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
                actions?.apply(.bold)
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(actions?.canFormat != true)

            Button(MarkdownInlineFormat.italic.label) {
                actions?.apply(.italic)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(actions?.canFormat != true)

            Button(MarkdownInlineFormat.strikethrough.label) {
                actions?.apply(.strikethrough)
            }
            .disabled(actions?.canFormat != true)
        }
    }
}
