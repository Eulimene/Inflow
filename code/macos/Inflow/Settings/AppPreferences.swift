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
        static let lastActiveEditorViewMode = "preferences.window.lastActiveEditorViewMode"
        static let autosaveEnabled = "preferences.documents.autosaveEnabled"
        static let autosaveDelay = "preferences.documents.autosaveDelay"
        static let existingImagePlacement = "preferences.resources.existingImagePlacement"
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

    @Published private(set) var lastActiveEditorViewMode: EditorViewMode {
        didSet {
            persist(lastActiveEditorViewMode.rawValue, forKey: Key.lastActiveEditorViewMode)
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
        persistenceFailure = nil
        editorFontSize = Self.number(
            forKey: Key.editorFontSize,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.fontSize,
            range: Limits.editorFontSize
        )
        editorLineHeight = Self.number(
            forKey: Key.editorLineHeight,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.lineHeight,
            range: Limits.editorLineHeight
        )
        syntaxHighlightingEnabled = Self.bool(
            forKey: Key.syntaxHighlightingEnabled,
            in: defaults,
            defaultValue: true
        )
        spellingEnabled = Self.bool(
            forKey: Key.spellingEnabled,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.spellingEnabled
        )
        wrapsLines = Self.bool(
            forKey: Key.wrapsLines,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.wrapsLines
        )
        showsLineNumbers = Self.bool(
            forKey: Key.showsLineNumbers,
            in: defaults,
            defaultValue: SourceEditorAppearance.default.showsLineNumbers
        )
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
        previewZoom = Self.number(
            forKey: Key.previewZoom,
            in: defaults,
            defaultValue: PreviewAppearanceConfiguration.default.zoom,
            range: Limits.previewZoom
        )
        previewColorScheme = Self.enumeration(
            PreviewColorScheme.self,
            forKey: Key.previewColorScheme,
            in: defaults,
            defaultValue: .system
        )
        previewTheme = Self.enumeration(
            PreviewTheme.self,
            forKey: Key.previewTheme,
            in: defaults,
            defaultValue: .standard
        )
        mathRenderingEnabled = Self.bool(
            forKey: Key.mathRenderingEnabled,
            in: defaults,
            defaultValue: PreviewAppearanceConfiguration.default.mathRenderingEnabled
        )
        mermaidRenderingEnabled = Self.bool(
            forKey: Key.mermaidRenderingEnabled,
            in: defaults,
            defaultValue: PreviewAppearanceConfiguration.default.mermaidRenderingEnabled
        )
        increasedContrast = Self.enumeration(
            AccessibilityPreference.self,
            forKey: Key.increasedContrast,
            in: defaults,
            defaultValue: .followSystem
        )
        reduceMotion = Self.enumeration(
            AccessibilityPreference.self,
            forKey: Key.reduceMotion,
            in: defaults,
            defaultValue: .followSystem
        )
        lastActiveEditorViewMode = Self.enumeration(
            EditorViewMode.self,
            forKey: Key.lastActiveEditorViewMode,
            in: defaults,
            defaultValue: .split
        )
        recentDocumentCapacity = RecentDocumentPolicy.capacity(in: defaults)
        markdownOpenBehavior = RecentDocumentPolicy.openBehavior(in: defaults)
        autosaveEnabled = Self.bool(
            forKey: Key.autosaveEnabled,
            in: defaults,
            defaultValue: true
        )
        autosaveDelay = Self.enumeration(
            AutosaveDelay.self,
            forKey: Key.autosaveDelay,
            in: defaults,
            defaultValue: .oneSecond
        )
        existingImagePlacement = Self.enumeration(
            ExistingImagePlacementPreference.self,
            forKey: Key.existingImagePlacement,
            in: defaults,
            defaultValue: .copyToAssets
        )

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

    func recordActiveEditorViewMode(_ mode: EditorViewMode) {
        lastActiveEditorViewMode = mode
    }

    func applyAutosavePolicy(to documentController: NSDocumentController = .shared) {
        documentController.autosavingDelay = autosaveEnabled ? autosaveDelay.seconds : 0
    }

    func reset(_ group: AppPreferenceGroup) {
        switch group {
        case .general:
            autosaveEnabled = true
            autosaveDelay = .oneSecond
            lastActiveEditorViewMode = .split
            recentDocumentCapacity = RecentDocumentPolicy.defaultCapacity
            markdownOpenBehavior = .newWindow
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
        mathRenderingEnabled = PreviewAppearanceConfiguration.default.mathRenderingEnabled
        mermaidRenderingEnabled = PreviewAppearanceConfiguration.default.mermaidRenderingEnabled
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
                Key.lastActiveEditorViewMode: lastActiveEditorViewMode.rawValue,
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
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
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
