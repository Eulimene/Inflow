import AppKit
import SwiftUI
import XCTest
@testable import Inflow

final class MarkdownSearcherTests: XCTestCase {
    func testSearchesMixedUnicodeCaseAndMultilineContent() throws {
        let source = "标题 Alpha\n正文 alpha\nSTRASSE Straße\n结尾 alpha"

        let insensitive = try MarkdownSearcher.matches(
            in: source,
            query: "alpha",
            caseSensitive: false
        )
        XCTAssertEqual(insensitive.count, 3)
        XCTAssertEqual(
            insensitive.map { sourceSlice(source, range: $0.utf8Range) },
            ["Alpha", "alpha", "alpha"]
        )

        let sensitive = try MarkdownSearcher.matches(
            in: source,
            query: "alpha",
            caseSensitive: true
        )
        XCTAssertEqual(sensitive.count, 2)

        let multiline = try MarkdownSearcher.matches(
            in: source,
            query: "Alpha\n正文",
            caseSensitive: true
        )
        XCTAssertEqual(multiline.count, 1)
        XCTAssertEqual(
            sourceSlice(source, range: try XCTUnwrap(multiline.first).utf8Range),
            "Alpha\n正文"
        )
        XCTAssertTrue(
            try MarkdownSearcher.matches(in: "", query: "", caseSensitive: false).isEmpty
        )
    }

    func testUnicodeCaseFoldingMapsExpandedCharactersToExactSource() throws {
        let source = "Straße STRASSE straße"
        let matches = try MarkdownSearcher.matches(
            in: source,
            query: "strasse",
            caseSensitive: false
        )

        XCTAssertEqual(
            matches.map { sourceSlice(source, range: $0.utf8Range) },
            ["Straße", "STRASSE", "straße"]
        )
        XCTAssertTrue(
            try MarkdownSearcher.matches(in: "ß", query: "s", caseSensitive: false).isEmpty
        )
        XCTAssertEqual(
            try MarkdownSearcher.matches(in: "sß", query: "ss", caseSensitive: false)
                .map(\.utf8Range),
            [1..<3]
        )
    }

    func testSearchNeverSplitsCombiningOrZWJGraphemes() throws {
        let decomposed = "e\u{301}"
        XCTAssertTrue(
            try MarkdownSearcher.matches(
                in: decomposed,
                query: "e",
                caseSensitive: true
            ).isEmpty
        )
        XCTAssertTrue(
            try MarkdownSearcher.matches(
                in: decomposed,
                query: "\u{301}",
                caseSensitive: true
            ).isEmpty
        )
        XCTAssertEqual(
            try MarkdownSearcher.matches(
                in: decomposed,
                query: decomposed,
                caseSensitive: true
            ).map(\.utf8Range),
            [0..<3]
        )

        let technologist = "👩‍💻"
        XCTAssertTrue(
            try MarkdownSearcher.matches(
                in: technologist,
                query: "👩",
                caseSensitive: true
            ).isEmpty
        )
        XCTAssertEqual(
            try MarkdownSearcher.matches(
                in: technologist,
                query: technologist,
                caseSensitive: true
            ).map(\.utf8Range),
            [0..<technologist.utf8.count]
        )
    }

    @MainActor
    func testCanonicalEquivalentTextUsesExactUTF8SnapshotIdentity() throws {
        let decomposed = "e\u{301}"
        let precomposed = "é"
        XCTAssertEqual(decomposed, precomposed)
        XCTAssertFalse(UTF8Text.isExactlyEqual(decomposed, precomposed))

        let session = DocumentFindSession()
        session.query = decomposed
        session.replacement = precomposed
        session.isCaseSensitive = true
        session.refresh(source: decomposed, position: .first)

        XCTAssertTrue(session.canReplaceCurrent)
        XCTAssertFalse(session.resultsAreCurrent(for: precomposed))

        let editorSession = MarkdownSourceEditorSession()
        editorSession.textView.string = precomposed
        XCTAssertFalse(
            editorSession.replaceCurrent(
                utf8Range: 0..<decomposed.utf8.count,
                with: "changed",
                expectedText: decomposed
            )
        )
        XCTAssertTrue(UTF8Text.isExactlyEqual(editorSession.textView.string, precomposed))

        let model = SearchEditorHarnessModel(text: decomposed)
        let boundSession = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: boundSession)
        defer { window.orderOut(nil) }
        renderPendingUI()
        model.text = precomposed
        renderPendingUI()
        XCTAssertTrue(UTF8Text.isExactlyEqual(boundSession.textView.string, precomposed))
        XCTAssertEqual((boundSession.textView.string as NSString).length, 1)
    }

    @MainActor
    func testFindSessionReportsPositionWrapsAndPreservesEmptyResultState() throws {
        let session = DocumentFindSession()
        session.query = "alpha"
        session.refresh(source: "Alpha alpha ALPHA", position: .first)

        XCTAssertEqual(session.statusText, "1 / 3")
        XCTAssertEqual(session.moveNext()?.utf8Range, 6..<11)
        XCTAssertEqual(session.statusText, "2 / 3")
        XCTAssertEqual(session.moveNext()?.utf8Range, 12..<17)
        XCTAssertEqual(session.moveNext()?.utf8Range, 0..<5)
        XCTAssertEqual(session.movePrevious()?.utf8Range, 12..<17)

        session.isCaseSensitive = true
        session.refresh(source: "Alpha alpha ALPHA", position: .first)
        XCTAssertEqual(session.matches.count, 1)
        XCTAssertEqual(session.statusText, "1 / 1")

        session.query = "missing"
        session.refresh(source: "Alpha alpha ALPHA", position: .first)
        XCTAssertEqual(session.query, "missing")
        XCTAssertEqual(session.statusText, "0 个匹配")
        XCTAssertNil(session.currentMatch)
    }

    @MainActor
    func testReplaceAllPlanContainsEveryContextAndImmutableSnapshot() throws {
        let source = "alpha before\n中文 alpha after\nalpha"
        let session = DocumentFindSession()
        session.query = "alpha"
        session.replacement = "beta"
        session.refresh(source: source, position: .first)

        let plan = try XCTUnwrap(session.makeReplaceAllPlan(source: source))
        let previews = plan.matches.indices.compactMap(plan.preview)

        XCTAssertEqual(plan.source, source)
        XCTAssertEqual(plan.matches.count, 3)
        XCTAssertEqual(previews.count, 3)
        XCTAssertEqual(previews.map(\.matched), ["alpha", "alpha", "alpha"])
        XCTAssertEqual(previews.map(\.replacement), ["beta", "beta", "beta"])

        session.refresh(source: source + " changed", position: .preserve)
        XCTAssertNotEqual(plan.source, session.sourceSnapshot)
    }

    @MainActor
    func testReplacementPlanSkipsExactNoOpMatches() throws {
        let session = DocumentFindSession()
        session.query = "alpha"
        session.replacement = "alpha"
        session.refresh(source: "alpha Alpha ALPHA", position: .first)

        let plan = try XCTUnwrap(
            session.makeReplaceAllPlan(source: "alpha Alpha ALPHA")
        )

        XCTAssertEqual(plan.matches.count, 2)
        XCTAssertEqual(
            plan.matches.indices.compactMap(plan.preview).map(\.matched),
            ["Alpha", "ALPHA"]
        )
        session.refresh(source: "alpha", position: .first)
        XCTAssertFalse(session.canReplaceCurrent)
        XCTAssertFalse(session.hasReplacementChanges)
    }

    @MainActor
    func testReplaceAllPlanRejectsStaleSearchResults() throws {
        let source = "alpha alpha"
        let session = DocumentFindSession()
        session.query = "alpha"
        session.replacement = "beta"

        XCTAssertThrowsError(try session.makeReplaceAllPlan(source: source)) { error in
            XCTAssertTrue(error is DocumentFindPlanError)
        }

        session.refresh(source: source, position: .first)
        session.query = "changed"
        XCTAssertThrowsError(try session.makeReplaceAllPlan(source: source)) { error in
            XCTAssertTrue(error is DocumentFindPlanError)
        }
    }

    @MainActor
    func testReplacementRefreshSkipsMatchesCreatedInsideReplacement() throws {
        let session = DocumentFindSession()
        session.query = "alpha"
        session.replacement = "alpha alpha"
        session.refresh(source: "alpha tail alpha", position: .first)

        let replaced = "alpha alpha tail alpha"
        session.refresh(
            source: replaced,
            position: .afterReplacement(0..<"alpha alpha".utf8.count)
        )

        XCTAssertEqual(session.currentMatch?.utf8Range, 17..<22)

        session.refresh(
            source: "alpha alpha",
            position: .afterReplacement(0..<"alpha alpha".utf8.count)
        )
        XCTAssertNil(session.currentMatch)
        XCTAssertEqual(session.statusText, "2 个匹配")
        XCTAssertEqual(session.moveNext()?.utf8Range, 0..<5)
    }

    @MainActor
    func testReopeningFindPreservesCurrentMatchAndQuery() throws {
        let source = "alpha alpha alpha"
        let session = DocumentFindSession()
        session.query = "alpha"
        session.refresh(source: source, position: .first)
        _ = session.moveNext()
        _ = session.moveNext()

        session.dismiss()
        session.present(replacing: false)
        session.refresh(source: source, position: .preserve)

        XCTAssertEqual(session.query, "alpha")
        XCTAssertEqual(session.currentIndex, 2)
        XCTAssertEqual(session.currentMatch?.utf8Range, 12..<17)
    }

    func testSearchABILayoutMatchesRustContractOnArm64() {
        XCTAssertEqual(MemoryLayout<InflowSearchMatch>.size, 16)
        XCTAssertEqual(MemoryLayout<InflowSearchMatch>.alignment, 8)
        XCTAssertEqual(MemoryLayout<InflowOwnedSearchMatches>.size, 16)
        XCTAssertEqual(MemoryLayout<InflowSearchResult>.size, 24)
    }

    func testRenderedEditingViewKeepsFindInTheCurrentEditableMode() {
        XCTAssertEqual(EditorViewMode.preview.sourceVisible, .preview)
        XCTAssertEqual(EditorViewMode.source.sourceVisible, .source)
        XCTAssertEqual(EditorViewMode.split.sourceVisible, .split)
    }

    @MainActor
    func testAppMenuExposesOneDiscoverableCommandForEachFindShortcut() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))

        let expectations: [(String, String, NSEvent.ModifierFlags)] = [
            ("查找…", "f", [.command]),
            ("查找与替换…", "f", [.command, .option]),
            ("查找下一个", "g", [.command]),
            ("查找上一个", "g", [.command, .shift]),
        ]
        for (title, key, modifiers) in expectations {
            let matching = items.filter { $0.title == title }
            XCTAssertEqual(matching.count, 1, "Expected one menu item titled \(title)")
            let item = try XCTUnwrap(matching.first)
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(
                item.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
                modifiers
            )
        }

        for title in ["拼写与语法", "文本替换", "转换", "语音"] {
            let matchingSubmenus = items.filter { $0.title == title && $0.submenu != nil }
            XCTAssertEqual(matchingSubmenus.count, 1, "Expected preserved submenu \(title)")
        }
        for title in ["立即检查文稿", "显示文本替换", "全部大写", "开始朗读"] {
            XCTAssertEqual(
                items.filter { $0.title == title }.count,
                1,
                "Expected preserved responder command \(title)"
            )
        }

        let undoItem = try XCTUnwrap(
            items.first {
                $0.keyEquivalent == "z"
                    && $0.keyEquivalentModifierMask.intersection([.command, .shift]) == .command
            }
        )
        let redoItem = try XCTUnwrap(
            items.first {
                $0.keyEquivalent == "z"
                    && $0.keyEquivalentModifierMask.intersection([.command, .shift])
                        == [.command, .shift]
            }
        )
        XCTAssertEqual(undoItem.action, #selector(WindowAwareTextView.undo(_:)))
        XCTAssertEqual(redoItem.action, #selector(WindowAwareTextView.redo(_:)))

        let sourceEditor = MarkdownSourceEditorSession().textView
        XCTAssertTrue(ResponderTextToggle.continuousSpellChecking.isOn(sourceEditor))
        XCTAssertFalse(ResponderTextToggle.automaticQuoteSubstitution.isOn(sourceEditor))
        sourceEditor.isAutomaticQuoteSubstitutionEnabled = true
        XCTAssertTrue(ResponderTextToggle.automaticQuoteSubstitution.isOn(sourceEditor))
    }

    @MainActor
    func testFindBarFocusesQueryFieldWhenPresented() throws {
        let session = DocumentFindSession()
        session.query = "alpha\nbeta"
        session.replacement = "段落\n完成"
        session.showsReplacement = true
        session.refresh(source: "alpha\nbeta", position: .first)
        var closeRequested = false
        let root = DocumentFindBar(
            session: session,
            isEditable: true,
            onPrevious: {},
            onNext: {},
            onReplaceCurrent: {},
            onPreviewReplaceAll: {},
            onClose: { closeRequested = true }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        renderPendingUI()

        let textEditors = descendants(of: try XCTUnwrap(window.contentView))
            .compactMap { $0 as? NSTextView }
        let queryField = textEditors.first { $0.string == "alpha\nbeta" }
        let replacementField = textEditors.first { $0.string == "段落\n完成" }

        XCTAssertNotNil(queryField)
        XCTAssertNotNil(replacementField)
        XCTAssertTrue(window.firstResponder === queryField)
        XCTAssertEqual(session.statusText, "1 / 1")

        let queryEditor = try XCTUnwrap(queryField)
        let replacementEditor = try XCTUnwrap(replacementField)
        for editor in [queryEditor, replacementEditor] {
            XCTAssertFalse(editor.smartInsertDeleteEnabled)
            XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
            XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
            XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
            XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
            XCTAssertFalse(editor.isAutomaticLinkDetectionEnabled)
            XCTAssertFalse(editor.isAutomaticDataDetectionEnabled)

            let literalInputToggles = [
                #selector(NSTextView.toggleContinuousSpellChecking(_:)),
                #selector(NSTextView.toggleGrammarChecking(_:)),
                #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
                #selector(NSTextView.toggleSmartInsertDelete(_:)),
                #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)),
                #selector(NSTextView.toggleAutomaticDashSubstitution(_:)),
                #selector(NSTextView.toggleAutomaticLinkDetection(_:)),
                #selector(NSTextView.toggleAutomaticDataDetection(_:)),
                #selector(NSTextView.toggleAutomaticTextReplacement(_:)),
            ]
            for selector in literalInputToggles {
                let item = NSMenuItem()
                item.action = selector
                XCTAssertFalse(editor.validateUserInterfaceItem(item))
                XCTAssertTrue(editor.tryToPerform(selector, with: nil))
            }

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

        XCTAssertTrue(window.makeFirstResponder(replacementEditor))
        let queryBeforeRefocus = session.query
        let currentIndexBeforeRefocus = session.currentIndex
        session.present(replacing: false)
        renderPendingUI()
        XCTAssertTrue(window.firstResponder === queryEditor)
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.query, queryBeforeRefocus))
        XCTAssertEqual(session.currentIndex, currentIndexBeforeRefocus)

        queryEditor.setSelectedRange(
            NSRange(location: (queryEditor.string as NSString).length, length: 0)
        )
        queryEditor.insertNewline(nil)
        renderPendingUI()
        XCTAssertEqual(session.query, "alpha\nbeta\n")

        XCTAssertTrue(window.makeFirstResponder(queryEditor))
        let queryBeforeTab = session.query
        queryEditor.insertTab(nil)
        renderPendingUI()
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.query, queryBeforeTab))
        XCTAssertFalse(window.firstResponder === queryEditor)

        XCTAssertTrue(window.makeFirstResponder(queryEditor))
        queryEditor.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(queryEditor.hasMarkedText())
        queryEditor.cancelOperation(nil)
        renderPendingUI()
        XCTAssertFalse(queryEditor.hasMarkedText())
        XCTAssertFalse(closeRequested)

        queryEditor.cancelOperation(nil)
        XCTAssertTrue(closeRequested)

        XCTAssertTrue(window.makeFirstResponder(replacementEditor))
        replacementEditor.setSelectedRange(
            NSRange(location: (replacementEditor.string as NSString).length, length: 0)
        )
        replacementEditor.insertNewline(nil)
        renderPendingUI()
        XCTAssertEqual(session.replacement, "段落\n完成\n")

        replacementEditor.insertText(
            "\"quoted\" -- literal",
            replacementRange: replacementEditor.selectedRange()
        )
        renderPendingUI()
        XCTAssertTrue(session.replacement.contains("\"quoted\" -- literal"))

        let replacementBeforeBacktab = session.replacement
        replacementEditor.insertBacktab(nil)
        renderPendingUI()
        XCTAssertTrue(
            UTF8Text.isExactlyEqual(session.replacement, replacementBeforeBacktab)
        )
        XCTAssertFalse(window.firstResponder === replacementEditor)
    }

    @MainActor
    func testMegabyteSearchKeepsMainActorResponsive() async throws {
        let line = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
        let repeats = (1_048_576 / line.utf8.count) + 1
        let source = String(repeating: line, count: repeats)
        let worker = DocumentSearchWorker()
        let searchTask = Task {
            await worker.search(source: source, query: "a", caseSensitive: true)
        }
        let heartbeatStarted = CFAbsoluteTimeGetCurrent()
        try await Task.sleep(nanoseconds: 20_000_000)
        let heartbeatElapsed = CFAbsoluteTimeGetCurrent() - heartbeatStarted

        guard case let .success(result)? = await searchTask.value else {
            XCTFail("Background search did not return matches")
            return
        }

        XCTAssertGreaterThan(source.utf8.count, 1_048_576)
        XCTAssertGreaterThan(source.filter(\.isNewline).count, 10_000)
        XCTAssertEqual(result.matches.count, repeats * 64)
        XCTAssertEqual(result.matchedTextCounts, [Data("a".utf8): repeats * 64])

        let session = DocumentFindSession()
        session.query = "a"
        session.replacement = "a"
        session.isCaseSensitive = true
        session.applySearch(
            result,
            source: source,
            query: "a",
            caseSensitive: true,
            position: .first
        )
        let resultPresentationStarted = CFAbsoluteTimeGetCurrent()
        XCTAssertFalse(session.hasReplacementChanges)
        XCTAssertNil(try session.makeReplaceAllPlan(source: source))
        let resultPresentationElapsed = CFAbsoluteTimeGetCurrent() - resultPresentationStarted

        XCTAssertLessThan(
            heartbeatElapsed,
            0.1,
            "Background search stalled the MainActor for \(heartbeatElapsed) seconds"
        )
        XCTAssertLessThan(
            resultPresentationElapsed,
            0.1,
            "Presenting one million exact matches took \(resultPresentationElapsed) seconds"
        )
    }

    @MainActor
    func testSearchSelectionHighlightsMatchWithoutStealingFindFocus() throws {
        let source = "开头 🚀 Alpha 结尾"
        let match = try XCTUnwrap(
            MarkdownSearcher.matches(in: source, query: "Alpha", caseSensitive: true).first
        )
        let model = SearchEditorHarnessModel(text: source)
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        let findField = NSSearchField(frame: NSRect(x: 20, y: 440, width: 220, height: 28))
        window.contentView?.addSubview(findField)
        XCTAssertTrue(window.makeFirstResponder(findField))

        model.selectionRequest = SourceSelectionRequest(
            generation: 1,
            utf8Range: match.utf8Range,
            style: .match,
            focusesEditor: false
        )
        XCTAssertTrue(
            try XCTUnwrap(model.selectionRequest).style.showsTransientMatchIndicator
        )
        renderPendingUI()

        XCTAssertTrue(window.firstResponder === findField.currentEditor())
        XCTAssertEqual(
            (source as NSString).substring(with: session.textView.selectedRange()),
            "Alpha"
        )

        model.selectionRequest = SourceSelectionRequest(
            generation: 2,
            utf8Range: match.utf8Range,
            style: .match,
            focusesEditor: true
        )
        renderPendingUI()

        XCTAssertTrue(window.firstResponder === session.textView)
    }

    @MainActor
    func testReplaceCurrentChangesOnlyRequestedUnicodeRange() throws {
        let source = "🚀 Alpha alpha Alpha"
        let match = try XCTUnwrap(
            MarkdownSearcher.matches(in: source, query: "alpha", caseSensitive: true).first
        )
        let model = SearchEditorHarnessModel(text: source)
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        XCTAssertTrue(
            session.replaceCurrent(
                utf8Range: match.utf8Range,
                with: "中文",
                expectedText: source
            )
        )
        renderPendingUI()

        XCTAssertEqual(model.text, "🚀 Alpha 中文 Alpha")
        session.textView.undoManager?.undo()
        renderPendingUI()
        XCTAssertEqual(model.text, source)
    }

    @MainActor
    func testReplaceAllIsOneUndoUnitAndDoesNotRecursivelyReplace() throws {
        let source = "Alpha 中文 alpha\nALPHA"
        let matches = try MarkdownSearcher.matches(
            in: source,
            query: "alpha",
            caseSensitive: false
        )
        let model = SearchEditorHarnessModel(text: source)
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        let findField = NSSearchField(frame: NSRect(x: 20, y: 440, width: 220, height: 28))
        findField.stringValue = "alpha"
        window.contentView?.addSubview(findField)
        XCTAssertTrue(window.makeFirstResponder(findField))
        model.resetTextUpdateCount()

        XCTAssertTrue(
            session.replaceAll(
                utf8Ranges: matches.map(\.utf8Range),
                with: "beta alpha",
                expectedText: source
            )
        )
        renderPendingUI()
        XCTAssertEqual(model.text, "beta alpha 中文 beta alpha\nbeta alpha")
        XCTAssertEqual(model.textUpdateCount, 1)
        XCTAssertEqual(session.textView.undoManager?.undoActionName, "全部替换")

        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(session.focusEditor())
        XCTAssertTrue(window.firstResponder === session.textView)
        XCTAssertTrue(
            window.firstResponder?.tryToPerform(
                #selector(WindowAwareTextView.undo(_:)),
                with: nil
            ) == true
        )
        renderPendingUI()
        XCTAssertEqual(model.text, source)
        XCTAssertEqual(findField.stringValue, "alpha")

        XCTAssertTrue(
            window.firstResponder?.tryToPerform(
                #selector(WindowAwareTextView.redo(_:)),
                with: nil
            ) == true
        )
        renderPendingUI()
        XCTAssertEqual(model.text, "beta alpha 中文 beta alpha\nbeta alpha")
    }

    @MainActor
    func testReplaceAllSupportsDeletionAndRejectsStaleOrReadOnlySource() throws {
        let source = "one one"
        let matches = try MarkdownSearcher.matches(
            in: source,
            query: "one",
            caseSensitive: true
        )
        let model = SearchEditorHarnessModel(text: source)
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        XCTAssertFalse(
            session.replaceAll(
                utf8Ranges: matches.map(\.utf8Range),
                with: "",
                expectedText: "stale snapshot"
            )
        )
        XCTAssertEqual(model.text, source)

        XCTAssertTrue(
            session.replaceAll(
                utf8Ranges: matches.map(\.utf8Range),
                with: "",
                expectedText: source
            )
        )
        renderPendingUI()
        XCTAssertEqual(model.text, " ")

        session.textView.undoManager?.undo()
        renderPendingUI()
        session.textView.isEditable = false
        XCTAssertFalse(
            session.replaceCurrent(
                utf8Range: matches[0].utf8Range,
                with: "two",
                expectedText: source
            )
        )
        XCTAssertEqual(model.text, source)
    }

    @MainActor
    func testReplaceAllSupportsMultilineQueryAndReplacement() throws {
        let source = "begin\nmiddle\nend\nmiddle\nend"
        let matches = try MarkdownSearcher.matches(
            in: source,
            query: "middle\nend",
            caseSensitive: true
        )
        let model = SearchEditorHarnessModel(text: source)
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(
            session.replaceAll(
                utf8Ranges: matches.map(\.utf8Range),
                with: "段落\n完成",
                expectedText: source
            )
        )
        renderPendingUI()
        XCTAssertEqual(model.text, "begin\n段落\n完成\n段落\n完成")

        session.textView.undoManager?.undo()
        renderPendingUI()
        XCTAssertEqual(model.text, source)
    }

    private func sourceSlice(_ source: String, range: Range<Int>) -> String {
        let bytes = Array(source.utf8)
        return String(decoding: bytes[range], as: UTF8.self)
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func makeHarnessWindow(
        model: SearchEditorHarnessModel,
        session: MarkdownSourceEditorSession
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let hostingView = NSHostingView(
            rootView: SearchEditorHarness(model: model, session: session)
        )
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @MainActor
    private func renderPendingUI() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

@MainActor
private final class SearchEditorHarnessModel: ObservableObject {
    @Published var text: String {
        didSet {
            if !UTF8Text.isExactlyEqual(text, oldValue) {
                textUpdateCount += 1
            }
        }
    }
    @Published var selectionRequest: SourceSelectionRequest?
    private(set) var textUpdateCount = 0

    init(text: String) {
        self.text = text
    }

    func resetTextUpdateCount() {
        textUpdateCount = 0
    }
}

private struct SearchEditorHarness: View {
    @ObservedObject var model: SearchEditorHarnessModel
    let session: MarkdownSourceEditorSession

    var body: some View {
        MarkdownSourceEditor(
            text: $model.text,
            selectionRequest: model.selectionRequest,
            session: session
        )
        .frame(width: 800, height: 500)
    }
}
