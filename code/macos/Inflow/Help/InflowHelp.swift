import AppKit
import SwiftUI

enum InflowReleaseProfile {
    static let infoKey = "InflowReleaseProfile"

    static var statusName: String {
        statusName(rawValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    static func statusName(rawValue: String?) -> String {
        rawValue == "signed-preview" ? "免费签名开发预览" : "开发预览"
    }
}

enum ManualUpdateCheck {
    static let infoKey = "InflowManualUpdateURL"

    static func validatedURL(from rawValue: String?) -> URL? {
        guard let rawValue,
              let components = URLComponents(string: rawValue),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.query == nil,
              components.port == nil,
              let url = components.url
        else {
            return nil
        }
        return url
    }

    @MainActor
    static func perform(
        bundle: Bundle = .main,
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let rawValue = bundle.object(forInfoDictionaryKey: infoKey) as? String
        guard let url = validatedURL(from: rawValue), open(url) else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "暂时无法检查更新"
            alert.informativeText =
                "当前开发预览未配置可验证的官方更新页。"
                    + "请继续使用当前版本；写作、保存、恢复和交付不受影响。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
    }
}

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
                "Inflow 启动后直接打开一份可编辑的未命名 Markdown，不弹出文件面板。立即输入内容，第一次按 ⌘S 时再选择文件名和保存位置。其他文件操作集中在 macOS 顶部“文件”菜单：用 ⌘N 新建 Markdown，用 ⌘O 打开一份或多份 Markdown。",
                "使用“打开项目…”可直接打开一个普通文件夹；左侧项目树不会复制、导入或重组原文件。项目树的按钮或右键菜单可在明确目录中新建 Markdown。",
                "使用 ⌘1、⌘2 和 ⌘3 在源码编辑、实时预览和即时编辑（边写边渲染）之间切换。三种视图始终使用同一份 Markdown 和撤销历史。",
            ]
        ),
        InflowHelpSection(
            id: "save",
            title: "保存与文件安全",
            paragraphs: [
                "Inflow 只在你按 ⌘S 或选择“保存”时写入正文，不自动保存。“另存为”会让当前窗口继续编辑新位置。",
                "检测到磁盘文件被其他应用修改时，可重新载入或暂不处理。如果当前编辑也有未保存修改，手动保存前会再次要求明确确认覆盖。",
            ]
        ),
        InflowHelpSection(
            id: "structure",
            title: "结构、查找与本地资源",
            paragraphs: [
                "大纲由当前文档的 H1–H6 生成。点击大纲或预览中的标题可返回精确源位置。使用 ⌘F 查找，⌥⌘F 查找与替换。",
                "插入、粘贴或拖入的静态 PNG/JPEG 会先经过内容校验，再复制到文档同级 assets 并插入相对引用。重名时自动使用递增后缀，不覆盖原图。未命名文档会先完成首次保存。",
            ]
        ),
        InflowHelpSection(
            id: "deliver",
            title: "离线预览与交付",
            paragraphs: [
                "预览禁止页面脚本和自动网络请求。本地静态图片会在校验后内联；缺失或不可用图片可在原位选择替代文件、定位引用或忽略，远程图片可定位、复制地址或关闭说明。",
                "使用“文件 > 导出 PDF…”交付发起时的当前内容快照。PDF 固定使用浅色 A4 版式；缺失图片可在确认后以可见占位继续，只保留可点击的 http/https 链接。",
            ]
        ),
        InflowHelpSection(
            id: "recover",
            title: "恢复与隐私",
            paragraphs: [
                "异常中断后，Inflow 对每份文档最多保留一份应用私有恢复快照；可选择恢复为未命名文档或放弃，不会自动覆盖原文件。",
                "Inflow 不收集或上传使用数据。应用只在本机保留当前与上一会话的最小故障日志；只有你主动选择“帮助 > 导出日志…”时才会保存到指定位置，且应用不会上传。",
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
    let failureLog: LocalFailureLogController

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Inflow 帮助") {
                openWindow(id: InflowHelpWindow.identifier)
            }
            Divider()
            Button("导出日志…") {
                failureLog.presentExport()
            }
        }
    }
}

struct InflowReleaseProfileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 Inflow（\(InflowReleaseProfile.statusName)）") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                ManualUpdateCheck.perform()
            }
        }
    }
}

struct InflowSupplementalCommands: Commands {
    let failureLog: LocalFailureLogController

    var body: some Commands {
        InflowHelpCommands(failureLog: failureLog)
    }
}
