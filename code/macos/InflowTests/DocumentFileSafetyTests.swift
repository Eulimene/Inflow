import AppKit
import XCTest
@testable import Inflow

final class DocumentFileSafetyTests: XCTestCase {
    func testSupersededProcessCannotSerializeOrAuthorizeDocumentSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DocumentProcessWitness(directory: root, instance: UUID(), isAlive: { _ in true })
        let second = DocumentProcessWitness(directory: root, instance: UUID(), isAlive: { _ in true })
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 1, recoveryIDs: []))
        let guardrail = MarkdownWriteGuard()
        guardrail.setProcessWitness(first)
        let data = Data("current content".utf8)
        XCTAssertEqual(try guardrail.fileDocumentSerializationData(fallback: data), data)
        try second.publish(DocumentProcessClaim(instance: second.instance, pid: 2, activatedAt: 2, recoveryIDs: []))
        XCTAssertThrowsError(try guardrail.fileDocumentSerializationData(fallback: data)) {
            XCTAssertEqual($0 as? MarkdownWriteGuardError, .supersededProcess)
        }
        XCTAssertThrowsError(try guardrail.authorize(existingFile: nil, proposedData: data)) {
            XCTAssertEqual($0 as? MarkdownWriteGuardError, .supersededProcess)
        }
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 3, recoveryIDs: []))
        XCTAssertEqual(try guardrail.fileDocumentSerializationData(fallback: data), data)
    }

    func testPeerReloadPreservesDirtyTextBeforeAdoptingDiskContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TemporaryDocumentDraftStore(rootURL: root)
        let url = root.appendingPathComponent("notes.md")
        let snapshot = DocumentFileConflictSnapshot(url: url, baselineData: Data("base".utf8), baselineText: "base",
            localData: Data("my draft".utf8), localText: "my draft", diskData: Data("peer saved".utf8), diskText: "peer saved", diskExists: true)
        XCTAssertTrue(DocumentPeerReloadPolicy.shouldReload(snapshot, isOwner: false, takingOwnership: false))
        XCTAssertTrue(DocumentPeerReloadPolicy.shouldReload(snapshot, isOwner: true, takingOwnership: true))
        XCTAssertFalse(DocumentPeerReloadPolicy.shouldReload(snapshot, isOwner: true, takingOwnership: false))
        try DocumentPeerReloadPolicy.preserveLocalChanges(snapshot, document: MarkdownDocument(text: "my draft"), viewMode: .preview, store: store)
        let copies = try store.records()
        XCTAssertEqual(copies.map(\.text), ["my draft"])
        XCTAssertEqual(copies.first?.originalURL, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Preserving a draft must not write back to the document")
    }

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
            "你没有未保存更改。可以重新载入磁盘内容，或暂不处理。"
        )
        XCTAssertEqual(ExternalFileChangePrompt.reloadTitle, "重新载入")
        XCTAssertEqual(ExternalFileChangePrompt.laterTitle, "稍后")
        XCTAssertEqual(
            ExternalFileChangePrompt.conflictTitle(filename: "notes.md"),
            "「notes.md」已在其他位置更改"
        )
        XCTAssertEqual(
            ExternalFileChangePrompt.conflictMessage,
            "磁盘内容与当前编辑都已保留。重新载入会采用磁盘版本；再次手动保存时会先询问是否覆盖。"
        )
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
            "确认后将用当前编辑覆盖磁盘内容；取消时两份内容都保持不变。"
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

    func testAutomaticSaveConfirmedByNextWrapperIsStillObservedBeforeFollowingWrite()
        throws
    {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        document.writeGuard.configure(
            url: fixture.documentURL,
            baselineData: baseline
        )

        document.text = "automatic A\n"
        let wrapperA = try document.fileWrapper(
            existingFile: FileWrapper(regularFileWithContents: baseline)
        )
        let dataA = try XCTUnwrap(wrapperA.regularFileContents)
        try dataA.write(to: fixture.documentURL)

        document.text = "automatic B\n"
        let wrapperB = try document.fileWrapper(
            existingFile: FileWrapper(regularFileWithContents: dataA)
        )
        let dataB = try XCTUnwrap(wrapperB.regularFileContents)
        XCTAssertNotEqual(dataA, dataB)

        let observedA = try XCTUnwrap(
            document.writeGuard.observe(diskData: dataA).committedAutomaticEnvelope
        )
        XCTAssertEqual(observedA.operation, .automatic)
        XCTAssertEqual(observedA.bytes, dataA)
        XCTAssertNil(
            document.writeGuard.observe(diskData: dataA).committedAutomaticEnvelope
        )

        try dataB.write(to: fixture.documentURL)
        let observedB = try XCTUnwrap(
            document.writeGuard.observe(diskData: dataB).committedAutomaticEnvelope
        )
        XCTAssertEqual(observedB.bytes, dataB)
        XCTAssertGreaterThan(observedB.revision, observedA.revision)
        XCTAssertNil(
            document.writeGuard.observe(diskData: dataB).committedAutomaticEnvelope
        )
    }

    func testMultipleUnobservedAutomaticCommitsCollapseToLatestRevision() throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        document.writeGuard.configure(
            url: fixture.documentURL,
            baselineData: baseline
        )

        document.text = "automatic A\n"
        let dataA = try XCTUnwrap(
            document.fileWrapper(
                existingFile: FileWrapper(regularFileWithContents: baseline)
            ).regularFileContents
        )
        try dataA.write(to: fixture.documentURL)

        document.text = "automatic B\n"
        let dataB = try XCTUnwrap(
            document.fileWrapper(
                existingFile: FileWrapper(regularFileWithContents: dataA)
            ).regularFileContents
        )
        try dataB.write(to: fixture.documentURL)

        document.text = "automatic C not committed\n"
        _ = try document.fileWrapper(
            existingFile: FileWrapper(regularFileWithContents: dataB)
        )

        let latest = try XCTUnwrap(
            document.writeGuard.observe(diskData: dataB).committedAutomaticEnvelope
        )
        XCTAssertEqual(latest.bytes, dataB)
        XCTAssertNotEqual(latest.bytes, dataA)
        XCTAssertNil(
            document.writeGuard.observe(diskData: dataB).committedAutomaticEnvelope
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

    @MainActor
    func testSaveEnvelopeCommitsOnlyFrozenBytesAndLeavesNewerEditDirty() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 60_000_000_000)
        session.update(document: document, fileURL: fixture.documentURL)

        document.text = "first edit\n"
        session.update(document: document, fileURL: fixture.documentURL)
        let envelope = try session.prepareSave(
            document: document,
            sourceURL: fixture.documentURL,
            targetURL: fixture.documentURL,
            targetExpectation: try .capture(fixture.documentURL),
            operation: .save
        )
        XCTAssertTrue(envelope.hasValidHash)
        XCTAssertEqual(envelope.bytes, Data("first edit\n".utf8))

        try envelope.bytes.write(to: fixture.documentURL)
        document.text = "first edit\nnewer edit\n"
        session.update(document: document, fileURL: fixture.documentURL)
        try await session.commitSave(envelope)

        XCTAssertTrue(session.hasUncommittedChanges)
        XCTAssertEqual(try Data(contentsOf: fixture.documentURL), envelope.bytes)
        session.stopMonitoring()
    }

    @MainActor
    func testFileDocumentWrapperSerializesPreparedEnvelopeWhileNewerEditStaysDirty()
        async throws
    {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 60_000_000_000)
        session.update(document: document, fileURL: fixture.documentURL)

        document.text = "frozen save\n"
        session.update(document: document, fileURL: fixture.documentURL)
        let envelope = try session.prepareSave(
            document: document,
            sourceURL: fixture.documentURL,
            targetURL: fixture.documentURL,
            targetExpectation: try .capture(fixture.documentURL),
            operation: .save
        )
        defer { session.cancelSave(envelope) }

        document.text = "frozen save\nnewer edit\n"
        session.update(document: document, fileURL: fixture.documentURL)
        let wrapper = try document.fileWrapper(
            existingFile: FileWrapper(regularFileWithContents: baseline)
        )
        let serialized = try XCTUnwrap(wrapper.regularFileContents)

        XCTAssertEqual(serialized, envelope.bytes)
        XCTAssertNotEqual(serialized, try document.encodedFileData())
        try serialized.write(to: fixture.documentURL)
        try await session.commitSave(envelope)
        XCTAssertTrue(session.hasUncommittedChanges)
        XCTAssertEqual(try Data(contentsOf: fixture.documentURL), envelope.bytes)
        session.stopMonitoring()
    }

    func testSaveExpectationRejectsSymlinkAndIdentityReplacementWithSameBytes() throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let original = Data("same bytes\n".utf8)
        try original.write(to: fixture.documentURL)
        let expectation = try SaveEnvelope.TargetExpectation.capture(fixture.documentURL)

        try FileManager.default.removeItem(at: fixture.documentURL)
        try original.write(to: fixture.documentURL)
        XCTAssertFalse(expectation.isCurrent(at: fixture.documentURL))

        let symbolicLink = fixture.root.appendingPathComponent("save-target.md")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: fixture.documentURL
        )
        XCTAssertThrowsError(try SaveEnvelope.TargetExpectation.capture(symbolicLink)) {
            error in
            XCTAssertEqual(error as? HTMLExportTargetError, .unsupportedTarget)
        }
    }

    @MainActor
    func testSaveEnvelopeRejectsCompletionWhoseDiskBytesDoNotMatch() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        let session = DocumentFileSafetySession(intervalNanoseconds: 60_000_000_000)
        session.update(document: document, fileURL: fixture.documentURL)
        document.text = "requested save\n"
        session.update(document: document, fileURL: fixture.documentURL)
        let envelope = try session.prepareSave(
            document: document,
            sourceURL: fixture.documentURL,
            targetURL: fixture.documentURL,
            targetExpectation: try .capture(fixture.documentURL),
            operation: .save
        )
        try Data("different writer won\n".utf8).write(to: fixture.documentURL)

        do {
            try await session.commitSave(envelope)
            XCTFail("Expected mismatched completion to remain uncommitted")
        } catch {
            XCTAssertEqual(error as? DocumentFileSafetyError, .saveCompletionMismatch)
        }
        XCTAssertTrue(session.hasUncommittedChanges)
        session.cancelSave(envelope)
        session.stopMonitoring()
    }

    @MainActor
    func testSaveAsBaselineSurvivesFileURLTransitionBeforeAndAfterCompletion() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let targetURL = fixture.root.appendingPathComponent("renamed.md")
        let baseline = Data("baseline\n".utf8)
        try baseline.write(to: fixture.documentURL)
        var document = try MarkdownDocument(fileData: baseline)
        document.text = "save as snapshot\n"
        let session = DocumentFileSafetySession(intervalNanoseconds: 60_000_000_000)
        session.update(document: document, fileURL: fixture.documentURL)
        let envelope = try session.prepareSave(
            document: document,
            sourceURL: fixture.documentURL,
            targetURL: targetURL,
            targetExpectation: .absent,
            operation: .saveAs
        )
        try envelope.bytes.write(to: targetURL)

        // SwiftUI may publish the new fileURL before AppKit calls save completion.
        session.update(document: document, fileURL: targetURL)
        // Monitoring may adopt matching disk bytes before native completion.
        document.writeGuard.adopt(envelope.bytes)
        try await session.commitSave(envelope)
        XCTAssertFalse(session.hasUncommittedChanges)

        // The reverse callback order must preserve the same committed baseline.
        let secondTarget = fixture.root.appendingPathComponent("renamed-again.md")
        document.text = "second relocation\n"
        session.update(document: document, fileURL: targetURL)
        let secondEnvelope = try session.prepareSave(
            document: document,
            sourceURL: targetURL,
            targetURL: secondTarget,
            targetExpectation: .absent,
            operation: .saveAs
        )
        try secondEnvelope.bytes.write(to: secondTarget)
        try await session.commitSave(secondEnvelope)
        session.update(document: document, fileURL: secondTarget)
        XCTAssertFalse(session.hasUncommittedChanges)
        session.stopMonitoring()
    }

    @MainActor
    func testFirstSaveAsCommitsFrozenEnvelopeWhenFileURLPublishesBeforeCompletion() async throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let targetURL = fixture.root.appendingPathComponent("first-save.md")
        var document = MarkdownDocument(text: "first save snapshot\n")
        let session = DocumentFileSafetySession(intervalNanoseconds: 60_000_000_000)
        session.update(document: document, fileURL: nil)
        let envelope = try session.prepareSave(
            document: document,
            sourceURL: nil,
            targetURL: targetURL,
            targetExpectation: .absent,
            operation: .saveAs
        )

        document.text = "first save snapshot\nnewer edit\n"
        let alias = fixture.root.appendingPathComponent("directory-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        session.update(document: document, fileURL: alias.appendingPathComponent("first-save.md"))
        try envelope.bytes.write(to: targetURL)
        try await session.commitSave(envelope)

        XCTAssertEqual(try Data(contentsOf: targetURL), envelope.bytes)
        XCTAssertTrue(session.hasUncommittedChanges)
        session.stopMonitoring()
    }

    func testFrozenLocalFileReadRejectsPathReplacementAndSymlink() throws {
        let fixture = try FileSafetyFixture()
        defer { fixture.remove() }
        let original = Data("trusted bytes".utf8)
        try original.write(to: fixture.documentURL)
        let snapshot = try PreviewLocalFileSnapshot.capture(fixture.documentURL)
        let frozen = try PreviewLocalFileReader.read(
            fixture.documentURL,
            expected: snapshot
        )
        XCTAssertEqual(frozen.data, original)

        try FileManager.default.removeItem(at: fixture.documentURL)
        try Data("replacement".utf8).write(to: fixture.documentURL)
        XCTAssertThrowsError(
            try PreviewLocalFileReader.read(fixture.documentURL, expected: snapshot)
        ) { error in
            XCTAssertEqual(error as? PreviewLocalFileError, .changedDuringRead)
        }

        let symlink = fixture.root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: fixture.documentURL
        )
        XCTAssertThrowsError(try PreviewLocalFileSnapshot.capture(symlink)) { error in
            XCTAssertEqual(error as? PreviewLocalFileError, .notRegularFile)
        }

        let symlinkTarget = fixture.root.appendingPathComponent("symlink-target.md")
        try Data("symlink replacement".utf8).write(to: symlinkTarget)
        try FileManager.default.removeItem(at: fixture.documentURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.documentURL,
            withDestinationURL: symlinkTarget
        )
        XCTAssertThrowsError(
            try PreviewLocalFileReader.read(fixture.documentURL, expected: snapshot)
        ) { error in
            XCTAssertEqual(error as? PreviewLocalFileError, .unavailable)
        }
    }

    func testFrozenMarkdownOpensAsUntitledCopyAndCarriesExactDecodedFragment() throws {
        let document = try FrozenPreviewMarkdownDocument.make(
            data: Data("# Café\n\nbody\n".utf8),
            headingFragment: "café"
        )

        XCTAssertEqual(document.text, "# Café\n\nbody\n")
        XCTAssertEqual(document.initialHeadingFragment, "café")
        XCTAssertNil(document.openedFileData)
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

        let reloadEnvelope = try await session.prepareReload(snapshot)
        let outsideURL = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data("outside marker\n".utf8).write(to: outsideURL)
        try FileManager.default.removeItem(at: fixture.documentURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.documentURL,
            withDestinationURL: outsideURL
        )
        do {
            _ = try await session.commitReload(reloadEnvelope)
            XCTFail("Expected a replaced reload path to invalidate the decision")
        } catch {
            XCTAssertEqual(error as? DocumentFileSafetyError, .staleDecision)
        }
        XCTAssertTrue(session.hasUncommittedChanges)

        try FileManager.default.removeItem(at: fixture.documentURL)
        try external.write(to: fixture.documentURL)

        let result = try await session.reload(snapshot)
        XCTAssertEqual(result.data, external)
        XCTAssertEqual(result.decoded.text, "external 🌍\n")

        let editor = MarkdownSourceEditorSession()
        editor.textView.string = "local edit\n"
        let formatted = await editor.applyEngineFormat(
            .bold,
            expectedText: editor.textView.string,
            selectedUTF16Range: NSRange(location: 0, length: 5),
            actionName: "粗体格式"
        )
        XCTAssertTrue(formatted)
        XCTAssertTrue(editor.textView.engineCanUndo)
        XCTAssertFalse(editor.textView.undoManager?.canUndo == true)
        editor.resetAfterExternalReload(result.decoded.text)
        try await waitForEditorCondition { !editor.textView.engineCanUndo }
        XCTAssertEqual(editor.textView.string, "external 🌍\n")
        XCTAssertFalse(editor.textView.engineCanUndo)
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
