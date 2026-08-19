import SwiftUI

struct MarkdownEditorView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $document.text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .accessibilityLabel("Markdown 源码编辑器")

            Divider()

            HStack(spacing: 12) {
                Label(
                    fileURL?.lastPathComponent ?? "未命名文档",
                    systemImage: fileURL == nil ? "doc.badge.plus" : "doc.text"
                )

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
        .background(Color(nsColor: .textBackgroundColor))
    }
}
