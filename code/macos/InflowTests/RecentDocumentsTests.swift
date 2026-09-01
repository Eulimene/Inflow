import AppKit
import XCTest
@testable import Inflow

@MainActor
final class RecentDocumentsTests: XCTestCase {
    func testSecurityScopedAccessLivesWithDocumentAndReleasesExactlyOnce() {
        let document = NSDocument()
        let firstURL = URL(fileURLWithPath: "/tmp/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/second.md")
        var released: [URL] = []

        SecurityScopedDocumentLeaseRegistry.retainActiveAccess(
            to: firstURL,
            for: document,
            stopAccess: { released.append($0) }
        )
        XCTAssertEqual(
            SecurityScopedDocumentLeaseRegistry.activeURL(for: document),
            firstURL
        )
        XCTAssertTrue(released.isEmpty)

        SecurityScopedDocumentLeaseRegistry.retainActiveAccess(
            to: secondURL,
            for: document,
            stopAccess: { released.append($0) }
        )
        XCTAssertEqual(released, [firstURL])
        XCTAssertEqual(
            SecurityScopedDocumentLeaseRegistry.activeURL(for: document),
            secondURL
        )

        SecurityScopedDocumentLeaseRegistry.releaseAccess(for: document)
        XCTAssertEqual(released, [firstURL, secondURL])
        XCTAssertNil(SecurityScopedDocumentLeaseRegistry.activeURL(for: document))

        SecurityScopedDocumentLeaseRegistry.releaseAccess(for: document)
        XCTAssertEqual(released, [firstURL, secondURL])
    }

    func testPolicyDefaultsAndBoundsAreStable() {
        let suiteName = "Inflow.RecentDocumentPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(RecentDocumentPolicy.capacity(in: defaults), 20)
        XCTAssertEqual(RecentDocumentPolicy.openBehavior(in: defaults), .newWindow)

        defaults.set(2, forKey: RecentDocumentPolicy.capacityKey)
        defaults.set(
            MarkdownOpenBehavior.reuseBlankWindow.rawValue,
            forKey: RecentDocumentPolicy.openBehaviorKey
        )
        XCTAssertEqual(RecentDocumentPolicy.capacity(in: defaults), 5)
        XCTAssertEqual(RecentDocumentPolicy.openBehavior(in: defaults), .reuseBlankWindow)

        defaults.set(500, forKey: RecentDocumentPolicy.capacityKey)
        defaults.set("retired", forKey: RecentDocumentPolicy.openBehaviorKey)
        XCTAssertEqual(RecentDocumentPolicy.capacity(in: defaults), 50)
        XCTAssertEqual(RecentDocumentPolicy.openBehavior(in: defaults), .newWindow)
    }

    func testRecentDocumentsAreUniqueBoundedPersistentAndIndividuallyRemovable() throws {
        let alpha = record("/tmp/inflow-recent/alpha.md", bookmark: Data([1]))
        let beta = record("/tmp/inflow-recent/beta.md", bookmark: Data([2]))
        let delta = record("/tmp/inflow-recent/delta.md", bookmark: Data([4]))
        let epsilon = record("/tmp/inflow-recent/epsilon.md", bookmark: Data([5]))
        let zeta = record("/tmp/inflow-recent/zeta.md", bookmark: Data([6]))
        let gammaURL = URL(fileURLWithPath: "/tmp/inflow-recent/gamma.md")
        let persistence = TestRecentDocumentPersistence(
            records: [alpha, beta, alpha, delta, epsilon, zeta]
        )
        var capacity = 5
        let controller = RecentDocumentsController(
            persistence: persistence,
            capacity: { capacity },
            bookmarkData: { _ in Data([3]) },
            systemSynchronizer: { _ in }
        )

        XCTAssertEqual(controller.entries.map(\.record), [alpha, beta, delta, epsilon, zeta])
        XCTAssertEqual(persistence.records, [alpha, beta, delta, epsilon, zeta])

        controller.note(gammaURL)
        let gamma = record(gammaURL.path, bookmark: Data([3]))
        XCTAssertEqual(controller.entries.map(\.record), [gamma, alpha, beta, delta, epsilon])
        XCTAssertEqual(persistence.records, [gamma, alpha, beta, delta, epsilon])

        capacity = 6
        controller.applyCapacity()
        XCTAssertEqual(
            controller.entries.map(\.record),
            [gamma, alpha, beta, delta, epsilon]
        )

        controller.remove(try XCTUnwrap(controller.entries.first))
        XCTAssertEqual(controller.entries.map(\.record), [alpha, beta, delta, epsilon])
        XCTAssertEqual(persistence.records, [alpha, beta, delta, epsilon])

        controller.note(URL(fileURLWithPath: zeta.exactPath))
        XCTAssertEqual(
            controller.entries.map(\.id),
            [zeta.exactPath, alpha.exactPath, beta.exactPath, delta.exactPath, epsilon.exactPath]
        )
        XCTAssertFalse(try XCTUnwrap(controller.entries.first).isAvailable)

        controller.clear()
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertTrue(persistence.records.isEmpty)
    }

    func testRecentDocumentsPhysicallyDeduplicateHardLinks() throws {
        try withTemporaryDirectory { directory in
            let original = directory.appendingPathComponent("original.md")
            let alias = directory.appendingPathComponent("alias.md")
            try Data("same inode".utf8).write(to: original)
            try FileManager.default.linkItem(at: original, to: alias)
            let first = record(original.path, bookmark: Data([1]))
            let second = record(alias.path, bookmark: Data([2]))
            let persistence = TestRecentDocumentPersistence(records: [first, second])
            let controller = RecentDocumentsController(
                persistence: persistence,
                capacity: { 20 },
                systemSynchronizer: { _ in }
            )

            XCTAssertEqual(controller.entries.map(\.record), [first])
            XCTAssertEqual(persistence.records, [first])
        }
    }

    func testMissingOrMovedBookmarkNeverSearchesForAnAlternateLocation() {
        let exactPath = "/documents/original.md"
        let record = RecentDocumentRecord(exactPath: exactPath, bookmark: Data([7]))
        let moved = URL(fileURLWithPath: "/documents/moved.md")

        XCTAssertNil(
            RecentDocumentsController.exactResolvedURL(
                for: record,
                fileExists: { _ in false },
                resolveBookmark: { _ in moved }
            )
        )
        XCTAssertNil(
            RecentDocumentsController.exactResolvedURL(
                for: record,
                fileExists: { _ in true },
                resolveBookmark: { _ in moved }
            )
        )
        XCTAssertEqual(
            RecentDocumentsController.exactResolvedURL(
                for: record,
                fileExists: { _ in true },
                resolveBookmark: { _ in URL(fileURLWithPath: exactPath) }
            )?.path,
            exactPath
        )
    }

    func testBlankWindowReuseNeverSelectsEditedOrNamedDocuments() {
        let named = NSDocument()
        named.fileURL = URL(fileURLWithPath: "/tmp/named.md")
        let edited = NSDocument()
        edited.updateChangeCount(.changeDone)
        let blank = NSDocument()

        XCTAssertNil(
            DocumentWindowReusePolicy.reusableBlankDocument(
                from: [blank],
                behavior: .newWindow
            )
        )
        XCTAssertTrue(
            DocumentWindowReusePolicy.reusableBlankDocument(
                from: [named, edited, blank],
                behavior: .reuseBlankWindow
            ) === blank
        )
        XCTAssertNil(
            DocumentWindowReusePolicy.reusableBlankDocument(
                from: [named, edited],
                behavior: .reuseBlankWindow
            )
        )
    }

    func testCloseAuthorizationIsSingleFlightPerDocument() throws {
        let document = DeferredCloseAuthorizationDocument()
        document.updateChangeCount(.changeDone)
        var firstResults: [Bool] = []
        var secondResults: [Bool] = []

        DocumentCloseAuthorization.request(for: document) {
            firstResults.append($0)
        }
        DocumentCloseAuthorization.request(for: document) {
            secondResults.append($0)
        }

        XCTAssertTrue(DocumentCloseAuthorization.hasPendingRequests)
        XCTAssertEqual(document.requestCount, 1)
        XCTAssertTrue(firstResults.isEmpty)
        XCTAssertEqual(secondResults, [false])

        try document.finishRequest(shouldClose: true)
        XCTAssertEqual(firstResults, [true])
        XCTAssertFalse(DocumentCloseAuthorization.hasPendingRequests)
    }

    func testCloseAuthorizationRemainsSingleFlightAfterSaveClearsEditedState() throws {
        let document = DeferredCloseAuthorizationDocument()
        document.updateChangeCount(.changeDone)
        var firstResults: [Bool] = []
        var secondResults: [Bool] = []

        DocumentCloseAuthorization.request(for: document) {
            firstResults.append($0)
        }
        document.updateChangeCount(.changeCleared)
        DocumentCloseAuthorization.request(for: document) {
            secondResults.append($0)
        }

        XCTAssertTrue(DocumentCloseAuthorization.hasPendingRequests)
        XCTAssertEqual(document.requestCount, 1)
        XCTAssertTrue(firstResults.isEmpty)
        XCTAssertEqual(secondResults, [false])

        try document.finishRequest(shouldClose: true)
        XCTAssertEqual(firstResults, [true])
        XCTAssertFalse(DocumentCloseAuthorization.hasPendingRequests)
    }

    func testOpenPreflightAcceptsUTF8AndPreservesUnsupportedOriginalBytes() throws {
        XCTAssertEqual(
            try MarkdownOpenPreflight.inspect(Data("# 你好\n".utf8)),
            .supported
        )

        let unsupported = Data([0x48, 0x69, 0x20, 0xFF, 0xFE, 0x00])
        XCTAssertEqual(
            try MarkdownOpenPreflight.inspect(unsupported),
            .unsupportedEncoding(originalData: unsupported)
        )
    }

    func testExternalOpenRouterAcceptsOnlySupportedLocalMarkdownURLs() {
        let markdown = URL(fileURLWithPath: "/tmp/Notes.MD")
        let longExtension = URL(fileURLWithPath: "/tmp/guide.Markdown")
        let text = URL(fileURLWithPath: "/tmp/plain.txt")
        let remote = URL(string: "https://example.com/readme.md")!

        XCTAssertEqual(
            RecentDocumentsController.supportedExternalDocumentURLs(
                from: [markdown, longExtension, text, remote]
            ),
            [markdown, longExtension]
        )
    }

    func testOpenRouteDeduplicatesBeforeGivingBlankToFirstNewFile() {
        let root = URL(fileURLWithPath: "/tmp/inflow-open-router", isDirectory: true)
        let existing = root.appendingPathComponent("existing.md")
        let equivalentExisting = URL(
            fileURLWithPath: root.appendingPathComponent("nested/../existing.md").path
        )
        let firstNew = root.appendingPathComponent("first-new.markdown")
        let secondNew = root.appendingPathComponent("second-new.md")

        let plan = DocumentOpenRouter.plan(
            inputURLs: [
                equivalentExisting,
                existing,
                firstNew,
                firstNew,
                secondNew,
            ],
            openedDocumentURLs: [existing, equivalentExisting, existing],
            openedProjectURLs: [],
            hasReusableBlankWindow: true
        )

        XCTAssertEqual(
            plan.actions,
            [
                .focusExistingFile(existing.standardizedFileURL),
                .openFile(
                    firstNew.standardizedFileURL,
                    reuseBlank: .reusableBlankWindow
                ),
                .openFile(secondNew.standardizedFileURL, reuseBlank: nil),
            ]
        )
        XCTAssertTrue(plan.rejections.isEmpty)
    }

    func testOpenRouteDoesNotReuseDraftWindow() {
        let draft = NSDocument()
        draft.updateChangeCount(.changeDone)
        let reusableDraft = DocumentWindowReusePolicy.reusableBlankDocument(
            from: [draft]
        )
        let url = URL(fileURLWithPath: "/tmp/inflow-open-router/draft-safe.md")

        let plan = DocumentOpenRouter.plan(
            inputURLs: [url],
            openedDocumentURLs: [],
            openedProjectURLs: [],
            hasReusableBlankWindow: reusableDraft != nil
        )

        XCTAssertNil(reusableDraft)
        XCTAssertEqual(
            plan.actions,
            [.openFile(url.standardizedFileURL, reuseBlank: nil)]
        )
    }

    func testOpenRouteFocusesExistingProjectWithoutConsumingBlank() {
        let existingProject = URL(
            fileURLWithPath: "/tmp/inflow-open-router/project",
            isDirectory: true
        )
        let equivalentProject = URL(
            fileURLWithPath: "/tmp/inflow-open-router/child/../project",
            isDirectory: true
        )

        let focusPlan = DocumentOpenRouter.plan(
            inputURLs: [equivalentProject, existingProject],
            openedDocumentURLs: [],
            openedProjectURLs: [existingProject, equivalentProject, existingProject],
            hasReusableBlankWindow: true,
            classifyTarget: { _ in .projectDirectory }
        )
        XCTAssertEqual(
            focusPlan.actions,
            [.focusExistingProject(existingProject.standardizedFileURL)]
        )

        let newProject = URL(
            fileURLWithPath: "/tmp/inflow-open-router/new-project",
            isDirectory: true
        )
        let projectPlan = DocumentOpenRouter.plan(
            inputURLs: [newProject],
            openedDocumentURLs: [],
            openedProjectURLs: [],
            hasReusableBlankWindow: true
        )
        XCTAssertEqual(
            projectPlan.actions,
            [
                .openProject(
                    newProject.standardizedFileURL,
                    reuseBlank: .reusableBlankWindow
                ),
            ]
        )

        let newFile = URL(fileURLWithPath: "/tmp/inflow-open-router/after-project.md")
        let filePlan = DocumentOpenRouter.plan(
            inputURLs: [newFile],
            openedDocumentURLs: [],
            openedProjectURLs: [],
            hasReusableBlankWindow: true
        )
        XCTAssertEqual(
            filePlan.actions,
            [
                .openFile(
                    newFile.standardizedFileURL,
                    reuseBlank: .reusableBlankWindow
                ),
            ]
        )
    }

    func testOpenRouteSafelyRejectsOutOfScopeDirectoryBatches() {
        let firstDirectory = URL(
            fileURLWithPath: "/tmp/inflow-open-router/first-project",
            isDirectory: true
        )
        let secondDirectory = URL(
            fileURLWithPath: "/tmp/inflow-open-router/second-project",
            isDirectory: true
        )
        let markdown = URL(fileURLWithPath: "/tmp/inflow-open-router/kept.md")

        let mixedPlan = DocumentOpenRouter.plan(
            inputURLs: [firstDirectory, markdown],
            openedDocumentURLs: [],
            openedProjectURLs: [],
            hasReusableBlankWindow: true
        )
        XCTAssertEqual(
            mixedPlan.actions,
            [
                .openFile(
                    markdown.standardizedFileURL,
                    reuseBlank: .reusableBlankWindow
                ),
            ]
        )
        XCTAssertEqual(
            mixedPlan.rejections,
            [
                DocumentOpenRouteRejection(
                    url: firstDirectory.standardizedFileURL,
                    reason: .mixedFilesAndDirectories
                ),
            ]
        )

        let multipleDirectoryPlan = DocumentOpenRouter.plan(
            inputURLs: [firstDirectory, secondDirectory],
            openedDocumentURLs: [],
            openedProjectURLs: [],
            hasReusableBlankWindow: true
        )
        XCTAssertTrue(multipleDirectoryPlan.actions.isEmpty)
        XCTAssertEqual(
            multipleDirectoryPlan.rejections.map(\.reason),
            [.multipleDirectories, .multipleDirectories]
        )
    }

    func testOpenRouteDoesNotPhysicallyDeduplicateHardLinks() throws {
        try withTemporaryDirectory { directory in
            let original = directory.appendingPathComponent("original.md")
            let hardLink = directory.appendingPathComponent("hard-link.md")
            try Data("same inode".utf8).write(to: original)
            try FileManager.default.linkItem(at: original, to: hardLink)

            let plan = DocumentOpenRouter.plan(
                inputURLs: [original, hardLink],
                openedDocumentURLs: [],
                openedProjectURLs: [],
                hasReusableBlankWindow: true
            )

            XCTAssertEqual(
                plan.actions,
                [
                    .openFile(original, reuseBlank: .reusableBlankWindow),
                    .openFile(hardLink, reuseBlank: nil),
                ]
            )
        }
    }

    func testControllerDelegatesProjectFocusAndOpenThroughCallbacks() {
        let existingProject = URL(
            fileURLWithPath: "/tmp/inflow-open-router/existing-project",
            isDirectory: true
        )
        let newProject = URL(
            fileURLWithPath: "/tmp/inflow-open-router/new-project",
            isDirectory: true
        )
        var focused: [URL] = []
        var opened: [(URL, NSDocument?)] = []
        let controller = RecentDocumentsController(
            persistence: TestRecentDocumentPersistence(records: []),
            openBehavior: { .newWindow },
            systemSynchronizer: { _ in },
            openedProjectURLs: { [existingProject, existingProject] },
            focusExistingProject: { focused.append($0) },
            openProject: { opened.append(($0, $1)) }
        )

        let focusPlan = controller.openExternalDocuments([existingProject])
        let openPlan = controller.openExternalDocuments([newProject])

        XCTAssertEqual(focused, [existingProject.standardizedFileURL])
        XCTAssertEqual(opened.map(\.0), [newProject.standardizedFileURL])
        XCTAssertNil(opened.first?.1)
        XCTAssertEqual(
            focusPlan.actions,
            [.focusExistingProject(existingProject.standardizedFileURL)]
        )
        XCTAssertEqual(
            openPlan.actions,
            [.openProject(newProject.standardizedFileURL, reuseBlank: nil)]
        )
    }

    func testUnsupportedEncodingRecoveryUsesFrozenProductCopy() {
        XCTAssertEqual(UnsupportedEncodingRecoveryUI.title, "不支持这个文件的编码")
        XCTAssertEqual(
            UnsupportedEncodingRecoveryUI.message,
            "Inflow 不会猜测编码或覆盖原文件。"
        )
        XCTAssertEqual(UnsupportedEncodingRecoveryUI.showInFinderTitle, "在 Finder 中显示")
        XCTAssertEqual(UnsupportedEncodingRecoveryUI.copyOriginalTitle, "复制原文件…")
        XCTAssertEqual(UnsupportedEncodingRecoveryUI.cancelTitle, "取消")
    }

    func testUnsupportedEncodingCopyPreservesSourceAndExactOriginalBytes() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("legacy.md")
            let target = directory.appendingPathComponent("legacy-copy.md")
            let original = Data([0xFF, 0xFE, 0x41, 0x00, 0x0D, 0x00, 0x0A, 0x00])
            try original.write(to: source)

            try UnsupportedEncodingRecoveryCopy.write(
                originalData: original,
                sourceURL: source,
                targetURL: target,
                expectedTarget: HTMLExportTargetSnapshot.capture(target)
            )

            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testUnsupportedEncodingCopyRejectsSourceAndChangedTarget() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("legacy.md")
            let target = directory.appendingPathComponent("copy.md")
            let original = Data([0xFF, 0xFE])
            try original.write(to: source)

            XCTAssertThrowsError(
                try UnsupportedEncodingRecoveryCopy.write(
                    originalData: original,
                    sourceURL: source,
                    targetURL: source,
                    expectedTarget: HTMLExportTargetSnapshot.capture(source)
                )
            ) { error in
                XCTAssertEqual(
                    error as? UnsupportedEncodingRecoveryCopyError,
                    .sourceDestinationConflict
                )
            }
            XCTAssertEqual(try Data(contentsOf: source), original)

            let hardLink = directory.appendingPathComponent("legacy-alias.md")
            try FileManager.default.linkItem(at: source, to: hardLink)
            XCTAssertThrowsError(
                try UnsupportedEncodingRecoveryCopy.write(
                    originalData: original,
                    sourceURL: source,
                    targetURL: hardLink,
                    expectedTarget: HTMLExportTargetSnapshot.capture(hardLink)
                )
            ) { error in
                XCTAssertEqual(
                    error as? UnsupportedEncodingRecoveryCopyError,
                    .sourceDestinationConflict
                )
            }
            XCTAssertEqual(try Data(contentsOf: source), original)

            let expectedTarget = try HTMLExportTargetSnapshot.capture(target)
            XCTAssertThrowsError(
                try UnsupportedEncodingRecoveryCopy.write(
                    originalData: original,
                    sourceURL: source,
                    targetURL: target,
                    expectedTarget: expectedTarget,
                    beforeCommit: { try Data("other".utf8).write(to: target) }
                )
            ) { error in
                XCTAssertEqual(
                    error as? UnsupportedEncodingRecoveryCopyError,
                    .targetChanged
                )
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertEqual(try Data(contentsOf: target), Data("other".utf8))
        }
    }

    @MainActor
    func testFileMenuRoutesOpenWithoutInstallingManagedRecentDocuments() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "文件")?.submenu)
        let openItems = fileMenu.items.filter { $0.title == "打开…" }
        XCTAssertEqual(openItems.count, 1)
        XCTAssertEqual(openItems.first?.keyEquivalent, "o")
        XCTAssertTrue(openItems.first?.target is RecentDocumentsController)
        let managedRecentItems = fileMenu.items.flatMap { item in
            [item] + (item.submenu?.items ?? [])
        }.filter {
            $0.target is RecentDocumentsController && $0.title != "打开…"
        }
        XCTAssertTrue(managedRecentItems.isEmpty)
    }

    private func record(_ path: String, bookmark: Data?) -> RecentDocumentRecord {
        RecentDocumentRecord(
            exactPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            bookmark: bookmark
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-unsupported-encoding-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class DeferredCloseAuthorizationDocument: NSDocument {
    private var callbackDelegate: AnyObject?
    private var callbackSelector: Selector?
    private var callbackContext: UnsafeMutableRawPointer?
    private(set) var requestCount = 0

    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        requestCount += 1
        callbackDelegate = delegate as AnyObject
        callbackSelector = shouldCloseSelector
        callbackContext = contextInfo
    }

    func finishRequest(shouldClose: Bool) throws {
        let delegate = try XCTUnwrap(callbackDelegate)
        let selector = try XCTUnwrap(callbackSelector)
        let method = try XCTUnwrap(class_getInstanceMethod(type(of: delegate), selector))
        typealias Callback = @convention(c) (
            AnyObject,
            Selector,
            NSDocument,
            Bool,
            UnsafeMutableRawPointer?
        ) -> Void
        let callback = unsafeBitCast(method_getImplementation(method), to: Callback.self)
        callback(delegate, selector, self, shouldClose, callbackContext)
        callbackDelegate = nil
        callbackSelector = nil
        callbackContext = nil
    }
}

@MainActor
private final class TestRecentDocumentPersistence: RecentDocumentPersistence {
    var records: [RecentDocumentRecord]

    init(records: [RecentDocumentRecord]) {
        self.records = records
    }

    func load() -> [RecentDocumentRecord] { records }

    func save(_ records: [RecentDocumentRecord]) {
        self.records = records
    }
}
