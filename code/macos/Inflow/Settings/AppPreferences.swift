import AppKit
import Combine
import Foundation

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

    init(
        fontSize: Double,
        lineHeight: Double,
        spellingEnabled: Bool,
        wrapsLines: Bool = true,
        showsLineNumbers: Bool = false
    ) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.spellingEnabled = spellingEnabled
        self.wrapsLines = wrapsLines
        self.showsLineNumbers = showsLineNumbers
    }
}

enum PreviewColorScheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

enum PreviewTheme: String, CaseIterable, Identifiable, Sendable {
    case standard
    case longform
    case code
    case highContrast

    var id: Self { self }

    var label: String {
        switch self {
        case .standard: "标准"
        case .longform: "长文阅读"
        case .code: "代码优先"
        case .highContrast: "高对比度"
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
    case writing
    case preview
    case resources
    case accessibility

    var id: Self { self }

    var label: String {
        switch self {
        case .general: "通用"
        case .writing: "写作"
        case .preview: "预览"
        case .resources: "资源"
        case .accessibility: "辅助功能"
        }
    }
}

struct PreviewAppearanceConfiguration: Equatable, Sendable {
    static let `default` = Self(
        contentWidth: 760,
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
        contentWidth: 760,
        zoom: 1,
        colorScheme: .light,
        theme: .standard,
        increasedContrast: false,
        reduceMotion: true,
        mathRenderingEnabled: false,
        mermaidRenderingEnabled: true
    )

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
        mermaidRenderingEnabled: Bool = true
    ) {
        self.contentWidth = contentWidth
        self.zoom = zoom
        self.colorScheme = colorScheme
        self.theme = theme
        self.increasedContrast = increasedContrast
        self.reduceMotion = reduceMotion
        self.mathRenderingEnabled = mathRenderingEnabled
        self.mermaidRenderingEnabled = mermaidRenderingEnabled
    }

    var coreRenderOptions: UInt32 {
        var options = UInt32(0)
        if mathRenderingEnabled {
            options |= INFLOW_RENDER_OPTION_MATH
        }
        if mermaidRenderingEnabled {
            options |= INFLOW_RENDER_OPTION_MERMAID
        }
        return options
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
        static let previewContentWidth = 600.0 ... 1_200.0
        static let previewZoom = 0.5 ... 2.0
        static let defaultSplitFraction = EditorSplitLayout.allowedFraction
    }

    private enum Key {
        static let editorFontSize = "preferences.editor.fontSize"
        static let editorLineHeight = "preferences.editor.lineHeight"
        static let syntaxHighlightingEnabled = "preferences.editor.syntaxHighlightingEnabled"
        static let spellingEnabled = "preferences.editor.spellingEnabled"
        static let wrapsLines = "preferences.editor.wrapsLines"
        static let showsLineNumbers = "preferences.editor.showsLineNumbers"
        static let scrollSyncEnabled = "preferences.preview.scrollSyncEnabled"
        static let headingNavigationEnabled = "preferences.preview.headingNavigationEnabled"
        static let previewContentWidth = "preferences.preview.contentWidth"
        static let previewZoom = "preferences.preview.zoom"
        static let previewColorScheme = "preferences.preview.colorScheme"
        static let previewTheme = "preferences.preview.theme"
        static let mathRenderingEnabled = "preferences.preview.mathRenderingEnabled"
        static let mermaidRenderingEnabled = "preferences.preview.mermaidRenderingEnabled"
        static let increasedContrast = "preferences.accessibility.increasedContrast"
        static let reduceMotion = "preferences.accessibility.reduceMotion"
        // Kept in the registry only so an older preview build's value remains a
        // recognized migration artifact. The launch product never reads or
        // rewrites a global "last active" editor mode: every new scene derives
        // its starting mode from its document context.
        static let legacyLastActiveEditorViewMode =
            "preferences.window.lastActiveEditorViewMode"
        static let defaultProjectSidebarVisible =
            "preferences.window.defaultProjectSidebarVisible"
        static let defaultOutlineVisible = "preferences.window.defaultOutlineVisible"
        static let defaultSplitFraction = "preferences.preview.defaultSplitFraction"
        static let autosaveEnabled = "preferences.documents.autosaveEnabled"
        static let autosaveDelay = "preferences.documents.autosaveDelay"
        static let existingImagePlacement = "preferences.resources.existingImagePlacement"
    }

    enum Registry {
        static let currentSchemaVersion = 1
        static let schemaVersionKey = "preferences.schemaVersion"
        static let knownKeys: Set<String> = [
            schemaVersionKey,
            Key.editorFontSize,
            Key.editorLineHeight,
            Key.syntaxHighlightingEnabled,
            Key.spellingEnabled,
            Key.wrapsLines,
            Key.showsLineNumbers,
            Key.scrollSyncEnabled,
            Key.headingNavigationEnabled,
            Key.previewContentWidth,
            Key.previewZoom,
            Key.previewColorScheme,
            Key.previewTheme,
            Key.mathRenderingEnabled,
            Key.mermaidRenderingEnabled,
            Key.increasedContrast,
            Key.reduceMotion,
            Key.legacyLastActiveEditorViewMode,
            Key.defaultProjectSidebarVisible,
            Key.defaultOutlineVisible,
            Key.defaultSplitFraction,
            Key.autosaveEnabled,
            Key.autosaveDelay,
            Key.existingImagePlacement,
            RecentDocumentPolicy.capacityKey,
            RecentDocumentPolicy.openBehaviorKey,
        ]

        /// Version 1 adopts the pre-registry keys without renaming them. This
        /// makes existing installations forward-compatible while giving every
        /// later rename or type conversion an explicit migration entry point.
        static func migrate(_ defaults: UserDefaults) {
            let storedVersion = defaults.object(forKey: schemaVersionKey) == nil
                ? 0
                : defaults.integer(forKey: schemaVersionKey)
            guard storedVersion >= 0,
                  storedVersion < currentSchemaVersion
            else {
                return
            }
            defaults.set(currentSchemaVersion, forKey: schemaVersionKey)
        }
    }

    /// Values that are deliberately fixed in the single-document launch
    /// profile. The stored keys remain registered for forward migration, but
    /// stale values from development previews must not activate hidden growth
    /// settings when their controls and commands are absent.
    enum LaunchFixed {
        static let editorLineHeight = 1.6
        static let spellingEnabled = true
        static let wrapsLines = true
        static let showsLineNumbers = false
        static let previewZoom = 1.0
        static let previewTheme = PreviewTheme.standard
        static let mathRenderingEnabled = false
        static let mermaidRenderingEnabled = true
        static let increasedContrast = AccessibilityPreference.followSystem
        static let reduceMotion = AccessibilityPreference.followSystem
        static let recentDocumentCapacity = 20
        static let markdownOpenBehavior = MarkdownOpenBehavior.reuseBlankWindow
        static let defaultProjectSidebarVisible = true
        static let defaultOutlineVisible = false
        static let autosaveDelay = AutosaveDelay.oneSecond
        static let autosaveEnabled = false
        static let existingImagePlacement = ExistingImagePlacementPreference.copyToAssets
    }

    private let defaults: UserDefaults
    private let persistence: any AppPreferencePersistence
    private var accessibilityObserver: AnyCancellable?
    @Published private(set) var persistenceFailure: SettingsPersistenceFailure?

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

    @Published var increasedContrast: AccessibilityPreference {
        didSet { persist(increasedContrast.rawValue, forKey: Key.increasedContrast) }
    }

    @Published var reduceMotion: AccessibilityPreference {
        didSet { persist(reduceMotion.rawValue, forKey: Key.reduceMotion) }
    }

    @Published var defaultProjectSidebarVisible: Bool {
        didSet {
            persist(
                defaultProjectSidebarVisible,
                forKey: Key.defaultProjectSidebarVisible
            )
        }
    }

    @Published var defaultOutlineVisible: Bool {
        didSet { persist(defaultOutlineVisible, forKey: Key.defaultOutlineVisible) }
    }

    @Published var defaultSplitFraction: Double {
        didSet {
            let clamped = Self.clamped(
                defaultSplitFraction,
                range: Limits.defaultSplitFraction
            )
            guard clamped == defaultSplitFraction else {
                defaultSplitFraction = clamped
                persist(clamped, forKey: Key.defaultSplitFraction)
                return
            }
            persist(clamped, forKey: Key.defaultSplitFraction)
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
        persistence: (any AppPreferencePersistence)? = nil
    ) {
        self.defaults = defaults
        self.persistence = persistence ?? UserDefaultsAppPreferencePersistence(defaults: defaults)
        Registry.migrate(defaults)
        persistenceFailure = nil
        editorFontSize = Self.number(
            forKey: Key.editorFontSize,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.fontSize,
            range: Limits.editorFontSize
        )
        editorLineHeight = LaunchFixed.editorLineHeight
        syntaxHighlightingEnabled = Self.bool(
            forKey: Key.syntaxHighlightingEnabled,
            in: defaults,
            defaultValue: true
        )
        spellingEnabled = LaunchFixed.spellingEnabled
        wrapsLines = LaunchFixed.wrapsLines
        showsLineNumbers = LaunchFixed.showsLineNumbers
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
        previewContentWidth = Self.number(
            forKey: Key.previewContentWidth,
            in: defaults,
            defaultValue: PreviewAppearanceConfiguration.default.contentWidth,
            range: Limits.previewContentWidth
        )
        previewZoom = LaunchFixed.previewZoom
        previewColorScheme = Self.enumeration(
            PreviewColorScheme.self,
            forKey: Key.previewColorScheme,
            in: defaults,
            defaultValue: .system
        )
        previewTheme = LaunchFixed.previewTheme
        mathRenderingEnabled = LaunchFixed.mathRenderingEnabled
        mermaidRenderingEnabled = LaunchFixed.mermaidRenderingEnabled
        increasedContrast = LaunchFixed.increasedContrast
        reduceMotion = LaunchFixed.reduceMotion
        defaultProjectSidebarVisible = Self.bool(
            forKey: Key.defaultProjectSidebarVisible,
            in: defaults,
            defaultValue: LaunchFixed.defaultProjectSidebarVisible
        )
        defaultOutlineVisible = Self.bool(
            forKey: Key.defaultOutlineVisible,
            in: defaults,
            defaultValue: LaunchFixed.defaultOutlineVisible
        )
        defaultSplitFraction = Self.number(
            forKey: Key.defaultSplitFraction,
            in: defaults,
            defaultValue: EditorSplitLayout.defaultFraction,
            range: Limits.defaultSplitFraction
        )
        recentDocumentCapacity = LaunchFixed.recentDocumentCapacity
        markdownOpenBehavior = LaunchFixed.markdownOpenBehavior
        autosaveEnabled = LaunchFixed.autosaveEnabled
        autosaveDelay = LaunchFixed.autosaveDelay
        existingImagePlacement = LaunchFixed.existingImagePlacement

        persistCurrentValues()
        accessibilityObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
    }

    var sourceEditorAppearance: SourceEditorAppearance {
        SourceEditorAppearance(
            fontSize: editorFontSize,
            lineHeight: editorLineHeight,
            spellingEnabled: spellingEnabled,
            wrapsLines: wrapsLines,
            showsLineNumbers: showsLineNumbers
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
            mermaidRenderingEnabled: mermaidRenderingEnabled
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
            defaultProjectSidebarVisible = LaunchFixed.defaultProjectSidebarVisible
            defaultOutlineVisible = LaunchFixed.defaultOutlineVisible
            defaultSplitFraction = EditorSplitLayout.defaultFraction
            recentDocumentCapacity = RecentDocumentPolicy.defaultCapacity
            markdownOpenBehavior = LaunchFixed.markdownOpenBehavior
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
        editorFontSize = SourceEditorAppearance.default.fontSize
        editorLineHeight = SourceEditorAppearance.default.lineHeight
        syntaxHighlightingEnabled = true
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
    }

    private func persistCurrentValues() {
        let succeeded = persistence.persist([
                Key.editorFontSize: editorFontSize,
                Key.editorLineHeight: editorLineHeight,
                Key.syntaxHighlightingEnabled: syntaxHighlightingEnabled,
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
                Key.increasedContrast: increasedContrast.rawValue,
                Key.reduceMotion: reduceMotion.rawValue,
                Key.defaultProjectSidebarVisible: defaultProjectSidebarVisible,
                Key.defaultOutlineVisible: defaultOutlineVisible,
                Key.defaultSplitFraction: defaultSplitFraction,
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
