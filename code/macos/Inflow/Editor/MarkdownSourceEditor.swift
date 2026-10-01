import SwiftUI
import AppKit

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
            // Focus, theme and link callbacks belong to the persistent session.
            // Unmounting this adapter must not disconnect the next mounted view.
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
                ? (parent.renderedColorScheme.nativeAppearance
                    ?? (parent.renderedTheme.styles.value("color-scheme") == "dark" ? NSAppearance(named: .darkAqua)
                        : parent.renderedTheme.styles.value("color-scheme") == "light" ? NSAppearance(named: .aqua) : nil))
                : nil
            textView.pasteImageHandler = parent.onPasteImage
            textView.dropImageHandler = parent.onDropImage
            textView.didAttachToWindow = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.parent.session.applyPendingRestorationIfPossible()
                self.parent.session.selectionController.applyPendingSelection(to: textView)
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
            parent.session.selectionController.apply(parent.selectionRequest, to: textView)
            parent.session.textView.refreshFindHighlights()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.session.updateSelectedRange(textView.selectedRange())
        }
    }
}

/// Selection requests outlive individual SwiftUI adapter instances.
@MainActor
final class MarkdownSelectionController {
    private var appliedGeneration: Int?
    private var pendingRequest: SourceSelectionRequest?

    func apply(_ request: SourceSelectionRequest?, to textView: NSTextView) {
        guard let request else {
            pendingRequest = nil
            return
        }
        guard request.generation != appliedGeneration,
              let target = MarkdownSourceRange.navigationTarget(
                  forUTF8Range: request.utf8Range,
                  in: textView.string
              )
        else {
            return
        }

        pendingRequest = request
        textView.setSelectedRange(
            request.style == .caret ? target.caretRange : target.revealRange
        )
        textView.scrollRangeToVisible(target.revealRange)
        if let layout = textView.layoutManager, let container = textView.textContainer,
           let scroll = textView.enclosingScrollView {
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: target.revealRange, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let clip = scroll.contentView
            let margin = request.style == .caret ? CGFloat(32) : clip.bounds.height * 0.3
            let y = min(max(0, textView.bounds.height - clip.bounds.height), max(0, rect.minY - margin))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        if request.style.showsTransientMatchIndicator {
            textView.showFindIndicator(for: target.revealRange)
        }
        completeApplication(for: request, textView: textView)
    }

    func applyPendingSelection(to textView: NSTextView) {
        guard let request = pendingRequest else { return }
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

        appliedGeneration = request.generation
        pendingRequest = nil
    }
}

/// Temporary layout attributes never become part of the document or undo history.
@MainActor
enum MarkdownFindHighlight {
    static func apply(to view: NSTextView, ranges: [NSRange], current: NSRange?) {
        guard let layout = view.layoutManager else { return }
        let full = NSRange(location: 0, length: view.string.utf16.count)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        for range in ranges where range.length > 0 && NSMaxRange(range) <= full.length {
            layout.addTemporaryAttribute(.backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.28), forCharacterRange: range)
        }
        if let current, current.length > 0, NSMaxRange(current) <= full.length {
            layout.addTemporaryAttributes([
                .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.55),
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: NSColor.labelColor,
            ], forCharacterRange: current)
        }
        view.needsDisplay = true
    }
}
