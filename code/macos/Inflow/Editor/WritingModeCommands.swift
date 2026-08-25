import SwiftUI

@MainActor
final class WritingModeCommandActions {
    let isFocusModeEnabled: Bool
    let isTypewriterModeEnabled: Bool
    let canEdit: Bool
    let setFocusMode: (Bool) -> Void
    let setTypewriterMode: (Bool) -> Void

    init(
        isFocusModeEnabled: Bool,
        isTypewriterModeEnabled: Bool,
        canEdit: Bool,
        setFocusMode: @escaping (Bool) -> Void,
        setTypewriterMode: @escaping (Bool) -> Void
    ) {
        self.isFocusModeEnabled = isFocusModeEnabled
        self.isTypewriterModeEnabled = isTypewriterModeEnabled
        self.canEdit = canEdit
        self.setFocusMode = setFocusMode
        self.setTypewriterMode = setTypewriterMode
    }

    var canToggleFocusMode: Bool { canEdit || isFocusModeEnabled }
    var canToggleTypewriterMode: Bool { canEdit || isTypewriterModeEnabled }

    var focusModeBinding: Binding<Bool> {
        Binding(
            get: { self.isFocusModeEnabled },
            set: { self.setFocusMode($0) }
        )
    }

    var typewriterModeBinding: Binding<Bool> {
        Binding(
            get: { self.isTypewriterModeEnabled },
            set: { self.setTypewriterMode($0) }
        )
    }
}

private struct WritingModeActionsFocusedKey: FocusedValueKey {
    typealias Value = WritingModeCommandActions
}

extension FocusedValues {
    var writingModeActions: WritingModeCommandActions? {
        get { self[WritingModeActionsFocusedKey.self] }
        set { self[WritingModeActionsFocusedKey.self] = newValue }
    }
}

struct WritingModeCommands: Commands {
    @FocusedValue(\.writingModeActions) private var actions

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Toggle(
                "专注模式",
                isOn: actions?.focusModeBinding ?? .constant(false)
            )
            .disabled(actions?.canToggleFocusMode != true)

            Toggle(
                "打字机模式",
                isOn: actions?.typewriterModeBinding ?? .constant(false)
            )
            .disabled(actions?.canToggleTypewriterMode != true)
        }
    }
}
