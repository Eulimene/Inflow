import AppKit
import Foundation
import XCTest
@testable import Inflow

final class HTMLExporterTests: XCTestCase {
    func testHTMLExportABILayoutMatchesRustContractOnArm64() {
        XCTAssertEqual(MemoryLayout<InflowHTMLExportResult>.size, 32)
        XCTAssertEqual(MemoryLayout<InflowHTMLExportResult>.alignment, 8)
        XCTAssertEqual(UInt64(INFLOW_HTML_EXPORT_ISSUE_IMAGE), HTMLExportIssue.image.rawValue)
        XCTAssertEqual(
            UInt64(INFLOW_HTML_EXPORT_ISSUE_UNSAFE_LINK),
            HTMLExportIssue.unsafeLink.rawValue
        )
    }

    func testExportUsesImmutableUTF8SnapshotAndStrictDocumentPolicy() throws {
        var markdown = "# 快照\n\n**First**"
        let snapshot = HTMLExportSnapshot(markdown: markdown)
        markdown = "# 新版本"

        let data = try HTMLExporter.generate(snapshot: snapshot)
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("<h1>快照</h1>"))
        XCTAssertTrue(html.contains("<strong>First</strong>"))
        XCTAssertFalse(html.contains("新版本"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains("file:"))
    }

    func testExportReportsAllUnsupportedDeliveryContent() {
        let snapshot = HTMLExportSnapshot(
            markdown: "![image](photo.png)\n\n$x$\n\n```mermaid\ngraph LR\n```\n\n[local](../a.md)\n\n[unsafe](javascript:alert(1))"
        )

        XCTAssertThrowsError(try HTMLExporter.generate(snapshot: snapshot)) { error in
            guard case let HTMLExportError.unsupportedContent(issues) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                Set(issues),
                Set([.image, .mermaid, .localLink, .unsafeLink])
            )
            XCTAssertTrue(error.localizedDescription.contains("导出前检查未通过"))
        }
    }

    func testExportRendersFormulaAsSelfContainedMathML() throws {
        let data = try HTMLExporter.generate(
            snapshot: HTMLExportSnapshot(markdown: "Inline $x_1^2$\n\n$$\\frac{a}{b}$$\n")
        )
        let html = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(html.contains("<math xmlns=\"http://www.w3.org/1998/Math/MathML\""))
        XCTAssertTrue(html.contains("<msubsup>"))
        XCTAssertTrue(html.contains("<mfrac>"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testWriterCreatesNewFileWithoutLeavingTemporaryArtifacts() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            let expected = try HTMLExportTargetSnapshot.capture(target)

            try HTMLExportFileWriter.write(
                Data("complete".utf8),
                to: target,
                expectedTarget: expected
            )

            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "complete")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterAtomicallyReplacesConfirmedExistingTarget() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            try Data("old-complete-version".utf8).write(to: target)
            let expected = try HTMLExportTargetSnapshot.capture(target)

            try HTMLExportFileWriter.write(
                Data("new-complete-version".utf8),
                to: target,
                expectedTarget: expected
            )

            XCTAssertEqual(
                try String(contentsOf: target, encoding: .utf8),
                "new-complete-version"
            )
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterRejectsTargetCreatedAfterConfirmation() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            let expected = try HTMLExportTargetSnapshot.capture(target)

            XCTAssertThrowsError(
                try HTMLExportFileWriter.write(
                    Data("inflow".utf8),
                    to: target,
                    expectedTarget: expected,
                    beforeCommit: {
                        try Data("external".utf8).write(to: target)
                    }
                )
            ) { error in
                XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterRejectsTargetModifiedAfterConfirmation() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            try Data("confirmed".utf8).write(to: target)
            let expected = try HTMLExportTargetSnapshot.capture(target)

            XCTAssertThrowsError(
                try HTMLExportFileWriter.write(
                    Data("inflow".utf8),
                    to: target,
                    expectedTarget: expected,
                    beforeCommit: {
                        try Data("external".utf8).write(to: target)
                    }
                )
            ) { error in
                XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "external")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testWriterRejectsTargetReplacedWithIdenticalContentsAfterConfirmation() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("document.html")
            try Data("same-content".utf8).write(to: target)
            let expected = try HTMLExportTargetSnapshot.capture(target)

            XCTAssertThrowsError(
                try HTMLExportFileWriter.write(
                    Data("inflow".utf8),
                    to: target,
                    expectedTarget: expected,
                    beforeCommit: {
                        try FileManager.default.removeItem(at: target)
                        try Data("same-content".utf8).write(to: target)
                    }
                )
            ) { error in
                XCTAssertEqual(error as? HTMLExportTargetError, .targetChanged)
            }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "same-content")
            XCTAssertEqual(try temporaryExportFiles(in: directory), [])
        }
    }

    func testTargetSnapshotRejectsSymlinksAndDirectories() throws {
        try withTemporaryDirectory { directory in
            let realFile = directory.appendingPathComponent("real.html")
            let symbolicLink = directory.appendingPathComponent("linked.html")
            try Data("private".utf8).write(to: realFile)
            try FileManager.default.createSymbolicLink(
                at: symbolicLink,
                withDestinationURL: realFile
            )

            for unsupportedTarget in [symbolicLink, directory] {
                XCTAssertThrowsError(try HTMLExportTargetSnapshot.capture(unsupportedTarget)) {
                    error in
                    XCTAssertEqual(error as? HTMLExportTargetError, .unsupportedTarget)
                }
            }
            XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "private")
        }
    }

    @MainActor
    func testFileMenuHasOneHTMLExportCommand() throws {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let items = allMenuItems(in: try XCTUnwrap(NSApp.mainMenu))
        XCTAssertEqual(items.filter { $0.title == "导出 HTML…" }.count, 1)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InflowHTMLExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func temporaryExportFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".inflow-export-") }
    }

    @MainActor
    private func allMenuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allMenuItems) ?? [])
        }
    }
}
