import SwiftUI

struct DocumentOutlineView: View {
    let analysisState: DocumentAnalysisState
    let selectedHeadingID: DocumentHeading.ID?
    let focusGeneration: Int
    let onSelect: (DocumentHeading) -> Void
    let onCollapse: () -> Void

    init(
        analysisState: DocumentAnalysisState,
        selectedHeadingID: DocumentHeading.ID?,
        focusGeneration: Int,
        onSelect: @escaping (DocumentHeading) -> Void,
        onCollapse: @escaping () -> Void = {}
    ) {
        self.analysisState = analysisState
        self.selectedHeadingID = selectedHeadingID
        self.focusGeneration = focusGeneration
        self.onSelect = onSelect
        self.onCollapse = onCollapse
    }

    @FocusState private var focusedHeadingID: DocumentHeading.ID?
    @State private var handledFocusGeneration = 0

    private var analysis: DocumentAnalysis {
        analysisState.displayedAnalysis
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("文档大纲", systemImage: "list.bullet.indent")
                    .font(.headline)
                Spacer()
                stateIndicator
                Text("\(analysis.headings.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(analysis.headings.count) 个标题")
            }
            .padding(.horizontal, 12)
            .frame(height: EditorWorkspaceMetrics.navigationHeaderHeight)

            Divider()

            statusBanner

            if analysis.headings.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(analysis.headings) { heading in
                            headingButton(heading)
                        }
                    }
                    .focusSection()
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文档大纲")
        .overlay(alignment: .leading) {
            WorkspacePaneVisibilityButton(
                paneName: "文档大纲",
                systemImage: "sidebar.right",
                isExpanded: true,
                action: onCollapse
            )
            .padding(.leading, 8)
        }
        .onChange(of: focusGeneration) { _, _ in
            focusFirstHeadingIfRequested()
        }
        .onChange(of: analysisState) { _, _ in
            focusFirstHeadingIfRequested()
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch analysisState {
        case .updating:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("大纲正在更新")
        case .ready:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("大纲更新失败")
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch analysisState {
        case .updating where !analysis.headings.isEmpty:
            Label("正在更新，暂停定位", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .failed(_, message) where !analysis.headings.isEmpty:
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch analysisState {
        case .updating:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("正在分析当前文档…")
            }
        case .ready:
            ContentUnavailableView(
                "暂无标题",
                systemImage: "text.badge.plus",
                description: Text("使用 H1–H6 标题即可生成大纲。")
            )
            .padding(16)
        case let .failed(_, message):
            ContentUnavailableView(
                "大纲暂不可用",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .padding(16)
        }
    }

    private func headingButton(_ heading: DocumentHeading) -> some View {
        let isSelected = heading.id == selectedHeadingID

        return Button {
            onSelect(heading)
        } label: {
            HStack(spacing: 7) {
                Text("H\(heading.level)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)

                Text(heading.displayTitle)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(heading.level - 1) * 8)
            .padding(.trailing, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!analysisState.allowsNavigation)
        .focused($focusedHeadingID, equals: heading.id)
        .accessibilityLabel(heading.displayTitle)
        .accessibilityValue(
            isSelected
                ? "\(heading.level) 级标题，已选择"
                : "\(heading.level) 级标题"
        )
        .accessibilityHint(
            analysisState.allowsNavigation
                ? "定位到源码中的这个标题"
                : "等待大纲更新后可用"
        )
    }

    private func focusFirstHeadingIfRequested() {
        guard focusGeneration != handledFocusGeneration,
              analysisState.allowsNavigation
        else {
            return
        }

        handledFocusGeneration = focusGeneration
        if let firstHeading = analysis.headings.first {
            focusedHeadingID = firstHeading.id
        }
    }
}
