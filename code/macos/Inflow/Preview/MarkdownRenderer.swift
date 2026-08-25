import Foundation

enum MarkdownRenderError: Error, LocalizedError {
    case invalidUTF8
    case coreFailure

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "预览输入不是有效的 UTF-8 文本。"
        case .coreFailure:
            "Markdown 预览暂时无法更新，但仍可继续编辑和保存。"
        }
    }
}

enum MarkdownRenderer {
    static func htmlFragment(for markdown: String) throws -> String {
        let utf8 = Data(markdown.utf8)
        let result: InflowEncodeResult = utf8.withUnsafeBytes { buffer in
            inflow_markdown_render_html(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count)
            )
        }
        guard result.status == INFLOW_STATUS_OK else {
            if result.status == INFLOW_STATUS_INVALID_UTF8 {
                throw MarkdownRenderError.invalidUTF8
            }
            throw MarkdownRenderError.coreFailure
        }

        let htmlData: Data
        do {
            htmlData = try InflowCoreBridge.copyAndFree(result.bytes)
        } catch {
            throw MarkdownRenderError.coreFailure
        }
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw MarkdownRenderError.coreFailure
        }
        return html
    }

    static func htmlDocument(for markdown: String) -> String {
        do {
            return document(containing: try htmlFragment(for: markdown))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? MarkdownRenderError.coreFailure.localizedDescription
            return errorDocument(message: message)
        }
    }

    static func document(containing fragment: String) -> String {
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'">
          <style>
            :root { color-scheme: light dark; font: 17px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; }
            body { box-sizing: border-box; max-width: 760px; margin: 0 auto; padding: 32px 36px 72px; color: #24292f; background: #ffffff; overflow-wrap: break-word; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.28; margin: 1.45em 0 .55em; }
            h1, h2 { border-bottom: 1px solid #d8dee4; padding-bottom: .28em; }
            h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
            a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
            blockquote { margin: 1em 0; padding: .15em 1em; color: #57606a; border-left: 4px solid #d0d7de; }
            code { font: .88em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; background: #afb8c133; border-radius: 5px; padding: .16em .34em; }
            pre { overflow: auto; padding: 16px; background: #f6f8fa; border-radius: 8px; }
            pre code { padding: 0; background: transparent; }
            table { width: 100%; border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: 1px solid #d0d7de; padding: 7px 12px; }
            tr:nth-child(even) { background: #f6f8fa; }
            img { max-width: 100%; height: auto; }
            hr { height: 1px; border: 0; background: #d8dee4; margin: 2em 0; }
            math { font-family: STIX Two Math, STIXGeneral, serif; }
            math[display="block"] { display: block; max-width: 100%; overflow-x: auto; margin: 1.2em 0; text-align: center; }
            .task-list-item { list-style: none; } input[type="checkbox"] { margin: 0 .45em 0 -1.35em; }
            .preview-error { margin-top: 30vh; text-align: center; color: #9a6700; }
            @media (prefers-color-scheme: dark) {
              body { color: #e6edf3; background: #0d1117; }
              h1, h2, th, td { border-color: #30363d; }
              a { color: #58a6ff; }
              blockquote { color: #8b949e; border-color: #3b434b; }
              pre, tr:nth-child(even) { background: #161b22; }
              code { background: #6e768166; }
              hr { background: #30363d; }
            }
          </style>
        </head>
        <body>
        \(fragment)
        </body>
        </html>
        """
    }

    private static func errorDocument(message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return document(containing: "<p class=\"preview-error\">\(escaped)</p>")
    }
}
