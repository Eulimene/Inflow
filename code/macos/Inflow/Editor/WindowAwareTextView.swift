import AppKit

@MainActor
final class WindowAwareTextView: DocumentFindTextView {
    private let centeredLineLayout = MarkdownCenteredLineLayout()

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        layoutManager?.delegate = centeredLineLayout
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        layoutManager?.delegate = centeredLineLayout
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layoutManager?.delegate = centeredLineLayout
    }


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
    var engineHistoryIsPending = false
    var sourceCaretFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    var engineUndoHandler: (() -> Void)?
    var engineRedoHandler: (() -> Void)?
    var didAttachToWindow: (() -> Void)?
    var focusDidChangeHandler: (() -> Void)?
    var effectiveAppearanceDidChangeHandler: (() -> Void)?
    var textDidChangeHandler: ((String) -> Void)?
    var compositionWillBeginHandler: (() -> Void)?
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
    var renderedTheme = PreviewTheme.standard { didSet { updateReadingColumn() } }
    private var findRanges: [NSRange] = []
    private var currentFindRange: NSRange?

    func setFindHighlights(_ ranges: [NSRange], current: NSRange?) {
        findRanges = ranges
        currentFindRange = current
        refreshFindHighlights()
    }

    func refreshFindHighlights() {
        MarkdownFindHighlight.apply(to: self, ranges: findRanges, current: currentFindRange)
        for state in renderedTableViews.values {
            state.tableView.setFindHighlights(findRanges, current: currentFindRange)
        }
    }

    var renderedTableAvailableWidth: CGFloat {
        let viewport = enclosingScrollView?.contentSize.width ?? bounds.width
        return max(160, min(readingColumnWidth, viewport - textContainerInset.width * 2
            - (textContainer?.lineFragmentPadding ?? 0) * 2))
    }

    var readingColumnWidth = CGFloat(MarkdownRenderMetrics.previewReadingWidth) { didSet { updateReadingColumn() } }
    var structuralEditDidApply: (() -> Void)?
    var selectionVisibilityHandler: (() -> Void)?
    var retryRenderingHandler: (() -> Void)?
    var markdownAutoPairEnabled = true
    var writingPlan: RenderedMarkdownPlan?
    var layoutPlanProvider: ((String) -> RenderedMarkdownPlan?)?

    func currentWritingPlan() -> RenderedMarkdownPlan {
        if let writingPlan, writingPlan.exactlyMatches(string) { return writingPlan }
        return layoutPlanProvider?(string) ?? RenderedMarkdownEditor.plan(for: string)
    }
    private var insertedCloser: (location: Int, text: String)?
    var renderedAnchorSourceRanges: [NSRange] = []
    var renderedCollapsedSourceRanges: [NSRange] = []
    var renderedReplacementBaseFont = NSFont.systemFont(ofSize: 15)
    private var renderedImageViews: [Int: RenderedImageViewState] = [:]
    private var renderedTableViews: [Int: RenderedTableViewState] = [:]
    var pendingTableFocus: (location: Int, row: Int, column: Int, selection: NSRange?)?
    var sourceSelectionHandler: ((NSRange) -> Void)?

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        sourceSelectionHandler?(charRange)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        updateRenderedSelection()
    }

    private func updateRenderedSelection(isFocused: Bool? = nil) {
        let focused = isFocused ?? (window == nil || window?.firstResponder === self)
        let ranges = focused ? selectedRanges.map(\.rangeValue).filter { $0.length > 0 } : []
        for state in renderedTableViews.values {
            state.tableView.isDocumentSelected = ranges.contains { NSIntersectionRange($0, state.sourceRange).length > 0 }
        }
        for state in renderedImageViews.values {
            state.imageView.isDocumentSelected = ranges.contains { NSIntersectionRange($0, state.sourceRange).length > 0 }
        }
        needsDisplay = true
    }
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
        let metricsFont = isLiveMarkdown
            ? (NSFont(descriptor: renderedReplacementBaseFont.fontDescriptor, size: visibleFont.pointSize)
                ?? renderedReplacementBaseFont)
            : sourceCaretFont
        return RenderedMarkdownCaretStyleResolver.insertionRect(rect, in: self, font: metricsFont)
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
        let themeInset = renderedTheme.styles.length("padding-left") ?? renderedTheme.styles.length("padding-right")
            ?? MarkdownRenderMetrics.renderedHorizontalInset
        let inset = isLiveMarkdown ? max(min(120, max(8, themeInset)),
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
        if becameFirstResponder {
            updateRenderedSelection(isFocused: true)
            focusDidChangeHandler?()
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            updateRenderedSelection(isFocused: false)
            focusDidChangeHandler?()
        }
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
        updateRenderedSelection()
        scheduleRenderedImageLayout()
    }

    @discardableResult
    func setRenderedImage(
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
        imageView.renderedTheme = renderedTheme
        imageView.presentsDiagram = alternative == "Mermaid 图表"
        imageView.setFrameSize(renderedSize)
        imageView.setAccessibilityLabel(alternative.isEmpty ? "图片" : alternative)
        updateRenderedSelection()
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
                existing.tableView.applyTheme(renderedTheme)
                existing.tableView.applyPalette(
                    MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme)
                )
                existing.tableView.applyFont(baseFont)
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
            reusable.value.tableView.applyTheme(renderedTheme)
            reusable.value.tableView.applyPalette(
                MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme)
            )
            reusable.value.tableView.applyFont(baseFont)
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
            palette: MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme),
            onLinkClick: onLinkClick,
            onEdit: onEdit
        )
        tableView.applyTheme(renderedTheme)
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

    func prepareRenderedLayoutForPrinting() {
        // Export has no window/run-loop layout pass to finish deferred overlays.
        layoutRenderedImages()
    }

    func layoutRenderedImages() {
        defer { refreshFindHighlights() }
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
                state.tableView.updateMaximumWidth(renderedTableAvailableWidth)
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
                x: min(textContainerOrigin.x + glyphRect.minX,
                    max(0, (viewportWidth - state.tableView.renderedSize.width) / 2)),
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
           renderedTableViews[pending.location]?.tableView.focusCell(row: pending.row, column: pending.column, selection: pending.selection) == true {
            pendingTableFocus = nil
        }
    }

    static func lastVisibleCharacterLocation(
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
        let palette = MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme)
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
                    baselineOffset: layoutManager.location(forGlyphAt: segment.location).y,
                    horizontalPadding: self.renderedTheme.styles.length("padding-left", on: "code") ?? 0,
                    verticalPadding: self.renderedTheme.styles.length("padding-top", on: "code") ?? 0
                )
                guard background.intersects(rect) else { return }
                NSBezierPath(
                    roundedRect: background,
                    xRadius: max(0, self.renderedTheme.styles.length("border-radius", on: "code") ?? 0),
                    yRadius: max(0, self.renderedTheme.styles.length("border-radius", on: "code") ?? 0)
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
            backgroundRect = backgroundRect.insetBy(dx: 0, dy: -renderedTheme.styles.token("code-block-outset"))
            guard backgroundRect.intersects(rect) else { continue }
            palette.subtleSurfaceColor.setFill()
            let css = renderedTheme.styles
            (css.value("border-color", on: "pre").flatMap(NativeCSSStyles.color) ?? palette.borderColor).setStroke()
            let radius = max(0, min(24, css.length("border-radius", on: "pre") ?? MarkdownRenderMetrics.blockCornerRadius))
            let path = NSBezierPath(roundedRect: backgroundRect, xRadius: radius, yRadius: radius)
            path.fill()
            path.lineWidth = max(0, min(8, css.length("border-width", on: "pre") ?? 1))
            if path.lineWidth > 0 { path.stroke() }
        }
        for characterRange in renderedHeadingDividerRanges where characterRange.length > 0 {
            guard let heading = writingPlan?.contentStyles.first(where: { style in
                if case .heading = style.kind { return NSIntersectionRange(style.sourceRange.utf16Range, characterRange).length > 0 }
                return false
            }), case .heading(let level) = heading.kind else { continue }
            let css = renderedTheme.styles
            let thickness = css.headingDividerWidth(level: level)
            guard thickness > 0 else { continue }
            ((css.value("--md-divider-color", on: "h\(level)") ?? css.value("border-bottom-color", on: "h\(level)")).flatMap(NativeCSSStyles.color) ?? palette.borderColor).setFill()
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let lastGlyph = min(
                layoutManager.numberOfGlyphs - 1,
                NSMaxRange(glyphRange) - 1
            )
            let lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: lastGlyph,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let startX = textContainerOrigin.x + textContainer.lineFragmentPadding
            let availableWidth = max(1, textContainer.size.width - textContainer.lineFragmentPadding * 2)
            let width = min(availableWidth, max(1, css.length("--md-divider-width", on: "h\(level)") ?? availableWidth))
            let divider = NSRect(x: startX + (availableWidth - width) / 2,
                y: textContainerOrigin.y + lineRect.maxY - thickness, width: width, height: thickness)
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
            if !blockBar.isNull {
                blockBar.origin.x += max(0, min(120, renderedTheme.styles.length("margin-left", on: "blockquote",
                    relativeTo: renderedReplacementBaseFont.pointSize) ?? 0))
                blockBar.size.width = max(0, min(12, renderedTheme.styles.length("border-left-width", on: "blockquote") ?? blockBar.width))
            }
            if !blockBar.isNull, blockBar.width > 0, blockBar.intersects(rect) {
                NSBezierPath(
                    roundedRect: blockBar,
                    xRadius: renderedTheme.styles.token("quote-radius"),
                    yRadius: renderedTheme.styles.token("quote-radius")
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
            path.lineWidth = max(0, min(8, renderedTheme.styles.length("border-width", on: "hr") ?? 0))
            guard path.lineWidth > 0 else { continue }
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
        let palette = MarkdownRenderPalette.resolved(for: effectiveAppearance, theme: renderedTheme)
        for marker in renderedReplacementMarkers {
            let range = marker.sourceRange.utf16Range
            guard let text = marker.displayText(styles: renderedTheme.styles),
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
                    ? palette.accentColor
                    : palette.textColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let point = NSPoint(
                x: textContainerOrigin.x + glyphRect.minX,
                y: textContainerOrigin.y + RenderedMarkdownMarkerTypography.originY(
                    for: marker.kind,
                    font: font,
                    baseFont: renderedReplacementBaseFont,
                    lineRect: lineRect,
                    baselineOffset: contentLocation < NSMaxRange(lineCharacterRange)
                        ? layoutManager.location(forGlyphAt: baselineGlyph).y : nil
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
        if compositionBaseline == nil {
            compositionBaseline = self.string
            compositionWillBeginHandler?()
        }
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
        if isLiveMarkdown, !hasActiveComposition,
           MarkdownEditingTransaction.mayHandleBackwardDelete(source: string, selection: selectedRange()),
           canUseWritingRules {
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
        if performEditingIntent(.paragraphBreak) { return }
        breakEngineTypingGroup()
        super.insertNewline(sender)
        normalizeInsertedLine()
    }

    override func insertLineBreak(_ sender: Any?) {
        if performEditingIntent(.lineBreak) { return }
        super.insertLineBreak(sender)
    }

    override func keyDown(with event: NSEvent) {
        // AppKit may map Shift-Return to insertNewline:, so resolve the live
        // editor's soft-break shortcut before the system key-binding layer.
        // Composition must keep receiving the original event to accept IME text.
        if isLiveMarkdown, isEditable, !hasActiveComposition,
           event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.shift],
           event.keyCode == 36 || event.keyCode == 76 {
            insertLineBreak(nil)
            return
        }
        if isLiveMarkdown, !hasActiveComposition,
           event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.shift, .command] {
            if event.charactersIgnoringModifiers?.lowercased() == "v" { pasteAsPlainText(nil); return }
            if event.charactersIgnoringModifiers?.lowercased() == "c" { copyAsMarkdown(nil); return }
        }
        if isLiveMarkdown, !hasActiveComposition,
           event.modifierFlags.intersection([.shift, .command, .option, .control]) == [.command],
           event.keyCode == 36 || event.keyCode == 76 {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }

    func exitRenderedTable(at location: Int) {
        guard let edit = MarkdownEditingTransaction.exitTable(source: string, at: location) else { return }
        _ = applyWritingEdit(edit, updatesParagraphLayout: true)
    }

    @discardableResult
    private func performEditingIntent(_ intent: MarkdownEditingIntent) -> Bool {
        guard isLiveMarkdown, isEditable, !hasActiveComposition else { return false }
        let plan = currentWritingPlan()
        guard let edit = MarkdownEditingTransaction.plan(intent, source: string, selection: selectedRange(), renderPlan: plan) else { return false }
        return applyWritingEdit(edit, updatesParagraphLayout: true)
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
        let plan = currentWritingPlan()
        let selection = location.map { NSRange(location: $0, length: 0) } ?? selectedRange()
        return plan.renderRequests.first {
            $0.kind != "math" && selection.location >= $0.contentRange.utf16Range.location
                && NSMaxRange(selection) <= NSMaxRange($0.contentRange.utf16Range)
                && selection.location < NSMaxRange($0.contentRange.utf16Range)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isLiveMarkdown, isEditable, !hasMarkedText(),
              let request = currentWritingPlan().renderRequests.first(where: {
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
        let plan = currentWritingPlan()
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
    private func applyWritingEdit(_ edit: MarkdownWritingEdit, updatesParagraphLayout: Bool = false) -> Bool {
        guard NSMaxRange(edit.range) <= string.utf16.count,
              shouldChangeText(in: edit.range, replacementString: edit.text), let storage = textStorage else { return false }
        breakEngineTypingGroup()
        insertedCloser = nil
        storage.replaceCharacters(in: edit.range, with: edit.text)
        setSelectedRange(edit.selection)
        if updatesParagraphLayout { structuralEditDidApply?() }
        didChangeText()
        scrollRangeToVisible(edit.selection)
        return true
    }

    func restoreTableFocus(for range: NSRange) {
        for table in currentWritingPlan().tables {
            for (row, cells) in table.rows.enumerated() {
                for (column, cell) in cells.enumerated() {
                    let raw = cell.sourceRange.utf16Range
                    guard range.location >= raw.location, NSMaxRange(range) <= NSMaxRange(raw) else { continue }
                    let visible = MarkdownInlineProjection(cell.markdown).visibleRange(
                        for: NSRange(location: range.location - raw.location, length: range.length))
                    pendingTableFocus = (table.sourceRange.utf16Range.location, row, column, visible)
                    return
                }
            }
        }
        pendingTableFocus = nil
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    func replaceRenderedTableSource(_ replacement: String, range: NSRange, selection: NSRange) {
        guard isEditable, !hasMarkedText(), let storage = textStorage,
              NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: replacement) else { return }
        breakEngineTypingGroup()
        let original = (string as NSString).substring(with: range)
        guard let diff = EditorEngineTextDiff.replacement(from: original, to: replacement),
              let target = MarkdownSourceRange.navigationTarget(forUTF8Range: diff.start..<diff.end, in: original) else { return }
        storage.replaceCharacters(in: NSRange(location: range.location + target.revealRange.location, length: target.revealRange.length), with: diff.inserted)
        setSelectedRange(selection)
        didChangeText()
    }

    private func handleWritingAction(_ action: MarkdownWritingAction) -> Bool {
        if canUseWritingRules, action == .indent || action == .outdent,
           let edit = MarkdownEditingTransaction.indentList(source: string, selection: selectedRange(), backwards: action == .outdent) {
            return applyWritingEdit(edit)
        }
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

    private func normalizeExtendedSelection() {
        guard isLiveMarkdown, !hasActiveComposition, selectedRange().length > 0 else { return }
        var range = selectedRange()
        for marker in renderedCollapsedSourceRanges where NSIntersectionRange(range, marker).length > 0 {
            range = NSUnionRange(range, marker)
        }
        if range != selectedRange(), NSMaxRange(range) <= string.utf16.count { setSelectedRange(range) }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        super.moveLeftAndModifySelection(sender)
        normalizeExtendedSelection()
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        super.moveRightAndModifySelection(sender)
        normalizeExtendedSelection()
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        super.moveUpAndModifySelection(sender)
        normalizeExtendedSelection()
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        super.moveDownAndModifySelection(sender)
        normalizeExtendedSelection()
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        for view in subviews where !view.isHidden && (view is RenderedMarkdownTableView || view is NSImageView) {
            if !children.contains(where: { ($0 as? NSView) === view }) { children.append(view) }
        }
        return children
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
        if isLiveMarkdown, isEditable, !hasActiveComposition {
            let board = NSPasteboard.general
            if let markdown = board.string(forType: Self.markdownClipboardType) {
                pasteMarkdown(markdown)
                return
            }
            if let html = board.string(forType: .html), let markdown = MarkdownClipboardCodec.markdown(fromHTML: html), !markdown.isEmpty {
                pasteMarkdown(markdown)
                return
            }
        }
        if consumeImagePaste(from: .general) { return }
        breakEngineTypingGroup()
        suppressesAutomaticEngineGrouping = true
        defer { suppressesAutomaticEngineGrouping = false }
        super.paste(sender)
    }

    private static let markdownClipboardType = NSPasteboard.PasteboardType("com.inflow.markdown")

    override func copy(_ sender: Any?) {
        guard isLiveMarkdown, selectedRange().length > 0 else { super.copy(sender); return }
        normalizeExtendedSelection()
        let source = (string as NSString).substring(with: selectedRange())
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(source, forType: .string)
        board.setString(source, forType: Self.markdownClipboardType)
        if let html = try? MarkdownRenderer.htmlFragment(for: source) { board.setString(html, forType: .html) }
    }

    override func cut(_ sender: Any?) {
        guard isLiveMarkdown, isEditable, !hasActiveComposition, selectedRange().length > 0 else { super.cut(sender); return }
        normalizeExtendedSelection()
        copy(sender)
        _ = applyWritingEdit(MarkdownWritingEdit(range: selectedRange(), text: "",
            selection: NSRange(location: selectedRange().location, length: 0)))
    }

    @objc func copyAsMarkdown(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        normalizeExtendedSelection()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard isLiveMarkdown, isEditable, !hasActiveComposition, let value = NSPasteboard.general.string(forType: .string)
        else { super.pasteAsPlainText(sender); return }
        pasteMarkdown(value)
    }

    private func pasteMarkdown(_ value: String) {
        _ = applyWritingEdit(MarkdownWritingEdit(range: selectedRange(), text: value,
            selection: NSRange(location: selectedRange().location + value.utf16.count, length: 0)))
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
        normalizeExtendedSelection()
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
            let copy = NSMenuItem(title: "复制代码内容", action: #selector(copyCodeContent(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = request
            menu.addItem(copy)
            let finish = NSMenuItem(title: "完成编辑", action: #selector(cancelOperation(_:)), keyEquivalent: "")
            finish.target = self
            menu.addItem(finish)
            addRenderRetry(to: menu)
            return menu
        }
        guard let location = clickableLinkLocation(at: localPoint) else {
            let menu = super.menu(for: event) ?? NSMenu()
            if isLiveMarkdown {
                let copy = NSMenuItem(title: "复制 Markdown", action: #selector(copyAsMarkdown(_:)), keyEquivalent: "")
                copy.target = self
                menu.addItem(copy)
                let paste = NSMenuItem(title: "粘贴纯文本", action: #selector(pasteAsPlainText(_:)), keyEquivalent: "")
                paste.target = self
                menu.addItem(paste)
                addRenderRetry(to: menu)
            }
            return menu
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

    private func addRenderRetry(to menu: NSMenu) {
        let retry = NSMenuItem(title: "重新渲染图表与公式", action: #selector(retryResources(_:)), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
    }

    @objc private func retryResources(_ sender: Any?) { retryRenderingHandler?() }

    @objc private func copyCodeContent(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? JavaScriptRenderRequest,
              let current = currentWritingPlan().renderRequests.first(where: {
                  $0.sourceRange == old.sourceRange && $0.source == old.source
              }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.source, forType: .string)
    }

    @objc private func editCodeLanguage(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? JavaScriptRenderRequest,
              let request = currentWritingPlan().renderRequests.first(where: {
                  $0.kind != "math" && $0.sourceRange == old.sourceRange && $0.source == old.source
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
            usesEngineHistory ? (engineCanUndo || engineHistoryIsPending) : persistentUndoManager.canUndo
        case #selector(redo(_:)):
            usesEngineHistory ? (engineCanRedo || engineHistoryIsPending) : persistentUndoManager.canRedo
        default:
            super.validateUserInterfaceItem(item)
        }
    }
}
