import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Inflow

final class MarkdownRendererTests: XCTestCase {
    func testMegabyteDocumentDerivesCompletePreviewWithinUpdateBudget() throws {
        let paragraph = String(repeating: "alpha beta gamma delta ", count: 5)
        var lines = (0..<10_000).map { index in
            index.isMultiple(of: 100)
                ? "## Section \(index) \(paragraph)"
                : "Paragraph \(index) \(paragraph)"
        }
        lines.append("## FINAL-PREVIEW-MARKER")
        let source = lines.joined(separator: "\n")
        XCTAssertGreaterThan(source.utf8.count, 1_000_000)
        XCTAssertGreaterThanOrEqual(source.filter(\.isNewline).count, 10_000)

        let analysisStarted = ProcessInfo.processInfo.systemUptime
        let analysis = try MarkdownAnalyzer.analyze(source)
        let analysisElapsed = ProcessInfo.processInfo.systemUptime - analysisStarted
        let highlightingStarted = ProcessInfo.processInfo.systemUptime
        let highlighting = try MarkdownHighlighter.spans(in: source)
        let highlightingElapsed = ProcessInfo.processInfo.systemUptime - highlightingStarted
        let previewStarted = ProcessInfo.processInfo.systemUptime
        let preview = MarkdownRenderer.previewDocument(
            for: source,
            navigationHeadings: analysis.headings
        )
        let previewElapsed = ProcessInfo.processInfo.systemUptime - previewStarted

        XCTAssertNil(preview.failureMessage)
        XCTAssertTrue(preview.html.contains("FINAL-PREVIEW-MARKER"))
        XCTAssertEqual(analysis.headings.last?.title, "FINAL-PREVIEW-MARKER")
        XCTAssertTrue(highlighting.contains { $0.utf8Range.upperBound > 1_000_000 })
        let elapsed = analysisElapsed + highlightingElapsed + previewElapsed
        #if DEBUG
        XCTAssertLessThan(elapsed, 1.0, "Debug pipeline took \(elapsed) seconds")
        #else
        XCTAssertLessThan(elapsed, 0.3, "Release pipeline took \(elapsed) seconds")
        #endif
    }

    func testPreviewFailureUsesFrozenSafeExitCopyAndKeepsDetailsOutOfHTML() {
        XCTAssertEqual(PreviewFailurePrompt.title, "暂时无法更新预览")
        XCTAssertEqual(PreviewFailurePrompt.message, "编辑和保存仍可用。")
        XCTAssertEqual(PreviewFailurePrompt.retryTitle, "重试预览")
        XCTAssertEqual(PreviewFailurePrompt.hideTitle, "隐藏预览")

        let result = MarkdownRenderer.previewDocument(
            for: "# private source",
            documentDirectory: nil,
            configuration: .default,
            navigationHeadings: [],
            fragmentRenderer: { _, _ in throw MarkdownRenderError.coreFailure }
        )

        XCTAssertEqual(
            result.failureMessage,
            MarkdownRenderError.coreFailure.localizedDescription
        )
        XCTAssertTrue(result.html.contains(PreviewFailurePrompt.title))
        XCTAssertTrue(result.html.contains(PreviewFailurePrompt.message))
        XCTAssertFalse(result.html.contains("private source"))
        XCTAssertFalse(result.html.contains("Markdown 预览暂时无法更新"))
        XCTAssertTrue(result.html.contains("default-src 'none'"))
    }

    func testSuccessfulPreviewDocumentDoesNotReportFailure() {
        let result = MarkdownRenderer.previewDocument(for: "# Ready")

        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(result.html.contains("<h1>Ready</h1>"))
        XCTAssertFalse(result.html.contains(PreviewFailurePrompt.title))
    }

    func testPreviewDerivationReportsRelativeResourcesWithoutAnotherSourceScan() {
        let local = MarkdownRenderer.previewDocument(
            for: "![cover](assets/cover.png) [guide](guide/readme.md)"
        )
        let remote = MarkdownRenderer.previewDocument(
            for: "![cover](https://example.com/cover.png) [part](#part)"
        )

        XCTAssertTrue(local.hasRelativeResources)
        XCTAssertFalse(remote.hasRelativeResources)
    }

    func testPreviewAddsSafeSelfContainedColorsForKnownCodeLanguages() throws {
        let fragment = try MarkdownRenderer.htmlFragment(
            for: "```rust\nfn main() { println!(\"<tag>你好</tag>\"); } // note\n```\n"
        )

        XCTAssertTrue(fragment.contains("language-rust inflow-code-highlight"))
        XCTAssertTrue(fragment.contains("<span class=\"tok-keyword\">fn</span>"))
        XCTAssertTrue(fragment.contains("<span class=\"tok-comment\">// note</span>"))
        XCTAssertTrue(fragment.contains("&lt;tag&gt;你好&lt;/tag&gt;"))
        XCTAssertFalse(fragment.contains("<tag>你好</tag>"))

        let document = MarkdownRenderer.document(containing: fragment)
        XCTAssertTrue(document.contains(".tok-keyword { color:"))
        XCTAssertTrue(document.contains("@media (prefers-color-scheme: dark)"))
        XCTAssertFalse(document.contains("<script"))

        let forcedDark = PreviewAppearanceCSS.styleElement(
            for: PreviewAppearanceConfiguration(
                contentWidth: 760,
                zoom: 1,
                colorScheme: .dark,
                theme: .standard,
                increasedContrast: false,
                reduceMotion: false,
                mathRenderingEnabled: true,
                mermaidRenderingEnabled: true
            )
        )
        XCTAssertTrue(forcedDark.contains(".tok-keyword { color: #ff7b72; }"))

        let highContrast = PreviewAppearanceCSS.styleElement(
            for: PreviewAppearanceConfiguration(
                contentWidth: 760,
                zoom: 1,
                colorScheme: .system,
                theme: .highContrast,
                increasedContrast: false,
                reduceMotion: false,
                mathRenderingEnabled: true,
                mermaidRenderingEnabled: true
            )
        )
        XCTAssertTrue(highContrast.contains(".tok-comment { text-decoration: underline dotted; }"))
    }

    func testRenderOptionValuesMatchRustContract() {
        XCTAssertEqual(INFLOW_RENDER_OPTION_MATH, UInt32(1 << 0))
        XCTAssertEqual(INFLOW_RENDER_OPTION_MERMAID, UInt32(1 << 1))
        XCTAssertEqual(
            INFLOW_RENDER_OPTIONS_DEFAULT,
            INFLOW_RENDER_OPTION_MATH | INFLOW_RENDER_OPTION_MERMAID
        )
        XCTAssertEqual(
            PreviewAppearanceConfiguration.default.coreRenderOptions,
            INFLOW_RENDER_OPTIONS_DEFAULT
        )
    }

    func testRendersCommonMarkdownAndExtensions() throws {
        let html = try MarkdownRenderer.htmlFragment(
            for: "# Title\n\n**Bold** and ~~old~~\n\n- [x] Done\n"
        )

        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("<del>old</del>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
    }

    func testRawHTMLIsEscaped() throws {
        let html = try MarkdownRenderer.htmlFragment(
            for: "<script>window.location='https://example.com'</script>"
        )

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testPresentationFeaturesCanBeDisabledWithoutChangingSource() throws {
        let configuration = PreviewAppearanceConfiguration(
            contentWidth: 760,
            zoom: 1,
            colorScheme: .system,
            theme: .standard,
            increasedContrast: false,
            reduceMotion: false,
            mathRenderingEnabled: false,
            mermaidRenderingEnabled: false
        )
        let source = "$x^2$\n\n```mermaid\nflowchart TD\nA --> B\n```"
        let html = try MarkdownRenderer.htmlFragment(
            for: source,
            configuration: configuration
        )

        XCTAssertTrue(html.contains("$x^2$"))
        XCTAssertFalse(html.contains("<math"))
        XCTAssertTrue(html.contains("language-mermaid"))
        XCTAssertTrue(html.contains("flowchart TD"))
        XCTAssertFalse(html.contains("mermaid-diagram"))
        XCTAssertFalse(html.contains("<svg"))
        XCTAssertEqual(source, "$x^2$\n\n```mermaid\nflowchart TD\nA --> B\n```")
    }

    func testMermaidFailureCarriesSafeSourceLocationAndRecoveryActions() throws {
        let source = "前文\n\n```mermaid\npie\ntitle Values\n```\n\n后文"
        let fragment = try MarkdownRenderer.htmlFragment(for: source)
        let marker = try XCTUnwrap(source.range(of: "```mermaid"))
        let markerStart = try XCTUnwrap(marker.lowerBound.samePosition(in: source.utf8))
        let start = source.utf8.distance(from: source.utf8.startIndex, to: markerStart)

        XCTAssertTrue(fragment.contains("无法呈现这个图表"))
        XCTAssertTrue(fragment.contains("当前文档的其他内容和其他文档不受影响"))
        XCTAssertTrue(fragment.contains("data-inflow-source-start=\"\(start)\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"locate\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"retry\""))
        XCTAssertTrue(fragment.contains(">定位源文本</button>"))
        XCTAssertTrue(fragment.contains(">重试</button>"))
        XCTAssertFalse(fragment.contains("<script"))
    }

    func testFormulaFailureCarriesSafeSourceLocationAndRecoveryActions() throws {
        let source = "前文 $\\unknown{<script>}$ 后文"
        let fragment = try MarkdownRenderer.htmlFragment(for: source)
        let formula = try XCTUnwrap(source.range(of: "$\\unknown{<script>}$"))
        let lower = try XCTUnwrap(formula.lowerBound.samePosition(in: source.utf8))
        let upper = try XCTUnwrap(formula.upperBound.samePosition(in: source.utf8))
        let start = source.utf8.distance(from: source.utf8.startIndex, to: lower)
        let end = source.utf8.distance(from: source.utf8.startIndex, to: upper)

        XCTAssertTrue(fragment.contains("无法呈现这个公式"))
        XCTAssertTrue(fragment.contains("原内容已保留，当前文档的其他内容和其他文档不受影响。"))
        XCTAssertTrue(fragment.contains("data-inflow-source-start=\"\(start)\""))
        XCTAssertTrue(fragment.contains("data-inflow-source-end=\"\(end)\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"locate\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"retry\""))
        XCTAssertTrue(fragment.contains("&lt;script&gt;"))
        XCTAssertFalse(fragment.contains("<script>"))
    }

    func testPreviewDocumentForbidsScriptsAndNetworkRequests() {
        let html = MarkdownRenderer.htmlDocument(for: "# Safe preview")

        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("img-src data:"))
        XCTAssertFalse(html.contains("img-src data: file:"))
        XCTAssertTrue(html.contains("<h1>Safe preview</h1>"))
    }

    func testLocalStaticPNGIsInlinedWithoutGivingWebKitAFilePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let imageURL = assets.appendingPathComponent("cover.png")
        try pngData().write(to: imageURL)

        let html = MarkdownRenderer.htmlDocument(
            for: "![封面 <图>](assets/cover.png)",
            documentDirectory: directory
        )

        XCTAssertTrue(html.contains("class=\"inflow-local-image\""))
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
        XCTAssertTrue(html.contains("alt=\"封面 &lt;图&gt;\""))
        XCTAssertFalse(html.contains("inflow-image-slot"))
        XCTAssertFalse(html.contains(imageURL.path))
    }

    func testMissingAndUnsavedRelativeImagesShowSpecificLocalPlaceholders() {
        let saved = MarkdownRenderer.htmlDocument(
            for: "![封面](assets/missing.png)",
            documentDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertTrue(saved.contains("找不到资源"))
        XCTAssertTrue(saved.contains("assets/missing.png"), saved)
        XCTAssertTrue(saved.contains("data-inflow-image-source-start=\"0\""))
        XCTAssertTrue(saved.contains("data-inflow-image-target-hex=\"\(hex("assets/missing.png"))\""))
        XCTAssertTrue(saved.contains("data-inflow-image-action=\"replace\""))
        XCTAssertTrue(saved.contains("选择替代文件…"))
        XCTAssertTrue(saved.contains("data-inflow-image-action=\"locate\""))
        XCTAssertTrue(saved.contains("data-inflow-image-action=\"ignore\""))

        let unsaved = MarkdownRenderer.htmlDocument(
            for: "![封面](assets/missing.png)",
            documentDirectory: nil
        )
        XCTAssertTrue(unsaved.contains("暂时无法读取相对图片"))
        XCTAssertTrue(unsaved.contains("请先保存文档"))
    }

    func testRemoteAndUnsupportedImagesNeverBecomeNetworkRequests() throws {
        let remote = MarkdownRenderer.htmlDocument(
            for: "![外部](https://private.example/path/secret.png)"
        )
        XCTAssertTrue(remote.contains("远程图片未加载"))
        XCTAssertFalse(remote.contains("private.example"))
        XCTAssertFalse(remote.contains("src=\"https://"))
        XCTAssertTrue(remote.contains("data-inflow-image-action=\"copyTarget\""))
        XCTAssertFalse(remote.contains("data-inflow-image-action=\"replace\""))

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disguised = directory.appendingPathComponent("wrong.jpg")
        try pngData().write(to: disguised)
        let mismatch = MarkdownRenderer.htmlDocument(
            for: "![伪装](wrong.jpg)",
            documentDirectory: directory
        )
        XCTAssertTrue(mismatch.contains("图片类型与扩展名不一致"))
        XCTAssertFalse(mismatch.contains("data:image"))
    }

    func testCoreImageSlotsAreInertUntilResolvedByThePlatform() throws {
        let fragment = try MarkdownRenderer.htmlFragment(
            for: "![封面](assets/cover.png)"
        )
        XCTAssertTrue(fragment.contains("class=\"inflow-image-slot\""))
        XCTAssertFalse(fragment.contains("<img"))
        XCTAssertFalse(fragment.contains("src="))

        let mismatched = LocalImageResolver.resolveSlots(
            in: fragment,
            documentDirectory: FileManager.default.temporaryDirectory,
            imageReferences: []
        )
        XCTAssertTrue(mismatched.contains("找不到资源"))
        XCTAssertFalse(mismatched.contains("data-inflow-image-source-start"))
        XCTAssertFalse(mismatched.contains("data-inflow-image-action"))
    }

    func testSplitViewIsTheDefaultMode() {
        XCTAssertEqual(EditorViewMode.split.rawValue, "split")
        XCTAssertEqual(EditorViewMode.allCases.count, 3)
    }

    func testPreviewHeadingsCarryExactSourceOffsetsOnlyWhenEnabled() throws {
        let markdown = "# 重复\n\n正文\n\n## 重复\n"
        let analysis = try MarkdownAnalyzer.analyze(markdown)
        let enabled = MarkdownRenderer.htmlDocument(
            for: markdown,
            navigationHeadings: analysis.headings
        )

        XCTAssertEqual(enabled.components(separatedBy: "<h1 data-inflow-source-start").count - 1, 1)
        XCTAssertEqual(enabled.components(separatedBy: "<h2 data-inflow-source-start").count - 1, 1)
        XCTAssertTrue(enabled.contains(
            "<h1 data-inflow-source-start=\"\(analysis.headings[0].sourceUTF8Range.lowerBound)\" tabindex=\"0\""
        ))
        XCTAssertTrue(enabled.contains(
            "<h2 data-inflow-source-start=\"\(analysis.headings[1].sourceUTF8Range.lowerBound)\" tabindex=\"0\""
        ))
        XCTAssertFalse(enabled.contains("<script"))

        let disabled = MarkdownRenderer.htmlDocument(for: markdown)
        XCTAssertFalse(disabled.contains("<h1 data-inflow-source-start"))
        XCTAssertFalse(disabled.contains("<h2 data-inflow-source-start"))
    }

    func testHeadingAnnotationFailsClosedWhenAnalysisDoesNotMatchRenderedHeadings() {
        let fragment = "<h1>One</h1><h2>Two</h2>"
        let mismatched = [
            DocumentHeading(level: 2, title: "One", sourceUTF8Range: 0..<5),
            DocumentHeading(level: 1, title: "Two", sourceUTF8Range: 6..<11),
        ]

        XCTAssertEqual(
            PreviewNavigationMarkup.annotateHeadings(in: fragment, headings: mismatched),
            fragment
        )
    }

    func testLinkAnnotationCarriesExactParsedTargetAndFailsClosedOnCountDrift() throws {
        let markdown = "Footnote[^n] [space](<https://example.com/a b>) [资料](资料/说明.md)\n\n[^n]: Note"
        let html = MarkdownRenderer.htmlDocument(for: markdown)

        XCTAssertTrue(html.contains("<a href=\"#n\">1</a>"))
        XCTAssertFalse(html.contains("<a href=\"#n\" data-inflow-link-target-hex"))
        XCTAssertTrue(html.contains("href=\"https://example.com/a%20b\""))
        XCTAssertTrue(html.contains(
            "data-inflow-link-target-hex=\"\(hex("https://example.com/a b"))\""
        ))
        XCTAssertTrue(html.contains(
            "data-inflow-link-target-hex=\"\(hex("资料/说明.md"))\""
        ))

        let fragment = try MarkdownRenderer.htmlFragment(for: markdown)
        XCTAssertEqual(
            PreviewNavigationMarkup.annotateLinks(in: fragment, targets: ["only-one"]),
            fragment
        )
    }

    func testPreviewBridgeAcceptsOnlyClosedNavigationMessages() {
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "heading",
                "sourceUTF8Offset": NSNumber(value: 42),
            ]),
            .heading(sourceUTF8Offset: 42)
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode(["type": "manualScroll"]),
            .manualScroll
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "previewIssue",
                "action": "locate",
                "sourceUTF8Offset": NSNumber(value: 19),
            ]),
            .previewIssue(action: .locate, sourceUTF8Offset: 19)
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "imageIssue",
                "action": "replace",
                "sourceUTF8Offset": NSNumber(value: 23),
                "targetHex": hex("assets/图.png"),
            ]),
            .imageIssue(
                action: .replace,
                sourceUTF8Offset: 23,
                target: "assets/图.png"
            )
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "link",
                "targetHex": hex("../资料/说明.md#标题"),
            ]),
            .link(target: "../资料/说明.md#标题")
        )
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "heading",
            "sourceUTF8Offset": "private document text",
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "heading",
            "sourceUTF8Offset": NSNumber(value: true),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "heading",
            "sourceUTF8Offset": NSNumber(value: 1.5),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "link",
            "targetHex": "0g",
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "link",
            "targetHex": hex("https://example.com/\nprivate"),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "previewIssue",
            "action": "open-private-path",
            "sourceUTF8Offset": NSNumber(value: 0),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "imageIssue",
            "action": "open-file",
            "sourceUTF8Offset": NSNumber(value: 0),
            "targetHex": hex("private.png"),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "imageIssue",
            "action": "locate",
            "sourceUTF8Offset": NSNumber(value: true),
            "targetHex": hex("private.png"),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "unknown",
            "document": "must not cross bridge",
        ]))
    }

    @MainActor
    func testPreviewCoordinatorRoutesHeadingAndManualScrollWithoutDocumentContent() {
        let coordinator = MarkdownPreviewView.Coordinator()
        let webView = WKWebView()
        var selectedOffset: Int?
        var selectedLink: String?
        var selectedIssue: (PreviewIssueAction, Int)?
        var selectedImageIssue: (PreviewImageIssueAction, Int, String)?
        var manualScrollCount = 0
        coordinator.update(
            scrollRequest: PreviewScrollRequest(generation: 1, fraction: 0.5),
            onHeadingActivated: { selectedOffset = $0 },
            onLinkActivated: { selectedLink = $0 },
            onPreviewIssueAction: { selectedIssue = ($0, $1) },
            onImageIssueAction: { selectedImageIssue = ($0, $1, $2) },
            onManualScroll: { manualScrollCount += 1 },
            webView: webView
        )

        coordinator.handle(.heading(sourceUTF8Offset: 128))
        coordinator.handle(.link(target: "https://example.com"))
        coordinator.handle(.previewIssue(action: .retry, sourceUTF8Offset: 64))
        coordinator.handle(.imageIssue(
            action: .copyTarget,
            sourceUTF8Offset: 72,
            target: "https://example.com/image.png"
        ))
        coordinator.handle(.manualScroll)

        XCTAssertEqual(selectedOffset, 128)
        XCTAssertEqual(selectedLink, "https://example.com")
        XCTAssertEqual(selectedIssue?.0, .retry)
        XCTAssertEqual(selectedIssue?.1, 64)
        XCTAssertEqual(selectedImageIssue?.0, .copyTarget)
        XCTAssertEqual(selectedImageIssue?.1, 72)
        XCTAssertEqual(selectedImageIssue?.2, "https://example.com/image.png")
        XCTAssertEqual(manualScrollCount, 1)
    }

    func testPreviewIssueNavigationRejectsStaleAndInvalidUTF8Offsets() throws {
        let rendered = "# 图表\n\n```mermaid\npie\n```"
        let marker = try XCTUnwrap(rendered.range(of: "```mermaid"))
        let markerStart = try XCTUnwrap(marker.lowerBound.samePosition(in: rendered.utf8))
        let offset = rendered.utf8.distance(from: rendered.utf8.startIndex, to: markerStart)
        XCTAssertEqual(
            PreviewIssueNavigation.validatedOffset(
                offset,
                renderedSource: rendered,
                currentSource: rendered
            ),
            offset
        )
        XCTAssertNil(PreviewIssueNavigation.validatedOffset(
            offset,
            renderedSource: rendered,
            currentSource: rendered + "\nchanged"
        ))
        XCTAssertNil(PreviewIssueNavigation.validatedOffset(
            2,
            renderedSource: "e\u{301}",
            currentSource: "e\u{301}"
        ))
    }

    func testImageIssueNavigationUsesExactDuplicateReferenceAndRejectsStaleContent() throws {
        let markdown = "![第一张](missing.png)\n\n![第二张](missing.png)"
        let references = try MarkdownReferenceScanner.references(in: markdown)
        let second = try XCTUnwrap(references.last)

        XCTAssertEqual(
            PreviewImageIssueNavigation.validatedReference(
                sourceUTF8Offset: second.sourceUTF8Range.lowerBound,
                target: "missing.png",
                renderedSource: markdown,
                currentSource: markdown
            ),
            second
        )
        XCTAssertNil(PreviewImageIssueNavigation.validatedReference(
            sourceUTF8Offset: references[0].sourceUTF8Range.lowerBound,
            target: "other.png",
            renderedSource: markdown,
            currentSource: markdown
        ))
        XCTAssertNil(PreviewImageIssueNavigation.validatedReference(
            sourceUTF8Offset: second.sourceUTF8Range.lowerBound,
            target: "missing.png",
            renderedSource: markdown,
            currentSource: markdown + "\nchanged"
        ))
    }

    func testLinkPlannerRequiresAnExactParsedCurrentReferenceAndSafeScheme() {
        let markdown = "[web](https://example.com/path) [mail](mailto:writer@example.com)"
        let web = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "https://example.com/path",
            documentURL: nil
        )
        guard case let .external(link) = web.destination else {
            return XCTFail("expected an external link")
        }
        XCTAssertEqual(link.url.absoluteString, "https://example.com/path")
        XCTAssertEqual(link.displayDestination, "example.com")
        XCTAssertTrue(PreviewLinkPlanner.isCurrent(web, markdown: markdown))
        XCTAssertFalse(PreviewLinkPlanner.isCurrent(web, markdown: markdown + "\nchanged"))

        let stale = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "https://removed.example",
            documentURL: nil
        )
        XCTAssertEqual(blockedReason(stale), .noLongerInDocument)

        let unsafeMarkdown = "[script](javascript:alert%281%29) [credentials](https://user:pass@example.com)"
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: unsafeMarkdown,
                target: "javascript:alert%281%29",
                documentURL: nil
            )),
            .unsupportedScheme
        )
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: unsafeMarkdown,
                target: "https://user:pass@example.com",
                documentURL: nil
            )),
            .invalidTarget
        )
        let encodedControl = "https://example.com/%0Aprivate"
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[control](\(encodedControl))",
                target: encodedControl,
                documentURL: nil
            )),
            .invalidTarget
        )
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[mail](mailto:writer@example.com?body=private)",
                target: "mailto:writer@example.com?body=private",
                documentURL: nil
            )),
            .invalidTarget
        )
    }

    func testLinkPlannerResolvesCurrentAndDuplicateUnicodeHeadingAnchors() throws {
        let markdown = "# Café\n\n# Café\n\n## 中文 标题\n\n[same](#caf%C3%A9-1)"
        let analysis = try MarkdownAnalyzer.analyze(markdown)
        let plan = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "#caf%C3%A9-1",
            documentURL: nil
        )
        XCTAssertEqual(plan.destination, .currentDocument(fragment: "café-1"))
        XCTAssertEqual(
            PreviewHeadingAnchorResolver.heading(for: "café-1", in: analysis.headings),
            analysis.headings[1]
        )
        XCTAssertEqual(
            PreviewHeadingAnchorResolver.heading(
                for: "%E4%B8%AD%E6%96%87-%E6%A0%87%E9%A2%98",
                in: analysis.headings
            ),
            analysis.headings[2]
        )
        XCTAssertNil(PreviewHeadingAnchorResolver.heading(for: "missing", in: analysis.headings))
    }

    func testLinkPlannerClassifiesLocalTargetsAndInvalidatesChangedSnapshots() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.md")
        let targetURL = directory.appendingPathComponent("guide.md")
        try Data("# Target\n".utf8).write(to: targetURL)
        let markdown = "[guide](guide.md#target)"

        let plan = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "guide.md#target",
            documentURL: sourceURL
        )
        guard case let .local(link) = plan.destination else {
            return XCTFail("expected a local link")
        }
        XCTAssertEqual(link.kind, .markdown)
        XCTAssertEqual(link.fragment, "target")
        XCTAssertEqual(link.url.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertTrue(PreviewLinkPlanner.localTargetIsCurrent(link))

        try Data("# Replaced with different bytes\n".utf8).write(to: targetURL)
        XCTAssertFalse(PreviewLinkPlanner.localTargetIsCurrent(link))

        let unsaved = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "guide.md#target",
            documentURL: nil
        )
        XCTAssertEqual(blockedReason(unsaved), .relativeTargetNeedsSavedDocument)

        let sameDocument = PreviewLinkPlanner.plan(
            markdown: "[top](source.md#top)",
            target: "source.md#top",
            documentURL: sourceURL
        )
        XCTAssertEqual(sameDocument.destination, .currentDocument(fragment: "top"))

        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[missing](missing.pdf)",
                target: "missing.pdf",
                documentURL: sourceURL
            )),
            .missingLocalTarget
        )

        let attachmentURL = directory.appendingPathComponent("archive.zip")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: attachmentURL)
        let attachmentPlan = PreviewLinkPlanner.plan(
            markdown: "[archive](archive.zip)",
            target: "archive.zip",
            documentURL: sourceURL
        )
        guard case let .local(attachment) = attachmentPlan.destination else {
            return XCTFail("expected a local attachment")
        }
        XCTAssertEqual(attachment.kind, .attachment)

        let fakePDF = directory.appendingPathComponent("fake.pdf")
        try Data("not pdf".utf8).write(to: fakePDF)
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[fake](fake.pdf)",
                target: "fake.pdf",
                documentURL: sourceURL
            )),
            .unsafeLocalTarget
        )
    }

    func testLinkPlannerValidatesImageContentAndNeverFollowsSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.md")
        let imageURL = directory.appendingPathComponent("cover.png")
        try pngData().write(to: imageURL)

        let imageMarkdown = "[cover](cover.png)"
        let imagePlan = PreviewLinkPlanner.plan(
            markdown: imageMarkdown,
            target: "cover.png",
            documentURL: sourceURL
        )
        guard case let .local(image) = imagePlan.destination else {
            return XCTFail("expected a validated local image")
        }
        XCTAssertEqual(image.kind, .image)

        let fakeURL = directory.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: fakeURL)
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[fake](fake.png)",
                target: "fake.png",
                documentURL: sourceURL
            )),
            .unsafeLocalTarget
        )

        let aliasURL = directory.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: imageURL)
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[alias](alias.md)",
                target: "alias.md",
                documentURL: sourceURL
            )),
            .unsafeLocalTarget
        )
    }

    @MainActor
    func testDocumentNavigationBrokerScopesRoutesAndConsumesPendingOnce() {
        let broker = PreviewDocumentNavigationBroker()
        let firstURL = URL(fileURLWithPath: "/tmp/inflow-first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/inflow-second.md")
        let firstID = UUID()
        var firstFragments: [String?] = []
        var secondFragments: [String?] = []
        broker.register(id: firstID, url: firstURL) { firstFragments.append($0) }

        XCTAssertTrue(broker.routeIfOpen(to: firstURL, fragment: "one"))
        XCTAssertFalse(broker.routeIfOpen(to: secondURL, fragment: "two"))
        XCTAssertEqual(firstFragments.count, 1)
        XCTAssertEqual(firstFragments[0], "one")

        _ = broker.enqueue(url: secondURL, fragment: "queued")
        let secondID = UUID()
        broker.register(id: secondID, url: secondURL) { secondFragments.append($0) }
        broker.register(id: secondID, url: secondURL) { secondFragments.append($0) }
        XCTAssertEqual(secondFragments.count, 1)
        XCTAssertEqual(secondFragments[0], "queued")

        let cancelledURL = URL(fileURLWithPath: "/tmp/inflow-cancelled.md")
        let superseded = broker.enqueue(url: cancelledURL, fragment: "old")
        let current = broker.enqueue(url: cancelledURL, fragment: "new")
        XCTAssertNotEqual(superseded, current)
        broker.cancelPending(url: cancelledURL, token: superseded)
        var cancelledFragments: [String?] = []
        let cancelledID = UUID()
        broker.register(id: cancelledID, url: cancelledURL) {
            cancelledFragments.append($0)
        }
        XCTAssertEqual(cancelledFragments.count, 1)
        XCTAssertEqual(cancelledFragments[0], "new")

        let removedURL = URL(fileURLWithPath: "/tmp/inflow-removed.md")
        let removed = broker.enqueue(url: removedURL, fragment: "removed")
        broker.cancelPending(url: removedURL, token: removed)
        let removedID = UUID()
        broker.register(id: removedID, url: removedURL) { _ in
            XCTFail("cancelled navigation must not be delivered")
        }

        broker.unregister(id: firstID)
        broker.unregister(id: secondID)
        broker.unregister(id: cancelledID)
        broker.unregister(id: removedID)
        XCTAssertFalse(broker.routeIfOpen(to: firstURL, fragment: nil))
    }

    @MainActor
    func testSourceEditorPublishesNormalizedScrollFraction() {
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1_000))
        session.scrollView.documentView = documentView
        session.scrollView.layoutSubtreeIfNeeded()
        session.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 400))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: session.scrollView.contentView
        )

        XCTAssertEqual(session.verticalScrollFraction, 0.5, accuracy: 0.01)
    }

    @MainActor
    func testAppScrollWorksWhilePageContentJavaScriptIsDisabled() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300),
            configuration: configuration
        )
        let loaded = expectation(description: "preview loaded")
        let delegate = PreviewTestLoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<html><body style=\"height: 5000px\">Long preview</body></html>",
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 5)

        let coordinator = MarkdownPreviewView.Coordinator()
        coordinator.update(
            scrollRequest: PreviewScrollRequest(generation: 7, fraction: 0.75),
            onHeadingActivated: { _ in },
            onLinkActivated: { _ in },
            onPreviewIssueAction: { _, _ in },
            onManualScroll: {},
            webView: webView
        )
        coordinator.webView(webView, didFinish: nil)

        for _ in 0..<50 {
            let value = try await webView.evaluateJavaScript("window.scrollY")
            if let y = value as? Double, y > 1_000 {
                XCTAssertLessThan(y, 5_000)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("isolated app script did not scroll the preview")
    }

    @MainActor
    func testMountedPreviewReportsExactLinkWhilePageScriptsRemainDisabled() async throws {
        let received = expectation(description: "link reported")
        var receivedTarget: String?
        let markdown = "[打开](<https://example.com/a b?x=1&y=2>)"
        let root = MarkdownPreviewView(
            html: MarkdownRenderer.htmlDocument(for: markdown),
            baseURL: nil,
            onLinkActivated: { target in
                receivedTarget = target
                received.fulfill()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var webView: WKWebView?
        var linkIsReady = false
        for _ in 0..<100 {
            webView = descendants(of: hosting).compactMap { $0 as? WKWebView }.first
            if let candidate = webView,
               candidate.isLoading == false,
               let isReady = try? await candidate.callAsyncJavaScript(
                   "return document.querySelector('a[data-inflow-link-target-hex]') !== null;",
                   arguments: [:],
                   in: nil,
                   contentWorld: .defaultClient
               ) as? Bool,
               isReady
            {
                linkIsReady = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let mounted = try XCTUnwrap(webView)
        XCTAssertTrue(linkIsReady)
        XCTAssertFalse(mounted.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        _ = try await mounted.callAsyncJavaScript(
            "document.querySelector('a').click(); return true;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(receivedTarget, "https://example.com/a b?x=1&y=2")
    }

    @MainActor
    func testMountedMermaidFailureRoutesOnlyClosedRecoveryActions() async throws {
        let received = expectation(description: "preview issue actions reported")
        received.expectedFulfillmentCount = 2
        var actions: [(PreviewIssueAction, Int)] = []
        let markdown = "前文\n\n```mermaid\npie\ntitle Values\n```"
        let marker = try XCTUnwrap(markdown.range(of: "```mermaid"))
        let markerStart = try XCTUnwrap(marker.lowerBound.samePosition(in: markdown.utf8))
        let expectedOffset = markdown.utf8.distance(
            from: markdown.utf8.startIndex,
            to: markerStart
        )
        let root = MarkdownPreviewView(
            html: MarkdownRenderer.htmlDocument(for: markdown),
            baseURL: nil,
            onPreviewIssueAction: { action, offset in
                actions.append((action, offset))
                received.fulfill()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var webView: WKWebView?
        var actionsAreReady = false
        for _ in 0..<100 {
            webView = descendants(of: hosting).compactMap { $0 as? WKWebView }.first
            if let candidate = webView,
               candidate.isLoading == false,
               let isReady = try? await candidate.callAsyncJavaScript(
                   "return document.querySelectorAll('[data-inflow-preview-error-action]').length === 2;",
                   arguments: [:],
                   in: nil,
                   contentWorld: .defaultClient
               ) as? Bool,
               isReady
            {
                actionsAreReady = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let mounted = try XCTUnwrap(webView)
        XCTAssertTrue(actionsAreReady)
        XCTAssertFalse(mounted.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        for action in ["locate", "retry"] {
            _ = try await mounted.callAsyncJavaScript(
                "document.querySelector(`[data-inflow-preview-error-action='${action}']`).click(); return true;",
                arguments: ["action": action],
                in: nil,
                contentWorld: .defaultClient
            )
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(actions.map(\.0), [.locate, .retry])
        XCTAssertEqual(actions.map(\.1), [expectedOffset, expectedOffset])
    }

    @MainActor
    func testMountedRemoteImageRoutesExactRecoveryActionsWithoutPageScripts() async throws {
        let received = expectation(description: "image issue actions reported")
        received.expectedFulfillmentCount = 3
        let target = "https://private.example/图.png?token=secret"
        var actions: [(PreviewImageIssueAction, Int, String)] = []
        let root = MarkdownPreviewView(
            html: MarkdownRenderer.htmlDocument(for: "![图](\(target))"),
            baseURL: nil,
            onImageIssueAction: { action, offset, reportedTarget in
                actions.append((action, offset, reportedTarget))
                received.fulfill()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var webView: WKWebView?
        var actionsAreReady = false
        for _ in 0..<100 {
            webView = descendants(of: hosting).compactMap { $0 as? WKWebView }.first
            if let candidate = webView,
               candidate.isLoading == false,
               let isReady = try? await candidate.callAsyncJavaScript(
                   "return document.querySelectorAll('[data-inflow-image-action]').length === 3;",
                   arguments: [:],
                   in: nil,
                   contentWorld: .defaultClient
               ) as? Bool,
               isReady
            {
                actionsAreReady = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let mounted = try XCTUnwrap(webView)
        XCTAssertTrue(actionsAreReady)
        XCTAssertFalse(mounted.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        for action in ["locate", "copyTarget", "ignore"] {
            _ = try await mounted.callAsyncJavaScript(
                "document.querySelector(`[data-inflow-image-action='${action}']`).click(); return true;",
                arguments: ["action": action],
                in: nil,
                contentWorld: .defaultClient
            )
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(actions.map(\.0), [.locate, .copyTarget, .ignore])
        XCTAssertEqual(actions.map(\.1), [0, 0, 0])
        XCTAssertEqual(actions.map(\.2), [target, target, target])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-image-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData() throws -> Data {
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
        pixels[0] = 32
        pixels[1] = 96
        pixels[2] = 220
        pixels[3] = 255
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func blockedReason(_ plan: PreviewLinkPlan) -> PreviewLinkFailureReason? {
        guard case let .blocked(failure) = plan.destination else { return nil }
        return failure.reason
    }

    private func hex(_ value: String) -> String {
        Data(value.utf8).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class PreviewTestLoadDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        onFinish()
    }
}
