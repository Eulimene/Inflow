import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
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

    func testExportFailurePromptsExposePDFOnlyRecoveryCopy() {
        let request = FrozenExportRequest(
            format: .pdf,
            snapshot: HTMLExportSnapshot(markdown: "# 冻结版本\n\ne\u{301}"),
            suggestedFilename: "draft.notes.pdf"
        )

        XCTAssertEqual(request.format, .pdf)
        XCTAssertEqual(request.suggestedFilename, "draft.notes.pdf")
        XCTAssertEqual(request.snapshot.utf8, Data("# 冻结版本\n\ne\u{301}".utf8))

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
        XCTAssertEqual(ExportFailurePrompt.checkFailedTitle, "导出结果未通过检查")
        XCTAssertEqual(
            ExportFailurePrompt.checkFailedMessage,
            "交付物包含不安全动作、私密路径或结构不完整，因此没有替换目标。"
        )
        XCTAssertEqual(ExportFailurePrompt.viewProblemsTitle, "查看问题")
        XCTAssertEqual(ExportFailurePrompt.closeTitle, "关闭")
        XCTAssertEqual(ExportFailurePrompt.retryTitle, "重试")
        XCTAssertEqual(
            ExportFailurePrompt.failureTitle(fileName: "draft.notes.pdf"),
            "未能导出「draft.notes.pdf」"
        )
        XCTAssertEqual(
            ExportFailurePrompt.failureMessage(reason: "未能完成交付。"),
            "未能完成交付。Markdown 文档未改变；请重新确认目标文件的状态。"
        )
        XCTAssertEqual(HTMLExportTargetError.cannotWrite.errorDescription, "未能完成交付")
    }

    @MainActor
    func testCancelledPDFGenerationStopsBeforeCreatingOutput() async {
        let task = Task { @MainActor in
            await Task.yield()
            return try await PDFExporter.generate(
                snapshot: HTMLExportSnapshot(markdown: "cancel", appearance: .personalPDF)
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

    func testHTMLExportIssueValuesRemainStable() {
        XCTAssertEqual(HTMLExportIssue.image.rawValue, 1)
        XCTAssertEqual(HTMLExportIssue.unsafeLink.rawValue, 16)
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

    func testFrozenExportRejectsImagesFromAReplacementProjectRoot() throws {
        try withTemporaryDirectory { directory in
            let project = directory.appendingPathComponent("project", isDirectory: true)
            let displacedProject = directory.appendingPathComponent(
                "displaced-project",
                isDirectory: true
            )
            let notes = project.appendingPathComponent("notes", isDirectory: true)
            let assets = project.appendingPathComponent("assets", isDirectory: true)
            for target in [notes, assets] {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            }
            let imageURL = assets.appendingPathComponent("photo.png")
            try testPNGData().write(to: imageURL)
            let projectIdentity = try XCTUnwrap(
                FolderProjectDirectoryIdentity.capture(project)
            )
            let frozen = HTMLExportSnapshot(
                markdown: "![project image](../assets/photo.png)",
                documentDirectory: notes,
                projectRoot: project,
                expectedProjectRootIdentity: projectIdentity,
                requiresProjectBoundary: true
            )

            try FileManager.default.moveItem(at: project, to: displacedProject)
            for target in [notes, assets] {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            }
            try testPNGData().write(to: imageURL)

            let preparation = try HTMLExporter.prepare(snapshot: frozen)
            let html = try XCTUnwrap(String(data: preparation.data, encoding: .utf8))
            XCTAssertEqual(preparation.warnings, [.image])
            XCTAssertTrue(html.contains("无法读取项目外图片"), html)
            XCTAssertFalse(html.contains("data:image/png;base64,"), html)
            XCTAssertThrowsError(try HTMLExporter.generate(snapshot: frozen)) { error in
                guard case let HTMLExportError.unsupportedContent(issues) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(issues, [.image])
            }
        }
    }

    func testPreparedExportWarnsAndDoesNotReadImageOutsideProjectBoundary() throws {
        try withTemporaryDirectory { directory in
            let project = directory.appendingPathComponent("project", isDirectory: true)
            let notes = project.appendingPathComponent("notes", isDirectory: true)
            let outside = directory.appendingPathComponent("outside", isDirectory: true)
            for target in [notes, outside] {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            }
            let outsideImage = outside.appendingPathComponent("private.png")
            try testPNGData().write(to: outsideImage)
            let outsideDirectoryLink = project.appendingPathComponent(
                "linked-outside",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: outsideDirectoryLink,
                withDestinationURL: outside
            )

            let preparation = try HTMLExporter.prepare(
                snapshot: HTMLExportSnapshot(
                    markdown: """
                    ![traversal](../../outside/private.png)

                    ![symlink](../linked-outside/private.png)
                    """,
                    documentDirectory: notes,
                    projectRoot: project
                )
            )
            let html = try XCTUnwrap(String(data: preparation.data, encoding: .utf8))

            XCTAssertTrue(preparation.warnings.contains(.image))
            XCTAssertTrue(html.contains("无法读取项目外图片"), html)
            XCTAssertEqual(
                html.components(separatedBy: "class=\"image-warning\"").count - 1,
                2,
                html
            )
            XCTAssertFalse(html.contains("src=\"data:image/png;base64,"), html)
            XCTAssertFalse(html.contains(outsideImage.path), html)
        }
    }

    func testExportRemovesPrivateMetadataFromPNGAndJPEG() throws {
        try withTemporaryDirectory { directory in
            for type in [UTType.png, .jpeg] {
                let marker = "INFLOW-PRIVATE-\(type.identifier)"
                let fileExtension = type == .png ? "png" : "jpg"
                let imageURL = directory.appendingPathComponent("private.\(fileExtension)")
                try privateImageData(type: type, marker: marker).write(to: imageURL)

                let data = try HTMLExporter.generate(
                    snapshot: HTMLExportSnapshot(
                        markdown: "![private](\(imageURL.lastPathComponent))",
                        documentDirectory: directory
                    )
                )
                let html = try XCTUnwrap(String(data: data, encoding: .utf8))
                let imageData = try embeddedImageData(
                    in: html,
                    mimeType: type == .png ? "image/png" : "image/jpeg"
                )
                XCTAssertNil(imageData.range(of: Data(marker.utf8)))

                let source = try XCTUnwrap(
                    CGImageSourceCreateWithData(imageData as CFData, nil)
                )
                let properties = try XCTUnwrap(
                    CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any]
                )
                let tiff = properties[kCGImagePropertyTIFFDictionary]
                    as? [CFString: Any]
                let exif = properties[kCGImagePropertyExifDictionary]
                    as? [CFString: Any]
                let gps = properties[kCGImagePropertyGPSDictionary]
                    as? [CFString: Any]
                let png = properties[kCGImagePropertyPNGDictionary]
                    as? [CFString: Any]
                XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
                XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
                XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
                XCTAssertNil(gps)
                XCTAssertNil(png?[kCGImagePropertyPNGAuthor])
                XCTAssertNil(png?[kCGImagePropertyPNGDescription])
                XCTAssertNil(png?[kCGImagePropertyPNGComment])
            }
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
        let snapshot = HTMLExportSnapshot(
            markdown: "# PDF 快照\n\n最新内容 **Bold**\n\n$x_1^2$",
            appearance: .personalPDF
        )
        let data = try await PDFExporter.generate(snapshot: snapshot)
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
    func testPDFExportRemovesHostVersionAndTimestampMetadata() async throws {
        let data = try await PDFExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "# Private metadata check",
                appearance: .personalPDF
            )
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue((document.documentAttributes ?? [:]).isEmpty)

        let rawPDF = try XCTUnwrap(String(data: data, encoding: .isoLatin1))
        for forbidden in [
            "/CreationDate",
            "/ModDate",
            "/Producer",
            "Quartz PDFContext",
            "macOS Version",
        ] {
            XCTAssertFalse(rawPDF.contains(forbidden), forbidden)
        }
    }

    @MainActor
    func testPDFKeepsOnlySafeWebLinksClickable() async throws {
        let snapshot = HTMLExportSnapshot(
            markdown: "[HTTPS](https://example.com/guide) [file](file:///Users/alice/private.md) [custom](inflow-script:run)",
            appearance: .personalPDF
        )
        let preparation = try HTMLExporter.prepare(snapshot: snapshot)
        XCTAssertEqual(
            preparation.warnings.map(\.rawValue),
            [HTMLExportIssue.localLink.rawValue, HTMLExportIssue.unsafeLink.rawValue]
        )
        let data = try await PDFExporter.generate(snapshot: snapshot)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let actions = (0..<document.pageCount).flatMap { index in
            document.page(at: index)?.annotations.compactMap {
                ($0.action as? PDFActionURL)?.url
            } ?? []
        }

        XCTAssertEqual(actions.map(\.absoluteString), ["https://example.com/guide"])
        try PDFDeliveryPostflight.validate(data)
    }

    @MainActor
    func testPDFPaintsSelectedThemeAcrossEveryPageCorner() async throws {
        let cases: [(PreviewTheme, PreviewColorScheme, [CGFloat])] = [
            (.standard, .dark, [1, 1, 1]),
            (try XCTUnwrap(PreviewTheme(rawValue: "night")), .light, [54 / 255, 59 / 255, 64 / 255]),
            (PreviewTheme(id: "custom-paper", label: "Custom", css: "body { background-color: #184c72; }"),
             .dark, [24 / 255, 76 / 255, 114 / 255]),
        ]
        for (theme, scheme, expected) in cases {
            let appearance = PreviewAppearanceConfiguration(
                contentWidth: 760,
                zoom: 1,
                colorScheme: scheme,
                theme: theme,
                increasedContrast: false,
                reduceMotion: false
            )
            let snapshot = HTMLExportSnapshot(
                markdown: String(repeating: "# Theme delivery\n\nEvery page edge must match the document surface.\n\n", count: 24),
                appearance: appearance
            )
            let data = try await PDFExporter.generate(snapshot: snapshot)
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertGreaterThan(document.pageCount, 1)
            for pageIndex in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: pageIndex))
                // Render into a declared color space; PDFKit thumbnails may use
                // a display-dependent profile and are not numeric color samples.
                let context = try XCTUnwrap(CGContext(
                    data: nil, width: 160, height: 226, bitsPerComponent: 8, bytesPerRow: 0,
                    space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                let bounds = page.bounds(for: .mediaBox)
                context.scaleBy(x: 160 / bounds.width, y: 226 / bounds.height)
                context.drawPDFPage(try XCTUnwrap(page.pageRef))
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let points = [(1, 1), (158, 1), (1, 224), (158, 224)]
                for (x, y) in points {
                    let offset = y * context.bytesPerRow + x * 4
                    let message = "\(theme.id), page \(pageIndex + 1), corner (\(x), \(y))"
                    for channel in 0..<3 {
                        XCTAssertEqual(CGFloat(pixels[offset + channel]) / 255, expected[channel],
                                       accuracy: 0.02, message)
                    }
                    XCTAssertEqual(pixels[offset + 3], 255, message)
                }
            }
        }
    }

    @MainActor
    func testPDFPersonalAppearanceUsesTheNativeLightTheme() {
        XCTAssertEqual(PreviewAppearanceConfiguration.personalPDF.colorScheme, .light)
        XCTAssertEqual(PreviewAppearanceConfiguration.personalPDF.theme, .standard)
        XCTAssertTrue(PreviewAppearanceConfiguration.personalPDF.mathRenderingEnabled)
        XCTAssertTrue(PreviewAppearanceConfiguration.personalPDF.mermaidRenderingEnabled)
    }

    func testPDFMetadataSanitizerFailsClosedForUnknownContainer() {
        XCTAssertThrowsError(
            try PDFContainerPrivacySanitizer.sanitize(Data("%PDF-1.7\n%%EOF".utf8))
        ) { error in
            XCTAssertEqual(error as? PDFExportError, .invalidOutput)
        }
    }

    func testVersionedPDFPostflightNegativeCorpus() throws {
        let corpus = try loadPDFPostflightCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.policyID, "inflow-pdf-delivery-postflight-v1")
        XCTAssertEqual(corpus.candidateStatus, "pending")
        XCTAssertEqual(corpus.cases.count, 13)

        for fixture in corpus.cases {
            let input = try makePDFPostflightFixture(fixture)
            let rawInput = try XCTUnwrap(String(data: input, encoding: .isoLatin1))
            XCTAssertNotNil(PDFDocument(data: input), fixture.id)
            for marker in fixture.forbiddenMarkers {
                XCTAssertTrue(rawInput.contains(marker), "\(fixture.id): \(marker)")
            }

            switch fixture.expectedOutcome {
            case "reject":
                XCTAssertThrowsError(
                    try PDFDeliveryPostflight.validate(input),
                    fixture.id
                ) { error in
                    XCTAssertEqual(error as? PDFExportError, .invalidOutput, fixture.id)
                }
                XCTAssertThrowsError(
                    try PDFContainerPrivacySanitizer.sanitize(input),
                    fixture.id
                ) { error in
                    XCTAssertEqual(error as? PDFExportError, .invalidOutput, fixture.id)
                }

            case "sanitize":
                XCTAssertThrowsError(
                    try PDFDeliveryPostflight.validate(input),
                    fixture.id
                )
                let output = try PDFContainerPrivacySanitizer.sanitize(input)
                try PDFDeliveryPostflight.validate(output)
                let rawOutput = try XCTUnwrap(String(data: output, encoding: .isoLatin1))
                for marker in fixture.forbiddenMarkers {
                    XCTAssertFalse(rawOutput.contains(marker), "\(fixture.id): \(marker)")
                }
                XCTAssertTrue(
                    (try XCTUnwrap(PDFDocument(data: output)).documentAttributes ?? [:]).isEmpty,
                    fixture.id
                )

            case "accept":
                try PDFDeliveryPostflight.validate(input)
                let output = try PDFContainerPrivacySanitizer.sanitize(input)
                try PDFDeliveryPostflight.validate(output)

            default:
                XCTFail("Unknown expected outcome for \(fixture.id)")
            }
        }
    }

    @MainActor
    func testPDFPostflightDoesNotTreatVisiblePageTextAsContainerMetadata() async throws {
        let snapshot = HTMLExportSnapshot(
            markdown: "```text\n/OpenAction /AA /EmbeddedFiles /Metadata /Users/alice/draft.md\n```",
            appearance: .personalPDF
        )
        let data = try await PDFExporter.generate(snapshot: snapshot)
        try PDFDeliveryPostflight.validate(data)

        let text = try XCTUnwrap(PDFDocument(data: data)?.string)
        XCTAssertTrue(text.contains("/OpenAction"), text)
        XCTAssertTrue(
            text.replacingOccurrences(of: "\n", with: "")
                .contains("/Users/alice/draft.md"),
            text
        )
    }

    func testExportDoesNotReportSuccessWhenTargetChangesAfterReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InflowExportPostCommit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("delivery.html")
        let expected = try HTMLExportTargetSnapshot.capture(target)
        let delivered = Data("expected delivery".utf8)
        let concurrent = Data("concurrent writer".utf8)

        XCTAssertThrowsError(
            try HTMLExportFileWriter.write(
                delivered,
                to: target,
                expectedTarget: expected,
                afterCommit: {
                    try? concurrent.write(to: target)
                }
            )
        ) { error in
            XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
        }
        XCTAssertEqual(try Data(contentsOf: target), concurrent)
    }

    @MainActor
    func testLongPDFPaginatesWithoutChangingPaperSize() async throws {
        let markdown = (1...180).map { "## Section \($0)\n\nParagraph \($0) with content." }
            .joined(separator: "\n\n")
        let data = try await PDFExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: markdown, appearance: .personalPDF)
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, PDFExporter.paperSize.width, accuracy: 1)
            XCTAssertEqual(bounds.height, PDFExporter.paperSize.height, accuracy: 1)
        }
        XCTAssertTrue(document.string?.contains("Section 180") == true)
    }

    @MainActor
    func testPDFWrapsWideCodeAndTableContentInsidePrintableBounds() async throws {
        let codePrefix = String(repeating: "code-segment-", count: 80)
        let tablePrefix = String(repeating: "table-segment-", count: 80)
        let markdown = """
        ```text
        \(codePrefix)CODE-END
        ```

        | Column |
        | --- |
        | \(tablePrefix)TABLE-END |
        """
        let data = try await PDFExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: markdown, appearance: .personalPDF)
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        let normalizedText = (document.string ?? "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        XCTAssertTrue(normalizedText.contains("CODE-END"))
        XCTAssertTrue(normalizedText.contains("TABLE-END"))

        // PDFKit may expose a visual wrap between the hyphen and END as a
        // newline, so search the stable prefix while separately proving that
        // the normalized extracted text contains the complete marker.
        for marker in ["CODE-", "TABLE-"] {
            let selection = try XCTUnwrap(
                document.findString(marker).first,
                "\(marker); PDF tail: \((document.string ?? "<no text>").suffix(240))"
            )
            let page = try XCTUnwrap(selection.pages.first, marker)
            let bounds = selection.bounds(for: page)
            XCTAssertGreaterThanOrEqual(bounds.minX, PDFExporter.margin - 1, marker)
            XCTAssertLessThanOrEqual(
                bounds.maxX,
                PDFExporter.paperSize.width - PDFExporter.margin + 1,
                marker
            )
        }
    }

    @MainActor
    func testPDFFitsWideDisplayFormulaInsidePrintableBounds() async throws {
        let formula = String(repeating: "x+", count: 160) + "FORMULAEND"
        let markdown = "$$\n\\text{\(formula)}\n$$\n"
        let data = try await PDFExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: markdown, appearance: .personalPDF)
        )
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        // MathJax emits vector paths, so searchable source text is no longer proof
        // of a rendered formula. Check actual page ink and its printable bounds.
        let image = page.thumbnail(of: NSSize(width: PDFExporter.paperSize.width * 2,
                                              height: PDFExporter.paperSize.height * 2), for: .mediaBox)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        var minimumX = bitmap.pixelsWide, maximumX = 0, ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      min(color.redComponent, color.greenComponent, color.blueComponent) < 0.85 else { continue }
                ink += 1
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
            }
        }
        let scale = CGFloat(bitmap.pixelsWide) / PDFExporter.paperSize.width
        XCTAssertGreaterThan(ink, 20, "The PDF must contain visible formula paths")
        XCTAssertGreaterThanOrEqual(CGFloat(minimumX) / scale, PDFExporter.margin - 2)
        XCTAssertLessThanOrEqual(CGFloat(maximumX) / scale, PDFExporter.paperSize.width - PDFExporter.margin + 2)
    }

    func testExportBundlesOfflineMathJax() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: "Inline $x_1^2$\n\n$$\\frac{a}{b}$$\n")
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("data-inflow-render=\"math\""))
        XCTAssertTrue(html.contains("x_1^2"))
        XCTAssertTrue(html.contains("MathJax"))
        XCTAssertTrue(html.contains("<script nonce="))
    }

    func testExportedFormulaFallbackHasNoEditorOffsetsOrDeadActions() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "Before $\\unknown{<script>}$ after"
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("data-inflow-render=\"math\""))
        XCTAssertTrue(html.contains("\\unknown{&lt;script&gt;}"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("data-inflow-source-start"))
        XCTAssertFalse(html.contains("data-inflow-source-end"))
        XCTAssertFalse(html.contains("data-inflow-preview-error-action"))
        XCTAssertFalse(html.contains("data-inflow-preview-error-action=\""))
    }

    func testExportBundlesOfflineDiagramAdapters() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "```mermaid\nflowchart TD\nA[开始] --> B[结束]\n```"
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("class=\"mermaid-diagram\""))
        XCTAssertTrue(html.contains("InflowRender.renderDocument()"))
        XCTAssertTrue(html.contains("开始"))
        XCTAssertTrue(html.contains("<script nonce="))
        XCTAssertFalse(html.contains("<script src="))
    }

    func testExportedMermaidFallbackHasNoEditorOffsetsOrDeadActions() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(
                markdown: "```mermaid\nflowchart LR\n-->\n```"
            )
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("data-inflow-render=\"mermaid\""))
        XCTAssertTrue(html.contains("flowchart LR"))
        XCTAssertFalse(html.contains("data-inflow-source-start"))
        XCTAssertFalse(html.contains("data-inflow-source-end"))
        XCTAssertFalse(html.contains("data-inflow-preview-error-action"))
        XCTAssertFalse(html.contains("data-inflow-preview-error-action=\""))
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

        // Disabled diagrams still use the code highlighter. Its bundled scripts
        // contain MathJax/SVG string literals, which are not document elements.
        let script = try XCTUnwrap(html.range(of: "<script nonce="))
        let markup = html[..<script.lowerBound]
        XCTAssertTrue(markup.contains("$x$"))
        XCTAssertTrue(markup.contains("language-mermaid"))
        XCTAssertTrue(markup.contains("flowchart TD"))
        XCTAssertTrue(markup.contains("A --&gt; B"))
        XCTAssertTrue(markup.contains("data-inflow-render=\"code\""))
        XCTAssertFalse(markup.contains("data-inflow-render=\"math\""))
        XCTAssertFalse(markup.contains("data-inflow-render=\"mermaid\""))
        XCTAssertFalse(markup.contains("<math"))
        XCTAssertFalse(markup.contains("<figure class=\"mermaid-diagram\""))
        XCTAssertFalse(markup.contains("<svg"))
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

    func testTargetSnapshotReadsBytesAndSHA256FromOneNoFollowDescriptor() throws {
        try withTemporaryDirectory { directory in
            let activeDirectory = directory.appendingPathComponent("active", isDirectory: true)
            let movedDirectory = directory.appendingPathComponent("opened", isDirectory: true)
            try FileManager.default.createDirectory(
                at: activeDirectory,
                withIntermediateDirectories: false
            )
            let target = activeDirectory.appendingPathComponent("document.html")
            let original = Data("opened descriptor bytes".utf8)
            let replacement = Data("replacement pathname bytes".utf8)
            try original.write(to: target)

            let captured = try HTMLExportTargetSnapshot.captureContents(
                target,
                afterOpeningDescriptor: {
                    try FileManager.default.moveItem(
                        at: activeDirectory,
                        to: movedDirectory
                    )
                    try FileManager.default.createDirectory(
                        at: activeDirectory,
                        withIntermediateDirectories: false
                    )
                    try replacement.write(to: target)
                }
            )

            XCTAssertEqual(captured.data, original)
            XCTAssertTrue(captured.snapshot.hasContents(original))
            XCTAssertFalse(captured.snapshot.hasContents(replacement))
            XCTAssertNotEqual(
                captured.snapshot,
                try HTMLExportTargetSnapshot.capture(target)
            )
            XCTAssertEqual(try Data(contentsOf: target), replacement)
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
    func testFileMenuHasOnePDFExportCommandAndNoHTMLEntry() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        XCTAssertEqual(items.filter { $0.title == "导出…" }.count, 0)
        XCTAssertEqual(items.filter { $0.title == "导出 HTML…" }.count, 0)
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

    private func loadPDFPostflightCorpus() throws -> PDFPostflightCorpus {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let codeDirectory = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpusURL = codeDirectory
            .appendingPathComponent("quality", isDirectory: true)
            .appendingPathComponent("pdf-postflight-negative-corpus-v1.json")
        return try JSONDecoder().decode(
            PDFPostflightCorpus.self,
            from: Data(contentsOf: corpusURL)
        )
    }

    private func makePDFPostflightFixture(_ fixture: PDFPostflightFixture) throws -> Data {
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R \(fixture.catalogFragment) >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] /Resources << >> /Contents 4 0 R \(fixture.pageFragment) >>",
            4: "<< /Length 0 >>\nstream\n\nendstream",
            5: "<< \(fixture.infoFragment) >>",
        ]
        for extra in fixture.extraObjects {
            guard objects[extra.number] == nil else {
                throw PDFPostflightFixtureError.duplicateObject(extra.number)
            }
            if let stream = extra.stream {
                objects[extra.number] = "<< \(extra.dictionary) /Length \(Data(stream.utf8).count) >>\nstream\n\(stream)\nendstream"
            } else {
                objects[extra.number] = "<< \(extra.dictionary) >>"
            }
        }

        let highestObjectNumber = try XCTUnwrap(objects.keys.max())
        var output = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int: Int] = [:]
        for objectNumber in objects.keys.sorted() {
            offsets[objectNumber] = output.count
            output.append(
                Data("\(objectNumber) 0 obj\n\(objects[objectNumber]!)\nendobj\n".utf8)
            )
        }

        let crossReferenceOffset = output.count
        output.append(Data("xref\n0 \(highestObjectNumber + 1)\n".utf8))
        output.append(Data("0000000000 65535 f \n".utf8))
        for objectNumber in 1 ... highestObjectNumber {
            if let offset = offsets[objectNumber] {
                output.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
            } else {
                output.append(Data("0000000000 00000 f \n".utf8))
            }
        }
        output.append(
            Data(
                "trailer\n<< /Size \(highestObjectNumber + 1) /Root 1 0 R /Info 5 0 R >>\nstartxref\n\(crossReferenceOffset)\n%%EOF\n".utf8
            )
        )
        return output
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

    private func privateImageData(type: UTType, marker: String) throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 6,
                bitsPerPixel: 24
            )
        )
        let pixels = try XCTUnwrap(representation.bitmapData)
        for index in 0..<6 {
            pixels[index] = UInt8(30 + index * 20)
        }
        let image = try XCTUnwrap(representation.cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                type.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [CFString: Any]
        if type == .png {
            properties = [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyPNGAuthor: marker,
                    kCGImagePropertyPNGDescription: marker,
                    kCGImagePropertyPNGComment: marker,
                ],
            ]
        } else {
            properties = [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: marker,
                    kCGImagePropertyTIFFModel: marker,
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: marker,
                ],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLatitude: 31.2304,
                    kCGImagePropertyGPSLongitudeRef: "E",
                    kCGImagePropertyGPSLongitude: 121.4737,
                ],
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func embeddedImageData(in html: String, mimeType: String) throws -> Data {
        let prefix = "src=\"data:\(mimeType);base64,"
        let start = try XCTUnwrap(html.range(of: prefix)?.upperBound)
        let end = try XCTUnwrap(html[start...].firstIndex(of: "\""))
        return try XCTUnwrap(Data(base64Encoded: String(html[start..<end])))
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}

private struct PDFPostflightCorpus: Decodable {
    let schemaVersion: Int
    let policyID: String
    let candidateStatus: String
    let cases: [PDFPostflightFixture]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case policyID = "policy_id"
        case candidateStatus = "candidate_status"
        case cases
    }
}

private struct PDFPostflightFixture: Decodable {
    let id: String
    let expectedOutcome: String
    let catalogFragment: String
    let pageFragment: String
    let infoFragment: String
    let extraObjects: [PDFPostflightExtraObject]
    let forbiddenMarkers: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case expectedOutcome = "expected_outcome"
        case catalogFragment = "catalog_fragment"
        case pageFragment = "page_fragment"
        case infoFragment = "info_fragment"
        case extraObjects = "extra_objects"
        case forbiddenMarkers = "forbidden_markers"
    }
}

private struct PDFPostflightExtraObject: Decodable {
    let number: Int
    let dictionary: String
    let stream: String?
}

private enum PDFPostflightFixtureError: Error {
    case duplicateObject(Int)
}
