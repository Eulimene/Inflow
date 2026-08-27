# Inflow 0.1.0（1）本地首发候选记录

记录日期：2026-08-27（Asia/Shanghai）

源码提交：`c0fcf02c62c4`

候选类型：本地无签名 Archive，仅用于验收和签名前交接

## 构建环境

- macOS 26.4（25E246），Apple Silicon arm64
- Xcode 26.6（17F113）
- Rust / Cargo 1.96.0
- Deployment target：macOS 14.0
- App 版本：0.1.0（1）

本机环境高于最低支持的 macOS 14，因此本记录不能替代最低系统、8 GB 目标机上的性能与兼容性验收。

## 自动化证据

源码提交 `c0fcf02c62c4` 已通过：

- `scripts/verify-launch.sh --local`
- Rust `fmt`、Clippy `-D warnings` 与 150 / 150 单元测试
- macOS Debug 全量 XCTest 260 / 260，0 failed，0 skipped
- Debug Analyze
- Release 1 MiB / 10,000 行派生性能门禁
- Release Archive 的 arm64、macOS 14.0 最低版本、系统动态依赖、隐私清单、沙箱 entitlement、私有路径清理与 dSYM UUID 校验

另有 5 条跨层首发旅程测试，把文档解码、Rust 分析/渲染、本地资源、HTML/PDF 交付串联在同一份冻结源文快照上，避免只靠孤立单元测试宣称用户旅程成立。

## 候选产物

- Archive：`code/build/Inflow-0.1.0-1-local.xcarchive`（约 19 MiB）
- 压缩交接包：`code/build/Inflow-0.1.0-1-local.xcarchive.zip`（约 7.2 MiB）
- ZIP SHA-256：`ecdcf70103c27fcd7338e762315ab131bead0982efc82643fbf0107b4f643f66`
- dSYM UUID：`694FD943-F7D6-397B-8DD3-8A3B8494923E`（arm64）

压缩包已通过 `unzip -t`；Archive 已通过：

```sh
scripts/verify-release-archive.sh --local \
  build/Inflow-0.1.0-1-local.xcarchive
```

不带 `--local` 的严格校验会以 `archived app is not validly distribution signed` 拒绝该 Archive，证明无签名候选不会被误认为分发包。

`code/build/` 为本地忽略目录，候选二进制不进入 Git；跨机器交接时必须先复核上面的 SHA-256。

## 尚未放行的外部条件

以下事项不由仓库代码或本地无签名构建单方面完成，本候选不宣称它们已经通过：

1. 产品负责人批准仍标为“待评审”的首发范围、文案和验收标准。
2. 在入门 Apple Silicon、8 GB、macOS 14 目标机记录冷启动、打开、视图切换、输入停顿和预览更新的中位、最长与 95 分位结果。
3. 用物理键盘、中文输入法、VoiceOver、系统放大、高对比和减少动态效果执行候选包旅程。
4. 配置并审查受控匿名数据 HTTPS 服务及服务端保留策略；完成前客户端保持不可开启。
5. 使用选定渠道的 Developer ID 或商店身份签名，完成 notarization / 渠道验证，并运行严格发布门禁。

只有以上外部条件全部完成并记录后，才能把本地候选升级为可公开分发的正式发布包。
