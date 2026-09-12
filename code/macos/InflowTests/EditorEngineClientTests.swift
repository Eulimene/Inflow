import XCTest
@testable import Inflow

final class EditorEngineClientTests: XCTestCase {
    @MainActor
    func testEditorStorePublishesOnlyTheLatestDerivedIntent() async throws {
        let session = MarkdownSourceEditorSession()
        let previewSession = MarkdownSourceEditorSession(role: .renderedProjection)
        session.textView.string = "# Old"
        previewSession.textView.string = "# Old"
        previewSession.textView.isEditable = false
        previewSession.setPresentation(.rendered, source: "# Old", onLinkClick: nil)
        let store = EditorStore(
            sourceEditorSession: session,
            renderedPreviewSession: previewSession
        )

        store.send(.refreshDerived(EditorDerivedContentRequest(
            markdown: "# Old",
            documentDirectory: nil,
            projectRoot: nil,
            expectedProjectRootIdentity: nil,
            requiresProjectBoundary: false,
            configuration: .default,
            syntaxHighlightingEnabled: true,
            delayNanoseconds: 1_000_000_000
        )))
        session.textView.string = "# New\n\n[next](note.md)"
        previewSession.textView.string = "# New\n\n[next](note.md)"
        store.send(.refreshDerived(EditorDerivedContentRequest(
            markdown: "# New\n\n[next](note.md)",
            documentDirectory: nil,
            projectRoot: nil,
            expectedProjectRootIdentity: nil,
            requiresProjectBoundary: false,
            configuration: .default,
            syntaxHighlightingEnabled: true,
            delayNanoseconds: 0
        )))

        for _ in 0..<100 where store.state.previewSourceSnapshot != "# New\n\n[next](note.md)" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.state.previewSourceSnapshot, "# New\n\n[next](note.md)")
        XCTAssertEqual(store.state.analysisState.displayedAnalysis.headings.map(\.title), ["New"])
        XCTAssertEqual(store.state.references.map(\.target), ["note.md"])
        let previewHeadingLocation = (previewSession.textView.string as NSString)
            .range(of: "New").location
        let previewHeadingFont = try XCTUnwrap(
            previewSession.textView.textStorage?.attribute(
                .font,
                at: previewHeadingLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertEqual(previewHeadingFont.pointSize, 27, accuracy: 0.001)
        XCTAssertFalse(previewSession.textView.isEditable)

        store.send(.suspendDerived(markdown: "# New\n\n[next](note.md)"))
        XCTAssertEqual(store.state.previewSourceSnapshot, "")
        XCTAssertEqual(store.state.analysisState, .ready(.empty))
        XCTAssertTrue(store.state.references.isEmpty)

        let becameReadOnly = await store.setMode(.readOnly)
        XCTAssertTrue(becameReadOnly)
        XCTAssertEqual(store.state.engineMode, .readOnly)
        let becameEditable = await store.setMode(.editable)
        XCTAssertTrue(becameEditable)
        XCTAssertEqual(store.state.engineMode, .editable)
    }

    @MainActor
    func testUnifiedDerivationReturnsOneRevisionBoundResult() async throws {
        let queue = EditorEngineClient()
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
        XCTAssertFalse(derived.htmlFragment.contains("data-inflow-link-target-hex"))
        XCTAssertTrue(derived.previewHTMLFragment.contains(
            "data-inflow-link-target-hex=\"6e6f74652e6d64\""
        ))
        XCTAssertTrue(derived.renderBlocks.contains { $0.visibleText.contains("正文 加粗 链接") })
        XCTAssertTrue(derived.nativeRenderPlan.contentStyles.contains { $0.kind == .strong })
        XCTAssertEqual(derived.nativeRenderPlan.links.map(\.target), ["note.md"])
    }

    @MainActor
    func testSourceSessionAppliesTheRevisionBoundNativeRenderPlan() async throws {
        let source = "# 标题 **加粗**"
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = source
        session.setPresentation(.rendered, source: source, onLinkClick: nil)

        let content = await session.deriveContent(for: source, configuration: .default)

        XCTAssertNotNil(content)
        let location = (source as NSString).range(of: "加粗").location
        let font = try XCTUnwrap(
            session.textView.textStorage?.attribute(
                .font,
                at: location,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(content?.nativeRenderPlan.exactlyMatches(source) == true)
    }

    @MainActor
    func testFormatAndSnapshotUseTheSameRevisionedEngine() async throws {
        let queue = EditorEngineClient()
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
        XCTAssertTrue(snapshot.dirty)

        let formattedSelection = NSRange(
            location: 0,
            length: (mutation.resultingSource as NSString).length
        )
        let canClearFormattedSelection = await queue.canClearFormat(
            text: mutation.resultingSource,
            selectionUTF16: formattedSelection
        )
        let canClearPlainSelection = await queue.canClearFormat(
            text: mutation.resultingSource,
            selectionUTF16: NSRange(location: 0, length: 5)
        )
        XCTAssertTrue(canClearFormattedSelection)
        XCTAssertFalse(canClearPlainSelection)

        let preparedSave = await queue.prepareSave(
            text: mutation.resultingSource,
            selectionUTF16: NSRange(location: 8, length: 2)
        )
        let savePreparation = try XCTUnwrap(preparedSave)
        XCTAssertEqual(savePreparation.revision, mutation.revision)
        XCTAssertEqual(savePreparation.text, mutation.resultingSource)
        XCTAssertEqual(savePreparation.contentHash, snapshot.contentHash)
        let saveCompleted = await queue.saveCompleted(savePreparation)
        XCTAssertTrue(saveCompleted)
        let saved = await queue.authoritativeSnapshot(
            matching: mutation.resultingSource,
            selectionUTF16: NSRange(location: 8, length: 2)
        )
        XCTAssertFalse(saved?.dirty == true)
    }

    @MainActor
    func testSearchUsesTheSameRevisionedEngineAndPreservesMatchedBytes() async throws {
        let queue = EditorEngineClient()
        let source = "Straße STRASSE straße"

        let result = await queue.search(
            text: source,
            selectionUTF16: NSRange(location: 0, length: 0),
            query: "strasse",
            caseSensitive: false
        )

        let search = try XCTUnwrap(result)
        XCTAssertEqual(search.matches.map(\.utf8Range), [0..<7, 8..<15, 16..<23])
        XCTAssertEqual(search.matches.map(\.matchedUTF8), [
            Data("Straße".utf8),
            Data("STRASSE".utf8),
            Data("straße".utf8),
        ])
        XCTAssertEqual(search.matchedTextCounts[Data("Straße".utf8)], 1)
        XCTAssertEqual(search.matchedTextCounts[Data("STRASSE".utf8)], 1)
        XCTAssertEqual(search.matchedTextCounts[Data("straße".utf8)], 1)

        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        let outcome = await session.search(
            source: source,
            query: "STRASSE",
            caseSensitive: true
        )
        guard case let .success(sessionResult) = outcome else {
            return XCTFail("source editor search should use its engine")
        }
        XCTAssertEqual(sessionResult.matches.map(\.utf8Range), [8..<15])
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
        let queue = EditorEngineClient()
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
        XCTAssertEqual(reset?.revision, redone.revision + 1)
        XCTAssertEqual(reset?.text, "reloaded")
        XCTAssertEqual(reset?.dirty, false)
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

    @MainActor
    func testRejectedOptimisticEditReconcilesFromEngineWithoutReplacingAuthority() async throws {
        let session = MarkdownSourceEditorSession()
        var publishedText = ""
        session.updateBoundText = { publishedText = $0 }
        session.textView.isEditable = true
        session.textView.string = "authoritative"
        session.textView.setSelectedRange(NSRange(location: 13, length: 0))
        let initial = await session.persistenceSnapshot()
        XCTAssertEqual(initial?.revision, 0)
        let becameReadOnly = await session.setEngineMode(.readOnly)
        XCTAssertTrue(becameReadOnly)

        session.textView.insertText(" drift", replacementRange: session.textView.selectedRange())
        XCTAssertEqual(session.textView.string, "authoritative drift")

        for _ in 0..<100 where session.textView.string != "authoritative" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.textView.string, "authoritative")
        XCTAssertEqual(publishedText, "authoritative")

        let recovered = await session.authoritativeSnapshot()
        XCTAssertEqual(recovered?.revision, 0)
        XCTAssertEqual(recovered?.text, "authoritative")
        XCTAssertFalse(recovered?.canUndo == true)
        XCTAssertEqual(recovered?.mode, .readOnly)
    }

    @MainActor
    func testAdjacentTypingUsesOneEngineUndoGroupAndNewlineBreaksIt() async throws {
        let session = MarkdownSourceEditorSession()
        session.textView.isEditable = true
        session.textView.string = ""
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = await session.authoritativeSnapshot()

        for character in ["a", "b", "c"] {
            session.textView.insertText(
                character,
                replacementRange: session.textView.selectedRange()
            )
        }
        let typed = await session.persistenceSnapshot()
        XCTAssertEqual(typed?.text, "abc")

        session.textView.undo(nil)
        for _ in 0..<40 where !session.textView.string.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(session.textView.string, "")

        for character in ["a", "b"] {
            session.textView.insertText(
                character,
                replacementRange: session.textView.selectedRange()
            )
        }
        session.textView.insertNewline(nil)
        session.textView.insertText("c", replacementRange: session.textView.selectedRange())
        _ = await session.persistenceSnapshot()
        XCTAssertEqual(session.textView.string, "ab\nc")

        session.textView.undo(nil)
        for _ in 0..<40 where session.textView.string != "ab\n" {
            await Task.yield()
        }
        XCTAssertEqual(session.textView.string, "ab\n")
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
