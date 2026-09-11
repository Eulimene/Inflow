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
        case .blockQuote, .unorderedList, .orderedList, .taskList:
            true
        case .heading, .emphasis, .strong, .strikethrough, .inlineCode,
             .linkDelimiter, .linkDestination:
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
    private var renderedAppliedAppearance: SourceEditorAppearance?
    private var renderedLinkHandler: ((String) -> Void)?
    private var renderedResourceContext = RenderedMarkdownResourceContext.unavailable
    private var renderedImageGeneration = 0
    private var renderedImageTask: Task<Void, Never>?
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
        resourceContext: RenderedMarkdownResourceContext = .unavailable
    ) {
        let changed = self.presentation != presentation
        let resourceContextChanged = renderedResourceContext != resourceContext
        self.presentation = presentation
        renderedLinkHandler = onLinkClick
        renderedResourceContext = resourceContext
        switch presentation {
        case .source:
            cancelRenderedImageLoading()
            renderedPlan = nil
            textView.linkClickHandler = nil
            textView.clickableLinkRanges = []
            textView.clearRenderedImages()
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
                force: changed || resourceContextChanged
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
            self.applyRenderedPresentation(source: source, force: true)
        }
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
        textView.clickableLinkRanges = plan.links.map(\.textRange.utf16Range)
        textView.clearRenderedImages()
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
            guard NSMaxRange(range) <= storage.length else { continue }
            applyRenderedAttributes(
                for: style.kind,
                range: range,
                storage: storage,
                baseFont: baseFont
            )
        }
        for block in plan.localSourceBlocks {
            let range = block.sourceRange.utf16Range
            guard NSMaxRange(range) <= storage.length else { continue }
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
                storage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 0.1),
                        .foregroundColor: NSColor.clear,
                        .backgroundColor: NSColor.clear,
                        .underlineStyle: 0,
                        .strikethroughStyle: 0,
                        .obliqueness: 0,
                    ],
                    range: range
                )
            }
        }
        for image in plan.images {
            applyRenderedImage(
                nil,
                alternative: image.alternative,
                sourceRange: image.sourceRange.utf16Range,
                storage: storage
            )
        }
        storage.endEditing()
        renderedAppliedAppearance = sourceAppearance
        textView.setSelectedRange(selection)
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
        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: sourceRange)
        textView.setRenderedImage(
            displayedImage,
            alternative: alternative,
            sourceRange: sourceRange
        )
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
                    ofSize: max(13, font.pointSize - 1),
                    weight: .regular
                )
            }
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.quaternaryLabelColor.withAlphaComponent(0.2),
                range: range
            )
        case .blockQuote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
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
        }
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
final class WindowAwareTextView: NSTextView {
    private struct RenderedImageViewState {
        let sourceRange: NSRange
        let imageView: RenderedMarkdownImageView
    }

    private let persistentUndoManager = UndoManager()
    var didAttachToWindow: (() -> Void)?
    var textDidChangeHandler: ((String) -> Void)?
    var pasteImageHandler: ((ClipboardImagePayload) -> Void)?
    var dropImageHandler: ((URL) -> Void)?
    var linkClickHandler: ((Int) -> Bool)?
    var clickableLinkRanges: [NSRange] = [] {
        didSet {
            guard oldValue != clickableLinkRanges else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    private var renderedImageViews: [Int: RenderedImageViewState] = [:]
    private var renderedImageLayoutTask: Task<Void, Never>?

    override var undoManager: UndoManager? {
        persistentUndoManager
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        super.setFrameSize(newSize)
        if sizeChanged, !renderedImageViews.isEmpty {
            scheduleRenderedImageLayout()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            didAttachToWindow?()
        }
    }

    func clearRenderedImages() {
        renderedImageLayoutTask?.cancel()
        renderedImageLayoutTask = nil
        renderedImageViews.values.forEach { $0.imageView.removeFromSuperview() }
        renderedImageViews.removeAll()
    }

    func setRenderedImage(
        _ image: NSImage,
        alternative: String,
        sourceRange: NSRange
    ) {
        let key = sourceRange.location
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

    private func scheduleRenderedImageLayout() {
        renderedImageLayoutTask?.cancel()
        renderedImageLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.layoutRenderedImages()
        }
    }

    private func layoutRenderedImages() {
        guard let layoutManager, let textContainer else { return }
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
        if let location = clickableLinkLocation(at: localPoint),
           linkClickHandler?(location) == true
        {
            return
        }
        super.mouseDown(with: event)
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
        renderedResourceContext: RenderedMarkdownResourceContext = .unavailable
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
                resourceContext: parent.renderedResourceContext
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
