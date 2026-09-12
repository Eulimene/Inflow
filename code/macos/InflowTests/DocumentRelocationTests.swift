import AppKit
import XCTest
@testable import Inflow

final class DocumentRelocationTests: XCTestCase {
    func testReferenceABILayoutAndUnicodeExtractionMatchRustContract() throws {
        XCTAssertEqual(InflowCoreBridge.abiVersion, 2)
        XCTAssertEqual(InflowCoreBridge.abiMajor, 2)
        XCTAssertGreaterThanOrEqual(InflowCoreBridge.abiMinor, 1)
        XCTAssertTrue(InflowCoreBridge.capabilities.isSuperset(of: .editorRequired))
        XCTAssertTrue(InflowCoreBridge.isCompatible)
        XCTAssertEqual(MemoryLayout<InflowReference>.size, 40)
        XCTAssertEqual(MemoryLayout<InflowReference>.alignment, 8)
        XCTAssertEqual(MemoryLayout<InflowReferenceResult>.size, 40)

        let markdown = "[文档][note] ![图](assets/图片%201.png) `![忽略](bad.png)`\n\n[note]: ../资料/说明.md#标题"
        let references = try MarkdownReferenceScanner.references(in: markdown)
        XCTAssertEqual(references.map(\.kind), [.link, .image])
        XCTAssertEqual(references.map(\.target), [
            "../资料/说明.md#标题",
            "assets/图片%201.png",
        ])
        let markdownData = Data(markdown.utf8)
        XCTAssertEqual(
            references.map {
                String(decoding: markdownData[$0.sourceUTF8Range], as: UTF8.self)
            },
            ["[文档][note]", "![图](assets/图片%201.png)"]
        )
    }

    func testSameDirectoryPlanKeepsRelativeResourcesAndIgnoresExternalTargets() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("draft.md")
            let target = directory.appendingPathComponent("renamed.md")
            let asset = directory.appendingPathComponent("assets/photo.png")
            try FileManager.default.createDirectory(
                at: asset.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("image".utf8).write(to: asset)
            let markdown = "![photo](assets/photo.png) [web](https://example.com) [part](#section)"
            let data = Data(markdown.utf8)
            try data.write(to: source)

            let plan = try DocumentRelocationAnalyzer.plan(
                markdown: markdown,
                references: try MarkdownReferenceScanner.references(in: markdown),
                sourceData: data,
                sourceURL: source,
                targetURL: target
            )

            XCTAssertEqual(plan.items.count, 1)
            XCTAssertEqual(plan.unchangedCount, 1)
            XCTAssertEqual(plan.changedCount, 0)
            XCTAssertEqual(plan.unavailableCount, 0)
            XCTAssertNoThrow(
                try DocumentRelocationAnalyzer.verify(
                    plan,
                    currentData: data,
                    currentSourceURL: source
                )
            )
        }
    }

    func testCrossDirectoryPlanShowsChangedAndUnavailableDestinations() throws {
        try withTemporaryDirectory { directory in
            let oldDirectory = directory.appendingPathComponent("old")
            let newDirectory = directory.appendingPathComponent("new")
            try FileManager.default.createDirectory(
                at: oldDirectory.appendingPathComponent("assets"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: newDirectory.appendingPathComponent("assets"),
                withIntermediateDirectories: true
            )
            try Data("old-photo".utf8).write(
                to: oldDirectory.appendingPathComponent("assets/photo.png")
            )
            try Data("new-photo".utf8).write(
                to: newDirectory.appendingPathComponent("assets/photo.png")
            )
            let markdown = "![photo](assets/photo.png) [missing](notes/missing.md)"
            let data = Data(markdown.utf8)

            let plan = try DocumentRelocationAnalyzer.plan(
                markdown: markdown,
                sourceData: data,
                sourceURL: oldDirectory.appendingPathComponent("draft.md"),
                targetURL: newDirectory.appendingPathComponent("draft.md")
            )

            XCTAssertEqual(plan.changedCount, 1)
            XCTAssertEqual(plan.unavailableCount, 1)
            XCTAssertTrue(plan.hasRisk)
            XCTAssertEqual(plan.items.map(\.reference.kind), [.image, .link])
        }
    }

    func testUnsavedDocumentReportsRelativeReferencesAgainstChosenDirectory() throws {
        try withTemporaryDirectory { directory in
            let markdown = "![photo](assets/photo.png)"
            let data = Data(markdown.utf8)
            let plan = try DocumentRelocationAnalyzer.plan(
                markdown: markdown,
                sourceData: data,
                sourceURL: nil,
                targetURL: directory.appendingPathComponent("new.md")
            )

            XCTAssertNil(plan.sourceURL)
            XCTAssertEqual(plan.unavailableCount, 1)
            XCTAssertNil(plan.items.first?.originalURL)
        }
    }

    func testConfirmationExpiresWhenSourceTargetOrResourceChanges() throws {
        try withTemporaryDirectory { directory in
            let oldDirectory = directory.appendingPathComponent("old")
            let newDirectory = directory.appendingPathComponent("new")
            try FileManager.default.createDirectory(
                at: oldDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: newDirectory,
                withIntermediateDirectories: true
            )
            let oldAsset = oldDirectory.appendingPathComponent("asset.txt")
            try Data("first".utf8).write(to: oldAsset)
            let markdown = "[asset](asset.txt)"
            let data = Data(markdown.utf8)
            let target = newDirectory.appendingPathComponent("draft.md")
            let plan = try DocumentRelocationAnalyzer.plan(
                markdown: markdown,
                sourceData: data,
                sourceURL: oldDirectory.appendingPathComponent("draft.md"),
                targetURL: target
            )

            XCTAssertThrowsError(
                try DocumentRelocationAnalyzer.verify(
                    plan,
                    currentData: Data("changed".utf8),
                    currentSourceURL: oldDirectory.appendingPathComponent("draft.md")
                )
            ) { XCTAssertEqual($0 as? DocumentRelocationError, .staleDecision) }

            XCTAssertThrowsError(
                try DocumentRelocationAnalyzer.verify(
                    plan,
                    currentData: data,
                    currentSourceURL: oldDirectory.appendingPathComponent("moved.md")
                )
            ) { XCTAssertEqual($0 as? DocumentRelocationError, .staleDecision) }

            try Data("second".utf8).write(to: oldAsset)
            XCTAssertThrowsError(
                try DocumentRelocationAnalyzer.verify(
                    plan,
                    currentData: data,
                    currentSourceURL: oldDirectory.appendingPathComponent("draft.md")
                )
            ) { XCTAssertEqual($0 as? DocumentRelocationError, .staleDecision) }

            let freshPlan = try DocumentRelocationAnalyzer.plan(
                markdown: markdown,
                sourceData: data,
                sourceURL: oldDirectory.appendingPathComponent("draft.md"),
                targetURL: target
            )
            try Data("occupied".utf8).write(to: target)
            XCTAssertThrowsError(
                try DocumentRelocationAnalyzer.verify(
                    freshPlan,
                    currentData: data,
                    currentSourceURL: oldDirectory.appendingPathComponent("draft.md")
                )
            ) { XCTAssertEqual($0 as? DocumentRelocationError, .staleDecision) }
        }
    }

    func testWriteGuardRechecksAuthorizedSaveAsTargetImmediatelyBeforeWrite() throws {
        try withTemporaryDirectory { directory in
            let sourceURL = directory.appendingPathComponent("source.md")
            let targetURL = directory.appendingPathComponent("target.md")
            let baseline = Data("source".utf8)
            let originalTarget = Data("target-v1".utf8)
            let proposed = Data("local edit".utf8)
            try baseline.write(to: sourceURL)
            try originalTarget.write(to: targetURL)

            let guarder = MarkdownWriteGuard()
            guarder.configure(url: sourceURL, baselineData: baseline)
            try guarder.authorizeRelocation(
                to: targetURL,
                targetSnapshot: HTMLExportTargetSnapshot.capture(targetURL),
                proposedData: proposed
            )
            try Data("target-v2".utf8).write(to: targetURL)

            XCTAssertThrowsError(
                try guarder.authorize(
                    existingFile: FileWrapper(regularFileWithContents: originalTarget),
                    proposedData: proposed
                )
            ) { XCTAssertEqual($0 as? MarkdownWriteGuardError, .targetChanged) }
        }
    }

    func testWriteGuardAllowsUnchangedAuthorizedTargetAndOperationTypesAreCorrect() throws {
        try withTemporaryDirectory { directory in
            let sourceURL = directory.appendingPathComponent("source.md")
            let targetURL = directory.appendingPathComponent("target.md")
            let baseline = Data("source".utf8)
            let target = Data("target".utf8)
            let proposed = Data("edit".utf8)
            try baseline.write(to: sourceURL)
            try target.write(to: targetURL)

            let guarder = MarkdownWriteGuard()
            guarder.configure(url: sourceURL, baselineData: baseline)
            try guarder.authorizeRelocation(
                to: targetURL,
                targetSnapshot: HTMLExportTargetSnapshot.capture(targetURL),
                proposedData: proposed
            )
            XCTAssertNoThrow(
                try guarder.authorize(
                    existingFile: FileWrapper(regularFileWithContents: target),
                    proposedData: proposed
                )
            )
            XCTAssertEqual(
                DocumentRelocationOperation.saveAs.nativeOperation,
                .saveAsOperation
            )
        }
    }

    func testWriteGuardRechecksResourceSnapshotsAtFileWrapperBoundary() throws {
        try withTemporaryDirectory { directory in
            let oldDirectory = directory.appendingPathComponent("old")
            let newDirectory = directory.appendingPathComponent("new")
            try FileManager.default.createDirectory(
                at: oldDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: newDirectory,
                withIntermediateDirectories: true
            )
            let sourceURL = oldDirectory.appendingPathComponent("draft.md")
            let resourceURL = oldDirectory.appendingPathComponent("asset.txt")
            let targetURL = newDirectory.appendingPathComponent("draft.md")
            let markdown = "[asset](asset.txt)"
            let data = Data(markdown.utf8)
            try data.write(to: sourceURL)
            try Data("one".utf8).write(to: resourceURL)
            let plan = try DocumentRelocationAnalyzer.plan(
                markdown: markdown,
                sourceData: data,
                sourceURL: sourceURL,
                targetURL: targetURL
            )
            let guarder = MarkdownWriteGuard()
            guarder.configure(url: sourceURL, baselineData: data)
            try guarder.authorizeRelocation(
                to: targetURL,
                targetSnapshot: plan.targetSnapshot,
                proposedData: data,
                additionalValidation: {
                    DocumentRelocationAnalyzer.resourcesAreCurrent(plan)
                }
            )
            try Data("two".utf8).write(to: resourceURL)

            XCTAssertThrowsError(
                try guarder.authorize(existingFile: nil, proposedData: data)
            ) { XCTAssertEqual($0 as? MarkdownWriteGuardError, .targetChanged) }
        }
    }

    func testDocumentIdentityTreatsHardLinksAsTheSameOpenDocument() throws {
        try withTemporaryDirectory { directory in
            let original = directory.appendingPathComponent("original.md")
            let hardLink = directory.appendingPathComponent("alias.md")
            try Data("one inode\n".utf8).write(to: original)
            try FileManager.default.linkItem(at: original, to: hardLink)

            XCTAssertNotEqual(
                original.standardizedFileURL.path,
                hardLink.standardizedFileURL.path
            )
            XCTAssertEqual(
                DocumentResourceIdentity.capture(original),
                DocumentResourceIdentity.capture(hardLink)
            )
            XCTAssertTrue(DocumentRelocationAnalyzer.isSameFile(original, hardLink))
        }
    }

    @MainActor
    func testNativeCoordinatorForwardsSaveAsAndCurrentSaveOperations() async throws {
        let document = RecordingDocument()
        let firstURL = URL(fileURLWithPath: "/tmp/inflow-save-as.md")
        try await NativeDocumentSaveCoordinator.save(
            document: document,
            to: firstURL,
            operation: .saveAs
        )
        XCTAssertEqual(document.lastURL, firstURL)
        XCTAssertEqual(document.lastOperation, .saveAsOperation)

        let currentURL = URL(fileURLWithPath: "/tmp/inflow-current.md")
        try await NativeDocumentSaveCoordinator.saveCurrent(
            document: document,
            to: currentURL
        )
        XCTAssertEqual(document.lastURL, currentURL)
        XCTAssertEqual(document.lastOperation, .saveOperation)

        document.nextError = CocoaError(.fileWriteNoPermission)
        do {
            try await NativeDocumentSaveCoordinator.saveCurrent(
                document: document,
                to: currentURL
            )
            XCTFail("Expected save failure to propagate")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-native-revert-\(UUID().uuidString).md"
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let verifiedData = Data("verified descriptor bytes\n".utf8)
        try verifiedData.write(to: sourceURL)
        let sourceModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: sourceModificationDate],
            ofItemAtPath: sourceURL.path
        )
        document.fileURL = sourceURL
        let stagingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-native-revert-staging-\(UUID().uuidString).md"
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let revertPreparation = try NativeDocumentSaveCoordinator.prepareRevert(
            from: sourceURL,
            verifiedData: verifiedData,
            materialize: { data, _ in
                try data.write(to: stagingURL)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                    ofItemAtPath: stagingURL.path
                )
                return stagingURL
            }
        )
        defer {
            NativeDocumentSaveCoordinator.discardRevertPreparation(revertPreparation)
        }
        try Data("untrusted path bytes\n".utf8).write(to: sourceURL)
        try NativeDocumentSaveCoordinator.revert(
            document: document,
            using: revertPreparation
        )
        XCTAssertEqual(document.lastRevertData, verifiedData)
        XCTAssertNotEqual(document.lastRevertURL, sourceURL)
        XCTAssertEqual(document.fileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(
            try XCTUnwrap(document.fileModificationDate).timeIntervalSince1970,
            sourceModificationDate.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try Data(contentsOf: sourceURL),
            Data("untrusted path bytes\n".utf8),
            "native revert must not reopen or rewrite the mutable represented path"
        )
    }

    @MainActor
    func testNativeCoordinatorRetainsDeferredSaveCopyOperation() async throws {
        let document = RecordingDocument()
        let copyURL = URL(fileURLWithPath: "/tmp/inflow-save-copy.md")
        try await NativeDocumentSaveCoordinator.save(
            document: document,
            to: copyURL,
            operation: .saveCopy
        )
        XCTAssertEqual(document.lastURL, copyURL)
        XCTAssertEqual(document.lastOperation, .saveToOperation)
        XCTAssertEqual(DocumentRelocationOperation.saveCopy.nativeOperation, .saveToOperation)
    }

    @MainActor
    func testFileMenuExposesSaveAsWithoutDeferredSaveCopyCommand() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        let saveAsItems = items.filter { $0.title == "另存为…" }
        XCTAssertEqual(saveAsItems.count, 1)
        let saveAs = try XCTUnwrap(saveAsItems.first)
        XCTAssertEqual(saveAs.keyEquivalent, "s")
        XCTAssertEqual(
            saveAs.keyEquivalentModifierMask.intersection([.command, .option, .shift]),
            [.command, .shift]
        )
        XCTAssertEqual(items.filter { $0.title == "保存副本…" }.count, 0)
        XCTAssertEqual(items.filter { $0.title == "在 Finder 中显示" }.count, 1)
    }

    @MainActor
    func testMenusDoNotExposePostLaunchCommands() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        let postLaunchTitles = [
            "打开工作区…",
            "打印…",
            "浏览本地版本时间线…",
            "快速打开…",
            "工作区搜索…",
            "结构洞察",
            "资源管家",
            "文档健康中心",
            "迁移内容…",
            "能力中心",
            "权限中心",
            "编辑来源信息…",
            "插件市场",
            "插件购买与订阅…",
            "开发者中心…",
            "关闭窗口",
            "显示上一个标签页",
            "显示下一个标签页",
            "将标签页移到新窗口",
        ]
        for title in postLaunchTitles {
            XCTAssertTrue(items.filter { $0.title == title }.isEmpty, title)
        }
        XCTAssertEqual(items.filter { $0.title == "即时编辑" }.count, 1)
        XCTAssertTrue(items.filter {
            $0.keyEquivalent == "p"
                && $0.keyEquivalentModifierMask.contains(.command)
        }.isEmpty)
    }

    @MainActor
    func testSaveCommandActionsRemainScopedToTheirDocumentScene() {
        var firstEvents: [String] = []
        var secondEvents: [String] = []
        let first = DocumentSaveCommandActions(
            isBusy: false,
            canSave: false,
            save: { firstEvents.append("save") },
            saveAs: { firstEvents.append("saveAs") },
            showInFinder: nil
        )
        let second = DocumentSaveCommandActions(
            isBusy: true,
            save: { secondEvents.append("save") },
            saveAs: { secondEvents.append("saveAs") },
            showInFinder: { secondEvents.append("finder") }
        )

        first.save()
        first.saveAs()
        second.showInFinder?()

        XCTAssertEqual(firstEvents, ["save", "saveAs"])
        XCTAssertEqual(secondEvents, ["finder"])
        XCTAssertFalse(first.isBusy)
        XCTAssertFalse(first.canSave)
        XCTAssertTrue(second.isBusy)
        XCTAssertTrue(second.canSave)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-relocation-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems(in:)) ?? [])
        }
    }
}

@MainActor
private final class RecordingDocument: NSDocument {
    private(set) var lastURL: URL?
    private(set) var lastOperation: NSDocument.SaveOperationType?
    private(set) var lastRevertURL: URL?
    private(set) var lastRevertData: Data?
    var nextError: Error?

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        lastURL = url
        lastOperation = saveOperation
        completionHandler(nextError)
        nextError = nil
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        lastRevertURL = url
        lastRevertData = try Data(contentsOf: url)
        fileURL = url
        fileType = typeName
    }
}
