import AppKit
import SwiftUI

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
    fileprivate var appliedSelectionGeneration: Int?
    fileprivate var pendingSelectionRequest: SourceSelectionRequest?
    fileprivate var updateBoundText: ((String) -> Void)?

    override init() {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

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

        scrollView.documentView = textView
        self.scrollView = scrollView
        self.textView = textView
        super.init()
        textView.textDidChangeHandler = { [weak self] text in
            self?.updateBoundText?(text)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerChangedText),
            name: .NSUndoManagerDidUndoChange,
            object: textView.undoManager
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(undoManagerChangedText),
            name: .NSUndoManagerDidRedoChange,
            object: textView.undoManager
        )
    }

    @objc
    private func undoManagerChangedText(_ notification: Notification) {
        updateBoundText?(textView.string)
    }

    @discardableResult
    func focusEditor() -> Bool {
        guard let window = textView.window else { return false }
        return window.makeFirstResponder(textView)
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
        textView.scrollRangeToVisible(finalSelection.revealRange)
        textView.undoManager?.setActionName(actionName)
        return true
    }
}

@MainActor
final class WindowAwareTextView: NSTextView {
    private let persistentUndoManager = UndoManager()
    var didAttachToWindow: (() -> Void)?
    var textDidChangeHandler: ((String) -> Void)?

    override var undoManager: UndoManager? {
        persistentUndoManager
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            didAttachToWindow?()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        textDidChangeHandler?(string)
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

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let selectionRequest: SourceSelectionRequest?
    let session: MarkdownSourceEditorSession
    let isEditable: Bool

    init(
        text: Binding<String>,
        selectionRequest: SourceSelectionRequest?,
        session: MarkdownSourceEditorSession,
        isEditable: Bool = true
    ) {
        _text = text
        self.selectionRequest = selectionRequest
        self.session = session
        self.isEditable = isEditable
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
            textView.didAttachToWindow = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyPendingSelection(to: textView)
            }

            if !UTF8Text.isExactlyEqual(textView.string, parent.text) {
                let selection = textView.selectedRange()
                textView.string = parent.text
                let utf16Length = (parent.text as NSString).length
                let location = min(selection.location, utf16Length)
                let length = min(selection.length, utf16Length - location)
                textView.setSelectedRange(NSRange(location: location, length: length))
            }

            apply(parent.selectionRequest, to: textView)
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
            textView.showFindIndicator(for: target.revealRange)
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
