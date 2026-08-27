import AppKit
import SwiftUI
import XCTest
@testable import Inflow

final class DocumentRecoveryTests: XCTestCase {
    func testChangedOriginalRecoveryPromptUsesFrozenSafeActions() {
        XCTAssertEqual(RecoveryOriginalChangePrompt.title, "恢复内容不会覆盖原文件")
        XCTAssertEqual(
            RecoveryOriginalChangePrompt.message,
            "原文件已经变化。请比较后将恢复内容作为未命名文档打开或另存。"
        )
        XCTAssertEqual(RecoveryOriginalChangePrompt.compareTitle, "查看差异…")
        XCTAssertEqual(RecoveryOriginalChangePrompt.openTitle, "打开恢复文档")
        XCTAssertEqual(RecoveryOriginalChangePrompt.saveAsTitle, "另存为…")
        XCTAssertEqual(RecoveryOriginalChangePrompt.closeTitle, "关闭")
    }

    func testOnlyReadableDifferentDiskContentIsClassifiedAsChangedOriginal() {
        let url = URL(fileURLWithPath: "/tmp/note.md")

        XCTAssertTrue(
            RecoveryDiskPreview.readable(url, text: "disk", matchesRecovery: false)
                .originalHasChanged
        )
        XCTAssertFalse(
            RecoveryDiskPreview.readable(url, text: "same", matchesRecovery: true)
                .originalHasChanged
        )
        XCTAssertFalse(RecoveryDiskPreview.missing(url).originalHasChanged)
        XCTAssertFalse(RecoveryDiskPreview.unavailable(url).originalHasChanged)
        XCTAssertFalse(RecoveryDiskPreview.unnamed.originalHasChanged)
    }

    @MainActor
    func testRecoveryProtectionPromptUsesFrozenSafeExitCopy() {
        XCTAssertEqual(RecoveryProtectionPrompt.title, "恢复保护暂时不可用")
        XCTAssertEqual(
            DocumentRecoveryCoordinator.degradedProtectionMessage,
            "你仍可以手动保存 Markdown 文件。在保护恢复前，请避免关闭未保存文档。"
        )
        XCTAssertEqual(RecoveryProtectionPrompt.retryTitle, "重试保护")
        XCTAssertEqual(RecoveryProtectionPrompt.continueTitle, "继续写作")
    }

    func testRecoveryRecordRoundTripsDocumentPropertiesAndWorkspaceState() throws {
        let document = MarkdownDocument(
            text: "# 恢复 🌍\n\n正文\n",
            properties: MarkdownFileProperties(
                hasUTF8BOM: true,
                lineEnding: .crlf
            )
        )
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: document,
            originalURL: URL(fileURLWithPath: "/Users/writer/稿件.md"),
            selectedUTF16Range: NSRange(location: 2, length: 4),
            viewMode: .preview,
            verticalScrollOffset: 128,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DocumentRecoveryRecord.self, from: data)
        let restored = try decoded.restoredDocument()

        XCTAssertEqual(restored.text, document.text)
        XCTAssertEqual(restored.properties, document.properties)
        XCTAssertEqual(restored.restorationState?.selectedUTF16Location, 2)
        XCTAssertEqual(restored.restorationState?.selectedUTF16Length, 4)
        XCTAssertEqual(restored.restorationState?.viewModeRawValue, EditorViewMode.preview.rawValue)
        XCTAssertEqual(restored.restorationState?.verticalScrollOffset, 128)
    }

    func testStoreKeepsOnlyContentNewerThanTheExactDiskDocument() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let documentURL = fixture.root.appendingPathComponent("note.md")
        let savedDocument = MarkdownDocument(text: "saved\n")
        try savedDocument.encodedFileData().write(to: documentURL)
        let store = DocumentRecoveryStore(rootURL: fixture.recoveryRoot)

        let matching = DocumentRecoveryRecord(
            id: UUID(),
            document: savedDocument,
            originalURL: documentURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let matchingOutcome = try await store.reconcile(matching)
        let initiallyLoaded = try await store.load()
        XCTAssertEqual(matchingOutcome, .removedBecauseSaved)
        XCTAssertTrue(initiallyLoaded.records.isEmpty)

        let changed = DocumentRecoveryRecord(
            id: matching.id,
            document: MarkdownDocument(text: "saved\nlocal edit\n"),
            originalURL: documentURL,
            selectedUTF16Range: NSRange(location: 6, length: 5),
            viewMode: .source,
            verticalScrollOffset: 24
        )
        let changedOutcome = try await store.reconcile(changed)
        let changedLoad = try await store.load()
        XCTAssertEqual(changedOutcome, .stored)
        XCTAssertEqual(changedLoad.records, [changed])
        XCTAssertEqual(try Data(contentsOf: documentURL), Data("saved\n".utf8))
    }

    func testNextLaunchRemovesSnapshotThatACompletedSaveMadeRedundant() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let documentURL = fixture.root.appendingPathComponent("note.md")
        try Data("old\n".utf8).write(to: documentURL)
        let recoveredDocument = MarkdownDocument(text: "saved later\n")
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: recoveredDocument,
            originalURL: documentURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let store = DocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        let initialOutcome = try await store.reconcile(record)
        XCTAssertEqual(initialOutcome, .stored)

        try recoveredDocument.encodedFileData().write(to: documentURL)
        let nextLaunch = try await store.load()

        XCTAssertTrue(nextLaunch.records.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: fixture.recoveryRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnnamedEmptyDocumentIsNotPresentedAsRecovery() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = DocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )

        let outcome = try await store.reconcile(record)
        let loaded = try await store.load()
        XCTAssertEqual(outcome, .removedBecauseEmpty)
        XCTAssertTrue(loaded.records.isEmpty)
    }

    func testLoadExpiresOldRecordsAndQuarantinesCorruptData() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = DocumentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            retentionInterval: 30
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let old = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "old"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0,
            updatedAt: now.addingTimeInterval(-31)
        )
        _ = try await store.reconcile(old)
        try FileManager.default.createDirectory(
            at: fixture.recoveryRoot,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: fixture.recoveryRoot.appendingPathComponent("broken.json")
        )

        let result = try await store.load(now: now)

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.quarantinedRecordCount, 1)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.recoveryRoot.path
        )
        XCTAssertFalse(names.contains("broken.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix("broken.corrupt-") })
    }

    @MainActor
    func testCoordinatorFlushesWithinIntervalAndNormalCloseRemovesSnapshot() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 20_000_000
        )
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "unsaved"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 7, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(record)

        let store = DocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        var protected = try await store.load()
        for _ in 0..<100 where protected.records != [record] {
            try await Task.sleep(for: .milliseconds(10))
            protected = try await store.load()
        }
        XCTAssertEqual(protected.records, [record])

        coordinator.close(record.id)
        var afterClose = try await store.load()
        for _ in 0..<100 where !afterClose.records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            afterClose = try await store.load()
        }
        XCTAssertTrue(afterClose.records.isEmpty)
    }

    @MainActor
    func testCoordinatorLoadsPreviousRunOnceAndDiscardsExplicitly() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "recover me"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let store = DocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        _ = try await store.reconcile(record)
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot)

        await coordinator.loadIfNeeded()

        XCTAssertEqual(coordinator.recoveredRecords, [record])
        XCTAssertTrue(coordinator.claimAutomaticPresentation())
        XCTAssertFalse(coordinator.claimAutomaticPresentation())
        await coordinator.discard(record)
        XCTAssertTrue(coordinator.recoveredRecords.isEmpty)
        let afterDiscard = try await store.load()
        XCTAssertTrue(afterDiscard.records.isEmpty)
    }

    @MainActor
    func testContinuingWritingDismissesDegradedProtectionUntilExplicitRetry() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let unavailableRoot = fixture.root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: unavailableRoot)
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: unavailableRoot,
            intervalNanoseconds: 5_000_000
        )

        await coordinator.loadIfNeeded()
        XCTAssertEqual(
            coordinator.protectionErrorMessage,
            DocumentRecoveryCoordinator.degradedProtectionMessage
        )

        coordinator.continueWritingWithoutProtection()
        XCTAssertNil(coordinator.protectionErrorMessage)
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "still writing"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(record)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(coordinator.protectionErrorMessage)

        await coordinator.retryProtection()
        XCTAssertEqual(
            coordinator.protectionErrorMessage,
            DocumentRecoveryCoordinator.degradedProtectionMessage
        )
        coordinator.close(record.id)
    }

    func testDiskInspectorDistinguishesMissingMatchingAndChangedFiles() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let documentURL = fixture.root.appendingPathComponent("disk.md")
        let document = MarkdownDocument(text: "same\n")
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: document,
            originalURL: documentURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let inspector = RecoveryDiskInspector()

        let missing = await inspector.inspect(record)
        XCTAssertEqual(missing, .missing(documentURL))

        try document.encodedFileData().write(to: documentURL)
        let matching = await inspector.inspect(record)
        XCTAssertEqual(matching, .readable(documentURL, text: "same\n", matchesRecovery: true))

        try Data("external\n".utf8).write(to: documentURL)
        let changed = await inspector.inspect(record)
        XCTAssertEqual(
            changed,
            .readable(documentURL, text: "external\n", matchesRecovery: false)
        )
    }

    func testInvalidWorkspaceRangeCannotBecomeARecoveredDocument() {
        let text = "hello"
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: text),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: text.utf16.count + 1, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )

        XCTAssertThrowsError(try record.restoredDocument()) { error in
            XCTAssertEqual(error as? DocumentRecoveryError, .invalidRecord)
        }
    }

    @MainActor
    func testEditorSessionRestoresSelectionAndVerticalScroll() {
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        session.textView.frame = NSRect(x: 0, y: 0, width: 400, height: 2_000)
        session.textView.string = String(repeating: "line of text\n", count: 200)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.scrollView
        defer { window.orderOut(nil) }

        session.requestRestoration(
            MarkdownRestorationState(
                selectedUTF16Location: 5,
                selectedUTF16Length: 4,
                viewModeRawValue: EditorViewMode.source.rawValue,
                verticalScrollOffset: 120
            )
        )

        XCTAssertEqual(session.textView.selectedRange(), NSRange(location: 5, length: 4))
        XCTAssertEqual(session.selectedUTF16Range, NSRange(location: 5, length: 4))
        XCTAssertEqual(session.verticalScrollOffset, 120, accuracy: 0.5)
        XCTAssertEqual(session.scrollView.contentView.bounds.origin.y, 120, accuracy: 0.5)
    }
}

private struct RecoveryFixture {
    let root: URL
    let recoveryRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        recoveryRoot = root.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
