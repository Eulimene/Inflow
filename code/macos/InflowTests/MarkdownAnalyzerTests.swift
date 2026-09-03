import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Inflow

final class MarkdownAnalyzerTests: XCTestCase {
    func testExtractsLevelsUnicodeAndDuplicateHeadingRanges() throws {
        let markdown = """
        # 概览

        ## Same

        #### 跳级

        ## Same

        ### Three

        ##### Five

        ###### 🚀 交付

        """
        let analysis = try MarkdownAnalyzer.analyze(markdown)

        XCTAssertEqual(analysis.headings.map(\.level), [1, 2, 4, 2, 3, 5, 6])
        XCTAssertEqual(
            analysis.headings.map(\.title),
            ["概览", "Same", "跳级", "Same", "Three", "Five", "🚀 交付"]
        )
        XCTAssertNotEqual(
            analysis.headings[1].sourceUTF8Range,
            analysis.headings[3].sourceUTF8Range
        )
        let firstDuplicate = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: analysis.headings[1].sourceUTF8Range,
                in: markdown
            )
        )
        let secondDuplicate = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: analysis.headings[3].sourceUTF8Range,
                in: markdown
            )
        )
        XCTAssertGreaterThan(
            secondDuplicate.caretRange.location,
            firstDuplicate.caretRange.location
        )
        XCTAssertEqual(
            (markdown as NSString).substring(with: secondDuplicate.revealRange),
            "## Same"
        )
        XCTAssertEqual(
            sourceSlice(markdown, range: analysis.headings[6].sourceUTF8Range),
            "###### 🚀 交付"
        )
    }

    func testIgnoresHeadingSyntaxInCodeFence() throws {
        let markdown = "# Real\n\n```md\n# Not a heading\n```\n"
        let analysis = try MarkdownAnalyzer.analyze(markdown)

        XCTAssertEqual(analysis.headings.map(\.title), ["Real"])
    }

    func testCountsCJKWordsAndUserPerceivedCharacters() throws {
        let analysis = try MarkdownAnalyzer.analyze("你好 world 123，世界")

        XCTAssertEqual(analysis.wordCount, 6)
        XCTAssertEqual(analysis.characterCountIncludingSpaces, 15)
        XCTAssertEqual(analysis.characterCountExcludingSpaces, 13)
    }

    func testConvertsUTF8HeadingRangeToUTF16Selection() throws {
        let markdown = "📝\n# 中文 🚀\n"
        let heading = try XCTUnwrap(MarkdownAnalyzer.analyze(markdown).headings.first)
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: heading.sourceUTF8Range,
                in: markdown
            )
        )

        XCTAssertEqual(
            (markdown as NSString).substring(with: target.revealRange),
            "# 中文 🚀"
        )
        XCTAssertEqual(target.caretRange.location, target.revealRange.location)
        XCTAssertEqual(target.caretRange.length, 0)
    }

    func testRejectsUTF8RangeInsideScalar() {
        XCTAssertNil(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: 1..<2,
                in: "🚀"
            )
        )
    }

    func testEmptyDocumentHasCurrentEmptyAnalysis() throws {
        let analysis = try MarkdownAnalyzer.analyze("")

        XCTAssertEqual(analysis, .empty)
    }

    func testUpdatingAndFailureStatesDisableStaleNavigation() throws {
        let previous = try MarkdownAnalyzer.analyze("# Previous\n")
        let updating = DocumentAnalysisState.updating(previous: previous)
        let failed = DocumentAnalysisState.failed(
            previous: previous,
            message: "Analysis failed"
        )

        XCTAssertEqual(updating.displayedAnalysis, previous)
        XCTAssertFalse(updating.allowsNavigation)
        XCTAssertEqual(failed.displayedAnalysis, previous)
        XCTAssertFalse(failed.allowsNavigation)
        XCTAssertTrue(DocumentAnalysisState.ready(previous).allowsNavigation)
    }

    func testAnalysisABILayoutMatchesRustContractOnArm64() {
        XCTAssertEqual(MemoryLayout<InflowHeading>.size, 40)
        XCTAssertEqual(MemoryLayout<InflowHeading>.stride, 40)
        XCTAssertEqual(MemoryLayout<InflowOwnedHeadings>.size, 16)
        XCTAssertEqual(MemoryLayout<InflowAnalysisResult>.size, 64)
    }

    @MainActor
    func testSourceEditorSessionRetainsViewSelectionAndUndoManager() throws {
        let session = MarkdownSourceEditorSession()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.scrollView
        let textView = session.textView
        textView.string = "Title"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())

        XCTAssertEqual(textView.string, "Title!")
        XCTAssertIdentical(session.textView, textView)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        let replacementContainer = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = replacementContainer
        replacementContainer.addSubview(session.scrollView)
        session.scrollView.frame = replacementContainer.bounds

        XCTAssertIdentical(session.textView, textView)
        XCTAssertEqual(textView.selectedRange().location, 6)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "Title")
        XCTAssertEqual(textView.selectedRange().location, 5)
    }

    @MainActor
    func testSwiftUIBranchSwitchesPreserveSourceEditorUndoAndSelection() throws {
        let model = SourceEditorHarnessModel(text: "Body")
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        let textView = session.textView
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        renderPendingUI()
        XCTAssertEqual(model.text, "Body!")

        model.showsOutline = false
        renderPendingUI()
        model.mode = .split
        renderPendingUI()
        model.mode = .preview
        renderPendingUI()
        model.mode = .source
        model.showsOutline = true
        renderPendingUI()

        XCTAssertIdentical(session.textView, textView)
        XCTAssertEqual(textView.selectedRange().location, 5)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        textView.undoManager?.undo()
        renderPendingUI()
        XCTAssertEqual(model.text, "Body")
        XCTAssertEqual(textView.selectedRange().location, 4)

        textView.undoManager?.redo()
        renderPendingUI()
        XCTAssertEqual(model.text, "Body!")
        XCTAssertEqual(textView.selectedRange().location, 5)
    }

    @MainActor
    func testOutlineNavigationMovesCaretAndFocusesRenderedEditorDirectly() throws {
        let markdown = "# First\n\n## 第二章 🚀\n"
        let heading = try XCTUnwrap(MarkdownAnalyzer.analyze(markdown).headings.last)
        let target = try XCTUnwrap(
            MarkdownSourceRange.navigationTarget(
                forUTF8Range: heading.sourceUTF8Range,
                in: markdown
            )
        )
        let model = SourceEditorHarnessModel(text: markdown, mode: .preview)
        let session = MarkdownSourceEditorSession()
        let window = makeHarnessWindow(model: model, session: session)
        defer { window.orderOut(nil) }
        renderPendingUI()

        model.selectionRequest = SourceSelectionRequest(
            generation: 1,
            utf8Range: heading.sourceUTF8Range
        )
        XCTAssertFalse(
            try XCTUnwrap(model.selectionRequest).style.showsTransientMatchIndicator,
            "outline navigation moves a caret without highlighting the heading as a search match"
        )
        renderPendingUI()

        XCTAssertTrue(window.firstResponder === session.textView)
        XCTAssertEqual(session.textView.selectedRange(), target.caretRange)
        XCTAssertEqual(session.textView.selectedRange().length, 0)
    }

    private func sourceSlice(_ markdown: String, range: Range<Int>) -> String {
        let bytes = Array(markdown.utf8)
        return String(decoding: bytes[range], as: UTF8.self)
    }

    @MainActor
    private func makeHarnessWindow(
        model: SourceEditorHarnessModel,
        session: MarkdownSourceEditorSession
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: SourceEditorSwitchingHarness(model: model, session: session)
        )
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @MainActor
    private func renderPendingUI() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    }
}

@MainActor
private final class SourceEditorHarnessModel: ObservableObject {
    @Published var text: String
    @Published var mode: EditorViewMode
    @Published var showsOutline = true
    @Published var selectionRequest: SourceSelectionRequest?

    init(text: String, mode: EditorViewMode = .source) {
        self.text = text
        self.mode = mode
    }
}

private struct SourceEditorSwitchingHarness: View {
    @ObservedObject var model: SourceEditorHarnessModel
    let session: MarkdownSourceEditorSession

    var body: some View {
        Group {
            if model.showsOutline {
                HSplitView {
                    Color.clear.frame(width: 180)
                    editorContent
                }
            } else {
                editorContent
            }
        }
        .frame(width: 800, height: 500)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch model.mode {
        case .source:
            sourceEditor
        case .split:
            HSplitView {
                sourceEditor
                Color.clear
            }
        case .preview:
            MarkdownSourceEditor(
                text: $model.text,
                selectionRequest: model.selectionRequest,
                session: session,
                presentation: .rendered
            )
        }
    }

    private var sourceEditor: some View {
        MarkdownSourceEditor(
            text: $model.text,
            selectionRequest: model.selectionRequest,
            session: session
        )
    }
}
