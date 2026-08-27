import SwiftUI

enum InflowSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case writing
    case preview
    case resources
    case accessibility
    case privacy

    var id: Self { self }

    var label: String {
        switch self {
        case .general: "通用"
        case .writing: "写作"
        case .preview: "预览"
        case .resources: "资源"
        case .accessibility: "辅助功能"
        case .privacy: "隐私"
        }
    }

    var preferenceGroup: AppPreferenceGroup? {
        AppPreferenceGroup(rawValue: rawValue)
    }
}

enum SettingsResetScope: Equatable, Sendable {
    case current(InflowSettingsSection)
    case all

    var menuTitle: String {
        switch self {
        case let .current(section): "恢复“\(section.label)”默认设置…"
        case .all: "恢复全部默认设置…"
        }
    }
}

enum SettingsResetPrompt {
    static let title = "恢复默认设置？"
    static let message = "只会重置所选偏好，不会删除任何用户内容或记录。"
    static let confirmTitle = "恢复默认"
    static let cancelTitle = "取消"
}

enum SettingsPersistencePrompt {
    static let title = "暂时无法保存设置"
    static let message =
        "本次会话可继续使用当前选择，重新打开 Inflow 后可能恢复之前的值。"
    static let retryTitle = "重试"
    static let continueTitle = "继续使用"
}

struct InflowSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var anonymousUsage: AnonymousUsageDataController
    @ObservedObject var recentDocuments: RecentDocumentsController
    @State private var selectedSection = InflowSettingsSection.general
    @State private var pendingResetScope: SettingsResetScope?

    var body: some View {
        TabView(selection: $selectedSection) {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(InflowSettingsSection.general)

            writingSettings
                .tabItem { Label("写作", systemImage: "pencil") }
                .tag(InflowSettingsSection.writing)

            previewSettings
                .tabItem { Label("预览", systemImage: "doc.richtext") }
                .tag(InflowSettingsSection.preview)

            resourceSettings
                .tabItem { Label("资源", systemImage: "photo.on.rectangle") }
                .tag(InflowSettingsSection.resources)

            accessibilitySettings
                .tabItem { Label("辅助功能", systemImage: "accessibility") }
                .tag(InflowSettingsSection.accessibility)

            AnonymousUsagePrivacyView(controller: anonymousUsage)
                .tabItem { Label("隐私", systemImage: "hand.raised") }
                .tag(InflowSettingsSection.privacy)
        }
        .padding(20)
        .frame(width: 620, height: 470)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Menu("恢复默认…") {
                    Button(SettingsResetScope.current(selectedSection).menuTitle) {
                        pendingResetScope = .current(selectedSection)
                    }
                    Button(SettingsResetScope.all.menuTitle) {
                        pendingResetScope = .all
                    }
                }
            }
        }
        .confirmationDialog(
            SettingsResetPrompt.title,
            isPresented: Binding(
                get: { pendingResetScope != nil },
                set: { if !$0 { pendingResetScope = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(SettingsResetPrompt.confirmTitle, role: .destructive) {
                applyPendingReset()
            }
            Button(SettingsResetPrompt.cancelTitle, role: .cancel) {
                pendingResetScope = nil
            }
        } message: {
            Text(SettingsResetPrompt.message)
        }
        .alert(
            SettingsPersistencePrompt.title,
            isPresented: Binding(
                get: { preferences.persistenceFailure != nil },
                set: { isPresented in
                    if !isPresented {
                        preferences.continueUsingSessionPreferences()
                    }
                }
            )
        ) {
            Button(SettingsPersistencePrompt.retryTitle) {
                Task { @MainActor in
                    await Task.yield()
                    preferences.retryPersistence()
                }
            }
            Button(SettingsPersistencePrompt.continueTitle, role: .cancel) {
                preferences.continueUsingSessionPreferences()
            }
        } message: {
            Text(SettingsPersistencePrompt.message)
        }
    }

    private func applyPendingReset() {
        guard let pendingResetScope else { return }
        switch pendingResetScope {
        case let .current(section):
            if let group = section.preferenceGroup {
                preferences.reset(group)
            } else {
                anonymousUsage.disable(clearPending: false)
            }
        case .all:
            preferences.resetAll()
            anonymousUsage.disable(clearPending: false)
        }
        self.pendingResetScope = nil
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
                Text("粘贴或新建的图片只保存到文档同级 assets 或你选择的文档内相对目录，不会引用不可迁移的临时位置。同名时不静默覆盖。")
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
        case .copyToRelativeDirectory:
            "每次复制或粘贴图片时选择当前 Markdown 目录或其真实子目录，并写入经编码的相对引用。"
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
