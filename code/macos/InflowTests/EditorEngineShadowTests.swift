import XCTest
@testable import Inflow

final class EditorEngineShadowTests: XCTestCase {
    @MainActor
    func testUnifiedDerivationReturnsOneRevisionBoundResult() async throws {
        let queue = EditorEngineShadowQueue(isEnabled: true)
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
        XCTAssertTrue(derived.renderBlocks.contains { $0.visibleText.contains("正文 加粗 链接") })
    }

    func testDiffReturnsOneUTF8ReplacementForUnicodeText() {
        XCTAssertEqual(
            EditorEngineShadowTextDiff.replacement(from: "A🌍B", to: "A世界B"),
            EditorEngineShadowTextEdit(start: 1, end: 5, inserted: "世界")
        )
    }

    func testDiffPreservesByteDistinctCanonicalForms() {
        XCTAssertEqual(
            EditorEngineShadowTextDiff.replacement(from: "e\u{301}", to: "é"),
            EditorEngineShadowTextEdit(start: 0, end: 3, inserted: "é")
        )
    }

    func testDiffReturnsNilOnlyForByteIdenticalText() {
        XCTAssertNil(EditorEngineShadowTextDiff.replacement(from: "你好", to: "你好"))
    }
}
