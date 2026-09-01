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

    func testSplitFractionDefaultsAndClampsToLaunchRange() {
        XCTAssertEqual(EditorSplitLayout.defaultFraction, 0.5)
        XCTAssertEqual(EditorSplitLayout.normalized(0.1), 0.25)
        XCTAssertEqual(EditorSplitLayout.normalized(0.6), 0.6)
        XCTAssertEqual(EditorSplitLayout.normalized(0.9), 0.75)
        XCTAssertEqual(EditorSplitLayout.normalized(.nan), 0.5)

        XCTAssertEqual(
            EditorSplitLayout.position(for: 0.5, totalWidth: 802, dividerThickness: 2),
            400
        )
        XCTAssertEqual(
            EditorSplitLayout.fraction(for: 200, totalWidth: 802, dividerThickness: 2),
            0.25
        )
    }

    func testEmptyMarkdownGuidanceExplainsOwnershipAndNextSteps() {
        XCTAssertTrue(EmptyMarkdownGuidance.isVisible(markdown: ""))
        XCTAssertFalse(EmptyMarkdownGuidance.isVisible(markdown: "\n"))
        XCTAssertTrue(EmptyMarkdownGuidance.title.contains("属于你"))
        XCTAssertTrue(EmptyMarkdownGuidance.description.contains("源码编辑器"))
        XCTAssertTrue(EmptyMarkdownGuidance.description.contains("顶部“文件”菜单"))
        XCTAssertTrue(EmptyMarkdownGuidance.description.contains("选择文件名和位置"))
        XCTAssertTrue(EmptyMarkdownGuidance.description.contains("不会把内容导入专有格式"))
        XCTAssertTrue(EmptyMarkdownGuidance.description.contains("文件夹项目"))
    }

    @MainActor
    func testHostedSplitRestoresFractionAndConstrainsDivider() throws {
        var storedFraction = 0.6
        let root = PersistentHorizontalSplitView(
            fraction: Binding(
                get: { storedFraction },
                set: { storedFraction = $0 }
            )
        ) {
            Text("Source")
        } trailing: {
            Text("Preview")
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_002, height: 500)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let splitView = try XCTUnwrap(
            descendants(of: hostingView).compactMap { $0 as? NSSplitView }.first
        )
        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        XCTAssertEqual(splitView.subviews[0].frame.width / availableWidth, 0.6, accuracy: 0.01)

        splitView.setPosition(0, ofDividerAt: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(splitView.subviews[0].frame.width / availableWidth, 0.25, accuracy: 0.01)
        XCTAssertEqual(storedFraction, 0.25, accuracy: 0.01)

        splitView.setPosition(splitView.bounds.width, ofDividerAt: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(splitView.subviews[0].frame.width / availableWidth, 0.75, accuracy: 0.01)
        XCTAssertEqual(storedFraction, 0.75, accuracy: 0.01)

        hostingView.frame.size.width = 1_202
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let resizedAvailableWidth = splitView.bounds.width - splitView.dividerThickness
        XCTAssertEqual(
            splitView.subviews[0].frame.width / resizedAvailableWidth,
            0.75,
            accuracy: 0.01
        )
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

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
