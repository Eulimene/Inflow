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
- 由 Rust 渲染 CommonMark、表格、脚注、删除线和任务列表，预览默认禁止脚本与网络请求。
- 由 Rust 生成 H1–H6 文档大纲与可呈现内容的字数/字符数，重复标题按源码范围精确定位；状态栏可切换统计口径或隐藏统计。
- 在当前文档中执行 Unicode 字面查找、多行查询/替换、大小写条件、环绕导航、逐项替换和全部替换；全部替换先展示完整影响，并可用一次撤销恢复。
- 从源码、实时预览或纯预览均可通过“⌘F”查找；纯预览会进入可定位源文本的实时预览，“⌥⌘F”“⌘G”与“⇧⌘G”分别用于查找替换、下一个和上一个匹配。

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
