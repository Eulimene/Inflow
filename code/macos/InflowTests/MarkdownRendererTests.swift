import AppKit
import WebKit
import XCTest
@testable import Inflow

final class MarkdownRendererTests: XCTestCase {
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
            "type": "unknown",
            "document": "must not cross bridge",
        ]))
    }

    @MainActor
    func testPreviewCoordinatorRoutesHeadingAndManualScrollWithoutDocumentContent() {
        let coordinator = MarkdownPreviewView.Coordinator()
        let webView = WKWebView()
        var selectedOffset: Int?
        var manualScrollCount = 0
        coordinator.update(
            scrollRequest: PreviewScrollRequest(generation: 1, fraction: 0.5),
            onHeadingActivated: { selectedOffset = $0 },
            onManualScroll: { manualScrollCount += 1 },
            webView: webView
        )

        coordinator.handle(.heading(sourceUTF8Offset: 128))
        coordinator.handle(.manualScroll)

        XCTAssertEqual(selectedOffset, 128)
        XCTAssertEqual(manualScrollCount, 1)
    }

    @MainActor
    func testSourceEditorPublishesNormalizedScrollFraction() {
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        session.textView.frame = NSRect(x: 0, y: 0, width: 320, height: 1_000)
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
