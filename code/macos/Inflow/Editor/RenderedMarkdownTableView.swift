import AppKit

@MainActor
final class RenderedMarkdownTableView: NSView, NSTextViewDelegate {
    private static let toolbarHeight: CGFloat = 28
    private let toolsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private final class CellLayout {
        let row: Int
        let column: Int
        let textView: RenderedMarkdownTableCellTextView
        var originalText: String
        var mathPreview: MarkdownTableMathPreview?

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

    private struct MathPreviewState: Equatable {
        let table: RenderedMarkdownTable
        let requests: [JavaScriptRenderRequest]
        let available: Set<String>
        let failures: Set<String>
        let widths: [CGFloat]
        let dark: Bool
    }
    private var mathPreviewState: MathPreviewState?

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
                MarkdownInlineProjection(cell.markdown).applyStyles(to: attributed, font: font)
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
        let previous = self.table
        needsContentMeasurement = needsContentMeasurement || self.table.rows.map { $0.map(\.text) } != table.rows.map { $0.map(\.text) }
        self.table = table
        self.onEdit = onEdit
        for cell in cells {
            cell.originalText = table.rows[cell.row][cell.column].text
            let model = table.rows[cell.row][cell.column]
            if previous.rows.indices.contains(cell.row), previous.rows[cell.row].indices.contains(cell.column),
               previous.rows[cell.row][cell.column].markdown != model.markdown {
                cell.mathPreview?.removeFromSuperview()
                cell.mathPreview = nil
            }
            if previous.rows.indices.contains(cell.row), previous.rows[cell.row].indices.contains(cell.column),
               previous.rows[cell.row][cell.column].markdown != model.markdown,
               !cell.textView.hasMarkedText(), let storage = cell.textView.textStorage, storage.string == model.text {
                let full = NSRange(location: 0, length: storage.length)
                storage.addAttribute(.font, value: cell.textView.caretFont, range: full)
                storage.removeAttribute(.strikethroughStyle, range: full)
                storage.removeAttribute(.backgroundColor, range: full)
                storage.removeAttribute(.link, range: full)
                storage.removeAttribute(.toolTip, range: full)
                storage.removeAttribute(.underlineColor, range: full)
                storage.removeAttribute(.underlineStyle, range: full)
                MarkdownInlineProjection(model.markdown).applyStyles(to: storage, font: cell.textView.caretFont)
                for link in model.links where NSMaxRange(link.visibleRange) <= storage.length {
                    storage.addAttributes(MarkdownLinkVisualStyle.restingAttributes(foregroundColor: currentPalette.accentColor)
                        .merging([.link: link.target]) { current, _ in current }, range: link.visibleRange)
                }
            }
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
        var heights = Self.rowHeights(for: table, widths: widths, baseFont: baseFont)
        for cell in cells {
            if let preview = cell.mathPreview {
                heights[cell.row] = max(heights[cell.row], preview.height(for: widths[cell.column]
                    - CGFloat(MarkdownRenderMetrics.tableCellHorizontalPadding * 2)) + CGFloat(MarkdownRenderMetrics.tableCellVerticalPadding * 2))
            }
        }
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

    @discardableResult
    func updateMathPreviews(requests: [JavaScriptRenderRequest], results: [String: JavaScriptRenderedOutput], failures: Set<String>) -> NSSize {
        let requests = requests.filter { NSIntersectionRange($0.sourceRange.utf16Range, table.sourceRange.utf16Range).length > 0 }
        guard !requests.isEmpty || cells.contains(where: { $0.mathPreview != nil }) else { return renderedSize }
        let state = MathPreviewState(table: table, requests: requests,
            available: Set(requests.compactMap { results[$0.cacheKey]?.svg == nil ? nil : $0.cacheKey }),
            failures: failures, widths: columnWidths,
            dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if mathPreviewState == state { updateMathPreviewVisibility(); return renderedSize }
        mathPreviewState = state
        let palette = MarkdownRenderPalette.resolved(for: effectiveAppearance)
        var heights = Self.rowHeights(for: table, widths: columnWidths, baseFont: baseFont)
        for cell in cells {
            cell.mathPreview?.removeFromSuperview()
            cell.mathPreview = nil
            let model = table.rows[cell.row][cell.column]
            let cellRequests = requests.filter { NSIntersectionRange($0.sourceRange.utf16Range, model.sourceRange.utf16Range).length > 0 }
            guard !cellRequests.isEmpty, let storage = cell.textView.textStorage else { continue }
            for request in requests where failures.contains(request.cacheKey) {
                let raw = request.sourceRange.utf16Range
                guard raw.location >= model.sourceRange.utf16Range.location,
                      NSMaxRange(raw) <= NSMaxRange(model.sourceRange.utf16Range) else { continue }
                let range = MarkdownInlineProjection(model.markdown).visibleRange(for:
                    NSRange(location: raw.location - model.sourceRange.utf16Range.location, length: raw.length))
                if NSMaxRange(range) <= storage.length {
                    storage.addAttributes([.toolTip: "公式渲染失败，请检查 TeX；表格外右键可重新渲染。",
                        .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.systemRed], range: range)
                }
            }
            guard let preview = MarkdownTableMathPreview(cell: model, attributedText: storage,
                requests: cellRequests, results: results, color: palette.textColor, font: cell.textView.caretFont,
                maximumWidth: columnWidths[cell.column] - CGFloat(MarkdownRenderMetrics.tableCellHorizontalPadding * 2)) else { continue }
            let row = cell.row, column = cell.column
            preview.drawsBackground = true
            preview.backgroundColor = backgroundColor(forRow: row)
            preview.activate = { [weak self, weak editor = cell.textView] location, event in
                guard let self, let editor, editor.isEditable else { return }
                if event.modifierFlags.contains(.shift), editor.selectionClickHandler?(true) == true { return }
                self.clearCellSelection()
                _ = self.focusCell(row: row, column: column, selection: NSRange(location: location, length: 0))
            }
            preview.openLink = { [weak self, weak editor = cell.textView] target, event in
                guard let self, let editor, RenderedMarkdownLinkActivation.shouldNavigate(for: event.modifierFlags,
                    preference: self.linkActivation, isEditing: editor.isEditable) else { return false }
                self.onLinkClick(target)
                return true
            }
            cell.mathPreview = preview
            addSubview(preview)
            let height = preview.height(for: columnWidths[cell.column] - CGFloat(MarkdownRenderMetrics.tableCellHorizontalPadding * 2))
            heights[cell.row] = max(heights[cell.row], height + CGFloat(MarkdownRenderMetrics.tableCellVerticalPadding * 2))
        }
        rowHeights = heights
        renderedSize.height = rowHeights.reduce(0, +) + Self.toolbarHeight
        setFrameSize(renderedSize)
        layoutCells()
        updateMathPreviewVisibility()
        return renderedSize
    }

    private func updateMathPreviewVisibility() {
        for cell in cells {
            let reading = window?.firstResponder !== cell.textView && selectionAnchor == nil
            cell.mathPreview?.isHidden = !reading
        }
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
            cell.mathPreview?.frame = cell.textView.frame
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
        updateMathPreviewVisibility()
        documentTextView?.selectionVisibilityHandler?()
        return true
    }

    private(set) var selectionAnchor: (Int, Int)?
    private(set) var selectionEnd: (Int, Int)?

    func clearCellSelection() {
        selectionAnchor = nil
        selectionEnd = nil
        for cell in cells { cell.textView.drawsBackground = false }
        updateMathPreviewVisibility()
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
        updateMathPreviewVisibility()
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
        updateMathPreviewVisibility()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textDidBeginEditing(notification)
        if let view = notification.object as? NSTextView, !view.hasMarkedText(),
           let cell = cells.first(where: { $0.textView === view }), view.string == cell.originalText,
           table.rows.indices.contains(cell.row), table.rows[cell.row].indices.contains(cell.column) {
            let model = table.rows[cell.row][cell.column]
            if let range = MarkdownInlineProjection(model.markdown).sourceRange(for: view.selectedRange()) {
                documentTextView?.setSelectedRange(NSRange(location: model.sourceRange.utf16Range.location + range.location, length: range.length))
            }
        }
        documentTextView?.selectionVisibilityHandler?()
    }

    private func insertRow(at row: Int, column: Int) {
        documentTextView?.pendingTableFocus = (table.sourceRange.utf16Range.location, row, column, nil)
        onEdit(.insertRow(at: row))
    }

    func textDidEndEditing(_ notification: Notification) {
        if let textView = notification.object as? NSTextView { commit(textView) }
        updateMathPreviewVisibility()
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
            let current = owner.currentWritingPlan().tables.first {
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

