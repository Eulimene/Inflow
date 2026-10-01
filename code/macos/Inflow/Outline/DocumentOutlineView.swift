import SwiftUI

struct DocumentOutlineView: View {
    let analysisState: DocumentAnalysisState
    let selectedHeadingID: DocumentHeading.ID?
    let focusGeneration: Int
    let onSelect: (DocumentHeading) -> Void

    init(
        analysisState: DocumentAnalysisState,
        selectedHeadingID: DocumentHeading.ID?,
        focusGeneration: Int,
        onSelect: @escaping (DocumentHeading) -> Void
    ) {
        self.analysisState = analysisState
        self.selectedHeadingID = selectedHeadingID
        self.focusGeneration = focusGeneration
        self.onSelect = onSelect
    }

    @FocusState private var focusedHeadingID: DocumentHeading.ID?
    @State private var handledFocusGeneration = 0
    @State private var collapsedHeadingIDs = Set<DocumentHeading.ID>()

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
                        ForEach(visibleHeadings) { heading in
                            HStack(spacing: 2) {
                                if hasChildren(heading) {
                                    Button {
                                        if !collapsedHeadingIDs.insert(heading.id).inserted {
                                            collapsedHeadingIDs.remove(heading.id)
                                        }
                                    } label: {
                                        Image(systemName: collapsedHeadingIDs.contains(heading.id)
                                            ? "chevron.right" : "chevron.down")
                                    }
                                    .buttonStyle(.plain)
                                    .frame(width: 18)
                                    .accessibilityLabel((collapsedHeadingIDs.contains(heading.id) ? "展开章节：" : "折叠章节：") + heading.displayTitle)
                                } else {
                                    Color.clear.frame(width: 18, height: 1)
                                }
                                headingButton(heading)
                            }
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
        .onChange(of: focusGeneration) { _, _ in
            focusFirstHeadingIfRequested()
        }
        .onChange(of: analysisState) { _, _ in
            focusFirstHeadingIfRequested()
        }
    }

    private var visibleHeadings: [DocumentHeading] {
        var hiddenBelowLevel: Int?
        return analysis.headings.filter { heading in
            if let level = hiddenBelowLevel, heading.level > level { return false }
            hiddenBelowLevel = collapsedHeadingIDs.contains(heading.id) ? heading.level : nil
            return true
        }
    }

    private func hasChildren(_ heading: DocumentHeading) -> Bool {
        guard let index = analysis.headings.firstIndex(where: { $0.id == heading.id }),
              index + 1 < analysis.headings.count else { return false }
        return analysis.headings[index + 1].level > heading.level
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
            VStack(alignment: .leading, spacing: 8) {
                Text("暂无标题").font(.headline)
                Text("输入 # 加空格创建标题，或使用“格式”菜单。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                Text(heading.displayTitle)
                    .fontWeight(heading.level == 1 ? .semibold : .regular)
                    .lineLimit(isSelected ? nil : 1)
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
