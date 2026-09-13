import Foundation
import XCTest

final class AnonymousUsageDataTests: XCTestCase {
    func testLaunchTargetDoesNotCompileAnonymousUsageComponents() throws {
        let project = try String(
            contentsOf: codeRoot.appendingPathComponent("Inflow.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertFalse(project.contains("AnonymousUsageData.swift in Sources"))
        XCTAssertFalse(project.contains("AnonymousUsagePrivacyView.swift in Sources"))
    }

    func testLaunchEntryPointsDoNotReferenceAnonymousUsage() throws {
        for relativePath in [
            "macos/Inflow/InflowApp.swift",
            "macos/Inflow/Editor/MarkdownEditorView.swift",
            "macos/Inflow/Settings/InflowSettingsView.swift",
        ] {
            let source = try String(
                contentsOf: codeRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("AnonymousUsage"),
                "launch source still references telemetry: \(relativePath)"
            )
        }
    }

    func testLaunchInfoAndEntitlementsContainNoTelemetryAndOnlyNetworkClientCapability() throws {
        let info = try propertyList(at: "macos/Inflow/Resources/Info.plist")
        XCTAssertNil(info["InflowAnonymousUsageEndpoint"])
        XCTAssertEqual(info["NSSupportsAutomaticTermination"] as? Bool, false)
        XCTAssertEqual(info["NSSupportsSuddenTermination"] as? Bool, false)

        let entitlements = try propertyList(at: "macos/Inflow/Resources/Inflow.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
        XCTAssertNil(entitlements["com.apple.security.network.server"])
    }

    func testLaunchPrivacyManifestDeclaresNoCollectionOrTracking() throws {
        let manifest = try propertyList(at: "macos/Inflow/Resources/PrivacyInfo.xcprivacy")

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertTrue(
            try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]).isEmpty
        )
        XCTAssertTrue(
            try XCTUnwrap(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]).isEmpty
        )
    }

    private var codeRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func propertyList(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: codeRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }
}
