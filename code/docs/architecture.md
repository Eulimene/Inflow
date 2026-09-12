# Inflow 个人首版架构基线

> 状态：适用于个人首版（内部验证版）
>
> 对齐日期：2026-09-12
>
> 本文描述当前主流程的责任与不变量，不把仓库中保留的后续代码写成当前产品能力。

## 1. 架构目标

当前架构只服务产品负责人本人的真实项目验证。核心目标是：

- Markdown 纯文本始终是唯一内容事实；
- 源码、分栏和即时编辑共享一份正文、保存路径与撤销历史；分栏右侧使用只读 HTML，块级即时编辑使用同一 Rust 解析结果驱动持久 NSTextView 的展示属性；
- 文件与项目操作保持在 macOS 原生授权和生命周期边界内；
- 解析、预览、图片、链接、恢复、PDF 或日志失败时，正文仍可继续手动保存；
- 复杂或不确定结构失败关闭到可见源码，不猜测性改写；
- 当前界面不暴露未进入个人首版范围的能力。

macOS 14 是当前工程构建目标。构建边界支持按 Xcode 的架构集合生成 arm64、x86_64
或 universal Rust 静态库；`cargo xtask xcframework` 另可生成带生成 header 的双架构 Release XCFramework，但尚未形成两类真实设备的公开支持承诺。

## 2. 分层与责任

### 2.1 Rust 核心

Rust 核心负责不依赖平台的纯值逻辑，并正在通过版本化 Engine 边界接管编辑状态：

- UTF-8 Markdown 分析、标题、统计、查找与格式计划；
- CommonMark/GFM 派生结果和安全的语法范围；
- Mermaid 围栏识别、语法校验和可确定复现的 SVG 生成；
- 可复用的 UTF-8 end-exclusive 范围与版本化 C ABI；
- 不访问用户任意文件，不持有 AppKit 对象。

当前迁移阶段已经引入有状态 `EditorEngine` 的 opaque handle、`revision`、UTF-8
`ReplaceText`、格式 Command、Memento undo/redo、快照和 `RefreshDerived`。每次 `RefreshDerived` 只创建一个 owned
`DocumentIr`，分析、语法范围、引用、`RenderIr`、`NativeRenderPlan` 与安全 HTML 都消费该事件流；派生缓存严格绑定
revision，正文修改后立即失效。macOS 已用该单次请求作为分析、高亮、引用、原生展示计划和预览的唯一文档派生热路径。
这份 revision-bound 引用集合由 `EditorStore` 与预览快照原子发布，预览链接、图片问题导航与文档迁移均显式消费它，不在交互时再把全文传入旧引用扫描 FFI。同步工具与隔离测试所需的 scanner 兼容入口也创建短生命周期 Engine，从统一 `DocumentIr` 读取引用，不再调用独立引用 FFI。

`EditorEngine` 通过 `MarkdownPort` 获取派生模型，不再直接依赖具体 Markdown
解析器或 renderer。默认 `CommonMarkAdapter` 负责从同一份 `DocumentIr` 一次生成分析、
高亮、引用、Render IR、原生渲染计划与预览 HTML；Engine 只负责 revision 校验、
缓存和命令顺序。该端口也是测试替身和未来解析策略演进的唯一接入点。
旧 `MarkdownAnalyzer` 与 `MarkdownHighlighter` 公开外观仍用于现有单元测试，但内部也已创建短生命 Engine 并消费同一 `RefreshDerived`，Swift 不再直接调用 analyze/highlight 数组 ABI。无预览 metadata 的交付 HTML 仍是独立低频边界，不与交互预览 HTML 混用。
预览链接目标、标题 source range 与块 ID 在 Rust 生成对应 HTML 事件时直接写入 data attribute；
Swift 不再把 HTML anchor、标题与引用列表做正则配对，也不再保留第二套 Markdown planner。
Rust 同时把 RenderIR 的稳定 `block_id` 与 UTF-8 source range 写到顶层预览节点。WKWebView 首次加载
完整文档，此后同一页面用隔离 content world 按 block id 复用未变化节点、替换变化节点并恢复顶部
可见块的滚动锚点；补丁失败才回退 `loadHTMLString`。
当前菜单格式与图片、链接、表格等插入操作也只发送 selection 与 operation，由 Engine 生成
revision-bound patch 后回写 NSTextView，不再由 View 调用一次性 formatter 规划。普通输入先由
NSTextView 乐观显示，再串行提交 Engine 并逐字节对账。默认编辑会话关闭 AppKit 正文 undo
registration，Command-Z 与 Shift-Command-Z 由第一响应者异步路由为 Engine `Undo/Redo`，返回 patch
时禁止再次登记撤销。查找请求同样携带 revision 并在该 Engine 的当前正文上执行，过期结果不能发布；旧同步 `MarkdownSearcher` 和 `MarkdownFormatter` 兼容入口也通过短生命周期 Engine 执行。格式可用性是不修改正文和历史的 `InspectFormat(revision, selection)` 命令；NSTextView 会话异步缓存结果，并在正文或选区改变时先失效。`SetMode(revision, editable/read_only)` 不改变正文 revision；read-only 在 Rust 命令边界拒绝 Replace/Format/Undo/Redo，而查找、派生和保存快照仍可执行。Store 串行模式更新，防止快速解锁/锁定产生过期模式。普通编辑只有在 Engine 返回匹配快照后才发布到 Swift 文档投影。保存、另存和覆盖确认在提交 marked text 并排空命令队列后发送 `PrepareSave`，Engine 保留该 revision 的 hash 直到 macOS Repository 完成磁盘验证并回传 `SaveCompleted` 或 `SaveAborted`。dirty 由当前 hash 与最后成功保存 hash 比较，因此保存期间的新编辑不会被错误清除。导出只冻结 Engine snapshot，不发送保存 receipt。
Engine 的 Memento 栈与连续输入合并策略封装在独立 `History`，Engine 只负责在命令成功后记录或完成 undo/redo。WindowAwareTextView 在第一次 `setMarkedText` 时保存组合前正文与选区，组合期间不发布正文命令；
`unmarkText` 或最终 `insertText` 清除 marked range 后只提交一次最终差异，因此一次候选词确认对应一个 Rust history entry。
宿主检测到外部文件重载后发送 `OpenDocument(base_revision, text, selection)`。Engine 在同一 opaque handle 内原子替换正文、清空派生缓存/历史/旧保存 receipt、重建已保存 hash，并单调推进 revision；不再销毁并新建 Engine 以及把 revision 退回 0。文件字节读取、UTF-8/BOM/换行解码仍由 macOS Repository 调用 Rust codec 后传入，路径与安全作用域不进入 Engine。

C ABI 用 `major/minor/capabilities` 协商兼容性：major 表示不兼容布局或所有权变化，minor
表示可加性演进，宿主只要求自身使用的 capability bits，不再因为链接到更新 minor 版本而拒绝启动。
旧 `inflow_core_abi_version` 保留为 major 的兼容别名。Rust build phase 声明源码输入和静态库输出，
未变化时允许 Xcode 跳过；脚本按 `ARCHS` 分别构建 Rust target，多架构时用 `lipo` 合并。稳定入口 header 只引入 `core/include/generated/inflow_core.h`，后者由固定版本 cbindgen 和 `core/cbindgen.toml` 生成；`cargo xtask verify-bindings` 逐字节拒绝过期绑定，手写 Swift/Rust ABI 声明不再是可接受路径。
Swift 边界中可在 Store/View 传递的稳定领域 DTO 集中在 `CoreBridge/CoreDTO.swift`；`EditorEngineClient.swift` 仅保留 actor 串行化、FFI envelope 与结果校验，不再同时定义上层命令模型。

核心可能保留比个人首版更宽的解析或导出实现。产品能力必须由 macOS 当前入口与 UAT 再收窄，不能直接从核心函数存在性推导。

### 2.2 macOS 宿主

SwiftUI 与 AppKit 负责：

- `MarkdownEditorView` 通过 `EditorStore` 调度文档派生、格式、查找、替换和持久化命令并消费 `EditorViewState`；Store 统一持有 generation、取消，并原子发布预览、分析和引用；
- 原生文档窗口、新建、打开、手动保存、另存和关闭确认；
- 没有外部目标时由应用委托显式创建并聚焦未命名文档，普通启动或 Finder 双击 App 不弹文件选择器；带外部目标时复用统一打开路由且不残留多余空白窗口；
- 普通文件夹项目、目录树、沙箱授权与项目根边界；
- 持久 NSTextView、菜单、快捷键、输入法和 UndoManager；
- UTF-8 核心范围到 TextKit UTF-16 范围的验证与转换；
- 本地图片读取、资源写入、链接激活、只读临时副本、PDF 和日志；
- 只在当前主流程安装个人首版允许的命令。

文件读写不跨越 Rust ABI。所有路径规范化、符号链接解析、安全作用域和目标状态都属于 macOS 宿主事实。

## 3. 单一正文不变量

迁移期间主数据流为：

    MarkdownDocument.text
        ↕
    MarkdownSourceEditorSession + 持久 NSTextView
        └─ ReplaceText 镜像 → Rust EditorEngine（revision + 字节快照对账）
        ├─ 源码展示属性
        ├─ 分栏预览派生结果
        └─ 即时编辑属性

必须同时保持以下约束：

1. NSTextView 的 string 是乐观显示缓存，MarkdownDocument.text 是 Engine 已确认的 Swift 投影；命令排空后两者必须逐字节一致。
2. 三种视图的可编辑侧都复用同一个 MarkdownSourceEditorSession；分栏右侧消费 previewHTML，即时编辑则把同一 Rust 解析范围映射到原始字符串的 TextKit 展示属性，不建立第二份可编辑内容。
3. 分栏右侧只消费当前源快照生成的派生结果，不可反向成为正文事实。
4. 展示属性、语法高亮和预览刷新不能发布正文变化，也不能登记正文 undo。
5. 格式、插入与正文撤销只通过 Engine Command 修改同一字符串；尚未迁移的查找替换先作为普通 `ReplaceText` 对账，不能建立第二套权威历史。
6. NSTextView 为 1.5 秒内同类型、相邻的普通键入或删除复用一个 `group_id`；Engine 只在补丁确实相邻且可逆时合并 Memento。换行、粘贴、IME 提交、格式命令和不同分组始终保留独立撤销边界。
6. 结果必须绑定精确 UTF-8 字节快照；正文变化后，旧范围和旧链接决定立即失效。
7. 默认写入方向已经反转：NSTextView 只保留乐观显示缓存，Rust 接受命令后才发布 Swift 文档投影；
   禁止 Swift 与 Rust 同时独立接受正文写入。生产路径不再提供关闭 Engine 事实源的环境开关。

Swift String 的规范等价不能替代精确字节身份。Rust 返回 UTF-8 byte range，TextKit 使用 UTF-16 NSRange，转换必须同时验证边界、长度和完整扩展字素，不能截断 Unicode 或 ZWJ 序列。

## 4. 三种视图

### 4.1 源码编辑

源码模式直接显示完整 Markdown，保留原生选择、输入、撤销、重做、查找和手动保存。

### 4.2 实时预览分栏

分栏左侧仍是同一个持久 NSTextView，右侧是当前源快照的只读派生结果。本地图片通过宿主验证后以内存数据提供，`http`/`https` 图片可由 WebKit 直接加载。非持久数据存储、页面脚本关闭、HTML CSP 和宿主导航策略仍禁止连接 API、媒体、嵌入、文件 URL 和页面自行导航。

标题定位和链接激活只接受当前快照中能够重新验证的封闭消息。派生失败不改变正文、保存或恢复。

### 4.3 即时编辑

EditorViewMode 的内部历史 case 名 preview 对应用户可见的“即时编辑”。该模式始终挂载共享的 MarkdownSourceEditorSession。Rust Engine 从同一次 `DocumentIr` 产生 revision-bound `NativeRenderPlan`，Swift 只校验 UTF-8 范围并映射为 TextKit 属性，不再分析 Markdown。普通文字保持渲染属性直接编辑，选区变化时从当前可见字符同步 typing attributes，使光标高度、字号和基线与文字一致。

只有围栏代码、Mermaid 和其他无法无损结构化编辑的块会在光标进入时局部恢复源码；普通文字和表格不进入该路径。RenderedMarkdownMermaidRenderer 是 Rust C ABI 的 Adapter，不再通过 HTML 字符串截取 SVG。表格宽度计算委托给 RenderedMarkdownTableLayoutStrategy，默认策略按内容和当前 viewport 自适应，并复用已挂载视图。CaretStyleResolver 负责跳过透明标记和换行符选择排版属性；隐藏标记不再使用微小字体改变光标和行高。链接激活策略作为持久偏好传入文本与表格链接，两者共享 Hover 反馈。该过程不替换 NSTextView，不创建第二份内容事实，也不登记展示层 undo。

## 5. 当前编辑命令边界

当前菜单只安装：

- 粗体、斜体与行内代码；
- H1–H6 标题；
- 引用；
- 无序、有序和任务列表；
- 链接；
- 图片；
- 固定空表格模板。

删除线、围栏代码和图片内容可以直接编辑源码并在预览中核对，但不是当前格式命令。分隔线、清除格式、脚注、公式和图表等实现即使仍留在类型或测试中，也不属于当前菜单合同。

格式计划必须绑定精确正文和选区；只读、输入法组合、过期快照、部分重叠或解析歧义时不修改正文。

## 6. 轻量文件夹项目

普通文件夹就是项目，不导入、不复制、不重组，也不创建 Inflow 私有项目文件。系统选择器返回的文件夹直接作为用户授权结果进入扫描，不再叠加 `fileExists` 可读性预检；无权读取的个别后代目录从树中跳过，不使整个根目录失效。

FolderBrowserController 负责：

- 递归列出普通目录与文件，默认隐藏点号项和系统隐藏项；
- 不跟随越出根目录的符号链接；
- 只在用户请求时刷新目录树；
- 根据选中目录、选中文件的父目录或项目根确定新建位置；
- 验证名称，自动补 .md，并以不覆盖方式创建空文件；
- 在确认创建前再次验证目录存在、可写且解析后仍在项目根内；
- 区分“落盘前失败”和“空文件已落盘但打开失败”，后者保留真实文件并报告。

LightweightProjectCoordinator 负责单一项目外壳、后台原生文档会话和应用内文档表面的注册与切换。同一规范路径已打开时只选择既有表面，不形成第二份编辑状态；新目标由 `NSDocument` 在后台完成读取和安全校验，其窗口在原生视图布局前就执行 `orderOut`，DocumentGroup 提供的 `Binding<MarkdownDocument>` 注册为 ProjectDocumentSurface 后先在隐藏层挂载，下一个主线程周期再替换右侧工作区。项目外壳的 `NSWindow`、FolderBrowserSidebar、左侧 PersistentEdgeSplitView、标签栏与工作区 ZStack 始终是同一实例；活动文档变化不调用 `showWindows`、不更换 AppKit 窗口，后台布局如果触发框架 frame 改写还会无动画恢复外壳原 frame。每个表面保留自己的 MarkdownSourceEditorSession 和 UndoManager，MarkdownEditorView 使用明确的原生文档覆盖执行保存、恢复与文件安全操作。标签关闭可以按当前、其他、左侧或右侧计算目标集；批量操作先逐份获得原生关闭授权，再在单次 WorkspaceSurfaceState 发布中移除全部目标。硬链接别名去重不属于当前合同。

项目根目录的 security-scoped 租约在用户选择后保持，项目文档不为子文件重复启动访问。该根目录身份也是项目内 Markdown 导航的直接编辑信任边界：每次打开仍重验目录身份、解析路径、符号链接边界和目标快照，通过后直接聚焦或打开标签，不再逐文件要求确认。原生打开造成的 last-used `ctime` 抖动只可在项目身份、解析路径、inode、大小、修改时间和描述符重读字节都与冻结请求匹配时稳定化；替换、越界或内容变更仍拒绝作为项目标签打开。

项目边界继续约束目录树、项目内可编辑 Markdown 标签和项目安全保存。用户明确点击的项目外本地链接不归类为项目标签，而是直接交给系统默认应用；嵌入预览的项目外图片仍要求当前沙箱已有读权限。

### 6.1 导航布局与工作区偏好

- 项目窗口使用固定空间顺序：左侧项目目录树、中间编辑区、右侧当前文档大纲；项目刚打开且没有当前文档时，右侧大纲不显示也不可操作。
- AppPreferences v2 是工作区展示偏好的唯一事实源，持久保存明确视图模式、项目目录树与文档大纲显隐、目录树与大纲宽度、实时预览源码占比；目录树首次默认开启，大纲首次默认折叠且只在有当前文档时可用。“自动”视图偏好保留未明确选择时的上下文起点。
- 目录树和大纲的展开/折叠按钮位于各自顶部；隐藏状态由 PersistentEdgeSplitView 在不替换 SwiftUI/AppKit 宿主的前提下把边缘宽度平滑过渡到零，目录树实例、文档表面和编辑器会话因此不会因显隐而重建。标签栏或编辑区顶部只保留一个紧凑恢复按钮，窗口工具栏不再重复显示面板按钮。“显示”菜单、设置页和 PersistentEdgeSplitView 全部读写同一偏好。用户操作立即作用于当前窗口，并由其他文件、窗口和重启后的进程复用。目录树栏头另使用一个动态按钮在“展开全部”与“折叠全部”之间切换。
- 项目目录树位于稳定外壳层，每份已打开文档的编辑表面都持续挂载在工作区内。切换标签只修改哪个表面可见和可交互，不替换项目外壳、分栏宿主、目录树或其 SwiftUI 根视图。后台 `NSDocument` 持续拥有内容、修改状态和保存身份，源码编辑器会话由 ProjectDocumentSurface 跨切换保留；文档自身的派生预览在其内容变化时独立更新。首个 DocumentGroup 宿主完成进程级类策略验证后，后台文档不再呈现自己的窗口。
- EditorWorkspaceMetrics 集中定义新窗口、项目目录树、大纲、正文最小宽度和底部状态栏尺寸。导航容器和空状态都以窗口可用高度为准参与布局，不能用自身固有高度缩短正文区域；状态栏始终贴在内容区底部。
- 导航区是正文之外的展示状态；显示、隐藏或修改工作区偏好不得改变 MarkdownDocument.text、当前项目文档、选区或 UndoManager 历史。

## 7. 手动保存与外部变化

个人首版只允许用户主动保存：

- 应用委托与 AppPreferences 都把 NSDocumentController.autosavingDelay 设为 0；
- ManualSaveDocumentHostPolicy 在允许输入前，对 DocumentGroup 创建的具体 NSDocument 宿主类关闭 autosavesInPlace、autosavesDrafts 与 preservesVersions，并通过 Objective-C 消息分派路径复核结果；
- 宿主策略无法安装或复核时，该文档不启用编辑，而不是降级到可能隐式写回的路径；
- 当前主 App 未安装自动保存开关；
- 未命名文档首次保存前不绑定用户路径；
- 已修改文档的普通关闭、项目切换与应用退出因此落回 AppKit 的 Save / Don't Save / Cancel 审查；`NSApplication` 在调用 `applicationShouldTerminate` 前已经完成退出审查，应用委托只核对 Inflow 自身的短期事务门禁，不得再嵌套第二次 `reviewUnsavedDocuments`；
- 保存失败保留当前编辑且不显示成功；
- 另存前只提示相对引用可能变化，不搬移资源或重写引用。

外部变化使用最小决策：

- 没有本地修改时可重新加载磁盘内容或暂不处理；
- 本地也有未保存修改时，手动保存前明确询问是否覆盖；
- 取消覆盖保持当前编辑和磁盘各自现状；
- 不提供三版本比较、自动合并或完整并发写入保证。

仓库中仍可能存在更复杂的冲突模型、目标指纹和写入后复核。它们可以作为防护实现，但不能把产品合同扩大为原子 compare-and-replace、无竞态覆盖或公共分发级文件事务。

DocumentGroup 本身没有公开的 FileDocument 自动保存策略开关。当前兼容层是个人内部里程碑的受限边界，不构成公共发布的长期宿主合同；任何公共版本都必须先以真实进程回归重新评审，必要时迁移到自有 NSDocument 生命周期。

## 8. 轻量单快照恢复

DocumentRecovery 负责应用私有恢复存储。当前界面只通过 LightweightRecoveryPromptView 暴露：

- 每份文档最多一个最新快照；
- 异常退出后恢复为未命名文档或放弃；
- 恢复文档不绑定、不自动覆盖原文件；
- 成功手动保存或明确放弃后清理对应快照；
- 恢复不可用不阻止正常打开和手动保存。

正式 Release 使用 `com.inflow.desktop.recovery` Keychain 项保存恢复域密钥。Xcode Debug 的 ad-hoc 指定要求会随重建变化，因此开发构建使用独立 DevelopmentRecovery 根和根内 mode-0600 随机开发密钥；XCTest 使用独立临时根与测试密钥。三种运行档位不得交叉读取、迁移或清理彼此的恢复记录。

RecoveryCenterView 中保留的比较、批量操作、历史、多快照、迁移和完整异常矩阵不构成当前产品能力。

## 9. 图片与链接边界

### 9.1 图片

- 文件选择、编辑区拖放与剪贴板只接受静态 PNG/JPEG。
- 未命名文档先完成首次保存；取消时不创建资源或引用。
- 系统选择器返回的项目或资源目录就是访问决策；ImageAssetDirectoryAccess 将所选目录及其边界内后代视为可用，不叠加应用内二次授权。跨启动访问仍由所选目录的安全作用域书签恢复。
- 资源写入当前 Markdown 同目录的 assets，重名自动使用递增后缀，不覆盖既有文件。
- 撤销只移除 Markdown 引用，已经创建的资源文件保留。
- 既有本地相对图片以 Markdown 所在目录为基准；沙箱可读的项目内外 PNG/JPEG 都经内容校验后内联为数据 URL。

不支持 TIFF 转换、图床上传、资源管家或删除孤立资源。`http`/`https` 远程图片可在分栏预览和即时编辑中加载，请求不发送 Referer，响应必须是有界的图片数据。

### 9.2 链接

- 项目内 .md / .markdown 打开原文件并允许继续手动保存；已有窗口时只聚焦。
- 项目内 Markdown 仍在当前项目打开；项目外 Markdown、文本、PNG/JPEG、PDF 和其他附件在明确点击后直接交给 Launch Services，不再以 Inflow 能否预读字节作为打开前提。
- 链接可使用相对路径、绝对路径或 `file://`；项目外目标不进入当前项目标签的直接编辑信任边界。
- http/https 只在用户明确激活时交给默认浏览器。
- `file://` 进入本地文件流程；脚本和其他自定义 scheme 被阻止。
- 每次激活前重新检查正文、目标类型与文件状态；项目内 Markdown 额外重验项目边界后直接打开原文件。失败只显示原因，不猜测替代目标。

## 10. Markdown 呈现范围

当前验收只包含：

- CommonMark 基础；
- GFM 删除线、任务列表和表格；
- Mermaid flowchart 与 stateDiagram-v2；
- 原始 HTML 的可读源码或安全转义。

公式、脚注、sequenceDiagram、classDiagram、其他 Mermaid 与完整原始 HTML 兼容均为后置范围。当前 Mermaid 渲染器只接受 flowchart 与 stateDiagram-v2；其他后续内部代码或历史材料的存在也不代表当前界面、PDF 或 UAT 承诺兼容。

## 11. 基础浅色 PDF

文件菜单只安装一个 PDF 导出入口，空白文档时禁用。发起导出时冻结当前正文，并强制使用 personalPDF 浅色外观。

当前合同只要求：

- 单篇 PDF、固定基础布局；
- 当前文字、静态 PNG/JPEG、flowchart 和 stateDiagram-v2；
- 缺图警告与用户确认后的可见占位；
- 简单同名覆盖确认；
- http/https 可点击，file、脚本和自定义 scheme 不形成动作；
- 成功后打开或在 Finder 显示，失败时正文继续可用。

仓库中的 HTMLExporter 名称与 HTML 生成函数来自历史实现或 PDF 内部准备层。当前没有用户可达的 HTML 导出，也不承诺深色 PDF、专业页面设置、打印、完整后验或非协作写入者并发保证。

## 12. 本地最小日志

LocalFailureLogController 只允许记录时间、应用版本、操作类别和错误代码。它不得接收正文、文件名、完整路径、选区、剪贴板、链接、搜索词、账号、凭据或恢复内容。

日志只保留当前与上一会话，并且只有用户选择“导出日志…”后才写到指定位置。Inflow 不自动上传、不打开上传渠道，也不保留隐藏导出副本。

## 13. 当前不安装的能力

以下源文件、类型、设置 key、测试或脚本可能仍在仓库中，但当前主 App 不应把它们安装成入口：

- 检查更新与公开发布 Profile；
- HTML 导出；
- 自动保存与 Inflow 管理的最近文档；
- 独立持久纯预览；
- 当前 Settings 场景未暴露的其余完整设置矩阵、完整恢复中心和多快照；
- 公式、脚注、其他 Mermaid 与超范围格式命令；
- 深色/专业 PDF、打印与公共分发级后验；
- 插件、人工智能、连接器、同步与商业能力。

这条边界应由菜单/场景测试和人工 UAT 共同验证。仅删除文案或仅保留不可达类型都不足以证明产品行为。

## 14. 验证边界

组件测试用于验证纯函数、范围转换、菜单可达性、资源边界和失败关闭。普通启动与 Finder 双击 App 无文件选择器、左右导航区的默认位置与独立开关、工作区偏好跨文件和应用重启持久化，以及真实 Finder、Dock、中文输入法、外部编辑器、外部查看器、沙箱授权、强制退出、焦点和一个真实项目，必须由产品负责人按 UAT-PERSONAL-01 至 10 实际操作。

在全部 UAT 完成并签署之前：

- 可以写“存在实现/组件测试入口”；
- 不得写“个人首版通过”“候选有效”“端到端闭环”或“发布就绪”；
- 不得用旧候选、旧测试计数或旧归档代替当前人工记录。
