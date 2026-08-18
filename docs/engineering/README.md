# 工程文档入口

本目录回答“如何实现、模块如何协作、怎样验证和发布”。

## Core 技术摘要

- AppKit `NSDocument` 管理文档生命周期，SwiftUI 承载产品界面。
- AppKit/TextKit 实现专业文本编辑，WKWebView 实现离线预览和 PDF。
- `swift-markdown` 提供 Core GFM AST，自研 Renderer 和 SourceMap 统一驱动预览、定位、同步及导出。
- 本地保存、Recovery、外部冲突和 Undo 独立于渲染与扩展。
- P0 采用模块化单体；第三方扩展平台在 E0–E5 进入隔离 XPC 进程。

## 阅读路由

- [Markdown 方言 Manifest](./MARKDOWN_DIALECT_MANIFEST.md)：P0 Parser 事实来源、options 与偏差表。
- [Sanitizer Manifest](./SANITIZER_MANIFEST.md)：P0 HTML/URL 清洗规则与冻结门槛。
- [Render Manifest](./RENDER_MANIFEST.md)：渲染依赖、golden 环境与输出一致性。
- [Save/Recovery ADR](./SAVE_RECOVERY_ADR.md)：SaveEnvelope、身份与故障矩阵。
- [Render Isolation ADR](./RENDER_HELPER_ISOLATION_ADR.md) 与 [PDF Path ADR](./PDF_PATH_ADR.md)：T0 条件实现路径。
- [Settings machine source](./SETTINGS_SCHEMA.json)（[说明](./SETTINGS_SCHEMA.md)）与 [Data Protection Policy](./DATA_PROTECTION_POLICY.md)：横切状态和静态加密契约。
- [Recovery event schema](./RECOVERY_JOURNAL_EVENT.schema.json)、[Keychain Policy](./KEYCHAIN_POLICY.json)、[Logging Policy](./LOGGING_POLICY.json) 与 [Performance Manifest](./PERFORMANCE_MANIFEST.json)：恢复、密钥、日志和全局资源机器权威。
- [Render Manifest schema](./RENDER_MANIFEST.schema.json)、[Sanitizer evidence schema](./SANITIZER_EVIDENCE.schema.json)、[Release Manifest schema](./RELEASE_MANIFEST.schema.json) 与 [Theme Policy schema](./THEME_POLICY.schema.json)：构建证据、发布及后续主题包合同。
- [P0–P3 Requirement Traceability](./REQUIREMENT_TRACEABILITY.json)（[Schema](./REQUIREMENT_TRACEABILITY.schema.json)、[校验说明](./REQUIREMENT_TRACEABILITY.md)）：PRD 全部 68 个 feature/DoD ID 到 owner、T0–T6 阶段和精确 fixture group 的 closed-world 机器映射。当前全部证据状态为 `OPEN`，不构成阶段通过。

- Core 工程、数据流、存储、测试或发布：[产品技术方案](./TECHNICAL_DESIGN.md)
- 插件、SDK、语法、市场、同步或 AI：[扩展文档入口](./extensions/README.md)
- 功能范围存在疑问：[产品 PRD](../product/PRD.md)

## 工程阶段

1. T0：编辑器、Parser、WebView、NSDocument 和深色 PDF 风险原型。
2. T1–T3：完成并发布 P0 Core。
3. T4–T5：Typora 迁移能力和领先能力。
4. T6：扩展 Host、SDK、市场、AI 和连接器。

扩展文档描述的是 T6 目标架构。除接口预留外，不应提前把扩展复杂度引入 P0 Core。

本轮 30 项前置意见的方案选择、规范落点和证据状态统一记录在 [前置产品复审处置台账](../FINAL_REVIEW_CLOSURE.md)。“契约已定稿”不代表 T0 已完成；真实 Release hash、PID/entitlement、故障注入、性能和 PDF postflight 证据仍须按 T0 退出矩阵生成。
