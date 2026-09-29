import AppKit
import Combine
import XCTest
@testable import Inflow

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testCSSSelectionColorsReachNativeTextAndTableCells() async throws {
        let theme = PreviewTheme(id: "selection", label: "Selection", css: """
        :root { --selection-color: #abcdee; --md-selection-overlay: #11223355; }
        ::selection { background: #ffdddd; color: #112233; }
        #write::selection { background-color: var(--selection-color); }
        """)
        let palette = MarkdownRenderPalette.resolved(for: try XCTUnwrap(NSAppearance(named: .aqua)), theme: theme)
        XCTAssertEqual(palette.selectionBackground, "#abcdee")
        XCTAssertEqual(palette.selectionText, "#112233")
        XCTAssertEqual(palette.selectionOverlay, "#11223355")
        let source = "正文\n\n| A | B |\n| --- | --- |\n| one | two |"
        let editor = MarkdownSourceEditorSession()
        editor.textView.string = source
        _ = await editor.deriveContent(for: source, configuration: .default)
        editor.setPresentation(.rendered, source: source, onLinkClick: nil, theme: theme)
        XCTAssertEqual(editor.textView.selectedTextAttributes[.backgroundColor] as? NSColor, palette.selectionBackgroundColor)
        let model = try XCTUnwrap(RenderedMarkdownEditor.plan(for: source).tables.first)
        let table = try XCTUnwrap(editor.textView.renderedTable(atUTF16Location: model.sourceRange.utf16Range.location))
        for cell in table.subviews.compactMap({ $0 as? NSTextView }) {
            XCTAssertEqual(cell.selectedTextAttributes[.backgroundColor] as? NSColor, palette.selectionBackgroundColor)
        }
        editor.setPresentation(.source, source: source, onLinkClick: nil)
        XCTAssertEqual(editor.textView.selectedTextAttributes[.backgroundColor] as? NSColor, .selectedTextBackgroundColor)
        for builtin in PreviewTheme.allCases {
            let colors = MarkdownRenderPalette.resolved(for: try XCTUnwrap(NSAppearance(named: .aqua)), theme: builtin)
            XCTAssertNotEqual(colors.selectionBackground, colors.canvas, builtin.label)
            XCTAssertNotEqual(colors.selectionBackground, colors.subtleSurface, builtin.label)
            XCTAssertEqual(colors.selectionBackgroundColor.alphaComponent, 1)
        }
    }

    func testCSSThemeCatalogInstallsSixEditableFilesAndDiscoversCustomThemes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = ThemeCatalog(directory: directory)
        let initial = try catalog.load()
        XCTAssertEqual(initial.themes.map(\.label), ["GitHub", "Whitey", "Night", "Newsprint", "Pixyll", "Gothic"])
        XCTAssertTrue(initial.issues.isEmpty)
        XCTAssertTrue(initial.themes.allSatisfy { !$0.css.isEmpty && $0.styles.isValid })
        XCTAssertEqual(Set(initial.themes.map(\.css)).count, 6)
        let custom = directory.appendingPathComponent("my-paper.css")
        try "body { color: #123456; background: #fff; }".write(to: custom, atomically: true, encoding: .utf8)
        let edited = directory.appendingPathComponent("whitey.css")
        try "body { color: #654321; }".write(to: edited, atomically: true, encoding: .utf8)
        let loaded = try catalog.load()
        XCTAssertEqual(loaded.themes.last?.label, "My Paper")
        XCTAssertEqual(loaded.themes.first { $0.id == "whitey" }?.styles.value("color"), "#654321")
        try "body {".write(to: custom, atomically: true, encoding: .utf8)
        let invalid = try catalog.load()
        XCTAssertEqual(invalid.themes.count, 6)
        XCTAssertEqual(invalid.issues.count, 1)
        XCTAssertEqual(try String(contentsOf: custom, encoding: .utf8), "body {", "Invalid user CSS is never overwritten")
    }

    func testCSSCascadeVariablesUnitsAndUnsupportedRulesStayBounded() {
        let css = NativeCSSStyles(css: """
        /* body { color: red } */
        :root { --ink: #123; --cycle: var(--cycle); color: red !important; }
        body { color: var(--ink); font-family: Georgia, serif; padding: 20px 32px; }
        #write h1 { color: #abc; font-size: 2em; margin: 1rem 0 .5rem; }
        h1 { color: #fed; color: rgb(20, 30, 40) !important; }
        a { color: var(--missing, #369); }
        pre { color: var(--cycle); }
        @media (max-width: 600px) { body { color: #ff0000; } }
        """)
        XCTAssertTrue(css.isValid)
        XCTAssertTrue(css.hasUnsupportedRules)
        XCTAssertEqual(css.value("color"), "#123", "Body declarations override inherited root color")
        XCTAssertEqual(NativeCSSStyles.colorHex(css.value("color", on: "h1")), "#141e28")
        XCTAssertEqual(css.length("font-size", on: "h1", relativeTo: 18), 36)
        XCTAssertEqual(css.length("margin-bottom", on: "h1", relativeTo: 18), 9)
        XCTAssertEqual(css.length("padding-left"), 32)
        XCTAssertEqual(NativeCSSStyles.colorHex(css.value("color", on: "a")), "#336699")
        XCTAssertNil(css.value("color", on: "pre"), "Cyclic variables must not hang rendering")
        XCTAssertEqual(NativeCSSStyles.colorHex("rgba(10,20,30,0.5)"), "#0a141e80")
        XCTAssertFalse(NativeCSSStyles(css: "body { color: red;").isValid)
    }

    func testCSSThemeReloadPersistsSelectionAndFreezesExportSnapshot() throws {
        let suite = "inflow-css-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: defaults, themeDirectory: directory)
        let file = directory.appendingPathComponent("custom.css")
        try "body { color: #123456; font-family: Georgia; }".write(to: file, atomically: true, encoding: .utf8)
        preferences.reloadThemes()
        preferences.previewTheme = try XCTUnwrap(preferences.availableThemes.first { $0.id == "custom" })
        let frozen = preferences.previewConfiguration
        try "body { color: #654321; font-family: Menlo; }".write(to: file, atomically: true, encoding: .utf8)
        preferences.reloadThemes()
        XCTAssertEqual(preferences.previewTheme.styles.value("color"), "#654321")
        XCTAssertEqual(frozen.theme.styles.value("color"), "#123456")
        let reloaded = AppPreferences(defaults: defaults, themeDirectory: directory)
        XCTAssertEqual(reloaded.previewTheme.id, "custom")
        XCTAssertEqual(reloaded.previewTheme.styles.value("color"), "#654321")
        try FileManager.default.removeItem(at: file)
        preferences.reloadThemes()
        XCTAssertEqual(preferences.previewTheme.id, "github")
        XCTAssertNil(preferences.themeLoadMessage)

        var updates = 0
        let subscription = preferences.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }
        preferences.reloadThemes()
        XCTAssertEqual(updates, 0, "Unchanged theme polling must not invalidate Commands")
        try FileManager.default.removeItem(at: directory)
        try Data("unavailable theme directory".utf8).write(to: directory)
        preferences.reloadThemes()
        XCTAssertEqual(updates, 1, "The first error must still be visible")
        XCTAssertNotNil(preferences.themeLoadMessage)
        preferences.reloadThemes()
        preferences.reloadThemes()
        XCTAssertEqual(updates, 1, "Repeated polling failures must not rebuild an open menu")
    }

    func testCSSThemeHTMLUsesWriteSelectorWithoutAllowingStyleTagEscape() {
        let theme = PreviewTheme(id: "custom", label: "Custom", css: "#write h1 { color: #abcdef; } /* </style><script>alert(1)</script> */")
        let configuration = PreviewAppearanceConfiguration(contentWidth: 1200, zoom: 1, colorScheme: .light,
            theme: theme, increasedContrast: false, reduceMotion: true)
        let html = MarkdownRenderer.htmlDocument(for: "# Hello", configuration: configuration)
        XCTAssertTrue(html.contains("<body id=\"write\">"))
        XCTAssertTrue(html.contains("#write h1 { color: #abcdef; }"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("</style><script>"))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    func testCSSThemesReachNativeFontsColorsHeadingsAndKeepMarkdownIntact() async throws {
        let source = "# Heading 标题\n\n正文排版 Typography：这是同一份 Markdown，用来比较字体、字号与行距。**重点内容**与 `inline code`。\n\n## Section 章节\n\n> 引用文字：安静地阅读，专注于内容。 A thoughtful quotation.\n\n### Detail 细节\n\n- 列表项目 List item\n- 第二个项目 Another item\n\n[阅读链接](https://example.com)\n\n| A | B |\n| --- | --- |\n| 甲 | 乙 |\n| 丙 | 丁 |\n\n```swift\nlet theme = \"Inflow\"\nprint(theme)\n```"
        let editor = MarkdownSourceEditorSession(role: .renderedProjection)
        editor.scrollView.frame = NSRect(x: 0, y: 0, width: 920, height: 1100)
        editor.textView.frame = editor.scrollView.bounds
        editor.textView.string = source
        for theme in PreviewTheme.allCases {
            let configuration = PreviewAppearanceConfiguration(contentWidth: 1200, zoom: 1, colorScheme: .system,
                theme: theme, increasedContrast: false, reduceMotion: true)
            editor.applySourceAppearance(configuration.nativeRenderedAppearance(spellingEnabled: false), force: true)
            _ = await editor.deriveContent(for: source, configuration: configuration)
            editor.setPresentation(.rendered, source: source, onLinkClick: nil, theme: theme)
            let palette = MarkdownRenderPalette.resolved(for: NSAppearance(named: .aqua)!, theme: theme)
            XCTAssertEqual(editor.textView.backgroundColor, palette.canvasColor, theme.label)
            XCTAssertEqual(editor.textView.string, source)
            let table = try XCTUnwrap(editor.textView.renderedTable(atUTF16Location: (source as NSString).range(of: "| A").location))
            XCTAssertEqual(table.backgroundColor(forRow: 0), palette.mutedSurfaceColor, theme.label)
            XCTAssertEqual(table.backgroundColor(forRow: 1), palette.canvasColor, theme.label)
            let cell = try XCTUnwrap(table.subviews.compactMap { $0 as? RenderedMarkdownTableCellTextView }.first { $0.string == "甲" })
            let expectedFont = theme.styles.font(size: CGFloat(configuration.fontSize), fallback: MarkdownRenderMetrics.bodyFont(size: CGFloat(configuration.fontSize)))
            XCTAssertEqual(cell.caretFont.familyName, expectedFont.familyName, theme.label)
            let headingRange = (source as NSString).range(of: "Heading")
            let headingFont = try XCTUnwrap(editor.textView.textStorage?.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont)
            XCTAssertGreaterThan(headingFont.pointSize, configuration.fontSize)
            let headingParagraph = try XCTUnwrap(editor.textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(headingParagraph.alignment, ["whitey", "gothic"].contains(theme.id) ? .center : .left, theme.label)
            XCTAssertEqual(editor.textView.renderedHeadingDividerRanges.count,
                theme.id == "github" ? 2 : ["whitey", "newsprint"].contains(theme.id) ? 1 : 0, theme.label)
            XCTAssertEqual(table.usesRowBorders, ["whitey", "pixyll", "gothic"].contains(theme.id), theme.label)
            if let path = ProcessInfo.processInfo.environment["INFLOW_THEME_SNAPSHOTS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                editor.textView.layoutManager?.ensureLayout(for: try XCTUnwrap(editor.textView.textContainer))
                editor.scrollView.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(editor.scrollView.bitmapImageRepForCachingDisplay(in: editor.scrollView.bounds))
                editor.scrollView.cacheDisplay(in: editor.scrollView.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(theme.id + ".png"))
            }
        }
        let custom = PreviewTheme(id: "custom", label: "Custom", css: "body { font-family: Menlo; color: #112233; } #write h1 { font-size: 3em; color: #ff0000; }")
        let config = PreviewAppearanceConfiguration(contentWidth: 1200, zoom: 1, colorScheme: .light, theme: custom,
            increasedContrast: false, reduceMotion: true)
        editor.applySourceAppearance(config.nativeRenderedAppearance(spellingEnabled: false), force: true)
        _ = await editor.deriveContent(for: source, configuration: config)
        editor.setPresentation(.rendered, source: source, onLinkClick: nil, theme: custom)
        let heading = (source as NSString).range(of: "Heading").location
        let font = try XCTUnwrap(editor.textView.textStorage?.attribute(.font, at: heading, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 48, accuracy: 0.1)
        XCTAssertTrue(font.fontName.contains("Menlo"))
        XCTAssertEqual(editor.textView.textStorage?.attribute(.foregroundColor, at: heading, effectiveRange: nil) as? NSColor, NativeCSSStyles.color("#ff0000"))
        XCTAssertEqual(editor.textView.string, source)
    }

    func testBuiltinThemeMigrationUpdatesDefaultsAndPreservesUserEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalWhitey = #"""
/* Inflow Whitey — original CSS, inspired by the named Typora theme style. */
:root {
  --bg-color: #fafafa;
  --text-color: #444444;
  --primary-color: #4a789c;
  --md-heading: #222222;
  --md-secondary: #777777;
  --md-border: #dddddd;
  --md-quote-bar: #dddddd;
  --md-surface: #f0f0f0;
  --md-surface-strong: #eeeeee;
  --md-table-stripe: #f0f0f0;
  --md-inline-code: #eeeeee;
}
body {
  background-color: var(--bg-color);
  color: var(--text-color);
  font-family: "Helvetica Neue", "PingFang SC", sans-serif;
  line-height: 1.7;
  color-scheme: light;
}
h1, h2, h3, h4, h5, h6 { color: var(--md-heading); }
a { color: var(--primary-color); }
blockquote { color: var(--md-secondary); border-left-color: var(--md-quote-bar); }
pre { background-color: var(--md-surface); border-color: var(--md-border); }
code { background-color: var(--md-inline-code); }
th, td { border-color: var(--md-border); }
th { background-color: var(--md-surface); }
tr:nth-child(even) { background-color: var(--md-table-stripe); }
h1 { font-size: 2em; font-weight: 500; }
h2 { font-weight: 500; }
"""# + "\n"
        let whitey = directory.appendingPathComponent("whitey.css")
        try originalWhitey.write(to: whitey, atomically: true, encoding: .utf8)
        let userCSS = "body { color: #123456; } /* my custom GitHub */"
        let github = directory.appendingPathComponent("github.css")
        try userCSS.write(to: github, atomically: true, encoding: .utf8)
        let oldNight = Data("body { color: white; background: black; }".utf8)
        try oldNight.write(to: directory.appendingPathComponent("night.css"))
        try JSONEncoder().encode(["night": ThemeCatalog.fingerprint(oldNight)])
            .write(to: directory.appendingPathComponent(".builtin-versions.json"))
        let catalog = ThemeCatalog(directory: directory)
        let loaded = try catalog.load()
        XCTAssertTrue(loaded.issues.isEmpty)
        XCTAssertEqual(try String(contentsOf: whitey, encoding: .utf8), PreviewTheme.allCases[1].css)
        XCTAssertEqual(try String(contentsOf: github, encoding: .utf8), userCSS)
        XCTAssertEqual(loaded.themes.first { $0.id == "night" }?.css, PreviewTheme.allCases[2].css)
        let modified = try whitey.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try catalog.load()
        XCTAssertEqual(try whitey.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
    }

    func testThemeDefaultsAndCustomOverridesComeFromCSS() {
        XCTAssertEqual(ThemeStyleResources.defaults.metric("bodyFontSize"), 16)
        XCTAssertEqual(MarkdownRenderPalette.light.canvas, "#ffffff")
        XCTAssertEqual(MarkdownRenderPalette.dark.canvas, "#0f1115")
        let theme = PreviewTheme(id: "custom", label: "Custom", css: """
        :root { --inflow-paragraphGap: 23; }
        body { font-family: Georgia, "Songti SC", serif; }
        h1 { border-bottom: 3px solid #123456; }
        """)
        XCTAssertEqual(theme.styles.metric("paragraphGap"), 23, "CSS custom property names are case sensitive")
        XCTAssertEqual(theme.styles.headingDividerWidth(level: 1), 3)
        XCTAssertEqual(theme.styles.value("border-bottom-color", on: "h1"), "#123456")
        let font = theme.styles.font(size: 18, fallback: .systemFont(ofSize: 18))
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        XCTAssertTrue(cascade?.contains { ($0.object(forKey: .family) as? String) == "Songti SC" } == true,
            "Chinese text must keep the serif fallback supplied by CSS")
        let fonts = PreviewTheme.allCases.map { $0.styles.font(size: 18, fallback: .systemFont(ofSize: 18)).familyName }
        XCTAssertGreaterThan(Set(fonts).count, 3)
        XCTAssertEqual(Set(PreviewTheme.allCases.map { $0.styles.value("font-size", on: "h1") }).count, 6)
    }

    func testDefaultsMatchLaunchContract() {
        withDefaults { defaults in
            defaults.set(760, forKey: "preferences.preview.contentWidth")
            XCTAssertEqual(AppPreferences(defaults: defaults).previewContentWidth, 1_200)
            defaults.set(760, forKey: "preferences.preview.contentWidth")
            XCTAssertEqual(AppPreferences(defaults: defaults).previewContentWidth, 760,
                "A later explicit width choice must survive relaunch")
        }
        withDefaults { defaults in
            defaults.set(940, forKey: "preferences.preview.contentWidth")
            XCTAssertEqual(AppPreferences(defaults: defaults).previewContentWidth, 940)
        }
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.applyAutosavePolicy()

            XCTAssertTrue(preferences.autoPairEnabled)
            preferences.autoPairEnabled = false
            XCTAssertFalse(AppPreferences(defaults: defaults).autoPairEnabled)
            XCTAssertFalse(preferences.sourceEditorAppearance.autoPairEnabled)
            preferences.autoPairEnabled = true
            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.editorLineHeight, 1.6)
            XCTAssertTrue(preferences.syntaxHighlightingEnabled)
            XCTAssertTrue(preferences.spellingEnabled)
            XCTAssertTrue(preferences.wrapsLines)
            XCTAssertFalse(preferences.showsLineNumbers)
            XCTAssertTrue(preferences.scrollSyncEnabled)
            XCTAssertTrue(preferences.headingNavigationEnabled)
            XCTAssertEqual(preferences.previewContentWidth, 1_200)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewColorScheme, .system)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertTrue(preferences.mathRenderingEnabled)
            XCTAssertTrue(preferences.mermaidRenderingEnabled)
            XCTAssertEqual(preferences.linkActivation, .singleClick)
            XCTAssertEqual(preferences.increasedContrast, .followSystem)
            XCTAssertEqual(preferences.reduceMotion, .followSystem)
            XCTAssertEqual(preferences.workspaceViewMode, .automatic)
            XCTAssertTrue(preferences.workspaceProjectSidebarVisible)
            XCTAssertFalse(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.5)
            XCTAssertEqual(preferences.workspaceProjectSidebarWidth, 228)
            XCTAssertEqual(preferences.workspaceOutlineWidth, 228)
            XCTAssertEqual(preferences.recentDocumentCapacity, 20)
            XCTAssertEqual(preferences.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertFalse(preferences.autosaveEnabled)
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(preferences.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
            XCTAssertEqual(
                preferences.previewConfiguration.contentWidth,
                MarkdownRenderMetrics.previewReadingWidth
            )
            XCTAssertEqual(
                preferences.previewConfiguration.nativeRenderedAppearance(
                    spellingEnabled: true
                ).fontSize,
                MarkdownRenderMetrics.bodyFontSize
            )
            XCTAssertGreaterThan(
                MarkdownRenderMetrics.heading(level: 1).scale,
                MarkdownRenderMetrics.heading(level: 2).scale
            )
            XCTAssertTrue(
                MarkdownRenderPalette.light.cssVariables.contains(
                    "--md-table-stripe: \(MarkdownRenderPalette.light.tableStripe);"
                )
            )
            XCTAssertNotEqual(
                MarkdownRenderPalette.light.inlineCode,
                MarkdownRenderPalette.dark.inlineCode
            )
            XCTAssertEqual(
                defaults.string(forKey: "preferences.workspace.viewMode"),
                WorkspaceViewModePreference.automatic.rawValue
            )
        }
    }

    func testWorkspacePreferencesPersistAcrossPreferenceInstancesAndClampToBounds() {
        withDefaults { defaults in
            let first = AppPreferences(defaults: defaults)
            first.renderedFontSize = 21
            first.editorFontSize = 24
            first.editorLineHeight = 1.9
            first.syntaxHighlightingEnabled = false
            first.spellingEnabled = false
            first.wrapsLines = false
            first.showsLineNumbers = true
            first.scrollSyncEnabled = false
            first.headingNavigationEnabled = false
            first.previewContentWidth = 1_040
            first.previewZoom = 1.65
            first.previewColorScheme = .dark
            first.previewTheme = .longform
            first.mathRenderingEnabled = false
            first.mermaidRenderingEnabled = false
            first.linkActivation = .contextMenu
            first.increasedContrast = .enabled
            first.reduceMotion = .disabled
            first.workspaceViewMode = .preview
            first.workspaceProjectSidebarVisible = false
            first.workspaceOutlineVisible = true
            first.workspaceSplitFraction = 0.65
            first.workspaceProjectSidebarWidth = 276
            first.workspaceOutlineWidth = 252
            first.recentDocumentCapacity = 42
            first.markdownOpenBehavior = .newWindow
            first.autosaveEnabled = false
            first.autosaveDelay = .fiveSeconds
            first.existingImagePlacement = .copyToRelativeDirectory

            let second = AppPreferences(defaults: defaults)
            second.applyAutosavePolicy()
            XCTAssertEqual(second.renderedFontSize, 21)
            XCTAssertEqual(second.previewConfiguration.nativeRenderedAppearance(spellingEnabled: false).fontSize, 21 * 1.65, accuracy: 0.001)
            XCTAssertEqual(second.previewConfiguration.nativeRenderedAppearance(spellingEnabled: false).lineHeight, 1.9)
            XCTAssertEqual(second.editorFontSize, 24)
            XCTAssertEqual(second.editorLineHeight, 1.9)
            XCTAssertFalse(second.syntaxHighlightingEnabled)
            XCTAssertFalse(second.spellingEnabled)
            XCTAssertFalse(second.wrapsLines)
            XCTAssertTrue(second.showsLineNumbers)
            XCTAssertFalse(second.scrollSyncEnabled)
            XCTAssertFalse(second.headingNavigationEnabled)
            XCTAssertEqual(second.previewContentWidth, 1_040)
            XCTAssertEqual(second.previewZoom, 1.65)
            XCTAssertEqual(second.previewColorScheme, .dark)
            XCTAssertEqual(second.previewTheme, .longform)
            XCTAssertTrue(second.mathRenderingEnabled)
            XCTAssertTrue(second.mermaidRenderingEnabled)
            XCTAssertEqual(second.linkActivation, .contextMenu)
            XCTAssertEqual(second.increasedContrast, .followSystem)
            XCTAssertEqual(second.reduceMotion, .followSystem)
            XCTAssertEqual(second.workspaceViewMode, .preview)
            XCTAssertFalse(second.workspaceProjectSidebarVisible)
            XCTAssertTrue(second.workspaceOutlineVisible)
            XCTAssertEqual(second.workspaceSplitFraction, 0.65)
            XCTAssertEqual(second.workspaceProjectSidebarWidth, 276)
            XCTAssertEqual(second.workspaceOutlineWidth, 252)
            XCTAssertEqual(second.recentDocumentCapacity, 20)
            XCTAssertEqual(second.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertFalse(second.autosaveEnabled)
            XCTAssertEqual(second.autosaveDelay, .oneSecond)
            XCTAssertEqual(second.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)

            second.editorFontSize = 100
            second.editorLineHeight = -4
            second.previewContentWidth = 50
            second.previewZoom = 9
            second.workspaceSplitFraction = 0.9
            second.workspaceProjectSidebarWidth = 1_000
            second.workspaceOutlineWidth = -10
            second.recentDocumentCapacity = 500
            XCTAssertEqual(second.editorFontSize, 28)
            XCTAssertEqual(second.editorLineHeight, 1.2)
            XCTAssertEqual(second.previewContentWidth, 600)
            XCTAssertEqual(second.previewZoom, 2)
            XCTAssertEqual(second.workspaceSplitFraction, 0.75)
            XCTAssertEqual(second.workspaceProjectSidebarWidth, 300)
            XCTAssertEqual(second.workspaceOutlineWidth, 200)
            XCTAssertEqual(second.recentDocumentCapacity, 50)

            let third = AppPreferences(defaults: defaults)
            XCTAssertEqual(third.editorFontSize, 28)
            XCTAssertEqual(third.editorLineHeight, 1.2)
            XCTAssertEqual(third.previewContentWidth, 600)
            XCTAssertEqual(third.previewZoom, 2)
            XCTAssertEqual(third.workspaceViewMode, .preview)
            XCTAssertFalse(third.workspaceProjectSidebarVisible)
            XCTAssertTrue(third.workspaceOutlineVisible)
            XCTAssertEqual(third.workspaceSplitFraction, 0.75)
            XCTAssertEqual(third.workspaceProjectSidebarWidth, 300)
            XCTAssertEqual(third.workspaceOutlineWidth, 200)
            XCTAssertEqual(third.recentDocumentCapacity, 20)
        }
    }

    func testInvalidStoredValuesAreSanitizedWithoutAffectingUnrelatedData() {
        withDefaults { defaults in
            defaults.set(Double.nan, forKey: "preferences.editor.fontSize")
            defaults.set(0, forKey: "preferences.editor.lineHeight")
            defaults.set(5_000, forKey: "preferences.preview.contentWidth")
            defaults.set("retired-theme", forKey: "preferences.preview.theme")
            defaults.set("retired-link-mode", forKey: "preferences.preview.linkActivation")
            defaults.set("retired-view", forKey: "preferences.window.lastActiveEditorViewMode")
            defaults.set(
                "not-a-boolean",
                forKey: "preferences.window.defaultProjectSidebarVisible"
            )
            defaults.set(7, forKey: "preferences.window.defaultOutlineVisible")
            defaults.set(Double.nan, forKey: "preferences.preview.defaultSplitFraction")
            defaults.set(Double.nan, forKey: "preferences.workspace.projectSidebarWidth")
            defaults.set(9_000, forKey: "preferences.workspace.outlineWidth")
            defaults.set(-40, forKey: RecentDocumentPolicy.capacityKey)
            defaults.set("retired-open", forKey: RecentDocumentPolicy.openBehaviorKey)
            defaults.set("retired-delay", forKey: "preferences.documents.autosaveDelay")
            defaults.set(
                "retired-placement",
                forKey: "preferences.resources.existingImagePlacement"
            )
            defaults.set("keep-me", forKey: "unrelated.document-state")

            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.editorLineHeight, 1.2)
            XCTAssertEqual(preferences.previewContentWidth, 1_800)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertEqual(preferences.linkActivation, .singleClick)
            XCTAssertEqual(preferences.workspaceViewMode, .automatic)
            XCTAssertTrue(preferences.workspaceProjectSidebarVisible)
            XCTAssertFalse(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.5)
            XCTAssertEqual(preferences.workspaceProjectSidebarWidth, 228)
            XCTAssertEqual(preferences.workspaceOutlineWidth, 288)
            XCTAssertEqual(preferences.recentDocumentCapacity, 20)
            XCTAssertEqual(preferences.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(preferences.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(defaults.string(forKey: "unrelated.document-state"), "keep-me")
            XCTAssertEqual(
                defaults.string(forKey: "preferences.window.lastActiveEditorViewMode"),
                "retired-view",
                "an invalid legacy value remains available for diagnostics"
            )
        }
    }

    func testGroupResetOnlyChangesTheSelectedPreferenceGroup() {
        withDefaults { defaults in
            defaults.set("recovery-sentinel", forKey: "document.recovery.record")
            let preferences = AppPreferences(defaults: defaults)
            preferences.editorFontSize = 27
            preferences.previewZoom = 1.8
            preferences.syntaxHighlightingEnabled = false
            preferences.scrollSyncEnabled = false
            preferences.linkActivation = .contextMenu
            preferences.increasedContrast = .enabled
            preferences.workspaceViewMode = .source
            preferences.workspaceProjectSidebarVisible = false
            preferences.workspaceOutlineVisible = true
            preferences.workspaceSplitFraction = 0.7
            preferences.workspaceProjectSidebarWidth = 284
            preferences.workspaceOutlineWidth = 244
            preferences.recentDocumentCapacity = 31
            preferences.markdownOpenBehavior = .newWindow
            preferences.autosaveEnabled = false
            preferences.autosaveDelay = .twoSeconds
            preferences.existingImagePlacement = .keepOriginal

            preferences.reset(.writing)

            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertTrue(preferences.syntaxHighlightingEnabled)
            XCTAssertEqual(preferences.previewZoom, 1.8)
            XCTAssertFalse(preferences.scrollSyncEnabled)
            XCTAssertEqual(preferences.linkActivation, .contextMenu)
            XCTAssertEqual(preferences.increasedContrast, .enabled)
            XCTAssertEqual(preferences.workspaceViewMode, .source)
            XCTAssertFalse(preferences.workspaceProjectSidebarVisible)
            XCTAssertTrue(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.7)
            XCTAssertEqual(preferences.workspaceProjectSidebarWidth, 284)
            XCTAssertEqual(preferences.workspaceOutlineWidth, 244)
            XCTAssertEqual(preferences.recentDocumentCapacity, 31)
            XCTAssertEqual(preferences.markdownOpenBehavior, .newWindow)
            XCTAssertFalse(preferences.autosaveEnabled)
            XCTAssertEqual(preferences.autosaveDelay, .twoSeconds)
            XCTAssertEqual(preferences.existingImagePlacement, .keepOriginal)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
            XCTAssertEqual(defaults.string(forKey: "document.recovery.record"), "recovery-sentinel")

            preferences.reset(.general)

            XCTAssertEqual(preferences.workspaceViewMode, .source)
            XCTAssertFalse(preferences.workspaceProjectSidebarVisible)
            XCTAssertTrue(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.7)
            XCTAssertEqual(preferences.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertFalse(preferences.scrollSyncEnabled)
            XCTAssertEqual(preferences.increasedContrast, .enabled)
            XCTAssertEqual(preferences.existingImagePlacement, .keepOriginal)
            XCTAssertEqual(defaults.string(forKey: "document.recovery.record"), "recovery-sentinel")

            preferences.reset(.workspace)

            XCTAssertEqual(preferences.workspaceViewMode, .automatic)
            XCTAssertTrue(preferences.workspaceProjectSidebarVisible)
            XCTAssertFalse(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.5)
            XCTAssertEqual(preferences.workspaceProjectSidebarWidth, 228)
            XCTAssertEqual(preferences.workspaceOutlineWidth, 228)
        }
    }

    func testResetAllReturnsEveryLaunchPreferenceToDefaultWithoutDeletingOtherRecords() {
        withDefaults { defaults in
            defaults.set("recovery-sentinel", forKey: "document.recovery.record")
            defaults.set("recent-sentinel", forKey: RecentDocumentPolicy.recordsKey)
            let preferences = AppPreferences(defaults: defaults)
            preferences.editorFontSize = 27
            preferences.editorLineHeight = 1.9
            preferences.syntaxHighlightingEnabled = false
            preferences.spellingEnabled = false
            preferences.wrapsLines = false
            preferences.showsLineNumbers = true
            preferences.scrollSyncEnabled = false
            preferences.headingNavigationEnabled = false
            preferences.previewContentWidth = 1_040
            preferences.previewZoom = 1.8
            preferences.previewColorScheme = .dark
            preferences.previewTheme = .code
            preferences.mathRenderingEnabled = false
            preferences.mermaidRenderingEnabled = false
            preferences.increasedContrast = .enabled
            preferences.reduceMotion = .disabled
            preferences.workspaceViewMode = .split
            preferences.workspaceProjectSidebarVisible = false
            preferences.workspaceOutlineVisible = true
            preferences.workspaceSplitFraction = 0.7
            preferences.workspaceProjectSidebarWidth = 292
            preferences.workspaceOutlineWidth = 268
            preferences.recentDocumentCapacity = 31
            preferences.markdownOpenBehavior = .newWindow
            preferences.autosaveEnabled = false
            preferences.autosaveDelay = .fiveSeconds
            preferences.existingImagePlacement = .keepOriginal

            preferences.resetAll()

            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.editorLineHeight, 1.6)
            XCTAssertTrue(preferences.syntaxHighlightingEnabled)
            XCTAssertTrue(preferences.spellingEnabled)
            XCTAssertTrue(preferences.wrapsLines)
            XCTAssertFalse(preferences.showsLineNumbers)
            XCTAssertTrue(preferences.scrollSyncEnabled)
            XCTAssertTrue(preferences.headingNavigationEnabled)
            XCTAssertEqual(preferences.previewContentWidth, 1_200)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewColorScheme, .system)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertTrue(preferences.mathRenderingEnabled)
            XCTAssertTrue(preferences.mermaidRenderingEnabled)
            XCTAssertEqual(preferences.increasedContrast, .followSystem)
            XCTAssertEqual(preferences.reduceMotion, .followSystem)
            XCTAssertEqual(preferences.workspaceViewMode, .automatic)
            XCTAssertTrue(preferences.workspaceProjectSidebarVisible)
            XCTAssertFalse(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.5)
            XCTAssertEqual(preferences.workspaceProjectSidebarWidth, 228)
            XCTAssertEqual(preferences.workspaceOutlineWidth, 228)
            XCTAssertEqual(preferences.recentDocumentCapacity, 20)
            XCTAssertEqual(preferences.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertFalse(preferences.autosaveEnabled)
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(preferences.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
            XCTAssertEqual(defaults.string(forKey: "document.recovery.record"), "recovery-sentinel")
            XCTAssertEqual(defaults.string(forKey: RecentDocumentPolicy.recordsKey), "recent-sentinel")
        }
    }

    func testSettingsResetUsesFrozenCopyAndNamesCurrentOrAllScope() {
        XCTAssertEqual(SettingsResetPrompt.title, "恢复默认设置？")
        XCTAssertEqual(
            SettingsResetPrompt.message,
            "只会重置所选偏好，不会删除任何用户内容或记录。"
        )
        XCTAssertEqual(SettingsResetPrompt.confirmTitle, "恢复默认")
        XCTAssertEqual(SettingsResetPrompt.cancelTitle, "取消")
        XCTAssertEqual(
            SettingsResetScope.current(.writing).menuTitle,
            "恢复“写作”默认设置…"
        )
        XCTAssertEqual(SettingsResetScope.all.menuTitle, "恢复全部默认设置…")
        XCTAssertEqual(InflowSettingsSection.preview.preferenceGroup, .preview)
        XCTAssertEqual(InflowSettingsSection.workspace.preferenceGroup, .workspace)
        XCTAssertEqual(
            InflowSettingsSection.allCases,
            [.general, .workspace, .writing, .preview]
        )
    }

    func testVersionedSettingsRegistryMigratesLegacyWorkspacePreferences() {
        withDefaults { defaults in
            defaults.set(1.7, forKey: "preferences.preview.zoom")
            defaults.set(
                EditorViewMode.preview.rawValue,
                forKey: "preferences.window.lastActiveEditorViewMode"
            )
            defaults.set(false, forKey: "preferences.window.defaultProjectSidebarVisible")
            defaults.set(true, forKey: "preferences.window.defaultOutlineVisible")
            defaults.set(0.65, forKey: "preferences.preview.defaultSplitFraction")
            defaults.set("keep-me", forKey: "unrelated.document-state")

            let preferences = AppPreferences(defaults: defaults)

            XCTAssertEqual(preferences.previewZoom, 1.7)
            XCTAssertEqual(preferences.workspaceViewMode, .preview)
            XCTAssertFalse(preferences.workspaceProjectSidebarVisible)
            XCTAssertTrue(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.65)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.zoom"), 1.7)
            XCTAssertEqual(
                defaults.integer(forKey: AppPreferences.Registry.schemaVersionKey),
                AppPreferences.Registry.currentSchemaVersion
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains("preferences.preview.zoom")
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains(
                    "preferences.preview.defaultSplitFraction"
                )
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains(
                    "preferences.window.defaultProjectSidebarVisible"
                )
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains(
                    "preferences.window.defaultOutlineVisible"
                )
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains(
                    "preferences.workspace.viewMode"
                )
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains(
                    "preferences.workspace.projectSidebarWidth"
                )
            )
            XCTAssertTrue(
                AppPreferences.Registry.knownKeys.contains(
                    "preferences.workspace.outlineWidth"
                )
            )
            XCTAssertEqual(defaults.string(forKey: "unrelated.document-state"), "keep-me")
        }
    }

    func testSettingsPersistenceFailureKeepsSessionValuesAndSupportsRetry() {
        withDefaults { defaults in
            let persistence = ControlledPreferencePersistence(defaults: defaults)
            let preferences = AppPreferences(
                defaults: defaults,
                persistence: persistence
            )
            XCTAssertNil(preferences.persistenceFailure)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.contentWidth"), 1_200)

            persistence.shouldFail = true
            preferences.previewContentWidth = 900
            preferences.workspaceOutlineVisible = true

            XCTAssertEqual(preferences.previewContentWidth, 900)
            XCTAssertTrue(preferences.workspaceOutlineVisible)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.contentWidth"), 1_200)
            XCTAssertFalse(defaults.bool(forKey: "preferences.workspace.outlineVisible"))
            XCTAssertNotNil(preferences.persistenceFailure)
            XCTAssertEqual(SettingsPersistencePrompt.title, "暂时无法保存设置")
            XCTAssertEqual(
                SettingsPersistencePrompt.message,
                "本次会话可继续使用当前选择，重新打开 Inflow 后可能恢复之前的值。"
            )
            XCTAssertEqual(SettingsPersistencePrompt.retryTitle, "重试")
            XCTAssertEqual(SettingsPersistencePrompt.continueTitle, "继续使用")

            preferences.continueUsingSessionPreferences()
            XCTAssertNil(preferences.persistenceFailure)
            XCTAssertEqual(preferences.previewContentWidth, 900)

            preferences.previewColorScheme = .dark
            XCTAssertNotNil(preferences.persistenceFailure)
            preferences.retryPersistence()
            XCTAssertNotNil(preferences.persistenceFailure)

            persistence.shouldFail = false
            preferences.retryPersistence()

            XCTAssertNil(preferences.persistenceFailure)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.contentWidth"), 900)
            XCTAssertTrue(defaults.bool(forKey: "preferences.workspace.outlineVisible"))
            XCTAssertEqual(
                defaults.string(forKey: "preferences.preview.colorScheme"),
                PreviewColorScheme.dark.rawValue
            )
        }
    }

    func testPersonalMilestoneKeepsPeriodicAutosaveDisabledAndManualSaveAvailable() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)

            preferences.autosaveEnabled = true
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)

            preferences.autosaveEnabled = false
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
            XCTAssertTrue(NSDocument.instancesRespond(to: #selector(NSDocument.save(_:))))
        }
    }

    func testPersonalMilestoneDisablesDocumentGroupHostAutosavePolicies() throws {
        let document = AutosavingDocumentHostProbe()

        XCTAssertFalse(
            ManualSaveDocumentHostPolicy.hasManualSaveFlags(type(of: document))
        )
        try ManualSaveDocumentHostPolicy.applyForTesting(to: document)
        XCTAssertTrue(
            ManualSaveDocumentHostPolicy.hasManualSaveFlags(type(of: document))
        )
        XCTAssertTrue(
            ManualSaveDocumentHostPolicy.hasDisposableDraftClosePolicy(type(of: document))
        )

        document.updateChangeCount(.changeDone)
        var closeResult: Bool?
        DocumentCloseAuthorization.request(for: document) { closeResult = $0 }
        XCTAssertEqual(closeResult, true)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(DocumentCloseAuthorization.hasPendingRequests)

        // Applying the policy again is an idempotent no-op for later windows
        // backed by the same concrete SwiftUI document host class.
        try ManualSaveDocumentHostPolicy.applyForTesting(to: document)
        XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
    }

    func testManualSaveHostPolicyNeverMutatesNSDocumentGlobally() throws {
        let baseBefore = try XCTUnwrap(
            ManualSaveDocumentHostPolicy.runtimeAutomaticSaveFlags(NSDocument.self)
        )

        try ManualSaveDocumentHostPolicy.applyForTesting(
            to: IsolatedAutosavingDocumentHostProbe()
        )

        let baseAfter = try XCTUnwrap(
            ManualSaveDocumentHostPolicy.runtimeAutomaticSaveFlags(NSDocument.self)
        )
        XCTAssertEqual(baseAfter.inPlace, baseBefore.inPlace)
        XCTAssertEqual(baseAfter.drafts, baseBefore.drafts)
        XCTAssertEqual(baseAfter.versions, baseBefore.versions)
    }

    func testManualSaveHostPolicyAddsOnlyToConcreteInheritedHost() throws {
        let parentBefore = try XCTUnwrap(
            ManualSaveDocumentHostPolicy.runtimeAutomaticSaveFlags(
                InheritedAutosavingDocumentHostParent.self
            )
        )
        let baseBefore = try XCTUnwrap(
            ManualSaveDocumentHostPolicy.runtimeAutomaticSaveFlags(NSDocument.self)
        )
        let document = InheritedAutosavingDocumentHostProbe()

        try ManualSaveDocumentHostPolicy.applyForTesting(to: document)

        XCTAssertTrue(
            ManualSaveDocumentHostPolicy.hasManualSaveFlags(type(of: document))
        )
        let parentAfter = try XCTUnwrap(
            ManualSaveDocumentHostPolicy.runtimeAutomaticSaveFlags(
                InheritedAutosavingDocumentHostParent.self
            )
        )
        let baseAfter = try XCTUnwrap(
            ManualSaveDocumentHostPolicy.runtimeAutomaticSaveFlags(NSDocument.self)
        )
        XCTAssertEqual(parentAfter.inPlace, parentBefore.inPlace)
        XCTAssertEqual(parentAfter.drafts, parentBefore.drafts)
        XCTAssertEqual(parentAfter.versions, parentBefore.versions)
        XCTAssertEqual(baseAfter.inPlace, baseBefore.inPlace)
        XCTAssertEqual(baseAfter.drafts, baseBefore.drafts)
        XCTAssertEqual(baseAfter.versions, baseBefore.versions)
    }

    func testExistingImagePlacementPreferenceKeepsPromptAsAnExplicitChoice() {
        XCTAssertEqual(
            ExistingImagePlacementPreference.copyToAssets.automaticPlacement,
            .copyToAssets
        )
        XCTAssertEqual(
            ExistingImagePlacementPreference.copyToRelativeDirectory.automaticPlacement,
            .copyToRelativeDirectory
        )
        XCTAssertEqual(
            ExistingImagePlacementPreference.keepOriginal.automaticPlacement,
            .keepOriginal
        )
        XCTAssertNil(ExistingImagePlacementPreference.askEveryTime.automaticPlacement)
    }

    func testSourceAppearanceChangesStyleWithoutChangingTextSelectionOrUndo() throws {
        let session = MarkdownSourceEditorSession()
        let source = "第一行\nsecond 👩‍💻 line"
        session.textView.string = source
        let selection = NSRange(location: 2, length: 4)
        session.textView.setSelectedRange(selection)
        session.textView.insertText("测试", replacementRange: selection)
        let textAfterEdit = session.textView.string
        let selectionAfterEdit = session.textView.selectedRange()
        let canUndo = session.textView.undoManager?.canUndo

        session.applySourceAppearance(
            SourceEditorAppearance(
                fontSize: 22,
                lineHeight: 1.9,
                spellingEnabled: false,
                wrapsLines: false,
                showsLineNumbers: true
            ),
            force: true
        )

        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, textAfterEdit))
        XCTAssertEqual(session.textView.selectedRange(), selectionAfterEdit)
        XCTAssertEqual(session.textView.undoManager?.canUndo, canUndo)
        XCTAssertEqual(session.textView.font?.pointSize, 22)
        XCTAssertFalse(session.textView.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(session.scrollView.hasHorizontalScroller)
        XCTAssertFalse(try XCTUnwrap(session.textView.textContainer).widthTracksTextView)
        XCTAssertTrue(session.scrollView.hasVerticalRuler)
        XCTAssertTrue(session.scrollView.rulersVisible)
        let ruler = try XCTUnwrap(
            session.scrollView.verticalRulerView as? MarkdownLineNumberRulerView
        )
        XCTAssertEqual(ruler.lineCount, textAfterEdit.filter { $0 == "\n" }.count + 1)
        let style = session.textView.textStorage?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(style).minimumLineHeight, 22 * 1.9, accuracy: 0.001)

        session.applySourceAppearance(.default, force: true)
        XCTAssertFalse(session.scrollView.hasHorizontalScroller)
        XCTAssertTrue(try XCTUnwrap(session.textView.textContainer).widthTracksTextView)
        XCTAssertFalse(session.scrollView.rulersVisible)
    }

    func testLineNumbersTrackPhysicalLinesWithoutChangingTextOrUndo() async throws {
        let session = MarkdownSourceEditorSession()
        session.textView.string = "first\nsecond\n"
        _ = await session.authoritativeSnapshot()
        session.applySourceAppearance(
            SourceEditorAppearance(
                fontSize: 15,
                lineHeight: 1.6,
                spellingEnabled: true,
                wrapsLines: true,
                showsLineNumbers: true
            ),
            force: true
        )
        let ruler = try XCTUnwrap(
            session.scrollView.verticalRulerView as? MarkdownLineNumberRulerView
        )
        XCTAssertEqual(ruler.lineCount, 3)

        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        session.textView.insertText("\ninserted", replacementRange: session.textView.selectedRange())

        XCTAssertEqual(ruler.lineCount, 4)
        XCTAssertEqual(session.textView.string, "first\ninserted\nsecond\n")
        _ = await session.authoritativeSnapshot()
        XCTAssertTrue(session.textView.engineCanUndo)
        XCTAssertFalse(try XCTUnwrap(session.textView.undoManager).canUndo)
        session.textView.undo(nil)
        for _ in 0..<20 where session.textView.string != "first\nsecond\n" {
            await Task.yield()
        }
        XCTAssertEqual(ruler.lineCount, 3)
        XCTAssertEqual(session.textView.string, "first\nsecond\n")
    }

    func testPreviewConfigurationProducesSafeDeterministicCSS() {
        let configuration = PreviewAppearanceConfiguration(
            contentWidth: 1_020,
            zoom: 1.5,
            colorScheme: .dark,
            theme: .longform,
            increasedContrast: true,
            reduceMotion: true
        )

        let html = MarkdownRenderer.htmlDocument(
            for: "# 阅读设置",
            configuration: configuration
        )

        XCTAssertTrue(html.contains("id=\"inflow-user-appearance\""))
        XCTAssertTrue(html.contains("max-width: 1020.00px"))
        XCTAssertTrue(html.contains("font-size: 24.00px"))
        XCTAssertTrue(html.contains("color-scheme: dark"))
        XCTAssertTrue(html.contains("PT Serif"))
        XCTAssertTrue(html.contains("animation: none !important"))
        XCTAssertTrue(html.contains(":focus-visible"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("<script"))

        let nativeAppearance = configuration.nativeRenderedAppearance(spellingEnabled: true)
        XCTAssertEqual(nativeAppearance.fontSize, 24)
        XCTAssertEqual(nativeAppearance.lineHeight, 1.5)
        XCTAssertTrue(nativeAppearance.spellingEnabled)
        XCTAssertTrue(nativeAppearance.wrapsLines)
        XCTAssertFalse(nativeAppearance.showsLineNumbers)
        let highContrast = MarkdownRenderPalette.resolved(for: NSAppearance(named: .aqua)!, theme: .highContrast)
        XCTAssertEqual(highContrast.text, "#111111")
        XCTAssertNotEqual(highContrast.border, MarkdownRenderPalette.light.border)
        XCTAssertNil(PreviewColorScheme.system.nativeAppearance)
        XCTAssertEqual(PreviewColorScheme.dark.nativeAppearance?.name, .darkAqua)
    }

    func testExportFreezesAppearanceSnapshot() throws {
        var selectedAppearance = PreviewAppearanceConfiguration(
            contentWidth: 900,
            zoom: 1.25,
            colorScheme: .light,
            theme: .code,
            increasedContrast: false,
            reduceMotion: false
        )
        let snapshot = HTMLExportSnapshot(
            markdown: "# Snapshot",
            appearance: selectedAppearance
        )
        selectedAppearance = .default

        let output = try HTMLExporter.generate(snapshot: snapshot)
        let html = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(html.contains("max-width: 900.00px"))
        XCTAssertTrue(html.contains("font-size: 20.00px"))
        XCTAssertTrue(html.contains("color-scheme: light"))
        XCTAssertTrue(html.contains("ui-monospace"))
        XCTAssertFalse(html.contains("max-width: 760.00px"))
        XCTAssertEqual(selectedAppearance, .default)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "Inflow.AppPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalAutosavingDelay = NSDocumentController.shared.autosavingDelay
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            NSDocumentController.shared.autosavingDelay = originalAutosavingDelay
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(defaults)
    }
}

private class AutosavingDocumentHostProbeParent: NSDocument {
    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { true }
    override class var preservesVersions: Bool { true }
}

private final class AutosavingDocumentHostProbe: AutosavingDocumentHostProbeParent {}

private class IsolatedAutosavingDocumentHostProbeParent: NSDocument {
    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { true }
    override class var preservesVersions: Bool { true }
}

private final class IsolatedAutosavingDocumentHostProbe:
    IsolatedAutosavingDocumentHostProbeParent {}

private class InheritedAutosavingDocumentHostParent: NSDocument {
    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { true }
    override class var preservesVersions: Bool { true }
}

private final class InheritedAutosavingDocumentHostProbe:
    InheritedAutosavingDocumentHostParent {}

@MainActor
private final class ControlledPreferencePersistence: AppPreferencePersistence {
    private let defaults: UserDefaults
    var shouldFail = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func persist(_ values: [String: Any]) -> Bool {
        guard !shouldFail else { return false }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        _ = defaults.synchronize()
        return values.allSatisfy { key, value in
            guard let stored = defaults.object(forKey: key) as? NSObject,
                  let expected = value as? NSObject
            else {
                return false
            }
            return stored.isEqual(expected)
        }
    }
}
