import SwiftUI

@MainActor
final class EditorViewModeCommandActions {
    let selectedMode: EditorViewMode
    let select: (EditorViewMode) -> Void

    init(
        selectedMode: EditorViewMode,
        select: @escaping (EditorViewMode) -> Void
    ) {
        self.selectedMode = selectedMode
        self.select = select
    }

    func selectionBinding(for mode: EditorViewMode) -> Binding<Bool> {
        Binding(
            get: { self.selectedMode == mode },
            set: { isSelected in
                guard isSelected else { return }
                self.select(mode)
            }
        )
    }
}

private struct EditorViewModeActionsFocusedKey: FocusedValueKey {
    typealias Value = EditorViewModeCommandActions
}

extension FocusedValues {
    var editorViewModeActions: EditorViewModeCommandActions? {
        get { self[EditorViewModeActionsFocusedKey.self] }
        set { self[EditorViewModeActionsFocusedKey.self] = newValue }
    }
}

struct EditorViewModeCommands: Commands {
    @FocusedValue(\.editorViewModeActions) private var actions

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            modeToggle(.source, shortcut: "1")
            modeToggle(.split, shortcut: "2")
            modeToggle(.preview, shortcut: "3")
            Divider()
        }
    }

    private func modeToggle(
        _ mode: EditorViewMode,
        shortcut: KeyEquivalent
    ) -> some View {
        Toggle(
            mode.label,
            isOn: actions?.selectionBinding(for: mode) ?? .constant(false)
        )
        .keyboardShortcut(shortcut, modifiers: .command)
        .disabled(actions == nil)
    }
}
