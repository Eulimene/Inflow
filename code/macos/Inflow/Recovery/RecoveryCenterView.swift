import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RecoveryProtectionPrompt {
    static let title = "恢复保护暂时不可用"
    static let retryTitle = "重试保护"
    static let continueTitle = "继续写作"
}

enum RecoveryOriginalChangePrompt {
    static let title = "恢复内容不会覆盖原文件"
    static let message = "原文件已经变化。请比较后将恢复内容作为未命名文档打开或另存。"
    static let compareTitle = "查看差异…"
    static let openTitle = "打开恢复文档"
    static let saveAsTitle = "另存为…"
    static let closeTitle = "关闭"
}

enum RecoveryDiskPreview: Equatable, Sendable {
    case unnamed
    case missing(URL)
    case unavailable(URL)
    case readable(URL, text: String, matchesRecovery: Bool)

    var status: String {
        switch self {
        case .unnamed:
            "这份恢复内容尚未选择磁盘位置。"
        case let .missing(url):
            "原文件已不存在：\(url.path)"
        case let .unavailable(url):
            "暂时无法读取原文件：\(url.path)"
        case let .readable(url, _, true):
            "磁盘文件与恢复内容当前一致：\(url.path)"
        case let .readable(url, _, false):
            "磁盘文件与恢复内容不同：\(url.path)"
        }
    }

    var diskText: String? {
        guard case let .readable(_, text, _) = self else { return nil }
        return text
    }

    var originalHasChanged: Bool {
        guard case .readable(_, _, false) = self else { return false }
        return true
    }
}

actor RecoveryDiskInspector {
    func inspect(_ record: DocumentRecoveryRecord) -> RecoveryDiskPreview {
        guard let originalURL = record.originalURL else { return .unnamed }
        do {
            guard let data = try DocumentRecoveryFileAccess.withResolvedURL(
                for: record,
                { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
            ) else {
                return .missing(originalURL)
            }
            let decoded = try MarkdownCodec.decode(data)
            return .readable(
                originalURL,
                text: decoded.text,
                matchesRecovery: UTF8Text.isExactlyEqual(decoded.text, record.text)
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing(originalURL)
        } catch {
            return .unavailable(originalURL)
        }
    }
}

@MainActor
final class RecoveryCommandActions {
    let showRecoveryCenter: () -> Void

    init(showRecoveryCenter: @escaping () -> Void) {
        self.showRecoveryCenter = showRecoveryCenter
    }
}

private struct RecoveryActionsFocusedKey: FocusedValueKey {
    typealias Value = RecoveryCommandActions
}

extension FocusedValues {
    var recoveryActions: RecoveryCommandActions? {
        get { self[RecoveryActionsFocusedKey.self] }
        set { self[RecoveryActionsFocusedKey.self] = newValue }
    }
}

struct RecoveryCommands: Commands {
    @FocusedValue(\.recoveryActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("恢复未保存的文档…") {
                actions?.showRecoveryCenter()
            }
            .disabled(actions == nil)
        }
    }
}

struct RecoveryProtectionStatusBanner: View {
    @ObservedObject var coordinator: DocumentRecoveryCoordinator

    var body: some View {
        if let message = coordinator.protectionErrorMessage {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RecoveryProtectionPrompt.title)
                            .font(.headline)
                        Text(message)
                            .font(.caption)
                    }
                    Spacer(minLength: 8)
                    Button(RecoveryProtectionPrompt.retryTitle) {
                        Task { await coordinator.retryProtection() }
                    }
                    Button(RecoveryProtectionPrompt.continueTitle) {
                        coordinator.continueWritingWithoutProtection()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.08))
                .accessibilityElement(children: .contain)
                Divider()
            }
        }
    }
}

struct RecoveryCenterView: View {
    @ObservedObject var coordinator: DocumentRecoveryCoordinator
    let onClose: () -> Void

    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @State private var selectedID: DocumentRecoveryRecord.ID?
    @State private var diskPreview = RecoveryDiskPreview.unnamed
    @State private var diskInspector = RecoveryDiskInspector()
    @State private var errorMessage: String?
    @State private var recordPendingDiscard: DocumentRecoveryRecord?
    @State private var comparisonRecordID: DocumentRecoveryRecord.ID?
    @State private var dismissedChangePromptRecordID: DocumentRecoveryRecord.ID?

    private var selectedRecord: DocumentRecoveryRecord? {
        coordinator.recoveredRecords.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("恢复未保存的文档")
                        .font(.title2.weight(.semibold))
                    Text("这里只显示比最近磁盘内容更新、且上次未正常关闭的恢复副本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            if coordinator.recoveredRecords.isEmpty {
                ContentUnavailableView(
                    "没有可恢复的文档",
                    systemImage: "checkmark.shield",
                    description: Text("完成的保存不会出现在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    recoveryList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    recoveryDetail
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            if selectedID == nil {
                selectedID = coordinator.recoveredRecords.first?.id
            }
        }
        .onChange(of: coordinator.recoveredRecords) { _, records in
            if let selectedID, records.contains(where: { $0.id == selectedID }) {
                return
            }
            self.selectedID = records.first?.id
        }
        .task(id: selectedID) {
            guard let selectedRecord else {
                diskPreview = .unnamed
                return
            }
            comparisonRecordID = nil
            dismissedChangePromptRecordID = nil
            diskPreview = .unnamed
            diskPreview = await diskInspector.inspect(selectedRecord)
        }
        .alert(
            "恢复操作未完成",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "恢复内容仍然保留。")
        }
        .confirmationDialog(
            "放弃所选恢复内容？",
            isPresented: Binding(
                get: { recordPendingDiscard != nil },
                set: { if !$0 { recordPendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("放弃", role: .destructive) {
                guard let record = recordPendingDiscard else { return }
                recordPendingDiscard = nil
                Task { await coordinator.discard(record) }
            }
            Button("取消", role: .cancel) {
                recordPendingDiscard = nil
            }
        } message: {
            Text("这些未保存内容将被删除，且无法恢复。")
        }
    }

    private var recoveryList: some View {
        List(coordinator.recoveredRecords, selection: $selectedID) { record in
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(record.updatedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .tag(record.id)
            .accessibilityValue("最后更新 \(record.updatedAt.formatted())")
        }
        .accessibilityLabel("可恢复文档")
    }

    private var recoveryDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = selectedRecord {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.displayName)
                            .font(.title3.weight(.semibold))
                        Text(diskPreview.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("放弃…", role: .destructive) {
                        recordPendingDiscard = record
                    }
                    if !showsOriginalChangePrompt(for: record) {
                        Button("另存所选…") {
                            saveAs(record)
                        }
                        .disabled(record.requiresLineEndingChoice)
                        Button(RecoveryOriginalChangePrompt.openTitle) {
                            restore(record)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }

                if showsOriginalChangePrompt(for: record) {
                    originalChangePrompt(for: record)
                }

                if record.requiresLineEndingChoice {
                    Label(
                        "恢复内容仍需选择 LF 或 CRLF。请先打开恢复文档，再选择换行方式后保存。",
                        systemImage: "arrow.left.arrow.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if shouldShowComparison(for: record) {
                    HSplitView {
                        sourcePreview(
                            title: "未保存的恢复内容",
                            text: record.text
                        )
                        sourcePreview(
                            title: "当前磁盘内容",
                            text: diskPreview.diskText
                        )
                    }
                }

                HStack {
                    Button("全部恢复为未命名文档") {
                        restoreAll()
                    }
                    Spacer()
                    Text("恢复不会直接覆盖原文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private func showsOriginalChangePrompt(for record: DocumentRecoveryRecord) -> Bool {
        diskPreview.originalHasChanged && dismissedChangePromptRecordID != record.id
    }

    private func shouldShowComparison(for record: DocumentRecoveryRecord) -> Bool {
        !diskPreview.originalHasChanged || comparisonRecordID == record.id
    }

    private func originalChangePrompt(for record: DocumentRecoveryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(RecoveryOriginalChangePrompt.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(RecoveryOriginalChangePrompt.message)
                .foregroundStyle(.secondary)
            HStack {
                Button(RecoveryOriginalChangePrompt.compareTitle) {
                    comparisonRecordID = record.id
                }
                Button(RecoveryOriginalChangePrompt.openTitle) {
                    restore(record)
                }
                .keyboardShortcut(.defaultAction)
                Button(RecoveryOriginalChangePrompt.saveAsTitle) {
                    saveAs(record)
                }
                .disabled(record.requiresLineEndingChoice)
                Spacer()
                Button(RecoveryOriginalChangePrompt.closeTitle) {
                    dismissedChangePromptRecordID = record.id
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func sourcePreview(title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text ?? "（没有可读取的磁盘文本）")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(text == nil ? .secondary : .primary)
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
        .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func restore(_ record: DocumentRecoveryRecord) {
        do {
            let document = try record.restoredDocument()
            newDocument(document)
            Task { await coordinator.discard(record) }
        } catch {
            errorMessage = "恢复内容无法验证，因此没有打开新文档。原恢复项仍被保留。"
        }
    }

    private func restoreAll() {
        let records = coordinator.recoveredRecords
        do {
            let documents = try records.map { try $0.restoredDocument() }
            for document in documents {
                newDocument(document)
            }
            Task {
                for record in records {
                    await coordinator.discard(record)
                }
            }
        } catch {
            errorMessage = "至少一项恢复内容无法验证；本次没有放弃任何恢复项。"
        }
    }

    private func saveAs(_ record: DocumentRecoveryRecord) {
        Task {
            guard !record.requiresLineEndingChoice else { return }
            let panel = NSSavePanel()
            panel.title = "另存恢复文档"
            panel.prompt = "另存"
            panel.allowedContentTypes = [.inflowMarkdown]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = record.originalURL?.lastPathComponent
                ?? "恢复的文档.md"
            let response = await panel.beginResponse()
            guard response == .OK, let url = panel.url else { return }

            do {
                let document = try record.restoredDocument()
                let data = try document.encodedFileData()
                let expectedTarget = try HTMLExportTargetSnapshot.capture(url)
                try HTMLExportFileWriter.write(
                    data,
                    to: url,
                    expectedTarget: expectedTarget
                )
                await coordinator.discard(record)
                do {
                    try await openDocument(at: url)
                } catch {
                    errorMessage = "恢复内容已安全保存到\(url.path)，但无法自动打开该文件。"
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "未能安全另存恢复内容；恢复项和原目标均未改变。"
            }
        }
    }
}

private extension NSSavePanel {
    func beginResponse() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }
}
