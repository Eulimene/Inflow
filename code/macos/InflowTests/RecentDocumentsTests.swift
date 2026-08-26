import AppKit
import XCTest
@testable import Inflow

@MainActor
final class RecentDocumentsTests: XCTestCase {
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

        controller.remove(try XCTUnwrap(controller.entries.first))
        XCTAssertEqual(controller.entries.map(\.record), [alpha, beta, delta, epsilon])

        capacity = 6
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
