# Inflow 个人首版开发基线

> 当前里程碑：个人首版（内部验证版）
>
> 当前用户：产品负责人本人
>
> 验收状态：UAT-PERSONAL-01 至 10 尚未记录为已执行；本文不表示个人首版已经通过。

Inflow 是一款本地优先的 Markdown 写作工作台。当前代码只为产品负责人在自己的真实 Markdown 项目中完成内部验证闭环，不是 0.1 公共预览，也没有公开分发、更新或长期兼容承诺。

## 目录

- core/：平台无关的 Rust 核心，负责 Markdown 分析、编辑计划与安全派生结果。
- macos/：SwiftUI 与 AppKit 客户端，负责文档、文件夹项目、窗口、菜单、文件授权和原生编辑。
- scripts/：开发构建与自动化检查脚本；其中保留的发布脚本不是当前里程碑入口。
- docs/：代码侧的当前实现、架构和验收说明。
- quality/：历史或后续阶段使用的机器可读协议与语料；它们不扩大个人首版范围。

## 当前实现口径

以下内容表示当前工作树中已经存在相应代码路径或组件测试，不等于产品负责人已完成人工 UAT。

### 文档与轻量项目

- 无待打开目标的普通启动，或在 Finder 中双击 Inflow App，均直接创建并聚焦一份可编辑的未命名 Markdown；不显示启动页，也不弹文件选择器。用户首次明确保存时才选择文件名和位置。
- 正文只在用户执行保存或 Command+S 时写回用户文件；未保存正文只进入应用私有暂存区，不会自动覆盖原文件。
- 关闭文档会将最后输入暂存到系统临时目录，不弹保存确认；关闭最后一个文档窗口会直接退出应用，不保留无窗口后台进程。
- 支持应用内打开一份或多份 .md / .markdown，以及打开普通文件夹项目；外部文件或文件夹请求沿同一去重与窗口复用路径处理。
- 项目目录树递归展示普通项目项，默认排除隐藏项与越界符号链接；刷新由用户主动执行。
- 新项目窗口采用左侧项目目录树、中间编辑区、右侧当前文档大纲的固定布局；产品首次默认显示目录树、折叠大纲，项目还没有当前文档时大纲不可操作。
- 目录树和大纲把展开/折叠控件放在各自顶部；隐藏后面板宽度平滑归零，并在标签栏或编辑区顶部保留紧凑的恢复按钮。“显示”菜单与“设置 > 工作区”读写同一组永久偏好，窗口工具栏不再重复提供面板按钮。
- 即时编辑对未支持的 Markdown 构造局部保留源码；成对三横线包裹的内容不会被误呈现为分隔线和 Setext 标题。
- 项目树可在选定目录安全新建 .md / .markdown，使用不覆盖创建并在执行时重新检查项目边界。
- 项目文档以顶部标签保持独立的内容、撤销与未保存状态；目录树和标签以圆点标记修改，每个标签都有快捷关闭按钮，关闭时暂存对应未保存内容，重启后静默恢复。

### 三种写作视图

- 源码编辑、实时预览分栏和即时编辑都绑定同一 Markdown 文本与同一保存路径；即时编辑与分栏右侧还共享同一份 Rust `NativeRenderPlan` 和同一个 TextKit 最终布局实现，两者只以 `isEditable` 区分。
- 即时编辑直接复用持久 NSTextView 与 Rust Core 的解析范围：普通文字、标题、行内代码、引用和列表在渲染态直接编辑。Markdown 标记由显示层折叠，插入光标按当前可见文字样式和行框计算；只有围栏代码、Mermaid 等必须暴露结构的块才在光标进入时局部显示源码。
- 光标移到另一块或编辑器失去焦点后，旧块立即恢复渲染；不再需要右上角“编辑源码/完成编辑”按钮，不创建第二份可编辑正文。正文修改统一进入 Rust Engine 的撤销与重做历史。
- 图片以不改写原文的布局覆盖呈现，加载前显示占位；表格保持带表头、对齐和网格线的原生渲染，宽度随编辑区自适应，单元格可直接编辑，右键菜单提供行列增删与列对齐；表格外的输入会复用既有表格视图。引用隐藏 `>` 并显示引用条。图表由 Rust Engine 提供源码请求，经离线 JavaScript 适配层生成 SVG，无专用 C ABI；编辑图表时显示源码和下方预览。围栏代码非编辑时隐藏围栏并呈现代码内容，光标进入时切换为局部源码。
- 输入法存在 marked text 时保留现有展示；编辑态链接默认单击编辑、⌘+单击导航，只读预览单击导航，也可在“设置 > 外观与预览”中改为只允许从右键菜单打开。文本和表格链接在鼠标悬停时都显示 Hover 背景。
- 格式菜单提供粗体、斜体、删除线、行内代码、代码块、H1–H6、引用、列表与清除格式；链接与固定表格模板位于插入菜单。排版偏好、主题和写作模式见 [Typora 参考界面优化](docs/typora-interface-implementation.md)。

即时编辑新增正文 Enter 分段、Shift+Enter 段内换行，引用与列表使用结构事务；表格支持 Cmd+Enter、新增行焦点恢复、单元格格式保留和逻辑选区撤销。普通复制/剪切提供 Markdown 与 HTML，网页粘贴转换为常见 Markdown 结构，另有纯文本粘贴入口。详细实施与验收边界见 [Typora 式编辑实施记录](docs/typora-editing-implementation.md)。

### Markdown、资源与链接

- 代码围栏支持 mermaid.js（`mermaid`）、flowchart.js（`flow`）和 js-sequence-diagrams（`sequence`）；CodeMirror 提供代码语法高亮，MathJax 提供行内与块级公式。单块失败保留原文。实现边界见 [JavaScript 渲染适配层](docs/javascript-rendering.md)，新增能力不代表已通过人工 UAT。
- 原始 HTML 只作为可读源码或安全转义文本处理，不执行其中的脚本、样式、事件、表单、嵌入或网络动作。
- 已保存文档可通过文件选择、拖入或剪贴板加入静态 PNG/JPEG；资源复制到同目录 assets，重名使用递增后缀。
- 撤销图片插入只撤销 Markdown 引用，不删除已经写入 assets 的资源文件。
- 明确点击后，`http`/`https` 链接直接交给默认浏览器；本地相对路径、绝对路径和 `file://` 可指向项目内外的 Markdown、文本、图片、PDF 或其他普通文件。项目内 Markdown 在当前项目打开，项目外目标直接交给 macOS；本地 PNG/JPEG 与 `http`/`https` 在线图片同时支持分栏预览和即时编辑。脚本和其他自定义 scheme 仍被阻止。

### 保存、恢复、PDF 与日志

- 文件保存失败不会显示成功，当前编辑继续保留。
- 外部文件变化使用简单提示；当前编辑也已变化时，手动保存前要求明确确认是否覆盖。
- 每份文档只向当前界面暴露一个最新恢复快照，可恢复为未命名文档或放弃；不把恢复内容自动写回原文件。
- 文件菜单只提供基础浅色 PDF 导出；空白文档禁用导出，缺图可在确认后以可见占位继续。
- 本机仅保留当前会话与上一会话的最小故障日志。日志只有在用户主动选择位置时导出，应用不自动上传。

## 不属于当前能力

- 自动保存，以及 Inflow 管理的最近文档或最近项目。
- 使用另一套 DOM→Markdown 转换器实现富文本式结构化编辑。
- HTML 导出、深色或专业 PDF、打印合同和公共分发级交付后验。
- 脚注、完整原始 HTML 兼容和复杂格式矩阵。
- 完整恢复中心、多快照、版本时间线和完整异常恢复矩阵。
- 项目搜索、快速打开、标签重排/拆分到窗口、项目内重命名/移动/删除和导航历史。
- 公共版本号、Developer ID、Apple 公证、ZIP/DMG、下载来源、SHA-256、检查更新、回退、商业与公开支持。
- 固定大文件门槛、30 次性能协议、全部设备矩阵和完整辅助使用矩阵。

仓库可能仍保留上述方向的源文件、类型、测试、配置或脚本。除非当前菜单、主流程和个人首版 UAT 同时纳入，它们只算历史或后续技术资产，不能据此写成当前产品能力。

## 验收状态

- 已批准的范围和 UAT 只确定了判定方法，不表示实现或人工操作已经通过。
- 当前没有一份有效的个人首版候选或签署结果。
- docs/launch-candidate-0.1.0-build-1.md 已明确废止，只保留历史组件记录。
- 只有产品负责人用同一个真实项目实际执行 UAT-PERSONAL-01 至 10、逐项记录结果并签署“个人首版通过”，内部验证才算完成。

## 开发构建

需要 Xcode 26 或兼容版本，以及 rust-toolchain.toml 指定的 Rust 工具链。以下命令只产生开发验证结果，不产生公开候选：

一键构建 Debug App：

    scripts/build-app.sh

构建成功后直接启动：

    scripts/build-app.sh --open

指定构建目录并在构建前清理该配置的旧产物：

    scripts/build-app.sh --output-dir /private/tmp/inflow-build --clean

也可使用 `--release` 构建 Release 配置。`--output-dir` 未指定时默认使用当前项目下的 `Build`，App 位于所选目录的 `Products/<配置>/Inflow.app`。`--open` 会以新进程启动这一确切产物，避免 macOS 激活同 Bundle ID 的旧构建。

Debug、Release 和测试进程共用 `Resources/Assets.xcassets/AppIcon.appiconset` 中的图标。直接运行 `xcrun xctest` 时，测试启动入口会读取其所在 `Inflow.app` 的编译后图标并设置 Dock 图标，进程名仍为 `xctest`。界面测试使用构建产物的完整路径启动，不按应用名称查找，也不另外创建改名副本，以免混入同名的旧应用。

等价的底层构建命令：

    xcodebuild \
      -project Inflow.xcodeproj \
      -scheme Inflow \
      -configuration Debug \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath Build \
      CONFIGURATION_BUILD_DIR=Build/Products/Debug \
      CODE_SIGNING_ALLOWED=NO \
      build

Rust 核心的独立检查：

    cargo xtask verify
    cargo xtask verify-bindings
    cargo fmt --manifest-path core/Cargo.toml --check
    cargo clippy --manifest-path core/Cargo.toml --locked --all-targets -- -D warnings
    cargo test --manifest-path core/Cargo.toml --locked

ABI 3 只暴露 Engine create/dispatch/snapshot/free 和 owned-bytes free，其余能力统一经 schema-versioned Command/StatePatch 传输。C 声明由固定版本 `cbindgen 0.29.4` 通过 `cargo xtask bindings` 生成到 `core/include/generated/inflow_core.h`；`core/include/inflow_core.h` 只是稳定的引入外壳。生成结果必须提交，且上述检查和仓库级门禁会在绑定过期时失败。
需要独立分发核心时，`cargo xtask xcframework` 会用锁定工具链分别构建 arm64 与 x86_64 Release 静态库、合并为 universal binary，并连同生成 header 输出到 `build/InflowCore.xcframework`。

个人首版的仓库级本地自动检查使用：

    scripts/verify-launch.sh --personal

该配置只执行生成绑定校验、Rust 格式、Clippy 与测试、macOS `build-for-testing` 后的个人首版 direct XCTest、Analyze 和 diff 检查；不创建归档或发布证据，也不执行固定设备/30 次性能协议、扩展生态合同、签名、公证或分发门禁。[`quality/personal-xctest-scope.tsv`](quality/personal-xctest-scope.tsv) 把当前 421 个 XCTest method 逐项分为 299 个 `current-direct`、31 个 `current-host`、86 个 `deferred` 和 5 个 `fixed-performance`。`--personal` 只执行 `current-direct`；其余三类不计为通过。31 个宿主用例保留为 App-host 专项验证或真实应用 UAT，其中包括需要 AppKit 打印/PDF 系统服务的导出用例；后置与固定性能用例由 deferred profile 的全量测试保留。脚本会对重复、陈旧、未分类、非法分区和四类精确计数失败关闭；新增测试不能默认混入当前门禁。可用 `scripts/verify-launch.sh --describe-profile personal` 无副作用查看边界。

`--deferred-release-local`、`--deferred-signed-archive` 以及 `scripts/release-workflow.sh` 只为后续公共分发决策保留，不属于个人首版完成条件。

按改动范围运行 macOS 定向 XCTest；自动化通过只能作为实现证据，不能替代真实项目、中文输入法、Finder、拖放、外部文件变化、异常退出或外部应用参与的人工 UAT。

## 文档入口

- 当前实现事实与边界：[docs/current-implementation.md](docs/current-implementation.md)
- 技术责任与单一正文约束：[docs/architecture.md](docs/architecture.md)
- 个人首版 UAT 状态：[docs/launch-acceptance.md](docs/launch-acceptance.md)
- 已废止的旧候选记录：[docs/launch-candidate-0.1.0-build-1.md](docs/launch-candidate-0.1.0-build-1.md)
- 产品范围：[个人首版（内部验证版）范围](../文档/01-产品设计/06-版本规划/02-首发版本范围.md)
- 产品验收方法：[产品验收标准](../文档/01-产品设计/06-版本规划/03-产品验收标准.md)

## 提交规则

每个功能只在与改动范围匹配的 Rust 检查、单元测试和 macOS 构建通过后提交。
