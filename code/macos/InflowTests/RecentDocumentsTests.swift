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
        XCTAssertEqual(persistence.records, [gamma, alpha, beta, delta, epsilon, zeta])

        capacity = 6
        controller.applyCapacity()
        XCTAssertEqual(
            controller.entries.map(\.record),
            [gamma, alpha, beta, delta, epsilon, zeta]
        )

        controller.remove(try XCTUnwrap(controller.entries.first))
        XCTAssertEqual(controller.entries.map(\.record), [alpha, beta, delta, epsilon, zeta])
        XCTAssertEqual(persistence.records, [alpha, beta, delta, epsilon, zeta])

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
    func testFileMenuUsesProductRecentDocumentLabelsWithoutRemovingOpen() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let fileMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "文件")?.submenu)
        let openItems = fileMenu.items.filter { $0.title == "打开…" }
        let recentItems = fileMenu.items.filter { $0.title == "打开最近" }
        XCTAssertEqual(openItems.count, 1)
        XCTAssertEqual(openItems.first?.keyEquivalent, "o")
        XCTAssertTrue(openItems.first?.target is RecentDocumentsController)
        XCTAssertEqual(recentItems.count, 1)
        let clearItems = try XCTUnwrap(recentItems.first?.submenu).items.filter {
            $0.title == "清除最近记录"
        }
        XCTAssertEqual(clearItems.count, 1)
        XCTAssertTrue(clearItems.first?.target is RecentDocumentsController)
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
