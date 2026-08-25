import AppKit
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
