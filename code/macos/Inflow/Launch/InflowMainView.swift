import SwiftUI

enum InflowMainWindow {
    static let title = "Inflow"
}

@MainActor
struct InflowMainView: View {
    @ObservedObject var folderBrowser: FolderBrowserController
    let onOpenDocument: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if folderBrowser.folderURL != nil {
                FolderBrowserSidebar(
                    controller: folderBrowser,
                    currentDocumentURL: nil,
                    onOpenDocument: onOpenDocument
                )
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

                Divider()
            }

            launchContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Inflow")
    }

    private var launchContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 54, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("Inflow")
                .font(.largeTitle.bold())

            Text("专注于本地 Markdown 写作")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(workspaceGuidance)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .accessibilityElement(children: .combine)
    }

    private var workspaceGuidance: String {
        if folderBrowser.folderURL == nil {
            "从 macOS 顶部菜单栏的“文件”菜单新建 Markdown、打开文件或打开文件夹。"
        } else {
            "从左侧文件夹选择 Markdown，或继续使用顶部“文件”菜单。"
        }
    }
}
