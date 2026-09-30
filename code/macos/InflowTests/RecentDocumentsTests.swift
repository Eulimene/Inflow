import AppKit
import SwiftUI
import XCTest
import UniformTypeIdentifiers
@testable import Inflow

@MainActor
final class RecentDocumentsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testRecoveryTabPlaceholdersOpenOnlyWhenSelected() {
        let tabs = DocumentWindowTabs()
        var opens = 0
        var dismissals = 0
        let windowCount = NSApp.windows.count
        let drafts = (0..<100).map { index in
            RecoveryDraftPlaceholder(id: UUID(), targetID: UUID(), locations: [], title: "Draft \(index)")
        }
        for draft in drafts { tabs.addPending(draft, dismiss: { dismissals += 1 }) { opens += 1 } }
        XCTAssertEqual(tabs.pending.count, 100)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(NSApp.windows.count, windowCount, "Startup must not allocate one window/editor per draft")
        tabs.openPending(drafts[70].id)
        tabs.openPending(drafts[70].id)
        XCTAssertEqual(opens, 1)
        tabs.closePending(drafts[0].id)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(opens, 1, "Closing an unloaded draft must not load it")
        tabs.removePending(drafts[70].id)
        XCTAssertEqual(tabs.pending.count, 98)

        let windows = (0..<2).map { _ in
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        }
        windows.forEach { $0.isReleasedWhenClosed = false; tabs.register($0) }
        defer { windows.forEach { $0.close() } }
        let first = DocumentWindowTabs.TabID.window(ObjectIdentifier(windows[0]))
        let second = DocumentWindowTabs.TabID.window(ObjectIdentifier(windows[1]))
        XCTAssertTrue(tabs.targets(.left, relativeTo: first).isEmpty)
        XCTAssertEqual(tabs.targets(.left, relativeTo: second), [first])
        XCTAssertEqual(tabs.targets(.others, relativeTo: first).count, 99)
        XCTAssertEqual(tabs.targets(.left, relativeTo: .pending(drafts[1].id)), [first, second])
        tabs.close(.left, relativeTo: second)
        XCTAssertEqual(tabs.items.map(\.id), [ObjectIdentifier(windows[1])])
        tabs.close(.right, relativeTo: second)
        XCTAssertTrue(tabs.pending.isEmpty)
        XCTAssertEqual(opens, 1, "Batch closing recovery tabs must never materialize their contents")
        XCTAssertEqual(dismissals, 99)
        XCTAssertTrue(tabs.targets(.others, relativeTo: second).isEmpty)
    }

    func testTitlebarTabsShareWindowControlRowAndPreserveWindowGeometry() async throws {
        let first = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 820, height: 520),
            styleMask: first.styleMask, backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        first.contentView = NSHostingView(rootView: DocumentTitlebar(isEnabled: true) {
            HStack { Button("目录树") {}; Text("Untitled"); Spacer(); Button("+") {} }
        })
        first.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        first.contentView?.layoutSubtreeIfNeeded()
        let accessory = try XCTUnwrap(first.titlebarAccessoryViewControllers.first)
        XCTAssertEqual(accessory.layoutAttribute, .left)
        let close = try XCTUnwrap(first.standardWindowButton(.closeButton))
        let controlRect = close.convert(close.bounds, to: nil)
        let titlebarRect = accessory.view.convert(accessory.view.bounds, to: nil)
        XCTAssertEqual(controlRect.midY, titlebarRect.midY, accuracy: 12)
        XCTAssertGreaterThanOrEqual(titlebarRect.minX, controlRect.maxX)
        XCTAssertEqual(first.tabbingMode, .disallowed)
        if let screen = first.screen {
            first.setFrame(screen.visibleFrame, display: true)
            first.contentView?.layoutSubtreeIfNeeded()
            let expandedRect = accessory.view.convert(accessory.view.bounds, to: nil)
            let expandedClose = close.convert(close.bounds, to: nil)
            XCTAssertEqual(expandedRect.midY, expandedClose.midY, accuracy: 12)
            XCTAssertLessThanOrEqual(expandedRect.maxX, first.frame.width + 1)
            XCTAssertEqual(accessory.layoutAttribute, .left)
        }
        // During a native full-screen transition the style mask can lag the
        // notification. A resize must not move controls back to the hidden row.
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: first)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        XCTAssertEqual(accessory.layoutAttribute, .bottom)
        XCTAssertEqual(accessory.fullScreenMinHeight, accessory.view.frame.height)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: first)
        XCTAssertEqual(accessory.layoutAttribute, .left)
        XCTAssertEqual(accessory.fullScreenMinHeight, 0)
        let tabs = DocumentWindowTabs.shared
        tabs.register(second)
        let item = try XCTUnwrap(tabs.items.first { $0.window === second })
        let frame = first.frame
        tabs.select(item)
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(second.isVisible)
        XCTAssertEqual(second.frame, frame)
        XCTAssertFalse(second.tabGroup?.isTabBarVisible == true)
    }

    func testTerminationDelegateNeverCancelsAnApprovedDisposableDraftQuit() throws {
        XCTAssertEqual(
            InflowTerminationPolicy.replyAfterDocumentCloseApproval,
            .terminateNow,
            "short-lived Inflow UI work must not turn the approved Quit command into a no-op"
        )
        XCTAssertTrue(InflowTerminationPolicy.terminatesAfterLastWindowClosed)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousStore = TemporaryDocumentDrafts.store
        let id = UUID()
        let document = NSDocument()
        var latest = "first"
        TemporaryDocumentDrafts.store = TemporaryDocumentDraftStore(rootURL: root)
        TemporaryDocumentDrafts.register(id, owner: document) {
            DocumentRecoveryRecord(id: id, document: MarkdownDocument(text: latest), originalURL: nil,
                selectedUTF16Range: NSRange(location: latest.utf16.count, length: 0), viewMode: .preview, verticalScrollOffset: 0)
        }
        defer {
            TemporaryDocumentDrafts.unregister(id)
            TemporaryDocumentDrafts.store = previousStore
            try? FileManager.default.removeItem(at: root)
        }
        latest = "last keystroke😀"
        TemporaryDocumentDrafts.installQuitReview()
        let probe = DraftQuitReviewProbe()
        NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: "Must not present a save review", cancellable: true,
            delegate: probe, didReviewAllSelector: #selector(DraftQuitReviewProbe.reviewed(_:approved:context:)), contextInfo: nil)
        XCTAssertEqual(probe.approved, true)
        XCTAssertEqual(try TemporaryDocumentDrafts.store.records().first(where: { $0.id == id })?.text, latest)
        // A failed checkpoint must preserve the last successful draft.
        let stagedStore = TemporaryDocumentDrafts.store
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data("original file".utf8).write(to: blockedRoot)
        TemporaryDocumentDrafts.store = TemporaryDocumentDraftStore(rootURL: blockedRoot)
        latest = "newer text"
        XCTAssertThrowsError(try TemporaryDocumentDrafts.checkpoint(owner: document))
        XCTAssertEqual(try String(contentsOf: blockedRoot, encoding: .utf8), "original file")
        XCTAssertEqual(try stagedStore.records().first(where: { $0.id == id })?.text, "last keystroke😀")
        TemporaryDocumentDrafts.store = stagedStore
        latest = ""
        try TemporaryDocumentDrafts.checkpoint(owner: document)
        XCTAssertFalse(try stagedStore.records().contains { $0.id == id }, "Clearing a draft after a cancelled quit must not restore stale content for that document")
        let delegate = InflowApplicationDelegate { _ in }
        XCTAssertTrue(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
            "closing the final document window must terminate the application"
        )
    }

    func testDocumentWindowResolutionNeverDisablesTheStandardCloseButton() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let closeButton = window.standardWindowButton(.closeButton)
        XCTAssertTrue(closeButton?.isEnabled == true)
        window.contentView = NSHostingView(
            rootView: DocumentWindowResolver(onResolve: { _ in true })
        )
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(closeButton?.isEnabled == true)
        window.orderOut(nil)
    }

    func testDocumentWindowZoomPreservesMinimizeAndRestore() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        let controls = DocumentWindowControls.WindowView()
        window.contentView = controls
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.collectionBehavior.contains(.managed))
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        XCTAssertTrue(zoom.isEnabled)
        let originalFrame = window.frame
        window.performZoom(nil)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertNotEqual(window.frame, originalFrame)
        XCTAssertTrue(minimize.isEnabled)
        let minimized = expectation(forNotification: NSWindow.didMiniaturizeNotification, object: window)
        minimize.performClick(nil)
        await fulfillment(of: [minimized], timeout: 5)
        XCTAssertTrue(window.isMiniaturized)
        let restored = expectation(forNotification: NSWindow.didDeminiaturizeNotification, object: window)
        let tabs = DocumentWindowTabs()
        tabs.register(window)
        var blankRequests = 0
        let delegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in blankRequests += 1 },
            hasOpenDocuments: { true },
            restoreDocumentWindow: { tabs.restoreSelectedWindow() }
        )
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(blankRequests, 0, "Dock reopen must restore the minimized document")
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertFalse(window.isMiniaturized)
        XCTAssertTrue(minimize.isEnabled)
        window.performZoom(nil)
        XCTAssertEqual(window.frame, originalFrame)
        // Repeated SwiftUI updates must preserve the same window policy.
        controls.configureWindow()
        XCTAssertTrue(minimize.isEnabled)
    }

    func testDocumentWindowRefreshDoesNotInvalidateNativeWindowCommands() async throws {
        let window = WindowConfigurationProbe(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.collectionBehavior = [.managed, .fullScreenNone, .fullScreenAllowsTiling]
        let controls = DocumentWindowControls.WindowView()
        window.contentView = controls
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAllowsTiling))
        XCTAssertTrue(window.collectionBehavior.contains(.managed))

        window.styleWrites = 0
        window.behaviorWrites = 0
        // Editing, recovery and preference updates can all refresh this view
        // while AppKit is tracking its dynamically populated Window menu.
        for _ in 0..<20 { controls.configureWindow() }
        XCTAssertEqual(window.styleWrites, 0, "Unchanged style must not invalidate AppKit window commands")
        XCTAssertEqual(window.behaviorWrites, 0, "Unchanged behavior must not invalidate AppKit tiling commands")

        // Reattachment must still configure a different document window.
        let other = WindowConfigurationProbe(
            contentRect: window.frame, styleMask: [.titled, .resizable],
            backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.contentView = controls
        XCTAssertTrue(other.styleMask.contains(.miniaturizable))
        XCTAssertTrue(other.collectionBehavior.contains(.fullScreenPrimary))

        let previousMainMenu = NSApp.mainMenu
        let previousWindowMenu = NSApp.windowsMenu
        let controller = NativeWindowMenuController()
        defer {
            controller.stop()
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowMenu
        }
        let mainMenu = NSMenu(title: "Test application")
        let windowItem = mainMenu.addItem(withTitle: "窗口", action: nil, keyEquivalent: "")
        let generated = NSMenu(title: "窗口")
        generated.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = generated
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = generated
        controller.install()
        controller.attachToMainMenu()
        let native = try XCTUnwrap(controller.menu)
        XCTAssertFalse(native === generated)
        XCTAssertIdentical(windowItem.submenu, native)
        XCTAssertIdentical(NSApp.windowsMenu, native)
        // Stand-ins for items AppKit inserts after menu tracking starts.
        let fill = native.addItem(withTitle: "填充", action: nil, keyEquivalent: "")
        let center = native.addItem(withTitle: "居中", action: nil, keyEquivalent: "")
        generated.removeAllItems()
        XCTAssertTrue(native.items.contains { $0 === fill })
        XCTAssertTrue(native.items.contains { $0 === center })

        // A scene change may also replace the generated submenu itself.
        let replacement = NSMenu(title: "窗口")
        windowItem.submenu = replacement
        NSApp.windowsMenu = replacement
        for _ in 0..<50 where windowItem.submenu !== native || NSApp.windowsMenu !== native {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertIdentical(windowItem.submenu, native)
        XCTAssertIdentical(NSApp.windowsMenu, native)
        XCTAssertTrue(native.items.contains { $0 === fill })
        XCTAssertTrue(native.items.contains { $0 === center })
    }

    func testProjectDocumentsReuseTheSelectedFolderSecurityScope() {
        XCTAssertFalse(
            DocumentSecurityScopePolicy.shouldStartFileScopedAccess(
                hasProjectAuthorization: true
            )
        )
        XCTAssertTrue(
            DocumentSecurityScopePolicy.shouldStartFileScopedAccess(
                hasProjectAuthorization: false
            )
        )
    }

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

    func testOpenPreflightAcceptsUTF8AndPreservesUnsupportedOriginalBytes() async throws {
        XCTAssertEqual(
            try MarkdownOpenPreflight.inspect(Data("# 你好\n".utf8)),
            .supported
        )

        let unsupported = Data([0x48, 0x69, 0x20, 0xFF, 0xFE, 0x00])
        XCTAssertEqual(
            try MarkdownOpenPreflight.inspect(unsupported),
            .unsupportedEncoding(originalData: unsupported)
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inflow.ProjectOpenAuthorization.\(UUID().uuidString)")
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let target = project.appendingPathComponent("target.md")
        let outside = root.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Project target\n".utf8).write(to: target)
        try Data("# Outside secret\n".utf8).write(to: outside)

        let authorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: target,
                projectRoot: project
            )
        )
        XCTAssertEqual(
            authorization.resolvedTargetURL,
            target.resolvingSymlinksInPath().standardizedFileURL
        )
        XCTAssertTrue(authorization.isCurrent())
        let authorizedInspection = try await MarkdownOpenPreflightWorker().inspect(
            target,
            authorization: authorization
        )
        XCTAssertEqual(authorizedInspection.preflight, .supported)
        XCTAssertEqual(
            authorizedInspection.authorizedData,
            Data("# Project target\n".utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
        XCTAssertFalse(
            authorization.isCurrent(),
            "ctime-only metadata bookkeeping must invalidate the exact old snapshot"
        )
        let metadataRefreshedAuthorization = try XCTUnwrap(
            authorization.refreshedAfterVerifiedRead(
                expectedData: Data("# Project target\n".utf8)
            )
        )
        XCTAssertTrue(metadataRefreshedAuthorization.isCurrent())
        XCTAssertNil(
            authorization.refreshedAfterVerifiedRead(
                expectedData: Data("# Different bytes\n".utf8)
            ),
            "a ctime refresh must still verify the descriptor-read bytes"
        )

        let oversized = project.appendingPathComponent("oversized.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(
            atOffset: UInt64(PreviewLocalFileReader.maximumBytes + 1)
        )
        try oversizedHandle.close()
        let oversizedAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: oversized,
                projectRoot: project
            )
        )
        do {
            _ = try await MarkdownOpenPreflightWorker().inspect(
                oversized,
                authorization: oversizedAuthorization
            )
            XCTFail("oversized project Markdown must fail closed")
        } catch DocumentOpenError.tooLarge {
            // Expected: report the safe size refusal instead of a false change race.
        }

        let unreadable = project.appendingPathComponent("unreadable.md")
        try Data("# Permission denied\n".utf8).write(to: unreadable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadable.path
            )
        }
        let unreadableAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: unreadable,
                projectRoot: project
            )
        )
        do {
            _ = try await MarkdownOpenPreflightWorker().inspect(
                unreadable,
                authorization: unreadableAuthorization
            )
            XCTFail("an unreadable target must not be reported as a change race")
        } catch DocumentOpenError.fileUnavailable {
            // Expected: permissions and I/O failures have their own user-facing reason.
        }

        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(
            at: target,
            withDestinationURL: outside
        )
        XCTAssertFalse(authorization.isCurrent())
        XCTAssertNil(
            authorization.refreshedAfterVerifiedRead(
                expectedData: Data("# Project target\n".utf8)
            ),
            "path replacement must never be accepted as benign metadata bookkeeping"
        )
        do {
            _ = try await MarkdownOpenPreflightWorker().inspect(
                target,
                authorization: authorization
            )
            XCTFail("replaced project target must fail closed")
        } catch DocumentOpenError.targetChanged {
            // Expected: the preflight never accepts bytes from the replacement.
        }
    }

    func testExternalOpenRouterAcceptsOnlySupportedLocalMarkdownURLs() async throws {
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

        let application = NSApplication.shared
        let didFinishLaunching = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: application
        )
        let openedBeforeLaunchFinished = NSDocument()
        openedBeforeLaunchFinished.fileURL = markdown
        let openedAfterLaunchFinished = NSDocument()
        openedAfterLaunchFinished.fileURL = longExtension
        NSDocumentController.shared.addDocument(openedBeforeLaunchFinished)
        NSDocumentController.shared.addDocument(openedAfterLaunchFinished)
        defer {
            openedBeforeLaunchFinished.close()
            openedAfterLaunchFinished.close()
        }

        var earlyInitialDocumentRequests = 0
        var earlyIntegrationInstallations = 0
        let earlyOpenDelegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in
                earlyInitialDocumentRequests += 1
            },
            hasOpenDocuments: { false },
            installLaunchIntegrations: { _ in
                earlyIntegrationInstallations += 1
            }
        )
        earlyOpenDelegate.application(application, open: [markdown])
        earlyOpenDelegate.applicationDidFinishLaunching(didFinishLaunching)
        earlyOpenDelegate.applicationDidFinishLaunching(didFinishLaunching)
        await drainMainActorTurns()

        XCTAssertEqual(earlyInitialDocumentRequests, 0)
        XCTAssertEqual(earlyIntegrationInstallations, 1)
        XCTAssertFalse(
            earlyOpenDelegate.applicationShouldOpenUntitledFile(application),
            "AppKit must not infer an untitled-document or Open-panel launch path"
        )

        var lateInitialDocumentRequests = 0
        var lateIntegrationInstallations = 0
        let lateOpenDelegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in
                lateInitialDocumentRequests += 1
            },
            hasOpenDocuments: { false },
            installLaunchIntegrations: { _ in
                lateIntegrationInstallations += 1
            }
        )
        lateOpenDelegate.applicationDidFinishLaunching(didFinishLaunching)
        lateOpenDelegate.application(application, open: [longExtension])
        lateOpenDelegate.applicationDidFinishLaunching(didFinishLaunching)
        await drainMainActorTurns()

        XCTAssertEqual(
            lateInitialDocumentRequests,
            0,
            "an external-open callback just after didFinishLaunching must cancel the fallback blank"
        )
        XCTAssertEqual(lateIntegrationInstallations, 1)
        XCTAssertFalse(lateOpenDelegate.applicationShouldOpenUntitledFile(application))

        var ordinaryInitialDocumentRequests = 0
        var ordinaryIntegrationInstallations = 0
        let ordinaryLaunchDelegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in
                ordinaryInitialDocumentRequests += 1
            },
            hasOpenDocuments: { false },
            installLaunchIntegrations: { _ in
                ordinaryIntegrationInstallations += 1
            }
        )
        ordinaryLaunchDelegate.applicationDidFinishLaunching(didFinishLaunching)
        ordinaryLaunchDelegate.applicationDidFinishLaunching(didFinishLaunching)
        await drainMainActorTurns()

        XCTAssertEqual(ordinaryInitialDocumentRequests, 1)
        XCTAssertEqual(ordinaryIntegrationInstallations, 1)

        var reopenRequests = 0
        var restoreRequests = 0
        var hasDocuments = true
        var canRestore = false
        let reopenDelegate = InflowApplicationDelegate(
            createUntitledDocument: { _ in reopenRequests += 1 },
            hasOpenDocuments: { hasDocuments },
            restoreDocumentWindow: { restoreRequests += 1; return canRestore }
        )
        XCTAssertTrue(reopenDelegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        XCTAssertEqual(restoreRequests, 0)
        XCTAssertTrue(reopenDelegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        XCTAssertEqual(reopenRequests, 0, "An opening document must not create a second blank tab")
        canRestore = true
        XCTAssertFalse(reopenDelegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        XCTAssertEqual(reopenRequests, 0)
        canRestore = false
        hasDocuments = false
        XCTAssertFalse(reopenDelegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
        XCTAssertEqual(reopenRequests, 1, "A windowless app can still open an editable blank")

        let info = try hostApplicationInfoDictionary()
        let documentTypes = try XCTUnwrap(
            info["CFBundleDocumentTypes"] as? [[String: Any]]
        )
        let markdownDocumentType = try XCTUnwrap(documentTypes.first { entry in
            (entry["LSItemContentTypes"] as? [String])?
                .contains(UTType.inflowMarkdown.identifier) == true
        })
        XCTAssertEqual(markdownDocumentType["CFBundleTypeRole"] as? String, "Editor")

        let folderDocumentType = try XCTUnwrap(documentTypes.first { entry in
            (entry["LSItemContentTypes"] as? [String])?
                .contains(UTType.folder.identifier) == true
        })
        XCTAssertEqual(folderDocumentType["CFBundleTypeRole"] as? String, "Viewer")

        let importedTypes = try XCTUnwrap(
            info["UTImportedTypeDeclarations"] as? [[String: Any]]
        )
        let markdownDeclaration = try XCTUnwrap(importedTypes.first { entry in
            entry["UTTypeIdentifier"] as? String == UTType.inflowMarkdown.identifier
        })
        let markdownTags = try XCTUnwrap(
            markdownDeclaration["UTTypeTagSpecification"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(markdownTags["public.filename-extension"] as? [String])),
            Set(["md", "markdown"])
        )
        XCTAssertEqual(markdownTags["public.mime-type"] as? String, "text/markdown")
    }

    func testOpenRouteDeduplicatesBeforeGivingBlankToFirstNewFile() throws {
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

        try withTemporaryDirectory { directory in
            let existing = directory.appendingPathComponent("symlink-target.md")
            let alias = directory.appendingPathComponent("alias.md")
            let firstNew = directory.appendingPathComponent("after-alias.md")
            try Data("existing".utf8).write(to: existing)
            try Data().write(to: firstNew)
            try FileManager.default.createSymbolicLink(
                at: alias,
                withDestinationURL: existing
            )

            let plan = DocumentOpenRouter.plan(
                inputURLs: [alias, existing, firstNew],
                openedDocumentURLs: [existing],
                openedProjectURLs: [],
                hasReusableBlankWindow: true
            )

            XCTAssertEqual(
                plan.actions,
                [
                    .focusExistingFile(alias.standardizedFileURL),
                    .openFile(
                        firstNew.standardizedFileURL,
                        reuseBlank: .reusableBlankWindow
                    ),
                ]
            )
            XCTAssertTrue(plan.rejections.isEmpty)
        }
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

    func testOpenRouteFocusesExistingProjectWithoutConsumingBlank() throws {
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

        try withTemporaryDirectory { directory in
            let project = directory.appendingPathComponent("Project", isDirectory: true)
            let alias = directory.appendingPathComponent("Project Alias", isDirectory: true)
            try FileManager.default.createDirectory(
                at: project,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: alias,
                withDestinationURL: project
            )

            let aliasInputPlan = DocumentOpenRouter.plan(
                inputURLs: [alias, project],
                openedDocumentURLs: [],
                openedProjectURLs: [project],
                hasReusableBlankWindow: true
            )
            XCTAssertEqual(
                aliasInputPlan.actions,
                [.focusExistingProject(alias.standardizedFileURL)]
            )
            XCTAssertTrue(aliasInputPlan.rejections.isEmpty)

            let aliasOpenedPlan = DocumentOpenRouter.plan(
                inputURLs: [project],
                openedDocumentURLs: [],
                openedProjectURLs: [alias],
                hasReusableBlankWindow: true
            )
            XCTAssertEqual(
                aliasOpenedPlan.actions,
                [.focusExistingProject(project.standardizedFileURL)]
            )
            XCTAssertTrue(aliasOpenedPlan.rejections.isEmpty)
        }
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
    func testFileMenuRoutesOpenWithoutInstallingManagedRecentDocuments() async throws {
        try await Task.sleep(for: .milliseconds(200))
        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "文件")?.submenu)
        let openItems = fileMenu.items.filter { $0.title == "打开…" }
        XCTAssertEqual(openItems.count, 1)
        XCTAssertEqual(openItems.first?.keyEquivalent, "o")
        XCTAssertTrue(openItems.first?.target is RecentDocumentsController)
        let menuController = try XCTUnwrap(
            openItems.first?.target as? RecentDocumentsController
        )
        let managedRecentItems = fileMenu.items.flatMap { item in
            [item] + (item.submenu?.items ?? [])
        }.filter {
            $0.target is RecentDocumentsController && $0.title != "打开…"
        }
        XCTAssertTrue(managedRecentItems.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-authorized-open-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("authorized.md")
        let trustedData = Data("# Descriptor-frozen bytes\n".utf8)
        try trustedData.write(to: originalURL)
        let trustedSnapshot = try PreviewLocalFileSnapshot.capture(originalURL)
        let projectIdentity = try XCTUnwrap(
            FolderProjectDirectoryIdentity.capture(directory)
        )
        let resolvedURL = try XCTUnwrap(
            FolderProjectPathBoundary.resolvedURL(originalURL, within: directory)
        )
        let authorization = ProjectDocumentOpenAuthorization(
            targetURL: originalURL.standardizedFileURL,
            resolvedTargetURL: resolvedURL,
            projectRoot: projectIdentity.resolvedURL,
            projectIdentity: projectIdentity,
            snapshot: trustedSnapshot
        )
        try Data("# Bytes currently at the path\n".utf8).write(to: originalURL)

        let openedDocuments: [OpenedDocumentResult]
        do {
            openedDocuments = try await openAuthorizedDocumentsConcurrently(
                from: trustedData,
                authorization: authorization
            )
        } catch {
            XCTFail("descriptor-frozen concurrent open failed: \(error)")
            throw error
        }
        let document = try XCTUnwrap(openedDocuments.first?.document)
        let appKitOwnedContentsURL = try XCTUnwrap(document.autosavedContentsFileURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appKitOwnedContentsURL.path),
            "the descriptor-frozen contents must remain available while AppKit owns them"
        )

        XCTAssertTrue(openedDocuments.allSatisfy { $0.document === document })
        XCTAssertEqual(
            NSDocumentController.shared.documents.filter {
                $0.fileURL?.standardizedFileURL == originalURL.standardizedFileURL
            }.count,
            1,
            "concurrent authorized opens must coalesce to one native document"
        )
        XCTAssertEqual(document.fileURL?.standardizedFileURL, originalURL.standardizedFileURL)
        XCTAssertFalse(document.isDocumentEdited)

        NativeDocumentLoadedFileRegistry.register(
            document,
            authorization: authorization
        )
        XCTAssertTrue(
            NativeDocumentLoadedFileRegistry.matches(
                document,
                authorization: authorization
            )
        )

        let serializedURL = directory.appendingPathComponent("serialized.md")
        try document.write(
            to: serializedURL,
            ofType: UTType.inflowMarkdown.identifier,
            for: .saveToOperation,
            originalContentsURL: originalURL
        )
        XCTAssertEqual(
            try Data(contentsOf: serializedURL),
            trustedData,
            "the native host must use the frozen bytes instead of reopening the path"
        )

        document.fileURL = serializedURL
        XCTAssertFalse(
            NativeDocumentLoadedFileRegistry.matches(
                document,
                authorization: authorization
            ),
            "Save As must not leave the old project identity attached to a new URL"
        )
        document.fileURL = originalURL
        try trustedData.write(to: originalURL)
        XCTAssertTrue(NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
            document,
            targetURL: originalURL,
            expectedData: trustedData
        ))
        let refreshedAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: originalURL,
                projectRoot: directory
            )
        )
        XCTAssertTrue(
            NativeDocumentLoadedFileRegistry.matches(
                document,
                authorization: refreshedAuthorization
            ),
            "a successful in-place save or reload must refresh the trusted snapshot"
        )

        try Data("unexpected replacement\n".utf8).write(to: originalURL)
        XCTAssertFalse(NativeDocumentLoadedFileRegistry.refreshAfterVerifiedWrite(
            document,
            targetURL: originalURL,
            expectedData: trustedData
        ))
        XCTAssertFalse(
            NativeDocumentLoadedFileRegistry.matches(
                document,
                authorization: refreshedAuthorization
            ),
            "a post-save replacement must invalidate rather than refresh trusted identity"
        )
        let replacementAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: originalURL,
                projectRoot: directory
            )
        )
        XCTAssertFalse(
            NativeDocumentLoadedFileRegistry.canFocusAlreadyOpen(
                document,
                authorization: replacementAuthorization
            ),
            "an invalidated managed document must not fall back to ordinary-window focus"
        )
        XCTAssertNil(
            NativeDocumentLoadedFileRegistry.focusableDocument(
                authorization: replacementAuthorization
            ),
            "a failed registry refresh must remain fail closed"
        )
        document.close()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: appKitOwnedContentsURL.path),
            "AppKit must remove its adopted contents copy when the native document closes"
        )

        let restoredContentsURL = try SafePreviewOpenStore.materialize(
            data: Data("# Restored autosave\n".utf8),
            extension: "md"
        )
        let restoredDocument = NSDocument()
        restoredDocument.autosavedContentsFileURL = restoredContentsURL
        NSDocumentController.shared.addDocument(restoredDocument)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)],
            ofItemAtPath: restoredContentsURL.path
        )
        let restoredMaintenance = SafePreviewOpenMaintenance(
            rootURL: restoredContentsURL.deletingLastPathComponent(),
            retentionInterval: 60,
            intervalNanoseconds: 60_000_000_000
        )
        restoredMaintenance.start()
        restoredMaintenance.stop()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: restoredContentsURL.path),
            "startup maintenance must preserve an autosave owned by a restored native document"
        )
        restoredDocument.close()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: restoredContentsURL.path),
            "the restored native document must retain cleanup ownership"
        )

        let callbackURL = directory.appendingPathComponent("callback-order.md")
        let callbackData = Data("# Callback order\n".utf8)
        try callbackData.write(to: callbackURL)
        let callbackAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: callbackURL,
                projectRoot: directory
            )
        )
        let callbackResults: (order: [Int], documents: [OpenedDocumentResult])
        do {
            callbackResults = try await openAuthorizedDocumentsWithClosingFirstCallback(
                from: callbackData,
                authorization: callbackAuthorization
            )
        } catch {
            XCTFail("serialized callback open failed: \(error)")
            throw error
        }
        let firstCallbackDocument = callbackResults.documents[0].document
        let secondCallbackDocument = callbackResults.documents[1].document
        let reentrantCallbackDocument = callbackResults.documents[2].document
        defer { secondCallbackDocument.close() }

        XCTAssertEqual(callbackResults.order, [1, 2, 3])
        XCTAssertFalse(
            NSDocumentController.shared.documents.contains(where: {
                $0 === firstCallbackDocument
            }),
            "the first completion must be allowed to synchronously close its document"
        )
        XCTAssertFalse(firstCallbackDocument === secondCallbackDocument)
        XCTAssertTrue(secondCallbackDocument === reentrantCallbackDocument)
        XCTAssertEqual(
            callbackResults.documents.map(\.wasAlreadyOpen),
            [false, false, true],
            "the queued request must fresh-open after close before a reentrant request reuses it"
        )

        let routedURL = directory.appendingPathComponent("routed-authorized.md")
        let routedData = Data("# Routed authorized open\n".utf8)
        try routedData.write(to: routedURL)
        let routedAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: routedURL,
                projectRoot: directory
            )
        )
        let routedDocument: OpenedDocumentResult
        do {
            routedDocument = try await openAuthorizedDocumentThroughController(
                menuController,
                url: routedURL,
                authorization: routedAuthorization
            )
        } catch {
            XCTFail("controller-authorized open failed: \(error)")
            throw error
        }
        defer { routedDocument.document.close() }
        XCTAssertFalse(routedDocument.wasAlreadyOpen)
        let routedReceipt = try XCTUnwrap(routedDocument.receipt)
        XCTAssertEqual(routedReceipt.expectedData, routedData)
        let routedCurrentAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: routedURL,
                projectRoot: directory
            )
        )
        XCTAssertEqual(
            try PreviewLocalFileReader.read(
                routedURL,
                expected: routedCurrentAuthorization.snapshot
            ).data,
            routedData
        )
        XCTAssertTrue(
            NativeDocumentLoadedFileRegistry.matches(
                routedDocument.document,
                authorization: routedReceipt.authorization
            ),
            "the real controller path must preserve the authorization returned by its descriptor-bound receipt"
        )

        let ordinaryRouteURL = directory.appendingPathComponent("ordinary-route.md")
        try Data("# Existing ordinary window\n".utf8).write(to: ordinaryRouteURL)
        let ordinaryRouteDocument = NSDocument()
        // Register before assigning the represented path. AppKit can perform
        // asynchronous last-used metadata bookkeeping during registration;
        // the authorization below must freeze the settled user-visible file.
        NSDocumentController.shared.addDocument(ordinaryRouteDocument)
        ordinaryRouteDocument.fileURL = ordinaryRouteURL
        defer { ordinaryRouteDocument.close() }
        let ordinaryRouteAuthorization = try XCTUnwrap(
            ProjectDocumentOpenAuthorization.capture(
                targetURL: ordinaryRouteURL,
                projectRoot: directory
            )
        )
        let focusedOrdinary: OpenedDocumentResult
        do {
            focusedOrdinary = try await openAuthorizedDocumentThroughController(
                menuController,
                url: ordinaryRouteURL,
                authorization: ordinaryRouteAuthorization
            )
        } catch {
            XCTFail("ordinary existing-document focus failed: \(error)")
            throw error
        }
        XCTAssertTrue(focusedOrdinary.wasAlreadyOpen)
        XCTAssertTrue(focusedOrdinary.document === ordinaryRouteDocument)
        XCTAssertFalse(
            NativeDocumentLoadedFileRegistry.matches(
                ordinaryRouteDocument,
                authorization: ordinaryRouteAuthorization
            ),
            "focusing an ordinary document must not claim a managed disk snapshot"
        )
    }

    @MainActor
    private func openAuthorizedDocumentsConcurrently(
        from data: Data,
        authorization: ProjectDocumentOpenAuthorization
    ) async throws -> [OpenedDocumentResult] {
        try await withCheckedThrowingContinuation { continuation in
            var results: [Result<OpenedDocumentResult, Error>] = []
            let receive: @MainActor (Result<OpenedDocumentResult, Error>) -> Void = { result in
                results.append(result)
                guard results.count == 2 else { return }
                do {
                    continuation.resume(returning: try results.map { try $0.get() })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            AuthorizedMarkdownDocumentOpener.open(
                from: data,
                authorization: authorization,
                completion: receive
            )
            AuthorizedMarkdownDocumentOpener.open(
                from: data,
                authorization: authorization,
                completion: receive
            )
        }
    }

    @MainActor
    private func openAuthorizedDocumentsWithClosingFirstCallback(
        from data: Data,
        authorization: ProjectDocumentOpenAuthorization
    ) async throws -> (order: [Int], documents: [OpenedDocumentResult]) {
        try await withCheckedThrowingContinuation { continuation in
            var order: [Int] = []
            var results: [Result<OpenedDocumentResult, Error>] = []
            var didResume = false
            let receive: @MainActor (
                Int,
                Result<OpenedDocumentResult, Error>
            ) -> Void = { index, result in
                guard !didResume else { return }
                order.append(index)
                results.append(result)
                guard results.count == 3 else { return }
                didResume = true
                do {
                    continuation.resume(
                        returning: (order, try results.map { try $0.get() })
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            AuthorizedMarkdownDocumentOpener.open(
                from: data,
                authorization: authorization
            ) { firstResult in
                if case let .success(opened) = firstResult {
                    opened.document.close()
                }
                receive(1, firstResult)
                AuthorizedMarkdownDocumentOpener.open(
                    from: data,
                    authorization: authorization
                ) { receive(3, $0) }
            }
            AuthorizedMarkdownDocumentOpener.open(
                from: data,
                authorization: authorization
            ) { receive(2, $0) }
        }
    }

    @MainActor
    private func openAuthorizedDocumentThroughController(
        _ controller: RecentDocumentsController,
        url: URL,
        authorization: ProjectDocumentOpenAuthorization
    ) async throws -> OpenedDocumentResult {
        try await withCheckedThrowingContinuation { continuation in
            controller.openDocumentFromFolderDetailed(
                url,
                authorization: authorization,
                display: false,
                presentsErrors: false
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func record(_ path: String, bookmark: Data?) -> RecentDocumentRecord {
        RecentDocumentRecord(
            exactPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            bookmark: bookmark
        )
    }

    private func hostApplicationInfoDictionary() throws -> [String: Any] {
        var candidate = Bundle(for: type(of: self)).bundleURL
        while candidate.pathExtension != "app",
              candidate.path != candidate.deletingLastPathComponent().path
        {
            candidate.deleteLastPathComponent()
        }
        let applicationBundle = try XCTUnwrap(
            candidate.pathExtension == "app" ? Bundle(url: candidate) : nil,
            "the hosted test bundle must be nested inside the built Inflow.app"
        )
        return try XCTUnwrap(applicationBundle.infoDictionary)
    }

    private func drainMainActorTurns() async {
        for _ in 0..<4 {
            await Task.yield()
        }
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

@MainActor
private final class DraftQuitReviewProbe: NSObject {
    var approved: Bool?
    @objc func reviewed(_ controller: NSDocumentController, approved: Bool, context: UnsafeMutableRawPointer?) {
        self.approved = approved
    }
}

@MainActor
private final class WindowConfigurationProbe: NSWindow {
    var styleWrites = 0
    var behaviorWrites = 0

    override var styleMask: NSWindow.StyleMask {
        didSet { styleWrites += 1 }
    }

    override var collectionBehavior: NSWindow.CollectionBehavior {
        didSet { behaviorWrites += 1 }
    }
}
