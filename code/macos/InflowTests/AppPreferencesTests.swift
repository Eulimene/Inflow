import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Inflow

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testDefaultsMatchLaunchContract() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)
            preferences.applyAutosavePolicy()

            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.editorLineHeight, 1.6)
            XCTAssertTrue(preferences.syntaxHighlightingEnabled)
            XCTAssertTrue(preferences.spellingEnabled)
            XCTAssertTrue(preferences.wrapsLines)
            XCTAssertFalse(preferences.showsLineNumbers)
            XCTAssertTrue(preferences.scrollSyncEnabled)
            XCTAssertTrue(preferences.headingNavigationEnabled)
            XCTAssertEqual(preferences.previewContentWidth, 760)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewColorScheme, .system)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertTrue(preferences.mathRenderingEnabled)
            XCTAssertTrue(preferences.mermaidRenderingEnabled)
            XCTAssertEqual(preferences.increasedContrast, .followSystem)
            XCTAssertEqual(preferences.reduceMotion, .followSystem)
            XCTAssertEqual(preferences.lastActiveEditorViewMode, .split)
            XCTAssertEqual(preferences.recentDocumentCapacity, 20)
            XCTAssertEqual(preferences.markdownOpenBehavior, .newWindow)
            XCTAssertTrue(preferences.autosaveEnabled)
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(preferences.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 1)
        }
    }

    func testPreferencesPersistAcrossInstancesAndClampSupportedRanges() {
        withDefaults { defaults in
            let first = AppPreferences(defaults: defaults)
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
            first.increasedContrast = .enabled
            first.reduceMotion = .disabled
            first.recordActiveEditorViewMode(.preview)
            first.recentDocumentCapacity = 42
            first.markdownOpenBehavior = .reuseBlankWindow
            first.autosaveEnabled = false
            first.autosaveDelay = .fiveSeconds
            first.existingImagePlacement = .copyToRelativeDirectory

            let second = AppPreferences(defaults: defaults)
            second.applyAutosavePolicy()
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
            XCTAssertFalse(second.mathRenderingEnabled)
            XCTAssertFalse(second.mermaidRenderingEnabled)
            XCTAssertEqual(second.increasedContrast, .enabled)
            XCTAssertEqual(second.reduceMotion, .disabled)
            XCTAssertEqual(second.lastActiveEditorViewMode, .preview)
            XCTAssertEqual(second.recentDocumentCapacity, 42)
            XCTAssertEqual(second.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertFalse(second.autosaveEnabled)
            XCTAssertEqual(second.autosaveDelay, .fiveSeconds)
            XCTAssertEqual(second.existingImagePlacement, .copyToRelativeDirectory)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)

            second.editorFontSize = 100
            second.editorLineHeight = -4
            second.previewContentWidth = 50
            second.previewZoom = 9
            second.recentDocumentCapacity = 500
            XCTAssertEqual(second.editorFontSize, 28)
            XCTAssertEqual(second.editorLineHeight, 1.2)
            XCTAssertEqual(second.previewContentWidth, 600)
            XCTAssertEqual(second.previewZoom, 2)
            XCTAssertEqual(second.recentDocumentCapacity, 50)

            let third = AppPreferences(defaults: defaults)
            XCTAssertEqual(third.editorFontSize, 28)
            XCTAssertEqual(third.editorLineHeight, 1.2)
            XCTAssertEqual(third.previewContentWidth, 600)
            XCTAssertEqual(third.previewZoom, 2)
            XCTAssertEqual(third.recentDocumentCapacity, 50)
        }
    }

    func testInvalidStoredValuesAreSanitizedWithoutAffectingUnrelatedData() {
        withDefaults { defaults in
            defaults.set(Double.nan, forKey: "preferences.editor.fontSize")
            defaults.set(0, forKey: "preferences.editor.lineHeight")
            defaults.set(5_000, forKey: "preferences.preview.contentWidth")
            defaults.set("retired-theme", forKey: "preferences.preview.theme")
            defaults.set("retired-view", forKey: "preferences.window.lastActiveEditorViewMode")
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
            XCTAssertEqual(preferences.previewContentWidth, 1_200)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertEqual(preferences.lastActiveEditorViewMode, .split)
            XCTAssertEqual(preferences.recentDocumentCapacity, 5)
            XCTAssertEqual(preferences.markdownOpenBehavior, .newWindow)
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(preferences.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(defaults.string(forKey: "unrelated.document-state"), "keep-me")
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
            preferences.increasedContrast = .enabled
            preferences.recordActiveEditorViewMode(.source)
            preferences.recentDocumentCapacity = 31
            preferences.markdownOpenBehavior = .reuseBlankWindow
            preferences.autosaveEnabled = false
            preferences.autosaveDelay = .twoSeconds
            preferences.existingImagePlacement = .keepOriginal

            preferences.reset(.writing)

            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertTrue(preferences.syntaxHighlightingEnabled)
            XCTAssertEqual(preferences.previewZoom, 1.8)
            XCTAssertFalse(preferences.scrollSyncEnabled)
            XCTAssertEqual(preferences.increasedContrast, .enabled)
            XCTAssertEqual(preferences.lastActiveEditorViewMode, .source)
            XCTAssertEqual(preferences.recentDocumentCapacity, 31)
            XCTAssertEqual(preferences.markdownOpenBehavior, .reuseBlankWindow)
            XCTAssertFalse(preferences.autosaveEnabled)
            XCTAssertEqual(preferences.autosaveDelay, .twoSeconds)
            XCTAssertEqual(preferences.existingImagePlacement, .keepOriginal)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
            XCTAssertEqual(defaults.string(forKey: "document.recovery.record"), "recovery-sentinel")
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
            preferences.recordActiveEditorViewMode(.source)
            preferences.recentDocumentCapacity = 31
            preferences.markdownOpenBehavior = .reuseBlankWindow
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
            XCTAssertEqual(preferences.previewContentWidth, 760)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewColorScheme, .system)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertTrue(preferences.mathRenderingEnabled)
            XCTAssertTrue(preferences.mermaidRenderingEnabled)
            XCTAssertEqual(preferences.increasedContrast, .followSystem)
            XCTAssertEqual(preferences.reduceMotion, .followSystem)
            XCTAssertEqual(preferences.lastActiveEditorViewMode, .split)
            XCTAssertEqual(preferences.recentDocumentCapacity, 20)
            XCTAssertEqual(preferences.markdownOpenBehavior, .newWindow)
            XCTAssertTrue(preferences.autosaveEnabled)
            XCTAssertEqual(preferences.autosaveDelay, .oneSecond)
            XCTAssertEqual(preferences.existingImagePlacement, .copyToAssets)
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 1)
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
            SettingsResetScope.current(.resources).menuTitle,
            "恢复“资源”默认设置…"
        )
        XCTAssertEqual(SettingsResetScope.all.menuTitle, "恢复全部默认设置…")
        XCTAssertNil(InflowSettingsSection.privacy.preferenceGroup)
        XCTAssertEqual(InflowSettingsSection.preview.preferenceGroup, .preview)
    }

    func testSettingsPersistenceFailureKeepsSessionValuesAndSupportsRetry() {
        withDefaults { defaults in
            let persistence = ControlledPreferencePersistence(defaults: defaults)
            let preferences = AppPreferences(
                defaults: defaults,
                persistence: persistence
            )
            XCTAssertNil(preferences.persistenceFailure)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.zoom"), 1)

            persistence.shouldFail = true
            preferences.previewZoom = 1.55

            XCTAssertEqual(preferences.previewZoom, 1.55)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.zoom"), 1)
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
            XCTAssertEqual(preferences.previewZoom, 1.55)

            preferences.previewTheme = .code
            XCTAssertNotNil(preferences.persistenceFailure)
            preferences.retryPersistence()
            XCTAssertNotNil(preferences.persistenceFailure)

            persistence.shouldFail = false
            preferences.retryPersistence()

            XCTAssertNil(preferences.persistenceFailure)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.zoom"), 1.55)
            XCTAssertEqual(
                defaults.string(forKey: "preferences.preview.theme"),
                PreviewTheme.code.rawValue
            )
        }
    }

    func testAutosavePolicySupportsEveryContractDelayAndKeepsManualSaveAvailable() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)

            for delay in AutosaveDelay.allCases {
                preferences.autosaveDelay = delay
                preferences.autosaveEnabled = true
                XCTAssertEqual(NSDocumentController.shared.autosavingDelay, delay.seconds)
            }

            preferences.autosaveEnabled = false
            XCTAssertEqual(NSDocumentController.shared.autosavingDelay, 0)
            XCTAssertTrue(NSDocument.instancesRespond(to: #selector(NSDocument.save(_:))))
        }
    }

    func testDocumentGroupDocumentClassSupportsInPlaceAutosave() throws {
        let document = try NSDocumentController.shared.makeUntitledDocument(
            ofType: UTType.inflowMarkdown.identifier
        )
        defer { document.close() }

        XCTAssertTrue(
            type(of: document).autosavesInPlace,
            "The autosave delay is ineffective unless the actual document class opts into in-place autosave"
        )
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
        XCTAssertEqual(try XCTUnwrap(style).lineHeightMultiple, 1.9, accuracy: 0.001)

        session.applySourceAppearance(.default, force: true)
        XCTAssertFalse(session.scrollView.hasHorizontalScroller)
        XCTAssertTrue(try XCTUnwrap(session.textView.textContainer).widthTracksTextView)
        XCTAssertFalse(session.scrollView.rulersVisible)
    }

    func testLineNumbersTrackPhysicalLinesWithoutChangingTextOrUndo() throws {
        let session = MarkdownSourceEditorSession()
        session.textView.string = "first\nsecond\n"
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
        XCTAssertTrue(try XCTUnwrap(session.textView.undoManager).canUndo)
        session.textView.undoManager?.undo()
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
        XCTAssertTrue(html.contains("font-size: 25.50px"))
        XCTAssertTrue(html.contains("color-scheme: dark"))
        XCTAssertTrue(html.contains("ui-serif"))
        XCTAssertTrue(html.contains("animation: none !important"))
        XCTAssertTrue(html.contains(":focus-visible"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("<script"))
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
        XCTAssertTrue(html.contains("font-size: 21.25px"))
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
        return defaults.synchronize()
    }
}
