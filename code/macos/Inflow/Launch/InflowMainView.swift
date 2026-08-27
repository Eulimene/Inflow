import SwiftUI

enum InflowMainWindow {
    static let title = "Inflow"
}

@MainActor
struct InflowMainView: View {
    @ObservedObject var recentDocuments: RecentDocumentsController
    @ObservedObject var folderBrowser: FolderBrowserController
    let onNewDocument: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if folderBrowser.folderURL != nil {
                FolderBrowserSidebar(
                    controller: folderBrowser,
                    currentDocumentURL: nil,
                    onOpenDocument: recentDocuments.openDocumentFromFolder
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
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                welcome
                primaryActions
                recentDocumentsSection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 52)
            .padding(.vertical, 46)
        }
    }

    private var welcome: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 48, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Inflow")
                    .font(.largeTitle.bold())
                Text("专注于本地 Markdown 写作")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var primaryActions: some View {
        HStack(spacing: 12) {
            Button {
                onNewDocument()
            } label: {
                Label("新建 Markdown", systemImage: "square.and.pencil")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)

            Button {
                recentDocuments.chooseDocumentToOpen()
            } label: {
                Label("打开文件…", systemImage: "doc")
                    .frame(minWidth: 105)
            }
            .buttonStyle(.bordered)

            Button {
                folderBrowser.chooseFolder()
            } label: {
                Label("打开文件夹…", systemImage: "folder")
                    .frame(minWidth: 115)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var recentDocumentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近文档")
                    .font(.headline)
                Spacer()
                if !recentDocuments.entries.isEmpty {
                    Button("清除记录") {
                        recentDocuments.clear()
                    }
                    .buttonStyle(.link)
                }
            }

            if recentDocuments.entries.isEmpty {
                ContentUnavailableView(
                    "还没有最近文档",
                    systemImage: "clock",
                    description: Text("新建文档，或从文件、文件夹中打开 Markdown。")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(recentDocuments.entries.prefix(8)),
                        id: \RecentDocumentEntry.id
                    ) { (entry: RecentDocumentEntry) in
                        VStack(spacing: 0) {
                            if entry.id != recentDocuments.entries.first?.id {
                                Divider().padding(.leading, 38)
                            }
                            Button {
                                recentDocuments.openRecentDocument(entry)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: entry.isAvailable
                                            ? "doc.text"
                                            : "questionmark.folder"
                                    )
                                    .foregroundStyle(
                                        entry.isAvailable ? Color.secondary : Color.orange
                                    )
                                    .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.displayName)
                                            .lineLimit(1)
                                        Text(entry.record.exactPath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            .disabled(!entry.isAvailable)
                            .accessibilityLabel(
                                entry.isAvailable
                                    ? "打开 \(entry.displayName)"
                                    : "\(entry.displayName)，原位置不可用"
                            )
                        }
                    }
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
