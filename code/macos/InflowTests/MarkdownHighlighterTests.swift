import AppKit
import XCTest
@testable import Inflow

final class MarkdownHighlighterTests: XCTestCase {
    func testBridgeReturnsValidatedLaunchSyntaxRanges() throws {
        let source = "# 标题\n\n> *quote*\n\n- **bold** [link](https://example.com) `code` $x$"
        let spans = try MarkdownHighlighter.spans(in: source)

        XCTAssertTrue(contains("# 标题", kind: .heading, source: source, spans: spans))
        XCTAssertTrue(contains("*quote*", kind: .emphasis, source: source, spans: spans))
        XCTAssertTrue(contains("**bold**", kind: .strong, source: source, spans: spans))
        XCTAssertTrue(
            contains("[link](https://example.com)", kind: .link, source: source, spans: spans)
        )
        XCTAssertTrue(contains("`code`", kind: .code, source: source, spans: spans))
        XCTAssertTrue(contains("$x$", kind: .math, source: source, spans: spans))
        XCTAssertTrue(spans.allSatisfy { NSMaxRange($0.utf16Range) <= source.utf16.count })
    }

    func testUTF8ScalarRangesConvertWithoutAssumingCharacterBoundaries() throws {
        let source = "e\u{301} 👩‍💻"
        XCTAssertEqual(
            MarkdownSyntaxRange.utf16Range(for: 1..<3, in: source),
            NSRange(location: 1, length: 1)
        )
        XCTAssertNil(
            MarkdownSyntaxRange.utf16Range(for: 2..<3, in: source)
        )
    }

    func testSyntaxKindValuesRemainStable() {
        XCTAssertEqual(MarkdownSyntaxKind.heading.rawValue, 1)
        XCTAssertEqual(MarkdownSyntaxKind.code.rawValue, 5)
        XCTAssertEqual(MarkdownSyntaxKind.rule.rawValue, 14)
    }

    @MainActor
    func testSessionAppliesAndDisablesHighlightingWithoutChangingDocumentOrUndo() async throws {
        let session = MarkdownSourceEditorSession()
        let source = "# Title\n\n**bold**"
        session.textView.string = source
        session.textView.setSelectedRange(NSRange(location: 3, length: 2))
        session.textView.insertText("TL", replacementRange: NSRange(location: 2, length: 2))
        let editedSource = session.textView.string
        let selection = session.textView.selectedRange()
        let canUndo = session.textView.undoManager?.canUndo
        var publishedTextChanges = 0
        session.textView.textDidChangeHandler = { _ in publishedTextChanges += 1 }
        let spans = try MarkdownHighlighter.spans(in: editedSource)

        XCTAssertTrue(
            session.applySyntaxHighlighting(spans, source: editedSource, enabled: true)
        )
        await waitForSyntaxApplication()

        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, editedSource))
        XCTAssertEqual(session.textView.selectedRange(), selection)
        XCTAssertEqual(session.textView.undoManager?.canUndo, canUndo)
        XCTAssertEqual(publishedTextChanges, 0)
        let headingColor = session.textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(headingColor, .systemBlue)

        XCTAssertTrue(
            session.applySyntaxHighlighting([], source: editedSource, enabled: false)
        )
        let plainColor = session.textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(plainColor, .textColor)
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, editedSource))
        XCTAssertEqual(session.textView.undoManager?.canUndo, canUndo)
        XCTAssertEqual(publishedTextChanges, 0)

        let incrementalSession = MarkdownSourceEditorSession()
        let incrementalSource = "# Heading\n\nplain **bold** tail"
        incrementalSession.textView.string = incrementalSource
        XCTAssertTrue(incrementalSession.applySyntaxHighlighting(
            try MarkdownHighlighter.spans(in: incrementalSource),
            source: incrementalSource,
            enabled: true
        ))
        await waitForSyntaxApplication()

        let appendedSource = incrementalSource + "!"
        incrementalSession.textView.string = appendedSource
        XCTAssertTrue(incrementalSession.applySyntaxHighlighting(
            try MarkdownHighlighter.spans(in: appendedSource),
            source: appendedSource,
            enabled: true
        ))
        XCTAssertEqual(
            incrementalSession.lastSyntaxDirtyUTF16Ranges,
            [NSRange(location: (incrementalSource as NSString).length, length: 1)]
        )
    }

    @MainActor
    func testSessionRejectsCanonicalEquivalentButByteStaleHighlighting() throws {
        let decomposed = "# e\u{301}"
        let precomposed = "# é"
        XCTAssertEqual(decomposed, precomposed)
        let session = MarkdownSourceEditorSession()
        session.textView.string = precomposed

        XCTAssertFalse(
            session.applySyntaxHighlighting(
                try MarkdownHighlighter.spans(in: decomposed),
                source: decomposed,
                enabled: true
            )
        )
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, precomposed))
    }

    @MainActor
    func testHighlightingPreparedInPreviewModeAppliesWhenSourceEditorMounts() async throws {
        let source = "# Prepared"
        let session = MarkdownSourceEditorSession()
        XCTAssertFalse(
            session.applySyntaxHighlighting(
                try MarkdownHighlighter.spans(in: source),
                source: source,
                enabled: true
            )
        )

        session.textView.string = source
        session.applySourceAppearance(.default, force: true)
        await waitForSyntaxApplication()

        let color = session.textView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(color, .systemBlue)
    }

    @MainActor
    func testMegabyteHighlightApplicationIsScheduledWithoutBlockingInput() async throws {
        let line = "- **item** with [link](https://example.com) and `code`\n"
        let source = String(repeating: line, count: 20_000)
        XCTAssertGreaterThan(source.utf8.count, 1_000_000)
        XCTAssertGreaterThanOrEqual(
            source.split(separator: "\n", omittingEmptySubsequences: false).count,
            10_000
        )
        let spans = try MarkdownHighlighter.spans(in: source)
        let lastCode = try XCTUnwrap(spans.last(where: { $0.kind == .code }))
        let session = MarkdownSourceEditorSession()
        session.textView.string = source

        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(session.applySyntaxHighlighting(spans, source: source, enabled: true))
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertTrue(UTF8Text.isExactlyEqual(session.textView.string, source))
        var didApplyLastCode = false
        while ProcessInfo.processInfo.systemUptime - started < 1.5 {
            let color = session.textView.textStorage?.attribute(
                .foregroundColor,
                at: lastCode.utf16Range.location,
                effectiveRange: nil
            ) as? NSColor
            if color == .systemOrange {
                didApplyLastCode = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(didApplyLastCode)
        session.applySyntaxHighlighting([], source: source, enabled: false)
    }

    private func contains(
        _ expected: String,
        kind: MarkdownSyntaxKind,
        source: String,
        spans: [MarkdownSyntaxSpan]
    ) -> Bool {
        let bytes = Data(source.utf8)
        return spans.contains { span in
            span.kind == kind
                && String(data: bytes.subdata(in: span.utf8Range), encoding: .utf8) == expected
        }
    }

    @MainActor
    private func waitForSyntaxApplication() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}
