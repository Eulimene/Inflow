import SwiftUI

enum EditorViewMode: String, CaseIterable, Identifiable {
    case source
    case split
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .source: "源码编辑"
        case .split: "实时预览"
        case .preview: "纯预览"
        }
    }

    var systemImage: String {
        switch self {
        case .source: "text.alignleft"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}

struct MarkdownEditorView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @SceneStorage("editorViewMode") private var storedViewMode = EditorViewMode.split.rawValue
    @State private var previewHTML = MarkdownRenderer.htmlDocument(for: "")
    @State private var renderGeneration = 0
    @State private var renderTask: Task<Void, Never>?

    private var viewMode: EditorViewMode {
        get { EditorViewMode(rawValue: storedViewMode) ?? .split }
        nonmutating set { storedViewMode = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            content

            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem {
                Picker(
                    "写作视图",
                    selection: Binding(
                        get: { viewMode },
                        set: { viewMode = $0 }
                    )
                ) {
                    ForEach(EditorViewMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                .accessibilityLabel("写作视图")
            }
        }
        .onAppear {
            scheduleRender(for: document.text, delayNanoseconds: 0)
        }
        .onChange(of: document.text) { _, markdown in
            scheduleRender(for: markdown, delayNanoseconds: 120_000_000)
        }
        .onDisappear {
            renderTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .source:
            sourceEditor
        case .split:
            HSplitView {
                sourceEditor
                    .frame(minWidth: 320)
                preview
                    .frame(minWidth: 320)
            }
        case .preview:
            preview
        }
    }

    private var sourceEditor: some View {
        TextEditor(text: $document.text)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .accessibilityLabel("Markdown 源码编辑器")
    }

    private var preview: some View {
        MarkdownPreviewView(
            html: previewHTML,
            baseURL: fileURL?.deletingLastPathComponent()
        )
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(
                fileURL?.lastPathComponent ?? "未命名文档",
                systemImage: fileURL == nil ? "doc.badge.plus" : "doc.text"
            )

            Text(viewMode.label)

            Spacer()

            Text("UTF-8\(document.properties.hasUTF8BOM ? " BOM" : "")")
            Text(document.properties.lineEnding.displayName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }

    private func scheduleRender(for markdown: String, delayNanoseconds: UInt64) {
        renderTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration

        renderTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let html = await Task.detached(priority: .userInitiated) {
                MarkdownRenderer.htmlDocument(for: markdown)
            }.value

            guard !Task.isCancelled, generation == renderGeneration else { return }
            previewHTML = html
        }
    }
}
