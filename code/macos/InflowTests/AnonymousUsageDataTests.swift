import Foundation
import XCTest
@testable import Inflow

private actor MockAnonymousUsageTransport: AnonymousUsageTransport {
    struct SendFailure: Error, LocalizedError {
        var errorDescription: String? { "mock transport rejected the batch" }
    }

    let shouldFail: Bool
    private var payloads: [Data] = []

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func send(_ data: Data) async throws {
        payloads.append(data)
        if shouldFail {
            throw SendFailure()
        }
    }

    func capturedPayloads() -> [Data] {
        payloads
    }
}

@MainActor
final class AnonymousUsageDataTests: XCTestCase {
    private let exactRecordKeys: Set<String> = [
        "inflow_version",
        "macos_major_version",
        "interface_language",
        "feature",
        "command",
        "duration_bucket",
        "error_category",
        "count",
    ]

    func testBundledPrivacyManifestMatchesAnonymousUsageContract() throws {
        let manifestURL = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        let accessedAPITypes = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        XCTAssertTrue(accessedAPITypes.isEmpty)

        let declarations = try XCTUnwrap(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )
        XCTAssertEqual(declarations.count, 4)
        XCTAssertEqual(
            declarations.compactMap { $0["NSPrivacyCollectedDataType"] as? String },
            [
                "NSPrivacyCollectedDataTypeProductInteraction",
                "NSPrivacyCollectedDataTypePerformanceData",
                "NSPrivacyCollectedDataTypeOtherDiagnosticData",
                "NSPrivacyCollectedDataTypeOtherDataTypes",
            ]
        )
        for declaration in declarations {
            XCTAssertEqual(declaration["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(declaration["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
            XCTAssertEqual(
                declaration["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAnalytics"]
            )
            XCTAssertEqual(declaration.count, 4)
        }
    }

    func testDefaultsOffAndDoesNotRecordBeforeExplicitConsent() async throws {
        let fixture = try makeFixture(transportFails: false)
        defer { fixture.cleanup() }

        await fixture.controller.waitForIdleForTesting()
        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertFalse(fixture.controller.hasViewedDisclosure)

        fixture.controller.record(feature: .document, command: .openDocument)
        await fixture.controller.waitForIdleForTesting()

        let pendingCount = await fixture.store.pendingCount()
        let payloads = await fixture.transport.capturedPayloads()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertTrue(payloads.isEmpty)
    }

    func testCannotEnableUntilDisclosureWasViewed() async throws {
        let fixture = try makeFixture(transportFails: false)
        defer { fixture.cleanup() }
        await fixture.controller.waitForIdleForTesting()

        XCTAssertFalse(fixture.controller.enable())
        XCTAssertFalse(fixture.controller.isEnabled)
        XCTAssertNotNil(fixture.controller.lastErrorMessage)

        fixture.controller.markDisclosureViewed()
        XCTAssertTrue(fixture.controller.enable())
        await fixture.controller.waitForIdleForTesting()

        XCTAssertTrue(fixture.controller.isEnabled)
        XCTAssertTrue(fixture.defaults.bool(forKey: "privacy.anonymousUsage.enabled"))
        XCTAssertTrue(fixture.defaults.bool(forKey: "privacy.anonymousUsage.hasViewedDisclosure"))
        let payloads = await fixture.transport.capturedPayloads()
        XCTAssertFalse(payloads.isEmpty)
    }

    func testUnavailableEndpointForcesExistingConsentOff() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "Inflow.AnonymousUsageDataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "privacy.anonymousUsage.enabled")
        defaults.set(true, forKey: "privacy.anonymousUsage.hasViewedDisclosure")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = AnonymousUsageDataController(
            defaults: defaults,
            store: AnonymousUsageStore(directoryURL: directory),
            transport: nil,
            context: testContext
        )
        await controller.waitForIdleForTesting()

        XCTAssertFalse(controller.isDisclosureAvailable)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: "privacy.anonymousUsage.enabled"))
        XCTAssertFalse(controller.enable())
    }

    func testPayloadContainsOnlyClosedAnonymousFields() async throws {
        let fixture = try makeFixture(transportFails: true)
        defer { fixture.cleanup() }
        await fixture.controller.waitForIdleForTesting()
        fixture.controller.markDisclosureViewed()
        XCTAssertTrue(fixture.controller.enable())
        fixture.controller.record(
            feature: .export,
            command: .exportHTML,
            durationBucket: .from100To499Milliseconds,
            errorCategory: .none
        )
        await fixture.controller.waitForIdleForTesting()

        let pendingBatch = try await fixture.store.pendingBatch()
        let batch = try XCTUnwrap(pendingBatch)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: batch.data) as? [String: Any]
        )
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(records.count, 2)
        for record in records {
            XCTAssertEqual(Set(record.keys), exactRecordKeys)
            XCTAssertEqual(record["inflow_version"] as? String, "9.8.7-test")
            XCTAssertEqual(record["macos_major_version"] as? Int, 26)
            XCTAssertEqual(record["interface_language"] as? String, "zh-Hans")
            XCTAssertEqual(record["count"] as? Int, 1)
        }

        let encoded = try XCTUnwrap(String(data: batch.data, encoding: .utf8))
        for forbidden in [
            "private-document-sentinel",
            "/Users/example/secret.md",
            "https://private.example/path",
            "confidential search query",
            "selection",
            "clipboard",
            "timestamp",
            "device_id",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), "payload leaked forbidden field: \(forbidden)")
        }
    }

    func testSuccessfulUploadRemovesPendingRecords() async throws {
        let fixture = try makeFixture(transportFails: false)
        defer { fixture.cleanup() }
        await fixture.controller.waitForIdleForTesting()
        fixture.controller.markDisclosureViewed()
        XCTAssertTrue(fixture.controller.enable())
        fixture.controller.record(feature: .preview, command: .selectSplitView)
        await fixture.controller.waitForIdleForTesting()

        let pendingCount = await fixture.store.pendingCount()
        let payloads = await fixture.transport.capturedPayloads()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(fixture.controller.pendingCount, 0)
        XCTAssertGreaterThanOrEqual(payloads.count, 1)
    }

    func testDisablingStopsNewRecordsAndCanClearUnsentRecords() async throws {
        let fixture = try makeFixture(transportFails: true)
        defer { fixture.cleanup() }
        await fixture.controller.waitForIdleForTesting()
        fixture.controller.markDisclosureViewed()
        XCTAssertTrue(fixture.controller.enable())
        fixture.controller.record(feature: .editor, command: .formatMarkdown)
        await fixture.controller.waitForIdleForTesting()
        let pendingBeforeDisable = await fixture.store.pendingCount()
        XCTAssertGreaterThan(pendingBeforeDisable, 0)

        fixture.controller.disable(clearPending: false)
        fixture.controller.record(feature: .document, command: .openDocument)
        await fixture.controller.waitForIdleForTesting()
        XCTAssertFalse(fixture.controller.isEnabled)
        let pendingAfterDisable = await fixture.store.pendingCount()
        XCTAssertEqual(pendingAfterDisable, pendingBeforeDisable)

        fixture.controller.clearPending()
        await fixture.controller.waitForIdleForTesting()
        let pendingAfterClear = await fixture.store.pendingCount()
        XCTAssertEqual(pendingAfterClear, 0)
        XCTAssertEqual(fixture.controller.pendingCount, 0)
    }

    func testLocalEventRetentionIsLimitedToThirtyDays() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnonymousUsageStore(directoryURL: directory)
        try await store.append(
            AnonymousUsageRecord(
                context: testContext,
                feature: .search,
                command: .findInDocument,
                durationBucket: .under100Milliseconds,
                errorCategory: .none
            )
        )
        let pendingBeforeExpiration = await store.pendingCount()
        XCTAssertEqual(pendingBeforeExpiration, 1)

        let afterRetention = Date().addingTimeInterval(
            AnonymousUsageStore.retentionInterval + 1
        )
        let pendingAfterExpiration = await store.pendingCount(now: afterRetention)
        XCTAssertEqual(pendingAfterExpiration, 0)
    }

    func testDurationBucketsHaveStableBoundaries() {
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: -1), .notMeasured)
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: 0), .under100Milliseconds)
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: 99.9), .under100Milliseconds)
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: 100), .from100To499Milliseconds)
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: 500), .from500MillisecondsTo1Second)
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: 1_000), .from1To5Seconds)
        XCTAssertEqual(AnonymousUsageDurationBucket.bucket(milliseconds: 5_000), .over5Seconds)
    }

    func testTransportRejectsNonHTTPSBeforeSending() async {
        let transport = HTTPSAnonymousUsageTransport(
            endpoint: URL(string: "http://example.invalid/anonymous-usage")!
        )
        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("non-HTTPS endpoint must never be used")
        } catch let error as AnonymousUsageTransportError {
            guard case .invalidEndpoint = error else {
                return XCTFail("unexpected transport error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private var testContext: AnonymousUsageContext {
        AnonymousUsageContext(
            inflowVersion: "9.8.7-test",
            macOSMajorVersion: 26,
            interfaceLanguage: "zh-Hans"
        )
    }

    private func makeFixture(transportFails: Bool) throws -> Fixture {
        let directory = temporaryDirectory()
        let suiteName = "Inflow.AnonymousUsageDataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = AnonymousUsageStore(directoryURL: directory)
        let transport = MockAnonymousUsageTransport(shouldFail: transportFails)
        let controller = AnonymousUsageDataController(
            defaults: defaults,
            store: store,
            transport: transport,
            context: testContext
        )
        return Fixture(
            controller: controller,
            store: store,
            transport: transport,
            defaults: defaults,
            directory: directory,
            suiteName: suiteName
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InflowAnonymousUsageTests-\(UUID().uuidString)", isDirectory: true)
    }

    private struct Fixture {
        let controller: AnonymousUsageDataController
        let store: AnonymousUsageStore
        let transport: MockAnonymousUsageTransport
        let defaults: UserDefaults
        let directory: URL
        let suiteName: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
