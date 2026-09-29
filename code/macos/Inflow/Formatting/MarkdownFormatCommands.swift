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

            Button("删除线") { actions?.apply(.inline(.strikethrough)) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(actions?.canFormat != true)
            Divider()
            Menu("标题") {
                ForEach(MarkdownHeadingLevel.allCases) { level in
                    Button(level.label) {
                        actions?.apply(.heading(level))
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(level.rawValue))), modifiers: [.command, .option])
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
            .keyboardShortcut("`", modifiers: [.command, .shift])
            .disabled(actions?.canFormat != true)
            Button("代码块") { actions?.apply(.codeBlock) }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(actions?.canFormat != true)
            Divider()
            Button("清除格式") { actions?.apply(.clear) }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(actions?.canClearFormat != true)
        }
        CommandGroup(after: .pasteboard) {
            Button("复制为 Markdown") {
                NSApp.sendAction(#selector(WindowAwareTextView.copyAsMarkdown(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(actions == nil)
            Button("粘贴为纯文本") {
                NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(actions?.canFormat != true)
        }
    }
}
