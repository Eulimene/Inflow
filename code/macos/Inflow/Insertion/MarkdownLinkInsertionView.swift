import AppKit
import SwiftUI

struct MarkdownLinkInsertionRequest: Identifiable {
    let id = UUID()
    let sourceSnapshot: String
    let selectedUTF16Range: NSRange

    var selectedLabel: String {
        guard selectedUTF16Range.length > 0 else { return "链接文字" }
        return (sourceSnapshot as NSString).substring(with: selectedUTF16Range)
    }
}

struct MarkdownLinkInsertionView: View {
    let request: MarkdownLinkInsertionRequest
    let onCancel: () -> Void
    let onInsert: (String) -> Void

    @State private var destination = "https://"

    private var normalizedDestination: String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("插入链接")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("链接文字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(request.selectedLabel)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            LiteralLinkDestinationField(
                text: $destination,
                accessibilityLabel: "链接地址或相对路径",
                onSubmit: submit
            )
            .frame(height: 24)

            Text("支持 HTTP(S)、mailto、文档内锚点和相对路径。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("插入", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedDestination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        guard !normalizedDestination.isEmpty else { return }
        onInsert(normalizedDestination)
    }
}

struct LiteralLinkDestinationField: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WindowAwareLinkTextField {
        let textField = WindowAwareLinkTextField(string: text)
        textField.placeholderString = accessibilityLabel
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.isAutomaticTextCompletionEnabled = false
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        context.coordinator.textField = textField
        textField.didAttachToWindow = { [weak textField] in
            guard let textField, let window = textField.window else { return }
            _ = window.makeFirstResponder(textField)
            context.coordinator.configureCurrentEditor()
        }
        return textField
    }

    func updateNSView(_ textField: WindowAwareLinkTextField, context: Context) {
        context.coordinator.parent = self
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.isAutomaticTextCompletionEnabled = false
        if !UTF8Text.isExactlyEqual(textField.stringValue, text) {
            textField.stringValue = text
        }
        context.coordinator.configureCurrentEditor()
    }

    static func dismantleNSView(
        _ textField: WindowAwareLinkTextField,
        coordinator: Coordinator
    ) {
        textField.delegate = nil
        textField.target = nil
        textField.didAttachToWindow = nil
    }

    static func configureLiteralInput(_ editor: NSTextView) {
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LiteralLinkDestinationField
        weak var textField: NSTextField?

        init(parent: LiteralLinkDestinationField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            textField = notification.object as? NSTextField
            configureCurrentEditor()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            self.textField = textField
            let updated = textField.stringValue
            guard !UTF8Text.isExactlyEqual(parent.text, updated) else { return }
            parent.text = updated
        }

        func configureCurrentEditor() {
            guard let editor = textField?.currentEditor() as? NSTextView else { return }
            LiteralLinkDestinationField.configureLiteralInput(editor)
        }

        @objc func submit() {
            parent.onSubmit()
        }
    }
}

@MainActor
final class WindowAwareLinkTextField: NSTextField {
    var didAttachToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            didAttachToWindow?()
        }
    }
}
