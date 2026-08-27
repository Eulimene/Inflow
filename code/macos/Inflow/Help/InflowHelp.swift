import SwiftUI

struct InflowHelpSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let paragraphs: [String]
}

enum InflowHelpContent {
    static let sections: [InflowHelpSection] = [
        InflowHelpSection(
            id: "start",
            title: "开始写作",
            paragraphs: [
                "使用 ⌘N 新建空白 Markdown，或使用 ⌘O 直接打开 .md 和 .markdown 文件。Inflow 不会导入成专有格式。",
                "使用 ⌘1、⌘2 和 ⌘3 在源码编辑、实时预览和纯预览之间切换。三种视图始终使用同一份当前正文。",
            ]
        ),
        InflowHelpSection(
            id: "save",
            title: "保存与文件安全",
            paragraphs: [
                "已命名且可写的文件会按 macOS 文档规则自动保存；也可随时使用 ⌘S。“另存为”会让当前窗口继续编辑新位置，“保存副本”不改变当前文档位置。",
                "如果磁盘文件被其他应用修改、删除或变为只读，Inflow 会在写入前停止，并提供比较、重新载入、保留当前修改或另存的安全选择。",
            ]
        ),
        InflowHelpSection(
            id: "structure",
            title: "结构、查找与本地资源",
            paragraphs: [
                "大纲由当前文档的 H1–H6 生成。点击大纲或预览中的标题可返回精确源位置。使用 ⌘F 查找，⌥⌘F 查找与替换。",
                "插入、粘贴或拖入的本地图片会先经过类型和内容校验。默认复制到文档同级 assets，也可每次选择文档内相对目录；未命名文档会先完成首次保存，取消时不创建资源。保留既有图片原位置前，Inflow 会先说明可移植性影响。",
            ]
        ),
        InflowHelpSection(
            id: "deliver",
            title: "离线预览与交付",
            paragraphs: [
                "预览禁止页面脚本和自动网络请求。本地静态图片会在校验后内联；缺失、远程或不可用资源会显示原位说明。",
                "使用“文件 > 导出 HTML…”或“导出 PDF…”交付发起时的精确内容快照。缺失资源、异常链接或目标在确认后发生变化时，交付会停止，不会写出不完整或覆盖他人内容的文件。",
            ]
        ),
        InflowHelpSection(
            id: "recover",
            title: "恢复与隐私",
            paragraphs: [
                "异常中断后，可在“文件 > 恢复中心…”查看未处理的本地恢复副本，比较它与磁盘文件的关系，再选择恢复、另存或放弃。",
                "Inflow 的首发写作、预览、恢复和交付均可完全离线使用，不需要账号。匿名产品使用数据默认关闭，只能在查看完整说明后主动开启。",
            ]
        ),
    ]
}

enum InflowHelpWindow {
    static let identifier = "inflow-help"
}

struct InflowHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inflow 帮助")
                        .font(.largeTitle.bold())
                    Text("不需要网络或账号的本地 Markdown 写作指南")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                ForEach(InflowHelpContent.sections) { section in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(section.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
        }
        .frame(minWidth: 520, minHeight: 440)
        .navigationTitle("Inflow 帮助")
    }
}

struct InflowHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Inflow 帮助") {
                openWindow(id: InflowHelpWindow.identifier)
            }
        }
    }
}

struct InflowSupplementalCommands: Commands {
    var body: some Commands {
        RecoveryCommands()
        InflowHelpCommands()
    }
}
