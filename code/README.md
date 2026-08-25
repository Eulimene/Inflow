# Inflow 开发基线

Inflow 是一款本地优先的 Markdown 写作工作台。首发客户端支持 macOS 14 及更高版本，并仅支持 Apple Silicon。

## 目录

- `core/`：平台无关的 Rust 核心，通过稳定 C ABI 对外提供能力。
- `macos/`：SwiftUI/AppKit 客户端，负责文件授权、窗口、菜单与原生交互。
- `scripts/`：Xcode 调用的可重复构建脚本。
- `docs/`：代码侧架构决策与开发约束。

## 当前能力

- 使用 macOS 原生文档生命周期新建、打开和自动保存 `.md` / `.markdown`；
- 在单一 Markdown 源文本中进行系统原生撤销、重做与文本编辑；
- 由 Rust 核心验证 UTF-8，并保留已有文件的 UTF-8 BOM 与 LF/CRLF 风格；
- 对非 UTF-8 或混合换行文件拒绝写回，保护原文件不被猜测性转换。
- 在源码编辑、实时分栏预览和纯预览间切换，三种视图共用同一份当前源文本；
- 通过“显示”菜单或 `⌘1`、`⌘2`、`⌘3` 切换三种视图，命令只作用于当前文档窗口；
- 由 Rust 渲染 CommonMark、表格、脚注、删除线和任务列表，预览默认禁止脚本与网络请求。
- 由 Rust 生成 H1–H6 文档大纲与可呈现内容的字数/字符数，重复标题按源码范围精确定位；状态栏可切换统计口径或隐藏统计。
- 在当前文档中执行 Unicode 字面查找、多行查询/替换、大小写条件、环绕导航、逐项替换和全部替换；全部替换先展示完整影响，并可用一次撤销恢复。
- 从源码、实时预览或纯预览均可通过“⌘F”查找；纯预览会进入可定位源文本的实时预览，“⌥⌘F”“⌘G”与“⇧⌘G”分别用于查找替换、下一个和上一个匹配。
- 通过“格式 > 粗体/斜体/删除线”对当前选区添加或移除 Markdown 标记，粗体与斜体支持 `⌘B` / `⌘I`；空选区会插入可继续输入的模板，模糊的局部标记不会被猜测性改写。
- 通过“格式 > 标题 > 一级至六级标题”转换当前行或多行选区；混合级别统一为目标级别，全部已是目标级别时取消标题，Setext 标题会作为完整块安全转换。
- 通过“格式 > 引用”对当前行或多行选区添加/移除一层 `>`；连续引用作为完整语义块处理，嵌套层级、空行、代码围栏与撤销边界均保留。
- 通过“格式 > 列表 > 有序/无序/任务”统一或取消完整行的列表结构；混合标记会规范为目标类型，任务完成状态、缩进、空行、Unicode 光标与一次撤销均保留。
- 通过“格式 > 行内代码”添加或移除 CommonMark 代码跨度；核心会选择避开内容的反引号长度，并保留边界空格、Unicode 选区和可继续输入的空模板。
- 通过“格式 > 代码块”包裹或取消完整行的 CommonMark 围栏；反引号围栏至少为 3 个，且总是比内容中最长连续反引号多 1 个，空光标会插入可继续输入的块模板。
- 通过“文件 > 导出 HTML…”将发起时的精确 UTF-8 快照生成不超过 100 MiB 的自包含 HTML；资源、公式、Mermaid 或不安全链接未支持时会在写入前明确阻止。

## 构建

需要 Xcode 26 或兼容版本，以及 `rust-toolchain.toml` 指定的 Rust 工具链。

```sh
xcodebuild \
  -project Inflow.xcodeproj \
  -scheme Inflow \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Rust 核心的独立验证：

```sh
cargo fmt --manifest-path core/Cargo.toml --check
cargo clippy --manifest-path core/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path core/Cargo.toml --locked
```

## 提交规则

每个功能只在对应的 Rust 检查、单元测试与 macOS 构建通过后单独提交。
