import AppKit
import XCTest
@testable import Inflow

final class MarkdownInsertionTests: XCTestCase {
    func testLinkPlanWrapsUnicodeSelectionAndUpdatesExistingLink() throws {
        let source = "Read 文档👩‍💻 now"
        let selected = (source as NSString).range(of: "文档👩‍💻")
        let added = try MarkdownFormatter.linkPlan(
            source: source,
            selectedUTF16Range: selected,
            destination: "https://example.com/guide"
        )
        XCTAssertEqual(
            added.resultingSource,
            "Read [文档👩‍💻](<https://example.com/guide>) now"
        )
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "href=\"https://example.com/guide\""
        ))

        let updated = try MarkdownFormatter.linkPlan(
            source: added.resultingSource,
            selectedUTF16Range: (added.resultingSource as NSString).range(of: "文档👩‍💻"),
            destination: "guide/local.md"
        )
        XCTAssertEqual(
            updated.resultingSource,
            "Read [文档👩‍💻](<guide/local.md>) now"
        )
    }

    func testEmptyLinkPlanSelectsEditableLabelAndRejectsUnsafeDestination() throws {
        let plan = try MarkdownFormatter.linkPlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            destination: "#section"
        )
        XCTAssertEqual(plan.resultingSource, "[链接文字](<#section>)")
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: plan.selectionUTF8Range,
                in: plan.resultingSource
            )
        )
        XCTAssertEqual((plan.resultingSource as NSString).substring(with: target.revealRange), "链接文字")

        XCTAssertThrowsError(
            try MarkdownFormatter.linkPlan(
                source: "text",
                selectedUTF16Range: NSRange(location: 0, length: 4),
                destination: "https://example.com/<unsafe>"
            )
        ) { error in
            guard case MarkdownFormatError.invalidDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testLinkPlanAppliesAsOneUndoUnit() throws {
        let source = "Read docs"
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = source
        session.textView.setSelectedRange((source as NSString).range(of: "docs"))
        let plan = try MarkdownFormatter.linkPlan(
            source: source,
            selectedUTF16Range: session.textView.selectedRange(),
            destination: "https://example.com"
        )
        XCTAssertTrue(session.applyMarkdownFormat(plan, actionName: "插入链接"))
        XCTAssertEqual(session.textView.string, "Read [docs](<https://example.com>)")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, source)
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Read [docs](<https://example.com>)")
    }

    @MainActor
    func testInsertActionsAreSceneScopedAndMenuHasCommandK() throws {
        var firstCount = 0
        var secondCount = 0
        let first = MarkdownInsertCommandActions(canInsert: true) { firstCount += 1 }
        let second = MarkdownInsertCommandActions(canInsert: false) { secondCount += 1 }
        first.insertLink()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        XCTAssertFalse(second.canInsert)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let matches = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "链接…"
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.keyEquivalent, "k")
        XCTAssertEqual(
            matches.first?.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
            .command
        )
    }

    @MainActor
    func testLinkDestinationEditorKeepsInputLiteral() {
        let editor = NSTextView()
        editor.smartInsertDeleteEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticLinkDetectionEnabled = true
        editor.isAutomaticDataDetectionEnabled = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true

        LiteralLinkDestinationField.configureLiteralInput(editor)

        XCTAssertFalse(editor.smartInsertDeleteEnabled)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(editor.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(editor.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(editor.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(editor.isGrammarCheckingEnabled)
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
