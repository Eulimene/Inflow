import AppKit
import SwiftUI

struct RenderedMarkdownResourceContext: Equatable, Sendable {
    let documentDirectory: URL?
    let projectRoot: URL?
    let expectedProjectRootIdentity: FolderProjectDirectoryIdentity?
    let requiresProjectBoundary: Bool

    static let unavailable = Self(
        documentDirectory: nil,
        projectRoot: nil,
        expectedProjectRootIdentity: nil,
        requiresProjectBoundary: false
    )
}

enum RenderedMarkdownImageTarget: Equatable, Sendable {
    case remote(URL)
    case local(URL)

    static func resolve(_ target: String, documentDirectory: URL?) -> Self? {
        if let components = URLComponents(string: target),
           let scheme = components.scheme?.lowercased()
        {
            if scheme == "http" || scheme == "https" {
                guard components.host?.isEmpty == false,
                      components.user == nil,
                      components.password == nil,
                      let url = components.url
                else {
                    return nil
                }
                return .remote(url)
            }
            guard scheme == "file",
                  components.host == nil
                    || components.host?.isEmpty == true
                    || components.host == "localhost",
                  components.user == nil,
                  components.password == nil,
                  let path = components.percentEncodedPath.removingPercentEncoding,
                  !path.isEmpty
            else {
                return nil
            }
            return .local(URL(fileURLWithPath: path).standardizedFileURL)
        }
        if target.hasPrefix("/") {
            guard let path = target.removingPercentEncoding else { return nil }
            return .local(URL(fileURLWithPath: path).standardizedFileURL)
        }
        guard let documentDirectory,
              let url = URL(string: target, relativeTo: documentDirectory)?.absoluteURL,
              url.isFileURL
        else {
            return nil
        }
        return .local(url.standardizedFileURL)
    }
}

actor RenderedMarkdownImageLoader {
    static let shared = RenderedMarkdownImageLoader()

    private var remoteCache: [URL: Data] = [:]
    private var remoteCacheOrder: [URL] = []
    private let maximumRemoteEntries = 24

    func load(
        target: String,
        context: RenderedMarkdownResourceContext
    ) async -> Data? {
        guard !Task.isCancelled, !target.isEmpty else { return nil }
        guard let resolved = RenderedMarkdownImageTarget.resolve(
            target,
            documentDirectory: context.documentDirectory
        ) else {
            return nil
        }
        if case let .remote(remoteURL) = resolved {
            return await loadRemote(remoteURL)
        }
        guard case let .local(localURL) = resolved else { return nil }

        let readsOutsideProject: Bool
        if let projectRoot = context.projectRoot,
           let normalizedRoot = try? FolderProjectPathBoundary.normalizedProjectRoot(projectRoot),
           context.expectedProjectRootIdentity.map({
               FolderProjectDirectoryIdentity.capture(normalizedRoot) == $0
           }) ?? true
        {
            readsOutsideProject = FolderProjectPathBoundary.resolvedURL(
                localURL,
                within: normalizedRoot
            ) == nil
        } else {
            readsOutsideProject = false
        }

        return try? ProjectBoundLocalImageLoader.load(
            at: localURL,
            projectRoot: readsOutsideProject ? nil : context.projectRoot,
            expectedProjectRootIdentity: readsOutsideProject
                ? nil
                : context.expectedProjectRootIdentity,
            requiresProjectBoundary: readsOutsideProject
                ? false
                : context.requiresProjectBoundary
        ).data
    }

    private func loadRemote(_ url: URL) async -> Data? {
        if let cached = remoteCache[url] { return cached }
        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 20
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              data.count <= LocalImageValidator.maximumBytes,
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.lowercased().hasPrefix("image/") == true
        else {
            return nil
        }
        remoteCache[url] = data
        remoteCacheOrder.removeAll { $0 == url }
        remoteCacheOrder.append(url)
        while remoteCacheOrder.count > maximumRemoteEntries {
            remoteCache.removeValue(forKey: remoteCacheOrder.removeFirst())
        }
        return data
    }
}

private extension RenderedMarkdownMarkerKind {
    /// Structural prefixes carry meaning of their own. Keeping them visible
    /// prevents inactive list, task, and quote blocks from collapsing into
    /// visually indistinguishable paragraphs while inline punctuation can
    /// still recede until the user edits that paragraph.
    var remainsVisibleWhenInactive: Bool {
        switch self {
        case .unorderedList, .orderedList, .taskList:
            true
        case .heading, .blockQuote, .referenceDefinition, .emphasis, .strong, .strikethrough,
             .inlineCode, .tableBoundary, .tableSeparator, .tableDelimiterRow, .linkDelimiter,
             .linkDestination:
            false
        }
    }
}

enum MarkdownEditorPresentation: Equatable {
    case source
    case rendered
}

struct SourceSelectionRequest: Equatable {
    let generation: Int
    let utf8Range: Range<Int>
    let style: SourceSelectionStyle
    let focusesEditor: Bool

    init(
        generation: Int,
        utf8Range: Range<Int>,
        style: SourceSelectionStyle = .caret,
        focusesEditor: Bool = true
    ) {
        self.generation = generation
        self.utf8Range = utf8Range
        self.style = style
        self.focusesEditor = focusesEditor
    }
}

enum SourceSelectionStyle: Equatable {
    case caret
    case match

    var showsTransientMatchIndicator: Bool { self == .match }
}

struct SourceNavigationTarget: Equatable {
    let revealRange: NSRange
    let caretRange: NSRange
}

enum MarkdownSourceRange {
    static func utf8Range(
        forUTF16Range utf16Range: NSRange,
        in text: String
    ) -> Range<Int>? {
        let utf16 = text.utf16
        guard utf16Range.location >= 0,
              utf16Range.length >= 0,
              utf16Range.location <= utf16.count,
              utf16Range.length <= utf16.count - utf16Range.location,
              let lowerUTF16 = utf16.index(
                  utf16.startIndex,
                  offsetBy: utf16Range.location,
                  limitedBy: utf16.endIndex
              ),
              let upperUTF16 = utf16.index(
                  lowerUTF16,
                  offsetBy: utf16Range.length,
                  limitedBy: utf16.endIndex
              ),
              let lower = String.Index(lowerUTF16, within: text),
              let upper = String.Index(upperUTF16, within: text),
              let lowerUTF8 = lower.samePosition(in: text.utf8),
              let upperUTF8 = upper.samePosition(in: text.utf8)
        else {
            return nil
        }

        let lowerOffset = text.utf8.distance(from: text.utf8.startIndex, to: lowerUTF8)
        let upperOffset = text.utf8.distance(from: text.utf8.startIndex, to: upperUTF8)
        return lowerOffset..<upperOffset
    }

    static func navigationTarget(
        forUTF8Range utf8Range: Range<Int>,
        in text: String
    ) -> SourceNavigationTarget? {
        guard utf8Range.lowerBound >= 0,
              utf8Range.lowerBound <= utf8Range.upperBound,
              utf8Range.upperBound <= text.utf8.count,
              let lowerUTF8 = text.utf8.index(
                  text.utf8.startIndex,
                  offsetBy: utf8Range.lowerBound,
                  limitedBy: text.utf8.endIndex
              ),
              let upperUTF8 = text.utf8.index(
                  text.utf8.startIndex,
                  offsetBy: utf8Range.upperBound,
                  limitedBy: text.utf8.endIndex
              ),
              let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text)
        else {
            return nil
        }

        let revealRange = NSRange(lower..<upper, in: text)
        return SourceNavigationTarget(
            revealRange: revealRange,
            caretRange: NSRange(location: revealRange.location, length: 0)
        )
    }
}

@MainActor
final class MarkdownSourceEditorSession: NSObject, ObservableObject {
    let scrollView: NSScrollView
    let textView: WindowAwareTextView
    @Published private(set) var selectedUTF16Range = NSRange(location: 0, length: 0)
    @Published private(set) var verticalScrollOffset = 0.0
    @Published private(set) var verticalScrollFraction = 0.0
    fileprivate var appliedSelectionGeneration: Int?
    fileprivate var pendingSelectionRequest: SourceSelectionRequest?
    fileprivate var pendingRestorationState: MarkdownRestorationState?
    fileprivate var updateBoundText: ((String) -> Void)?
    private(set) var sourceAppearance = SourceEditorAppearance.default
    private var hasAppliedSourceAppearance = false
    private var syntaxHighlightingEnabled = false
    private var syntaxHighlightingSourceUTF8 = Data()
    private var syntaxHighlightingSpans: [MarkdownSyntaxSpan] = []
    private var syntaxApplicationGeneration = 0
    private var syntaxApplicationTask: Task<Void, Never>?
    private var presentation = MarkdownEditorPresentation.source
    private var renderedPlan: RenderedMarkdownPlan?
    private var renderedEditingRange: NSRange?
    private var renderedAppliedAppearance: SourceEditorAppearance?
    private var renderedLinkHandler: ((String) -> Void)?
    private var renderedLinkActivation = LinkActivationPreference.singleClick
    private var renderedResourceContext = RenderedMarkdownResourceContext.unavailable
    private var renderedImageGeneration = 0
    private var renderedImageTask: Task<Void, Never>?
    private var renderedInteractionTask: Task<Void, Never>?
    private let lineNumberRuler: MarkdownLineNumberRulerView
    private var focusModeEnabled = false
    private var typewriterModeEnabled = false

    override init() {
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
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 12, height: 14)
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
        textView.textDidChangeHandler = { [weak self] text in
            self?.invalidateSyntaxApplication()
            self?.lineNumberRuler.updateText(text)
            self?.refreshWritingModePresentation()
            self?.updateBoundText?(text)
            self?.scheduleRenderedPresentation(for: text)
        }
        textView.focusDidChangeHandler = { [weak self] in
            self?.scheduleRenderedInteractionPresentation()
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
        guard force || !hasAppliedSourceAppearance || sourceAppearance != appearance else { return }
        sourceAppearance = appearance
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

    func setPresentation(
        _ presentation: MarkdownEditorPresentation,
        source: String,
        onLinkClick: ((String) -> Void)?,
        resourceContext: RenderedMarkdownResourceContext = .unavailable,
        linkActivation: LinkActivationPreference = .singleClick
    ) {
        let changed = self.presentation != presentation
        let resourceContextChanged = renderedResourceContext != resourceContext
        let linkActivationChanged = renderedLinkActivation != linkActivation
        self.presentation = presentation
        renderedLinkHandler = onLinkClick
        renderedLinkActivation = linkActivation
        textView.linkActivation = linkActivation
        renderedResourceContext = resourceContext
        switch presentation {
        case .source:
            renderedInteractionTask?.cancel()
            renderedInteractionTask = nil
            cancelRenderedImageLoading()
            renderedPlan = nil
            renderedEditingRange = nil
            textView.linkClickHandler = nil
            textView.clickableLinkRanges = []
            textView.clearRenderedImages()
            textView.renderedQuoteRanges = []
            textView.renderedInlineCodeRanges = []
            textView.setAccessibilityLabel("Markdown 源码编辑器")
            applySourceAppearance(sourceAppearance, force: changed)
        case .rendered:
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
                    || !renderedPresentationIsCurrent(source: source)
            )
        }
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
            && currentRenderedEditingRange(source: source) == renderedEditingRange
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
              !textView.hasMarkedText()
        else {
            return
        }
        let selection = textView.selectedRange()
        if !force,
           renderedPlan?.exactlyMatches(source) == true,
           renderedAppliedAppearance == sourceAppearance
        {
            return
        }

        invalidateSyntaxApplication()
        let plan = RenderedMarkdownEditor.plan(for: source)
        renderedPlan = plan
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
            return rangesOverlap(range, editingRange) ? nil : range
        }
        textView.beginRenderedOverlayUpdate()
        textView.renderedQuoteRanges = plan.contentStyles.compactMap { style in
            guard style.kind == .blockQuote else { return nil }
            guard !rangesOverlap(style.sourceRange.utf16Range, editingRange) else { return nil }
            return style.sourceRange.utf16Range
        }
        textView.renderedInlineCodeRanges = plan.contentStyles.compactMap { style in
            guard style.kind == .inlineCode else { return nil }
            guard !rangesOverlap(style.sourceRange.utf16Range, editingRange) else { return nil }
            return style.sourceRange.utf16Range
        }
        scrollView.hasVerticalRuler = false
        scrollView.rulersVisible = false

        let baseFont = NSFont.systemFont(ofSize: max(15, CGFloat(sourceAppearance.fontSize)))
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineHeightMultiple = CGFloat(sourceAppearance.lineHeight)
        baseParagraph.paragraphSpacing = 6
        textView.font = baseFont
        textView.defaultParagraphStyle = baseParagraph
        textView.typingAttributes = [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: baseParagraph,
        ]

        guard let storage = textView.textStorage else { return }
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
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: baseParagraph,
            ],
            range: fullRange
        )
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
            editingParagraph.paragraphSpacing = 6
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
                            ofSize: max(13, CGFloat(sourceAppearance.fontSize)),
                            weight: .regular
                        ),
                        .foregroundColor: NSColor.labelColor,
                        .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.16),
                    ],
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
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.08),
                ],
                range: range
            )
        }
        for marker in plan.markers {
            let range = marker.sourceRange.utf16Range
            guard NSMaxRange(range) <= storage.length,
                  !plan.localSourceBlocks.contains(where: {
                      NSIntersectionRange($0.sourceRange.utf16Range, range).length > 0
                  })
            else {
                continue
            }
            if rangesOverlap(range, editingRange) { continue }
            if marker.kind.remainsVisibleWhenInactive {
                storage.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: max(12, CGFloat(sourceAppearance.fontSize) - 2),
                            weight: .regular
                        ),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .backgroundColor: NSColor.clear,
                        .underlineStyle: 0,
                        .strikethroughStyle: 0,
                        .obliqueness: 0,
                    ],
                    range: range
                )
            } else {
                hideRenderedMarker(range, storage: storage, fallbackFont: baseFont)
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
                storage: storage
            )
        }
        for table in plan.tables {
            guard !rangesOverlap(table.sourceRange.utf16Range, editingRange) else { continue }
            let size = textView.setRenderedTable(
                table,
                baseFont: baseFont,
                maximumWidth: max(240, scrollView.contentSize.width - 32),
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
            guard !rangesOverlap(diagram.sourceRange.utf16Range, editingRange) else { continue }
            guard let image = renderedMermaidImage(from: diagram.svg) else { continue }
            applyRenderedImage(
                image,
                alternative: "Mermaid 图表",
                sourceRange: diagram.sourceRange.utf16Range,
                storage: storage
            )
        }
        textView.endRenderedOverlayUpdate()
        storage.endEditing()
        renderedAppliedAppearance = sourceAppearance
        textView.setSelectedRange(selection)
        syncRenderedTypingAttributes()
        refreshWritingModePresentation()
        loadRenderedImages(for: plan)
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
            storage: storage
        )
        storage.endEditing()
        textView.setSelectedRange(selection)
        textView.needsDisplay = true
    }

    private func applyRenderedImage(
        _ image: NSImage?,
        alternative: String,
        sourceRange: NSRange,
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

        let displayedImage = scaledRenderedImage(
            image ?? NSImage(
                systemSymbolName: "photo",
                accessibilityDescription: alternative.isEmpty ? "图片" : alternative
            ) ?? NSImage(size: NSSize(width: 28, height: 28))
        )
        displayedImage.accessibilityDescription = alternative.isEmpty ? "图片" : alternative
        storage.addAttribute(
            .kern,
            value: displayedImage.size.width,
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
            displayedImage.size.height + 10
        )
        storage.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: sourceRange.location, length: 1)
        )
        textView.setRenderedImage(
            displayedImage,
            alternative: alternative,
            sourceRange: sourceRange
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
        storage.addAttribute(
            .kern,
            value: size.width,
            range: NSRange(location: sourceRange.location, length: 1)
        )
        let paragraphStyle = (
            storage.attribute(.paragraphStyle, at: sourceRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = max(paragraphStyle.minimumLineHeight, size.height + 10)
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
        guard presentation == .rendered,
              let storage = textView.textStorage,
              storage.length > 0
        else { return }
        let selection = textView.selectedRange()
        var location = min(selection.location, storage.length - 1)
        if let plan = renderedPlan {
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
        textView.typingAttributes = typing
    }

    private func hideRenderedMarker(
        _ range: NSRange,
        storage: NSTextStorage,
        fallbackFont: NSFont
    ) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let neighbor = RenderedMarkdownCaretStyleResolver.nearestVisibleLocation(
            to: range,
            textLength: storage.length,
            hiddenRanges: renderedPlan?.markers.map(\.sourceRange.utf16Range) ?? []
        )
        let font = neighbor.flatMap {
            storage.attribute(.font, at: $0, effectiveRange: nil) as? NSFont
        } ?? fallbackFont
        storage.addAttributes(
            [
                .font: font,
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .obliqueness: 0,
                .baselineOffset: 0,
            ],
            range: range
        )
        let source = storage.string as NSString
        for location in range.location..<NSMaxRange(range) {
            let character = source.substring(with: NSRange(location: location, length: 1))
            let advance = (character as NSString).size(withAttributes: [.font: font]).width
            storage.addAttribute(
                .kern,
                value: -advance,
                range: NSRange(location: location, length: 1)
            )
        }
    }

    private func applyRenderedTableEdit(
        _ edit: RenderedMarkdownTableEdit,
        to table: RenderedMarkdownTable
    ) {
        guard presentation == .rendered,
              textView.isEditable,
              let replacement = RenderedMarkdownTableEditing.replacement(
                  for: table,
                  applying: edit
              ),
              NSMaxRange(table.sourceRange.utf16Range) <= (textView.string as NSString).length
        else { return }
        textView.insertText(replacement, replacementRange: table.sourceRange.utf16Range)
        textView.undoManager?.setActionName("编辑表格")
    }

    private func renderedMermaidImage(from sourceSVG: String) -> NSImage? {
        let styledSVG = sourceSVG.replacingOccurrences(
            of: "<defs>",
            with: """
            <defs><style>
            .node rect { fill: #f6f8fa; stroke: #57606a; stroke-width: 1.5; }
            text { fill: #24292f; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
            line, marker path { color: #57606a; }
            </style>
            """
        )
        guard let image = NSImage(data: Data(styledSVG.utf8)), image.isValid else { return nil }
        image.accessibilityDescription = "Mermaid 图表"
        return image
    }

    private func scaledRenderedImage(_ source: NSImage) -> NSImage {
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return source }
        let availableWidth = max(240, min(720, scrollView.contentSize.width - 32))
        let scale = min(1, availableWidth / sourceSize.width, 480 / sourceSize.height)
        guard scale < 1, let copy = source.copy() as? NSImage else { return source }
        copy.size = NSSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )
        return copy
    }

    private func applyRenderedAttributes(
        for kind: RenderedMarkdownContentStyleKind,
        range: NSRange,
        storage: NSTextStorage,
        baseFont: NSFont
    ) {
        switch kind {
        case .paragraph, .unorderedListItem, .orderedListItem, .taskListItem:
            break
        case let .heading(level):
            storage.addAttributes(
                [
                .font: NSFont.systemFont(
                    ofSize: max(baseFont.pointSize, 30 - CGFloat(level * 3)),
                    weight: level <= 2 ? .bold : .semibold
                ),
                .foregroundColor: NSColor.labelColor,
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
                    ofSize: max(13, font.pointSize),
                    weight: .regular
                )
            }
            storage.addAttribute(.baselineOffset, value: 0, range: range)
        case .blockQuote:
            let paragraphStyle = (
                storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent += 16
            paragraphStyle.headIndent += 16
            paragraphStyle.paragraphSpacingBefore = max(paragraphStyle.paragraphSpacingBefore, 3)
            paragraphStyle.paragraphSpacing = max(paragraphStyle.paragraphSpacing, 3)
            storage.addAttributes(
                [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraphStyle,
                ],
                range: range
            )
        case .tableHeader:
            transformFonts(in: range, storage: storage) { font in
                NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            applyRenderedTableRow(
                range: range,
                storage: storage,
                backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10)
            )
        case let .tableBody(alternating):
            applyRenderedTableRow(
                range: range,
                storage: storage,
                backgroundColor: alternating
                    ? NSColor.quaternaryLabelColor.withAlphaComponent(0.22)
                    : NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
            )
        case .link:
            storage.addAttributes(
                [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: range
            )
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
              textView.window != nil,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let length = (textView.string as NSString).length
        let selectionLocation = min(textView.selectedRange().location, length)
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
        let caretMidpoint = caretRect.midY + textView.textContainerOrigin.y
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
        syntaxHighlightingEnabled = enabled
        syntaxHighlightingSourceUTF8 = Data(source.utf8)
        syntaxHighlightingSpans = enabled ? spans : []
        guard UTF8Text.isExactlyEqual(textView.string, source) else { return false }
        if presentation == .source {
            applySourceAppearance(sourceAppearance, force: true)
        } else {
            applyRenderedPresentation(source: source, force: true)
        }
        return true
    }

    private func scheduleCachedSyntaxHighlighting(baseFont: NSFont) {
        syntaxApplicationTask?.cancel()
        syntaxApplicationGeneration &+= 1
        let generation = syntaxApplicationGeneration
        guard presentation == .source,
              syntaxHighlightingEnabled,
              syntaxHighlightingSourceUTF8 == Data(textView.string.utf8)
        else {
            return
        }

        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let sortedSpans = syntaxHighlightingSpans
        syntaxApplicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for batchStart in stride(from: 0, to: sortedSpans.count, by: 512) {
                guard !Task.isCancelled,
                      generation == self.syntaxApplicationGeneration,
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
        }
    }

    private func invalidateSyntaxApplication() {
        syntaxApplicationTask?.cancel()
        syntaxApplicationGeneration &+= 1
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
            [
                .foregroundColor: NSColor.systemPurple,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
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

    @objc
    private func undoManagerChangedText(_ notification: Notification) {
        invalidateSyntaxApplication()
        lineNumberRuler.updateText(textView.string)
        updateBoundText?(textView.string)
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
            scheduleRenderedInteractionPresentation()
        }
        syncRenderedTypingAttributes()
        refreshWritingModePresentation()
    }

    func requestRestoration(_ state: MarkdownRestorationState) {
        pendingRestorationState = state
        applyPendingRestorationIfPossible()
    }

    func resetAfterExternalReload(_ text: String) {
        invalidateSyntaxApplication()
        let previousSelection = textView.selectedRange()
        textView.string = text
        let utf16Length = (text as NSString).length
        let location = min(previousSelection.location, utf16Length)
        let length = min(previousSelection.length, utf16Length - location)
        let selection = NSRange(location: location, length: length)
        textView.setSelectedRange(selection)
        updateSelectedRange(selection)
        textView.undoManager?.removeAllActions()
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
    ) -> Bool {
        guard textView.isEditable,
              UTF8Text.isExactlyEqual(textView.string, expectedText),
              let target = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: utf8Range,
                  in: expectedText
              )
        else {
            return false
        }

        textView.insertText(replacement, replacementRange: target.revealRange)
        textView.undoManager?.setActionName("替换")
        return true
    }

    @discardableResult
    func replaceAll(
        utf8Ranges: [Range<Int>],
        with replacement: String,
        expectedText: String
    ) -> Bool {
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
        let fullRange = NSRange(location: 0, length: (expectedText as NSString).length)
        textView.insertText(finalText, replacementRange: fullRange)
        textView.undoManager?.setActionName("全部替换")
        return true
    }

    @discardableResult
    func applyMarkdownFormat(
        _ plan: MarkdownFormatPlan,
        actionName: String
    ) -> Bool {
        guard textView.isEditable,
              !textView.hasMarkedText(),
              UTF8Text.isExactlyEqual(textView.string, plan.sourceSnapshot),
              let replacementTarget = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: plan.replaceUTF8Range,
                  in: plan.sourceSnapshot
              ),
              let finalSelection = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: plan.selectionUTF8Range,
                  in: plan.resultingSource
              )
        else {
            return false
        }

        textView.insertText(
            plan.replacement,
            replacementRange: replacementTarget.revealRange
        )
        guard UTF8Text.isExactlyEqual(textView.string, plan.resultingSource) else {
            textView.undoManager?.undo()
            return false
        }

        textView.setSelectedRange(finalSelection.revealRange)
        updateSelectedRange(finalSelection.revealRange)
        textView.scrollRangeToVisible(finalSelection.revealRange)
        textView.undoManager?.setActionName(actionName)
        return true
    }

    @discardableResult
    func applyMarkdownImage(
        _ plan: MarkdownFormatPlan,
        asset _: ImportedImageAsset,
        actionName: String,
        onResourceError _: @escaping @MainActor (String) -> Void
    ) -> Bool {
        // The imported file is a durable project resource. Undo owns only the
        // Markdown reference; removing the asset could break another document
        // that started using it after insertion.
        applyMarkdownFormat(plan, actionName: actionName)
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
        preference: LinkActivationPreference
    ) -> Bool {
        guard preference == .singleClick else { return false }
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.isEmpty || modifiers == .command
    }
}

enum RenderedMarkdownCaretStyleResolver {
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

    static func nearestVisibleLocation(
        to range: NSRange,
        textLength: Int,
        hiddenRanges: [NSRange]
    ) -> Int? {
        guard textLength > 0 else { return nil }
        if NSMaxRange(range) < textLength,
           !isHidden(NSMaxRange(range), in: hiddenRanges)
        {
            return NSMaxRange(range)
        }
        var location = range.location - 1
        while location >= 0 {
            if !isHidden(location, in: hiddenRanges) { return location }
            location -= 1
        }
        return nil
    }

    static func adjustedInsertionRect(_ rect: NSRect, font: NSFont?) -> NSRect {
        guard let font else { return rect }
        let fontHeight = ceil(font.ascender - font.descender + font.leading)
        let height = min(rect.height, max(1, fontHeight))
        return NSRect(
            x: rect.origin.x,
            y: rect.midY - height / 2,
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

@MainActor
final class WindowAwareTextView: NSTextView {
    private struct RenderedImageViewState {
        let sourceRange: NSRange
        let imageView: RenderedMarkdownImageView
    }

    private struct RenderedTableViewState {
        let sourceRange: NSRange
        let tableView: RenderedMarkdownTableView
    }

    private let persistentUndoManager = UndoManager()
    var didAttachToWindow: (() -> Void)?
    var focusDidChangeHandler: (() -> Void)?
    var textDidChangeHandler: ((String) -> Void)?
    var pasteImageHandler: ((ClipboardImagePayload) -> Void)?
    var dropImageHandler: ((URL) -> Void)?
    var linkClickHandler: ((Int) -> Bool)?
    var linkActivation = LinkActivationPreference.singleClick
    var clickableLinkRanges: [NSRange] = [] {
        didSet {
            guard oldValue != clickableLinkRanges else { return }
            if let hoveredLinkRange, !clickableLinkRanges.contains(hoveredLinkRange) {
                self.hoveredLinkRange = nil
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
    private var renderedImageViews: [Int: RenderedImageViewState] = [:]
    private var renderedTableViews: [Int: RenderedTableViewState] = [:]
    private var retainedRenderedOverlayKeys: Set<Int>?
    private var renderedImageLayoutTask: Task<Void, Never>?
    private var isUpdatingRenderedOverlayLayout = false
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredLinkRange: NSRange?

    override var undoManager: UndoManager? {
        persistentUndoManager
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        super.drawInsertionPoint(
            in: RenderedMarkdownCaretStyleResolver.adjustedInsertionRect(
                rect,
                font: typingAttributes[.font] as? NSFont
            ),
            color: color,
            turnedOn: flag
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged, !renderedImageViews.isEmpty || !renderedTableViews.isEmpty {
            scheduleRenderedImageLayout()
        }
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
        hoveredLinkRange = range
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

    func setRenderedImage(
        _ image: NSImage,
        alternative: String,
        sourceRange: NSRange
    ) {
        let key = sourceRange.location
        retainedRenderedOverlayKeys?.insert(key)
        let imageView: RenderedMarkdownImageView
        if let existing = renderedImageViews[key], existing.sourceRange == sourceRange {
            imageView = existing.imageView
        } else {
            renderedImageViews[key]?.imageView.removeFromSuperview()
            imageView = RenderedMarkdownImageView()
            imageView.imageScaling = .scaleProportionallyDown
            addSubview(imageView)
            renderedImageViews[key] = RenderedImageViewState(
                sourceRange: sourceRange,
                imageView: imageView
            )
        }
        imageView.image = image
        imageView.setAccessibilityLabel(alternative.isEmpty ? "图片" : alternative)
        scheduleRenderedImageLayout()
    }

    func renderedImage(atUTF16Location location: Int) -> NSImage? {
        renderedImageViews[location]?.imageView.image
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
        retainedRenderedOverlayKeys?.insert(key)
        if let existing = renderedTableViews[key],
           existing.sourceRange == table.sourceRange.utf16Range,
           existing.tableView.linkActivation == linkActivation
        {
            if existing.tableView.table == table
                || existing.tableView.hasSameLiveRenderedContent(as: table)
            {
                existing.tableView.update(table: table, onEdit: onEdit)
                existing.tableView.updateMaximumWidth(maximumWidth)
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
            onLinkClick: onLinkClick,
            onEdit: onEdit
        )
        addSubview(tableView)
        renderedTableViews[key] = RenderedTableViewState(
            sourceRange: table.sourceRange.utf16Range,
            tableView: tableView
        )
        scheduleRenderedImageLayout()
        return tableView.renderedSize
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

    private func layoutRenderedImages() {
        guard let layoutManager, let textContainer, !isUpdatingRenderedOverlayLayout else { return }
        isUpdatingRenderedOverlayLayout = true
        defer { isUpdatingRenderedOverlayLayout = false }
        let availableWidth = max(
            240,
            bounds.width - textContainerInset.width * 2 - textContainer.lineFragmentPadding * 2
        )
        if let storage = textStorage {
            let resizedTables = renderedTableViews.values.compactMap { state -> (NSRange, NSSize)? in
                state.tableView.updateMaximumWidth(availableWidth)
                    ? (state.sourceRange, state.tableView.renderedSize)
                    : nil
            }
            if !resizedTables.isEmpty {
                let undoManager = undoManager
                let restoresUndo = undoManager?.isUndoRegistrationEnabled == true
                if restoresUndo { undoManager?.disableUndoRegistration() }
                storage.beginEditing()
                for (range, size) in resizedTables
                where range.length > 0 && NSMaxRange(range) <= storage.length {
                    let paragraph = (
                        storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                            as? NSParagraphStyle
                    )?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    paragraph.minimumLineHeight = size.height + 10
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
            let glyphIndex = layoutManager.glyphIndexForCharacter(
                at: state.sourceRange.location
            )
            guard glyphIndex < layoutManager.numberOfGlyphs,
                  let image = state.imageView.image
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
                x: textContainerOrigin.x + glyphRect.minX,
                y: textContainerOrigin.y + lineRect.minY + 5,
                width: image.size.width,
                height: image.size.height
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
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        for range in renderedInlineCodeRanges {
            drawRoundedBackground(
                for: range,
                color: NSColor.quaternaryLabelColor.withAlphaComponent(0.24),
                horizontalPadding: 3,
                radius: 4,
                layoutManager: layoutManager,
                textContainer: textContainer,
                dirtyRect: rect
            )
        }
        if let hoveredLinkRange {
            drawRoundedBackground(
                for: hoveredLinkRange,
                color: NSColor.controlAccentColor.withAlphaComponent(0.13),
                horizontalPadding: 3,
                radius: 4,
                layoutManager: layoutManager,
                textContainer: textContainer,
                dirtyRect: rect
            )
        }
        NSColor.separatorColor.setFill()
        for characterRange in renderedQuoteRanges where characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                lineRect, _, _, _, _ in
                let bar = NSRect(
                    x: self.textContainerOrigin.x + lineRect.minX + 3,
                    y: self.textContainerOrigin.y + lineRect.minY + 1,
                    width: 3,
                    height: max(1, lineRect.height - 2)
                )
                if bar.intersects(rect) { bar.fill() }
            }
        }
    }

    private func drawRoundedBackground(
        for characterRange: NSRange,
        color: NSColor,
        horizontalPadding: CGFloat,
        radius: CGFloat,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        dirtyRect: NSRect
    ) {
        guard characterRange.length > 0,
              NSMaxRange(characterRange) <= (string as NSString).length
        else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { glyphRect, _ in
            let background = glyphRect
                .offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                .insetBy(dx: -horizontalPadding, dy: -1)
            guard background.intersects(dirtyRect) else { return }
            color.setFill()
            NSBezierPath(roundedRect: background, xRadius: radius, yRadius: radius).fill()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        textDidChangeHandler?(string)
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
        super.paste(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = localPoint(forWindowPoint: event.locationInWindow)
        if RenderedMarkdownLinkActivation.shouldNavigate(
            for: event.modifierFlags,
            preference: linkActivation
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
        persistentUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        persistentUndoManager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            persistentUndoManager.canUndo
        case #selector(redo(_:)):
            persistentUndoManager.canRedo
        default:
            super.validateUserInterfaceItem(item)
        }
    }
}

final class RenderedMarkdownImageView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class RenderedMarkdownTableView: NSView, NSTextViewDelegate {
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
    private let cells: [CellLayout]
    private let onLinkClick: (String) -> Void
    private var onEdit: (RenderedMarkdownTableEdit) -> Void
    private let baseFont: NSFont
    private let layoutStrategy: any RenderedMarkdownTableLayoutStrategy
    private var maximumWidth: CGFloat
    private var contextCell = (row: 0, column: 0)
    private var contextLinkTarget: String?
    private(set) var renderedSize: NSSize
    let cellTexts: [[String]]
    private(set) var table: RenderedMarkdownTable
    let linkActivation: LinkActivationPreference

    override var isFlipped: Bool { true }

    init(
        table: RenderedMarkdownTable,
        baseFont: NSFont,
        maximumWidth: CGFloat,
        linkActivation: LinkActivationPreference,
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
        self.maximumWidth = maximumWidth
        cellTexts = table.rows.map { $0.map(\.text) }
        let widths = layoutStrategy.columnWidths(
            for: table,
            font: baseFont,
            availableWidth: max(160, maximumWidth)
        )
        columnWidths = widths

        let heights = Self.rowHeights(for: table, widths: widths, baseFont: baseFont)
        rowHeights = heights
        renderedSize = NSSize(width: widths.reduce(0, +), height: heights.reduce(0, +))

        var layouts: [CellLayout] = []
        for (rowIndex, row) in table.rows.enumerated() {
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
                let attributed = NSMutableAttributedString(
                    string: cell.text,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: paragraph,
                    ]
                )
                for link in cell.links
                where link.visibleRange.length > 0
                    && NSMaxRange(link.visibleRange) <= attributed.length {
                    attributed.addAttributes(
                        [
                            .link: link.target,
                            .foregroundColor: NSColor.linkColor,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                        ],
                        range: link.visibleRange
                    )
                }
                let textView = RenderedMarkdownTableCellTextView()
                textView.isEditable = true
                textView.isSelectable = true
                textView.isRichText = true
                textView.drawsBackground = false
                textView.textContainerInset = .zero
                textView.textContainer?.lineFragmentPadding = 0
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.heightTracksTextView = false
                textView.textStorage?.setAttributedString(attributed)
                textView.delegate = nil
                textView.setAccessibilityLabel(cell.text)
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
        cells = layouts
        super.init(frame: NSRect(origin: .zero, size: renderedSize))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        for layout in cells {
            layout.textView.delegate = self
            layout.textView.linkActivation = linkActivation
            layout.textView.onLinkClick = onLinkClick
            layout.textView.contextMenuProvider = { [weak self, weak textView = layout.textView]
                event in
                guard let self, let textView else { return nil }
                return self.tableMenu(for: layout.row, column: layout.column, event: event, in: textView)
            }
            addSubview(layout.textView)
        }
        layoutCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
        self.table = table
        self.onEdit = onEdit
        for cell in cells {
            cell.originalText = table.rows[cell.row][cell.column].text
        }
    }

    @discardableResult
    func updateMaximumWidth(_ width: CGFloat) -> Bool {
        let width = max(160, width)
        let widths = layoutStrategy.columnWidths(
            for: table,
            font: baseFont,
            availableWidth: width
        )
        guard widths != columnWidths || maximumWidth != width else { return false }
        maximumWidth = width
        columnWidths = widths
        rowHeights = Self.rowHeights(for: table, widths: widths, baseFont: baseFont)
        renderedSize = NSSize(width: widths.reduce(0, +), height: rowHeights.reduce(0, +))
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
            var rowHeight = CGFloat(34)
            for (column, cell) in row.enumerated() where column < widths.count {
                let bounds = (cell.text as NSString).boundingRect(
                    with: NSSize(width: max(20, widths[column] - 16), height: 2_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                rowHeight = max(rowHeight, ceil(bounds.height) + 12)
            }
            return rowHeight
        }
    }

    private func layoutCells() {
        let xOffsets = columnWidths.reduce(into: [CGFloat(0)]) { result, width in
            result.append((result.last ?? 0) + width)
        }
        let yOffsets = rowHeights.reduce(into: [CGFloat(0)]) { result, height in
            result.append((result.last ?? 0) + height)
        }
        for cell in cells {
            guard cell.column + 1 < xOffsets.count, cell.row + 1 < yOffsets.count else { continue }
            cell.textView.frame = NSRect(
                x: xOffsets[cell.column] + 8,
                y: yOffsets[cell.row] + 6,
                width: max(1, columnWidths[cell.column] - 16),
                height: max(1, rowHeights[cell.row] - 12)
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var y = CGFloat(0)
        for (index, height) in rowHeights.enumerated() {
            let rowRect = NSRect(x: 0, y: y, width: renderedSize.width, height: height)
            let color = index == 0
                ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                : (index.isMultiple(of: 2)
                    ? NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
                    : NSColor.textBackgroundColor)
            color.setFill()
            rowRect.fill()
            y += height
        }
        NSColor.separatorColor.setStroke()
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
        y = 0
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

    func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let cell = cells.first(where: { $0.textView === textView }),
              textView.string != cell.originalText
        else { return }
        onEdit(.updateCell(row: cell.row, column: cell.column, text: textView.string))
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
        onEdit(.insertRow(at: contextCell.row))
    }

    @objc private func insertRowBelow(_ sender: Any?) {
        onEdit(.insertRow(at: contextCell.row + 1))
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
        setHoveredLinkRange(link(at: event)?.range)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredLinkRange(nil)
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if linkActivation == .singleClick, let target = linkTarget(at: event) {
            onLinkClick?(target)
            return
        }
        super.mouseDown(with: event)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let hoveredLinkRange, let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: hoveredLinkRange,
            actualCharacterRange: nil
        )
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            .insetBy(dx: -3, dy: -1)
        guard glyphRect.intersects(rect) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: glyphRect, xRadius: 4, yRadius: 4).fill()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event) ?? super.menu(for: event)
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
        hoveredLinkRange = range
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
        linkActivation: LinkActivationPreference = .singleClick
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
            parent.session.updateBoundText = { updatedText in
                if !UTF8Text.isExactlyEqual(textBinding.wrappedValue, updatedText) {
                    textBinding.wrappedValue = updatedText
                }
            }
            textView.delegate = self
            textView.isEditable = parent.isEditable
            textView.isSelectable = true
            textView.pasteImageHandler = parent.onPasteImage
            textView.dropImageHandler = parent.onDropImage
            textView.didAttachToWindow = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.parent.session.applyPendingRestorationIfPossible()
                self.applyPendingSelection(to: textView)
            }

            let textChanged = !UTF8Text.isExactlyEqual(textView.string, parent.text)
            if textChanged {
                let selection = textView.selectedRange()
                textView.string = parent.text
                let utf16Length = (parent.text as NSString).length
                let location = min(selection.location, utf16Length)
                let length = min(selection.length, utf16Length - location)
                textView.setSelectedRange(NSRange(location: location, length: length))
            }
            parent.session.applySourceAppearance(parent.appearance, force: textChanged)
            parent.session.setPresentation(
                parent.presentation,
                source: parent.text,
                onLinkClick: parent.onLinkClick,
                resourceContext: parent.renderedResourceContext,
                linkActivation: parent.linkActivation
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
