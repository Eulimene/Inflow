import SwiftUI
import WebKit

struct PreviewScrollRequest: Equatable {
    let generation: Int
    let fraction: Double
}

enum PreviewNavigationMessage: Equatable {
    case heading(sourceUTF8Offset: Int)
    case manualScroll

    static func decode(_ body: Any) -> Self? {
        guard let dictionary = body as? [String: Any],
              let type = dictionary["type"] as? String
        else {
            return nil
        }
        switch type {
        case "heading":
            guard let number = dictionary["sourceUTF8Offset"] as? NSNumber else { return nil }
            let value = number.doubleValue
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  value.isFinite,
                  value >= 0,
                  value <= 9_007_199_254_740_991,
                  value.rounded(.towardZero) == value
            else {
                return nil
            }
            return .heading(sourceUTF8Offset: Int(value))
        case "manualScroll":
            return .manualScroll
        default:
            return nil
        }
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    private static let messageHandlerName = "inflowPreviewNavigation"

    let html: String
    let baseURL: URL?
    let scrollRequest: PreviewScrollRequest?
    let onHeadingActivated: (Int) -> Void
    let onManualScroll: () -> Void

    init(
        html: String,
        baseURL: URL?,
        scrollRequest: PreviewScrollRequest? = nil,
        onHeadingActivated: @escaping (Int) -> Void = { _ in },
        onManualScroll: @escaping () -> Void = {}
    ) {
        self.html = html
        self.baseURL = baseURL
        self.scrollRequest = scrollRequest
        self.onHeadingActivated = onHeadingActivated
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
            onManualScroll: onManualScroll,
            webView: webView
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            scrollRequest: scrollRequest,
            onHeadingActivated: onHeadingActivated,
            onManualScroll: onManualScroll,
            webView: webView
        )
        let htmlChanged = context.coordinator.lastHTML.map {
            !UTF8Text.isExactlyEqual($0, html)
        } ?? true
        guard htmlChanged || context.coordinator.lastBaseURL != baseURL else {
            return
        }

        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.willLoadDocument()
        // All accepted local images have already been validated and converted
        // to data URLs. Never give WebKit a filesystem origin or read scope.
        webView.loadHTMLString(html, baseURL: nil)
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
        coordinator.willLoadDocument()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String?
        var lastBaseURL: URL?
        private var requestedScroll: PreviewScrollRequest?
        private var appliedScrollGeneration: Int?
        private var isDocumentLoaded = false
        private var onHeadingActivated: (Int) -> Void = { _ in }
        private var onManualScroll: () -> Void = {}

        func update(
            scrollRequest: PreviewScrollRequest?,
            onHeadingActivated: @escaping (Int) -> Void,
            onManualScroll: @escaping () -> Void,
            webView: WKWebView
        ) {
            requestedScroll = scrollRequest
            self.onHeadingActivated = onHeadingActivated
            self.onManualScroll = onManualScroll
            applyScrollIfPossible(to: webView)
        }

        func willLoadDocument() {
            isDocumentLoaded = false
            appliedScrollGeneration = nil
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
            isDocumentLoaded = true
            applyScrollIfPossible(to: webView)
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
            case .manualScroll:
                onManualScroll()
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }

            let scheme = navigationAction.request.url?.scheme
            decisionHandler(
                scheme == nil || scheme == "about" || scheme == "data"
                    ? .allow
                    : .cancel
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
        const heading = headingFor(event.target);
        if (!heading || (event.target instanceof Element && event.target.closest('a'))) {
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
