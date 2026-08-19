import AppKit
import SwiftUI

struct SourceSelectionRequest: Equatable {
    let generation: Int
    let utf8Range: Range<Int>
}

struct SourceNavigationTarget: Equatable {
    let revealRange: NSRange
    let caretRange: NSRange
}

enum MarkdownSourceRange {
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
        textView.usesFindBar = true
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
}

struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let selectionRequest: SourceSelectionRequest?
    let session: MarkdownSourceEditorSession

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
                if textBinding.wrappedValue != updatedText {
                    textBinding.wrappedValue = updatedText
                }
            }
            textView.delegate = self
            textView.didAttachToWindow = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyPendingSelection(to: textView)
            }

            if textView.string != parent.text {
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
            textView.setSelectedRange(target.caretRange)
            textView.scrollRangeToVisible(target.revealRange)
            textView.showFindIndicator(for: target.revealRange)
            completeFocus(for: request, textView: textView)
        }

        private func applyPendingSelection(to textView: NSTextView) {
            guard let request = parent.session.pendingSelectionRequest else { return }
            apply(request, to: textView)
        }

        private func completeFocus(
            for request: SourceSelectionRequest,
            textView: NSTextView
        ) {
            guard let window = textView.window,
                  window.makeFirstResponder(textView)
            else {
                return
            }

            parent.session.appliedSelectionGeneration = request.generation
            parent.session.pendingSelectionRequest = nil
        }
    }
}
