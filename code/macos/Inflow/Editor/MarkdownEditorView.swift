import AppKit
import CoreGraphics
import SwiftUI

struct MarkdownEditorView: View {
    @Environment(\.newDocument) private var newDocument
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    let isEditable: Bool
    var recoveryCoordinator: DocumentRecoveryCoordinator? = nil
    @ObservedObject private var preferences: AppPreferences
    private let recentDocuments: RecentDocumentsController?
    @ObservedObject private var folderBrowser: FolderBrowserController
    private let projectCoordinator: LightweightProjectCoordinator?
    private let nativeDocumentOverride: NSDocument?
    private let workspaceWindowDocument: NSDocument?
    private let showsProjectSidebar: Bool
    private let tearsDownWhenRemovedFromWorkspace: Bool
    private let isWorkspaceSurfaceActive: Bool

    init(
        document: Binding<MarkdownDocument>,
        fileURL: URL?,
        isEditable: Bool,
        recoveryCoordinator: DocumentRecoveryCoordinator? = nil,
        preferences: AppPreferences? = nil,
        recentDocuments: RecentDocumentsController? = nil,
        folderBrowser: FolderBrowserController,
        projectCoordinator: LightweightProjectCoordinator? = nil,
        nativeDocumentOverride: NSDocument? = nil,
        workspaceWindowDocument: NSDocument? = nil,
        showsProjectSidebar: Bool = true,
        tearsDownWhenRemovedFromWorkspace: Bool = false,
        sourceEditorSessionOverride: MarkdownSourceEditorSession? = nil,
        isWorkspaceSurfaceActive: Bool = true
    ) {
        _document = document
        self.fileURL = fileURL
        self.isEditable = isEditable
        self.recoveryCoordinator = recoveryCoordinator
        _preferences = ObservedObject(wrappedValue: preferences ?? AppPreferences())
        self.recentDocuments = recentDocuments
        _folderBrowser = ObservedObject(wrappedValue: folderBrowser)
        self.projectCoordinator = projectCoordinator
        self.nativeDocumentOverride = nativeDocumentOverride
        self.workspaceWindowDocument = workspaceWindowDocument
        self.showsProjectSidebar = showsProjectSidebar
        self.tearsDownWhenRemovedFromWorkspace = tearsDownWhenRemovedFromWorkspace
        self.isWorkspaceSurfaceActive = isWorkspaceSurfaceActive
        let sourceEditorSession = sourceEditorSessionOverride ?? MarkdownSourceEditorSession()
        let renderedPreviewSession = MarkdownSourceEditorSession(role: .renderedProjection)
        _sourceEditorSession = StateObject(wrappedValue: sourceEditorSession)
        _renderedPreviewSession = StateObject(wrappedValue: renderedPreviewSession)
        _editorStore = StateObject(
            wrappedValue: EditorStore(
                sourceEditorSession: sourceEditorSession,
                renderedPreviewSession: renderedPreviewSession
            )
        )
        let initialDocument = document.wrappedValue
        _recoveryRecordID = State(
            initialValue: initialDocument.recoveryTransfer?.targetRecordID ?? UUID()
        )
        _incomingHeadingFragment = State(
            initialValue: initialDocument.initialHeadingFragment
        )
        _incomingNavigationIsPending = State(
            initialValue: initialDocument.initialHeadingFragment != nil
        )
    }

    @SceneStorage("editorStatisticMode") private var storedStatisticMode =
        EditorStatisticMode.words.rawValue
    // Writing modes belong to each window; read-only documents suppress them.
    @SceneStorage("isFocusModeEnabled") private var restoredFocusModeEnabled = false
    @SceneStorage("isTypewriterModeEnabled") private var restoredTypewriterModeEnabled = false
    private var isFocusModeEnabled: Bool { canEditDocument && restoredFocusModeEnabled }
    private var isTypewriterModeEnabled: Bool { canEditDocument && restoredTypewriterModeEnabled }
    @StateObject private var editorStore: EditorStore
    @State private var previewLinkGeneration = 0
    @State private var previewLinkTask: Task<Void, Never>?
    @State private var previewLinkWorker = PreviewLinkWorker()
    @State private var previewLinkPlan: PreviewLinkPlan?
    @State private var incomingHeadingFragment: String?
    @State private var incomingNavigationIsPending = false
    @StateObject private var sourceEditorSession: MarkdownSourceEditorSession
    @StateObject private var renderedPreviewSession: MarkdownSourceEditorSession
    @StateObject private var nativeDocumentHost = MarkdownEditorNativeDocumentHost()
    @State private var selectedHeadingID: DocumentHeading.ID?
    @State private var sourceSelectionRequest: SourceSelectionRequest?
    @State private var sourceSelectionGeneration = 0
    @State private var outlineFocusGeneration = 0
    @StateObject private var findSession = DocumentFindSession()
    @State private var replaceAllPlan: ReplaceAllPlan?
    @State private var findSearchGeneration = 0
    @State private var findSearchTask: Task<Void, Never>?
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
    @State private var tableInsertionRequest: MarkdownTableInsertionRequest?
    @State private var isImportingImage = false
    @State private var deferredImageInsertionQueue = DeferredImageInsertionQueue()
    @State private var imageAssetWorker = ImageAssetWorker()
    @StateObject private var imageDirectoryAccess = ImageAssetDirectoryAccess()
    @State private var recoveryRecordID = UUID()
    @State private var isRecoveryCenterPresented = false
    @State private var didApplyRestorationState = false
    @State private var didPrepareFreshUntitledDocument = false
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

    private var previewSourceSnapshot: String { editorStore.state.previewSourceSnapshot }
    private var previewFailureMessage: String? { editorStore.state.previewFailureMessage }
    private var analysisState: DocumentAnalysisState { editorStore.state.analysisState }
    private var derivedReferences: [MarkdownReference] { editorStore.state.references }
    private var renderedSurfaceCanDisplay: Bool {
        editorStore.state.renderedSurfacePhase.canDisplay(
            documentText: document.text
        )
    }

    private var viewMode: EditorViewMode {
        get {
            if usesSourceOnlyExperience {
                return .source
            }
            return preferences.workspaceViewMode.resolve(context: initialViewModeContext)
        }
        nonmutating set {
            guard !usesSourceOnlyExperience || newValue == .source else { return }
            preferences.workspaceViewMode = WorkspaceViewModePreference(mode: newValue)
        }
    }

    private var initialViewModeContext: EditorViewModeLaunchContext {
        EditorViewModeLaunchContext.resolve(
            fileURL: fileURL,
            hasRestorationState: document.restorationState != nil
        )
    }

    private var editorSplitFractionBinding: Binding<Double> {
        Binding(
            get: { preferences.workspaceSplitFraction },
            set: { preferences.workspaceSplitFraction = EditorSplitLayout.normalized($0) }
        )
    }

    private var isOutlineVisible: Bool {
        get { preferences.workspaceOutlineVisible }
        nonmutating set {
            preferences.workspaceOutlineVisible = newValue
        }
    }

    private var isProjectSidebarVisible: Bool {
        get { preferences.workspaceProjectSidebarVisible }
        nonmutating set {
            preferences.workspaceProjectSidebarVisible = newValue
        }
    }

    private var outlineVisibilityBinding: Binding<Bool> {
        Binding(
            get: { isOutlineVisible },
            set: { isOutlineVisible = $0 }
        )
    }

    private var projectSidebarVisibilityBinding: Binding<Bool> {
        Binding(
            get: { isProjectSidebarVisible },
            set: { isProjectSidebarVisible = $0 }
        )
    }

    private var usesSourceOnlyExperience: Bool {
        document.capabilityTier == .sourceOnly
    }

    private var statisticMode: EditorStatisticMode {
        get { EditorStatisticMode(rawValue: storedStatisticMode) ?? .words }
        nonmutating set { storedStatisticMode = newValue.rawValue }
    }

    @ObservedObject private var processOwnership = DocumentProcessOwnership.shared
    @State private var isRefreshingPeerFile = false
    @State private var peerRefreshGeneration: UInt64 = 0

    private var canEditDocument: Bool {
        isEditable
            && processOwnership.isOwner
            && !isRefreshingPeerFile
            && !isProjectShell
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
            .background {
                if nativeDocumentOverride == nil {
                    MarkdownEditorNativeDocumentResolver { document in
                        nativeDocumentHost.attach(document)
                        updateRecoveryProtection()
                        projectCoordinator?.activateProjectDocument(document)
                    }
                }
            }
            .alert(
                "上次项目需要重新选择",
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
        editorFocusedSurface
            .focusedSceneValue(
                \.markdownFormatActions,
                isWorkspaceSurfaceActive ? markdownFormatCommandActions : nil
            )
            .focusedSceneValue(
                \.markdownInsertActions,
                isWorkspaceSurfaceActive ? markdownInsertCommandActions : nil
            )
            .focusedSceneValue(
                \.recoveryActions,
                isWorkspaceSurfaceActive ? recoveryCommandActions : nil
            )
            .focusedSceneValue(
                \.documentSaveActions,
                isWorkspaceSurfaceActive ? documentSaveCommandActions : nil
            )
        .onChange(of: canEditDocument) { _, editable in
            if editable { prepareFreshUntitledDocumentForEditingIfNeeded() }
        }
    }

    private var editorFocusedSurface: some View {
        editorSurfaceLayout
            .focusedValue(
                \.outlineVisibility,
                !isWorkspaceSurfaceActive || isProjectShell || usesSourceOnlyExperience
                    ? nil
                    : outlineVisibilityBinding
            )
            .focusedValue(
                \.projectSidebarVisibility,
                isWorkspaceSurfaceActive && hasProjectContext
                    ? projectSidebarVisibilityBinding
                    : nil
            )
            .focusedSceneValue(
                \.editorViewModeActions,
                isWorkspaceSurfaceActive ? editorViewModeCommandActions : nil
            )
            .focusedSceneValue(
                \.previewZoomActions,
                isWorkspaceSurfaceActive ? previewZoomCommandActions : nil
            )
            .focusedSceneValue(
                \.writingModeActions,
                isWorkspaceSurfaceActive ? writingModeCommandActions : nil
            )
            .focusedSceneValue(
                \.documentFindActions,
                isWorkspaceSurfaceActive ? findCommandActions : nil
            )
            .focusedSceneValue(
                \.htmlExportActions,
                isWorkspaceSurfaceActive ? htmlExportCommandActions : nil
            )
    }

    private var editorSurfaceLayout: some View {
        VStack(spacing: 0) {
            if let recoveryCoordinator {
                RecoveryProtectionStatusBanner(coordinator: recoveryCoordinator)
            }

            DocumentFileSafetyBanner(
                state: displayedFileSafetyState,
                deferredSnapshotID: deferredFileSafetySnapshotID,
                onReload: requestFileSafetyReload,
                onDefer: { snapshot in
                    deferredFileSafetySnapshotID = snapshot.id
                },
                onResume: {
                    deferredFileSafetySnapshotID = nil
                },
                onSaveAs: { beginDocumentRelocation(.saveAs) },
                onClose: {
                    MixedLineEndingPrompt.closeDocumentWindow(
                        sourceEditorSession.textView.window ?? NSApp.keyWindow
                    )
                }
            )

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

            if usesSourceOnlyExperience {
                SourceOnlyDocumentBanner()
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

            GeometryReader { geometry in
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .layoutPriority(1)

            Divider()
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var documentObservationLayer: some View {
        editorSurface
        .onAppear {
            SafePreviewOpenStore.startMaintenance()
            // SwiftUI creates its document controller while the app is launching.
            // Apply the host policy only after this document scene is attached.
            preferences.applyAutosavePolicy()
            registerSelectedProjectDirectory(folderBrowser.folderURL)
            restoreRelativeResourceDirectoryAccess(for: fileURL)
            if let fileURL {
                recentDocuments?.note(fileURL)
            }
            applyRestorationStateIfNeeded()
            prepareFreshUntitledDocumentForEditingIfNeeded()
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                projectRoot: activeProjectRoot,
                configuration: preferences.previewConfiguration,
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
            consumePendingLinkedHeadingNavigation()
            if canEditDocument {
                sourceEditorSession.setWritingModes(
                    focusModeEnabled: isFocusModeEnabled,
                    typewriterModeEnabled: isTypewriterModeEnabled
                )
            } else {
                sourceEditorSession.setWritingModes(
                    focusModeEnabled: false,
                    typewriterModeEnabled: false
                )
            }
            synchronizeEngineMode()
            if let recoveryCoordinator {
                Task {
                    await Task.yield()
                    await recoveryCoordinator.beginStartupRestoration(anchor: sourceEditorSession.textView.window) { placeholder in
                        if let pending = placeholder.recoveryPlaceholder {
                            DocumentWindowTabs.shared.addPending(pending, dismiss: { recoveryCoordinator.dismissStartupDraft(pending.id) }) { newDocument(placeholder) }
                        }
                    }
                }
            }
            if isWorkspaceSurfaceActive {
                focusProjectEditorAfterNavigation(in: sourceEditorSession.textView.window)
            }
        }
        .onChange(of: Data(document.text.utf8)) { _, _ in
            let markdown = document.text
            selectedHeadingID = nil
            sourceSelectionRequest = nil
            scheduleDerivedContent(
                for: markdown,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                projectRoot: activeProjectRoot,
                configuration: preferences.previewConfiguration,
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
            restoreRelativeResourceDirectoryAccess(for: newURL)
            if let newURL {
                recentDocuments?.note(newURL)
            }
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: newURL?.deletingLastPathComponent(),
                projectRoot: projectRoot(for: newURL),
                configuration: preferences.previewConfiguration,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
                delayNanoseconds: 0
            )
            updateRecoveryProtection()
            fileSafetySession.update(document: document, fileURL: newURL)
        }
        .onChange(of: folderBrowser.folderURL) { _, newURL in
            registerSelectedProjectDirectory(newURL)
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                projectRoot: projectRoot(for: fileURL),
                configuration: preferences.previewConfiguration,
                syntaxHighlightingEnabled: preferences.syntaxHighlightingEnabled,
                delayNanoseconds: 0
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            notification in
            guard isWorkspaceSurfaceActive,
                  let window = notification.object as? NSWindow,
                  let windowDocument = window.windowController?.document as? NSDocument,
                  windowDocument === (workspaceWindowDocument ?? nativeDocument)
            else { return }
            projectCoordinator?.activateProjectDocument(nativeDocument)
            focusProjectEditorAfterNavigation(in: window)
        }
        .onChange(of: document.properties) { _, _ in
            updateRecoveryProtection()
            fileSafetySession.update(document: document, fileURL: fileURL)
        }
        .onChange(of: fileSafetySession.automaticSaveCommit) { _, envelope in
            guard let envelope else { return }
            if let nativeDocument = NativeDocumentSaveCoordinator.activeDocument(
                sourceURL: envelope.targetURL
            ) {
                NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
                    nativeDocument,
                    targetURL: envelope.targetURL,
                    expectedData: envelope.bytes
                )
            }
            document.adoptRecoveryCommittedSave(envelope)
            updateRecoveryProtection(originalURL: envelope.targetURL)
            Task { @MainActor in
                await recoveryCoordinator?.flush(recoveryRecordID)
            }
        }
        .onChange(of: preferences.workspaceViewMode) { _, _ in
            updateRecoveryProtection()
        }
        .onChange(of: editorStore.state.analysisState) { _, state in
            if case .ready = state {
                applyPendingDocumentNavigationIfPossible()
            }
        }
        .onChange(of: preferences.previewConfiguration) { _, configuration in
            scheduleDerivedContent(
                for: document.text,
                documentDirectory: fileURL?.deletingLastPathComponent(),
                projectRoot: activeProjectRoot,
                configuration: configuration,
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
                projectRoot: activeProjectRoot,
                configuration: preferences.previewConfiguration,
                syntaxHighlightingEnabled: isEnabled,
                delayNanoseconds: 0
            )
        }
        .onChange(of: preferences.scrollSyncEnabled) { _, isEnabled in
            if isEnabled {
                requestPreviewScroll()
            }
        }
        .onChange(of: restoredFocusModeEnabled) { _, _ in
            applyWritingModes()
        }
        .onChange(of: restoredTypewriterModeEnabled) { _, _ in
            applyWritingModes()
        }
        .onChange(of: canEditDocument) { _, _ in
            applyWritingModes()
            synchronizeEngineMode()
        }
        .onChange(of: isWorkspaceSurfaceActive) { _, isActive in
            guard isActive else { return }
            focusProjectEditorAfterNavigation(in: sourceEditorSession.textView.window)
        }
    }

    private func releaseStaleDocumentSecurityScope(for newURL: URL?) {
        guard let nativeDocument,
              let authorizedURL = SecurityScopedDocumentLeaseRegistry.activeURL(
                  for: nativeDocument
              ),
              authorizedURL.standardizedFileURL != newURL?.standardizedFileURL
        else {
            return
        }
        SecurityScopedDocumentLeaseRegistry.releaseAccess(for: nativeDocument)
    }

    private var processObservationLayer: some View {
        documentObservationLayer
        .onChange(of: processOwnership.generation) { _, _ in
            refreshFromPeerProcess(takingOwnership: processOwnership.isOwner)
        }
        .onChange(of: fileSafetySession.state.conflictSnapshot?.id) { _, _ in
            if !processOwnership.isOwner { refreshFromPeerProcess(takingOwnership: false) }
        }
    }

    private var interactionObservationLayer: some View {
        processObservationLayer
        .onChange(of: sourceEditorSession.selectedUTF16Range) { _, _ in
            updateRecoveryProtection()
        }
        .onChange(of: sourceEditorSession.verticalScrollOffset) { _, _ in
            updateRecoveryProtection()
        }
        .onChange(of: sourceEditorSession.verticalScrollFraction) { _, _ in
            guard preferences.scrollSyncEnabled else { return }
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
            if tearsDownWhenRemovedFromWorkspace {
                tearDownDocumentSession()
                return
            }
            // Ordinary native windows can temporarily leave the visible
            // hierarchy without closing. Embedded project surfaces opt into
            // the explicit teardown branch above when the workspace replaces
            // only its document content.
            guard let nativeDocument,
                  NSDocumentController.shared.documents.contains(where: {
                      $0 === nativeDocument
                  })
            else {
                tearDownDocumentSession()
                return
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            notification in
            guard let closingWindow = notification.object as? NSWindow,
                  let closingDocument = closingWindow.windowController?.document as? NSDocument,
                  closingDocument === (workspaceWindowDocument ?? nativeDocument)
            else { return }
            tearDownDocumentSession()
            folderBrowser.dissociateProjectWindow(nativeDocument)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
            _ in
            recoveryCoordinator?.close(recoveryRecordID)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: LinkedHeadingNavigationBroker.didRequestNavigation
            )
        ) { notification in
            guard let requestedPath = notification.object as? String,
                  fileURL?.standardizedFileURL.path == requestedPath
            else {
                return
            }
            consumePendingLinkedHeadingNavigation()
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
        .sheet(item: $tableInsertionRequest) { request in
            MarkdownTableInsertionView(
                request: request,
                onCancel: { tableInsertionRequest = nil },
                onInsert: { columns, rows in
                    insertTable(request, columns: columns, rows: rows)
                }
            )
        }
        .sheet(isPresented: $isRecoveryCenterPresented) {
            if let recoveryCoordinator {
                LightweightRecoveryPromptView(
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
                    onReload: { try await reloadFromDisk(snapshot) },
                    onOverwrite: { try await overwriteDiskVersion(snapshot) },
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
                case .tooLarge:
                    Button(ExportFailurePrompt.returnToAdjustTitle, role: .cancel) {
                        htmlExportNotice = nil
                    }
                case let .checkFailed(_, details):
                    Button(ExportFailurePrompt.viewProblemsTitle) {
                        htmlExportNotice = nil
                        Task { @MainActor in
                            await Task.yield()
                            exportIssueDetails = ExportIssueDetails(message: details)
                        }
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
                "\(documentSaveFailureMessage ?? "目标当前不可写。")\n\n当前编辑仍已保留；请重新确认目标文件的状态。"
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
        Group {
            if showsProjectSidebar && hasProjectContext {
                PersistentEdgeSplitView(
                    edge: .leading,
                    width: $preferences.workspaceProjectSidebarWidth,
                    isEdgeVisible: isProjectSidebarVisible,
                    allowedWidth: AppPreferences.Limits.projectSidebarWidth,
                    accessibilityLabel: "目录树与工作区分栏"
                ) {
                    FolderBrowserSidebar(
                        controller: folderBrowser,
                        currentDocumentURL: fileURL,
                        onOpenDocument: { url in
                            guard let recentDocuments else {
                                throw DocumentOpenError.unsupportedTarget
                            }
                            if let projectCoordinator {
                                projectCoordinator.openDocument(
                                    url,
                                    replacing: nativeDocument,
                                    using: recentDocuments
                                )
                            } else {
                                recentDocuments.openDocumentFromFolder(url)
                            }
                        },
                        onOpenDocumentWithCompletion: { url, completion in
                            guard let recentDocuments else {
                                completion(.failure(DocumentOpenError.unsupportedTarget))
                                return
                            }
                            if let projectCoordinator {
                                projectCoordinator.openDocument(
                                    url,
                                    replacing: nativeDocument,
                                    using: recentDocuments,
                                    completion: completion
                                )
                            } else {
                                recentDocuments.openDocumentFromFolder(
                                    url,
                                    completion: completion
                                )
                            }
                        },
                        onOpenCreatedDocument: { url, completion in
                            guard let recentDocuments else {
                                completion(.failure(DocumentOpenError.unsupportedTarget))
                                return
                            }
                            if let projectCoordinator {
                                projectCoordinator.openDocument(
                                    url,
                                    replacing: nativeDocument,
                                    using: recentDocuments,
                                    completion: completion
                                )
                            } else {
                                recentDocuments.openDocumentFromFolder(
                                    url,
                                    completion: completion
                                )
                            }
                        },
                        onPrepareToReplaceCurrentDocument: { completion in
                            guard let projectCoordinator else {
                                completion(true)
                                return
                            }
                            projectCoordinator.prepareToReplaceCurrentDocument(
                                nativeDocument,
                                completion: completion
                            )
                        },
                        onCollapse: { isProjectSidebarVisible = false }
                    )
                    .frame(
                        minWidth: EditorWorkspaceMetrics.projectSidebarMinimumWidth,
                        maxWidth: EditorWorkspaceMetrics.projectSidebarMaximumWidth
                    )
                } trailing: {
                    documentContent
                        .frame(minWidth: EditorWorkspaceMetrics.editorMinimumWidth)
                }
            } else {
                documentContent
            }
        }
    }

    private var hasProjectContext: Bool {
        activeProjectRoot != nil
    }

    private var activeProjectRoot: URL? {
        projectRoot(for: fileURL)
    }

    private func projectRoot(for documentURL: URL?) -> URL? {
        ProjectSessionBoundary.activeEditorRoot(
            for: documentURL,
            document: nativeDocument,
            browser: folderBrowser
        )
    }

    private func currentProjectRootIdentity(
        for projectRoot: URL?
    ) -> FolderProjectDirectoryIdentity? {
        guard let projectRoot,
              let identity = folderBrowser.projectRootIdentity,
              FolderProjectDirectoryIdentity.capture(projectRoot) == identity
        else {
            return nil
        }
        return identity
    }

    private var isProjectShell: Bool {
        hasProjectContext && fileURL == nil
    }

    private var nativeDocument: NSDocument? {
        nativeDocumentOverride
            ?? nativeDocumentHost.document
            ?? sourceEditorSession.textView.window?.windowController?.document as? NSDocument
    }

    @ViewBuilder
    private var documentContent: some View {
        if isProjectShell {
            ContentUnavailableView {
                Label("选择一份 Markdown", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(
                    isProjectSidebarVisible
                        ? "从左侧目录树选择 .md 或 .markdown，或新建一份 Markdown。"
                        : "目录树已隐藏。显示后可以选择或新建 Markdown。"
                )
            } actions: {
                if !isProjectSidebarVisible {
                    Button("显示目录树") {
                        isProjectSidebarVisible = true
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !usesSourceOnlyExperience {
            PersistentEdgeSplitView(
                edge: .trailing,
                width: $preferences.workspaceOutlineWidth,
                isEdgeVisible: isOutlineVisible,
                allowedWidth: AppPreferences.Limits.outlineWidth,
                accessibilityLabel: "工作区与文档大纲分栏"
            ) {
                editorContent
                    .frame(minWidth: EditorWorkspaceMetrics.editorMinimumWidth)
            } trailing: {
                DocumentOutlineView(
                    analysisState: analysisState,
                    selectedHeadingID: selectedHeadingID,
                    focusGeneration: outlineFocusGeneration,
                    onSelect: selectHeading,
                    onCollapse: { isOutlineVisible = false }
                )
                .frame(
                    minWidth: EditorWorkspaceMetrics.outlineMinimumWidth,
                    maxWidth: EditorWorkspaceMetrics.outlineMaximumWidth
                )
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
            PersistentHorizontalSplitView(fraction: editorSplitFractionBinding) {
                sourceEditor
                    .frame(minWidth: 320)
            } trailing: {
                preview
                    .frame(minWidth: 320)
            }
        case .preview:
            renderedEditor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sourceEditor: some View {
        return MarkdownSourceEditor(
            text: $document.text,
            selectionRequest: sourceSelectionRequest,
            session: sourceEditorSession,
            isEditable: canEditDocument,
            appearance: preferences.sourceEditorAppearance,
            presentation: .source,
            onPasteImage: pasteImage,
            onDropImage: dropImage
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var renderedEditor: some View {
        ZStack {
            renderedSurface(
                session: sourceEditorSession,
                isEditable: canEditDocument
            )
            .opacity(renderedSurfaceCanDisplay ? 1 : 0)
            .allowsHitTesting(renderedSurfaceCanDisplay)
            .accessibilityHidden(!renderedSurfaceCanDisplay)

            if !renderedSurfaceCanDisplay {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备即时编辑…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func renderedSurface(
        session: MarkdownSourceEditorSession,
        isEditable: Bool
    ) -> some View {
        let selection = isEditable ? sourceSelectionRequest : nil
        let pasteHandler: ((ClipboardImagePayload) -> Void)? = isEditable
            ? { payload in pasteImage(payload) }
            : nil
        let dropHandler: ((URL) -> Void)? = isEditable
            ? { url in dropImage(url) }
            : nil
        return MarkdownSourceEditor(
            text: $document.text,
            selectionRequest: selection,
            session: session,
            isEditable: isEditable,
            appearance: preferences.previewConfiguration.nativeRenderedAppearance(
                spellingEnabled: preferences.sourceEditorAppearance.spellingEnabled,
                autoPairEnabled: preferences.autoPairEnabled
            ),
            presentation: .rendered,
            onPasteImage: pasteHandler,
            onDropImage: dropHandler,
            onLinkClick: activatePreviewLink,
            renderedResourceContext: renderedEditingResourceContext,
            linkActivation: preferences.linkActivation,
            renderedTheme: preferences.previewConfiguration.theme,
            renderedColorScheme: preferences.previewConfiguration.colorScheme
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var renderedEditingResourceContext: RenderedMarkdownResourceContext {
        RenderedMarkdownResourceContext(
            documentDirectory: fileURL?.deletingLastPathComponent(),
            projectRoot: activeProjectRoot,
            expectedProjectRootIdentity: currentProjectRootIdentity(for: activeProjectRoot),
            requiresProjectBoundary: activeProjectRoot != nil
        )
    }

    private var preview: some View {
        previewSurface()
    }

    private func previewSurface() -> some View {
        VStack(spacing: 0) {
            if previewFailureMessage != nil {
                previewFailureBanner
                Divider()
            }

            ZStack {
                renderedSurface(
                    session: renderedPreviewSession,
                    isEditable: false
                )

                if previewFailureMessage == nil,
                   EmptyMarkdownGuidance.isVisible(markdown: document.text)
                {
                    EmptyMarkdownPreviewView(
                        onStartWriting: {
                            selectViewMode(viewMode == .preview ? .source : viewMode)
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
            .lineLimit(1)

            Divider()
                .frame(height: 12)
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

            if usesSourceOnlyExperience {
                Label("统计已暂停", systemImage: "pause.circle")
                    .help("源码优先文件不运行完整文档分析")
            } else {
                statisticsMenu
                    .help(statisticsHelp)
            }
            Divider()
                .frame(height: 12)
            Text("UTF-8\(document.properties.hasUTF8BOM ? " BOM" : "")")
            Text(
                document.properties.requiresLineEndingChoice
                    ? "混合换行（待选择）"
                    : document.properties.lineEnding.displayName
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: EditorWorkspaceMetrics.statusBarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
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
            setFocusMode: { enabled in
                restoredFocusModeEnabled = enabled
                applyWritingModes()
            },
            setTypewriterMode: { enabled in
                restoredTypewriterModeEnabled = enabled
                applyWritingModes()
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
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        }
    }

    private func synchronizeEngineMode() {
        let mode: EditorEngineMode = canEditDocument ? .editable : .readOnly
        Task { @MainActor in
            _ = await editorStore.setMode(mode)
        }
    }

    private func applyRestorationStateIfNeeded() {
        guard !didApplyRestorationState,
              let restorationState = document.restorationState
        else {
            return
        }
        didApplyRestorationState = true
        sourceEditorSession.requestRestoration(restorationState)
    }

    private func prepareFreshUntitledDocumentForEditingIfNeeded() {
        guard !didPrepareFreshUntitledDocument else { return }
        guard InflowLaunchPolicy.shouldFocusFreshUntitledDocument(
            fileURL: fileURL,
            text: document.text,
            hasRestorationState: document.restorationState != nil,
            isEditable: canEditDocument
        ) else {
            return
        }
        didPrepareFreshUntitledDocument = true

        Task { @MainActor in
            // Rendered mode mounts the text view after its first derived plan.
            // A single yield can run too early and leave the blank tab unfocused.
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if sourceEditorSession.focusEditor() { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func updateRecoveryProtection(originalURL: URL? = nil) {
        document.writeGuard.setProcessWitness(processOwnership.witness)
        TemporaryDocumentDrafts.register(recoveryRecordID, owner: nativeDocument, windowOwner: workspaceWindowDocument) {
            let view = sourceEditorSession.textView
            view.finishPendingInputForCheckpoint()
            var latest = document
            latest.text = view.string
            return DocumentRecoveryRecord(id: recoveryRecordID, document: latest,
                originalURL: originalURL ?? fileURL, selectedUTF16Range: view.selectedRange(),
                viewMode: viewMode, verticalScrollOffset: sourceEditorSession.verticalScrollOffset)
        }
        let isModified = MarkdownDocumentModificationProjection.isModified(document)
        folderBrowser.setDocumentModified(nativeDocument, modified: isModified)
        projectCoordinator?.setDocumentModified(nativeDocument, modified: isModified)
        guard let recoveryCoordinator else { return }
        recoveryCoordinator.update(
            DocumentRecoveryRecord(
                id: recoveryRecordID,
                document: document,
                originalURL: originalURL ?? fileURL,
                selectedUTF16Range: sourceEditorSession.selectedUTF16Range,
                viewMode: viewMode,
                verticalScrollOffset: sourceEditorSession.verticalScrollOffset
            )
        )
    }

    private func refreshFromPeerProcess(takingOwnership: Bool) {
        guard fileURL != nil else { return }
        peerRefreshGeneration &+= 1
        let generation = peerRefreshGeneration
        isRefreshingPeerFile = true
        Task { @MainActor in
            defer {
                if generation == peerRefreshGeneration { isRefreshingPeerFile = false }
            }
            await fileSafetySession.inspectNow()
            guard generation == peerRefreshGeneration,
                  let snapshot = fileSafetySession.state.conflictSnapshot,
                  DocumentPeerReloadPolicy.shouldReload(snapshot, isOwner: processOwnership.isOwner,
                    takingOwnership: takingOwnership) else { return }
            // Preserve a separate recovery copy before replacing a passive
            // instance's uncommitted text. Never overwrite the user file here.
            do {
                try DocumentPeerReloadPolicy.preserveLocalChanges(snapshot, document: document,
                    viewMode: viewMode, store: TemporaryDocumentDraftStore(rootURL: TemporaryDocumentDraftStore.defaultRoot))
                guard generation == peerRefreshGeneration else { return }
                try await reloadFromDisk(snapshot)
                deferredFileSafetySnapshotID = nil
            } catch {
                // Keep the original text and recovery copy. The existing
                // conflict banner remains available for a manual retry.
            }
        }
    }

    private func reloadFromDisk(_ snapshot: DocumentFileConflictSnapshot) async throws {
        guard let nativeDocument = nativeDocument ?? NativeDocumentSaveCoordinator.activeDocument(
            sourceURL: snapshot.url
        ), NativeDocumentSaveCoordinator.represents(
            nativeDocument,
            sourceURL: snapshot.url
        ) else {
            throw DocumentRelocationError.cannotInspect
        }
        let reloadEnvelope = try await fileSafetySession.prepareReload(snapshot)
        let nativeRevert = try NativeDocumentSaveCoordinator.prepareRevert(
            from: snapshot.url,
            verifiedData: reloadEnvelope.diskData
        )
        defer {
            NativeDocumentSaveCoordinator.discardRevertPreparation(nativeRevert)
        }
        // Verify the decision one final time before mutating the native
        // document. The subsequent revert consumes only the already-frozen
        // bytes, never the now-mutable source pathname.
        let result = try await fileSafetySession.commitReload(reloadEnvelope)
        editorStore.prepareForDocumentReplacement()
        try NativeDocumentSaveCoordinator.revert(
            document: nativeDocument,
            using: nativeRevert
        )
        NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
            nativeDocument,
            targetURL: snapshot.url,
            expectedData: result.data
        )
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

    private var documentSaveCommandActions: DocumentSaveCommandActions {
        DocumentSaveCommandActions(
            isBusy: isProjectShell
                || isSavingDocument
                || isRelocatingDocument
                || relocationRequest != nil,
            canSave: canEditDocument,
            save: saveCurrentDocument,
            saveAs: { beginDocumentRelocation(.saveAs) },
            showInFinder: fileURL.map { url in
                { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        )
    }

    @discardableResult
    private func freezeAuthoritativeTextForPersistence() async throws -> String {
        guard let snapshot = await editorStore.persistenceSnapshot(),
              UTF8Text.isExactlyEqual(snapshot.text, editorStore.textProjection)
        else {
            throw EditorPersistenceError.unavailableAuthoritativeSnapshot
        }
        if !UTF8Text.isExactlyEqual(document.text, snapshot.text) {
            document.text = snapshot.text
        }
        return snapshot.text
    }

    private func prepareAuthoritativeSaveForPersistence() async throws
        -> EditorEngineSavePreparation
    {
        guard let preparation = await editorStore.preparePersistenceSave(),
              UTF8Text.isExactlyEqual(
                  preparation.text,
                  editorStore.textProjection
              )
        else {
            throw EditorPersistenceError.unavailableAuthoritativeSnapshot
        }
        if !UTF8Text.isExactlyEqual(document.text, preparation.text) {
            document.text = preparation.text
        }
        return preparation
    }

    private func saveCurrentDocument() {
        guard !isSavingDocument, !isRelocatingDocument, relocationRequest == nil else { return }
        guard let fileURL else {
            _ = beginDocumentRelocation(.saveAs)
            return
        }
        guard let nativeDocument = NativeDocumentSaveCoordinator.activeDocument(
            sourceURL: fileURL
        ), NativeDocumentSaveCoordinator.represents(nativeDocument, sourceURL: fileURL) else {
            documentSaveFailureMessage = "无法确认当前文档的保存目标。"
            return
        }
        if let snapshot = fileSafetySession.state.conflictSnapshot {
            guard snapshot.diskExists else {
                beginDocumentRelocation(.saveAs)
                return
            }
            presentFileSafetyReview(snapshot, decision: .overwrite)
            return
        }

        isSavingDocument = true
        Task { @MainActor in
            defer { isSavingDocument = false }
            var engineSave: EditorEngineSavePreparation?
            do {
                engineSave = try await prepareAuthoritativeSaveForPersistence()
                let envelope = try fileSafetySession.prepareSave(
                    document: document,
                    sourceURL: fileURL,
                    targetURL: fileURL,
                    targetExpectation: try .capture(fileURL),
                    operation: .save
                )
                defer { fileSafetySession.cancelSave(envelope) }
                try await NativeDocumentSaveCoordinator.saveCurrent(
                    document: nativeDocument,
                    to: fileURL
                )
                try await fileSafetySession.commitSave(envelope)
                guard let completedSave = engineSave,
                      await editorStore.completePersistenceSave(completedSave)
                else {
                    throw EditorPersistenceError.unavailableAuthoritativeSnapshot
                }
                engineSave = nil
                NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
                    nativeDocument,
                    targetURL: envelope.targetURL,
                    expectedData: envelope.bytes
                )
                document.adoptRecoveryCommittedSave(envelope)
                updateRecoveryProtection(originalURL: envelope.targetURL)
                await recoveryCoordinator?.flush(recoveryRecordID)
                documentSaveFailureMessage = nil
            } catch {
                if let engineSave {
                    await editorStore.abortPersistenceSave(engineSave)
                }
                LocalFailureLogController.shared.record(.saving, code: .saveFailed)
                documentSaveFailureMessage = error.localizedDescription
            }
        }
    }

    private func overwriteDiskVersion(_ snapshot: DocumentFileConflictSnapshot) async throws {
        guard !isSavingDocument,
              let nativeDocument = NativeDocumentSaveCoordinator.activeDocument(
                  sourceURL: snapshot.url
              ), NativeDocumentSaveCoordinator.represents(
                  nativeDocument,
                  sourceURL: snapshot.url
              )
        else {
            throw DocumentRelocationError.cannotInspect
        }
        isSavingDocument = true
        defer { isSavingDocument = false }
        var engineSave: EditorEngineSavePreparation?
        do {
            engineSave = try await prepareAuthoritativeSaveForPersistence()
            let envelope = try await fileSafetySession.prepareConfirmedOverwrite(
                document: document,
                snapshot: snapshot
            )
            defer { fileSafetySession.cancelSave(envelope) }
            try await NativeDocumentSaveCoordinator.saveCurrent(
                document: nativeDocument,
                to: snapshot.url
            )
            try await fileSafetySession.commitSave(envelope)
            guard let completedSave = engineSave,
                  await editorStore.completePersistenceSave(completedSave)
            else {
                throw EditorPersistenceError.unavailableAuthoritativeSnapshot
            }
            engineSave = nil
            NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
                nativeDocument,
                targetURL: envelope.targetURL,
                expectedData: envelope.bytes
            )
            document.adoptRecoveryCommittedSave(envelope)
            updateRecoveryProtection(originalURL: envelope.targetURL)
            await recoveryCoordinator?.flush(recoveryRecordID)
            documentSaveFailureMessage = nil
        } catch {
            if let engineSave {
                await editorStore.abortPersistenceSave(engineSave)
            }
            LocalFailureLogController.shared.record(.saving, code: .saveFailed)
            throw error
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
            let snapshotData: Data
            do {
                _ = try await freezeAuthoritativeTextForPersistence()
                snapshotData = try document.encodedFileData()
            } catch {
                isRelocatingDocument = false
                relocationNativeDocument = nil
                if isSavingBeforeImage { deferredImageInsertionQueue.cancel() }
                presentFileOperationFailure(error, fallback: "当前正文无法编码，未写入任何文件。")
                return
            }
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
                let relocationReferences: [MarkdownReference]
                if UTF8Text.isExactlyEqual(previewSourceSnapshot, document.text) {
                    relocationReferences = derivedReferences
                } else if let content = await editorStore.deriveContent(
                    for: document.text,
                    configuration: preferences.previewConfiguration
                ), UTF8Text.isExactlyEqual(content.sourceSnapshot, document.text) {
                    relocationReferences = content.references
                } else {
                    throw DocumentRelocationError.cannotInspect
                }
                let plan = try DocumentRelocationAnalyzer.plan(
                    markdown: document.text,
                    references: relocationReferences,
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

        var engineSave: EditorEngineSavePreparation?
        do {
            if request.operation == .saveAs {
                engineSave = try await prepareAuthoritativeSaveForPersistence()
            } else {
                _ = try await freezeAuthoritativeTextForPersistence()
            }
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

            let envelope = try fileSafetySession.prepareSave(
                document: document,
                sourceURL: request.plan.sourceURL,
                targetURL: request.plan.targetURL,
                targetExpectation: request.plan.targetSnapshot.isExistingTarget
                    ? .exact(request.plan.targetSnapshot)
                    : .absent,
                operation: request.operation == .saveAs ? .saveAs : .saveCopy
            )
            defer { fileSafetySession.cancelSave(envelope) }
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
            try await fileSafetySession.commitSave(envelope)
            if request.operation == .saveAs {
                guard let completedSave = engineSave,
                      await editorStore.completePersistenceSave(completedSave)
                else {
                    throw EditorPersistenceError.unavailableAuthoritativeSnapshot
                }
                engineSave = nil
                NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
                    nativeDocument,
                    targetURL: envelope.targetURL,
                    expectedData: envelope.bytes
                )
                document.adoptRecoveryCommittedSave(envelope)
                updateRecoveryProtection(originalURL: envelope.targetURL)
                await recoveryCoordinator?.flush(recoveryRecordID)
            }

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
            if let engineSave {
                await editorStore.abortPersistenceSave(engineSave)
            }
            deferredImageInsertionQueue.cancel()
            relocationRequest = nil
            relocationNativeDocument = nil
            presentFileOperationFailure(error)
        }
    }

    private func presentFileOperationFailure(
        _ error: Error,
        fallback: String = "未能完成文件操作；当前编辑仍已保留，请重新确认目标文件的状态。"
    ) {
        LocalFailureLogController.shared.record(.saving, code: .saveFailed)
        fileSafetyNotice = .failure(
            (error as? LocalizedError)?.errorDescription ?? fallback
        )
    }

    private func selectHeading(_ heading: DocumentHeading) {
        guard analysisState.allowsNavigation,
              analysisState.displayedAnalysis.headings.contains(heading)
        else {
            return
        }

        selectedHeadingID = heading.id
        revealSourceSurface()
        sourceSelectionGeneration &+= 1
        sourceSelectionRequest = SourceSelectionRequest(
            generation: sourceSelectionGeneration,
            utf8Range: heading.sourceUTF8Range
        )
    }

    private func tearDownDocumentSession() {
        TemporaryDocumentDrafts.unregister(recoveryRecordID)
        editorStore.send(.cancelPending)
        previewLinkTask?.cancel()
        findSearchTask?.cancel()
        abandonExportTracking()
        pendingFindNavigation.removeAll()
        findSession.cancelSearch()
        fileSafetySession.stopMonitoring()
        recoveryCoordinator?.close(recoveryRecordID)
    }

    private func activatePreviewLink(_ target: String) {
        previewLinkTask?.cancel()
        previewLinkGeneration &+= 1
        let generation = previewLinkGeneration
        let markdown = document.text
        let references = UTF8Text.isExactlyEqual(previewSourceSnapshot, markdown)
            ? derivedReferences
            : []
        let documentURL = fileURL
        let candidateProjectRoot = activeProjectRoot
        let projectRootIdentity = currentProjectRootIdentity(for: candidateProjectRoot)
        let projectRoot = projectRootIdentity == nil ? nil : candidateProjectRoot

        previewLinkTask = Task { @MainActor in
            let plan = await previewLinkWorker.plan(
                markdown: markdown,
                references: references,
                target: target,
                documentURL: documentURL,
                projectRoot: projectRoot,
                expectedProjectRootIdentity: projectRootIdentity
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
            case .external:
                performResolvedPreviewLink(plan)
            case .local where PreviewLinkActivationPolicy.opensWithoutConfirmation(plan):
                performResolvedPreviewLink(plan)
            case .local, .blocked:
                previewLinkPlan = plan
            }
        }
    }

    private func focusProjectEditorAfterNavigation(in candidateWindow: NSWindow?) {
        guard InflowLaunchPolicy.shouldFocusProjectDocumentAfterNavigation(
            fileURL: fileURL,
            hasProjectContext: hasProjectContext,
            sourceIsVisible: true,
            isEditable: canEditDocument
        )
        else { return }

        Task { @MainActor in
            // Let the destination surface finish its atomic presentation before
            // moving first responder away from the directory tree.
            await Task.yield()
            guard let editorWindow = sourceEditorSession.textView.window,
                  editorWindow === candidateWindow || candidateWindow == nil,
                  editorWindow.isKeyWindow
            else { return }
            _ = sourceEditorSession.focusEditor()
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
            revealSourceSurface()
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
                if PreviewLinkOpenPolicy.usesSystemApplication(link) {
                    guard NSWorkspace.shared.open(accessURL) else {
                        previewLinkPlan = blockedPreviewLinkPlan(
                            target: plan.target,
                            reason: .cannotOpen,
                            safeTarget: link.url.lastPathComponent,
                            expectedURL: link.url
                        )
                        return
                    }
                } else {
                    openProjectMarkdown(link, sourcePlan: plan)
                }
            case .image, .pdf:
                guard !PreviewLinkOpenPolicy.usesSystemApplication(link) else {
                    guard NSWorkspace.shared.open(accessURL) else {
                        previewLinkPlan = blockedPreviewLinkPlan(
                            target: plan.target,
                            reason: .cannotOpen,
                            safeTarget: link.url.lastPathComponent,
                            expectedURL: link.url
                        )
                        return
                    }
                    return
                }
                do {
                    guard let snapshot = link.snapshot else {
                        throw PreviewLocalFileError.unavailable
                    }
                    let frozen = try PreviewLocalFileReader.read(
                        accessURL,
                        expected: snapshot
                    )
                    let safeURL = try SafePreviewOpenStore.materialize(
                        frozen,
                        extension: link.url.pathExtension.lowercased()
                    )
                    do {
                        switch link.kind {
                        case .image:
                            _ = try LocalImageValidator.load(at: safeURL)
                        case .pdf:
                            guard let provider = CGDataProvider(data: frozen.data as CFData),
                                  let pdf = CGPDFDocument(provider),
                                  pdf.numberOfPages > 0
                            else {
                                throw PreviewLocalFileError.unsafeContent
                            }
                        case .markdown, .attachment:
                            break
                        }
                        guard NSWorkspace.shared.open(safeURL) else {
                            throw PreviewLocalFileError.unavailable
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: safeURL)
                        throw error
                    }
                } catch {
                    previewLinkPlan = blockedPreviewLinkPlan(
                        target: plan.target,
                        reason: .unsafeLocalTarget,
                        safeTarget: link.url.lastPathComponent,
                        expectedURL: link.url
                    )
                }
            case .attachment:
                guard NSWorkspace.shared.open(accessURL) else {
                    previewLinkPlan = blockedPreviewLinkPlan(
                        target: plan.target,
                        reason: .cannotOpen,
                        safeTarget: link.url.lastPathComponent,
                        expectedURL: link.url
                    )
                    return
                }
            }
        case let .currentDocument(fragment):
            previewLinkPlan = nil
            navigateInCurrentDocument(to: fragment)
        case .blocked:
            break
        }
    }

    private func openProjectMarkdown(
        _ link: PreviewLocalLink,
        sourcePlan: PreviewLinkPlan
    ) {
        guard let recentDocuments,
              let projectRoot = link.projectRoot,
              let authorization = ProjectDocumentOpenAuthorization.capture(
                  targetURL: link.url,
                  projectRoot: projectRoot
              )
        else {
            previewLinkPlan = blockedPreviewLinkPlan(
                target: sourcePlan.target,
                reason: .cannotOpen,
                safeTarget: link.url.lastPathComponent
            )
            return
        }
        guard let snapshot = link.snapshot,
              authorization.snapshot == snapshot,
              link.expectedProjectRootIdentity.map({
                  authorization.projectIdentity == $0
              }) ?? true,
              authorization.isCurrent()
        else {
            previewLinkPlan = blockedPreviewLinkPlan(
                target: sourcePlan.target,
                reason: .unavailableLocalTarget,
                safeTarget: link.url.lastPathComponent,
                expectedURL: link.url
            )
            return
        }

        let completion: @MainActor @Sendable (Result<Void, Error>) -> Void = { result in
            switch result {
            case .success:
                LinkedHeadingNavigationBroker.request(
                    documentURL: link.url,
                    fragment: link.fragment
                )
            case let .failure(error):
                if let openError = error as? DocumentOpenError,
                   case .cancelled = openError
                {
                    previewLinkPlan = nil
                    return
                }
                let reason: PreviewLinkFailureReason
                switch error as? DocumentOpenError {
                case .targetChanged?, .fileUnavailable?:
                    reason = .unavailableLocalTarget
                case .unsupportedTarget?:
                    reason = .unsafeLocalTarget
                default:
                    reason = .cannotOpen
                }
                previewLinkPlan = blockedPreviewLinkPlan(
                    target: sourcePlan.target,
                    reason: reason,
                    safeTarget: link.url.lastPathComponent,
                    expectedURL: link.url
                )
            }
        }
        if let projectCoordinator {
            projectCoordinator.openDocument(
                link.url,
                replacing: nativeDocument,
                using: recentDocuments,
                authorization: authorization,
                completion: completion
            )
        } else {
            recentDocuments.openDocumentFromFolderDetailed(
                link.url,
                authorization: authorization
            ) { result in
                completion(result.map { _ in () })
            }
        }
    }

    private func consumePendingLinkedHeadingNavigation() {
        guard let fileURL,
              let fragment = LinkedHeadingNavigationBroker.consume(for: fileURL)
        else {
            return
        }
        incomingHeadingFragment = fragment
        incomingNavigationIsPending = true
        applyPendingDocumentNavigationIfPossible()
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
        renderedPreviewSession.scroll(
            toFraction: sourceEditorSession.verticalScrollFraction
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
            isExportingPDF: isExportingPDF,
            canExportPDF: !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            startPDF: startPDFExport
        )
    }

    private var markdownFormatCommandActions: MarkdownFormatCommandActions {
        let formattingIsAvailable = canEditDocument && !usesSourceOnlyExperience
        let canClearFormat = formattingIsAvailable && sourceEditorSession.canClearFormat
        return MarkdownFormatCommandActions(
            canFormat: formattingIsAvailable,
            canClearFormat: canClearFormat,
            apply: applyMarkdownFormat
        )
    }

    private var markdownInsertCommandActions: MarkdownInsertCommandActions {
        MarkdownInsertCommandActions(
            canInsert: canEditDocument,
            insertLink: presentLinkInsertion,
            insertImage: insertImage,
            insertTable: { columns, rows in
                insertTable(columns: columns, rows: rows)
            },
            presentTableInsertion: presentTableInsertion,
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

    private func registerSelectedProjectDirectory(_ directory: URL?) {
        guard let directory else { return }
        imageDirectoryAccess.registerUserSelectedDirectory(directory)
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
                let placement = ExistingImagePlacement.copyToAssets
                let alternative = sourceURL.deletingPathExtension().lastPathComponent

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
                let resolution: ImageAssetCollisionResolution = destinationSnapshot.exists
                    ? .incrementName
                    : .failIfExists

                let asset = try await worker.importAsset(
                    image: image,
                    originalFilename: filename,
                    directoryPlan: directoryPlan,
                    collisionResolution: resolution,
                    expectedDestination: destinationSnapshot
                )
                do {
                    revealSourceSurface()
                    guard await editorStore.applyFormat(
                        .image(
                            destination: asset.relativeMarkdownPath,
                            defaultAlternative: alternative.isEmpty ? "图片描述" : alternative
                        ),
                        expectedText: sourceSnapshot,
                        selectedUTF16Range: selectedRange,
                        actionName: "插入图片",
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
                LocalFailureLogController.shared.record(.imageImport, code: .invalidImage)
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
        revealSourceSurface()
        guard await editorStore.applyFormat(
            .image(
                destination: reference.markdownDestination,
                defaultAlternative: defaultAlternative.isEmpty
                    ? "图片描述"
                    : defaultAlternative
            ),
            expectedText: sourceSnapshot,
            selectedUTF16Range: selectedRange,
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
            if imageDirectoryAccess.isAuthorized(documentDirectory) {
                return .assets(in: documentDirectory)
            }
            guard let selectedDirectory = try await ImageAssetPicker.chooseDocumentDirectory(
                documentDirectory,
                attachedTo: window
            ) else {
                return nil
            }
            try imageDirectoryAccess.authorizePersistently(selectedDirectory)
            return .assets(in: selectedDirectory)
        case .copyToRelativeDirectory:
            guard let plan = try await ImageAssetPicker.chooseRelativeAssetDirectory(
                relativeTo: documentDirectory,
                attachedTo: window
            ) else {
                return nil
            }
            try imageDirectoryAccess.authorizePersistently(plan.directoryURL)
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
                guard let directoryPlan = try await imageAssetDirectoryPlan(
                    for: .copyToAssets,
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
                    revealSourceSurface()
                    guard await editorStore.applyFormat(
                        .image(
                            destination: asset.relativeMarkdownPath,
                            defaultAlternative: alternative
                        ),
                        expectedText: sourceSnapshot,
                        selectedUTF16Range: selectedRange,
                        actionName: "粘贴图片",
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
        applyEngineInsertion(.mermaid, actionName: "插入图表", noun: "图表")
    }

    private func insertFormula() {
        applyEngineInsertion(.math, actionName: "插入公式", noun: "公式")
    }

    private func insertFootnote() {
        applyEngineInsertion(.footnote, actionName: "插入脚注", noun: "脚注")
    }

    private func insertHorizontalRule() {
        applyEngineInsertion(.horizontalRule, actionName: "插入分隔线", noun: "分隔线")
    }

    private func insertTable(columns: UInt8, rows: UInt8) {
        applyEngineInsertion(
            .table(columns: columns, rows: rows),
            actionName: "插入表格",
            noun: "表格"
        )
    }

    private func presentTableInsertion() {
        guard canEditDocument, tableInsertionRequest == nil else { return }
        tableInsertionRequest = MarkdownTableInsertionRequest(
            sourceSnapshot: document.text,
            selectedUTF16Range: sourceEditorSession.textView.selectedRange()
        )
    }

    private func insertTable(
        _ request: MarkdownTableInsertionRequest,
        columns: UInt8,
        rows: UInt8
    ) {
        guard tableInsertionRequest?.id == request.id else { return }
        revealSourceSurface()
        Task { @MainActor in
            guard await editorStore.applyFormat(
                .table(columns: columns, rows: rows),
                expectedText: request.sourceSnapshot,
                selectedUTF16Range: request.selectedUTF16Range,
                actionName: "插入表格"
            ) else {
                tableInsertionRequest = nil
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入表格。"
                return
            }
            tableInsertionRequest = nil
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
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
        revealSourceSurface()
        Task { @MainActor in
            guard await editorStore.applyFormat(
                .link(destination: destination),
                expectedText: request.sourceSnapshot,
                selectedUTF16Range: request.selectedUTF16Range,
                actionName: "插入链接"
            ) else {
                linkInsertionRequest = nil
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入链接。"
                return
            }
            linkInsertionRequest = nil
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
        }
    }

    private func applyEngineInsertion(
        _ operation: EditorEngineFormatOperation,
        actionName: String,
        noun: String
    ) {
        guard canEditDocument else { return }
        let source = document.text
        let selection = sourceEditorSession.textView.selectedRange()
        revealSourceSurface()
        Task { @MainActor in
            guard await editorStore.applyFormat(
                operation,
                expectedText: source,
                selectedUTF16Range: selection,
                actionName: actionName
            ) else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未插入\(noun)。"
                return
            }
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
        }
    }

    private func applyMarkdownFormat(_ command: MarkdownFormatCommand) {
        guard canEditDocument, !usesSourceOnlyExperience else { return }
        let source = document.text
        let selection = sourceEditorSession.textView.selectedRange()
        guard !sourceEditorSession.textView.hasActiveComposition else {
            markdownFormatErrorMessage = "请先确认或取消输入法候选，再应用格式。"
            return
        }
        do {
            _ = try MarkdownFormatter.plan(source: source, selectedUTF16Range: selection, command: command)
        } catch {
            markdownFormatErrorMessage = error.localizedDescription
            return
        }
        revealSourceSurface()
        Task { @MainActor in
            guard await editorStore.applyFormat(
                command.engineOperation,
                expectedText: source,
                selectedUTF16Range: selection,
                actionName: command.undoActionName
            ) else {
                markdownFormatErrorMessage = "正文、选区或输入法状态已变化，本次未修改文档。"
                return
            }
            await Task.yield()
            _ = sourceEditorSession.focusEditor()
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

    private func startPDFExport() {
        guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isExportingHTML,
              !isExportingPDF
        else {
            return
        }
        Task { @MainActor in
            do {
                let markdown = try await freezeAuthoritativeTextForPersistence()
                guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !isExportingHTML,
                      !isExportingPDF
                else { return }
                prepareExport(makeFrozenExportRequest(format: .pdf, markdown: markdown))
            } catch {
                exportIssueDetails = ExportIssueDetails(message: error.localizedDescription)
            }
        }
    }

    private func makeFrozenExportRequest(
        format: ExportFormat,
        markdown: String
    ) -> FrozenExportRequest {
        let requiresProjectBoundary = folderBrowser.isAssociatedProjectDocument(nativeDocument)
        let candidateProjectRoot = activeProjectRoot
        let projectRootIdentity = currentProjectRootIdentity(for: candidateProjectRoot)
        let projectRoot = projectRootIdentity == nil ? nil : candidateProjectRoot
        let documentDirectory = requiresProjectBoundary && projectRoot == nil
            ? nil
            : fileURL?.deletingLastPathComponent()
        let snapshot = HTMLExportSnapshot(
            markdown: markdown,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: projectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            appearance: format == .pdf ? .personalPDF : preferences.previewConfiguration
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
                    snapshot: pending.request.snapshot
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
        if request.format == .pdf {
            LocalFailureLogController.shared.record(.pdfExport, code: .pdfPreparationFailed)
        }
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
        LocalFailureLogController.shared.record(.pdfExport, code: .pdfRenderingFailed)
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
        if context.request.format == .pdf {
            LocalFailureLogController.shared.record(.pdfExport, code: .pdfWriteFailed)
        }
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

    private func revealSourceSurface() {
        viewMode = viewMode.sourceVisible
    }

    private func selectViewMode(_ mode: EditorViewMode) {
        guard !usesSourceOnlyExperience || mode == .source else { return }
        viewMode = mode
        guard !findSession.isPresented else { return }

        if mode != .preview {
            Task { @MainActor in
                await Task.yield()
                _ = sourceEditorSession.focusEditor()
            }
        }
    }

    private func presentFind(replacing: Bool) {
        guard !replacing || canEditDocument else { return }
        revealSourceSurface()
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
        revealSourceSurface()
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
        revealSourceSurface()
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
        Task { @MainActor in
            let replaced = await editorStore.replaceCurrent(
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

        replaceAllPlan = nil
        Task { @MainActor in
            let replaced = await editorStore.replaceAll(
                utf8Ranges: plan.matches.map(\.utf8Range),
                with: plan.replacement,
                expectedText: plan.source
            )
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
        findSession.beginSearch()

        findSearchTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            guard let outcome = await editorStore.search(
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
        projectRoot: URL?,
        configuration: PreviewAppearanceConfiguration,
        syntaxHighlightingEnabled: Bool,
        delayNanoseconds: UInt64
    ) {
        let requiresProjectBoundary = folderBrowser.isAssociatedProjectDocument(nativeDocument)
        let projectRootIdentity = currentProjectRootIdentity(for: projectRoot)
        let authorizedProjectRoot = projectRootIdentity == nil ? nil : projectRoot
        let authorizedDocumentDirectory = requiresProjectBoundary
            && authorizedProjectRoot == nil
            ? nil
            : documentDirectory

        guard !usesSourceOnlyExperience else {
            selectedHeadingID = nil
            incomingNavigationIsPending = false
            editorStore.send(.suspendDerived(markdown: markdown))
            return
        }

        editorStore.send(
            .refreshDerived(
                EditorDerivedContentRequest(
                    markdown: markdown,
                    documentDirectory: authorizedDocumentDirectory,
                    projectRoot: authorizedProjectRoot,
                    expectedProjectRootIdentity: projectRootIdentity,
                    requiresProjectBoundary: requiresProjectBoundary,
                    configuration: configuration,
                    syntaxHighlightingEnabled: syntaxHighlightingEnabled,
                    delayNanoseconds: delayNanoseconds
                )
            )
        )
    }

    private func retryPreview() {
        scheduleDerivedContent(
            for: document.text,
            documentDirectory: fileURL?.deletingLastPathComponent(),
            projectRoot: activeProjectRoot,
            configuration: preferences.previewConfiguration,
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
