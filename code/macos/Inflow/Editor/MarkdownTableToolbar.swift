import AppKit

/// Presentation only: all commands are applied by the session's source transaction pipeline.
@MainActor
final class MarkdownTableToolbar: NSView, NSPopoverDelegate {
    var onEdit: ((RenderedMarkdownTableEdit) -> Void)?
    var onInteractionChange: (() -> Void)?
    var hasActivePopover: Bool { sizePopover?.isShown == true }
    var onAlignment: ((RenderedMarkdownTableAlignment) -> Void)?
    private let sizeButton = NSButton(title: "", target: nil, action: nil)
    private let alignmentControl = NSSegmentedControl()
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private var rows = 1
    private var columns = 1
    private var sizePopover: NSPopover?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        sizeButton.bezelStyle = .recessed
        sizeButton.font = .systemFont(ofSize: 12)
        sizeButton.target = self
        sizeButton.action = #selector(showSizeEditor(_:))
        sizeButton.toolTip = "调整表格行数和列数"
        sizeButton.setAccessibilityLabel("调整表格尺寸")
        alignmentControl.segmentCount = 3
        alignmentControl.trackingMode = .selectOne
        alignmentControl.segmentStyle = .smallSquare
        alignmentControl.target = self
        alignmentControl.action = #selector(changeAlignment(_:))
        for (index, item) in [("text.alignleft", "左对齐"), ("text.aligncenter", "居中对齐"), ("text.alignright", "右对齐")].enumerated() {
            alignmentControl.setImage(NSImage(systemSymbolName: item.0, accessibilityDescription: item.1), forSegment: index)
            alignmentControl.setToolTip(item.1, forSegment: index)
            alignmentControl.setWidth(28, forSegment: index)
        }
        alignmentControl.setAccessibilityLabel("当前列对齐方式")
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除表格")
        deleteButton.bezelStyle = .recessed
        deleteButton.target = self
        deleteButton.action = #selector(deleteTable(_:))
        deleteButton.toolTip = "删除表格"
        deleteButton.setAccessibilityLabel("删除表格")
        [sizeButton, alignmentControl, deleteButton].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { nil }

    func configure(rows: Int, columns: Int, alignment: RenderedMarkdownTableAlignment) {
        self.rows = rows
        self.columns = columns
        sizeButton.title = "\(rows) × \(columns)"
        sizeButton.setAccessibilityValue("\(rows) 行，\(columns) 列")
        alignmentControl.selectedSegment = [.leading, .center, .trailing].firstIndex(of: alignment) ?? 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        sizeButton.frame = NSRect(x: 0, y: 2, width: 72, height: 24)
        alignmentControl.isHidden = bounds.width < 202
        alignmentControl.frame = NSRect(x: 78, y: 3, width: 90, height: 22)
        deleteButton.isHidden = bounds.width < 106
        deleteButton.frame = NSRect(x: bounds.width - 28, y: 2, width: 28, height: 24)
    }

    @objc private func changeAlignment(_ sender: NSSegmentedControl) {
        let values: [RenderedMarkdownTableAlignment] = [.leading, .center, .trailing]
        guard values.indices.contains(sender.selectedSegment) else { return }
        onAlignment?(values[sender.selectedSegment])
    }

    @objc private func deleteTable(_ sender: Any?) { onEdit?(.deleteTable) }

    @objc private func showSizeEditor(_ sender: Any?) {
        let controller = MarkdownTableSizeController(rows: rows, columns: columns)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        controller.onApply = { [weak self, weak popover] rows, columns in
            popover?.close()
            self?.onEdit?(.resize(rows: rows, columns: columns))
        }
        sizePopover = popover
        popover.show(relativeTo: sizeButton.bounds, of: sizeButton, preferredEdge: .maxX)
        onInteractionChange?()
    }

    func popoverDidClose(_ notification: Notification) {
        onInteractionChange?()
    }
}

@MainActor
private final class MarkdownTableSizeController: NSViewController {
    var onApply: ((Int, Int) -> Void)?
    private let rowField = NSTextField()
    private let columnField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(rows: Int, columns: Int) {
        super.init(nibName: nil, bundle: nil)
        rowField.stringValue = String(rows)
        columnField.stringValue = String(columns)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for (label, field) in [("行数（含表头）", rowField), ("列数", columnField)] {
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let title = NSTextField(labelWithString: label)
            title.widthAnchor.constraint(equalToConstant: 110).isActive = true
            stack.addArrangedSubview(NSStackView(views: [title, field]))
        }
        let hint = NSTextField(wrappingLabelWithString: "缩小尺寸将移除超出范围的单元格，可撤销。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        let apply = NSButton(title: "应用", target: self, action: #selector(applySize(_:)))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        stack.addArrangedSubview(apply)
        stack.widthAnchor.constraint(equalToConstant: 250).isActive = true
        view = stack
    }

    @objc private func applySize(_ sender: Any?) {
        guard let rows = Int(rowField.stringValue), let columns = Int(columnField.stringValue),
              RenderedMarkdownTableEditing.isValidSize(rows: rows, columns: columns) else {
            errorLabel.stringValue = "行数 1–1000，列数 1–100，最多 10000 个单元格。"
            errorLabel.isHidden = false
            return
        }
        onApply?(rows, columns)
    }
}
