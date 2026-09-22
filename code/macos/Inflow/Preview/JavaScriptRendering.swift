import AppKit
import WebKit

struct JavaScriptRenderRequest: Equatable, Sendable {
    let sourceRange: RenderedMarkdownSourceRange
    let contentRange: RenderedMarkdownSourceRange
    let kind: String
    let language: String
    let source: String
    let display: Bool
    var dark = false

    var cacheKey: String { "\(kind)\u{0}\(language)\u{0}\(display)\u{0}\(dark)\u{0}\(source)" }
    var arguments: [String: Any] {
        ["kind": kind, "language": language, "source": source, "display": display, "dark": dark]
    }
}

struct JavaScriptRenderedOutput: Decodable, Sendable {
    struct Token: Decodable, Sendable {
        let start: Int
        let end: Int
        let kind: String
    }
    let svg: String?
    let width: Int?
    let height: Int?
    let html: String?
    let tokens: [Token]?
    var pdfData: Data? = nil
}

enum JavaScriptRenderingError: Error {
    case missingResource(String)
    case invalidResult
    case timeout
    case processTerminated
}

/// Trusted, versioned scripts are bundled with the app. Markdown is always passed as data.
enum JavaScriptRenderAssets {
    static let scripts = [
        "codemirror-runmode", "codemirror-simple", "codemirror-meta",
        "codemirror-javascript", "codemirror-python", "codemirror-rust", "codemirror-swift",
        "codemirror-clike", "codemirror-shell", "codemirror-sql", "codemirror-css",
        "codemirror-xml", "codemirror-htmlmixed", "codemirror-yaml", "codemirror-markdown",
        "codemirror-stex", "codemirror-go", "codemirror-properties",
        "raphael.min", "underscore.min", "snap.svg.min", "webfontloader",
        "flowchart", "sequence-diagram.min", "mermaid.min", "mathjax-tex-svg", "render-adapters"
    ]

    private static let bundledScripts: Result<String, Error> = Result {
        var bundle = Bundle(for: JavaScriptRenderWorker.self)
        // A direct XCTest loader places the host dylib inside its test bundle.
        // Resolve the enclosing application bundle there, just as in an app-hosted run.
        var parent = bundle.bundleURL
        while bundle.url(forResource: "JavaScript", withExtension: nil) == nil && parent.path != "/" {
            parent.deleteLastPathComponent()
            if parent.pathExtension == "app", let application = Bundle(url: parent) {
                bundle = application
                break
            }
        }
        return try scripts.map { name in
            guard let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "JavaScript")
            else { throw JavaScriptRenderingError.missingResource(name) }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw JavaScriptRenderingError.invalidResult }
            return text
        }.joined(separator: "\n;\n")
    }

    static func scriptElement(nonce: String, renderDocument: Bool) throws -> String {
        let configuration = """
        window.MathJax = {startup:{typeset:false}, svg:{fontCache:'none'},
          options:{enableMenu:false}, tex:{packages:['base','ams','newcommand','configmacros','color','bbox','boldsymbol','braket','cancel','mathtools'], maxBuffer:100000, maxMacros:1000}};
        """
        let code = configuration + (try bundledScripts.get())
            + (renderDocument ? "\nwindow.inflowRenderingReady = InflowRender.renderDocument();" : "")
        let safe = code.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        return "<script nonce=\"\(nonce)\">\(safe)</script>"
    }

    /// Export and HTML preview use the same adapters, with no CDN or network dependency.
    static func installing(in html: String) throws -> String {
        guard html.contains("data-inflow-render=") else { return html }
        let nonce = UUID().uuidString
        var result = html.replacingOccurrences(of: "script-src 'none';", with: "")
        result = result.replacingOccurrences(
            of: "default-src 'none';",
            with: "default-src 'none'; script-src 'nonce-\(nonce)';"
        )
        return result.replacingOccurrences(of: "</body>", with: try scriptElement(nonce: nonce, renderDocument: true) + "</body>")
    }
}

/// Serial execution avoids global-state collisions in Mermaid, Raphael and MathJax.
/// Only successful results enter the bounded cache, so failed blocks can be retried.
@MainActor
final class JavaScriptRenderService {
    static let shared = JavaScriptRenderService()
    private var cache: [String: JavaScriptRenderedOutput] = [:]
    private var order: [String] = []
    private var tail: Task<JavaScriptRenderedOutput, Error>?
    private let worker = JavaScriptRenderWorker()

    func render(_ request: JavaScriptRenderRequest) async throws -> JavaScriptRenderedOutput {
        try Task.checkCancellation()
        if let cached = cache[request.cacheKey] { return cached }
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            if let cached = self.cache[request.cacheKey] { return cached }
            let result = try await self.worker.render(request)
            self.cache[request.cacheKey] = result
            self.order.append(request.cacheKey)
            while self.order.count > 64 { self.cache.removeValue(forKey: self.order.removeFirst()) }
            return result
        }
        tail = task
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}

@MainActor
final class JavaScriptRenderWorker: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var navigationWaiter: CheckedContinuation<Void, Error>?
    private var renderWaiter: CheckedContinuation<JavaScriptRenderedOutput, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var generation = 0

    func render(_ request: JavaScriptRenderRequest) async throws -> JavaScriptRenderedOutput {
        guard request.source.utf16.count <= 100_000 else { throw JavaScriptRenderingError.invalidResult }
        generation += 1
        let current = generation
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.fail(JavaScriptRenderingError.timeout)
        }
        defer { timeoutTask?.cancel(); timeoutTask = nil }
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
            view.navigationDelegate = self
            webView = view
            let nonce = UUID().uuidString
            let script = try JavaScriptRenderAssets.scriptElement(nonce: nonce, renderDocument: false)
            let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'">
            <style>body{margin:0;background:white;color:#333;font-size:16px}svg{overflow:visible}</style>
            </head><body>\(script)</body></html>
            """
            try await withCheckedThrowingContinuation { continuation in
                navigationWaiter = continuation
                view.loadHTMLString(html, baseURL: nil)
            }
        }
        guard let view = webView else { throw JavaScriptRenderingError.processTerminated }
        return try await withCheckedThrowingContinuation { continuation in
            renderWaiter = continuation
            view.callAsyncJavaScript(
                "return JSON.stringify(await InflowRender.render(request));",
                arguments: ["request": request.arguments], in: nil, in: .page
            ) { [weak self] result in
                guard let self, self.generation == current, let waiter = self.renderWaiter else { return }
                do {
                    guard let json = try result.get() as? String else { throw JavaScriptRenderingError.invalidResult }
                    let output = try JSONDecoder().decode(JavaScriptRenderedOutput.self, from: Data(json.utf8))
                    if request.kind != "code" {
                        guard let svg = output.svg, let width = output.width, let height = output.height,
                              svg.hasPrefix("<svg"), width > 0, height > 0, width <= 16384, height <= 16384
                        else { throw JavaScriptRenderingError.invalidResult }
                    }
                    if ["mermaid", "flow", "sequence"].contains(request.kind), let svg = output.svg,
                       let width = output.width, let height = output.height {
                        // WebKit's vector PDF preserves SVG markers, which AppKit's SVG decoder ignores.
                        view.callAsyncJavaScript(
                            "document.body.innerHTML = svg; document.body.firstElementChild.style.display = 'block';",
                            arguments: ["svg": svg], in: nil, in: .page
                        ) { [weak self] mounted in
                            guard let self, self.generation == current, self.renderWaiter != nil else { return }
                            if case .failure(let error) = mounted { self.fail(error); return }
                            let config = WKPDFConfiguration()
                            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
                            view.createPDF(configuration: config) { [weak self] pdf in
                                guard let self, self.generation == current, let pending = self.renderWaiter else { return }
                                self.renderWaiter = nil
                                do {
                                    var complete = output
                                    complete.pdfData = try pdf.get()
                                    pending.resume(returning: complete)
                                } catch { pending.resume(throwing: error) }
                            }
                        }
                    } else {
                        self.renderWaiter = nil
                        waiter.resume(returning: output)
                    }
                } catch { self.renderWaiter = nil; waiter.resume(throwing: error) }
            }
        }
    }

    private func fail(_ error: Error) {
        navigationWaiter?.resume(throwing: error); navigationWaiter = nil
        renderWaiter?.resume(throwing: error); renderWaiter = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationWaiter?.resume(); navigationWaiter = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(JavaScriptRenderingError.processTerminated) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationWaiter != nil && navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

extension JavaScriptRenderService {
    func resolveDiagrams(in plan: RenderedMarkdownPlan, revision: UInt64, dark: Bool = false) async -> EditorEngineMermaidResolution? {
        var diagrams: [RenderedMarkdownMermaidDiagram] = []
        var failures: [RenderedMarkdownSourceRange] = []
        for request in plan.renderRequests where ["mermaid", "flow", "sequence"].contains(request.kind)
            && plan.mermaidDiagrams.contains(where: { $0.sourceRange == request.sourceRange }) {
            guard !Task.isCancelled else { return nil }
            do {
                var themed = request
                themed.dark = dark
                let result = try await render(themed)
                guard let svg = result.svg, let width = result.width, let height = result.height else {
                    throw JavaScriptRenderingError.invalidResult
                }
                diagrams.append(RenderedMarkdownMermaidDiagram(
                    sourceRange: request.sourceRange, svg: svg,
                    intrinsicWidth: width, intrinsicHeight: height, isPlaceholder: false, pdfData: result.pdfData
                ))
            } catch is CancellationError { return nil }
            catch { failures.append(request.sourceRange) }
        }
        return EditorEngineMermaidResolution(revision: revision, diagrams: diagrams, failedSourceRanges: failures)
    }
}
