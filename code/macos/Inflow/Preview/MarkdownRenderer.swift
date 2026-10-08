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
          \(ThemeStyleResources.css("html"))
          \(ThemeStyleResources.defaultCSS)
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
        func rules(dark: Bool) -> String {
            let styles = theme.resolved(dark: dark).styles
            let palette = styles.applying(to: dark ? MarkdownRenderPalette.dark : .light)
            let css = styles.snapshot.resolvedCSS.replacingOccurrences(of: "<", with: "\\3C ")
            return ":root { color-scheme: \(dark ? "dark" : "light"); \(palette.cssVariables) }\n" + css
        }
        let themeRules: String
        if theme.rawValue == PreviewTheme.highContrast.rawValue {
            themeRules = highContrastRules
        } else {
            switch configuration.colorScheme {
            case .system:
                themeRules = rules(dark: false) + "\n@media (prefers-color-scheme: dark) {\n" + rules(dark: true) + "\n}"
            case .light: themeRules = rules(dark: false)
            case .dark: themeRules = rules(dark: true)
            }
        }
        let colorRules = ":root { color-scheme: \(configuration.colorScheme == .system ? "light dark" : configuration.colorScheme.rawValue); }"

        let contrastRules = configuration.increasedContrast ? highContrastRules : ""
        let motionRules = configuration.reduceMotion
            ? ThemeStyleResources.css("reduced-motion")
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

    private static let highContrastRules = ThemeStyleResources.css("html-contrast")

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
