import SwiftUI

enum EditorRenderedSurfacePhase: Equatable {
    case preparing
    case ready(sourceSnapshot: String)
    case optimistic(sourceSnapshot: String)
    case fallback(sourceSnapshot: String)

    func canDisplay(documentText: String) -> Bool {
        switch self {
        case .preparing:
            false
        case let .ready(sourceSnapshot),
             let .optimistic(sourceSnapshot),
             let .fallback(sourceSnapshot):
            UTF8Text.isExactlyEqual(sourceSnapshot, documentText)
        }
    }
}

struct EditorViewState: Equatable {
    var previewSourceSnapshot: String
    var previewFailureMessage: String?
    var analysisState: DocumentAnalysisState
    var references: [MarkdownReference]
    var engineMode: EditorEngineMode
    var renderedSurfacePhase: EditorRenderedSurfacePhase

    static let initial = Self(
        previewSourceSnapshot: "",
        previewFailureMessage: nil,
        analysisState: .updating(previous: .empty),
        references: [],
        engineMode: .editable,
        renderedSurfacePhase: .preparing
    )
}

struct EditorDerivedContentRequest: Equatable, Sendable {
    let markdown: String
    let documentDirectory: URL?
    let projectRoot: URL?
    let expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
    let requiresProjectBoundary: Bool
    let configuration: PreviewAppearanceConfiguration
    let syntaxHighlightingEnabled: Bool
    let delayNanoseconds: UInt64

    func hasSameDerivationInput(as other: Self) -> Bool {
        UTF8Text.isExactlyEqual(markdown, other.markdown)
            && documentDirectory == other.documentDirectory
            && projectRoot == other.projectRoot
            && expectedProjectRootIdentity == other.expectedProjectRootIdentity
            && requiresProjectBoundary == other.requiresProjectBoundary
            && configuration == other.configuration
            && syntaxHighlightingEnabled == other.syntaxHighlightingEnabled
    }
}

enum EditorIntent: Sendable {
    case refreshDerived(EditorDerivedContentRequest)
    case suspendDerived(markdown: String)
    case cancelPending
}

@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var state: EditorViewState

    private let sourceEditorSession: MarkdownSourceEditorSession
    private let renderedPreviewSession: MarkdownSourceEditorSession
    private var derivedContentGeneration = 0
    private var derivedContentTask: Task<Void, Never>?
    private var activeDerivedRequest: EditorDerivedContentRequest?
    private var completedDerivedRequest: EditorDerivedContentRequest?
    private var latestDerivedRequest: EditorDerivedContentRequest?
    private var requestedMode: EditorEngineMode
    private var modeSynchronizationTask: Task<Bool, Never>?

    init(
        sourceEditorSession: MarkdownSourceEditorSession,
        renderedPreviewSession: MarkdownSourceEditorSession = MarkdownSourceEditorSession(
            role: .renderedProjection
        ),
        initialState: EditorViewState = .initial
    ) {
        self.sourceEditorSession = sourceEditorSession
        self.renderedPreviewSession = renderedPreviewSession
        state = initialState
        requestedMode = initialState.engineMode
        sourceEditorSession.localTextProjectionDidPublish = { [weak self] sourceSnapshot in
            guard let self else { return }
            self.state.renderedSurfacePhase = .optimistic(sourceSnapshot: sourceSnapshot)
            // SwiftUI may coalesce A -> B -> A during undo/redo. A native
            // acknowledgement still invalidates analysis of the earlier A.
            guard let request = self.latestDerivedRequest else { return }
            self.activeDerivedRequest = nil
            self.completedDerivedRequest = nil
            self.refreshDerived(EditorDerivedContentRequest(
                markdown: sourceSnapshot, documentDirectory: request.documentDirectory,
                projectRoot: request.projectRoot, expectedProjectRootIdentity: request.expectedProjectRootIdentity,
                requiresProjectBoundary: request.requiresProjectBoundary, configuration: request.configuration,
                syntaxHighlightingEnabled: request.syntaxHighlightingEnabled,
                delayNanoseconds: request.delayNanoseconds))
        }
        sourceEditorSession.resolvedMermaidPlanDidPublish = {
            [weak renderedPreviewSession] plan, source in
            renderedPreviewSession?.installResolvedMermaidPlan(plan, source: source)
        }
    }

    deinit {
        derivedContentTask?.cancel()
        modeSynchronizationTask?.cancel()
    }

    var textProjection: String {
        sourceEditorSession.textView.string
    }

    func deriveContent(
        for markdown: String,
        configuration: PreviewAppearanceConfiguration
    ) async -> EditorEngineDerivedContent? {
        await sourceEditorSession.deriveContent(
            for: markdown,
            configuration: configuration
        )
    }

    func applyFormat(
        _ operation: EditorEngineFormatOperation,
        expectedText: String,
        selectedUTF16Range: NSRange,
        actionName: String
    ) async -> Bool {
        await sourceEditorSession.applyEngineFormat(
            operation,
            expectedText: expectedText,
            selectedUTF16Range: selectedUTF16Range,
            actionName: actionName
        )
    }

    func replaceCurrent(
        utf8Range: Range<Int>,
        with replacement: String,
        expectedText: String
    ) async -> Bool {
        await sourceEditorSession.replaceCurrent(
            utf8Range: utf8Range,
            with: replacement,
            expectedText: expectedText
        )
    }

    func replaceAll(
        utf8Ranges: [Range<Int>],
        with replacement: String,
        expectedText: String
    ) async -> Bool {
        await sourceEditorSession.replaceAll(
            utf8Ranges: utf8Ranges,
            with: replacement,
            expectedText: expectedText
        )
    }

    func search(
        source: String,
        query: String,
        caseSensitive: Bool
    ) async -> DocumentSearchOutcome? {
        await sourceEditorSession.search(
            source: source,
            query: query,
            caseSensitive: caseSensitive
        )
    }

    func persistenceSnapshot() async -> EditorEngineDocumentSnapshot? {
        await sourceEditorSession.persistenceSnapshot()
    }

    func preparePersistenceSave() async -> EditorEngineSavePreparation? {
        await sourceEditorSession.preparePersistenceSave()
    }

    func completePersistenceSave(_ preparation: EditorEngineSavePreparation) async -> Bool {
        await sourceEditorSession.completePersistenceSave(preparation)
    }

    func abortPersistenceSave(_ preparation: EditorEngineSavePreparation) async {
        await sourceEditorSession.abortPersistenceSave(preparation)
    }

    @discardableResult
    func setMode(_ mode: EditorEngineMode) async -> Bool {
        requestedMode = mode
        let previous = modeSynchronizationTask
        let task = Task { @MainActor [sourceEditorSession] in
            _ = await previous?.value
            guard !Task.isCancelled else { return false }
            return await sourceEditorSession.setEngineMode(mode)
        }
        modeSynchronizationTask = task
        guard await task.value else { return false }
        guard requestedMode == mode else { return false }
        state.engineMode = mode
        return true
    }

    func send(_ intent: EditorIntent) {
        switch intent {
        case let .refreshDerived(request):
            refreshDerived(request)
        case let .suspendDerived(markdown):
            suspendDerived(markdown: markdown)
        case .cancelPending:
            derivedContentTask?.cancel()
            derivedContentGeneration &+= 1
            activeDerivedRequest = nil
            latestDerivedRequest = nil
        }
    }

    func prepareForDocumentReplacement() {
        latestDerivedRequest = nil
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        activeDerivedRequest = nil
        completedDerivedRequest = nil
        state.renderedSurfacePhase = .preparing
    }

    private func refreshDerived(_ request: EditorDerivedContentRequest) {
        latestDerivedRequest = request
        if activeDerivedRequest?.hasSameDerivationInput(as: request) == true
            || completedDerivedRequest?.hasSameDerivationInput(as: request) == true
        {
            return
        }
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        let generation = derivedContentGeneration
        activeDerivedRequest = request
        state.analysisState = .updating(previous: state.analysisState.displayedAnalysis)

        derivedContentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if request.delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: request.delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let coreContent = await sourceEditorSession.deriveContent(
                for: request.markdown,
                configuration: request.configuration
            )
            guard !Task.isCancelled else { return }
            guard let coreContent,
                  UTF8Text.isExactlyEqual(coreContent.sourceSnapshot, request.markdown)
            else {
                guard generation == derivedContentGeneration else { return }
                activeDerivedRequest = nil
                completedDerivedRequest = nil
                LocalFailureLogController.shared.record(.previewing, code: .previewFailed)
                state.analysisState = .failed(
                    previous: state.analysisState.displayedAnalysis,
                    message: MarkdownRenderError.coreFailure.localizedDescription
                )
                state.previewFailureMessage = MarkdownRenderError.coreFailure.localizedDescription
                state.renderedSurfacePhase = .fallback(sourceSnapshot: request.markdown)
                return
            }

            guard !Task.isCancelled, generation == derivedContentGeneration else { return }
            activeDerivedRequest = nil
            completedDerivedRequest = request
            renderedPreviewSession.installSharedRenderedPlan(
                coreContent.nativeRenderPlan,
                source: request.markdown
            )
            state = EditorViewState(
                previewSourceSnapshot: coreContent.sourceSnapshot,
                previewFailureMessage: nil,
                analysisState: .ready(coreContent.analysis),
                references: coreContent.references,
                engineMode: state.engineMode,
                renderedSurfacePhase: .ready(sourceSnapshot: coreContent.sourceSnapshot)
            )
            _ = sourceEditorSession.applySyntaxHighlighting(
                request.syntaxHighlightingEnabled
                    ? coreContent.syntaxHighlighting
                    : [],
                source: request.markdown,
                enabled: request.syntaxHighlightingEnabled
            )
        }
    }

    private func suspendDerived(markdown: String) {
        latestDerivedRequest = nil
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        activeDerivedRequest = nil
        completedDerivedRequest = nil
        renderedPreviewSession.installSharedRenderedPlan(nil, source: markdown)
        state = EditorViewState(
            previewSourceSnapshot: "",
            previewFailureMessage: nil,
            analysisState: .ready(.empty),
            references: [],
            engineMode: state.engineMode,
            renderedSurfacePhase: .preparing
        )
        _ = sourceEditorSession.applySyntaxHighlighting(
            [],
            source: markdown,
            enabled: false
        )
    }
}
