import Foundation
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Inflow

final class MarkdownCodecTests: XCTestCase {
    @MainActor
    func testHostedEditorRetainsSessionAndRenderingAcrossViewReconstruction() async throws {
        let sample = "# 产品方案\n\n连续写作与清晰的保存反馈。\n\n## 方案比较\n\n| 能力 | 当前目标 | 优先级 |\n| --- | --- | --- |\n| 连续写作 | 不中断输入 | 高 |\n| 文档导航 | 快速找到内容 | 高 |\n| 个性化 | 合适的排版 | 中 |\n\n- [ ] 待完成\n- [x] 已完成\n"
        let model = MarkdownDocumentHarness(document: MarkdownDocument(text: sample))
        let suite = "UXReview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.workspaceViewMode = .preview
        preferences.workspaceOutlineVisible = true
        let browser = FolderBrowserController(restoresSavedFolder: false)
        func content() -> some View {
            MarkdownEditorView(document: Binding(get: { model.document }, set: { model.document = $0 }),
                fileURL: nil, isEditable: true, preferences: preferences, folderBrowser: browser)
                .frame(width: 1200, height: 760)
        }
        let host = NSHostingView(rootView: content())
        host.rootView = content()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<50 where descendantTextViews(in: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(descendantTextViews(in: host).compactMap { $0 as? WindowAwareTextView }.first)
        let location = (sample as NSString).range(of: "| 能力").location
        for _ in 0..<100 where editor.renderedTable(atUTF16Location: location) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(editor.renderedTable(atUTF16Location: location))
        for mode: WorkspaceViewModePreference in [.split, .source, .preview, .split] {
            preferences.workspaceViewMode = mode
            host.rootView = content()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(descendantTextViews(in: host).contains { $0 === editor })
            XCTAssertEqual(editor.string, sample)
        }
        let preview = try XCTUnwrap(descendantTextViews(in: host).compactMap { $0 as? WindowAwareTextView }
            .first { !$0.isEditable })
        XCTAssertEqual(preview.accessibilityLabel(), "Markdown 只读预览")
        XCTAssertNotNil(preview.renderedTable(atUTF16Location: location))
        if let directory = ProcessInfo.processInfo.environment["INFLOW_UX_SCREENSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("verified-split.png"))
        }
        editor.setSelectedRange(NSRange(location: sample.utf16.count, length: 0))
        editor.insertText("新增正文", replacementRange: editor.selectedRange())
        for _ in 0..<100 where model.document.text != sample + "新增正文" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.document.text, sample + "新增正文")
        XCTAssertEqual(try model.document.encodedFileData(), Data((sample + "新增正文").utf8))
    }

    func testEngineABILayoutMatchesRustContractOnArm64() {
        XCTAssertEqual(MemoryLayout<InflowEngineCreateResult>.size, 32)
        XCTAssertEqual(MemoryLayout<InflowEngineCreateResult>.alignment, 8)
        XCTAssertEqual(MemoryLayout<InflowBytesResult>.size, 24)
    }

    func testNewDocumentUsesUTF8WithoutBOMAndLF() throws {
        let document = MarkdownDocument(text: "# 你好\n\nHello 🌍\n")

        XCTAssertEqual(
            try document.encodedFileData(),
            Data("# 你好\n\nHello 🌍\n".utf8)
        )
    }

    func testExistingDocumentPreservesBOMAndCRLF() throws {
        let source = Data([0xEF, 0xBB, 0xBF])
            + Data("# Title\r\n\r\nBody\r\n".utf8)
        var document = try MarkdownDocument(fileData: source)

        XCTAssertEqual(document.text, "# Title\n\nBody\n")
        XCTAssertTrue(document.properties.hasUTF8BOM)
        XCTAssertEqual(document.properties.lineEnding, .crlf)

        document.text += "新内容\n"
        XCTAssertEqual(
            try document.encodedFileData(),
            source + Data("新内容\r\n".utf8)
        )
    }

    func testInvalidUTF8IsRejectedWithoutReplacementCharacters() {
        XCTAssertThrowsError(try MarkdownDocument(fileData: Data([0xFF, 0xFE]))) { error in
            XCTAssertEqual(error as? MarkdownCodecError, .invalidUTF8)
        }
    }

    func testPersonalMilestoneDoesNotInventFixedDocumentSizeTiers() throws {
        for byteCount in [0, 1_024 * 1_024, 11 * 1_024 * 1_024] {
            XCTAssertEqual(
                try MarkdownDocumentSizePolicy.validatedTierForOpening(byteCount: byteCount),
                .full
            )
        }
    }

    func testLargerInvalidUTF8StillUsesTheEncodingFailure() {
        let invalid = Data(repeating: 0xFF, count: 2 * 1_024 * 1_024)
        XCTAssertThrowsError(try MarkdownDocument(fileData: invalid)) { error in
            XCTAssertEqual(error as? MarkdownCodecError, .invalidUTF8)
        }
    }

    func testLargerDocumentOpensCompleteTextWithoutAHiddenNumericTier() throws {
        let source = Data(repeating: 0x61, count: 2 * 1_024 * 1_024)
        var document = try MarkdownDocument(fileData: source)

        XCTAssertEqual(document.capabilityTier, .full)
        XCTAssertEqual(document.text.utf8.count, source.count)
        document.text = "small again"
        XCTAssertEqual(document.capabilityTier, .full)
    }

    func testMixedLineEndingsOpenReadOnlyUntilUserChoosesCRLF() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let source = bom + Data("one\r\ntwo\n".utf8)
        var document = try MarkdownDocument(fileData: source)

        XCTAssertEqual(document.text, "one\ntwo\n")
        XCTAssertTrue(document.properties.hasUTF8BOM)
        XCTAssertTrue(document.properties.requiresLineEndingChoice)
        XCTAssertThrowsError(try document.encodedFileData()) { error in
            XCTAssertEqual(error as? MarkdownCodecError, .mixedLineEndings)
        }

        document.chooseLineEnding(.crlf)
        XCTAssertFalse(document.properties.requiresLineEndingChoice)
        XCTAssertEqual(try document.encodedFileData(), bom + Data("one\r\ntwo\r\n".utf8))
    }

    func testMixedAndBareCRCanBeExplicitlyUnifiedToLFWithoutLosingText() throws {
        var document = try MarkdownDocument(fileData: Data("one\r\ntwo\nthree\rfour".utf8))

        XCTAssertEqual(document.text, "one\ntwo\nthree\nfour")
        XCTAssertTrue(document.properties.requiresLineEndingChoice)

        document.chooseLineEnding(.lf)
        XCTAssertEqual(try document.encodedFileData(), Data("one\ntwo\nthree\nfour".utf8))
    }

    func testMixedLineEndingPromptUsesFrozenSafeExitCopy() {
        XCTAssertEqual(MixedLineEndingPrompt.title, "选择这份文档的换行方式")
        XCTAssertEqual(
            MixedLineEndingPrompt.message,
            "检测到 LF 和 CRLF 混合。作出选择前，文档保持只读且不会自动保存。"
        )
        XCTAssertEqual(MixedLineEndingPrompt.useLFTitle, "使用 LF")
        XCTAssertEqual(MixedLineEndingPrompt.useCRLFTitle, "使用 CRLF")
        XCTAssertEqual(MixedLineEndingPrompt.closeTitle, "关闭文档")
    }

    @MainActor
    func testMixedLineEndingSafeExitClosesWithoutChoosingAFormat() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)

        MixedLineEndingPrompt.closeDocumentWindow(window)

        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testMixedLineEndingGateKeepsMountedSourceEditorReadOnlyUntilChoice() throws {
        let model = MarkdownDocumentHarness(
            document: try MarkdownDocument(fileData: Data("one\r\ntwo\n".utf8))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MarkdownDocumentEditorHarness(model: model)
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))

        let sourceEditor = try XCTUnwrap(
            descendantTextViews(in: try XCTUnwrap(window.contentView))
                .first { $0.string == "one\ntwo\n" }
        )
        XCTAssertFalse(sourceEditor.isEditable)

        model.document.chooseLineEnding(.lf)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        XCTAssertTrue(sourceEditor.isEditable)
    }

    @MainActor
    func testFreshUntitledDocumentMountsAndFocusesTheEditableSourceEditor() throws {
        let model = MarkdownDocumentHarness(document: MarkdownDocument())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MarkdownDocumentEditorHarness(model: model)
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0 ..< 20 where !(window.firstResponder is WindowAwareTextView) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let contentView = try XCTUnwrap(window.contentView)
        let sourceEditor = try XCTUnwrap(
            descendantTextViews(in: contentView)
                .compactMap { $0 as? WindowAwareTextView }
                .first
        )
        XCTAssertTrue(sourceEditor.isEditable)
        XCTAssertTrue(window.firstResponder === sourceEditor)
        let sourceScrollView = try XCTUnwrap(sourceEditor.enclosingScrollView)
        let sourceFrame = sourceScrollView.convert(sourceScrollView.bounds, to: contentView)
        XCTAssertLessThanOrEqual(
            sourceFrame.minY,
            EditorWorkspaceMetrics.statusBarHeight + 4,
            "The source editor should extend down to the status bar instead of leaving blank space."
        )
        XCTAssertGreaterThan(
            sourceFrame.height,
            contentView.bounds.height * 0.8,
            "The source editor should consume the available document height."
        )
        let visibleReadOnlyEditors = descendantTextViews(in: contentView).filter { textView in
            !textView.isEditable
                && !hasHiddenAncestor(textView)
                && !textView.convert(textView.bounds, to: contentView)
                    .intersection(contentView.bounds).isEmpty
        }
        XCTAssertTrue(
            visibleReadOnlyEditors.isEmpty,
            "A fresh untitled document must start in the source editor, not split preview"
        )

        sourceEditor.insertText("# 立即开始\n", replacementRange: sourceEditor.selectedRange())
        for _ in 0..<20 where model.document.text != "# 立即开始\n" {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertEqual(model.document.text, "# 立即开始\n")
        XCTAssertEqual(
            try model.document.encodedFileData(),
            Data("# 立即开始\n".utf8)
        )
    }

    func testMarkdownTypeCoversBothSupportedExtensions() {
        XCTAssertTrue(UTType.inflowMarkdown.conforms(to: .plainText))
        XCTAssertEqual(UTType(filenameExtension: "md"), .inflowMarkdown)
        XCTAssertEqual(UTType(filenameExtension: "markdown"), .inflowMarkdown)
    }
}

@MainActor
private final class MarkdownDocumentHarness: ObservableObject {
    @Published var document: MarkdownDocument

    init(document: MarkdownDocument) {
        self.document = document
    }
}

private struct MarkdownDocumentEditorHarness: View {
    @ObservedObject var model: MarkdownDocumentHarness
    @StateObject private var preferences: AppPreferences
    @StateObject private var folderBrowser = FolderBrowserController(
        restoresSavedFolder: false
    )

    init(model: MarkdownDocumentHarness) {
        self.model = model
        let suiteName = "MarkdownDocumentEditorHarness.preferences"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        _preferences = StateObject(
            wrappedValue: AppPreferences(defaults: defaults)
        )
    }

    var body: some View {
        MarkdownEditorView(
            document: $model.document,
            fileURL: nil,
            isEditable: true,
            preferences: preferences,
            folderBrowser: folderBrowser
        )
    }
}

@MainActor
private func descendantTextViews(in view: NSView) -> [NSTextView] {
    var result: [NSTextView] = []
    if let textView = view as? NSTextView {
        result.append(textView)
    }
    for subview in view.subviews {
        result.append(contentsOf: descendantTextViews(in: subview))
    }
    return result
}

@MainActor
private func hasHiddenAncestor(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return true }
        current = candidate.superview
    }
    return false
}
