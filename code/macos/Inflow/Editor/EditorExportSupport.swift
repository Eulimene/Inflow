import Foundation
import SwiftUI

enum EditorPersistenceError: LocalizedError {
    case unavailableAuthoritativeSnapshot

    var errorDescription: String? {
        "无法冻结当前 Engine revision，未执行保存或导出。"
    }
}

enum ExportFormat: String, Sendable {
    case html = "HTML"
    case pdf = "PDF"

    var filenameExtension: String { rawValue.lowercased() }
}

struct FrozenExportRequest: Sendable {
    let format: ExportFormat
    let snapshot: HTMLExportSnapshot
    let suggestedFilename: String
}

struct PreparedExportDelivery: Sendable {
    let request: FrozenExportRequest
    let data: Data
}

enum ExportRecoveryContext: Sendable {
    case prepare(FrozenExportRequest)
    case capture(PreparedExportDelivery, URL)
    case write(PreparedExportDelivery, URL, HTMLExportTargetSnapshot)

    var request: FrozenExportRequest {
        switch self {
        case let .prepare(request): request
        case let .capture(delivery, _), let .write(delivery, _, _): delivery.request
        }
    }

    var delivery: PreparedExportDelivery? {
        switch self {
        case .prepare: nil
        case let .capture(delivery, _), let .write(delivery, _, _): delivery
        }
    }

    var fileName: String {
        switch self {
        case let .prepare(request): request.suggestedFilename
        case let .capture(_, url), let .write(_, url, _): url.lastPathComponent
        }
    }
}

enum ExportDeliveryStep: Sendable {
    case chooseDestination
    case capture(URL)
    case write(URL, HTMLExportTargetSnapshot)
}

enum ExportNoticeOutcome: Sendable {
    case success(format: ExportFormat, url: URL, documentVersion: String)
    case targetChanged(delivery: PreparedExportDelivery, targetURL: URL)
    case tooLarge(FrozenExportRequest)
    case checkFailed(request: FrozenExportRequest, details: String)
    case failure(context: ExportRecoveryContext, reason: String)
}

struct HTMLExportNotice: Identifiable {
    let id = UUID()
    let outcome: ExportNoticeOutcome

    static func success(
        format: ExportFormat,
        url: URL,
        documentVersion: String
    ) -> Self {
        Self(outcome: .success(format: format, url: url, documentVersion: documentVersion))
    }

    var title: String {
        switch outcome {
        case let .success(_, url, _):
            ExportResultPrompt.successTitle(exportName: url.lastPathComponent)
        case .targetChanged: ExportFailurePrompt.targetChangedTitle
        case .tooLarge: ExportFailurePrompt.tooLargeTitle
        case .checkFailed: ExportFailurePrompt.checkFailedTitle
        case let .failure(context, _):
            ExportFailurePrompt.failureTitle(fileName: context.fileName)
        }
    }

    var message: String {
        switch outcome {
        case let .success(_, _, documentVersion):
            ExportResultPrompt.successMessage(documentVersion: documentVersion)
        case .targetChanged: ExportFailurePrompt.targetChangedMessage
        case .tooLarge:
            ExportFailurePrompt.tooLargeMessage(limit: ExportFailurePrompt.outputLimit)
        case .checkFailed: ExportFailurePrompt.checkFailedMessage
        case let .failure(_, reason): ExportFailurePrompt.failureMessage(reason: reason)
        }
    }
}

enum ExportProgressPrompt {
    static let cancelTitle = "取消"
    static func title(format: String) -> String { "正在导出 \(format)…" }
    static func message(documentVersion: String) -> String {
        "使用文档版本 \(documentVersion)。"
    }
}

enum ExportResultPrompt {
    static let showInFinderTitle = "在 Finder 中显示"
    static let openTitle = "打开"
    static let doneTitle = "完成"
    static func successTitle(exportName: String) -> String { "已导出「\(exportName)」" }
    static func successMessage(documentVersion: String) -> String {
        "使用文档版本 \(documentVersion)。"
    }
}

enum ExportFailurePrompt {
    static let outputLimit = "100 MiB"
    static let targetChangedTitle = "导出目标已变化"
    static let targetChangedMessage = "选择位置后，目标已被创建、替换或修改。"
    static let reconfirmReplacementTitle = "重新确认替换…"
    static let chooseAnotherLocationTitle = "选择其他位置…"
    static let cancelTitle = "取消"
    static let tooLargeTitle = "导出内容过大"
    static let returnToAdjustTitle = "返回调整"
    static let checkFailedTitle = "导出结果未通过检查"
    static let checkFailedMessage =
        "交付物包含不安全动作、私密路径或结构不完整，因此没有替换目标。"
    static let viewProblemsTitle = "查看问题"
    static let closeTitle = "关闭"
    static let retryTitle = "重试"

    static func tooLargeMessage(limit: String) -> String {
        "预计交付物超出\(limit)，未写入目标。"
    }

    static func failureTitle(fileName: String) -> String { "未能导出「\(fileName)」" }

    static func failureMessage(reason: String) -> String {
        let normalized = reason.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "。.!！?？")
            )
        )
        return "\(normalized)。Markdown 文档未改变；请重新确认目标文件的状态。"
    }
}

struct ExportIssueDetails: Identifiable {
    let id = UUID()
    let message: String
}

struct ActiveExportProgress: Equatable {
    let format: ExportFormat
    let documentVersion: String
    let isCancellable: Bool
}

struct ExportProgressBanner: View {
    let progress: ActiveExportProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ExportProgressPrompt.title(format: progress.format.rawValue))
                        .font(.headline)
                    Text(ExportProgressPrompt.message(documentVersion: progress.documentVersion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if progress.isCancellable {
                    Button(ExportProgressPrompt.cancelTitle, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Text("正在安全完成写入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            .accessibilityElement(children: .contain)
            Divider()
        }
    }
}

struct PendingExportConfirmation: Identifiable {
    let id = UUID()
    let request: FrozenExportRequest
    let preparation: HTMLExportPreparation
}
