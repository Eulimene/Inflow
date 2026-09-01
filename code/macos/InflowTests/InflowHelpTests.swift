import AppKit
import XCTest
@testable import Inflow

final class InflowHelpTests: XCTestCase {
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

        let appMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        XCTAssertEqual(
            appMenu.items.filter { $0.title == "检查更新…" && $0.submenu == nil }.count,
            1
        )
        XCTAssertEqual(
            appMenu.items.filter {
                $0.title == "关于 Inflow（开发预览）" && $0.submenu == nil
            }.count,
            1
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
