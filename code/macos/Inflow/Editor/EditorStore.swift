import SwiftUI

struct EditorViewState: Equatable {
    var previewHTML: String
    var previewSourceSnapshot: String
    var previewFailureMessage: String?
    var analysisState: DocumentAnalysisState
    var references: [MarkdownReference]
    var engineMode: EditorEngineMode

    static let initial = Self(
        previewHTML: MarkdownRenderer.htmlDocument(for: ""),
        previewSourceSnapshot: "",
        previewFailureMessage: nil,
        analysisState: .updating(previous: .empty),
        references: [],
        engineMode: .editable
    )
}

struct EditorDerivedContentRequest: Sendable {
    let markdown: String
    let documentDirectory: URL?
    let projectRoot: URL?
    let expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
    let requiresProjectBoundary: Bool
    let configuration: PreviewAppearanceConfiguration
    let syntaxHighlightingEnabled: Bool
    let delayNanoseconds: UInt64
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
    private let contentDeriver = DocumentContentDeriver()
    private var derivedContentGeneration = 0
    private var derivedContentTask: Task<Void, Never>?
    private var requestedMode: EditorEngineMode
    private var modeSynchronizationTask: Task<Bool, Never>?

    init(
        sourceEditorSession: MarkdownSourceEditorSession,
        initialState: EditorViewState = .initial
    ) {
        self.sourceEditorSession = sourceEditorSession
        state = initialState
        requestedMode = initialState.engineMode
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
        }
    }

    private func refreshDerived(_ request: EditorDerivedContentRequest) {
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        let generation = derivedContentGeneration
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
            guard let content = await contentDeriver.derive(
                request: request,
                coreContent: coreContent
            ) else {
                guard generation == derivedContentGeneration else { return }
                LocalFailureLogController.shared.record(.previewing, code: .previewFailed)
                state.analysisState = .failed(
                    previous: state.analysisState.displayedAnalysis,
                    message: MarkdownRenderError.coreFailure.localizedDescription
                )
                return
            }

            guard !Task.isCancelled, generation == derivedContentGeneration else { return }
            state = EditorViewState(
                previewHTML: content.html,
                previewSourceSnapshot: content.sourceSnapshot,
                previewFailureMessage: content.previewFailureMessage,
                analysisState: .ready(content.analysis),
                references: content.references,
                engineMode: state.engineMode
            )
            _ = sourceEditorSession.applySyntaxHighlighting(
                content.syntaxHighlighting,
                source: request.markdown,
                enabled: request.syntaxHighlightingEnabled
            )
        }
    }

    private func suspendDerived(markdown: String) {
        derivedContentTask?.cancel()
        derivedContentGeneration &+= 1
        state = EditorViewState(
            previewHTML: MarkdownRenderer.htmlDocument(for: ""),
            previewSourceSnapshot: "",
            previewFailureMessage: nil,
            analysisState: .ready(.empty),
            references: [],
            engineMode: state.engineMode
        )
        _ = sourceEditorSession.applySyntaxHighlighting(
            [],
            source: markdown,
            enabled: false
        )
    }
}

private struct DerivedDocumentContent: Sendable {
    let sourceSnapshot: String
    let html: String
    let previewFailureMessage: String?
    let analysis: DocumentAnalysis
    let syntaxHighlighting: [MarkdownSyntaxSpan]
    let references: [MarkdownReference]
}

private actor DocumentContentDeriver {
    func derive(
        request: EditorDerivedContentRequest,
        coreContent: EditorEngineDerivedContent?
    ) -> DerivedDocumentContent? {
        guard !Task.isCancelled,
              let coreContent,
              UTF8Text.isExactlyEqual(coreContent.sourceSnapshot, request.markdown)
        else { return nil }
        let previewDocument = MarkdownRenderer.previewDocument(
            coreFragment: coreContent.htmlFragment,
            references: coreContent.references,
            documentDirectory: request.documentDirectory,
            projectRoot: request.projectRoot,
            expectedProjectRootIdentity: request.expectedProjectRootIdentity,
            requiresProjectBoundary: request.requiresProjectBoundary,
            configuration: request.configuration
        )
        return DerivedDocumentContent(
            sourceSnapshot: request.markdown,
            html: previewDocument.html,
            previewFailureMessage: previewDocument.failureMessage,
            analysis: coreContent.analysis,
            syntaxHighlighting: request.syntaxHighlightingEnabled
                ? coreContent.syntaxHighlighting
                : [],
            references: coreContent.references
        )
    }
}
