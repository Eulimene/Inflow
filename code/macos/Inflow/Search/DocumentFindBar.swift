import AppKit
import SwiftUI

enum SearchRefreshPosition {
    case first
    case preserve
    case atOrAfter(Int)
    case afterReplacement(Range<Int>)
}

enum DocumentFindPlanError: Error, LocalizedError {
    case resultsOutdated

    var errorDescription: String? {
        "查找结果正在更新，请稍后重新确认。"
    }
}

@MainActor
final class DocumentFindSession: ObservableObject {
    @Published var isPresented = false
    @Published var showsReplacement = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var isCaseSensitive = false
    @Published private(set) var matches: [DocumentSearchMatch] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var focusGeneration = 0
    @Published private(set) var isSearching = false

    private(set) var sourceSnapshot = ""
    private var resultQuery = ""
    private var resultCaseSensitive = false
    private var matchedTextCounts: [Data: Int] = [:]

    var currentMatch: DocumentSearchMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var statusText: String {
        if isSearching {
            return "正在查找…"
        }
        if let errorMessage {
            return errorMessage
        }
        if query.isEmpty {
            return "输入查找内容"
        }
        guard !matches.isEmpty else {
            return "0 个匹配"
        }
        guard let currentIndex else {
            return "\(matches.count) 个匹配"
        }
        return "\(currentIndex + 1) / \(matches.count)"
    }

    var canNavigate: Bool {
        !isSearching && !matches.isEmpty
    }

    var canReplaceCurrent: Bool {
        guard !isSearching, let currentMatch else { return false }
        return currentMatch.matchedUTF8 != replacementUTF8
    }

    var hasReplacementChanges: Bool {
        !isSearching
            && matches.count > (matchedTextCounts[replacementUTF8] ?? 0)
    }

    func present(replacing: Bool) {
        isPresented = true
        if replacing {
            showsReplacement = true
        }
        focusGeneration &+= 1
    }

    func dismiss() {
        isPresented = false
        notice = nil
    }

    func clearNotice() {
        notice = nil
    }

    func showNotice(_ message: String) {
        notice = message
    }

    func resultsAreCurrent(for source: String) -> Bool {
        !isSearching
            && errorMessage == nil
            && UTF8Text.isExactlyEqual(sourceSnapshot, source)
            && UTF8Text.isExactlyEqual(resultQuery, query)
            && resultCaseSensitive == isCaseSensitive
    }

    func beginSearch() {
        isSearching = true
        errorMessage = nil
    }

    func cancelSearch() {
        isSearching = false
    }

    func applySearch(
        _ result: DocumentSearchResult,
        source: String,
        query: String,
        caseSensitive: Bool,
        position: SearchRefreshPosition
    ) {
        let previousRange = currentMatch?.utf8Range
        sourceSnapshot = source
        resultQuery = query
        resultCaseSensitive = caseSensitive
        matches = result.matches
        matchedTextCounts = result.matchedTextCounts
        errorMessage = nil
        isSearching = false
        currentIndex = resolvedIndex(
            in: result.matches,
            position: position,
            previousRange: previousRange
        )
    }

    func failSearch(
        message: String,
        source: String,
        query: String,
        caseSensitive: Bool
    ) {
        sourceSnapshot = source
        resultQuery = query
        resultCaseSensitive = caseSensitive
        matches = []
        matchedTextCounts = [:]
        currentIndex = nil
        errorMessage = message
        isSearching = false
    }

    func refresh(
        source: String,
        position: SearchRefreshPosition = .preserve
    ) {
        beginSearch()
        do {
            let result = try MarkdownSearcher.searchResult(
                in: source,
                query: query,
                caseSensitive: isCaseSensitive
            )
            applySearch(
                result,
                source: source,
                query: query,
                caseSensitive: isCaseSensitive,
                position: position,
            )
        } catch {
            failSearch(
                message: (error as? LocalizedError)?.errorDescription
                    ?? MarkdownSearchError.coreFailure.localizedDescription,
                source: source,
                query: query,
                caseSensitive: isCaseSensitive
            )
        }
    }

    @discardableResult
    func moveNext() -> DocumentSearchMatch? {
        guard !isSearching, !matches.isEmpty else { return nil }
        if let currentIndex {
            self.currentIndex = (currentIndex + 1) % matches.count
        } else {
            currentIndex = 0
        }
        return currentMatch
    }

    @discardableResult
    func movePrevious() -> DocumentSearchMatch? {
        guard !isSearching, !matches.isEmpty else { return nil }
        if let currentIndex {
            self.currentIndex = (currentIndex - 1 + matches.count) % matches.count
        } else {
            currentIndex = matches.index(before: matches.endIndex)
        }
        return currentMatch
    }

    func makeReplaceAllPlan(source: String) throws -> ReplaceAllPlan? {
        guard resultsAreCurrent(for: source) else {
            throw DocumentFindPlanError.resultsOutdated
        }

        let replacementUTF8 = self.replacementUTF8
        guard !query.isEmpty,
              matches.count > (matchedTextCounts[replacementUTF8] ?? 0)
        else {
            return nil
        }

        let changingMatches: [DocumentSearchMatch]
        if matchedTextCounts[replacementUTF8] == nil {
            changingMatches = matches
        } else {
            changingMatches = matches.filter { $0.matchedUTF8 != replacementUTF8 }
        }

        return ReplaceAllPlan(
            source: source,
            query: query,
            replacement: replacement,
            caseSensitive: isCaseSensitive,
            matches: changingMatches
        )
    }

    private var replacementUTF8: Data {
        Data(replacement.utf8)
    }

    private func resolvedIndex(
        in refreshed: [DocumentSearchMatch],
        position: SearchRefreshPosition,
        previousRange: Range<Int>?
    ) -> Int? {
        guard !refreshed.isEmpty else { return nil }

        switch position {
        case .first:
            return 0
        case let .atOrAfter(offset):
            return refreshed.firstIndex { $0.utf8Range.lowerBound >= offset } ?? 0
        case let .afterReplacement(insertedRange):
            let eligible = refreshed.indices.filter {
                !refreshed[$0].utf8Range.overlaps(insertedRange)
            }
            return eligible.first {
                refreshed[$0].utf8Range.lowerBound >= insertedRange.upperBound
            } ?? eligible.first
        case .preserve:
            if let previousRange,
               let exact = refreshed.firstIndex(where: { $0.utf8Range == previousRange }) {
                return exact
            }
            if let previousRange {
                return refreshed.firstIndex {
                    $0.utf8Range.lowerBound >= previousRange.lowerBound
                } ?? 0
            }
            return 0
        }
    }
}

struct ReplaceAllPlan: Identifiable {
    let id = UUID()
    let source: String
    let query: String
    let replacement: String
    let caseSensitive: Bool
    let matches: [DocumentSearchMatch]

    init(
        source: String,
        query: String,
        replacement: String,
        caseSensitive: Bool,
        matches: [DocumentSearchMatch]
    ) {
        self.source = source
        self.query = query
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.matches = matches
    }

    func preview(at index: Int) -> ReplacementPreview? {
        guard matches.indices.contains(index) else { return nil }
        return ReplacementPreview(
            source: source,
            match: matches[index],
            replacement: replacement
        )
    }
}

struct ReplacementPreview: Identifiable, Equatable {
    let id: Int
    let before: String
    let matched: String
    let after: String
    let replacement: String

    init?(source: String, match: DocumentSearchMatch, replacement: String) {
        let range = match.utf8Range
        guard let lowerUTF8 = source.utf8.index(
                  source.utf8.startIndex,
                  offsetBy: range.lowerBound,
                  limitedBy: source.utf8.endIndex
              ),
              let upperUTF8 = source.utf8.index(
                  source.utf8.startIndex,
                  offsetBy: range.upperBound,
                  limitedBy: source.utf8.endIndex
              ),
              let lower = String.Index(lowerUTF8, within: source),
              let upper = String.Index(upperUTF8, within: source)
        else {
            return nil
        }

        let contextStart = source.index(lower, offsetBy: -36, limitedBy: source.startIndex)
            ?? source.startIndex
        let contextEnd = source.index(upper, offsetBy: 36, limitedBy: source.endIndex)
            ?? source.endIndex

        id = range.lowerBound
        before = String(source[contextStart..<lower])
        matched = String(source[lower..<upper])
        after = String(source[upper..<contextEnd])
        self.replacement = replacement
    }
}

struct DocumentFindBar: View {
    @ObservedObject var session: DocumentFindSession
    let isEditable: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onReplaceCurrent: () -> Void
    let onPreviewReplaceAll: () -> Void
    let onClose: () -> Void

    @State private var focusedField: Field?

    private enum Field {
        case query
        case replacement
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    session.showsReplacement.toggle()
                } label: {
                    Image(
                        systemName: session.showsReplacement
                            ? "chevron.down"
                            : "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .help(session.showsReplacement ? "隐藏替换" : "显示替换")
                .accessibilityLabel(session.showsReplacement ? "隐藏替换" : "显示替换")

                multilineEditor(
                    text: $session.query,
                    prompt: "查找",
                    accessibilityLabel: "查找内容",
                    field: .query
                )

                Text(session.statusText)
                    .foregroundStyle(session.errorMessage == nil ? Color.secondary : Color.red)
                    .frame(minWidth: 86, alignment: .trailing)
                    .accessibilityLabel("查找结果")
                    .accessibilityValue(session.statusText)

                Toggle("区分大小写", isOn: $session.isCaseSensitive)
                    .toggleStyle(.button)
                    .help("区分大小写")

                Button(action: onPrevious) {
                    Label("查找上一个", systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(!session.canNavigate)
                .help("查找上一个（⇧⌘G）")
                .accessibilityLabel("查找上一个")

                Button(action: onNext) {
                    Label("查找下一个", systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .disabled(!session.canNavigate)
                .help("查找下一个（⌘G）")
                .accessibilityLabel("查找下一个")

                Button(action: onClose) {
                    Label("关闭查找", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("关闭查找（Esc）")
                .accessibilityLabel("关闭查找")
            }

            if session.showsReplacement {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 18, height: 1)

                    multilineEditor(
                        text: $session.replacement,
                        prompt: "替换为",
                        accessibilityLabel: "替换内容",
                        field: .replacement
                    )
                    .disabled(!isEditable)

                    Button("替换当前", action: onReplaceCurrent)
                        .disabled(!isEditable || !session.canReplaceCurrent)

                    Button("全部替换…", action: onPreviewReplaceAll)
                        .disabled(!isEditable || !session.hasReplacementChanges)

                    Spacer(minLength: 0)
                }
            }

            if let notice = session.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(notice)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task(id: session.focusGeneration) {
            await Task.yield()
            focusedField = .query
        }
        .onExitCommand(perform: onClose)
    }

    private func multilineEditor(
        text: Binding<String>,
        prompt: String,
        accessibilityLabel: String,
        field: Field
    ) -> some View {
        ZStack(alignment: .topLeading) {
            LiteralMultilineTextEditor(
                text: text,
                isFocused: Binding(
                    get: { focusedField == field },
                    set: { isFocused in
                        if isFocused {
                            focusedField = field
                        } else if focusedField == field {
                            focusedField = nil
                        }
                    }
                ),
                accessibilityLabel: accessibilityLabel,
                onCancel: onClose
            )

            if text.wrappedValue.isEmpty {
                Text(prompt)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 180, minHeight: 32, idealHeight: 32, maxHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct LiteralMultilineTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let accessibilityLabel: String
    let onCancel: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = LiteralFindTextView(frame: scrollView.contentView.bounds)
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
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
        textView.textContainerInset = NSSize(width: 5, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.cancelHandler = onCancel
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.didAttachToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.applyRequestedFocus()
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? LiteralFindTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.cancelHandler = onCancel

        if !UTF8Text.isExactlyEqual(textView.string, text) {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(
                NSRange(location: min(selection.location, length), length: 0)
            )
        }

        context.coordinator.applyRequestedFocus()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? LiteralFindTextView else { return }
        textView.delegate = nil
        textView.didAttachToWindow = nil
        textView.cancelHandler = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiteralMultilineTextEditor
        weak var textView: LiteralFindTextView?

        init(parent: LiteralMultilineTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? LiteralFindTextView else { return }
            self.textView = textView
            Task { @MainActor [weak self, weak textView] in
                guard let self,
                      let textView,
                      textView.window?.firstResponder === textView,
                      !parent.isFocused
                else {
                    return
                }
                parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? LiteralFindTextView else { return }
            self.textView = textView
            Task { @MainActor [weak self, weak textView] in
                guard let self,
                      let textView,
                      textView.window?.firstResponder !== textView,
                      parent.isFocused
                else {
                    return
                }
                parent.isFocused = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? LiteralFindTextView else { return }
            self.textView = textView
            let updatedText = textView.string
            Task { @MainActor [weak self] in
                guard let self,
                      !UTF8Text.isExactlyEqual(parent.text, updatedText)
                else {
                    return
                }
                parent.text = updatedText
            }
        }

        func applyRequestedFocus() {
            guard parent.isEnabled,
                  parent.isFocused,
                  let textView,
                  let window = textView.window,
                  window.firstResponder !== textView
            else {
                return
            }

            Task { @MainActor [weak textView] in
                guard let textView,
                      parent.isEnabled,
                      parent.isFocused,
                      let window = textView.window
                else {
                    return
                }
                _ = window.makeFirstResponder(textView)
            }
        }
    }
}

@MainActor
private final class LiteralFindTextView: NSTextView {
    var didAttachToWindow: (() -> Void)?
    var cancelHandler: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            didAttachToWindow?()
        }
    }

    override func insertTab(_ sender: Any?) {
        guard let window else { return }
        window.recalculateKeyViewLoop()
        window.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        guard let window else { return }
        window.recalculateKeyViewLoop()
        window.selectPreviousKeyView(self)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            return
        }
        cancelHandler?()
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {}

    override func toggleGrammarChecking(_ sender: Any?) {}

    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}

    override func toggleSmartInsertDelete(_ sender: Any?) {}

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {}

    override func toggleAutomaticDashSubstitution(_ sender: Any?) {}

    override func toggleAutomaticLinkDetection(_ sender: Any?) {}

    override func toggleAutomaticDataDetection(_ sender: Any?) {}

    override func toggleAutomaticTextReplacement(_ sender: Any?) {}

    override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        switch item.action {
        case #selector(toggleContinuousSpellChecking(_:)),
             #selector(toggleGrammarChecking(_:)),
             #selector(toggleAutomaticSpellingCorrection(_:)),
             #selector(toggleSmartInsertDelete(_:)),
             #selector(toggleAutomaticQuoteSubstitution(_:)),
             #selector(toggleAutomaticDashSubstitution(_:)),
             #selector(toggleAutomaticLinkDetection(_:)),
             #selector(toggleAutomaticDataDetection(_:)),
             #selector(toggleAutomaticTextReplacement(_:)):
            false
        default:
            super.validateUserInterfaceItem(item)
        }
    }
}

struct ReplaceAllPreviewView: View {
    let plan: ReplaceAllPlan
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("确认全部替换")
                    .font(.title2.weight(.semibold))
                Text("将修改 \(plan.matches.count) 处；正文变化后此计划会自动失效。")
                    .foregroundStyle(.secondary)
            }

            HStack {
                LabeledContent("查找", value: plan.query)
                Divider()
                LabeledContent("替换为", value: plan.replacement.isEmpty ? "（删除）" : plan.replacement)
                Spacer()
                Text(plan.caseSensitive ? "区分大小写" : "不区分大小写")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.matches.indices, id: \.self) { index in
                        if let preview = plan.preview(at: index) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("匹配 \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Label("替换前", systemImage: "minus.circle")
                                    .font(.caption)
                                (
                                    Text(preview.before)
                                        + Text(preview.matched).bold().foregroundColor(.red)
                                        + Text(preview.after)
                                )
                                .textSelection(.enabled)
                                Label("替换后", systemImage: "plus.circle")
                                    .font(.caption)
                                (
                                    Text(preview.before)
                                        + Text(preview.replacement).bold().foregroundColor(.green)
                                        + Text(preview.after)
                                )
                                .textSelection(.enabled)
                            }
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                .quaternary.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .frame(minHeight: 240)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("替换 \(plan.matches.count) 处", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 420)
    }
}
