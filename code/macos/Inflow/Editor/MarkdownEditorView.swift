import SwiftUI

enum EditorViewMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .source: "源码编辑"
        case .split: "实时预览"
        case .preview: "纯预览"
        }
    }

    var systemImage: String {
        switch self {
        case .source: "text.alignleft"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}

enum EditorStatisticMode: String, CaseIterable, Identifiable {
    case words
    case charactersIncludingSpaces
    case charactersExcludingSpaces
    case hidden

    var id: Self { self }

    var label: String {
        switch self {
        case .words: "字数"
        case .charactersIncludingSpaces: "字符数（含空格）"
        case .charactersExcludingSpaces: "字符数（不含空格）"
        case .hidden: "隐藏统计"
        }
    }
}

struct MarkdownEditorView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @SceneStorage("editorViewMode") private var storedViewMode = EditorViewMode.split.rawValue
    @SceneStorage("isDocumentOutlineVisible") private var isOutlineVisible = true
    @SceneStorage("editorStatisticMode") private var storedStatisticMode =
        EditorStatisticMode.words.rawValue
    @State private var previewHTML = MarkdownRenderer.htmlDocument(for: "")
    @State private var analysisState = DocumentAnalysisState.updating(previous: .empty)
    @State private var derivedContentGeneration = 0
    @State private var derivedContentTask: Task<Void, Never>?
    @State private var contentDeriver = DocumentContentDeriver()
    @StateObject private var sourceEditorSession = MarkdownSourceEditorSession()
    @State private var selectedHeadingID: DocumentHeading.ID?
    @State private var sourceSelectionRequest: SourceSelectionRequest?
    @State private var sourceSelectionGeneration = 0
    @State private var outlineFocusGeneration = 0

    private var viewMode: EditorViewMode {
        get { EditorViewMode(rawValue: storedViewMode) ?? .split }
        nonmutating set { storedViewMode = newValue.rawValue }
    }

    private var statisticMode: EditorStatisticMode {
        get { EditorStatisticMode(rawValue: storedStatisticMode) ?? .words }
        nonmutating set { storedStatisticMode = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            content

            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedValue(\.outlineVisibility, $isOutlineVisible)
        .toolbar {
            ToolbarItem {
                Button {
                    isOutlineVisible.toggle()
                } label: {
                    Label(
                        isOutlineVisible ? "隐藏大纲" : "显示大纲",
                        systemImage: "sidebar.left"
                    )
                }
                .help(isOutlineVisible ? "隐藏文档大纲" : "显示文档大纲")
                .accessibilityValue(isOutlineVisible ? "已显示" : "已隐藏")
            }

            ToolbarItem {
                Picker(
                    "写作视图",
                    selection: Binding(
                        get: { viewMode },
                        set: { viewMode = $0 }
                    )
                ) {
                    ForEach(EditorViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                .accessibilityLabel("写作视图")
            }
        }
        .onAppear {
            scheduleDerivedContent(for: document.text, delayNanoseconds: 0)
        }
        .onChange(of: document.text) { _, markdown in
            selectedHeadingID = nil
            sourceSelectionRequest = nil
            analysisState = .updating(previous: analysisState.displayedAnalysis)
            scheduleDerivedContent(for: markdown, delayNanoseconds: 120_000_000)
        }
        .onChange(of: isOutlineVisible) { _, isVisible in
            if isVisible {
                outlineFocusGeneration &+= 1
            }
        }
        .onDisappear {
            derivedContentTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isOutlineVisible {
            HSplitView {
                DocumentOutlineView(
                    analysisState: analysisState,
                    selectedHeadingID: selectedHeadingID,
                    focusGeneration: outlineFocusGeneration,
                    onSelect: selectHeading
                )
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

                editorContent
                    .frame(minWidth: 520)
            }
        } else {
            editorContent
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch viewMode {
        case .source:
            sourceEditor
        case .split:
            HSplitView {
                sourceEditor
                    .frame(minWidth: 320)
                preview
                    .frame(minWidth: 320)
            }
        case .preview:
            preview
        }
    }

    private var sourceEditor: some View {
        MarkdownSourceEditor(
            text: $document.text,
            selectionRequest: sourceSelectionRequest,
            session: sourceEditorSession
        )
    }

    private var preview: some View {
        MarkdownPreviewView(
            html: previewHTML,
            baseURL: fileURL?.deletingLastPathComponent()
        )
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(
                fileURL?.lastPathComponent ?? "未命名文档",
                systemImage: fileURL == nil ? "doc.badge.plus" : "doc.text"
            )

            Text(viewMode.label)

            Spacer()

            statisticsMenu
                .help(statisticsHelp)
            Text("UTF-8\(document.properties.hasUTF8BOM ? " BOM" : "")")
            Text(document.properties.lineEnding.displayName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .contain)
    }

    private func selectHeading(_ heading: DocumentHeading) {
        guard analysisState.allowsNavigation,
              analysisState.displayedAnalysis.headings.contains(heading)
        else {
            return
        }

        selectedHeadingID = heading.id
        if viewMode == .preview {
            viewMode = .split
        }
        sourceSelectionGeneration &+= 1
        sourceSelectionRequest = SourceSelectionRequest(
            generation: sourceSelectionGeneration,
            utf8Range: heading.sourceUTF8Range
        )
    }

    private func scheduleDerivedContent(for markdown: String, delayNanoseconds: UInt64) {
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        let generation = derivedContentGeneration

        derivedContentTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            guard let content = await contentDeriver.derive(markdown: markdown) else { return }

            guard !Task.isCancelled, generation == derivedContentGeneration else { return }
            previewHTML = content.html
            switch content.analysis {
            case let .success(analysis):
                analysisState = .ready(analysis)
            case let .failure(message):
                analysisState = .failed(
                    previous: analysisState.displayedAnalysis,
                    message: message
                )
            }
        }
    }

    @ViewBuilder
    private var analysisStatus: some View {
        let text = statisticsText
        if let text {
            switch analysisState {
            case .ready:
                Text(text)
            case .updating:
                Label(text, systemImage: "clock")
            case .failed:
                Label(text, systemImage: "exclamationmark.triangle")
            }
        } else {
            Image(systemName: "textformat.123")
        }
    }

    private var statisticsMenu: some View {
        Menu {
            Picker(
                "状态栏统计",
                selection: Binding(
                    get: { statisticMode },
                    set: { statisticMode = $0 }
                )
            ) {
                ForEach(EditorStatisticMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } label: {
            analysisStatus
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("文档统计")
        .accessibilityValue(statisticsAccessibilityValue)
    }

    private var statisticsText: String? {
        let analysis = analysisState.displayedAnalysis
        return switch statisticMode {
        case .words:
            "\(analysis.wordCount) 字"
        case .charactersIncludingSpaces:
            "\(analysis.characterCountIncludingSpaces) 字符"
        case .charactersExcludingSpaces:
            "\(analysis.characterCountExcludingSpaces) 字符"
        case .hidden:
            nil
        }
    }

    private var statisticsAccessibilityValue: String {
        let result = statisticsText ?? "已隐藏"
        switch analysisState {
        case .ready:
            return result
        case .updating:
            return "正在更新，上次结果 \(result)"
        case .failed:
            return "更新失败，上次结果 \(result)"
        }
    }

    private var statisticsHelp: String {
        guard statisticMode != .hidden else {
            return "选择要在状态栏显示的文档统计"
        }
        return "字符数：\(analysisState.displayedAnalysis.characterCountIncludingSpaces)"
            + "（含空格） / "
            + "\(analysisState.displayedAnalysis.characterCountExcludingSpaces)"
            + "（不含空格）"
    }
}

private struct DerivedDocumentContent: Sendable {
    let html: String
    let analysis: DocumentAnalysisOutcome
}

private enum DocumentAnalysisOutcome: Sendable {
    case success(DocumentAnalysis)
    case failure(String)
}

private actor DocumentContentDeriver {
    func derive(markdown: String) -> DerivedDocumentContent? {
        guard !Task.isCancelled else { return nil }
        let html = MarkdownRenderer.htmlDocument(for: markdown)
        guard !Task.isCancelled else { return nil }

        let analysis: DocumentAnalysisOutcome
        do {
            analysis = .success(try MarkdownAnalyzer.analyze(markdown))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? MarkdownAnalysisError.coreFailure.localizedDescription
            analysis = .failure(message)
        }

        guard !Task.isCancelled else { return nil }
        return DerivedDocumentContent(html: html, analysis: analysis)
    }
}
