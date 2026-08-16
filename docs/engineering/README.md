# 工程文档入口

本目录回答“如何实现、模块如何协作、怎样验证和发布”。

## Core 技术摘要

- AppKit `NSDocument` 管理文档生命周期，SwiftUI 承载产品界面。
- AppKit/TextKit 实现专业文本编辑，WKWebView 实现离线预览和 PDF。
- `swift-markdown` 提供 Core GFM AST，自研 Renderer 和 SourceMap 统一驱动预览、定位、同步及导出。
- 本地保存、Recovery、外部冲突和 Undo 独立于渲染与扩展。
- Phase 0 采用模块化单体；第三方扩展平台后续进入隔离 XPC 进程。

## 阅读路由

- Core 工程、数据流、存储、测试或发布：[产品技术方案](./TECHNICAL_DESIGN.md)
- 插件、SDK、语法、市场、同步或 AI：[扩展文档入口](./extensions/README.md)
- 功能范围存在疑问：[产品 PRD](../product/PRD.md)

## 工程阶段

1. T0：编辑器、Parser、WebView、NSDocument 和深色 PDF 风险原型。
2. T1–T3：完成并发布 P0 Core。
3. T4–T5：Typora 迁移能力和领先能力。
4. T6：扩展 Host、SDK、市场、AI 和连接器。

扩展文档描述的是 T6 目标架构。除接口预留外，不应提前把扩展复杂度引入 P0 Core。
