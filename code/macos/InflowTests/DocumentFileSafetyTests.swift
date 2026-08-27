import AppKit
import XCTest
@testable import Inflow

final class DocumentFileSafetyTests: XCTestCase {
    func testReadOnlyPromptUsesFrozenSafeExitCopy() {
        XCTAssertEqual(
            ReadOnlyDocumentPrompt.title(filename: "notes.md"),
            "「notes.md」是只读的"
        )
        XCTAssertEqual(
            ReadOnlyDocumentPrompt.message,
            "你可以阅读、复制或将它另存到其他位置。"
        )
        XCTAssertEqual(ReadOnlyDocumentPrompt.saveAsTitle, "另存为…")
        XCTAssertEqual(ReadOnlyDocumentPrompt.showInFinderTitle, "在 Finder 中显示")
        XCTAssertEqual(ReadOnlyDocumentPrompt.closeTitle, "关闭")
    }

    func testExternalChangePromptsUseFrozenTitlesMessagesAndActions() {
        XCTAssertEqual(
            ExternalFileChangePrompt.diskOnlyTitle(filename: "notes.md"),
            "「notes.md」已有新内容"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.diskOnlyMessage,
            "你没有未保存更改，可以查看变化并采用磁盘版本。"
        )
        XCTAssertEqual(ExternalFileChangePrompt.viewChangesTitle, "查看变化…")
        XCTAssertEqual(ExternalFileChangePrompt.reloadTitle, "重新载入")
        XCTAssertEqual(ExternalFileChangePrompt.laterTitle, "稍后")
        XCTAssertEqual(
            ExternalFileChangePrompt.conflictTitle(filename: "notes.md"),
            "「notes.md」已在其他位置更改"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.conflictMessage,
            "为避免覆盖，自动保存已暂停。请对照最近成功保存版本、当前编辑和磁盘版本。"
        )
        XCTAssertEqual(ExternalFileChangePrompt.compareTitle, "比较…")
        XCTAssertEqual(ExternalFileChangePrompt.saveCopyTitle, "保存副本…")
        XCTAssertEqual(ExternalFileChangePrompt.reloadReviewTitle, "重新载入…")
        XCTAssertEqual(ExternalFileChangePrompt.overwriteTitle, "覆盖磁盘版本…")
        XCTAssertEqual(
            ExternalFileChangePrompt.reloadConfirmationTitle,
            "放弃当前编辑并重新载入？"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.reloadConfirmationMessage,
            "当前未保存更改将被放弃，且无法通过撤销恢复。"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.overwriteConfirmationTitle,
            "覆盖磁盘上的新版本？"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.overwriteConfirmationMessage,
            "先保存当前磁盘版本的冲突副本，然后写入你的编辑。"
        )
        XCTAssertEqual(ExternalFileChangePrompt.overwriteFailureTitle, "无法安全覆盖")
        XCTAssertEqual(
            ExternalFileChangePrompt.overwriteFailureMessage,
            "未能保存磁盘当前版本的冲突副本，因此没有执行覆盖。"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.deletedTitle(filename: "notes.md"),
            "「notes.md」已从磁盘删除"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.deletedMessage,
            "当前编辑仍已保留，且不会自动重建原文件。"
        )
        XCTAssertEqual(ExternalFileChangePrompt.saveAsTitle, "另存为…")
        XCTAssertEqual(ExternalFileChangePrompt.recreateTitle, "在原位置重建…")
        XCTAssertEqual(ExternalFileChangePrompt.handleLaterTitle, "稍后处理")
    }

    func testConflictSnapshotIdentityChangesOnlyWhenComparedFactsChange() {
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let baseline = Data("baseline".utf8)
        let local = Data("local".utf8)
        let disk = Data("disk".utf8)
        let first = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baseline,
            baselineText: "baseline",
            localData: local,
            localText: "local",
            diskData: disk,
            diskText: "disk",
            diskExists: true
        )
        let sameFacts = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baseline,
            baselineText: "baseline",
            localData: local,
            localText: "local",
            diskData: disk,
            diskText: "disk",
            diskExists: true
        )
        let changedAgain = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baseline,
            baselineText: "baseline",
            localData: local,
            localText: "local",
            diskData: Data("new disk".utf8),
            diskText: "new disk",
            diskExists: true
        )

        XCTAssertTrue(first.hasSameFacts(as: sameFacts))
        XCTAssertFalse(first.hasSameFacts(as: changedAgain))
    }

    func testOnlyDirectoryMutatingConflictActionsRequireExactDirectoryAccess() {
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let baseline = Data("baseline".utf8)
        let disk = Data("disk".utf8)
        let unchangedLocal = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baseline,
            baselineText: "baseline",
            localData: baseline,
            localText: "baseline",
            diskData: disk,
            diskText: "disk",
            diskExists: true
        )
        let changedLocal = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baseline,
            baselineText: "baseline",
            localData: Data("local".utf8),
            localText: "local",
            diskData: disk,
            diskText: "disk",
            diskExists: true
        )
        let deleted = DocumentFileConflictSnapshot(
            url: url,
            baselineData: baseline,
            baselineText: "baseline",
            localData: Data("local".utf8),
            localText: "local",
            diskData: nil,
            diskText: nil,
            diskExists: false
        )

        XCTAssertNil(DocumentFileSafetyState.safe.directoryMutationSnapshotID)
        XCTAssertNil(
            DocumentFileSafetyState.readOnly(url).directoryMutationSnapshotID
        )
        XCTAssertNil(
            DocumentFileSafetyState.changed(unchangedLocal).directoryMutationSnapshotID
        )
        XCTAssertEqual(
            DocumentFileSafetyState.changed(changedLocal).directoryMutationSnapshotID,
            changedLocal.id
        )
        XCTAssertEqual(
            DocumentFileSafetyState.deleted(deleted).directoryMutationSnapshotID,
            deleted.id
        )
    }

    func testWriteGuardAllowsOwnSaveAndAdoptsCompletedWrite() throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("saved\n".utf8)
        let firstEdit = Data("saved\nfirst\n".utf8)
        let secondEdit = Data("saved\nfirst\nsecond\n".utf8)
        try baseline.write(to: fixture.documentURL)
        let guardrail = MarkdownWriteGuard()
        guardrail.configure(url: fixture.documentURL, baselineData: baseline)

        XCTAssertNoThrow(
            try guardrail.authorize(
                existingFile: FileWrapper(regularFileWithContents: baseline),
                proposedData: firstEdit
            )
        )
        try firstEdit.write(to: fixture.documentURL)
        XCTAssertNoThrow(
            try guardrail.authorize(
                existingFile: FileWrapper(regularFileWithContents: firstEdit),
                proposedData: secondEdit
            )
        )
    }

    func testWriteGuardBlocksExternalChangeAndDeletionButAllowsSaveAsTarget() throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        let external = Data("external\n".utf8)
        let local = Data("local\n".utf8)
        try baseline.write(to: fixture.documentURL)
        let guardrail = MarkdownWriteGuard()
        guardrail.configure(url: fixture.documentURL, baselineData: baseline)

        try external.write(to: fixture.documentURL)
        XCTAssertThrowsError(
            try guardrail.authorize(
                existingFile: FileWrapper(regularFileWithContents: external),
                proposedData: local
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownWriteGuardError, .externalChange)
        }
        XCTAssertNoThrow(
            try guardrail.authorize(
                existingFile: FileWrapper(regularFileWithContents: Data("other target".utf8)),
                proposedData: local
            )
        )

        try FileManager.default.removeItem(at: fixture.documentURL)
        XCTAssertThrowsError(
            try guardrail.authorize(existingFile: nil, proposedData: local)
        ) { error in
            XCTAssertEqual(error as? MarkdownWriteGuardError, .deletedTarget)
        }
    }

    func testWorkerOverwriteCreatesPermanentConflictCopyBeforeReplacingOriginal() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        let disk = Data("external\n".utf8)
        let local = Data("local\n".utf8)
        try disk.write(to: fixture.documentURL)
        let snapshot = DocumentFileConflictSnapshot(
            url: fixture.documentURL,
            baselineData: baseline,
            baselineText: "baseline\n",
            localData: local,
            localText: "local\n",
            diskData: disk,
            diskText: "external\n",
            diskExists: true
        )

        let conflictURL = try await DocumentFileSafetyWorker().overwrite(
            snapshot: snapshot,
            with: local,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(try Data(contentsOf: fixture.documentURL), local)
        XCTAssertEqual(try Data(contentsOf: conflictURL), disk)
        XCTAssertTrue(conflictURL.lastPathComponent.contains("冲突副本"))
    }

    func testOverwriteAndRecreateRejectStaleDiskDecision() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        let disk = Data("external\n".utf8)
        let local = Data("local\n".utf8)
        try disk.write(to: fixture.documentURL)
        let worker = DocumentFileSafetyWorker()
        let changedSnapshot = DocumentFileConflictSnapshot(
            url: fixture.documentURL,
            baselineData: baseline,
            baselineText: "baseline\n",
            localData: local,
            localText: "local\n",
            diskData: disk,
            diskText: "external\n",
            diskExists: true
        )
        try Data("changed again\n".utf8).write(to: fixture.documentURL)

        do {
            _ = try await worker.overwrite(snapshot: changedSnapshot, with: local)
            XCTFail("Expected a stale overwrite decision")
        } catch {
            XCTAssertEqual(error as? DocumentFileSafetyError, .staleDecision)
        }

        try FileManager.default.removeItem(at: fixture.documentURL)
        let deletedSnapshot = DocumentFileConflictSnapshot(
            url: fixture.documentURL,
            baselineData: baseline,
            baselineText: "baseline\n",
            localData: local,
            localText: "local\n",
            diskData: nil,
            diskText: nil,
            diskExists: false
        )
        try Data("reappeared\n".utf8).write(to: fixture.documentURL)
        do {
            try await worker.recreate(snapshot: deletedSnapshot, with: local)
            XCTFail("Expected a stale recreate decision")
        } catch {
            XCTAssertEqual(error as? DocumentFileSafetyError, .staleDecision)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.documentURL), Data("reappeared\n".utf8))
    }

    @MainActor
    func testSessionBuildsThreeWayConflictAndReloadAdoptsDiskAsNewUndoOrigin() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        let external = Data("external 🌍\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 5_000_000)
        session.update(document: document, fileURL: fixture.documentURL)
        document.text = "local edit\n"
        session.update(document: document, fileURL: fixture.documentURL)
        try external.write(to: fixture.documentURL)

        let snapshot = try await waitForConflict(in: session)
        XCTAssertEqual(snapshot.baselineText, "baseline\n")
        XCTAssertEqual(snapshot.localText, "local edit\n")
        XCTAssertEqual(snapshot.diskText, "external 🌍\n")
        XCTAssertTrue(snapshot.localHasChanges)

        let result = try await session.reload(snapshot)
        XCTAssertEqual(result.data, external)
        XCTAssertEqual(result.decoded.text, "external 🌍\n")

        let editor = MarkdownSourceEditorSession()
        editor.textView.string = "local edit\n"
        editor.textView.insertText("more", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.textView.undoManager?.canUndo == true)
        editor.resetAfterExternalReload(result.decoded.text)
        XCTAssertEqual(editor.textView.string, "external 🌍\n")
        XCTAssertFalse(editor.textView.undoManager?.canUndo == true)
        session.stopMonitoring()
    }

    @MainActor
    func testDiskOnlyExternalChangeCanAdoptDiskWithoutDestructiveConfirmation() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        let external = Data("external\n".utf8)
        try baseline.write(to: fixture.documentURL)
        let document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 5_000_000)
        session.update(document: document, fileURL: fixture.documentURL)
        try external.write(to: fixture.documentURL)

        let snapshot = try await waitForConflict(in: session)
        XCTAssertFalse(snapshot.localHasChanges)
        let result = try await session.reload(snapshot)

        XCTAssertEqual(result.data, external)
        XCTAssertEqual(result.decoded.text, "external\n")
        guard case .safe = session.state else {
            return XCTFail("Expected the adopted disk version to restore safe state")
        }
        session.stopMonitoring()
    }

    @MainActor
    func testSessionReportsDeletionWithoutRecreatingTarget() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 5_000_000)
        session.update(document: document, fileURL: fixture.documentURL)
        document.text = "still in memory\n"
        session.update(document: document, fileURL: fixture.documentURL)
        try FileManager.default.removeItem(at: fixture.documentURL)

        let snapshot = try await waitForConflict(in: session)
        guard case .deleted = session.state else {
            return XCTFail("Expected deleted state")
        }
        XCTAssertFalse(snapshot.diskExists)
        XCTAssertEqual(snapshot.localText, "still in memory\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.documentURL.path))
        session.stopMonitoring()
    }

    @MainActor
    func testUpdatingSameDocumentRestartsStoppedMonitor() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        let document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 5_000_000)
        session.update(document: document, fileURL: fixture.documentURL)
        session.stopMonitoring()

        try Data("external\n".utf8).write(to: fixture.documentURL)
        session.update(document: document, fileURL: fixture.documentURL)

        let snapshot = try await waitForConflict(in: session)
        XCTAssertEqual(snapshot.diskText, "external\n")
        session.stopMonitoring()
    }

    private struct FileSafetyFixture {
        let root: URL
        let documentURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "inflow-file-safety-\(UUID().uuidString)",
                isDirectory: true
            )
            documentURL = root.appendingPathComponent("note.md")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private func waitForConflict(
        in session: DocumentFileSafetySession,
        timeout: TimeInterval = 1
    ) async throws -> DocumentFileConflictSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = session.state.conflictSnapshot {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out while waiting for file monitor")
        throw NSError(domain: "DocumentFileSafetyTests", code: 1)
    }
}
