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
            configuration: configuration,
            includesSourceMetadata: false
        )
    }

    static func editorHTMLFragment(
        for markdown: String,
        configuration: PreviewAppearanceConfiguration = .default
    ) throws -> String {
        try coreHTMLFragment(
            for: markdown,
            configuration: configuration,
            includesSourceMetadata: true
        )
    }

    private static func coreHTMLFragment(
        for markdown: String,
        configuration: PreviewAppearanceConfiguration,
        includesSourceMetadata: Bool
    ) throws -> String {
        let utf8 = Data(markdown.utf8)
        let result: InflowEncodeResult = utf8.withUnsafeBytes { buffer in
            if includesSourceMetadata {
                inflow_markdown_render_editor_html_with_options(
                    buffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(buffer.count),
                    configuration.coreRenderOptions
                )
            } else {
                inflow_markdown_render_html_with_options(
                    buffer.bindMemory(to: UInt8.self).baseAddress,
                    UInt(buffer.count),
                    configuration.coreRenderOptions
                )
            }
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

    static func htmlDocument(
        for markdown: String,
        documentDirectory: URL? = nil,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        configuration: PreviewAppearanceConfiguration = .default,
        navigationHeadings: [DocumentHeading] = []
    ) -> String {
        previewDocument(
            for: markdown,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            configuration: configuration,
            navigationHeadings: navigationHeadings
        ).html
    }

    static func editableHTMLDocument(
        for markdown: String,
        configuration: PreviewAppearanceConfiguration = .default
    ) -> String {
        previewDocument(
            for: markdown,
            documentDirectory: nil,
            configuration: configuration,
            navigationHeadings: [],
            fragmentRenderer: editorHTMLFragment
        ).html
    }

    static func previewDocument(
        for markdown: String,
        documentDirectory: URL? = nil,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        configuration: PreviewAppearanceConfiguration = .default,
        navigationHeadings: [DocumentHeading] = []
    ) -> MarkdownPreviewDocument {
        previewDocument(
            for: markdown,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            configuration: configuration,
            navigationHeadings: navigationHeadings,
            fragmentRenderer: htmlFragment
        )
    }

    static func editablePreviewDocument(
        for markdown: String,
        documentDirectory: URL?,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?,
        requiresProjectBoundary: Bool,
        configuration: PreviewAppearanceConfiguration,
        navigationHeadings: [DocumentHeading]
    ) -> MarkdownPreviewDocument {
        previewDocument(
            for: markdown,
            documentDirectory: documentDirectory,
            projectRoot: projectRoot,
            expectedProjectRootIdentity: expectedProjectRootIdentity,
            requiresProjectBoundary: requiresProjectBoundary,
            configuration: configuration,
            navigationHeadings: navigationHeadings,
            fragmentRenderer: editorHTMLFragment
        )
    }

    static func previewDocument(
        for markdown: String,
        documentDirectory: URL?,
        projectRoot: URL? = nil,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity? = nil,
        requiresProjectBoundary: Bool = false,
        configuration: PreviewAppearanceConfiguration,
        navigationHeadings: [DocumentHeading],
        fragmentRenderer: (String, PreviewAppearanceConfiguration) throws -> String
    ) -> MarkdownPreviewDocument {
        do {
            let fragment = try fragmentRenderer(markdown, configuration)
            let references = try MarkdownReferenceScanner.references(in: markdown)
            return previewDocument(
                coreFragment: fragment,
                references: references,
                documentDirectory: documentDirectory,
                projectRoot: projectRoot,
                expectedProjectRootIdentity: expectedProjectRootIdentity,
                requiresProjectBoundary: requiresProjectBoundary,
                configuration: configuration,
                navigationHeadings: navigationHeadings
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? MarkdownRenderError.coreFailure.localizedDescription
            return MarkdownPreviewDocument(
                html: errorDocument(configuration: configuration),
                failureMessage: message,
                hasRelativeResources: false
            )
        }
    }

    static func previewDocument(
        coreFragment: String,
        references: [MarkdownReference],
        documentDirectory: URL?,
        projectRoot: URL?,
        expectedProjectRootIdentity: FolderProjectDirectoryIdentity?,
        requiresProjectBoundary: Bool,
        configuration: PreviewAppearanceConfiguration,
        navigationHeadings: [DocumentHeading]
    ) -> MarkdownPreviewDocument {
        let headingFragment = PreviewNavigationMarkup.annotateHeadings(
            in: coreFragment,
            headings: navigationHeadings
        )
        let linkTargets = references.filter { $0.kind == .link }.map(\.target)
        let fragment = PreviewNavigationMarkup.annotateLinks(
            in: headingFragment,
            targets: linkTargets
        )
        return MarkdownPreviewDocument(
            html: document(
                containing: LocalImageResolver.resolveSlots(
                    in: fragment,
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
        """
        <!doctype html>
        <html lang="zh-Hans">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'">
          <style>
            :root { color-scheme: light dark; font: 17px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; }
            body { box-sizing: border-box; max-width: 760px; margin: 0 auto; padding: 32px 36px 72px; color: #24292f; background: #ffffff; overflow-wrap: break-word; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.28; margin: 1.45em 0 .55em; }
            h1[data-inflow-source-start], h2[data-inflow-source-start], h3[data-inflow-source-start], h4[data-inflow-source-start], h5[data-inflow-source-start], h6[data-inflow-source-start] { cursor: pointer; }
            h1, h2 { border-bottom: 1px solid #d8dee4; padding-bottom: .28em; }
            h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
            a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
            blockquote { margin: 1em 0; padding: .15em 1em; color: #57606a; border-left: 4px solid #d0d7de; }
            code { font: .88em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; background: #afb8c133; border-radius: 5px; padding: .16em .34em; }
            pre { overflow: auto; padding: 16px; background: #f6f8fa; border-radius: 8px; }
            pre code { padding: 0; background: transparent; }
            .tok-keyword { color: #cf222e; font-weight: 600; }
            .tok-type { color: #8250df; }
            .tok-string { color: #0a3069; }
            .tok-number, .tok-literal { color: #0550ae; }
            .tok-comment { color: #57606a; font-style: italic; }
            .tok-tag { color: #116329; }
            table { width: 100%; border-collapse: collapse; display: block; overflow-x: auto; }
            th, td { border: 1px solid #d0d7de; padding: 7px 12px; }
            tr:nth-child(even) { background: #f6f8fa; }
            img { max-width: 100%; height: auto; }
            .image-warning { display: flex; flex-direction: column; gap: .2em; margin: 1em 0; padding: 12px 14px; border: 1px solid #d4a72c; border-radius: 8px; color: #9a6700; }
            .image-warning span { font-size: .9em; }
            .image-warning-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
            .image-warning-actions button { font: inherit; color: inherit; border: 1px solid currentColor; border-radius: 6px; background: transparent; padding: 5px 9px; cursor: pointer; }
            hr { height: 1px; border: 0; background: #d8dee4; margin: 2em 0; }
            math { font-family: STIX Two Math, STIXGeneral, serif; }
            math[display="block"] { display: block; max-width: 100%; overflow-x: auto; margin: 1.2em 0; text-align: center; }
            .math-error { border: 1px solid #d4a72c; border-radius: 8px; padding: 12px 14px; color: #9a6700; }
            .math-error-inline { display: inline-flex; flex-wrap: wrap; align-items: baseline; gap: .35em; margin: 0 .15em; }
            .math-error pre { margin: 10px 0 0; }
            .math-error-inline code { max-width: 100%; overflow-wrap: anywhere; }
            .math-error-actions { display: flex; gap: 8px; margin-top: 10px; }
            .math-error-inline .math-error-actions { display: inline-flex; margin-top: 0; }
            .math-error-actions button { font: inherit; color: inherit; border: 1px solid currentColor; border-radius: 6px; background: transparent; padding: 5px 9px; cursor: pointer; }
            .mermaid-diagram { margin: 1.4em 0; overflow-x: auto; }
            .mermaid-diagram svg { min-width: 420px; width: 100%; height: auto; color: currentColor; }
            .mermaid-diagram .node rect { fill: #f6f8fa; stroke: #57606a; stroke-width: 1.5; }
            .mermaid-diagram text { fill: currentColor; font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
            .mermaid-error { border: 1px solid #d4a72c; border-radius: 8px; padding: 12px 14px; color: #9a6700; }
            .mermaid-error-actions { display: flex; gap: 8px; margin-top: 10px; }
            .mermaid-error-actions button { font: inherit; color: inherit; border: 1px solid currentColor; border-radius: 6px; background: transparent; padding: 5px 9px; cursor: pointer; }
            .task-list-item { list-style: none; } input[type="checkbox"] { margin: 0 .45em 0 -1.35em; }
            body[data-inflow-editable="true"] [data-inflow-source-start] { transition: outline-color 120ms ease, background-color 120ms ease; }
            body[data-inflow-editable="true"] [data-inflow-source-start]:hover { outline: 2px solid color-mix(in srgb, #0969da 28%, transparent); outline-offset: 4px; cursor: text; }
            body[data-inflow-editable="true"] [data-inflow-editing="true"] { outline: 2px solid #0969da; outline-offset: 5px; }
            [contenteditable="true"] { caret-color: currentColor; }
            .inflow-source-block-editor { box-sizing: border-box; display: block; width: 100%; min-height: 8em; resize: vertical; border: 0; outline: 0; margin: 0; padding: 14px; color: inherit; background: #f6f8fa; font: 14px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; tab-size: 4; }
            .preview-error { margin-top: 30vh; text-align: center; color: #9a6700; }
            @media (prefers-color-scheme: dark) {
              body { color: #e6edf3; background: #0d1117; }
              h1, h2, th, td { border-color: #30363d; }
              a { color: #58a6ff; }
              blockquote { color: #8b949e; border-color: #3b434b; }
              pre, tr:nth-child(even) { background: #161b22; }
              code { background: #6e768166; }
              .tok-keyword { color: #ff7b72; }
              .tok-type { color: #d2a8ff; }
              .tok-string { color: #a5d6ff; }
              .tok-number, .tok-literal { color: #79c0ff; }
              .tok-comment { color: #8b949e; }
              .tok-tag { color: #7ee787; }
              hr { background: #30363d; }
              .mermaid-diagram .node rect { fill: #161b22; stroke: #8b949e; }
              .math-error { color: #d29922; border-color: #9e6a03; }
              .mermaid-error { color: #d29922; border-color: #9e6a03; }
              .image-warning { color: #d29922; border-color: #9e6a03; }
              .inflow-source-block-editor { background: #161b22; }
            }
          </style>
          \(PreviewAppearanceCSS.styleElement(for: configuration))
        </head>
        <body>
        \(fragment)
        </body>
        </html>
        """
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

enum PreviewNavigationMarkup {
    private static let maximumLinkTargetBytes = 16 * 1_024

    static func annotateHeadings(
        in fragment: String,
        headings: [DocumentHeading]
    ) -> String {
        guard !headings.isEmpty,
              let headingPattern = try? NSRegularExpression(pattern: #"<h([1-6])([^>]*)>"#)
        else {
            return fragment
        }
        let fullRange = NSRange(location: 0, length: (fragment as NSString).length)
        let matches = headingPattern.matches(in: fragment, range: fullRange)
        guard matches.count == headings.count else { return fragment }

        for (match, heading) in zip(matches, headings) {
            guard match.numberOfRanges == 3,
                  let levelRange = Range(match.range(at: 1), in: fragment),
                  Int(fragment[levelRange]) == heading.level
            else {
                return fragment
            }
        }

        let identifiers = HeadingIdentifier.identifiers(for: headings)
        let result = NSMutableString(string: fragment)
        for ((match, heading), identifier) in zip(zip(matches, headings), identifiers).reversed() {
            let attributes = (fragment as NSString).substring(with: match.range(at: 2))
            let sourceAttribute = attributes.contains("data-inflow-source-start=")
                ? ""
                : " data-inflow-source-start=\"\(heading.sourceUTF8Range.lowerBound)\""
            result.replaceCharacters(
                in: match.range,
                with: "<h\(heading.level) id=\"\(escapeHTMLAttribute(identifier))\"\(sourceAttribute) tabindex=\"0\" title=\"在源码中定位\"\(attributes)>"
            )
        }
        return result as String
    }

    static func annotateLinks(in fragment: String, targets: [String]) -> String {
        guard !targets.isEmpty,
              let linkPattern = try? NSRegularExpression(pattern: #"<a href=\"([^\"]*)\""#)
        else {
            return fragment
        }
        let source = fragment as NSString
        let fullRange = NSRange(location: 0, length: (fragment as NSString).length)
        let matches = linkPattern.matches(in: fragment, range: fullRange)
        var selectedMatches: [(NSTextCheckingResult, String)] = []
        var searchIndex = 0
        for target in targets {
            guard let renderedTarget = URL(string: target)?.relativeString else { return fragment }
            let expectedHref = escapeHTMLAttribute(renderedTarget)
            var selected: NSTextCheckingResult?
            while searchIndex < matches.count {
                let candidate = matches[searchIndex]
                searchIndex += 1
                guard candidate.numberOfRanges == 2,
                      source.substring(with: candidate.range(at: 1)) == expectedHref,
                      !isGeneratedFootnoteAnchor(candidate, in: source)
                else {
                    continue
                }
                selected = candidate
                break
            }
            guard let selected else { return fragment }
            selectedMatches.append((selected, target))
        }

        let result = NSMutableString(string: fragment)
        for (match, target) in selectedMatches.reversed() {
            guard target.utf8.count <= maximumLinkTargetBytes,
                  !target.unicodeScalars.contains(where: { scalar in
                      CharacterSet.controlCharacters.contains(scalar)
                  })
            else {
                continue
            }
            let original = result.substring(with: match.range)
            let targetHex = Data(target.utf8).map { String(format: "%02x", $0) }.joined()
            result.replaceCharacters(
                in: match.range,
                with: "\(original) data-inflow-link-target-hex=\"\(targetHex)\""
            )
        }
        return result as String
    }

    private static func isGeneratedFootnoteAnchor(
        _ match: NSTextCheckingResult,
        in source: NSString
    ) -> Bool {
        let marker = #"<sup class="footnote-reference">"#
        let start = max(0, match.range.location - (marker as NSString).length)
        let prefix = source.substring(
            with: NSRange(location: start, length: match.range.location - start)
        )
        return prefix.hasSuffix(marker)
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum PreviewAppearanceCSS {
    static func styleElement(for configuration: PreviewAppearanceConfiguration) -> String {
        let width = decimal(configuration.contentWidth)
        let fontSize = decimal(17 * configuration.zoom)
        let themeRules: String = switch configuration.theme {
        case .standard:
            ""
        case .longform:
            "body { font-family: ui-serif, Georgia, 'Songti SC', serif; line-height: 1.82; }"
        case .code:
            "body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.58; } h1, h2, h3, h4, h5, h6 { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }"
        case .highContrast:
            highContrastRules
        }

        let colorRules: String = switch configuration.colorScheme {
        case .system:
            ":root { color-scheme: light dark; }"
        case .light:
            ":root { color-scheme: light; } body { color: #111111; background: #ffffff; } h1, h2, th, td { border-color: #767676; } a { color: #004ea8; } blockquote { color: #333333; border-color: #606060; } pre, tr:nth-child(even) { background: #f1f1f1; } code { background: #d8d8d866; } \(syntaxLightRules)"
        case .dark:
            ":root { color-scheme: dark; } body { color: #f2f2f2; background: #101214; } h1, h2, th, td { border-color: #8a8a8a; } a { color: #78b7ff; } blockquote { color: #d0d0d0; border-color: #a0a0a0; } pre, tr:nth-child(even) { background: #202428; } code { background: #ffffff24; } \(syntaxDarkRules)"
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

    private static let syntaxLightRules =
        ".tok-keyword { color: #cf222e; } .tok-type { color: #8250df; } .tok-string { color: #0a3069; } .tok-number, .tok-literal { color: #0550ae; } .tok-comment { color: #57606a; } .tok-tag { color: #116329; }"

    private static let syntaxDarkRules =
        ".tok-keyword { color: #ff7b72; } .tok-type { color: #d2a8ff; } .tok-string { color: #a5d6ff; } .tok-number, .tok-literal { color: #79c0ff; } .tok-comment { color: #8b949e; } .tok-tag { color: #7ee787; }"

    private static let highContrastRules =
        "body { color: CanvasText; background: Canvas; } a { color: LinkText; text-decoration: underline; text-decoration-thickness: 2px; } h1, h2, th, td, blockquote { border-color: currentColor; } .tok-keyword, .tok-type, .tok-string, .tok-number, .tok-literal, .tok-comment, .tok-tag { color: currentColor; } .tok-keyword, .tok-type { font-weight: 700; } .tok-comment { text-decoration: underline dotted; } :focus-visible { outline: 3px solid currentColor; outline-offset: 3px; }"

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
