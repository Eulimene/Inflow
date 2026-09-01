# Inflow 当前实现基线

> 对齐日期：2026-09-01
>
> 适用里程碑：个人首版（内部验证版）
>
> 状态：工作树实现盘点；UAT-PERSONAL-01 至 10 均未在本文记录为已执行或通过。

本文区分三件事：

1. 仓库中存在代码或测试入口；
2. 当前个人首版界面确实把能力暴露给产品负责人；
3. 产品负责人已用真实项目完成人工 UAT。

前两项不能替代第三项。本文中的“已接入”只描述代码结构，不表示人工验收通过、候选有效或产品可公开分发。

## 1. 当前里程碑结论

当前工作树面向一位内部用户完成本地 Markdown 写作闭环：

- 普通启动、Finder、应用内命令或拖到应用图标后进入独立文档或普通文件夹项目；
- 在项目树中新建和切换 Markdown；
- 在源码、分栏和即时渲染编辑之间使用同一份正文；
- 只由用户手动保存，并处理简单外部变化和单快照恢复；
- 加入本地 PNG/JPEG、打开受限本地链接并导出基础浅色 PDF；
- 在本机记录最小故障信息，由用户主动导出。

它不是 0.1 公共预览。当前不需要也不声称具备公开版本号、安装包、签名、公证、更新、回退、商业或公开支持。

## 2. 当前主流程接线

### 2.1 入口、文档与轻量项目

- InflowApp 使用原生文档生命周期创建未命名 Markdown。在允许编辑前，ManualSaveDocumentHostPolicy 将当前 DocumentGroup 宿主的就地自动保存、草稿自动保存和版本保留策略统一关闭，并将定时保存延迟设为 0；若宿主策略无法覆盖或复核，文档保持只读并记录本地错误，而不承受未确认写入。
- RecentDocumentsController 当前用于统一应用内与外部目标的规范化、去重、空白窗口复用和多文件打开；recordsOpenedDocuments 为 false，因此不把它描述成 Inflow 管理的最近文档能力。
- “打开项目…”把普通文件夹交给 LightweightProjectCoordinator 与 FolderBrowserController。项目不导入、不复制，也不创建私有项目文件。
- FolderBrowser 负责递归目录树、隐藏项过滤、手动刷新、项目边界和安全新建 Markdown。新建使用不覆盖语义，并在执行前重新核对目标目录与符号链接边界。
- 打开项目时先在不改动当前界面的情况下完成首轮目录扫描，并绑定目录 dev/inode 身份；只有扫描、旧文档关闭确认和提交点复核全部成功后，才附着新项目宿主并关闭旧文档。异步打开的隐藏目标在事务期间会被预留，超时迟到的回调不会关闭其他流程已采用的文档。
- 项目上下文附着在一个原生文档窗口上；选择另一份 Markdown 前复用系统的未保存内容确认。取消切换时，只清理仍未修改且不可见的未提交目标；已被其他窗口显示或修改的文档保留为独立窗口。项目外另存成功后，当前窗口退出项目上下文。

上述代码入口仍必须由 UAT-PERSONAL-01、08 和 09 在真实 Finder、Dock、沙箱与文件系统上验证。

### 2.2 单一正文与三种视图

- MarkdownDocument.text 是 SwiftUI 文档模型中的正文事实；MarkdownSourceEditorSession 持有一个持久 NSTextView。
- 源码编辑和实时预览分栏使用同一个 MarkdownSourceEditor；即时渲染编辑也把同一 session 以 rendered presentation 重新挂载，不创建第二个可编辑模型。
- 文本修改由 NSTextView 发布回同一个绑定，撤销与重做继续使用同一个 UndoManager。展示属性更新不登记正文 undo。
- EditorViewMode 的历史内部 case 名 preview 现在对应用户可见的“即时渲染编辑”，不代表个人首版存在独立持久纯预览。
- 视图切换复用同一选区与源范围导航入口；产品只承诺回到同一语义块，不承诺逐像素或逐字符位置一致。

### 2.3 即时渲染编辑

- RenderedMarkdownEditor 为同一源字符串同步生成只读展示计划；计划包含 Markdown 标记范围、内容样式、局部源码块以及链接文字与目标范围。
- 计划不插入、删除、替换或规范化任何源字符。UTF-8 源范围会严格映射到 TextKit 使用的 UTF-16 范围。
- 段落、H1–H6、粗体、斜体、删除线、引用、无序/有序/任务列表、行内代码和普通链接文字可直接呈现。
- 表格、围栏代码、Mermaid、图片、原始 HTML、复杂嵌套、带标题或其他歧义链接以及无法可靠解析的结构保留为非重叠局部源码块。
- 解析失败采用保守局部源码，不猜测性改写原文。
- NSTextView 存在 marked text 时，请求保持现有展示；组合完成后再重建计划。
- 普通鼠标点击继续用于编辑。只有 Command+点击命中当前、未过期的可见链接文字范围时，才把目标交给既有链接激活路径。

对应组件入口在 RenderedMarkdownEditorTests；这些测试不能代替 UAT-PERSONAL-10 的中文输入法、富文本粘贴、跨视图撤销与真实链接操作。

### 2.4 查找、格式和 Markdown 呈现

- 当前文档查找、上一个/下一个、替换和全部替换仍走同一正文与一次撤销计划。
- 当前格式菜单只安装粗体、斜体、行内代码、H1–H6、引用和无序/有序/任务列表。
- 插入菜单只安装链接、图片和固定表格模板。删除线、围栏代码与图片内容仍可在源码中编辑并在预览中核对。
- 当前产品合同只覆盖 CommonMark/GFM 基础、flowchart 和 stateDiagram-v2。
- 原始 HTML 被转义或保留为可读源码，不执行其中的脚本、样式、事件、表单、嵌入、导航或网络动作。
- 仓库仍保留公式、脚注等后续内部路径，历史材料也可能提到额外 Mermaid 类型；这些都不属于个人首版当前能力或 UAT 通过项。当前 Mermaid 渲染器只接受 flowchart 与 stateDiagram-v2。

### 2.5 图片与链接

- 当前图片入口接受文件选择、编辑区拖入与剪贴板中的静态 PNG/JPEG；未命名文档先完成首次保存。
- 新图片复制到 Markdown 同目录的 assets，冲突名称使用递增后缀，不覆盖既有文件。
- 图片文本编辑与资源创建不是可逆的同一文件事务：撤销只移除 Markdown 引用，已经写入 assets 的图片保留。
- 项目内既有相对图片以当前 Markdown 目录为基准解析，并在规范化和符号链接解析后限制在项目根内。
- 项目内 Markdown 链接用于打开原文件；同一路径已有编辑窗口时只聚焦既有窗口。
- 项目内 PNG/JPEG/PDF 通过应用管理的文件系统只读临时副本交给外部应用。http/https 只由用户明确激活后打开；file、脚本和自定义 scheme 被阻止。

这些路径的真实文件权限、外部应用行为、临时副本不可写和周期清理由 UAT-PERSONAL-05 与 09 判定。

### 2.6 手动保存、外部变化与轻量恢复

- AppPreferences.applyAutosavePolicy 和应用委托都把 NSDocumentController.autosavingDelay 设为 0；ManualSaveDocumentHostPolicy 还在启用编辑前关闭具体文档宿主的 autosavesInPlace、autosavesDrafts 与 preservesVersions，并动态复核三个结果。
- 关闭已修改文档、项目内切换文档和退出应用继续由 AppKit 的原生 Save / Don't Save / Cancel 审查处理；只有选择 Save 才会写回。
- 当前主 App 未安装自动保存开关。宿主策略兼容层只服务个人内部版；未经真实进程 UAT 不得推导为公开发布架构证据。
- 已命名文档的保存动作经原生文档 API 完成。失败保留当前编辑，不显示成功。当前文件菜单只暴露保存与另存为；保存副本的底层路径仅作为后续延期实现保留，不属于个人首版界面能力。
- 外部变化提示当前只承诺重新加载或暂不处理；本地也有未保存修改时，后续手动保存要求明确覆盖确认。
- 当前里程碑不承诺三版本比较、自动合并、无竞态 compare-and-replace 或删除文件原位重建。
- DocumentRecovery 后端仍包含较完整的存储与迁移实现，但当前 UI 只使用 LightweightRecoveryPromptView：每份文档最多呈现一个最新快照，操作只有恢复为未命名文档或放弃。
- 当前不把 RecoveryCenterView 中保留的比较、批量和历史管理代码描述成个人首版能力。

真实外部编辑器参与的覆盖流程和真实强制退出仍分别由 UAT-PERSONAL-02 与 03 判定。

### 2.7 基础浅色 PDF 与本地日志

- 文件菜单只安装一个“导出 PDF…”命令；空白正文时入口禁用。
- PDF 请求强制使用 personalPDF 浅色外观，并从用户发起时的当前正文准备单篇交付物。
- 当前验收只要求基础文字结构、PNG/JPEG、flowchart、stateDiagram-v2、缺图占位、安全链接动作、简单覆盖确认及失败不误报。
- HTMLExporter 和相关 Rust HTML 生成代码仍作为历史实现或 PDF 内部准备层存在，但当前没有用户可达的 HTML 导出菜单，不能写成个人首版交付能力。
- LocalFailureLogController 只允许记录时间、应用版本、操作类别与错误代码；当前与上一会话可由用户主动选择位置导出，应用不提供自动上传路径。

真实 PDF 阅读器检查、缺图继续、覆盖确认、失败路径和日志内容检查仍由 UAT-PERSONAL-06 与 07 判定。

## 3. 保留但不构成当前能力的代码

仓库仍有为旧基线或后续阶段准备的实现。以下存在性不能转换成 current claim：

- ManualUpdateCheck、InflowReleaseProfileCommands 与发布/公证/封签脚本；
- HTML 导出 API、面板、写入器及相关历史测试；
- 自动保存偏好 key、旧延迟枚举和完整设置页代码；
- Inflow 管理的最近文档记录、完整恢复中心、多快照、复杂冲突与比较界面；
- 公式、脚注、额外 Mermaid 图类、删除线/围栏代码等未安装菜单动作；
- 深色 PDF、专业后验、固定性能门槛、30 次协议和发布证据链；
- 扩展、插件、人工智能、连接器与市场设计。

判断当前能力时，以已批准的个人首版范围、实际安装的菜单和主流程、以及 UAT-PERSONAL-01 至 10 为准，而不是以某个源文件或测试名称是否存在为准。

自动化同样按这个边界分区。`quality/personal-xctest-scope.tsv` 当前完整列出 361 个 XCTest method：255 个 `current-direct`、13 个依赖真实 `NSApplication` 菜单或生命周期的 `current-host`、88 个后置 selector，以及 5 个固定性能 selector。`scripts/verify-launch.sh --personal` 只执行 `current-direct`，不会把另外三类记作通过；deferred profile 仍保留 macOS 全量测试。清单对重复、陈旧、未分类、非法分区及四类精确计数失败关闭，因此新增后置测试不能静默成为个人首版完成条件。

## 4. 人工 UAT 状态

| UAT | 主题 | 当前人工状态 |
| --- | --- | --- |
| UAT-PERSONAL-01 | 入口、新建、首次保存、编辑与关闭 | 未执行 |
| UAT-PERSONAL-02 | 简单外部变化提示 | 未执行 |
| UAT-PERSONAL-03 | 轻量单快照恢复 | 未执行 |
| UAT-PERSONAL-04 | 源码、分栏、查找格式与两类 Mermaid | 未执行 |
| UAT-PERSONAL-05 | 图片与本地链接 | 未执行 |
| UAT-PERSONAL-06 | 基础浅色 PDF | 未执行 |
| UAT-PERSONAL-07 | 本地最小日志与无自动遥测 | 未执行 |
| UAT-PERSONAL-08 | 一个真实项目端到端与基础烟测 | 未执行 |
| UAT-PERSONAL-09 | 项目目录树、新建与相对资源 | 未执行 |
| UAT-PERSONAL-10 | 即时渲染编辑基础范围 | 未执行 |

没有产品负责人签署的实际记录前，不得把任一项改为“通过”，也不得使用“候选已闭环”“个人首版完成”或“发布就绪”等表述。

## 5. 证据入口

- 产品范围：[个人首版范围](../../文档/01-产品设计/06-版本规划/02-首发版本范围.md)
- 人工步骤与结果：[产品验收标准](../../文档/01-产品设计/06-版本规划/03-产品验收标准.md)
- 技术责任边界：[architecture.md](architecture.md)
- 当前 UAT 对照：[launch-acceptance.md](launch-acceptance.md)
- 已废止旧记录：[launch-candidate-0.1.0-build-1.md](launch-candidate-0.1.0-build-1.md)
- 即时渲染核心：[../macos/Inflow/Editor/RenderedMarkdownEditor.swift](../macos/Inflow/Editor/RenderedMarkdownEditor.swift)
- 三视图接线：[../macos/Inflow/Editor/MarkdownEditorView.swift](../macos/Inflow/Editor/MarkdownEditorView.swift)
- 同一 NSTextView 宿主：[../macos/Inflow/Editor/MarkdownSourceEditor.swift](../macos/Inflow/Editor/MarkdownSourceEditor.swift)
