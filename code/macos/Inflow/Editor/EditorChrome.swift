import AppKit
import SwiftUI

struct SourceOnlyDocumentBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("已切换为源码优先").font(.headline)
                Text(
                    "文件大于 1 MiB。完整源码、查找、保存、恢复和冲突保护仍可用；"
                        + "实时/纯预览、大纲、完整语法高亮、诊断、统计和结构格式已暂停。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyMarkdownPreviewView: View {
    let onStartWriting: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(EmptyMarkdownGuidance.title, systemImage: "doc.text")
        } description: {
            Text(EmptyMarkdownGuidance.description)
        } actions: {
            Button("在源码编辑器中开始", action: onStartWriting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
    }
}

/// Keeps the scene's native document identity available while SwiftUI resolves
/// an ordinary document window or the project shell shows empty guidance.
@MainActor
final class MarkdownEditorNativeDocumentHost: ObservableObject {
    weak private(set) var document: NSDocument?

    func attach(_ document: NSDocument) {
        guard self.document !== document else { return }
        objectWillChange.send()
        self.document = document
    }
}

struct MarkdownEditorNativeDocumentResolver: NSViewRepresentable {
    let onResolve: @MainActor (NSDocument) -> Void

    func makeNSView(context _: Context) -> ResolverView {
        ResolverView(onResolve: onResolve)
    }

    func updateNSView(_ view: ResolverView, context _: Context) {
        view.onResolve = onResolve
        view.resolveIfPossible()
    }

    final class ResolverView: NSView {
        var onResolve: @MainActor (NSDocument) -> Void
        private weak var candidateWindow: NSWindow?
        private weak var resolvedDocument: NSDocument?
        private var resolutionTask: Task<Void, Never>?

        init(onResolve: @escaping @MainActor (NSDocument) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit { resolutionTask?.cancel() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                resolutionTask?.cancel()
                resolutionTask = nil
                candidateWindow = nil
                return
            }
            resolveIfPossible()
        }

        @MainActor
        func resolveIfPossible() {
            guard let window else { return }
            if let document = window.windowController?.document as? NSDocument {
                resolutionTask?.cancel()
                resolutionTask = nil
                candidateWindow = window
                if resolvedDocument !== document {
                    resolvedDocument = document
                    onResolve(document)
                }
                return
            }
            guard resolutionTask == nil else { return }
            candidateWindow = window
            resolutionTask = Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                for attempt in 0 ..< 50 {
                    await Task.yield()
                    guard !Task.isCancelled,
                          self.window === window,
                          self.candidateWindow === window
                    else { return }
                    if let document = window.windowController?.document as? NSDocument {
                        self.resolvedDocument = document
                        self.resolutionTask = nil
                        self.onResolve(document)
                        return
                    }
                    if attempt < 49 { try? await Task.sleep(for: .milliseconds(20)) }
                }
                self.resolutionTask = nil
            }
        }
    }
}

/// Keep document zoom on the current desktop. Native full-screen creates a
/// separate Space whose system-provided minimize button is unavailable.
struct DocumentWindowControls: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context _: Context) {
        view.configureWindow()
    }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            // AppKit setters can invalidate native window commands even when the
            // assigned value is unchanged. SwiftUI can refresh this view while
            // the Window menu is open, so only write actual policy changes.
            if !window.styleMask.contains(.miniaturizable) {
                window.styleMask.insert(.miniaturizable)
            }
            var behavior = window.collectionBehavior
            behavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
            behavior.insert(.fullScreenNone)
            if window.collectionBehavior != behavior {
                window.collectionBehavior = behavior
            }
        }
    }
}
