import SwiftUI

@MainActor
final class InflowApplicationDelegate: NSObject, NSApplicationDelegate {
    let recentDocuments: RecentDocumentsController
    let folderBrowser: FolderBrowserController
    private let createUntitledDocument: (Any?) -> Void

    override convenience init() {
        self.init { sender in
            NSDocumentController.shared.newDocument(sender)
        }
    }

    init(createUntitledDocument: @escaping (Any?) -> Void) {
        let controller = RecentDocumentsController()
        controller.installMenuIntegration()
        recentDocuments = controller
        folderBrowser = FolderBrowserController()
        self.createUntitledDocument = createUntitledDocument
        super.init()
    }

    func application(_: NSApplication, open urls: [URL]) {
        recentDocuments.openExternalDocuments(urls)
    }

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        InflowLaunchPolicy.automaticallyOpensUntitledDocument
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        createUntitledDocument(sender)
        return true
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        createUntitledDocument(nil)
        return true
    }
}

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

private struct InflowPrimaryCommands: Commands {
    let folderBrowser: FolderBrowserController

    var body: some Commands {
        DocumentSaveCommands()
        FolderBrowserCommands(controller: folderBrowser)
        EditorViewModeCommands()
        PreviewZoomCommands()
        OutlineCommands()
        WritingModeCommands()
    }
}

private struct InflowEditingCommands: Commands {
    var body: some Commands {
        DocumentFindCommands()
        HTMLExportCommands()
        MarkdownFormatCommands()
        MarkdownInsertCommands()
        InflowSupplementalCommands()
    }
}

@main
struct InflowApp: App {
    @NSApplicationDelegateAdaptor(InflowApplicationDelegate.self)
    private var applicationDelegate
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
                anonymousUsage: anonymousUsage,
                recentDocuments: applicationDelegate.recentDocuments,
                folderBrowser: applicationDelegate.folderBrowser
            )
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1_080, height: 720)
        .commands {
            InflowPrimaryCommands(folderBrowser: applicationDelegate.folderBrowser)
            InflowEditingCommands()
        }

        Window("Inflow 帮助", id: InflowHelpWindow.identifier) {
            InflowHelpView()
        }
        .defaultSize(width: 760, height: 680)

        Settings {
            InflowSettingsView(
                preferences: preferences,
                anonymousUsage: anonymousUsage,
                recentDocuments: applicationDelegate.recentDocuments
            )
        }
    }
}
