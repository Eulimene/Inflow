import SwiftUI

struct DocumentRelocationRequest: Identifiable, Sendable {
    let id: UUID
    let operation: DocumentRelocationOperation
    let plan: DocumentRelocationPlan

    init(operation: DocumentRelocationOperation, plan: DocumentRelocationPlan) {
        id = UUID()
        self.operation = operation
        self.plan = plan
    }
}

struct DocumentRelocationView: View {
    let request: DocumentRelocationRequest
    let onCancel: () -> Void
    let onConfirm: () async -> Void

    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: request.plan.hasRisk ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(request.plan.hasRisk ? .orange : .green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("检查相对引用")
                        .font(.title2.bold())
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("目标", value: request.plan.targetURL.path)
                .textSelection(.enabled)

            if request.plan.items.isEmpty {
                ContentUnavailableView(
                    "没有相对引用",
                    systemImage: "link.badge.plus",
                    description: Text("链接和图片不会因文档位置变化而改变。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(request.plan.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.reference.kind == .image ? "photo" : "link")
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.reference.target)
                                .font(.body.monospaced())
                            Text(item.impact.displayName)
                                .font(.caption)
                                .foregroundStyle(color(for: item.impact))
                            if let originalURL = item.originalURL,
                               originalURL != item.relocatedURL
                            {
                                Text("原位置：\(originalURL.path)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text("新位置：\(item.relocatedURL.path)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .frame(minHeight: 230)
            }

            HStack {
                Text("继续前会再次核对正文、目标和相关资源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .disabled(isApplying)
                Button("继续\(request.operation.actionTitle)") {
                    isApplying = true
                    Task { await onConfirm() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }

    private var summary: String {
        "\(request.plan.changedCount) 项将改变，\(request.plan.unavailableCount) 项不可用，\(request.plan.unchangedCount) 项不变。"
    }

    private func color(for impact: DocumentRelocationImpact) -> Color {
        switch impact {
        case .unchanged: .secondary
        case .changed: .orange
        case .unavailable: .red
        }
    }
}
