import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
@testable import Inflow

final class MarkdownRendererTests: XCTestCase {
    func testLocalMarkdownPromptFreezesSafeCopySemantics() {
        XCTAssertEqual(PreviewLocalMarkdownPrompt.confirmTitle, "打开安全副本")
        XCTAssertEqual(
            PreviewLocalMarkdownPrompt.message,
            "Inflow 会读取当前已确认的文件内容，并以未命名安全副本打开；"
                + "这个副本不会继续关联或写回原文件。有标题片段时会精确定位。"
        )
        XCTAssertFalse(PreviewLocalMarkdownPrompt.message.contains("文件描述符"))
    }

    func testMiBDocumentDerivesCompletePreviewWithinUpdateBudget() throws {
        let source = Self.largePerformanceFixture()
        XCTAssertEqual(source.utf8.count, 1_048_576)
        XCTAssertEqual(source.filter(\.isNewline).count, 9_999)
        XCTAssertEqual(source.split(separator: "\n", omittingEmptySubsequences: false).count, 10_000)

        let analysisStarted = ProcessInfo.processInfo.systemUptime
        let analysis = try MarkdownAnalyzer.analyze(source)
        let analysisElapsed = ProcessInfo.processInfo.systemUptime - analysisStarted
        let highlightingStarted = ProcessInfo.processInfo.systemUptime
        let highlighting = try MarkdownHighlighter.spans(in: source)
        let highlightingElapsed = ProcessInfo.processInfo.systemUptime - highlightingStarted
        let previewStarted = ProcessInfo.processInfo.systemUptime
        let preview = MarkdownRenderer.previewDocument(
            for: source,
            navigationHeadings: analysis.headings
        )
        let previewElapsed = ProcessInfo.processInfo.systemUptime - previewStarted

        XCTAssertNil(preview.failureMessage)
        XCTAssertTrue(preview.html.contains("FINAL-PREVIEW-MARKER"))
        XCTAssertEqual(analysis.headings.last?.title, "FINAL-PREVIEW-MARKER")
        XCTAssertTrue(highlighting.contains { $0.utf8Range.upperBound == source.utf8.count })
        let elapsed = analysisElapsed + highlightingElapsed + previewElapsed
        #if DEBUG
        XCTAssertLessThan(elapsed, 1.0, "Debug pipeline took \(elapsed) seconds")
        #else
        XCTAssertLessThan(elapsed, 0.3, "Release pipeline took \(elapsed) seconds")
        #endif
    }

    func testPerformanceManifestPinsTargetFixtureAndMeasurementProtocol() throws {
        struct Manifest: Decodable {
            struct Target: Decodable {
                let model_identifier: String
                let soc: String
                let physical_memory_bytes: UInt64
                let operating_system_version: String
            }
            struct Fixture: Decodable {
                struct LocalImages: Decodable {
                    let status: String
                    let required_count: Int
                    let required_total_bytes: Int
                    let corpus_sha256: String?
                }

                let full_fixture_status: String
                let expected_bytes: Int
                let expected_lines: Int
                let expected_line_feeds: Int
                let sha256: String
                let local_images: LocalImages
            }
            struct Measurement: Decodable {
                struct SessionPreparation: Decodable {
                    let device_restart_required: Bool
                    let post_restart_wait_seconds: Int
                    let close_other_user_foreground_apps: Bool
                }

                struct ColdDefinition: Decodable {
                    let inflow_exited: Bool
                    let minimum_not_running_seconds: Int
                    let start_event: String
                }

                struct WarmDefinition: Decodable {
                    let inflow_state: String
                    let idle_seconds: Int
                    let start_event: String
                }

                struct ContinuousInput: Decodable {
                    let duration_seconds: Int
                    let characters_per_second: Int
                }

                let warmup_runs: Int
                let measured_runs: Int
                let statistics: [String]
                let resource_sample_window_seconds: Int
                let continuous_input: ContinuousInput
                let measurement_session_preparation: SessionPreparation
                let cold_definition: ColdDefinition
                let warm_definition: WarmDefinition
            }
            struct RepositoryGate: Decodable {
                let status: String
                let authoritative_for_target_device: Bool
            }

            let schema_version: Int
            let authoritative_target: Target
            let fixture: Fixture
            let measurement: Measurement
            let repository_gate: RepositoryGate
        }

        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let manifestURL = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("quality/performance-manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let source = Self.largePerformanceFixture()
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(manifest.schema_version, 1)
        XCTAssertEqual(manifest.authoritative_target.model_identifier, "MacBookAir10,1")
        XCTAssertEqual(manifest.authoritative_target.soc, "Apple M1")
        XCTAssertEqual(manifest.authoritative_target.physical_memory_bytes, 8 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(manifest.authoritative_target.operating_system_version, "14.0")
        XCTAssertEqual(manifest.fixture.expected_bytes, source.utf8.count)
        XCTAssertEqual(manifest.fixture.expected_lines, 10_000)
        XCTAssertEqual(manifest.fixture.expected_line_feeds, source.filter(\.isNewline).count)
        XCTAssertEqual(manifest.fixture.sha256, digest)
        XCTAssertEqual(manifest.fixture.full_fixture_status, "open")
        XCTAssertEqual(manifest.fixture.local_images.status, "open")
        XCTAssertEqual(manifest.fixture.local_images.required_count, 20)
        XCTAssertEqual(manifest.fixture.local_images.required_total_bytes, 16 * 1_024 * 1_024)
        XCTAssertNil(manifest.fixture.local_images.corpus_sha256)
        XCTAssertEqual(manifest.measurement.warmup_runs, 3)
        XCTAssertEqual(manifest.measurement.measured_runs, 30)
        XCTAssertEqual(manifest.measurement.statistics, ["median", "p95", "maximum"])
        XCTAssertEqual(manifest.measurement.resource_sample_window_seconds, 30)
        XCTAssertEqual(manifest.measurement.continuous_input.duration_seconds, 60)
        XCTAssertEqual(manifest.measurement.continuous_input.characters_per_second, 10)
        XCTAssertTrue(
            manifest.measurement.measurement_session_preparation.device_restart_required
        )
        XCTAssertEqual(
            manifest.measurement.measurement_session_preparation.post_restart_wait_seconds,
            300
        )
        XCTAssertTrue(
            manifest.measurement.measurement_session_preparation
                .close_other_user_foreground_apps
        )
        XCTAssertTrue(manifest.measurement.cold_definition.inflow_exited)
        XCTAssertEqual(manifest.measurement.cold_definition.minimum_not_running_seconds, 30)
        XCTAssertEqual(
            manifest.measurement.cold_definition.start_event,
            "finder-open-request-for-benchmark-document"
        )
        XCTAssertEqual(manifest.measurement.warm_definition.inflow_state, "one-blank-window")
        XCTAssertEqual(manifest.measurement.warm_definition.idle_seconds, 10)
        XCTAssertEqual(
            manifest.measurement.warm_definition.start_event,
            "user-confirms-open-file"
        )
        XCTAssertEqual(manifest.repository_gate.status, "component-smoke-only")
        XCTAssertFalse(manifest.repository_gate.authoritative_for_target_device)
    }

    @MainActor
    func testExactMiBTextCanTraverseTextKitRecoveryAndMountedWebKit() async throws {
        let source = Self.largePerformanceFixture()

        let editor = MarkdownSourceEditorSession()
        editor.textView.isEditable = true
        editor.textView.string = source
        editor.textView.layoutManager?.ensureLayout(for: editor.textView.textContainer!)
        XCTAssertEqual(editor.textView.string.utf8.count, source.utf8.count)

        let recoveryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inflow-Performance-Recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        let recoveryKeyProvider = FixedDocumentRecoveryKeyProvider(
            keyData: Data(repeating: 0x5C, count: 32)
        )
        let recoveryStore = DocumentRecoveryStore(
            rootURL: recoveryRoot,
            keyProvider: recoveryKeyProvider
        )
        let recoveryRecord = DocumentRecoveryRecord(
            id: UUID(),
            document: MarkdownDocument(text: source),
            originalURL: nil,
            selectedUTF16Range: NSRange(location: 0, length: 0),
            viewMode: .split,
            verticalScrollOffset: 0
        )
        let reconcileOutcome = try await recoveryStore.reconcile(recoveryRecord)
        let recoveredText = try await recoveryStore.load().records.first?.text
        XCTAssertEqual(reconcileOutcome, .stored)
        XCTAssertEqual(recoveredText, source)
        try await recoveryStore.removeAll()

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            configuration: configuration
        )
        let loaded = expectation(description: "exact MiB text preview mounted")
        let delegate = PreviewTestLoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(MarkdownRenderer.htmlDocument(for: source), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        let containsMarker = try await webView.evaluateJavaScript(
            "document.body.innerText.includes('FINAL-PREVIEW-MARKER')"
        ) as? Bool
        XCTAssertEqual(containsMarker, true)
    }

    private static func largePerformanceFixture() -> String {
        let exactByteCount = 1_048_576
        let paragraph = String(repeating: "alpha beta gamma delta ", count: 3)
        var lines = (0..<9_999).map { index in
            index.isMultiple(of: 100)
                ? "## Section \(index) \(paragraph)"
                : "Paragraph \(index) \(paragraph)"
        }
        lines.append("## FINAL-PREVIEW-MARKER")
        let unpadded = lines.joined(separator: "\n")
        let missingBytes = exactByteCount - unpadded.utf8.count
        precondition(missingBytes >= 0)
        let padding = missingBytes.quotientAndRemainder(dividingBy: 9_999)
        for index in 0..<9_999 {
            lines[index].append(
                String(repeating: "x", count: padding.quotient + (index < padding.remainder ? 1 : 0))
            )
        }
        let source = lines.joined(separator: "\n")
        precondition(source.utf8.count == exactByteCount)
        return source
    }

    func testPreviewFailureUsesFrozenSafeExitCopyAndKeepsDetailsOutOfHTML() {
        XCTAssertEqual(PreviewFailurePrompt.title, "暂时无法更新预览")
        XCTAssertEqual(PreviewFailurePrompt.message, "编辑和保存仍可用。")
        XCTAssertEqual(PreviewFailurePrompt.retryTitle, "重试预览")
        XCTAssertEqual(PreviewFailurePrompt.hideTitle, "隐藏预览")

        let result = MarkdownRenderer.previewDocument(
            for: "# private source",
            documentDirectory: nil,
            configuration: .default,
            navigationHeadings: [],
            fragmentRenderer: { _, _ in throw MarkdownRenderError.coreFailure }
        )

        XCTAssertEqual(
            result.failureMessage,
            MarkdownRenderError.coreFailure.localizedDescription
        )
        XCTAssertTrue(result.html.contains(PreviewFailurePrompt.title))
        XCTAssertTrue(result.html.contains(PreviewFailurePrompt.message))
        XCTAssertFalse(result.html.contains("private source"))
        XCTAssertFalse(result.html.contains("Markdown 预览暂时无法更新"))
        XCTAssertTrue(result.html.contains("default-src 'none'"))
    }

    func testSuccessfulPreviewDocumentDoesNotReportFailure() {
        let result = MarkdownRenderer.previewDocument(for: "# Ready")

        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(result.html.contains("<h1>Ready</h1>"))
        XCTAssertFalse(result.html.contains(PreviewFailurePrompt.title))
    }

    func testPreviewDerivationReportsRelativeResourcesWithoutAnotherSourceScan() {
        let local = MarkdownRenderer.previewDocument(
            for: "![cover](assets/cover.png) [guide](guide/readme.md)"
        )
        let remote = MarkdownRenderer.previewDocument(
            for: "![cover](https://example.com/cover.png) [part](#part)"
        )

        XCTAssertTrue(local.hasRelativeResources)
        XCTAssertFalse(remote.hasRelativeResources)
    }

    func testPreviewAddsSafeSelfContainedColorsForKnownCodeLanguages() throws {
        let fragment = try MarkdownRenderer.htmlFragment(
            for: "```rust\nfn main() { println!(\"<tag>你好</tag>\"); } // note\n```\n"
        )

        XCTAssertTrue(fragment.contains("language-rust inflow-code-highlight"))
        XCTAssertTrue(fragment.contains("<span class=\"tok-keyword\">fn</span>"))
        XCTAssertTrue(fragment.contains("<span class=\"tok-comment\">// note</span>"))
        XCTAssertTrue(fragment.contains("&lt;tag&gt;你好&lt;/tag&gt;"))
        XCTAssertFalse(fragment.contains("<tag>你好</tag>"))

        let document = MarkdownRenderer.document(containing: fragment)
        XCTAssertTrue(document.contains(".tok-keyword { color:"))
        XCTAssertTrue(document.contains("@media (prefers-color-scheme: dark)"))
        XCTAssertFalse(document.contains("<script"))

        let forcedDark = PreviewAppearanceCSS.styleElement(
            for: PreviewAppearanceConfiguration(
                contentWidth: 760,
                zoom: 1,
                colorScheme: .dark,
                theme: .standard,
                increasedContrast: false,
                reduceMotion: false,
                mathRenderingEnabled: true,
                mermaidRenderingEnabled: true
            )
        )
        XCTAssertTrue(forcedDark.contains(".tok-keyword { color: #ff7b72; }"))

        let highContrast = PreviewAppearanceCSS.styleElement(
            for: PreviewAppearanceConfiguration(
                contentWidth: 760,
                zoom: 1,
                colorScheme: .system,
                theme: .highContrast,
                increasedContrast: false,
                reduceMotion: false,
                mathRenderingEnabled: true,
                mermaidRenderingEnabled: true
            )
        )
        XCTAssertTrue(highContrast.contains(".tok-comment { text-decoration: underline dotted; }"))
    }

    func testRenderOptionValuesMatchRustContract() {
        XCTAssertEqual(INFLOW_RENDER_OPTION_MATH, UInt32(1 << 0))
        XCTAssertEqual(INFLOW_RENDER_OPTION_MERMAID, UInt32(1 << 1))
        XCTAssertEqual(
            INFLOW_RENDER_OPTIONS_DEFAULT,
            INFLOW_RENDER_OPTION_MATH | INFLOW_RENDER_OPTION_MERMAID
        )
        XCTAssertEqual(
            PreviewAppearanceConfiguration.default.coreRenderOptions,
            INFLOW_RENDER_OPTIONS_DEFAULT
        )
    }

    func testVersionedDialectCorpusExecutesVerifiedCasesAndKeepsOpenGapsVisible() throws {
        struct Corpus: Decodable {
            struct Case: Decodable {
                let id: String
                let status: String
                let operation: String
                let source: String
                let expected_identifiers: [String]?
                let target: String?
                let expected_fragment: String?
                let expected_exact_match: Bool?
                let contains: [String]?
                let excludes: [String]?
                let reason: String?
            }

            struct CrossToolCompatibility: Decodable {
                let status: String
                let reference_tool_builds: [String]
                let result_artifacts: [String]
                let reason: String
            }

            let schema_version: Int
            let dialect: String
            let product_contract: String
            let candidate_status: String
            let candidate_blocker: String
            let cases: [Case]
            let cross_tool_compatibility: CrossToolCompatibility
        }

        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("quality/markdown-dialect-corpus.json")
        let corpus = try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: corpusURL)
        )

        XCTAssertEqual(corpus.schema_version, 1)
        XCTAssertEqual(corpus.dialect, "Inflow Markdown 1.0")
        XCTAssertEqual(corpus.product_contract, "APP-DIALECT-001 v1.1")
        XCTAssertEqual(corpus.candidate_status, "open")
        XCTAssertFalse(corpus.candidate_blocker.isEmpty)
        XCTAssertEqual(
            Set(corpus.cases.prefix(7).map(\.id)),
            Set((1 ... 7).map { String(format: "DIALECT-1.0-%03d", $0) })
        )
        XCTAssertEqual(corpus.cross_tool_compatibility.status, "open")
        XCTAssertTrue(corpus.cross_tool_compatibility.reference_tool_builds.isEmpty)
        XCTAssertTrue(corpus.cross_tool_compatibility.result_artifacts.isEmpty)
        XCTAssertFalse(corpus.cross_tool_compatibility.reason.isEmpty)

        var verifiedCaseCount = 0
        for testCase in corpus.cases {
            if testCase.status == "open" {
                XCTAssertFalse(testCase.reason?.isEmpty ?? true, testCase.id)
                continue
            }
            XCTAssertEqual(testCase.status, "verified", testCase.id)
            verifiedCaseCount += 1

            switch testCase.operation {
            case "heading_identifiers":
                let analysis = try MarkdownAnalyzer.analyze(testCase.source)
                XCTAssertEqual(
                    HeadingIdentifier.identifiers(for: analysis.headings),
                    try XCTUnwrap(testCase.expected_identifiers),
                    testCase.id
                )

            case "fragment":
                let target = try XCTUnwrap(testCase.target)
                let expectedFragment = try XCTUnwrap(testCase.expected_fragment)
                let plan = PreviewLinkPlanner.plan(
                    markdown: testCase.source,
                    target: target,
                    documentURL: nil
                )
                guard case let .currentDocument(fragment) = plan.destination else {
                    XCTFail("\(testCase.id) did not produce current-document navigation")
                    continue
                }
                XCTAssertEqual(fragment, expectedFragment, testCase.id)
                let headings = try MarkdownAnalyzer.analyze(testCase.source).headings
                XCTAssertEqual(
                    PreviewHeadingAnchorResolver.heading(
                        for: expectedFragment,
                        in: headings
                    ) != nil,
                    try XCTUnwrap(testCase.expected_exact_match),
                    testCase.id
                )

            case "render":
                let html = try MarkdownRenderer.htmlFragment(for: testCase.source)
                for marker in testCase.contains ?? [] {
                    XCTAssertTrue(html.contains(marker), "\(testCase.id) missing \(marker)")
                }
                for marker in testCase.excludes ?? [] {
                    XCTAssertFalse(html.contains(marker), "\(testCase.id) exposed \(marker)")
                }

            default:
                XCTFail("unknown corpus operation \(testCase.operation) for \(testCase.id)")
            }
        }
        XCTAssertGreaterThanOrEqual(verifiedCaseCount, 8)
    }

    func testRendersCommonMarkdownAndExtensions() throws {
        let source = """
        # Title

        **Bold** and ~~old~~

        - [x] Done

        ```mermaid
        flowchart LR
        F[个性化] -.贯穿.-> A[内容]
        G[扩展] -.服务.-> A
        ```
        """
        let html = try MarkdownRenderer.htmlFragment(
            for: source
        )

        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("<del>old</del>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("class=\"mermaid-diagram\""))
        XCTAssertTrue(html.contains("stroke-dasharray=\"6 5\""))
        XCTAssertTrue(html.contains(">贯穿</text>"))
        XCTAssertTrue(html.contains(">服务</text>"))
        XCTAssertFalse(html.contains("mermaid-error"))
    }

    func testRawHTMLIsEscaped() throws {
        let html = try MarkdownRenderer.htmlFragment(
            for: "<script>window.location='https://example.com'</script>"
        )

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testPresentationFeaturesCanBeDisabledWithoutChangingSource() throws {
        let configuration = PreviewAppearanceConfiguration(
            contentWidth: 760,
            zoom: 1,
            colorScheme: .system,
            theme: .standard,
            increasedContrast: false,
            reduceMotion: false,
            mathRenderingEnabled: false,
            mermaidRenderingEnabled: false
        )
        let source = "$x^2$\n\n```mermaid\nflowchart TD\nA --> B\n```"
        let html = try MarkdownRenderer.htmlFragment(
            for: source,
            configuration: configuration
        )

        XCTAssertTrue(html.contains("$x^2$"))
        XCTAssertFalse(html.contains("<math"))
        XCTAssertTrue(html.contains("language-mermaid"))
        XCTAssertTrue(html.contains("flowchart TD"))
        XCTAssertFalse(html.contains("mermaid-diagram"))
        XCTAssertFalse(html.contains("<svg"))
        XCTAssertEqual(source, "$x^2$\n\n```mermaid\nflowchart TD\nA --> B\n```")
    }

    func testMermaidFailureCarriesSafeSourceLocationAndRecoveryActions() throws {
        let source = "前文\n\n```mermaid\npie\ntitle Values\n```\n\n后文"
        let fragment = try MarkdownRenderer.htmlFragment(for: source)
        let marker = try XCTUnwrap(source.range(of: "```mermaid"))
        let markerStart = try XCTUnwrap(marker.lowerBound.samePosition(in: source.utf8))
        let start = source.utf8.distance(from: source.utf8.startIndex, to: markerStart)

        XCTAssertTrue(fragment.contains("无法呈现这个图表"))
        XCTAssertTrue(fragment.contains("当前文档的其他内容和其他文档不受影响"))
        XCTAssertTrue(fragment.contains("data-inflow-source-start=\"\(start)\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"locate\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"retry\""))
        XCTAssertTrue(fragment.contains(">定位源文本</button>"))
        XCTAssertTrue(fragment.contains(">重试</button>"))
        XCTAssertFalse(fragment.contains("<script"))
    }

    func testFormulaFailureCarriesSafeSourceLocationAndRecoveryActions() throws {
        let source = "前文 $\\unknown{<script>}$ 后文"
        let fragment = try MarkdownRenderer.htmlFragment(for: source)
        let formula = try XCTUnwrap(source.range(of: "$\\unknown{<script>}$"))
        let lower = try XCTUnwrap(formula.lowerBound.samePosition(in: source.utf8))
        let upper = try XCTUnwrap(formula.upperBound.samePosition(in: source.utf8))
        let start = source.utf8.distance(from: source.utf8.startIndex, to: lower)
        let end = source.utf8.distance(from: source.utf8.startIndex, to: upper)

        XCTAssertTrue(fragment.contains("无法呈现这个公式"))
        XCTAssertTrue(fragment.contains("原内容已保留，当前文档的其他内容和其他文档不受影响。"))
        XCTAssertTrue(fragment.contains("data-inflow-source-start=\"\(start)\""))
        XCTAssertTrue(fragment.contains("data-inflow-source-end=\"\(end)\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"locate\""))
        XCTAssertTrue(fragment.contains("data-inflow-preview-error-action=\"retry\""))
        XCTAssertTrue(fragment.contains("&lt;script&gt;"))
        XCTAssertFalse(fragment.contains("<script>"))
    }

    func testPreviewDocumentAllowsOnlyImageNetworkRequestsAndForbidsScripts() {
        let html = MarkdownRenderer.htmlDocument(for: "# Safe preview")

        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("img-src data: https: http:"))
        XCTAssertFalse(html.contains("img-src data: https: http: file:"))
        XCTAssertTrue(html.contains("<h1>Safe preview</h1>"))
    }

    func testLocalStaticPNGIsInlinedWithoutGivingWebKitAFilePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let imageURL = assets.appendingPathComponent("cover.png")
        try pngData().write(to: imageURL)

        let html = MarkdownRenderer.htmlDocument(
            for: "![封面 <图>](assets/cover.png)",
            documentDirectory: directory
        )

        XCTAssertTrue(html.contains("class=\"inflow-local-image\""))
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"))
        XCTAssertTrue(html.contains("alt=\"封面 &lt;图&gt;\""))
        XCTAssertFalse(html.contains("inflow-image-slot"))
        XCTAssertFalse(html.contains(imageURL.path))
    }

    func testProjectImageResolutionSupportsPathsOutsideTheProjectRoot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project", isDirectory: true)
        let notes = project.appendingPathComponent("notes", isDirectory: true)
        let assets = project.appendingPathComponent("assets", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        for target in [notes, assets, outside] {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }

        let outsideImage = outside.appendingPathComponent("private.png")
        try pngData().write(to: outsideImage)
        let outsideDirectoryLink = project.appendingPathComponent(
            "linked-outside",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: outsideDirectoryLink,
            withDestinationURL: outside
        )

        for target in ["../../outside/private.png", "../linked-outside/private.png"] {
            let html = MarkdownRenderer.htmlDocument(
                for: "![private](\(target))",
                documentDirectory: notes,
                projectRoot: project
            )
            XCTAssertTrue(html.contains("class=\"inflow-local-image\""), html)
            XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), html)
            XCTAssertFalse(html.contains(outsideImage.path), html)
        }

        let insideImage = assets.appendingPathComponent("inside.png")
        try pngData().write(to: insideImage)
        let insideHTML = MarkdownRenderer.htmlDocument(
            for: "![inside](../assets/inside.png)",
            documentDirectory: notes,
            projectRoot: project
        )
        XCTAssertTrue(insideHTML.contains("class=\"inflow-local-image\""), insideHTML)
        XCTAssertTrue(insideHTML.contains("src=\"data:image/png;base64,"), insideHTML)
    }

    func testReplacedProjectRootBlocksPreviewImagesAndLocalLinkExecution() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let project = container.appendingPathComponent("project", isDirectory: true)
        let displacedProject = container.appendingPathComponent(
            "displaced-project",
            isDirectory: true
        )
        let notes = project.appendingPathComponent("notes", isDirectory: true)
        let assets = project.appendingPathComponent("assets", isDirectory: true)
        let guides = project.appendingPathComponent("guides", isDirectory: true)
        for directory in [notes, assets, guides] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let sourceURL = notes.appendingPathComponent("source.md")
        let imageURL = assets.appendingPathComponent("inside.png")
        let linkedURL = guides.appendingPathComponent("inside.md")
        try Data("# Source".utf8).write(to: sourceURL)
        try pngData().write(to: imageURL)
        try Data("# Inside".utf8).write(to: linkedURL)
        let projectIdentity = try XCTUnwrap(
            FolderProjectDirectoryIdentity.capture(project)
        )

        let linkTarget = "../guides/inside.md"
        let originalPlan = PreviewLinkPlanner.plan(
            markdown: "[inside](\(linkTarget))",
            target: linkTarget,
            documentURL: sourceURL,
            projectRoot: project,
            expectedProjectRootIdentity: projectIdentity
        )
        guard case let .local(originalLink) = originalPlan.destination else {
            return XCTFail("expected a project-local link")
        }
        XCTAssertEqual(originalLink.expectedProjectRootIdentity, projectIdentity)
        XCTAssertTrue(PreviewLinkPlanner.localTargetIsCurrent(originalLink))

        try FileManager.default.moveItem(at: project, to: displacedProject)
        for directory in [notes, assets, guides] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("# Replacement source".utf8).write(to: sourceURL)
        try pngData().write(to: imageURL)
        try Data("# Replacement target".utf8).write(to: linkedURL)

        let imageMarkdown = "![inside](../assets/inside.png)"
        let guardedHTML = MarkdownRenderer.htmlDocument(
            for: imageMarkdown,
            documentDirectory: notes,
            projectRoot: project,
            expectedProjectRootIdentity: projectIdentity,
            requiresProjectBoundary: true
        )
        XCTAssertTrue(guardedHTML.contains("无法读取项目外图片"), guardedHTML)
        XCTAssertFalse(guardedHTML.contains("data:image/png;base64,"), guardedHTML)

        let invalidProjectFallback = MarkdownRenderer.htmlDocument(
            for: imageMarkdown,
            documentDirectory: nil,
            projectRoot: nil,
            requiresProjectBoundary: true
        )
        XCTAssertTrue(invalidProjectFallback.contains("暂时无法读取相对图片"))
        XCTAssertFalse(invalidProjectFallback.contains("data:image/png;base64,"))
        let absoluteFallback = MarkdownRenderer.htmlDocument(
            for: "![inside](\(imageURL.absoluteString))",
            documentDirectory: notes,
            projectRoot: nil,
            requiresProjectBoundary: true
        )
        XCTAssertTrue(absoluteFallback.contains("无法读取项目外图片"), absoluteFallback)
        XCTAssertFalse(absoluteFallback.contains("data:image/png;base64,"), absoluteFallback)

        XCTAssertFalse(PreviewLinkPlanner.localTargetIsCurrent(originalLink))
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[inside](\(linkTarget))",
                target: linkTarget,
                documentURL: sourceURL,
                projectRoot: project,
                expectedProjectRootIdentity: projectIdentity
            )),
            .outsideProject
        )
    }

    func testMissingAndUnsavedRelativeImagesShowSpecificLocalPlaceholders() {
        let saved = MarkdownRenderer.htmlDocument(
            for: "![封面](assets/missing.png)",
            documentDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertTrue(saved.contains("找不到资源"))
        XCTAssertTrue(saved.contains("assets/missing.png"), saved)
        XCTAssertTrue(saved.contains("data-inflow-image-source-start=\"0\""))
        XCTAssertTrue(saved.contains("data-inflow-image-target-hex=\"\(hex("assets/missing.png"))\""))
        XCTAssertTrue(saved.contains("data-inflow-image-action=\"replace\""))
        XCTAssertTrue(saved.contains("选择替代文件…"))
        XCTAssertTrue(saved.contains("data-inflow-image-action=\"locate\""))
        XCTAssertTrue(saved.contains("data-inflow-image-action=\"ignore\""))

        let unsaved = MarkdownRenderer.htmlDocument(
            for: "![封面](assets/missing.png)",
            documentDirectory: nil
        )
        XCTAssertTrue(unsaved.contains("暂时无法读取相对图片"))
        XCTAssertTrue(unsaved.contains("请先保存文档"))
    }

    func testRemoteImagesRenderWhileUnsupportedLocalImagesStayBlocked() throws {
        let remote = MarkdownRenderer.htmlDocument(
            for: "![外部](https://private.example/path/secret.png)"
        )
        XCTAssertTrue(remote.contains("class=\"inflow-remote-image\""))
        XCTAssertTrue(remote.contains("src=\"https://private.example/path/secret.png\""))
        XCTAssertTrue(remote.contains("loading=\"lazy\""))
        XCTAssertTrue(remote.contains("referrerpolicy=\"no-referrer\""))
        XCTAssertFalse(remote.contains("data-inflow-image-action"))

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disguised = directory.appendingPathComponent("wrong.jpg")
        try pngData().write(to: disguised)
        let mismatch = MarkdownRenderer.htmlDocument(
            for: "![伪装](wrong.jpg)",
            documentDirectory: directory
        )
        XCTAssertTrue(mismatch.contains("图片类型与扩展名不一致"))
        XCTAssertFalse(mismatch.contains("data:image"))
    }

    func testCoreImageSlotsAreInertUntilResolvedByThePlatform() throws {
        let fragment = try MarkdownRenderer.htmlFragment(
            for: "![封面](assets/cover.png)"
        )
        XCTAssertTrue(fragment.contains("class=\"inflow-image-slot\""))
        XCTAssertFalse(fragment.contains("<img"))
        XCTAssertFalse(fragment.contains("src="))

        let mismatched = LocalImageResolver.resolveSlots(
            in: fragment,
            documentDirectory: FileManager.default.temporaryDirectory,
            imageReferences: []
        )
        XCTAssertTrue(mismatched.contains("找不到资源"))
        XCTAssertFalse(mismatched.contains("data-inflow-image-source-start"))
        XCTAssertFalse(mismatched.contains("data-inflow-image-action"))
    }

    func testSplitViewIsTheDefaultMode() {
        XCTAssertEqual(EditorViewMode.split.rawValue, "split")
        XCTAssertEqual(EditorViewMode.allCases.count, 3)
    }

    func testPreviewHeadingsCarryExactSourceOffsetsOnlyWhenEnabled() throws {
        let markdown = "# 重复\n\n正文\n\n## 重复\n"
        let analysis = try MarkdownAnalyzer.analyze(markdown)
        let enabled = MarkdownRenderer.htmlDocument(
            for: markdown,
            navigationHeadings: analysis.headings
        )

        XCTAssertEqual(enabled.components(separatedBy: "<h1 id=\"重复\" data-inflow-source-start").count - 1, 1)
        XCTAssertEqual(enabled.components(separatedBy: "<h2 id=\"重复-1\" data-inflow-source-start").count - 1, 1)
        XCTAssertTrue(enabled.contains(
            "<h1 id=\"重复\" data-inflow-source-start=\"\(analysis.headings[0].sourceUTF8Range.lowerBound)\" tabindex=\"0\""
        ))
        XCTAssertTrue(enabled.contains(
            "<h2 id=\"重复-1\" data-inflow-source-start=\"\(analysis.headings[1].sourceUTF8Range.lowerBound)\" tabindex=\"0\""
        ))
        XCTAssertFalse(enabled.contains("<script"))

        let disabled = MarkdownRenderer.htmlDocument(for: markdown)
        XCTAssertFalse(disabled.contains("<h1 data-inflow-source-start"))
        XCTAssertFalse(disabled.contains("<h1 id="))
        XCTAssertFalse(disabled.contains("id=\"重复\""))
    }

    func testHeadingAnnotationFailsClosedWhenAnalysisDoesNotMatchRenderedHeadings() {
        let fragment = "<h1>One</h1><h2>Two</h2>"
        let mismatched = [
            DocumentHeading(level: 2, title: "One", sourceUTF8Range: 0..<5),
            DocumentHeading(level: 1, title: "Two", sourceUTF8Range: 6..<11),
        ]

        XCTAssertEqual(
            PreviewNavigationMarkup.annotateHeadings(in: fragment, headings: mismatched),
            fragment
        )
    }

    func testHeadingIdentifiersUseOneStableNormalizedContract() {
        let headings = [
            DocumentHeading(level: 1, title: "Cafe\u{301}", sourceUTF8Range: 0..<1),
            DocumentHeading(level: 2, title: "  A \t -- B  ", sourceUTF8Range: 1..<2),
            DocumentHeading(level: 3, title: "!!!", sourceUTF8Range: 2..<3),
            DocumentHeading(level: 4, title: "!!!", sourceUTF8Range: 3..<4),
        ]

        XCTAssertEqual(
            HeadingIdentifier.identifiers(for: headings),
            ["café", "a-b", "section", "section-1"]
        )
        XCTAssertEqual(HeadingIdentifier.base(for: "  --hello---world--  "), "hello-world")
        XCTAssertEqual(HeadingIdentifier.base(for: "中文 _ 42"), "中文-_-42")
    }

    func testHeadingAnnotationWritesOnlyEscapedGeneratedDOMIdentifiers() {
        let heading = DocumentHeading(
            level: 1,
            title: "\"&<>",
            sourceUTF8Range: 0..<4
        )
        let annotated = PreviewNavigationMarkup.annotateHeadings(
            in: "<h1>unsafe</h1>",
            headings: [heading]
        )

        XCTAssertTrue(annotated.contains("<h1 id=\"section\" data-inflow-source-start=\"0\""))
        XCTAssertFalse(annotated.contains("id=\"\"&<>"))
    }

    func testLinkAnnotationCarriesExactParsedTargetAndFailsClosedOnCountDrift() throws {
        let markdown = "Footnote[^n] [space](<https://example.com/a b>) [资料](资料/说明.md)\n\n[^n]: Note"
        let html = MarkdownRenderer.htmlDocument(for: markdown)

        XCTAssertTrue(html.contains("<a href=\"#n\">1</a>"))
        XCTAssertFalse(html.contains("<a href=\"#n\" data-inflow-link-target-hex"))
        XCTAssertTrue(html.contains("href=\"https://example.com/a%20b\""))
        XCTAssertTrue(html.contains(
            "data-inflow-link-target-hex=\"\(hex("https://example.com/a b"))\""
        ))
        XCTAssertTrue(html.contains(
            "data-inflow-link-target-hex=\"\(hex("资料/说明.md"))\""
        ))

        let fragment = try MarkdownRenderer.htmlFragment(for: markdown)
        XCTAssertEqual(
            PreviewNavigationMarkup.annotateLinks(in: fragment, targets: ["only-one"]),
            fragment
        )
    }

    func testPreviewBridgeAcceptsOnlyClosedNavigationMessages() {
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "heading",
                "sourceUTF8Offset": NSNumber(value: 42),
            ]),
            .heading(sourceUTF8Offset: 42)
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode(["type": "manualScroll"]),
            .manualScroll
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "previewIssue",
                "action": "locate",
                "sourceUTF8Offset": NSNumber(value: 19),
            ]),
            .previewIssue(action: .locate, sourceUTF8Offset: 19)
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "imageIssue",
                "action": "replace",
                "sourceUTF8Offset": NSNumber(value: 23),
                "targetHex": hex("assets/图.png"),
            ]),
            .imageIssue(
                action: .replace,
                sourceUTF8Offset: 23,
                target: "assets/图.png"
            )
        )
        XCTAssertEqual(
            PreviewNavigationMessage.decode([
                "type": "link",
                "targetHex": hex("../资料/说明.md#标题"),
            ]),
            .link(target: "../资料/说明.md#标题")
        )
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "heading",
            "sourceUTF8Offset": "private document text",
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "heading",
            "sourceUTF8Offset": NSNumber(value: true),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "heading",
            "sourceUTF8Offset": NSNumber(value: 1.5),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "link",
            "targetHex": "0g",
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "link",
            "targetHex": hex("https://example.com/\nprivate"),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "previewIssue",
            "action": "open-private-path",
            "sourceUTF8Offset": NSNumber(value: 0),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "imageIssue",
            "action": "open-file",
            "sourceUTF8Offset": NSNumber(value: 0),
            "targetHex": hex("private.png"),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "imageIssue",
            "action": "locate",
            "sourceUTF8Offset": NSNumber(value: true),
            "targetHex": hex("private.png"),
        ]))
        XCTAssertNil(PreviewNavigationMessage.decode([
            "type": "unknown",
            "document": "must not cross bridge",
        ]))
    }

    @MainActor
    func testPreviewCoordinatorRoutesHeadingAndManualScrollWithoutDocumentContent() {
        XCTAssertTrue(
            PreviewWebNavigationPolicy.allows(
                navigationType: .other,
                scheme: "applewebdata"
            )
        )
        XCTAssertTrue(
            PreviewWebNavigationPolicy.allows(navigationType: .other, scheme: "about")
        )
        XCTAssertFalse(
            PreviewWebNavigationPolicy.allows(navigationType: .other, scheme: "https")
        )
        XCTAssertFalse(
            PreviewWebNavigationPolicy.allows(
                navigationType: .linkActivated,
                scheme: "applewebdata"
            )
        )

        let coordinator = MarkdownPreviewView.Coordinator()
        let webView = WKWebView()
        var selectedOffset: Int?
        var selectedLink: String?
        var selectedIssue: (PreviewIssueAction, Int)?
        var selectedImageIssue: (PreviewImageIssueAction, Int, String)?
        var manualScrollCount = 0
        coordinator.update(
            scrollRequest: PreviewScrollRequest(generation: 1, fraction: 0.5),
            onHeadingActivated: { selectedOffset = $0 },
            onLinkActivated: { selectedLink = $0 },
            onPreviewIssueAction: { selectedIssue = ($0, $1) },
            onImageIssueAction: { selectedImageIssue = ($0, $1, $2) },
            onManualScroll: { manualScrollCount += 1 },
            webView: webView
        )

        coordinator.handle(.heading(sourceUTF8Offset: 128))
        coordinator.handle(.link(target: "https://example.com"))
        coordinator.handle(.previewIssue(action: .retry, sourceUTF8Offset: 64))
        coordinator.handle(.imageIssue(
            action: .copyTarget,
            sourceUTF8Offset: 72,
            target: "https://example.com/image.png"
        ))
        coordinator.handle(.manualScroll)

        XCTAssertEqual(selectedOffset, 128)
        XCTAssertEqual(selectedLink, "https://example.com")
        XCTAssertEqual(selectedIssue?.0, .retry)
        XCTAssertEqual(selectedIssue?.1, 64)
        XCTAssertEqual(selectedImageIssue?.0, .copyTarget)
        XCTAssertEqual(selectedImageIssue?.1, 72)
        XCTAssertEqual(selectedImageIssue?.2, "https://example.com/image.png")
        XCTAssertEqual(manualScrollCount, 1)
    }

    func testPreviewIssueNavigationRejectsStaleAndInvalidUTF8Offsets() throws {
        let rendered = "# 图表\n\n```mermaid\npie\n```"
        let marker = try XCTUnwrap(rendered.range(of: "```mermaid"))
        let markerStart = try XCTUnwrap(marker.lowerBound.samePosition(in: rendered.utf8))
        let offset = rendered.utf8.distance(from: rendered.utf8.startIndex, to: markerStart)
        XCTAssertEqual(
            PreviewIssueNavigation.validatedOffset(
                offset,
                renderedSource: rendered,
                currentSource: rendered
            ),
            offset
        )
        XCTAssertNil(PreviewIssueNavigation.validatedOffset(
            offset,
            renderedSource: rendered,
            currentSource: rendered + "\nchanged"
        ))
        XCTAssertNil(PreviewIssueNavigation.validatedOffset(
            2,
            renderedSource: "e\u{301}",
            currentSource: "e\u{301}"
        ))
    }

    func testImageIssueNavigationUsesExactDuplicateReferenceAndRejectsStaleContent() throws {
        let markdown = "![第一张](missing.png)\n\n![第二张](missing.png)"
        let references = try MarkdownReferenceScanner.references(in: markdown)
        let second = try XCTUnwrap(references.last)

        XCTAssertEqual(
            PreviewImageIssueNavigation.validatedReference(
                sourceUTF8Offset: second.sourceUTF8Range.lowerBound,
                target: "missing.png",
                renderedSource: markdown,
                currentSource: markdown
            ),
            second
        )
        XCTAssertNil(PreviewImageIssueNavigation.validatedReference(
            sourceUTF8Offset: references[0].sourceUTF8Range.lowerBound,
            target: "other.png",
            renderedSource: markdown,
            currentSource: markdown
        ))
        XCTAssertNil(PreviewImageIssueNavigation.validatedReference(
            sourceUTF8Offset: second.sourceUTF8Range.lowerBound,
            target: "missing.png",
            renderedSource: markdown,
            currentSource: markdown + "\nchanged"
        ))
    }

    func testLinkPlannerRequiresAnExactParsedReferenceAndSupportsWebAndFileURLs() {
        let markdown = "[web](https://example.com/path) [mail](mailto:writer@example.com)"
        let web = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "https://example.com/path",
            documentURL: nil
        )
        guard case let .external(link) = web.destination else {
            return XCTFail("expected an external link")
        }
        XCTAssertEqual(link.url.absoluteString, "https://example.com/path")
        XCTAssertEqual(link.displayDestination, "example.com")
        XCTAssertTrue(PreviewLinkPlanner.isCurrent(web, markdown: markdown))
        XCTAssertFalse(PreviewLinkPlanner.isCurrent(web, markdown: markdown + "\nchanged"))

        let stale = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "https://removed.example",
            documentURL: nil
        )
        XCTAssertEqual(blockedReason(stale), .noLongerInDocument)

        let unsafeMarkdown = "[script](javascript:alert%281%29) [credentials](https://user:pass@example.com)"
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: unsafeMarkdown,
                target: "javascript:alert%281%29",
                documentURL: nil
            )),
            .unsupportedScheme
        )
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: unsafeMarkdown,
                target: "https://user:pass@example.com",
                documentURL: nil
            )),
            .invalidTarget
        )
        let encodedControl = "https://example.com/%0Aprivate"
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[control](\(encodedControl))",
                target: encodedControl,
                documentURL: nil
            )),
            .invalidTarget
        )
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[mail](mailto:writer@example.com?body=private)",
                target: "mailto:writer@example.com?body=private",
                documentURL: nil
            )),
            .unsupportedScheme
        )

        let fileURL = URL(fileURLWithPath: "/tmp/inflow-missing-file.md")
        let filePlan = PreviewLinkPlanner.plan(
            markdown: "[file](\(fileURL.absoluteString))",
            target: fileURL.absoluteString,
            documentURL: nil
        )
        guard case let .local(fileLink) = filePlan.destination else {
            return XCTFail("file URLs must reach Launch Services without a speculative read")
        }
        XCTAssertNil(fileLink.snapshot)
        XCTAssertTrue(PreviewLinkOpenPolicy.usesSystemApplication(fileLink))

        let disallowedSchemes = [
            "mailto:writer@example.com",
            "ftp://example.com/archive.zip",
            "inflow-script:run",
        ]
        for target in disallowedSchemes {
            XCTAssertEqual(
                blockedReason(PreviewLinkPlanner.plan(
                    markdown: "[target](\(target))",
                    target: target,
                    documentURL: nil
                )),
                .unsupportedScheme,
                target
            )
        }
    }

    func testProjectLinkPlannerSupportsNormalizedTargetsInsideAndOutsideRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let project = container.appendingPathComponent("project", isDirectory: true)
        let notes = project.appendingPathComponent("notes", isDirectory: true)
        let guides = project.appendingPathComponent("guides", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        for directory in [notes, guides, outside] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let sourceURL = notes.appendingPathComponent("source.md")
        let insideURL = guides.appendingPathComponent("inside.md")
        let outsideURL = outside.appendingPathComponent("outside.md")
        try Data("# Source\n".utf8).write(to: sourceURL)
        try Data("# Inside\n".utf8).write(to: insideURL)
        try Data("# Outside\n".utf8).write(to: outsideURL)

        let insideTarget = "../guides/./inside.md"
        let insidePlan = PreviewLinkPlanner.plan(
            markdown: "[inside](\(insideTarget))",
            target: insideTarget,
            documentURL: sourceURL,
            projectRoot: project
        )
        guard case let .local(insideLink) = insidePlan.destination else {
            return XCTFail("expected a project-local link")
        }
        XCTAssertEqual(insideLink.url.standardizedFileURL, insideURL.standardizedFileURL)
        XCTAssertEqual(
            insideLink.projectRoot,
            try FolderProjectPathBoundary.normalizedProjectRoot(project)
        )

        let absoluteInsideTarget = insideURL.path
        let absoluteInsidePlan = PreviewLinkPlanner.plan(
            markdown: "[absolute inside](\(absoluteInsideTarget))",
            target: absoluteInsideTarget,
            documentURL: sourceURL,
            projectRoot: project
        )
        guard case let .local(absoluteInsideLink) = absoluteInsidePlan.destination else {
            return XCTFail("expected an absolute project-local link")
        }
        XCTAssertEqual(
            absoluteInsideLink.url.standardizedFileURL,
            insideURL.standardizedFileURL
        )

        let escapingTarget = "../../outside/outside.md"
        let escapingPlan = PreviewLinkPlanner.plan(
            markdown: "[outside](\(escapingTarget))",
            target: escapingTarget,
            documentURL: sourceURL,
            projectRoot: project
        )
        guard case let .local(outsideLink) = escapingPlan.destination else {
            return XCTFail("expected an outside-project local link")
        }
        XCTAssertEqual(outsideLink.url.standardizedFileURL, outsideURL.standardizedFileURL)
        XCTAssertNil(outsideLink.projectRoot)

        let escapingLink = notes.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: escapingLink,
            withDestinationURL: outside
        )
        let symlinkTarget = "escape/outside.md"
        guard case let .local(symlinkLink) = PreviewLinkPlanner.plan(
            markdown: "[symlink](\(symlinkTarget))",
            target: symlinkTarget,
            documentURL: sourceURL,
            projectRoot: project
        ).destination else {
            return XCTFail("expected a directory-symlink local link")
        }
        XCTAssertEqual(
            symlinkLink.url.resolvingSymlinksInPath().standardizedFileURL,
            outsideURL.standardizedFileURL
        )
        XCTAssertNil(symlinkLink.projectRoot)

        let absoluteTarget = outsideURL.path
        guard case let .local(absoluteLink) = PreviewLinkPlanner.plan(
            markdown: "[absolute](\(absoluteTarget))",
            target: absoluteTarget,
            documentURL: sourceURL,
            projectRoot: project
        ).destination else {
            return XCTFail("expected an absolute outside-project local link")
        }
        XCTAssertEqual(absoluteLink.url.standardizedFileURL, outsideURL.standardizedFileURL)
        XCTAssertNil(absoluteLink.projectRoot)
    }

    func testLinkPlannerResolvesCurrentAndDuplicateUnicodeHeadingAnchors() throws {
        let markdown = "# Café\n\n# Café\n\n## 中文 标题\n\n[same](#caf%C3%A9-1)"
        let analysis = try MarkdownAnalyzer.analyze(markdown)
        let plan = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "#caf%C3%A9-1",
            documentURL: nil
        )
        XCTAssertEqual(plan.destination, .currentDocument(fragment: "café-1"))
        XCTAssertEqual(
            PreviewHeadingAnchorResolver.heading(for: "café-1", in: analysis.headings),
            analysis.headings[1]
        )
        XCTAssertEqual(
            PreviewHeadingAnchorResolver.heading(
                for: "中文-标题",
                in: analysis.headings
            ),
            analysis.headings[2]
        )
        XCTAssertNil(
            PreviewHeadingAnchorResolver.heading(
                for: "%E4%B8%AD%E6%96%87-%E6%A0%87%E9%A2%98",
                in: analysis.headings
            )
        )
        XCTAssertNil(PreviewHeadingAnchorResolver.heading(for: "missing", in: analysis.headings))
    }

    func testHeadingFragmentsDecodeExactlyOnceBeforeExactDOMIdentifierMatch() throws {
        let markdown = "# foo bar\n\n[once](#foo%20bar) [twice](#foo%2520bar)"
        let analysis = try MarkdownAnalyzer.analyze(markdown)
        let once = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "#foo%20bar",
            documentURL: nil
        )
        let twice = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "#foo%2520bar",
            documentURL: nil
        )

        XCTAssertEqual(once.destination, .currentDocument(fragment: "foo bar"))
        XCTAssertEqual(twice.destination, .currentDocument(fragment: "foo%20bar"))
        XCTAssertNil(PreviewHeadingAnchorResolver.heading(for: "foo bar", in: analysis.headings))
        XCTAssertNil(PreviewHeadingAnchorResolver.heading(for: "foo%20bar", in: analysis.headings))
        XCTAssertEqual(
            PreviewHeadingAnchorResolver.heading(for: "foo-bar", in: analysis.headings),
            analysis.headings[0]
        )
    }

    func testLinkPlannerClassifiesLocalTargetsAndInvalidatesChangedSnapshots() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.md")
        let targetURL = directory.appendingPathComponent("guide.md")
        try Data("# Target\n".utf8).write(to: targetURL)
        let markdown = "[guide](guide.md#target)"

        let plan = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "guide.md#target",
            documentURL: sourceURL,
            projectRoot: directory
        )
        guard case let .local(link) = plan.destination else {
            return XCTFail("expected a local link")
        }
        XCTAssertEqual(link.kind, .markdown)
        XCTAssertEqual(link.fragment, "target")
        XCTAssertEqual(link.url.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertTrue(PreviewLinkPlanner.localTargetIsCurrent(link))
        XCTAssertTrue(
            PreviewLinkActivationPolicy.opensWithoutConfirmation(plan),
            "an explicit click opens a current local target without another confirmation"
        )

        let projectIdentity = try XCTUnwrap(
            FolderProjectDirectoryIdentity.capture(directory)
        )
        let trustedProjectPlan = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "guide.md#target",
            documentURL: sourceURL,
            projectRoot: directory,
            expectedProjectRootIdentity: projectIdentity
        )
        XCTAssertTrue(
            PreviewLinkActivationPolicy.opensWithoutConfirmation(trustedProjectPlan),
            "a current Markdown target inside the user-selected project opens directly"
        )
        guard case let .local(trustedProjectLink) = trustedProjectPlan.destination else {
            return XCTFail("expected a trusted project link")
        }
        XCTAssertFalse(PreviewLinkOpenPolicy.usesSystemApplication(trustedProjectLink))

        let trustedImageURL = directory.appendingPathComponent("cover.png")
        try pngData().write(to: trustedImageURL)
        let trustedImagePlan = PreviewLinkPlanner.plan(
            markdown: "[cover](cover.png)",
            target: "cover.png",
            documentURL: sourceURL,
            projectRoot: directory,
            expectedProjectRootIdentity: projectIdentity
        )
        XCTAssertTrue(
            PreviewLinkActivationPolicy.opensWithoutConfirmation(trustedImagePlan),
            "an explicit click opens a current local image without another confirmation"
        )
        guard case let .local(trustedImageLink) = trustedImagePlan.destination else {
            return XCTFail("expected a trusted image link")
        }
        XCTAssertFalse(PreviewLinkOpenPolicy.usesSystemApplication(trustedImageLink))

        try Data("# Replaced with different bytes\n".utf8).write(to: targetURL)
        XCTAssertFalse(PreviewLinkPlanner.localTargetIsCurrent(link))
        XCTAssertFalse(
            PreviewLinkActivationPolicy.opensWithoutConfirmation(trustedProjectPlan),
            "a target changed after planning must never use the direct project path"
        )

        let independentRelative = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "guide.md#target",
            documentURL: sourceURL
        )
        guard case let .local(independentRelativeLink) = independentRelative.destination else {
            return XCTFail("expected an independent relative local link")
        }
        XCTAssertNil(independentRelativeLink.projectRoot)
        XCTAssertNil(independentRelativeLink.snapshot)
        XCTAssertTrue(PreviewLinkOpenPolicy.usesSystemApplication(independentRelativeLink))

        let absoluteTarget = targetURL.path
        let independentAbsolute = PreviewLinkPlanner.plan(
            markdown: "[guide](\(absoluteTarget))",
            target: absoluteTarget,
            documentURL: sourceURL
        )
        guard case let .local(independentAbsoluteLink) = independentAbsolute.destination else {
            return XCTFail("expected an independent absolute local link")
        }
        XCTAssertNil(independentAbsoluteLink.projectRoot)
        XCTAssertNil(independentAbsoluteLink.snapshot)
        XCTAssertTrue(PreviewLinkOpenPolicy.usesSystemApplication(independentAbsoluteLink))

        let unsavedProjectDocument = PreviewLinkPlanner.plan(
            markdown: markdown,
            target: "guide.md#target",
            documentURL: nil,
            projectRoot: directory
        )
        XCTAssertEqual(
            blockedReason(unsavedProjectDocument),
            .relativeTargetNeedsSavedDocument
        )

        let sameDocument = PreviewLinkPlanner.plan(
            markdown: "[top](source.md#top)",
            target: "source.md#top",
            documentURL: sourceURL,
            projectRoot: directory
        )
        XCTAssertEqual(sameDocument.destination, .currentDocument(fragment: "top"))

        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[missing](missing.pdf)",
                target: "missing.pdf",
                documentURL: sourceURL,
                projectRoot: directory
            )),
            .missingLocalTarget
        )

        let attachmentURL = directory.appendingPathComponent("archive.zip")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: attachmentURL)
        let attachmentPlan = PreviewLinkPlanner.plan(
            markdown: "[archive](archive.zip)",
            target: "archive.zip",
            documentURL: sourceURL
        )
        guard case let .local(attachment) = attachmentPlan.destination else {
            return XCTFail("expected a generic local attachment")
        }
        XCTAssertEqual(attachment.kind, .attachment)
        guard case let .local(projectAttachment) = PreviewLinkPlanner.plan(
            markdown: "[archive](archive.zip)",
            target: "archive.zip",
            documentURL: sourceURL,
            projectRoot: directory
        ).destination else {
            return XCTFail("expected a project attachment")
        }
        XCTAssertEqual(projectAttachment.kind, .attachment)
        XCTAssertTrue(PreviewLinkOpenPolicy.usesSystemApplication(projectAttachment))

        let fakePDF = directory.appendingPathComponent("fake.pdf")
        try Data("not pdf".utf8).write(to: fakePDF)
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[fake](fake.pdf)",
                target: "fake.pdf",
                documentURL: sourceURL,
                projectRoot: directory
            )),
            .unsafeLocalTarget
        )
    }

    func testLinkPlannerValidatesImageContentAndNeverFollowsSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.md")
        let imageURL = directory.appendingPathComponent("cover.png")
        try pngData().write(to: imageURL)

        let imageMarkdown = "[cover](cover.png)"
        let imagePlan = PreviewLinkPlanner.plan(
            markdown: imageMarkdown,
            target: "cover.png",
            documentURL: sourceURL,
            projectRoot: directory
        )
        guard case let .local(image) = imagePlan.destination else {
            return XCTFail("expected a validated local image")
        }
        XCTAssertEqual(image.kind, .image)

        let fakeURL = directory.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: fakeURL)
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[fake](fake.png)",
                target: "fake.png",
                documentURL: sourceURL,
                projectRoot: directory
            )),
            .unsafeLocalTarget
        )
        guard case let .local(systemImageLink) = PreviewLinkPlanner.plan(
            markdown: "[fake](fake.png)",
            target: "fake.png",
            documentURL: directory.appendingPathComponent("source.md")
        ).destination else {
            return XCTFail("an explicitly clicked external image should reach Launch Services")
        }
        XCTAssertTrue(PreviewLinkOpenPolicy.usesSystemApplication(systemImageLink))

        let aliasURL = directory.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: imageURL)
        XCTAssertEqual(
            blockedReason(PreviewLinkPlanner.plan(
                markdown: "[alias](alias.md)",
                target: "alias.md",
                documentURL: sourceURL,
                projectRoot: directory
            )),
            .unsafeLocalTarget
        )
    }

    @MainActor
    func testSafePreviewMaintenanceCleansExpiredManagedCopiesAtStartupSafely() throws {
        let root = try temporaryDirectory().appendingPathComponent(
            "SafeOpen",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let expired = root.appendingPathComponent("\(UUID().uuidString).png")
        let protected = root.appendingPathComponent("\(UUID().uuidString).md")
        let unmanaged = root.appendingPathComponent("keep.pdf")
        let directory = root.appendingPathComponent("\(UUID().uuidString).pdf", isDirectory: true)
        let symlink = root.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("expired".utf8).write(to: expired)
        try Data("protected".utf8).write(to: protected)
        try Data("keep".utf8).write(to: unmanaged)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unmanaged)
        let oldDate = Date().addingTimeInterval(-120)
        for url in [expired, protected, unmanaged, directory] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
        }

        let maintenance = SafePreviewOpenMaintenance(
            rootURL: root,
            retentionInterval: 60,
            intervalNanoseconds: 60_000_000_000,
            excludedPaths: { [protected.standardizedFileURL.path] }
        )
        maintenance.start()
        defer { maintenance.stop() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    @MainActor
    func testSafePreviewMaintenanceRepeatsStopsAndDoesNotRetainItsOwner() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("SafeOpen", isDirectory: true)
        let maintenance = SafePreviewOpenMaintenance(
            rootURL: root,
            retentionInterval: 60,
            intervalNanoseconds: 5_000_000
        )
        maintenance.start()
        maintenance.start()
        XCTAssertTrue(maintenance.isRunning)

        let periodicallyExpired = root.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data("periodic".utf8).write(to: periodicallyExpired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: periodicallyExpired.path
        )
        for _ in 0 ..< 100
        where FileManager.default.fileExists(atPath: periodicallyExpired.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: periodicallyExpired.path))

        maintenance.stop()
        XCTAssertFalse(maintenance.isRunning)
        let retainedAfterStop = root.appendingPathComponent("\(UUID().uuidString).png")
        try Data("stopped".utf8).write(to: retainedAfterStop)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: retainedAfterStop.path
        )
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedAfterStop.path))

        let lifecycleRoot = container.appendingPathComponent("Lifecycle", isDirectory: true)
        weak var weakMaintenance: SafePreviewOpenMaintenance?
        do {
            let shortLived = SafePreviewOpenMaintenance(
                rootURL: lifecycleRoot,
                retentionInterval: 60,
                intervalNanoseconds: 5_000_000
            )
            weakMaintenance = shortLived
            shortLived.start()
        }
        await Task.yield()
        XCTAssertNil(weakMaintenance)
    }

    @MainActor
    func testSourceEditorPublishesNormalizedScrollFraction() {
        let session = MarkdownSourceEditorSession()
        session.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1_000))
        session.scrollView.documentView = documentView
        session.scrollView.layoutSubtreeIfNeeded()
        session.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 400))
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: session.scrollView.contentView
        )

        XCTAssertEqual(session.verticalScrollFraction, 0.5, accuracy: 0.01)
    }

    @MainActor
    func testAppScrollWorksWhilePageContentJavaScriptIsDisabled() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300),
            configuration: configuration
        )
        let loaded = expectation(description: "preview loaded")
        let delegate = PreviewTestLoadDelegate { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<html><body style=\"height: 5000px\">Long preview</body></html>",
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 5)

        let coordinator = MarkdownPreviewView.Coordinator()
        coordinator.update(
            scrollRequest: PreviewScrollRequest(generation: 7, fraction: 0.75),
            onHeadingActivated: { _ in },
            onLinkActivated: { _ in },
            onPreviewIssueAction: { _, _ in },
            onManualScroll: {},
            webView: webView
        )
        coordinator.webView(webView, didFinish: nil)

        for _ in 0..<50 {
            let value = try await webView.evaluateJavaScript("window.scrollY")
            if let y = value as? Double, y > 1_000 {
                XCTAssertLessThan(y, 5_000)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("isolated app script did not scroll the preview")
    }

    @MainActor
    func testMountedPreviewReportsExactLinkWhilePageScriptsRemainDisabled() async throws {
        let received = expectation(description: "link reported")
        var receivedTarget: String?
        let markdown = "[打开](<https://example.com/a b?x=1&y=2>)"
        let root = MarkdownPreviewView(
            html: MarkdownRenderer.htmlDocument(for: markdown),
            baseURL: nil,
            onLinkActivated: { target in
                receivedTarget = target
                received.fulfill()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var webView: WKWebView?
        var linkIsReady = false
        for _ in 0..<100 {
            webView = descendants(of: hosting).compactMap { $0 as? WKWebView }.first
            if let candidate = webView,
               candidate.isLoading == false,
               let isReady = try? await candidate.callAsyncJavaScript(
                   "return document.querySelector('a[data-inflow-link-target-hex]') !== null;",
                   arguments: [:],
                   in: nil,
                   contentWorld: .defaultClient
               ) as? Bool,
               isReady
            {
                linkIsReady = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let mounted = try XCTUnwrap(webView)
        XCTAssertTrue(linkIsReady)
        XCTAssertFalse(mounted.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        _ = try await mounted.callAsyncJavaScript(
            "document.querySelector('a').click(); return true;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(receivedTarget, "https://example.com/a b?x=1&y=2")
    }

    @MainActor
    func testMountedMermaidFailureRoutesOnlyClosedRecoveryActions() async throws {
        let received = expectation(description: "preview issue actions reported")
        received.expectedFulfillmentCount = 2
        var actions: [(PreviewIssueAction, Int)] = []
        let markdown = "前文\n\n```mermaid\npie\ntitle Values\n```"
        let marker = try XCTUnwrap(markdown.range(of: "```mermaid"))
        let markerStart = try XCTUnwrap(marker.lowerBound.samePosition(in: markdown.utf8))
        let expectedOffset = markdown.utf8.distance(
            from: markdown.utf8.startIndex,
            to: markerStart
        )
        let root = MarkdownPreviewView(
            html: MarkdownRenderer.htmlDocument(for: markdown),
            baseURL: nil,
            onPreviewIssueAction: { action, offset in
                actions.append((action, offset))
                received.fulfill()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var webView: WKWebView?
        var actionsAreReady = false
        for _ in 0..<100 {
            webView = descendants(of: hosting).compactMap { $0 as? WKWebView }.first
            if let candidate = webView,
               candidate.isLoading == false,
               let isReady = try? await candidate.callAsyncJavaScript(
                   "return document.querySelectorAll('[data-inflow-preview-error-action]').length === 2;",
                   arguments: [:],
                   in: nil,
                   contentWorld: .defaultClient
               ) as? Bool,
               isReady
            {
                actionsAreReady = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let mounted = try XCTUnwrap(webView)
        XCTAssertTrue(actionsAreReady)
        XCTAssertFalse(mounted.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        for action in ["locate", "retry"] {
            _ = try await mounted.callAsyncJavaScript(
                "document.querySelector(`[data-inflow-preview-error-action='${action}']`).click(); return true;",
                arguments: ["action": action],
                in: nil,
                contentWorld: .defaultClient
            )
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(actions.map(\.0), [.locate, .retry])
        XCTAssertEqual(actions.map(\.1), [expectedOffset, expectedOffset])
    }

    @MainActor
    func testMountedRemoteImageUsesARestrictedNetworkImageElement() async throws {
        let target = "https://private.example/图.png?token=secret"
        let renderedTarget = try XCTUnwrap(URL(string: target)?.absoluteString)
        let root = MarkdownPreviewView(
            html: MarkdownRenderer.htmlDocument(for: "![图](\(target))"),
            baseURL: nil
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        var webView: WKWebView?
        var imageIsReady = false
        for _ in 0..<100 {
            webView = descendants(of: hosting).compactMap { $0 as? WKWebView }.first
            if let candidate = webView,
               let isReady = try? await candidate.callAsyncJavaScript(
                   "const image = document.querySelector('img.inflow-remote-image'); return image?.getAttribute('src') === target && image?.getAttribute('referrerpolicy') === 'no-referrer';",
                   arguments: ["target": renderedTarget],
                   in: nil,
                   contentWorld: .defaultClient
               ) as? Bool,
               isReady
            {
                imageIsReady = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let mounted = try XCTUnwrap(webView)
        XCTAssertTrue(imageIsReady)
        XCTAssertFalse(mounted.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inflow-image-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData() throws -> Data {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 4,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(representation.bitmapData)
        pixels[0] = 32
        pixels[1] = 96
        pixels[2] = 220
        pixels[3] = 255
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func blockedReason(_ plan: PreviewLinkPlan) -> PreviewLinkFailureReason? {
        guard case let .blocked(failure) = plan.destination else { return nil }
        return failure.reason
    }

    private func hex(_ value: String) -> String {
        Data(value.utf8).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class PreviewTestLoadDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        onFinish()
    }
}
