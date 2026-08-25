import AppKit
import XCTest
@testable import Inflow

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testDefaultsMatchLaunchContract() {
        withDefaults { defaults in
            let preferences = AppPreferences(defaults: defaults)

            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.editorLineHeight, 1.6)
            XCTAssertTrue(preferences.spellingEnabled)
            XCTAssertEqual(preferences.previewContentWidth, 760)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewColorScheme, .system)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertEqual(preferences.increasedContrast, .followSystem)
            XCTAssertEqual(preferences.reduceMotion, .followSystem)
        }
    }

    func testPreferencesPersistAcrossInstancesAndClampSupportedRanges() {
        withDefaults { defaults in
            let first = AppPreferences(defaults: defaults)
            first.editorFontSize = 24
            first.editorLineHeight = 1.9
            first.spellingEnabled = false
            first.previewContentWidth = 1_040
            first.previewZoom = 1.65
            first.previewColorScheme = .dark
            first.previewTheme = .longform
            first.increasedContrast = .enabled
            first.reduceMotion = .disabled

            let second = AppPreferences(defaults: defaults)
            XCTAssertEqual(second.editorFontSize, 24)
            XCTAssertEqual(second.editorLineHeight, 1.9)
            XCTAssertFalse(second.spellingEnabled)
            XCTAssertEqual(second.previewContentWidth, 1_040)
            XCTAssertEqual(second.previewZoom, 1.65)
            XCTAssertEqual(second.previewColorScheme, .dark)
            XCTAssertEqual(second.previewTheme, .longform)
            XCTAssertEqual(second.increasedContrast, .enabled)
            XCTAssertEqual(second.reduceMotion, .disabled)

            second.editorFontSize = 100
            second.editorLineHeight = -4
            second.previewContentWidth = 50
            second.previewZoom = 9
            XCTAssertEqual(second.editorFontSize, 28)
            XCTAssertEqual(second.editorLineHeight, 1.2)
            XCTAssertEqual(second.previewContentWidth, 600)
            XCTAssertEqual(second.previewZoom, 2)
        }
    }

    func testInvalidStoredValuesAreSanitizedWithoutAffectingUnrelatedData() {
        withDefaults { defaults in
            defaults.set(Double.nan, forKey: "preferences.editor.fontSize")
            defaults.set(0, forKey: "preferences.editor.lineHeight")
            defaults.set(5_000, forKey: "preferences.preview.contentWidth")
            defaults.set("retired-theme", forKey: "preferences.preview.theme")
            defaults.set("keep-me", forKey: "unrelated.document-state")

            let preferences = AppPreferences(defaults: defaults)
            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.editorLineHeight, 1.2)
            XCTAssertEqual(preferences.previewContentWidth, 1_200)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertEqual(defaults.string(forKey: "unrelated.document-state"), "keep-me")
        }
    }

    func testResetOnlyChangesWritingPreviewAndAccessibilityPreferences() {
        withDefaults { defaults in
            defaults.set("recovery-sentinel", forKey: "document.recovery.record")
            let preferences = AppPreferences(defaults: defaults)
            preferences.editorFontSize = 27
            preferences.previewZoom = 1.8
            preferences.previewTheme = .code
            preferences.increasedContrast = .enabled

            preferences.resetWritingAndPreview()

            XCTAssertEqual(preferences.editorFontSize, 15)
            XCTAssertEqual(preferences.previewZoom, 1)
            XCTAssertEqual(preferences.previewTheme, .standard)
            XCTAssertEqual(preferences.increasedContrast, .followSystem)
            XCTAssertEqual(defaults.string(forKey: "document.recovery.record"), "recovery-sentinel")
        }
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
            SourceEditorAppearance(fontSize: 22, lineHeight: 1.9, spellingEnabled: false),
            force: true
        )

        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, textAfterEdit))
        XCTAssertEqual(session.textView.selectedRange(), selectionAfterEdit)
        XCTAssertEqual(session.textView.undoManager?.canUndo, canUndo)
        XCTAssertEqual(session.textView.font?.pointSize, 22)
        XCTAssertFalse(session.textView.isContinuousSpellCheckingEnabled)
        let style = session.textView.textStorage?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(try XCTUnwrap(style).lineHeightMultiple, 1.9, accuracy: 0.001)
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
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
