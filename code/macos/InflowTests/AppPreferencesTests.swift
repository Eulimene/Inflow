import AppKit
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
            XCTAssertFalse(preferences.mathRenderingEnabled)
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
                defaults.string(forKey: "preferences.workspace.viewMode"),
                WorkspaceViewModePreference.automatic.rawValue
            )
        }
    }

    func testWorkspacePreferencesPersistAcrossPreferenceInstancesAndClampToBounds() {
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
            XCTAssertEqual(second.editorFontSize, 24)
            XCTAssertEqual(second.editorLineHeight, 1.6)
            XCTAssertFalse(second.syntaxHighlightingEnabled)
            XCTAssertTrue(second.spellingEnabled)
            XCTAssertTrue(second.wrapsLines)
            XCTAssertFalse(second.showsLineNumbers)
            XCTAssertFalse(second.scrollSyncEnabled)
            XCTAssertFalse(second.headingNavigationEnabled)
            XCTAssertEqual(second.previewContentWidth, 1_040)
            XCTAssertEqual(second.previewZoom, 1)
            XCTAssertEqual(second.previewColorScheme, .dark)
            XCTAssertEqual(second.previewTheme, .standard)
            XCTAssertFalse(second.mathRenderingEnabled)
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
            XCTAssertEqual(third.editorLineHeight, 1.6)
            XCTAssertEqual(third.previewContentWidth, 600)
            XCTAssertEqual(third.previewZoom, 1)
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
            XCTAssertEqual(preferences.editorLineHeight, 1.6)
            XCTAssertEqual(preferences.previewContentWidth, 1_200)
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
            XCTAssertEqual(preferences.previewContentWidth, 760)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewColorScheme, .system)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertFalse(preferences.mathRenderingEnabled)
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

            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.workspaceViewMode, .preview)
            XCTAssertFalse(preferences.workspaceProjectSidebarVisible)
            XCTAssertTrue(preferences.workspaceOutlineVisible)
            XCTAssertEqual(preferences.workspaceSplitFraction, 0.65)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.zoom"), 1)
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
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.contentWidth"), 760)

            persistence.shouldFail = true
            preferences.previewContentWidth = 900
            preferences.workspaceOutlineVisible = true

            XCTAssertEqual(preferences.previewContentWidth, 900)
            XCTAssertTrue(preferences.workspaceOutlineVisible)
            XCTAssertEqual(defaults.double(forKey: "preferences.preview.contentWidth"), 760)
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
        XCTAssertEqual(try XCTUnwrap(style).lineHeightMultiple, 1.9, accuracy: 0.001)

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
        for _ in 0..<20 where !session.textView.engineCanUndo { await Task.yield() }
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
        XCTAssertTrue(html.contains("font-size: 25.50px"))
        XCTAssertTrue(html.contains("color-scheme: dark"))
        XCTAssertTrue(html.contains("ui-serif"))
        XCTAssertTrue(html.contains("animation: none !important"))
        XCTAssertTrue(html.contains(":focus-visible"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("<script"))

        let nativeAppearance = configuration.nativeRenderedAppearance(spellingEnabled: true)
        XCTAssertEqual(nativeAppearance.fontSize, 25.5)
        XCTAssertEqual(nativeAppearance.lineHeight, 1.82)
        XCTAssertTrue(nativeAppearance.spellingEnabled)
        XCTAssertTrue(nativeAppearance.wrapsLines)
        XCTAssertFalse(nativeAppearance.showsLineNumbers)
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
