import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Inflow

final class MarkdownCodecTests: XCTestCase {
    func testNewDocumentUsesUTF8WithoutBOMAndLF() throws {
        let document = MarkdownDocument(text: "# 你好\n\nHello 🌍\n")

        XCTAssertEqual(
            try document.encodedFileData(),
            Data("# 你好\n\nHello 🌍\n".utf8)
        )
    }

    func testExistingDocumentPreservesBOMAndCRLF() throws {
        let source = Data([0xEF, 0xBB, 0xBF])
            + Data("# Title\r\n\r\nBody\r\n".utf8)
        var document = try MarkdownDocument(fileData: source)

        XCTAssertEqual(document.text, "# Title\n\nBody\n")
        XCTAssertTrue(document.properties.hasUTF8BOM)
        XCTAssertEqual(document.properties.lineEnding, .crlf)

        document.text += "新内容\n"
        XCTAssertEqual(
            try document.encodedFileData(),
            source + Data("新内容\r\n".utf8)
        )
    }

    func testInvalidUTF8IsRejectedWithoutReplacementCharacters() {
        XCTAssertThrowsError(try MarkdownDocument(fileData: Data([0xFF, 0xFE]))) { error in
            XCTAssertEqual(error as? MarkdownCodecError, .invalidUTF8)
        }
    }

    func testMixedLineEndingsAreRejectedBeforeWriteBack() {
        let source = Data("one\r\ntwo\n".utf8)

        XCTAssertThrowsError(try MarkdownDocument(fileData: source)) { error in
            XCTAssertEqual(error as? MarkdownCodecError, .mixedLineEndings)
        }
    }

    func testMarkdownTypeCoversBothSupportedExtensions() {
        XCTAssertTrue(UTType.inflowMarkdown.conforms(to: .plainText))
        XCTAssertEqual(UTType(filenameExtension: "md"), .inflowMarkdown)
        XCTAssertEqual(UTType(filenameExtension: "markdown"), .inflowMarkdown)
    }
}
