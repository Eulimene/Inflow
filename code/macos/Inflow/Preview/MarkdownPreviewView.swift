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
    let scrollRequest: PreviewScrollRequest?
    let onHeadingActivated: (Int) -> Void
    let onLinkActivated: (String) -> Void
    let onPreviewIssueAction: (PreviewIssueAction, Int) -> Void
    let onImageIssueAction: (PreviewImageIssueAction, Int, String) -> Void
    let onManualScroll: () -> Void

    init(
        html: String,
        baseURL: URL?,
        scrollRequest: PreviewScrollRequest? = nil,
        onHeadingActivated: @escaping (Int) -> Void = { _ in },
        onLinkActivated: @escaping (String) -> Void = { _ in },
        onPreviewIssueAction: @escaping (PreviewIssueAction, Int) -> Void = { _, _ in },
        onImageIssueAction: @escaping (PreviewImageIssueAction, Int, String) -> Void = { _, _, _ in },
        onManualScroll: @escaping () -> Void = {}
    ) {
        self.html = html
        self.baseURL = baseURL
        self.scrollRequest = scrollRequest
        self.onHeadingActivated = onHeadingActivated
        self.onLinkActivated = onLinkActivated
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
            scrollRequest: scrollRequest,
            onHeadingActivated: onHeadingActivated,
            onLinkActivated: onLinkActivated,
            onPreviewIssueAction: onPreviewIssueAction,
            onImageIssueAction: onImageIssueAction,
            onManualScroll: onManualScroll,
            webView: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            scrollRequest: scrollRequest,
            onHeadingActivated: onHeadingActivated,
            onLinkActivated: onLinkActivated,
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
        private var onHeadingActivated: (Int) -> Void = { _ in }
        private var onLinkActivated: (String) -> Void = { _ in }
        private var onPreviewIssueAction: (PreviewIssueAction, Int) -> Void = { _, _ in }
        private var onImageIssueAction: (PreviewImageIssueAction, Int, String) -> Void = { _, _, _ in }
        private var onManualScroll: () -> Void = {}

        func update(
            scrollRequest: PreviewScrollRequest?,
            onHeadingActivated: @escaping (Int) -> Void,
            onLinkActivated: @escaping (String) -> Void,
            onPreviewIssueAction: @escaping (PreviewIssueAction, Int) -> Void,
            onImageIssueAction: @escaping (PreviewImageIssueAction, Int, String) -> Void = { _, _, _ in },
            onManualScroll: @escaping () -> Void,
            webView: WKWebView
        ) {
            requestedScroll = scrollRequest
            self.onHeadingActivated = onHeadingActivated
            self.onLinkActivated = onLinkActivated
            self.onPreviewIssueAction = onPreviewIssueAction
            self.onImageIssueAction = onImageIssueAction
            self.onManualScroll = onManualScroll
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
        event.preventDefault();
        activate(heading);
      });
      document.addEventListener('keydown', (event) => {
        if ((event.key === 'Enter' || event.key === ' ')
            && event.target instanceof Element
            && event.target.matches(selector)) {
          event.preventDefault();
          activate(event.target);
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
