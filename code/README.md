# Inflow 开发基线

Inflow 是一款本地优先的 Markdown 写作工作台。首发客户端支持 macOS 14 及更高版本，并仅支持 Apple Silicon。

## 目录

- `core/`：平台无关的 Rust 核心，通过稳定 C ABI 对外提供能力。
- `macos/`：SwiftUI/AppKit 客户端，负责文件授权、窗口、菜单与原生交互。
- `scripts/`：Xcode 调用的可重复构建脚本。
- `docs/`：代码侧架构决策与开发约束。

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
