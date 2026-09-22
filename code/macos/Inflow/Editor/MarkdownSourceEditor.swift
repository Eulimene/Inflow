import AppKit
import SwiftUI

enum MarkdownSourceEditorSessionRole: Equatable {
    case document
    case renderedProjection
}

fileprivate enum RenderedMarkdownImagePlacement: Equatable {
    case replacesSource
    case belowSource
}

@MainActor
final class MarkdownSourceEditorSession: NSObject, ObservableObject {
    let scrollView: NSScrollView
    let textView: WindowAwareTextView
    @Published private(set) var selectedUTF16Range = NSRange(location: 0, length: 0)
    @Published private(set) var canClearFormat = false
    @Published private(set) var verticalScrollOffset = 0.0
    @Published private(set) var verticalScrollFraction = 0.0
    fileprivate var appliedSelectionGeneration: Int?
    fileprivate var pendingSelectionRequest: SourceSelectionRequest?
    fileprivate var pendingRestorationState: MarkdownRestorationState?
    var updateBoundText: ((String) -> Void)?
    var localTextProjectionDidPublish: ((String) -> Void)?
    var resolvedMermaidPlanDidPublish: ((RenderedMarkdownPlan, String) -> Void)?
    var deferredMermaidResolver: (@Sendable (
        String,
        PreviewAppearanceConfiguration
    ) async -> EditorEngineMermaidResolution?)?
    private(set) var sourceAppearance = SourceEditorAppearance.default
    private var hasAppliedSourceAppearance = false
    private var syntaxHighlightingEnabled = false
    private var syntaxHighlightingSource = ""
    private var syntaxHighlightingSourceUTF8 = Data()
    private var syntaxHighlightingSpans: [MarkdownSyntaxSpan] = []
    private var syntaxApplicationGeneration = 0
    private var syntaxApplicationTask: Task<Void, Never>?
    private var syntaxApplicationIsComplete = true
    private(set) var lastSyntaxDirtyUTF16Ranges: [NSRange] = []
    private var presentation = MarkdownEditorPresentation.source
    private var renderedPlan: RenderedMarkdownPlan?
    private var optimisticTable: (source: String, table: RenderedMarkdownTable)?
    private var engineRenderedPlan: RenderedMarkdownPlan?
    private var renderedEditingRange: NSRange?
    private var renderedAppliedAppearance: SourceEditorAppearance?
    private var renderedTheme = PreviewTheme.standard
    private var renderedAppliedTheme: PreviewTheme?
    private var renderedLinkHandler: ((String) -> Void)?
    private var renderedLinkActivation = LinkActivationPreference.singleClick
    private var renderedResourceContext = RenderedMarkdownResourceContext.unavailable
    private var renderedImageGeneration = 0
    private var renderedImageTask: Task<Void, Never>?
    private var deferredMermaidGeneration = 0
    private var deferredMermaidTask: Task<Void, Never>?
    private var javaScriptResourcesTask: Task<Void, Never>?
    private var javaScriptResults: [String: JavaScriptRenderedOutput] = [:]
    private var javaScriptFailures: Set<String> = []
    private var javaScriptSnapshot = ""

    private var renderedRevealedMarkers: [NSRange] = []
    private var renderedInteractionTask: Task<Void, Never>?
    private let lineNumberRuler: MarkdownLineNumberRulerView
    private let engineClient: EditorEngineClient
    private var formatInspectionGeneration = 0
    private var formatInspectionTask: Task<Void, Never>?
    private var isApplyingEngineMutation = false
    private var pendingOptimisticText: String?
    private var deferredCompositionSnapshot: EditorEngineDocumentSnapshot?
    private var focusModeEnabled = false
    private var typewriterModeEnabled = false
    private var configuredLineWrapping: Bool?
    private let role: MarkdownSourceEditorSessionRole
    private(set) var renderedPresentationPassCount = 0
    private(set) var renderedAttributePatchRanges: [NSRange] = []
    private(set) var renderedMermaidPatchCount = 0

    override convenience init() {
        self.init(role: .document)
    }

    init(role: MarkdownSourceEditorSessionRole) {
        self.role = role
        engineClient = EditorEngineClient()
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = WindowAwareTextView(frame: scrollView.contentView.bounds)
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = role == .document
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(
            width: MarkdownRenderMetrics.editorHorizontalInset,
            height: MarkdownRenderMetrics.editorVerticalInset
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = false
        textView.setAccessibilityLabel("Markdown 源码编辑器")
        textView.registerForDraggedTypes([.fileURL])

        let lineNumberRuler = MarkdownLineNumberRulerView(
            textView: textView,
            scrollView: scrollView
        )
        scrollView.documentView = textView
        scrollView.verticalRulerView = lineNumberRuler
        self.scrollView = scrollView
        self.textView = textView
        self.lineNumberRuler = lineNumberRuler
        super.init()
        textView.usesEngineHistory = role == .document
        textView.allowsUndo = false
        textView.undoManager?.disableUndoRegistration()
        textView.engineUndoHandler = { [weak self] in
            self?.performEngineHistory(.undo)
        }
        textView.engineRedoHandler = { [weak self] in
            self?.performEngineHistory(.redo)
        }
        engineClient.onHistoryStateChange = { [weak textView] canUndo, canRedo in
            textView?.engineCanUndo = canUndo
            textView?.engineCanRedo = canRedo
        }
        engineClient.onAuthoritativeSnapshot = { [weak self] snapshot in
            self?.applyAuthoritativeSnapshot(snapshot)
        }
        textView.compositionDidEndHandler = { [weak self] text, selection, changed in
            guard let self, self.role == .document else { return }
            if changed || self.pendingOptimisticText != nil {
                self.pendingOptimisticText = text
                self.engineClient.submit(text: text, selectionUTF16: selection)
            }
            let deferred = self.deferredCompositionSnapshot
            self.deferredCompositionSnapshot = nil
            if let deferred, UTF8Text.isExactlyEqual(deferred.text, text) {
                self.applyAuthoritativeSnapshot(deferred)
            }
            self.syncRenderedTypingAttributes()
            self.scheduleRenderedPresentation(for: text)
        }
        textView.textDidChangeHandler = { [weak self] text in
            guard let self, self.role == .document else { return }
            if !self.isApplyingEngineMutation, !self.textView.hasActiveComposition {
                self.pendingOptimisticText = text
                self.engineClient.submit(
                    text: text,
                    selectionUTF16: self.textView.selectedRange(),
                    groupID: self.textView.consumeEngineEditGroupID()
                )
            } else {
                _ = self.textView.consumeEngineEditGroupID()
            }
            self.invalidateSyntaxApplication()
            self.cancelDeferredMermaidRendering()
            self.scheduleFormatInspection()
            self.lineNumberRuler.updateText(text)
            self.refreshWritingModePresentation()
            self.scheduleRenderedPresentation(for: text)
        }
        textView.focusDidChangeHandler = { [weak self] in
            self?.scheduleRenderedInteractionPresentation()
        }
        textView.selectionVisibilityHandler = { [weak self] in self?.centerSelectionForTypewriterMode() }
        textView.effectiveAppearanceDidChangeHandler = { [weak self] in
            guard let self, self.presentation == .rendered else { return }
            self.applyRenderedPresentation(source: self.textView.string, force: true)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerChangedText),
            name: .NSUndoManagerDidUndoChange,
            object: textView.undoManager
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerChangedText),
            name: .NSUndoManagerDidRedoChange,
            object: textView.undoManager
        )
        applySourceAppearance(.default)
    }

    func applySourceAppearance(_ appearance: SourceEditorAppearance, force: Bool = false) {
        guard !textView.hasActiveComposition else { return }
        guard force || !hasAppliedSourceAppearance || sourceAppearance != appearance else { return }
        sourceAppearance = appearance
        textView.markdownAutoPairEnabled = appearance.autoPairEnabled
        hasAppliedSourceAppearance = true
        renderedAppliedAppearance = nil

        let selection = textView.selectedRange()
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(appearance.fontSize),
            weight: .regular
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = CGFloat(appearance.lineHeight)

        let undoManager = textView.undoManager
        let shouldRestoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                undoManager?.enableUndoRegistration()
            }
        }

        textView.font = font
        textView.defaultParagraphStyle = paragraphStyle
        textView.isContinuousSpellCheckingEnabled = appearance.spellingEnabled
        configureLineWrapping(appearance.wrapsLines)
        scrollView.hasVerticalRuler = appearance.showsLineNumbers
        scrollView.rulersVisible = appearance.showsLineNumbers
        lineNumberRuler.updateText(textView.string)
        textView.typingAttributes[.font] = font
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        if let textStorage = textView.textStorage, textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.setAttributes(
                [
                    .font: font,
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraphStyle,
                ],
                range: NSRange(location: 0, length: textStorage.length)
            )
            textStorage.endEditing()
        }
        textView.setSelectedRange(selection)
        scheduleCachedSyntaxHighlighting(baseFont: font)
        refreshWritingModePresentation()
    }

    func deriveContent(
        for source: String,
        configuration: PreviewAppearanceConfiguration
    ) async -> EditorEngineDerivedContent? {
        textView.readingColumnWidth = CGFloat(configuration.contentWidth)
        cancelDeferredMermaidRendering()
        deferredMermaidGeneration &+= 1
        let mermaidGeneration = deferredMermaidGeneration
        guard let content = await engineClient.derive(
            text: source,
            selectionUTF16: textView.selectedRange(),
            configuration: configuration,
            deferMermaid: configuration.mermaidRenderingEnabled
        ) else { return nil }
        guard content.nativeRenderPlan.exactlyMatches(source) else { return nil }
        let planChanged = engineRenderedPlan != content.nativeRenderPlan
        engineRenderedPlan = content.nativeRenderPlan
        if presentation == .rendered,
           UTF8Text.isExactlyEqual(textView.string, source),
           !textView.hasActiveComposition,
           planChanged || !renderedPresentationIsCurrent(source: source)
        {
            applyRenderedPresentation(source: source, force: planChanged)
        }
        if content.mermaidDeferred,
           content.nativeRenderPlan.mermaidDiagrams.contains(where: \.isPlaceholder)
        {
            scheduleDeferredMermaidRendering(
                source: source,
                configuration: configuration,
                generation: mermaidGeneration
            )
        }
        if presentation == .source, syntaxHighlightingEnabled {
            scheduleJavaScriptResources(for: content.nativeRenderPlan)
        }
        return content
    }

    /// Waits until the native surface has resolved the resources scheduled by
    /// the current render pass. Export uses this instead of maintaining a
    /// separate HTML loading lifecycle.
    func waitForRenderedResources() async {
        await deferredMermaidTask?.value
        await javaScriptResourcesTask?.value
        await renderedImageTask?.value
        await Task.yield()
        textView.layoutSubtreeIfNeeded()
        textView.layoutRenderedImages()
    }

    /// Installs the already-derived native plan in another TextKit surface.
    ///
    /// Split view owns two NSTextViews because one view cannot be mounted in two
    /// places at once. They deliberately share this exact immutable render plan
    /// instead of asking a second renderer (or a second parser) to interpret the
    /// Markdown again.
    func installSharedRenderedPlan(
        _ plan: RenderedMarkdownPlan?,
        source: String
    ) {
        guard let plan else {
            engineRenderedPlan = nil
            return
        }
        guard plan.exactlyMatches(source) else { return }
        if let currentPlan = engineRenderedPlan,
           currentPlan.hasSameNonMermaidProjection(as: plan),
           currentPlan.mermaidDiagrams.map(\.sourceRange)
               == plan.mermaidDiagrams.map(\.sourceRange),
           currentPlan.mermaidDiagrams.allSatisfy({ !$0.isPlaceholder }),
           plan.mermaidDiagrams.contains(where: \.isPlaceholder)
        {
            // A fast placeholder snapshot can arrive after the detached renderer
            // has already published the completed SVG. Never let delivery order
            // downgrade a resolved projection back to its loading state.
            return
        }
        let planChanged = engineRenderedPlan != plan
        engineRenderedPlan = plan
        if role == .renderedProjection,
           !UTF8Text.isExactlyEqual(textView.string, source)
        {
            let selection = textView.selectedRange()
            isApplyingEngineMutation = true
            textView.string = source
            isApplyingEngineMutation = false
            let utf16Length = (source as NSString).length
            textView.setSelectedRange(
                NSRange(location: min(selection.location, utf16Length), length: 0)
            )
            invalidateSyntaxApplication()
            lineNumberRuler.updateText(source)
        }
        guard presentation == .rendered,
              UTF8Text.isExactlyEqual(textView.string, source),
              !textView.hasActiveComposition
        else { return }
        guard planChanged || !renderedPresentationIsCurrent(source: source) else { return }
        applyRenderedPresentation(source: source, force: planChanged)
    }

    @discardableResult
    func applyEngineFormat(
        _ operation: EditorEngineFormatOperation,
        expectedText: String,
        selectedUTF16Range: NSRange,
        actionName: String
    ) async -> Bool {
        guard textView.isEditable,
              !textView.hasActiveComposition,
              UTF8Text.isExactlyEqual(textView.string, expectedText)
        else { return false }
        guard let mutation = await engineClient.format(
            text: expectedText,
            selectionUTF16: selectedUTF16Range,
            operation: operation
        ) else { return false }
        let plan = MarkdownFormatPlan(
            sourceSnapshot: mutation.sourceSnapshot,
            replaceUTF8Range: mutation.replaceUTF8Range,
            replacement: mutation.replacement,
            resultingSource: mutation.resultingSource,
            selectionUTF8Range: mutation.selectionUTF8Range
        )
        return applyEngineMutation(mutation, plan: plan, actionName: actionName)
    }

    private enum EngineHistoryAction {
        case undo
        case redo
    }

    private func performEngineHistory(_ action: EngineHistoryAction) {
        guard !textView.hasActiveComposition, !isApplyingEngineMutation else { return }
        let source = textView.string
        let selection = textView.selectedRange()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mutation: EditorEngineMutation?
            switch action {
            case .undo:
                mutation = await self.engineClient.undo(
                    text: source,
                    selectionUTF16: selection
                )
            case .redo:
                mutation = await self.engineClient.redo(
                    text: source,
                    selectionUTF16: selection
                )
            }
            guard let mutation else { return }
            _ = self.applyEngineMutation(mutation, plan: nil, actionName: nil)
        }
    }

    @discardableResult
    private func applyEngineMutation(
        _ mutation: EditorEngineMutation,
        plan: MarkdownFormatPlan?,
        actionName _: String?
    ) -> Bool {
        guard textView.isEditable,
              !textView.hasActiveComposition,
              UTF8Text.isExactlyEqual(textView.string, mutation.sourceSnapshot),
              let replacementTarget = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: mutation.replaceUTF8Range,
                  in: mutation.sourceSnapshot
              ),
              let finalSelection = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: mutation.selectionUTF8Range,
                  in: mutation.resultingSource
              ),
              plan == nil || (
                  plan?.sourceSnapshot == mutation.sourceSnapshot
                      && plan?.replaceUTF8Range == mutation.replaceUTF8Range
                      && plan?.replacement == mutation.replacement
                      && plan?.resultingSource == mutation.resultingSource
                      && plan?.selectionUTF8Range == mutation.selectionUTF8Range
              )
        else { return false }

        let undoManager = textView.undoManager
        let restoresUndo = undoManager?.isUndoRegistrationEnabled == true
        if restoresUndo { undoManager?.disableUndoRegistration() }
        isApplyingEngineMutation = true
        defer {
            isApplyingEngineMutation = false
            if restoresUndo { undoManager?.enableUndoRegistration() }
        }
        textView.insertText(
            mutation.replacement,
            replacementRange: replacementTarget.revealRange
        )
        guard UTF8Text.isExactlyEqual(textView.string, mutation.resultingSource) else {
            return false
        }
        textView.setSelectedRange(finalSelection.revealRange)
        updateSelectedRange(finalSelection.revealRange)
        textView.scrollRangeToVisible(finalSelection.revealRange)
        pendingOptimisticText = nil
        updateBoundText?(mutation.resultingSource)
        localTextProjectionDidPublish?(mutation.resultingSource)
        return true
    }

    private func applyAuthoritativeSnapshot(_ snapshot: EditorEngineDocumentSnapshot) {
        guard !isApplyingEngineMutation else { return }
        if textView.hasActiveComposition {
            deferredCompositionSnapshot = snapshot
            return
        }
        guard let selection = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: snapshot.selectionUTF8Range,
                  in: snapshot.text
              )
        else { return }

        if !UTF8Text.isExactlyEqual(textView.string, snapshot.text) {
            let undoManager = textView.undoManager
            let restoresUndo = undoManager?.isUndoRegistrationEnabled == true
            if restoresUndo { undoManager?.disableUndoRegistration() }
            isApplyingEngineMutation = true
            textView.string = snapshot.text
            textView.setSelectedRange(selection.revealRange)
            isApplyingEngineMutation = false
            if restoresUndo { undoManager?.enableUndoRegistration() }

            invalidateSyntaxApplication()
            updateSelectedRange(selection.revealRange)
            lineNumberRuler.updateText(snapshot.text)
            refreshWritingModePresentation()
            scheduleRenderedPresentation(for: snapshot.text)
        }
        let publishesOptimisticText = pendingOptimisticText.map {
            UTF8Text.isExactlyEqual($0, snapshot.text)
        } == true
        pendingOptimisticText = nil
        updateBoundText?(snapshot.text)
        if publishesOptimisticText {
            localTextProjectionDidPublish?(snapshot.text)
        }
    }

    func authoritativeSnapshot() async -> EditorEngineDocumentSnapshot? {
        guard !textView.hasActiveComposition else { return nil }
        return await engineClient.authoritativeSnapshot(
            matching: textView.string,
            selectionUTF16: textView.selectedRange()
        )
    }

    func search(
        source: String,
        query: String,
        caseSensitive: Bool
    ) async -> DocumentSearchOutcome? {
        guard !textView.hasActiveComposition, !Task.isCancelled else { return nil }
        guard let result = await engineClient.search(
            text: source,
            selectionUTF16: textView.selectedRange(),
            query: query,
            caseSensitive: caseSensitive
        ) else {
            return .failure(MarkdownSearchError.coreFailure.localizedDescription)
        }
        guard !Task.isCancelled else { return nil }
        return .success(result)
    }

    func persistenceSnapshot() async -> EditorEngineDocumentSnapshot? {
        if textView.hasMarkedText() {
            textView.unmarkText()
            await Task.yield()
        }
        return await authoritativeSnapshot()
    }

    func preparePersistenceSave() async -> EditorEngineSavePreparation? {
        if textView.hasMarkedText() {
            textView.unmarkText()
            await Task.yield()
        }
        guard !textView.hasActiveComposition else { return nil }
        return await engineClient.prepareSave(
            text: textView.string,
            selectionUTF16: textView.selectedRange()
        )
    }

    func completePersistenceSave(_ preparation: EditorEngineSavePreparation) async -> Bool {
        await engineClient.saveCompleted(preparation)
    }

    func abortPersistenceSave(_ preparation: EditorEngineSavePreparation) async {
        await engineClient.saveAborted(preparation)
    }

    func setEngineMode(_ mode: EditorEngineMode) async -> Bool {
        if textView.hasMarkedText() {
            textView.unmarkText()
            await Task.yield()
        }
        guard !textView.hasActiveComposition else { return false }
        return await engineClient.setMode(
            mode,
            text: textView.string,
            selectionUTF16: textView.selectedRange()
        )
    }

    func setPresentation(
        _ presentation: MarkdownEditorPresentation,
        source: String,
        onLinkClick: ((String) -> Void)?,
        resourceContext: RenderedMarkdownResourceContext = .unavailable,
        linkActivation: LinkActivationPreference = .singleClick,
        theme: PreviewTheme = .standard
    ) {
        guard !textView.hasActiveComposition else { return }
        let changed = self.presentation != presentation
        let resourceContextChanged = renderedResourceContext != resourceContext
        let linkActivationChanged = renderedLinkActivation != linkActivation
        let themeChanged = renderedTheme != theme
        self.presentation = presentation
        textView.isLiveMarkdown = presentation == .rendered
        renderedLinkHandler = onLinkClick
        renderedLinkActivation = linkActivation
        renderedTheme = theme
        textView.linkActivation = linkActivation
        renderedResourceContext = resourceContext
        switch presentation {
        case .source:
            renderedInteractionTask?.cancel()
            renderedInteractionTask = nil
            cancelRenderedImageLoading()
            cancelDeferredMermaidRendering()
            renderedPlan = nil
            textView.writingPlan = nil
            renderedRevealedMarkers = []
            renderedEditingRange = nil
            textView.linkClickHandler = nil
            textView.clickableLinkRanges = []
            textView.clearRenderedImages()
            textView.renderedQuoteRanges = []
            textView.renderedInlineCodeRanges = []
            textView.renderedCodeBlockRanges = []
            textView.renderedHeadingDividerRanges = []
            textView.renderedReplacementMarkers = []
            textView.renderedRuleRanges = []
            textView.renderedCollapsedSourceRanges = []
            textView.renderedAnchorSourceRanges = []
            textView.setAccessibilityLabel("Markdown 源码编辑器")
            applySourceAppearance(sourceAppearance, force: changed)
            if syntaxHighlightingEnabled, let plan = engineRenderedPlan {
                scheduleJavaScriptResources(for: plan)
            }
        case .rendered:
            configureLineWrapping(true)
            textView.setAccessibilityLabel("Markdown 即时编辑器")
            textView.linkClickHandler = { [weak self] location in
                guard let self,
                      let renderedPlan = self.renderedPlan,
                      let link = RenderedMarkdownEditor.clickTarget(
                          atUTF16Location: location,
                          currentSource: self.textView.string,
                          plan: renderedPlan
                      )
                else {
                    return false
                }
                self.renderedLinkHandler?(link.target)
                return true
            }
            applyRenderedPresentation(
                source: source,
                force: changed
                    || resourceContextChanged
                    || linkActivationChanged
                    || themeChanged
                    || !renderedPresentationIsCurrent(source: source)
            )
        }
    }

    func installResolvedMermaidPlan(
        _ plan: RenderedMarkdownPlan,
        source: String
    ) {
        guard plan.exactlyMatches(source) else { return }
        if role == .renderedProjection,
           !UTF8Text.isExactlyEqual(textView.string, source)
        {
            // The detached renderer can finish before the store delivers the
            // corresponding placeholder snapshot to the split preview. Install
            // the completed snapshot directly; a later placeholder is rejected
            // by installSharedRenderedPlan instead of causing a visible rewind.
            installSharedRenderedPlan(plan, source: source)
            return
        }
        guard UTF8Text.isExactlyEqual(textView.string, source) else { return }
        let previousPlan = engineRenderedPlan
        engineRenderedPlan = plan
        guard presentation == .rendered,
              !textView.hasActiveComposition,
              let previousPlan,
              previousPlan.hasSameNonMermaidProjection(as: plan),
              previousPlan.mermaidDiagrams.map(\.sourceRange)
                == plan.mermaidDiagrams.map(\.sourceRange),
              previousPlan.mermaidDiagrams.allSatisfy(\.isPlaceholder),
              plan.mermaidDiagrams.allSatisfy({ !$0.isPlaceholder })
        else {
            if presentation == .rendered {
                applyRenderedPresentation(source: source, force: true)
            }
            return
        }
        applyResolvedMermaidOverlays(plan, source: source)
    }

    private func scheduleDeferredMermaidRendering(
        source: String,
        configuration: PreviewAppearanceConfiguration,
        generation: Int
    ) {
        deferredMermaidTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == deferredMermaidGeneration {
                    deferredMermaidTask = nil
                }
            }
            let resolved = if let deferredMermaidResolver {
                await deferredMermaidResolver(source, configuration)
            } else {
                await engineClient.resolveDeferredMermaid(
                    source: source,
                    configuration: configuration
                )
            }
            guard !Task.isCancelled,
                  generation == deferredMermaidGeneration,
                  let resolved,
                  UTF8Text.isExactlyEqual(textView.string, source),
                  let placeholderPlan = engineRenderedPlan,
                  let resolvedPlan = placeholderPlan.resolvingMermaid(with: resolved)
            else { return }
            installResolvedMermaidPlan(resolvedPlan, source: source)
            resolvedMermaidPlanDidPublish?(resolvedPlan, source)
        }
    }

    private func cancelDeferredMermaidRendering() {
        deferredMermaidGeneration &+= 1
        deferredMermaidTask?.cancel()
        deferredMermaidTask = nil
    }

    private func scheduleRenderedPresentation(for source: String) {
        guard presentation == .rendered else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.presentation == .rendered,
                  UTF8Text.isExactlyEqual(self.textView.string, source)
            else {
                return
            }
            guard !self.renderedPresentationIsCurrent(source: source) else { return }
            self.applyRenderedPresentation(source: source, force: true)
        }
    }

    private func scheduleRenderedInteractionPresentation() {
        guard presentation == .rendered else { return }
        renderedInteractionTask?.cancel()
        renderedInteractionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.presentation == .rendered
            else { return }
            guard !self.renderedPresentationIsCurrent(source: self.textView.string) else {
                self.renderedInteractionTask = nil
                return
            }
            self.applyRenderedPresentation(source: self.textView.string, force: true)
            self.renderedInteractionTask = nil
        }
    }

    private func renderedPresentationIsCurrent(source: String) -> Bool {
        renderedPlan?.exactlyMatches(source) == true
            && renderedAppliedAppearance == sourceAppearance
            && renderedAppliedTheme == renderedTheme
            && currentRenderedEditingRange(source: source) == renderedEditingRange
            && activeRevealedMarkers() == renderedRevealedMarkers
    }

    private func activeRevealedMarkers() -> [NSRange] {
        guard textView.isEditable, textView.window?.firstResponder === textView,
              let plan = renderedPlan, plan.exactlyMatches(textView.string) else { return [] }
        return MarkdownWritingRules.revealedMarkers(plan: plan, selection: textView.selectedRange())
    }

    private func currentRenderedEditingRange(source: String) -> NSRange? {
        guard presentation == .rendered,
              textView.isEditable,
              textView.window?.firstResponder === textView,
              let renderedPlan,
              renderedPlan.exactlyMatches(source)
        else {
            return nil
        }
        return RenderedMarkdownEditor.sourceEditingBlockRange(
            containingUTF16Location: textView.selectedRange().location,
            source: source,
            plan: renderedPlan
        )
    }

    private func applyRenderedPresentation(source: String, force: Bool) {
        guard presentation == .rendered,
              UTF8Text.isExactlyEqual(textView.string, source),
              !textView.hasActiveComposition
        else {
            return
        }
        let selection = textView.selectedRange()
        if !force,
           renderedPlan?.exactlyMatches(source) == true,
           renderedAppliedAppearance == sourceAppearance,
           renderedAppliedTheme == renderedTheme
        {
            return
        }

        invalidateSyntaxApplication()
        guard let plan = engineRenderedPlan,
              plan.exactlyMatches(source)
        else { return }
        renderedPlan = plan
        textView.writingPlan = plan
        renderedRevealedMarkers = activeRevealedMarkers()
        let editingRange: NSRange? = if textView.isEditable,
                                       textView.window?.firstResponder === textView
        {
            RenderedMarkdownEditor.sourceEditingBlockRange(
                containingUTF16Location: selection.location,
                source: source,
                plan: plan
            )
        } else {
            nil
        }
        renderedEditingRange = editingRange
        textView.clickableLinkRanges = plan.links.compactMap { link in
            let range = link.textRange.utf16Range
            return range
        }
        textView.beginRenderedOverlayUpdate()
        textView.renderedQuoteRanges = RenderedMarkdownQuoteGeometry.contiguousRanges(plan.contentStyles.compactMap { style in
            guard style.kind == .blockQuote else { return nil }
            guard !rangesOverlap(style.sourceRange.utf16Range, editingRange) else { return nil }
            return (source as NSString).paragraphRange(for: style.sourceRange.utf16Range)
        })
        textView.renderedInlineCodeRanges = plan.contentStyles.compactMap { style in
            guard style.kind == .inlineCode,
                  !rangesOverlap(style.sourceRange.utf16Range, editingRange)
            else { return nil }
            return style.sourceRange.utf16Range
        }
        textView.renderedHeadingDividerRanges = plan.contentStyles.compactMap { style in
            guard case let .heading(level) = style.kind,
                  level <= 2,
                  !rangesOverlap(style.sourceRange.utf16Range, editingRange)
            else { return nil }
            return (source as NSString).paragraphRange(for: style.sourceRange.utf16Range)
        }
        textView.renderedCodeBlockRanges = plan.localSourceBlocks.compactMap { block in
            guard block.reasons.contains(.fencedCode),
                  let parts = fencedCodeParts(
                      in: block.sourceRange.utf16Range,
                      source: source
                  )
            else { return nil }
            return rangesOverlap(block.sourceRange.utf16Range, editingRange)
                ? block.sourceRange.utf16Range
                : parts.content
        }
        scrollView.hasVerticalRuler = false
        scrollView.rulersVisible = false

        let baseFont = renderedBaseFont()
        textView.renderedReplacementBaseFont = baseFont
        textView.renderedReplacementMarkers = plan.markers.filter { marker in
            marker.replacementText != nil
                && !rangesOverlap(marker.sourceRange.utf16Range, editingRange)
        }
        textView.renderedRuleRanges = plan.markers.compactMap { marker in
            marker.kind == .rule && !rangesOverlap(marker.sourceRange.utf16Range, editingRange)
                ? marker.sourceRange.utf16Range
                : nil
        }
        let anchoredRanges = plan.markers.compactMap { marker -> NSRange? in
            guard marker.replacementText != nil || marker.kind == .rule,
                  !rangesOverlap(marker.sourceRange.utf16Range, editingRange)
            else { return nil }
            return marker.sourceRange.utf16Range
        } + plan.images.compactMap { image in
            rangesOverlap(image.sourceRange.utf16Range, editingRange)
                ? nil : image.sourceRange.utf16Range
        } + plan.tables.compactMap { table in
            rangesOverlap(table.sourceRange.utf16Range, editingRange)
                ? nil : table.sourceRange.utf16Range
        } + plan.mermaidDiagrams.compactMap { diagram in
            rangesOverlap(diagram.sourceRange.utf16Range, editingRange)
                ? nil : diagram.sourceRange.utf16Range
        }
        let mathAnchors = plan.renderRequests.compactMap { request -> NSRange? in
            guard request.kind == "math", javaScriptResults[request.cacheKey]?.svg != nil,
                  !rangesOverlap(request.sourceRange.utf16Range, editingRange) else { return nil }
            return request.sourceRange.utf16Range
        }
        var collapsedRanges = plan.markers.compactMap { marker -> NSRange? in
            if renderedRevealedMarkers.contains(marker.sourceRange.utf16Range) { return nil }
            if marker.kind == .mathDelimiter,
               plan.renderRequests.contains(where: { request in
                   request.kind == "math" && javaScriptResults[request.cacheKey]?.svg == nil
                       && NSIntersectionRange(request.sourceRange.utf16Range, marker.sourceRange.utf16Range).length > 0
               }) { return nil }
            guard !marker.kind.remainsVisibleWhenInactive,
                  !rangesOverlap(marker.sourceRange.utf16Range, editingRange)
            else { return nil }
            return marker.sourceRange.utf16Range
        } + anchoredRanges + mathAnchors
        collapsedRanges += plan.localSourceBlocks.flatMap { block -> [NSRange] in
            guard block.reasons.contains(.fencedCode),
                  !rangesOverlap(block.sourceRange.utf16Range, editingRange),
                  let parts = fencedCodeParts(in: block.sourceRange.utf16Range, source: source)
            else { return [] }
            return [parts.opening, parts.closing].filter { $0.length > 0 }
        }
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.minimumLineHeight = baseFont.pointSize * CGFloat(sourceAppearance.lineHeight)
        baseParagraph.paragraphSpacing = 0
        let palette = MarkdownRenderPalette.resolved(for: textView.effectiveAppearance)
        if textView.string.isEmpty { textView.font = baseFont }
        textView.defaultParagraphStyle = baseParagraph
        textView.linkTextAttributes = MarkdownLinkVisualStyle.restingAttributes(
            foregroundColor: palette.accentColor
        )
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: palette.textColor,
            .paragraphStyle: baseParagraph,
        ]

        guard let liveStorage = textView.textStorage else { return }
        let storage = NSTextStorage(string: source)
        let fullRange = NSRange(location: 0, length: storage.length)
        let undoManager = textView.undoManager
        let restoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if restoreUndoRegistration { undoManager?.disableUndoRegistration() }
        defer {
            if restoreUndoRegistration { undoManager?.enableUndoRegistration() }
        }

        storage.beginEditing()
        storage.setAttributes(
            [
                .font: baseFont,
                .foregroundColor: palette.textColor,
                .paragraphStyle: baseParagraph,
            ],
            range: fullRange
        )
        applyCompactParagraphGaps(source: source, storage: storage)
        for style in plan.contentStyles {
            let range = style.sourceRange.utf16Range
            guard NSMaxRange(range) <= storage.length,
                  !rangesOverlap(range, editingRange)
            else { continue }
            applyRenderedAttributes(
                for: style.kind,
                range: range,
                storage: storage,
                baseFont: baseFont
            )
        }
        if let editingRange,
           editingRange.length > 0,
           NSMaxRange(editingRange) <= storage.length
        {
            let editingParagraph = NSMutableParagraphStyle()
            editingParagraph.lineHeightMultiple = CGFloat(sourceAppearance.lineHeight)
            editingParagraph.paragraphSpacing = 0
            storage.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: max(13, CGFloat(sourceAppearance.fontSize)),
                        weight: .regular
                    ),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.clear,
                    .paragraphStyle: editingParagraph,
                ],
                range: editingRange
            )
        }
        for block in plan.localSourceBlocks {
            let range = block.sourceRange.utf16Range
            guard NSMaxRange(range) <= storage.length else { continue }
            if block.reasons.contains(.fencedCode),
               !rangesOverlap(range, editingRange),
               let parts = fencedCodeParts(in: range, source: source)
            {
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: max(
                                13,
                                CGFloat(sourceAppearance.fontSize)
                                    * CGFloat(MarkdownRenderMetrics.inlineCodeScale)
                            ),
                            weight: .regular
                        ),
                        .foregroundColor: palette.textColor,
                        .backgroundColor: NSColor.clear,
                    ],
                    range: parts.content
                )
                let codeParagraph = NSMutableParagraphStyle()
                codeParagraph.lineHeightMultiple = MarkdownRenderMetrics.codeBlockLineHeight
                codeParagraph.lineBreakMode = .byCharWrapping
                codeParagraph.firstLineHeadIndent = MarkdownRenderMetrics.tableCellHorizontalPadding
                codeParagraph.headIndent = MarkdownRenderMetrics.tableCellHorizontalPadding
                codeParagraph.tailIndent = -MarkdownRenderMetrics.tableCellHorizontalPadding
                storage.addAttribute(
                    .paragraphStyle,
                    value: codeParagraph,
                    range: parts.content
                )
                for fence in [parts.opening, parts.closing] where fence.length > 0 {
                    storage.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: 0.1),
                            .foregroundColor: NSColor.clear,
                            .backgroundColor: NSColor.clear,
                        ],
                        range: fence
                    )
                }
                continue
            }
            storage.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: max(13, CGFloat(sourceAppearance.fontSize) - 1),
                        weight: .regular
                    ),
                    .foregroundColor: palette.textColor,
                    .backgroundColor: NSColor.clear,
                ],
                range: range
            )
        }
        for marker in plan.markers {
            if renderedRevealedMarkers.contains(marker.sourceRange.utf16Range) { continue }
            if marker.kind == .mathDelimiter,
               plan.renderRequests.contains(where: { request in
                   request.kind == "math" && javaScriptResults[request.cacheKey]?.svg == nil
                       && NSIntersectionRange(request.sourceRange.utf16Range, marker.sourceRange.utf16Range).length > 0
               }) { continue }

            let range = marker.sourceRange.utf16Range
            guard NSMaxRange(range) <= storage.length,
                  !plan.localSourceBlocks.contains(where: {
                      NSIntersectionRange($0.sourceRange.utf16Range, range).length > 0
                  })
            else {
                continue
            }
            if rangesOverlap(range, editingRange) { continue }
            if marker.replacementText != nil {
                applyRenderedReplacement(marker, storage: storage, baseFont: baseFont)
                continue
            }
            if marker.kind == .rule {
                applyRenderedRule(range, storage: storage, baseFont: baseFont)
                continue
            }
            if marker.kind.remainsVisibleWhenInactive {
                let markerFont: NSFont
                let markerColor: NSColor
                if marker.kind == .orderedList {
                    markerFont = baseFont
                    markerColor = palette.textColor
                } else {
                    markerFont = NSFont.monospacedSystemFont(
                        ofSize: max(12, CGFloat(sourceAppearance.fontSize) - 2),
                        weight: .regular
                    )
                    markerColor = palette.secondaryTextColor
                }
                storage.addAttributes(
                    [
                        .font: markerFont,
                        .foregroundColor: markerColor,
                        .backgroundColor: NSColor.clear,
                        .underlineStyle: 0,
                        .strikethroughStyle: 0,
                        .obliqueness: 0,
                    ],
                    range: range
                )
                if marker.kind == .orderedList, range.length > 0 {
                    storage.addAttribute(
                        .kern,
                        value: MarkdownRenderMetrics.listMarkerExtraSpacing,
                        range: NSRange(location: NSMaxRange(range) - 1, length: 1)
                    )
                }
            } else {
                hideRenderedMarker(
                    range,
                    storage: storage,
                    reservedAdvance: marker.kind == .inlineCode
                        ? MarkdownRenderMetrics.inlineCodeHorizontalPadding
                        : 0
                )
            }
        }
        for image in plan.images {
            guard !plan.tables.contains(where: {
                NSIntersectionRange($0.sourceRange.utf16Range, image.sourceRange.utf16Range).length
                    == image.sourceRange.utf16Range.length
            }), !rangesOverlap(image.sourceRange.utf16Range, editingRange)
            else { continue }
            applyRenderedImage(
                nil,
                alternative: image.alternative,
                sourceRange: image.sourceRange.utf16Range,
                fillsAvailableWidth: false,
                storage: storage
            )
        }
        for table in plan.tables {
            guard !rangesOverlap(table.sourceRange.utf16Range, editingRange) else { continue }
            let size = textView.setRenderedTable(
                table,
                baseFont: baseFont,
                maximumWidth: max(
                    160,
                    scrollView.contentSize.width - textView.textContainerInset.width * 2
                        - (textView.textContainer?.lineFragmentPadding ?? 0) * 2
                ),
                linkActivation: renderedLinkActivation,
                onLinkClick: { [weak self] target in
                    self?.renderedLinkHandler?(target)
                },
                onEdit: { [weak self] edit in
                    self?.applyRenderedTableEdit(edit, to: table)
                }
            )
            applyRenderedBlock(
                sourceRange: table.sourceRange.utf16Range,
                size: size,
                storage: storage
            )
        }
        for diagram in plan.mermaidDiagrams {
            guard let image = renderedMermaidImage(from: diagram) else { continue }
            if rangesOverlap(diagram.sourceRange.utf16Range, editingRange) {
                applyRenderedMermaidPreviewBelowSource(
                    image,
                    sourceRange: diagram.sourceRange.utf16Range,
                    storage: storage
                )
                continue
            }
            applyRenderedImage(
                image,
                alternative: "Mermaid 图表",
                sourceRange: diagram.sourceRange.utf16Range,
                fillsAvailableWidth: true,
                collapsesSourceLines: true,
                storage: storage
            )
        }
        applyJavaScriptResources(plan, editingRange: editingRange, storage: storage)
        textView.endRenderedOverlayUpdate()
        storage.endEditing()
        renderedAttributePatchRanges = RenderedAttributePatch.apply(storage, to: liveStorage)
        textView.layoutRenderedImages()
        textView.renderedAnchorSourceRanges = anchoredRanges + mathAnchors
        textView.renderedCollapsedSourceRanges = collapsedRanges
        renderedAppliedAppearance = sourceAppearance
        renderedAppliedTheme = renderedTheme
        renderedPresentationPassCount &+= 1
        textView.setSelectedRange(selection)
        syncRenderedTypingAttributes()
        refreshWritingModePresentation()
        loadRenderedImages(for: plan)
        scheduleJavaScriptResources(for: plan)
    }

    private func scheduleJavaScriptResources(for plan: RenderedMarkdownPlan) {
        let source = plan.sourceSnapshot
        if !UTF8Text.isExactlyEqual(javaScriptSnapshot, source) {
            javaScriptResourcesTask?.cancel()
            javaScriptSnapshot = source
            let keys = Set(plan.renderRequests.map(\.cacheKey))
            javaScriptResults = javaScriptResults.filter { keys.contains($0.key) }
            javaScriptFailures.removeAll()
        }
        let requests = plan.renderRequests.filter {
            ($0.kind != "math" || presentation == .rendered)
                && javaScriptResults[$0.cacheKey] == nil && !javaScriptFailures.contains($0.cacheKey)
        }
        guard !requests.isEmpty else {
            if presentation == .source { applyCodeMirrorTokens(plan, storage: textView.textStorage) }
            return
        }
        javaScriptResourcesTask?.cancel()
        javaScriptResourcesTask = Task { @MainActor [weak self] in
            for request in requests {
                do {
                    let input = request.kind == "math" ? request : JavaScriptRenderRequest(
                        sourceRange: request.sourceRange, contentRange: request.contentRange,
                        kind: "code", language: request.language, source: request.source, display: true
                    )
                    let result = try await JavaScriptRenderService.shared.render(input)
                    guard let self, !Task.isCancelled,
                          UTF8Text.isExactlyEqual(self.textView.string, source) else { return }
                    self.javaScriptResults[request.cacheKey] = result
                } catch is CancellationError { return }
                catch {
                    guard let self, !Task.isCancelled,
                          UTF8Text.isExactlyEqual(self.textView.string, source) else { return }
                    self.javaScriptFailures.insert(request.cacheKey)
                }
            }
            guard let self, !Task.isCancelled, !self.textView.hasActiveComposition,
                  UTF8Text.isExactlyEqual(self.textView.string, source) else { return }
            if self.presentation == .rendered {
                self.applyRenderedPresentation(source: source, force: true)
            } else {
                self.applyCodeMirrorTokens(plan, storage: self.textView.textStorage)
            }
        }
    }

    private func applyCodeMirrorTokens(_ plan: RenderedMarkdownPlan, storage: NSTextStorage?) {
        guard let storage, !textView.hasActiveComposition else { return }
        let palette = MarkdownRenderPalette.resolved(for: textView.effectiveAppearance)
        let undo = textView.undoManager
        let undoEnabled = undo?.isUndoRegistrationEnabled == true
        if undoEnabled { undo?.disableUndoRegistration() }
        defer { if undoEnabled { undo?.enableUndoRegistration() } }
        storage.beginEditing()
        defer { storage.endEditing() }
        for request in plan.renderRequests where request.kind != "math" {
            if request.kind != "code", presentation == .rendered,
               !rangesOverlap(request.sourceRange.utf16Range, currentRenderedEditingRange(source: plan.sourceSnapshot)) { continue }
            guard let tokens = javaScriptResults[request.cacheKey]?.tokens else { continue }
            for token in tokens {
                guard token.start >= 0, token.end > token.start,
                      token.end <= request.contentRange.utf16Range.length else { continue }
                let range = NSRange(location: request.contentRange.utf16Range.location + token.start,
                                    length: token.end - token.start)
                guard NSMaxRange(range) <= storage.length else { continue }
                let color: NSColor
                switch token.kind {
                case "keyword", "tag": color = palette.accentColor
                case "string": color = NSColor.systemGreen
                case "number", "literal": color = NSColor.systemOrange
                case "comment": color = palette.secondaryTextColor
                case "type", "attribute": color = NSColor.systemPurple
                default: color = palette.textColor
                }
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    private func applyJavaScriptResources(_ plan: RenderedMarkdownPlan, editingRange: NSRange?, storage: NSTextStorage) {
        applyCodeMirrorTokens(plan, storage: storage)
        for request in plan.renderRequests where request.kind == "math" {
            guard let svg = javaScriptResults[request.cacheKey]?.svg,
                  let image = NSImage(data: Data(svg.utf8)) else {
                if javaScriptFailures.contains(request.cacheKey) {
                    storage.addAttributes([.toolTip: "公式渲染失败，请检查 TeX 语法。", .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.systemRed], range: request.sourceRange.utf16Range)
                }
                continue
            }
            image.isTemplate = true
            if rangesOverlap(request.sourceRange.utf16Range, editingRange) {
                let size = textView.setRenderedImage(image, alternative: "数学公式预览",
                    sourceRange: request.sourceRange.utf16Range, fillsAvailableWidth: request.display, placement: .belowSource)
                reserveSpaceBelowRenderedSource(sourceRange: request.sourceRange.utf16Range, size: size, storage: storage)
                continue
            }
            applyRenderedImage(image, alternative: "数学公式：" + request.source,
                               sourceRange: request.sourceRange.utf16Range,
                               fillsAvailableWidth: request.display,
                               collapsesSourceLines: request.display, storage: storage)
        }
    }

    private func cancelRenderedImageLoading() {
        renderedImageTask?.cancel()
        renderedImageTask = nil
        renderedImageGeneration &+= 1
    }

    private func loadRenderedImages(for plan: RenderedMarkdownPlan) {
        cancelRenderedImageLoading()
        guard !plan.images.isEmpty else { return }
        let generation = renderedImageGeneration
        let context = renderedResourceContext
        renderedImageTask = Task { @MainActor [weak self] in
            for renderedImage in plan.images {
                guard let self,
                      !Task.isCancelled,
                      generation == self.renderedImageGeneration,
                      self.presentation == .rendered,
                      self.renderedPlan?.exactlyMatches(self.textView.string) == true
                else {
                    return
                }
                guard !plan.tables.contains(where: {
                    NSIntersectionRange(
                        $0.sourceRange.utf16Range,
                        renderedImage.sourceRange.utf16Range
                    ).length == renderedImage.sourceRange.utf16Range.length
                }), !self.rangesOverlap(
                    renderedImage.sourceRange.utf16Range,
                    self.renderedEditingRange
                ) else { continue }
                guard let data = await RenderedMarkdownImageLoader.shared.load(
                    target: renderedImage.target,
                    context: context
                ), let image = NSImage(data: data), image.isValid else {
                    continue
                }
                self.mountRenderedImage(
                    image,
                    alternative: renderedImage.alternative,
                    sourceRange: renderedImage.sourceRange.utf16Range,
                    generation: generation
                )
            }
        }
    }

    private func mountRenderedImage(
        _ image: NSImage,
        alternative: String,
        sourceRange: NSRange,
        generation: Int
    ) {
        guard generation == renderedImageGeneration,
              presentation == .rendered,
              let storage = textView.textStorage,
              NSMaxRange(sourceRange) <= storage.length
        else {
            return
        }
        let selection = textView.selectedRange()
        let undoManager = textView.undoManager
        let restoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if restoreUndoRegistration { undoManager?.disableUndoRegistration() }
        defer {
            if restoreUndoRegistration { undoManager?.enableUndoRegistration() }
        }
        storage.beginEditing()
        applyRenderedImage(
            image,
            alternative: alternative,
            sourceRange: sourceRange,
            fillsAvailableWidth: false,
            storage: storage
        )
        storage.endEditing()
        textView.setSelectedRange(selection)
        textView.needsDisplay = true
    }

    private func applyRenderedMermaidPreviewBelowSource(
        _ image: NSImage,
        sourceRange: NSRange,
        storage: NSTextStorage
    ) {
        guard sourceRange.length > 0, NSMaxRange(sourceRange) <= storage.length else { return }
        let renderedSize = textView.setRenderedImage(
            image,
            alternative: "Mermaid 图表",
            sourceRange: sourceRange,
            fillsAvailableWidth: true,
            placement: .belowSource
        )
        reserveSpaceBelowRenderedSource(
            sourceRange: sourceRange,
            size: renderedSize,
            storage: storage
        )
    }

    private func reserveSpaceBelowRenderedSource(
        sourceRange: NSRange,
        size: NSSize,
        storage: NSTextStorage
    ) {
        guard let anchor = WindowAwareTextView.lastVisibleCharacterLocation(
            in: sourceRange,
            text: storage.string
        ) else { return }
        let paragraphRange = storage.mutableString.paragraphRange(
            for: NSRange(location: anchor, length: 0)
        )
        let paragraph = (
            storage.attribute(.paragraphStyle, at: anchor, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.paragraphSpacing = size.height + 18
        storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
    }

    private func applyRenderedImage(
        _ image: NSImage?,
        alternative: String,
        sourceRange: NSRange,
        fillsAvailableWidth: Bool,
        collapsesSourceLines: Bool = false,
        storage: NSTextStorage
    ) {
        guard sourceRange.length > 0, NSMaxRange(sourceRange) <= storage.length else { return }
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .kern: 0,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
            ],
            range: sourceRange
        )

        let displayedImage = image ?? NSImage(
                systemSymbolName: "photo",
                accessibilityDescription: alternative.isEmpty ? "图片" : alternative
            ) ?? NSImage(size: NSSize(width: 28, height: 28))
        displayedImage.accessibilityDescription = alternative.isEmpty ? "图片" : alternative
        let renderedSize = textView.setRenderedImage(
            displayedImage,
            alternative: alternative,
            sourceRange: sourceRange,
            fillsAvailableWidth: fillsAvailableWidth
        )
        if collapsesSourceLines {
            reserveRenderedOverlaySpace(
                sourceRange: sourceRange,
                size: renderedSize,
                storage: storage
            )
            return
        }
        storage.addAttribute(
            .kern,
            value: renderedSize.width,
            range: NSRange(location: sourceRange.location, length: 1)
        )
        let paragraphStyle = (
            storage.attribute(
                .paragraphStyle,
                at: sourceRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = max(
            paragraphStyle.minimumLineHeight,
            renderedSize.height + 10
        )
        storage.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: sourceRange.location, length: 1)
        )
    }

    private func applyRenderedBlock(
        sourceRange: NSRange,
        size: NSSize,
        storage: NSTextStorage
    ) {
        guard sourceRange.length > 0, NSMaxRange(sourceRange) <= storage.length else { return }
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .kern: 0,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
            ],
            range: sourceRange
        )
        reserveRenderedOverlaySpace(sourceRange: sourceRange, size: size, storage: storage)
    }

    /// A rendered block is represented by one visible layout anchor. The remaining source must
    /// keep its characters for lossless editing, but must not keep one TextKit line fragment per
    /// Markdown row. Otherwise a long table or Mermaid block leaves a matching column of empty
    /// line fragments below its overlay.
    private func reserveRenderedOverlaySpace(
        sourceRange: NSRange,
        size: NSSize,
        storage: NSTextStorage
    ) {
        guard sourceRange.length > 0, NSMaxRange(sourceRange) <= storage.length else { return }
        let inheritedStyle = (
            storage.attribute(.paragraphStyle, at: sourceRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let collapsedStyle = inheritedStyle.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        collapsedStyle.minimumLineHeight = 0.1
        collapsedStyle.maximumLineHeight = 0.1
        collapsedStyle.lineHeightMultiple = 0.01
        collapsedStyle.lineSpacing = 0
        collapsedStyle.paragraphSpacingBefore = 0
        collapsedStyle.paragraphSpacing = 0
        storage.addAttribute(.paragraphStyle, value: collapsedStyle, range: sourceRange)

        storage.addAttribute(
            .kern,
            value: size.width,
            range: NSRange(location: sourceRange.location, length: 1)
        )
        let paragraphStyle = inheritedStyle
        let anchorHeight = size.height + 10
        paragraphStyle.minimumLineHeight = anchorHeight
        paragraphStyle.maximumLineHeight = anchorHeight
        paragraphStyle.lineHeightMultiple = 1
        paragraphStyle.lineSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.lineBreakMode = .byClipping
        storage.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: sourceRange.location, length: 1)
        )
    }

    private func rangesOverlap(_ range: NSRange, _ optionalRange: NSRange?) -> Bool {
        guard let optionalRange else { return false }
        if range.length == 0 || optionalRange.length == 0 {
            return range.location == optionalRange.location
        }
        return NSIntersectionRange(range, optionalRange).length > 0
    }

    private func fencedCodeParts(
        in range: NSRange,
        source: String
    ) -> (opening: NSRange, content: NSRange, closing: NSRange)? {
        let text = source as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let block = text.substring(with: range) as NSString
        let firstNewline = block.range(of: "\n")
        guard firstNewline.location != NSNotFound else { return nil }
        let searchLength = block.hasSuffix("\n") ? block.length - 1 : block.length
        let lastNewline = block.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: max(0, searchLength))
        )
        guard lastNewline.location != NSNotFound,
              lastNewline.location >= NSMaxRange(firstNewline)
        else { return nil }
        let openingEnd = NSMaxRange(firstNewline)
        let closingStart = NSMaxRange(lastNewline)
        let openingLine = block.substring(to: firstNewline.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let closingLine = block.substring(from: closingStart).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = openingLine.first, marker == "`" || marker == "~" else { return nil }
        let fenceLength = openingLine.prefix { $0 == marker }.count
        guard fenceLength >= 3, closingLine.count >= fenceLength,
              closingLine.allSatisfy({ $0 == marker }) else { return nil }
        return (
            NSRange(location: range.location, length: openingEnd),
            NSRange(
                location: range.location + openingEnd,
                length: closingStart - openingEnd
            ),
            NSRange(
                location: range.location + closingStart,
                length: range.length - closingStart
            )
        )
    }

    private func syncRenderedTypingAttributes() {
        guard !textView.hasActiveComposition, presentation == .rendered,
              let storage = textView.textStorage,
              storage.length > 0
        else { return }
        let selection = textView.selectedRange()
        let source = storage.string as NSString
        let line = source.lineRange(for: NSRange(location: min(selection.location, source.length), length: 0))
        let emptyLine = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let protectedBlock = renderedPlan?.localSourceBlocks.contains {
            NSLocationInRange(selection.location, $0.sourceRange.utf16Range)
        } == true
        if emptyLine, !protectedBlock {
            let font = renderedBaseFont()
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = font.pointSize * CGFloat(sourceAppearance.lineHeight)
            textView.typingAttributes = [.font: font, .foregroundColor: MarkdownRenderPalette.resolved(for: textView.effectiveAppearance).textColor,
                                        .paragraphStyle: paragraph]
            return
        }
        var location = min(selection.location, storage.length - 1)
        if let plan = renderedPlan, plan.exactlyMatches(storage.string) {
            let hiddenRanges = plan.markers.map(\.sourceRange.utf16Range)
            location = RenderedMarkdownCaretStyleResolver.visibleAttributeLocation(
                forInsertionLocation: selection.location,
                text: storage.string,
                hiddenRanges: hiddenRanges
            ) ?? location
        }
        let attributes = storage.attributes(at: location, effectiveRange: nil)
        var typing: [NSAttributedString.Key: Any] = [:]
        for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
            if let value = attributes[key] { typing[key] = value }
        }
        if typing[.font] == nil { typing[.font] = textView.font }
        if typing[.foregroundColor] == nil { typing[.foregroundColor] = NSColor.textColor }
        if (typing[.font] as? NSFont)?.pointSize ?? 0 < 1 {
            let font = renderedBaseFont()
            typing[.font] = font
            let paragraph = (typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.minimumLineHeight = max(paragraph.minimumLineHeight, font.pointSize * CGFloat(sourceAppearance.lineHeight))
            if paragraph.maximumLineHeight > 0, paragraph.maximumLineHeight < paragraph.minimumLineHeight { paragraph.maximumLineHeight = 0 }
            typing[.paragraphStyle] = paragraph
        }
        if (typing[.foregroundColor] as? NSColor)?.alphaComponent == 0 {
            let palette = MarkdownRenderPalette.resolved(for: textView.effectiveAppearance)
            let isQuote = textView.renderedQuoteRanges.contains { NSIntersectionRange($0, line).length > 0 }
            typing[.foregroundColor] = isQuote ? palette.secondaryTextColor : palette.textColor
        }
        textView.typingAttributes = typing
    }

    private func hideRenderedMarker(
        _ range: NSRange,
        storage: NSTextStorage,
        reservedAdvance: CGFloat = 0
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let collapsedFont = NSFont.systemFont(ofSize: 0.1)
        storage.addAttributes(
            [
                .font: collapsedFont,
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
                .baselineOffset: 0,
                // Keep the Markdown source byte-for-byte intact while making each marker's
                // layout advance effectively zero. Using the marker's visible font here made
                // inline-code backticks and heading markers distort both wrapping and carets.
                .kern: -collapsedFont.pointSize,
            ],
            range: range
        )
        if reservedAdvance > 0 {
            storage.addAttribute(
                .kern,
                value: reservedAdvance - collapsedFont.pointSize,
                range: NSRange(location: range.location, length: 1)
            )
        }
    }

    private func applyRenderedReplacement(
        _ marker: RenderedMarkdownMarker,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        let range = marker.sourceRange.utf16Range
        guard let replacement = marker.replacementText,
              range.length > 0,
              NSMaxRange(range) <= storage.length
        else { return }
        let font = RenderedMarkdownMarkerTypography.font(
            for: marker.kind,
            baseFont: baseFont
        )
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .kern: 0,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
            ],
            range: range
        )
        let markerSpacing = switch marker.kind {
        case .unorderedList, .taskList:
            MarkdownRenderMetrics.listMarkerExtraSpacing
        default:
            CGFloat.zero
        }
        let width = ceil((replacement as NSString).size(withAttributes: [.font: font]).width)
            + markerSpacing
        storage.addAttribute(
            .kern,
            value: max(1, width),
            range: NSRange(location: range.location, length: 1)
        )
    }

    private func applyRenderedRule(
        _ range: NSRange,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .kern: 0,
            ],
            range: range
        )
        let paragraph = (
            storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(paragraph.minimumLineHeight, baseFont.pointSize * 1.4)
        storage.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: range.location, length: 1)
        )
    }

    private func applyRenderedTableEdit(_ edit: RenderedMarkdownTableEdit, to table: RenderedMarkdownTable) {
        guard presentation == .rendered, textView.isEditable else { return }
        let source = textView.string
        let current: RenderedMarkdownTable?
        if let optimisticTable, UTF8Text.isExactlyEqual(optimisticTable.source, source),
           optimisticTable.table.sourceRange.utf16Range.location == table.sourceRange.utf16Range.location {
            current = optimisticTable.table
        } else {
            let plan = engineRenderedPlan?.exactlyMatches(source) == true ? engineRenderedPlan! : RenderedMarkdownEditor.plan(for: source)
            current = plan.tables.first { $0.sourceRange.utf16Range.location == table.sourceRange.utf16Range.location }
        }
        guard let current, let replacement = RenderedMarkdownTableEditing.replacement(for: current, applying: edit),
              let localTable = RenderedMarkdownEditor.plan(for: replacement).tables.first else { return }
        let original = (source as NSString).substring(with: current.sourceRange.utf16Range)
        let ending = original.hasSuffix("\r\n") ? "\r\n" : (original.hasSuffix("\n") ? "\n" : "")
        let text = replacement + ending
        let newRange = RenderedMarkdownSourceRange(
            utf8Range: current.sourceRange.utf8Range.lowerBound..<(current.sourceRange.utf8Range.lowerBound + text.utf8.count),
            utf16Range: NSRange(location: current.sourceRange.utf16Range.location, length: text.utf16.count))
        func offset(_ range: RenderedMarkdownSourceRange) -> RenderedMarkdownSourceRange {
            RenderedMarkdownSourceRange(utf8Range: (range.utf8Range.lowerBound + newRange.utf8Range.lowerBound)..<(range.utf8Range.upperBound + newRange.utf8Range.lowerBound),
                utf16Range: NSRange(location: range.utf16Range.location + newRange.utf16Range.location, length: range.utf16Range.length))
        }
        let updated = RenderedMarkdownTable(sourceRange: newRange, alignments: localTable.alignments,
            rows: localTable.rows.map { $0.map { RenderedMarkdownTableCell(sourceRange: offset($0.sourceRange), markdown: $0.markdown, text: $0.text, links: $0.links) } })
        // Old image requests still carry positions from before this local edit.
        cancelRenderedImageLoading()
        textView.replaceRenderedTableSource(text, range: current.sourceRange.utf16Range)
        textView.rebaseRenderedRanges(replacing: current.sourceRange.utf16Range, withLength: text.utf16.count)
        optimisticTable = (textView.string, updated)
        let size = textView.setRenderedTable(updated, baseFont: renderedBaseFont(),
            maximumWidth: max(160, scrollView.contentSize.width - textView.textContainerInset.width * 2
                - (textView.textContainer?.lineFragmentPadding ?? 0) * 2),
            linkActivation: renderedLinkActivation, onLinkClick: { [weak self] in self?.renderedLinkHandler?($0) },
            onEdit: { [weak self] in self?.applyRenderedTableEdit($0, to: updated) })
        if let storage = textView.textStorage {
            storage.beginEditing()
            applyRenderedBlock(sourceRange: newRange.utf16Range, size: size, storage: storage)
            storage.endEditing()
        }
        textView.layoutRenderedImages()
        textView.undoManager?.setActionName("编辑表格")
    }

    private func renderedMermaidImage(from diagram: RenderedMarkdownMermaidDiagram) -> NSImage? {
        guard let image = NSImage(data: diagram.pdfData ?? Data(diagram.svg.utf8)), image.isValid else { return nil }
        image.isTemplate = false
        image.size = NSSize(width: diagram.intrinsicWidth, height: diagram.intrinsicHeight)
        image.accessibilityDescription = "Mermaid 图表"
        return image
    }

    private func applyResolvedMermaidOverlays(
        _ plan: RenderedMarkdownPlan,
        source: String
    ) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let editingRange = currentRenderedEditingRange(source: source)
        let undoManager = textView.undoManager
        let restoresUndo = undoManager?.isUndoRegistrationEnabled == true
        if restoresUndo { undoManager?.disableUndoRegistration() }
        storage.beginEditing()
        for diagram in plan.mermaidDiagrams {
            guard let image = renderedMermaidImage(from: diagram) else { continue }
            if rangesOverlap(diagram.sourceRange.utf16Range, editingRange) {
                applyRenderedMermaidPreviewBelowSource(
                    image,
                    sourceRange: diagram.sourceRange.utf16Range,
                    storage: storage
                )
            } else {
                applyRenderedImage(
                    image,
                    alternative: "Mermaid 图表",
                    sourceRange: diagram.sourceRange.utf16Range,
                    fillsAvailableWidth: true,
                    collapsesSourceLines: true,
                    storage: storage
                )
            }
        }
        storage.endEditing()
        if restoresUndo { undoManager?.enableUndoRegistration() }
        renderedPlan = plan
        renderedEditingRange = editingRange
        renderedMermaidPatchCount &+= 1
        textView.setSelectedRange(selection)
        textView.layoutSubtreeIfNeeded()
        textView.needsDisplay = true
    }

    private func applyRenderedAttributes(
        for kind: RenderedMarkdownContentStyleKind,
        range: NSRange,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        let palette = MarkdownRenderPalette.resolved(for: textView.effectiveAppearance)
        switch kind {
        case .paragraph:
            break
        case .unorderedListItem, .orderedListItem, .taskListItem:
            let paragraphRange = storage.mutableString.paragraphRange(for: range)
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, 2)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
        case let .heading(level):
            let metrics = MarkdownRenderMetrics.heading(level: level)
            let paragraphRange = storage.mutableString.paragraphRange(for: range)
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.minimumLineHeight = baseFont.pointSize * CGFloat(metrics.scale * MarkdownRenderMetrics.headingLineHeight(level: level))
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            paragraph.lineHeightMultiple = 1
            paragraph.paragraphSpacingBefore = baseFont.pointSize * CGFloat(metrics.spacingBefore)
            paragraph.paragraphSpacing = baseFont.pointSize * CGFloat(metrics.spacingAfter)
            storage.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: paragraphRange
            )
            storage.addAttributes(
                [
                    .font: NSFontManager.shared.convert(
                        NSFont(descriptor: baseFont.fontDescriptor, size: baseFont.pointSize * CGFloat(metrics.scale)) ?? baseFont,
                        toHaveTrait: .boldFontMask
                    ),
                    .foregroundColor: level == 6
                        ? palette.secondaryTextColor
                        : palette.headingColor,
                ],
                range: range
            )
        case .emphasis:
            storage.addAttribute(.obliqueness, value: 0.18, range: range)
        case .strong:
            transformFonts(in: range, storage: storage) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        case .strikethrough:
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .inlineCode:
            transformFonts(in: range, storage: storage) { font in
                NSFont.monospacedSystemFont(
                    ofSize: max(
                        13,
                        font.pointSize * CGFloat(MarkdownRenderMetrics.inlineCodeScale)
                    ),
                    weight: .regular
                )
            }
            storage.addAttributes(
                [
                    .baselineOffset: 0,
                    .foregroundColor: palette.textColor,
                    // Attribute backgrounds use the line box and make the
                    // smaller monospace font look vertically displaced. The
                    // text view draws a glyph-bound rounded background instead.
                    .backgroundColor: NSColor.clear,
                ],
                range: range
            )
        case .inlineMath:
            storage.addAttributes(
                [
                    .font: NSFont(name: "Times New Roman", size: baseFont.pointSize)
                        ?? NSFont.systemFont(ofSize: baseFont.pointSize),
                    .foregroundColor: palette.headingColor,
                ],
                range: range
            )
        case .displayMath:
            let paragraph = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, 8)
            paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, 8)
            storage.addAttributes(
                [
                    .font: NSFont(name: "Times New Roman", size: baseFont.pointSize + 1)
                        ?? NSFont.systemFont(ofSize: baseFont.pointSize + 1),
                    .foregroundColor: palette.headingColor,
                    .paragraphStyle: paragraph,
                ],
                range: range
            )
        case .blockQuote:
            let paragraphStyle = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent += 16
            paragraphStyle.headIndent += 16
            paragraphStyle.paragraphSpacingBefore = 0
            paragraphStyle.paragraphSpacing = 0
            let paragraphRange = storage.mutableString.paragraphRange(for: range)
            storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraphRange)
            storage.addAttribute(
                .foregroundColor,
                value: palette.secondaryTextColor,
                range: range
            )
        case .tableHeader:
            transformFonts(in: range, storage: storage) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            applyRenderedTableRow(
                range: range,
                storage: storage,
                backgroundColor: palette.mutedSurfaceColor
            )
        case let .tableBody(alternating):
            applyRenderedTableRow(
                range: range,
                storage: storage,
                backgroundColor: alternating
                    ? palette.tableStripeColor
                    : palette.canvasColor
            )
        case .link:
            storage.addAttributes(
                MarkdownLinkVisualStyle.restingAttributes(
                    foregroundColor: palette.accentColor
                ),
                range: range
            )
        }
    }

    private func renderedBaseFont() -> NSFont {
        let size = max(15, CGFloat(sourceAppearance.fontSize))
        switch renderedTheme {
        case .code:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .longform:
            let fallback = NSFont.systemFont(ofSize: size)
            guard let descriptor = fallback.fontDescriptor.withDesign(.serif) else {
                return fallback
            }
            return NSFont(descriptor: descriptor, size: size) ?? fallback
        case .standard, .highContrast:
            return MarkdownRenderMetrics.bodyFont(size: size)
        }
    }

    private func applyRenderedTableRow(
        range: NSRange,
        storage: NSTextStorage,
        backgroundColor: NSColor
    ) {
        storage.addAttribute(.backgroundColor, value: backgroundColor, range: range)
        guard range.length > 0 else { return }
        let paragraphStyle = (
            storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 1
        paragraphStyle.paragraphSpacingBefore = 1
        paragraphStyle.lineHeightMultiple = max(paragraphStyle.lineHeightMultiple, 1.25)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
    }

    private func transformFonts(
        in range: NSRange,
        storage: NSTextStorage,
        transform: (NSFont) -> NSFont
    ) {
        guard range.length > 0 else { return }
        var replacements: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, effectiveRange, _ in
            let font = value as? NSFont ?? textView.font ?? NSFont.systemFont(ofSize: 15)
            replacements.append((effectiveRange, transform(font)))
        }
        for (effectiveRange, font) in replacements {
            storage.addAttribute(.font, value: font, range: effectiveRange)
        }
    }

    func setWritingModes(
        focusModeEnabled: Bool,
        typewriterModeEnabled: Bool
    ) {
        let focusChanged = self.focusModeEnabled != focusModeEnabled
        let typewriterChanged = self.typewriterModeEnabled != typewriterModeEnabled
        guard focusChanged || typewriterChanged else { return }
        self.focusModeEnabled = focusModeEnabled
        self.typewriterModeEnabled = typewriterModeEnabled
        refreshWritingModePresentation()
    }

    private func applyCompactParagraphGaps(source: String, storage: NSTextStorage) {
        // Editable blank lines are caret destinations, not display-only paragraph gaps.
        guard !textView.isEditable else { return }
        let text = source as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            let raw = text.substring(with: paragraph)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = MarkdownRenderMetrics.paragraphGap * CGFloat(sourceAppearance.fontSize / MarkdownRenderMetrics.bodyFontSize)
                style.maximumLineHeight = style.minimumLineHeight
                style.paragraphSpacing = 0
                style.paragraphSpacingBefore = 0
                storage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 0.1),
                        .foregroundColor: NSColor.clear,
                        .paragraphStyle: style,
                    ],
                    range: paragraph
                )
            }
            location = NSMaxRange(paragraph)
        }
    }

    private func refreshWritingModePresentation() {
        applyFocusModePresentation()
        centerSelectionForTypewriterMode()
    }

    private func applyFocusModePresentation() {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard focusModeEnabled, length > 0 else { return }

        layoutManager.addTemporaryAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            forCharacterRange: fullRange
        )
        let selection = textView.selectedRange()
        let location = min(selection.location, length)
        let paragraph = (textView.string as NSString).paragraphRange(
            for: NSRange(location: location, length: 0)
        )
        layoutManager.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: paragraph
        )
    }

    private func centerSelectionForTypewriterMode() {
        guard typewriterModeEnabled,
              let active = textView.window?.firstResponder as? NSTextView,
              active === textView || active.isDescendant(of: textView),
              !active.hasMarkedText(),
              let layoutManager = active.layoutManager,
              let textContainer = active.textContainer
        else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let length = (active.string as NSString).length
        let selectionLocation = min(active.selectedRange().location, length)
        let caretRect: NSRect
        if selectionLocation == length {
            caretRect = layoutManager.extraLineFragmentRect
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: selectionLocation)
            caretRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
        }
        let caretMidpoint = active.convert(caretRect.offsetBy(dx: active.textContainerOrigin.x,
            dy: active.textContainerOrigin.y), to: textView).midY
        let clipView = scrollView.contentView
        let maximumOffset = max(0, textView.bounds.height - clipView.bounds.height)
        let targetOffset = min(
            max(0, caretMidpoint - clipView.bounds.height / 2),
            maximumOffset
        )
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetOffset))
        scrollView.reflectScrolledClipView(clipView)
        verticalScrollOffset = Double(targetOffset)
        updateScrollFraction(using: clipView, offset: targetOffset)
    }

    private func configureLineWrapping(_ wrapsLines: Bool) {
        guard configuredLineWrapping != wrapsLines else { return }
        configuredLineWrapping = wrapsLines
        scrollView.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines
                ? max(0, scrollView.contentSize.width)
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if wrapsLines {
            textView.frame.size.width = max(textView.frame.width, scrollView.contentSize.width)
        }
        textView.needsLayout = true
        lineNumberRuler.needsDisplay = true
    }

    @discardableResult
    func applySyntaxHighlighting(
        _ spans: [MarkdownSyntaxSpan],
        source: String,
        enabled: Bool
    ) -> Bool {
        let previousSource = syntaxHighlightingSource
        let previousSpans = syntaxHighlightingSpans
        let previousApplicationWasComplete = syntaxApplicationIsComplete
        syntaxHighlightingEnabled = enabled
        syntaxHighlightingSource = source
        syntaxHighlightingSourceUTF8 = Data(source.utf8)
        syntaxHighlightingSpans = enabled ? spans : []
        guard !textView.hasActiveComposition,
              UTF8Text.isExactlyEqual(textView.string, source) else { return false }
        if presentation == .source {
            applySourceSyntaxDifference(
                from: previousSource,
                spans: previousSpans,
                previousApplicationWasComplete: previousApplicationWasComplete
            )
        } else if !renderedPresentationIsCurrent(source: source) {
            applyRenderedPresentation(source: source, force: false)
        }
        return true
    }

    private func applySourceSyntaxDifference(
        from previousSource: String,
        spans previousSpans: [MarkdownSyntaxSpan],
        previousApplicationWasComplete: Bool
    ) {
        guard let storage = textView.textStorage else { return }
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(sourceAppearance.fontSize),
            weight: .regular
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = CGFloat(sourceAppearance.lineHeight)
        let fullRange = NSRange(location: 0, length: storage.length)
        let dirtyRanges = previousApplicationWasComplete
            ? Self.syntaxDirtyRanges(
                previousSource: previousSource,
                previousSpans: previousSpans,
                source: syntaxHighlightingSource,
                spans: syntaxHighlightingSpans
            )
            : (fullRange.length > 0 ? [fullRange] : [])
        lastSyntaxDirtyUTF16Ranges = dirtyRanges
        guard !dirtyRanges.isEmpty else { return }

        let undoManager = textView.undoManager
        let restoreUndoRegistration = undoManager?.isUndoRegistrationEnabled == true
        if restoreUndoRegistration { undoManager?.disableUndoRegistration() }
        defer {
            if restoreUndoRegistration { undoManager?.enableUndoRegistration() }
        }

        storage.beginEditing()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .backgroundColor: NSColor.clear,
            .paragraphStyle: paragraphStyle,
            .underlineStyle: 0,
            .strikethroughStyle: 0,
            .obliqueness: 0,
        ]
        for range in dirtyRanges where NSMaxRange(range) <= storage.length {
            storage.addAttributes(baseAttributes, range: range)
        }
        storage.endEditing()
        scheduleCachedSyntaxHighlighting(
            baseFont: font,
            limitedTo: dirtyRanges == [fullRange] ? nil : dirtyRanges
        )
        refreshWritingModePresentation()
    }

    private func scheduleCachedSyntaxHighlighting(
        baseFont: NSFont,
        limitedTo dirtyRanges: [NSRange]? = nil
    ) {
        syntaxApplicationTask?.cancel()
        syntaxApplicationGeneration &+= 1
        let generation = syntaxApplicationGeneration
        guard presentation == .source,
              syntaxHighlightingEnabled,
              syntaxHighlightingSourceUTF8 == Data(textView.string.utf8)
        else {
            syntaxApplicationIsComplete = true
            return
        }

        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let sortedSpans = syntaxHighlightingSpans.filter { span in
            guard let dirtyRanges else { return true }
            return dirtyRanges.contains {
                NSIntersectionRange($0, span.utf16Range).length > 0
            }
        }
        syntaxApplicationIsComplete = false
        syntaxApplicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for batchStart in stride(from: 0, to: sortedSpans.count, by: 512) {
                guard !Task.isCancelled,
                      generation == self.syntaxApplicationGeneration,
                      !self.textView.hasActiveComposition,
                      let textStorage = self.textView.textStorage
                else {
                    return
                }
                let batchEnd = min(batchStart + 512, sortedSpans.count)
                textStorage.beginEditing()
                for span in sortedSpans[batchStart..<batchEnd] {
                    let range = span.utf16Range
                    guard NSMaxRange(range) <= textStorage.length
                    else {
                        continue
                    }
                    textStorage.addAttributes(
                        self.syntaxAttributes(for: span.kind, boldFont: boldFont),
                        range: range
                    )
                }
                textStorage.endEditing()
                await Task.yield()
            }
            guard !Task.isCancelled,
                  generation == self.syntaxApplicationGeneration,
                  !self.textView.hasActiveComposition
            else { return }
            self.syntaxApplicationIsComplete = true
            self.syntaxApplicationTask = nil
            let plan = RenderedMarkdownEditor.plan(for: self.textView.string)
            self.applyCodeMirrorTokens(plan, storage: self.textView.textStorage)
            self.scheduleJavaScriptResources(for: plan)
        }
    }

    private func invalidateSyntaxApplication() {
        if syntaxApplicationTask != nil {
            syntaxApplicationIsComplete = false
        }
        syntaxApplicationTask?.cancel()
        syntaxApplicationTask = nil
        syntaxApplicationGeneration &+= 1
    }

    private struct SyntaxSpanKey: Hashable {
        let kind: UInt8
        let start: Int
        let end: Int
    }

    private static func syntaxDirtyRanges(
        previousSource: String,
        previousSpans: [MarkdownSyntaxSpan],
        source: String,
        spans: [MarkdownSyntaxSpan]
    ) -> [NSRange] {
        if previousSource.isEmpty, previousSpans.isEmpty {
            let fullRange = NSRange(location: 0, length: (source as NSString).length)
            return fullRange.length > 0 ? [fullRange] : []
        }
        guard let edit = EditorEngineTextDiff.replacement(from: previousSource, to: source) else {
            let previousByKey = Dictionary(previousSpans.map {
                (SyntaxSpanKey(
                    kind: $0.kind.rawValue,
                    start: $0.utf8Range.lowerBound,
                    end: $0.utf8Range.upperBound
                ), $0.utf16Range)
            }, uniquingKeysWith: { first, _ in first })
            let newByKey = Dictionary(spans.map {
                (SyntaxSpanKey(
                    kind: $0.kind.rawValue,
                    start: $0.utf8Range.lowerBound,
                    end: $0.utf8Range.upperBound
                ), $0.utf16Range)
            }, uniquingKeysWith: { first, _ in first })
            let removed = previousByKey.compactMap { key, range in
                newByKey[key] == nil ? range : nil
            }
            let added = newByKey.compactMap { key, range in
                previousByKey[key] == nil ? range : nil
            }
            return coalescedRanges(removed + added)
        }

        let insertedLength = edit.inserted.utf8.count
        let removedLength = edit.end - edit.start
        let delta = insertedLength - removedLength
        var mappedPrevious: [SyntaxSpanKey: Range<Int>] = [:]
        var dirtyUTF8: [Range<Int>] = []

        for span in previousSpans {
            let old = span.utf8Range
            let mapped: Range<Int>
            if old.upperBound <= edit.start {
                mapped = old
            } else if old.lowerBound >= edit.end {
                mapped = (old.lowerBound + delta)..<(old.upperBound + delta)
            } else {
                let start = min(old.lowerBound, edit.start)
                let trailing = max(0, old.upperBound - edit.end)
                mapped = start..<(edit.start + insertedLength + trailing)
                if !mapped.isEmpty { dirtyUTF8.append(mapped) }
            }
            if !mapped.isEmpty {
                mappedPrevious[
                    SyntaxSpanKey(
                        kind: span.kind.rawValue,
                        start: mapped.lowerBound,
                        end: mapped.upperBound
                    )
                ] = mapped
            }
        }

        let newKeys = Set(spans.map {
            SyntaxSpanKey(
                kind: $0.kind.rawValue,
                start: $0.utf8Range.lowerBound,
                end: $0.utf8Range.upperBound
            )
        })
        for (key, range) in mappedPrevious where !newKeys.contains(key) {
            dirtyUTF8.append(range)
        }
        for span in spans {
            let key = SyntaxSpanKey(
                kind: span.kind.rawValue,
                start: span.utf8Range.lowerBound,
                end: span.utf8Range.upperBound
            )
            if mappedPrevious[key] == nil {
                dirtyUTF8.append(span.utf8Range)
            }
        }
        if insertedLength > 0 {
            dirtyUTF8.append(edit.start..<(edit.start + insertedLength))
        }

        let validUTF8 = dirtyUTF8.filter {
            !$0.isEmpty && $0.lowerBound >= 0 && $0.upperBound <= source.utf8.count
        }
        guard let utf16 = MarkdownSyntaxRange.utf16Ranges(for: validUTF8, in: source) else {
            let fullRange = NSRange(location: 0, length: (source as NSString).length)
            return fullRange.length > 0 ? [fullRange] : []
        }
        return coalescedRanges(utf16)
    }

    private static func coalescedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted {
            ($0.location, $0.length) < ($1.location, $1.length)
        }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func syntaxAttributes(
        for kind: MarkdownSyntaxKind,
        boldFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading:
            [.foregroundColor: NSColor.systemBlue, .font: boldFont]
        case .emphasis:
            [.obliqueness: 0.18]
        case .strong:
            [.font: boldFont]
        case .strikethrough:
            [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .code:
            [
                .foregroundColor: NSColor.systemOrange,
                .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18),
            ]
        case .link:
            MarkdownLinkVisualStyle.restingAttributes(
                foregroundColor: MarkdownRenderPalette.resolved(
                    for: textView.effectiveAppearance
                ).accentColor
            )
        case .image:
            [.foregroundColor: NSColor.systemPink]
        case .blockQuote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .list:
            [.foregroundColor: NSColor.systemIndigo]
        case .table:
            [.foregroundColor: NSColor.systemTeal]
        case .footnote:
            [.foregroundColor: NSColor.systemMint]
        case .math:
            [.foregroundColor: NSColor.systemGreen]
        case .raw:
            [.foregroundColor: NSColor.systemRed]
        case .rule:
            [.foregroundColor: NSColor.tertiaryLabelColor]
        }
    }

    @objc
    private func scrollViewBoundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else { return }
        let offset = max(0, clipView.bounds.origin.y)
        if verticalScrollOffset != offset {
            verticalScrollOffset = offset
        }
        updateScrollFraction(using: clipView, offset: offset)
    }

    private func updateScrollFraction(using clipView: NSClipView, offset: CGFloat) {
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maximumOffset = max(0, documentHeight - clipView.bounds.height)
        let fraction = maximumOffset > 0
            ? min(max(Double(offset / maximumOffset), 0), 1)
            : 0
        if abs(verticalScrollFraction - fraction) > 0.000_1 {
            verticalScrollFraction = fraction
        }
    }

    func scroll(toFraction requestedFraction: Double) {
        let fraction = min(max(requestedFraction, 0), 1)
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maximumOffset = max(0, documentHeight - clipView.bounds.height)
        let targetOffset = CGFloat(fraction) * maximumOffset
        guard abs(clipView.bounds.origin.y - targetOffset) > 0.5 else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetOffset))
        scrollView.reflectScrolledClipView(clipView)
        verticalScrollOffset = Double(targetOffset)
        updateScrollFraction(using: clipView, offset: targetOffset)
    }

    @objc
    private func undoManagerChangedText(_ notification: Notification) {
        invalidateSyntaxApplication()
        lineNumberRuler.updateText(textView.string)
        if !textView.hasActiveComposition {
            engineClient.submit(
                text: textView.string,
                selectionUTF16: textView.selectedRange()
            )
        }
        updateBoundText?(textView.string)
        localTextProjectionDidPublish?(textView.string)
        scheduleRenderedPresentation(for: textView.string)
    }

    @discardableResult
    func focusEditor() -> Bool {
        guard let window = textView.window else { return false }
        return window.makeFirstResponder(textView)
    }

    fileprivate func updateSelectedRange(_ range: NSRange) {
        if selectedUTF16Range != range {
            selectedUTF16Range = range
            scheduleFormatInspection()
            scheduleRenderedInteractionPresentation()
        }
        syncRenderedTypingAttributes()
        refreshWritingModePresentation()
    }

    private func scheduleFormatInspection() {
        formatInspectionTask?.cancel()
        formatInspectionGeneration &+= 1
        let generation = formatInspectionGeneration
        let source = textView.string
        let selection = textView.selectedRange()
        guard !textView.hasActiveComposition, selection.length > 0 else {
            canClearFormat = false
            return
        }
        canClearFormat = false

        formatInspectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let result = await engineClient.canClearFormat(
                text: source,
                selectionUTF16: selection
            )
            guard !Task.isCancelled,
                  generation == formatInspectionGeneration,
                  UTF8Text.isExactlyEqual(textView.string, source),
                  textView.selectedRange() == selection
            else { return }
            canClearFormat = result
        }
    }

    fileprivate func synchronizeEngine(text: String, selection: NSRange) {
        guard role == .document, !textView.hasActiveComposition else { return }
        engineClient.submit(text: text, selectionUTF16: selection)
    }

    fileprivate var isRenderedProjection: Bool {
        role == .renderedProjection
    }

    /// SwiftUI is a projection of committed text. It must never replace a native
    /// composition transaction, or a local edit awaiting its Engine acknowledgement.
    fileprivate enum BoundTextUpdate {
        case deferred, unchanged, replaced
    }

    fileprivate func reconcileBoundText(_ boundText: String) -> BoundTextUpdate {
        guard !textView.hasActiveComposition else { return .deferred }
        guard role == .document else { return .unchanged }
        let changed = !preservesOptimisticText(over: boundText)
            && !UTF8Text.isExactlyEqual(textView.string, boundText)
        if changed {
            let selection = textView.selectedRange()
            textView.string = boundText
            let length = boundText.utf16.count
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        synchronizeEngine(text: textView.string, selection: textView.selectedRange())
        return changed ? .replaced : .unchanged
    }

    private func preservesOptimisticText(over boundText: String) -> Bool {
        guard let pendingOptimisticText else { return false }
        return UTF8Text.isExactlyEqual(textView.string, pendingOptimisticText)
            && !UTF8Text.isExactlyEqual(boundText, pendingOptimisticText)
    }

    func requestRestoration(_ state: MarkdownRestorationState) {
        pendingRestorationState = state
        applyPendingRestorationIfPossible()
    }

    func resetAfterExternalReload(_ text: String) {
        invalidateSyntaxApplication()
        pendingOptimisticText = nil
        deferredCompositionSnapshot = nil
        let previousSelection = textView.selectedRange()
        textView.string = text
        let utf16Length = (text as NSString).length
        let location = min(previousSelection.location, utf16Length)
        let length = min(previousSelection.length, utf16Length - location)
        let selection = NSRange(location: location, length: length)
        textView.setSelectedRange(selection)
        updateSelectedRange(selection)
        textView.undoManager?.removeAllActions()
        engineClient.reset(text: text, selectionUTF16: selection)
        lineNumberRuler.updateText(text)
        refreshWritingModePresentation()
    }

    fileprivate func applyPendingRestorationIfPossible() {
        guard let state = pendingRestorationState,
              textView.window != nil
        else {
            return
        }
        let utf16Length = (textView.string as NSString).length
        let location = min(state.selectedUTF16Location, utf16Length)
        let length = min(state.selectedUTF16Length, utf16Length - location)
        let range = NSRange(location: location, length: length)
        textView.setSelectedRange(range)
        updateSelectedRange(range)

        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        let maximumOffset = max(
            0,
            textView.bounds.height - scrollView.contentSize.height
        )
        let offset = min(CGFloat(state.verticalScrollOffset), maximumOffset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        verticalScrollOffset = Double(offset)
        updateScrollFraction(using: scrollView.contentView, offset: offset)
        pendingRestorationState = nil
    }

    @discardableResult
    func replaceCurrent(
        utf8Range: Range<Int>,
        with replacement: String,
        expectedText: String
    ) async -> Bool {
        guard textView.isEditable,
              !textView.hasActiveComposition,
              UTF8Text.isExactlyEqual(textView.string, expectedText),
              MarkdownSourceRange.navigationTarget(
                  forUTF8Range: utf8Range,
                  in: expectedText
              ) != nil
        else {
            return false
        }
        let selectionOffset = utf8Range.lowerBound + replacement.utf8.count
        guard let mutation = await engineClient.replace(
            text: expectedText,
            range: utf8Range,
            replacement: replacement,
            selectionBeforeUTF16: textView.selectedRange(),
            selectionAfterUTF8: selectionOffset..<selectionOffset,
            groupID: "replace"
        ) else { return false }
        return applyEngineMutation(mutation, plan: nil, actionName: "替换")
    }

    @discardableResult
    func replaceAll(
        utf8Ranges: [Range<Int>],
        with replacement: String,
        expectedText: String
    ) async -> Bool {
        guard textView.isEditable,
              UTF8Text.isExactlyEqual(textView.string, expectedText),
              !utf8Ranges.isEmpty
        else {
            return false
        }

        let sourceBytes = Array(expectedText.utf8)
        let replacementBytes = Array(replacement.utf8)
        var previousEnd = 0
        var outputSize = sourceBytes.count
        for utf8Range in utf8Ranges {
            guard utf8Range.lowerBound >= previousEnd,
                  let target = MarkdownSourceRange.navigationTarget(
                      forUTF8Range: utf8Range,
                      in: expectedText
                  ),
                  target.revealRange.length > 0
            else {
                return false
            }

            let removed = utf8Range.count
            let (afterRemoval, removalOverflow) = outputSize.subtractingReportingOverflow(removed)
            let (afterInsertion, insertionOverflow) = afterRemoval.addingReportingOverflow(
                replacementBytes.count
            )
            guard !removalOverflow, !insertionOverflow else { return false }
            outputSize = afterInsertion
            previousEnd = utf8Range.upperBound
        }

        var output: [UInt8] = []
        output.reserveCapacity(outputSize)
        var cursor = 0
        for utf8Range in utf8Ranges {
            output.append(contentsOf: sourceBytes[cursor..<utf8Range.lowerBound])
            output.append(contentsOf: replacementBytes)
            cursor = utf8Range.upperBound
        }
        output.append(contentsOf: sourceBytes[cursor...])

        let finalText = String(decoding: output, as: UTF8.self)
        let selectionOffset = finalText.utf8.count
        guard let mutation = await engineClient.replace(
            text: expectedText,
            range: 0..<expectedText.utf8.count,
            replacement: finalText,
            selectionBeforeUTF16: textView.selectedRange(),
            selectionAfterUTF8: selectionOffset..<selectionOffset,
            groupID: "replace_all"
        ) else { return false }
        return applyEngineMutation(mutation, plan: nil, actionName: "全部替换")
    }

}

@MainActor
final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var sourceTextView: NSTextView?
    private var sourceUTF8 = Data()
    private(set) var lineStarts = [0]

    init(textView: NSTextView, scrollView: NSScrollView) {
        sourceTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var lineCount: Int { lineStarts.count }

    func updateText(_ text: String) {
        let utf8 = Data(text.utf8)
        guard utf8 != sourceUTF8 else {
            needsDisplay = true
            return
        }
        sourceUTF8 = utf8
        var starts = [0]
        starts.reserveCapacity(max(1, text.utf8.count / 48))
        var utf16Offset = 0
        var previousWasCarriageReturn = false
        for codeUnit in text.utf16 {
            utf16Offset += 1
            if codeUnit == 0x0D {
                starts.append(utf16Offset)
                previousWasCarriageReturn = true
            } else if codeUnit == 0x0A {
                if previousWasCarriageReturn {
                    starts[starts.count - 1] = utf16Offset
                } else {
                    starts.append(utf16Offset)
                }
                previousWasCarriageReturn = false
            } else {
                previousWasCarriageReturn = false
            }
        }
        lineStarts = starts
        let digitCount = max(2, String(starts.count).count)
        ruleThickness = max(42, CGFloat(digitCount * 9 + 18))
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = sourceTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }

        NSColor.textBackgroundColor.setFill()
        rect.fill()
        layoutManager.ensureLayout(for: textContainer)
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect,
            in: textContainer
        )
        let visibleCharacters = layoutManager.characterRange(
            forGlyphRange: visibleGlyphs,
            actualGlyphRange: nil
        )
        let firstLine = max(0, insertionIndex(for: visibleCharacters.location) - 1)
        let lastVisibleCharacter = NSMaxRange(visibleCharacters)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        for index in firstLine..<lineStarts.count {
            let characterIndex = lineStarts[index]
            if characterIndex > lastVisibleCharacter && index > firstLine { break }
            guard let lineRect = lineRect(
                forUTF16Location: characterIndex,
                textView: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                continue
            }
            let rulerPoint = convert(
                NSPoint(x: 0, y: lineRect.minY),
                from: textView
            )
            let labelRect = NSRect(
                x: 4,
                y: rulerPoint.y + max(0, (lineRect.height - font.ascender + font.descender) / 2),
                width: ruleThickness - 12,
                height: max(font.pointSize + 4, lineRect.height)
            )
            String(index + 1).draw(in: labelRect, withAttributes: attributes)
        }
    }

    private func insertionIndex(for location: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] < location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func lineRect(
        forUTF16Location location: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        if location == textView.string.utf16.count {
            let extra = layoutManager.extraLineFragmentRect
            guard !extra.isEmpty else { return nil }
            return extra.offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
        }
        guard location < textView.string.utf16.count else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        return fragment.offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
    }
}

@MainActor
enum RenderedMarkdownLinkActivation {
    static func shouldNavigate(
        for modifierFlags: NSEvent.ModifierFlags,
        preference: LinkActivationPreference,
        isEditing: Bool = false
    ) -> Bool {
        guard preference == .singleClick else { return false }
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        let editingModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
        return modifiers.intersection(editingModifiers).isEmpty
            && (!isEditing || modifiers.contains(.command))
    }
}

enum RenderedMarkdownCaretStyleResolver {
    @MainActor
    static func insertionRect(_ nativeRect: NSRect, in textView: NSTextView, font: NSFont) -> NSRect {
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            return adjustedInsertionRect(nativeRect, font: font)
        }
        let location = min(textView.selectedRange().location, textView.string.utf16.count)
        let length = textView.string.utf16.count
        let line: NSRect
        if location == length, manager.extraLineFragmentTextContainer === container {
            line = manager.extraLineFragmentRect
        } else if length > 0 {
            let glyph = manager.glyphIndexForCharacter(at: min(location, length - 1))
            guard glyph < manager.numberOfGlyphs else { return adjustedInsertionRect(nativeRect, font: font) }
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        } else { return adjustedInsertionRect(nativeRect, font: font) }
        guard line.height > 0 else { return adjustedInsertionRect(nativeRect, font: font) }
        return adjustedInsertionRect(NSRect(x: nativeRect.minX, y: textView.textContainerOrigin.y + line.minY,
            width: nativeRect.width, height: line.height), font: font)
    }

    static func visibleAttributeLocation(
        forInsertionLocation insertion: Int,
        text: String,
        hiddenRanges: [NSRange]
    ) -> Int? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let location = min(max(0, insertion), source.length - 1)
        if !isHidden(location, in: hiddenRanges), !isLineEnding(source.character(at: location)) {
            return location
        }
        if let hidden = hiddenRanges.first(where: { NSLocationInRange(location, $0) }),
           let forward = firstVisibleLocation(
               from: NSMaxRange(hidden),
               through: source.length,
               direction: 1,
               source: source,
               hiddenRanges: hiddenRanges
           )
        {
            return forward
        }
        return firstVisibleLocation(
            from: min(insertion - 1, source.length - 1),
            through: -1,
            direction: -1,
            source: source,
            hiddenRanges: hiddenRanges
        )
    }

    static func adjustedInsertionRect(
        _ rect: NSRect,
        font: NSFont?,
        baselineY: CGFloat? = nil
    ) -> NSRect {
        guard let font else { return rect }
        let fontHeight = ceil(font.ascender - font.descender + font.leading)
        let height = max(1, fontHeight)
        let proposedY = baselineY.map { $0 - font.ascender } ?? (rect.midY - height / 2)
        // Preserve the line centre even when AppKit supplies a transient short rectangle.
        let originY = proposedY
        return NSRect(
            x: rect.origin.x,
            y: originY,
            width: max(1, rect.width),
            height: height
        )
    }

    private static func firstVisibleLocation(
        from start: Int,
        through limit: Int,
        direction: Int,
        source: NSString,
        hiddenRanges: [NSRange]
    ) -> Int? {
        var location = start
        while direction > 0 ? location < limit : location > limit {
            if location >= 0,
               location < source.length,
               !isHidden(location, in: hiddenRanges),
               !isLineEnding(source.character(at: location))
            {
                return location
            }
            location += direction
        }
        return nil
    }

    private static func isHidden(_ location: Int, in ranges: [NSRange]) -> Bool {
        ranges.contains(where: { NSLocationInRange(location, $0) })
    }

    private static func isLineEnding(_ value: unichar) -> Bool {
        value == 0x0A || value == 0x0D
    }
}

enum RenderedMarkdownQuoteGeometry {
    static func contiguousRanges(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else { result.append(range) }
        }
        return result
    }

    static func barRect(
        lineFragment: NSRect,
        textContainerOrigin: NSPoint,
        font: NSFont,
        baselineOffset: CGFloat
    ) -> NSRect {
        let textHeight = max(1, font.ascender - font.descender)
        let fontBoxMinY = textContainerOrigin.y
            + lineFragment.minY
            + baselineOffset
            - font.ascender
        return NSRect(
            x: textContainerOrigin.x + lineFragment.minX + 4,
            y: fontBoxMinY,
            width: 3,
            height: textHeight
        )
    }
}

enum RenderedMarkdownInlineCodeGeometry {
    static func backgroundRect(
        glyphRect: NSRect,
        lineFragment: NSRect,
        textContainerOrigin: NSPoint,
        font: NSFont,
        baselineOffset: CGFloat
    ) -> NSRect {
        let horizontalPadding = MarkdownRenderMetrics.inlineCodeHorizontalPadding
        let verticalPadding = MarkdownRenderMetrics.inlineCodeVerticalPadding
        let textHeight = max(1, ceil(font.ascender - font.descender))
        let textMinY = textContainerOrigin.y
            + lineFragment.minY
            + baselineOffset
            - font.ascender
        return NSRect(
            x: textContainerOrigin.x + glyphRect.minX - horizontalPadding,
            y: textMinY - verticalPadding,
            width: max(1, glyphRect.width + horizontalPadding * 2),
            height: textHeight + verticalPadding * 2
        )
    }
}

enum RenderedMarkdownMarkerTypography {
    static func font(for kind: RenderedMarkdownMarkerKind, baseFont: NSFont) -> NSFont {
        if kind == .footnoteReference {
            return .systemFont(
                ofSize: max(9, baseFont.pointSize * 0.72),
                weight: .medium
            )
        }
        if kind == .unorderedList {
            return .systemFont(
                ofSize: baseFont.pointSize * MarkdownRenderMetrics.unorderedListMarkerScale,
                weight: .semibold
            )
        }
        return baseFont
    }

    static func originY(
        for kind: RenderedMarkdownMarkerKind,
        font: NSFont,
        baseFont: NSFont,
        lineRect: NSRect,
        baselineOffset: CGFloat? = nil
    ) -> CGFloat {
        let baseline = baselineOffset.map { lineRect.minY + $0 } ?? {
            let baseHeight = ceil(baseFont.ascender - baseFont.descender + baseFont.leading)
            return lineRect.minY
                + max(0, (lineRect.height - baseHeight) / 2)
                + baseFont.ascender
        }()
        let footnoteLift = kind == .footnoteReference ? lineRect.height * 0.22 : 0
        return baseline - font.ascender - footnoteLift
    }
}

@MainActor
final class WindowAwareTextView: NSTextView {

    private final class RenderedImageViewState {
        var sourceRange: NSRange
        let imageView: RenderedMarkdownImageView
        var renderedSize: NSSize
        let fillsAvailableWidth: Bool
        let placement: RenderedMarkdownImagePlacement

        init(
            sourceRange: NSRange,
            imageView: RenderedMarkdownImageView,
            renderedSize: NSSize,
            fillsAvailableWidth: Bool,
            placement: RenderedMarkdownImagePlacement
        ) {
            self.sourceRange = sourceRange
            self.imageView = imageView
            self.renderedSize = renderedSize
            self.fillsAvailableWidth = fillsAvailableWidth
            self.placement = placement
        }
    }

    private struct RenderedTableViewState {
        let sourceRange: NSRange
        let tableView: RenderedMarkdownTableView
    }

    private enum EngineTypingKind {
        case insertion
        case backwardDeletion
        case forwardDeletion
    }

    private let persistentUndoManager = UndoManager()
    var usesEngineHistory = false
    var engineCanUndo = false
    var engineCanRedo = false
    var engineUndoHandler: (() -> Void)?
    var engineRedoHandler: (() -> Void)?
    var didAttachToWindow: (() -> Void)?
    var focusDidChangeHandler: (() -> Void)?
    var effectiveAppearanceDidChangeHandler: (() -> Void)?
    var textDidChangeHandler: ((String) -> Void)?
    var compositionDidEndHandler: ((String, NSRange, Bool) -> Void)?
    var pasteImageHandler: ((ClipboardImagePayload) -> Void)?
    var dropImageHandler: ((URL) -> Void)?
    var linkClickHandler: ((Int) -> Bool)?
    var linkActivation = LinkActivationPreference.singleClick
    var clickableLinkRanges: [NSRange] = [] {
        didSet {
            guard oldValue != clickableLinkRanges else { return }
            if let hoveredLinkRange, !clickableLinkRanges.contains(hoveredLinkRange) {
                setHoveredLinkRange(nil)
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var renderedQuoteRanges: [NSRange] = [] {
        didSet {
            if oldValue != renderedQuoteRanges { needsDisplay = true }
        }
    }
    var renderedInlineCodeRanges: [NSRange] = [] {
        didSet {
            if oldValue != renderedInlineCodeRanges { needsDisplay = true }
        }
    }
    var renderedCodeBlockRanges: [NSRange] = [] {
        didSet {
            if oldValue != renderedCodeBlockRanges { needsDisplay = true }
        }
    }
    var renderedHeadingDividerRanges: [NSRange] = [] {
        didSet {
            if oldValue != renderedHeadingDividerRanges { needsDisplay = true }
        }
    }
    var renderedReplacementMarkers: [RenderedMarkdownMarker] = [] {
        didSet {
            if oldValue != renderedReplacementMarkers { needsDisplay = true }
        }
    }
    var renderedRuleRanges: [NSRange] = [] {
        didSet {
            if oldValue != renderedRuleRanges { needsDisplay = true }
        }
    }
    var isLiveMarkdown = false { didSet { updateReadingColumn() } }
    var readingColumnWidth = CGFloat(MarkdownRenderMetrics.readingWidth) { didSet { updateReadingColumn() } }
    var selectionVisibilityHandler: (() -> Void)?
    var markdownAutoPairEnabled = true
    var writingPlan: RenderedMarkdownPlan?
    private var insertedCloser: (location: Int, text: String)?
    var renderedAnchorSourceRanges: [NSRange] = []
    var renderedCollapsedSourceRanges: [NSRange] = []
    var renderedReplacementBaseFont = NSFont.systemFont(ofSize: 15)
    private var renderedImageViews: [Int: RenderedImageViewState] = [:]
    private var renderedTableViews: [Int: RenderedTableViewState] = [:]
    var pendingTableFocus: (location: Int, row: Int, column: Int)?
    private var tableFocusRestorations: [Int: (row: Int, column: Int, selection: NSRange)] = [:]
    private var tableSelectionRestorations: [Int: (anchor: (Int, Int), end: (Int, Int))] = [:]
    private var retainedRenderedOverlayKeys: Set<Int>?
    private var renderedImageLayoutTask: Task<Void, Never>?
    private var isUpdatingRenderedOverlayLayout = false
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredLinkRange: NSRange?
    private var engineTypingKind: EngineTypingKind?
    private var engineTypingGroupID: String?
    private var engineTypingDeadline = TimeInterval.zero
    private var pendingEngineEditGroupID: String?
    private var suppressesAutomaticEngineGrouping = false

    override var undoManager: UndoManager? {
        persistentUndoManager
    }

    private var drawnInsertionRect: NSRect?

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        let font = typingAttributes[.font] as? NSFont
        let target = flag ? renderedInsertionRect(rect, font: font)
            : (drawnInsertionRect ?? renderedInsertionRect(rect, font: font))
        super.drawInsertionPoint(in: target, color: color, turnedOn: flag)
        drawnInsertionRect = flag ? target : nil
    }

    func renderedInsertionRect(_ rect: NSRect, font: NSFont? = nil) -> NSRect {
        let candidate = font ?? typingAttributes[.font] as? NSFont
        let visibleFont = candidate.flatMap { $0.pointSize >= 1 ? $0 : nil } ?? renderedReplacementBaseFont
        return RenderedMarkdownCaretStyleResolver.insertionRect(rect, in: self, font: visibleFont)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearanceDidChangeHandler?()
    }

    func isRenderedCharacterSuppressed(at location: Int) -> Bool {
        guard renderedCollapsedSourceRanges.contains(where: { NSLocationInRange(location, $0) })
        else { return false }
        return !renderedAnchorSourceRanges.contains(where: {
            $0.length > 0 && $0.location == location
        })
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        updateReadingColumn()
        if sizeChanged, !renderedImageViews.isEmpty || !renderedTableViews.isEmpty {
            scheduleRenderedImageLayout()
        }
    }

    private func updateReadingColumn() {
        let inset = isLiveMarkdown ? max(MarkdownRenderMetrics.editorHorizontalInset,
            (bounds.width - readingColumnWidth) / 2) : MarkdownRenderMetrics.editorHorizontalInset
        guard abs(textContainerInset.width - inset) > 0.5 else { return }
        textContainerInset = NSSize(width: inset, height: textContainerInset.height)
        scheduleRenderedImageLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            didAttachToWindow?()
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTrackingArea = tracking
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = localPoint(forWindowPoint: event.locationInWindow)
        updateHoveredLink(atLocalPoint: point)
        super.mouseMoved(with: event)
        cursorForRenderedContent(atLocalPoint: point).set()
    }

    func cursorForRenderedContent(atLocalPoint point: NSPoint) -> NSCursor {
        clickableLinkLocation(at: point) == nil ? .iBeam : .pointingHand
    }

    func updateHoveredLink(atLocalPoint point: NSPoint) {
        let location = clickableLinkLocation(at: point)
        setHoveredLinkRange(
            location.flatMap { location in
                clickableLinkRanges.first(where: { NSLocationInRange(location, $0) })
            }
        )
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredLinkRange(nil)
        super.mouseExited(with: event)
    }

    private func setHoveredLinkRange(_ range: NSRange?) {
        guard hoveredLinkRange != range else { return }
        if let hoveredLinkRange {
            layoutManager?.removeTemporaryAttribute(
                .underlineStyle,
                forCharacterRange: hoveredLinkRange
            )
        }
        hoveredLinkRange = range
        if let range {
            layoutManager?.addTemporaryAttribute(
                .underlineStyle,
                value: MarkdownLinkVisualStyle.hoverUnderline,
                forCharacterRange: range
            )
        }
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { focusDidChangeHandler?() }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { focusDidChangeHandler?() }
        return resignedFirstResponder
    }

    func clearRenderedImages() {
        renderedImageLayoutTask?.cancel()
        renderedImageLayoutTask = nil
        renderedImageViews.values.forEach { $0.imageView.removeFromSuperview() }
        renderedImageViews.removeAll()
        renderedTableViews.values.forEach { $0.tableView.removeFromSuperview() }
        renderedTableViews.removeAll()
    }

    func beginRenderedOverlayUpdate() {
        retainedRenderedOverlayKeys = []
    }

    func endRenderedOverlayUpdate() {
        guard let retainedRenderedOverlayKeys else { return }
        for key in renderedImageViews.keys where !retainedRenderedOverlayKeys.contains(key) {
            renderedImageViews.removeValue(forKey: key)?.imageView.removeFromSuperview()
        }
        for key in renderedTableViews.keys where !retainedRenderedOverlayKeys.contains(key) {
            renderedTableViews.removeValue(forKey: key)?.tableView.removeFromSuperview()
        }
        self.retainedRenderedOverlayKeys = nil
        scheduleRenderedImageLayout()
    }

    @discardableResult
    fileprivate func setRenderedImage(
        _ image: NSImage,
        alternative: String,
        sourceRange: NSRange,
        fillsAvailableWidth: Bool,
        placement: RenderedMarkdownImagePlacement = .replacesSource
    ) -> NSSize {
        let key = sourceRange.location
        retainedRenderedOverlayKeys?.insert(key)
        let viewportWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let availableWidth = max(
            160,
            viewportWidth - textContainerInset.width * 2
                - (textContainer?.lineFragmentPadding ?? 0) * 2
        )
        let renderedSize = Self.fittedRenderedImageSize(
            image.size,
            availableWidth: availableWidth,
            fillsAvailableWidth: fillsAvailableWidth
        )
        let imageView: RenderedMarkdownImageView
        if let existing = renderedImageViews[key],
           existing.sourceRange == sourceRange,
           existing.fillsAvailableWidth == fillsAvailableWidth,
           existing.placement == placement
        {
            imageView = existing.imageView
            existing.renderedSize = renderedSize
        } else {
            renderedImageViews[key]?.imageView.removeFromSuperview()
            imageView = RenderedMarkdownImageView()
            imageView.imageScaling = .scaleProportionallyDown
            addSubview(imageView)
            renderedImageViews[key] = RenderedImageViewState(
                sourceRange: sourceRange,
                imageView: imageView,
                renderedSize: renderedSize,
                fillsAvailableWidth: fillsAvailableWidth,
                placement: placement
            )
        }
        imageView.image = image
        imageView.contentTintColor = image.isTemplate ? .labelColor : nil
        imageView.presentsDiagram = alternative == "Mermaid 图表"
        imageView.setFrameSize(renderedSize)
        imageView.setAccessibilityLabel(alternative.isEmpty ? "图片" : alternative)
        scheduleRenderedImageLayout()
        return renderedSize
    }

    func renderedImage(atUTF16Location location: Int) -> NSImage? {
        renderedImageViews[location]?.imageView.image
    }

    func renderedImageSize(atUTF16Location location: Int) -> NSSize? {
        renderedImageViews[location]?.renderedSize
    }

    private static func fittedRenderedImageSize(
        _ intrinsicSize: NSSize,
        availableWidth: CGFloat,
        fillsAvailableWidth: Bool
    ) -> NSSize {
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else {
            return NSSize(width: 1, height: 1)
        }
        let widthLimit = max(
            1,
            fillsAvailableWidth ? availableWidth : min(760, availableWidth)
        )
        let widthScale = widthLimit / intrinsicSize.width
        let heightScale = 480 / intrinsicSize.height
        let scale = min(1, widthScale, heightScale)
        return NSSize(
            width: max(1, intrinsicSize.width * scale),
            height: max(1, intrinsicSize.height * scale)
        )
    }

    @discardableResult
    func setRenderedTable(
        _ table: RenderedMarkdownTable,
        baseFont: NSFont,
        maximumWidth: CGFloat,
        linkActivation: LinkActivationPreference,
        onLinkClick: @escaping (String) -> Void,
        onEdit: @escaping (RenderedMarkdownTableEdit) -> Void
    ) -> NSSize {
        let key = table.sourceRange.utf16Range.location
        let previousFocus = renderedTableViews[key]?.tableView.focusedCell
        let previousAnchor = renderedTableViews[key]?.tableView.selectionAnchor
        let previousEnd = renderedTableViews[key]?.tableView.selectionEnd
        defer {
            if let anchor = previousAnchor, let end = previousEnd {
                tableSelectionRestorations[key] = (anchor, end)
            }
            if let previousFocus { tableFocusRestorations[key] = previousFocus }
        }
        retainedRenderedOverlayKeys?.insert(key)
        if let existing = renderedTableViews[key],
           existing.tableView.linkActivation == linkActivation
        {
            if existing.tableView.table == table
                || existing.tableView.hasSameLiveRenderedContent(as: table)
                || existing.tableView.appendRowsIfPossible(table, onEdit: onEdit)
            {
                existing.tableView.applyPalette(
                    MarkdownRenderPalette.resolved(for: effectiveAppearance)
                )
                existing.tableView.setEditingEnabled(isEditable)
                existing.tableView.update(table: table, onEdit: onEdit)
                existing.tableView.updateMaximumWidth(maximumWidth)
                renderedTableViews[key] = RenderedTableViewState(sourceRange: table.sourceRange.utf16Range, tableView: existing.tableView)
                return existing.tableView.renderedSize
            }
        }
        if let reusable = renderedTableViews.first(where: { oldKey, state in
            oldKey != key
                && retainedRenderedOverlayKeys?.contains(oldKey) != true
                && state.tableView.hasSameRenderedContent(as: table)
                && state.tableView.linkActivation == linkActivation
        }) {
            renderedTableViews.removeValue(forKey: reusable.key)
            reusable.value.tableView.applyPalette(
                MarkdownRenderPalette.resolved(for: effectiveAppearance)
            )
            reusable.value.tableView.setEditingEnabled(isEditable)
            reusable.value.tableView.update(table: table, onEdit: onEdit)
            reusable.value.tableView.updateMaximumWidth(maximumWidth)
            renderedTableViews[key] = RenderedTableViewState(
                sourceRange: table.sourceRange.utf16Range,
                tableView: reusable.value.tableView
            )
            scheduleRenderedImageLayout()
            return reusable.value.tableView.renderedSize
        }
        renderedTableViews[key]?.tableView.removeFromSuperview()
        let tableView = RenderedMarkdownTableView(
            table: table,
            baseFont: baseFont,
            maximumWidth: maximumWidth,
            linkActivation: linkActivation,
            palette: MarkdownRenderPalette.resolved(for: effectiveAppearance),
            onLinkClick: onLinkClick,
            onEdit: onEdit
        )
        tableView.setEditingEnabled(isEditable)
        addSubview(tableView)
        renderedTableViews[key] = RenderedTableViewState(
            sourceRange: table.sourceRange.utf16Range,
            tableView: tableView
        )
        scheduleRenderedImageLayout()
        return tableView.renderedSize
    }

    func rebaseRenderedRanges(replacing old: NSRange, withLength length: Int) {
        let delta = length - old.length
        func shifted(_ range: NSRange) -> NSRange {
            if range == old { return NSRange(location: old.location, length: length) }
            if range.location >= NSMaxRange(old) { return NSRange(location: range.location + delta, length: range.length) }
            return range
        }
        renderedAnchorSourceRanges = renderedAnchorSourceRanges.map(shifted)
        renderedCollapsedSourceRanges = renderedCollapsedSourceRanges.map(shifted)
        renderedCodeBlockRanges = renderedCodeBlockRanges.map(shifted)
        renderedQuoteRanges = renderedQuoteRanges.map(shifted)
        renderedInlineCodeRanges = renderedInlineCodeRanges.map(shifted)
        renderedHeadingDividerRanges = renderedHeadingDividerRanges.map(shifted)
        clickableLinkRanges = clickableLinkRanges.map(shifted)
        renderedRuleRanges = renderedRuleRanges.map(shifted)
        renderedReplacementMarkers = renderedReplacementMarkers.map {
            RenderedMarkdownMarker(kind: $0.kind, sourceRange: RenderedMarkdownSourceRange(utf8Range: $0.sourceRange.utf8Range,
                utf16Range: shifted($0.sourceRange.utf16Range)), replacementText: $0.replacementText)
        }
        renderedImageViews = Dictionary(uniqueKeysWithValues: renderedImageViews.values.map { state in
            state.sourceRange = shifted(state.sourceRange)
            return (state.sourceRange.location, state)
        })
        renderedTableViews = Dictionary(uniqueKeysWithValues: renderedTableViews.values.map { state in
            let range = shifted(state.sourceRange)
            return (range.location, RenderedTableViewState(sourceRange: range, tableView: state.tableView))
        })
    }

    func finishPendingInputForCheckpoint() {
        if hasMarkedText() { unmarkText() }
        for state in renderedTableViews.values { state.tableView.finishPendingInputForCheckpoint() }
    }

    func renderedTable(atUTF16Location location: Int) -> RenderedMarkdownTableView? {
        renderedTableViews[location]?.tableView
    }

    private func scheduleRenderedImageLayout() {
        renderedImageLayoutTask?.cancel()
        renderedImageLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.layoutRenderedImages()
        }
    }

    fileprivate func layoutRenderedImages() {
        guard let layoutManager, let textContainer, !isUpdatingRenderedOverlayLayout else { return }
        isUpdatingRenderedOverlayLayout = true
        defer { isUpdatingRenderedOverlayLayout = false }
        let viewportWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let availableWidth = max(
            160,
            viewportWidth - textContainerInset.width * 2 - textContainer.lineFragmentPadding * 2
        )
        if let storage = textStorage {
            let resizedImages = renderedImageViews.values.compactMap {
                state -> (NSRange, NSSize, RenderedMarkdownImagePlacement)? in
                guard let image = state.imageView.image else { return nil }
                let size = Self.fittedRenderedImageSize(
                    image.size,
                    availableWidth: availableWidth,
                    fillsAvailableWidth: state.fillsAvailableWidth
                )
                guard size != state.renderedSize else { return nil }
                state.renderedSize = size
                return (state.sourceRange, size, state.placement)
            }
            let resizedTables = renderedTableViews.values.compactMap { state -> (NSRange, NSSize)? in
                state.tableView.updateMaximumWidth(availableWidth)
                    ? (state.sourceRange, state.tableView.renderedSize)
                    : nil
            }
            if !resizedImages.isEmpty || !resizedTables.isEmpty {
                let undoManager = undoManager
                let restoresUndo = undoManager?.isUndoRegistrationEnabled == true
                if restoresUndo { undoManager?.disableUndoRegistration() }
                storage.beginEditing()
                for (range, size, placement) in resizedImages
                where range.length > 0 && NSMaxRange(range) <= storage.length {
                    switch placement {
                    case .replacesSource:
                        storage.addAttribute(
                            .kern,
                            value: size.width,
                            range: NSRange(location: range.location, length: 1)
                        )
                        let paragraph = (
                            storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                                as? NSParagraphStyle
                        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                        paragraph.minimumLineHeight = size.height + 10
                        paragraph.maximumLineHeight = size.height + 10
                        storage.addAttribute(
                            .paragraphStyle,
                            value: paragraph,
                            range: NSRange(location: range.location, length: 1)
                        )
                    case .belowSource:
                        guard let anchor = Self.lastVisibleCharacterLocation(
                            in: range,
                            text: storage.string
                        ) else { continue }
                        let paragraphRange = storage.mutableString.paragraphRange(
                            for: NSRange(location: anchor, length: 0)
                        )
                        let paragraph = (
                            storage.attribute(.paragraphStyle, at: anchor, effectiveRange: nil)
                                as? NSParagraphStyle
                        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                        paragraph.paragraphSpacing = size.height + 18
                        storage.addAttribute(
                            .paragraphStyle,
                            value: paragraph,
                            range: paragraphRange
                        )
                    }
                }
                for (range, size) in resizedTables
                where range.length > 0 && NSMaxRange(range) <= storage.length {
                    let paragraph = (
                        storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                            as? NSParagraphStyle
                    )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    paragraph.minimumLineHeight = size.height + 10
                    paragraph.maximumLineHeight = size.height + 10
                    storage.addAttribute(
                        .paragraphStyle,
                        value: paragraph,
                        range: NSRange(location: range.location, length: 1)
                    )
                }
                storage.endEditing()
                if restoresUndo { undoManager?.enableUndoRegistration() }
            }
        }
        layoutManager.ensureLayout(for: textContainer)
        for state in renderedImageViews.values {
            guard state.sourceRange.location < string.utf16.count else {
                state.imageView.isHidden = true
                continue
            }
            let anchorLocation: Int
            switch state.placement {
            case .replacesSource:
                anchorLocation = state.sourceRange.location
            case .belowSource:
                guard let location = Self.lastVisibleCharacterLocation(
                    in: state.sourceRange,
                    text: string
                ) else {
                    state.imageView.isHidden = true
                    continue
                }
                anchorLocation = location
            }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: anchorLocation)
            guard glyphIndex < layoutManager.numberOfGlyphs,
                  state.imageView.image != nil
            else {
                state.imageView.isHidden = true
                continue
            }
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            state.imageView.frame = NSRect(
                x: state.placement == .belowSource
                    ? textContainerOrigin.x + lineRect.minX
                    : textContainerOrigin.x + glyphRect.minX,
                y: state.placement == .belowSource
                    ? textContainerOrigin.y + lineRect.minY + layoutManager.location(forGlyphAt: glyphIndex).y
                        - ((textStorage?.attribute(.font, at: anchorLocation, effectiveRange: nil) as? NSFont)?.descender ?? 0) + 10
                    : textContainerOrigin.y + lineRect.minY + 5,
                width: state.renderedSize.width,
                height: state.renderedSize.height
            )
            state.imageView.isHidden = false
        }
        for state in renderedTableViews.values {
            guard state.sourceRange.location < string.utf16.count else {
                state.tableView.isHidden = true
                continue
            }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: state.sourceRange.location)
            guard glyphIndex < layoutManager.numberOfGlyphs else {
                state.tableView.isHidden = true
                continue
            }
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            state.tableView.frame = NSRect(
                x: textContainerOrigin.x + glyphRect.minX,
                y: textContainerOrigin.y + lineRect.minY + 5,
                width: state.tableView.renderedSize.width,
                height: state.tableView.renderedSize.height
            )
            state.tableView.isHidden = false
        }
        for (key, focus) in tableFocusRestorations {
            if let table = renderedTableViews[key]?.tableView, table.focusedCell == nil {
                _ = table.focusCell(row: focus.row, column: focus.column, selection: focus.selection, scroll: false)
            }
        }
        tableFocusRestorations.removeAll()
        for (key, selection) in tableSelectionRestorations {
            renderedTableViews[key]?.tableView.selectCells(from: selection.anchor, to: selection.end, scroll: false)
        }
        tableSelectionRestorations.removeAll()
        if let pending = pendingTableFocus,
           renderedTableViews[pending.location]?.tableView.focusCell(row: pending.row, column: pending.column) == true {
            pendingTableFocus = nil
        }
    }

    fileprivate static func lastVisibleCharacterLocation(
        in range: NSRange,
        text: String
    ) -> Int? {
        guard range.length > 0 else { return nil }
        let source = text as NSString
        var location = min(NSMaxRange(range), source.length) - 1
        while location >= range.location {
            let character = source.character(at: location)
            if character != 0x0A && character != 0x0D {
                return location
            }
            location -= 1
        }
        return nil
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let palette = MarkdownRenderPalette.resolved(for: effectiveAppearance)
        palette.inlineCodeColor.setFill()
        for characterRange in renderedInlineCodeRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect, _, _, lineGlyphRange, _ in
                let segment = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard segment.length > 0 else { return }
                let character = layoutManager.characterIndexForGlyph(at: segment.location)
                guard let font = self.textStorage?.attribute(
                    .font,
                    at: character,
                    effectiveRange: nil
                ) as? NSFont else { return }
                let glyphRect = layoutManager.boundingRect(
                    forGlyphRange: segment,
                    in: textContainer
                )
                let background = RenderedMarkdownInlineCodeGeometry.backgroundRect(
                    glyphRect: glyphRect,
                    lineFragment: lineRect,
                    textContainerOrigin: self.textContainerOrigin,
                    font: font,
                    baselineOffset: layoutManager.location(forGlyphAt: segment.location).y
                )
                guard background.intersects(rect) else { return }
                NSBezierPath(
                    roundedRect: background,
                    xRadius: MarkdownRenderMetrics.inlineCodeCornerRadius,
                    yRadius: MarkdownRenderMetrics.inlineCodeCornerRadius
                ).fill()
            }
        }
        for characterRange in renderedCodeBlockRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var backgroundRect = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect, _, _, _, _ in
                backgroundRect = backgroundRect.union(lineRect)
            }
            guard !backgroundRect.isNull else { continue }
            let localMinX = backgroundRect.minX
            backgroundRect = NSRect(
                x: textContainerOrigin.x + localMinX,
                y: textContainerOrigin.y + backgroundRect.minY,
                width: max(
                    backgroundRect.width,
                    textContainer.size.width - localMinX - textContainer.lineFragmentPadding
                ),
                height: backgroundRect.height
            )
            backgroundRect = backgroundRect.insetBy(dx: 0, dy: -4)
            guard backgroundRect.intersects(rect) else { continue }
            palette.subtleSurfaceColor.setFill()
            palette.borderColor.setStroke()
            let path = NSBezierPath(
                roundedRect: backgroundRect,
                xRadius: MarkdownRenderMetrics.blockCornerRadius,
                yRadius: MarkdownRenderMetrics.blockCornerRadius
            )
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
        palette.borderColor.withAlphaComponent(0.72).setFill()
        for characterRange in renderedHeadingDividerRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let lastGlyph = min(
                layoutManager.numberOfGlyphs - 1,
                NSMaxRange(glyphRange) - 1
            )
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: lastGlyph,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let startX = textContainerOrigin.x + lineRect.minX
            let endX = textContainerOrigin.x + textContainer.size.width
                - textContainer.lineFragmentPadding
            let divider = NSRect(
                x: startX,
                y: textContainerOrigin.y + lineRect.maxY - 1,
                width: max(1, endX - startX),
                height: 1
            )
            if divider.intersects(rect) { divider.fill() }
        }
        palette.quoteBarColor.setFill()
        for characterRange in renderedQuoteRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            var blockBar = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect, _, _, lineGlyphRange, _ in
                guard lineGlyphRange.length > 0 else { return }
                let lineCharacterRange = layoutManager.characterRange(
                    forGlyphRange: lineGlyphRange,
                    actualGlyphRange: nil
                )
                var visibleLocation = lineCharacterRange.location
                while visibleLocation < NSMaxRange(lineCharacterRange),
                      self.isRenderedCharacterSuppressed(at: visibleLocation)
                {
                    visibleLocation += 1
                }
                let baselineGlyph = visibleLocation < NSMaxRange(lineCharacterRange)
                    ? layoutManager.glyphIndexForCharacter(at: visibleLocation)
                    : lineGlyphRange.location
                let bar = RenderedMarkdownQuoteGeometry.barRect(
                    lineFragment: lineRect,
                    textContainerOrigin: self.textContainerOrigin,
                    font: self.renderedReplacementBaseFont,
                    baselineOffset: visibleLocation < NSMaxRange(lineCharacterRange)
                        ? layoutManager.location(forGlyphAt: baselineGlyph).y
                        : (lineRect.height - self.renderedReplacementBaseFont.ascender + self.renderedReplacementBaseFont.descender) / 2
                            + self.renderedReplacementBaseFont.ascender
                )
                blockBar = blockBar.union(bar)
            }
            if !blockBar.isNull, blockBar.intersects(rect) {
                NSBezierPath(
                    roundedRect: blockBar,
                    xRadius: 1.5,
                    yRadius: 1.5
                ).fill()
            }
        }
        palette.borderColor.setStroke()
        for characterRange in renderedRuleRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let y = textContainerOrigin.y + lineRect.midY
            let startX = textContainerOrigin.x + lineRect.minX
            let endX = textContainerOrigin.x + textContainer.size.width
                - textContainer.lineFragmentPadding
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: startX, y: y))
            path.line(to: NSPoint(x: endX, y: y))
            let strokeRect = NSRect(
                x: startX,
                y: y - 1,
                width: max(1, endX - startX),
                height: 2
            )
            if strokeRect.intersects(rect) { path.stroke() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        for marker in renderedReplacementMarkers {
            let range = marker.sourceRange.utf16Range
            guard let text = marker.replacementText,
                  range.length > 0,
                  NSMaxRange(range) <= (string as NSString).length
            else { continue }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyphIndex < layoutManager.numberOfGlyphs else { continue }
            var lineGlyphRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            let font = RenderedMarkdownMarkerTypography.font(
                for: marker.kind,
                baseFont: renderedReplacementBaseFont
            )
            let lineCharacterRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            var contentLocation = NSMaxRange(range)
            while contentLocation < NSMaxRange(lineCharacterRange) {
                let candidateFont = textStorage?.attribute(
                    .font,
                    at: contentLocation,
                    effectiveRange: nil
                ) as? NSFont
                if candidateFont?.pointSize ?? 0 >= 1 {
                    break
                }
                contentLocation += 1
            }
            let baselineGlyph = contentLocation < NSMaxRange(lineCharacterRange)
                ? layoutManager.glyphIndexForCharacter(at: contentLocation)
                : glyphIndex
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: marker.kind == .footnoteReference
                    ? NSColor.linkColor
                    : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let point = NSPoint(
                x: textContainerOrigin.x + glyphRect.minX,
                y: textContainerOrigin.y + RenderedMarkdownMarkerTypography.originY(
                    for: marker.kind,
                    font: font,
                    baseFont: renderedReplacementBaseFont,
                    lineRect: lineRect,
                    baselineOffset: layoutManager.location(forGlyphAt: baselineGlyph).y
                )
            )
            let drawRect = NSRect(origin: point, size: size)
            if drawRect.intersects(dirtyRect) {
                (text as NSString).draw(at: point, withAttributes: attributes)
            }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        textDidChangeHandler?(string)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if compositionBaseline == nil { compositionBaseline = self.string }
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        if !hasMarkedText() { finishCompositionIfNeeded() }
    }

    override func unmarkText() {
        super.unmarkText()
        finishCompositionIfNeeded()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let wasComposing = hasActiveComposition
        let effectiveRange = replacementRange.location == NSNotFound
            ? selectedRange()
            : replacementRange
        if !wasComposing, !suppressesAutomaticEngineGrouping, isLiveMarkdown, isEditable,
           markdownAutoPairEnabled, let input = Self.plainText(from: insertString), input.count == 1 {
            if let closer = insertedCloser, effectiveRange.length == 0,
               effectiveRange.location == closer.location, input == closer.text,
               closer.location + input.utf16.count <= string.utf16.count,
               (string as NSString).substring(with: NSRange(location: closer.location, length: input.utf16.count)) == input {
                setSelectedRange(NSRange(location: closer.location + input.utf16.count, length: 0))
                insertedCloser = nil
                breakEngineTypingGroup()
                return
            }
            if ["(", "[", "{", "`", "*", "_", "~"].contains(input),
               canUseWritingRules, let edit = MarkdownWritingRules.pair(input, source: string, selection: effectiveRange) {
                if applyWritingEdit(edit) {
                    insertedCloser = (NSMaxRange(edit.selection), String(edit.text.suffix(1)))
                    return
                }
            }
        }
        let previousCloser = insertedCloser
        insertedCloser = nil
        if !wasComposing,
           !suppressesAutomaticEngineGrouping,
           effectiveRange.length == 0,
           let inserted = Self.plainText(from: insertString),
           inserted.count == 1,
           !inserted.contains(where: \.isNewline)
        {
            prepareEngineTypingGroup(.insertion)
        } else {
            breakEngineTypingGroup()
        }
        super.insertText(insertString, replacementRange: replacementRange)
        if !wasComposing, let previousCloser, effectiveRange.length == 0,
           effectiveRange.location == previousCloser.location,
           let inserted = Self.plainText(from: insertString), !inserted.contains(where: \.isNewline) {
            insertedCloser = (previousCloser.location + inserted.utf16.count, previousCloser.text)
        }
        if wasComposing, !hasMarkedText() {
            finishCompositionIfNeeded()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if canUseWritingRules {
            let selection = selectedRange()
            if markdownAutoPairEnabled, selection.length == 0, selection.location > 0,
               selection.location < string.utf16.count {
                let text = string as NSString
                let left = text.substring(with: NSRange(location: selection.location - 1, length: 1))
                let right = text.substring(with: NSRange(location: selection.location, length: 1))
                if ["(": ")", "[": "]", "{": "}", "`": "`" ][left] == right,
                   applyWritingEdit(MarkdownWritingEdit(range: NSRange(location: selection.location - 1, length: 2),
                       text: "", selection: NSRange(location: selection.location - 1, length: 0))) { return }
            }
            if performEditingIntent(.mergeBackward) { return }
        }
        if !suppressesAutomaticEngineGrouping, selectedRange().length == 0 {
            prepareEngineTypingGroup(.backwardDeletion)
        } else {
            breakEngineTypingGroup()
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if !suppressesAutomaticEngineGrouping, selectedRange().length == 0 {
            prepareEngineTypingGroup(.forwardDeletion)
        } else {
            breakEngineTypingGroup()
        }
        super.deleteForward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if performEditingIntent(.paragraphBreak) { normalizeInsertedLine(); return }
        breakEngineTypingGroup()
        super.insertNewline(sender)
        normalizeInsertedLine()
    }

    override func insertLineBreak(_ sender: Any?) {
        if performEditingIntent(.lineBreak) { normalizeInsertedLine(); return }
        super.insertLineBreak(sender)
    }

    @discardableResult
    private func performEditingIntent(_ intent: MarkdownEditingIntent) -> Bool {
        guard isLiveMarkdown, isEditable, !hasActiveComposition else { return false }
        let plan = writingPlan?.exactlyMatches(string) == true ? writingPlan! : RenderedMarkdownEditor.plan(for: string)
        guard let edit = MarkdownEditingTransaction.plan(intent, source: string, selection: selectedRange(), renderPlan: plan) else { return false }
        return applyWritingEdit(edit)
    }

    private func normalizeInsertedLine() {
        guard isLiveMarkdown, !hasMarkedText(), let storage = textStorage else { return }
        let candidate = typingAttributes[.font] as? NSFont
        let font = candidate.flatMap { $0.pointSize >= 1 ? $0 : nil } ?? renderedReplacementBaseFont
        let source = string as NSString
        let range = source.lineRange(for: selectedRange())
        guard source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        typingAttributes[.font] = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(font.pointSize * 1.6, font.ascender - font.descender + font.leading)
        typingAttributes[.paragraphStyle] = paragraph
        if range.length > 0 { storage.addAttributes(typingAttributes, range: range) }
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }

    private func editableCodeRequest(at location: Int? = nil) -> JavaScriptRenderRequest? {
        guard isLiveMarkdown, isEditable, !hasActiveComposition else { return nil }
        let plan = writingPlan?.exactlyMatches(string) == true ? writingPlan! : RenderedMarkdownEditor.plan(for: string)
        let selection = location.map { NSRange(location: $0, length: 0) } ?? selectedRange()
        return plan.renderRequests.first {
            $0.kind != "math" && selection.location >= $0.contentRange.utf16Range.location
                && NSMaxRange(selection) <= NSMaxRange($0.contentRange.utf16Range)
                && selection.location < NSMaxRange($0.contentRange.utf16Range)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isLiveMarkdown, isEditable, !hasMarkedText(),
              let request = RenderedMarkdownEditor.plan(for: string).renderRequests.first(where: {
                  NSLocationInRange(selectedRange().location, $0.sourceRange.utf16Range)
              }) else { super.cancelOperation(sender); return }
        let end = NSMaxRange(request.sourceRange.utf16Range)
        setSelectedRange(NSRange(location: end, length: 0))
        if end == string.utf16.count {
            _ = applyWritingEdit(MarkdownWritingEdit(range: selectedRange(), text: "\n\n",
                selection: NSRange(location: end + 2, length: 0)))
        }
    }

    private var canUseWritingRules: Bool {
        guard isLiveMarkdown, isEditable, !hasActiveComposition,
              !suppressesAutomaticEngineGrouping else { return false }
        // Refresh only for an explicit editing gesture when async derivation is stale.
        // Syntax interpretation remains in Rust, including unfinished fenced blocks.
        let plan = writingPlan?.exactlyMatches(string) == true ? writingPlan! : RenderedMarkdownEditor.plan(for: string)
        let selection = selectedRange()
        return !(plan.localSourceBlocks.map(\.sourceRange.utf16Range)
            + plan.renderRequests.filter { $0.kind == "math" }.map(\.sourceRange.utf16Range)
            + plan.tables.map(\.sourceRange.utf16Range)
            + plan.contentStyles.filter { $0.kind == .inlineCode || $0.kind == .inlineMath }.map(\.sourceRange.utf16Range)).contains {
                (selection.location >= $0.location && selection.location < NSMaxRange($0))
                    || NSIntersectionRange(selection, $0).length > 0
            }
    }

    @discardableResult
    private func applyWritingEdit(_ edit: MarkdownWritingEdit) -> Bool {
        guard NSMaxRange(edit.range) <= string.utf16.count,
              shouldChangeText(in: edit.range, replacementString: edit.text), let storage = textStorage else { return false }
        breakEngineTypingGroup()
        insertedCloser = nil
        storage.replaceCharacters(in: edit.range, with: edit.text)
        setSelectedRange(edit.selection)
        didChangeText()
        scrollRangeToVisible(edit.selection)
        return true
    }

    func replaceRenderedTableSource(_ replacement: String, range: NSRange) {
        guard isEditable, !hasMarkedText(), let storage = textStorage,
              NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: replacement) else { return }
        breakEngineTypingGroup()
        let original = (string as NSString).substring(with: range)
        guard let diff = EditorEngineTextDiff.replacement(from: original, to: replacement),
              let target = MarkdownSourceRange.navigationTarget(forUTF8Range: diff.start..<diff.end, in: original) else { return }
        storage.replaceCharacters(in: NSRange(location: range.location + target.revealRange.location, length: target.revealRange.length), with: diff.inserted)
        setSelectedRange(NSRange(location: range.location, length: 0))
        didChangeText()
    }

    private func handleWritingAction(_ action: MarkdownWritingAction) -> Bool {
        guard canUseWritingRules,
              let edit = MarkdownWritingRules.edit(action, source: string, selection: selectedRange()) else { return false }
        return applyWritingEdit(edit)
    }

    private func movePastHiddenMarker(forward: Bool) {
        guard isLiveMarkdown, isEditable, !hasMarkedText(), selectedRange().length == 0 else { return }
        let location = selectedRange().location
        guard let hidden = renderedCollapsedSourceRanges.first(where: {
            location > $0.location && location < NSMaxRange($0)
        }), !renderedAnchorSourceRanges.contains(hidden) else { return }
        setSelectedRange(NSRange(location: forward ? NSMaxRange(hidden) : hidden.location, length: 0))
    }

    override func moveLeft(_ sender: Any?) {
        super.moveLeft(sender)
        movePastHiddenMarker(forward: false)
    }

    override func moveRight(_ sender: Any?) {
        super.moveRight(sender)
        movePastHiddenMarker(forward: true)
    }

    override func moveUp(_ sender: Any?) {
        super.moveUp(sender)
        movePastHiddenMarker(forward: true)
    }

    override func moveDown(_ sender: Any?) {
        super.moveDown(sender)
        movePastHiddenMarker(forward: true)
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        super.moveToBeginningOfLine(sender)
        guard isLiveMarkdown, !hasActiveComposition,
              let marker = renderedCollapsedSourceRanges.first(where: { $0.location == selectedRange().location }),
              !renderedAnchorSourceRanges.contains(marker) else { return }
        setSelectedRange(NSRange(location: NSMaxRange(marker), length: 0))
    }

    override func selectAll(_ sender: Any?) {
        if let request = editableCodeRequest(), selectedRange() != request.contentRange.utf16Range {
            setSelectedRange(request.contentRange.utf16Range)
            return
        }
        super.selectAll(sender)
    }

    private func indentCode(backwards: Bool) -> Bool {
        guard let request = editableCodeRequest() else { return false }
        let selection = selectedRange()
        if !backwards && selection.length == 0 {
            return applyWritingEdit(MarkdownWritingEdit(range: selection, text: "    ",
                selection: NSRange(location: selection.location + 4, length: 0)))
        }
        let source = string as NSString
        let lines = source.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        let range = NSIntersectionRange(lines, request.contentRange.utf16Range)
        let result = NSMutableString(string: source.substring(with: range))
        var offset = 0
        var changes: [(Int, Int)] = []
        while offset < range.length {
            let line = source.lineRange(for: NSRange(location: range.location + offset, length: 0))
            let text = source.substring(with: NSIntersectionRange(line, range))
            let removed = backwards ? (text.hasPrefix("\t") ? 1 : min(4, text.prefix { $0 == " " }.count)) : 0
            changes.append((offset, removed))
            offset = NSMaxRange(line) - range.location
        }
        for (offset, removed) in changes.reversed() {
            result.replaceCharacters(in: NSRange(location: offset, length: removed), with: backwards ? "" : "    ")
        }
        let target: NSRange
        if selection.length == 0 {
            target = NSRange(location: max(range.location, selection.location - (changes.first?.1 ?? 0)), length: 0)
        } else {
            target = NSRange(location: range.location, length: result.length)
        }
        return applyWritingEdit(MarkdownWritingEdit(range: range, text: result as String, selection: target))
    }

    override func insertTab(_ sender: Any?) {
        if indentCode(backwards: false) || handleWritingAction(.indent) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if indentCode(backwards: true) || handleWritingAction(.outdent) { return }
        super.insertBacktab(sender)
    }

    func consumeEngineEditGroupID() -> String? {
        defer { pendingEngineEditGroupID = nil }
        return pendingEngineEditGroupID
    }

    private func prepareEngineTypingGroup(_ kind: EngineTypingKind) {
        let now = ProcessInfo.processInfo.systemUptime
        if engineTypingKind != kind || now > engineTypingDeadline {
            engineTypingGroupID = UUID().uuidString
        }
        engineTypingKind = kind
        engineTypingDeadline = now + 1.5
        pendingEngineEditGroupID = engineTypingGroupID
    }

    private func breakEngineTypingGroup() {
        engineTypingKind = nil
        engineTypingGroupID = nil
        engineTypingDeadline = 0
        pendingEngineEditGroupID = nil
    }

    private static func plainText(from value: Any) -> String? {
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }

    private var compositionBaseline: String?
    var hasActiveComposition: Bool { compositionBaseline != nil || hasMarkedText() }

    private func finishCompositionIfNeeded() {
        guard let baseline = compositionBaseline else { return }
        compositionBaseline = nil
        // Cancellation also ends the transaction and releases any deferred acknowledgement.
        compositionDidEndHandler?(string, selectedRange(), !UTF8Text.isExactlyEqual(baseline, string))
    }

    @discardableResult
    func consumeImagePaste(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable,
              let pasteImageHandler,
              let payload = ClipboardImagePayload.read(from: pasteboard)
        else {
            return false
        }
        pasteImageHandler(payload)
        return true
    }

    override func paste(_ sender: Any?) {
        if consumeImagePaste(from: .general) { return }
        breakEngineTypingGroup()
        suppressesAutomaticEngineGrouping = true
        defer { suppressesAutomaticEngineGrouping = false }
        super.paste(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = localPoint(forWindowPoint: event.locationInWindow)
        if RenderedMarkdownLinkActivation.shouldNavigate(
            for: event.modifierFlags,
            preference: linkActivation,
            isEditing: isEditable
        ),
           let location = clickableLinkLocation(at: localPoint),
           linkClickHandler?(location) == true
        {
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let localPoint = localPoint(forWindowPoint: event.locationInWindow)
        if let request = editableCodeRequest(at: characterIndexForInsertion(at: localPoint)) {
            let menu = super.menu(for: event) ?? NSMenu()
            menu.addItem(.separator())
            let item = NSMenuItem(title: "编辑代码语言…", action: #selector(editCodeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
            return menu
        }
        guard let location = clickableLinkLocation(at: localPoint) else {
            return super.menu(for: event)
        }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(
            title: "打开链接",
            action: #selector(openContextLink(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = location
        menu.addItem(item)
        return menu
    }

    @objc private func editCodeLanguage(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? JavaScriptRenderRequest,
              let request = RenderedMarkdownEditor.plan(for: string).renderRequests.first(where: {
                  $0.kind == "code" && $0.sourceRange == old.sourceRange && $0.source == old.source
              }) else { return }
        let source = string as NSString
        let opening = source.lineRange(for: NSRange(location: request.sourceRange.utf16Range.location, length: 0))
        let line = source.substring(with: opening) as NSString
        guard let regex = try? NSRegularExpression(pattern: "[`~]{3,}([^\r\n]*)"),
              let match = regex.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: opening.location + match.range(at: 1).location, length: match.range(at: 1).length))
        focusDidChangeHandler?()
    }

    @objc
    private func openContextLink(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? Int else { return }
        _ = linkClickHandler?(location)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer else { return }
        for characterRange in clickableLinkRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            ).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    private func clickableLinkLocation(at localPoint: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return clickableLinkRanges.contains(where: { NSLocationInRange(characterIndex, $0) })
            ? characterIndex
            : nil
    }

    func localPoint(forWindowPoint point: NSPoint) -> NSPoint {
        convert(point, from: nil)
    }

    @discardableResult
    func consumeImageDrop(from pasteboard: NSPasteboard, insertionRange: NSRange) -> Bool {
        guard isEditable,
              let dropImageHandler,
              let url = DroppedImageSource.read(from: pasteboard)
        else {
            return false
        }
        let length = (string as NSString).length
        let location = min(max(0, insertionRange.location), length)
        setSelectedRange(NSRange(location: location, length: 0))
        dropImageHandler(url)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if DroppedImageSource.read(from: sender.draggingPasteboard) != nil {
            return isEditable && dropImageHandler != nil ? .copy : []
        }
        if DroppedImageSource.containsFileURLs(sender.draggingPasteboard) { return [] }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if DroppedImageSource.read(from: sender.draggingPasteboard) != nil {
            return isEditable && dropImageHandler != nil
        }
        if DroppedImageSource.containsFileURLs(sender.draggingPasteboard) { return false }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard DroppedImageSource.read(from: sender.draggingPasteboard) != nil else {
            if DroppedImageSource.containsFileURLs(sender.draggingPasteboard) { return false }
            return super.performDragOperation(sender)
        }
        let screenPoint = window?.convertPoint(toScreen: sender.draggingLocation)
            ?? sender.draggingLocation
        let insertion = characterIndexForInsertion(at: screenPoint)
        return consumeImageDrop(
            from: sender.draggingPasteboard,
            insertionRange: NSRange(location: insertion, length: 0)
        )
    }

    /// AppKit's standard Edit menu dispatches these actions through the first
    /// responder. NSTextView owns an undo manager but does not itself expose
    /// the menu selectors, so bridge them explicitly for this persistent view.
    @objc func undo(_ sender: Any?) {
        if usesEngineHistory {
            engineUndoHandler?()
        } else {
            persistentUndoManager.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if usesEngineHistory {
            engineRedoHandler?()
        } else {
            persistentUndoManager.redo()
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            usesEngineHistory ? engineCanUndo : persistentUndoManager.canUndo
        case #selector(redo(_:)):
            usesEngineHistory ? engineCanRedo : persistentUndoManager.canRedo
        default:
            super.validateUserInterfaceItem(item)
        }
    }
}

final class RenderedMarkdownImageView: NSImageView {
    var presentsDiagram = false {
        didSet { updateDiagramFrame() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDiagramFrame()
    }

    private func updateDiagramFrame() {
        guard presentsDiagram else {
            layer?.borderWidth = 0
            layer?.cornerRadius = 0
            layer?.backgroundColor = nil
            return
        }
        let palette = MarkdownRenderPalette.resolved(for: effectiveAppearance)
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.cornerRadius = 0
        layer?.backgroundColor = palette.canvasColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class RenderedMarkdownTableView: NSView, NSTextViewDelegate {
    private static let toolbarHeight: CGFloat = 28
    private let toolsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private final class CellLayout {
        let row: Int
        let column: Int
        let textView: RenderedMarkdownTableCellTextView
        var originalText: String

        init(
            row: Int,
            column: Int,
            textView: RenderedMarkdownTableCellTextView,
            originalText: String
        ) {
            self.row = row
            self.column = column
            self.textView = textView
            self.originalText = originalText
        }
    }

    private var columnWidths: [CGFloat]
    private var rowHeights: [CGFloat]
    private var cells: [CellLayout]
    private let onLinkClick: (String) -> Void
    private var onEdit: (RenderedMarkdownTableEdit) -> Void
    private let baseFont: NSFont
    private let layoutStrategy: any RenderedMarkdownTableLayoutStrategy
    private var maximumWidth: CGFloat
    private var needsContentMeasurement = false
    private var currentPalette: MarkdownRenderPalette
    private var contextCell = (row: 0, column: 0)
    private var contextLinkTarget: String?
    private(set) var renderedSize: NSSize
    var cellTexts: [[String]] { table.rows.map { $0.map(\.text) } }
    private(set) var table: RenderedMarkdownTable
    let linkActivation: LinkActivationPreference

    override var isFlipped: Bool { true }

    static func backgroundColor(
        forRow index: Int,
        appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        let palette = MarkdownRenderPalette.resolved(for: appearance)
        if index == 0 {
            return palette.mutedSurfaceColor
        }
        return index.isMultiple(of: 2)
            ? palette.tableStripeColor
            : palette.canvasColor
    }

    static var borderColor: NSColor {
        MarkdownRenderPalette.resolved(for: NSApp.effectiveAppearance).borderColor
    }

    func backgroundColor(forRow index: Int) -> NSColor {
        Self.backgroundColor(forRow: index, appearance: effectiveAppearance)
    }

    func restingLinkUnderlineStyles() -> [Int] {
        cells.flatMap { cell -> [Int] in
            guard let storage = cell.textView.textStorage, storage.length > 0 else { return [] }
            var styles: [Int] = []
            storage.enumerateAttribute(
                .link,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                guard value != nil, range.length > 0 else { return }
                let style = storage.attribute(
                    .underlineStyle,
                    at: range.location,
                    effectiveRange: nil
                ) as? NSNumber
                styles.append(style?.intValue ?? NSUnderlineStyle.single.rawValue)
            }
            return styles
        }
    }

    init(
        table: RenderedMarkdownTable,
        baseFont: NSFont,
        maximumWidth: CGFloat,
        linkActivation: LinkActivationPreference,
        palette: MarkdownRenderPalette,
        onLinkClick: @escaping (String) -> Void,
        onEdit: @escaping (RenderedMarkdownTableEdit) -> Void,
        layoutStrategy: any RenderedMarkdownTableLayoutStrategy =
            AdaptiveRenderedMarkdownTableLayoutStrategy()
    ) {
        self.table = table
        self.linkActivation = linkActivation
        self.onLinkClick = onLinkClick
        self.onEdit = onEdit
        self.baseFont = baseFont
        self.layoutStrategy = layoutStrategy
        self.maximumWidth = max(160, maximumWidth)
        self.currentPalette = palette
        let widths = layoutStrategy.columnWidths(
            for: table,
            font: baseFont,
            availableWidth: max(160, maximumWidth)
        )
        columnWidths = widths

        let heights = Self.rowHeights(for: table, widths: widths, baseFont: baseFont)
        rowHeights = heights
        renderedSize = NSSize(width: widths.reduce(0, +), height: heights.reduce(0, +) + Self.toolbarHeight)

        cells = Self.makeCells(table: table, widths: widths, baseFont: baseFont, palette: palette)
        super.init(frame: NSRect(origin: .zero, size: renderedSize))
        wantsLayer = true
        layer?.cornerRadius = MarkdownRenderMetrics.blockCornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        toolTip = "Tab 切换单元格；⌘Enter 新增行；Shift+Enter 换行；Shift+方向键选择多个单元格；Enter / Esc 退出表格。"
        setAccessibilityHelp(toolTip)
        for cell in cells { configure(cell) }
        configureTools()
        layoutCells()
    }

    private func configureTools() {
        let menu = NSMenu()
        menu.addItem(withTitle: "表格", action: nil, keyEquivalent: "")
        for (title, action) in [("在上方插入行", #selector(insertRowAbove(_:))),
                                ("在下方插入行", #selector(insertRowBelow(_:))),
                                ("删除当前行", #selector(deleteCurrentRow(_:))),
                                ("在左侧插入列", #selector(insertColumnLeft(_:))),
                                ("在右侧插入列", #selector(insertColumnRight(_:))),
                                ("删除当前列", #selector(deleteCurrentColumn(_:))),
                                ("左对齐", #selector(alignColumnLeading(_:))),
                                ("居中对齐", #selector(alignColumnCenter(_:))),
                                ("右对齐", #selector(alignColumnTrailing(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        toolsButton.menu = menu
        toolsButton.bezelStyle = .recessed
        toolsButton.font = .systemFont(ofSize: 12)
        toolsButton.setAccessibilityLabel("表格行列与对齐操作")
        addSubview(toolsButton)
        setAccessibilityChildren(cells.map { $0.textView as NSView } + [toolsButton])
    }

    private static func makeCells(table: RenderedMarkdownTable, widths: [CGFloat], baseFont: NSFont,
                                  palette: MarkdownRenderPalette, startingRow: Int = 0) -> [CellLayout] {
        var layouts: [CellLayout] = []
        for (rowIndex, row) in table.rows.enumerated() where rowIndex >= startingRow {
            for (column, cell) in row.enumerated() where column < widths.count {
                let paragraph = NSMutableParagraphStyle()
                let alignment = column < table.alignments.count
                    ? table.alignments[column]
                    : .leading
                switch alignment {
                case .leading: paragraph.alignment = .natural
                case .center: paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }
                let font = rowIndex == 0
                    ? NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                    : baseFont
                paragraph.minimumLineHeight = font.pointSize * MarkdownRenderMetrics.bodyLineHeight
                let attributed = NSMutableAttributedString(
                    string: cell.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: palette.textColor,
                        .paragraphStyle: paragraph,
                    ]
                )
                for link in cell.links
                where link.visibleRange.length > 0
                    && NSMaxRange(link.visibleRange) <= attributed.length {
                    attributed.addAttributes(
                        MarkdownLinkVisualStyle.restingAttributes(
                            foregroundColor: palette.accentColor
                        ).merging([.link: link.target]) { current, _ in current },
                        range: link.visibleRange
                    )
                }
                let textView = RenderedMarkdownTableCellTextView()
                textView.font = font
                textView.defaultParagraphStyle = paragraph
                textView.caretFont = font
                textView.typingAttributes = [.font: font, .foregroundColor: palette.textColor, .paragraphStyle: paragraph]
                textView.isEditable = true
                textView.allowsUndo = false
                textView.isSelectable = true
                textView.isRichText = true
                textView.drawsBackground = false
                textView.textContainerInset = .zero
                textView.textContainer?.lineFragmentPadding = 0
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.heightTracksTextView = false
                textView.linkTextAttributes = MarkdownLinkVisualStyle.restingAttributes(
                    foregroundColor: palette.accentColor
                )
                textView.textStorage?.setAttributedString(attributed)
                textView.delegate = nil
                textView.setAccessibilityLabel("第 \(rowIndex + 1) 行，第 \(column + 1) 列")
                layouts.append(
                    CellLayout(
                        row: rowIndex,
                        column: column,
                        textView: textView,
                        originalText: cell.text
                    )
                )
            }
        }
        return layouts
    }

    private func configure(_ layout: CellLayout) {
        layout.textView.delegate = self
        layout.textView.linkActivation = linkActivation
        layout.textView.onLinkClick = onLinkClick
        layout.textView.navigationHandler = { [weak self, weak textView = layout.textView] backwards, exit in
            guard let self, let textView else { return }
            self.navigate(from: textView, backwards: backwards, exit: exit)
        }
        layout.textView.insertRowHandler = { [weak self, weak textView = layout.textView] in
            guard let self, let textView, !textView.hasMarkedText() else { return }
            self.commit(textView)
            self.insertRow(at: layout.row + 1, column: layout.column)
        }
        layout.textView.selectionClickHandler = { [weak self] extend in
            guard let self else { return false }
            if extend {
                let anchor = self.selectionAnchor ?? self.focusedCell.map { ($0.row, $0.column) } ?? (layout.row, layout.column)
                self.selectCells(from: anchor, to: (layout.row, layout.column))
                return true
            }
            self.clearCellSelection()
            return false
        }
        layout.textView.extendSelectionHandler = { [weak self] row, column in
            self?.extendCellSelection(row: row, column: column)
        }
        layout.textView.replaceCellSelectionHandler = { [weak self] text in
            guard let self, let selected = self.selectedCellTexts,
                  let a = self.selectionAnchor, let b = self.selectionEnd else { return false }
            var values = selected.map { $0.map { _ in "" } }
            values[0][0] = text
            self.clearCellSelection()
            self.applyCellValues(values, row: min(a.0, b.0), column: min(a.1, b.1))
            _ = self.focusCell(row: min(a.0, b.0), column: min(a.1, b.1),
                selection: NSRange(location: text.utf16.count, length: 0))
            return true
        }
        layout.textView.clipboardHandler = { [weak self] action in self?.handleCellClipboard(action) ?? false }
        layout.textView.historyHandler = { [weak self] redo in
            guard let self, let owner = self.documentTextView else { return }
            if redo { owner.redo(nil) } else { owner.undo(nil) }
        }
        layout.textView.contextMenuProvider = { [weak self, weak textView = layout.textView]
            event in
            guard let self, let textView else { return nil }
            return self.tableMenu(for: layout.row, column: layout.column, event: event, in: textView)
        }
        addSubview(layout.textView)
    }

    /// Appending rows retains active editors, their selections, and the responder chain.
    func appendRowsIfPossible(_ updated: RenderedMarkdownTable, onEdit: @escaping (RenderedMarkdownTableEdit) -> Void) -> Bool {
        guard updated.rows.count > table.rows.count, updated.alignments == table.alignments,
              zip(table.rows, updated.rows).allSatisfy({ old, new in
                  old.map(\.markdown) == new.map(\.markdown) && old.map(\.text) == new.map(\.text)
              }) else { return false }
        let added = Self.makeCells(table: updated, widths: columnWidths, baseFont: baseFont,
            palette: MarkdownRenderPalette.resolved(for: effectiveAppearance), startingRow: table.rows.count)
        let editable = cells.first?.textView.isEditable ?? false
        cells += added
        for cell in added { configure(cell); cell.textView.isEditable = editable }
        setAccessibilityChildren(cells.map { $0.textView as NSView } + [toolsButton])
        update(table: updated, onEdit: onEdit)
        _ = updateMaximumWidth(maximumWidth)
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setEditingEnabled(_ enabled: Bool) {
        for cell in cells { cell.textView.isEditable = enabled }
        toolsButton.isEnabled = enabled
    }

    func hasSameRenderedContent(as other: RenderedMarkdownTable) -> Bool {
        table.alignments == other.alignments
            && table.rows.map { $0.map(\.text) } == other.rows.map { $0.map(\.text) }
            && table.rows.map { $0.flatMap(\.links) } == other.rows.map { $0.flatMap(\.links) }
    }

    func hasSameLiveRenderedContent(as other: RenderedMarkdownTable) -> Bool {
        guard table.alignments == other.alignments,
              table.rows.count == other.rows.count,
              table.rows.enumerated().allSatisfy({ row, cells in
                  cells.count == other.rows[row].count
              })
        else { return false }
        return cells.allSatisfy { cell in
            other.rows[cell.row][cell.column].text == cell.textView.string
        }
    }

    func update(
        table: RenderedMarkdownTable,
        onEdit: @escaping (RenderedMarkdownTableEdit) -> Void
    ) {
        needsContentMeasurement = needsContentMeasurement || self.table.rows.map { $0.map(\.text) } != table.rows.map { $0.map(\.text) }
        self.table = table
        self.onEdit = onEdit
        for cell in cells {
            cell.originalText = table.rows[cell.row][cell.column].text
        }
    }

    func applyPalette(_ palette: MarkdownRenderPalette) {
        guard palette != currentPalette else { return }
        currentPalette = palette
        for cell in cells {
            guard let storage = cell.textView.textStorage, storage.length > 0 else { continue }
            cell.textView.linkTextAttributes = MarkdownLinkVisualStyle.restingAttributes(
                foregroundColor: palette.accentColor
            )
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.foregroundColor, value: palette.textColor, range: fullRange)
            storage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
                guard value != nil else { return }
                storage.addAttributes(
                    MarkdownLinkVisualStyle.restingAttributes(
                        foregroundColor: palette.accentColor
                    ),
                    range: range
                )
            }
        }
        needsDisplay = true
    }

    @discardableResult
    func updateMaximumWidth(_ width: CGFloat) -> Bool {
        let width = max(160, width)
        guard needsContentMeasurement || maximumWidth != width else { return false }
        needsContentMeasurement = false
        let widths = layoutStrategy.columnWidths(
            for: table,
            font: baseFont,
            availableWidth: width
        )
        let heights = Self.rowHeights(for: table, widths: widths, baseFont: baseFont)
        guard widths != columnWidths || maximumWidth != width || heights != rowHeights else { return false }
        maximumWidth = width
        columnWidths = widths
        rowHeights = heights
        renderedSize = NSSize(width: widths.reduce(0, +), height: rowHeights.reduce(0, +) + Self.toolbarHeight)
        setFrameSize(renderedSize)
        layoutCells()
        needsDisplay = true
        return true
    }

    private static func rowHeights(
        for table: RenderedMarkdownTable,
        widths: [CGFloat],
        baseFont: NSFont
    ) -> [CGFloat] {
        table.rows.enumerated().map { rowIndex, row in
            let font = rowIndex == 0
                ? NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
                : baseFont
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = font.pointSize * MarkdownRenderMetrics.bodyLineHeight
            var rowHeight = max(CGFloat(36), paragraph.minimumLineHeight + CGFloat(MarkdownRenderMetrics.tableCellVerticalPadding * 2))
            for (column, cell) in row.enumerated() where column < widths.count {
                let bounds = (cell.text as NSString).boundingRect(
                    with: NSSize(
                        width: max(
                            20,
                            widths[column]
                                - CGFloat(MarkdownRenderMetrics.tableCellHorizontalPadding * 2)
                        ),
                        height: 2_000
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font, .paragraphStyle: paragraph]
                )
                rowHeight = max(
                    rowHeight,
                    ceil(bounds.height) + (cell.text.hasSuffix("\n") ? paragraph.minimumLineHeight : 0)
                        + CGFloat(MarkdownRenderMetrics.tableCellVerticalPadding * 2)
                )
            }
            return rowHeight
        }
    }

    private func layoutCells() {
        let xOffsets = columnWidths.reduce(into: [CGFloat(0)]) { result, width in
            result.append((result.last ?? 0) + width)
        }
        toolsButton.frame = NSRect(x: 4, y: 0, width: min(220, renderedSize.width - 8), height: Self.toolbarHeight)
        toolsButton.menu?.items.first?.title = "表格 · \(table.rows.count) 行 × \(table.alignments.count) 列"
        let yOffsets = rowHeights.reduce(into: [Self.toolbarHeight]) { result, height in
            result.append((result.last ?? 0) + height)
        }
        for cell in cells {
            guard cell.column + 1 < xOffsets.count, cell.row + 1 < yOffsets.count else { continue }
            let horizontalPadding = CGFloat(MarkdownRenderMetrics.tableCellHorizontalPadding)
            let verticalPadding = CGFloat(MarkdownRenderMetrics.tableCellVerticalPadding)
            cell.textView.frame = NSRect(
                x: xOffsets[cell.column] + horizontalPadding,
                y: yOffsets[cell.row] + verticalPadding,
                width: max(1, columnWidths[cell.column] - horizontalPadding * 2),
                height: max(1, rowHeights[cell.row] - verticalPadding * 2)
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var y = Self.toolbarHeight
        for (index, height) in rowHeights.enumerated() {
            let rowRect = NSRect(x: 0, y: y, width: renderedSize.width, height: height)
            backgroundColor(forRow: index).setFill()
            rowRect.fill()
            y += height
        }
        MarkdownRenderPalette.resolved(for: effectiveAppearance).borderColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        var x = CGFloat(0)
        for width in columnWidths.dropLast() {
            x += width
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: x, y: 0))
            divider.line(to: NSPoint(x: x, y: renderedSize.height))
            divider.stroke()
        }
        y = Self.toolbarHeight
        for height in rowHeights.dropLast() {
            y += height
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 0, y: y))
            divider.line(to: NSPoint(x: renderedSize.width, y: y))
            divider.stroke()
        }
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let target = link as? String else { return false }
        guard linkActivation == .singleClick else { return false }
        onLinkClick(target)
        return true
    }

    private var documentTextView: WindowAwareTextView? {
        var view = superview
        while let candidate = view {
            if let editor = candidate as? WindowAwareTextView { return editor }
            view = candidate.superview
        }
        return nil
    }

    var focusedCell: (row: Int, column: Int, selection: NSRange)? {
        guard let cell = cells.first(where: { $0.textView === window?.firstResponder }) else { return nil }
        return (cell.row, cell.column, cell.textView.selectedRange())
    }

    @discardableResult
    func focusCell(row: Int, column: Int, selection: NSRange? = nil, scroll: Bool = true) -> Bool {
        guard let cell = cells.first(where: { $0.row == row && $0.column == column }),
              cell.textView.isEditable, window?.makeFirstResponder(cell.textView) == true else { return false }
        let length = cell.textView.string.utf16.count
        let range = selection ?? NSRange(location: 0, length: length)
        cell.textView.setSelectedRange(NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
        if scroll { cell.textView.scrollRangeToVisible(cell.textView.selectedRange()) }
        documentTextView?.selectionVisibilityHandler?()
        return true
    }

    private(set) var selectionAnchor: (Int, Int)?
    private(set) var selectionEnd: (Int, Int)?

    func clearCellSelection() {
        selectionAnchor = nil
        selectionEnd = nil
        for cell in cells { cell.textView.drawsBackground = false }
    }

    func selectCells(from anchor: (Int, Int), to end: (Int, Int), scroll: Bool = true) {
        guard (window?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        guard table.rows.indices.contains(anchor.0), table.rows[anchor.0].indices.contains(anchor.1),
              table.rows.indices.contains(end.0), table.rows[end.0].indices.contains(end.1) else { return }
        selectionAnchor = anchor
        selectionEnd = end
        _ = focusCell(row: end.0, column: end.1, selection: NSRange(location: 0, length: 0), scroll: scroll)
        for cell in cells {
            cell.textView.drawsBackground = (min(anchor.0, end.0)...max(anchor.0, end.0)).contains(cell.row)
                && (min(anchor.1, end.1)...max(anchor.1, end.1)).contains(cell.column)
            cell.textView.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.3)
        }
    }

    func extendCellSelection(row: Int, column: Int) {
        guard let focus = focusedCell else { return }
        let anchor = selectionAnchor ?? (focus.row, focus.column)
        let end = selectionEnd ?? (focus.row, focus.column)
        let nextRow = min(max(0, end.0 + row), table.rows.count - 1)
        let nextColumn = min(max(0, end.1 + column), table.rows[nextRow].count - 1)
        selectCells(from: anchor, to: (nextRow, nextColumn))
    }

    var selectedCellTexts: [[String]]? {
        guard let a = selectionAnchor, let b = selectionEnd else { return nil }
        return (min(a.0, b.0)...max(a.0, b.0)).map { row in
            (min(a.1, b.1)...max(a.1, b.1)).map { column in
                cells.first { $0.row == row && $0.column == column }?.textView.string ?? ""
            }
        }
    }

    @discardableResult
    func handleCellClipboard(_ action: String) -> Bool {
        guard let focus = focusedCell else { return false }
        let selected = selectedCellTexts
        let editable = cells.first { $0.row == focus.row && $0.column == focus.column }?.textView.isEditable == true
        let row = min(selectionAnchor?.0 ?? focus.row, selectionEnd?.0 ?? focus.row)
        let column = min(selectionAnchor?.1 ?? focus.column, selectionEnd?.1 ?? focus.column)
        if action == "paste" {
            guard editable, let text = NSPasteboard.general.string(forType: .string) else { return false }
            let values = TableClipboard.decode(text)
            guard selected != nil || values.count > 1 || (values.first?.count ?? 0) > 1 else { return false }
            clearCellSelection()
            applyCellValues(values, row: row, column: column)
            return true
        }
        guard let selected else { return false }
        if action == "copy" || action == "cut" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TableClipboard.encode(selected), forType: .string)
        }
        if action == "delete" || action == "cut", editable {
            clearCellSelection()
            applyCellValues(selected.map { $0.map { _ in "" } }, row: row, column: column)
        }
        return true
    }

    private func applyCellValues(_ values: [[String]], row: Int, column: Int) {
        // Keep active cells current while the async engine projection catches up.
        // Otherwise a subsequent keystroke could overwrite a just-pasted cell.
        for cell in cells where values.indices.contains(cell.row - row) {
            let values = values[cell.row - row]
            guard values.indices.contains(cell.column - column) else { continue }
            cell.originalText = values[cell.column - column]
            cell.textView.string = cell.originalText
        }
        onEdit(.updateCells(row: row, column: column, texts: values))
    }

    func finishPendingInputForCheckpoint() {
        for cell in cells {
            if cell.textView.hasMarkedText() { cell.textView.unmarkText() }
            commit(cell.textView)
        }
    }

    private func commit(_ textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
              let cell = cells.first(where: { $0.textView === textView }), textView.string != cell.originalText else { return }
        cell.originalText = textView.string
        onEdit(.updateCell(row: cell.row, column: cell.column, text: textView.string))
    }

    func textDidChange(_ notification: Notification) {
        if let textView = notification.object as? NSTextView { commit(textView) }
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard let view = notification.object as? NSTextView,
              let cell = cells.first(where: { $0.textView === view }) else { return }
        contextCell = (cell.row, cell.column)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textDidBeginEditing(notification)
        documentTextView?.selectionVisibilityHandler?()
    }

    private func insertRow(at row: Int, column: Int) {
        documentTextView?.pendingTableFocus = (table.sourceRange.utf16Range.location, row, column)
        onEdit(.insertRow(at: row))
    }

    func textDidEndEditing(_ notification: Notification) {
        if let textView = notification.object as? NSTextView { commit(textView) }
    }

    private func navigate(from textView: NSTextView, backwards: Bool, exit: Bool) {
        guard textView.isEditable, !textView.hasMarkedText(),
              let index = cells.firstIndex(where: { $0.textView === textView }) else { return }
        commit(textView)
        clearCellSelection()
        let next = backwards ? index - 1 : index + 1
        if exit || next < 0 {
            guard let owner = documentTextView else { return }
            owner.pendingTableFocus = nil
            window?.makeFirstResponder(owner)
            let current = RenderedMarkdownEditor.plan(for: owner.string).tables.first {
                $0.sourceRange.utf16Range.location == table.sourceRange.utf16Range.location
            } ?? table
            let location = backwards ? current.sourceRange.utf16Range.location : NSMaxRange(current.sourceRange.utf16Range)
            owner.setSelectedRange(NSRange(location: min(location, owner.string.utf16.count), length: 0))
            if !backwards, location == owner.string.utf16.count { owner.insertText("\n\n", replacementRange: owner.selectedRange()) }
            return
        }
        if next < cells.count {
            _ = focusCell(row: cells[next].row, column: cells[next].column)
        } else {
            guard documentTextView?.pendingTableFocus == nil else { return }
            insertRow(at: table.rows.count, column: 0)
        }
    }

    private func tableMenu(
        for row: Int,
        column: Int,
        event: NSEvent,
        in textView: RenderedMarkdownTableCellTextView
    ) -> NSMenu {
        contextCell = (row, column)
        contextLinkTarget = textView.linkTarget(at: event)
        let menu = NSMenu(title: "")
        addResponderMenuItem("剪切", action: #selector(NSText.cut(_:)), to: menu)
        addResponderMenuItem("复制", action: #selector(NSText.copy(_:)), to: menu)
        addResponderMenuItem("粘贴", action: #selector(NSText.paste(_:)), to: menu)
        menu.addItem(.separator())
        if contextLinkTarget != nil {
            addMenuItem("打开链接", action: #selector(openTableLink(_:)), to: menu)
            menu.addItem(.separator())
        }
        addMenuItem("在上方插入行", action: #selector(insertRowAbove(_:)), to: menu)
        addMenuItem("在下方插入行", action: #selector(insertRowBelow(_:)), to: menu)
        addMenuItem("删除当前行", action: #selector(deleteCurrentRow(_:)), to: menu)
        menu.addItem(.separator())
        addMenuItem("在左侧插入列", action: #selector(insertColumnLeft(_:)), to: menu)
        addMenuItem("在右侧插入列", action: #selector(insertColumnRight(_:)), to: menu)
        addMenuItem("删除当前列", action: #selector(deleteCurrentColumn(_:)), to: menu)
        menu.addItem(.separator())
        addMenuItem("左对齐", action: #selector(alignColumnLeading(_:)), to: menu)
        addMenuItem("居中对齐", action: #selector(alignColumnCenter(_:)), to: menu)
        addMenuItem("右对齐", action: #selector(alignColumnTrailing(_:)), to: menu)
        return menu
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addResponderMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = nil
        menu.addItem(item)
    }

    @objc private func openTableLink(_ sender: Any?) {
        if let contextLinkTarget { onLinkClick(contextLinkTarget) }
    }

    @objc private func insertRowAbove(_ sender: Any?) {
        insertRow(at: contextCell.row, column: contextCell.column)
    }

    @objc private func insertRowBelow(_ sender: Any?) {
        insertRow(at: contextCell.row + 1, column: contextCell.column)
    }

    @objc private func deleteCurrentRow(_ sender: Any?) {
        onEdit(.deleteRow(contextCell.row))
    }

    @objc private func insertColumnLeft(_ sender: Any?) {
        onEdit(.insertColumn(at: contextCell.column))
    }

    @objc private func insertColumnRight(_ sender: Any?) {
        onEdit(.insertColumn(at: contextCell.column + 1))
    }

    @objc private func deleteCurrentColumn(_ sender: Any?) {
        onEdit(.deleteColumn(contextCell.column))
    }

    @objc private func alignColumnLeading(_ sender: Any?) {
        onEdit(.setAlignment(column: contextCell.column, alignment: .leading))
    }

    @objc private func alignColumnCenter(_ sender: Any?) {
        onEdit(.setAlignment(column: contextCell.column, alignment: .center))
    }

    @objc private func alignColumnTrailing(_ sender: Any?) {
        onEdit(.setAlignment(column: contextCell.column, alignment: .trailing))
    }
}

@MainActor
final class RenderedMarkdownTableCellTextView: NSTextView {
    var caretFont = NSFont.systemFont(ofSize: 16)

    func renderedInsertionRect(_ rect: NSRect) -> NSRect {
        RenderedMarkdownCaretStyleResolver.insertionRect(rect, in: self, font: caretFont)
    }

    private var drawnInsertionRect: NSRect?

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let target = flag ? renderedInsertionRect(rect) : (drawnInsertionRect ?? renderedInsertionRect(rect))
        super.drawInsertionPoint(in: target, color: color, turnedOn: flag)
        drawnInsertionRect = flag ? target : nil
    }

    var selectionClickHandler: ((Bool) -> Bool)?
    var extendSelectionHandler: ((Int, Int) -> Void)?
    var clipboardHandler: ((String) -> Bool)?
    var replaceCellSelectionHandler: ((String) -> Bool)?
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let value = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if isEditable, !hasMarkedText(), let value, replaceCellSelectionHandler?(value) == true { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func deleteForward(_ sender: Any?) { if clipboardHandler?("delete") != true { super.deleteForward(sender) } }

    var navigationHandler: ((_ backwards: Bool, _ exit: Bool) -> Void)?
    var insertRowHandler: (() -> Void)?

    override func insertLineBreak(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { super.insertLineBreak(sender); return }
        insertText("\n", replacementRange: selectedRange())
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.command],
           event.keyCode == 36 || event.keyCode == 76 {
            insertRowHandler?()
            return
        }
        if !hasMarkedText(), event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.shift] {
            if event.keyCode == 36 || event.keyCode == 76 { insertLineBreak(nil); return }
            let delta: (Int, Int)? = switch event.keyCode {
            case 123: (0, -1)
            case 124: (0, 1)
            case 125: (1, 0)
            case 126: (-1, 0)
            default: nil
            }
            if let delta { extendSelectionHandler?(delta.0, delta.1); return }
        }
        super.keyDown(with: event)
    }
    override func copy(_ sender: Any?) { if clipboardHandler?("copy") != true { super.copy(sender) } }
    override func cut(_ sender: Any?) { if clipboardHandler?("cut") != true { super.cut(sender) } }
    override func paste(_ sender: Any?) { if clipboardHandler?("paste") != true { super.paste(sender) } }
    override func deleteBackward(_ sender: Any?) { if clipboardHandler?("delete") != true { super.deleteBackward(sender) } }

    var historyHandler: ((_ redo: Bool) -> Void)?

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertTab(sender); return }
        navigationHandler?(false, false)
    }
    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertBacktab(sender); return }
        navigationHandler?(true, false)
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        navigationHandler?(false, true)
    }
    override func cancelOperation(_ sender: Any?) { navigationHandler?(false, true) }
    @objc func undo(_ sender: Any?) { historyHandler?(false) }
    @objc func redo(_ sender: Any?) { historyHandler?(true) }
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    var linkActivation = LinkActivationPreference.singleClick
    var onLinkClick: ((String) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredLinkRange: NSRange?

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTrackingArea = tracking
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let link = link(at: event)
        setHoveredLinkRange(link?.range)
        super.mouseMoved(with: event)
        (link == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredLinkRange(nil)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if selectionClickHandler?(event.modifierFlags.contains(.shift)) == true { return }
        if RenderedMarkdownLinkActivation.shouldNavigate(
            for: event.modifierFlags,
            preference: linkActivation,
            isEditing: isEditable
        ), let target = linkTarget(at: event) {
            onLinkClick?(target)
            return
        }
        if isEditable, let link = link(at: event) {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            let location = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: min(max(location, link.range.location), NSMaxRange(link.range)), length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil, range.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    func linkTarget(at event: NSEvent) -> String? {
        link(at: event)?.target
    }

    private func link(at event: NSEvent) -> (target: String, range: NSRange)? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(containerPoint) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < (string as NSString).length else { return nil }
        var range = NSRange()
        guard let target = textStorage?.attribute(.link, at: character, effectiveRange: &range)
            as? String
        else { return nil }
        return (target, range)
    }

    private func setHoveredLinkRange(_ range: NSRange?) {
        guard hoveredLinkRange != range else { return }
        if let hoveredLinkRange {
            layoutManager?.removeTemporaryAttribute(
                .underlineStyle,
                forCharacterRange: hoveredLinkRange
            )
        }
        hoveredLinkRange = range
        if let range {
            layoutManager?.addTemporaryAttribute(
                .underlineStyle,
                value: MarkdownLinkVisualStyle.hoverUnderline,
                forCharacterRange: range
            )
        }
        needsDisplay = true
    }
}

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let selectionRequest: SourceSelectionRequest?
    let session: MarkdownSourceEditorSession
    let isEditable: Bool
    let appearance: SourceEditorAppearance
    let presentation: MarkdownEditorPresentation
    let onPasteImage: ((ClipboardImagePayload) -> Void)?
    let onDropImage: ((URL) -> Void)?
    let onLinkClick: ((String) -> Void)?
    let renderedResourceContext: RenderedMarkdownResourceContext
    let linkActivation: LinkActivationPreference
    let renderedTheme: PreviewTheme
    let renderedColorScheme: PreviewColorScheme

    init(
        text: Binding<String>,
        selectionRequest: SourceSelectionRequest?,
        session: MarkdownSourceEditorSession,
        isEditable: Bool = true,
        appearance: SourceEditorAppearance = .default,
        presentation: MarkdownEditorPresentation = .source,
        onPasteImage: ((ClipboardImagePayload) -> Void)? = nil,
        onDropImage: ((URL) -> Void)? = nil,
        onLinkClick: ((String) -> Void)? = nil,
        renderedResourceContext: RenderedMarkdownResourceContext = .unavailable,
        linkActivation: LinkActivationPreference = .singleClick,
        renderedTheme: PreviewTheme = .standard,
        renderedColorScheme: PreviewColorScheme = .system
    ) {
        _text = text
        self.selectionRequest = selectionRequest
        self.session = session
        self.isEditable = isEditable
        self.appearance = appearance
        self.presentation = presentation
        self.onPasteImage = onPasteImage
        self.onDropImage = onDropImage
        self.onLinkClick = onLinkClick
        self.renderedResourceContext = renderedResourceContext
        self.linkActivation = linkActivation
        self.renderedTheme = renderedTheme
        self.renderedColorScheme = renderedColorScheme
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        session.scrollView.removeFromSuperview()
        context.coordinator.update(parent: self, textView: session.textView)
        return session.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self, textView: session.textView)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        let textView = coordinator.parent.session.textView
        if textView.delegate === coordinator {
            textView.delegate = nil
            textView.didAttachToWindow = nil
            textView.pasteImageHandler = nil
            textView.dropImageHandler = nil
            textView.linkClickHandler = nil
            textView.focusDidChangeHandler = nil
            textView.effectiveAppearanceDidChangeHandler = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor

        init(parent: MarkdownSourceEditor) {
            self.parent = parent
        }

        func update(parent: MarkdownSourceEditor, textView: WindowAwareTextView) {
            self.parent = parent
            let textBinding = parent.$text
            if parent.session.isRenderedProjection {
                parent.session.updateBoundText = nil
            } else {
                parent.session.updateBoundText = { updatedText in
                    if !UTF8Text.isExactlyEqual(textBinding.wrappedValue, updatedText) {
                        textBinding.wrappedValue = updatedText
                    }
                }
            }
            textView.delegate = self
            textView.isEditable = parent.isEditable
            textView.isSelectable = true
            textView.appearance = parent.presentation == .rendered
                ? parent.renderedColorScheme.nativeAppearance
                : nil
            textView.pasteImageHandler = parent.onPasteImage
            textView.dropImageHandler = parent.onDropImage
            textView.didAttachToWindow = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.parent.session.applyPendingRestorationIfPossible()
                self.applyPendingSelection(to: textView)
            }

            let bindingUpdate = parent.session.reconcileBoundText(parent.text)
            guard bindingUpdate != .deferred else { return }
            let textChanged = bindingUpdate == .replaced
            let displayedText = textView.string
            parent.session.applySourceAppearance(parent.appearance, force: textChanged)
            parent.session.setPresentation(
                parent.presentation,
                source: displayedText,
                onLinkClick: parent.onLinkClick,
                resourceContext: parent.renderedResourceContext,
                linkActivation: parent.linkActivation,
                theme: parent.renderedTheme
            )

            parent.session.applyPendingRestorationIfPossible()
            apply(parent.selectionRequest, to: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.session.updateSelectedRange(textView.selectedRange())
        }

        private func apply(_ request: SourceSelectionRequest?, to textView: NSTextView) {
            guard let request else {
                parent.session.pendingSelectionRequest = nil
                return
            }
            guard request.generation != parent.session.appliedSelectionGeneration,
                  let target = MarkdownSourceRange.navigationTarget(
                      forUTF8Range: request.utf8Range,
                      in: textView.string
                  )
            else {
                return
            }

            parent.session.pendingSelectionRequest = request
            textView.setSelectedRange(
                request.style == .caret ? target.caretRange : target.revealRange
            )
            textView.scrollRangeToVisible(target.revealRange)
            if request.style == .caret {
                textView.centerSelectionInVisibleArea(nil)
            }
            if request.style.showsTransientMatchIndicator {
                textView.showFindIndicator(for: target.revealRange)
            }
            completeApplication(for: request, textView: textView)
        }

        private func applyPendingSelection(to textView: NSTextView) {
            guard let request = parent.session.pendingSelectionRequest else { return }
            apply(request, to: textView)
        }

        private func completeApplication(
            for request: SourceSelectionRequest,
            textView: NSTextView
        ) {
            guard let window = textView.window else { return }
            if request.focusesEditor {
                guard window.makeFirstResponder(textView) else { return }
            }

            parent.session.appliedSelectionGeneration = request.generation
            parent.session.pendingSelectionRequest = nil
        }
    }
}
