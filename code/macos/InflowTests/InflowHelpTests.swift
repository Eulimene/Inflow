import AppKit
import XCTest
@testable import Inflow

final class InflowHelpTests: XCTestCase {
    @MainActor
    func testTestRunnerAutomaticallyUsesTheHostApplicationIcon() throws {
        // Do not invoke the bootstrap here: this verifies XCTest's real startup
        // hook, including direct runs where Bundle.main belongs to xctest.
        let testBundle = Bundle(for: InflowTestBootstrap.self)
        XCTAssertEqual(testBundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String,
                       NSStringFromClass(InflowTestBootstrap.self))
        let host = try XCTUnwrap(InflowTestBootstrap.hostApplicationBundle)
        let iconURL = try XCTUnwrap(host.url(forResource: "AppIcon", withExtension: "icns"))
        let expected = try iconPixels(XCTUnwrap(NSImage(contentsOf: iconURL)))
        let actual = try iconPixels(XCTUnwrap(NSApplication.shared.applicationIconImage))
        // AppKit may rasterize the Dock icon at a different resolution and
        // color profile. Compare normalized pixels, allowing small color shifts.
        let meanDifference = zip(actual, expected).reduce(0.0) {
            $0 + Double(abs(Int($1.0) - Int($1.1)))
        } / Double(expected.count)
        XCTAssertLessThan(meanDifference, 10, "The test process must display the Inflow artwork")
    }

    @MainActor
    private func iconPixels(_ image: NSImage) throws -> [UInt8] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero,
                   operation: .copy, fraction: 1)
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        return Array(UnsafeBufferPointer(start: pixels, count: 64 * 256))
    }

    func testBundledHelpCoversTheOfflineCoreWorkflow() {
        let sections = InflowHelpContent.sections
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertEqual(
            sections.map(\.title),
            ["开始写作", "保存与文件安全", "结构、查找与本地资源", "离线预览与交付", "恢复与隐私"]
        )

        let text = sections.flatMap(\.paragraphs).joined(separator: "\n")
        for requiredTerm in [
            "⌘N", "⌘O", "⌘S", "⌘1", "⌘2", "⌘3", "⌘F",
            "打开项目", "新建 Markdown", "另存为", "不自动保存", "导出 PDF",
            "禁止页面脚本", "不收集或上传", "导出日志",
        ] {
            XCTAssertTrue(text.contains(requiredTerm), "Missing help topic: \(requiredTerm)")
        }
        XCTAssertFalse(text.contains("http://"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("打开文件夹"))
        XCTAssertFalse(text.contains("匿名产品使用数据"))
        XCTAssertTrue(text.contains("项目树"))
        XCTAssertTrue(text.contains("手动保存前"))
        XCTAssertFalse(text.contains("会在写入前停止"))
        XCTAssertFalse(text.contains("自动保存已暂停"))
    }

    @MainActor
    func testHelpMenuHasOneAlwaysEnabledOfflineEntry() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let helpMenu = try XCTUnwrap(mainMenu.item(withTitle: "帮助")?.submenu)
        let items = allMenuItems(in: helpMenu)
            .filter { $0.title == "Inflow 帮助" && $0.submenu == nil }

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(try XCTUnwrap(items.first).isEnabled)
        XCTAssertTrue(try XCTUnwrap(items.first).keyEquivalent.isEmpty)

        // A hand-built replacement Window submenu used to discard this scene
        // command. Check the real application menu after deferred launch work,
        // rather than inserting fake Center/Fill items into a test-only menu.
        let windowMenu = try XCTUnwrap(NSApp.windowsMenu)
        XCTAssertEqual(mainMenu.items.filter { $0.submenu === windowMenu }.count, 1)
        XCTAssertEqual(windowMenu.items.filter { $0.title == "Inflow 帮助" }.count, 1)
        for action in [#selector(NSWindow.performMiniaturize(_:)),
                       #selector(NSWindow.performZoom(_:)),
                       #selector(NSApplication.arrangeInFront(_:))] {
            XCTAssertEqual(windowMenu.items.filter { $0.action == action }.count, 1)
        }

        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        XCTAssertEqual(
            appMenu.items.filter { $0.title == "检查更新…" && $0.submenu == nil }.count,
            0
        )
        XCTAssertEqual(
            appMenu.items.filter {
                $0.title == "关于 Inflow（开发预览）" && $0.submenu == nil
            }.count,
            0
        )
    }

    func testReleaseProfileNeverInfersSignedStatusFromTheMachine() {
        XCTAssertEqual(InflowReleaseProfile.statusName(rawValue: nil), "开发预览")
        XCTAssertEqual(InflowReleaseProfile.statusName(rawValue: "development-preview"), "开发预览")
        XCTAssertEqual(InflowReleaseProfile.statusName(rawValue: "unknown"), "开发预览")
        XCTAssertEqual(
            InflowReleaseProfile.statusName(rawValue: "signed-preview"),
            "免费签名开发预览"
        )
    }

    func testManualUpdateURLRequiresAClosedHTTPSDestination() {
        XCTAssertEqual(
            ManualUpdateCheck.validatedURL(from: "https://updates.example.test/inflow"),
            URL(string: "https://updates.example.test/inflow")
        )
        for rejected in [
            nil,
            "",
            "http://updates.example.test/inflow",
            "https://user@updates.example.test/inflow",
            "https://updates.example.test:443/inflow",
            "https://updates.example.test:8443/inflow",
            "https://updates.example.test/inflow?channel=preview",
            "https://updates.example.test/inflow#fragment",
            "file:///tmp/update",
        ] {
            XCTAssertNil(ManualUpdateCheck.validatedURL(from: rejected))
        }
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
