# Inflow 文档入口

本文档库采用渐进式披露：先读取当前页面，根据任务选择一个入口；只有遇到具体问题时才继续读取下一级文档。

## 项目一句话

Inflow 是仅支持 Apple Silicon 的原生 macOS Markdown 编辑器，离线和本地文件优先，以 Typora 的核心写作能力为基线，并为后续安全扩展、专业语法、同步和 AI 生态提供平台能力。

## 快速路由

| 当前任务 | 首先读取 | 必要时继续读取 |
| --- | --- | --- |
| 理解产品、功能和范围 | [产品文档入口](./product/README.md) | PRD、对标或生态战略 |
| 设计或实现 Core | [工程文档入口](./engineering/README.md) | 产品技术方案 |
| 设计插件或扩展 SDK | [扩展文档入口](./engineering/extensions/README.md) | 能力边界、系统设计或语法 API |
| 讨论 AI、同步和市场生态 | [扩展生态战略](./product/ECOSYSTEM_STRATEGY.md) | 扩展系统设计 |
| 查询最终产品决策 | [PRD](./product/PRD.md) | 对标路线、技术方案 |

## 当前正式基线

- 产品基线：[PRD v2.0](./product/PRD.md)
- 工程基线：[产品技术方案 v1.0](./engineering/TECHNICAL_DESIGN.md)
- 扩展产品边界：[扩展能力规范](./engineering/extensions/OVERVIEW.md)
- 扩展实现基线：[扩展系统总体设计](./engineering/extensions/SYSTEM_DESIGN.md)

## 已确认决策摘要

- 仅支持 Apple Silicon 和 macOS 14+。
- 暂不通过 Mac App Store 分发；使用 Developer ID 签名和 Apple 公证。
- Markdown 源码是唯一事实来源。
- Core 离线可用，本地保存不依赖插件、AI 或云端。
- PDF 在深色主题下保留深色背景。
- CLI、批处理和完整 Git 客户端不进入编辑器本体。
- 第三方可执行扩展运行在隔离进程中。
- AI、GitHub 和云同步属于用户主动安装的后续生态能力。

## AI 阅读约定

1. 默认只读取本入口和任务对应的下一级 README。
2. 产品问题不要先加载扩展系统实现细节。
3. Core 工程问题先读技术方案，只在涉及插件时进入扩展目录。
4. 扩展问题先读 `OVERVIEW.md`；只有架构、安全、运行时和市场问题才读 `SYSTEM_DESIGN.md`。
5. 语法、LaTeX 或 Domain Pack 问题只额外读取 `SYNTAX_EXTENSION_API.md`。
6. 文档冲突时，PRD 决定产品范围，技术方案决定 Core 实现，扩展系统设计决定插件运行规则。

## 目录

```text
docs/
├── README.md
├── product/
│   ├── README.md
│   ├── PRD.md
│   ├── TYPORA_BENCHMARK.md
│   └── ECOSYSTEM_STRATEGY.md
└── engineering/
    ├── README.md
    ├── TECHNICAL_DESIGN.md
    └── extensions/
        ├── README.md
        ├── OVERVIEW.md
        ├── SYSTEM_DESIGN.md
        └── SYNTAX_EXTENSION_API.md
```
