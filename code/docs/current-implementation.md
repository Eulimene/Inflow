# Inflow 当前实现基线

> 对齐日期：2026-09-12
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

- 无待打开目标时，普通启动或在 Finder 中双击 Inflow App 都不弹文件选择器，直接进入可编辑的未命名文档；带外部目标的 Finder、应用内命令或拖到应用图标请求则沿统一路由进入独立文档或普通文件夹项目；
- 在项目树中新建 Markdown，并在单一稳定项目外壳的应用内标签栏保留和切换已打开文档；
- 在源码、分栏和可直接写作的即时编辑之间使用同一份正文；
- 只由用户手动保存，并处理简单外部变化和单快照恢复；
- 加入本地 PNG/JPEG、打开受限本地链接并导出基础浅色 PDF；
- 在本机记录最小故障信息，由用户主动导出。

它不是 0.1 公共预览。当前不需要也不声称具备公开版本号、安装包、签名、公证、更新、回退、商业或公开支持。

## 2. 当前主流程接线

### 2.1 入口、文档与轻量项目

- InflowApp 使用原生文档生命周期创建未命名 Markdown。在允许编辑前，ManualSaveDocumentHostPolicy 将当前 DocumentGroup 宿主的就地自动保存、草稿自动保存和版本保留策略统一关闭，并将定时保存延迟设为 0；若宿主策略无法覆盖或复核，文档保持只读并记录本地错误，而不承受未确认写入。
- InflowLaunchPolicy 禁止 AppKit 自行弹出打开面板；应用委托在普通启动或 Finder 双击 App 且没有待处理外部目标时，显式创建并聚焦可编辑的未命名文档。带文件或文件夹目标的启动继续交给统一打开路由，不额外留下空白窗口。
- RecentDocumentsController 当前用于统一应用内与外部目标的规范化、去重、空白窗口复用和多文件打开；recordsOpenedDocuments 为 false，因此不把它描述成 Inflow 管理的最近文档能力。
- “打开项目…”把普通文件夹交给 LightweightProjectCoordinator 与 FolderBrowserController。项目不导入、不复制，也不创建私有项目文件。
- FolderBrowser 负责递归目录树、展开状态、一键展开/折叠全部、隐藏项过滤、手动刷新、项目边界和安全新建 Markdown。新建使用不覆盖语义，并在执行前重新核对目标目录与符号链接边界。
- 系统文件夹选择器返回的 URL 直接进入安全作用域与首轮目录扫描，不再先做一遍应用内 `fileExists` 可读性预检。扫描会跳过个别被系统拒绝读取的后代目录，而不是因此拒绝整个已选择项目；根目录身份异常仍会失败。扫描仍在不改动当前界面的情况下绑定目录 dev/inode 身份；只有实际扫描、旧文档关闭确认和提交点复核全部成功后，才附着新项目宿主并关闭旧文档。异步打开的隐藏目标在事务期间会被预留，超时迟到的回调不会关闭其他流程已采用的文档。
- 项目窗口现在采用单一稳定外壳：目录树、目录树分栏、项目工具区、标签栏和工作区容器只创建一次，不再随文件切换替换。每份已打开 Markdown 仍由独立原生文档会话持有正文、修改状态、保存路径与安全身份，但文档自己的窗口会在布局前被隐藏；应用内标签栏只切换右侧文档表面。新目标先由后台文档完成读取和校验，再在保持旧编辑器可见的情况下挂载新表面，挂载完成后才一次性切换；项目外壳窗口的 frame 在后台文档布局前后保持不变。重复选择只切换现有会话，不调用 `showWindows`、不切换 `NSWindow`，也不关闭项目外壳或触发保存。每个顶部标签都有独立叉号按钮，右键菜单提供关闭当前、其他、左侧和右侧文件；批量关闭会逐份完成原生未保存复核，再一次性移除已授权的表面并选中最近的保留项。项目外另存成功后，该文档退出项目上下文。
- 用户选中项目根目录后，项目文档复用该根目录已保留的 security-scoped 访问，不再对每个子文件重复启动授权。原生文档打开产生的 Finder/AppKit last-used `ctime` 更新只在路径、根目录身份、inode、大小、修改时间与描述符重读字节都持续匹配时才可重试，内容或目标替换仍失败关闭。
- MarkdownEditorView 以左侧项目目录树、中间编辑区、右侧当前文档大纲承载项目窗口；首次默认显示目录树、折叠大纲，没有当前文档时大纲不可用。目录树和大纲在各自顶部提供展开/折叠按钮；隐藏时 PersistentEdgeSplitView 保持面板与编辑器实例挂载，只把面板宽度平滑过渡到零，并在标签栏或编辑区顶部显示紧凑恢复按钮。目录树栏头另以一个动态按钮执行一键展开全部或折叠全部；窗口工具栏不再重复提供面板按钮，“显示”菜单入口继续可用。新窗口采用 1,200 × 760 pt、最小 820 × 520 pt，导航栏使用受限宽度，把主要空间留给编辑与预览。AppPreferences v2 以一组应用级工作区偏好统一保存视图模式、两侧显隐、目录树/大纲宽度和实时预览源码占比；菜单、设置页和 PersistentEdgeSplitView 都读写同一值，旧的新窗口默认 key 在升级时迁移。
- 即时编辑对自身无法无损呈现的 Markdown 构造采用局部源码回退；例如成对三横线包裹的文字会完整保留原文，而不会被 CommonMark 拆成分隔线与 Setext 标题。
- 首个 DocumentGroup 宿主验证手动保存类策略后，后台项目文档直接注册为可切换表面，不再显示自己的窗口或整窗“正在准备手动保存”。项目外壳将已打开表面持久挂载在同一工作区，切换时只改变可见性、交互和当前大纲，不销毁再重建编辑器。目录树 View 身份、展开层级、滚动位置与分栏宽度跨文件保持不变；每份表面的源码编辑器会话、UndoManager、视图内部状态也继续存活。切换完成后，可编辑的目标编辑器成为第一响应者。

上述启动与布局入口仍必须由 UAT-PERSONAL-01、04、08 和 09 在真实 Finder、Dock、沙箱、窗口与文件系统上验证；这四项及其他 UAT 当前均未执行。

### 2.2 单一正文与三种视图

- Rust `EditorEngine` 是默认正文、revision 与历史事实源；`MarkdownDocument.text` 是 FileDocument/SwiftUI 使用的已确认投影，`MarkdownSourceEditorSession` 中的持久 NSTextView 是可乐观更新的显示缓存。
- NSTextView 完成一次非组合输入后，以 UTF-8 grapheme 边界的 `ReplaceText(base_revision, range, inserted)` 提交 Engine，并在 Engine 返回逐字节匹配的快照后才发布 Swift 文档投影；可用 `INFLOW_EDITOR_ENGINE_SHADOW=0` 失败关闭到旧路径。当前菜单格式与图片、链接、表格等插入命令均发送 selection 与 operation，由 Engine 生成并执行 revision-bound patch 后回写 NSTextView。默认会话关闭 AppKit 正文 undo registration，Command-Z/Shift-Command-Z 发送 Engine `Undo/Redo`，Rust Memento 历史是撤销事实源。原位保存、另存、覆盖确认与 PDF 导出开始前会提交 marked text、排空 Engine 队列并冻结权威 snapshot，再把该文本写入 FileDocument 投影。
- IME 第一次 `setMarkedText` 会记录组合前正文与选区；marked text 存续期间不发布 Swift 文档投影、不刷新 Engine 正文，`unmarkText` 或最终 `insertText` 结束组合后只提交一次最终 replacement。保存触发提交组合后也等待这条命令完成。
- Rust/Swift 边界通过 ABI major、minor 与 capability bits 协商；宿主要求 Engine、统一派生、Engine 历史和 Render IR 能力，不再精确比较单一整数。Xcode 构建脚本按目标架构生成 arm64、x86_64 或 universal 静态库，并允许依赖分析在输入未变化时跳过 Rust 重建。
- Engine 的 `RefreshDerived(revision)` 由一次 `DocumentIr` 解析同时产生分析、语法范围、引用、稳定块 ID 的 `RenderIr` 和安全 HTML，并缓存到对应 revision；Swift 文档派生热路径直接消费这一响应，失败才回退旧散点调用。旧 `RenderedMarkdownPlanner` 尚未删除，因此不能据此声称双解析器已经完全清除。
- Engine 预览 HTML 的链接 target metadata 在 Rust 处理 `Link` AST 事件时直接附着到同一个 `<a>`；默认派生热路径跳过 Swift 的 anchor/reference 正则配对。标题 DOM id 的旧后处理和关闭 Engine 时的完整旧 renderer 仍待清理。
- 顶层预览节点携带 Rust RenderIR 的稳定 `data-inflow-block-id` 与 source range；WKWebView 首次装载后通过隔离 content world 做块级 DOM patch，字节相同的节点保留实例，变化节点替换并按新顺序挂载，同时以原顶部可见块恢复滚动位置。只有初次装载、页面未就绪或补丁失败才执行完整 `loadHTMLString`。
- 可编辑 WKWebView 只保留在显式环境开关 `INFLOW_EDITABLE_WEB_PREVIEW=1` 后作为实验；默认“即时编辑”仍是持久 NSTextView，不把 DOM 转换结果写成主编辑路径。
- 源码编辑、实时预览分栏左侧与即时编辑复用同一个 MarkdownSourceEditor 和 MarkdownSourceEditorSession；分栏右侧使用当前内存正文生成的只读 WebKit 结果，即时编辑在原始字符串上应用 Rust 解析范围对应的 TextKit 展示属性。
- 文本修改由 NSTextView 发布回同一个绑定；默认撤销与重做走 Rust Engine 历史，旧 AppKit UndoManager 只在关闭 Engine 的回退路径中使用。展示属性和 Engine patch 回写不登记正文 undo。
- EditorViewMode 的历史内部 case 名 preview 现在对应用户可见的“即时编辑”。
- 视图切换复用同一选区与源范围导航入口。点击大纲后当前可编辑视图直接滚动到标题，把插入光标放到标题起点并聚焦编辑器；不切换视图，caret 导航不显示查找匹配高亮。

### 2.3 即时编辑与分栏预览

- 即时编辑始终挂载同一个 MarkdownSourceEditor。普通文字、行内代码与引用在渲染态直接输入；Markdown 标记以透明和负字距折叠，不再用 0.1pt 字体改变行度量。CaretStyleResolver 从最近可见字符解析字体、字号和行高，并将插入光标在行框中居中。围栏代码平时隐藏围栏呈现代码，光标进入才局部显示源码；Mermaid 也使用同样的局部切换。保存内容和 undo 始终属于原始 Markdown。
- 分栏右侧的 MarkdownPreviewView 使用 MarkdownRenderer 把当前内存正文生成 HTML，并在禁用页面脚本的 WKWebView 中展示。Mermaid `flowchart` 支持普通连线和仓库已有的 `-.文字.->` 带标签虚线，生成有明确固有尺寸的本地自包含 SVG；即时编辑通过 `inflow_mermaid_render_svg` 直接获取同一 Rust 渲染器的 SVG，不再解析或截取预览 HTML。进入 Mermaid 源码块时会先卸载图表覆视图，移出后再挂载。CSP 只放行 `data:` 以及 `http`/`https` 图片，仍禁止脚本、连接 API、媒体、嵌入、文件 URL 和页面自行导航；非持久数据存储不保留站点数据。
- 展示属性与 Engine patch 回写都不登记 AppKit 正文 undo；三种视图间切换时保持同一正文、修改状态、保存路径和 Rust 撤销历史。
- 即时编辑中的链接默认单击执行导航，“设置 > 预览”可改为只从右键菜单打开，此时单击只定位光标；文本与表格中的链接共享 Hover 高亮反馈。表格使用 AdaptiveRenderedMarkdownTableLayoutStrategy 按内容测量列宽，再随编辑区扩张或压缩；单元格可编辑，右键提供行列增删和列对齐。链接导航、本地图片和失败降级继续受当前内容快照与封闭宿主消息约束。

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
- 用户通过系统面板选择的项目或资源目录会直接注册为当前可用范围，其内部文档和资源不再触发应用内“允许目录访问”提示；恢复失败时只要求重新选择不可用的项目。
- 图片文本编辑与资源创建不是可逆的同一文件事务：撤销只移除 Markdown 引用，已经写入 assets 的图片保留。
- 本地相对图片以当前 Markdown 目录为基准解析；已授权且通过 PNG/JPEG 校验的项目内外路径均可在分栏预览和即时编辑中呈现。`http`/`https` 图片使用无 Referer 的异步网络请求，并对同一 URL 做有界缓存。
- 用户选择项目目录即授权该目录身份下的项目内导航；每次激活仍重新验证根目录身份、规范路径、符号链接边界和目标文件快照。验证通过的项目内 Markdown 链接直接打开原文件，不再重复显示确认或文件授权面板；同一路径已有编辑窗口时只聚焦既有窗口。
- 用户在即时编辑或分栏预览中普通点击后，相对路径、绝对路径和 `file://` 都进入本地打开流程。项目内 Markdown 在当前项目打开；项目外 Markdown、文本、图片、PDF 及其他普通文件不再要求 Inflow 先读取或复制字节，而是直接交给 macOS Launch Services。`http`/`https` 交给默认浏览器；脚本和自定义 scheme 被阻止。

这些路径的真实文件权限、外部默认应用行为及项目内打开由 UAT-PERSONAL-05 与 09 判定。

### 2.6 手动保存、外部变化与轻量恢复

- AppPreferences.applyAutosavePolicy 和应用委托都把 NSDocumentController.autosavingDelay 设为 0；ManualSaveDocumentHostPolicy 还在启用编辑前关闭具体文档宿主的 autosavesInPlace、autosavesDrafts 与 preservesVersions，并动态复核三个结果。
- 关闭已修改标签、关闭窗口和退出应用继续由 AppKit 的原生 Save / Don't Save / Cancel 审查处理；`NSApplication` 在调用应用委托前已经完成退出审查，应用委托不会再次启动第二轮 `reviewUnsavedDocuments`。选择 Don't Save 后直接完成原退出事务；项目内切换标签不会触发写回或关闭确认。
- 当前主 App 未安装自动保存开关。宿主策略兼容层只服务个人内部版；未经真实进程 UAT 不得推导为公开发布架构证据。
- 已命名文档的保存动作经原生文档 API 完成。失败保留当前编辑，不显示成功。当前文件菜单只暴露保存与另存为；保存副本的底层路径仅作为后续延期实现保留，不属于个人首版界面能力。
- 外部变化提示当前只承诺重新加载或暂不处理；本地也有未保存修改时，后续手动保存要求明确覆盖确认。
- 当前里程碑不承诺三版本比较、自动合并、无竞态 compare-and-replace 或删除文件原位重建。
- DocumentRecovery 后端仍包含较完整的存储与迁移实现，但当前 UI 只使用 LightweightRecoveryPromptView：每份文档最多呈现一个最新快照，操作只有恢复为未命名文档或放弃。
- 正式 Release 恢复密钥继续存入 Keychain。Xcode Debug 使用独立的 DevelopmentRecovery 目录和该目录内随机、权限为 `0600` 的开发密钥；XCTest 再使用每次运行独立的临时目录与固定测试密钥。开发或自动化构建不读取 `com.inflow.desktop.recovery`，避免 ad-hoc 签名每次变化时反复请求“登录”钥匙串密码，也不接触正式恢复内容。
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
- 自动保存偏好 key、旧延迟枚举，以及当前 Settings 场景未暴露的其余完整设置矩阵；
- Inflow 管理的最近文档记录、完整恢复中心、多快照、复杂冲突与比较界面；
- 公式、脚注、额外 Mermaid 图类、删除线/围栏代码等未安装菜单动作；
- 深色 PDF、专业后验、固定性能门槛、30 次协议和发布证据链；
- 扩展、插件、人工智能、连接器与市场设计。

判断当前能力时，以已批准的个人首版范围、实际安装的菜单和主流程、以及 UAT-PERSONAL-01 至 10 为准，而不是以某个源文件或测试名称是否存在为准。

自动化同样按这个边界分区。`quality/personal-xctest-scope.tsv` 当前完整列出 403 个 XCTest method：297 个 `current-direct`、13 个依赖真实 `NSApplication` 菜单或生命周期的 `current-host`、88 个后置 selector，以及 5 个固定性能 selector。`scripts/verify-launch.sh --personal` 只执行 `current-direct`，不会把另外三类记作通过；deferred profile 仍保留 macOS 全量测试。清单对重复、陈旧、未分类、非法分区及四类精确计数失败关闭，因此新增后置测试不能静默成为个人首版完成条件。

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
| UAT-PERSONAL-10 | 即时编辑基础范围 | 未执行 |

没有产品负责人签署的实际记录前，不得把任一项改为“通过”，也不得使用“候选已闭环”“个人首版完成”或“发布就绪”等表述。

## 5. 证据入口

- 产品范围：[个人首版范围](../../文档/01-产品设计/06-版本规划/02-首发版本范围.md)
- 人工步骤与结果：[产品验收标准](../../文档/01-产品设计/06-版本规划/03-产品验收标准.md)
- 技术责任边界：[architecture.md](architecture.md)
- 当前 UAT 对照：[launch-acceptance.md](launch-acceptance.md)
- 已废止旧记录：[launch-candidate-0.1.0-build-1.md](launch-candidate-0.1.0-build-1.md)
- 即时编辑块级计划：[../macos/Inflow/Editor/RenderedMarkdownEditor.swift](../macos/Inflow/Editor/RenderedMarkdownEditor.swift)
- 分栏预览宿主：[../macos/Inflow/Preview/MarkdownPreviewView.swift](../macos/Inflow/Preview/MarkdownPreviewView.swift)
- 三视图接线：[../macos/Inflow/Editor/MarkdownEditorView.swift](../macos/Inflow/Editor/MarkdownEditorView.swift)
- 同一 NSTextView 宿主：[../macos/Inflow/Editor/MarkdownSourceEditor.swift](../macos/Inflow/Editor/MarkdownSourceEditor.swift)
