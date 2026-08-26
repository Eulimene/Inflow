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
            "另存为", "保存副本", "恢复中心", "导出 HTML", "导出 PDF",
            "禁止页面脚本", "完全离线", "默认关闭",
        ] {
            XCTAssertTrue(text.contains(requiredTerm), "Missing help topic: \(requiredTerm)")
        }
        XCTAssertFalse(text.contains("http://"))
        XCTAssertFalse(text.contains("https://"))
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
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
