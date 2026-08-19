import AppKit
import SwiftUI

struct DocumentFindCommandActions {
    let hasQuery: Bool
    let canReplace: Bool
    let showFind: () -> Void
    let showReplace: () -> Void
    let next: () -> Void
    let previous: () -> Void
}

private struct DocumentFindActionsFocusedKey: FocusedValueKey {
    typealias Value = DocumentFindCommandActions
}

extension FocusedValues {
    var documentFindActions: DocumentFindCommandActions? {
        get { self[DocumentFindActionsFocusedKey.self] }
        set { self[DocumentFindActionsFocusedKey.self] = newValue }
    }
}

struct DocumentFindCommands: Commands {
    @FocusedValue(\.documentFindActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Menu("查找") {
                Button("查找…") {
                    actions?.showFind()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)

                Button("查找与替换…") {
                    actions?.showReplace()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil || actions?.canReplace != true)

                Divider()

                Button("查找下一个") {
                    actions?.next()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.hasQuery != true)

                Button("查找上一个") {
                    actions?.previous()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.hasQuery != true)
            }

            Menu("拼写与语法") {
                responderButton("显示拼写与语法", action: "showGuessPanel:")
                responderButton("立即检查文稿", action: "checkSpelling:")
                    .keyboardShortcut(";", modifiers: .command)
                Divider()
                responderToggle("键入时检查拼写", command: .continuousSpellChecking)
                responderToggle("检查语法", command: .grammarChecking)
                responderToggle("自动纠正拼写", command: .automaticSpellingCorrection)
            }

            Menu("文本替换") {
                responderButton("显示文本替换", action: "orderFrontSubstitutionsPanel:")
                Divider()
                responderToggle("智能拷贝/粘贴", command: .smartInsertDelete)
                responderToggle("智能引号", command: .automaticQuoteSubstitution)
                responderToggle("智能破折号", command: .automaticDashSubstitution)
                responderToggle("智能链接", command: .automaticLinkDetection)
                responderToggle("数据检测器", command: .automaticDataDetection)
                responderToggle("文本替换", command: .automaticTextReplacement)
            }

            Menu("转换") {
                responderButton("全部大写", action: "uppercaseWord:")
                responderButton("全部小写", action: "lowercaseWord:")
                responderButton("首字母大写", action: "capitalizeWord:")
            }

            Menu("语音") {
                responderButton("开始朗读", action: "startSpeaking:")
                responderButton("停止朗读", action: "stopSpeaking:")
            }
        }
    }

    private func responderButton(_ title: String, action: String) -> some View {
        let selector = Selector((action))
        return Button(title) {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
        .disabled(!responderCanPerform(selector))
    }

    private func responderToggle(
        _ title: String,
        command: ResponderTextToggle
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { command.isOnCurrentResponder },
                set: { _ in
                    NSApp.sendAction(command.selector, to: nil, from: nil)
                }
            )
        )
        .disabled(!responderCanPerform(command.selector))
    }

    private func responderCanPerform(_ selector: Selector) -> Bool {
        guard let target = NSApp.target(forAction: selector, to: nil, from: nil) else {
            return false
        }
        guard let validator = target as? NSUserInterfaceValidations else {
            return true
        }

        let item = NSMenuItem()
        item.action = selector
        return validator.validateUserInterfaceItem(item)
    }
}

enum ResponderTextToggle {
    case continuousSpellChecking
    case grammarChecking
    case automaticSpellingCorrection
    case smartInsertDelete
    case automaticQuoteSubstitution
    case automaticDashSubstitution
    case automaticLinkDetection
    case automaticDataDetection
    case automaticTextReplacement

    var selector: Selector {
        switch self {
        case .continuousSpellChecking:
            #selector(NSTextView.toggleContinuousSpellChecking(_:))
        case .grammarChecking:
            #selector(NSTextView.toggleGrammarChecking(_:))
        case .automaticSpellingCorrection:
            #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))
        case .smartInsertDelete:
            #selector(NSTextView.toggleSmartInsertDelete(_:))
        case .automaticQuoteSubstitution:
            #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))
        case .automaticDashSubstitution:
            #selector(NSTextView.toggleAutomaticDashSubstitution(_:))
        case .automaticLinkDetection:
            #selector(NSTextView.toggleAutomaticLinkDetection(_:))
        case .automaticDataDetection:
            #selector(NSTextView.toggleAutomaticDataDetection(_:))
        case .automaticTextReplacement:
            #selector(NSTextView.toggleAutomaticTextReplacement(_:))
        }
    }

    @MainActor
    var isOnCurrentResponder: Bool {
        guard let textView = NSApp.target(
            forAction: selector,
            to: nil,
            from: nil
        ) as? NSTextView else {
            return false
        }
        return isOn(textView)
    }

    @MainActor
    func isOn(_ textView: NSTextView) -> Bool {
        switch self {
        case .continuousSpellChecking:
            textView.isContinuousSpellCheckingEnabled
        case .grammarChecking:
            textView.isGrammarCheckingEnabled
        case .automaticSpellingCorrection:
            textView.isAutomaticSpellingCorrectionEnabled
        case .smartInsertDelete:
            textView.smartInsertDeleteEnabled
        case .automaticQuoteSubstitution:
            textView.isAutomaticQuoteSubstitutionEnabled
        case .automaticDashSubstitution:
            textView.isAutomaticDashSubstitutionEnabled
        case .automaticLinkDetection:
            textView.isAutomaticLinkDetectionEnabled
        case .automaticDataDetection:
            textView.isAutomaticDataDetectionEnabled
        case .automaticTextReplacement:
            textView.isAutomaticTextReplacementEnabled
        }
    }
}
