import SwiftUI
import WebKit

struct PreviewScrollRequest: Equatable {
    let generation: Int
    let fraction: Double
}

enum PreviewIssueAction: String, Equatable, Sendable {
    case locate
    case retry
}

enum PreviewImageIssueAction: String, Equatable, Sendable {
    case replace
    case locate
    case copyTarget
    case ignore
}

struct PreviewMarkdownEdit: Equatable, Sendable {
    let sourceUTF8Range: Range<Int>
    let originalSource: String
    let replacement: String
}

enum PreviewWebNavigationPolicy {
    static func allows(navigationType: WKNavigationType, scheme: String?) -> Bool {
        guard navigationType != .linkActivated else { return false }
        guard let scheme = scheme?.lowercased() else { return true }
        // WKWebView uses the private applewebdata scheme for documents created
        // by loadHTMLString on some macOS releases. It is an in-memory document
        // origin, not permission to read a file or contact the network.
        return scheme == "about" || scheme == "data" || scheme == "applewebdata"
    }
}

enum PreviewNavigationMessage: Equatable {
    case heading(sourceUTF8Offset: Int)
    case link(target: String)
    case edit(sourceUTF8Offset: Int?)
    case markdownEdit(PreviewMarkdownEdit)
    case previewIssue(action: PreviewIssueAction, sourceUTF8Offset: Int)
    case imageIssue(
        action: PreviewImageIssueAction,
        sourceUTF8Offset: Int,
        target: String
    )
    case manualScroll

    static func decode(_ body: Any) -> Self? {
        guard let dictionary = body as? [String: Any],
              let type = dictionary["type"] as? String
        else {
            return nil
        }
        switch type {
        case "heading":
            guard let offset = decodeSourceOffset(dictionary) else { return nil }
            return .heading(sourceUTF8Offset: offset)
        case "link":
            guard let targetHex = dictionary["targetHex"] as? String,
                  let target = decodeHexTarget(targetHex),
                  !target.unicodeScalars.contains(where: { scalar in
                      CharacterSet.controlCharacters.contains(scalar)
                  })
            else {
                return nil
            }
            return .link(target: target)
        case "manualScroll":
            return .manualScroll
        case "edit":
            guard dictionary.keys.contains("sourceUTF8Offset") else {
                return .edit(sourceUTF8Offset: nil)
            }
            guard let offset = decodeSourceOffset(dictionary) else { return nil }
            return .edit(sourceUTF8Offset: offset)
        case "markdownEdit":
            guard let start = decodeSourceOffset(dictionary, key: "sourceStart"),
                  let end = decodeSourceOffset(dictionary, key: "sourceEnd"),
                  start <= end,
                  let originalHex = dictionary["originalHex"] as? String,
                  let replacementHex = dictionary["replacementHex"] as? String,
                  let original = decodeHex(originalHex, maximumBytes: 1_048_576),
                  let replacement = decodeHex(replacementHex, maximumBytes: 1_048_576)
            else {
                return nil
            }
            return .markdownEdit(
                PreviewMarkdownEdit(
                    sourceUTF8Range: start..<end,
                    originalSource: original,
                    replacement: replacement
                )
            )
        case "previewIssue":
            guard let actionName = dictionary["action"] as? String,
                  let action = PreviewIssueAction(rawValue: actionName),
                  let offset = decodeSourceOffset(dictionary)
            else {
                return nil
            }
            return .previewIssue(action: action, sourceUTF8Offset: offset)
        case "imageIssue":
            guard let actionName = dictionary["action"] as? String,
                  let action = PreviewImageIssueAction(rawValue: actionName),
                  let offset = decodeSourceOffset(dictionary),
                  let targetHex = dictionary["targetHex"] as? String,
                  let target = decodeHexTarget(targetHex),
                  !target.unicodeScalars.contains(where: { scalar in
                      CharacterSet.controlCharacters.contains(scalar)
                  })
            else {
                return nil
            }
            return .imageIssue(
                action: action,
                sourceUTF8Offset: offset,
                target: target
            )
        default:
            return nil
        }
    }

    private static func decodeSourceOffset(
        _ dictionary: [String: Any],
        key: String = "sourceUTF8Offset"
    ) -> Int? {
        guard let number = dictionary[key] as? NSNumber else { return nil }
        let value = number.doubleValue
        guard CFGetTypeID(number) != CFBooleanGetTypeID(),
              value.isFinite,
              value >= 0,
              value <= 9_007_199_254_740_991,
              value.rounded(.towardZero) == value
        else {
            return nil
        }
        return Int(value)
    }

    private static func decodeHexTarget(_ hex: String) -> String? {
        decodeHex(hex, maximumBytes: 16 * 1_024)
    }

    private static func decodeHex(_ hex: String, maximumBytes: Int) -> String? {
        let bytes = Array(hex.utf8)
        guard bytes.count <= maximumBytes * 2, bytes.count.isMultiple(of: 2) else { return nil }
        var decoded = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = hexadecimalValue(bytes[index]),
                  let low = hexadecimalValue(bytes[index + 1])
            else {
                return nil
            }
            decoded.append(high << 4 | low)
            index += 2
        }
        return String(data: decoded, encoding: .utf8)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    private static let messageHandlerName = "inflowPreviewNavigation"

    let html: String
    let baseURL: URL?
    let isEditable: Bool
    let scrollRequest: PreviewScrollRequest?
    let onHeadingActivated: (Int) -> Void
    let onLinkActivated: (String) -> Void
    let onEditRequested: (Int?) -> Void
    let onMarkdownEditCommitted: (PreviewMarkdownEdit) -> Void
    let onPreviewIssueAction: (PreviewIssueAction, Int) -> Void
    let onImageIssueAction: (PreviewImageIssueAction, Int, String) -> Void
    let onManualScroll: () -> Void

    init(
        html: String,
        baseURL: URL?,
        isEditable: Bool = false,
        scrollRequest: PreviewScrollRequest? = nil,
        onHeadingActivated: @escaping (Int) -> Void = { _ in },
        onLinkActivated: @escaping (String) -> Void = { _ in },
        onEditRequested: @escaping (Int?) -> Void = { _ in },
        onMarkdownEditCommitted: @escaping (PreviewMarkdownEdit) -> Void = { _ in },
        onPreviewIssueAction: @escaping (PreviewIssueAction, Int) -> Void = { _, _ in },
        onImageIssueAction: @escaping (PreviewImageIssueAction, Int, String) -> Void = { _, _, _ in },
        onManualScroll: @escaping () -> Void = {}
    ) {
        self.html = html
        self.baseURL = baseURL
        self.isEditable = isEditable
        self.scrollRequest = scrollRequest
        self.onHeadingActivated = onHeadingActivated
        self.onLinkActivated = onLinkActivated
        self.onEditRequested = onEditRequested
        self.onMarkdownEditCommitted = onMarkdownEditCommitted
        self.onPreviewIssueAction = onPreviewIssueAction
        self.onImageIssueAction = onImageIssueAction
        self.onManualScroll = onManualScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .defaultClient,
            name: Self.messageHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.navigationBridgeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityLabel("Markdown 预览")
        context.coordinator.update(
            isEditable: isEditable,
            scrollRequest: scrollRequest,
            onHeadingActivated: onHeadingActivated,
            onLinkActivated: onLinkActivated,
            onEditRequested: onEditRequested,
            onMarkdownEditCommitted: onMarkdownEditCommitted,
            onPreviewIssueAction: onPreviewIssueAction,
            onImageIssueAction: onImageIssueAction,
            onManualScroll: onManualScroll,
            webView: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            isEditable: isEditable,
            scrollRequest: scrollRequest,
            onHeadingActivated: onHeadingActivated,
            onLinkActivated: onLinkActivated,
            onEditRequested: onEditRequested,
            onMarkdownEditCommitted: onMarkdownEditCommitted,
            onPreviewIssueAction: onPreviewIssueAction,
            onImageIssueAction: onImageIssueAction,
            onManualScroll: onManualScroll,
            webView: webView
        )
        let htmlChanged = context.coordinator.lastHTML.map {
            !UTF8Text.isExactlyEqual($0, html)
        } ?? true
        let baseURLChanged = context.coordinator.lastBaseURL != baseURL
        guard htmlChanged || baseURLChanged else {
            return
        }

        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.scheduleDocumentUpdate(
            html,
            permitsBlockPatch: !baseURLChanged,
            in: webView
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.messageHandlerName,
            contentWorld: .defaultClient
        )
        coordinator.lastHTML = nil
        coordinator.lastBaseURL = nil
        coordinator.cancelDocumentLoad()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String?
        var lastBaseURL: URL?
        private var requestedScroll: PreviewScrollRequest?
        private var appliedScrollGeneration: Int?
        private var isDocumentLoaded = false
        private var documentLoadTask: Task<Void, Never>?
        private var documentLoadGeneration = 0
        private var isEditable = false
        private var onHeadingActivated: (Int) -> Void = { _ in }
        private var onLinkActivated: (String) -> Void = { _ in }
        private var onEditRequested: (Int?) -> Void = { _ in }
        private var onMarkdownEditCommitted: (PreviewMarkdownEdit) -> Void = { _ in }
        private var onPreviewIssueAction: (PreviewIssueAction, Int) -> Void = { _, _ in }
        private var onImageIssueAction: (PreviewImageIssueAction, Int, String) -> Void = { _, _, _ in }
        private var onManualScroll: () -> Void = {}

        func update(
            isEditable: Bool = false,
            scrollRequest: PreviewScrollRequest?,
            onHeadingActivated: @escaping (Int) -> Void,
            onLinkActivated: @escaping (String) -> Void,
            onEditRequested: @escaping (Int?) -> Void = { _ in },
            onMarkdownEditCommitted: @escaping (PreviewMarkdownEdit) -> Void = { _ in },
            onPreviewIssueAction: @escaping (PreviewIssueAction, Int) -> Void,
            onImageIssueAction: @escaping (PreviewImageIssueAction, Int, String) -> Void = { _, _, _ in },
            onManualScroll: @escaping () -> Void,
            webView: WKWebView
        ) {
            self.isEditable = isEditable
            requestedScroll = scrollRequest
            self.onHeadingActivated = onHeadingActivated
            self.onLinkActivated = onLinkActivated
            self.onEditRequested = onEditRequested
            self.onMarkdownEditCommitted = onMarkdownEditCommitted
            self.onPreviewIssueAction = onPreviewIssueAction
            self.onImageIssueAction = onImageIssueAction
            self.onManualScroll = onManualScroll
            applyEditingModeIfPossible(to: webView)
            applyScrollIfPossible(to: webView)
        }

        func scheduleDocumentLoad(_ html: String, in webView: WKWebView) {
            documentLoadTask?.cancel()
            documentLoadGeneration &+= 1
            let generation = documentLoadGeneration
            isDocumentLoaded = false
            appliedScrollGeneration = nil
            documentLoadTask = Task { @MainActor [weak self, weak webView] in
                // Loading synchronously from updateNSView can ask WebKit to
                // publish navigation state while SwiftUI is updating its view
                // graph. Waiting one run-loop turn also lets the preview pane
                // receive its final size before its first document is loaded.
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.documentLoadGeneration == generation,
                      let webView
                else {
                    return
                }

                for _ in 0..<60 {
                    if webView.window != nil,
                       webView.bounds.width > 0,
                       webView.bounds.height > 0
                    {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    guard !Task.isCancelled,
                          self.documentLoadGeneration == generation
                    else {
                        return
                    }
                }
                guard webView.window != nil,
                      webView.bounds.width > 0,
                      webView.bounds.height > 0
                else {
                    webView.setAccessibilityValue("Markdown 预览尚未就绪")
                    return
                }
                webView.setAccessibilityValue("正在加载 Markdown 预览")
                // All accepted local images have already been validated and
                // converted to data URLs. Never give WebKit a filesystem origin
                // or read scope.
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func scheduleDocumentUpdate(
            _ html: String,
            permitsBlockPatch: Bool,
            in webView: WKWebView
        ) {
            guard permitsBlockPatch, isDocumentLoaded else {
                scheduleDocumentLoad(html, in: webView)
                return
            }
            documentLoadTask?.cancel()
            documentLoadGeneration &+= 1
            let generation = documentLoadGeneration
            documentLoadTask = Task { @MainActor [weak self, weak webView] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.documentLoadGeneration == generation,
                      let webView
                else { return }
                webView.callAsyncJavaScript(
                    Self.blockPatchFunction,
                    arguments: ["html": html],
                    in: nil,
                    in: .defaultClient
                ) { [weak self, weak webView] result in
                    guard let self,
                          self.documentLoadGeneration == generation,
                          let webView
                    else { return }
                    switch result {
                    case let .success(value) where (value as? Bool) == true:
                        self.isDocumentLoaded = true
                        webView.setAccessibilityValue("Markdown 预览已更新")
                        self.applyEditingModeIfPossible(to: webView)
                        self.applyScrollIfPossible(to: webView)
                    default:
                        self.scheduleDocumentLoad(html, in: webView)
                    }
                }
            }
        }

        func cancelDocumentLoad() {
            documentLoadTask?.cancel()
            documentLoadTask = nil
            documentLoadGeneration &+= 1
            isDocumentLoaded = false
            appliedScrollGeneration = nil
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
            isDocumentLoaded = true
            webView.setAccessibilityValue("Markdown 预览已加载")
            applyEditingModeIfPossible(to: webView)
            applyScrollIfPossible(to: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail _: WKNavigation?,
            withError _: Error
        ) {
            isDocumentLoaded = false
            webView.setAccessibilityValue("Markdown 预览加载失败")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation _: WKNavigation?,
            withError _: Error
        ) {
            isDocumentLoaded = false
            webView.setAccessibilityValue("Markdown 预览加载失败")
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == MarkdownPreviewView.messageHandlerName,
                  message.frameInfo.isMainFrame,
                  let navigation = PreviewNavigationMessage.decode(message.body)
            else {
                return
            }
            handle(navigation)
        }

        func handle(_ message: PreviewNavigationMessage) {
            switch message {
            case let .heading(sourceUTF8Offset):
                onHeadingActivated(sourceUTF8Offset)
            case let .link(target):
                onLinkActivated(target)
            case let .edit(sourceUTF8Offset):
                onEditRequested(sourceUTF8Offset)
            case let .markdownEdit(edit):
                onMarkdownEditCommitted(edit)
            case let .previewIssue(action, sourceUTF8Offset):
                onPreviewIssueAction(action, sourceUTF8Offset)
            case let .imageIssue(action, sourceUTF8Offset, target):
                onImageIssueAction(action, sourceUTF8Offset, target)
            case .manualScroll:
                onManualScroll()
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let isAllowed = PreviewWebNavigationPolicy.allows(
                navigationType: navigationAction.navigationType,
                scheme: navigationAction.request.url?.scheme
            )
            decisionHandler(
                isAllowed ? .allow : .cancel
            )
        }

        private func applyScrollIfPossible(to webView: WKWebView) {
            guard isDocumentLoaded,
                  let request = requestedScroll,
                  request.generation != appliedScrollGeneration
            else {
                return
            }
            let fraction = min(max(request.fraction, 0), 1)
            appliedScrollGeneration = request.generation
            webView.callAsyncJavaScript(
                Self.scrollFunction,
                arguments: ["fraction": NSNumber(value: fraction)],
                in: nil,
                in: .defaultClient
            ) { [weak self] result in
                guard case .failure = result,
                      self?.appliedScrollGeneration == request.generation
                else {
                    return
                }
                self?.appliedScrollGeneration = nil
            }
        }

        private func applyEditingModeIfPossible(to webView: WKWebView) {
            guard isDocumentLoaded else { return }
            webView.callAsyncJavaScript(
                "document.body.dataset.inflowEditable = editable ? 'true' : 'false'; return true;",
                arguments: ["editable": NSNumber(value: isEditable)],
                in: nil,
                in: .defaultClient
            ) { _ in }
            webView.setAccessibilityLabel(isEditable ? "Markdown 即时编辑器" : "Markdown 预览")
        }

        private static let scrollFunction = """
        const maximum = Math.max(
          0,
          document.documentElement.scrollHeight - window.innerHeight
        );
        window.scrollTo(0, maximum * fraction);
        return window.scrollY;
        """

        private static let blockPatchFunction = """
        const parsed = new DOMParser().parseFromString(html, 'text/html');
        if (!parsed || !parsed.body) return false;

        const currentChildren = Array.from(document.body.children);
        const nextChildren = Array.from(parsed.body.children);
        const currentByID = new Map();
        for (const node of currentChildren) {
          const id = node.getAttribute('data-inflow-block-id');
          if (id) currentByID.set(id, node);
        }

        const anchor = currentChildren.find((node) => {
          const rect = node.getBoundingClientRect();
          return rect.bottom >= 0 && node.hasAttribute('data-inflow-block-id');
        });
        const anchorID = anchor?.getAttribute('data-inflow-block-id') ?? null;
        const anchorTop = anchor?.getBoundingClientRect().top ?? 0;

        const fragment = document.createDocumentFragment();
        for (const nextNode of nextChildren) {
          const id = nextNode.getAttribute('data-inflow-block-id');
          const current = id ? currentByID.get(id) : null;
          if (current && current.outerHTML === nextNode.outerHTML) {
            fragment.appendChild(current);
          } else {
            fragment.appendChild(document.importNode(nextNode, true));
          }
        }
        document.body.replaceChildren(fragment);

        const currentStyles = Array.from(document.head.querySelectorAll('style'));
        for (const style of currentStyles) style.remove();
        for (const style of Array.from(parsed.head.querySelectorAll('style'))) {
          document.head.appendChild(document.importNode(style, true));
        }

        if (anchorID) {
          const escaped = CSS.escape(anchorID);
          const restored = document.querySelector(`[data-inflow-block-id="${escaped}"]`);
          if (restored) window.scrollBy(0, restored.getBoundingClientRect().top - anchorTop);
        }
        return true;
        """
    }

    private static let navigationBridgeScript = """
    (() => {
      const handler = window.webkit.messageHandlers.inflowPreviewNavigation;
      const selector = '[data-inflow-source-start]';
      const headingFor = (target) =>
        target instanceof Element ? target.closest(selector) : null;
      const activate = (heading) => {
        const value = Number(heading.dataset.inflowSourceStart);
        if (Number.isSafeInteger(value) && value >= 0) {
          handler.postMessage({ type: 'heading', sourceUTF8Offset: value });
        }
      };
      const isEditable = () => document.body.dataset.inflowEditable === 'true';
      const hexToText = (hex) => {
        if (typeof hex !== 'string' || hex.length % 2 !== 0) return null;
        const bytes = new Uint8Array(hex.length / 2);
        for (let index = 0; index < hex.length; index += 2) {
          const value = Number.parseInt(hex.slice(index, index + 2), 16);
          if (!Number.isFinite(value)) return null;
          bytes[index / 2] = value;
        }
        try { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
        catch (_) { return null; }
      };
      const textToHex = (value) => Array.from(new TextEncoder().encode(value))
        .map((byte) => byte.toString(16).padStart(2, '0')).join('');
      const inlineMarkdown = (node) => {
        if (node.nodeType === Node.TEXT_NODE) return node.nodeValue ?? '';
        if (!(node instanceof Element)) return '';
        const content = Array.from(node.childNodes).map(inlineMarkdown).join('');
        switch (node.tagName) {
        case 'STRONG': case 'B': return `**${content}**`;
        case 'EM': case 'I': return `*${content}*`;
        case 'DEL': case 'S': return `~~${content}~~`;
        case 'CODE': {
          const delimiter = content.includes('`') ? '``' : '`';
          return `${delimiter}${content}${delimiter}`;
        }
        case 'A': {
          const encoded = node.getAttribute('data-inflow-link-target-hex');
          const target = hexToText(encoded) ?? node.getAttribute('href') ?? '';
          return `[${content}](${target})`;
        }
        case 'BR': return '\n';
        case 'IMG': {
          const encoded = node.getAttribute('data-inflow-markdown-target-hex');
          const target = hexToText(encoded);
          return target === null ? '' : `![${node.getAttribute('alt') ?? ''}](${target})`;
        }
        case 'INPUT': return '';
        default: return content;
        }
      };
      const listItemMarkdown = (item, ordered, index) => {
        const nested = Array.from(item.children).filter((child) =>
          child.tagName === 'UL' || child.tagName === 'OL');
        const clone = item.cloneNode(true);
        for (const child of Array.from(clone.children)) {
          if (child.tagName === 'UL' || child.tagName === 'OL') child.remove();
        }
        const checkbox = item.querySelector(':scope > input[type="checkbox"]');
        const marker = ordered ? `${index + 1}. ` : '- ';
        const task = checkbox ? `[${checkbox.checked ? 'x' : ' '}] ` : '';
        let result = marker + task + inlineMarkdown(clone).trim();
        for (const child of nested) {
          const rendered = blockMarkdown(child);
          result += '\n' + rendered.split('\n').map((line) => `  ${line}`).join('\n');
        }
        return result;
      };
      const tableMarkdown = (table, original) => {
        const rows = Array.from(table.querySelectorAll('tr'));
        if (rows.length === 0) return original;
        const cells = rows.map((row) => Array.from(row.querySelectorAll(':scope > th, :scope > td'))
          .map((cell) => inlineMarkdown(cell).trim().split('|').join('\\|')));
        const widths = Math.max(...cells.map((row) => row.length));
        const normalized = cells.map((row) => Array.from({ length: widths }, (_, column) => row[column] ?? ''));
        const headerCells = Array.from(rows[0].querySelectorAll(':scope > th, :scope > td'));
        const delimiter = Array.from({ length: widths }, (_, column) => {
          const alignment = getComputedStyle(headerCells[column] ?? rows[0]).textAlign;
          if (alignment === 'center') return ':---:';
          if (alignment === 'right' || alignment === 'end') return '---:';
          return '---';
        });
        const line = (row) => `| ${row.join(' | ')} |`;
        return [line(normalized[0]), line(delimiter), ...normalized.slice(1).map(line)].join('\n');
      };
      const blockMarkdown = (block) => {
        switch (block.tagName) {
        case 'P': return inlineMarkdown(block);
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
          return `${'#'.repeat(Number(block.tagName.slice(1)))} ${inlineMarkdown(block).trim()}`;
        case 'BLOCKQUOTE': {
          const content = Array.from(block.children).map(blockMarkdown).join('\n\n');
          return content.split('\n').map((line) => `> ${line}`).join('\n');
        }
        case 'UL': case 'OL':
          return Array.from(block.children)
            .filter((child) => child.tagName === 'LI')
            .map((item, index) => listItemMarkdown(item, block.tagName === 'OL', index))
            .join('\n');
        case 'TABLE': return tableMarkdown(block, '');
        default: return null;
        }
      };
      const trailingLineEndings = (source) => {
        let index = source.length;
        while (index > 0 && (source[index - 1] === '\n' || source[index - 1] === '\r')) index -= 1;
        return source.slice(index);
      };
      const finishEditing = (block, cancel = false) => {
        if (!(block instanceof Element) || block.dataset.inflowEditing !== 'true') return;
        const originalHex = block.dataset.inflowSourceHex;
        const original = hexToText(originalHex);
        const start = Number(block.dataset.inflowSourceStart);
        const end = Number(block.dataset.inflowSourceEnd);
        const sourceEditor = block.querySelector(':scope > textarea.inflow-source-block-editor');
        let replacement = sourceEditor ? sourceEditor.value : blockMarkdown(block);
        if (cancel || original === null || replacement === null) {
          block.innerHTML = block.__inflowOriginalHTML;
          block.removeAttribute('contenteditable');
          block.removeAttribute('data-inflow-editing');
          return;
        }
        replacement += trailingLineEndings(original);
        block.removeAttribute('contenteditable');
        block.removeAttribute('data-inflow-editing');
        if (replacement === original) return;
        if (Number.isSafeInteger(start) && Number.isSafeInteger(end) && start <= end) {
          handler.postMessage({
            type: 'markdownEdit', sourceStart: start, sourceEnd: end,
            originalHex, replacementHex: textToHex(replacement)
          });
        }
      };
      const beginEditing = (block, event) => {
        if (!(block instanceof Element) || block.dataset.inflowEditing === 'true') return;
        const original = hexToText(block.dataset.inflowSourceHex);
        if (original === null) return;
        block.__inflowOriginalHTML = block.innerHTML;
        block.dataset.inflowEditing = 'true';
        const requiresSource = ['PRE', 'FIGURE', 'DL'].includes(block.tagName);
        if (requiresSource) {
          const textarea = document.createElement('textarea');
          textarea.className = 'inflow-source-block-editor';
          textarea.value = original;
          textarea.setAttribute('aria-label', 'Markdown 块源码');
          block.replaceChildren(textarea);
          textarea.focus();
          textarea.setSelectionRange(textarea.value.length, textarea.value.length);
        } else {
          block.contentEditable = 'true';
          block.focus({ preventScroll: true });
          const position = document.caretPositionFromPoint?.(event.clientX, event.clientY);
          if (position) {
            const range = document.createRange();
            range.setStart(position.offsetNode, position.offset);
            range.collapse(true);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
          }
        }
      };

      document.addEventListener('click', (event) => {
        const imageAction = event.target instanceof Element
          ? event.target.closest('[data-inflow-image-action]')
          : null;
        if (imageAction) {
          event.preventDefault();
          const issue = imageAction.closest('[data-inflow-image-source-start]');
          const sourceUTF8Offset = Number(issue?.dataset.inflowImageSourceStart);
          const targetHex = issue?.dataset.inflowImageTargetHex;
          const action = imageAction.dataset.inflowImageAction;
          if (Number.isSafeInteger(sourceUTF8Offset)
              && sourceUTF8Offset >= 0
              && typeof targetHex === 'string'
              && (action === 'replace'
                  || action === 'locate'
                  || action === 'copyTarget'
                  || action === 'ignore')) {
            handler.postMessage({
              type: 'imageIssue', action, sourceUTF8Offset, targetHex
            });
            if (action === 'ignore') {
              issue.hidden = true;
            }
          }
          return;
        }
        const issueAction = event.target instanceof Element
          ? event.target.closest('[data-inflow-preview-error-action]')
          : null;
        if (issueAction) {
          event.preventDefault();
          const issue = issueAction.closest('[data-inflow-source-start]');
          const sourceUTF8Offset = Number(issue?.dataset.inflowSourceStart);
          const action = issueAction.dataset.inflowPreviewErrorAction;
          if (Number.isSafeInteger(sourceUTF8Offset)
              && sourceUTF8Offset >= 0
              && (action === 'locate' || action === 'retry')) {
            handler.postMessage({ type: 'previewIssue', action, sourceUTF8Offset });
          }
          return;
        }
        const link = event.target instanceof Element
          ? event.target.closest('a[data-inflow-link-target-hex]')
          : null;
        if (link) {
          event.preventDefault();
          const targetHex = link.getAttribute('data-inflow-link-target-hex');
          if (targetHex !== null) {
            handler.postMessage({ type: 'link', targetHex });
          }
          return;
        }
        const heading = headingFor(event.target);
        if (!heading) {
          return;
        }
        if (isEditable()) return;
        event.preventDefault();
        activate(heading);
      });
      document.addEventListener('keydown', (event) => {
        if (!isEditable()
            && (event.key === 'Enter' || event.key === ' ')
            && event.target instanceof Element
            && event.target.matches(selector)) {
          event.preventDefault();
          activate(event.target);
        }
      });

      document.addEventListener('dblclick', (event) => {
        const target = event.target instanceof Element ? event.target : null;
        if (!isEditable() || !target || target.closest('a, button, input')) {
          return;
        }
        const located = target.closest(selector);
        if (!located || typeof located.dataset.inflowSourceHex !== 'string') return;
        event.preventDefault();
        beginEditing(located, event);
      });
      document.addEventListener('focusout', (event) => {
        const block = event.target instanceof Element ? event.target.closest(selector) : null;
        if (!block || block.dataset.inflowEditing !== 'true') return;
        setTimeout(() => {
          if (!block.contains(document.activeElement)) finishEditing(block);
        }, 0);
      });
      document.addEventListener('keydown', (event) => {
        const block = event.target instanceof Element ? event.target.closest(selector) : null;
        if (!block || block.dataset.inflowEditing !== 'true') return;
        if (event.key === 'Escape') {
          event.preventDefault();
          finishEditing(block, true);
        } else if (event.key === 'Enter' && event.metaKey) {
          event.preventDefault();
          finishEditing(block);
        }
      });

      let manualInputUntil = 0;
      let lastManualNotice = 0;
      const markManualInput = () => { manualInputUntil = Date.now() + 750; };
      for (const eventName of ['wheel', 'mousedown', 'touchstart', 'keydown']) {
        window.addEventListener(eventName, markManualInput, { passive: true });
      }
      window.addEventListener('scroll', () => {
        const now = Date.now();
        if (now <= manualInputUntil && now - lastManualNotice > 100) {
          lastManualNotice = now;
          handler.postMessage({ type: 'manualScroll' });
        }
      }, { passive: true });
    })();
    """
}
