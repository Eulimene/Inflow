import AppKit
import SwiftUI

enum MarkdownSourceEditorSessionRole: Equatable {
    case document
    case renderedProjection
}

enum RenderedMarkdownImagePlacement: Equatable {
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
    let selectionController = MarkdownSelectionController()
    private var pendingRestorationState: MarkdownRestorationState?
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
    // Core analysis survives presentation changes; diagram work does not.
    private var contentDerivationGeneration = 0
    private var deferredMermaidTask: Task<Void, Never>?
    private var javaScriptResourcesTask: Task<Void, Never>?
    private var javaScriptResults: [String: JavaScriptRenderedOutput] = [:]
    private var javaScriptFailures: Set<String> = []
    private var javaScriptSnapshot = ""
    private var latestRenderConfiguration = PreviewAppearanceConfiguration.default

    private var renderedRevealedMarkers: [NSRange] = []
    private var renderedInteractionTask: Task<Void, Never>?
    private let lineNumberRuler: MarkdownLineNumberRulerView
    private let engineClient: EditorEngineClient
    private var formatInspectionGeneration = 0
    private var formatInspectionTask: Task<Void, Never>?
    private var engineHistoryTask: Task<Void, Never>?
    private var engineHistoryGeneration = 0
    private var pendingHistoryCommands = 0
    private let inputState = MarkdownInputState()
    private let typingStyles = MarkdownTypingStyleProjection()
    private let layoutPlans = MarkdownLayoutPlanCache()
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
        textView.compositionWillBeginHandler = { [weak self] in self?.inputState.beginComposition() }
        textView.compositionDidEndHandler = { [weak self] text, selection, changed in
            guard let self, self.role == .document else { return }
            let result = self.inputState.finishComposition(text: text, changed: changed)
            if result.shouldSubmit { self.engineClient.submit(text: text, selectionUTF16: selection) }
            if let acknowledgement = result.acknowledgement { self.applyAuthoritativeSnapshot(acknowledgement) }
            self.syncTypingAttributes()
            self.scheduleRenderedPresentation(for: text)
        }
        textView.textDidChangeHandler = { [weak self] text in
            guard let self, self.role == .document else { return }
            if self.inputState.recordNativeEdit(text, isComposing: self.textView.hasActiveComposition) {
                self.engineClient.submit(
                    text: text,
                    selectionUTF16: self.textView.selectedRange(),
                    groupID: self.textView.consumeEngineEditGroupID()
                )
            } else {
                _ = self.textView.consumeEngineEditGroupID()
            }
            self.invalidateSyntaxApplication()
            self.contentDerivationGeneration &+= 1
            self.cancelDeferredMermaidRendering()
            self.scheduleFormatInspection()
            self.lineNumberRuler.updateText(text)
            self.refreshWritingModePresentation()
            self.scheduleRenderedPresentation(for: text)
        }
        textView.focusDidChangeHandler = { [weak self] in
            self?.scheduleRenderedInteractionPresentation()
        }
        textView.sourceSelectionHandler = { [weak self] range in
            guard let self, !self.textView.hasActiveComposition, !self.inputState.isApplyingEngineMutation else { return }
            self.engineClient.observeSelection(text: self.textView.string, selectionUTF16: range)
        }
        textView.layoutPlanProvider = { [weak self] source in
            guard let self else { return nil }
            return self.layoutPlans.resolve(source: source, configuration: self.latestRenderConfiguration)
        }
        textView.structuralEditDidApply = { [weak self] in
            guard let self, self.presentation == .rendered else { return }
            // Enter changes paragraph geometry. Commit its native projection before
            // scrolling or drawing the caret; JS resources still resolve asynchronously.
            self.synchronizeStructuralPresentation(source: self.textView.string)
        }
        textView.selectionVisibilityHandler = { [weak self] in self?.centerSelectionForTypewriterMode() }
        textView.retryRenderingHandler = { [weak self] in self?.retryRenderedResources() }
        textView.effectiveAppearanceDidChangeHandler = { [weak self] in
            guard let self, self.presentation == .rendered else { return }
            self.applyRenderedPresentation(source: self.textView.string, force: true)
            self.retryRenderedResources()
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
        let paragraphStyle = MarkdownNativeTypography.paragraphStyle(font: font, lineHeight: CGFloat(appearance.lineHeight))
        textView.sourceCaretFont = font

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
        latestRenderConfiguration = configuration
        textView.readingColumnWidth = min(CGFloat(configuration.contentWidth),
            max(240, configuration.theme.styles.length("max-width") ?? CGFloat(configuration.contentWidth)))
        cancelDeferredMermaidRendering()
        contentDerivationGeneration &+= 1
        let contentGeneration = contentDerivationGeneration
        let mermaidGeneration = deferredMermaidGeneration
        guard let content = await engineClient.derive(
            text: source,
            selectionUTF16: textView.selectedRange(),
            configuration: configuration,
            deferMermaid: configuration.mermaidRenderingEnabled
        ) else { return nil }
        guard !Task.isCancelled, content.nativeRenderPlan.exactlyMatches(source) else { return nil }
        // A resource/theme refresh can supersede this session's installation
        // while a Store request still needs its valid immutable result.
        // Superseded side effects are forbidden; the read itself has not failed.
        guard contentGeneration == contentDerivationGeneration else { return content }
        let planChanged = engineRenderedPlan != content.nativeRenderPlan
        engineRenderedPlan = content.nativeRenderPlan
        layoutPlans.install(content.nativeRenderPlan, configuration: configuration)
        if presentation == .rendered,
           UTF8Text.isExactlyEqual(textView.string, source),
           !textView.hasActiveComposition,
           planChanged || !renderedPresentationIsCurrent(source: source)
        {
            applyRenderedPresentation(source: source, force: planChanged)
        }
        if mermaidGeneration == deferredMermaidGeneration, content.mermaidDeferred,
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
            inputState.withEngineMutation { textView.string = source }
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
        guard !textView.hasActiveComposition, !inputState.isApplyingEngineMutation else { return }
        let previous = engineHistoryTask
        let generation = engineHistoryGeneration
        pendingHistoryCommands += 1
        textView.engineHistoryIsPending = true
        engineHistoryTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.engineHistoryGeneration else { return }
            defer {
                if generation == self.engineHistoryGeneration {
                    self.pendingHistoryCommands -= 1
                    self.textView.engineHistoryIsPending = self.pendingHistoryCommands > 0
                }
            }
            guard !Task.isCancelled, !self.textView.hasActiveComposition else { return }
            // Capture source after the previous command has updated the native
            // surface; rapid Undo/Redo must not both target the pre-Undo text.
            let source = self.textView.string
            let selection = self.textView.selectedRange()
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
            guard !Task.isCancelled, generation == self.engineHistoryGeneration, let mutation else { return }
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
        defer { if restoresUndo { undoManager?.enableUndoRegistration() } }
        return inputState.withEngineMutation {
            textView.insertText(
                mutation.replacement,
                replacementRange: replacementTarget.revealRange
            )
            guard UTF8Text.isExactlyEqual(textView.string, mutation.resultingSource) else {
                return false
            }
            textView.setSelectedRange(finalSelection.revealRange)
            if presentation == .rendered {
                textView.restoreTableFocus(for: finalSelection.revealRange)
            }
            updateSelectedRange(finalSelection.revealRange)
            if presentation == .rendered {
                // Undo/Redo may restore hidden syntax or shorten a quote. Its
                // attributes and decoration ranges must match before publication.
                synchronizeStructuralPresentation(source: mutation.resultingSource)
            }
            if textView.pendingTableFocus == nil {
                textView.scrollRangeToVisible(finalSelection.revealRange)
            }
            inputState.reset()
            updateBoundText?(mutation.resultingSource)
            localTextProjectionDidPublish?(mutation.resultingSource)
            return true
        }
    }

    private func applyAuthoritativeSnapshot(_ snapshot: EditorEngineDocumentSnapshot) {
        guard let selection = MarkdownSourceRange.navigationTarget(
            forUTF8Range: snapshot.selectionUTF8Range, in: snapshot.text
        ), let publishesOptimisticText = inputState.acknowledge(snapshot, isComposing: textView.hasActiveComposition)
        else { return }

        if !UTF8Text.isExactlyEqual(textView.string, snapshot.text) {
            let undoManager = textView.undoManager
            let restoresUndo = undoManager?.isUndoRegistrationEnabled == true
            if restoresUndo { undoManager?.disableUndoRegistration() }
            inputState.withEngineMutation {
                textView.string = snapshot.text
                textView.setSelectedRange(selection.revealRange)
            }
            if restoresUndo { undoManager?.enableUndoRegistration() }

            invalidateSyntaxApplication()
            updateSelectedRange(selection.revealRange)
            lineNumberRuler.updateText(snapshot.text)
            refreshWritingModePresentation()
            scheduleRenderedPresentation(for: snapshot.text)
        }
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
        textView.renderedTheme = theme
        if presentation == .source {
            textView.backgroundColor = .textBackgroundColor
            scrollView.backgroundColor = .textBackgroundColor
            textView.insertionPointColor = .textColor
        }
        textView.linkActivation = linkActivation
        renderedResourceContext = resourceContext
        switch presentation {
        case .source:
            typingStyles.reset()
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

    private func synchronizeStructuralPresentation(source: String) {
        guard presentation == .rendered else { return }
        engineRenderedPlan = layoutPlans.resolve(source: source, configuration: latestRenderConfiguration)
        applyRenderedPresentation(source: source, force: true)
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
        guard var plan = engineRenderedPlan,
              plan.exactlyMatches(source)
        else { return }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for index in plan.renderRequests.indices where plan.renderRequests[index].kind == "math" {
            plan.renderRequests[index].dark = dark
        }
        renderedPlan = plan
        let blockSpacing = plan.blockSpacing
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
                  !plan.tables.contains(where: { NSIntersectionRange($0.sourceRange.utf16Range, request.sourceRange.utf16Range).length > 0 }),
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
        let baseParagraph = MarkdownNativeTypography.paragraphStyle(font: baseFont, lineHeight: CGFloat(sourceAppearance.lineHeight))
        baseParagraph.paragraphSpacing = 0
        let palette = MarkdownRenderPalette.resolved(for: textView.effectiveAppearance, theme: renderedTheme)
        textView.backgroundColor = palette.canvasColor
        scrollView.backgroundColor = palette.canvasColor
        textView.insertionPointColor = palette.textColor
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
        let styleSheet = MarkdownNativeStyleSheet(baseFont: baseFont, palette: palette,
            sourceAppearance: sourceAppearance, isEditable: textView.isEditable, theme: renderedTheme)
        styleSheet.applyCompactParagraphGaps(blockSpacing.separatorLines, storage: storage)
        for style in plan.contentStyles {
            let range = style.sourceRange.utf16Range
            guard NSMaxRange(range) <= storage.length,
                  !rangesOverlap(range, editingRange)
            else { continue }
            styleSheet.applyRenderedAttributes(
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
        typingStyles.install(semanticText: storage, plan: plan, baseAttributes: [
            .font: baseFont, .foregroundColor: palette.textColor, .paragraphStyle: baseParagraph,
        ])
        // Capture semantic input attributes before collapsing display-only gaps.
        styleSheet.collapseBlankLines(blockSpacing.collapsedLines, storage: storage)
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
                styleSheet.applyRenderedReplacement(marker, storage: storage, baseFont: baseFont)
                continue
            }
            if marker.kind == .rule {
                styleSheet.applyRenderedRule(range, storage: storage, baseFont: baseFont)
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
                styleSheet.hideRenderedMarker(
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
            var size = textView.setRenderedTable(
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
            if let grid = textView.renderedTable(atUTF16Location: table.sourceRange.utf16Range.location) {
                size = grid.updateMathPreviews(requests: plan.renderRequests.filter { $0.kind == "math" }, results: javaScriptResults, failures: javaScriptFailures)
            }
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
        styleSheet.applyBlockSpacing(plan.blockSpacingBoundaries, storage: storage)
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
        syncTypingAttributes()
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
        let palette = MarkdownRenderPalette.resolved(for: textView.effectiveAppearance, theme: renderedTheme)
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
        for block in plan.localSourceBlocks where block.reasons.contains(.mermaid) {
            applyRenderFailure("图表渲染失败，请检查语法；右键可重新渲染。", range: block.sourceRange.utf16Range, storage: storage)
        }
        for request in plan.renderRequests where request.kind == "math" {
            guard !plan.tables.contains(where: { NSIntersectionRange($0.sourceRange.utf16Range, request.sourceRange.utf16Range).length > 0 }) else { continue }
            guard let result = javaScriptResults[request.cacheKey], let svg = result.svg,
                  let image = NSImage(data: result.pdfData ?? Data(svg.utf8)) else {
                if javaScriptFailures.contains(request.cacheKey) {
                    storage.addAttributes([.toolTip: "公式渲染失败，请检查 TeX 语法。", .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: NSColor.systemRed], range: request.sourceRange.utf16Range)
                    if request.display {
                        applyRenderFailure("公式渲染失败，请检查 TeX；右键可重新渲染。", range: request.sourceRange.utf16Range, storage: storage)
                    }
                }
                continue
            }
            image.isTemplate = result.pdfData == nil
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

    private func applyRenderFailure(_ message: String, range: NSRange, storage: NSTextStorage) {
        let width = min(560, max(180, textView.bounds.width - textView.textContainerInset.width * 2))
        let image = NSImage(size: NSSize(width: width, height: 32), flipped: false) { rect in
            NSColor.systemRed.withAlphaComponent(0.10).setFill()
            rect.fill()
            (message as NSString).draw(in: rect.insetBy(dx: 8, dy: 7), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
            return true
        }
        let size = textView.setRenderedImage(image, alternative: message, sourceRange: range,
            fillsAvailableWidth: false, placement: .belowSource)
        reserveSpaceBelowRenderedSource(sourceRange: range, size: size, storage: storage)
    }

    private func retryRenderedResources() {
        guard !textView.hasActiveComposition else { return }
        javaScriptFailures.removeAll()
        let source = textView.string
        let configuration = latestRenderConfiguration
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.deriveContent(for: source, configuration: configuration)
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

    private func syncTypingAttributes() {
        guard !textView.hasActiveComposition else { return }
        if presentation == .source {
            textView.typingAttributes = [.font: textView.sourceCaretFont,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: MarkdownNativeTypography.paragraphStyle(font: textView.sourceCaretFont,
                    lineHeight: CGFloat(sourceAppearance.lineHeight))]
            return
        }
        guard let attributes = typingStyles.attributes(in: textView.string, selection: textView.selectedRange())
        else { return }
        textView.typingAttributes = attributes
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
        guard let current, let replacement = RenderedMarkdownTableEditing.replacement(for: current, applying: edit) else { return }
        if edit == .deleteTable {
            textView.pendingTableFocus = nil
            textView.window?.makeFirstResponder(textView)
            textView.replaceRenderedTableSource("", range: current.sourceRange.utf16Range,
                selection: NSRange(location: current.sourceRange.utf16Range.location, length: 0))
            optimisticTable = nil
            applyRenderedPresentation(source: textView.string, force: true)
            return
        }
        guard let localTable = RenderedMarkdownEditor.plan(for: replacement).tables.first else { return }
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
        let grid = textView.renderedTable(atUTF16Location: current.sourceRange.utf16Range.location)
        let focus = grid?.focusedCell
        let pending = textView.pendingTableFocus
        let row = min(pending?.row ?? focus?.row ?? 0, updated.rows.count - 1)
        let column = min(pending?.column ?? focus?.column ?? 0, updated.rows[row].count - 1)
        let cell = updated.rows[row][column]
        let projection = MarkdownInlineProjection(cell.markdown)
        let visible = pending == nil ? focus?.selection : nil
        let local = projection.sourceRange(for: visible ?? NSRange(location: 0, length: cell.text.utf16.count))
            ?? NSRange(location: 0, length: 0)
        let selection = NSRange(location: cell.sourceRange.utf16Range.location + local.location, length: local.length)
        textView.replaceRenderedTableSource(text, range: current.sourceRange.utf16Range, selection: selection)
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

    private func renderedBaseFont() -> NSFont {
        let size = max(6, CGFloat(sourceAppearance.fontSize))
        return renderedTheme.styles.font(size: size, fallback: MarkdownRenderMetrics.bodyFont(size: size))
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
        // AppKit can move the document view origin (for example with content
        // insets). Center in clip-view coordinates, not document coordinates.
        let caretInClip = clipView.convert(NSPoint(x: 0, y: caretMidpoint), from: textView).y
        let documentBounds = clipView.convert(textView.bounds, from: textView)
        let minimumOffset = documentBounds.minY
        let maximumOffset = max(minimumOffset, documentBounds.maxY - clipView.bounds.height)
        let targetOffset = min(
            max(minimumOffset, caretInClip - clipView.bounds.height / 2),
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
        let paragraphStyle = MarkdownNativeTypography.paragraphStyle(font: font, lineHeight: CGFloat(sourceAppearance.lineHeight))
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

    func updateSelectedRange(_ range: NSRange) {
        textView.sourceSelectionHandler?(range)
        if selectedUTF16Range != range {
            selectedUTF16Range = range
            scheduleFormatInspection()
            scheduleRenderedInteractionPresentation()
        }
        syncTypingAttributes()
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
            guard !Task.isCancelled,
                  UTF8Text.isExactlyEqual(textView.string, source),
                  textView.selectedRange() == selection,
                  !textView.hasActiveComposition else { return }
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

    func synchronizeEngine(text: String, selection: NSRange) {
        guard role == .document, !textView.hasActiveComposition else { return }
        engineClient.submit(text: text, selectionUTF16: selection)
    }

    var isRenderedProjection: Bool {
        role == .renderedProjection
    }

    /// SwiftUI is a projection of committed text. It must never replace a native
    /// composition transaction, or a local edit awaiting its Engine acknowledgement.
    enum BoundTextUpdate {
        case deferred, unchanged, replaced
    }

    func reconcileBoundText(_ boundText: String) -> BoundTextUpdate {
        guard role == .document else { return .unchanged }
        let decision = inputState.bindingDecision(bound: boundText, native: textView.string,
            isComposing: textView.hasActiveComposition)
        guard decision != .deferred else { return .deferred }
        if decision == .replace {
            let selection = textView.selectedRange()
            textView.string = boundText
            let length = boundText.utf16.count
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        synchronizeEngine(text: textView.string, selection: textView.selectedRange())
        return decision == .replace ? .replaced : .unchanged
    }

    func requestRestoration(_ state: MarkdownRestorationState) {
        pendingRestorationState = state
        applyPendingRestorationIfPossible()
    }

    func resetAfterExternalReload(_ text: String) {
        engineHistoryGeneration &+= 1
        engineHistoryTask?.cancel()
        engineHistoryTask = nil
        pendingHistoryCommands = 0
        textView.engineHistoryIsPending = false
        contentDerivationGeneration &+= 1
        typingStyles.reset()
        layoutPlans.invalidate()
        cancelDeferredMermaidRendering()
        renderedInteractionTask?.cancel()
        engineRenderedPlan = nil
        textView.writingPlan = nil
        formatInspectionTask?.cancel()
        formatInspectionGeneration &+= 1
        invalidateSyntaxApplication()
        inputState.reset()
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

    func applyPendingRestorationIfPossible() {
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
