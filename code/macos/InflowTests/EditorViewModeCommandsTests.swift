import AppKit
import SwiftUI
import XCTest
@testable import Inflow

final class EditorViewModeCommandsTests: XCTestCase {
    func testWorkspaceViewModePreferenceMapsEveryExplicitMode() {
        XCTAssertEqual(WorkspaceViewModePreference(mode: .source), .source)
        XCTAssertEqual(WorkspaceViewModePreference(mode: .split), .split)
        XCTAssertEqual(WorkspaceViewModePreference(mode: .preview), .preview)
        XCTAssertNil(WorkspaceViewModePreference(rawValue: "removed-mode"))
        XCTAssertEqual(EditorViewMode.preview.label, "即时渲染编辑")
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
    func testHostedSplitsRestorePersistedGeometryAndConstrainDividers() throws {
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

        var storedLeadingWidth = 264.0
        let edgeRoot = PersistentEdgeSplitView(
            edge: .leading,
            width: Binding(
                get: { storedLeadingWidth },
                set: { storedLeadingWidth = $0 }
            ),
            allowedWidth: 200 ... 300,
            accessibilityLabel: "Test edge split"
        ) {
            Text("Sidebar")
        } trailing: {
            Text("Workspace")
        }
        let edgeHost = NSHostingView(rootView: edgeRoot)
        edgeHost.frame = NSRect(x: 0, y: 0, width: 1_002, height: 500)
        edgeHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let edgeSplit = try XCTUnwrap(
            descendants(of: edgeHost).compactMap { $0 as? NSSplitView }.first
        )
        XCTAssertEqual(edgeSplit.subviews[0].frame.width, 264, accuracy: 1)
        edgeSplit.setPosition(900, ofDividerAt: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(edgeSplit.subviews[0].frame.width, 300, accuracy: 1)
        XCTAssertEqual(storedLeadingWidth, 300, accuracy: 1)

        var storedTrailingWidth = 236.0
        let trailingRoot = PersistentEdgeSplitView(
            edge: .trailing,
            width: Binding(
                get: { storedTrailingWidth },
                set: { storedTrailingWidth = $0 }
            ),
            allowedWidth: 200 ... 288,
            accessibilityLabel: "Test trailing split"
        ) {
            Text("Workspace")
        } trailing: {
            Text("Outline")
        }
        let trailingHost = NSHostingView(rootView: trailingRoot)
        trailingHost.frame = NSRect(x: 0, y: 0, width: 1_002, height: 500)
        trailingHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let trailingSplit = try XCTUnwrap(
            descendants(of: trailingHost).compactMap { $0 as? NSSplitView }.first
        )
        XCTAssertEqual(
            trailingSplit.subviews[1].frame.width,
            236,
            accuracy: 1
        )
        trailingSplit.setPosition(0, ofDividerAt: 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(trailingSplit.subviews[1].frame.width, 288, accuracy: 1)
        XCTAssertEqual(storedTrailingWidth, 288, accuracy: 1)
    }

    @MainActor
    func testDocumentContextDefaultsAndWorkspacePreferencesRemainGlobal() {
        XCTAssertEqual(
            EditorViewModeLaunchContext.resolve(
                fileURL: nil,
                hasRestorationState: false
            ),
            .untitled
        )
        XCTAssertEqual(
            EditorViewModeLaunchContext.resolve(
                fileURL: URL(fileURLWithPath: "/tmp/existing.md"),
                hasRestorationState: false
            ),
            .existingDocument
        )
        XCTAssertEqual(
            EditorViewModeLaunchContext.resolve(
                fileURL: URL(fileURLWithPath: "/tmp/recovered.md"),
                hasRestorationState: true
            ),
            .recoverySnapshot
        )
        XCTAssertEqual(
            WorkspaceViewModePreference.automatic.resolve(context: .untitled),
            .source
        )
        XCTAssertEqual(
            WorkspaceViewModePreference.automatic.resolve(context: .existingDocument),
            .split
        )
        XCTAssertEqual(
            WorkspaceViewModePreference.preview.resolve(context: .untitled),
            .preview,
            "an explicit user preference remains authoritative across document contexts"
        )
        XCTAssertEqual(
            WorkspaceViewModePreference(mode: .source),
            .source
        )

        XCTAssertEqual(
            EditorWorkspaceLayout.panes(
                hasProjectContext: true,
                projectSidebarVisible: true,
                outlineAvailable: true,
                outlineVisible: true
            ),
            [.projectSidebar, .editor, .outline]
        )
        XCTAssertEqual(
            EditorWorkspaceLayout.panes(
                hasProjectContext: true,
                projectSidebarVisible: false,
                outlineAvailable: true,
                outlineVisible: true
            ),
            [.editor, .outline]
        )
        XCTAssertEqual(
            EditorWorkspaceLayout.panes(
                hasProjectContext: true,
                projectSidebarVisible: true,
                outlineAvailable: true,
                outlineVisible: false
            ),
            [.projectSidebar, .editor]
        )
        XCTAssertEqual(
            EditorWorkspaceLayout.panes(
                hasProjectContext: true,
                projectSidebarVisible: true,
                outlineAvailable: false,
                outlineVisible: true
            ),
            [.projectSidebar, .editor],
            "a project shell cannot accidentally expose an outline action"
        )

        XCTAssertEqual(EditorWorkspaceMetrics.defaultWindowWidth, 1_200)
        XCTAssertEqual(EditorWorkspaceMetrics.defaultWindowHeight, 760)
        XCTAssertLessThan(
            EditorWorkspaceMetrics.projectSidebarMaximumWidth,
            EditorWorkspaceMetrics.editorMinimumWidth
        )
        XCTAssertLessThan(
            EditorWorkspaceMetrics.outlineMaximumWidth,
            EditorWorkspaceMetrics.editorMinimumWidth
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

        let directoryTreeItems = items.filter { $0.title == "显示目录树" }
        XCTAssertEqual(directoryTreeItems.count, 1)
        XCTAssertEqual(directoryTreeItems.first?.keyEquivalent, "")
        let outlineItems = items.filter {
            $0.title == "显示大纲" || $0.title == "隐藏大纲"
        }
        XCTAssertEqual(outlineItems.count, 1)
        XCTAssertEqual(outlineItems.first?.keyEquivalent, "")
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
