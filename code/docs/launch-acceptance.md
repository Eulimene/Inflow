# Inflow 个人首版内部验收矩阵

> 适用范围：[个人首版（内部验证版）范围](../../文档/01-产品设计/06-版本规划/02-首发版本范围.md)
>
> 人工步骤：[产品验收标准](../../文档/01-产品设计/06-版本规划/03-产品验收标准.md)
>
> 当前结论：UAT-PERSONAL-01 至 10 均未执行；个人首版尚未通过。

本文把当前代码入口映射到个人首版 UAT。它不再使用旧的公共首发、签名、公证、更新、候选包或 30 次性能门禁作为当前完成条件。

## 状态定义

- **实现入口**：当前工作树中存在对应主流程、纯函数或测试文件，可供开发验证。
- **自动化结果**：只有实际运行并记录的构建或测试结果才能声称通过；代码或测试文件存在本身不算结果。
- **人工 UAT**：产品负责人必须在自己的真实项目上完成产品文档中的操作，并记录“通过”“退回”或“未执行”。
- **个人首版通过**：仅当十项人工 UAT 全部实际通过，且产品负责人签署最终结论时成立。

自动化不能替代 Finder、Dock、拖放、中文输入法、外部编辑器、外部查看器、沙箱授权、强制退出、焦点或真实项目烟测。

## 当前 UAT 映射

| UAT | 当前可检查的实现入口 | 必须由本人实际确认 | 当前人工状态 |
| --- | --- | --- | --- |
| UAT-PERSONAL-01 入口、新建、首次保存、编辑与关闭 | InflowApp、InflowLaunchPolicy、RecentDocuments、FolderBrowser、MarkdownDocument、ManualSaveDocumentHostPolicy、DocumentSaveCommands、AppPreferences、InflowSettingsView；相关 FolderBrowserTests、RecentDocumentsTests、MarkdownCodecTests、AppPreferencesTests | 普通启动和 Finder 双击 App 均不弹文件选择器、直接进入可编辑未命名文档；菜单与 Command+N；首次保存取消/成功；应用内多文件与项目；Finder“打开方式”与默认应用；拖到应用图标；去重和空白窗口复用；工作区偏好跨文件和应用重启保持；另存退出项目；临时文档退出时选择 Don't Save 后一次完成、不重复审查；保存失败；全程无自动保存 | **未执行** |
| UAT-PERSONAL-02 简单外部变化提示 | DocumentFileSafety、DocumentFileSafetyView、DocumentSaveCommands；相关 DocumentFileSafetyTests | 外部编辑器修改；重新加载或暂不处理；双方变化后手动保存的明确覆盖确认；取消时两边各自保持；无三版本比较或自动合并 | **未执行** |
| UAT-PERSONAL-03 轻量单快照恢复 | DocumentRecovery、LightweightRecoveryPromptView；相关 DocumentRecoveryTests | 真实强制退出；每份文档只见一个最新快照；恢复为未命名文档或放弃；恢复前不覆盖原文件；手动保存后清理 | **未执行** |
| UAT-PERSONAL-04 源码、分栏、查找格式与两类 Mermaid | MarkdownEditorView、DocumentOutlineView、OutlineCommands、MarkdownSourceEditor、MarkdownRenderer、MarkdownFormatter、查找组件；相关 EditorViewModeCommandsTests、MarkdownRendererTests、MarkdownFormatterTests、MarkdownInsertionTests | 源码与分栏共用正文；大纲默认折叠并可在工作区边缘中部用同一按钮展开或折叠；点击标题滚动正文、移动光标并聚焦编辑器，不显示查找高亮；查找替换与一次撤销；只使用允许的格式命令和固定表格模板；删除线/围栏代码/图片走源码；CommonMark/GFM、带文字虚线的 flowchart、stateDiagram-v2；原始 HTML 安全；单图局部降级 | **未执行** |
| UAT-PERSONAL-05 图片与本地链接 | ImageAssetImporter、LocalImageResolver、PreviewLinkNavigation、图片插入与临时副本路径；相关 MarkdownInsertionTests、MarkdownRendererTests | 文件选择/拖放/剪贴板静态 PNG/JPEG；assets 与递增重名；撤销只移除引用且保留资源；已选项目内 Markdown 在重验边界与快照后无重复确认地打开原件并去重；PNG/JPEG/PDF 是不可写临时副本；http/https 需明确激活；file、脚本、自定义 scheme 被阻止；临时副本周期清理 | **未执行** |
| UAT-PERSONAL-06 基础浅色 PDF | HTMLExportCommands 当前只安装 PDF；PDFExporter 与 personalPDF 配置；相关 PDF 定向测试及“无 HTML 菜单”测试 | 空白禁用；导出时当前内容；基础浅色页面；PNG/JPEG、两类 Mermaid 与缺图占位；http/https 可点击且危险 scheme 无动作；同名覆盖确认；成功后打开/Finder；失败不误报 | **未执行** |
| UAT-PERSONAL-07 本地最小日志与无自动遥测 | LocalFailureLogController、帮助菜单导出日志；LocalFailureLogTests | 当前与上一会话；仅时间、应用版本、操作类别和错误代码；无敏感内容；本人选择位置；Inflow 不上传、不打开上传渠道、不保留隐藏副本 | **未执行** |
| UAT-PERSONAL-08 一个真实项目端到端与基础烟测 | 上述主流程及启动、左右导航区和持久工作区偏好的组合入口 | 从双击 App 不经文件选择器进入可编辑正文开始，用同一个真实项目完成产品文档列出的整段旅程；核对默认左侧目录树、右侧大纲与独立隐藏/显示，切换文件和重启后偏好保持；基础键盘和焦点；非颜色状态；可控异常不崩溃；较大文档继续工作或安全降级；记录实际环境与观察，不套用固定阈值或 30 次协议 | **未执行** |
| UAT-PERSONAL-09 项目目录树、新建与相对资源 | MarkdownEditorView、PersistentEdgeSplitView、FolderBrowser、LightweightProjectCoordinator、ProjectDocumentSurface、AppPreferences、InflowSettingsView、项目资源边界与链接路径；相关 EditorViewModeCommandsTests、FolderBrowserTests、AppPreferencesTests、MarkdownRendererTests | 普通文件夹项目；首次默认显示左侧目录树、折叠右侧大纲；两侧在边缘中部使用同一控件就地展开/折叠，目录树用单一动态按钮展开全部/折叠全部，且不改变内容状态；视图、显隐和三处分栏尺寸跨文件与重启保持；单一项目外壳和目录树实例保持不变，后台文档只切换可见的右侧工作区表面，不显示或切换文档窗口，源码可见时焦点返回编辑器；顶部标签可右键关闭且不静默丢弃修改；递归树、隐藏项与手动刷新；按钮/右键安全新建；落盘前后失败差异；已选项目内 Markdown 无重复确认地导航、相对图片呈现；规范化和符号链接越界阻止 | **未执行** |
| UAT-PERSONAL-10 即时编辑基础范围 | RenderedMarkdownEditor、MarkdownSourceEditorSession、MarkdownEditorView；RenderedMarkdownEditorTests | 基础结构直接编辑；复杂块局部源码；中文输入法 marked text；普通点击编辑、Command+点击打开；文本/RTF/HTML 粘贴只留纯文本，PNG/JPEG 走图片流程；三视图同一正文/undo/路径；保存后仍为纯 Markdown；未操作与不支持范围逐字不变 | **未执行** |

表中的测试名称只是定位入口。本文没有把它们写成一次新的全量测试回执，也没有因此改变人工状态；启动、左右导航区和设置默认的新增检查同样均未执行。

## UAT-PERSONAL-04 与 05 的固定边界

为防止旧文档把超范围能力重新带回当前口径，验收时必须特别检查：

- 格式菜单只有粗体、斜体、行内代码、H1–H6、引用和三类列表；链接与固定空表格模板位于插入菜单。
- 删除线、围栏代码和图片内容通过源码编辑与预览验证，不写成格式菜单能力。
- Mermaid 当前只验 flowchart 与 stateDiagram-v2；公式、脚注、sequenceDiagram、classDiagram 和其他 Mermaid 不计入通过。
- 原始 HTML 只能可读或安全转义，不能执行样式、脚本、事件、表单、嵌入、导航或网络动作。
- 断开网络后实时预览仍能完成首帧与内容刷新，即时编辑仍可直接写作；已声明的 WebKit 客户端沙箱能力不得导致任何页面网络请求，`http`/`https` 只在用户明确操作后交给系统浏览器。
- 图片新增只接受静态 PNG/JPEG，写入 assets，重名递增；撤销不删除已写入资源。
- 项目内 Markdown 打开可编辑原件；PNG/JPEG/PDF 打开不可写临时副本。即时编辑只在 Command+点击时执行链接。

## 自动化检查口径

开发者可以按改动范围运行 Rust 检查、macOS build 与定向 XCTest。允许记录：

- 执行日期、提交或工作树标识；
- 精确命令；
- 通过、失败、跳过与未执行数量；
- 已知测试宿主或环境阻塞。

仓库级当前自动检查的唯一配置是 `scripts/verify-launch.sh --personal`。它运行 Rust 格式、Clippy 与测试、macOS `build-for-testing` 后的个人首版 direct XCTest、Analyze 和 diff 检查，不生成归档或发布证据。`quality/personal-xctest-scope.tsv` 将当前 373 个 XCTest method 逐项分为 267 个 `current-direct`、13 个 `current-host`、88 个 `deferred` 与 5 个 `fixed-performance`；personal profile 只执行第一类，其他三类不计为通过。13 个宿主用例保留为 App-host 专项验证或真实应用 UAT；deferred profile 仍运行 macOS 全量测试。清单只要出现重复、陈旧、未分类、非法分区或计数变化，脚本就失败关闭。`--deferred-release-local`、`--deferred-signed-archive`、`scripts/release-workflow.sh`、固定性能协议和扩展合同均为显式后置门禁；即使单独通过，也不改变本表的人工状态。

可用 `scripts/verify-launch.sh --describe-profile personal` 查看当前配置，也可查看两个 deferred profile；描述命令不构建、不归档、不签名、不联网。

不允许把以下内容写成当前结论：

- “有测试文件”推导为“测试已通过”；
- “定向测试通过”推导为“十项 UAT 已通过”；
- “产品范围已批准”推导为“实现已完成”；
- 旧归档、旧哈希或旧测试计数推导为“当前候选有效”。

## 人工记录模板

产品负责人完成一次真实操作后，至少记录：

| 字段 | 内容 |
| --- | --- |
| 日期 | 实际验收日期 |
| 环境 | Mac 型号、macOS 版本 |
| 构建 | 应用构建或提交标识 |
| 主样本 | 本人真实 Markdown 项目的内部标识 |
| 烟测样本 | 项目内较大 Markdown 的内部标识 |
| UAT 结果 | UAT-PERSONAL-01 至 10 各自的通过、退回或未执行 |
| 问题 | 影响、复现方式与复验结果 |
| 最终结论 | 产品负责人签署“个人首版通过”或“退回” |

在这份记录实际产生前，当前结论保持“未执行”。

## 历史记录

[launch-candidate-0.1.0-build-1.md](launch-candidate-0.1.0-build-1.md) 已废止。它不绑定当前工作树，不使用当前个人首版 UAT，也不构成当前候选、内部验收或发布批准。
