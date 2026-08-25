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

    func testTablePlanCreatesThreeByThreeTemplateAndEscapesSelection() throws {
        let empty = try MarkdownFormatter.tablePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(
            empty.resultingSource,
            "| 标题 1 | 标题 2 | 标题 3 |\n| --- | --- | --- |\n| 内容 1 | 内容 2 | 内容 3 |\n| 内容 4 | 内容 5 | 内容 6 |"
        )
        let header = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: empty.selectionUTF8Range,
                in: empty.resultingSource
            )
        )
        XCTAssertEqual((empty.resultingSource as NSString).substring(with: header.revealRange), "标题 1")

        let source = "before A|B\nC after"
        let selected = (source as NSString).range(of: "A|B\nC")
        let escaped = try MarkdownFormatter.tablePlan(
            source: source,
            selectedUTF16Range: selected
        )
        XCTAssertTrue(escaped.resultingSource.contains("| A\\|B<br>C | 标题 2 |"))
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: escaped.resultingSource).contains(
            "<table>"
        ))
    }

    func testTablePlanRejectsInsertionInsideExistingTable() {
        let source = "| One | Two |\n| --- | --- |\n| A | B |\n"
        XCTAssertThrowsError(
            try MarkdownFormatter.tablePlan(
                source: source,
                selectedUTF16Range: NSRange(
                    location: (source as NSString).range(of: "A").location,
                    length: 0
                )
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHorizontalRulePlanPreservesSelectionAndCreatesRealRule() throws {
        let empty = try MarkdownFormatter.horizontalRulePlan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(empty.resultingSource, "---\n\n")
        XCTAssertEqual(empty.selectionUTF8Range, 5..<5)
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: empty.resultingSource).contains(
            "<hr />"
        ))

        let source = "before 文字👩‍💻 after"
        let selection = (source as NSString).range(of: "文字👩‍💻")
        let plan = try MarkdownFormatter.horizontalRulePlan(
            source: source,
            selectedUTF16Range: selection
        )
        XCTAssertEqual(plan.resultingSource, "before 文字👩‍💻\n\n---\n\n after")
        XCTAssertTrue(plan.resultingSource.hasPrefix("before 文字👩‍💻"))
    }

    @MainActor
    func testInsertionPlansApplyAsOneUndoUnit() throws {
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

        session.textView.string = "Header"
        session.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let table = try MarkdownFormatter.tablePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(table, actionName: "插入表格"))
        XCTAssertTrue(session.textView.string.hasPrefix("| Header | 标题 2 |"))
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Header")
        session.textView.undoManager?.redo()
        XCTAssertTrue(session.textView.string.hasPrefix("| Header | 标题 2 |"))

        session.textView.string = "Before"
        session.textView.setSelectedRange(NSRange(location: 6, length: 0))
        let horizontalRule = try MarkdownFormatter.horizontalRulePlan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange()
        )
        XCTAssertTrue(session.applyMarkdownFormat(horizontalRule, actionName: "插入分隔线"))
        XCTAssertEqual(session.textView.string, "Before\n\n---\n\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Before")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Before\n\n---\n\n")
    }

    @MainActor
    func testInsertActionsAreSceneScopedAndMenuHasCommandK() throws {
        var firstCount = 0
        var secondCount = 0
        var firstTableCount = 0
        var firstRuleCount = 0
        let first = MarkdownInsertCommandActions(
            canInsert: true,
            insertLink: { firstCount += 1 },
            insertTable: { firstTableCount += 1 },
            insertHorizontalRule: { firstRuleCount += 1 }
        )
        let second = MarkdownInsertCommandActions(
            canInsert: false,
            insertLink: { secondCount += 1 },
            insertTable: { secondCount += 1 },
            insertHorizontalRule: { secondCount += 1 }
        )
        first.insertLink()
        first.insertTable()
        first.insertHorizontalRule()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(firstTableCount, 1)
        XCTAssertEqual(firstRuleCount, 1)
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

        let tableItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "表格"
        }
        XCTAssertEqual(tableItems.count, 1)
        XCTAssertEqual(tableItems.first?.keyEquivalent, "")

        let horizontalRuleItems = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu)).filter {
            $0.title == "分隔线"
        }
        XCTAssertEqual(horizontalRuleItems.count, 1)
        XCTAssertEqual(horizontalRuleItems.first?.keyEquivalent, "")
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
