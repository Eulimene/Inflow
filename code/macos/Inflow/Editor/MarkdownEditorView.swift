import AppKit
import SwiftUI

private enum HTMLExportNotice: Identifiable {
    case success(URL)
    case failure(String)
    case pdfSuccess(URL)
    case pdfFailure(String)

    var id: String {
        switch self {
        case let .success(url): "success:\(url.path)"
        case let .failure(message): "failure:\(message)"
        case let .pdfSuccess(url): "pdf-success:\(url.path)"
        case let .pdfFailure(message): "pdf-failure:\(message)"
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
        case let .pdfSuccess(url):
            Alert(
                title: Text("PDF 导出完成"),
                message: Text("已导出到：\n\(url.path)"),
                primaryButton: .default(Text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                secondaryButton: .default(Text("打开 PDF")) {
                    NSWorkspace.shared.open(url)
                }
            )
        case let .pdfFailure(message):
            Alert(
                title: Text("PDF 导出未完成"),
                message: Text(message),
                dismissButton: .default(Text("好"))
            )
        }
    }
}

private struct PendingExportConfirmation: Identifiable {
    enum Format {
        case html
        case pdf
    }

    let id = UUID()
    let format: Format
    let preparation: HTMLExportPreparation
    let suggestedFilename: String
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

    static func initialMode(
        storedValue: String,
        lastActiveMode: EditorViewMode
    ) -> EditorViewMode {
        storedValue.isEmpty ? lastActiveMode : resolve(storedValue: storedValue)
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

enum EmptyMarkdownGuidance {
    static let title = "这份 Markdown 属于你"
    static let description =
        "直接在源码编辑器中开始写作；首次保存时由你选择文件名和位置，Inflow 不会把内容导入专有格式。"

    static func isVisible(markdown: String) -> Bool {
        markdown.isEmpty
    }
}

private struct EmptyMarkdownPreviewView: View {
    let onStartWriting: () -> Void
    let onOpenDocument: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(EmptyMarkdownGuidance.title, systemImage: "doc.text")
        } description: {
            Text(EmptyMarkdownGuidance.description)
        } actions: {
            VStack(spacing: 10) {
                Button("在源码编辑器中开始", action: onStartWriting)
                Button("打开现有 Markdown…", action: onOpenDocument)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
    }
}

struct MarkdownEditorView: View {
    @Environment(\.openDocument) private var openDocument
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    let isEditable: Bool
    var recoveryCoordinator: DocumentRecoveryCoordinator? = nil
    @ObservedObject private var preferences: AppPreferences
    private let anonymousUsage: AnonymousUsageDataController?
    private let recentDocuments: RecentDocumentsController?

    init(
        document: Binding<MarkdownDocument>,
        fileURL: URL?,
        isEditable: Bool,
        recoveryCoordinator: DocumentRecoveryCoordinator? = nil,
        preferences: AppPreferences? = nil,
        anonymousUsage: AnonymousUsageDataController? = nil,
        recentDocuments: RecentDocumentsController? = nil
    ) {
        _document = document
        self.fileURL = fileURL
        self.isEditable = isEditable
        self.recoveryCoordinator = recoveryCoordinator
        _preferences = ObservedObject(wrappedValue: preferences ?? AppPreferences())
        self.anonymousUsage = anonymousUsage
        self.recentDocuments = recentDocuments
    }

    @SceneStorage("editorViewMode") private var storedViewMode = ""
    @SceneStorage("isDocumentOutlineVisible") private var isOutlineVisible = true
    @SceneStorage("editorStatisticMode") private var storedStatisticMode =
        EditorStatisticMode.words.rawValue
    @SceneStorage("isFocusModeEnabled") private var isFocusModeEnabled = false
    @SceneStorage("isTypewriterModeEnabled") private var isTypewriterModeEnabled = false
    @SceneStorage("editorSplitFraction") private var editorSplitFraction =
        EditorSplitLayout.defaultFraction
    @State private var previewHTML = MarkdownRenderer.htmlDocument(for: "")
    @State private var analysisState = DocumentAnalysisState.updating(previous: .empty)
    @State private var derivedContentGeneration = 0
    @State private var derivedContentTask: Task<Void, Never>?
    @State private var contentDeriver = DocumentContentDeriver()
    @State private var previewScrollGeneration = 0
    @State private var previewScrollRequest: PreviewScrollRequest?
    @State private var previewScrollPausedByUser = false
    @State private var previewLinkGeneration = 0
    @State private var previewLinkTask: Task<Void, Never>?
    @State private var previewLinkWorker = PreviewLinkWorker()
    @State private var previewLinkPlan: PreviewLinkPlan?
    @State private var incomingHeadingFragment: String?
    @State private var incomingNavigationIsPending = false
    @State private var navigationRegistrationID = UUID()
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
    @State private var isExportingPDF = false
    @State private var htmlExportWorker = HTMLExportWorker()
    @State private var htmlExportNotice: HTMLExportNotice?
    @State private var pendingExportConfirmation: PendingExportConfirmation?
    @State private var markdownFormatErrorMessage: String?
    @State private var linkInsertionRequest: MarkdownLinkInsertionRequest?
    @State private var isImportingImage = false
    @State private var imageAssetWorker = ImageAssetWorker()
    @StateObject private var imageDirectoryAccess = ImageAssetDirectoryAccess()
    @State private var recoveryRecordID = UUID()
    @State private var isRecoveryCenterPresented = false
    @State private var didApplyRestorationState = false
    @StateObject private var fileSafetySession = DocumentFileSafetySession()
    @State private var isFileSafetyPresented = false
    @State private var fileSafetyNotice: DocumentFileSafetyNotice?
    @State private var relocationRequest: DocumentRelocationRequest?
    @State private var isRelocatingDocument = false
    @State private var relocationNativeDocument: NSDocument?
    @State private var isSavingDocument = false
    @State private var documentSaveFailureMessage: String?

    private var viewMode: EditorViewMode {
        get {
            EditorViewMode.initialMode(
                storedValue: storedViewMode,
                lastActiveMode: preferences.lastActiveEditorViewMode
            )
        }
        nonmutating set { storedViewMode = newValue.rawValue }
    }

    private var statisticMode: EditorStatisticMode {
        get { EditorStatisticMode(rawValue: storedStatisticMode) ?? .words }
        nonmutating set { storedStatisticMode = newValue.rawValue }
    }

    private var canEditDocument: Bool {
        isEditable
            && !document.properties.requiresLineEndingChoice
            && !fileSafetySession.state.blocksEditing
            && !isFileSafetyPresented
    }

    private var displayedFileSafetyState: DocumentFileSafetyState {
        if case .safe = fileSafetySession.state,
           !isEditable,
           let fileURL
        {
            return .readOnly(fileURL)
        }
        return fileSafetySession.state
    }

    var body: some View {
        presentationLayer
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            if let recoveryCoordinator {
                RecoveryProtectionStatusBanner(coordinator: recoveryCoordinator)
            }

            DocumentFileSafetyBanner(
                state: displayedFileSafetyState,
                onCompare: { isFileSafetyPresented = true },
                onSaveCopy: { beginDocumentRelocation(.saveCopy) }
            )

            if document.properties.requiresLineEndingChoice {
                lineEndingChoiceBanner
                Divider()
            }

            if findSession.isPresented {
                DocumentFindBar(
                    session: findSession,
                    isEditable: canEditDocument,
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
        .focusedSceneValue(\.previewZoomActions, previewZoomCommandActions)
        .focusedSceneValue(\.writingModeActions, writingModeCommandActions)
        .focusedSceneValue(\.documentFindActions, findCommandActions)
        .focusedSceneValue(\.htmlExportActions, htmlExportCommandActions)
        .focusedSceneValue(\.markdownFormatActions, markdownFormatCommandActions)
        .focusedSceneValue(\.markdownInsertActions, markdownInsertCommandActions)
        .focusedSceneValue(\.recoveryActions, recoveryCommandActions)
        .focusedSceneValue(\.documentSaveActions, documentSaveCommandActions)
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
    }

    private var documentObservationLayer: some View {
        editorSurface
        .onAppear {
            // SwiftUI creates its document controller while the app is launching.
            // Apply the host policy only after this document scene is attached.
            preferences.applyAutosavePolicy()
            registerDocumentNavigation(url: fileURL)
            if let fileURL {
                recentDocuments?.note(fileURL)
            }
            applyRestorationStateIfNeeded()
            initializeViewModeIfNeeded()
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                configuration: preferences.previewConfiguration,
                headingNavigationEnabled: preferences.headingNavigationEnabled,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
                delayNanoseconds: 0
            )
            requestPreviewScroll()
            if !findSession.query.isEmpty {
                scheduleFindSearch(
                    source: document.text,
                    position: .preserve,
                    revealAfterSearch: false,
                    delayNanoseconds: 0
                )
            }
            updateRecoveryProtection()
            fileSafetySession.update(document: document, fileURL: fileURL)
            if canEditDocument {
                sourceEditorSession.setWritingModes(
                    focusModeEnabled: isFocusModeEnabled,
                    typewriterModeEnabled: isTypewriterModeEnabled
                )
            } else {
                isFocusModeEnabled = false
                isTypewriterModeEnabled = false
            }
            if let recoveryCoordinator {
                Task {
                    await recoveryCoordinator.loadIfNeeded()
                    if recoveryCoordinator.claimAutomaticPresentation() {
                        isRecoveryCenterPresented = true
                    }
                }
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
                configuration: preferences.previewConfiguration,
                headingNavigationEnabled: preferences.headingNavigationEnabled,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
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
            updateRecoveryProtection()
            fileSafetySession.update(document: document, fileURL: fileURL)
        }
        .onChange(of: fileURL) { _, newURL in
            registerDocumentNavigation(url: newURL)
            if let newURL {
                recentDocuments?.note(newURL)
            }
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: newURL?.deletingLastPathComponent(),
                configuration: preferences.previewConfiguration,
                headingNavigationEnabled: preferences.headingNavigationEnabled,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
                delayNanoseconds: 0
            )
            updateRecoveryProtection()
            fileSafetySession.update(document: document, fileURL: newURL)
        }
        .onChange(of: document.properties) { _, _ in
            updateRecoveryProtection()
            fileSafetySession.update(document: document, fileURL: fileURL)
        }
        .onChange(of: storedViewMode) { _, _ in
            updateRecoveryProtection()
        }
        .onChange(of: preferences.previewConfiguration) { _, configuration in
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                configuration: configuration,
                headingNavigationEnabled: preferences.headingNavigationEnabled,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
                delayNanoseconds: 0
            )
        }
        .onChange(of: preferences.headingNavigationEnabled) { _, isEnabled in
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                configuration: preferences.previewConfiguration,
                headingNavigationEnabled: isEnabled,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
                delayNanoseconds: 0
            )
        }
        .onChange(of: preferences.syntaxHighlightingEnabled) { _, isEnabled in
            if !isEnabled {
                sourceEditorSession.applySyntaxHighlighting(
                    [],
                    source: document.text,
                    enabled: false
                )
            }
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                configuration: preferences.previewConfiguration,
                headingNavigationEnabled: preferences.headingNavigationEnabled,
                syntaxHighlightingEnabled: isEnabled,
                delayNanoseconds: 0
            )
        }
        .onChange(of: preferences.scrollSyncEnabled) { _, isEnabled in
            previewScrollPausedByUser = false
            if isEnabled {
                requestPreviewScroll()
            }
        }
        .onChange(of: isFocusModeEnabled) { _, _ in
            applyWritingModes()
        }
        .onChange(of: isTypewriterModeEnabled) { _, _ in
            applyWritingModes()
        }
        .onChange(of: canEditDocument) { _, canEdit in
            guard !canEdit else { return }
            isFocusModeEnabled = false
            isTypewriterModeEnabled = false
        }
    }

    private var interactionObservationLayer: some View {
        documentObservationLayer
        .onChange(of: sourceEditorSession.selectedUTF16Range) { _, _ in
            updateRecoveryProtection()
        }
        .onChange(of: sourceEditorSession.verticalScrollOffset) { _, _ in
            updateRecoveryProtection()
        }
        .onChange(of: sourceEditorSession.verticalScrollFraction) { _, _ in
            guard preferences.scrollSyncEnabled else { return }
            previewScrollPausedByUser = false
            requestPreviewScroll()
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
            previewLinkTask?.cancel()
            findSearchTask?.cancel()
            pendingFindNavigation.removeAll()
            findSession.cancelSearch()
            fileSafetySession.stopMonitoring()
            recoveryCoordinator?.close(recoveryRecordID)
            PreviewDocumentNavigationBroker.shared.unregister(id: navigationRegistrationID)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
            _ in
            recoveryCoordinator?.close(recoveryRecordID)
        }
    }

    private var presentationLayer: some View {
        interactionObservationLayer
        .sheet(item: $previewLinkPlan) { plan in
            PreviewLinkDecisionView(
                plan: plan,
                onCancel: { previewLinkPlan = nil },
                onConfirm: { confirmPreviewLink(plan) },
                onReveal: { url in
                    guard previewLocalTargetIsCurrent(plan, url: url) else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    previewLinkPlan = nil
                },
                onReauthorize: { url in reauthorizePreviewLink(plan, expectedURL: url) },
                onCopyTarget: { copyPreviewLinkTarget(plan) }
            )
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
        .sheet(isPresented: $isRecoveryCenterPresented) {
            if let recoveryCoordinator {
                RecoveryCenterView(
                    coordinator: recoveryCoordinator,
                    onClose: { isRecoveryCenterPresented = false }
                )
            }
        }
        .sheet(isPresented: $isFileSafetyPresented) {
            if let snapshot = fileSafetySession.state.conflictSnapshot {
                DocumentConflictReviewView(
                    snapshot: snapshot,
                    onSaveCopy: saveCopyFromConflictReview,
                    onReload: { try await reloadFromDisk(snapshot) },
                    onOverwrite: {
                        try await overwriteDiskVersion(snapshot)
                    },
                    onRecreate: { try await recreateDeletedFile(snapshot) },
                    onResolved: { isFileSafetyPresented = false },
                    onClose: { isFileSafetyPresented = false }
                )
            } else {
                ContentUnavailableView(
                    "文件状态已变化",
                    systemImage: "checkmark.circle",
                    description: Text("请关闭此窗口并查看当前文档状态。")
                )
                .frame(minWidth: 520, minHeight: 280)
            }
        }
        .sheet(item: $relocationRequest) { request in
            DocumentRelocationView(
                request: request,
                onCancel: {
                    relocationRequest = nil
                    relocationNativeDocument = nil
                },
                onConfirm: { await confirmDocumentRelocation(request) }
            )
        }
        .alert(item: $htmlExportNotice) { notice in
            notice.alert
        }
        .alert(item: $pendingExportConfirmation) { pending in
            Alert(
                title: Text("导出前发现可处理的问题"),
                message: Text(pending.preparation.warningMessage),
                primaryButton: .default(Text("明确继续")) {
                    continuePreparedExport(pending)
                },
                secondaryButton: .cancel(Text("返回修正"))
            )
        }
        .alert(item: $fileSafetyNotice) { notice in
            notice.alert
        }
        .confirmationDialog(
            "未能保存「\(fileURL?.lastPathComponent ?? "未命名文档")」",
            isPresented: Binding(
                get: { documentSaveFailureMessage != nil },
                set: { if !$0 { documentSaveFailureMessage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("重试") { saveCurrentDocument() }
            Button("另存为…") { beginDocumentRelocation(.saveAs) }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text(
                "\(documentSaveFailureMessage ?? "目标当前不可写。")\n\n原文件未被破坏，当前编辑仍已保留。"
            )
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
            PersistentHorizontalSplitView(fraction: $editorSplitFraction) {
                sourceEditor
                    .frame(minWidth: 320)
            } trailing: {
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
            isEditable: canEditDocument,
            appearance: preferences.sourceEditorAppearance,
            onPasteImage: pasteImage,
            onDropImage: dropImage
        )
    }

    private var preview: some View {
        ZStack {
            MarkdownPreviewView(
                html: previewHTML,
                baseURL: fileURL?.deletingLastPathComponent(),
                scrollRequest: preferences.scrollSyncEnabled && !previewScrollPausedByUser
                    ? previewScrollRequest
                    : nil,
                onHeadingActivated: activatePreviewHeading,
                onLinkActivated: activatePreviewLink,
                onManualScroll: {
                    if preferences.scrollSyncEnabled {
                        previewScrollPausedByUser = true
                    }
                }
            )

            if EmptyMarkdownGuidance.isVisible(markdown: document.text) {
                EmptyMarkdownPreviewView(
                    onStartWriting: {
                        selectViewMode(viewMode == .preview ? .source : viewMode)
                    },
                    onOpenDocument: {
                        recentDocuments?.chooseDocumentToOpen()
                    }
                )
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(
                fileURL?.lastPathComponent ?? "未命名文档",
                systemImage: fileURL == nil ? "doc.badge.plus" : "doc.text"
            )

            Text(viewMode.label)

            if isSavingDocument {
                Label("正在保存…", systemImage: "arrow.triangle.2.circlepath")
                    .accessibilityLabel("正在保存 Markdown 文档")
            }

            if isFocusModeEnabled {
                Label("专注", systemImage: "scope")
                    .accessibilityLabel("专注模式已开启")
            }
            if isTypewriterModeEnabled {
                Label("打字机", systemImage: "text.cursor")
                    .accessibilityLabel("打字机模式已开启")
            }

            Spacer()

            statisticsMenu
                .help(statisticsHelp)
            Text("UTF-8\(document.properties.hasUTF8BOM ? " BOM" : "")")
            Text(
                document.properties.requiresLineEndingChoice
                    ? "混合换行（待选择）"
                    : document.properties.lineEnding.displayName
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .contain)
    }

    private var lineEndingChoiceBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("请先选择换行方式")
                    .font(.headline)
                Text("该文件同时包含 LF、CRLF 或单独 CR。选择统一方式前保持只读，不会写回原文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("统一为 LF") {
                document.chooseLineEnding(.lf)
            }
            Button("统一为 CRLF") {
                document.chooseLineEnding(.crlf)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private var recoveryCommandActions: RecoveryCommandActions? {
        guard recoveryCoordinator != nil else { return nil }
        return RecoveryCommandActions {
            isRecoveryCenterPresented = true
        }
    }

    private var writingModeCommandActions: WritingModeCommandActions {
        WritingModeCommandActions(
            isFocusModeEnabled: isFocusModeEnabled,
            isTypewriterModeEnabled: isTypewriterModeEnabled,
            canEdit: canEditDocument,
            setFocusMode: { isEnabled in
                guard canEditDocument || !isEnabled else { return }
                isFocusModeEnabled = isEnabled
            },
            setTypewriterMode: { isEnabled in
                guard canEditDocument || !isEnabled else { return }
                isTypewriterModeEnabled = isEnabled
            }
        )
    }

    private var previewZoomCommandActions: PreviewZoomCommandActions {
        PreviewZoomCommandActions(zoom: preferences.previewZoom) { zoom in
            preferences.previewZoom = zoom
        }
    }

    private func applyWritingModes() {
        sourceEditorSession.setWritingModes(
            focusModeEnabled: isFocusModeEnabled,
            typewriterModeEnabled: isTypewriterModeEnabled
        )
        if isFocusModeEnabled || isTypewriterModeEnabled {
            viewMode = viewMode.sourceVisible
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        }
    }

    private func applyRestorationStateIfNeeded() {
        guard !didApplyRestorationState,
              let restorationState = document.restorationState,
              EditorViewMode(rawValue: restorationState.viewModeRawValue) != nil
        else {
            return
        }
        didApplyRestorationState = true
        storedViewMode = restorationState.viewModeRawValue
        sourceEditorSession.requestRestoration(restorationState)
    }

    private func initializeViewModeIfNeeded() {
        guard storedViewMode.isEmpty else { return }
        storedViewMode = preferences.lastActiveEditorViewMode.rawValue
    }

    private func updateRecoveryProtection() {
        guard let recoveryCoordinator else { return }
        recoveryCoordinator.update(
            DocumentRecoveryRecord(
                id: recoveryRecordID,
                document: document,
                originalURL: fileURL,
                selectedUTF16Range: sourceEditorSession.selectedUTF16Range,
                viewMode: viewMode,
                verticalScrollOffset: sourceEditorSession.verticalScrollOffset
            )
        )
    }

    private func reloadFromDisk(_ snapshot: DocumentFileConflictSnapshot) async throws {
        let result = try await fileSafetySession.reload(snapshot)
        document.properties = result.decoded.properties
        document.openedFileData = result.data
        document.text = result.decoded.text
        sourceEditorSession.resetAfterExternalReload(result.decoded.text)
    }

    private func overwriteDiskVersion(_ snapshot: DocumentFileConflictSnapshot) async throws
        -> URL
    {
        let conflictURL = try await fileSafetySession.overwrite(snapshot)
        fileSafetyNotice = .conflictCopySaved(conflictURL)
        return conflictURL
    }

    private func recreateDeletedFile(_ snapshot: DocumentFileConflictSnapshot) async throws {
        try await fileSafetySession.recreate(snapshot)
    }

    private var documentSaveCommandActions: DocumentSaveCommandActions {
        DocumentSaveCommandActions(
            isBusy: isSavingDocument || isRelocatingDocument || relocationRequest != nil,
            canSave: canEditDocument,
            save: saveCurrentDocument,
            saveAs: { beginDocumentRelocation(.saveAs) },
            saveCopy: { beginDocumentRelocation(.saveCopy) },
            showInFinder: fileURL.map { url in
                { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        )
    }

    private func saveCurrentDocument() {
        guard !isSavingDocument, !isRelocatingDocument, relocationRequest == nil else { return }
        guard let fileURL else {
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            return
        }
        guard let nativeDocument = NativeDocumentSaveCoordinator.activeDocument(
            sourceURL: fileURL
        ), NativeDocumentSaveCoordinator.represents(nativeDocument, sourceURL: fileURL) else {
            documentSaveFailureMessage = "无法确认当前文档的保存目标。"
            return
        }

        isSavingDocument = true
        Task { @MainActor in
            defer { isSavingDocument = false }
            do {
                try await NativeDocumentSaveCoordinator.saveCurrent(
                    document: nativeDocument,
                    to: fileURL
                )
                documentSaveFailureMessage = nil
            } catch {
                documentSaveFailureMessage = error.localizedDescription
            }
        }
    }

    private func beginDocumentRelocation(_ operation: DocumentRelocationOperation) {
        guard !isRelocatingDocument, relocationRequest == nil else { return }
        guard let nativeDocument = NativeDocumentSaveCoordinator.activeDocument(
            sourceURL: fileURL
        ) else {
            presentFileOperationFailure(DocumentRelocationError.cannotInspect)
            return
        }
        let snapshotData: Data
        do {
            snapshotData = try document.encodedFileData()
        } catch {
            presentFileOperationFailure(error, fallback: "当前正文无法编码，未写入任何文件。")
            return
        }

        let panel = NSSavePanel()
        panel.title = operation.panelTitle
        panel.prompt = operation.actionTitle
        panel.allowedContentTypes = [.inflowMarkdown]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "未命名文档.md"
        isRelocatingDocument = true
        relocationNativeDocument = nativeDocument

        Task { @MainActor in
            let response = await withCheckedContinuation { continuation in
                if let window = sourceEditorSession.textView.window ?? NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else {
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            defer { isRelocatingDocument = false }
            guard response == .OK, let targetURL = panel.url else {
                relocationNativeDocument = nil
                return
            }

            let accessed = targetURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { targetURL.stopAccessingSecurityScopedResource() }
            }

            if let openDocument = NativeDocumentSaveCoordinator.documentAlreadyOpen(
                at: targetURL,
                excluding: nativeDocument
            ) {
                openDocument.showWindows()
                openDocument.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                presentFileOperationFailure(DocumentRelocationError.targetOpen)
                relocationNativeDocument = nil
                return
            }

            do {
                guard try document.encodedFileData() == snapshotData else {
                    throw DocumentRelocationError.staleDecision
                }
                let plan = try DocumentRelocationAnalyzer.plan(
                    markdown: document.text,
                    sourceData: snapshotData,
                    sourceURL: fileURL,
                    targetURL: targetURL
                )
                relocationRequest = DocumentRelocationRequest(
                    operation: operation,
                    plan: plan
                )
            } catch {
                presentFileOperationFailure(error)
                relocationNativeDocument = nil
            }
        }
    }

    private func confirmDocumentRelocation(_ request: DocumentRelocationRequest) async {
        guard !isRelocatingDocument else { return }
        isRelocatingDocument = true
        defer { isRelocatingDocument = false }

        let accessed = request.plan.targetURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { request.plan.targetURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let currentData = try document.encodedFileData()
            try DocumentRelocationAnalyzer.verify(
                request.plan,
                currentData: currentData,
                currentSourceURL: fileURL
            )
            guard let nativeDocument = relocationNativeDocument,
                  NativeDocumentSaveCoordinator.represents(
                      nativeDocument,
                      sourceURL: request.plan.sourceURL
                  )
            else {
                throw DocumentRelocationError.cannotInspect
            }
            if let openDocument = NativeDocumentSaveCoordinator.documentAlreadyOpen(
                at: request.plan.targetURL,
                excluding: nativeDocument
            ) {
                openDocument.showWindows()
                openDocument.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                throw DocumentRelocationError.targetOpen
            }

            try document.writeGuard.authorizeRelocation(
                to: request.plan.targetURL,
                targetSnapshot: request.plan.targetSnapshot,
                proposedData: currentData,
                additionalValidation: {
                    DocumentRelocationAnalyzer.resourcesAreCurrent(request.plan)
                }
            )
            defer { document.writeGuard.cancelRelocationAuthorization() }
            try await NativeDocumentSaveCoordinator.save(
                document: nativeDocument,
                to: request.plan.targetURL,
                operation: request.operation
            )

            relocationRequest = nil
            relocationNativeDocument = nil
            switch request.operation {
            case .saveAs:
                fileSafetyNotice = .savedAs(request.plan.targetURL)
            case .saveCopy:
                fileSafetyNotice = .copySaved(request.plan.targetURL)
            }
        } catch {
            relocationRequest = nil
            relocationNativeDocument = nil
            presentFileOperationFailure(error)
        }
    }

    private func presentFileOperationFailure(
        _ error: Error,
        fallback: String = "未能安全完成文件操作；原文件与当前编辑均未改变。"
    ) {
        fileSafetyNotice = .failure(
            (error as? LocalizedError)?.errorDescription ?? fallback
        )
    }

    private func saveCopyFromConflictReview() {
        isFileSafetyPresented = false
        Task { @MainActor in
            await Task.yield()
            beginDocumentRelocation(.saveCopy)
        }
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

    private func activatePreviewHeading(sourceUTF8Offset: Int) {
        guard preferences.headingNavigationEnabled,
              analysisState.allowsNavigation,
              let heading = analysisState.displayedAnalysis.headings.first(where: {
                  $0.sourceUTF8Range.lowerBound == sourceUTF8Offset
              })
        else {
            return
        }
        selectHeading(heading)
    }

    private func activatePreviewLink(_ target: String) {
        previewLinkTask?.cancel()
        previewLinkGeneration &+= 1
        let generation = previewLinkGeneration
        let markdown = document.text
        let documentURL = fileURL

        previewLinkTask = Task { @MainActor in
            let plan = await previewLinkWorker.plan(
                markdown: markdown,
                target: target,
                documentURL: documentURL
            )
            guard !Task.isCancelled, generation == previewLinkGeneration else { return }
            guard PreviewLinkPlanner.isCurrent(plan, markdown: document.text) else {
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: target,
                    reason: .noLongerInDocument,
                    safeTarget: "该预览链接"
                )
                return
            }
            switch plan.destination {
            case let .currentDocument(fragment):
                navigateInCurrentDocument(to: fragment)
            case .external, .local, .blocked:
                previewLinkPlan = plan
            }
        }
    }

    private func navigateInCurrentDocument(to fragment: String?) {
        incomingHeadingFragment = fragment
        incomingNavigationIsPending = true
        applyPendingDocumentNavigationIfPossible()
    }

    private func applyPendingDocumentNavigationIfPossible() {
        guard incomingNavigationIsPending else { return }
        guard let fragment = incomingHeadingFragment else {
            incomingNavigationIsPending = false
            selectedHeadingID = nil
            viewMode = viewMode.sourceVisible
            sourceSelectionGeneration &+= 1
            sourceSelectionRequest = SourceSelectionRequest(
                generation: sourceSelectionGeneration,
                utf8Range: 0..<0
            )
            return
        }

        switch analysisState {
        case .updating:
            return
        case let .ready(analysis):
            incomingNavigationIsPending = false
            guard let heading = PreviewHeadingAnchorResolver.heading(
                for: fragment,
                in: analysis.headings
            ) else {
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: "#\(fragment)",
                    reason: .missingHeading,
                    safeTarget: "标题“\(fragment.prefix(80))”"
                )
                return
            }
            selectHeading(heading)
        case .failed:
            incomingNavigationIsPending = false
            previewLinkPlan = blockedPreviewLinkPlan(
                target: "#\(fragment)",
                reason: .missingHeading,
                safeTarget: "标题“\(fragment.prefix(80))”"
            )
        }
    }

    private func registerDocumentNavigation(url: URL?) {
        PreviewDocumentNavigationBroker.shared.register(
            id: navigationRegistrationID,
            url: url
        ) { fragment in
            navigateInCurrentDocument(to: fragment)
        }
    }

    private func confirmPreviewLink(_ plan: PreviewLinkPlan) {
        guard PreviewLinkPlanner.isCurrent(plan, markdown: document.text) else {
            previewLinkPlan = blockedPreviewLinkPlan(
                target: plan.target,
                reason: .noLongerInDocument,
                safeTarget: "该预览链接"
            )
            return
        }
        performResolvedPreviewLink(plan)
    }

    private func performResolvedPreviewLink(
        _ plan: PreviewLinkPlan,
        authorizedURL: URL? = nil
    ) {
        switch plan.destination {
        case let .external(link):
            previewLinkPlan = nil
            guard NSWorkspace.shared.open(link.url) else {
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: plan.target,
                    reason: .cannotOpen,
                    safeTarget: link.displayDestination
                )
                return
            }
        case let .local(link):
            let accessURL = authorizedURL ?? link.url
            guard accessURL.standardizedFileURL.path == link.url.standardizedFileURL.path else {
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: plan.target,
                    reason: .unavailableLocalTarget,
                    safeTarget: link.url.lastPathComponent,
                    expectedURL: link.url
                )
                return
            }
            let accessed = accessURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { accessURL.stopAccessingSecurityScopedResource() }
            }
            guard PreviewLinkPlanner.localTargetIsCurrent(link) else {
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: plan.target,
                    reason: .unavailableLocalTarget,
                    safeTarget: link.url.lastPathComponent,
                    expectedURL: link.url
                )
                return
            }
            previewLinkPlan = nil
            switch link.kind {
            case .markdown:
                openLinkedMarkdown(
                    link,
                    originalTarget: plan.target,
                    accessURL: accessURL
                )
            case .image, .pdf:
                guard NSWorkspace.shared.open(accessURL) else {
                    previewLinkPlan = blockedPreviewLinkPlan(
                        target: plan.target,
                        reason: .cannotOpen,
                        safeTarget: link.url.lastPathComponent,
                        expectedURL: link.url
                    )
                    return
                }
            case .attachment:
                NSWorkspace.shared.activateFileViewerSelecting([accessURL])
            }
        case let .currentDocument(fragment):
            previewLinkPlan = nil
            navigateInCurrentDocument(to: fragment)
        case .blocked:
            break
        }
    }

    private func openLinkedMarkdown(
        _ link: PreviewLocalLink,
        originalTarget: String,
        accessURL: URL
    ) {
        if PreviewDocumentNavigationBroker.shared.routeIfOpen(
            to: link.url,
            fragment: link.fragment
        ) {
            if let openDocument = NativeDocumentSaveCoordinator.documentAlreadyOpen(
                at: link.url,
                excluding: nil
            ) {
                openDocument.showWindows()
                openDocument.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            }
            return
        }

        let token = PreviewDocumentNavigationBroker.shared.enqueue(
            url: link.url,
            fragment: link.fragment
        )
        Task { @MainActor in
            let accessed = accessURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { accessURL.stopAccessingSecurityScopedResource() }
            }
            do {
                _ = try await openDocument(at: accessURL)
                try? await Task.sleep(for: .seconds(10))
                PreviewDocumentNavigationBroker.shared.cancelPending(
                    url: link.url,
                    token: token
                )
            } catch {
                PreviewDocumentNavigationBroker.shared.cancelPending(
                    url: link.url,
                    token: token
                )
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: originalTarget,
                    reason: .cannotOpen,
                    safeTarget: link.url.lastPathComponent,
                    expectedURL: link.url
                )
            }
        }
    }

    private func previewLocalTargetIsCurrent(_ plan: PreviewLinkPlan, url: URL) -> Bool {
        guard PreviewLinkPlanner.isCurrent(plan, markdown: document.text),
              case let .local(link) = plan.destination,
              link.url.standardizedFileURL.path == url.standardizedFileURL.path,
              PreviewLinkPlanner.localTargetIsCurrent(link)
        else {
            previewLinkPlan = blockedPreviewLinkPlan(
                target: plan.target,
                reason: .unavailableLocalTarget,
                safeTarget: url.lastPathComponent,
                expectedURL: url
            )
            return false
        }
        return true
    }

    private func reauthorizePreviewLink(_ plan: PreviewLinkPlan, expectedURL: URL) {
        previewLinkPlan = nil
        Task { @MainActor in
            await Task.yield()
            guard let chosen = await PreviewLinkAuthorization.chooseExactTarget(
                expectedURL,
                attachedTo: sourceEditorSession.textView.window ?? NSApp.keyWindow
            ) else {
                return
            }
            let accessed = chosen.startAccessingSecurityScopedResource()
            defer {
                if accessed { chosen.stopAccessingSecurityScopedResource() }
            }
            let refreshed = await previewLinkWorker.plan(
                markdown: document.text,
                target: plan.target,
                documentURL: fileURL
            )
            guard PreviewLinkPlanner.isCurrent(refreshed, markdown: document.text) else {
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: plan.target,
                    reason: .noLongerInDocument,
                    safeTarget: "该预览链接"
                )
                return
            }
            guard case let .local(link) = refreshed.destination,
                  link.url.standardizedFileURL.path == chosen.standardizedFileURL.path
            else {
                previewLinkPlan = refreshed
                return
            }
            performResolvedPreviewLink(refreshed, authorizedURL: chosen)
        }
    }

    private func copyPreviewLinkTarget(_ plan: PreviewLinkPlan) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plan.target, forType: .string)
        previewLinkPlan = nil
    }

    private func blockedPreviewLinkPlan(
        target: String,
        reason: PreviewLinkFailureReason,
        safeTarget: String,
        expectedURL: URL? = nil
    ) -> PreviewLinkPlan {
        PreviewLinkPlan(
            sourceUTF8: Data(document.text.utf8),
            target: target,
            destination: .blocked(
                PreviewLinkFailure(
                    reason: reason,
                    safeTarget: safeTarget,
                    expectedURL: expectedURL
                )
            )
        )
    }

    private func requestPreviewScroll() {
        guard preferences.scrollSyncEnabled else { return }
        previewScrollGeneration &+= 1
        previewScrollRequest = PreviewScrollRequest(
            generation: previewScrollGeneration,
            fraction: sourceEditorSession.verticalScrollFraction
        )
    }

    private var findCommandActions: DocumentFindCommandActions {
        DocumentFindCommandActions(
            hasQuery: !findSession.query.isEmpty,
            canReplace: canEditDocument,
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
            isExportingHTML: isExportingHTML,
            isExportingPDF: isExportingPDF,
            startHTML: startHTMLExport,
            startPDF: startPDFExport
        )
    }

    private var markdownFormatCommandActions: MarkdownFormatCommandActions {
        let canClearFormat = canEditDocument && MarkdownFormatter.canClearFormat(
            source: document.text,
            selectedUTF16Range: sourceEditorSession.selectedUTF16Range
        )
        return MarkdownFormatCommandActions(
            canFormat: canEditDocument,
            canClearFormat: canClearFormat,
            apply: applyMarkdownFormat
        )
    }

    private var markdownInsertCommandActions: MarkdownInsertCommandActions {
        MarkdownInsertCommandActions(
            canInsert: canEditDocument,
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
        importExistingImage(from: nil)
    }

    private func dropImage(_ sourceURL: URL) {
        importExistingImage(from: sourceURL)
    }

    private func importExistingImage(from providedSourceURL: URL?) {
        guard canEditDocument, !isImportingImage else { return }
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
            let sourceURL: URL
            if let providedSourceURL {
                sourceURL = providedSourceURL
            } else {
                guard let selectedURL = await ImageAssetPicker.chooseSource(attachedTo: window) else {
                    return
                }
                sourceURL = selectedURL
            }

            do {
                let image = try await worker.loadSource(at: sourceURL)
                let placement: ExistingImagePlacement
                if let automaticPlacement = preferences.existingImagePlacement.automaticPlacement {
                    placement = automaticPlacement
                } else {
                    guard let selectedPlacement = await ImageAssetPicker.choosePlacement(
                        filename: sourceURL.lastPathComponent,
                        attachedTo: window
                    ) else {
                        return
                    }
                    placement = selectedPlacement
                }
                let alternative = sourceURL.deletingPathExtension().lastPathComponent

                if placement == .keepOriginal {
                    try await retainExistingImage(
                        sourceURL: sourceURL,
                        documentURL: documentURL,
                        sourceSnapshot: sourceSnapshot,
                        selectedRange: selectedRange,
                        defaultAlternative: alternative,
                        window: window,
                        worker: worker
                    )
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
                    guard let choice = await ImageAssetPicker.resolveExistingImageCollision(
                        filename: filename,
                        attachedTo: window
                    ) else {
                        return
                    }
                    switch choice {
                    case .incrementName:
                        resolution = .incrementName
                    case .replace:
                        resolution = .replace
                    case .keepOriginal:
                        try await retainExistingImage(
                            sourceURL: sourceURL,
                            documentURL: documentURL,
                            sourceSnapshot: sourceSnapshot,
                            selectedRange: selectedRange,
                            defaultAlternative: alternative,
                            window: window,
                            worker: worker
                        )
                        return
                    }
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

    @MainActor
    private func retainExistingImage(
        sourceURL: URL,
        documentURL: URL,
        sourceSnapshot: String,
        selectedRange: NSRange,
        defaultAlternative: String,
        window: NSWindow?,
        worker: ImageAssetWorker
    ) async throws {
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
            defaultAlternative: defaultAlternative.isEmpty
                ? "图片描述"
                : defaultAlternative
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
    }

    private func pasteImage(_ payload: ClipboardImagePayload) {
        guard canEditDocument, !isImportingImage else { return }
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
            do {
                let image = try await worker.prepareClipboardImage(payload)
                guard let authorizedDirectory = try await ImageAssetPicker.authorizeDocumentDirectory(
                    documentDirectory,
                    attachedTo: window
                ) else {
                    return
                }
                imageDirectoryAccess.authorize(authorizedDirectory)
                let asset = try await worker.importClipboardImage(
                    image,
                    documentDirectory: authorizedDirectory
                )
                do {
                    let alternative = asset.destinationURL.deletingPathExtension().lastPathComponent
                    let plan = try MarkdownFormatter.imagePlan(
                        source: sourceSnapshot,
                        selectedUTF16Range: selectedRange,
                        destination: asset.relativeMarkdownPath,
                        defaultAlternative: alternative
                    )
                    viewMode = viewMode.sourceVisible
                    guard sourceEditorSession.applyMarkdownImage(
                        plan,
                        asset: asset,
                        actionName: "粘贴图片",
                        onResourceError: { message in
                            markdownFormatErrorMessage = message
                        }
                    ) else {
                        try await Task.detached { try asset.rollback() }.value
                        markdownFormatErrorMessage = "正文、选区或输入法状态已变化，已回滚粘贴的图片。"
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
        guard canEditDocument else { return }
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
        guard canEditDocument else { return }
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
        guard canEditDocument else { return }
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
        guard canEditDocument else { return }
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
        guard canEditDocument else { return }
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
        guard canEditDocument, linkInsertionRequest == nil else { return }
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
        guard canEditDocument else { return }
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
            anonymousUsage?.record(feature: .formatting, command: .formatMarkdown)

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
        guard !isExportingHTML, !isExportingPDF else { return }
        anonymousUsage?.record(feature: .export, command: .exportHTML)
        let snapshot = HTMLExportSnapshot(
            markdown: document.text,
            documentDirectory: fileURL?.deletingLastPathComponent(),
            appearance: preferences.previewConfiguration
        )
        let basename = fileURL?.deletingPathExtension().lastPathComponent ?? "未命名文档"
        let suggestedFilename = "\(basename).html"
        let worker = htmlExportWorker
        isExportingHTML = true

        Task { @MainActor in
            let preparation: HTMLExportPreparation
            switch await worker.prepare(snapshot) {
            case let .success(value):
                preparation = value
            case let .failure(error):
                isExportingHTML = false
                htmlExportNotice = .failure(error.localizedDescription)
                return
            }

            guard preparation.warnings.isEmpty else {
                isExportingHTML = false
                pendingExportConfirmation = PendingExportConfirmation(
                    format: .html,
                    preparation: preparation,
                    suggestedFilename: suggestedFilename
                )
                return
            }
            isExportingHTML = false
            continuePreparedHTMLExport(preparation, suggestedFilename: suggestedFilename)
        }
    }

    private func startPDFExport() {
        guard !isExportingHTML, !isExportingPDF else { return }
        anonymousUsage?.record(feature: .export, command: .exportPDF)
        let snapshot = HTMLExportSnapshot(
            markdown: document.text,
            documentDirectory: fileURL?.deletingLastPathComponent(),
            appearance: preferences.previewConfiguration
        )
        let basename = fileURL?.deletingPathExtension().lastPathComponent ?? "未命名文档"
        let worker = htmlExportWorker
        isExportingPDF = true

        Task { @MainActor in
            let preparation: HTMLExportPreparation
            switch await worker.prepare(snapshot) {
            case let .success(value):
                preparation = value
            case let .failure(error):
                isExportingPDF = false
                htmlExportNotice = .pdfFailure(error.localizedDescription)
                return
            }

            let suggestedFilename = "\(basename).pdf"
            guard preparation.warnings.isEmpty else {
                isExportingPDF = false
                pendingExportConfirmation = PendingExportConfirmation(
                    format: .pdf,
                    preparation: preparation,
                    suggestedFilename: suggestedFilename
                )
                return
            }
            isExportingPDF = false
            continuePreparedPDFExport(preparation, suggestedFilename: suggestedFilename)
        }
    }

    private func continuePreparedExport(_ pending: PendingExportConfirmation) {
        switch pending.format {
        case .html:
            continuePreparedHTMLExport(
                pending.preparation,
                suggestedFilename: pending.suggestedFilename
            )
        case .pdf:
            continuePreparedPDFExport(
                pending.preparation,
                suggestedFilename: pending.suggestedFilename
            )
        }
    }

    private func continuePreparedHTMLExport(
        _ preparation: HTMLExportPreparation,
        suggestedFilename: String
    ) {
        guard !isExportingHTML, !isExportingPDF else { return }
        let worker = htmlExportWorker
        isExportingHTML = true
        Task { @MainActor in
            defer { isExportingHTML = false }
            guard let targetURL = await HTMLExportPanel.chooseDestination(
                suggestedFilename: suggestedFilename
            ) else { return }

            let accessed = targetURL.startAccessingSecurityScopedResource()
            defer { if accessed { targetURL.stopAccessingSecurityScopedResource() } }
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
                preparation.data,
                to: targetURL,
                expectedTarget: targetSnapshot
            ) {
            case .success: htmlExportNotice = .success(targetURL)
            case let .failure(error): htmlExportNotice = .failure(error.localizedDescription)
            }
        }
    }

    private func continuePreparedPDFExport(
        _ preparation: HTMLExportPreparation,
        suggestedFilename: String
    ) {
        guard !isExportingHTML, !isExportingPDF else { return }
        let worker = htmlExportWorker
        isExportingPDF = true
        Task { @MainActor in
            defer { isExportingPDF = false }
            let pdf: Data
            do {
                pdf = try await PDFExporter.generate(fromSelfContainedHTML: preparation.data)
            } catch {
                htmlExportNotice = .pdfFailure(
                    (error as? LocalizedError)?.errorDescription
                        ?? PDFExportError.renderingFailed.localizedDescription
                )
                return
            }
            guard let targetURL = await PDFExportPanel.chooseDestination(
                suggestedFilename: suggestedFilename
            ) else { return }

            let accessed = targetURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { targetURL.stopAccessingSecurityScopedResource() }
            }
            let targetSnapshot: HTMLExportTargetSnapshot
            do {
                targetSnapshot = try HTMLExportTargetSnapshot.capture(targetURL)
            } catch {
                htmlExportNotice = .pdfFailure(
                    (error as? LocalizedError)?.errorDescription
                        ?? HTMLExportTargetError.cannotInspect.localizedDescription
                )
                return
            }

            switch await worker.write(pdf, to: targetURL, expectedTarget: targetSnapshot) {
            case .success:
                htmlExportNotice = .pdfSuccess(targetURL)
            case let .failure(error):
                htmlExportNotice = .pdfFailure(error.localizedDescription)
            }
        }
    }

    private func selectViewMode(_ mode: EditorViewMode) {
        viewMode = mode
        preferences.recordActiveEditorViewMode(mode)
        let command: AnonymousUsageCommand = switch mode {
        case .source: .selectSourceView
        case .split: .selectSplitView
        case .preview: .selectPreviewView
        }
        anonymousUsage?.record(feature: .preview, command: command)
        guard mode != .preview, !findSession.isPresented else { return }

        Task { @MainActor in
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
        }
    }

    private func presentFind(replacing: Bool) {
        guard !replacing || canEditDocument else { return }
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
        guard canEditDocument,
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
        guard canEditDocument else { return }
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
        guard canEditDocument,
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
        configuration: PreviewAppearanceConfiguration,
        headingNavigationEnabled: Bool,
        syntaxHighlightingEnabled: Bool,
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
                documentDirectory: documentDirectory,
                configuration: configuration,
                headingNavigationEnabled: headingNavigationEnabled,
                syntaxHighlightingEnabled: syntaxHighlightingEnabled
            ) else { return }

            guard !Task.isCancelled, generation == derivedContentGeneration else { return }
            previewHTML = content.html
            _ = sourceEditorSession.applySyntaxHighlighting(
                content.syntaxHighlighting,
                source: markdown,
                enabled: syntaxHighlightingEnabled
            )
            switch content.analysis {
            case let .success(analysis):
                analysisState = .ready(analysis)
                applyPendingDocumentNavigationIfPossible()
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
    let syntaxHighlighting: [MarkdownSyntaxSpan]
}

private enum DocumentAnalysisOutcome: Sendable {
    case success(DocumentAnalysis)
    case failure(String)
}

private actor DocumentContentDeriver {
    func derive(
        markdown: String,
        documentDirectory: URL?,
        configuration: PreviewAppearanceConfiguration,
        headingNavigationEnabled: Bool,
        syntaxHighlightingEnabled: Bool
    ) -> DerivedDocumentContent? {
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
        let syntaxHighlighting: [MarkdownSyntaxSpan] = if syntaxHighlightingEnabled {
            (try? MarkdownHighlighter.spans(in: markdown)) ?? []
        } else {
            []
        }

        guard !Task.isCancelled else { return nil }
        let headings: [DocumentHeading]
        if headingNavigationEnabled, case let .success(documentAnalysis) = analysis {
            headings = documentAnalysis.headings
        } else {
            headings = []
        }
        let html = MarkdownRenderer.htmlDocument(
            for: markdown,
            documentDirectory: documentDirectory,
            configuration: configuration,
            navigationHeadings: headings
        )
        guard !Task.isCancelled else { return nil }
        return DerivedDocumentContent(
            html: html,
            analysis: analysis,
            syntaxHighlighting: syntaxHighlighting
        )
    }
}
