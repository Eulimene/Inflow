import SwiftUI

struct InflowSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var anonymousUsage: AnonymousUsageDataController
    @State private var isResetConfirmationPresented = false

    var body: some View {
        TabView {
            writingSettings
                .tabItem { Label("写作", systemImage: "pencil") }

            previewSettings
                .tabItem { Label("预览", systemImage: "doc.richtext") }

            accessibilitySettings
                .tabItem { Label("辅助功能", systemImage: "accessibility") }

            AnonymousUsagePrivacyView(controller: anonymousUsage)
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .padding(20)
        .frame(width: 560, height: 410)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("恢复默认…") {
                    isResetConfirmationPresented = true
                }
            }
        }
        .confirmationDialog(
            "恢复写作与预览默认设置？",
            isPresented: $isResetConfirmationPresented
        ) {
            Button("恢复默认", role: .destructive) {
                preferences.resetWritingAndPreview()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会重置本页设置，不会删除文档、自动恢复副本或最近打开记录。")
        }
    }

    private var writingSettings: some View {
        Form {
            SettingSliderRow(
                title: "编辑器字号",
                value: $preferences.editorFontSize,
                range: AppPreferences.Limits.editorFontSize,
                step: 1,
                valueText: "\(Int(preferences.editorFontSize.rounded())) 磅"
            )
            SettingSliderRow(
                title: "编辑器行高",
                value: $preferences.editorLineHeight,
                range: AppPreferences.Limits.editorLineHeight,
                step: 0.1,
                valueText: preferences.editorLineHeight.formatted(.number.precision(.fractionLength(1)))
            )
            Toggle("Markdown 语法高亮", isOn: $preferences.syntaxHighlightingEnabled)
                .help("只改变源码编辑器的视觉样式，不会修改 Markdown 正文。")
            Toggle("连续拼写检查", isOn: $preferences.spellingEnabled)
                .help("只影响编辑器提示，不会修改 Markdown 正文。")
        }
        .formStyle(.grouped)
    }

    private var previewSettings: some View {
        Form {
            SettingSliderRow(
                title: "内容宽度",
                value: $preferences.previewContentWidth,
                range: AppPreferences.Limits.previewContentWidth,
                step: 20,
                valueText: "\(Int(preferences.previewContentWidth.rounded())) 像素"
            )
            SettingSliderRow(
                title: "阅读缩放",
                value: $preferences.previewZoom,
                range: AppPreferences.Limits.previewZoom,
                step: 0.05,
                valueText: preferences.previewZoom.formatted(.percent.precision(.fractionLength(0)))
            )
            Picker("外观", selection: $preferences.previewColorScheme) {
                ForEach(PreviewColorScheme.allCases) { scheme in
                    Text(scheme.label).tag(scheme)
                }
            }
            Picker("阅读主题", selection: $preferences.previewTheme) {
                ForEach(PreviewTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            Toggle("编辑器到预览滚动同步", isOn: $preferences.scrollSyncEnabled)
                .help("手动滚动预览后会暂停跟随，直到再次滚动源码编辑器。")
            Toggle("点击预览标题定位源码", isOn: $preferences.headingNavigationEnabled)
                .help("定位时会从纯预览进入实时预览，不会修改 Markdown。")
        }
        .formStyle(.grouped)
    }

    private var accessibilitySettings: some View {
        Form {
            Picker("增强对比度", selection: $preferences.increasedContrast) {
                ForEach(AccessibilityPreference.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            Picker("减少动态效果", selection: $preferences.reduceMotion) {
                ForEach(AccessibilityPreference.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            Text("“跟随系统”会采用 macOS 当前的辅助功能显示设置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct SettingSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 260)
                Text(valueText)
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(valueText)
    }
}
