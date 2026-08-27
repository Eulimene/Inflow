import AppKit
import Foundation
import PDFKit
import XCTest
@testable import Inflow

final class HTMLExporterTests: XCTestCase {
    func testExportProgressUsesFrozenCopyAndExactSnapshotVersion() {
        let first = HTMLExportSnapshot(markdown: "e\u{301}")
        let same = HTMLExportSnapshot(markdown: "e\u{301}")
        let canonicallyEquivalentButByteDifferent = HTMLExportSnapshot(markdown: "é")

        XCTAssertEqual(ExportProgressPrompt.title(format: "HTML"), "正在导出 HTML…")
        XCTAssertEqual(ExportProgressPrompt.cancelTitle, "取消")
        XCTAssertEqual(
            ExportProgressPrompt.message(documentVersion: first.documentVersion),
            "使用文档版本 \(first.documentVersion)。"
        )
        XCTAssertEqual(first.documentVersion, same.documentVersion)
        XCTAssertNotEqual(
            first.documentVersion,
            canonicallyEquivalentButByteDifferent.documentVersion
        )
        XCTAssertEqual(
            ExportResultPrompt.successTitle(exportName: "notes.html"),
            "已导出「notes.html」"
        )
        XCTAssertEqual(
            ExportResultPrompt.successMessage(documentVersion: first.documentVersion),
            "使用文档版本 \(first.documentVersion)。"
        )
        XCTAssertEqual(ExportResultPrompt.showInFinderTitle, "在 Finder 中显示")
        XCTAssertEqual(ExportResultPrompt.openTitle, "打开")
        XCTAssertEqual(ExportResultPrompt.doneTitle, "完成")
    }

    func testExportFailurePromptsAndFormatChangeKeepTheFrozenSnapshot() {
        let request = FrozenExportRequest(
            format: .html,
            snapshot: HTMLExportSnapshot(markdown: "# 冻结版本\n\ne\u{301}"),
            suggestedFilename: "draft.notes.html"
        )
        let alternate = request.changingFormat()

        XCTAssertEqual(alternate.format, .pdf)
        XCTAssertEqual(alternate.suggestedFilename, "draft.notes.pdf")
        XCTAssertEqual(alternate.snapshot.utf8, request.snapshot.utf8)
        XCTAssertEqual(alternate.snapshot.documentVersion, request.snapshot.documentVersion)

        XCTAssertEqual(ExportFailurePrompt.targetChangedTitle, "导出目标已变化")
        XCTAssertEqual(
            ExportFailurePrompt.targetChangedMessage,
            "选择位置后，目标已被创建、替换或修改。"
        )
        XCTAssertEqual(ExportFailurePrompt.reconfirmReplacementTitle, "重新确认替换…")
        XCTAssertEqual(ExportFailurePrompt.chooseAnotherLocationTitle, "选择其他位置…")
        XCTAssertEqual(ExportFailurePrompt.cancelTitle, "取消")
        XCTAssertEqual(ExportFailurePrompt.tooLargeTitle, "导出内容过大")
        XCTAssertEqual(
            ExportFailurePrompt.tooLargeMessage(limit: "100 MiB"),
            "预计交付物超出100 MiB，未写入目标。"
        )
        XCTAssertEqual(ExportFailurePrompt.returnToAdjustTitle, "返回调整")
        XCTAssertEqual(ExportFailurePrompt.changeFormatTitle, "更换格式…")
        XCTAssertEqual(ExportFailurePrompt.checkFailedTitle, "导出结果未通过检查")
        XCTAssertEqual(
            ExportFailurePrompt.checkFailedMessage,
            "交付物包含不安全动作、私密路径或结构不完整，因此没有替换目标。"
        )
        XCTAssertEqual(ExportFailurePrompt.viewProblemsTitle, "查看问题")
        XCTAssertEqual(ExportFailurePrompt.closeTitle, "关闭")
        XCTAssertEqual(ExportFailurePrompt.retryTitle, "重试")
        XCTAssertEqual(
            ExportFailurePrompt.failureTitle(fileName: "draft.notes.html"),
            "未能导出「draft.notes.html」"
        )
        XCTAssertEqual(
            ExportFailurePrompt.failureMessage(reason: "无法完成原子写入。"),
            "无法完成原子写入。Markdown 文档未改变，也没有留下残缺目标。"
        )
    }

    @MainActor
    func testCancelledPDFGenerationStopsBeforeCreatingOutput() async {
        let task = Task { @MainActor in
            await Task.yield()
            return try await PDFExporter.generate(
                fromSelfContainedHTML: Data("<!doctype html><p>cancel</p>".utf8)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PDF generation cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testHTMLExportABILayoutMatchesRustContractOnArm64() {
        XCTAssertEqual(MemoryLayout<InflowHTMLExportResult>.size, 32)
        XCTAssertEqual(MemoryLayout<InflowHTMLExportResult>.alignment, 8)
        XCTAssertEqual(UInt64(INFLOW_HTML_EXPORT_ISSUE_IMAGE), HTMLExportIssue.image.rawValue)
        XCTAssertEqual(
            UInt64(INFLOW_HTML_EXPORT_ISSUE_UNSAFE_LINK),
            HTMLExportIssue.unsafeLink.rawValue
        )
    }

    func testExportUsesImmutableUTF8SnapshotAndStrictDocumentPolicy() throws {
        var markdown = "# 快照\n\n**First**"
        let snapshot = HTMLExportSnapshot(markdown: markdown)
        markdown = "# 新版本"

        let data = try HTMLExporter.generate(snapshot: snapshot)
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("<h1>快照</h1>"))
        XCTAssertTrue(html.contains("<strong>First</strong>"))
        XCTAssertFalse(html.contains("新版本"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains("file:"))
    }

    func testExportReportsAllUnsupportedDeliveryContent() {
        let snapshot = HTMLExportSnapshot(
            markdown: "![image](photo.png)\n\n$x$\n\n```mermaid\ngraph LR\n```\n\n[local](../a.md)\n\n[unsafe](javascript:alert(1))"
        )

        XCTAssertThrowsError(try HTMLExporter.generate(snapshot: snapshot)) { error in
            guard case let HTMLExportError.unsupportedContent(issues) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                Set(issues),
                Set([.image, .localLink, .unsafeLink])
            )
            XCTAssertTrue(error.localizedDescription.contains("导出前检查未通过"))
        }
    }

    func testPreparationReportsWarningsAndProducesSafeDegradedHTML() throws {
        let preparation = try HTMLExporter.prepare(
            snapshot: HTMLExportSnapshot(
                markdown: "[local](/Users/person/Secret.md) [unsafe](javascript:alert(1))"
            )
        )
        let html = try XCTUnwrap(String(data: preparation.data, encoding: .utf8))

        XCTAssertEqual(Set(preparation.warnings), Set([.localLink, .unsafeLink]))
        XCTAssertEqual(html.components(separatedBy: "inflow-disabled-link").count - 1, 2)
        XCTAssertTrue(html.contains("local</span>"))
        XCTAssertTrue(html.contains("unsafe</span>"))
        XCTAssertFalse(html.contains("/Users/person"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(preparation.warningMessage.contains("明确继续"))
    }

    func testExportInlinesValidatedLocalImageWithoutFilePath() throws {
        try withTemporaryDirectory { directory in
            let imageURL = directory.appendingPathComponent("photo.png")
            try testPNGData().write(to: imageURL)
            let data = try HTMLExporter.generate(
                snapshot: HTMLExportSnapshot(
                    markdown: "![本地图片](photo.png)",
                    documentDirectory: directory
                )
            )
            let html = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
            XCTAssertTrue(html.contains("alt=\"本地图片\""))
            XCTAssertFalse(html.contains("inflow-image-slot"))
            XCTAssertFalse(html.contains(imageURL.path))
            XCTAssertFalse(html.contains("file:"))
        }
    }

    func testStrictExportRejectsMissingOrUnavailableImageBeforeWriting() {
        let snapshot = HTMLExportSnapshot(
            markdown: "![missing](assets/missing.png)",
            documentDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertThrowsError(try HTMLExporter.generate(snapshot: snapshot)) { error in
            guard case let HTMLExportError.unsupportedContent(issues) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(issues, [.image])
        }
    }

    func testPreparationKeepsMissingImageAsExplicitPlaceholder() throws {
        let preparation = try HTMLExporter.prepare(
            snapshot: HTMLExportSnapshot(
                markdown: "![missing](assets/private-name.png)",
                documentDirectory: FileManager.default.temporaryDirectory
            )
        )
        let html = try XCTUnwrap(String(data: preparation.data, encoding: .utf8))

        XCTAssertEqual(preparation.warnings, [.image])
        XCTAssertTrue(html.contains("找不到资源"))
        XCTAssertTrue(html.contains("private-name.png"))
        XCTAssertFalse(html.contains("file:"))
        XCTAssertFalse(html.contains(FileManager.default.temporaryDirectory.path))
        XCTAssertFalse(html.contains("data-inflow-image-source-start"))
        XCTAssertFalse(html.contains("data-inflow-image-action"))
        XCTAssertFalse(html.contains("选择替代文件"))
    }

    func testExportDoesNotMistakeCodeTextForImageFailureMarkup() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: "```html\nclass=\"image-warning\"\n```")
        )
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    @MainActor
    func testPDFExportUsesA4PortraitTwentyMillimeterMarginsAndLatestSnapshot() async throws {
        XCTAssertEqual(PDFExporter.margin * 25.4 / 72.0, 20, accuracy: 0.01)
        let html = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "# PDF 快照\n\n最新内容 **Bold**\n\n$x_1^2$"
            )
        )
        let data = try await PDFExporter.generate(fromSelfContainedHTML: html)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 0)
        let page = try XCTUnwrap(document.page(at: 0))
        let mediaBox = page.bounds(for: .mediaBox)
        XCTAssertEqual(mediaBox.width, PDFExporter.paperSize.width, accuracy: 1)
        XCTAssertEqual(mediaBox.height, PDFExporter.paperSize.height, accuracy: 1)
        XCTAssertTrue(document.string?.contains("最新内容") == true)
        let selection = try XCTUnwrap(document.findString("最新内容").first)
        let textBounds = selection.bounds(for: page)
        XCTAssertGreaterThanOrEqual(textBounds.minX, PDFExporter.margin - 1)
        XCTAssertLessThanOrEqual(textBounds.maxX, PDFExporter.paperSize.width - PDFExporter.margin + 1)
        XCTAssertGreaterThanOrEqual(textBounds.minY, PDFExporter.margin - 1)
        XCTAssertLessThanOrEqual(textBounds.maxY, PDFExporter.paperSize.height - PDFExporter.margin + 1)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("file:") == true)
    }

    @MainActor
    func testLongPDFPaginatesWithoutChangingPaperSize() async throws {
        let markdown = (1...180).map { "## Section \($0)\n\nParagraph \($0) with content." }
            .joined(separator: "\n\n")
        let html = try HTMLExporter.generate(snapshot: HTMLExportSnapshot(markdown: markdown))
        let data = try await PDFExporter.generate(fromSelfContainedHTML: html)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, PDFExporter.paperSize.width, accuracy: 1)
            XCTAssertEqual(bounds.height, PDFExporter.paperSize.height, accuracy: 1)
        }
        XCTAssertTrue(document.string?.contains("Section 180") == true)
    }

    func testExportRendersFormulaAsSelfContainedMathML() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: "Inline $x_1^2$\n\n$$\\frac{a}{b}$$\n")
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("<math xmlns=\"http://www.w3.org/1998/Math/MathML\""))
        XCTAssertTrue(html.contains("<msubsup>"))
        XCTAssertTrue(html.contains("<mfrac>"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testExportedFormulaFallbackHasNoEditorOffsetsOrDeadActions() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "Before $\\unknown{<script>}$ after"
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("无法呈现这个公式"))
        XCTAssertTrue(html.contains("\\unknown{&lt;script&gt;}"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("data-inflow-source-start"))
        XCTAssertFalse(html.contains("data-inflow-source-end"))
        XCTAssertFalse(html.contains("data-inflow-preview-error-action"))
        XCTAssertFalse(html.contains("<button"))
    }

    func testExportRendersMermaidAsSelfContainedSVG() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "```mermaid\nflowchart TD\nA[开始] --> B[结束]\n```"
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("class=\"mermaid-diagram\""))
        XCTAssertTrue(html.contains("<svg"))
        XCTAssertTrue(html.contains("开始"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("cdn"))
    }

    func testExportedMermaidFallbackHasNoEditorOffsetsOrDeadActions() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "```mermaid\npie\ntitle Values\n```"
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("无法呈现这个图表"))
        XCTAssertTrue(html.contains("pie"))
        XCTAssertFalse(html.contains("data-inflow-source-start"))
        XCTAssertFalse(html.contains("data-inflow-source-end"))
        XCTAssertFalse(html.contains("data-inflow-preview-error-action"))
        XCTAssertFalse(html.contains("<button"))
    }

    func testExportFreezesDisabledFormulaAndMermaidPresentation() throws {
        let appearance = PreviewAppearanceConfiguration(
            contentWidth: 760,
            zoom: 1,
            colorScheme: .system,
            theme: .standard,
            increasedContrast: false,
            reduceMotion: false,
            mathRenderingEnabled: false,
            mermaidRenderingEnabled: false
        )
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "$x$\n\n```mermaid\nflowchart TD\nA --> B\n```",
                appearance: appearance
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("$x$"))
        XCTAssertFalse(html.contains("<math"))
        XCTAssertTrue(html.contains("language-mermaid"))
        XCTAssertFalse(html.contains("<figure class=\"mermaid-diagram\""))
        XCTAssertFalse(html.contains("<svg"))
    }

    func testWriterCreatesNewFileWithoutLeavingTemporaryArtifacts() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            let expected = try HTMLExportTargetSnapshot.capture(target)

            try HTMLExportFileWriter.write(
                Data("complete".utf8),
                to: target,
                expectedTarget: expected
            )

            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "complete")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterAtomicallyReplacesConfirmedExistingTarget() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            try Data("old-complete-version".utf8).write(to: target)
            let expected = try HTMLExportTargetSnapshot.capture(target)

            try HTMLExportFileWriter.write(
                Data("new-complete-version".utf8),
                to: target,
                expectedTarget: expected
            )

            XCTAssertEqual(
                try String(contentsOf: target, encoding: .utf8),
                "new-complete-version"
            )
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterRejectsTargetCreatedAfterConfirmation() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            let expected = try HTMLExportTargetSnapshot.capture(target)

            XCTAssertThrowsError(
                try HTMLExportFileWriter.write(
                    Data("inflow".utf8),
                    to: target,
                    expectedTarget: expected,
                    beforeCommit: {
                        try Data("external".utf8).write(to: target)
                    }
                )
            ) { error in
                XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterRejectsTargetModifiedAfterConfirmation() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            try Data("confirmed".utf8).write(to: target)
            let expected = try HTMLExportTargetSnapshot.capture(target)

            XCTAssertThrowsError(
                try HTMLExportFileWriter.write(
                    Data("inflow".utf8),
                    to: target,
                    expectedTarget: expected,
                    beforeCommit: {
                        try Data("external".utf8).write(to: target)
                    }
                )
            ) { error in
                XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterRejectsTargetReplacedWithIdenticalContentsAfterConfirmation() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            try Data("same-content".utf8).write(to: target)
            let expected = try HTMLExportTargetSnapshot.capture(target)

            XCTAssertThrowsError(
                try HTMLExportFileWriter.write(
                    Data("inflow".utf8),
                    to: target,
                    expectedTarget: expected,
                    beforeCommit: {
                        try FileManager.default.removeItem(at: target)
                        try Data("same-content".utf8).write(to: target)
                    }
                )
            ) { error in
                XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "same-content")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testTargetSnapshotRejectsSymlinksAndDirectories() throws {
        try withTemporaryDirectory { directory in
            let realFile = directory.appendingPathComponent("real.html")
            let symbolicLink = directory.appendingPathComponent("linked.html")
            try Data("private".utf8).write(to: realFile)
            try FileManager.default.createSymbolicLink(
                at: symbolicLink,
                withDestinationURL: realFile
            )

            for unsupportedTarget in [symbolicLink, directory] {
                XCTAssertThrowsError(try HTMLExportTargetSnapshot.capture(unsupportedTarget)) {
                    error in
                    XCTAssertEqual(error as? HTMLExportTargetError, .unsupportedTarget)
                }
            }
            XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "private")
        }
    }

    @MainActor
    func testFileMenuHasOneHTMLExportCommand() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        let exportMenus = items.filter { $0.title == "导出…" }
        XCTAssertEqual(exportMenus.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(exportMenus.first?.submenu).items.map(\.title),
            ["导出 HTML…", "导出 PDF…"]
        )
        XCTAssertEqual(items.filter { $0.title == "导出 HTML…" }.count, 1)
        XCTAssertEqual(items.filter { $0.title == "导出 PDF…" }.count, 1)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InflowHTMLExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func temporaryExportFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".inflow-export-") }
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

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
