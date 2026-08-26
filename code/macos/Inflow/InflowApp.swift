import SwiftUI

private struct OutlineVisibilityFocusedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var outlineVisibility: Binding<Bool>? {
        get { self[OutlineVisibilityFocusedKey.self] }
        set { self[OutlineVisibilityFocusedKey.self] = newValue }
    }
}

private struct OutlineCommands: Commands {
    @FocusedValue(\.outlineVisibility) private var outlineVisibility

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(
                outlineVisibility?.wrappedValue == true ? "隐藏大纲" : "显示大纲"
            ) {
                outlineVisibility?.wrappedValue.toggle()
            }
            .disabled(outlineVisibility == nil)
        }
    }
}

@main
struct InflowApp: App {
    @StateObject private var recoveryCoordinator = DocumentRecoveryCoordinator()
    @StateObject private var preferences = AppPreferences()
    @StateObject private var anonymousUsage = AnonymousUsageDataController()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            MarkdownEditorView(
                document: configuration.$document,
                fileURL: configuration.fileURL,
                isEditable: configuration.isEditable,
                recoveryCoordinator: recoveryCoordinator,
                preferences: preferences,
                anonymousUsage: anonymousUsage
            )
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            DocumentSaveCommands()
            EditorViewModeCommands()
            PreviewZoomCommands()
            OutlineCommands()
            WritingModeCommands()
            DocumentFindCommands()
            HTMLExportCommands()
            MarkdownFormatCommands()
            MarkdownInsertCommands()
            InflowSupplementalCommands()
        }

        Window("Inflow 帮助", id: InflowHelpWindow.identifier) {
            InflowHelpView()
        }
        .defaultSize(width: 760, height: 680)

        Settings {
            InflowSettingsView(
                preferences: preferences,
                anonymousUsage: anonymousUsage
            )
        }
    }
}
