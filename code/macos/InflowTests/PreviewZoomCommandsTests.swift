import AppKit
import XCTest
@testable import Inflow

final class PreviewZoomCommandsTests: XCTestCase {
    @MainActor
    func testZoomActionsUseStableStepsClampAndReset() {
        var value = 1.0
        var actions = PreviewZoomCommandActions(zoom: value) { value = $0 }
        actions.zoomIn()
        XCTAssertEqual(value, 1.1, accuracy: 0.000_1)

        actions = PreviewZoomCommandActions(zoom: value) { value = $0 }
        actions.zoomOut()
        XCTAssertEqual(value, 1.0, accuracy: 0.000_1)

        actions = PreviewZoomCommandActions(zoom: 1.96) { value = $0 }
        actions.zoomIn()
        XCTAssertEqual(value, 2.0, accuracy: 0.000_1)

        actions = PreviewZoomCommandActions(zoom: 0.53) { value = $0 }
        actions.zoomOut()
        XCTAssertEqual(value, 0.5, accuracy: 0.000_1)

        actions = PreviewZoomCommandActions(zoom: 1.7) { value = $0 }
        actions.reset()
        XCTAssertEqual(value, 1.0, accuracy: 0.000_1)
    }

    @MainActor
    func testZoomActionsExposeBoundaryAvailability() {
        let lower = PreviewZoomCommandActions(zoom: 0.5) { _ in }
        XCTAssertFalse(lower.canZoomOut)
        XCTAssertTrue(lower.canZoomIn)

        let upper = PreviewZoomCommandActions(zoom: 2.0) { _ in }
        XCTAssertTrue(upper.canZoomOut)
        XCTAssertFalse(upper.canZoomIn)
    }

    @MainActor
    func testAppMenuExposesLaunchZoomShortcutsExactlyOnce() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        let expected: [(String, String)] = [
            ("放大", "+"),
            ("缩小", "-"),
            ("实际大小", "0"),
        ]
        for (title, key) in expected {
            let matching = items.filter { $0.title == title }
            XCTAssertEqual(matching.count, 1)
            let item = try XCTUnwrap(matching.first)
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(
                item.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
                .command
            )
        }
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
