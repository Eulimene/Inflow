import Foundation
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Inflow

final class MarkdownCodecTests: XCTestCase {
    func testDocumentOpenABILayoutMatchesRustContractOnArm64() {
        XCTAssertEqual(MemoryLayout<InflowDocumentOpenResult>.size, 32)
        XCTAssertEqual(MemoryLayout<InflowDocumentOpenResult>.alignment, 8)
    }

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

    func testMixedLineEndingsOpenReadOnlyUntilUserChoosesCRLF() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let source = bom + Data("one\r\ntwo\n".utf8)
        var document = try MarkdownDocument(fileData: source)

        XCTAssertEqual(document.text, "one\ntwo\n")
        XCTAssertTrue(document.properties.hasUTF8BOM)
        XCTAssertTrue(document.properties.requiresLineEndingChoice)
        XCTAssertThrowsError(try document.encodedFileData()) { error in
            XCTAssertEqual(error as? MarkdownCodecError, .mixedLineEndings)
        }

        document.chooseLineEnding(.crlf)
        XCTAssertFalse(document.properties.requiresLineEndingChoice)
        XCTAssertEqual(try document.encodedFileData(), bom + Data("one\r\ntwo\r\n".utf8))
    }

    func testMixedAndBareCRCanBeExplicitlyUnifiedToLFWithoutLosingText() throws {
        var document = try MarkdownDocument(fileData: Data("one\r\ntwo\nthree\rfour".utf8))

        XCTAssertEqual(document.text, "one\ntwo\nthree\nfour")
        XCTAssertTrue(document.properties.requiresLineEndingChoice)

        document.chooseLineEnding(.lf)
        XCTAssertEqual(try document.encodedFileData(), Data("one\ntwo\nthree\nfour".utf8))
    }

    @MainActor
    func testMixedLineEndingGateKeepsMountedSourceEditorReadOnlyUntilChoice() throws {
        let model = MarkdownDocumentHarness(
            document: try MarkdownDocument(fileData: Data("one\r\ntwo\n".utf8))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: MarkdownDocumentEditorHarness(model: model)
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))

        let sourceEditor = try XCTUnwrap(
            descendantTextViews(in: try XCTUnwrap(window.contentView))
                .first { $0.string == "one\ntwo\n" }
        )
        XCTAssertFalse(sourceEditor.isEditable)

        model.document.chooseLineEnding(.lf)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        XCTAssertTrue(sourceEditor.isEditable)
    }

    func testMarkdownTypeCoversBothSupportedExtensions() {
        XCTAssertTrue(UTType.inflowMarkdown.conforms(to: .plainText))
        XCTAssertEqual(UTType(filenameExtension: "md"), .inflowMarkdown)
        XCTAssertEqual(UTType(filenameExtension: "markdown"), .inflowMarkdown)
    }
}

@MainActor
private final class MarkdownDocumentHarness: ObservableObject {
    @Published var document: MarkdownDocument

    init(document: MarkdownDocument) {
        self.document = document
    }
}

private struct MarkdownDocumentEditorHarness: View {
    @ObservedObject var model: MarkdownDocumentHarness

    var body: some View {
        MarkdownEditorView(
            document: $model.document,
            fileURL: nil,
            isEditable: true
        )
    }
}

@MainActor
private func descendantTextViews(in view: NSView) -> [NSTextView] {
    var result: [NSTextView] = []
    if let textView = view as? NSTextView {
        result.append(textView)
    }
    for subview in view.subviews {
        result.append(contentsOf: descendantTextViews(in: subview))
    }
    return result
}
