import AppKit
import SwiftUI
import XCTest
@testable import Inflow

final class EditorViewModeCommandsTests: XCTestCase {
    func testStoredViewModeFallsBackToSplitForUnknownValue() {
        XCTAssertEqual(EditorViewMode.resolve(storedValue: EditorViewMode.source.rawValue), .source)
        XCTAssertEqual(EditorViewMode.resolve(storedValue: EditorViewMode.preview.rawValue), .preview)
        XCTAssertEqual(EditorViewMode.resolve(storedValue: "removed-mode"), .split)
    }

    func testNewSceneUsesLastActiveModeWhileRestoredSceneKeepsItsOwnMode() {
        XCTAssertEqual(
            EditorViewMode.initialMode(storedValue: "", lastActiveMode: .preview),
            .preview
        )
        XCTAssertEqual(
            EditorViewMode.initialMode(
                storedValue: EditorViewMode.source.rawValue,
                lastActiveMode: .preview
            ),
            .source
        )
        XCTAssertEqual(
            EditorViewMode.initialMode(storedValue: "retired-mode", lastActiveMode: .preview),
            .split
        )
    }

    @MainActor
    func testCommandActionsAreScopedAndOnlySelectOnActivation() {
        var firstMode = EditorViewMode.source
        var secondMode = EditorViewMode.preview
        var firstSelections: [EditorViewMode] = []

        let first = EditorViewModeCommandActions(
            selectedMode: firstMode,
            select: {
                firstMode = $0
                firstSelections.append($0)
            }
        )
        let second = EditorViewModeCommandActions(
            selectedMode: secondMode,
            select: { secondMode = $0 }
        )

        XCTAssertTrue(first.selectionBinding(for: .source).wrappedValue)
        XCTAssertFalse(first.selectionBinding(for: .split).wrappedValue)
        first.selectionBinding(for: .split).wrappedValue = false
        XCTAssertTrue(firstSelections.isEmpty)

        first.selectionBinding(for: .split).wrappedValue = true
        XCTAssertEqual(firstMode, .split)
        XCTAssertEqual(firstSelections, [.split])
        XCTAssertEqual(secondMode, .preview)

        second.selectionBinding(for: .source).wrappedValue = true
        XCTAssertEqual(secondMode, .source)
        XCTAssertEqual(firstMode, .split)
    }

    @MainActor
    func testAppMenuExposesOneCommandForEachViewShortcut() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        let expectations: [(String, String)] = [
            (EditorViewMode.source.label, "1"),
            (EditorViewMode.split.label, "2"),
            (EditorViewMode.preview.label, "3"),
        ]

        for (title, key) in expectations {
            let matching = items.filter { $0.title == title }
            XCTAssertEqual(matching.count, 1, "Expected one menu item titled \(title)")
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
