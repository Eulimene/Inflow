import AppKit
import XCTest
@testable import Inflow

final class DocumentRelocationTests: XCTestCase {
    func testReferenceABILayoutAndUnicodeExtractionMatchRustContract() throws {
        XCTAssertEqual(MemoryLayout<InflowReference>.size, 24)
        XCTAssertEqual(MemoryLayout<InflowReference>.alignment, 8)
        XCTAssertEqual(MemoryLayout<InflowReferenceResult>.size, 40)

        let references = try MarkdownReferenceScanner.references(
            in: "[文档][note] ![图](assets/图片%201.png) `![忽略](bad.png)`\n\n[note]: ../资料/说明.md#标题"
        )
        XCTAssertEqual(
            references,
            [
                MarkdownReference(kind: .link, target: "../资料/说明.md#标题"),
                MarkdownReference(kind: .image, target: "assets/图片%201.png"),
            ]
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
            XCTAssertEqual(
                DocumentRelocationOperation.saveCopy.nativeOperation,
                .saveToOperation
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

    @MainActor
    func testNativeCoordinatorForwardsSaveAsAndSaveCopyOperations() async throws {
        let document = RecordingDocument()
        let firstURL = URL(fileURLWithPath: "/tmp/inflow-save-as.md")
        try await NativeDocumentSaveCoordinator.save(
            document: document,
            to: firstURL,
            operation: .saveAs
        )
        XCTAssertEqual(document.lastURL, firstURL)
        XCTAssertEqual(document.lastOperation, .saveAsOperation)

        let copyURL = URL(fileURLWithPath: "/tmp/inflow-save-copy.md")
        try await NativeDocumentSaveCoordinator.save(
            document: document,
            to: copyURL,
            operation: .saveCopy
        )
        XCTAssertEqual(document.lastURL, copyURL)
        XCTAssertEqual(document.lastOperation, .saveToOperation)

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
    }

    @MainActor
    func testFileMenuExposesOneSaveAsAndSaveCopyCommand() throws {
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
        XCTAssertEqual(items.filter { $0.title == "保存副本…" }.count, 1)
        XCTAssertEqual(items.filter { $0.title == "在 Finder 中显示" }.count, 1)
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
            saveCopy: { firstEvents.append("copy") },
            showInFinder: nil
        )
        let second = DocumentSaveCommandActions(
            isBusy: true,
            save: { secondEvents.append("save") },
            saveAs: { secondEvents.append("saveAs") },
            saveCopy: { secondEvents.append("copy") },
            showInFinder: { secondEvents.append("finder") }
        )

        first.save()
        first.saveAs()
        first.saveCopy()
        second.showInFinder?()

        XCTAssertEqual(firstEvents, ["save", "saveAs", "copy"])
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
}
