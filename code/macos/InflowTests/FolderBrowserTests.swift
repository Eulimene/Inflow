import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest
@testable import Inflow

@MainActor
final class FolderBrowserTests: XCTestCase {
    func testOneModificationProjectionFeedsProjectTreeAndTabState() throws {
        let url = URL(fileURLWithPath: "/tmp/inflow-dirty-projection/note.md")
        let nativeDocument = NSDocument()
        nativeDocument.fileURL = url
        let controller = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false
        )
        controller.associateProjectWindow(with: nativeDocument)

        var markdown = try MarkdownDocument(fileData: Data("saved\n".utf8))
        XCTAssertFalse(MarkdownDocumentModificationProjection.isModified(markdown))
        markdown.text = "changed\n"
        let modified = MarkdownDocumentModificationProjection.isModified(markdown)
        XCTAssertTrue(modified)

        controller.setDocumentModified(nativeDocument, modified: modified)
        XCTAssertTrue(controller.isDocumentModified(at: url))

        let surface = ProjectDocumentSurface(
            nativeDocument: nativeDocument,
            content: Binding(get: { markdown }, set: { markdown = $0 }),
            fileURL: url,
            isEditable: true
        )
        surface.setModified(modified)
        XCTAssertTrue(surface.isModified)

        markdown.openedFileData = try markdown.encodedFileData()
        let saved = MarkdownDocumentModificationProjection.isModified(markdown)
        XCTAssertFalse(saved)
        controller.setDocumentModified(nativeDocument, modified: saved)
        surface.setModified(saved)
        XCTAssertFalse(controller.isDocumentModified(at: url))
        XCTAssertFalse(surface.isModified)

        controller.setDocumentModified(nativeDocument, modified: true)
        controller.dissociateProjectWindow(nativeDocument)
        XCTAssertFalse(controller.isDocumentModified(at: url))
    }

    func testClosingAnActiveTabSelectsItsNearestNeighbor() {
        let firstObject = NSObject()
        let secondObject = NSObject()
        let thirdObject = NSObject()
        let first = ObjectIdentifier(firstObject)
        let second = ObjectIdentifier(secondObject)
        let third = ObjectIdentifier(thirdObject)
        let ordered = [first, second, third]

        XCTAssertEqual(
            ProjectDocumentTabSelection.activeIDAfterClosing(
                second,
                orderedIDs: ordered,
                activeID: second
            ),
            third
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.activeIDAfterClosing(
                third,
                orderedIDs: ordered,
                activeID: third
            ),
            second
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.activeIDAfterClosing(
                first,
                orderedIDs: ordered,
                activeID: third
            ),
            third
        )

        XCTAssertEqual(
            ProjectDocumentTabSelection.targetIDs(
                for: .current,
                anchorID: second,
                orderedIDs: ordered
            ),
            [second]
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.targetIDs(
                for: .others,
                anchorID: second,
                orderedIDs: ordered
            ),
            [first, third]
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.targetIDs(
                for: .left,
                anchorID: second,
                orderedIDs: ordered
            ),
            [first]
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.targetIDs(
                for: .right,
                anchorID: second,
                orderedIDs: ordered
            ),
            [third]
        )
        XCTAssertTrue(
            ProjectDocumentTabSelection.targetIDs(
                for: .left,
                anchorID: first,
                orderedIDs: ordered
            ).isEmpty
        )
        XCTAssertTrue(
            ProjectDocumentTabSelection.targetIDs(
                for: .right,
                anchorID: third,
                orderedIDs: ordered
            ).isEmpty
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.activeIDAfterClosing(
                [first, second],
                orderedIDs: ordered,
                activeID: first
            ),
            third
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.activeIDAfterClosing(
                [second, third],
                orderedIDs: ordered,
                activeID: third
            ),
            first
        )
        XCTAssertEqual(
            ProjectDocumentTabSelection.activeIDAfterClosing(
                [first, third],
                orderedIDs: ordered,
                activeID: second
            ),
            second
        )
    }

    func testProjectDocumentSwitchGateRejectsConcurrentTransactions() async throws {
        _ = NSApplication.shared
        let gate = ProjectDocumentSwitchGate()
        let first = try XCTUnwrap(gate.begin())

        XCTAssertTrue(gate.isBusy)
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.finish(UUID()))
        XCTAssertTrue(gate.isActive(first))

        XCTAssertTrue(gate.finish(first))
        XCTAssertFalse(gate.isBusy)
        XCTAssertNotNil(gate.begin())

        let reservations = ProjectDocumentReservationRegistry()
        let target = URL(fileURLWithPath: "/tmp/reserved-project-target.md")
        let originalOwner = UUID()
        let retryOwner = UUID()
        let document = ClosingTrackingDocument()
        reservations.reserve(document: document, owner: originalOwner)
        reservations.reserve(targetURL: target, owner: originalOwner)
        reservations.reserve(targetURL: target, owner: retryOwner)
        XCTAssertTrue(reservations.isReserved(document))
        reservations.handleLateOpen(
            document: document,
            targetURL: target,
            wasAlreadyOpen: false,
            isProtected: { _ in false }
        )

        reservations.release(owner: originalOwner, isProtected: { _ in false })
        XCTAssertFalse(reservations.isReserved(document))
        XCTAssertEqual(document.closeCount, 0)
        reservations.release(owner: retryOwner, isProtected: { _ in false })
        XCTAssertEqual(document.closeCount, 1)

        let policyDocument = ClosingTrackingDocument()
        XCTAssertTrue(
            ProjectDocumentTargetPolicy.canCloseUncommitted(
                policyDocument,
                isRegistered: true
            )
        )
        XCTAssertTrue(
            ProjectDocumentTargetPolicy.isReusableShell(
                policyDocument,
                isAssociated: false,
                isRegistered: true
            )
        )
        policyDocument.updateChangeCount(.changeDone)
        XCTAssertFalse(
            ProjectDocumentTargetPolicy.canCloseUncommitted(
                policyDocument,
                isRegistered: true
            )
        )
        XCTAssertFalse(
            ProjectDocumentTargetPolicy.isReusableShell(
                policyDocument,
                isAssociated: false,
                isRegistered: true
            )
        )
        policyDocument.updateChangeCount(.changeCleared)
        policyDocument.fileURL = target
        XCTAssertFalse(
            ProjectDocumentTargetPolicy.isReusableShell(
                policyDocument,
                isAssociated: false,
                isRegistered: true
            )
        )
        policyDocument.fileURL = nil
        policyDocument.updateChangeCount(.changeDone)
        policyDocument.updateChangeCount(.changeCleared)

        let projectRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let projectTarget = projectRoot.appendingPathComponent("target.md")
        let trustedData = Data("# Trusted\n".utf8)
        try trustedData.write(to: projectTarget)
        let browser = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            bookmarkData: { _ in Data() },
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        browser.openFolder(projectRoot)
        try await waitUntilReady(browser)

        var pendingOpen: ProjectDocumentOpenCompletion?
        var openedAuthorization: ProjectDocumentOpenAuthorization?
        let detailedOpener = ProjectDocumentDetailedOpener { url, authorization, completion in
            XCTAssertEqual(url.standardizedFileURL, projectTarget.standardizedFileURL)
            openedAuthorization = authorization
            pendingOpen = completion
        }
        var onSurfaceActivation: ((NSDocument) -> Void)?
        let coordinator = LightweightProjectCoordinator(
            browser: browser,
            createProjectDocument: { ClosingTrackingDocument() },
            detailedDocumentOpener: detailedOpener,
            willActivateDocumentSurface: { document in
                onSurfaceActivation?(document)
            }
        )
        let recentDocuments = RecentDocumentsController(
            persistence: EmptyRecentDocumentPersistence(),
            bookmarkData: { _ in nil },
            systemSynchronizer: { _ in },
            recordsOpenedDocuments: false
        )
        let oldDocument = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(oldDocument)
        browser.associateProjectWindow(with: oldDocument)
        defer {
            for document in NSDocumentController.shared.documents
                where document === oldDocument
            {
                document.close()
            }
        }

        let firstAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: projectTarget,
                projectRoot: projectRoot
            )
        )
        var firstResult: Result<Void, Error>?
        coordinator.openDocument(
            projectTarget,
            replacing: oldDocument,
            using: recentDocuments,
            authorization: firstAuthorization
        ) { firstResult = $0 }
        XCTAssertTrue(coordinator.hasActiveDocumentSwitch)
        XCTAssertNil(firstResult)
        XCTAssertEqual(openedAuthorization, firstAuthorization)

        let newDocument = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(newDocument)
        var firstMutationError: Error?
        onSurfaceActivation = { document in
            guard document === newDocument else { return }
            onSurfaceActivation = nil
            do {
                try FileManager.default.removeItem(at: projectTarget)
                try Data("# Replacement during attach\n".utf8).write(to: projectTarget)
            } catch {
                firstMutationError = error
            }
        }
        pendingOpen?(
            .success(
                OpenedDocumentResult(
                    document: newDocument,
                    wasAlreadyOpen: false,
                    receipt: ProjectDocumentOpenReceipt(
                        authorization: firstAuthorization,
                        expectedData: trustedData
                    )
                )
            )
        )
        XCTAssertNil(firstMutationError)
        assertTargetChanged(firstResult)
        XCTAssertFalse(coordinator.hasActiveDocumentSwitch)
        XCTAssertEqual(oldDocument.closeCount, 0)
        XCTAssertEqual(newDocument.closeCount, 1)
        XCTAssertTrue(browser.isAssociatedProjectDocument(oldDocument))
        XCTAssertFalse(browser.isAssociatedProjectDocument(newDocument))
        XCTAssertEqual(coordinator.openedProjectURLs, [projectRoot])

        try trustedData.write(to: projectTarget)
        pendingOpen = nil
        openedAuthorization = nil
        let secondAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: projectTarget,
                projectRoot: projectRoot
            )
        )
        let alreadyOpenDocument = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(alreadyOpenDocument)
        defer {
            for document in NSDocumentController.shared.documents
                where document === alreadyOpenDocument
            {
                document.close()
            }
        }
        var secondResult: Result<Void, Error>?
        coordinator.openDocument(
            projectTarget,
            replacing: oldDocument,
            using: recentDocuments,
            authorization: secondAuthorization
        ) { secondResult = $0 }
        XCTAssertTrue(coordinator.hasActiveDocumentSwitch)
        XCTAssertNil(secondResult)

        alreadyOpenDocument.fileURL = projectTarget
        var secondMutationError: Error?
        onSurfaceActivation = { document in
            guard document === alreadyOpenDocument else { return }
            onSurfaceActivation = nil
            do {
                try FileManager.default.removeItem(at: projectTarget)
                try Data("# Replacement during focus\n".utf8).write(to: projectTarget)
            } catch {
                secondMutationError = error
            }
        }
        pendingOpen?(
            .success(
                OpenedDocumentResult(
                    document: alreadyOpenDocument,
                    wasAlreadyOpen: true,
                    receipt: ProjectDocumentOpenReceipt(
                        authorization: secondAuthorization,
                        expectedData: trustedData
                    )
                )
            )
        )
        XCTAssertNil(secondMutationError)
        assertTargetChanged(secondResult)
        XCTAssertFalse(coordinator.hasActiveDocumentSwitch)
        XCTAssertEqual(alreadyOpenDocument.closeCount, 0)
        XCTAssertEqual(oldDocument.closeCount, 0)
        XCTAssertTrue(browser.isAssociatedProjectDocument(oldDocument))

        alreadyOpenDocument.close()
        try trustedData.write(to: projectTarget)
        pendingOpen = nil
        let ordinaryDocument = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(ordinaryDocument)
        // Register the native document before assigning its represented URL.
        // AppKit may perform asynchronous ctime-only bookkeeping during
        // registration; the authorization must describe the settled target.
        ordinaryDocument.fileURL = projectTarget
        defer {
            for document in NSDocumentController.shared.documents
                where document === ordinaryDocument
            {
                document.close()
            }
        }
        // AppKit may update filesystem metadata while registering a native
        // document. Capture the project click only after that already-open
        // window exists, matching the real user sequence.
        let ordinaryAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: projectTarget,
                projectRoot: projectRoot
            )
        )
        XCTAssertTrue(
            NativeDocumentLoadedFileRegistry.canFocusAlreadyOpen(
                ordinaryDocument,
                authorization: ordinaryAuthorization
            ),
            "a never-managed native document at the exact target must be focusable"
        )
        var ordinaryResult: Result<Void, Error>?
        coordinator.openDocument(
            projectTarget,
            replacing: oldDocument,
            using: recentDocuments,
            authorization: ordinaryAuthorization
        ) { ordinaryResult = $0 }
        guard case .success? = ordinaryResult else {
            return XCTFail(
                "an ordinary single-file window must satisfy project deduplication; "
                    + "result=\(String(describing: ordinaryResult)), "
                    + "pendingClose=\(DocumentCloseAuthorization.hasPendingRequests), "
                    + "openerInvoked=\(pendingOpen != nil), "
                    + "authorizationCurrent=\(ordinaryAuthorization.isCurrent()), "
                    + "rootCurrent=\(ProjectSessionBoundary.hasCurrentRoot(browser)), "
                    + "representedURL=\(String(describing: ordinaryDocument.fileURL))"
            )
        }
        XCTAssertNil(pendingOpen, "deduplication must not start a second native open")
        XCTAssertEqual(
            ordinaryDocument.showCount,
            0,
            "project documents must stay behind the stable project host"
        )
        XCTAssertTrue(browser.isAssociatedProjectDocument(oldDocument))

        let mutationAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: projectTarget,
                projectRoot: projectRoot
            )
        )
        var ordinaryMutationError: Error?
        onSurfaceActivation = { document in
            guard document === ordinaryDocument else { return }
            onSurfaceActivation = nil
            do {
                try FileManager.default.removeItem(at: projectTarget)
                try Data("# Replacement during ordinary focus\n".utf8)
                    .write(to: projectTarget)
            } catch {
                ordinaryMutationError = error
            }
        }
        var ordinaryMutationResult: Result<Void, Error>?
        coordinator.openDocument(
            projectTarget,
            replacing: oldDocument,
            using: recentDocuments,
            authorization: mutationAuthorization
        ) { ordinaryMutationResult = $0 }
        XCTAssertNil(ordinaryMutationError)
        assertTargetChanged(ordinaryMutationResult)
        XCTAssertNil(pendingOpen, "a focused ordinary window must not invoke the native opener")
        XCTAssertEqual(ordinaryDocument.showCount, 0)
        XCTAssertTrue(browser.isAssociatedProjectDocument(oldDocument))

        ordinaryDocument.fileURL = nil
        ordinaryDocument.close()
        // NSDocument removal can finish its AppKit bookkeeping on the next
        // main-actor turn. Let that settle before freezing the next open's
        // filesystem authorization, otherwise a harmless late ctime update
        // makes this long transaction test nondeterministic.
        await Task.yield()
        try trustedData.write(to: projectTarget)
        try await Task.sleep(for: .milliseconds(20))
        pendingOpen = nil
        let successfulAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: projectTarget,
                projectRoot: projectRoot
            )
        )
        var successfulResult: Result<Void, Error>?
        coordinator.openDocument(
            projectTarget,
            replacing: oldDocument,
            using: recentDocuments,
            authorization: successfulAuthorization
        ) { successfulResult = $0 }
        XCTAssertNotNil(pendingOpen)

        let replacementDocument = ClosingTrackingDocument()
        replacementDocument.fileURL = projectTarget
        NSDocumentController.shared.addDocument(replacementDocument)
        // Match the real DocumentGroup lifecycle: its native window exists
        // before the project coordinator receives the completed open. Let
        // AppKit finish that setup before freezing the callback receipt so the
        // explicit permission mutation below remains the only attach-time
        // metadata change exercised by this assertion.
        replacementDocument.makeWindowControllers()
        replacementDocument.windowControllers.forEach { $0.window?.orderOut(nil) }
        await Task.yield()
        defer {
            for document in NSDocumentController.shared.documents
                where document === replacementDocument
            {
                document.close()
            }
        }
        var benignMetadataMutationError: Error?
        onSurfaceActivation = { document in
            guard document === replacementDocument else { return }
            onSurfaceActivation = nil
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: projectTarget.path
                )
            } catch {
                benignMetadataMutationError = error
            }
        }
        let callbackAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: projectTarget,
                projectRoot: projectRoot
            )
        )
        pendingOpen?(
            .success(
                OpenedDocumentResult(
                    document: replacementDocument,
                    wasAlreadyOpen: false,
                    receipt: ProjectDocumentOpenReceipt(
                        authorization: callbackAuthorization,
                        expectedData: trustedData
                    )
                )
            )
        )
        XCTAssertNil(benignMetadataMutationError)
        guard case .success? = successfulResult else {
            return XCTFail(
                "expected the final project document replacement to succeed, got "
                    + String(describing: successfulResult)
            )
        }
        XCTAssertTrue(browser.isAssociatedProjectDocument(replacementDocument))

        coordinator.registerDocumentSurface(
            nativeDocument: replacementDocument,
            content: .constant(MarkdownDocument(text: "# Trusted\n")),
            fileURL: projectTarget,
            isEditable: true
        )
        XCTAssertTrue(coordinator.isProjectHostDocument(oldDocument))
        XCTAssertTrue(coordinator.isBackgroundProjectDocument(replacementDocument))
        XCTAssertTrue(
            coordinator.activeDocumentSurface?.nativeDocument === replacementDocument
        )
        let firstEditorSession = coordinator.activeDocumentSurface?.sourceEditorSession
        XCTAssertEqual(replacementDocument.showCount, 0)

        let secondTarget = projectRoot.appendingPathComponent("second.md")
        try Data("# Second\n".utf8).write(to: secondTarget)
        let secondDocument = ClosingTrackingDocument()
        secondDocument.fileURL = secondTarget
        let backgroundWindow = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        backgroundWindow.animationBehavior = .none
        let backgroundWindowController = NSWindowController(window: backgroundWindow)
        secondDocument.addWindowController(backgroundWindowController)
        backgroundWindow.orderFront(nil)
        XCTAssertTrue(backgroundWindow.isVisible)
        NSDocumentController.shared.addDocument(secondDocument)
        browser.associateProjectWindow(with: secondDocument)
        defer {
            if NSDocumentController.shared.documents.contains(where: {
                $0 === secondDocument
            }) {
                secondDocument.close()
            }
        }
        coordinator.registerDocumentSurface(
            nativeDocument: secondDocument,
            content: .constant(MarkdownDocument(text: "# Second\n")),
            fileURL: secondTarget,
            isEditable: true
        )
        XCTAssertFalse(
            backgroundWindow.isVisible,
            "a project document's native window must be hidden before its workspace surface publishes"
        )
        secondDocument.removeWindowController(backgroundWindowController)
        backgroundWindow.close()
        coordinator.selectDocumentSurface(ObjectIdentifier(secondDocument))
        XCTAssertTrue(coordinator.isProjectHostDocument(oldDocument))
        XCTAssertTrue(coordinator.activeDocumentSurface?.nativeDocument === secondDocument)
        XCTAssertEqual(coordinator.documentSurfaces.count, 2)
        XCTAssertEqual(secondDocument.showCount, 0)
        XCTAssertEqual(oldDocument.closeCount, 0)

        let thirdTarget = projectRoot.appendingPathComponent("third.md")
        try Data("# Third\n".utf8).write(to: thirdTarget)
        let thirdDocument = ClosingTrackingDocument()
        thirdDocument.fileURL = thirdTarget
        NSDocumentController.shared.addDocument(thirdDocument)
        browser.associateProjectWindow(with: thirdDocument)
        defer {
            if NSDocumentController.shared.documents.contains(where: {
                $0 === thirdDocument
            }) {
                thirdDocument.close()
            }
        }
        coordinator.registerDocumentSurface(
            nativeDocument: thirdDocument,
            content: .constant(MarkdownDocument(text: "# Third\n")),
            fileURL: thirdTarget,
            isEditable: true
        )
        XCTAssertEqual(coordinator.documentSurfaces.count, 3)

        coordinator.selectDocumentSurface(ObjectIdentifier(replacementDocument))
        XCTAssertTrue(coordinator.isProjectHostDocument(oldDocument))
        XCTAssertTrue(
            coordinator.activeDocumentSurface?.sourceEditorSession === firstEditorSession
        )
        XCTAssertEqual(replacementDocument.showCount, 0)
        XCTAssertEqual(secondDocument.showCount, 0)

        coordinator.closeDocumentSurfaces(
            in: .others,
            relativeTo: ObjectIdentifier(secondDocument)
        )
        XCTAssertEqual(replacementDocument.closeCount, 1)
        XCTAssertEqual(thirdDocument.closeCount, 1)
        XCTAssertEqual(coordinator.documentSurfaces.count, 1)
        XCTAssertTrue(coordinator.activeDocumentSurface?.nativeDocument === secondDocument)
        XCTAssertFalse(browser.isAssociatedProjectDocument(replacementDocument))

        coordinator.closeDocumentSurface(ObjectIdentifier(secondDocument))
        XCTAssertEqual(secondDocument.closeCount, 1)
        XCTAssertTrue(coordinator.documentSurfaces.isEmpty)
        XCTAssertNil(coordinator.activeSurfaceID)
        XCTAssertTrue(coordinator.isProjectHostDocument(oldDocument))
    }

    func testCoordinatorReleaseCleanupClosesOnlyUnownedNewHiddenDocuments() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        browser.openFolder(root)
        try await waitUntilReady(browser)

        let newlyOpened = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(newlyOpened)
        LightweightProjectCoordinator.closeOpenedDocumentAfterCoordinatorReleaseIfSafe(
            .success(
                OpenedDocumentResult(
                    document: newlyOpened,
                    wasAlreadyOpen: false
                )
            ),
            browser: browser
        )
        XCTAssertEqual(newlyOpened.closeCount, 1)
        XCTAssertFalse(
            NSDocumentController.shared.documents.contains { $0 === newlyOpened }
        )

        let alreadyOpen = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(alreadyOpen)
        defer {
            if NSDocumentController.shared.documents.contains(where: {
                $0 === alreadyOpen
            }) {
                alreadyOpen.close()
            }
        }
        LightweightProjectCoordinator.closeOpenedDocumentAfterCoordinatorReleaseIfSafe(
            .success(
                OpenedDocumentResult(
                    document: alreadyOpen,
                    wasAlreadyOpen: true
                )
            ),
            browser: browser
        )
        XCTAssertEqual(alreadyOpen.closeCount, 0)

        let protected = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(protected)
        browser.associateProjectWindow(with: protected)
        defer {
            browser.associateProjectWindow(with: nil)
            if NSDocumentController.shared.documents.contains(where: {
                $0 === protected
            }) {
                protected.close()
            }
        }
        LightweightProjectCoordinator.closeOpenedDocumentAfterCoordinatorReleaseIfSafe(
            .success(
                OpenedDocumentResult(
                    document: protected,
                    wasAlreadyOpen: false
                )
            ),
            browser: browser
        )
        XCTAssertEqual(protected.closeCount, 0)
    }

    private func assertTargetChanged(
        _ result: Result<Void, Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error)? = result,
              let openError = error as? DocumentOpenError,
              case .targetChanged = openError
        else {
            XCTFail("expected targetChanged, got \(String(describing: result))", file: file, line: line)
            return
        }
    }

    func testLaunchPolicyCreatesAnEditableUntitledDocumentWithoutOpeningAFile() {
        let application = NSApplication.shared
        var createdDocumentCount = 0
        let delegate = InflowApplicationDelegate { _ in
            createdDocumentCount += 1
        }

        XCTAssertTrue(InflowLaunchPolicy.presentsEditableDocumentFirst)
        XCTAssertFalse(InflowLaunchPolicy.letsAppKitOpenUntitledDocument)
        XCTAssertTrue(
            InflowLaunchPolicy.shouldCreateInitialDocument(
                hasReceivedExternalOpenRequest: false,
                hasOpenDocuments: false
            )
        )
        XCTAssertFalse(
            InflowLaunchPolicy.shouldCreateInitialDocument(
                hasReceivedExternalOpenRequest: true,
                hasOpenDocuments: false
            )
        )
        XCTAssertFalse(
            InflowLaunchPolicy.shouldCreateInitialDocument(
                hasReceivedExternalOpenRequest: false,
                hasOpenDocuments: true
            )
        )
        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(application))
        XCTAssertTrue(delegate.applicationOpenUntitledFile(application))
        XCTAssertEqual(createdDocumentCount, 1)

        XCTAssertTrue(
            InflowLaunchPolicy.shouldFocusFreshUntitledDocument(
                fileURL: nil,
                text: "",
                hasRestorationState: false,
                isEditable: true
            )
        )
        XCTAssertFalse(
            InflowLaunchPolicy.shouldFocusFreshUntitledDocument(
                fileURL: URL(fileURLWithPath: "/tmp/named.md"),
                text: "",
                hasRestorationState: false,
                isEditable: true
            )
        )
        XCTAssertFalse(
            InflowLaunchPolicy.shouldFocusFreshUntitledDocument(
                fileURL: nil,
                text: "restored",
                hasRestorationState: true,
                isEditable: true
            )
        )

        let projectFileURL = URL(fileURLWithPath: "/tmp/project/note.md")
        XCTAssertTrue(
            InflowLaunchPolicy.shouldFocusProjectDocumentAfterNavigation(
                fileURL: projectFileURL,
                hasProjectContext: true,
                sourceIsVisible: true,
                isEditable: true
            )
        )
        for state in [
            (fileURL: nil, project: true, source: true, editable: true),
            (fileURL: projectFileURL, project: false, source: true, editable: true),
            (fileURL: projectFileURL, project: true, source: false, editable: true),
            (fileURL: projectFileURL, project: true, source: true, editable: false),
        ] {
            XCTAssertFalse(
                InflowLaunchPolicy.shouldFocusProjectDocumentAfterNavigation(
                    fileURL: state.fileURL,
                    hasProjectContext: state.project,
                    sourceIsVisible: state.source,
                    isEditable: state.editable
                )
            )
        }
    }

    func testLaunchIntegrationsWaitUntilApplicationDidFinishLaunching() async {
        let application = NSApplication.shared
        var installationCount = 0
        var createdDocumentCount = 0
        let initialDocumentCreated = expectation(description: "initial document created")
        let delegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in
                createdDocumentCount += 1
                initialDocumentCreated.fulfill()
            },
            hasOpenDocuments: { false },
            installLaunchIntegrations: { _ in
                installationCount += 1
            }
        )

        XCTAssertEqual(installationCount, 0)

        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: application
        )
        delegate.applicationDidFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)

        XCTAssertEqual(installationCount, 1)
        XCTAssertEqual(createdDocumentCount, 0)
        await fulfillment(of: [initialDocumentCreated], timeout: 1)
        XCTAssertEqual(createdDocumentCount, 1)
    }

    func testDockReopenCreatesAnUntitledDocumentOnlyWhenNoWindowIsVisible() {
        let application = NSApplication.shared
        var createdDocumentCount = 0
        let delegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in createdDocumentCount += 1 },
            hasOpenDocuments: { false },
            restoreDocumentWindow: { false }
        )

        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(
                application,
                hasVisibleWindows: true
            )
        )
        XCTAssertEqual(createdDocumentCount, 0)
        XCTAssertFalse(
            delegate.applicationShouldHandleReopen(
                application,
                hasVisibleWindows: false
            )
        )
        XCTAssertEqual(createdDocumentCount, 1)
    }

    func testScannerRecursivelyBuildsVisibleDirectoryTreeAndKeepsMarkdownCompatibilityList()
        throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Guide", isDirectory: true)
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("# B".utf8).write(to: nested.appendingPathComponent("Beta.markdown"))
        try Data("# A".utf8).write(to: root.appendingPathComponent("Alpha.MD"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("hidden".utf8).write(to: hidden.appendingPathComponent("secret.md"))
        let flaggedHidden = root.appendingPathComponent("finder-hidden.md")
        try Data("hidden by flag".utf8).write(to: flaggedHidden)
        let hiddenFlagResult = flaggedHidden.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.chflags(path, UInt32(UF_HIDDEN))
        }
        XCTAssertEqual(hiddenFlagResult, 0)

        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.md"),
            withDestinationURL: outside.appendingPathComponent("outside.md")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-folder"),
            withDestinationURL: outside
        )

        let files = try FolderContentScanner.scan(root)
        let tree = try FolderContentScanner.scanTree(root)

        XCTAssertEqual(files.map(\.relativePath), ["Alpha.MD", "Guide/Beta.markdown"])
        XCTAssertEqual(files.map(\.displayName), ["Alpha.MD", "Beta.markdown"])
        XCTAssertNil(files[0].parentPath)
        XCTAssertEqual(files[1].parentPath, "Guide")
        XCTAssertEqual(
            flattenedPaths(in: tree),
            ["Empty", "Guide", "Guide/Beta.markdown", "Alpha.MD", "notes.txt"]
        )
        XCTAssertEqual(tree.map(\.kind), [.directory, .directory, .file, .file])
        XCTAssertEqual(tree[1].children?.map(\.displayName), ["Beta.markdown"])
        XCTAssertTrue(tree[1].children?.first?.isMarkdown == true)
        XCTAssertFalse(tree.last?.isMarkdown == true)
        XCTAssertEqual(
            FolderProjectTreeState.directoryIDs(in: tree),
            Set(["Empty", "Guide"])
        )
        XCTAssertEqual(
            FolderProjectTreeState.toggledExpansion(current: [], in: tree),
            Set(["Empty", "Guide"])
        )
        XCTAssertEqual(
            FolderProjectTreeState.toggledExpansion(
                current: Set(["Empty", "Guide"]),
                in: tree
            ),
            []
        )

        let markdownItem = try XCTUnwrap(tree[1].children?.first)
        XCTAssertEqual(
            FolderProjectTreeState.selectedItemID(
                for: markdownItem.url,
                in: tree
            ),
            markdownItem.id
        )
        XCTAssertNil(
            FolderProjectTreeState.selectedItemID(
                for: outside.appendingPathComponent("outside.md"),
                in: tree
            )
        )
        XCTAssertEqual(
            FolderBrowserActivation.markdownURL(
                forSelectedItemID: markdownItem.id,
                in: tree
            ),
            markdownItem.url
        )
        XCTAssertNil(
            FolderBrowserActivation.markdownURL(
                forSelectedItemID: tree[1].id,
                in: tree
            )
        )
        XCTAssertNil(
            FolderBrowserActivation.markdownURL(
                forSelectedItemID: tree.last?.id,
                in: tree
            )
        )
        XCTAssertNil(
            FolderBrowserActivation.markdownURL(
                forSelectedItemID: nil,
                in: tree
            )
        )

        let replaceable = root.appendingPathComponent("Replaceable", isDirectory: true)
        let displaced = root.appendingPathComponent("Replaceable-original", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replaceable,
            withIntermediateDirectories: false
        )
        try Data("inside".utf8).write(
            to: replaceable.appendingPathComponent("inside.md")
        )
        var replacementHookRan = false
        XCTAssertThrowsError(
            try FolderContentScanner.snapshot(
                root,
                beforeOpeningDirectory: { directory in
                    guard directory == replaceable else { return }
                    replacementHookRan = true
                    try FileManager.default.moveItem(at: replaceable, to: displaced)
                    try FileManager.default.createSymbolicLink(
                        at: replaceable,
                        withDestinationURL: outside
                    )
                }
            )
        ) { error in
            XCTAssertEqual(error as? FolderBrowserError, .unavailable)
        }
        XCTAssertTrue(replacementHookRan)

        let rootRaceContainer = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootRaceContainer) }
        let replaceableRoot = rootRaceContainer.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        let displacedRoot = rootRaceContainer.appendingPathComponent(
            "Project-original",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replaceableRoot,
            withIntermediateDirectories: false
        )
        try Data("inside root".utf8).write(
            to: replaceableRoot.appendingPathComponent("inside.md")
        )
        var rootReplacementHookRan = false
        XCTAssertThrowsError(
            try FolderContentScanner.snapshot(
                replaceableRoot,
                beforeOpeningDirectory: { directory in
                    guard directory == replaceableRoot else { return }
                    rootReplacementHookRan = true
                    try FileManager.default.moveItem(
                        at: replaceableRoot,
                        to: displacedRoot
                    )
                    try FileManager.default.createSymbolicLink(
                        at: replaceableRoot,
                        withDestinationURL: outside
                    )
                }
            )
        ) { error in
            XCTAssertEqual(error as? FolderBrowserError, .unavailable)
        }
        XCTAssertTrue(rootReplacementHookRan)

        let abaContainer = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: abaContainer) }
        let abaRoot = abaContainer.appendingPathComponent("Project", isDirectory: true)
        let originalABARoot = abaContainer.appendingPathComponent(
            "Project-A",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: abaRoot,
            withIntermediateDirectories: false
        )
        try Data("A".utf8).write(to: abaRoot.appendingPathComponent("a.md"))
        let expectedABAIdentity = try XCTUnwrap(
            FolderProjectDirectoryIdentity.capture(abaRoot)
        )
        try FileManager.default.moveItem(at: abaRoot, to: originalABARoot)
        try FileManager.default.createDirectory(
            at: abaRoot,
            withIntermediateDirectories: false
        )
        try Data("B".utf8).write(to: abaRoot.appendingPathComponent("b.md"))
        XCTAssertThrowsError(
            try FolderContentScanner.snapshot(
                abaRoot,
                expectedRootIdentity: expectedABAIdentity
            )
        ) { error in
            XCTAssertEqual(error as? FolderBrowserError, .unavailable)
        }
    }

    func testScannerRejectsFilesAndBoundsPathologicalFolderSize() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try Data().write(to: first)
        try Data().write(to: second)
        let namedPipe = root.appendingPathComponent("events.pipe")
        let pipeResult = namedPipe.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.mkfifo(path, 0o600)
        }
        XCTAssertEqual(pipeResult, 0)

        XCTAssertThrowsError(try FolderContentScanner.scan(first)) { error in
            XCTAssertEqual(error as? FolderBrowserError, .unavailable)
        }
        XCTAssertEqual(
            try FolderContentScanner.scan(root, maximumFileCount: 2)
                .map(\.relativePath),
            ["a.md", "b.md"]
        )
        XCTAssertThrowsError(
            try FolderContentScanner.scan(root, maximumFileCount: 1)
        ) { error in
            XCTAssertEqual(
                error as? FolderBrowserError,
                .tooManyMarkdownFiles(limit: 1)
            )
        }
    }

    func testScannerSkipsUnreadableDescendantsInsteadOfRejectingSelectedRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Visible".utf8).write(to: root.appendingPathComponent("visible.md"))
        let unreadable = root.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unreadable,
            withIntermediateDirectories: false
        )
        try Data("# Hidden".utf8).write(to: unreadable.appendingPathComponent("hidden.md"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unreadable.path
            )
        }

        let snapshot = try FolderContentScanner.snapshot(root)

        XCTAssertEqual(snapshot.markdownFiles.map(\.relativePath), ["visible.md"])
        XCTAssertEqual(snapshot.items.map(\.relativePath), ["visible.md"])
    }

    func testProjectBoundaryNormalizesRootAndResolvesSymlinksBeforeContainment()
        throws
    {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Project", isDirectory: true)
        let sibling = container.appendingPathComponent("Project-copy", isDirectory: true)
        let nested = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let rootAlias = container.appendingPathComponent("Project-alias", isDirectory: true)
        let insideAlias = root.appendingPathComponent("inside", isDirectory: true)
        let escapeAlias = root.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: insideAlias, withDestinationURL: nested)
        try FileManager.default.createSymbolicLink(at: escapeAlias, withDestinationURL: sibling)

        XCTAssertEqual(
            try FolderProjectPathBoundary.normalizedProjectRoot(rootAlias),
            FolderProjectPathBoundary.normalizedResolvedURL(root)
        )
        XCTAssertEqual(
            FolderProjectPathBoundary.resolvedURL(insideAlias, within: root),
            FolderProjectPathBoundary.normalizedResolvedURL(nested)
        )
        XCTAssertNil(FolderProjectPathBoundary.resolvedURL(escapeAlias, within: root))
        XCTAssertFalse(FolderProjectPathBoundary.contains(sibling, in: root))
        XCTAssertEqual(
            FolderProjectPathBoundary.relativeComponents(of: nested, in: root),
            ["Notes"]
        )
    }

    func testCreationTargetUsesDirectoryFileParentOrProjectRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Notes", isDirectory: true)
        let file = nested.appendingPathComponent("existing.md")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: file)

        XCTAssertEqual(
            try FolderMarkdownFileCreator.targetDirectory(
                for: .directory(nested),
                projectRoot: root
            ),
            FolderProjectPathBoundary.normalizedResolvedURL(nested)
        )
        XCTAssertEqual(
            try FolderMarkdownFileCreator.targetDirectory(
                for: .file(file),
                projectRoot: root
            ),
            FolderProjectPathBoundary.normalizedResolvedURL(nested)
        )
        XCTAssertEqual(
            try FolderMarkdownFileCreator.targetDirectory(
                for: .none,
                projectRoot: root
            ),
            FolderProjectPathBoundary.normalizedResolvedURL(root)
        )
    }

    func testCreationNameValidationAddsMarkdownExtensionAndRejectsUnsafeNames() throws {
        XCTAssertEqual(
            try FolderMarkdownFileCreator.normalizedFileName("新文档"),
            "新文档.md"
        )
        XCTAssertEqual(
            try FolderMarkdownFileCreator.normalizedFileName("README.MD"),
            "README.MD"
        )
        XCTAssertEqual(
            try FolderMarkdownFileCreator.normalizedFileName("chapter.one.markdown"),
            "chapter.one.markdown"
        )

        for name in ["", "   ", ".", "..", ".hidden", "a/b", "a\\b", "line\nfeed"] {
            XCTAssertThrowsError(try FolderMarkdownFileCreator.normalizedFileName(name)) { error in
                XCTAssertEqual(error as? FolderMarkdownCreationError, .invalidName)
            }
        }
        for name in ["draft.txt", "draft.", "archive.tar.gz"] {
            XCTAssertThrowsError(try FolderMarkdownFileCreator.normalizedFileName(name)) { error in
                XCTAssertEqual(error as? FolderMarkdownCreationError, .unsupportedExtension)
            }
        }
    }

    func testExclusiveCreationWritesEmptyFileAndNeverOverwritesFileOrDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let created = try FolderMarkdownFileCreator.createEmptyMarkdownFile(
            named: "Draft",
            projectRoot: root
        )
        XCTAssertEqual(created.relativePath, "Draft.md")
        XCTAssertEqual(try Data(contentsOf: created.url), Data())

        try Data("keep".utf8).write(to: root.appendingPathComponent("existing.md"))
        XCTAssertThrowsError(
            try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: "existing.md",
                projectRoot: root
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderMarkdownCreationError,
                .alreadyExists(fileName: "existing.md")
            )
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("existing.md"), encoding: .utf8),
            "keep"
        )

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("occupied.md", isDirectory: true),
            withIntermediateDirectories: false
        )
        XCTAssertThrowsError(
            try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: "occupied.md",
                projectRoot: root
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderMarkdownCreationError,
                .alreadyExists(fileName: "occupied.md")
            )
        }
    }

    func testCreationRejectsOutsideAndEscapingSymlinkButAllowsResolvedInternalLink()
        throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let insideLink = root.appendingPathComponent("inside-link", isDirectory: true)
        let outsideLink = root.appendingPathComponent("outside-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: insideLink, withDestinationURL: nested)
        try FileManager.default.createSymbolicLink(at: outsideLink, withDestinationURL: outside)
        let rootIdentity = try XCTUnwrap(FolderProjectDirectoryIdentity.capture(root))
        let nestedIdentity = try XCTUnwrap(FolderProjectDirectoryIdentity.capture(nested))
        let outsideIdentity = try XCTUnwrap(FolderProjectDirectoryIdentity.capture(outside))

        let inside = try FolderMarkdownFileCreator.createEmptyMarkdownFile(
            named: "inside",
            projectRoot: root,
            selection: .directory(insideLink),
            expectedRootIdentity: rootIdentity,
            expectedTargetIdentity: nestedIdentity
        )
        XCTAssertEqual(inside.relativePath, "Nested/inside.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("inside.md").path))

        XCTAssertThrowsError(
            try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: "mismatched-root",
                projectRoot: root,
                selection: .directory(nested),
                expectedRootIdentity: outsideIdentity,
                expectedTargetIdentity: nestedIdentity
            )
        ) { error in
            XCTAssertEqual(error as? FolderMarkdownCreationError, .projectUnavailable)
        }
        XCTAssertThrowsError(
            try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: "mismatched-target",
                projectRoot: root,
                selection: .directory(nested),
                expectedRootIdentity: rootIdentity,
                expectedTargetIdentity: rootIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderMarkdownCreationError,
                .targetDirectoryUnavailable
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: nested.appendingPathComponent("mismatched-root.md").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: nested.appendingPathComponent("mismatched-target.md").path
            )
        )

        for selection in [
            FolderBrowserSelection.directory(outside),
            FolderBrowserSelection.directory(outsideLink),
            FolderBrowserSelection.file(outside.appendingPathComponent("outside.md")),
        ] {
            XCTAssertThrowsError(
                try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                    named: "escaped",
                    projectRoot: root,
                    selection: selection
                )
            ) { error in
                XCTAssertEqual(
                    error as? FolderMarkdownCreationError,
                    .targetOutsideProject
                )
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.md").path)
        )
    }

    func testCreationRejectsMissingAndUnwritableTargetsWithoutCreatingAFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        XCTAssertThrowsError(
            try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: "missing",
                projectRoot: root,
                selection: .directory(missing)
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderMarkdownCreationError,
                .targetDirectoryUnavailable
            )
        }

        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: locked.path
            )
        }
        XCTAssertThrowsError(
            try FolderMarkdownFileCreator.createEmptyMarkdownFile(
                named: "denied",
                projectRoot: root,
                selection: .directory(locked)
            )
        ) { error in
            XCTAssertEqual(
                error as? FolderMarkdownCreationError,
                .cannotCreate(fileName: "denied.md")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: locked.appendingPathComponent("denied.md").path)
        )
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
        XCTAssertEqual(
            controller.projectRootIdentity,
            FolderProjectDirectoryIdentity.capture(root)
        )
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

        let candidate = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: candidate) }
        try Data("# Two".utf8).write(to: candidate.appendingPathComponent("two.md"))
        XCTAssertEqual(controller.folderURL?.path, root.path)
        XCTAssertEqual(started.map(\.path), [root.path])

        let preparation: FolderProjectOpenPreparation = try await withCheckedThrowingContinuation {
            continuation in
            _ = controller.prepareFolderForOpening(candidate) {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(controller.folderURL?.path, root.path)
        XCTAssertEqual(started.map(\.path), [root.path, candidate.path])
        XCTAssertEqual(preparation.snapshot.markdownFiles.map(\.relativePath), ["two.md"])
        XCTAssertTrue(controller.commitPreparedFolder(preparation))
        XCTAssertEqual(controller.folderURL?.path, candidate.path)
        XCTAssertEqual(controller.projectRootIdentity, preparation.rootIdentity)
        XCTAssertEqual(controller.files.map(\.relativePath), ["two.md"])
        XCTAssertTrue(ProjectSessionBoundary.hasCurrentRoot(controller))
        let candidateAlias = candidate.deletingLastPathComponent()
            .appendingPathComponent("alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: candidateAlias,
            withDestinationURL: candidate
        )
        defer { try? FileManager.default.removeItem(at: candidateAlias) }
        XCTAssertTrue(
            ProjectSessionBoundary.matchesRequestedProject(
                candidateAlias,
                browser: controller
            )
        )
        let candidateTarget = candidate.appendingPathComponent("two.md")
        let documentAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: candidateTarget,
                projectRoot: candidate
            )
        )
        XCTAssertTrue(
            ProjectSessionBoundary.authorizationIsCurrent(
                documentAuthorization,
                targetURL: candidateTarget,
                browser: controller
            )
        )

        let replacementContainer = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: replacementContainer) }
        let replacedCandidate = replacementContainer.appendingPathComponent(
            "candidate",
            isDirectory: true
        )
        let movedCandidate = replacementContainer.appendingPathComponent(
            "original",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacedCandidate,
            withIntermediateDirectories: true
        )
        let stalePreparation: FolderProjectOpenPreparation = try await withCheckedThrowingContinuation {
            continuation in
            _ = controller.prepareFolderForOpening(replacedCandidate) {
                continuation.resume(with: $0)
            }
        }
        try FileManager.default.moveItem(at: replacedCandidate, to: movedCandidate)
        try FileManager.default.createDirectory(
            at: replacedCandidate,
            withIntermediateDirectories: true
        )
        XCTAssertFalse(controller.commitPreparedFolder(stalePreparation))
        XCTAssertEqual(controller.folderURL?.path, candidate.path)

        let displacedCurrentProject = candidate
            .deletingLastPathComponent()
            .appendingPathComponent(
                "displaced-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: candidate, to: displacedCurrentProject)
        defer { try? FileManager.default.removeItem(at: displacedCurrentProject) }
        try FileManager.default.createDirectory(
            at: candidate,
            withIntermediateDirectories: false
        )
        try Data("replacement".utf8).write(
            to: candidate.appendingPathComponent("two.md")
        )

        XCTAssertFalse(ProjectSessionBoundary.hasCurrentRoot(controller))
        XCTAssertFalse(
            ProjectSessionBoundary.matchesRequestedProject(
                candidate,
                browser: controller
            )
        )
        XCTAssertFalse(
            ProjectSessionBoundary.authorizationIsCurrent(
                documentAuthorization,
                targetURL: candidateTarget,
                browser: controller
            )
        )

        XCTAssertThrowsError(try controller.targetDirectory(for: .none)) { error in
            XCTAssertEqual(
                error as? FolderMarkdownCreationError,
                .projectUnavailable
            )
        }
        XCTAssertEqual(
            controller.createMarkdownFile(
                named: "must-not-create.md",
                openDocument: { _ in XCTFail("replacement project must not open") }
            ),
            .notCreated(.projectUnavailable)
        )
        controller.refresh()
        XCTAssertEqual(
            controller.state,
            .failed(FolderBrowserError.unavailable.localizedDescription)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("must-not-create.md").path
            )
        )
    }

    func testPreparedFolderCommitRollsBackWhenPublishedCandidateIsReplaced() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let originalRoot = container.appendingPathComponent("original", isDirectory: true)
        let candidateRoot = container.appendingPathComponent("candidate", isDirectory: true)
        let displacedCandidate = container.appendingPathComponent(
            "displaced-candidate",
            isDirectory: true
        )
        let displacedOriginal = container.appendingPathComponent(
            "displaced-original",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: candidateRoot,
            withIntermediateDirectories: false
        )
        try Data("# Original".utf8).write(
            to: originalRoot.appendingPathComponent("original.md")
        )
        try Data("# Candidate".utf8).write(
            to: candidateRoot.appendingPathComponent("candidate.md")
        )

        let controller = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            bookmarkData: { _ in Data() },
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        controller.openFolder(originalRoot)
        try await waitUntilReady(controller)
        let associatedDocument = NSDocument()
        let secondAssociatedDocument = NSDocument()
        controller.associateProjectWindow(with: associatedDocument)
        controller.associateProjectWindow(with: secondAssociatedDocument)

        let previousRoot = controller.folderURL
        let previousIdentity = controller.projectRootIdentity
        let previousItems = controller.items
        let previousFiles = controller.files
        let previousState = controller.state
        let previousWarning = controller.restorationWarning
        let preparation: FolderProjectOpenPreparation = try await withCheckedThrowingContinuation {
            continuation in
            _ = controller.prepareFolderForOpening(candidateRoot) {
                continuation.resume(with: $0)
            }
        }

        var replacementError: Error?
        var didReplaceCandidate = false
        let observation = controller.$folderURL.dropFirst().sink { publishedURL in
            guard !didReplaceCandidate,
                  publishedURL?.standardizedFileURL == candidateRoot.standardizedFileURL
            else { return }
            didReplaceCandidate = true
            do {
                try FileManager.default.moveItem(
                    at: candidateRoot,
                    to: displacedCandidate
                )
                try FileManager.default.createDirectory(
                    at: candidateRoot,
                    withIntermediateDirectories: false
                )
            } catch {
                replacementError = error
            }
        }

        XCTAssertFalse(controller.commitPreparedFolder(preparation))
        observation.cancel()
        if let replacementError { throw replacementError }
        XCTAssertTrue(didReplaceCandidate)
        XCTAssertEqual(controller.folderURL, previousRoot)
        XCTAssertEqual(controller.projectRootIdentity, previousIdentity)
        XCTAssertEqual(controller.items, previousItems)
        XCTAssertEqual(controller.files, previousFiles)
        XCTAssertEqual(controller.state, previousState)
        XCTAssertEqual(controller.restorationWarning, previousWarning)
        XCTAssertTrue(controller.isAssociatedProjectDocument(associatedDocument))
        XCTAssertTrue(controller.isAssociatedProjectDocument(secondAssociatedDocument))
        XCTAssertTrue(ProjectSessionBoundary.hasCurrentRoot(controller))
        let originalDocumentURL = originalRoot.appendingPathComponent("original.md")
        XCTAssertEqual(
            ProjectSessionBoundary.activeEditorRoot(
                for: originalDocumentURL,
                document: associatedDocument,
                browser: controller
            ),
            originalRoot
        )

        try FileManager.default.moveItem(at: originalRoot, to: displacedOriginal)
        try FileManager.default.createDirectory(
            at: originalRoot,
            withIntermediateDirectories: false
        )
        try Data("# Replacement original".utf8).write(to: originalDocumentURL)
        XCTAssertNil(
            ProjectSessionBoundary.activeEditorRoot(
                for: originalDocumentURL,
                document: associatedDocument,
                browser: controller
            )
        )
    }

    func testPreparedFolderFinalValidationRollsBackReentrantSwitchAndTargetMutation()
        async throws
    {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let originalRoot = container.appendingPathComponent("original", isDirectory: true)
        let candidateRoot = container.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: originalRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: candidateRoot,
            withIntermediateDirectories: false
        )
        try Data("# Original".utf8).write(
            to: originalRoot.appendingPathComponent("original.md")
        )
        try Data("# Candidate".utf8).write(
            to: candidateRoot.appendingPathComponent("candidate.md")
        )

        let controller = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            bookmarkData: { _ in Data() },
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        controller.openFolder(originalRoot)
        try await waitUntilReady(controller)
        let associatedDocument = NSDocument()
        controller.associateProjectWindow(with: associatedDocument)
        let preparation: FolderProjectOpenPreparation = try await withCheckedThrowingContinuation {
            continuation in
            _ = controller.prepareFolderForOpening(candidateRoot) {
                continuation.resume(with: $0)
            }
        }

        let previousRoot = controller.folderURL
        let previousIdentity = controller.projectRootIdentity
        let previousItems = controller.items
        let previousFiles = controller.files
        let previousState = controller.state
        let targetDocument = ClosingTrackingDocument()
        NSDocumentController.shared.addDocument(targetDocument)
        defer {
            targetDocument.updateChangeCount(.changeCleared)
            if NSDocumentController.shared.documents.contains(where: {
                $0 === targetDocument
            }) {
                targetDocument.close()
            }
        }
        let gate = ProjectDocumentSwitchGate()
        let switchToken = try XCTUnwrap(gate.begin())
        XCTAssertTrue(
            ProjectDocumentTargetPolicy.isReusableShell(
                targetDocument,
                isAssociated: controller.isAssociatedProjectDocument(targetDocument),
                isRegistered: true
            )
        )

        var subscriberRan = false
        let observation = controller.$folderURL.dropFirst().sink { publishedURL in
            guard !subscriberRan,
                  publishedURL?.standardizedFileURL
                      == candidateRoot.standardizedFileURL
            else { return }
            subscriberRan = true
            targetDocument.updateChangeCount(.changeDone)
            XCTAssertTrue(gate.finish(switchToken))
        }
        let committed = controller.commitPreparedFolder(
            preparation,
            finalValidation: {
                gate.isActive(switchToken)
                    && ProjectDocumentTargetPolicy.isReusableShell(
                        targetDocument,
                        isAssociated: controller.isAssociatedProjectDocument(
                            targetDocument
                        ),
                        isRegistered: NSDocumentController.shared.documents.contains {
                            $0 === targetDocument
                        }
                    )
            }
        )
        observation.cancel()

        XCTAssertTrue(subscriberRan)
        XCTAssertFalse(committed)
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(targetDocument.isDocumentEdited)
        XCTAssertEqual(controller.folderURL, previousRoot)
        XCTAssertEqual(controller.projectRootIdentity, previousIdentity)
        XCTAssertEqual(controller.items, previousItems)
        XCTAssertEqual(controller.files, previousFiles)
        XCTAssertEqual(controller.state, previousState)
        XCTAssertTrue(controller.isAssociatedProjectDocument(associatedDocument))
        XCTAssertTrue(ProjectSessionBoundary.hasCurrentRoot(controller))
    }

    func testControllerCreatesInAllSelectionModesAndImmediatelyUpdatesTree() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Notes", isDirectory: true)
        let selectedFile = nested.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: selectedFile)
        let controller = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        controller.openFolder(root)
        try await waitUntilReady(controller)

        let nestedSelection = FolderBrowserSelection.directory(nested)
        let creationAuthorization = try controller.creationAuthorization(
            for: nestedSelection
        )
        XCTAssertTrue(
            controller.creationAuthorizationIsCurrent(
                creationAuthorization,
                for: nestedSelection
            )
        )
        let displacedNested = root.appendingPathComponent(
            "Notes-original",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: nested, to: displacedNested)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: false
        )
        XCTAssertFalse(
            controller.creationAuthorizationIsCurrent(
                creationAuthorization,
                for: nestedSelection
            )
        )
        XCTAssertEqual(
            controller.createMarkdownFile(
                named: "must-not-create.md",
                selection: nestedSelection,
                expectedRootIdentity: creationAuthorization.projectIdentity,
                expectedTargetIdentity: creationAuthorization.targetIdentity,
                openDocument: { _ in XCTFail("replaced target must not open") }
            ),
            .notCreated(.targetDirectoryUnavailable)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: nested.appendingPathComponent("must-not-create.md").path
            )
        )
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.moveItem(at: displacedNested, to: nested)

        var opened: [URL] = []
        let rootResult = controller.createMarkdownFile(
            named: "Root",
            selection: .none,
            openDocument: { opened.append($0) }
        )
        let directoryResult = controller.createMarkdownFile(
            named: "Directory.markdown",
            selection: .directory(nested),
            openDocument: { opened.append($0) }
        )
        let fileResult = controller.createMarkdownFile(
            named: "Sibling.md",
            selection: .file(selectedFile),
            openDocument: { opened.append($0) }
        )

        XCTAssertEqual(rootResult.createdFile?.relativePath, "Root.md")
        XCTAssertEqual(
            directoryResult.createdFile?.relativePath,
            "Notes/Directory.markdown"
        )
        XCTAssertEqual(fileResult.createdFile?.relativePath, "Notes/Sibling.md")
        for result in [rootResult, directoryResult, fileResult] {
            guard case .createdAndOpened = result else {
                return XCTFail("Expected createdAndOpened, got \(result)")
            }
        }
        XCTAssertEqual(
            opened.map(\.lastPathComponent),
            ["Root.md", "Directory.markdown", "Sibling.md"]
        )
        XCTAssertEqual(
            controller.files.map(\.relativePath),
            ["Notes/Directory.markdown", "Notes/Sibling.md", "Root.md"]
        )
        XCTAssertEqual(
            flattenedPaths(in: controller.items),
            [
                "Notes",
                "Notes/Directory.markdown",
                "Notes/existing.txt",
                "Notes/Sibling.md",
                "Root.md",
            ]
        )
        for url in opened {
            XCTAssertEqual(try Data(contentsOf: url), Data())
        }
    }

    func testControllerDistinguishesPreCreationFailureFromPostCreationOpenFailure()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("preserve".utf8).write(to: root.appendingPathComponent("existing.md"))
        let controller = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        controller.openFolder(root)
        try await waitUntilReady(controller)
        let itemsBeforeFailure = controller.items

        let preCreationFailure = controller.createMarkdownFile(
            named: "existing.md",
            openDocument: { _ in XCTFail("Must not open when creation failed") }
        )
        XCTAssertEqual(
            preCreationFailure,
            .notCreated(.alreadyExists(fileName: "existing.md"))
        )
        XCTAssertEqual(controller.items, itemsBeforeFailure)
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("existing.md"),
                encoding: .utf8
            ),
            "preserve"
        )

        let postCreationFailure = controller.createMarkdownFile(
            named: "created.md",
            openDocument: { _ in throw TestFolderOpenError.cannotOpen }
        )
        guard case let .createdButOpeningFailed(file, reason) = postCreationFailure else {
            return XCTFail("Expected a post-creation open failure")
        }
        XCTAssertEqual(file.relativePath, "created.md")
        XCTAssertEqual(reason, TestFolderOpenError.cannotOpen.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(controller.files.contains(file))
        XCTAssertTrue(flattenedPaths(in: controller.items).contains("created.md"))
    }

    func testControllerKeepsCreatedNodeWhileCompletionAwareOpenIsPendingOrFails()
        async throws
    {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = FolderBrowserController(
            persistence: TestFolderBrowserPersistence(),
            restoresSavedFolder: false,
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
        controller.openFolder(root)
        try await waitUntilReady(controller)

        var pendingOpen: FolderDocumentOpenCompletion?
        var finalResult: FolderMarkdownCreationResult?
        controller.createMarkdownFile(
            named: "pending",
            openDocumentWithCompletion: { _, completion in
                pendingOpen = completion
            },
            completion: { finalResult = $0 }
        )

        let createdURL = root.appendingPathComponent("pending.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertTrue(flattenedPaths(in: controller.items).contains("pending.md"))
        XCTAssertNil(finalResult)

        pendingOpen?(.failure(TestFolderOpenError.cannotOpen))
        guard case let .some(.createdButOpeningFailed(file, reason)) = finalResult else {
            return XCTFail("Expected completion-aware opening failure")
        }
        XCTAssertEqual(file.relativePath, "pending.md")
        XCTAssertEqual(reason, TestFolderOpenError.cannotOpen.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertTrue(flattenedPaths(in: controller.items).contains("pending.md"))
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

    func testLaunchFileMenuDoesNotExposeFutureFolderBrowser() throws {
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        XCTAssertTrue(items.filter { $0.title == "打开文件夹…" }.isEmpty)
        for title in ["专注模式", "打字机模式", "放大", "缩小", "实际大小"] {
            XCTAssertTrue(items.filter { $0.title == title }.isEmpty)
        }
    }

    func testLaunchDocumentKeepsFileActionsInTheMacOSMenuBar() throws {
        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "文件")?.submenu)
        XCTAssertEqual(fileMenu.items.filter { $0.title == "打开…" }.count, 1)
        XCTAssertTrue(fileMenu.items.filter { $0.title == "打开文件夹…" }.isEmpty)
        XCTAssertEqual(FinderRevealAction.title, "在 Finder 中显示")
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

    private func flattenedPaths(in items: [FolderProjectItem]) -> [String] {
        items.flatMap { item in
            [item.relativePath] + flattenedPaths(in: item.children ?? [])
        }
    }

    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems(in:)) ?? [])
        }
    }
}

private enum TestFolderOpenError: Error, LocalizedError {
    case cannotOpen

    var errorDescription: String? {
        "测试打开失败。"
    }
}

private final class ClosingTrackingDocument: NSDocument {
    private(set) var closeCount = 0
    private(set) var showCount = 0

    override func showWindows() {
        showCount += 1
        super.showWindows()
    }

    override func close() {
        closeCount += 1
        if NSDocumentController.shared.documents.contains(where: { $0 === self }) {
            super.close()
        }
    }
}

@MainActor
private final class EmptyRecentDocumentPersistence: RecentDocumentPersistence {
    func load() -> [RecentDocumentRecord] { [] }
    func save(_: [RecentDocumentRecord]) {}
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
