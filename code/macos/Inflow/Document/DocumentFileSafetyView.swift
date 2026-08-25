import AppKit
import SwiftUI

struct DocumentFileSafetyBanner: View {
    let state: DocumentFileSafetyState
    let onCompare: () -> Void
    let onSaveCopy: () -> Void

    var body: some View {
        switch state {
        case .safe:
            EmptyView()
        case let .readOnly(url):
            banner(
                icon: "lock.fill",
                title: "只读",
                detail: "「\(url.lastPathComponent)」当前不可写。可以复制内容或另存到其他位置。"
            ) {
                Button("另存副本…", action: onSaveCopy)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        case let .changed(snapshot):
            banner(
                icon: "arrow.triangle.branch",
                title: "自动保存已暂停",
                detail: snapshot.localHasChanges
                    ? "「\(snapshot.url.lastPathComponent)」已在其他位置更改，且当前编辑也有变化。"
                    : "「\(snapshot.url.lastPathComponent)」已在其他位置更改。"
            ) {
                Button("比较…", action: onCompare)
                Button("保存副本…", action: onSaveCopy)
            }
        case let .deleted(snapshot):
            banner(
                icon: "doc.badge.ellipsis",
                title: "原文件已删除",
                detail: "「\(snapshot.url.lastPathComponent)」不会被自动重建；当前编辑仍已保留。"
            ) {
                Button("处理…", action: onCompare)
                Button("另存副本…", action: onSaveCopy)
            }
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
    let onSaveCopy: () -> Void
    let onReload: () async throws -> Void
    let onOverwrite: () async throws -> URL
    let onRecreate: () async throws -> Void
    let onResolved: () -> Void
    let onClose: () -> Void

    @State private var pendingDecision: ConflictDecision?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private enum ConflictDecision: String, Identifiable {
        case reload
        case overwrite
        case recreate

        var id: String { rawValue }
    }

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
                    Button("重新载入…") {
                        pendingDecision = .reload
                    }
                    .disabled(isWorking || snapshot.diskText == nil)
                    Button("保存冲突副本并覆盖…") {
                        pendingDecision = .overwrite
                    }
                    .disabled(isWorking || snapshot.diskData == nil)
                } else {
                    Button("在原位置重建…") {
                        pendingDecision = .recreate
                    }
                    .disabled(isWorking)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 1_020, minHeight: 600)
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
            "文件冲突尚未处理",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
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
        case .reload: "放弃当前编辑并重新载入？"
        case .overwrite: "覆盖磁盘上的新版本？"
        case .recreate: "在原位置重建文件？"
        case nil: "确认文件操作"
        }
    }

    private func confirmationButton(for decision: ConflictDecision) -> String {
        switch decision {
        case .reload: "重新载入"
        case .overwrite: "保存冲突副本并覆盖"
        case .recreate: "在原位置重建"
        }
    }

    private func confirmationMessage(for decision: ConflictDecision) -> String {
        switch decision {
        case .reload:
            "当前未保存编辑将被放弃，且无法通过撤销恢复。"
        case .overwrite:
            "Inflow 会先在同一目录保存当前磁盘版本的冲突副本，成功后才写入当前编辑。"
        case .recreate:
            "只有原位置仍然没有文件时才会写入；若目标重新出现，本次操作会停止。"
        }
    }

    private func perform(_ decision: ConflictDecision) {
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
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "文件内容已再次变化，没有执行写入。"
            }
        }
    }
}

enum DocumentFileSafetyNotice: Identifiable {
    case conflictCopySaved(URL)
    case copySaved(URL)
    case failure(String)

    var id: String {
        switch self {
        case let .conflictCopySaved(url): "conflict-\(url.path)"
        case let .copySaved(url): "copy-\(url.path)"
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
        case let .failure(message):
            Alert(
                title: Text("文件操作未完成"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
