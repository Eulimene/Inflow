import SwiftUI

struct EditorViewState: Equatable {
    var previewHTML: String
    var previewSourceSnapshot: String
    var previewFailureMessage: String?
    var analysisState: DocumentAnalysisState
    var references: [MarkdownReference]

    static let initial = Self(
        previewHTML: MarkdownRenderer.htmlDocument(for: ""),
        previewSourceSnapshot: "",
        previewFailureMessage: nil,
        analysisState: .updating(previous: .empty),
        references: []
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

    init(
        sourceEditorSession: MarkdownSourceEditorSession,
        initialState: EditorViewState = .initial
    ) {
        self.sourceEditorSession = sourceEditorSession
        state = initialState
    }

    deinit {
        derivedContentTask?.cancel()
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
                references: content.references
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
            references: []
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
