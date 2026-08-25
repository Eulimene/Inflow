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
        XCTAssertEqual(MarkdownListFormat.ordered.coreValue, UInt8(INFLOW_LIST_FORMAT_ORDERED))
        XCTAssertEqual(
            MarkdownListFormat.unordered.coreValue,
            UInt8(INFLOW_LIST_FORMAT_UNORDERED)
        )
        XCTAssertEqual(MarkdownListFormat.task.coreValue, UInt8(INFLOW_LIST_FORMAT_TASK))
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

    func testInlineCodePlansSafeDelimiterAndRemovesCompleteSpan() throws {
        let source = "before code `value` 中文 after"
        let selected = (source as NSString).range(of: "code `value` 中文")
        let added = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: selected,
            command: .inlineCode
        )
        XCTAssertEqual(added.replacement, "``code `value` 中文``")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "<code>code `value` 中文</code>"
        ))

        let removed = try MarkdownFormatter.plan(
            source: added.resultingSource,
            selectedUTF16Range: (added.resultingSource as NSString).range(of: "code `value` 中文"),
            command: .inlineCode
        )
        XCTAssertEqual(removed.resultingSource, source)

        let empty = try MarkdownFormatter.plan(
            source: "text",
            selectedUTF16Range: NSRange(location: 2, length: 0),
            command: .inlineCode
        )
        XCTAssertEqual(empty.resultingSource, "te``xt")
        XCTAssertEqual(empty.selectionUTF8Range, 3..<3)
    }

    func testInlineCodeRejectsPartialAndMultilineSelection() {
        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: "`code`",
                selectedUTF16Range: NSRange(location: 2, length: 2),
                command: .inlineCode
            )
        )
        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: "one\ntwo",
                selectedUTF16Range: NSRange(location: 0, length: 7),
                command: .inlineCode
            )
        )
    }

    func testCodeBlockPlansSafeFenceAndRemovesCompleteContent() throws {
        let source = "before\nlet value = ```raw```;\nprint(\"中文\")\nafter\n"
        let selected = (source as NSString).range(of: "let value = ```raw```;\nprint(\"中文\")")
        let added = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: selected,
            command: .codeBlock
        )
        XCTAssertEqual(
            added.resultingSource,
            "before\n````\nlet value = ```raw```;\nprint(\"中文\")\n````\nafter\n"
        )
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "<pre><code>"
        ))

        let contentSelection = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: added.selectionUTF8Range,
                in: added.resultingSource
            )
        )
        let removed = try MarkdownFormatter.plan(
            source: added.resultingSource,
            selectedUTF16Range: contentSelection.revealRange,
            command: .codeBlock
        )
        XCTAssertEqual(removed.resultingSource, source)
    }

    func testCodeBlockInsertsTemplateAndRejectsPartialExistingFence() throws {
        let empty = try MarkdownFormatter.plan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            command: .codeBlock
        )
        XCTAssertEqual(empty.resultingSource, "```\n\n```")
        XCTAssertEqual(empty.selectionUTF8Range, 4..<4)

        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: "```swift\nprint(\"ok\")\n```\n",
                selectedUTF16Range: NSRange(location: 12, length: 5),
                command: .codeBlock
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

    func testHeadingPlanExpandsUnicodeLineAndPreservesCaret() throws {
        let source = "Intro\n标题👩‍💻\nTail\n"
        let caret = (source as NSString).range(of: "👩‍💻").location
        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: NSRange(location: caret, length: 0),
            heading: .three
        )

        XCTAssertEqual(plan.resultingSource, "Intro\n### 标题👩‍💻\nTail\n")
        let selected = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: plan.selectionUTF8Range,
                in: plan.resultingSource
            )
        )
        XCTAssertEqual(selected.revealRange.length, 0)
        XCTAssertEqual(selected.revealRange.location, caret + 4)
    }

    func testHeadingPlanUnifiesMultilineAndConvertsSetext() throws {
        let source = "Title\n=====\nplain\n### Three\n"
        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: (source as NSString).length),
            heading: .two
        )
        XCTAssertEqual(plan.resultingSource, "## Title\n## plain\n## Three\n")
        XCTAssertEqual(
            try MarkdownAnalyzer.analyze(plan.resultingSource).headings.map(\.level),
            [2, 2, 2]
        )

        let removed = try MarkdownFormatter.plan(
            source: plan.resultingSource,
            selectedUTF16Range: NSRange(
                location: 0,
                length: (plan.resultingSource as NSString).length
            ),
            heading: .two
        )
        XCTAssertEqual(removed.resultingSource, "Title\nplain\nThree\n")
    }

    func testHeadingPlanRejectsCodeFenceWithoutChangingSource() {
        let source = "```\ninside\n```\n"
        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: source,
                selectedUTF16Range: (source as NSString).range(of: "inside"),
                heading: .one
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testBlockQuotePlanHandlesUnicodeCaretAndEmptyTemplate() throws {
        let source = "Intro\n引用👩‍💻\nTail\n"
        let caret = (source as NSString).range(of: "👩‍💻").location
        let plan = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: NSRange(location: caret, length: 0),
            command: .blockQuote
        )
        XCTAssertEqual(plan.resultingSource, "Intro\n> 引用👩‍💻\nTail\n")
        let selected = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: plan.selectionUTF8Range,
                in: plan.resultingSource
            )
        )
        XCTAssertEqual(selected.revealRange.location, caret + 2)
        XCTAssertEqual(selected.revealRange.length, 0)

        let empty = try MarkdownFormatter.plan(
            source: "",
            selectedUTF16Range: NSRange(location: 0, length: 0),
            command: .blockQuote
        )
        XCTAssertEqual(empty.resultingSource, "> ")
        XCTAssertEqual(empty.selectionUTF8Range, 2..<2)
    }

    func testBlockQuotePlanAddsRemovesAndPreservesNestedLevel() throws {
        let source = "one\n\n二\n"
        let added = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: (source as NSString).length),
            command: .blockQuote
        )
        XCTAssertEqual(added.resultingSource, "> one\n> \n> 二\n")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: added.resultingSource).contains(
            "<blockquote>"
        ))

        let removed = try MarkdownFormatter.plan(
            source: added.resultingSource,
            selectedUTF16Range: NSRange(
                location: 0,
                length: (added.resultingSource as NSString).length
            ),
            command: .blockQuote
        )
        XCTAssertEqual(removed.resultingSource, source)

        let nested = "> > inner\n> > next\n"
        let shallower = try MarkdownFormatter.plan(
            source: nested,
            selectedUTF16Range: NSRange(location: 5, length: 0),
            command: .blockQuote
        )
        XCTAssertEqual(shallower.resultingSource, "> inner\n> next\n")
    }

    func testListPlansNormalizeMixedLinesAndRemoveMatchingMarkers() throws {
        let source = "- one\n2. 二\nthree\n\n"
        let selected = NSRange(location: 0, length: (source as NSString).length)
        let normalized = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: selected,
            command: .list(.unordered)
        )
        XCTAssertEqual(normalized.resultingSource, "- one\n- 二\n- three\n\n")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: normalized.resultingSource).contains(
            "<ul>"
        ))

        let removed = try MarkdownFormatter.plan(
            source: normalized.resultingSource,
            selectedUTF16Range: NSRange(
                location: 0,
                length: (normalized.resultingSource as NSString).length
            ),
            command: .list(.unordered)
        )
        XCTAssertEqual(removed.resultingSource, "one\n二\nthree\n\n")
    }

    func testTaskListPlanPreservesCheckedStateAndUnicodeCaret() throws {
        let source = "- [x] 完成\n- todo👩‍💻\n"
        let normalized = try MarkdownFormatter.plan(
            source: source,
            selectedUTF16Range: NSRange(location: 0, length: (source as NSString).length),
            command: .list(.task)
        )
        XCTAssertEqual(normalized.resultingSource, "- [x] 完成\n- [ ] todo👩‍💻\n")
        XCTAssertTrue(try MarkdownRenderer.htmlFragment(for: normalized.resultingSource).contains(
            "checkbox"
        ))

        let plain = "前文\n事项👩‍💻\n"
        let caret = (plain as NSString).range(of: "👩‍💻").location
        let planned = try MarkdownFormatter.plan(
            source: plain,
            selectedUTF16Range: NSRange(location: caret, length: 0),
            command: .list(.task)
        )
        XCTAssertEqual(planned.resultingSource, "前文\n- [ ] 事项👩‍💻\n")
        let selection = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: planned.selectionUTF8Range,
                in: planned.resultingSource
            )
        )
        XCTAssertEqual(selection.revealRange.location, caret + 6)
        XCTAssertEqual(selection.revealRange.length, 0)
    }

    func testListPlanRejectsCodeFencePseudoItem() {
        let source = "```\n- not a list\n```\n"
        XCTAssertThrowsError(
            try MarkdownFormatter.plan(
                source: source,
                selectedUTF16Range: (source as NSString).range(of: "not"),
                command: .list(.unordered)
            )
        ) { error in
            guard case MarkdownFormatError.ambiguousSelection = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

        session.textView.string = "Title\nBody\n"
        session.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let heading = try MarkdownFormatter.plan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange(),
            heading: .two
        )
        XCTAssertTrue(session.applyMarkdownFormat(heading, actionName: "标题格式"))
        XCTAssertEqual(session.textView.string, "## Title\nBody\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "Title\nBody\n")

        session.textView.string = "one\ntwo\n"
        session.textView.setSelectedRange(
            NSRange(location: 0, length: (session.textView.string as NSString).length)
        )
        let list = try MarkdownFormatter.plan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange(),
            command: .list(.ordered)
        )
        XCTAssertTrue(session.applyMarkdownFormat(list, actionName: "列表格式"))
        XCTAssertEqual(session.textView.string, "1. one\n1. two\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "one\ntwo\n")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "1. one\n1. two\n")

        session.textView.string = "let value = `raw`;\n"
        session.textView.setSelectedRange(
            NSRange(location: 0, length: (session.textView.string as NSString).length)
        )
        let codeBlock = try MarkdownFormatter.plan(
            source: session.textView.string,
            selectedUTF16Range: session.textView.selectedRange(),
            command: .codeBlock
        )
        XCTAssertTrue(session.applyMarkdownFormat(codeBlock, actionName: "代码块格式"))
        XCTAssertEqual(session.textView.string, "```\nlet value = `raw`;\n```\n")
        session.textView.undoManager?.undo()
        XCTAssertEqual(session.textView.string, "let value = `raw`;\n")
        session.textView.undoManager?.redo()
        XCTAssertEqual(session.textView.string, "```\nlet value = `raw`;\n```\n")
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
        var first: [MarkdownFormatCommand] = []
        var second: [MarkdownFormatCommand] = []
        let editable = MarkdownFormatCommandActions(canFormat: true) { first.append($0) }
        let readOnly = MarkdownFormatCommandActions(canFormat: false) { second.append($0) }

        editable.apply(.inline(.bold))
        editable.apply(.inlineCode)
        editable.apply(.codeBlock)
        editable.apply(.heading(.four))
        editable.apply(.blockQuote)
        editable.apply(.list(.task))
        XCTAssertEqual(
            first,
            [
                .inline(.bold), .inlineCode, .codeBlock, .heading(.four), .blockQuote,
                .list(.task),
            ]
        )
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

        XCTAssertEqual(items.filter { $0.title == "标题" }.count, 1)
        for level in MarkdownHeadingLevel.allCases {
            let matches = items.filter { $0.title == level.label }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.keyEquivalent, "")
        }

        let quoteItems = items.filter { $0.title == "引用" }
        XCTAssertEqual(quoteItems.count, 1)
        XCTAssertEqual(quoteItems.first?.keyEquivalent, "")

        XCTAssertEqual(items.filter { $0.title == "列表" }.count, 1)
        for format in MarkdownListFormat.allCases {
            let matches = items.filter { $0.title == format.label }
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.keyEquivalent, "")
        }

        let inlineCodeItems = items.filter { $0.title == "行内代码" }
        XCTAssertEqual(inlineCodeItems.count, 1)
        XCTAssertEqual(inlineCodeItems.first?.keyEquivalent, "")

        let codeBlockItems = items.filter { $0.title == "代码块" }
        XCTAssertEqual(codeBlockItems.count, 1)
        XCTAssertEqual(codeBlockItems.first?.keyEquivalent, "")
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
