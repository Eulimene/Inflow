import AppKit
import SwiftUI

enum ReadOnlyDocumentPrompt {
    static let message = "你可以阅读、复制或将它另存到其他位置。"
    static let saveAsTitle = "另存为…"
    static let showInFinderTitle = "在 Finder 中显示"
    static let closeTitle = "关闭"

    static func title(filename: String) -> String {
        "「\(filename)」是只读的"
    }
}

enum ExternalFileChangePrompt {
    static let diskOnlyMessage = "你没有未保存更改，可以查看变化并采用磁盘版本。"
    static let conflictMessage = "为避免覆盖，自动保存已暂停。请对照最近成功保存版本、当前编辑和磁盘版本。"
    static let reloadConfirmationTitle = "放弃当前编辑并重新载入？"
    static let reloadConfirmationMessage = "当前未保存更改将被放弃，且无法通过撤销恢复。"
    static let overwriteConfirmationTitle = "覆盖磁盘上的新版本？"
    static let overwriteConfirmationMessage = "先保存当前磁盘版本的冲突副本，然后写入你的编辑。"
    static let overwriteFailureTitle = "无法安全覆盖"
    static let overwriteFailureMessage = "未能保存磁盘当前版本的冲突副本，因此没有执行覆盖。"
    static let deletedMessage = "当前编辑仍已保留，且不会自动重建原文件。"
    static let viewChangesTitle = "查看变化…"
    static let reloadTitle = "重新载入"
    static let reloadReviewTitle = "重新载入…"
    static let laterTitle = "稍后"
    static let compareTitle = "比较…"
    static let saveCopyTitle = "保存副本…"
    static let overwriteTitle = "覆盖磁盘版本…"
    static let saveAsTitle = "另存为…"
    static let recreateTitle = "在原位置重建…"
    static let handleLaterTitle = "稍后处理"

    static func diskOnlyTitle(filename: String) -> String {
        "「\(filename)」已有新内容"
    }

    static func conflictTitle(filename: String) -> String {
        "「\(filename)」已在其他位置更改"
    }

    static func deletedTitle(filename: String) -> String {
        "「\(filename)」已从磁盘删除"
    }
}

enum DocumentConflictDecision: String, Identifiable {
    case reload
    case overwrite
    case recreate

    var id: String { rawValue }
}

struct DocumentFileSafetyBanner: View {
    let state: DocumentFileSafetyState
    let deferredSnapshotID: DocumentFileConflictSnapshot.ID?
    let onCompare: () -> Void
    let onReload: (DocumentFileConflictSnapshot) -> Void
    let onOverwrite: (DocumentFileConflictSnapshot) -> Void
    let onRecreate: (DocumentFileConflictSnapshot) -> Void
    let onDefer: (DocumentFileConflictSnapshot) -> Void
    let onResume: () -> Void
    let onSaveAs: () -> Void
    let onSaveCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        switch state {
        case .safe:
            EmptyView()
        case let .readOnly(url):
            banner(
                icon: "lock.fill",
                title: ReadOnlyDocumentPrompt.title(filename: url.lastPathComponent),
                detail: ReadOnlyDocumentPrompt.message
            ) {
                Button(ReadOnlyDocumentPrompt.saveAsTitle, action: onSaveAs)
                Button(ReadOnlyDocumentPrompt.showInFinderTitle) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button(ReadOnlyDocumentPrompt.closeTitle, action: onClose)
            }
        case let .changed(snapshot):
            if deferredSnapshotID == snapshot.id {
                deferredBanner(
                    icon: "arrow.triangle.branch",
                    title: ExternalFileChangePrompt.diskOnlyTitle(
                        filename: snapshot.url.lastPathComponent
                    )
                )
            } else if snapshot.localHasChanges {
                banner(
                    icon: "arrow.triangle.branch",
                    title: ExternalFileChangePrompt.conflictTitle(
                        filename: snapshot.url.lastPathComponent
                    ),
                    detail: ExternalFileChangePrompt.conflictMessage
                ) {
                    Button(ExternalFileChangePrompt.compareTitle, action: onCompare)
                    Button(ExternalFileChangePrompt.saveCopyTitle, action: onSaveCopy)
                    Button(ExternalFileChangePrompt.reloadReviewTitle) { onReload(snapshot) }
                    Button(ExternalFileChangePrompt.overwriteTitle) { onOverwrite(snapshot) }
                }
            } else {
                banner(
                    icon: "arrow.triangle.branch",
                    title: ExternalFileChangePrompt.diskOnlyTitle(
                        filename: snapshot.url.lastPathComponent
                    ),
                    detail: ExternalFileChangePrompt.diskOnlyMessage
                ) {
                    Button(ExternalFileChangePrompt.viewChangesTitle, action: onCompare)
                    Button(ExternalFileChangePrompt.reloadTitle) { onReload(snapshot) }
                    Button(ExternalFileChangePrompt.laterTitle) { onDefer(snapshot) }
                }
            }
        case let .deleted(snapshot):
            if deferredSnapshotID == snapshot.id {
                deferredBanner(
                    icon: "doc.badge.ellipsis",
                    title: ExternalFileChangePrompt.deletedTitle(
                        filename: snapshot.url.lastPathComponent
                    )
                )
            } else {
                banner(
                    icon: "doc.badge.ellipsis",
                    title: ExternalFileChangePrompt.deletedTitle(
                        filename: snapshot.url.lastPathComponent
                    ),
                    detail: ExternalFileChangePrompt.deletedMessage
                ) {
                    Button(ExternalFileChangePrompt.saveAsTitle, action: onSaveAs)
                    Button(ExternalFileChangePrompt.recreateTitle) { onRecreate(snapshot) }
                    Button(ExternalFileChangePrompt.handleLaterTitle) { onDefer(snapshot) }
                }
            }
        }
    }

    private func deferredBanner(icon: String, title: String) -> some View {
        banner(
            icon: icon,
            title: title,
            detail: "自动保存仍已暂停；当前编辑仍已保留。"
        ) {
            Button("处理…", action: onResume)
        }
    }

    private func banner<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                actions()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
        .accessibilityElement(children: .contain)
    }
}

struct DocumentConflictReviewView: View {
    let snapshot: DocumentFileConflictSnapshot
    let initialDecision: DocumentConflictDecision?
    let onSaveCopy: () -> Void
    let onReload: () async throws -> Void
    let onOverwrite: () async throws -> URL
    let onRecreate: () async throws -> Void
    let onResolved: () -> Void
    let onClose: () -> Void

    @State private var pendingDecision: DocumentConflictDecision?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var conflictCopyFailure = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.diskExists ? "比较文档版本" : "原文件已删除")
                        .font(.title2.weight(.semibold))
                    Text(snapshot.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理文件冲突")
                }
                Button("完成", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
            }
            .padding(16)

            Divider()

            HSplitView {
                sourceColumn(title: "最近成功保存", text: snapshot.baselineText)
                sourceColumn(title: "当前编辑", text: snapshot.localText)
                sourceColumn(
                    title: "当前磁盘版本",
                    text: snapshot.diskExists
                        ? snapshot.diskText ?? "（无法以 UTF-8 Markdown 读取）"
                        : "（文件已删除）"
                )
            }
            .frame(minHeight: 420)

            Divider()

            HStack(spacing: 10) {
                Button(snapshot.diskExists ? "保存副本…" : "另存为…") {
                    onSaveCopy()
                }
                .disabled(isWorking)

                Spacer()

                if snapshot.diskExists {
                    Button(
                        snapshot.localHasChanges
                            ? ExternalFileChangePrompt.reloadReviewTitle
                            : ExternalFileChangePrompt.reloadTitle
                    ) {
                        if snapshot.localHasChanges {
                            pendingDecision = .reload
                        } else {
                            perform(.reload)
                        }
                    }
                    .disabled(isWorking || snapshot.diskText == nil)
                    Button(ExternalFileChangePrompt.overwriteTitle) {
                        pendingDecision = .overwrite
                    }
                    .disabled(isWorking || snapshot.diskData == nil)
                } else {
                    Button(ExternalFileChangePrompt.recreateTitle) {
                        pendingDecision = .recreate
                    }
                    .disabled(isWorking)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 1_020, minHeight: 600)
        .onAppear {
            guard pendingDecision == nil else { return }
            pendingDecision = initialDecision
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingDecision != nil },
                set: { if !$0 { pendingDecision = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let decision = pendingDecision {
                Button(
                    confirmationButton(for: decision),
                    role: decision == .reload ? .destructive : nil
                ) {
                    perform(decision)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let decision = pendingDecision {
                Text(confirmationMessage(for: decision))
            }
        }
        .alert(
            conflictCopyFailure
                ? ExternalFileChangePrompt.overwriteFailureTitle
                : "文件冲突尚未处理",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                        conflictCopyFailure = false
                    }
                }
            )
        ) {
            if conflictCopyFailure {
                Button("重试") {
                    errorMessage = nil
                    conflictCopyFailure = false
                    perform(.overwrite)
                }
                Button(ExternalFileChangePrompt.saveCopyTitle) {
                    errorMessage = nil
                    conflictCopyFailure = false
                    onSaveCopy()
                }
                Button("取消", role: .cancel) {}
            } else {
                Button("好", role: .cancel) {}
            }
        } message: {
            Text(errorMessage ?? "当前编辑和磁盘文件均未被丢弃。")
        }
    }

    private func sourceColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var confirmationTitle: String {
        switch pendingDecision {
        case .reload: ExternalFileChangePrompt.reloadConfirmationTitle
        case .overwrite: ExternalFileChangePrompt.overwriteConfirmationTitle
        case .recreate: "在原位置重建文件？"
        case nil: "确认文件操作"
        }
    }

    private func confirmationButton(for decision: DocumentConflictDecision) -> String {
        switch decision {
        case .reload: "重新载入"
        case .overwrite: "保存冲突副本并覆盖"
        case .recreate: "在原位置重建"
        }
    }

    private func confirmationMessage(for decision: DocumentConflictDecision) -> String {
        switch decision {
        case .reload:
            ExternalFileChangePrompt.reloadConfirmationMessage
        case .overwrite:
            ExternalFileChangePrompt.overwriteConfirmationMessage
        case .recreate:
            "只有原位置仍然没有文件时才会写入；若目标重新出现，本次操作会停止。"
        }
    }

    private func perform(_ decision: DocumentConflictDecision) {
        isWorking = true
        Task {
            do {
                switch decision {
                case .reload:
                    try await onReload()
                case .overwrite:
                    _ = try await onOverwrite()
                case .recreate:
                    try await onRecreate()
                }
                isWorking = false
                onResolved()
            } catch {
                isWorking = false
                if case .cannotCreateConflictCopy = error as? DocumentFileSafetyError {
                    conflictCopyFailure = true
                    errorMessage = ExternalFileChangePrompt.overwriteFailureMessage
                } else {
                    conflictCopyFailure = false
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "文件内容已再次变化，没有执行写入。"
                }
            }
        }
    }
}

enum DocumentFileSafetyNotice: Identifiable {
    case conflictCopySaved(URL)
    case copySaved(URL)
    case savedAs(URL)
    case failure(String)

    var id: String {
        switch self {
        case let .conflictCopySaved(url): "conflict-\(url.path)"
        case let .copySaved(url): "copy-\(url.path)"
        case let .savedAs(url): "save-as-\(url.path)"
        case let .failure(message): "failure-\(message)"
        }
    }

    var alert: Alert {
        switch self {
        case let .conflictCopySaved(url):
            Alert(
                title: Text("已安全覆盖"),
                message: Text("磁盘原版本已保存为「\(url.lastPathComponent)」。"),
                dismissButton: .default(Text("好"))
            )
        case let .copySaved(url):
            Alert(
                title: Text("副本已保存"),
                message: Text(url.path),
                dismissButton: .default(Text("好"))
            )
        case let .savedAs(url):
            Alert(
                title: Text("已另存为"),
                message: Text("当前窗口现在编辑：\(url.path)"),
                dismissButton: .default(Text("好"))
            )
        case let .failure(message):
            Alert(
                title: Text("文件操作未完成"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
