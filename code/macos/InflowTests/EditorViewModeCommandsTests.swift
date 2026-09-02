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

        var uninitializedFraction = EditorSplitSceneState.uninitialized
        let firstFrameRoot = PersistentHorizontalSplitView(
            fraction: Binding(
                get: {
                    EditorSplitSceneState.effectiveFraction(
                        storedValue: uninitializedFraction,
                        defaultValue: 0.65
                    )
                },
                set: { uninitializedFraction = EditorSplitLayout.normalized($0) }
            )
        ) {
            Text("First-frame source")
        } trailing: {
            Text("First-frame preview")
        }
        let firstFrameHost = NSHostingView(rootView: firstFrameRoot)
        firstFrameHost.frame = NSRect(x: 0, y: 0, width: 1_002, height: 500)
        firstFrameHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let firstFrameSplit = try XCTUnwrap(
            descendants(of: firstFrameHost).compactMap { $0 as? NSSplitView }.first
        )
        let firstFrameAvailableWidth =
            firstFrameSplit.bounds.width - firstFrameSplit.dividerThickness
        XCTAssertEqual(
            firstFrameSplit.subviews[0].frame.width / firstFrameAvailableWidth,
            0.65,
            accuracy: 0.01,
            "the configured default must be effective before onAppear persists the scene value"
        )
        XCTAssertEqual(
            uninitializedFraction,
            EditorSplitSceneState.uninitialized,
            "synthetic bootstrap resizes must not overwrite SceneStorage"
        )
    }

    @MainActor
    func testDocumentContextDefaultsAndSceneNavigationStateRemainScoped() {
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
            EditorViewMode.initialMode(storedValue: "", context: .untitled),
            .source
        )
        XCTAssertEqual(
            EditorViewMode.initialMode(storedValue: "", context: .existingDocument),
            .split
        )
        XCTAssertEqual(
            EditorViewMode.initialMode(storedValue: "", context: .recoverySnapshot),
            .source
        )
        XCTAssertEqual(
            EditorViewMode.initialMode(
                storedValue: EditorViewMode.preview.rawValue,
                context: .existingDocument
            ),
            .preview,
            "a valid value restored for the same scene remains authoritative"
        )
        XCTAssertEqual(
            EditorViewMode.initialMode(storedValue: "retired-mode", context: .untitled),
            .source,
            "an invalid nonempty scene value is frozen to the document-context default"
        )

        XCTAssertFalse(
            EditorNavigationVisibilityState.resolve(
                storedValue: "",
                defaultValue: false
            )
        )
        XCTAssertTrue(
            EditorNavigationVisibilityState.resolve(
                storedValue: "",
                defaultValue: true
            )
        )
        XCTAssertTrue(
            EditorNavigationVisibilityState.resolve(
                storedValue: EditorNavigationVisibilityState.storedValue(isVisible: true),
                defaultValue: false
            )
        )
        XCTAssertFalse(
            EditorNavigationVisibilityState.resolve(
                storedValue: EditorNavigationVisibilityState.storedValue(isVisible: false),
                defaultValue: true
            )
        )

        let normalizedInvalidVisibility =
            EditorNavigationVisibilityState.normalizedStoredValue(
                "retired-visibility",
                defaultValue: false
            )
        XCTAssertFalse(
            EditorNavigationVisibilityState.resolve(
                storedValue: normalizedInvalidVisibility,
                defaultValue: true
            ),
            "normalization must keep an existing scene independent of later preference changes"
        )

        let projectState = ProjectEditorNavigationState()
        let projectA = FolderProjectDirectoryIdentity(
            resolvedURL: URL(fileURLWithPath: "/tmp/project-a"),
            device: 1,
            inode: 10,
            generation: 1
        )
        let projectB = FolderProjectDirectoryIdentity(
            resolvedURL: URL(fileURLWithPath: "/tmp/project-b"),
            device: 1,
            inode: 11,
            generation: 1
        )
        XCTAssertEqual(
            projectState.resolve(
                projectIdentity: projectA,
                defaultProjectSidebarVisible: false,
                defaultOutlineVisible: true
            ),
            EditorNavigationVisibilitySnapshot(
                projectSidebarVisible: false,
                outlineVisible: true
            )
        )
        let editorSession = MarkdownSourceEditorSession()
        editorSession.textView.string = "project draft"
        editorSession.textView.setSelectedRange(NSRange(location: 7, length: 5))
        editorSession.textView.insertText(
            "note",
            replacementRange: editorSession.textView.selectedRange()
        )
        let textBeforeNavigationToggle = editorSession.textView.string
        let selectionBeforeNavigationToggle = editorSession.textView.selectedRange()
        let undoBeforeNavigationToggle = editorSession.textView.undoManager?.canUndo
        projectState.setProjectSidebarVisible(true)
        projectState.setOutlineVisible(false)
        XCTAssertEqual(
            projectState.resolve(
                projectIdentity: projectA,
                defaultProjectSidebarVisible: true,
                defaultOutlineVisible: false
            ),
            EditorNavigationVisibilitySnapshot(
                projectSidebarVisible: true,
                outlineVisible: false
            ),
            "a replacement project document must inherit its window's navigation state"
        )
        XCTAssertEqual(
            projectState.resolve(
                projectIdentity: projectB,
                defaultProjectSidebarVisible: true,
                defaultOutlineVisible: false
            ),
            EditorNavigationVisibilitySnapshot(
                projectSidebarVisible: true,
                outlineVisible: false
            ),
            "a different project starts from current defaults instead of project A or blank-scene storage"
        )
        projectState.setProjectSidebarVisible(false)
        projectState.setOutlineVisible(true)
        projectState.reset()
        XCTAssertEqual(
            projectState.resolve(
                projectIdentity: projectB,
                defaultProjectSidebarVisible: true,
                defaultOutlineVisible: false
            ),
            EditorNavigationVisibilitySnapshot(
                projectSidebarVisible: true,
                outlineVisible: false
            ),
            "closing and reopening the same directory starts a fresh project-window session"
        )
        XCTAssertTrue(
            UTF8Text.isExactlyEqual(
                editorSession.textView.string,
                textBeforeNavigationToggle
            )
        )
        XCTAssertEqual(
            editorSession.textView.selectedRange(),
            selectionBeforeNavigationToggle
        )
        XCTAssertEqual(editorSession.textView.undoManager?.canUndo, undoBeforeNavigationToggle)

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
