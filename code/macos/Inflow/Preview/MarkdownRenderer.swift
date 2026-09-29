import Foundation

enum MarkdownRenderError: Error, Equatable, LocalizedError {
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

enum PreviewFailurePrompt {
    static let title = "暂时无法更新预览"
    static let message = "编辑和保存仍可用。"
    static let retryTitle = "重试预览"
    static let hideTitle = "隐藏预览"
}

struct MarkdownPreviewDocument: Equatable, Sendable {
    let html: String
    let failureMessage: String?
    let hasRelativeResources: Bool
}

enum MarkdownRenderer {
    static func htmlFragment(
        for markdown: String,
        configuration: PreviewAppearanceConfiguration = .default
    ) throws -> String {
        try coreHTMLFragment(
            for: markdown,
            configuration: configuration
        )
    }

    private static func coreHTMLFragment(
        for markdown: String,
        configuration: PreviewAppearanceConfiguration
    ) throws -> String {
        guard let derived = EditorEngineDerivedContent.deriveSynchronously(
            source: markdown,
            configuration: configuration
        ), let html = derived.htmlFragment
        else { throw MarkdownRenderError.coreFailure }
        return html
    }

    static func htmlDocument(
        for markdown: String,
        documentDirectory: URL? = nil,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        configuration: PreviewAppearanceConfiguration = .default
    ) -> String {
        previewDocument(
            for: markdown,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            configuration: configuration
        ).html
    }

    static func previewDocument(
        for markdown: String,
        documentDirectory: URL? = nil,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        configuration: PreviewAppearanceConfiguration = .default
    ) -> MarkdownPreviewDocument {
        guard let derived = EditorEngineDerivedContent.deriveSynchronously(
            source: markdown,
            configuration: configuration
        ), let previewHTML = derived.previewHTMLFragment
        else {
            return previewFailureDocument(configuration: configuration)
        }
        return previewDocument(
            coreFragment: previewHTML,
            references: derived.references,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            configuration: configuration
        )
    }

    static func previewDocument(
        coreFragment: String,
        references: [MarkdownReference],
        documentDirectory: URL?,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?,
        requiresProjectBoundary: Bool,
        configuration: PreviewAppearanceConfiguration
    ) -> MarkdownPreviewDocument {
        return MarkdownPreviewDocument(
            html: document(
                containing: LocalImageResolver.resolveSlots(
                    in: coreFragment,
                    documentDirectory: documentDirectory,
                    imageReferences: references.filter { $0.kind == .image },
                    projectRoot: projectRoot,
                    expectedProjectRootIdentity: expectedProjectRootIdentity,
                    requiresProjectBoundary: requiresProjectBoundary
                ),
                configuration: configuration
            ),
            failureMessage: nil,
            hasRelativeResources: RelativeResourceDirectoryPolicy.hasRelativeResources(
                in: references
            )
        )
    }

    static func document(
        containing fragment: String,
        configuration: PreviewAppearanceConfiguration = .default
    ) -> String {
        let html = """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'">
          <style>
            :root {
              color-scheme: light dark;
              font: \(MarkdownRenderMetrics.bodyFontSize)px/\(MarkdownRenderMetrics.bodyLineHeight) \(MarkdownRenderMetrics.bodyFontFamilyCSS);
              \(MarkdownRenderPalette.light.cssVariables)
            }
            *, *::before, *::after { box-sizing: border-box; }
            html { min-height: 100%; background: var(--md-canvas); }
            body {
              max-width: \(MarkdownRenderMetrics.readingWidth)px;
              min-height: 100vh;
              margin: 0 auto;
              padding: 32px 36px 72px;
              color: var(--md-text);
              background: var(--md-canvas);
              overflow-wrap: break-word;
              text-rendering: optimizeLegibility;
            }
            body > :first-child { margin-top: 0 !important; }
            body > :last-child { margin-bottom: 0 !important; }
            p { margin: .8em 0; }
            strong { color: var(--md-heading); font-weight: 650; }
            h1, h2, h3, h4, h5, h6 {
              color: var(--md-heading);
              line-height: 1.4;
              letter-spacing: normal;
              font-weight: bold;
            }
            h1[data-inflow-source-start], h2[data-inflow-source-start], h3[data-inflow-source-start], h4[data-inflow-source-start], h5[data-inflow-source-start], h6[data-inflow-source-start] { cursor: pointer; }
            h1, h2 { border-bottom: 1px solid var(--md-border); padding-bottom: .24em; }
            h1 { line-height: \(MarkdownRenderMetrics.headingLineHeight(level: 1)); font-size: \(MarkdownRenderMetrics.heading(level: 1).scale)em; margin: \(MarkdownRenderMetrics.heading(level: 1).spacingBefore)rem 0 \(MarkdownRenderMetrics.heading(level: 1).spacingAfter)rem; }
            h2 { line-height: \(MarkdownRenderMetrics.headingLineHeight(level: 2)); font-size: \(MarkdownRenderMetrics.heading(level: 2).scale)em; margin: \(MarkdownRenderMetrics.heading(level: 2).spacingBefore)rem 0 \(MarkdownRenderMetrics.heading(level: 2).spacingAfter)rem; }
            h3 { line-height: \(MarkdownRenderMetrics.headingLineHeight(level: 3)); font-size: \(MarkdownRenderMetrics.heading(level: 3).scale)em; margin: \(MarkdownRenderMetrics.heading(level: 3).spacingBefore)rem 0 \(MarkdownRenderMetrics.heading(level: 3).spacingAfter)rem; }
            h4 { line-height: \(MarkdownRenderMetrics.headingLineHeight(level: 4)); font-size: \(MarkdownRenderMetrics.heading(level: 4).scale)em; margin: \(MarkdownRenderMetrics.heading(level: 4).spacingBefore)rem 0 \(MarkdownRenderMetrics.heading(level: 4).spacingAfter)rem; }
            h5 { line-height: \(MarkdownRenderMetrics.headingLineHeight(level: 5)); font-size: \(MarkdownRenderMetrics.heading(level: 5).scale)em; margin: \(MarkdownRenderMetrics.heading(level: 5).spacingBefore)rem 0 \(MarkdownRenderMetrics.heading(level: 5).spacingAfter)rem; }
            h6 { line-height: \(MarkdownRenderMetrics.headingLineHeight(level: 6)); font-size: \(MarkdownRenderMetrics.heading(level: 6).scale)em; margin: \(MarkdownRenderMetrics.heading(level: 6).spacingBefore)rem 0 \(MarkdownRenderMetrics.heading(level: 6).spacingAfter)rem; color: var(--md-secondary); }
            a { color: var(--md-accent); text-decoration: none; text-underline-offset: .16em; cursor: pointer; }
            a:hover { text-decoration: underline; background: transparent; }
            a:focus-visible, button:focus-visible, input:focus-visible { outline: 2px solid var(--md-accent); outline-offset: 3px; }
            blockquote { margin: .85em 0; padding: .08em 0 .08em 1em; color: var(--md-secondary); border-left: 4px solid var(--md-quote-bar); line-height: inherit; }
            blockquote > :first-child { margin-top: 0; } blockquote > :last-child { margin-bottom: 0; }
            ul, ol { margin: .65em 0; padding-left: 1.7em; }
            li { margin: \(MarkdownRenderMetrics.listItemGap / CGFloat(MarkdownRenderMetrics.bodyFontSize))em 0; padding-left: .1em; }
            li > p { margin: .35em 0; }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace; font-size: \(MarkdownRenderMetrics.inlineCodeScale)em; line-height: inherit; background: var(--md-inline-code); border-radius: 4px; padding: 0; }
            pre { margin: 1em 0; overflow: auto; padding: 15px 16px; color: var(--md-text); background: var(--md-surface); border: 1px solid var(--md-border); border-radius: \(MarkdownRenderMetrics.blockCornerRadius)px; line-height: \(MarkdownRenderMetrics.codeBlockLineHeight); }
            pre code { padding: 0; background: transparent; }
            .tok-keyword { color: var(--md-keyword); font-weight: 600; }
            .tok-type { color: var(--md-type); }
            .tok-string { color: var(--md-string); }
            .tok-number, .tok-literal { color: var(--md-number); }
            .tok-comment { color: var(--md-comment); font-style: italic; }
            .tok-tag { color: var(--md-tag); }
            table { width: 100%; margin: 1em 0; border: 1px solid var(--md-border); border-collapse: separate; border-spacing: 0; border-radius: \(MarkdownRenderMetrics.blockCornerRadius)px; display: block; overflow-x: auto; }
            th, td { min-width: 7em; padding: \(MarkdownRenderMetrics.tableCellVerticalPadding)px \(MarkdownRenderMetrics.tableCellHorizontalPadding)px; border-right: 1px solid var(--md-border); border-bottom: 1px solid var(--md-border); text-align: left; vertical-align: top; }
            tr > :last-child { border-right: 0; }
            tbody tr:last-child > td { border-bottom: 0; }
            thead { background: var(--md-surface-strong); } th { color: var(--md-heading); font-weight: 650; }
            tbody tr:nth-child(even) { background: var(--md-table-stripe); }
            img { display: block; max-width: 100%; height: auto; margin: 1.15em auto; border-radius: 4px; }
            .image-warning { display: flex; flex-direction: column; gap: .2em; margin: 1em 0; padding: 12px 14px; border: 1px solid var(--md-warning); border-radius: \(MarkdownRenderMetrics.blockCornerRadius)px; color: var(--md-warning); }
            .image-warning span { font-size: .9em; }
            .image-warning-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
            .image-warning-actions button { font: inherit; color: inherit; border: 1px solid currentColor; border-radius: 6px; background: transparent; padding: 5px 9px; cursor: pointer; }
            hr { height: 1px; border: 0; background: var(--md-border); margin: 2em 0; }
            math { font-family: STIX Two Math, STIXGeneral, serif; }
            math[display="block"] { display: block; max-width: 100%; overflow-x: auto; margin: 1.2em 0; text-align: center; }
            .math-error { border: 1px solid var(--md-warning); border-radius: \(MarkdownRenderMetrics.blockCornerRadius)px; padding: 12px 14px; color: var(--md-warning); }
            .math-error-inline { display: inline-flex; flex-wrap: wrap; align-items: baseline; gap: .35em; margin: 0 .15em; }
            .math-error pre { margin: 10px 0 0; }
            .math-error-inline code { max-width: 100%; overflow-wrap: anywhere; }
            .math-error-actions { display: flex; gap: 8px; margin-top: 10px; }
            .math-error-inline .math-error-actions { display: inline-flex; margin-top: 0; }
            .math-error-actions button { font: inherit; color: inherit; border: 1px solid currentColor; border-radius: 6px; background: transparent; padding: 5px 9px; cursor: pointer; }
            .inflow-math svg { max-width: 100%; height: auto; }
            div.inflow-math { margin: 1.2em 0; text-align: center; overflow-x: auto; }
            .mermaid-diagram { margin: 1.4em 0; overflow-x: auto; text-align: center; }
            .mermaid-diagram svg { display: block; max-width: 100%; height: auto; margin: 0 auto; }
            .mermaid-error { border: 1px solid var(--md-warning); border-radius: \(MarkdownRenderMetrics.blockCornerRadius)px; padding: 12px 14px; color: var(--md-warning); }
            .mermaid-error-actions { display: flex; gap: 8px; margin-top: 10px; }
            .mermaid-error-actions button { font: inherit; color: inherit; border: 1px solid currentColor; border-radius: 6px; background: transparent; padding: 5px 9px; cursor: pointer; }
            .task-list-item { list-style: none; } input[type="checkbox"] { margin: 0 .45em 0 -1.35em; accent-color: var(--md-accent); }
            .preview-error { margin-top: 30vh; text-align: center; color: var(--md-warning); }
            ::selection { color: var(--md-heading); background: color-mix(in srgb, var(--md-accent) 22%, transparent); }
            @media (prefers-color-scheme: dark) {
              :root { \(MarkdownRenderPalette.dark.cssVariables) }
            }
            @media (max-width: 640px) { body { padding: 24px 20px 56px; } }
          </style>
          \(PreviewAppearanceCSS.styleElement(for: configuration))
        </head>
        <body id="write">
        \(fragment)
        </body>
        </html>
        """
        return (try? JavaScriptRenderAssets.installing(in: html)) ?? html
    }

    static func previewFailureDocument(
        configuration: PreviewAppearanceConfiguration = .default
    ) -> MarkdownPreviewDocument {
        MarkdownPreviewDocument(
            html: errorDocument(configuration: configuration),
            failureMessage: MarkdownRenderError.coreFailure.localizedDescription,
            hasRelativeResources: false
        )
    }

    private static func errorDocument(configuration: PreviewAppearanceConfiguration) -> String {
        return document(
            containing: """
            <section class="preview-error" role="status">
              <strong>\(PreviewFailurePrompt.title)</strong>
              <p>\(PreviewFailurePrompt.message)</p>
            </section>
            """,
            configuration: configuration
        )
    }
}

enum PreviewAppearanceCSS {
    static func styleElement(for configuration: PreviewAppearanceConfiguration) -> String {
        let width = decimal(configuration.contentWidth)
        let fontSize = decimal(configuration.fontSize * configuration.zoom)
        let theme = configuration.theme
        let scheme = theme.styles.value("color-scheme")
        let dark = scheme == "dark" || (scheme != "light" && configuration.colorScheme == .dark)
        let palette = theme.styles.applying(to: dark ? MarkdownRenderPalette.dark : .light)
        let themeRules = theme == .highContrast ? highContrastRules
            : ":root { \(palette.cssVariables) }\n" + theme.safeStyleContent

        let colorRules: String = switch configuration.colorScheme {
        case .system:
            ":root { color-scheme: light dark; }"
        case .light:
            ":root { color-scheme: light; \(MarkdownRenderPalette.light.cssVariables) }"
        case .dark:
            ":root { color-scheme: dark; \(MarkdownRenderPalette.dark.cssVariables) }"
        }

        let contrastRules = configuration.increasedContrast ? highContrastRules : ""
        let motionRules = configuration.reduceMotion
            ? "*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }"
            : ""

        return """
        <style id="inflow-user-appearance">
          :root { font-size: \(fontSize)px; }
          body { max-width: \(width)px; }
          \(colorRules)
          \(themeRules)
          body { font-size: \(fontSize)px; line-height: \(decimal(configuration.lineHeight)); }
          \(contrastRules)
          \(motionRules)
        </style>
        """
    }

    static func applying(
        _ configuration: PreviewAppearanceConfiguration,
        to html: String
    ) -> String {
        let style = styleElement(for: configuration)
        guard let headEnd = html.range(of: "</head>", options: [.caseInsensitive]) else {
            return style + html
        }
        var result = html
        result.insert(contentsOf: style + "\n", at: headEnd.lowerBound)
        return result
    }

    private static let highContrastRules =
        ":root { --md-canvas: Canvas; --md-text: CanvasText; --md-heading: CanvasText; --md-secondary: CanvasText; --md-accent: LinkText; --md-border: CanvasText; --md-quote-bar: CanvasText; --md-surface: Canvas; --md-surface-strong: Canvas; --md-table-stripe: Canvas; --md-inline-code: Canvas; --md-keyword: CanvasText; --md-type: CanvasText; --md-string: CanvasText; --md-number: CanvasText; --md-comment: CanvasText; --md-tag: CanvasText; --md-warning: CanvasText; } a { text-decoration: underline; text-decoration-thickness: 2px; } .tok-keyword, .tok-type { font-weight: 700; } .tok-comment { text-decoration: underline dotted; } :focus-visible { outline: 3px solid currentColor; outline-offset: 3px; }"

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
