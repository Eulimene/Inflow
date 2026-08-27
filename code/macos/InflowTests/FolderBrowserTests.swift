import AppKit
import SwiftUI
import XCTest
@testable import Inflow

@MainActor
final class FolderBrowserTests: XCTestCase {
    func testLaunchPolicyPresentsTheApplicationBeforeAnyDocumentPicker() {
        XCTAssertTrue(InflowLaunchPolicy.presentsApplicationWindowFirst)
        XCTAssertFalse(InflowLaunchPolicy.automaticallyOpensUntitledDocument)
        XCTAssertTrue(InflowLaunchPolicy.isRunningUnderXCTest)
        let delegate = InflowApplicationDelegate()
        XCTAssertTrue(delegate.applicationShouldOpenUntitledFile(NSApp))
        XCTAssertFalse(NSApp.windows.contains { $0.title == InflowMainWindow.title })
    }

    func testScannerRecursivelyListsOnlyVisibleMarkdownFilesInStableOrder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Guide", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("# B".utf8).write(to: nested.appendingPathComponent("Beta.markdown"))
        try Data("# A".utf8).write(to: root.appendingPathComponent("Alpha.MD"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: hidden.appendingPathComponent("secret.md"))

        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.md"),
            withDestinationURL: outside.appendingPathComponent("outside.md")
        )

        let files = try FolderContentScanner.scan(root)

        XCTAssertEqual(files.map(\.relativePath), ["Alpha.MD", "Guide/Beta.markdown"])
        XCTAssertEqual(files.map(\.displayName), ["Alpha.MD", "Beta.markdown"])
        XCTAssertNil(files[0].parentPath)
        XCTAssertEqual(files[1].parentPath, "Guide")
    }

    func testScannerRejectsFilesAndBoundsPathologicalFolderSize() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try Data().write(to: first)
        try Data().write(to: second)

        XCTAssertThrowsError(try FolderContentScanner.scan(first)) { error in
            XCTAssertEqual(error as? FolderBrowserError, .unavailable)
        }
        XCTAssertThrowsError(
            try FolderContentScanner.scan(root, maximumFileCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? FolderBrowserError,
                .tooManyMarkdownFiles(limit: 1)
            )
        }
    }

    func testBookmarkRestoreRequiresExactDirectoryAndFreshAuthorization() {
        let exact = "/tmp/inflow-folder"
        let record = FolderBrowserRecord(exactPath: exact, bookmark: Data([1]))

        XCTAssertEqual(
            FolderBrowserController.exactResolvedDirectory(
                for: record,
                directoryExists: { _ in false },
                resolveBookmark: { _ in (URL(fileURLWithPath: exact), false) }
            )?.path,
            exact
        )
        XCTAssertNil(
            FolderBrowserController.exactResolvedDirectory(
                for: record,
                directoryExists: { _ in true },
                resolveBookmark: { _ in (URL(fileURLWithPath: exact), true) }
            )
        )
        XCTAssertNil(
            FolderBrowserController.exactResolvedDirectory(
                for: record,
                directoryExists: { _ in true },
                resolveBookmark: { _ in (URL(fileURLWithPath: "/tmp/moved"), false) }
            )
        )
        XCTAssertEqual(
            FolderBrowserController.exactResolvedDirectory(
                for: record,
                directoryExists: { _ in true },
                resolveBookmark: { _ in (URL(fileURLWithPath: exact), false) }
            )?.path,
            exact
        )
    }

    func testControllerPersistsScansAndRetainsFolderAccessForTheSession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# One".utf8).write(to: root.appendingPathComponent("one.md"))
        let persistence = TestFolderBrowserPersistence()
        var started: [URL] = []
        var stopped: [URL] = []
        let controller = FolderBrowserController(
            persistence: persistence,
            restoresSavedFolder: false,
            bookmarkData: { _ in Data([4, 2]) },
            startAccess: { url in
                started.append(url)
                return true
            },
            stopAccess: { stopped.append($0) }
        )

        controller.openFolder(root)
        try await waitUntilReady(controller)

        XCTAssertEqual(controller.folderURL?.path, root.path)
        XCTAssertEqual(controller.files.map(\.relativePath), ["one.md"])
        XCTAssertEqual(
            persistence.record,
            FolderBrowserRecord(exactPath: root.path, bookmark: Data([4, 2]))
        )
        XCTAssertEqual(started.map(\.path), [root.path])
        XCTAssertTrue(stopped.isEmpty)

        controller.openFolder(root)
        try await waitUntilReady(controller)
        XCTAssertEqual(started.map(\.path), [root.path])
    }

    func testControllerRestoresSavedFolderAndRejectsStaleRecord() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Restored".utf8).write(to: root.appendingPathComponent("restored.md"))
        let record = FolderBrowserRecord(exactPath: root.path, bookmark: Data([9]))
        let persistence = TestFolderBrowserPersistence(record: record)
        let restored = FolderBrowserController(
            persistence: persistence,
            resolveBookmark: { _ in (root, false) },
            startAccess: { _ in true },
            stopAccess: { _ in }
        )

        try await waitUntilReady(restored)
        XCTAssertEqual(restored.folderURL?.path, root.path)
        XCTAssertEqual(restored.files.map(\.relativePath), ["restored.md"])

        let stalePersistence = TestFolderBrowserPersistence(record: record)
        let stale = FolderBrowserController(
            persistence: stalePersistence,
            resolveBookmark: { _ in (root, true) }
        )
        XCTAssertNil(stale.folderURL)
        XCTAssertNil(stalePersistence.record)
        XCTAssertNotNil(stale.restorationWarning)
    }

    func testFolderOpenAlwaysPrefersAnUneditedUntitledMainWindow() {
        let named = NSDocument()
        named.fileURL = URL(fileURLWithPath: "/tmp/named.md")
        let edited = NSDocument()
        edited.updateChangeCount(.changeDone)
        let blank = NSDocument()

        XCTAssertTrue(
            DocumentWindowReusePolicy.reusableBlankDocument(
                from: [named, edited, blank]
            ) === blank
        )
        XCTAssertNil(
            DocumentWindowReusePolicy.reusableBlankDocument(from: [named, edited])
        )
    }

    func testFileMenuContainsOneOpenFolderCommand() throws {
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        XCTAssertEqual(items.filter { $0.title == "打开文件夹…" }.count, 1)
    }

    func testLaunchWorkspaceKeepsFileActionsInTheMacOSMenuBar() throws {
        let folderBrowser = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: InflowMainView(
                folderBrowser: folderBrowser,
                onOpenDocument: { _ in }
            )
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let workspaceButtonTitles = descendantButtons(
            in: try XCTUnwrap(window.contentView)
        ).map(\.title)
        XCTAssertTrue(
            Set(workspaceButtonTitles).isDisjoint(
                with: Set(["新建 Markdown", "打开文件…", "打开文件夹…", "清除记录"])
            )
        )

        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "文件")?.submenu)
        XCTAssertEqual(fileMenu.items.filter { $0.title == "打开…" }.count, 1)
        XCTAssertEqual(fileMenu.items.filter { $0.title == "打开文件夹…" }.count, 1)
        XCTAssertEqual(fileMenu.items.filter { $0.title == "打开最近" }.count, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inflow-FolderBrowser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func waitUntilReady(_ controller: FolderBrowserController) async throws {
        for _ in 0 ..< 200 {
            switch controller.state {
            case .ready:
                return
            case let .failed(message):
                XCTFail(message)
                return
            case .idle, .loading:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTFail("文件夹扫描未在预期时间内完成")
    }

    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems(in:)) ?? [])
        }
    }

    private func descendantButtons(in view: NSView) -> [NSButton] {
        let current = (view as? NSButton).map { [$0] } ?? []
        return current + view.subviews.flatMap(descendantButtons(in:))
    }
}

@MainActor
private final class TestFolderBrowserPersistence: FolderBrowserPersistence {
    var record: FolderBrowserRecord?

    init(record: FolderBrowserRecord? = nil) {
        self.record = record
    }

    func load() -> FolderBrowserRecord? {
        record
    }

    func save(_ record: FolderBrowserRecord?) {
        self.record = record
    }
}
