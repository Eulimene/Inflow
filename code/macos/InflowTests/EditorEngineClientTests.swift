import XCTest
import SwiftUI
@testable import Inflow

final class EditorEngineClientTests: XCTestCase {
    func testRenderedSurfacePhaseHidesOnlyUnpreparedDocumentReplacements() {
        let ready = EditorRenderedSurfacePhase.ready(sourceSnapshot: "old")

        XCTAssertFalse(
            EditorRenderedSurfacePhase.preparing.canDisplay(
                documentText: "new"
            )
        )
        XCTAssertFalse(ready.canDisplay(documentText: "new"))
        XCTAssertTrue(
            EditorRenderedSurfacePhase.optimistic(sourceSnapshot: "new").canDisplay(
                documentText: "new"
            ),
            "optimistic typing must keep the already-mounted editor visible"
        )
        XCTAssertTrue(ready.canDisplay(documentText: "old"))
        XCTAssertTrue(
            EditorRenderedSurfacePhase.fallback(sourceSnapshot: "new").canDisplay(
                documentText: "new"
            )
        )
    }

    @MainActor
    func testStoreReceivesExplicitOptimisticProjectionEventsFromTheEditor() async throws {
        let source = "正文"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.isEditable = true
        let store = EditorStore(sourceEditorSession: session)
        session.textView.setSelectedRange(NSRange(location: 2, length: 0))

        session.textView.insertText("a", replacementRange: session.textView.selectedRange())

        let expected = "正文a"
        for _ in 0..<100
        where store.state.renderedSurfacePhase != .optimistic(sourceSnapshot: expected) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            store.state.renderedSurfacePhase,
            .optimistic(sourceSnapshot: expected)
        )
        XCTAssertTrue(store.state.renderedSurfacePhase.canDisplay(documentText: expected))
    }

    @MainActor
    func testEquivalentDerivedRequestsDoNotRestartOrRepaintRenderedEditing() async throws {
        let source = "# 标题\n\n正文"
        let session = MarkdownSourceEditorSession()
        session.textView.string = source
        session.textView.isEditable = true
        session.setPresentation(.rendered, source: source, onLinkClick: nil)
        let previewSession = MarkdownSourceEditorSession(role: .renderedProjection)
        previewSession.textView.isEditable = false
        previewSession.setPresentation(.rendered, source: "", onLinkClick: nil)
        let store = EditorStore(
            sourceEditorSession: session,
            renderedPreviewSession: previewSession
        )
        let delayed = EditorDerivedContentRequest(
            markdown: source,
            documentDirectory: nil,
            projectRoot: nil,
            expectedProjectRootIdentity: nil,
            requiresProjectBoundary: false,
            configuration: .default,
            syntaxHighlightingEnabled: true,
            delayNanoseconds: 50_000_000
        )
        let immediate = EditorDerivedContentRequest(
            markdown: source,
            documentDirectory: nil,
            projectRoot: nil,
            expectedProjectRootIdentity: nil,
            requiresProjectBoundary: false,
            configuration: .default,
            syntaxHighlightingEnabled: true,
            delayNanoseconds: 0
        )

        store.send(.refreshDerived(delayed))
        store.send(.refreshDerived(immediate))
        for _ in 0..<100 where store.state.previewSourceSnapshot != source {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.state.previewSourceSnapshot, source)
        XCTAssertEqual(
            store.state.renderedSurfacePhase,
            .ready(sourceSnapshot: source)
        )
        XCTAssertEqual(session.renderedPresentationPassCount, 1)
        XCTAssertEqual(previewSession.renderedPresentationPassCount, 1)

        store.send(.refreshDerived(immediate))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(session.renderedPresentationPassCount, 1)
        XCTAssertEqual(previewSession.renderedPresentationPassCount, 1)

        store.prepareForDocumentReplacement()
        XCTAssertEqual(store.state.renderedSurfacePhase, .preparing)
        store.send(.refreshDerived(immediate))
        for _ in 0..<100
        where store.state.renderedSurfacePhase != .ready(sourceSnapshot: source) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.state.renderedSurfacePhase, .ready(sourceSnapshot: source))

        session.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        session.textView.insertText("x", replacementRange: session.textView.selectedRange())
        let typed = source + "x"
        for _ in 0..<100 where store.state.renderedSurfacePhase != .ready(sourceSnapshot: typed) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.state.renderedSurfacePhase, .ready(sourceSnapshot: typed),
            "Native acknowledgements must refresh analysis without waiting for SwiftUI onChange")
        var historyPublications: [String] = []
        session.updateBoundText = { historyPublications.append($0) }
        session.textView.undo(nil)
        let redoItem = NSMenuItem(title: "Redo", action: #selector(WindowAwareTextView.redo(_:)), keyEquivalent: "z")
        XCTAssertTrue(session.textView.validateUserInterfaceItem(redoItem),
            "AppKit must accept Cmd-Shift-Z while the preceding Undo is still queued")
        session.textView.redo(nil)
        session.setPresentation(.source, source: typed, onLinkClick: nil)
        for _ in 0..<100 where historyPublications.count < 2
            || store.state.renderedSurfacePhase != .ready(sourceSnapshot: typed) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(Array(historyPublications.suffix(2)), [source, typed])
        XCTAssertEqual(session.textView.string, typed)
        XCTAssertEqual(store.state.renderedSurfacePhase, .ready(sourceSnapshot: typed))
        XCTAssertNil(store.state.previewFailureMessage)
        XCTAssertFalse(session.textView.engineHistoryIsPending)
    }

    @MainActor
    func testEditorStorePublishesOnlyTheLatestDerivedIntent() async throws {
        let session = MarkdownSourceEditorSession()
        let previewSession = MarkdownSourceEditorSession(role: .renderedProjection)
        let previewBaseFontSize = try XCTUnwrap(previewSession.textView.font).pointSize
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
        XCTAssertEqual(
            previewHeadingFont.pointSize,
            previewBaseFontSize * MarkdownRenderMetrics.heading(level: 1).scale,
            accuracy: 0.001
        )
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
        XCTAssertNil(derived.htmlFragment)
        XCTAssertNil(derived.previewHTMLFragment)
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
    func testCoordinatorPreservesCompositionAcrossSwiftUIUpdates() async throws {
        for presentation in [MarkdownEditorPresentation.source, .rendered] {
            let session = MarkdownSourceEditorSession()
            var boundText = "A"
            let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
            func editor() -> MarkdownSourceEditor {
                MarkdownSourceEditor(text: binding, selectionRequest: nil, session: session, presentation: presentation)
            }
            let coordinator = editor().makeCoordinator()
            coordinator.update(parent: editor(), textView: session.textView)
            session.textView.setSelectedRange(NSRange(location: 1, length: 0))
            _ = await session.deriveContent(for: boundText, configuration: .default)
            coordinator.update(parent: editor(), textView: session.textView)

            session.textView.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(boundText, "A")
            let selection = session.textView.selectedRange()
            // SwiftUI refreshes for selection, recovery, scroll, and derived-content changes.
            for _ in 0..<3 { coordinator.update(parent: editor(), textView: session.textView) }
            XCTAssertEqual(session.textView.string, "Apin", "A binding refresh must not replace uncommitted IME text")
            XCTAssertTrue(session.textView.hasMarkedText())
            XCTAssertEqual(session.textView.selectedRange(), selection)

            session.textView.insertText("拼音", replacementRange: session.textView.markedRange())
            let committed = await session.persistenceSnapshot()
            XCTAssertEqual(committed?.text, "A拼音")
            XCTAssertEqual(boundText, "A拼音")
            session.textView.undo(nil)
            for _ in 0..<100 where session.textView.string != "A" { await Task.yield() }
            XCTAssertEqual(session.textView.string, "A", "IME composition must form one committed edit")
        }
    }

    @MainActor
    func testCoordinatorKeepsPendingEditsWhenCompositionIsCancelled() async throws {
        for presentation in [MarkdownEditorPresentation.source, .rendered] {
            let session = MarkdownSourceEditorSession()
            var boundText = "A"
            let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
            let editor = MarkdownSourceEditor(text: binding, selectionRequest: nil, session: session, presentation: presentation)
            let coordinator = editor.makeCoordinator()
            coordinator.update(parent: editor, textView: session.textView)
            session.textView.setSelectedRange(NSRange(location: 1, length: 0))
            _ = await session.persistenceSnapshot()
            session.textView.insertText("B", replacementRange: session.textView.selectedRange())
            session.textView.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            for _ in 0..<100 where !session.textView.engineCanUndo { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(session.textView.engineCanUndo, "The Engine must acknowledge B while native composition remains active")
            coordinator.update(parent: editor, textView: session.textView)
            XCTAssertEqual(boundText, "A")
            XCTAssertEqual(session.textView.string, "ABpin")
            session.textView.insertText("", replacementRange: session.textView.markedRange())
            coordinator.update(parent: editor, textView: session.textView)
            XCTAssertEqual(session.textView.string, "AB")
            XCTAssertEqual(boundText, "AB", "Cancelling composition must release the deferred acknowledgement of B")
            let snapshot = await session.persistenceSnapshot()
            XCTAssertEqual(snapshot?.revision, 1, "Cancelling an IME candidate must not create another history entry")

            // Cancelling with no outstanding acknowledgement must leave the input boundary idle.
            session.textView.setMarkedText("cancel", selectedRange: NSRange(location: 6, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            session.textView.insertText("", replacementRange: session.textView.markedRange())
            boundText = "replacement"
            coordinator.update(parent: editor, textView: session.textView)
            XCTAssertEqual(session.textView.string, "replacement", "A cancelled candidate must not leave a phantom pending edit blocking subsequent document updates")
        }
    }

    @MainActor
    func testCoordinatorPreservesRapidTypingAcrossBindingRefreshes() async throws {
        for presentation in [MarkdownEditorPresentation.source, .rendered] {
            let session = MarkdownSourceEditorSession()
            var boundText = ""
            let binding = Binding<String>(get: { boundText }, set: { boundText = $0 })
            let editor = MarkdownSourceEditor(text: binding, selectionRequest: nil, session: session, presentation: presentation)
            let coordinator = editor.makeCoordinator()
            coordinator.update(parent: editor, textView: session.textView)
            _ = await session.persistenceSnapshot()
            var expected = ""
            for character in "hello 世界😀\nsecond line\nthird" {
                if character == "\n" { session.textView.insertNewline(nil) }
                else { session.textView.insertText(String(character), replacementRange: session.textView.selectedRange()) }
                if character == "\n", presentation == .rendered { expected += "\n\n" }
                else { expected.append(character) }
                coordinator.update(parent: editor, textView: session.textView)
                XCTAssertEqual(session.textView.string, expected)
                XCTAssertEqual(session.textView.selectedRange().location, expected.utf16.count)
            }
            let snapshot = await session.persistenceSnapshot()
            coordinator.update(parent: editor, textView: session.textView)
            XCTAssertEqual(snapshot?.text, expected)
            XCTAssertEqual(boundText, expected)
            XCTAssertEqual(session.textView.selectedRange().location, expected.utf16.count)
        }
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

    @MainActor
    func testAdapterDetachmentPreservesSessionOwnedCallbacks() {
        let session = MarkdownSourceEditorSession()
        let editor = MarkdownSourceEditor(text: .constant("body"), selectionRequest: nil, session: session, presentation: .rendered)
        let first = editor.makeCoordinator()
        first.update(parent: editor, textView: session.textView)
        MarkdownSourceEditor.dismantleNSView(session.scrollView, coordinator: first)
        XCTAssertNil(session.textView.delegate)
        XCTAssertNil(session.textView.didAttachToWindow)
        XCTAssertNotNil(session.textView.focusDidChangeHandler)
        XCTAssertNotNil(session.textView.effectiveAppearanceDidChangeHandler)
        XCTAssertNotNil(session.textView.linkClickHandler)
        let second = editor.makeCoordinator()
        second.update(parent: editor, textView: session.textView)
        // A stale adapter cannot detach the replacement adapter's bindings.
        MarkdownSourceEditor.dismantleNSView(session.scrollView, coordinator: first)
        XCTAssertTrue(session.textView.delegate === second)
        XCTAssertNotNil(session.textView.didAttachToWindow)
        XCTAssertNotNil(session.textView.focusDidChangeHandler)
    }

    @MainActor
    func testInputStateMachineProtectsCompositionAndMutationScopes() {
        let state = MarkdownInputState()
        let acknowledgement = EditorEngineDocumentSnapshot(revision: 1, text: "AB", selectionUTF8Range: 2..<2,
            mode: .editable, contentHash: "", canUndo: true, canRedo: false, dirty: true)
        XCTAssertTrue(state.recordNativeEdit("AB", isComposing: false))
        XCTAssertEqual(state.bindingDecision(bound: "A", native: "AB", isComposing: false), .unchanged)
        state.beginComposition()
        XCTAssertFalse(state.recordNativeEdit("ABpin", isComposing: true))
        XCTAssertNil(state.acknowledge(acknowledgement, isComposing: true))
        XCTAssertEqual(state.bindingDecision(bound: "A", native: "ABpin", isComposing: true), .deferred)
        let cancelled = state.finishComposition(text: "AB", changed: false)
        XCTAssertTrue(cancelled.shouldSubmit)
        XCTAssertEqual(cancelled.acknowledgement, acknowledgement)
        XCTAssertEqual(state.acknowledge(acknowledgement, isComposing: false), true)
        XCTAssertEqual(state.bindingDecision(bound: "external", native: "AB", isComposing: false), .replace)
        state.withEngineMutation {
            XCTAssertFalse(state.recordNativeEdit("command", isComposing: false))
            XCTAssertNil(state.acknowledge(acknowledgement, isComposing: false))
            state.withEngineMutation { XCTAssertTrue(state.isApplyingEngineMutation) }
            XCTAssertTrue(state.isApplyingEngineMutation)
        }
        XCTAssertFalse(state.isApplyingEngineMutation)
        state.beginComposition()
        _ = state.acknowledge(acknowledgement, isComposing: true)
        let committed = state.finishComposition(text: "AB拼", changed: true)
        XCTAssertTrue(committed.shouldSubmit)
        XCTAssertNil(committed.acknowledgement, "An old acknowledgement must not replace committed composition")
        state.reset()
        XCTAssertEqual(state.bindingDecision(bound: "external", native: "AB拼", isComposing: false), .replace)
    }

    @MainActor
    func testEngineResetAndABAInputPublishOnlyLatestSubmission() async throws {
        let client = EditorEngineClient()
        var acknowledgements: [String] = []
        client.onAuthoritativeSnapshot = { acknowledgements.append($0.text) }
        client.reset(text: "A", selectionUTF16: NSRange(location: 1, length: 0))
        client.submit(text: "B", selectionUTF16: NSRange(location: 1, length: 0))
        client.reset(text: "A", selectionUTF16: NSRange(location: 1, length: 0))
        let snapshot = await client.authoritativeSnapshot(matching: "A", selectionUTF16: NSRange(location: 1, length: 0))
        XCTAssertEqual(snapshot?.text, "A")
        XCTAssertEqual(acknowledgements, ["A"], "Byte equality cannot distinguish an obsolete A from the latest A")
        acknowledgements = []
        client.reset(text: "old", selectionUTF16: NSRange(location: 3, length: 0))
        client.submit(text: "new", selectionUTF16: NSRange(location: 3, length: 0))
        _ = await client.authoritativeSnapshot(matching: "new", selectionUTF16: NSRange(location: 3, length: 0))
        XCTAssertEqual(acknowledgements, ["new"], "A queued reset must not rewind subsequent native typing")

        let reopening = EditorEngineClient()
        let source = "# 重新打开\n\n正文"
        var acknowledgementCount = 0
        reopening.onAuthoritativeSnapshot = { _ in
            acknowledgementCount += 1
            if acknowledgementCount == 1 {
                reopening.reset(text: "old", selectionUTF16: NSRange(location: 0, length: 0))
                reopening.reset(text: source, selectionUTF16: NSRange(location: 0, length: 0))
            }
        }
        let reopened = await reopening.derive(text: source,
            selectionUTF16: NSRange(location: 0, length: 0), configuration: .default)
        XCTAssertEqual(acknowledgementCount, 2, "Derived reads must wait for resets queued during an earlier acknowledgement")
        XCTAssertEqual(reopened?.sourceSnapshot, source)
        XCTAssertEqual(reopened?.analysis.headings.first?.displayTitle, "重新打开")

    }

    func testSynchronousDerivationCacheKeepsUnicodeByteIdentity() throws {
        let composed = "**é**"
        let decomposed = "**e\u{301}**"
        XCTAssertEqual(composed, decomposed, "Swift string equality is canonically equivalent")
        _ = try XCTUnwrap(EditorEngineDerivedContent.deriveSynchronously(source: composed))
        let derived = try XCTUnwrap(EditorEngineDerivedContent.deriveSynchronously(source: decomposed))
        XCTAssertTrue(UTF8Text.isExactlyEqual(derived.sourceSnapshot, decomposed))
        XCTAssertTrue(derived.nativeRenderPlan.exactlyMatches(decomposed))
        let strong = try XCTUnwrap(derived.nativeRenderPlan.contentStyles.first { $0.kind == .strong })
        XCTAssertEqual(strong.sourceRange.utf16Range, (decomposed as NSString).range(of: "e\u{301}"))

        let shortRow = "| A | B |\n| --- | --- |\n| C | D<br>F |\nAfter\n结束"
        let table = try XCTUnwrap(EditorEngineDerivedContent.deriveSynchronously(source: shortRow))
        XCTAssertEqual(table.nativeRenderPlan.tables.first?.rows.last?.last?.text, "")
    }

    @MainActor
    func testCancelledDerivationCannotInstallPlanAfterDocumentReplacement() async throws {
        let session = MarkdownSourceEditorSession()
        session.textView.string = "old"
        _ = await session.deriveContent(for: "old", configuration: .default)
        session.setPresentation(.rendered, source: "old", onLinkClick: nil)
        session.resetAfterExternalReload("# new")
        let cancelled = Task { @MainActor in
            await session.deriveContent(for: "# new", configuration: .default)
        }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result)
        let passes = session.renderedPresentationPassCount
        session.setPresentation(.rendered, source: "# new", onLinkClick: nil)
        XCTAssertEqual(session.renderedPresentationPassCount, passes,
            "A cancelled derivation must not install a render plan as a hidden side effect")
        let current = await session.deriveContent(for: "# new", configuration: .default)
        XCTAssertNotNil(current)
        XCTAssertGreaterThan(session.renderedPresentationPassCount, passes)
        XCTAssertEqual(session.textView.string, "# new")

        // SwiftUI can reapply source presentation while analysis is awaiting
        // the Engine. Cancelling diagram work must not discard core analysis.
        for _ in 0..<5 {
            let presentationRefresh = Task { @MainActor in
                session.setPresentation(.source, source: "# new", onLinkClick: nil)
            }
            let refreshed = await session.deriveContent(for: "# new", configuration: .default)
            await presentationRefresh.value
            XCTAssertEqual(refreshed?.sourceSnapshot, "# new")
        }
        async let analysis = session.deriveContent(for: "# new", configuration: .default)
        async let resourceRefresh = session.deriveContent(for: "# new", configuration: .default)
        let concurrent = await (analysis, resourceRefresh)
        XCTAssertEqual(concurrent.0?.sourceSnapshot, "# new")
        XCTAssertEqual(concurrent.1?.sourceSnapshot, "# new",
            "Superseding plan installation must not turn a valid analysis result into a failure")
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
