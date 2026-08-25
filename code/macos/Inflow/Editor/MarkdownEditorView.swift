import SwiftUI

private enum HTMLExportNotice: Identifiable {
    case success(URL)
    case failure(String)

    var id: String {
        switch self {
        case let .success(url): "success:\(url.path)"
        case let .failure(message): "failure:\(message)"
        }
    }

    var alert: Alert {
        switch self {
        case let .success(url):
            Alert(
                title: Text("HTML 导出完成"),
                message: Text("已导出到：\n\(url.path)"),
                primaryButton: .default(Text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                secondaryButton: .cancel(Text("完成"))
            )
        case let .failure(message):
            Alert(
                title: Text("HTML 导出未完成"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}

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

    var sourceVisible: EditorViewMode {
        self == .preview ? .split : self
    }

    static func resolve(storedValue: String) -> EditorViewMode {
        EditorViewMode(rawValue: storedValue) ?? .split
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
    let isEditable: Bool

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
    @StateObject private var findSession = DocumentFindSession()
    @State private var replaceAllPlan: ReplaceAllPlan?
    @State private var findSearchGeneration = 0
    @State private var findSearchTask: Task<Void, Never>?
    @State private var findSearchWorker = DocumentSearchWorker()
    @State private var pendingReplacementRange: Range<Int>?
    @State private var pendingFindNavigation: [Int] = []
    @State private var isExportingHTML = false
    @State private var htmlExportWorker = HTMLExportWorker()
    @State private var htmlExportNotice: HTMLExportNotice?
    @State private var markdownFormatErrorMessage: String?
    @State private var linkInsertionRequest: MarkdownLinkInsertionRequest?
    @State private var isImportingImage = false
    @State private var imageAssetWorker = ImageAssetWorker()
    @StateObject private var imageDirectoryAccess = ImageAssetDirectoryAccess()

    private var viewMode: EditorViewMode {
        get { EditorViewMode.resolve(storedValue: storedViewMode) }
        nonmutating set { storedViewMode = newValue.rawValue }
    }

    private var statisticMode: EditorStatisticMode {
        get { EditorStatisticMode(rawValue: storedStatisticMode) ?? .words }
        nonmutating set { storedStatisticMode = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if findSession.isPresented {
                DocumentFindBar(
                    session: findSession,
                    isEditable: isEditable,
                    onPrevious: findPrevious,
                    onNext: findNext,
                    onReplaceCurrent: replaceCurrent,
                    onPreviewReplaceAll: previewReplaceAll,
                    onClose: closeFind
                )
                Divider()
            }

            content

            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedValue(\.outlineVisibility, $isOutlineVisible)
        .focusedSceneValue(\.editorViewModeActions, editorViewModeCommandActions)
        .focusedSceneValue(\.documentFindActions, findCommandActions)
        .focusedSceneValue(\.htmlExportActions, htmlExportCommandActions)
        .focusedSceneValue(\.markdownFormatActions, markdownFormatCommandActions)
        .focusedSceneValue(\.markdownInsertActions, markdownInsertCommandActions)
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
                        set: { mode in selectViewMode(mode) }
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
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                delayNanoseconds: 0
            )
            if !findSession.query.isEmpty {
                scheduleFindSearch(
                    source: document.text,
                    position: .preserve,
                    revealAfterSearch: false,
                    delayNanoseconds: 0
                )
            }
        }
        .onChange(of: Data(document.text.utf8)) { _, _ in
            let markdown = document.text
            selectedHeadingID = nil
            sourceSelectionRequest = nil
            analysisState = .updating(previous: analysisState.displayedAnalysis)
            scheduleDerivedContent(
                for: markdown,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                delayNanoseconds: 120_000_000
            )
            if findSession.isPresented || !findSession.query.isEmpty {
                let replacementRange = pendingReplacementRange
                pendingReplacementRange = nil
                scheduleFindSearch(
                    source: markdown,
                    position: replacementRange.map(SearchRefreshPosition.afterReplacement)
                        ?? .preserve,
                    revealAfterSearch: replacementRange != nil,
                    delayNanoseconds: replacementRange == nil ? 80_000_000 : 0
                )
            }
        }
        .onChange(of: fileURL) { _, newURL in
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: newURL?.deletingLastPathComponent(),
                delayNanoseconds: 0
            )
        }
        .onChange(of: Data(findSession.query.utf8)) { _, _ in
            findSession.clearNotice()
            scheduleFindSearch(
                source: document.text,
                position: .first,
                revealAfterSearch: true,
                delayNanoseconds: 60_000_000
            )
        }
        .onChange(of: findSession.isCaseSensitive) { _, _ in
            findSession.clearNotice()
            scheduleFindSearch(
                source: document.text,
                position: .first,
                revealAfterSearch: true,
                delayNanoseconds: 60_000_000
            )
        }
        .onChange(of: Data(findSession.replacement.utf8)) { _, _ in
            findSession.clearNotice()
        }
        .onChange(of: isOutlineVisible) { _, isVisible in
            if isVisible {
                outlineFocusGeneration &+= 1
            }
        }
        .onDisappear {
            derivedContentTask?.cancel()
            findSearchTask?.cancel()
            pendingFindNavigation.removeAll()
            findSession.cancelSearch()
        }
        .sheet(item: $replaceAllPlan) { plan in
            ReplaceAllPreviewView(
                plan: plan,
                onCancel: { replaceAllPlan = nil },
                onApply: { applyReplaceAll(plan) }
            )
        }
        .sheet(item: $linkInsertionRequest) { request in
            MarkdownLinkInsertionView(
                request: request,
                onCancel: { linkInsertionRequest = nil },
                onInsert: { destination in insertLink(request, destination: destination) }
            )
        }
        .alert(item: $htmlExportNotice) { notice in
            notice.alert
        }
        .alert(
            "无法修改 Markdown",
            isPresented: Binding(
                get: { markdownFormatErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        markdownFormatErrorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(markdownFormatErrorMessage ?? "正文未被修改。")
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
            session: sourceEditorSession,
            isEditable: isEditable
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
        viewMode = viewMode.sourceVisible
        sourceSelectionGeneration &+= 1
        sourceSelectionRequest = SourceSelectionRequest(
            generation: sourceSelectionGeneration,
            utf8Range: heading.sourceUTF8Range
        )
    }

    private var findCommandActions: DocumentFindCommandActions {
        DocumentFindCommandActions(
            hasQuery: !findSession.query.isEmpty,
            canReplace: isEditable,
            showFind: { presentFind(replacing: false) },
            showReplace: { presentFind(replacing: true) },
            next: findNext,
            previous: findPrevious
        )
    }

    private var editorViewModeCommandActions: EditorViewModeCommandActions {
        EditorViewModeCommandActions(
            selectedMode: viewMode,
            select: { mode in selectViewMode(mode) }
        )
    }

    private var htmlExportCommandActions: HTMLExportCommandActions {
        HTMLExportCommandActions(
            isExporting: isExportingHTML,
            start: startHTMLExport
        )
    }

    private var markdownFormatCommandActions: MarkdownFormatCommandActions {
        let canClearFormat = isEditable && MarkdownFormatter.canClearFormat(
            source: document.text,
            selectedUTF16Range: sourceEditorSession.selectedUTF16Range
        )
        return MarkdownFormatCommandActions(
            canFormat: isEditable,
            canClearFormat: canClearFormat,
            apply: applyMarkdownFormat
        )
    }

    private var markdownInsertCommandActions: MarkdownInsertCommandActions {
        MarkdownInsertCommandActions(
            canInsert: isEditable,
            insertLink: presentLinkInsertion,
            insertImage: insertImage,
            insertTable: insertTable,
            insertHorizontalRule: insertHorizontalRule,
            insertFootnote: insertFootnote,
            insertFormula: insertFormula,
            insertDiagram: insertDiagram
        )
    }

    private func insertImage() {
        guard isEditable, !isImportingImage else { return }
        guard let documentURL = fileURL else {
            markdownFormatErrorMessage = ImageAssetImportError.unsavedDocument.localizedDescription
            return
        }
        let sourceSnapshot = document.text
        let selectedRange = sourceEditorSession.textView.selectedRange()
        let documentDirectory = documentURL.deletingLastPathComponent()
        let window = sourceEditorSession.textView.window ?? NSApp.keyWindow
        let worker = imageAssetWorker
        isImportingImage = true

        Task { @MainActor in
            defer { isImportingImage = false }
            guard let sourceURL = await ImageAssetPicker.chooseSource(attachedTo: window) else {
                return
            }

            do {
                let image = try await worker.loadSource(at: sourceURL)
                guard let placement = await ImageAssetPicker.choosePlacement(
                    filename: sourceURL.lastPathComponent,
                    attachedTo: window
                ) else {
                    return
                }
                let alternative = sourceURL.deletingPathExtension().lastPathComponent

                if placement == .keepOriginal {
                    let reference = try await worker.retainedReference(
                        sourceURL: sourceURL,
                        documentURL: documentURL
                    )
                    if !reference.isRelative {
                        guard await ImageAssetPicker.confirmAbsoluteReference(
                            filename: sourceURL.lastPathComponent,
                            attachedTo: window
                        ) else {
                            return
                        }
                    }
                    let plan = try MarkdownFormatter.imagePlan(
                        source: sourceSnapshot,
                        selectedUTF16Range: selectedRange,
                        destination: reference.markdownDestination,
                        defaultAlternative: alternative.isEmpty ? "图片描述" : alternative
                    )
                    viewMode = viewMode.sourceVisible
                    guard sourceEditorSession.applyMarkdownFormat(
                        plan,
                        actionName: "插入图片"
                    ) else {
                        markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未引用图片。"
                        return
                    }
                    imageDirectoryAccess.authorize(sourceURL)
                    await Task.yield()
                    _ = sourceEditorSession.focusEditor()
                    return
                }

                guard let authorizedDirectory = try await ImageAssetPicker.authorizeDocumentDirectory(
                    documentDirectory,
                    attachedTo: window
                ) else {
                    return
                }
                imageDirectoryAccess.authorize(authorizedDirectory)

                let filename = sourceURL.lastPathComponent
                let destinationSnapshot = try await worker.destinationSnapshot(
                    documentDirectory: authorizedDirectory,
                    originalFilename: filename
                )
                let resolution: ImageAssetCollisionResolution
                if destinationSnapshot.exists {
                    guard let choice = await ImageAssetPicker.resolveCollision(
                        filename: filename,
                        attachedTo: window
                    ) else {
                        return
                    }
                    resolution = choice
                } else {
                    resolution = .failIfExists
                }

                let asset = try await worker.importAsset(
                    image: image,
                    originalFilename: filename,
                    documentDirectory: authorizedDirectory,
                    collisionResolution: resolution,
                    expectedDestination: destinationSnapshot
                )
                do {
                    let plan = try MarkdownFormatter.imagePlan(
                        source: sourceSnapshot,
                        selectedUTF16Range: selectedRange,
                        destination: asset.relativeMarkdownPath,
                        defaultAlternative: alternative.isEmpty ? "图片描述" : alternative
                    )
                    viewMode = viewMode.sourceVisible
                    guard sourceEditorSession.applyMarkdownImage(
                        plan,
                        asset: asset,
                        actionName: "插入图片",
                        onResourceError: { message in
                            markdownFormatErrorMessage = message
                        }
                    ) else {
                        try await Task.detached { try asset.rollback() }.value
                        markdownFormatErrorMessage = "正文、选区或输入法状态已变化，已回滚复制的图片。"
                        return
                    }
                    await Task.yield()
                    _ = sourceEditorSession.focusEditor()
                } catch {
                    try? await Task.detached { try asset.rollback() }.value
                    throw error
                }
            } catch {
                markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? ImageAssetImportError.copyFailed.localizedDescription
            }
        }
    }

    private func insertDiagram() {
        guard isEditable else { return }
        do {
            let plan = try MarkdownFormatter.mermaidPlan(
                source: document.text,
                selectedUTF16Range: sourceEditorSession.textView.selectedRange()
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(plan, actionName: "插入图表") else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入图表。"
                return
            }
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func insertFormula() {
        guard isEditable else { return }
        do {
            let plan = try MarkdownFormatter.mathPlan(
                source: document.text,
                selectedUTF16Range: sourceEditorSession.textView.selectedRange()
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(plan, actionName: "插入公式") else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入公式。"
                return
            }
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func insertFootnote() {
        guard isEditable else { return }
        do {
            let plan = try MarkdownFormatter.footnotePlan(
                source: document.text,
                selectedUTF16Range: sourceEditorSession.textView.selectedRange()
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(plan, actionName: "插入脚注") else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入脚注。"
                return
            }
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func insertHorizontalRule() {
        guard isEditable else { return }
        do {
            let plan = try MarkdownFormatter.horizontalRulePlan(
                source: document.text,
                selectedUTF16Range: sourceEditorSession.textView.selectedRange()
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(plan, actionName: "插入分隔线") else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入分隔线。"
                return
            }
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func insertTable() {
        guard isEditable else { return }
        do {
            let plan = try MarkdownFormatter.tablePlan(
                source: document.text,
                selectedUTF16Range: sourceEditorSession.textView.selectedRange()
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(plan, actionName: "插入表格") else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入表格。"
                return
            }
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func presentLinkInsertion() {
        guard isEditable, linkInsertionRequest == nil else { return }
        linkInsertionRequest = MarkdownLinkInsertionRequest(
            sourceSnapshot: document.text,
            selectedUTF16Range: sourceEditorSession.textView.selectedRange()
        )
    }

    private func insertLink(
        _ request: MarkdownLinkInsertionRequest,
        destination: String
    ) {
        guard linkInsertionRequest?.id == request.id else { return }
        do {
            let plan = try MarkdownFormatter.linkPlan(
                source: request.sourceSnapshot,
                selectedUTF16Range: request.selectedUTF16Range,
                destination: destination
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(plan, actionName: "插入链接") else {
                linkInsertionRequest = nil
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入链接。"
                return
            }
            linkInsertionRequest = nil
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            linkInsertionRequest = nil
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func applyMarkdownFormat(_ command: MarkdownFormatCommand) {
        guard isEditable else { return }
        let source = document.text

        do {
            let plan = try MarkdownFormatter.plan(
                source: source,
                selectedUTF16Range: sourceEditorSession.textView.selectedRange(),
                command: command
            )
            viewMode = viewMode.sourceVisible
            guard sourceEditorSession.applyMarkdownFormat(
                plan,
                actionName: command.undoActionName
            ) else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未修改文档。"
                return
            }

            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        } catch {
            markdownFormatErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? MarkdownFormatError.coreFailure.localizedDescription
        }
    }

    private func startHTMLExport() {
        guard !isExportingHTML else { return }
        let snapshot = HTMLExportSnapshot(markdown: document.text)
        let basename = fileURL?.deletingPathExtension().lastPathComponent ?? "未命名文档"
        let suggestedFilename = "\(basename).html"
        let worker = htmlExportWorker
        isExportingHTML = true

        Task { @MainActor in
            defer { isExportingHTML = false }

            let generation = await worker.generate(snapshot)
            let html: Data
            switch generation {
            case let .success(data):
                html = data
            case let .failure(error):
                htmlExportNotice = .failure(error.localizedDescription)
                return
            }

            guard let targetURL = await HTMLExportPanel.chooseDestination(
                suggestedFilename: suggestedFilename
            ) else {
                return
            }

            let accessed = targetURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    targetURL.stopAccessingSecurityScopedResource()
                }
            }

            let targetSnapshot: HTMLExportTargetSnapshot
            do {
                targetSnapshot = try HTMLExportTargetSnapshot.capture(targetURL)
            } catch {
                htmlExportNotice = .failure(
                    (error as? LocalizedError)?.errorDescription
                        ?? HTMLExportTargetError.cannotInspect.localizedDescription
                )
                return
            }

            switch await worker.write(
                html,
                to: targetURL,
                expectedTarget: targetSnapshot
            ) {
            case .success:
                htmlExportNotice = .success(targetURL)
            case let .failure(error):
                htmlExportNotice = .failure(error.localizedDescription)
            }
        }
    }

    private func selectViewMode(_ mode: EditorViewMode) {
        viewMode = mode
        guard mode != .preview, !findSession.isPresented else { return }

        Task { @MainActor in
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
        }
    }

    private func presentFind(replacing: Bool) {
        guard !replacing || isEditable else { return }
        viewMode = viewMode.sourceVisible
        findSession.present(replacing: replacing)
        if !findSession.resultsAreCurrent(for: document.text) {
            scheduleFindSearch(
                source: document.text,
                position: .preserve,
                revealAfterSearch: false,
                delayNanoseconds: 0
            )
        }
    }

    private func closeFind() {
        findSession.dismiss()
        Task { @MainActor in
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
        }
    }

    private func findNext() {
        navigateFind(by: 1)
    }

    private func findPrevious() {
        navigateFind(by: -1)
    }

    private func navigateFind(by offset: Int) {
        viewMode = viewMode.sourceVisible
        if findSession.isSearching {
            pendingFindNavigation.append(offset)
            return
        }
        guard findSession.resultsAreCurrent(for: document.text) else {
            pendingFindNavigation.append(offset)
            scheduleFindSearch(
                source: document.text,
                position: .preserve,
                revealAfterSearch: false,
                delayNanoseconds: 0
            )
            return
        }
        reveal(offset > 0 ? findSession.moveNext() : findSession.movePrevious())
    }

    private func revealCurrentMatch() {
        reveal(findSession.currentMatch)
    }

    private func reveal(_ match: DocumentSearchMatch?) {
        guard let match else { return }
        viewMode = viewMode.sourceVisible
        sourceSelectionGeneration &+= 1
        sourceSelectionRequest = SourceSelectionRequest(
            generation: sourceSelectionGeneration,
            utf8Range: match.utf8Range,
            style: .match,
            focusesEditor: !findSession.isPresented
        )
    }

    private func replaceCurrent() {
        guard isEditable,
              findSession.canReplaceCurrent,
              let match = findSession.currentMatch
        else {
            return
        }
        guard UTF8Text.isExactlyEqual(findSession.sourceSnapshot, document.text) else {
            scheduleFindSearch(
                source: document.text,
                position: .preserve,
                revealAfterSearch: false,
                delayNanoseconds: 0
            )
            findSession.showNotice("正文已变化，查找结果已刷新；请重新确认替换。")
            return
        }

        let (replacementEnd, overflow) = match.utf8Range.lowerBound.addingReportingOverflow(
            findSession.replacement.utf8.count
        )
        guard !overflow else {
            findSession.showNotice("替换内容过大，未执行替换。")
            return
        }
        pendingReplacementRange = match.utf8Range.lowerBound..<replacementEnd
        let replaced = sourceEditorSession.replaceCurrent(
            utf8Range: match.utf8Range,
            with: findSession.replacement,
            expectedText: document.text
        )
        guard replaced else {
            pendingReplacementRange = nil
            scheduleFindSearch(
                source: document.text,
                position: .preserve,
                revealAfterSearch: false,
                delayNanoseconds: 0
            )
            findSession.showNotice("当前匹配已变化，未执行替换。")
            return
        }

        focusSourceForDocumentUndo()
        findSession.showNotice("已替换 1 处。")
    }

    private func previewReplaceAll() {
        guard isEditable else { return }
        do {
            replaceAllPlan = try findSession.makeReplaceAllPlan(source: document.text)
            if replaceAllPlan == nil {
                findSession.showNotice("当前没有可替换的匹配。")
            }
        } catch {
            findSession.showNotice(
                (error as? LocalizedError)?.errorDescription
                    ?? "暂时无法准备全部替换。"
            )
        }
    }

    private func applyReplaceAll(_ plan: ReplaceAllPlan) {
        guard isEditable,
              UTF8Text.isExactlyEqual(plan.source, document.text),
              UTF8Text.isExactlyEqual(plan.query, findSession.query),
              UTF8Text.isExactlyEqual(plan.replacement, findSession.replacement),
              plan.caseSensitive == findSession.isCaseSensitive
        else {
            replaceAllPlan = nil
            scheduleFindSearch(
                source: document.text,
                position: .preserve,
                revealAfterSearch: false,
                delayNanoseconds: 0
            )
            findSession.showNotice("正文或替换条件已变化，旧计划未执行；结果已刷新。")
            return
        }

        let replaced = sourceEditorSession.replaceAll(
            utf8Ranges: plan.matches.map(\.utf8Range),
            with: plan.replacement,
            expectedText: plan.source
        )
        replaceAllPlan = nil
        guard replaced else {
            scheduleFindSearch(
                source: document.text,
                position: .preserve,
                revealAfterSearch: false,
                delayNanoseconds: 0
            )
            findSession.showNotice("正文已变化，未执行全部替换。")
            return
        }

        focusSourceForDocumentUndo()
        findSession.showNotice("已替换 \(plan.matches.count) 处；可用“撤销”一次恢复。")
    }

    private func focusSourceForDocumentUndo() {
        Task { @MainActor in
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
        }
    }

    private func scheduleFindSearch(
        source: String,
        position: SearchRefreshPosition,
        revealAfterSearch: Bool,
        delayNanoseconds: UInt64
    ) {
        findSearchTask?.cancel()
        findSearchGeneration &+= 1
        let generation = findSearchGeneration
        let query = findSession.query
        let caseSensitive = findSession.isCaseSensitive
        let worker = findSearchWorker
        findSession.beginSearch()

        findSearchTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            guard let outcome = await worker.search(
                source: source,
                query: query,
                caseSensitive: caseSensitive
            ) else {
                return
            }
            guard !Task.isCancelled,
                  generation == findSearchGeneration,
                  UTF8Text.isExactlyEqual(document.text, source),
                  UTF8Text.isExactlyEqual(findSession.query, query),
                  findSession.isCaseSensitive == caseSensitive
            else {
                return
            }

            switch outcome {
            case let .success(result):
                findSession.applySearch(
                    result,
                    source: source,
                    query: query,
                    caseSensitive: caseSensitive,
                    position: position
                )
                let pendingNavigation = pendingFindNavigation
                pendingFindNavigation.removeAll()
                if !pendingNavigation.isEmpty {
                    var match = findSession.currentMatch
                    for offset in pendingNavigation {
                        match = offset > 0
                            ? findSession.moveNext()
                            : findSession.movePrevious()
                    }
                    reveal(match)
                } else if revealAfterSearch {
                    revealCurrentMatch()
                }
            case let .failure(message):
                pendingFindNavigation.removeAll()
                findSession.failSearch(
                    message: message,
                    source: source,
                    query: query,
                    caseSensitive: caseSensitive
                )
            }
        }
    }

    private func scheduleDerivedContent(
        for markdown: String,
        documentDirectory: URL?,
        delayNanoseconds: UInt64
    ) {
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        let generation = derivedContentGeneration

        derivedContentTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            guard let content = await contentDeriver.derive(
                markdown: markdown,
                documentDirectory: documentDirectory
            ) else { return }

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
    func derive(markdown: String, documentDirectory: URL?) -> DerivedDocumentContent? {
        guard !Task.isCancelled else { return nil }
        let html = MarkdownRenderer.htmlDocument(
            for: markdown,
            documentDirectory: documentDirectory
        )
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
