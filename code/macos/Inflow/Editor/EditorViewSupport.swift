import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum EditorWorkspacePane: Equatable {
    case projectSidebar
    case editor
    case outline
}

enum EditorWorkspaceLayout {
    static func panes(
        hasProjectContext: Bool,
        projectSidebarVisible: Bool,
        outlineAvailable: Bool,
        outlineVisible: Bool
    ) -> [EditorWorkspacePane] {
        var result: [EditorWorkspacePane] = []
        if hasProjectContext && projectSidebarVisible { result.append(.projectSidebar) }
        result.append(.editor)
        if outlineAvailable && outlineVisible { result.append(.outline) }
        return result
    }
}

enum EditorWorkspaceMetrics {
    static let minimumWindowWidth: CGFloat = 820
    static let minimumWindowHeight: CGFloat = 520
    static let defaultWindowWidth: CGFloat = 1_200
    static let defaultWindowHeight: CGFloat = 760
    static let projectSidebarMinimumWidth: CGFloat = 200
    static let projectSidebarIdealWidth: CGFloat = 228
    static let projectSidebarMaximumWidth: CGFloat = 300
    static let editorMinimumWidth: CGFloat = 560
    static let outlineMinimumWidth: CGFloat = 200
    static let outlineIdealWidth: CGFloat = 228
    static let outlineMaximumWidth: CGFloat = 288
    static let navigationHeaderHeight: CGFloat = 40
    static let statusBarHeight: CGFloat = 30
}

struct WorkspacePaneVisibilityButton: View {
    let paneName: String
    let systemImage: String
    let isExpanded: Bool
    let action: () -> Void

    private var label: String { "\(isExpanded ? "折叠" : "展开")\(paneName)" }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .help(label)
        .accessibilityLabel(label)
    }
}

enum EditorViewMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .source: "源码编辑"
        case .split: "实时预览"
        case .preview: "即时编辑"
        }
    }

    var systemImage: String {
        switch self {
        case .source: "text.alignleft"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }

    var sourceVisible: EditorViewMode { self }
    var usesCanonicalPreviewRenderer: Bool { self != .source }
    var renderedSurfaceEngine: MarkdownRenderedSurfaceEngine? {
        self == .source ? nil : .textKit
    }
}

/// The interactive rendered document has one final-layout implementation.
/// Split preview and instant editing differ only in whether that TextKit
/// surface accepts edits; HTML/WebKit remains an export adapter.
enum MarkdownRenderedSurfaceEngine: Equatable {
    case textKit
}

enum EditorViewModeLaunchContext: Equatable {
    case untitled
    case existingDocument
    case recoverySnapshot

    var defaultMode: EditorViewMode {
        switch self {
        case .untitled, .recoverySnapshot: .source
        case .existingDocument: .split
        }
    }

    static func resolve(fileURL: URL?, hasRestorationState: Bool) -> Self {
        if hasRestorationState { return .recoverySnapshot }
        return fileURL == nil ? .untitled : .existingDocument
    }
}

/// One application-wide workspace preference replaces per-document scene
/// storage. `automatic` preserves the original context-sensitive first-launch
/// behavior until the user explicitly selects a writing view.
enum WorkspaceViewModePreference: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case source
    case split
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "自动（按文档类型）"
        case .source: EditorViewMode.source.label
        case .split: EditorViewMode.split.label
        case .preview: EditorViewMode.preview.label
        }
    }

    init(mode: EditorViewMode) {
        switch mode {
        case .source: self = .source
        case .split: self = .split
        case .preview: self = .preview
        }
    }

    func resolve(context: EditorViewModeLaunchContext) -> EditorViewMode {
        switch self {
        case .automatic: context.defaultMode
        case .source: .source
        case .split: .split
        case .preview: .preview
        }
    }
}

enum EditorStatisticMode: String, CaseIterable, Identifiable {
    case words
    case charactersIncludingSpaces
    case charactersExcludingSpaces
    case hidden

    var id: Self { self }

    var label: String {
        switch self {
        case .words: "字数"
        case .charactersIncludingSpaces: "字符数（含空格）"
        case .charactersExcludingSpaces: "字符数（不含空格）"
        case .hidden: "隐藏统计"
        }
    }
}

enum EmptyMarkdownGuidance {
    static let title = "这份 Markdown 属于你"
    static let description =
        "直接在源码编辑器中开始写作，或从 macOS 顶部“文件”菜单打开 Markdown 或文件夹项目。首次保存时由你选择文件名和位置，Inflow 不会把内容导入专有格式。"

    static func isVisible(markdown: String) -> Bool { markdown.isEmpty }
}

enum MixedLineEndingPrompt {
    static let title = "选择这份文档的换行方式"
    static let message = "检测到 LF 和 CRLF 混合。作出选择前，文档保持只读且不会自动保存。"
    static let useLFTitle = "使用 LF"
    static let useCRLFTitle = "使用 CRLF"
    static let closeTitle = "关闭文档"

    @MainActor
    static func closeDocumentWindow(_ window: NSWindow?) {
        window?.performClose(nil)
    }
}

enum DeferredImageInsertion: Equatable {
    case chooseExistingImage
    case paste(ClipboardImagePayload)
    case drop(URL)

    static let savePanelTitle = "先保存这份 Markdown"
    static let savePanelMessage =
        "图片必须保存在你确认的文档相对目录中。保存成功后会继续本次图片操作；取消不会创建资源。"
    static let savePanelActionTitle = "保存并继续"
}

struct DeferredImageInsertionQueue: Equatable {
    private(set) var pending: DeferredImageInsertion?

    var hasPending: Bool { pending != nil }

    mutating func enqueue(_ insertion: DeferredImageInsertion) -> Bool {
        guard pending == nil else { return false }
        pending = insertion
        return true
    }

    mutating func cancel() { pending = nil }

    mutating func consumeAfterSuccessfulSave() -> DeferredImageInsertion? {
        defer { pending = nil }
        return pending
    }
}

enum PreviewIssueNavigation {
    static func validatedOffset(
        _ offset: Int,
        renderedSource: String,
        currentSource: String
    ) -> Int? {
        guard UTF8Text.isExactlyEqual(renderedSource, currentSource),
              MarkdownSourceRange.navigationTarget(
                  forUTF8Range: offset..<offset,
                  in: currentSource
              ) != nil
        else { return nil }
        return offset
    }
}

enum PreviewImageIssueNavigation {
    static func validatedReference(
        sourceUTF8Offset: Int,
        target: String,
        renderedSource: String,
        currentSource: String,
        references: [MarkdownReference]
    ) -> MarkdownReference? {
        guard UTF8Text.isExactlyEqual(renderedSource, currentSource) else { return nil }
        return references.first { reference in
            reference.kind == .image
                && reference.sourceUTF8Range.lowerBound == sourceUTF8Offset
                && UTF8Text.isExactlyEqual(reference.target, target)
        }
    }

    static func validatedReference(
        sourceUTF8Offset: Int,
        target: String,
        renderedSource: String,
        currentSource: String
    ) -> MarkdownReference? {
        guard let references = try? MarkdownReferenceScanner.references(in: currentSource) else {
            return nil
        }
        return validatedReference(
            sourceUTF8Offset: sourceUTF8Offset,
            target: target,
            renderedSource: renderedSource,
            currentSource: currentSource,
            references: references
        )
    }
}
