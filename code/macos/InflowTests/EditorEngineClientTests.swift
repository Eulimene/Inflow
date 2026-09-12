import XCTest
@testable import Inflow

final class EditorEngineClientTests: XCTestCase {
    @MainActor
    func testUnifiedDerivationReturnsOneRevisionBoundResult() async throws {
        let queue = EditorEngineClient(isEnabled: true)
        let source = "# 标题\n\n正文 **加粗** [链接](note.md)"

        let content = await queue.derive(
            text: source,
            selectionUTF16: NSRange(location: 0, length: 0),
            configuration: .default
        )

        let derived = try XCTUnwrap(content)
        XCTAssertEqual(derived.revision, 0)
        XCTAssertEqual(derived.sourceSnapshot, source)
        XCTAssertEqual(derived.analysis.headings.map(\.title), ["标题"])
        XCTAssertTrue(derived.syntaxHighlighting.contains { $0.kind == .strong })
        XCTAssertEqual(derived.references.map(\.target), ["note.md"])
        XCTAssertTrue(derived.htmlFragment.contains("<strong>加粗</strong>"))
        XCTAssertTrue(derived.htmlFragment.contains(
            "data-inflow-link-target-hex=\"6e6f74652e6d64\""
        ))
        XCTAssertTrue(derived.renderBlocks.contains { $0.visibleText.contains("正文 加粗 链接") })
    }

    @MainActor
    func testFormatAndSnapshotUseTheSameRevisionedEngine() async throws {
        let queue = EditorEngineClient(isEnabled: true)
        let source = "Hello 世界"
        let selection = (source as NSString).range(of: "世界")

        let formatted = await queue.format(
            text: source,
            selectionUTF16: selection,
            operation: .bold
        )
        let mutation = try XCTUnwrap(formatted)

        XCTAssertEqual(mutation.baseRevision, 0)
        XCTAssertEqual(mutation.revision, 1)
        XCTAssertEqual(mutation.resultingSource, "Hello **世界**")
        XCTAssertEqual(mutation.replacement, "**世界**")
        XCTAssertTrue(mutation.canUndo)
        XCTAssertFalse(mutation.canRedo)

        let authoritative = await queue.authoritativeSnapshot(
            matching: mutation.resultingSource,
            selectionUTF16: NSRange(location: 8, length: 2)
        )
        let snapshot = try XCTUnwrap(authoritative)
        XCTAssertEqual(snapshot.revision, mutation.revision)
        XCTAssertEqual(snapshot.text, mutation.resultingSource)
        XCTAssertEqual(snapshot.selectionUTF8Range, mutation.selectionUTF8Range)
        XCTAssertTrue(snapshot.canUndo)
    }

    @MainActor
    func testSourceSessionAppliesEngineFormatAndPublishesAuthoritativeSnapshot() async throws {
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = "Hello 世界"
        let selected = (session.textView.string as NSString).range(of: "世界")
        session.textView.setSelectedRange(selected)

        let applied = await session.applyEngineFormat(
            .bold,
            expectedText: session.textView.string,
            selectedUTF16Range: selected,
            actionName: "粗体格式"
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(session.textView.string, "Hello **世界**")
        let snapshot = await session.authoritativeSnapshot()
        XCTAssertEqual(snapshot?.text, session.textView.string)
        XCTAssertEqual(snapshot?.revision, 1)
        XCTAssertEqual(snapshot?.canUndo, true)
    }

    @MainActor
    func testEngineHistoryOwnsUndoAndRedoPatches() async throws {
        let queue = EditorEngineClient(isEnabled: true)
        let source = "Hello 世界"
        let selection = (source as NSString).range(of: "世界")
        let formattedResult = await queue.format(
            text: source,
            selectionUTF16: selection,
            operation: .bold
        )
        let formatted = try XCTUnwrap(formattedResult)

        let undoneResult = await queue.undo(
            text: formatted.resultingSource,
            selectionUTF16: NSRange(location: 8, length: 2)
        )
        let undone = try XCTUnwrap(undoneResult)
        XCTAssertEqual(undone.resultingSource, source)
        XCTAssertFalse(undone.canUndo)
        XCTAssertTrue(undone.canRedo)

        let redoneResult = await queue.redo(
            text: undone.resultingSource,
            selectionUTF16: selection
        )
        let redone = try XCTUnwrap(redoneResult)
        XCTAssertEqual(redone.resultingSource, formatted.resultingSource)
        XCTAssertTrue(redone.canUndo)
        XCTAssertFalse(redone.canRedo)

        queue.reset(text: "reloaded", selectionUTF16: NSRange(location: 0, length: 0))
        let reset = await queue.authoritativeSnapshot(
            matching: "reloaded",
            selectionUTF16: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(reset?.revision, 0)
        XCTAssertFalse(reset?.canUndo == true)
        XCTAssertFalse(reset?.canRedo == true)
    }

    @MainActor
    func testSourceSessionRoutesUndoAndRedoToEngineHistory() async throws {
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = "Hello 世界"
        let selected = (session.textView.string as NSString).range(of: "世界")
        session.textView.setSelectedRange(selected)

        let applied = await session.applyEngineFormat(
            .bold,
            expectedText: session.textView.string,
            selectedUTF16Range: selected,
            actionName: "粗体格式"
        )
        XCTAssertTrue(applied)
        XCTAssertTrue(session.textView.usesEngineHistory)
        XCTAssertFalse(session.textView.allowsUndo)
        XCTAssertTrue(session.textView.engineCanUndo)

        session.textView.undo(nil)
        for _ in 0..<20 where session.textView.string != "Hello 世界" {
            await Task.yield()
        }
        XCTAssertEqual(session.textView.string, "Hello 世界")
        XCTAssertTrue(session.textView.engineCanRedo)

        session.textView.redo(nil)
        for _ in 0..<20 where session.textView.string != "Hello **世界**" {
            await Task.yield()
        }
        XCTAssertEqual(session.textView.string, "Hello **世界**")
    }

    @MainActor
    func testCommittedTypingCreatesOnlyEngineUndoHistory() async throws {
        let session = MarkdownSourceEditorSession()
        var publishedText = ""
        session.updateBoundText = { publishedText = $0 }
        session.textView.isEditable = true
        session.textView.string = "alpha"
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        _ = await session.authoritativeSnapshot()

        session.textView.insertText(" beta", replacementRange: session.textView.selectedRange())
        let committed = await session.persistenceSnapshot()
        XCTAssertEqual(committed?.text, "alpha beta")
        XCTAssertEqual(publishedText, "alpha beta")
        XCTAssertEqual(committed?.canUndo, true)
        XCTAssertFalse(session.textView.undoManager?.canUndo == true)

        session.textView.undo(nil)
        for _ in 0..<20 where session.textView.string != "alpha" {
            await Task.yield()
        }
        XCTAssertEqual(session.textView.string, "alpha")
        XCTAssertTrue(session.textView.engineCanRedo)

        let imeSession = MarkdownSourceEditorSession()
        var imeProjection = ""
        imeSession.updateBoundText = { imeProjection = $0 }
        imeSession.textView.isEditable = true
        imeSession.textView.string = "A"
        imeSession.textView.setSelectedRange(NSRange(location: 1, length: 0))
        _ = await imeSession.persistenceSnapshot()
        XCTAssertEqual(imeProjection, "A")

        imeSession.textView.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(imeSession.textView.hasMarkedText())
        XCTAssertEqual(imeProjection, "A")
        imeSession.textView.unmarkText()
        let imeSnapshot = await imeSession.persistenceSnapshot()
        XCTAssertEqual(imeSnapshot?.text, "A拼")
        XCTAssertEqual(imeSnapshot?.revision, 1)
        XCTAssertEqual(imeProjection, "A拼")
        XCTAssertTrue(imeSnapshot?.canUndo == true)
    }

    func testDiffReturnsOneUTF8ReplacementForUnicodeText() {
        XCTAssertEqual(
            EditorEngineTextDiff.replacement(from: "A🌍B", to: "A世界B"),
            EditorEngineTextEdit(start: 1, end: 5, inserted: "世界")
        )
    }

    func testDiffPreservesByteDistinctCanonicalForms() {
        XCTAssertEqual(
            EditorEngineTextDiff.replacement(from: "e\u{301}", to: "é"),
            EditorEngineTextEdit(start: 0, end: 3, inserted: "é")
        )
    }

    func testDiffReturnsNilOnlyForByteIdenticalText() {
        XCTAssertNil(EditorEngineTextDiff.replacement(from: "你好", to: "你好"))
    }
}
