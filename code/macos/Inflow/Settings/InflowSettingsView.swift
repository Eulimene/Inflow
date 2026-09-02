import SwiftUI

enum InflowSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case workspace
    case writing
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .general: "通用"
        case .workspace: "工作区"
        case .writing: "写作"
        case .preview: "预览"
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
    @State private var selectedSection = InflowSettingsSection.general
    @State private var pendingResetScope: SettingsResetScope?

    var body: some View {
        TabView(selection: $selectedSection) {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(InflowSettingsSection.general)

            workspaceSettings
                .tabItem { Label("工作区", systemImage: "rectangle.3.group") }
                .tag(InflowSettingsSection.workspace)

            writingSettings
                .tabItem { Label("写作", systemImage: "pencil") }
                .tag(InflowSettingsSection.writing)

            previewSettings
                .tabItem { Label("预览", systemImage: "doc.richtext") }
                .tag(InflowSettingsSection.preview)

        }
        .padding(20)
        .frame(width: 680, height: 560)
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
            guard let group = section.preferenceGroup else { return }
            preferences.reset(group)
        case .all:
            preferences.resetAll()
        }
        self.pendingResetScope = nil
    }

    private var generalSettings: some View {
        Form {
            Section("保存") {
                LabeledContent("正文保存方式", value: "手动保存")
                Text("使用 ⌘S 保存；异常恢复保护独立运行，不会自动写回用户文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var workspaceSettings: some View {
        Form {
            Section("视图与面板") {
                Picker("写作视图", selection: $preferences.workspaceViewMode) {
                    ForEach(WorkspaceViewModePreference.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle(
                    "显示项目目录树",
                    isOn: $preferences.workspaceProjectSidebarVisible
                )
                Toggle(
                    "显示文档大纲",
                    isOn: $preferences.workspaceOutlineVisible
                )
                Text(
                    "工具栏、显示菜单以及目录树和大纲自身的展开/折叠操作"
                        + "都会立即保存；之后打开文件、项目或重新启动 Inflow 时继续使用。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("区域宽度") {
                SettingSliderRow(
                    title: "目录树宽度",
                    value: $preferences.workspaceProjectSidebarWidth,
                    range: AppPreferences.Limits.projectSidebarWidth,
                    step: 4,
                    valueText: "\(Int(preferences.workspaceProjectSidebarWidth.rounded())) 点"
                )
                SettingSliderRow(
                    title: "大纲宽度",
                    value: $preferences.workspaceOutlineWidth,
                    range: AppPreferences.Limits.outlineWidth,
                    step: 4,
                    valueText: "\(Int(preferences.workspaceOutlineWidth.rounded())) 点"
                )
                SettingSliderRow(
                    title: "实时预览源码占比",
                    value: $preferences.workspaceSplitFraction,
                    range: EditorSplitLayout.allowedFraction,
                    step: 0.05,
                    valueText: preferences.workspaceSplitFraction.formatted(
                        .percent.precision(.fractionLength(0))
                    )
                )
                Text("直接拖拽任一分隔线也会更新这里的长期偏好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
            Toggle("Markdown 语法高亮", isOn: $preferences.syntaxHighlightingEnabled)
                .help("只改变源码编辑器的视觉样式，不会修改 Markdown 正文。")
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
            Picker("外观", selection: $preferences.previewColorScheme) {
                ForEach(PreviewColorScheme.allCases) { scheme in
                    Text(scheme.label).tag(scheme)
                }
            }
            Toggle("编辑器到预览滚动同步", isOn: $preferences.scrollSyncEnabled)
                .help("手动滚动预览后会暂停跟随，直到再次滚动源码编辑器。")
            Toggle("点击预览标题定位源码", isOn: $preferences.headingNavigationEnabled)
                .help("定位时会从纯预览进入实时预览，不会修改 Markdown。")
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
