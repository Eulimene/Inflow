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
- 正文只在用户执行保存、Command+S 或关闭确认中选择“保存”时写回用户文件；定时、草稿和就地自动保存在启用编辑前关闭。
- 支持应用内打开一份或多份 .md / .markdown，以及打开普通文件夹项目；外部文件或文件夹请求沿同一去重与窗口复用路径处理。
- 项目目录树递归展示普通项目项，默认排除隐藏项与越界符号链接；刷新由用户主动执行。
- 新项目窗口采用左侧项目目录树、中间编辑区、右侧当前文档大纲的固定布局；产品首次默认显示目录树、折叠大纲，项目还没有当前文档时大纲不可操作。
- 目录树和大纲在各自工作区边缘中部提供同一个展开/折叠控件；工具栏、“显示”菜单与“设置 > 工作区”读写同一组永久偏好。
- 项目树可在选定目录安全新建 .md / .markdown，使用不覆盖创建并在执行时重新检查项目边界。
- 项目文档以顶部标签保持独立的内容、撤销与未保存状态；右键任何标签都可关闭，如有修改则使用原生“保存 / 不保存 / 取消”复核。

### 三种写作视图

- 源码编辑、实时预览分栏和即时编辑都绑定同一 Markdown 文本、同一保存路径与同一个持久 NSTextView 会话。
- 视图切换不创建富文本副本；正文修改继续进入同一原生撤销与重做历史。
- 即时编辑直接呈现段落、ATX H1–H6、Setext H1/H2、粗体、斜体、删除线、引用、三类列表、GFM 表格、行内代码、行内/完整引用/折叠引用/快捷引用/自动链接及本地/在线图片；嵌套样式按有效字号合成，合法代码跨度的边界空格、链接定界符、表格分隔行和引用定义不会残留在阅读内容中。
- 图片以不改写原文的布局覆盖呈现，加载前显示占位；表格呈现为带表头、对齐和网格线的原生表格，表格内链接同样可普通单击；引用隐藏 `>` 并显示引用条。受支持的 Mermaid 由离线 Rust Core 生成 SVG 后直接呈现。普通围栏代码、原始 HTML、无效或不支持的 Mermaid 及其他复杂或歧义结构仍在原位保留可编辑源码。
- 输入法存在 marked text 时保留现有展示；链接普通点击即激活，指针经过可点击文字时显示链接光标。
- 当前格式菜单只暴露粗体、斜体、行内代码、H1–H6、引用和无序/有序/任务列表；链接与固定表格模板位于插入菜单。

### Markdown、资源与链接

- 当前验收范围是 CommonMark/GFM 基础、flowchart 与 stateDiagram-v2；单个图表失败只降级该块。
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
- 独立持久的纯预览、完整 Typora 对等、表格的结构化单元格编辑与完整结构化即时编辑。
- HTML 导出、深色或专业 PDF、打印合同和公共分发级交付后验。
- 公式、脚注、其他 Mermaid 图形、完整原始 HTML 兼容和复杂格式矩阵。
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

    cargo fmt --manifest-path core/Cargo.toml --check
    cargo clippy --manifest-path core/Cargo.toml --locked --all-targets -- -D warnings
    cargo test --manifest-path core/Cargo.toml --locked

个人首版的仓库级本地自动检查使用：

    scripts/verify-launch.sh --personal

该配置只执行 Rust 格式、Clippy 与测试、macOS `build-for-testing` 后的个人首版 direct XCTest、Analyze 和 diff 检查；不创建归档或发布证据，也不执行固定设备/30 次性能协议、扩展生态合同、签名、公证或分发门禁。[`quality/personal-xctest-scope.tsv`](quality/personal-xctest-scope.tsv) 把当前 380 个 XCTest method 逐项分为 274 个 `current-direct`、13 个 `current-host`、88 个 `deferred` 和 5 个 `fixed-performance`。`--personal` 只执行 `current-direct`；其余三类不计为通过。13 个宿主用例保留为 App-host 专项验证或真实应用 UAT，后置与固定性能用例由 deferred profile 的全量测试保留。脚本会对重复、陈旧、未分类、非法分区和四类精确计数失败关闭；新增测试不能默认混入当前门禁。可用 `scripts/verify-launch.sh --describe-profile personal` 无副作用查看边界。

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
