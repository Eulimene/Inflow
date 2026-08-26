import SwiftUI

struct InflowSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var anonymousUsage: AnonymousUsageDataController
    @ObservedObject var recentDocuments: RecentDocumentsController
    @State private var isResetConfirmationPresented = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }

            writingSettings
                .tabItem { Label("写作", systemImage: "pencil") }

            previewSettings
                .tabItem { Label("预览", systemImage: "doc.richtext") }

            resourceSettings
                .tabItem { Label("资源", systemImage: "photo.on.rectangle") }

            accessibilitySettings
                .tabItem { Label("辅助功能", systemImage: "accessibility") }

            AnonymousUsagePrivacyView(controller: anonymousUsage)
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .padding(20)
        .frame(width: 620, height: 470)
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

    private var generalSettings: some View {
        Form {
            Section("文档窗口") {
                Picker("打开 Markdown 文件", selection: $preferences.markdownOpenBehavior) {
                    ForEach(MarkdownOpenBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                Text("只有当前窗口是未编辑的未命名空白文档时才会复用；打开失败时原窗口保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(
                    "最近文档：\(preferences.recentDocumentCapacity) 项",
                    value: $preferences.recentDocumentCapacity,
                    in: RecentDocumentPolicy.capacityRange
                )
            }

            Section("自动保存") {
                Toggle("自动保存可写文档", isOn: $preferences.autosaveEnabled)
                Picker("编辑后延迟", selection: $preferences.autosaveDelay) {
                    ForEach(AutosaveDelay.allCases) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .disabled(!preferences.autosaveEnabled)

                Text(
                    preferences.autosaveEnabled
                        ? "延迟从最近一次编辑开始计算；外部冲突或只读状态仍会暂停写回。"
                        : "可随时使用 ⌘S 手动保存；异常恢复保护仍会独立运行。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("最近文档") {
                if recentDocuments.entries.isEmpty {
                    Text("暂无最近文档")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentDocuments.entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.isAvailable ? "doc.text" : "doc.badge.ellipsis")
                                .foregroundStyle(entry.isAvailable ? Color.primary : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                    .lineLimit(1)
                                Text(
                                    entry.isAvailable
                                        ? entry.directoryPath
                                        : "原位置已不可用 · \(entry.directoryPath)"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                recentDocuments.remove(entry)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("从最近文档移除 \(entry.displayName)")
                            .accessibilityLabel("从最近文档移除 \(entry.displayName)")
                        }
                    }

                    Button("清除最近记录", role: .destructive) {
                        recentDocuments.clear()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { recentDocuments.refresh() }
        .onChange(of: preferences.recentDocumentCapacity) { _, _ in
            recentDocuments.applyCapacity()
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
            Toggle("自动换行", isOn: $preferences.wrapsLines)
                .help("关闭后可水平滚动查看长行，不会修改 Markdown 正文。")
            Toggle("显示行号", isOn: $preferences.showsLineNumbers)
                .help("按源文本的物理行编号，自动换行不会新增行号。")
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
            Toggle("呈现数学公式", isOn: $preferences.mathRenderingEnabled)
                .help("关闭后，公式定界符和内容作为普通文本显示。")
            Toggle("呈现 Mermaid 图表", isOn: $preferences.mermaidRenderingEnabled)
                .help("关闭后，Mermaid 围栏作为普通代码块显示。")
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

    private var resourceSettings: some View {
        Form {
            Section("既有图片") {
                Picker("插入时", selection: $preferences.existingImagePlacement) {
                    ForEach(ExistingImagePlacementPreference.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                Text(resourcePlacementExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("安全边界") {
                LabeledContent("同名文件", value: "每次询问")
                Text("粘贴或新建的图片始终保存到文档同级 assets，不会引用不可迁移的临时位置。同名时不静默覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var resourcePlacementExplanation: String {
        switch preferences.existingImagePlacement {
        case .copyToAssets:
            "默认把选择或拖入的既有图片复制到当前 Markdown 同级 assets，并写入相对引用。"
        case .keepOriginal:
            "不复制既有图片；可形成相对路径时优先使用，否则仍会在写入绝对本地地址前单独确认。"
        case .askEveryTime:
            "每次选择或拖入既有图片时，先说明复制与保留原位置的迁移影响。"
        }
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
