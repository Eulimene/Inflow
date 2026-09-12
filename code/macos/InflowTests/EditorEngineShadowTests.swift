import XCTest
@testable import Inflow

final class EditorEngineShadowTests: XCTestCase {
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
