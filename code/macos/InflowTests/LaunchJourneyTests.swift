import AppKit
import Foundation
import PDFKit
import XCTest
@testable import Inflow

/// Cross-layer launch fixtures. These tests intentionally exercise the same
/// source snapshot through the file codec, Rust analysis/rendering and delivery
/// adapters instead of proving each layer with unrelated idealized inputs.
final class LaunchJourneyTests: XCTestCase {
    func testDailyDocumentRemainsExactFromOpenThroughHTMLDelivery() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(
            """
            # Release Journey\r
            \r
            Hello **world** and 你好.\r
            \r
            - [x] saved\r
            \r
            [Docs](https://example.com)\r

            """.utf8
        )
        let document = try MarkdownDocument(fileData: original)
        let analysis = try MarkdownAnalyzer.analyze(document.text)
        let preview = MarkdownRenderer.previewDocument(
            for: document.text,
            navigationHeadings: analysis.headings
        )
        let delivered = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: document.text)
        )
        let deliveredHTML = try XCTUnwrap(String(data: delivered, encoding: .utf8))

        XCTAssertEqual(analysis.headings.map(\.title), ["Release Journey"])
        XCTAssertNil(preview.failureMessage)
        XCTAssertTrue(preview.html.contains("<strong>world</strong>"))
        XCTAssertTrue(preview.html.contains("你好"))
        XCTAssertTrue(preview.html.contains("task-list-item"))
        XCTAssertTrue(deliveredHTML.contains("<h1>Release Journey</h1>"))
        XCTAssertTrue(deliveredHTML.contains("https://example.com"))
        XCTAssertFalse(deliveredHTML.contains("data-inflow-source-start"))
        XCTAssertEqual(try document.encodedFileData(), original)
    }

    func testStructureFixtureKeepsOutlinePreviewAndDeliveryInAgreement() throws {
        let source = """
        # Handbook

        ## Repeat

        - [ ] first
        - [x] second

        | Name | Value |
        | --- | ---: |
        | 中文 | 42 |

        ## Repeat

        Footnote reference[^note].

        [^note]: Footnote body.
        """
        let analysis = try MarkdownAnalyzer.analyze(source)
        let preview = MarkdownRenderer.previewDocument(
            for: source,
            navigationHeadings: analysis.headings
        )
        let delivered = try HTMLExporter.generate(snapshot: HTMLExportSnapshot(markdown: source))
        let deliveredHTML = try XCTUnwrap(String(data: delivered, encoding: .utf8))

        XCTAssertEqual(analysis.headings.map(\.title), ["Handbook", "Repeat", "Repeat"])
        XCTAssertEqual(analysis.headings.map(\.level), [1, 2, 2])
        XCTAssertNotEqual(
            analysis.headings[1].sourceUTF8Range,
            analysis.headings[2].sourceUTF8Range
        )
        XCTAssertNil(preview.failureMessage)
        XCTAssertEqual(
            preview.html.components(separatedBy: "data-inflow-source-start=").count - 1,
            3
        )
        XCTAssertTrue(deliveredHTML.contains("<table>"))
        XCTAssertTrue(deliveredHTML.contains("task-list-item"))
        XCTAssertTrue(deliveredHTML.contains("Footnote body"))
        XCTAssertFalse(deliveredHTML.contains("data-inflow-source-start"))
    }

    func testTechnicalFixtureStaysOfflineAcrossPreviewAndDelivery() throws {
        let source = #"""
        # Technical

        ```rust
        fn main() { println!("hello"); }
        ```

        Inline $x_1^2$ and display:

        $$\frac{a}{b}$$

        ```mermaid
        flowchart TD
        A[开始] --> B[结束]
        ```
        """#
        let analysis = try MarkdownAnalyzer.analyze(source)
        let highlights = try MarkdownHighlighter.spans(in: source)
        let preview = MarkdownRenderer.previewDocument(
            for: source,
            navigationHeadings: analysis.headings
        )
        let delivered = try HTMLExporter.generate(snapshot: HTMLExportSnapshot(markdown: source))
        let deliveredHTML = try XCTUnwrap(String(data: delivered, encoding: .utf8))

        XCTAssertFalse(highlights.isEmpty)
        XCTAssertNil(preview.failureMessage)
        XCTAssertTrue(preview.html.contains("inflow-code-highlight"))
        XCTAssertTrue(preview.html.contains("<math"))
        XCTAssertTrue(preview.html.contains("class=\"mermaid-diagram\""))
        XCTAssertTrue(deliveredHTML.contains("<math"))
        XCTAssertTrue(deliveredHTML.contains("<svg"))
        XCTAssertTrue(deliveredHTML.contains("script-src 'none'"))
        XCTAssertTrue(deliveredHTML.contains("connect-src 'none'"))
        XCTAssertFalse(deliveredHTML.contains("<script"))
        XCTAssertFalse(deliveredHTML.localizedCaseInsensitiveContains("cdn"))
    }

    func testResourceFixtureInlinesValidatedImageAndFailsClosedWhenMissing() throws {
        try withTemporaryDirectory { directory in
            let assets = directory.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: assets,
                withIntermediateDirectories: true
            )
            let imageURL = assets.appendingPathComponent("cover.png")
            try testPNGData().write(to: imageURL)
            let source = "![Launch cover](assets/cover.png)\n\n[Site](https://example.com)\n"
            let preview = MarkdownRenderer.previewDocument(
                for: source,
                documentDirectory: directory
            )
            let delivered = try HTMLExporter.generate(
                snapshot: HTMLExportSnapshot(
                    markdown: source,
                    documentDirectory: directory
                )
            )
            let deliveredHTML = try XCTUnwrap(String(data: delivered, encoding: .utf8))

            XCTAssertNil(preview.failureMessage)
            XCTAssertTrue(preview.hasRelativeResources)
            XCTAssertTrue(preview.html.contains("data:image/png;base64,"))
            XCTAssertTrue(deliveredHTML.contains("data:image/png;base64,"))
            XCTAssertTrue(deliveredHTML.contains("alt=\"Launch cover\""))
            XCTAssertFalse(deliveredHTML.contains(directory.path))
            XCTAssertFalse(deliveredHTML.contains("file:"))

            try FileManager.default.removeItem(at: imageURL)
            let degraded = try HTMLExporter.prepare(
                snapshot: HTMLExportSnapshot(
                    markdown: source,
                    documentDirectory: directory
                )
            )
            let degradedHTML = try XCTUnwrap(String(data: degraded.data, encoding: .utf8))
            XCTAssertEqual(degraded.warnings, [.image])
            XCTAssertTrue(degradedHTML.contains("找不到资源"))
            XCTAssertFalse(degradedHTML.contains(directory.path))
            XCTAssertThrowsError(
                try HTMLExporter.generate(
                    snapshot: HTMLExportSnapshot(
                        markdown: source,
                        documentDirectory: directory
                    )
                )
            )
        }
    }

    @MainActor
    func testCurrentSnapshotProducesIndependentPDFWithoutChangingMarkdown() async throws {
        let source = "# PDF Journey\n\nLATEST-JOURNEY-MARKER **bold**\n"
        let sourceBeforeDelivery = source
        let html = try HTMLExporter.generate(snapshot: HTMLExportSnapshot(markdown: source))
        let pdfData = try await PDFExporter.generate(fromSelfContainedHTML: html)
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData))

        XCTAssertEqual(source, sourceBeforeDelivery)
        XCTAssertGreaterThan(pdf.pageCount, 0)
        XCTAssertTrue(pdf.string?.contains("LATEST-JOURNEY-MARKER") == true)
        XCTAssertTrue((pdf.documentAttributes ?? [:]).isEmpty)
        XCTAssertFalse(
            String(data: pdfData, encoding: .isoLatin1)?.contains("/CreationDate") == true
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InflowLaunchJourneyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func testPNGData() throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(representation.bitmapData)
        pixels[0] = 40
        pixels[1] = 100
        pixels[2] = 220
        pixels[3] = 255
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
