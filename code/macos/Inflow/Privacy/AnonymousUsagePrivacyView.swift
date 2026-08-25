import SwiftUI

struct AnonymousUsagePrivacyView: View {
    @ObservedObject var controller: AnonymousUsageDataController
    @State private var isDisclosurePresented = false
    @State private var isDisableConfirmationPresented = false

    var body: some View {
        Form {
            Section("匿名产品使用数据") {
                LabeledContent("当前状态") {
                    Label(
                        controller.isEnabled ? "已开启" : "已关闭",
                        systemImage: controller.isEnabled ? "checkmark.shield" : "shield"
                    )
                    .foregroundStyle(controller.isEnabled ? .green : .secondary)
                    .accessibilityLabel(
                        controller.isEnabled
                            ? "匿名产品使用数据已开启"
                            : "匿名产品使用数据已关闭"
                    )
                }

                Text("初始关闭。Inflow 不需要账号；保持关闭不会减少写作、保存、恢复、预览或交付功能。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("查看完整范围…") {
                        isDisclosurePresented = true
                    }

                    Spacer()

                    if controller.isEnabled {
                        Button("关闭…", role: .destructive) {
                            isDisableConfirmationPresented = true
                        }
                    } else {
                        Button("主动开启") {
                            if controller.hasViewedDisclosure {
                                _ = controller.enable()
                            } else {
                                isDisclosurePresented = true
                            }
                        }
                        .disabled(!controller.isDisclosureAvailable)
                    }
                }
            }

            Section("未发送记录") {
                LabeledContent("本机待发送") {
                    Text("\(controller.pendingCount) 项")
                        .monospacedDigit()
                        .accessibilityLabel("本机待发送 \(controller.pendingCount) 项")
                }
                Button("清除未发送记录", role: .destructive) {
                    controller.clearPending()
                }
                .disabled(controller.pendingCount == 0)
            }

            if !controller.isDisclosureAvailable {
                Label(
                    "完整说明或安全接收地址不可用，因此保持关闭且不允许开启。",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }

            if let message = controller.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("匿名产品使用数据状态：\(message)")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isDisclosurePresented) {
            AnonymousUsageDisclosureView(
                isAvailable: controller.isDisclosureAvailable,
                onCancel: { isDisclosurePresented = false },
                onEnable: {
                    controller.markDisclosureViewed()
                    _ = controller.enable()
                    isDisclosurePresented = false
                }
            )
        }
        .confirmationDialog(
            "关闭匿名产品使用数据？",
            isPresented: $isDisableConfirmationPresented
        ) {
            Button("关闭并清除未发送记录", role: .destructive) {
                controller.disable(clearPending: true)
            }
            Button("仅关闭") {
                controller.disable(clearPending: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("关闭后不再产生或发送新记录。写作、文件、恢复、预览和交付功能不受影响。")
        }
    }
}

private struct AnonymousUsageDisclosureView: View {
    let isAvailable: Bool
    let onCancel: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("允许发送匿名产品使用数据？")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    disclosureSection(
                        title: "允许字段",
                        text: "Inflow 版本、macOS 主版本、界面语言、功能与命令计数、耗时区间、错误类别。"
                    )
                    disclosureSection(
                        title: "永不纳入",
                        text: "文档内容、选区、剪贴板、文件名、文件路径、链接地址、搜索词、账号凭据、插件处理内容或可识别个人的信息。"
                    )
                    disclosureSection(
                        title: "用途",
                        text: "只用于产品质量、可用性与性能改进；不用于广告、内容画像，也不出售数据。"
                    )
                    disclosureSection(
                        title: "保留与退出",
                        text: "可识别单次事件的记录不超过 30 天；不可回溯到用户或设备的汇总不超过 12 个月。你可随时关闭并清除尚未发送的记录。"
                    )
                    disclosureSection(
                        title: "发送方式",
                        text: "只向 Inflow 配置的 HTTPS 接收地址发送；不跟随重定向，不使用 Cookie。发送失败时记录留在本机，仍可清除。"
                    )
                }
            }

            HStack {
                Button("取消", role: .cancel, action: onCancel)
                Spacer()
                Button("我已查看并主动开启", action: onEnable)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isAvailable)
            }
        }
        .padding(24)
        .frame(width: 620, height: 540)
        .accessibilityElement(children: .contain)
    }

    private func disclosureSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
