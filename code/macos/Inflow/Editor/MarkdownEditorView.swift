import AppKit
import SwiftUI

enum ExportFormat: String, Sendable {
    case html = "HTML"
    case pdf = "PDF"

    var filenameExtension: String {
        rawValue.lowercased()
    }

    var alternate: Self {
        self == .html ? .pdf : .html
    }
}

struct FrozenExportRequest: Sendable {
    let format: ExportFormat
    let snapshot: HTMLExportSnapshot
    let suggestedFilename: String

    func changingFormat() -> Self {
        let stem = (suggestedFilename as NSString).deletingPathExtension
        let alternateFormat = format.alternate
        return Self(
            format: alternateFormat,
            snapshot: snapshot,
            suggestedFilename: "\(stem).\(alternateFormat.filenameExtension)"
        )
    }
}

private struct PreparedExportDelivery: Sendable {
    let request: FrozenExportRequest
    let data: Data
}

private enum ExportRecoveryContext: Sendable {
    case prepare(FrozenExportRequest)
    case capture(PreparedExportDelivery, URL)
    case write(PreparedExportDelivery, URL, HTMLExportTargetSnapshot)

    var request: FrozenExportRequest {
        switch self {
        case let .prepare(request): request
        case let .capture(delivery, _), let .write(delivery, _, _): delivery.request
        }
    }

    var delivery: PreparedExportDelivery? {
        switch self {
        case .prepare: nil
        case let .capture(delivery, _), let .write(delivery, _, _): delivery
        }
    }

    var fileName: String {
        switch self {
        case let .prepare(request): request.suggestedFilename
        case let .capture(_, url), let .write(_, url, _): url.lastPathComponent
        }
    }
}

private enum ExportDeliveryStep: Sendable {
    case chooseDestination
    case capture(URL)
    case write(URL, HTMLExportTargetSnapshot)
}

private enum ExportNoticeOutcome: Sendable {
    case success(format: ExportFormat, url: URL, documentVersion: String)
    case targetChanged(delivery: PreparedExportDelivery, targetURL: URL)
    case tooLarge(FrozenExportRequest)
    case checkFailed(request: FrozenExportRequest, details: String)
    case failure(context: ExportRecoveryContext, reason: String)
}

private struct HTMLExportNotice: Identifiable {
    let id = UUID()
    let outcome: ExportNoticeOutcome

    static func success(
        format: ExportFormat,
        url: URL,
        documentVersion: String
    ) -> Self {
        Self(outcome: .success(format: format, url: url, documentVersion: documentVersion))
    }

    var title: String {
        switch outcome {
        case let .success(_, url, _):
            ExportResultPrompt.successTitle(exportName: url.lastPathComponent)
        case .targetChanged:
            ExportFailurePrompt.targetChangedTitle
        case .tooLarge:
            ExportFailurePrompt.tooLargeTitle
        case .checkFailed:
            ExportFailurePrompt.checkFailedTitle
        case let .failure(context, _):
            ExportFailurePrompt.failureTitle(fileName: context.fileName)
        }
    }

    var message: String {
        switch outcome {
        case let .success(_, _, documentVersion):
            ExportResultPrompt.successMessage(documentVersion: documentVersion)
        case .targetChanged:
            ExportFailurePrompt.targetChangedMessage
        case .tooLarge:
            ExportFailurePrompt.tooLargeMessage(limit: ExportFailurePrompt.outputLimit)
        case .checkFailed:
            ExportFailurePrompt.checkFailedMessage
        case let .failure(_, reason):
            ExportFailurePrompt.failureMessage(reason: reason)
        }
    }
}

enum ExportProgressPrompt {
    static let cancelTitle = "取消"

    static func title(format: String) -> String {
        "正在导出 \(format)…"
    }

    static func message(documentVersion: String) -> String {
        "使用文档版本 \(documentVersion)。"
    }
}

enum ExportResultPrompt {
    static let showInFinderTitle = "在 Finder 中显示"
    static let openTitle = "打开"
    static let doneTitle = "完成"

    static func successTitle(exportName: String) -> String {
        "已导出「\(exportName)」"
    }

    static func successMessage(documentVersion: String) -> String {
        "使用文档版本 \(documentVersion)。"
    }
}

enum ExportFailurePrompt {
    static let outputLimit = "100 MiB"
    static let targetChangedTitle = "导出目标已变化"
    static let targetChangedMessage = "选择位置后，目标已被创建、替换或修改。"
    static let reconfirmReplacementTitle = "重新确认替换…"
    static let chooseAnotherLocationTitle = "选择其他位置…"
    static let cancelTitle = "取消"
    static let tooLargeTitle = "导出内容过大"
    static let returnToAdjustTitle = "返回调整"
    static let changeFormatTitle = "更换格式…"
    static let checkFailedTitle = "导出结果未通过检查"
    static let checkFailedMessage =
        "交付物包含不安全动作、私密路径或结构不完整，因此没有替换目标。"
    static let viewProblemsTitle = "查看问题"
    static let closeTitle = "关闭"
    static let retryTitle = "重试"

    static func tooLargeMessage(limit: String) -> String {
        "预计交付物超出\(limit)，未写入目标。"
    }

    static func failureTitle(fileName: String) -> String {
        "未能导出「\(fileName)」"
    }

    static func failureMessage(reason: String) -> String {
        let normalized = reason.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "。.!！?？")
            )
        )
        return "\(normalized)。Markdown 文档未改变，也没有留下残缺目标。"
    }
}

private struct ExportIssueDetails: Identifiable {
    let id = UUID()
    let message: String
}

private struct ActiveExportProgress: Equatable {
    let format: ExportFormat
    let documentVersion: String
    let isCancellable: Bool
}

private struct ExportProgressBanner: View {
    let progress: ActiveExportProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ExportProgressPrompt.title(format: progress.format.rawValue))
                        .font(.headline)
                    Text(
                        ExportProgressPrompt.message(
                            documentVersion: progress.documentVersion
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if progress.isCancellable {
                    Button(ExportProgressPrompt.cancelTitle, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Text("正在安全完成写入")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            .accessibilityElement(children: .contain)
            Divider()
        }
    }
}

private struct PendingExportConfirmation: Identifiable {
    let id = UUID()
    let request: FrozenExportRequest
    let preparation: HTMLExportPreparation
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
        "直接在源码编辑器中开始写作，或打开文件夹后从侧栏选择 Markdown。首次保存时由你选择文件名和位置，Inflow 不会把内容导入专有格式。"

    static func isVisible(markdown: String) -> Bool {
        markdown.isEmpty
    }
}

enum MixedLineEndingPrompt {
    static let title = "选择这份文档的换行方式"
    static let message = "检测到 LF 和 CRLF 混合。作出选择前，文档保持只读且不会自动保存。"
    static let useLFTitle = "使用 LF"
    static let useCRLFTitle = "使用 CRLF"
    static let closeTitle = "关闭文档"

    @MainActor
    static func closeDocumentWindow(_ window: NSWindow?) {
        window?.performClose(nil)
    }
}

private struct RelativeResourceDirectoryAccessBanner: View {
    let directory: URL
    let onAuthorize: () -> Void
    let onDefer: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("允许访问「\(directory.lastPathComponent)」？")
                    .font(.headline)
                Text(ImageAssetPicker.resourceDirectoryPromptMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("选择目录…", action: onAuthorize)
            Button("暂不", action: onDefer)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

private enum DocumentDirectoryAccessDecisionError: Error, LocalizedError {
    case declined

    var errorDescription: String? {
        "未授权当前 Markdown 文档所在目录，因此没有执行文件操作。当前编辑和磁盘内容均未丢失。"
    }
}

private struct DocumentDirectoryAccessRequest {
    let directory: URL
    let conflictSnapshotID: DocumentFileConflictSnapshot.ID?
}

enum DeferredImageInsertion: Equatable {
    case chooseExistingImage
    case paste(ClipboardImagePayload)
    case drop(URL)

    static let savePanelTitle = "先保存这份 Markdown"
    static let savePanelMessage =
        "图片必须保存在你确认的文档相对目录中。保存成功后会继续本次图片操作；取消不会创建资源。"
    static let savePanelActionTitle = "保存并继续"
}

struct DeferredImageInsertionQueue: Equatable {
    private(set) var pending: DeferredImageInsertion?

    var hasPending: Bool { pending != nil }

    mutating func enqueue(_ insertion: DeferredImageInsertion) -> Bool {
        guard pending == nil else { return false }
        pending = insertion
        return true
    }

    mutating func cancel() {
        pending = nil
    }

    mutating func consumeAfterSuccessfulSave() -> DeferredImageInsertion? {
        defer { pending = nil }
        return pending
    }
}

private struct EmptyMarkdownPreviewView: View {
    let onStartWriting: () -> Void
    let onOpenFolder: () -> Void
    let onOpenDocument: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(EmptyMarkdownGuidance.title, systemImage: "doc.text")
        } description: {
            Text(EmptyMarkdownGuidance.description)
        } actions: {
            VStack(spacing: 10) {
                Button("在源码编辑器中开始", action: onStartWriting)
                Button("打开文件夹…", action: onOpenFolder)
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
    @ObservedObject private var folderBrowser: FolderBrowserController

    init(
        document: Binding<MarkdownDocument>,
        fileURL: URL?,
        isEditable: Bool,
        recoveryCoordinator: DocumentRecoveryCoordinator? = nil,
        preferences: AppPreferences? = nil,
        anonymousUsage: AnonymousUsageDataController? = nil,
        recentDocuments: RecentDocumentsController? = nil,
        folderBrowser: FolderBrowserController
    ) {
        _document = document
        self.fileURL = fileURL
        self.isEditable = isEditable
        self.recoveryCoordinator = recoveryCoordinator
        _preferences = ObservedObject(wrappedValue: preferences ?? AppPreferences())
        self.anonymousUsage = anonymousUsage
        self.recentDocuments = recentDocuments
        _folderBrowser = ObservedObject(wrappedValue: folderBrowser)
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
    @State private var previewSourceSnapshot = ""
    @State private var previewFailureMessage: String?
    @State private var relativeResourceSourceSnapshot = ""
    @State private var hasRelativeResources = false
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
    @State private var exportTask: Task<Void, Never>?
    @State private var exportGeneration = 0
    @State private var activeExportProgress: ActiveExportProgress?
    @State private var htmlExportNotice: HTMLExportNotice?
    @State private var exportIssueDetails: ExportIssueDetails?
    @State private var pendingExportConfirmation: PendingExportConfirmation?
    @State private var markdownFormatErrorMessage: String?
    @State private var linkInsertionRequest: MarkdownLinkInsertionRequest?
    @State private var isImportingImage = false
    @State private var deferredImageInsertionQueue = DeferredImageInsertionQueue()
    @State private var imageAssetWorker = ImageAssetWorker()
    @StateObject private var imageDirectoryAccess = ImageAssetDirectoryAccess()
    @State private var deferredResourceDirectoryPath: String?
    @State private var deferredDirectoryConflictSnapshotID:
        DocumentFileConflictSnapshot.ID?
    @State private var resourceDirectoryAccessErrorMessage: String?
    @State private var recoveryRecordID = UUID()
    @State private var isRecoveryCenterPresented = false
    @State private var didApplyRestorationState = false
    @StateObject private var fileSafetySession = DocumentFileSafetySession()
    @State private var isFileSafetyPresented = false
    @State private var requestedConflictDecision: DocumentConflictDecision?
    @State private var deferredFileSafetySnapshotID: DocumentFileConflictSnapshot.ID?
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

    private var pendingResourceDirectoryAuthorization: DocumentDirectoryAccessRequest? {
        guard let fileURL else { return nil }
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        guard !imageDirectoryAccess.isAuthorized(directory) else { return nil }

        let conflictSnapshotID = fileSafetySession.state.directoryMutationSnapshotID
        let needsConflictAccess = conflictSnapshotID != nil
            && conflictSnapshotID != deferredDirectoryConflictSnapshotID
        let needsRelativeResourceAccess = UTF8Text.isExactlyEqual(
            relativeResourceSourceSnapshot,
            document.text
        ) && hasRelativeResources
            && deferredResourceDirectoryPath != directory.path
        guard needsConflictAccess || needsRelativeResourceAccess else { return nil }

        return DocumentDirectoryAccessRequest(
            directory: directory,
            conflictSnapshotID: conflictSnapshotID
        )
    }

    var body: some View {
        presentationLayer
            .alert(
                "文件夹访问需要确认",
                isPresented: Binding(
                    get: { folderBrowser.restorationWarning != nil },
                    set: { if !$0 { folderBrowser.dismissRestorationWarning() } }
                )
            ) {
                Button("重新选择文件夹") {
                    folderBrowser.dismissRestorationWarning()
                    folderBrowser.chooseFolder(
                        attachedTo: sourceEditorSession.textView.window
                            ?? NSApp.keyWindow
                            ?? NSApp.mainWindow
                    )
                }
                Button("稍后", role: .cancel) {
                    folderBrowser.dismissRestorationWarning()
                }
            } message: {
                Text(folderBrowser.restorationWarning ?? "请重新选择文件夹。")
            }
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            if let recoveryCoordinator {
                RecoveryProtectionStatusBanner(coordinator: recoveryCoordinator)
            }

            DocumentFileSafetyBanner(
                state: displayedFileSafetyState,
                deferredSnapshotID: deferredFileSafetySnapshotID,
                onCompare: {
                    requestedConflictDecision = nil
                    isFileSafetyPresented = true
                },
                onReload: requestFileSafetyReload,
                onOverwrite: { snapshot in
                    presentFileSafetyReview(snapshot, decision: .overwrite)
                },
                onRecreate: { snapshot in
                    presentFileSafetyReview(snapshot, decision: .recreate)
                },
                onDefer: { snapshot in
                    deferredFileSafetySnapshotID = snapshot.id
                },
                onResume: {
                    deferredFileSafetySnapshotID = nil
                },
                onSaveAs: { beginDocumentRelocation(.saveAs) },
                onSaveCopy: { beginDocumentRelocation(.saveCopy) },
                onClose: {
                    MixedLineEndingPrompt.closeDocumentWindow(
                        sourceEditorSession.textView.window ?? NSApp.keyWindow
                    )
                }
            )

            if let request = pendingResourceDirectoryAuthorization {
                RelativeResourceDirectoryAccessBanner(
                    directory: request.directory,
                    onAuthorize: {
                        authorizeRelativeResourceDirectory(request.directory)
                    },
                    onDefer: {
                        deferredResourceDirectoryPath = request.directory.path
                        deferredDirectoryConflictSnapshotID = request.conflictSnapshotID
                    }
                )
                Divider()
            }

            if let activeExportProgress {
                ExportProgressBanner(
                    progress: activeExportProgress,
                    onCancel: cancelExport
                )
            }

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
                    folderBrowser.chooseFolder(
                        attachedTo: sourceEditorSession.textView.window
                            ?? NSApp.keyWindow
                            ?? NSApp.mainWindow
                    )
                } label: {
                    Label(
                        folderBrowser.folderURL == nil ? "打开文件夹" : "更换文件夹",
                        systemImage: "folder"
                    )
                }
                .help(folderBrowser.folderURL == nil ? "打开文件夹" : "更换文件夹")
            }

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
            restoreRelativeResourceDirectoryAccess(for: fileURL)
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
            releaseStaleDocumentSecurityScope(for: newURL)
            deferredResourceDirectoryPath = nil
            deferredDirectoryConflictSnapshotID = nil
            restoreRelativeResourceDirectoryAccess(for: newURL)
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

    private func releaseStaleDocumentSecurityScope(for newURL: URL?) {
        guard let nativeDocument = sourceEditorSession.textView.window?
            .windowController?.document as? NSDocument,
              let authorizedURL = SecurityScopedDocumentLeaseRegistry.activeURL(
                  for: nativeDocument
              ),
              authorizedURL.standardizedFileURL != newURL?.standardizedFileURL
        else {
            return
        }
        SecurityScopedDocumentLeaseRegistry.releaseAccess(for: nativeDocument)
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
            abandonExportTracking()
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
                    initialDecision: requestedConflictDecision,
                    onSaveCopy: saveCopyFromConflictReview,
                    onReload: { try await reloadFromDisk(snapshot) },
                    onOverwrite: {
                        try await overwriteDiskVersion(snapshot)
                    },
                    onRecreate: { try await recreateDeletedFile(snapshot) },
                    onResolved: {
                        requestedConflictDecision = nil
                        isFileSafetyPresented = false
                    },
                    onClose: {
                        requestedConflictDecision = nil
                        isFileSafetyPresented = false
                    }
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
                    deferredImageInsertionQueue.cancel()
                    relocationRequest = nil
                    relocationNativeDocument = nil
                },
                onConfirm: { await confirmDocumentRelocation(request) }
            )
        }
        .confirmationDialog(
            htmlExportNotice?.title ?? "导出结果",
            isPresented: Binding(
                get: { htmlExportNotice != nil },
                set: { if !$0 { htmlExportNotice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let notice = htmlExportNotice {
                switch notice.outcome {
                case let .success(_, url, _):
                    Button(ExportResultPrompt.showInFinderTitle) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        htmlExportNotice = nil
                    }
                    Button(ExportResultPrompt.openTitle) {
                        NSWorkspace.shared.open(url)
                        htmlExportNotice = nil
                    }
                    Button(ExportResultPrompt.doneTitle, role: .cancel) {
                        htmlExportNotice = nil
                    }
                case let .targetChanged(delivery, targetURL):
                    Button(ExportFailurePrompt.reconfirmReplacementTitle) {
                        htmlExportNotice = nil
                        deliver(delivery, from: .capture(targetURL))
                    }
                    Button(ExportFailurePrompt.chooseAnotherLocationTitle) {
                        htmlExportNotice = nil
                        deliver(delivery, from: .chooseDestination)
                    }
                    Button(ExportFailurePrompt.cancelTitle, role: .cancel) {
                        htmlExportNotice = nil
                    }
                case let .tooLarge(request):
                    Button(ExportFailurePrompt.returnToAdjustTitle, role: .cancel) {
                        htmlExportNotice = nil
                    }
                    Button(ExportFailurePrompt.changeFormatTitle) {
                        htmlExportNotice = nil
                        prepareExport(request.changingFormat())
                    }
                case let .checkFailed(request, details):
                    Button(ExportFailurePrompt.viewProblemsTitle) {
                        htmlExportNotice = nil
                        Task { @MainActor in
                            await Task.yield()
                            exportIssueDetails = ExportIssueDetails(message: details)
                        }
                    }
                    Button(ExportFailurePrompt.changeFormatTitle) {
                        htmlExportNotice = nil
                        prepareExport(request.changingFormat())
                    }
                    Button(ExportFailurePrompt.closeTitle, role: .cancel) {
                        htmlExportNotice = nil
                    }
                case let .failure(context, _):
                    Button(ExportFailurePrompt.retryTitle) {
                        htmlExportNotice = nil
                        retryExport(context)
                    }
                    Button(ExportFailurePrompt.chooseAnotherLocationTitle) {
                        htmlExportNotice = nil
                        chooseAnotherExportLocation(context)
                    }
                    Button(ExportFailurePrompt.closeTitle, role: .cancel) {
                        htmlExportNotice = nil
                    }
                }
            }
        } message: {
            if let htmlExportNotice {
                Text(htmlExportNotice.message)
            }
        }
        .alert(item: $exportIssueDetails) { details in
            Alert(
                title: Text("导出检查问题"),
                message: Text(details.message),
                dismissButton: .default(Text(ExportFailurePrompt.closeTitle))
            )
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
        .alert(
            "未能保留目录访问权限",
            isPresented: Binding(
                get: { resourceDirectoryAccessErrorMessage != nil },
                set: { if !$0 { resourceDirectoryAccessErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resourceDirectoryAccessErrorMessage ?? "文档和资源未被修改。")
        }
    }

    @ViewBuilder
    private var content: some View {
        if folderBrowser.folderURL != nil {
            HSplitView {
                FolderBrowserSidebar(
                    controller: folderBrowser,
                    currentDocumentURL: fileURL,
                    onOpenDocument: { url in
                        recentDocuments?.openDocumentFromFolder(url)
                    }
                )
                .frame(minWidth: 190, idealWidth: 230, maxWidth: 340)

                documentContent
                    .frame(minWidth: 520)
            }
        } else {
            documentContent
        }
    }

    @ViewBuilder
    private var documentContent: some View {
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
        VStack(spacing: 0) {
            if previewFailureMessage != nil {
                previewFailureBanner
                Divider()
            }

            ZStack {
                MarkdownPreviewView(
                    html: previewHTML,
                    baseURL: fileURL?.deletingLastPathComponent(),
                    scrollRequest: preferences.scrollSyncEnabled && !previewScrollPausedByUser
                        ? previewScrollRequest
                        : nil,
                    onHeadingActivated: activatePreviewHeading,
                    onLinkActivated: activatePreviewLink,
                    onPreviewIssueAction: activatePreviewIssue,
                    onImageIssueAction: activatePreviewImageIssue,
                    onManualScroll: {
                        if preferences.scrollSyncEnabled {
                            previewScrollPausedByUser = true
                        }
                    }
                )

                if previewFailureMessage == nil,
                   EmptyMarkdownGuidance.isVisible(markdown: document.text)
                {
                    EmptyMarkdownPreviewView(
                        onStartWriting: {
                            selectViewMode(viewMode == .preview ? .source : viewMode)
                        },
                        onOpenFolder: {
                            folderBrowser.chooseFolder(
                                attachedTo: sourceEditorSession.textView.window
                                    ?? NSApp.keyWindow
                                    ?? NSApp.mainWindow
                            )
                        },
                        onOpenDocument: {
                            recentDocuments?.chooseDocumentToOpen()
                        }
                    )
                }
            }
        }
    }

    private var previewFailureBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(PreviewFailurePrompt.title)
                    .font(.headline)
                Text(PreviewFailurePrompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(PreviewFailurePrompt.retryTitle, action: retryPreview)
            Button(PreviewFailurePrompt.hideTitle) {
                selectViewMode(.source)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .help(previewFailureMessage ?? PreviewFailurePrompt.message)
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
                Text(MixedLineEndingPrompt.title)
                    .font(.headline)
                Text(MixedLineEndingPrompt.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(MixedLineEndingPrompt.useLFTitle) {
                document.chooseLineEnding(.lf)
            }
            Button(MixedLineEndingPrompt.useCRLFTitle) {
                document.chooseLineEnding(.crlf)
            }
            Button(MixedLineEndingPrompt.closeTitle) {
                MixedLineEndingPrompt.closeDocumentWindow(
                    sourceEditorSession.textView.window ?? NSApp.keyWindow
                )
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

    private func requestFileSafetyReload(_ snapshot: DocumentFileConflictSnapshot) {
        if snapshot.localHasChanges {
            presentFileSafetyReview(snapshot, decision: .reload)
            return
        }
        Task { @MainActor in
            do {
                try await reloadFromDisk(snapshot)
                deferredFileSafetySnapshotID = nil
            } catch {
                presentFileOperationFailure(error)
            }
        }
    }

    private func presentFileSafetyReview(
        _ snapshot: DocumentFileConflictSnapshot,
        decision: DocumentConflictDecision? = nil
    ) {
        guard fileSafetySession.state.conflictSnapshot?.id == snapshot.id else {
            presentFileOperationFailure(DocumentFileSafetyError.staleDecision)
            return
        }
        requestedConflictDecision = decision
        isFileSafetyPresented = true
    }

    private func overwriteDiskVersion(_ snapshot: DocumentFileConflictSnapshot) async throws
        -> URL
    {
        guard try await requestDocumentDirectoryAccessIfNeeded(for: snapshot) else {
            throw DocumentDirectoryAccessDecisionError.declined
        }
        let conflictURL = try await fileSafetySession.overwrite(snapshot)
        fileSafetyNotice = .conflictCopySaved(conflictURL)
        return conflictURL
    }

    private func recreateDeletedFile(_ snapshot: DocumentFileConflictSnapshot) async throws {
        guard try await requestDocumentDirectoryAccessIfNeeded(for: snapshot) else {
            throw DocumentDirectoryAccessDecisionError.declined
        }
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

    @discardableResult
    private func beginDocumentRelocation(_ operation: DocumentRelocationOperation) -> Bool {
        guard !isRelocatingDocument, relocationRequest == nil else { return false }
        guard let nativeDocument = NativeDocumentSaveCoordinator.activeDocument(
            sourceURL: fileURL
        ) else {
            presentFileOperationFailure(DocumentRelocationError.cannotInspect)
            return false
        }
        let snapshotData: Data
        do {
            snapshotData = try document.encodedFileData()
        } catch {
            presentFileOperationFailure(error, fallback: "当前正文无法编码，未写入任何文件。")
            return false
        }

        let panel = NSSavePanel()
        let isSavingBeforeImage = operation == .saveAs
            && fileURL == nil
            && deferredImageInsertionQueue.hasPending
        panel.title = isSavingBeforeImage
            ? DeferredImageInsertion.savePanelTitle
            : operation.panelTitle
        panel.message = isSavingBeforeImage
            ? DeferredImageInsertion.savePanelMessage
            : ""
        panel.prompt = isSavingBeforeImage
            ? DeferredImageInsertion.savePanelActionTitle
            : operation.actionTitle
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
                if isSavingBeforeImage { deferredImageInsertionQueue.cancel() }
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
                if isSavingBeforeImage { deferredImageInsertionQueue.cancel() }
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
                if isSavingBeforeImage { deferredImageInsertionQueue.cancel() }
            }
        }
        return true
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

            let deferredInsertion = request.operation == .saveAs
                ? deferredImageInsertionQueue.consumeAfterSuccessfulSave()
                : nil
            relocationRequest = nil
            relocationNativeDocument = nil
            switch request.operation {
            case .saveAs:
                if deferredInsertion == nil {
                    fileSafetyNotice = .savedAs(request.plan.targetURL)
                }
            case .saveCopy:
                fileSafetyNotice = .copySaved(request.plan.targetURL)
            }
            if let deferredInsertion {
                Task { @MainActor in
                    await Task.yield()
                    resumeDeferredImageInsertion(
                        deferredInsertion,
                        savedDocumentURL: request.plan.targetURL
                    )
                }
            }
        } catch {
            deferredImageInsertionQueue.cancel()
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
        requestedConflictDecision = nil
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

    private func activatePreviewIssue(
        action: PreviewIssueAction,
        sourceUTF8Offset: Int
    ) {
        guard let validatedOffset = PreviewIssueNavigation.validatedOffset(
            sourceUTF8Offset,
            renderedSource: previewSourceSnapshot,
            currentSource: document.text
        ) else {
            retryPreview()
            return
        }

        switch action {
        case .locate:
            viewMode = viewMode.sourceVisible
            sourceSelectionGeneration &+= 1
            sourceSelectionRequest = SourceSelectionRequest(
                generation: sourceSelectionGeneration,
                utf8Range: validatedOffset..<validatedOffset
            )
        case .retry:
            retryPreview()
        }
    }

    private func activatePreviewImageIssue(
        action: PreviewImageIssueAction,
        sourceUTF8Offset: Int,
        target: String
    ) {
        guard let reference = PreviewImageIssueNavigation.validatedReference(
            sourceUTF8Offset: sourceUTF8Offset,
            target: target,
            renderedSource: previewSourceSnapshot,
            currentSource: document.text
        ) else {
            retryPreview()
            return
        }

        switch action {
        case .locate:
            viewMode = viewMode.sourceVisible
            sourceSelectionGeneration &+= 1
            sourceSelectionRequest = SourceSelectionRequest(
                generation: sourceSelectionGeneration,
                utf8Range: reference.sourceUTF8Range,
                style: .match
            )
        case .copyTarget:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(reference.target, forType: .string)
        case .ignore:
            break
        case .replace:
            guard canEditDocument,
                  let selection = MarkdownSourceRange.navigationTarget(
                      forUTF8Range: reference.sourceUTF8Range,
                      in: document.text
                  )
            else {
                markdownFormatErrorMessage = canEditDocument
                    ? "图片引用已变化，请重试。"
                    : "文档为只读，无法替换图片引用。"
                return
            }
            viewMode = viewMode.sourceVisible
            sourceEditorSession.textView.setSelectedRange(selection.revealRange)
            sourceEditorSession.textView.scrollRangeToVisible(selection.revealRange)
            insertImage()
        }
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
        guard fileURL != nil else {
            deferImageInsertionUntilFirstSave(.chooseExistingImage)
            return
        }
        importExistingImage(from: nil)
    }

    private func restoreRelativeResourceDirectoryAccess(for documentURL: URL?) {
        guard let directory = documentURL?.deletingLastPathComponent() else { return }
        _ = imageDirectoryAccess.restoreAuthorization(for: directory)
    }

    private func authorizeRelativeResourceDirectory(_ directory: URL) {
        let window = sourceEditorSession.textView.window ?? NSApp.keyWindow
        Task { @MainActor in
            do {
                _ = try await requestDocumentDirectoryAccess(
                    directory,
                    attachedTo: window
                )
            } catch {
                resourceDirectoryAccessErrorMessage =
                    "请选择当前 Markdown 文档所在的精确目录。文档和资源未被修改。"
            }
        }
    }

    private func requestDocumentDirectoryAccessIfNeeded(
        for snapshot: DocumentFileConflictSnapshot
    ) async throws -> Bool {
        let directory = snapshot.url.deletingLastPathComponent().standardizedFileURL
        guard !imageDirectoryAccess.isAuthorized(directory) else { return true }
        let keyWindow = NSApp.keyWindow
        let attachmentWindow: NSWindow? = if keyWindow?.sheetParent == nil,
                                             keyWindow?.attachedSheet == nil
        {
            keyWindow
        } else {
            nil
        }
        return try await requestDocumentDirectoryAccess(
            directory,
            attachedTo: attachmentWindow
        )
    }

    private func requestDocumentDirectoryAccess(
        _ directory: URL,
        attachedTo window: NSWindow?
    ) async throws -> Bool {
        guard let authorized = try await ImageAssetPicker.authorizeRelativeResources(
            in: directory,
            attachedTo: window
        ) else {
            return false
        }
        try imageDirectoryAccess.authorizePersistently(authorized)
        deferredResourceDirectoryPath = nil
        deferredDirectoryConflictSnapshotID = nil
        retryPreview()
        return true
    }

    private func dropImage(_ sourceURL: URL) {
        guard fileURL != nil else {
            deferImageInsertionUntilFirstSave(.drop(sourceURL))
            return
        }
        importExistingImage(from: sourceURL)
    }

    private func deferImageInsertionUntilFirstSave(_ insertion: DeferredImageInsertion) {
        guard canEditDocument,
              !isImportingImage,
              !deferredImageInsertionQueue.hasPending,
              !isRelocatingDocument,
              relocationRequest == nil
        else {
            return
        }
        guard deferredImageInsertionQueue.enqueue(insertion) else { return }
        if !beginDocumentRelocation(.saveAs) {
            deferredImageInsertionQueue.cancel()
        }
    }

    private func resumeDeferredImageInsertion(
        _ insertion: DeferredImageInsertion,
        savedDocumentURL: URL
    ) {
        switch insertion {
        case .chooseExistingImage:
            importExistingImage(from: nil, documentURLOverride: savedDocumentURL)
        case let .paste(payload):
            pasteImage(payload, documentURLOverride: savedDocumentURL)
        case let .drop(sourceURL):
            importExistingImage(from: sourceURL, documentURLOverride: savedDocumentURL)
        }
    }

    private func importExistingImage(
        from providedSourceURL: URL?,
        documentURLOverride: URL? = nil
    ) {
        guard canEditDocument, !isImportingImage else { return }
        guard let documentURL = documentURLOverride ?? fileURL else {
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

                guard let directoryPlan = try await imageAssetDirectoryPlan(
                    for: placement,
                    documentDirectory: documentDirectory,
                    attachedTo: window
                ) else {
                    return
                }

                let filename = sourceURL.lastPathComponent
                let destinationSnapshot = try await worker.destinationSnapshot(
                    directoryPlan: directoryPlan,
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
                    directoryPlan: directoryPlan,
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

    @MainActor
    private func imageAssetDirectoryPlan(
        for placement: ExistingImagePlacement,
        documentDirectory: URL,
        attachedTo window: NSWindow?
    ) async throws -> ImageAssetDirectoryPlan? {
        switch placement {
        case .copyToAssets:
            guard let authorizedDirectory = try await ImageAssetPicker.authorizeDocumentDirectory(
                documentDirectory,
                attachedTo: window
            ) else {
                return nil
            }
            try imageDirectoryAccess.authorizePersistently(authorizedDirectory)
            return .assets(in: authorizedDirectory)
        case .copyToRelativeDirectory:
            guard let plan = try await ImageAssetPicker.chooseRelativeAssetDirectory(
                relativeTo: documentDirectory,
                attachedTo: window
            ) else {
                return nil
            }
            imageDirectoryAccess.authorize(plan.directoryURL)
            return plan
        case .keepOriginal:
            return nil
        }
    }

    private func pasteImage(_ payload: ClipboardImagePayload) {
        pasteImage(payload, documentURLOverride: nil)
    }

    private func pasteImage(
        _ payload: ClipboardImagePayload,
        documentURLOverride: URL?
    ) {
        guard canEditDocument, !isImportingImage else { return }
        guard let documentURL = documentURLOverride ?? fileURL else {
            deferImageInsertionUntilFirstSave(.paste(payload))
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
                let copyPlacement: ExistingImagePlacement =
                    preferences.existingImagePlacement == .copyToRelativeDirectory
                    ? .copyToRelativeDirectory
                    : .copyToAssets
                guard let directoryPlan = try await imageAssetDirectoryPlan(
                    for: copyPlacement,
                    documentDirectory: documentDirectory,
                    attachedTo: window
                ) else {
                    return
                }
                let asset = try await worker.importClipboardImage(
                    image,
                    directoryPlan: directoryPlan
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

    private func beginExport(
        format: ExportFormat,
        documentVersion: String,
        isCancellable: Bool
    ) -> Int {
        exportTask?.cancel()
        exportGeneration &+= 1
        isExportingHTML = format == .html
        isExportingPDF = format == .pdf
        activeExportProgress = ActiveExportProgress(
            format: format,
            documentVersion: documentVersion,
            isCancellable: isCancellable
        )
        return exportGeneration
    }

    private func exportIsCurrent(_ generation: Int) -> Bool {
        generation == exportGeneration && !Task.isCancelled
    }

    private func finishExport(_ generation: Int) {
        guard generation == exportGeneration else { return }
        exportTask = nil
        activeExportProgress = nil
        isExportingHTML = false
        isExportingPDF = false
    }

    private func cancelExport() {
        guard activeExportProgress?.isCancellable == true else { return }
        abandonExportTracking()
    }

    private func abandonExportTracking() {
        exportGeneration &+= 1
        exportTask?.cancel()
        exportTask = nil
        activeExportProgress = nil
        isExportingHTML = false
        isExportingPDF = false
    }

    private func startHTMLExport() {
        guard !isExportingHTML, !isExportingPDF else { return }
        anonymousUsage?.record(feature: .export, command: .exportHTML)
        prepareExport(makeFrozenExportRequest(format: .html))
    }

    private func startPDFExport() {
        guard !isExportingHTML, !isExportingPDF else { return }
        anonymousUsage?.record(feature: .export, command: .exportPDF)
        prepareExport(makeFrozenExportRequest(format: .pdf))
    }

    private func makeFrozenExportRequest(format: ExportFormat) -> FrozenExportRequest {
        let snapshot = HTMLExportSnapshot(
            markdown: document.text,
            documentDirectory: fileURL?.deletingLastPathComponent(),
            appearance: preferences.previewConfiguration
        )
        let basename = fileURL?.deletingPathExtension().lastPathComponent ?? "未命名文档"
        return FrozenExportRequest(
            format: format,
            snapshot: snapshot,
            suggestedFilename: "\(basename).\(format.filenameExtension)"
        )
    }

    private func prepareExport(_ request: FrozenExportRequest) {
        guard !isExportingHTML, !isExportingPDF else { return }
        let worker = htmlExportWorker
        let generation = beginExport(
            format: request.format,
            documentVersion: request.snapshot.documentVersion,
            isCancellable: true
        )

        exportTask = Task { @MainActor in
            let preparation: HTMLExportPreparation
            switch await worker.prepare(request.snapshot) {
            case let .success(value):
                preparation = value
            case let .failure(error):
                guard exportIsCurrent(generation) else { return }
                finishExport(generation)
                presentPreparationFailure(error, request: request)
                return
            }
            guard exportIsCurrent(generation) else { return }

            guard preparation.warnings.isEmpty else {
                finishExport(generation)
                pendingExportConfirmation = PendingExportConfirmation(
                    request: request,
                    preparation: preparation
                )
                return
            }
            finishExport(generation)
            continuePreparedExport(
                PendingExportConfirmation(request: request, preparation: preparation)
            )
        }
    }

    private func continuePreparedExport(_ pending: PendingExportConfirmation) {
        switch pending.request.format {
        case .html:
            deliver(
                PreparedExportDelivery(
                    request: pending.request,
                    data: pending.preparation.data
                ),
                from: .chooseDestination
            )
        case .pdf:
            generatePDFDelivery(pending)
        }
    }

    private func generatePDFDelivery(_ pending: PendingExportConfirmation) {
        guard !isExportingHTML, !isExportingPDF else { return }
        let generation = beginExport(
            format: .pdf,
            documentVersion: pending.request.snapshot.documentVersion,
            isCancellable: true
        )
        exportTask = Task { @MainActor in
            let pdf: Data
            do {
                pdf = try await PDFExporter.generate(
                    fromSelfContainedHTML: pending.preparation.data
                )
            } catch {
                guard exportIsCurrent(generation) else { return }
                finishExport(generation)
                presentPDFFailure(error, request: pending.request)
                return
            }
            guard exportIsCurrent(generation) else { return }
            finishExport(generation)
            deliver(
                PreparedExportDelivery(request: pending.request, data: pdf),
                from: .chooseDestination
            )
        }
    }

    private func deliver(
        _ delivery: PreparedExportDelivery,
        from step: ExportDeliveryStep
    ) {
        guard !isExportingHTML, !isExportingPDF else { return }
        let worker = htmlExportWorker
        let generation = beginExport(
            format: delivery.request.format,
            documentVersion: delivery.request.snapshot.documentVersion,
            isCancellable: true
        )
        exportTask = Task { @MainActor in
            let targetURL: URL
            switch step {
            case .chooseDestination:
                guard let selectedURL = await chooseExportDestination(for: delivery.request),
                      exportIsCurrent(generation)
                else {
                    finishExport(generation)
                    return
                }
                targetURL = selectedURL
            case let .capture(url), let .write(url, _):
                targetURL = url
            }

            let accessed = targetURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { targetURL.stopAccessingSecurityScopedResource() }
            }

            let targetSnapshot: HTMLExportTargetSnapshot
            switch step {
            case let .write(_, expectedTarget):
                targetSnapshot = expectedTarget
            case .chooseDestination, .capture:
                switch await worker.captureTarget(targetURL) {
                case let .success(snapshot):
                    targetSnapshot = snapshot
                case let .failure(error):
                    guard exportIsCurrent(generation) else { return }
                    finishExport(generation)
                    presentTargetFailure(
                        error,
                        context: .capture(delivery, targetURL)
                    )
                    return
                }
            }
            guard exportIsCurrent(generation) else { return }
            activeExportProgress = ActiveExportProgress(
                format: delivery.request.format,
                documentVersion: delivery.request.snapshot.documentVersion,
                isCancellable: false
            )

            let result = await worker.write(
                delivery.data,
                to: targetURL,
                expectedTarget: targetSnapshot
            )
            guard exportIsCurrent(generation) else { return }
            finishExport(generation)
            switch result {
            case .success:
                htmlExportNotice = .success(
                    format: delivery.request.format,
                    url: targetURL,
                    documentVersion: delivery.request.snapshot.documentVersion
                )
            case let .failure(error):
                presentTargetFailure(
                    error,
                    context: .write(delivery, targetURL, targetSnapshot)
                )
            }
        }
    }

    @MainActor
    private func chooseExportDestination(for request: FrozenExportRequest) async -> URL? {
        switch request.format {
        case .html:
            await HTMLExportPanel.chooseDestination(
                suggestedFilename: request.suggestedFilename
            )
        case .pdf:
            await PDFExportPanel.chooseDestination(
                suggestedFilename: request.suggestedFilename
            )
        }
    }

    private func presentPreparationFailure(
        _ error: HTMLExportError,
        request: FrozenExportRequest
    ) {
        switch error {
        case .outputTooLarge:
            htmlExportNotice = HTMLExportNotice(outcome: .tooLarge(request))
        case let .unsupportedContent(issues):
            let details = issues.map { "• \($0.description)" }.joined(separator: "\n")
            htmlExportNotice = HTMLExportNotice(
                outcome: .checkFailed(request: request, details: details)
            )
        case .invalidUTF8, .unavailableResource:
            htmlExportNotice = HTMLExportNotice(
                outcome: .checkFailed(
                    request: request,
                    details: error.localizedDescription
                )
            )
        case .coreFailure:
            htmlExportNotice = HTMLExportNotice(
                outcome: .failure(
                    context: .prepare(request),
                    reason: error.localizedDescription
                )
            )
        }
    }

    private func presentPDFFailure(_ error: Error, request: FrozenExportRequest) {
        if error as? PDFExportError == .invalidOutput {
            htmlExportNotice = HTMLExportNotice(
                outcome: .checkFailed(
                    request: request,
                    details: PDFExportError.invalidOutput.localizedDescription
                )
            )
            return
        }
        let reason = (error as? LocalizedError)?.errorDescription
            ?? PDFExportError.renderingFailed.localizedDescription
        htmlExportNotice = HTMLExportNotice(
            outcome: .failure(context: .prepare(request), reason: reason)
        )
    }

    private func presentTargetFailure(
        _ error: HTMLExportTargetError,
        context: ExportRecoveryContext
    ) {
        if error == .targetChanged, let delivery = context.delivery {
            let targetURL: URL = switch context {
            case let .capture(_, url), let .write(_, url, _): url
            case .prepare: preconditionFailure("A target change requires a delivery target")
            }
            htmlExportNotice = HTMLExportNotice(
                outcome: .targetChanged(delivery: delivery, targetURL: targetURL)
            )
        } else {
            htmlExportNotice = HTMLExportNotice(
                outcome: .failure(context: context, reason: error.localizedDescription)
            )
        }
    }

    private func retryExport(_ context: ExportRecoveryContext) {
        switch context {
        case let .prepare(request):
            prepareExport(request)
        case let .capture(delivery, targetURL):
            deliver(delivery, from: .capture(targetURL))
        case let .write(delivery, targetURL, expectedTarget):
            deliver(delivery, from: .write(targetURL, expectedTarget))
        }
    }

    private func chooseAnotherExportLocation(_ context: ExportRecoveryContext) {
        if let delivery = context.delivery {
            deliver(delivery, from: .chooseDestination)
        } else {
            prepareExport(context.request)
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
            previewSourceSnapshot = content.sourceSnapshot
            previewFailureMessage = content.previewFailureMessage
            relativeResourceSourceSnapshot = content.sourceSnapshot
            hasRelativeResources = content.hasRelativeResources
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

    private func retryPreview() {
        scheduleDerivedContent(
            for: document.text,
            documentDirectory: fileURL?.deletingLastPathComponent(),
            configuration: preferences.previewConfiguration,
            headingNavigationEnabled: preferences.headingNavigationEnabled,
            syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
            delayNanoseconds: 0
        )
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
    let sourceSnapshot: String
    let html: String
    let previewFailureMessage: String?
    let hasRelativeResources: Bool
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
        let previewDocument = MarkdownRenderer.previewDocument(
            for: markdown,
            documentDirectory: documentDirectory,
            configuration: configuration,
            navigationHeadings: headings
        )
        guard !Task.isCancelled else { return nil }
        return DerivedDocumentContent(
            sourceSnapshot: markdown,
            html: previewDocument.html,
            previewFailureMessage: previewDocument.failureMessage,
            hasRelativeResources: previewDocument.hasRelativeResources,
            analysis: analysis,
            syntaxHighlighting: syntaxHighlighting
        )
    }
}

enum PreviewIssueNavigation {
    static func validatedOffset(
        _ offset: Int,
        renderedSource: String,
        currentSource: String
    ) -> Int? {
        guard UTF8Text.isExactlyEqual(renderedSource, currentSource),
              MarkdownSourceRange.navigationTarget(
                  forUTF8Range: offset..<offset,
                  in: currentSource
              ) != nil
        else {
            return nil
        }
        return offset
    }
}

enum PreviewImageIssueNavigation {
    static func validatedReference(
        sourceUTF8Offset: Int,
        target: String,
        renderedSource: String,
        currentSource: String
    ) -> MarkdownReference? {
        guard UTF8Text.isExactlyEqual(renderedSource, currentSource),
              let references = try? MarkdownReferenceScanner.references(in: currentSource)
        else {
            return nil
        }
        return references.first { reference in
            reference.kind == .image
                && reference.sourceUTF8Range.lowerBound == sourceUTF8Offset
                && UTF8Text.isExactlyEqual(reference.target, target)
        }
    }
}
