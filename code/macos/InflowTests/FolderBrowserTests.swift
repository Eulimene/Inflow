import AppKit
import XCTest
@testable import Inflow

@MainActor
final class FolderBrowserTests: XCTestCase {
    func testProjectDocumentSwitchGateRejectsConcurrentTransactions() throws {
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
    }

    func testLaunchPolicyCreatesAnEditableUntitledDocumentWithoutOpeningAFile() {
        var createdDocumentCount = 0
        let delegate = InflowApplicationDelegate { _ in
            createdDocumentCount += 1
        }

        XCTAssertTrue(InflowLaunchPolicy.presentsEditableDocumentFirst)
        XCTAssertTrue(InflowLaunchPolicy.automaticallyOpensUntitledDocument)
        XCTAssertTrue(delegate.applicationShouldOpenUntitledFile(NSApp))
        XCTAssertTrue(delegate.applicationOpenUntitledFile(NSApp))
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
    }

    func testLaunchIntegrationsWaitUntilApplicationDidFinishLaunching() {
        var installationCount = 0
        let delegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in },
            installLaunchIntegrations: { _ in
                installationCount += 1
            }
        )

        XCTAssertEqual(installationCount, 0)

        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApp
        )
        delegate.applicationDidFinishLaunching(notification)
        delegate.applicationDidFinishLaunching(notification)

        XCTAssertEqual(installationCount, 1)
    }

    func testDockReopenCreatesAnUntitledDocumentOnlyWhenNoWindowIsVisible() {
        var createdDocumentCount = 0
        let delegate = InflowApplicationDelegate { _ in
            createdDocumentCount += 1
        }

        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        )
        XCTAssertEqual(createdDocumentCount, 0)
        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
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
        XCTAssertEqual(
            controller.validatedFolderURLForOpening(candidate)?.path,
            candidate.path
        )
        XCTAssertEqual(controller.folderURL?.path, root.path)
        XCTAssertEqual(started.map(\.path), [root.path, candidate.path])

        let preparation: FolderProjectOpenPreparation = try await withCheckedThrowingContinuation {
            continuation in
            _ = controller.prepareFolderForOpening(candidate) {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(controller.folderURL?.path, root.path)
        XCTAssertEqual(preparation.snapshot.markdownFiles.map(\.relativePath), ["two.md"])
        XCTAssertTrue(controller.commitPreparedFolder(preparation))
        XCTAssertEqual(controller.folderURL?.path, candidate.path)
        XCTAssertEqual(controller.files.map(\.relativePath), ["two.md"])

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

    override func close() {
        closeCount += 1
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
