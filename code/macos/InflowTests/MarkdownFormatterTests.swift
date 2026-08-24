import AppKit
import XCTest
@testable import Inflow

final class MarkdownFormatterTests: XCTestCase {
    func testFormatABILayoutAndCommandValuesMatchRustContract() {
        XCTAssertEqual(MemoryLayout<InflowMarkdownEditResult>.size, 56)
        XCTAssertEqual(MemoryLayout<InflowMarkdownEditResult>.alignment, 8)
        XCTAssertEqual(MarkdownInlineFormat.bold.coreValue, UInt8(INFLOW_INLINE_FORMAT_BOLD))
        XCTAssertEqual(MarkdownInlineFormat.italic.coreValue, UInt8(INFLOW_INLINE_FORMAT_ITALIC))
        XCTAssertEqual(
            MarkdownInlineFormat.strikethrough.coreValue,
            UInt8(INFLOW_INLINE_FORMAT_STRIKETHROUGH)
        )
    }

    func testPlansUnicodeBoldUsingUTF16SelectionAndUTF8CoreRanges() throws {
        let source = "Start 中文👩‍💻 end"
        let selectedRange = (source as NSString).range(of: "中文👩‍💻")

        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: selectedRange,
            format: .bold
        )

        XCTAssertEqual(plan.replacement, "**中文👩‍💻**")
        XCTAssertEqual(plan.resultingSource, "Start **中文👩‍💻** end")
        let selection = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: plan.selectionUTF8Range,
                in: plan.resultingSource
            )
        )
        XCTAssertEqual(
            (plan.resultingSource as NSString).substring(with: selection.revealRange),
            "中文👩‍💻"
        )
    }

    func testCompleteWrapperIsRemovedButPartialSelectionIsRejected() throws {
        let source = "_italic_"
        let contentRange = (source as NSString).range(of: "italic")
        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: contentRange,
            format: .italic
        )
        XCTAssertEqual(plan.resultingSource, "italic")
        XCTAssertEqual(plan.selectionUTF8Range, 0..<6)

        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: "**bold**",
                selectedUTF16Range: NSRange(location: 3, length: 2),
                format: .bold
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testEmptySelectionInsertsEditableTemplate() throws {
        let plan = try MarkdownFormatter.plan(
            source: "text",
            selectedUTF16Range: NSRange(location: 2, length: 0),
            format: .bold
        )

        XCTAssertEqual(plan.resultingSource, "te****xt")
        XCTAssertEqual(plan.selectionUTF8Range, 4..<4)
    }

    func testMultilineSelectionFormatsOnlyWhenItProducesValidInlineMarkdown() throws {
        let source = " first\nsecond "
        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: (source as NSString).length),
            format: .italic
        )
        XCTAssertEqual(plan.resultingSource, " *first\nsecond* ")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: plan.resultingSource).contains(
            "<em>first\nsecond</em>"
        ))

        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: "first\n\nsecond",
                selectedUTF16Range: NSRange(location: 0, length: 13),
                format: .bold
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPlansAndRemovesUnicodeStrikethrough() throws {
        let source = "保留 旧内容 继续"
        let selected = (source as NSString).range(of: "旧内容")
        let added = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: selected,
            format: .strikethrough
        )
        XCTAssertEqual(added.resultingSource, "保留 ~~旧内容~~ 继续")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "<del>旧内容</del>"
        ))

        let removed = try MarkdownFormatter.plan(
            source: added.resultingSource,
            selectedUTF16Range: (added.resultingSource as NSString).range(of: "旧内容"),
            format: .strikethrough
        )
        XCTAssertEqual(removed.resultingSource, source)
    }

    @MainActor
    func testSessionAppliesFormatAsOneUndoUnitAndRestoresSelection() throws {
        let source = "Hello 世界"
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = source
        session.textView.setSelectedRange((source as NSString).range(of: "世界"))

        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: session.textView.selectedRange(),
            format: .bold
        )
        XCTAssertTrue(session.applyMarkdownFormat(plan, actionName: "粗体格式"))
        XCTAssertEqual(session.textView.string, "Hello **世界**")
        XCTAssertEqual(
            (session.textView.string as NSString).substring(
                with: session.textView.selectedRange()
            ),
            "世界"
        )

        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, source)
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "Hello **世界**")
    }

    @MainActor
    func testSessionRejectsStaleAndReadOnlyPlansWithoutChangingText() throws {
        let plan = try MarkdownFormatter.plan(
            source: "source",
            selectedUTF16Range: NSRange(location: 0, length: 6),
            format: .italic
        )
        let session = MarkdownSourceEditorSession()
        session.textView.string = "changed"
        session.textView.isEditable = true
        XCTAssertFalse(session.applyMarkdownFormat(plan, actionName: "斜体格式"))
        XCTAssertEqual(session.textView.string, "changed")

        session.textView.string = "source"
        session.textView.isEditable = false
        XCTAssertFalse(session.applyMarkdownFormat(plan, actionName: "斜体格式"))
        XCTAssertEqual(session.textView.string, "source")
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)
    }

    @MainActor
    func testFormatCommandActionsAreSceneScopedAndRespectReadOnlyState() {
        var first: [MarkdownInlineFormat] = []
        var second: [MarkdownInlineFormat] = []
        let editable = MarkdownFormatCommandActions(canFormat: true) { first.append($0) }
        let readOnly = MarkdownFormatCommandActions(canFormat: false) { second.append($0) }

        editable.apply(.bold)
        XCTAssertEqual(first, [.bold])
        XCTAssertTrue(second.isEmpty)
        XCTAssertFalse(readOnly.canFormat)
    }

    @MainActor
    func testFormatMenuExposesUniqueBoldAndItalicShortcuts() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        for (format, shortcut) in [
            (MarkdownInlineFormat.bold, "b"),
            (MarkdownInlineFormat.italic, "i"),
        ] {
            let matches = items.filter { $0.title == format.label }
            XCTAssertEqual(matches.count, 1)
            let item = try XCTUnwrap(matches.first)
            XCTAssertEqual(item.keyEquivalent, shortcut)
            XCTAssertEqual(
                item.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
                .command
            )
        }

        let strikethroughItems = items.filter {
            $0.title == MarkdownInlineFormat.strikethrough.label
        }
        XCTAssertEqual(strikethroughItems.count, 1)
        XCTAssertEqual(strikethroughItems.first?.keyEquivalent, "")
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
