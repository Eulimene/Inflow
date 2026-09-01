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
    static let diskOnlyMessage = "你没有未保存更改。可以重新载入磁盘内容，或暂不处理。"
    static let conflictMessage = "磁盘内容与当前编辑都已保留。重新载入会采用磁盘版本；再次手动保存时会先询问是否覆盖。"
    static let reloadConfirmationTitle = "放弃当前编辑并重新载入？"
    static let reloadConfirmationMessage = "当前未保存更改将被放弃，且无法通过撤销恢复。"
    static let overwriteConfirmationTitle = "覆盖磁盘上的新版本？"
    static let overwriteConfirmationMessage = "确认后将用当前编辑覆盖磁盘内容；取消时两份内容都保持不变。"
    static let deletedMessage = "当前编辑仍已保留，且不会自动重建原文件。"
    static let reloadTitle = "重新载入"
    static let reloadReviewTitle = "重新载入…"
    static let laterTitle = "稍后"
    static let overwriteTitle = "覆盖磁盘版本…"
    static let saveAsTitle = "另存为…"
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

    var id: String { rawValue }
}

struct DocumentFileSafetyBanner: View {
    let state: DocumentFileSafetyState
    let deferredSnapshotID: DocumentFileConflictSnapshot.ID?
    let onReload: (DocumentFileConflictSnapshot) -> Void
    let onDefer: (DocumentFileConflictSnapshot) -> Void
    let onResume: () -> Void
    let onSaveAs: () -> Void
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
                    Button(ExternalFileChangePrompt.reloadReviewTitle) { onReload(snapshot) }
                    Button(ExternalFileChangePrompt.laterTitle) { onDefer(snapshot) }
                }
            } else {
                banner(
                    icon: "arrow.triangle.branch",
                    title: ExternalFileChangePrompt.diskOnlyTitle(
                        filename: snapshot.url.lastPathComponent
                    ),
                    detail: ExternalFileChangePrompt.diskOnlyMessage
                ) {
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
                    Button(ExternalFileChangePrompt.handleLaterTitle) { onDefer(snapshot) }
                }
            }
        }
    }

    private func deferredBanner(icon: String, title: String) -> some View {
        banner(
            icon: icon,
            title: title,
            detail: "当前编辑仍已保留；再次手动保存前会先确认是否覆盖。"
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
    let onReload: () async throws -> Void
    let onOverwrite: () async throws -> Void
    let onResolved: () -> Void
    let onClose: () -> Void

    @State private var pendingDecision: DocumentConflictDecision?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(reviewTitle)
                        .font(.title2.weight(.semibold))
                    Text(reviewMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理文件冲突")
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(cancelTitle, action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)

                Spacer()

                Button(actionTitle) {
                    pendingDecision = presentedDecision
                }
                .disabled(isWorking || !canPerformPresentedDecision)
            }
        }
        .padding(20)
        .frame(minWidth: 520, maxWidth: 620, minHeight: 210)
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
                    role: .destructive
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
            "文件冲突尚未处理",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "当前编辑和磁盘文件均未被丢弃。")
        }
    }

    private var presentedDecision: DocumentConflictDecision {
        initialDecision ?? .reload
    }

    private var reviewTitle: String {
        switch presentedDecision {
        case .reload:
            ExternalFileChangePrompt.conflictTitle(filename: snapshot.url.lastPathComponent)
        case .overwrite:
            ExternalFileChangePrompt.overwriteConfirmationTitle
        }
    }

    private var reviewMessage: String {
        switch presentedDecision {
        case .reload:
            snapshot.localHasChanges
                ? ExternalFileChangePrompt.reloadConfirmationMessage
                : ExternalFileChangePrompt.diskOnlyMessage
        case .overwrite:
            ExternalFileChangePrompt.overwriteConfirmationMessage
        }
    }

    private var cancelTitle: String {
        presentedDecision == .reload ? ExternalFileChangePrompt.laterTitle : "取消"
    }

    private var actionTitle: String {
        switch presentedDecision {
        case .reload: ExternalFileChangePrompt.reloadReviewTitle
        case .overwrite: ExternalFileChangePrompt.overwriteTitle
        }
    }

    private var canPerformPresentedDecision: Bool {
        guard snapshot.diskExists else { return false }
        switch presentedDecision {
        case .reload: return snapshot.diskText != nil
        case .overwrite: return snapshot.localHasChanges
        }
    }

    private var confirmationTitle: String {
        switch pendingDecision {
        case .reload: ExternalFileChangePrompt.reloadConfirmationTitle
        case .overwrite: ExternalFileChangePrompt.overwriteConfirmationTitle
        case nil: "确认文件操作"
        }
    }

    private func confirmationButton(for decision: DocumentConflictDecision) -> String {
        switch decision {
        case .reload: "重新载入"
        case .overwrite: "明确覆盖"
        }
    }

    private func confirmationMessage(for decision: DocumentConflictDecision) -> String {
        switch decision {
        case .reload:
            ExternalFileChangePrompt.reloadConfirmationMessage
        case .overwrite:
            ExternalFileChangePrompt.overwriteConfirmationMessage
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
                    try await onOverwrite()
                }
                isWorking = false
                onResolved()
            } catch {
                isWorking = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "文件内容已再次变化，没有执行写入。"
            }
        }
    }
}

enum DocumentFileSafetyNotice: Identifiable {
    case copySaved(URL)
    case savedAs(URL)
    case failure(String)

    var id: String {
        switch self {
        case let .copySaved(url): "copy-\(url.path)"
        case let .savedAs(url): "save-as-\(url.path)"
        case let .failure(message): "failure-\(message)"
        }
    }

    var alert: Alert {
        switch self {
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
