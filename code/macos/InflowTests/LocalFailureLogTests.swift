import Foundation
import XCTest
@testable import Inflow

@MainActor
final class LocalFailureLogTests: XCTestCase {
    func testKeepsOnlyCurrentAndPreviousSessions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeController(directory: directory, timestamp: "2026-09-01T00:00:00Z")
        first.record(.opening, code: .fileUnavailable)

        let second = makeController(directory: directory, timestamp: "2026-09-01T01:00:00Z")
        second.record(.saving, code: .saveFailed)

        let third = makeController(directory: directory, timestamp: "2026-09-01T02:00:00Z")
        third.record(.pdfExport, code: .pdfRenderingFailed)

        XCTAssertEqual(third.previousSession.map(\.operationCategory), [.saving])
        XCTAssertEqual(third.currentSession.map(\.operationCategory), [.pdfExport])
        let payload = try JSONDecoder().decode(
            LocalFailureLogExport.self,
            from: third.exportData()
        )
        XCTAssertEqual(payload.previousSession.map(\.errorCode), [.saveFailed])
        XCTAssertEqual(payload.currentSession.map(\.errorCode), [.pdfRenderingFailed])
        XCTAssertFalse(
            String(decoding: try third.exportData(), as: UTF8.self).contains("fileUnavailable")
        )
    }

    func testExportContainsOnlyAllowlistedRecordFieldsAndNoSensitiveInputChannel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(
            directory: directory,
            timestamp: "2026-09-01T03:00:00Z"
        )
        controller.record(.project, code: .projectCreationFailed)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: controller.exportData()) as? [String: Any]
        )
        let current = try XCTUnwrap(object["currentSession"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(current.first).keys), [
            "timestamp",
            "applicationVersion",
            "operationCategory",
            "errorCode",
        ])
        let text = String(decoding: try controller.exportData(), as: UTF8.self)
        for forbidden in [
            "secret body",
            "/Users/person/private.md",
            "https://example.invalid/private",
            "search term",
            "clipboard",
        ] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testVersionRejectsUnexpectedCharacters() {
        XCTAssertEqual(
            LocalFailureLogController.safeVersion(short: "1.2.3", build: "42"),
            "1.2.3 (42)"
        )
        XCTAssertEqual(
            LocalFailureLogController.safeVersion(short: "private/path", build: nil),
            "unknown"
        )
    }

    private func makeController(directory: URL, timestamp: String) -> LocalFailureLogController {
        LocalFailureLogController(
            directoryURL: directory,
            timestamp: { timestamp },
            applicationVersion: { "1.0 (1)" }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inflow-LocalFailureLog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
