import AppKit
import Combine
import Foundation

struct MarkdownHeadingStyle: Equatable, Sendable {
    let scale: Double
    let spacingBefore: Double
    let spacingAfter: Double
}

enum MarkdownRenderMetrics {
    static let readingWidth = 800.0
    static let previewReadingWidth = 1_200.0
    static let renderedHorizontalInset = CGFloat(24)
    static let bodyFontSize = 16.0
    static let bodyLineHeight = 1.6
    static let paragraphGap = CGFloat(12.8)
    static let listItemGap = CGFloat(5)
    static let unorderedListMarkerScale = CGFloat(1.22)
    static let listMarkerExtraSpacing = CGFloat(6)
    static let editorHorizontalInset = CGFloat(28)
    static let editorVerticalInset = CGFloat(30)
    static let blockCornerRadius = CGFloat(4)
    static let inlineCodeScale = 0.88
    static let inlineCodeHorizontalPadding = CGFloat(4)
    static let inlineCodeVerticalPadding = CGFloat(2)
    static let inlineCodeCornerRadius = CGFloat(4)
    static let codeBlockLineHeight = CGFloat(1.5)
    static let tableCellHorizontalPadding = CGFloat(12)
    static let tableCellVerticalPadding = CGFloat(8)

    static let bodyFontFamilyCSS = "\"Open Sans\", \"Helvetica Neue\", Helvetica, Arial, \"PingFang SC\", sans-serif"

    static func bodyFont(size: CGFloat) -> NSFont {
        NSFont(name: "OpenSans", size: size)
            ?? NSFont(name: "Helvetica Neue", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

    static func headingLineHeight(level: Int) -> Double {
        switch level {
        case 1: 1.2
        case 2: 1.225
        case 3: 1.43
        default: 1.4
        }
    }

    static func heading(level: Int) -> MarkdownHeadingStyle {
        let scale: Double = switch level {
        case 1: 2.25
        case 2: 1.75
        case 3: 1.5
        case 4: 1.25
        default: 1.0
        }
        return MarkdownHeadingStyle(scale: scale, spacingBefore: 1, spacingAfter: 1)
    }
}

struct MarkdownRenderPalette: Equatable, Sendable {
    static let light = Self(
        canvas: "#ffffff",
        text: "#333333",
        heading: "#333333",
        secondaryText: "#737982",
        accent: "#2f6fda",
        border: "#dfe3e8",
        quoteBar: "#c3cad5",
        subtleSurface: "#f8f8f8",
        mutedSurface: "#eef1f5",
        tableStripe: "#fafbfc",
        inlineCode: "#edf0f4",
        keyword: "#b42318",
        type: "#6941c6",
        string: "#175cd3",
        number: "#026aa2",
        comment: "#697386",
        tag: "#067647",
        warning: "#9a6700"
    )

    static let dark = Self(
        canvas: "#0f1115",
        text: "#dfe4ea",
        heading: "#f1f4f7",
        secondaryText: "#9ba7b4",
        accent: "#79a8ff",
        border: "#303744",
        quoteBar: "#4a5565",
        subtleSurface: "#171b22",
        mutedSurface: "#202630",
        tableStripe: "#141820",
        inlineCode: "#252b35",
        keyword: "#ff8a80",
        type: "#c4a7ff",
        string: "#9cc2ff",
        number: "#7cd4fd",
        comment: "#9ba7b4",
        tag: "#75e0a7",
        warning: "#e0b450"
    )

    var canvas: String
    var text: String
    var heading: String
    var secondaryText: String
    var accent: String
    var border: String
    var quoteBar: String
    var subtleSurface: String
    var mutedSurface: String
    var tableStripe: String
    var inlineCode: String
    var keyword: String
    var type: String
    var string: String
    var number: String
    var comment: String
    var tag: String
    var warning: String

    @MainActor
    static func resolved(for appearance: NSAppearance, theme: PreviewTheme = .standard) -> Self {
        let scheme = theme.styles.value("color-scheme")
        let isDark = scheme == "dark" || (scheme != "light" && appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        var palette: Self = isDark ? .dark : .light
        if theme == .highContrast {
            palette.text = isDark ? "#ffffff" : "#111111"
            palette.heading = palette.text
            palette.secondaryText = isDark ? "#dddddd" : "#444444"
            palette.border = isDark ? "#a0a0a0" : "#666666"
            palette.quoteBar = palette.border
        }
        return theme.styles.applying(to: palette)
    }

    var cssVariables: String {
        """
        --md-canvas: \(canvas); --md-text: \(text); --md-heading: \(heading);
        --md-secondary: \(secondaryText); --md-accent: \(accent); --md-border: \(border);
        --md-quote-bar: \(quoteBar); --md-surface: \(subtleSurface);
        --md-surface-strong: \(mutedSurface); --md-table-stripe: \(tableStripe);
        --md-inline-code: \(inlineCode); --md-keyword: \(keyword); --md-type: \(type);
        --md-string: \(string); --md-number: \(number); --md-comment: \(comment);
        --md-tag: \(tag); --md-warning: \(warning);
        """
    }

    var canvasColor: NSColor { color(canvas) }
    var textColor: NSColor { color(text) }
    var headingColor: NSColor { color(heading) }
    var secondaryTextColor: NSColor { color(secondaryText) }
    var accentColor: NSColor { color(accent) }
    var borderColor: NSColor { color(border) }
    var quoteBarColor: NSColor { color(quoteBar) }
    var subtleSurfaceColor: NSColor { color(subtleSurface) }
    var mutedSurfaceColor: NSColor { color(mutedSurface) }
    var tableStripeColor: NSColor { color(tableStripe) }
    var inlineCodeColor: NSColor { color(inlineCode) }

    private func color(_ value: String) -> NSColor {
        NativeCSSStyles.color(value) ?? .textColor
    }
}

struct SourceEditorAppearance: Equatable, Sendable {
    static let `default` = Self(
        fontSize: 15,
        lineHeight: 1.6,
        spellingEnabled: true,
        wrapsLines: true,
        showsLineNumbers: false
    )

    let fontSize: Double
    let lineHeight: Double
    let spellingEnabled: Bool
    let wrapsLines: Bool
    let showsLineNumbers: Bool
    let autoPairEnabled: Bool

    init(
        fontSize: Double,
        lineHeight: Double,
        spellingEnabled: Bool,
        wrapsLines: Bool = true,
        showsLineNumbers: Bool = false,
        autoPairEnabled: Bool = true
    ) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.spellingEnabled = spellingEnabled
        self.wrapsLines = wrapsLines
        self.showsLineNumbers = showsLineNumbers
        self.autoPairEnabled = autoPairEnabled
    }
}

enum PreviewColorScheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    @MainActor
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

enum LinkActivationPreference: String, CaseIterable, Identifiable, Sendable {
    case singleClick
    case contextMenu

    var id: Self { self }

    var label: String {
        switch self {
        case .singleClick: "预览单击打开，编辑时 ⌘+单击"
        case .contextMenu: "仅从右键菜单打开"
        }
    }
}

enum AutosaveDelay: String, CaseIterable, Identifiable, Sendable {
    case halfSecond = "0.5"
    case oneSecond = "1"
    case twoSeconds = "2"
    case fiveSeconds = "5"

    var id: Self { self }

    var seconds: TimeInterval {
        switch self {
        case .halfSecond: 0.5
        case .oneSecond: 1
        case .twoSeconds: 2
        case .fiveSeconds: 5
        }
    }

    var label: String {
        switch self {
        case .halfSecond: "0.5 秒"
        case .oneSecond: "1 秒"
        case .twoSeconds: "2 秒"
        case .fiveSeconds: "5 秒"
        }
    }
}

enum AccessibilityPreference: String, CaseIterable, Identifiable, Sendable {
    case followSystem
    case enabled
    case disabled

    var id: Self { self }

    var label: String {
        switch self {
        case .followSystem: "跟随系统"
        case .enabled: "开启"
        case .disabled: "关闭"
        }
    }

    func resolve(systemValue: Bool) -> Bool {
        switch self {
        case .followSystem: systemValue
        case .enabled: true
        case .disabled: false
        }
    }
}

enum AppPreferenceGroup: String, CaseIterable, Identifiable, Sendable {
    case general
    case workspace
    case writing
    case preview
    case resources
    case accessibility

    var id: Self { self }

    var label: String {
        switch self {
        case .general: "通用"
        case .workspace: "工作区"
        case .writing: "写作"
        case .preview: "预览"
        case .resources: "资源"
        case .accessibility: "辅助功能"
        }
    }
}

struct PreviewAppearanceConfiguration: Equatable, Sendable {
    static let `default` = Self(
        contentWidth: MarkdownRenderMetrics.previewReadingWidth,
        zoom: 1,
        colorScheme: .system,
        theme: .standard,
        increasedContrast: false,
        reduceMotion: false,
        mathRenderingEnabled: true,
        mermaidRenderingEnabled: true
    )

    /// The personal milestone has one intentionally fixed PDF treatment. It
    /// must not inherit a dark/system preview or any later preference surface.
    static let personalPDF = Self(
        contentWidth: MarkdownRenderMetrics.readingWidth,
        zoom: 1,
        colorScheme: .light,
        theme: .standard,
        increasedContrast: false,
        reduceMotion: true,
        mathRenderingEnabled: true,
        mermaidRenderingEnabled: true
    )

    let fontSize: Double
    let lineHeight: Double
    let contentWidth: Double
    let zoom: Double
    let colorScheme: PreviewColorScheme
    let theme: PreviewTheme
    let increasedContrast: Bool
    let reduceMotion: Bool
    let mathRenderingEnabled: Bool
    let mermaidRenderingEnabled: Bool

    init(
        contentWidth: Double,
        zoom: Double,
        colorScheme: PreviewColorScheme,
        theme: PreviewTheme,
        increasedContrast: Bool,
        reduceMotion: Bool,
        mathRenderingEnabled: Bool = true,
        mermaidRenderingEnabled: Bool = true,
        fontSize: Double = MarkdownRenderMetrics.bodyFontSize,
        lineHeight: Double? = nil
    ) {
        let themeSize = min(72, max(6, Double(theme.styles.length("font-size") ?? CGFloat(MarkdownRenderMetrics.bodyFontSize))))
        self.fontSize = fontSize * themeSize / MarkdownRenderMetrics.bodyFontSize
        self.lineHeight = lineHeight ?? min(2.5, max(1, Double(theme.styles.value("line-height") ?? "") ?? MarkdownRenderMetrics.bodyLineHeight))
        self.contentWidth = contentWidth
        self.zoom = zoom
        self.colorScheme = colorScheme
        self.theme = theme
        self.increasedContrast = increasedContrast
        self.reduceMotion = reduceMotion
        self.mathRenderingEnabled = mathRenderingEnabled
        self.mermaidRenderingEnabled = mermaidRenderingEnabled
    }

    func nativeRenderedAppearance(spellingEnabled: Bool, autoPairEnabled: Bool = true) -> SourceEditorAppearance {
        return SourceEditorAppearance(
            fontSize: fontSize * zoom,
            lineHeight: lineHeight,
            spellingEnabled: spellingEnabled,
            wrapsLines: true,
            showsLineNumbers: false,
            autoPairEnabled: autoPairEnabled
        )
    }

}

@MainActor
protocol AppPreferencePersistence: AnyObject {
    func persist(_ values: [String: Any]) -> Bool
}

@MainActor
final class UserDefaultsAppPreferencePersistence: AppPreferencePersistence {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func persist(_ values: [String: Any]) -> Bool {
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        guard defaults.synchronize() else { return false }
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

struct SettingsPersistenceFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
}

@MainActor
final class AppPreferences: ObservableObject {
    enum Limits {
        static let editorFontSize = 12.0 ... 28.0
        static let editorLineHeight = 1.2 ... 2.0
        static let previewContentWidth = 600.0 ... 1_800.0
        static let previewZoom = 0.5 ... 2.0
        static let workspaceSplitFraction = EditorSplitLayout.allowedFraction
        static let projectSidebarWidth =
            Double(EditorWorkspaceMetrics.projectSidebarMinimumWidth)
                ... Double(EditorWorkspaceMetrics.projectSidebarMaximumWidth)
        static let outlineWidth =
            Double(EditorWorkspaceMetrics.outlineMinimumWidth)
                ... Double(EditorWorkspaceMetrics.outlineMaximumWidth)
    }

    private enum Key {
        static let renderedFontSize = "preferences.rendered.fontSize"
        static let editorFontSize = "preferences.editor.fontSize"
        static let editorLineHeight = "preferences.editor.lineHeight"
        static let autoPairEnabled = "preferences.editor.autoPairEnabled"
        static let syntaxHighlightingEnabled = "preferences.editor.syntaxHighlightingEnabled"
        static let spellingEnabled = "preferences.editor.spellingEnabled"
        static let wrapsLines = "preferences.editor.wrapsLines"
        static let showsLineNumbers = "preferences.editor.showsLineNumbers"
        static let scrollSyncEnabled = "preferences.preview.scrollSyncEnabled"
        static let headingNavigationEnabled = "preferences.preview.headingNavigationEnabled"
        static let previewContentWidth = "preferences.preview.contentWidth"
        static let previewWidthMigration = "preferences.preview.widthMigration3"
        static let previewZoom = "preferences.preview.zoom"
        static let previewColorScheme = "preferences.preview.colorScheme"
        static let previewTheme = "preferences.preview.theme"
        static let mathRenderingEnabled = "preferences.preview.mathRenderingEnabled"
        static let mermaidRenderingEnabled = "preferences.preview.mermaidRenderingEnabled"
        static let linkActivation = "preferences.preview.linkActivation"
        static let increasedContrast = "preferences.accessibility.increasedContrast"
        static let reduceMotion = "preferences.accessibility.reduceMotion"
        // Version-1 layout keys remain registered as migration artifacts.
        static let legacyLastActiveEditorViewMode =
            "preferences.window.lastActiveEditorViewMode"
        static let legacyDefaultProjectSidebarVisible =
            "preferences.window.defaultProjectSidebarVisible"
        static let legacyDefaultOutlineVisible = "preferences.window.defaultOutlineVisible"
        static let legacyDefaultSplitFraction = "preferences.preview.defaultSplitFraction"
        static let workspaceViewMode = "preferences.workspace.viewMode"
        static let workspaceProjectSidebarVisible =
            "preferences.workspace.projectSidebarVisible"
        static let workspaceOutlineVisible = "preferences.workspace.outlineVisible"
        static let workspaceSplitFraction = "preferences.workspace.splitFraction"
        static let workspaceProjectSidebarWidth =
            "preferences.workspace.projectSidebarWidth"
        static let workspaceOutlineWidth = "preferences.workspace.outlineWidth"
        static let autosaveEnabled = "preferences.documents.autosaveEnabled"
        static let autosaveDelay = "preferences.documents.autosaveDelay"
        static let existingImagePlacement = "preferences.resources.existingImagePlacement"
    }

    enum Registry {
        static let currentSchemaVersion = 2
        static let schemaVersionKey = "preferences.schemaVersion"
        static let knownKeys: Set<String> = [
            schemaVersionKey,
            Key.renderedFontSize,
            Key.editorFontSize,
            Key.editorLineHeight,
            Key.syntaxHighlightingEnabled,
            Key.autoPairEnabled,
            Key.spellingEnabled,
            Key.wrapsLines,
            Key.showsLineNumbers,
            Key.scrollSyncEnabled,
            Key.headingNavigationEnabled,
            Key.previewContentWidth,
            Key.previewWidthMigration,
            Key.previewZoom,
            Key.previewColorScheme,
            Key.previewTheme,
            Key.mathRenderingEnabled,
            Key.mermaidRenderingEnabled,
            Key.linkActivation,
            Key.increasedContrast,
            Key.reduceMotion,
            Key.legacyLastActiveEditorViewMode,
            Key.legacyDefaultProjectSidebarVisible,
            Key.legacyDefaultOutlineVisible,
            Key.legacyDefaultSplitFraction,
            Key.workspaceViewMode,
            Key.workspaceProjectSidebarVisible,
            Key.workspaceOutlineVisible,
            Key.workspaceSplitFraction,
            Key.workspaceProjectSidebarWidth,
            Key.workspaceOutlineWidth,
            Key.autosaveEnabled,
            Key.autosaveDelay,
            Key.existingImagePlacement,
            RecentDocumentPolicy.capacityKey,
            RecentDocumentPolicy.openBehaviorKey,
        ]

        /// Version 1 adopted pre-registry keys. Version 2 moves every workspace
        /// choice into one application-wide namespace; existing layout choices
        /// are copied once and remain valid after upgrading.
        static func migrate(_ defaults: UserDefaults) {
            let storedVersion = defaults.object(forKey: schemaVersionKey) == nil
                ? 0
                : defaults.integer(forKey: schemaVersionKey)
            guard storedVersion >= 0, storedVersion < currentSchemaVersion else {
                return
            }
            if storedVersion < 2 {
                copyIfMissing(
                    from: Key.legacyDefaultProjectSidebarVisible,
                    to: Key.workspaceProjectSidebarVisible,
                    in: defaults
                )
                copyIfMissing(
                    from: Key.legacyDefaultOutlineVisible,
                    to: Key.workspaceOutlineVisible,
                    in: defaults
                )
                copyIfMissing(
                    from: Key.legacyDefaultSplitFraction,
                    to: Key.workspaceSplitFraction,
                    in: defaults
                )
                if defaults.object(forKey: Key.workspaceViewMode) == nil,
                   let legacyMode = defaults.string(
                       forKey: Key.legacyLastActiveEditorViewMode
                   ),
                   let mode = EditorViewMode(rawValue: legacyMode)
                {
                    defaults.set(
                        WorkspaceViewModePreference(mode: mode).rawValue,
                        forKey: Key.workspaceViewMode
                    )
                }
            }
            defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
        }

        private static func copyIfMissing(
            from sourceKey: String,
            to targetKey: String,
            in defaults: UserDefaults
        ) {
            guard defaults.object(forKey: targetKey) == nil,
                  let value = defaults.object(forKey: sourceKey)
            else { return }
            defaults.set(value, forKey: targetKey)
        }
    }

    /// Defaults for the personal launch profile. Most growth settings remain
    /// fixed, while the workspace values seed durable user preferences when no
    /// saved value exists.
    enum LaunchFixed {
        static let editorLineHeight = 1.6
        static let spellingEnabled = true
        static let wrapsLines = true
        static let showsLineNumbers = false
        static let previewZoom = 1.0
        static let previewTheme = PreviewTheme.standard
        static let mathRenderingEnabled = true
        static let mermaidRenderingEnabled = true
        static let linkActivation = LinkActivationPreference.singleClick
        static let increasedContrast = AccessibilityPreference.followSystem
        static let reduceMotion = AccessibilityPreference.followSystem
        static let recentDocumentCapacity = 20
        static let markdownOpenBehavior = MarkdownOpenBehavior.reuseBlankWindow
        static let workspaceViewMode = WorkspaceViewModePreference.automatic
        static let workspaceProjectSidebarVisible = true
        static let workspaceOutlineVisible = false
        static let workspaceSplitFraction = EditorSplitLayout.defaultFraction
        static let workspaceProjectSidebarWidth =
            Double(EditorWorkspaceMetrics.projectSidebarIdealWidth)
        static let workspaceOutlineWidth = Double(EditorWorkspaceMetrics.outlineIdealWidth)
        static let autosaveDelay = AutosaveDelay.oneSecond
        static let autosaveEnabled = false
        static let existingImagePlacement = ExistingImagePlacementPreference.copyToAssets
    }

    private let defaults: UserDefaults
    private let persistence: any AppPreferencePersistence
    private var accessibilityObserver: AnyCancellable?
    private var themeRefreshTimer: AnyCancellable?
    let themeDirectory: URL
    @Published private(set) var availableThemes: [PreviewTheme] = PreviewTheme.allCases
    @Published private(set) var themeLoadMessage: String?

    @Published private(set) var persistenceFailure: SettingsPersistenceFailure?

    @Published var renderedFontSize: Double {
        didSet {
            let value = Self.clamped(renderedFontSize, range: Limits.editorFontSize)
            if renderedFontSize != value { renderedFontSize = value }
            persist(value, forKey: Key.renderedFontSize)
        }
    }

    @Published var editorFontSize: Double {
        didSet {
            let clamped = Self.clamped(editorFontSize, range: Limits.editorFontSize)
            guard clamped == editorFontSize else {
                editorFontSize = clamped
                persist(clamped, forKey: Key.editorFontSize)
                return
            }
            persist(clamped, forKey: Key.editorFontSize)
        }
    }

    @Published var editorLineHeight: Double {
        didSet {
            let clamped = Self.clamped(editorLineHeight, range: Limits.editorLineHeight)
            guard clamped == editorLineHeight else {
                editorLineHeight = clamped
                persist(clamped, forKey: Key.editorLineHeight)
                return
            }
            persist(clamped, forKey: Key.editorLineHeight)
        }
    }

    @Published var spellingEnabled: Bool {
        didSet { persist(spellingEnabled, forKey: Key.spellingEnabled) }
    }

    @Published var autoPairEnabled: Bool {
        didSet { persist(autoPairEnabled, forKey: Key.autoPairEnabled) }
    }

    @Published var syntaxHighlightingEnabled: Bool {
        didSet {
            persist(syntaxHighlightingEnabled, forKey: Key.syntaxHighlightingEnabled)
        }
    }

    @Published var wrapsLines: Bool {
        didSet { persist(wrapsLines, forKey: Key.wrapsLines) }
    }

    @Published var showsLineNumbers: Bool {
        didSet { persist(showsLineNumbers, forKey: Key.showsLineNumbers) }
    }

    @Published var scrollSyncEnabled: Bool {
        didSet { persist(scrollSyncEnabled, forKey: Key.scrollSyncEnabled) }
    }

    @Published var headingNavigationEnabled: Bool {
        didSet { persist(headingNavigationEnabled, forKey: Key.headingNavigationEnabled) }
    }

    @Published var previewContentWidth: Double {
        didSet {
            let clamped = Self.clamped(previewContentWidth, range: Limits.previewContentWidth)
            guard clamped == previewContentWidth else {
                previewContentWidth = clamped
                persist(clamped, forKey: Key.previewContentWidth)
                return
            }
            persist(clamped, forKey: Key.previewContentWidth)
        }
    }

    @Published var previewZoom: Double {
        didSet {
            let clamped = Self.clamped(previewZoom, range: Limits.previewZoom)
            guard clamped == previewZoom else {
                previewZoom = clamped
                persist(clamped, forKey: Key.previewZoom)
                return
            }
            persist(clamped, forKey: Key.previewZoom)
        }
    }

    @Published var previewColorScheme: PreviewColorScheme {
        didSet { persist(previewColorScheme.rawValue, forKey: Key.previewColorScheme) }
    }

    @Published var previewTheme: PreviewTheme {
        didSet { persist(previewTheme.rawValue, forKey: Key.previewTheme) }
    }

    @Published var mathRenderingEnabled: Bool {
        didSet { persist(mathRenderingEnabled, forKey: Key.mathRenderingEnabled) }
    }

    @Published var mermaidRenderingEnabled: Bool {
        didSet { persist(mermaidRenderingEnabled, forKey: Key.mermaidRenderingEnabled) }
    }

    @Published var linkActivation: LinkActivationPreference {
        didSet { persist(linkActivation.rawValue, forKey: Key.linkActivation) }
    }

    @Published var increasedContrast: AccessibilityPreference {
        didSet { persist(increasedContrast.rawValue, forKey: Key.increasedContrast) }
    }

    @Published var reduceMotion: AccessibilityPreference {
        didSet { persist(reduceMotion.rawValue, forKey: Key.reduceMotion) }
    }

    @Published var workspaceViewMode: WorkspaceViewModePreference {
        didSet { persist(workspaceViewMode.rawValue, forKey: Key.workspaceViewMode) }
    }

    @Published var workspaceProjectSidebarVisible: Bool {
        didSet {
            persist(
                workspaceProjectSidebarVisible,
                forKey: Key.workspaceProjectSidebarVisible
            )
        }
    }

    @Published var workspaceOutlineVisible: Bool {
        didSet { persist(workspaceOutlineVisible, forKey: Key.workspaceOutlineVisible) }
    }

    @Published var workspaceSplitFraction: Double {
        didSet {
            let clamped = Self.clamped(
                workspaceSplitFraction,
                range: Limits.workspaceSplitFraction
            )
            guard clamped == workspaceSplitFraction else {
                workspaceSplitFraction = clamped
                persist(clamped, forKey: Key.workspaceSplitFraction)
                return
            }
            persist(clamped, forKey: Key.workspaceSplitFraction)
        }
    }

    @Published var workspaceProjectSidebarWidth: Double {
        didSet {
            let clamped = Self.clamped(
                workspaceProjectSidebarWidth,
                range: Limits.projectSidebarWidth
            )
            guard clamped == workspaceProjectSidebarWidth else {
                workspaceProjectSidebarWidth = clamped
                persist(clamped, forKey: Key.workspaceProjectSidebarWidth)
                return
            }
            persist(clamped, forKey: Key.workspaceProjectSidebarWidth)
        }
    }

    @Published var workspaceOutlineWidth: Double {
        didSet {
            let clamped = Self.clamped(
                workspaceOutlineWidth,
                range: Limits.outlineWidth
            )
            guard clamped == workspaceOutlineWidth else {
                workspaceOutlineWidth = clamped
                persist(clamped, forKey: Key.workspaceOutlineWidth)
                return
            }
            persist(clamped, forKey: Key.workspaceOutlineWidth)
        }
    }

    @Published var recentDocumentCapacity: Int {
        didSet {
            let clamped = RecentDocumentPolicy.clampCapacity(recentDocumentCapacity)
            guard clamped == recentDocumentCapacity else {
                recentDocumentCapacity = clamped
                persist(clamped, forKey: RecentDocumentPolicy.capacityKey)
                return
            }
            persist(clamped, forKey: RecentDocumentPolicy.capacityKey)
        }
    }

    @Published var markdownOpenBehavior: MarkdownOpenBehavior {
        didSet {
            persist(
                markdownOpenBehavior.rawValue,
                forKey: RecentDocumentPolicy.openBehaviorKey
            )
        }
    }

    @Published var autosaveEnabled: Bool {
        didSet {
            persist(autosaveEnabled, forKey: Key.autosaveEnabled)
            applyAutosavePolicy()
        }
    }

    @Published var autosaveDelay: AutosaveDelay {
        didSet {
            persist(autosaveDelay.rawValue, forKey: Key.autosaveDelay)
            applyAutosavePolicy()
        }
    }

    @Published var existingImagePlacement: ExistingImagePlacementPreference {
        didSet {
            persist(existingImagePlacement.rawValue, forKey: Key.existingImagePlacement)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        persistence: (any AppPreferencePersistence)? = nil,
        themeDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.themeDirectory = themeDirectory ?? ThemeCatalog.defaultDirectory
        self.persistence = persistence ?? UserDefaultsAppPreferencePersistence(defaults: defaults)
        Registry.migrate(defaults)
        persistenceFailure = nil
        renderedFontSize = Self.number(forKey: Key.renderedFontSize, in: defaults,
            defaultValue: MarkdownRenderMetrics.bodyFontSize, range: Limits.editorFontSize)
        editorFontSize = Self.number(
            forKey: Key.editorFontSize,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.fontSize,
            range: Limits.editorFontSize
        )
        editorLineHeight = Self.number(forKey: Key.editorLineHeight, in: defaults,
            defaultValue: LaunchFixed.editorLineHeight, range: Limits.editorLineHeight)
        autoPairEnabled = Self.bool(forKey: Key.autoPairEnabled, in: defaults, defaultValue: true)
        syntaxHighlightingEnabled = Self.bool(
            forKey: Key.syntaxHighlightingEnabled,
            in: defaults,
            defaultValue: true
        )
        spellingEnabled = Self.bool(forKey: Key.spellingEnabled, in: defaults, defaultValue: LaunchFixed.spellingEnabled)
        wrapsLines = Self.bool(forKey: Key.wrapsLines, in: defaults, defaultValue: LaunchFixed.wrapsLines)
        showsLineNumbers = Self.bool(forKey: Key.showsLineNumbers, in: defaults, defaultValue: LaunchFixed.showsLineNumbers)
        scrollSyncEnabled = Self.bool(
            forKey: Key.scrollSyncEnabled,
            in: defaults,
            defaultValue: true
        )
        headingNavigationEnabled = Self.bool(
            forKey: Key.headingNavigationEnabled,
            in: defaults,
            defaultValue: true
        )
        if defaults.object(forKey: Key.previewWidthMigration) == nil {
            // Upgrade the two historical defaults once. Subsequent explicit
            // narrow-width choices survive relaunch, as do other custom widths.
            let previousWidth = defaults.double(forKey: Key.previewContentWidth)
            if previousWidth == 760 || previousWidth == 800 {
                defaults.set(MarkdownRenderMetrics.previewReadingWidth, forKey: Key.previewContentWidth)
            }
            defaults.set(true, forKey: Key.previewWidthMigration)
        }
        previewContentWidth = Self.number(
            forKey: Key.previewContentWidth,
            in: defaults,
            defaultValue: PreviewAppearanceConfiguration.default.contentWidth,
            range: Limits.previewContentWidth
        )
        previewZoom = Self.number(forKey: Key.previewZoom, in: defaults,
            defaultValue: LaunchFixed.previewZoom, range: Limits.previewZoom)
        previewColorScheme = Self.enumeration(
            PreviewColorScheme.self,
            forKey: Key.previewColorScheme,
            in: defaults,
            defaultValue: .system
        )
        previewTheme = Self.enumeration(PreviewTheme.self, forKey: Key.previewTheme,
            in: defaults, defaultValue: .standard)
        mathRenderingEnabled = LaunchFixed.mathRenderingEnabled
        mermaidRenderingEnabled = LaunchFixed.mermaidRenderingEnabled
        linkActivation = Self.enumeration(
            LinkActivationPreference.self,
            forKey: Key.linkActivation,
            in: defaults,
            defaultValue: LaunchFixed.linkActivation
        )
        increasedContrast = LaunchFixed.increasedContrast
        reduceMotion = LaunchFixed.reduceMotion
        workspaceViewMode = Self.enumeration(
            WorkspaceViewModePreference.self,
            forKey: Key.workspaceViewMode,
            in: defaults,
            defaultValue: LaunchFixed.workspaceViewMode
        )
        workspaceProjectSidebarVisible = Self.bool(
            forKey: Key.workspaceProjectSidebarVisible,
            in: defaults,
            defaultValue: LaunchFixed.workspaceProjectSidebarVisible
        )
        workspaceOutlineVisible = Self.bool(
            forKey: Key.workspaceOutlineVisible,
            in: defaults,
            defaultValue: LaunchFixed.workspaceOutlineVisible
        )
        workspaceSplitFraction = Self.number(
            forKey: Key.workspaceSplitFraction,
            in: defaults,
            defaultValue: LaunchFixed.workspaceSplitFraction,
            range: Limits.workspaceSplitFraction
        )
        workspaceProjectSidebarWidth = Self.number(
            forKey: Key.workspaceProjectSidebarWidth,
            in: defaults,
            defaultValue: LaunchFixed.workspaceProjectSidebarWidth,
            range: Limits.projectSidebarWidth
        )
        workspaceOutlineWidth = Self.number(
            forKey: Key.workspaceOutlineWidth,
            in: defaults,
            defaultValue: LaunchFixed.workspaceOutlineWidth,
            range: Limits.outlineWidth
        )
        recentDocumentCapacity = LaunchFixed.recentDocumentCapacity
        markdownOpenBehavior = LaunchFixed.markdownOpenBehavior
        autosaveEnabled = LaunchFixed.autosaveEnabled
        autosaveDelay = LaunchFixed.autosaveDelay
        existingImagePlacement = LaunchFixed.existingImagePlacement

        if defaults === UserDefaults.standard || themeDirectory != nil {
            reloadThemes()
            if defaults === UserDefaults.standard {
                themeRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                    self?.reloadThemes()
                }
            }
        } else if previewTheme.css.isEmpty && previewTheme != .highContrast {
            previewTheme = .standard
        }
        persistCurrentValues()
        accessibilityObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
    }

    func reloadThemes() {
        do {
            let result = try ThemeCatalog(directory: themeDirectory).load()
            if availableThemes != result.themes { availableThemes = result.themes }
            let selected = result.themes.first { $0.rawValue == previewTheme.rawValue }
                ?? ([PreviewTheme.code, .highContrast].first { $0.rawValue == previewTheme.rawValue }) ?? .standard
            if previewTheme != selected { previewTheme = selected }
            let message = result.issues.isEmpty ? nil : result.issues.joined(separator: "\n")
            if themeLoadMessage != message { themeLoadMessage = message }
        } catch { themeLoadMessage = "无法读取主题目录；继续使用当前主题。" }
    }

    func openThemeDirectory() {
        reloadThemes()
        NSWorkspace.shared.open(themeDirectory)
    }

    var sourceEditorAppearance: SourceEditorAppearance {
        SourceEditorAppearance(
            fontSize: editorFontSize,
            lineHeight: editorLineHeight,
            spellingEnabled: spellingEnabled,
            wrapsLines: wrapsLines,
            showsLineNumbers: showsLineNumbers,
            autoPairEnabled: autoPairEnabled
        )
    }

    var previewConfiguration: PreviewAppearanceConfiguration {
        let workspace = NSWorkspace.shared
        return PreviewAppearanceConfiguration(
            contentWidth: previewContentWidth,
            zoom: previewZoom,
            colorScheme: previewColorScheme,
            theme: previewTheme,
            increasedContrast: increasedContrast.resolve(
                systemValue: workspace.accessibilityDisplayShouldIncreaseContrast
            ),
            reduceMotion: reduceMotion.resolve(
                systemValue: workspace.accessibilityDisplayShouldReduceMotion
            ),
            mathRenderingEnabled: mathRenderingEnabled,
            mermaidRenderingEnabled: mermaidRenderingEnabled,
            fontSize: renderedFontSize,
            lineHeight: editorLineHeight == MarkdownRenderMetrics.bodyLineHeight ? nil : editorLineHeight
        )
    }

    func applyAutosavePolicy(to documentController: NSDocumentController = .shared) {
        // The personal validation milestone is deliberately manual-save only.
        // Keep AppKit automatic saving disabled even if a development build left
        // an older preference behind.
        documentController.autosavingDelay = 0
    }

    func reset(_ group: AppPreferenceGroup) {
        switch group {
        case .general:
            autosaveEnabled = LaunchFixed.autosaveEnabled
            autosaveDelay = .oneSecond
            recentDocumentCapacity = RecentDocumentPolicy.defaultCapacity
            markdownOpenBehavior = LaunchFixed.markdownOpenBehavior
        case .workspace:
            workspaceViewMode = LaunchFixed.workspaceViewMode
            workspaceProjectSidebarVisible = LaunchFixed.workspaceProjectSidebarVisible
            workspaceOutlineVisible = LaunchFixed.workspaceOutlineVisible
            workspaceSplitFraction = LaunchFixed.workspaceSplitFraction
            workspaceProjectSidebarWidth = LaunchFixed.workspaceProjectSidebarWidth
            workspaceOutlineWidth = LaunchFixed.workspaceOutlineWidth
        case .writing:
            resetWriting()
        case .preview:
            resetPreview()
        case .resources:
            existingImagePlacement = .copyToAssets
        case .accessibility:
            increasedContrast = .followSystem
            reduceMotion = .followSystem
        }
    }

    func resetAll() {
        for group in AppPreferenceGroup.allCases {
            reset(group)
        }
    }

    func retryPersistence() {
        persistCurrentValues()
    }

    func continueUsingSessionPreferences() {
        persistenceFailure = nil
    }

    private func resetWriting() {
        renderedFontSize = MarkdownRenderMetrics.bodyFontSize
        editorFontSize = SourceEditorAppearance.default.fontSize
        editorLineHeight = SourceEditorAppearance.default.lineHeight
        syntaxHighlightingEnabled = true
        autoPairEnabled = true
        spellingEnabled = SourceEditorAppearance.default.spellingEnabled
        wrapsLines = SourceEditorAppearance.default.wrapsLines
        showsLineNumbers = SourceEditorAppearance.default.showsLineNumbers
    }

    private func resetPreview() {
        scrollSyncEnabled = true
        headingNavigationEnabled = true
        previewContentWidth = PreviewAppearanceConfiguration.default.contentWidth
        previewZoom = PreviewAppearanceConfiguration.default.zoom
        previewColorScheme = .system
        previewTheme = .standard
        mathRenderingEnabled = LaunchFixed.mathRenderingEnabled
        mermaidRenderingEnabled = LaunchFixed.mermaidRenderingEnabled
        linkActivation = LaunchFixed.linkActivation
    }

    private func persistCurrentValues() {
        let succeeded = persistence.persist([
                Key.renderedFontSize: renderedFontSize,
                Key.editorFontSize: editorFontSize,
                Key.editorLineHeight: editorLineHeight,
                Key.syntaxHighlightingEnabled: syntaxHighlightingEnabled,
                Key.autoPairEnabled: autoPairEnabled,
                Key.spellingEnabled: spellingEnabled,
                Key.wrapsLines: wrapsLines,
                Key.showsLineNumbers: showsLineNumbers,
                Key.scrollSyncEnabled: scrollSyncEnabled,
                Key.headingNavigationEnabled: headingNavigationEnabled,
                Key.previewContentWidth: previewContentWidth,
                Key.previewZoom: previewZoom,
                Key.previewColorScheme: previewColorScheme.rawValue,
                Key.previewTheme: previewTheme.rawValue,
                Key.mathRenderingEnabled: mathRenderingEnabled,
                Key.mermaidRenderingEnabled: mermaidRenderingEnabled,
                Key.linkActivation: linkActivation.rawValue,
                Key.increasedContrast: increasedContrast.rawValue,
                Key.reduceMotion: reduceMotion.rawValue,
                Key.workspaceViewMode: workspaceViewMode.rawValue,
                Key.workspaceProjectSidebarVisible: workspaceProjectSidebarVisible,
                Key.workspaceOutlineVisible: workspaceOutlineVisible,
                Key.workspaceSplitFraction: workspaceSplitFraction,
                Key.workspaceProjectSidebarWidth: workspaceProjectSidebarWidth,
                Key.workspaceOutlineWidth: workspaceOutlineWidth,
                RecentDocumentPolicy.capacityKey: recentDocumentCapacity,
                RecentDocumentPolicy.openBehaviorKey: markdownOpenBehavior.rawValue,
                Key.autosaveEnabled: autosaveEnabled,
                Key.autosaveDelay: autosaveDelay.rawValue,
                Key.existingImagePlacement: existingImagePlacement.rawValue,
            ])
        persistenceFailure = succeeded ? nil : SettingsPersistenceFailure()
    }

    private func persist(_ value: Any, forKey key: String) {
        if !persistence.persist([key: value]) {
            persistenceFailure = SettingsPersistenceFailure()
        }
    }

    private static func clamped(_ value: Double, range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }

    private static func number(
        forKey key: String,
        in defaults: UserDefaults,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return defaultValue
        }
        let value = number.doubleValue
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func bool(
        forKey key: String,
        in defaults: UserDefaults,
        defaultValue: Bool
    ) -> Bool {
        guard let value = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            return defaultValue
        }
        return value.boolValue
    }

    private static func enumeration<Value: RawRepresentable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults,
        defaultValue: Value
    ) -> Value where Value.RawValue == String {
        guard let rawValue = defaults.string(forKey: key),
              let value = Value(rawValue: rawValue)
        else {
            return defaultValue
        }
        return value
    }
}
