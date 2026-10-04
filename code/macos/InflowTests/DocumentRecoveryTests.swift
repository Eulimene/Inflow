import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Inflow

final class DocumentRecoveryTests: XCTestCase {
    @MainActor
    func testPlaintextCheckpointArrivesPromptlyAndUnchangedSnapshotsDoNotRewrite() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot, usesPlaintext: true)
        let record = recoveryRecord(text: "first draft", updatedAt: Date())
        coordinator.update(record)
        defer { coordinator.close(record.id) }
        let path = fixture.recoveryRoot.appendingPathComponent(record.id.uuidString + ".json")
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: path.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "First checkpoint must not wait for the old five-second timer")
        let before = try Data(contentsOf: path)
        let modified = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let repeated = DocumentRecoveryRecord(id: record.id, document: MarkdownDocument(text: record.text),
            originalURL: nil, selectedUTF16Range: NSRange(location: record.selectedUTF16Location, length: record.selectedUTF16Length),
            viewMode: try XCTUnwrap(EditorViewMode(rawValue: record.viewModeRawValue)),
            verticalScrollOffset: record.verticalScrollOffset, updatedAt: Date(timeIntervalSinceNow: 1))
        coordinator.update(repeated)
        for _ in 0..<3 { await coordinator.flush(record.id) }
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        let changed = DocumentRecoveryRecord(id: record.id, document: MarkdownDocument(text: "newer draft"),
            originalURL: nil, selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        coordinator.update(changed)
        await coordinator.flush(record.id)
        XCTAssertEqual(try JSONDecoder().decode(DocumentRecoveryRecord.self, from: Data(contentsOf: path)).text, "newer draft")
    }

    @MainActor
    func testBackgroundCheckpointsDoNotPublishUnchangedPresentationState() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot, usesPlaintext: true)
        let record = recoveryRecord(text: "draft remains durable while a menu is open", updatedAt: Date())
        coordinator.update(record)
        defer { coordinator.close(record.id) }
        var notifications = 0
        let subscription = coordinator.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<3 { await coordinator.flush(record.id) }
        XCTAssertEqual(notifications, 0, "A successful checkpoint must not rebuild the scene and native Window menu")
        let loaded = try await PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot).load()
        XCTAssertEqual(loaded.records.map(\.text), [record.text])

        let blockedRoot = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedRoot)
        let blocked = DocumentRecoveryCoordinator(rootURL: blockedRoot, usesPlaintext: true)
        blocked.update(record)
        var repeatedWarnings = 0
        let warningSubscription = blocked.objectWillChange.sink { repeatedWarnings += 1 }
        defer { warningSubscription.cancel() }
        for _ in 0..<3 { blocked.update(record) }
        XCTAssertEqual(repeatedWarnings, 0, "An unchanged failure must not refresh menus every checkpoint")
        XCTAssertNotNil(blocked.protectionErrorMessage)
        try FileManager.default.removeItem(at: blockedRoot)
        blocked.update(record)
        await blocked.flush(record.id)
        XCTAssertNil(blocked.protectionErrorMessage)
        XCTAssertEqual(repeatedWarnings, 1, "A real recovery must still clear the warning in the UI")
        blocked.close(record.id)
    }

    @MainActor
    func testStartupValidatesBeforePublishingAndSlowDraftDoesNotBlockReadyDraft() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let first = recoveryRecord(text: "slow background draft", updatedAt: Date())
        let second = recoveryRecord(text: "selected draft 😀", updatedAt: Date())
        try temporary.write(second)
        try temporary.write(first)
        let gate = RecoveryReconcileGate()
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true,
            beforeStartupRead: { placeholder in
                XCTAssertFalse(Thread.isMainThread)
                if placeholder.id == first.id { await gate.suspendFirstCommit() }
            })
        var tabs: [MarkdownDocument] = []
        let fastPublished = expectation(description: "Ready draft appears while slow candidate is still private")
        let slowPublished = expectation(description: "Slow draft appears only after validation")
        await coordinator.beginStartupRestoration {
            tabs.append($0)
            if $0.recoveryPlaceholder?.id == second.id { fastPublished.fulfill() }
            if $0.recoveryPlaceholder?.id == first.id { slowPublished.fulfill() }
        }
        await gate.waitUntilSuspended()
        await fulfillment(of: [fastPublished], timeout: 2)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.recoveryPlaceholder?.title, second.displayName)
        XCTAssertTrue(tabs.allSatisfy { $0.text.isEmpty && $0.recoveryPlaceholder != nil })
        XCTAssertFalse(MarkdownDocumentModificationProjection.isModified(tabs[0]))
        XCTAssertThrowsError(try tabs[0].encodedFileData())
        XCTAssertEqual(try temporary.records().count, 2, "Discovery must not consume checkpoints")
        var editable = MarkdownDocument()
        editable.text = "typing while recovery is suspended"
        XCTAssertEqual(try editable.encodedFileData(), Data(editable.text.utf8))
        let selected = try XCTUnwrap(tabs.compactMap(\.recoveryPlaceholder).first { $0.id == second.id })
        let completed = expectation(description: "Selection bypasses suspended background read")
        let selection = Task { @MainActor in
            let document = await coordinator.materializeStartupDraft(selected)
            completed.fulfill()
            return document
        }
        await fulfillment(of: [completed], timeout: 2)
        await gate.resume()
        await fulfillment(of: [slowPublished], timeout: 2)
        let restored = await selection.value
        XCTAssertEqual(restored?.text, second.text)
        XCTAssertEqual(restored?.recoveryTransfer?.targetRecordID, selected.targetID)
        XCTAssertEqual(try temporary.records().map(\.id), [first.id])
        let heads = try await PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot).load()
        XCTAssertEqual(heads.records.map(\.text), [second.text], "Keep a durable source before consuming temporary copy")
        coordinator.completeStartupDraft(second.id)
        _ = await coordinator.prepareStartupDraft(selected)
        XCTAssertEqual(coordinator.startupPhases[second.id], .opened)
        await coordinator.beginStartupRestoration { _ in XCTFail("Startup must run once") }
        for tab in tabs { coordinator.dismissStartupDraft(try XCTUnwrap(tab.recoveryPlaceholder).id) }
    }

    @MainActor
    func testStartupClosingPendingTabDiscardsCheckpointAndPreventsLateRecovery() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let record = recoveryRecord(text: "discard on explicit close", updatedAt: Date())
        try temporary.write(record)
        let gate = RecoveryReconcileGate()
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true,
            beforeStartupRead: { _ in await gate.suspendFirstCommit() })
        await coordinator.beginStartupRestoration { _ in XCTFail("Dismissed candidate must never be published") }
        await gate.waitUntilSuspended()
        let placeholder = try XCTUnwrap(coordinator.startupDrafts.first)
        XCTAssertTrue(coordinator.closeStartupDraft(record.id))
        await gate.resume()
        let restored = await coordinator.materializeStartupDraft(placeholder)
        XCTAssertNil(restored)
        XCTAssertEqual(coordinator.startupPhases[record.id], .unnecessary)
        XCTAssertTrue(try temporary.records().isEmpty)
        let loader = RecoveryStartupLoader(recoveryRoot: fixture.recoveryRoot,
            temporaryRoot: temporary.rootURL, witness: nil)
        XCTAssertTrue(try loader.discover().isEmpty, "Closed placeholders must stay closed after relaunch")
        // Even a previously captured snapshot must not resurrect the dismissed tab.
        try temporary.write(record)
        XCTAssertTrue(try loader.discover().isEmpty)
        XCTAssertNil(try loader.prepare(placeholder))
        let store = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        do {
            _ = try await store.claimStartup(record, targetRecordID: placeholder.targetID)
            XCTFail("A delayed claim must not resurrect an explicitly closed draft")
        } catch { XCTAssertEqual(error as? DocumentRecoveryError, .staleClaim) }
        XCTAssertTrue(try loader.discover().isEmpty)
    }

    @MainActor
    func testStartupCorruptDraftDoesNotBlockGoodDraftAndCanRetry() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let good = recoveryRecord(text: "good draft", updatedAt: Date())
        let repaired = recoveryRecord(text: "repaired draft", updatedAt: Date())
        try temporary.write(good)
        let corruptURL = temporary.rootURL.appendingPathComponent(repaired.id.uuidString + ".json")
        try Data("unfinished JSON".utf8).write(to: corruptURL)
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true)
        let published = expectation(description: "Both valid and retryable drafts appear")
        published.expectedFulfillmentCount = 2
        await coordinator.beginStartupRestoration { _ in published.fulfill() }
        await fulfillment(of: [published], timeout: 2)
        let invalid = try XCTUnwrap(coordinator.startupDrafts.first { $0.id == repaired.id })
        let failed = await coordinator.materializeStartupDraft(invalid)
        XCTAssertNil(failed)
        guard case .failed = coordinator.startupPhases[repaired.id] else { return XCTFail("Per-tab error required") }
        XCTAssertEqual(try Data(contentsOf: corruptURL), Data("unfinished JSON".utf8))
        let valid = try XCTUnwrap(coordinator.startupDrafts.first { $0.id == good.id })
        let restored = await coordinator.materializeStartupDraft(valid)
        XCTAssertEqual(restored?.text, good.text)
        XCTAssertNil(coordinator.protectionErrorMessage)
        try temporary.write(repaired)
        coordinator.retryStartupDraft(invalid)
        let retried = await coordinator.materializeStartupDraft(invalid)
        XCTAssertEqual(retried?.text, repaired.text)
    }

    @MainActor
    func testStartupConcurrentSelectionsShareOneClaim() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let record = recoveryRecord(text: "one claim", updatedAt: Date())
        try temporary.write(record)
        let gate = RecoveryReconcileGate()
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true,
            beforeStartupRead: { _ in await gate.suspendFirstCommit() })
        await coordinator.beginStartupRestoration { _ in }
        await gate.waitUntilSuspended()
        let placeholder = try XCTUnwrap(coordinator.startupDrafts.first)
        let first = Task { await coordinator.materializeStartupDraft(placeholder) }
        let second = Task { await coordinator.materializeStartupDraft(placeholder) }
        await gate.resume()
        let a = await first.value, b = await second.value
        XCTAssertEqual(a?.text, record.text)
        XCTAssertEqual(b?.text, record.text)
        XCTAssertEqual(a?.recoveryTransfer, b?.recoveryTransfer)
        XCTAssertEqual(coordinator.startupPhases[record.id], .ready)
        XCTAssertTrue(try temporary.records().isEmpty)
    }

    func testStartupClaimCannotOverwriteAClaimMadeAfterBackgroundRead() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let record = recoveryRecord(text: "do not reclaim", updatedAt: Date())
        let store = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        try await store.importTemporaryDraft(record)
        let target = UUID()
        _ = try await store.claim(record, targetRecordID: target)
        do {
            _ = try await store.claimStartup(record, targetRecordID: UUID())
            XCTFail("A background snapshot must not overwrite another claim")
        } catch { XCTAssertEqual(error as? DocumentRecoveryError, .staleClaim) }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.records.first?.transferTargetRecordID, target)
    }

    @MainActor
    func testStartupDiscoveryDeduplicatesFilesAndKeepsSavedDraftUntouched() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let store = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        let original = fixture.root.appendingPathComponent("saved.md")
        let record = DocumentRecoveryRecord(id: UUID(), document: MarkdownDocument(text: "saved"), originalURL: original,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        try Data(record.text.utf8).write(to: original)
        try temporary.write(record)
        try await store.importTemporaryDraft(record)
        let closed = recoveryRecord(text: "closed", updatedAt: Date())
        try await store.importTemporaryDraft(closed)
        _ = try store.markSessionClosed(closed.id, generation: 1)
        let loader = RecoveryStartupLoader(recoveryRoot: fixture.recoveryRoot, temporaryRoot: temporary.rootURL, witness: nil)
        let placeholders = try loader.discover()
        XCTAssertEqual(placeholders.count, 1)
        XCTAssertEqual(placeholders.first?.locations.count, 2)
        XCTAssertNil(try loader.prepare(XCTUnwrap(placeholders.first)))
        XCTAssertEqual(try temporary.records(), [record])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "saved")
        let empty = recoveryRecord(text: "", updatedAt: Date())
        try temporary.write(empty)
        // Retained checkpoints must not flash as tabs on this or a later launch.
        for _ in 0..<2 {
            let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
                temporaryDraftStore: temporary, usesPlaintext: true)
            await coordinator.beginStartupRestoration { _ in XCTFail("Unnecessary candidate must never appear") }
            for _ in 0..<200 where !coordinator.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(coordinator.isLoaded)
            XCTAssertEqual(coordinator.startupPhases[record.id], .unnecessary)
            XCTAssertEqual(coordinator.startupPhases[empty.id], .unnecessary)
        }
        XCTAssertEqual(Set(try temporary.records().map(\.id)), Set([record.id, empty.id]),
            "Filtering presentation must not delete recovery data")
    }


    @MainActor
    func testStartupClearAllCancelsPendingReadsWithoutRecreatingDrafts() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let record = recoveryRecord(text: "clear pending draft", updatedAt: Date())
        try temporary.write(record)
        let gate = RecoveryReconcileGate()
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true,
            beforeStartupRead: { _ in await gate.suspendFirstCommit() })
        await coordinator.beginStartupRestoration { _ in XCTFail("Dismissed candidate must never be published") }
        await gate.waitUntilSuspended()
        let placeholder = try XCTUnwrap(coordinator.startupDrafts.first)
        try await coordinator.removeAllRecoveryContent()
        await gate.resume()
        let restored = await coordinator.materializeStartupDraft(placeholder)
        XCTAssertNil(restored)
        XCTAssertTrue(try temporary.records().isEmpty)
        let loaded = try await PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot).load()
        XCTAssertTrue(loaded.records.isEmpty)
    }

    @MainActor
    func testSelectedRecoveryDoesNotCreateASecondNativeTabStrip() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        _ = NSApplication.shared
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let record = recoveryRecord(text: "background tab", updatedAt: Date())
        try temporary.write(record)
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true)
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let pending = NSWindow(contentRect: anchor.frame,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let anchorDocument = NSDocument(), pendingDocument = NSDocument()
        anchorDocument.addWindowController(NSWindowController(window: anchor))
        pendingDocument.addWindowController(NSWindowController(window: pending))
        defer { anchor.orderOut(nil); pending.orderOut(nil) }
        anchor.makeKeyAndOrderFront(nil)
        let published = expectation(description: "Verified draft is published")
        await coordinator.beginStartupRestoration(anchor: anchor) { document in
            guard let placeholder = document.recoveryPlaceholder else { return XCTFail("Missing placeholder") }
            pending.makeKeyAndOrderFront(nil)
            coordinator.attachStartupWindow(pending, placeholder: placeholder)
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 2)
        XCTAssertNil(anchor.tabbedWindows)
        XCTAssertEqual(pending.tabbingMode, .disallowed)
        XCTAssertEqual(pending.title, record.displayName)
        for placeholder in coordinator.startupDrafts { coordinator.dismissStartupDraft(placeholder.id) }
    }

    func testProcessActivationTakesPriorityWithoutWaitingForLivePeer() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("Owners")
        let first = DocumentProcessWitness(directory: directory, instance: UUID(), isAlive: { $0 != 99 })
        let second = DocumentProcessWitness(directory: directory, instance: UUID(), isAlive: { $0 != 99 })
        let recordID = UUID()
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 1, recoveryIDs: [recordID]))
        XCTAssertTrue(first.isCurrentWriter)
        try second.publish(DocumentProcessClaim(instance: second.instance, pid: 2, activatedAt: 2, recoveryIDs: []))
        XCTAssertFalse(first.isCurrentWriter)
        XCTAssertTrue(second.isCurrentWriter)
        XCTAssertTrue(second.isLiveRecovery(recordID))
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 3, recoveryIDs: [recordID]))
        XCTAssertTrue(first.isCurrentWriter)
        // Publishing old metadata cannot steal priority from a newer activation.
        try second.publish(DocumentProcessClaim(instance: second.instance, pid: 2, activatedAt: 2, recoveryIDs: [UUID()]))
        XCTAssertTrue(first.isCurrentWriter)
        let dead = DocumentProcessWitness(directory: directory, instance: UUID())
        try dead.publish(DocumentProcessClaim(instance: dead.instance, pid: 99, activatedAt: 100, recoveryIDs: []))
        XCTAssertTrue(first.isCurrentWriter)
    }

    func testSupersededRecoveryWriteCannotOverwriteNewOwner() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("Owners")
        let first = DocumentProcessWitness(directory: directory, instance: UUID(), isAlive: { _ in true })
        let second = DocumentProcessWitness(directory: directory, instance: UUID(), isAlive: { _ in true })
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 1, recoveryIDs: []))
        let gate = RecoveryReconcileGate()
        let older = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot, witness: first,
            beforeReconcileCommit: { _ in await gate.suspendFirstCommit() })
        let newer = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot, witness: second)
        let id = UUID()
        let stale = DocumentRecoveryRecord(id: id, document: MarkdownDocument(text: "old process"), originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        let current = DocumentRecoveryRecord(id: id, document: MarkdownDocument(text: "new owner"), originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        let write = Task { try await older.reconcile(stale) }
        await gate.waitUntilSuspended()
        try second.publish(DocumentProcessClaim(instance: second.instance, pid: 2, activatedAt: 2, recoveryIDs: []))
        _ = try await newer.reconcile(current)
        await gate.resume()
        do { _ = try await write.value; XCTFail("The old writer must stand down") }
        catch { XCTAssertEqual(error as? DocumentRecoveryError, .supersededProcess) }
        let loaded = try await newer.load()
        XCTAssertEqual(loaded.records.map(\.text), ["new owner"])
        do { try await older.remove(id); XCTFail("Old process must not delete the new head") }
        catch { XCTAssertEqual(error as? DocumentRecoveryError, .supersededProcess) }
    }

    @MainActor
    func testPassiveRecoveryDoesNotWarnOrClaimLivePeerDrafts() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("Owners")
        let first = DocumentProcessWitness(directory: directory, instance: UUID(), isAlive: { _ in true })
        let second = DocumentProcessWitness(directory: directory, instance: UUID(), isAlive: { _ in true })
        let record = DocumentRecoveryRecord(id: UUID(), document: MarkdownDocument(text: "live peer text"), originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 1, recoveryIDs: [record.id]))
        let store = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot, witness: first)
        _ = try await store.reconcile(record)
        try second.publish(DocumentProcessClaim(instance: second.instance, pid: 2, activatedAt: 2, recoveryIDs: []))
        let passive = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot, keyProvider: fixture.keyProvider, processWitness: first)
        passive.update(record)
        await passive.loadIfNeeded()
        await passive.flush(record.id)
        XCTAssertNil(passive.protectionErrorMessage)
        let owner = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot, witness: second)
        let whileLive = try await owner.load()
        XCTAssertTrue(whileLive.records.isEmpty)
        // Once the peer closes its document, its retained draft can be restored.
        try first.publish(DocumentProcessClaim(instance: first.instance, pid: 1, activatedAt: 1, recoveryIDs: []))
        let afterClose = try await owner.load()
        XCTAssertEqual(afterClose.records.map(\.text), [record.text])
        passive.close(record.id)
    }

    func testPlaintextRecoveryRoundTripsAndRejectsLateClosedWrites() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let gate = RecoveryReconcileGate()
        let store = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot,
            beforeReconcileCommit: { _ in await gate.suspendFirstCommit() })
        let record = DocumentRecoveryRecord(id: UUID(), document: MarkdownDocument(text: "明文草稿"), originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        try await store.importTemporaryDraft(record)
        let file = fixture.recoveryRoot.appendingPathComponent(record.id.uuidString).appendingPathExtension("json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, record.text)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.records, [record])
        try store.markSessionActive(record.id, generation: 1)
        let pending = Task { try await store.reconcile(record) }
        await gate.waitUntilSuspended()
        XCTAssertTrue(try store.markSessionClosed(record.id, generation: 1))
        await gate.resume()
        let result = try await pending.value
        XCTAssertEqual(result, .discardedBecauseClosed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let afterClose = try await store.load()
        XCTAssertTrue(afterClose.records.isEmpty)
        try await store.importTemporaryDraft(record)
        let restored = try await store.load()
        XCTAssertEqual(restored.records, [record])
    }

    @MainActor
    func testPlaintextCoordinatorRestoresOnceAndConsumesSavedDrafts() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let store = PlaintextDocumentRecoveryStore(rootURL: fixture.recoveryRoot)
        let record = DocumentRecoveryRecord(id: UUID(), document: MarkdownDocument(text: "restore without keys"), originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        _ = try await store.reconcile(record)
        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let coordinator = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot,
            temporaryDraftStore: temporary, usesPlaintext: true)
        await coordinator.loadIfNeeded()
        XCTAssertNil(coordinator.protectionErrorMessage)
        let documents = await coordinator.claimDraftsForAutomaticRestoration()
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(document.text, record.text)
        let repeated = await coordinator.claimDraftsForAutomaticRestoration()
        XCTAssertTrue(repeated.isEmpty)
        let targetID = try XCTUnwrap(document.recoveryTransfer?.targetRecordID)
        let target = DocumentRecoveryRecord(id: targetID, document: document, originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        coordinator.update(target)
        await coordinator.flush(targetID)
        let transferred = try await store.load()
        XCTAssertEqual(transferred.records.map(\.id), [targetID])
        try temporary.write(target)
        coordinator.close(targetID, discardingDraft: true)
        XCTAssertTrue(try temporary.records().isEmpty)
        let loader = RecoveryStartupLoader(recoveryRoot: fixture.recoveryRoot,
            temporaryRoot: temporary.rootURL, witness: nil)
        XCTAssertTrue(try loader.discover().isEmpty)

        // Closing immediately after restoration must also retire the claimed
        // source, even before the new editor has flushed its first revision.
        let earlySource = recoveryRecord(text: "close before first save", updatedAt: Date())
        try await store.importTemporaryDraft(earlySource)
        let earlyTargetID = UUID()
        let earlyTransfer = try await store.claim(earlySource, targetRecordID: earlyTargetID)
        let earlyDocument = try earlySource.restoredDocument(transfer: earlyTransfer)
        let earlyTarget = DocumentRecoveryRecord(id: earlyTargetID, document: earlyDocument, originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        try temporary.write(earlySource)
        try temporary.write(earlyTarget)
        coordinator.update(earlyTarget)
        coordinator.close(earlyTargetID, discardingDraft: true)
        XCTAssertTrue(try loader.discover().isEmpty)
        XCTAssertTrue(try temporary.records().isEmpty)

        // Quit preserves the tabs that were still open, including the latest
        // synchronous checkpoint rather than the older background snapshot.
        let retained = recoveryRecord(text: "still open on quit", updatedAt: Date())
        coordinator.update(retained)
        await coordinator.flush(retained.id)
        try temporary.write(retained)
        coordinator.close(retained.id)
        let reopened = try loader.discover()
        XCTAssertEqual(reopened.map(\.id), [retained.id])
        XCTAssertEqual(try loader.prepare(XCTUnwrap(reopened.first))?.document.text, retained.text)
        let closed = try await store.load()
        XCTAssertTrue(closed.records.isEmpty)
        let file = fixture.root.appendingPathComponent("saved.md")
        let saved = DocumentRecoveryRecord(id: UUID(), document: MarkdownDocument(text: "now saved"), originalURL: file,
            selectedUTF16Range: NSRange(location: 0, length: 0), viewMode: .source, verticalScrollOffset: 0)
        _ = try await store.reconcile(saved)
        try Data(saved.text.utf8).write(to: file)
        let afterSave = try await store.load()
        XCTAssertTrue(afterSave.records.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), saved.text)
        let corrupt = fixture.recoveryRoot.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try Data("unfinished JSON".utf8).write(to: corrupt)
        let invalid = try await store.load()
        XCTAssertEqual(invalid.quarantinedRecordCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testRuntimeProfileKeepsTestsAndDebugBuildsOffTheProductionKeychain() {
        XCTAssertEqual(
            DocumentRecoveryRuntime.profile(
                environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
                isDebugBuild: false
            ),
            .automatedTest
        )
        XCTAssertEqual(
            DocumentRecoveryRuntime.profile(environment: [:], isDebugBuild: true),
            .development
        )
        XCTAssertEqual(
            DocumentRecoveryRuntime.profile(environment: [:], isDebugBuild: false),
            .production
        )
    }

#if DEBUG
    func testDevelopmentRecoveryKeyIsPersistentPrivateAndDoesNotUseKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-development-key-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let keyURL = root.appendingPathComponent(".development-recovery-key")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = DevelopmentDocumentRecoveryKeyProvider(keyURL: keyURL)

        XCTAssertNil(try provider.loadKey())
        let created = try provider.createKey().withUnsafeBytes { Data($0) }
        let loaded = try XCTUnwrap(provider.loadKey()).withUnsafeBytes { Data($0) }
        XCTAssertEqual(created.count, 32)
        XCTAssertEqual(loaded, created)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        try provider.removeKey()
        XCTAssertNil(try provider.loadKey())
    }
#endif

    func testRecoveryCenterCopyDoesNotInventDiskOrdering() {
        XCTAssertEqual(RecoveryCenterPrompt.title, "恢复未保存的文档")
        XCTAssertEqual(
            RecoveryCenterPrompt.message,
            "上次 Inflow 未正常关闭。以下内容为恢复区暂存副本，尚未写入原文件；可打开或与当前磁盘版本比较。"
        )
        XCTAssertFalse(RecoveryCenterPrompt.message.contains("比最近磁盘内容更新"))
    }

    func testChangedOriginalRecoveryPromptUsesFrozenSafeActions() {
        XCTAssertEqual(RecoveryOriginalChangePrompt.title, "原文件已变化")
        XCTAssertEqual(
            RecoveryOriginalChangePrompt.message,
            "暂存副本尚未写入原文件。请比较后将它作为未命名文档打开，或另存到你确认的位置。"
        )
        XCTAssertEqual(RecoveryOriginalChangePrompt.compareTitle, "查看差异…")
        XCTAssertEqual(RecoveryOriginalChangePrompt.openTitle, "打开恢复文档")
        XCTAssertEqual(RecoveryOriginalChangePrompt.saveAsTitle, "另存为…")
        XCTAssertEqual(RecoveryOriginalChangePrompt.closeTitle, "关闭")
    }

    func testClearAllPromptStatesDestructiveScopeAndMarkdownExclusion() {
        XCTAssertEqual(RecoveryClearAllPrompt.title, "清除全部恢复内容？")
        XCTAssertEqual(RecoveryClearAllPrompt.actionTitle, "清除全部")
        XCTAssertEqual(RecoveryClearAllPrompt.buttonTitle, "清除全部恢复内容…")
        XCTAssertTrue(RecoveryClearAllPrompt.message.contains("关联的本机保护密钥"))
        XCTAssertTrue(RecoveryClearAllPrompt.message.contains("后续修改会建立新的保护"))
        XCTAssertTrue(RecoveryClearAllPrompt.message.contains("Markdown 文件、资源和已导出文件不会被删除或改写"))
    }

    func testOnlyReadableDifferentDiskContentIsClassifiedAsChangedOriginal() {
        let url = URL(fileURLWithPath: "/tmp/note.md")

        XCTAssertTrue(
            RecoveryDiskPreview.readable(
                url,
                text: "disk",
                relationship: .divergedOrUnknown
            )
                .originalHasChanged
        )
        XCTAssertFalse(
            RecoveryDiskPreview.readable(
                url,
                text: "same",
                relationship: .sameAsRecovery
            )
                .originalHasChanged
        )
        XCTAssertFalse(
            RecoveryDiskPreview.readable(
                url,
                text: "saved base",
                relationship: .sameAsCommittedBase
            )
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

    func testExactLifecycleSaveAdvancesRecoveryCommittedBaseButSaveCopyDoesNot() throws {
        let initialData = Data("initial\n".utf8)
        var document = try MarkdownDocument(fileData: initialData)
        document.text = "saved revision\n"
        let savedData = try document.encodedFileData()
        let saveEnvelope = SaveEnvelope(
            revision: 2,
            bytes: savedData,
            sourceURL: URL(fileURLWithPath: "/tmp/source.md"),
            targetURL: URL(fileURLWithPath: "/tmp/source.md"),
            targetExpectation: .absent,
            operation: .save
        )

        document.adoptRecoveryCommittedSave(saveEnvelope)
        document.text = "saved revision\nnewer local edit\n"
        let recovery = DocumentRecoveryRecord(
            id: UUID(),
            document: document,
            originalURL: saveEnvelope.targetURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        XCTAssertEqual(recovery.relationship(toDiskData: savedData), .sameAsCommittedBase)

        var copyDocument = try MarkdownDocument(fileData: initialData)
        copyDocument.text = "copy only\n"
        let copyData = try copyDocument.encodedFileData()
        copyDocument.adoptRecoveryCommittedSave(
            SaveEnvelope(
                revision: 2,
                bytes: copyData,
                sourceURL: URL(fileURLWithPath: "/tmp/source.md"),
                targetURL: URL(fileURLWithPath: "/tmp/copy.md"),
                targetExpectation: .absent,
                operation: .saveCopy
            )
        )
        copyDocument.text = "copy only\nnewer local edit\n"
        let copyRecovery = DocumentRecoveryRecord(
            id: UUID(),
            document: copyDocument,
            originalURL: URL(fileURLWithPath: "/tmp/source.md"),
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        XCTAssertEqual(
            copyRecovery.relationship(toDiskData: initialData),
            .sameAsCommittedBase
        )
        XCTAssertEqual(
            copyRecovery.relationship(toDiskData: copyData),
            .divergedOrUnknown
        )
    }

    @MainActor
    func testExactSaveRefreshPersistsNewCommittedBaseWithLaterEdits() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let documentURL = fixture.root.appendingPathComponent("note.md")
        let initialData = Data("initial\n".utf8)
        try initialData.write(to: documentURL)
        var document = try MarkdownDocument(fileData: initialData)
        document.text = "saved revision\n"
        let savedData = try document.encodedFileData()
        let envelope = SaveEnvelope(
            revision: 2,
            bytes: savedData,
            sourceURL: documentURL,
            targetURL: documentURL,
            targetExpectation: try .capture(documentURL),
            operation: .save
        )
        let id = UUID()
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 60_000_000_000,
            keyProvider: fixture.keyProvider
        )

        document.adoptRecoveryCommittedSave(envelope)
        document.text = "saved revision\nnewer local edit\n"
        try savedData.write(to: documentURL)
        coordinator.update(
            DocumentRecoveryRecord(
                id: id,
                document: document,
                originalURL: envelope.targetURL,
                selectedUTF16Range: NSRange(location: 0, length: 0),
                viewMode: .source,
                verticalScrollOffset: 0
            )
        )
        await coordinator.flush(id)

        let refreshed = try await fixture.makeStore().load()
        let persisted = try XCTUnwrap(refreshed.records.first)
        XCTAssertEqual(refreshed.records.count, 1)
        XCTAssertEqual(persisted.text, document.text)
        XCTAssertEqual(persisted.relationship(toDiskData: savedData), .sameAsCommittedBase)
    }

    @MainActor
    func testAutomaticSaveEnvelopeAdvancesRecoveryBaseWithoutAdoptingLaterEdit()
        async throws
    {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let documentURL = fixture.root.appendingPathComponent("automatic.md")
        let initialData = Data("initial\n".utf8)
        try initialData.write(to: documentURL)
        var document = try MarkdownDocument(fileData: initialData)
        let fileSafety = DocumentFileSafetySession(
            intervalNanoseconds: 60_000_000_000
        )
        fileSafety.update(document: document, fileURL: documentURL)

        document.text = "automatic save A\n"
        fileSafety.update(document: document, fileURL: documentURL)
        let wrapper = try document.fileWrapper(
            existingFile: FileWrapper(regularFileWithContents: initialData)
        )
        let automaticData = try XCTUnwrap(wrapper.regularFileContents)
        try automaticData.write(to: documentURL)

        document.text = "automatic save A\nlater edit B\n"
        fileSafety.update(document: document, fileURL: documentURL)
        await fileSafety.inspectNow()
        let envelope = try XCTUnwrap(fileSafety.automaticSaveCommit)
        XCTAssertEqual(envelope.operation, .automatic)
        XCTAssertEqual(envelope.bytes, automaticData)
        XCTAssertNotEqual(envelope.bytes, try document.encodedFileData())

        document.adoptRecoveryCommittedSave(envelope)
        let id = UUID()
        let record = DocumentRecoveryRecord(
            id: id,
            document: document,
            originalURL: documentURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        XCTAssertEqual(
            record.relationship(toDiskData: automaticData),
            .sameAsCommittedBase
        )

        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 60_000_000_000,
            keyProvider: fixture.keyProvider
        )
        coordinator.update(record)
        await coordinator.flush(id)
        let loaded = try await fixture.makeStore().load()
        let persisted = try XCTUnwrap(loaded.records.first)
        XCTAssertEqual(persisted.text, document.text)
        XCTAssertEqual(
            persisted.relationship(toDiskData: automaticData),
            .sameAsCommittedBase
        )
        fileSafety.stopMonitoring()
    }

    func testStoreKeepsOnlyContentNewerThanTheExactDiskDocument() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let documentURL = fixture.root.appendingPathComponent("note.md")
        let savedDocument = MarkdownDocument(text: "saved\n")
        try savedDocument.encodedFileData().write(to: documentURL)
        let store = fixture.makeStore()

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
        let store = fixture.makeStore()
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
        let store = fixture.makeStore()
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
            retentionInterval: 30,
            keyProvider: fixture.keyProvider
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
        let legacyPlaintext = Data("not-json-TOP-SECRET-legacy-body".utf8)
        try legacyPlaintext.write(
            to: fixture.recoveryRoot.appendingPathComponent("broken.json")
        )

        let result = try await store.load(now: now)

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.quarantinedRecordCount, 1)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.recoveryRoot.path
        )
        XCTAssertFalse(names.contains("broken.json"))
        XCTAssertTrue(names.contains("Quarantine"))
        let quarantinedNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.recoveryRoot.appendingPathComponent("Quarantine").path
        )
        let quarantinedName = try XCTUnwrap(quarantinedNames.first)
        XCTAssertTrue(quarantinedName.hasPrefix("legacy-legacy-corrupt-"))
        let quarantinedData = try Data(
            contentsOf: fixture.recoveryRoot
                .appendingPathComponent("Quarantine")
                .appendingPathComponent(quarantinedName)
        )
        XCTAssertNotEqual(quarantinedData, legacyPlaintext)
        XCTAssertFalse(
            String(decoding: quarantinedData, as: UTF8.self)
                .contains("TOP-SECRET-legacy-body")
        )
    }

    func testLegacyPlaintextIsRemovedWhenEncryptedQuarantineWriteFails() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.recoveryRoot,
            withIntermediateDirectories: true
        )
        let legacyURL = fixture.recoveryRoot.appendingPathComponent("broken.json")
        let secret = Data("invalid-json-private-legacy-content".utf8)
        try secret.write(to: legacyURL)
        let store = fixture.makeStore(
            beforeLegacyQuarantineWrite: {
                throw DocumentRecoveryError.cannotWrite
            }
        )

        let result = try await store.load(now: Date(timeIntervalSince1970: 5_000))

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.quarantinedRecordCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let quarantine = fixture.recoveryRoot.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: quarantine.path).isEmpty
        )
    }

    func testQuarantineRetentionDeletesOnlyItemsOlderThanSevenDays() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let quarantine = fixture.recoveryRoot.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let expired = quarantine.appendingPathComponent("expired.recovery.corrupt")
        let retained = quarantine.appendingPathComponent("retained.recovery.corrupt")
        try Data("expired".utf8).write(to: expired)
        try Data("retained".utf8).write(to: retained)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let sevenDays = DocumentRecoveryStore.Limits.quarantineRetention
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-sevenDays - 1)],
            ofItemAtPath: expired.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-sevenDays + 1)],
            ofItemAtPath: retained.path
        )

        _ = try await DocumentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            quarantineRetentionInterval: sevenDays,
            keyProvider: fixture.keyProvider
        ).load(now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testNewQuarantineRetentionStartsAtIsolationTime() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let sevenDays = DocumentRecoveryStore.Limits.quarantineRetention
        let oldRecord = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "old but still recoverable"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0,
            updatedAt: now.addingTimeInterval(-20 * 24 * 60 * 60)
        )
        let store = DocumentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            quarantineRetentionInterval: sevenDays,
            keyProvider: fixture.keyProvider
        )
        _ = try await store.reconcile(oldRecord, now: oldRecord.updatedAt)
        let oldURL = recoveryFileURL(oldRecord, in: fixture)
        try FileManager.default.setAttributes(
            [.modificationDate: oldRecord.updatedAt],
            ofItemAtPath: oldURL.path
        )
        try fixture.keyProvider.removeKey()

        let isolated = try await store.load(now: now)
        XCTAssertEqual(isolated.quarantinedRecordCount, 1)
        let quarantine = fixture.recoveryRoot.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        let isolatedURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: quarantine,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ).first
        )
        let isolatedAt = try XCTUnwrap(
            isolatedURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        )
        XCTAssertEqual(isolatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)

        _ = try await store.load(now: now.addingTimeInterval(sevenDays - 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedURL.path))
        _ = try await store.load(now: now.addingTimeInterval(sevenDays + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolatedURL.path))
    }

    func testRecoveryEnvelopeEncryptsAllUserDataAndAppliesFileProtection() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let secret = "TOP-SECRET-恢复正文-不应出现在密文中"
        let originalURL = fixture.root.appendingPathComponent("secret-path.md")
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: secret),
            originalURL: originalURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 12
        )
        let store = fixture.makeStore()

        let outcome = try await store.reconcile(record)
        XCTAssertEqual(outcome, .stored)
        let encryptedURL = fixture.recoveryRoot
            .appendingPathComponent(record.id.uuidString)
            .appendingPathExtension("recovery")
        let encrypted = try Data(contentsOf: encryptedURL)
        XCTAssertNil(encrypted.range(of: Data(secret.utf8)))
        XCTAssertNil(encrypted.range(of: Data(originalURL.path.utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: encryptedURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let isExcludedFromBackup = try encryptedURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true
        let systemTemporaryDirectory = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .path
        let isAlreadyOutsideBackupScope = encryptedURL.standardizedFileURL.path
            .hasPrefix(systemTemporaryDirectory + "/")
        XCTAssertTrue(isExcludedFromBackup || isAlreadyOutsideBackupScope)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.records, [record])
    }

    func testEncryptedFileLimitIncludesBase64EnvelopeOverheadAtPlaintextBoundary() {
        let plaintextLimit = DocumentRecoveryStore.Limits.recordBytes
        let exactBase64Length = ((plaintextLimit + 2) / 3) * 4

        XCTAssertGreaterThan(
            DocumentRecoveryStore.Limits.encryptedRecordBytes,
            exactBase64Length * 2
        )
        XCTAssertEqual(
            DocumentRecoveryStore.Limits.encryptedRecordBytes,
            DocumentRecoveryStore.Limits.maximumEncryptedBytes(
                forPlaintextBytes: plaintextLimit
            )
        )
        XCTAssertGreaterThan(
            DocumentRecoveryStore.Limits.encryptedRecordBytes,
            DocumentRecoveryStore.Limits.recordBytes + 1_048_576
        )
    }

    func testOversizedEncryptedFileIsQuarantinedBeforeEnvelopeDecode() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.recoveryRoot,
            withIntermediateDirectories: true
        )
        let oversized = fixture.recoveryRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("recovery")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(
            atOffset: UInt64(DocumentRecoveryStore.Limits.encryptedRecordBytes + 1)
        )
        try handle.close()

        let loaded = try await fixture.makeStore().load()

        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertEqual(loaded.quarantinedRecordCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
    }

    func testQuotaReclamationPurgesExpiredHeadsBeforeSupersededHistory() async throws {
        let fixture = try RecoveryFixture()
        let sizingFixture = try RecoveryFixture()
        defer {
            fixture.remove()
            sizingFixture.remove()
        }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let history = recoveryRecord(
            text: "lineage history",
            updatedAt: now.addingTimeInterval(-10)
        )
        let current = try replacingRecoveryIdentity(
            history,
            id: UUID(),
            lineageID: history.effectiveLineageID,
            epoch: 2,
            revision: 1,
            updatedAt: now.addingTimeInterval(-5)
        )
        let expired = recoveryRecord(
            text: "expired unique head",
            updatedAt: now.addingTimeInterval(-31)
        )
        let incoming = recoveryRecord(text: "incoming head", updatedAt: now)
        let seedStore = fixture.makeStore()
        _ = try await seedStore.reconcile(expired, now: now.addingTimeInterval(-31))
        _ = try await seedStore.reconcile(history, now: now.addingTimeInterval(-10))
        _ = try await seedStore.reconcile(current, now: now.addingTimeInterval(-5))
        _ = try await sizingFixture.makeStore().reconcile(incoming, now: now)

        let currentSize = try recoveryFileSize(current, in: fixture)
        let historySize = try recoveryFileSize(history, in: fixture)
        let incomingSize = try recoveryFileSize(incoming, in: sizingFixture)
        // Keep bounded serialization slack so this test couples to eviction
        // semantics rather than an exact envelope byte count.
        let envelopeEncodingSlack = 256
        XCTAssertGreaterThan(historySize, envelopeEncodingSlack)
        let quota = currentSize + historySize + incomingSize + envelopeEncodingSlack
        let limited = DocumentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            retentionInterval: 30,
            totalByteLimit: quota,
            keyProvider: fixture.keyProvider
        )

        let outcome = try await limited.reconcile(incoming, now: now)
        XCTAssertEqual(outcome, .stored)
        let loaded = try await limited.load(now: now)
        XCTAssertFalse(loaded.records.contains { $0.id == expired.id })
        XCTAssertTrue(loaded.records.contains { $0.id == history.id })
        XCTAssertTrue(loaded.records.contains { $0.id == current.id })
        XCTAssertTrue(loaded.records.contains { $0.id == incoming.id })
    }

    func testQuotaReclamationEvictsOldestSupersededHistoryButKeepsCurrentHeads() async throws {
        let fixture = try RecoveryFixture()
        let sizingFixture = try RecoveryFixture()
        defer {
            fixture.remove()
            sizingFixture.remove()
        }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let history = recoveryRecord(
            text: "same durable lineage bytes",
            updatedAt: now.addingTimeInterval(-20)
        )
        let current = try replacingRecoveryIdentity(
            history,
            id: UUID(),
            lineageID: history.effectiveLineageID,
            epoch: 2,
            revision: 1,
            updatedAt: now.addingTimeInterval(-10)
        )
        let incoming = recoveryRecord(text: "another current head", updatedAt: now)
        let seedStore = fixture.makeStore()
        _ = try await seedStore.reconcile(history, now: now.addingTimeInterval(-20))
        _ = try await seedStore.reconcile(current, now: now.addingTimeInterval(-10))
        _ = try await sizingFixture.makeStore().reconcile(incoming, now: now)
        let currentSize = try recoveryFileSize(current, in: fixture)
        let incomingSize = try recoveryFileSize(incoming, in: sizingFixture)
        let envelopeEncodingSlack = 256
        XCTAssertGreaterThan(try recoveryFileSize(history, in: fixture), envelopeEncodingSlack)
        let quota = currentSize + incomingSize + envelopeEncodingSlack
        let limited = DocumentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            totalByteLimit: quota,
            keyProvider: fixture.keyProvider
        )

        let outcome = try await limited.reconcile(incoming, now: now)
        XCTAssertEqual(outcome, .stored)
        let loaded = try await limited.load(now: now)
        XCTAssertEqual(Set(loaded.records.map(\.id)), Set([current.id, incoming.id]))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recoveryFileURL(history, in: fixture).path
        ))
    }

    func testQuotaNeverEvictsAnotherLineagesUniqueCurrentHead() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 5_000_000)
        let existing = recoveryRecord(text: "unique existing head", updatedAt: now)
        let incoming = recoveryRecord(text: "unique incoming head", updatedAt: now)
        _ = try await fixture.makeStore().reconcile(existing, now: now)
        let existingSize = try recoveryFileSize(existing, in: fixture)
        let limited = DocumentRecoveryStore(
            rootURL: fixture.recoveryRoot,
            totalByteLimit: existingSize,
            keyProvider: fixture.keyProvider
        )

        do {
            _ = try await limited.reconcile(incoming, now: now)
            XCTFail("expected recovery protection to degrade at the quota")
        } catch {
            XCTAssertEqual(error as? DocumentRecoveryError, .quotaExceeded)
        }
        let loaded = try await limited.load(now: now)
        XCTAssertEqual(loaded.records.map(\.id), [existing.id])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recoveryFileURL(incoming, in: fixture).path
        ))
    }

    func testClaimSurvivesSecondCrashUntilTransferredHeadIsDurable() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "only recovery copy"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 2, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        let store = fixture.makeStore()
        _ = try await store.reconcile(source)
        let targetID = UUID()
        let transfer = try await store.claim(source, targetRecordID: targetID)

        // Simulate a second crash before the restored window performs its first flush.
        let afterSecondCrash = try await fixture.makeStore().load()
        let durableSource = try XCTUnwrap(
            afterSecondCrash.records.first(where: { $0.id == source.id })
        )
        XCTAssertEqual(durableSource.transferTargetRecordID, targetID)
        XCTAssertGreaterThan(durableSource.effectiveRevision, source.effectiveRevision)
        XCTAssertNil(afterSecondCrash.records.first(where: { $0.id == targetID }))

        let restoredDocument = try durableSource.restoredDocument(transfer: transfer)
        let target = DocumentRecoveryRecord(
            id: targetID,
            document: restoredDocument,
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 2, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        _ = try await store.reconcile(target)
        let completed = try await store.load()
        XCTAssertEqual(completed.records.map(\.id), [targetID])
        XCTAssertEqual(completed.records.first?.effectiveLineageID, source.effectiveLineageID)
        XCTAssertEqual(completed.records.first?.effectiveEpoch, source.effectiveEpoch + 1)
    }

    func testLoadReconcilesCrashAfterTargetBecameDurableBeforeSourceConsumption() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let source = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "claimed source"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        let seedStore = fixture.makeStore()
        _ = try await seedStore.reconcile(source)
        let targetID = UUID()
        let transfer = try await seedStore.claim(source, targetRecordID: targetID)
        var restored = try source.restoredDocument(transfer: transfer)
        restored.text += " with a newer target head"
        let target = DocumentRecoveryRecord(
            id: targetID,
            document: restored,
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        let interruptedStore = fixture.makeStore { sourceID, durableTargetID in
            XCTAssertEqual(sourceID, source.id)
            XCTAssertEqual(durableTargetID, targetID)
            throw DocumentRecoveryError.cannotRemove
        }

        do {
            _ = try await interruptedStore.reconcile(target)
            XCTFail("expected injected interruption after the target write")
        } catch {
            XCTAssertEqual(error as? DocumentRecoveryError, .cannotRemove)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryFileURL(source, in: fixture).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryFileURL(target, in: fixture).path
        ))

        let reconciled = try await fixture.makeStore().load()
        XCTAssertEqual(reconciled.records.map(\.id), [targetID])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recoveryFileURL(source, in: fixture).path
        ))
    }

    func testTamperingAndMissingKeyQuarantineOldCiphertextWithoutBlockingNewHeads() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let first = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "first secret"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let store = fixture.makeStore()
        _ = try await store.reconcile(first)
        try fixture.keyProvider.removeKey()

        let afterKeyLoss = try await store.load()
        XCTAssertTrue(afterKeyLoss.records.isEmpty)
        XCTAssertEqual(afterKeyLoss.quarantinedRecordCount, 1)

        let second = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "new protected head"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let secondOutcome = try await store.reconcile(second)
        let secondLoad = try await store.load()
        XCTAssertEqual(secondOutcome, .stored)
        XCTAssertEqual(secondLoad.records, [second])

        let secondURL = fixture.recoveryRoot
            .appendingPathComponent(second.id.uuidString)
            .appendingPathExtension("recovery")
        var ciphertext = try Data(contentsOf: secondURL)
        ciphertext[ciphertext.startIndex] ^= 0x01
        try ciphertext.write(to: secondURL)
        let afterTamper = try await store.load()
        XCTAssertTrue(afterTamper.records.isEmpty)
        XCTAssertEqual(afterTamper.quarantinedRecordCount, 1)

        try await store.removeAll()
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)
                .isEmpty
        )
        XCTAssertNil(try fixture.keyProvider.loadKey())
    }

    func testLegacyPlaintextRecordMigratesOnceToEncryptedSchemaTwo() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "legacy body"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                as? [String: Any]
        )
        legacy["schemaVersion"] = 1
        for key in [
            "lineageID", "epoch", "revision", "contentHash", "committedContentHash",
            "transferSourceRecordID", "transferTargetRecordID", "claimedAt",
        ] {
            legacy.removeValue(forKey: key)
        }
        try FileManager.default.createDirectory(
            at: fixture.recoveryRoot,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: legacy).write(
            to: fixture.recoveryRoot
                .appendingPathComponent(record.id.uuidString)
                .appendingPathExtension("json")
        )

        let loaded = try await fixture.makeStore().load()
        let migrated = try XCTUnwrap(loaded.records.first)
        XCTAssertEqual(migrated.schemaVersion, DocumentRecoveryRecord.currentSchemaVersion)
        XCTAssertEqual(migrated.text, record.text)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.recoveryRoot
                    .appendingPathComponent(record.id.uuidString)
                    .appendingPathExtension("recovery").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.recoveryRoot
                    .appendingPathComponent(record.id.uuidString)
                    .appendingPathExtension("json").path
            )
        )
    }

    func testCommittedHashDistinguishesNewerRecoveryFromIndependentDiskChange() throws {
        let savedData = Data("saved base\n".utf8)
        var document = try MarkdownDocument(fileData: savedData)
        document.text = "saved base\nnewer local edit\n"
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: document,
            originalURL: URL(fileURLWithPath: "/tmp/hash-order.md"),
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )

        XCTAssertEqual(record.relationship(toDiskData: savedData), .sameAsCommittedBase)
        XCTAssertEqual(
            record.relationship(toDiskData: try document.encodedFileData()),
            .sameAsRecovery
        )
        XCTAssertEqual(
            record.relationship(toDiskData: Data("independent edit\n".utf8)),
            .divergedOrUnknown
        )
    }

    @MainActor
    func testCoordinatorFlushesWithinIntervalAndNormalCloseRemovesSnapshot() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 20_000_000,
            keyProvider: fixture.keyProvider
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

        let store = fixture.makeStore()
        var protected = try await store.load()
        for _ in 0..<100 where protected.records != [record] {
            try await Task.sleep(for: .milliseconds(10))
            protected = try await store.load()
        }
        XCTAssertEqual(protected.records, [record])

        XCTAssertTrue(coordinator.protectsCurrentContent(record.id,
            document: MarkdownDocument(text: record.text), originalURL: nil))
        coordinator.close(record.id)
        XCTAssertNil(coordinator.protectedRecords[record.id])
        var afterClose = try await store.load()
        for _ in 0..<100 where !afterClose.records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            afterClose = try await store.load()
        }
        XCTAssertTrue(afterClose.records.isEmpty)

        let temporary = TemporaryDocumentDraftStore(rootURL: fixture.root.appendingPathComponent("SessionDrafts"))
        let fresh = DocumentRecoveryRecord(id: record.id, document: MarkdownDocument(text: "刚输入😀"),
            originalURL: nil, selectedUTF16Range: NSRange(location: 5, length: 0), viewMode: .preview, verticalScrollOffset: 23)
        try temporary.write(fresh)
        XCTAssertEqual(try temporary.records(), [fresh])
        let relaunched = DocumentRecoveryCoordinator(rootURL: fixture.recoveryRoot, keyProvider: fixture.keyProvider,
            temporaryDraftStore: temporary)
        await relaunched.loadIfNeeded()
        XCTAssertEqual(relaunched.recoveredRecords.map(\.text), ["刚输入😀"])
        XCTAssertTrue(try temporary.records().isEmpty, "Remove temporary plaintext only after encrypted recovery owns it")
        let restored = await relaunched.claimDraftsForAutomaticRestoration()
        XCTAssertEqual(restored.map(\.text), ["刚输入😀"])
        XCTAssertEqual(restored.first?.restorationState?.selectedUTF16Location, 5)
        XCTAssertEqual(restored.first?.restorationState?.verticalScrollOffset, 23)
        let secondClaim = await relaunched.claimDraftsForAutomaticRestoration()
        XCTAssertTrue(secondClaim.isEmpty)

        // A blocked recovery handoff must leave the temporary draft available for retry.
        let retryRoot = fixture.root.appendingPathComponent("blocked-recovery")
        try Data("blocking file".utf8).write(to: retryRoot)
        try temporary.write(fresh)
        let retrying = DocumentRecoveryCoordinator(rootURL: retryRoot, keyProvider: fixture.keyProvider,
            temporaryDraftStore: temporary)
        await retrying.loadIfNeeded()
        XCTAssertNotNil(retrying.protectionErrorMessage)
        XCTAssertEqual(try temporary.records(), [fresh])
        try FileManager.default.removeItem(at: retryRoot)
        await retrying.retryProtection()
        XCTAssertNil(retrying.protectionErrorMessage)
        XCTAssertEqual(retrying.recoveredRecords.map(\.text), [fresh.text])
        XCTAssertTrue(try temporary.records().isEmpty)
    }

    @MainActor
    func testFlushLoopsUntilAnUpdateArrivingDuringStoreWriteIsDurable() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let gate = RecoveryReconcileGate()
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 60_000_000_000,
            keyProvider: fixture.keyProvider,
            beforeReconcileCommit: { _ in await gate.suspendFirstCommit() }
        )
        let id = UUID()
        let first = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "first pending revision"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(first)
        XCTAssertFalse(coordinator.protectsCurrentContent(id,
            document: MarkdownDocument(text: first.text), originalURL: nil))
        let flush = Task { @MainActor in
            await coordinator.flush(id)
        }
        await gate.waitUntilSuspended()
        XCTAssertTrue(coordinator.protectedRecords.isEmpty, "Starting a write must not claim success")

        let latest = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "latest revision during flush"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 3, length: 0),
            viewMode: .split,
            verticalScrollOffset: 12
        )
        coordinator.update(latest)
        await gate.resume()
        await flush.value

        let loaded = try await fixture.makeStore().load()
        let durable = try XCTUnwrap(loaded.records.first)
        XCTAssertEqual(loaded.records.count, 1)
        XCTAssertEqual(durable.text, latest.text)
        XCTAssertEqual(durable.selectedUTF16Location, latest.selectedUTF16Location)
        XCTAssertGreaterThan(durable.effectiveRevision, first.effectiveRevision)
        XCTAssertTrue(coordinator.protectsCurrentContent(id,
            document: MarkdownDocument(text: latest.text), originalURL: nil))
        XCTAssertFalse(coordinator.protectsCurrentContent(id,
            document: MarkdownDocument(text: first.text), originalURL: nil))
        XCTAssertFalse(coordinator.protectsCurrentContent(id,
            document: MarkdownDocument(text: latest.text + "new edit"), originalURL: nil))
        try await coordinator.removeAllRecoveryContent()
        XCTAssertTrue(coordinator.protectedRecords.isEmpty)
        coordinator.close(id)
    }

    @MainActor
    func testCleanCloseDeletesDraftImmediatelyAndStartupConsumesTombstone() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 60_000_000_000,
            keyProvider: fixture.keyProvider
        )
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "durable until clean-close convergence"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(record)
        await coordinator.flush(record.id)
        let headURL = recoveryFileURL(record, in: fixture)
        let markerURL = closedMarkerURL(record.id, in: fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: headURL.path))

        coordinator.close(record.id)
        try await waitForFile(at: markerURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))

        // A new store models relaunch immediately after the durable close marker.
        let relaunched = try await fixture.makeStore().load()
        XCTAssertTrue(relaunched.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @MainActor
    func testReactivationRemovesTombstoneWithoutRevivingDiscardedDraft()
        async throws
    {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 60_000_000_000,
            keyProvider: fixture.keyProvider
        )
        let id = UUID()
        let original = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "old durable head"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(original)
        await coordinator.flush(id)
        let headURL = recoveryFileURL(original, in: fixture)
        let markerURL = closedMarkerURL(id, in: fixture)

        coordinator.close(id)
        try await waitForFile(at: markerURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))

        let reactivated = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "new in-memory head not flushed yet"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(reactivated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))

        // Simulate a crash before the reactivated session performs its first write.
        let relaunched = try await fixture.makeStore().load()
        XCTAssertTrue(relaunched.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headURL.path))
        coordinator.close(id)
    }

    @MainActor
    func testCloseGenerationCannotDeleteAnImmediatelyReactivatedSession() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 60_000_000_000,
            keyProvider: fixture.keyProvider
        )
        let id = UUID()
        let first = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "first protected head"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(first)
        await coordinator.flush(id)
        let persistedFirst = try await fixture.makeStore().load()
        XCTAssertEqual(persistedFirst.records.map(\.id), [id])

        coordinator.close(id)
        let reactivated = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "reactivated before close removal"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(reactivated)
        for _ in 0 ..< 20 { await Task.yield() }

        let afterStaleClose = try await fixture.makeStore().load()
        // Close retires the old head synchronously. Reactivation must not revive it
        // before the new session has flushed its own content.
        XCTAssertTrue(afterStaleClose.records.isEmpty)
        await coordinator.flush(id)
        let persistedReactivated = try await fixture.makeStore().load()
        XCTAssertEqual(persistedReactivated.records, [reactivated])
    }

    @MainActor
    func testCoordinatorLoadsPreviousRunOnceAndRestoresSilently() async throws {
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
        let store = fixture.makeStore()
        _ = try await store.reconcile(record)
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            keyProvider: fixture.keyProvider
        )

        await coordinator.loadIfNeeded()

        XCTAssertEqual(coordinator.recoveredRecords, [record])
        let restored = await coordinator.claimDraftsForAutomaticRestoration()
        XCTAssertEqual(restored.map(\.text), [record.text])
        let secondAutomaticRestore = await coordinator.claimDraftsForAutomaticRestoration()
        XCTAssertTrue(secondAutomaticRestore.isEmpty)
        XCTAssertTrue(coordinator.recoveredRecords.isEmpty)
        let transferred = try await store.load()
        XCTAssertEqual(transferred.records.count, 1)
        XCTAssertEqual(transferred.records.first?.transferTargetRecordID, restored.first?
            .recoveryTransfer?.targetRecordID)
    }

    @MainActor
    func testCoordinatorClearAllRemovesRecoveryDomainWithoutTouchingMarkdown() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let markdownURL = fixture.root.appendingPathComponent("kept.md")
        let markdown = Data("saved Markdown remains\n".utf8)
        try markdown.write(to: markdownURL)
        let record = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: "unsaved recovery differs\n"),
            originalURL: markdownURL,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        _ = try await fixture.makeStore().reconcile(record)
        let quarantine = fixture.recoveryRoot.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data("isolated bytes".utf8).write(
            to: quarantine.appendingPathComponent("isolated.recovery.corrupt")
        )
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            keyProvider: fixture.keyProvider
        )
        await coordinator.loadIfNeeded()
        XCTAssertEqual(coordinator.recoveredRecords.map(\.id), [record.id])

        try await coordinator.removeAllRecoveryContent()

        XCTAssertTrue(coordinator.recoveredRecords.isEmpty)
        XCTAssertEqual(try Data(contentsOf: markdownURL), markdown)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)
                .isEmpty
        )
        XCTAssertNil(try fixture.keyProvider.loadKey())
    }

    @MainActor
    func testClearAllDoesNotRecreateAnActiveHeadUntilContentChanges() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: fixture.recoveryRoot,
            intervalNanoseconds: 10_000_000,
            keyProvider: fixture.keyProvider
        )
        let id = UUID()
        let record = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "clear this head"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(record)
        await coordinator.flush(id)
        try await coordinator.removeAllRecoveryContent()

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)
                .isEmpty
        )
        XCTAssertNil(try fixture.keyProvider.loadKey())

        let metadataOnlyUpdate = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "clear this head"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 3, length: 0),
            viewMode: .preview,
            verticalScrollOffset: 40
        )
        coordinator.update(metadataOnlyUpdate)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.recoveryRoot.path)
                .isEmpty
        )
        XCTAssertNil(try fixture.keyProvider.loadKey())

        let changed = DocumentRecoveryRecord(
            id: id,
            document: MarkdownDocument(text: "clear this head, then edit"),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 5, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0
        )
        coordinator.update(changed)
        var loaded = try await fixture.makeStore().load()
        for _ in 0..<100 where loaded.records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            loaded = try await fixture.makeStore().load()
        }
        XCTAssertEqual(loaded.records.map(\.text), [changed.text])
        coordinator.close(id)
    }

    @MainActor
    func testContinuingWritingDismissesDegradedProtectionUntilExplicitRetry() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.remove() }
        let unavailableRoot = fixture.root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: unavailableRoot)
        let coordinator = DocumentRecoveryCoordinator(
            rootURL: unavailableRoot,
            intervalNanoseconds: 5_000_000,
            keyProvider: fixture.keyProvider
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
        XCTAssertTrue(coordinator.protectedRecords.isEmpty)
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
        XCTAssertEqual(
            matching,
            .readable(documentURL, text: "same\n", relationship: .sameAsRecovery)
        )

        try Data("external\n".utf8).write(to: documentURL)
        let changed = await inspector.inspect(record)
        XCTAssertEqual(
            changed,
            .readable(documentURL, text: "external\n", relationship: .divergedOrUnknown)
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

    private func recoveryRecord(text: String, updatedAt: Date) -> DocumentRecoveryRecord {
        DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: text),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .source,
            verticalScrollOffset: 0,
            updatedAt: updatedAt
        )
    }

    private func replacingRecoveryIdentity(
        _ record: DocumentRecoveryRecord,
        id: UUID,
        lineageID: UUID,
        epoch: UInt64,
        revision: UInt64,
        updatedAt: Date
    ) throws -> DocumentRecoveryRecord {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                as? [String: Any]
        )
        object["id"] = id.uuidString
        object["lineageID"] = lineageID.uuidString
        object["epoch"] = epoch
        object["revision"] = revision
        object["updatedAt"] = updatedAt.timeIntervalSinceReferenceDate
        return try JSONDecoder().decode(
            DocumentRecoveryRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func recoveryFileURL(
        _ record: DocumentRecoveryRecord,
        in fixture: RecoveryFixture
    ) -> URL {
        fixture.recoveryRoot
            .appendingPathComponent(record.id.uuidString)
            .appendingPathExtension("recovery")
    }

    private func recoveryFileSize(
        _ record: DocumentRecoveryRecord,
        in fixture: RecoveryFixture
    ) throws -> Int {
        try XCTUnwrap(
            recoveryFileURL(record, in: fixture)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
    }

    private func closedMarkerURL(_ id: UUID, in fixture: RecoveryFixture) -> URL {
        fixture.recoveryRoot
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("closed")
    }

    @MainActor
    private func waitForFile(at url: URL, timeout: TimeInterval = 1) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent)")
        throw NSError(domain: "DocumentRecoveryTests", code: 1)
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

private actor RecoveryReconcileGate {
    private var shouldSuspend = true
    private var isSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendFirstCommit() async {
        guard shouldSuspend else { return }
        shouldSuspend = false
        isSuspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct RecoveryFixture {
    let root: URL
    let recoveryRoot: URL
    let keyProvider = FixedDocumentRecoveryKeyProvider()

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

    func makeStore(
        beforeTransferConsumption: (@Sendable (UUID, UUID) throws -> Void)? = nil,
        beforeLegacyQuarantineWrite: (@Sendable () throws -> Void)? = nil
    ) -> DocumentRecoveryStore {
        DocumentRecoveryStore(
            rootURL: recoveryRoot,
            keyProvider: keyProvider,
            beforeTransferConsumption: beforeTransferConsumption,
            beforeLegacyQuarantineWrite: beforeLegacyQuarantineWrite
        )
    }
}
