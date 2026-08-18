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
| 核对本轮复审结论 | [前置产品复审处置台账](./FINAL_REVIEW_CLOSURE.md) | 各规范落点与证据 gate |

## 当前正式基线

- 产品基线：[PRD v2.1](./product/PRD.md)
- 复审定稿：[30 项处置台账](./FINAL_REVIEW_CLOSURE.md)（契约已闭环；T0 证据仍开放，T1 未授权）
- P0 决策状态：[P0 决策记录](./product/P0_DECISIONS.md)（当前仅授权继续 T0 原型验证，P0 未冻结）
- 工程基线：[产品技术方案 v1.1-final](./engineering/TECHNICAL_DESIGN.md)
- T0 工件：[Markdown 方言](./engineering/MARKDOWN_DIALECT_MANIFEST.md)、[Render](./engineering/RENDER_MANIFEST.md)、[Sanitizer](./engineering/SANITIZER_MANIFEST.md)、[Save/Recovery ADR](./engineering/SAVE_RECOVERY_ADR.md)、[Render Isolation ADR](./engineering/RENDER_HELPER_ISOLATION_ADR.md)、[PDF ADR](./engineering/PDF_PATH_ADR.md)
- 横切契约：[Settings Schema](./engineering/SETTINGS_SCHEMA.json)、[Data Protection](./engineering/DATA_PROTECTION_POLICY.md)、[Keychain Policy](./engineering/KEYCHAIN_POLICY.json)、[Logging Policy](./engineering/LOGGING_POLICY.json)、[Performance Manifest](./engineering/PERFORMANCE_MANIFEST.json)
- 需求追踪：[P0–P3 Requirement Traceability](./engineering/REQUIREMENT_TRACEABILITY.json)（68 个 feature/DoD ID；当前证据全部 OPEN）
- 发布/主题机器合同：[Release Manifest schema](./engineering/RELEASE_MANIFEST.schema.json)、[Theme Policy schema](./engineering/THEME_POLICY.schema.json)
- 扩展产品边界：[扩展能力规范](./engineering/extensions/OVERVIEW.md)
- 扩展实现基线：[扩展系统总体设计](./engineering/extensions/SYSTEM_DESIGN.md)
- E3 市场网络合同：[Market Broker Policy](./engineering/extensions/MARKET_BROKER_POLICY.json)（[Schema](./engineering/extensions/schemas/market-broker-policy-v1.schema.json)）

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
├── FINAL_REVIEW_CLOSURE.md
├── product/
│   ├── README.md
│   ├── PRD.md
│   ├── P0_DECISIONS.md
│   ├── TYPORA_BENCHMARK.md
│   ├── TYPORA_CAPABILITY_INVENTORY.json
│   ├── TYPORA_CAPABILITY_INVENTORY.schema.json
│   ├── TYPORA_CAPABILITY_INVENTORY.md
│   └── ECOSYSTEM_STRATEGY.md
└── engineering/
    ├── README.md
    ├── TECHNICAL_DESIGN.md
    ├── MARKDOWN_DIALECT_MANIFEST.md
    ├── RENDER_MANIFEST.md
    ├── SANITIZER_MANIFEST.md
    ├── SAVE_RECOVERY_ADR.md
    ├── RENDER_HELPER_ISOLATION_ADR.md
    ├── PDF_PATH_ADR.md
    ├── SETTINGS_SCHEMA.json
    ├── SETTINGS_SCHEMA.md
    ├── DATA_PROTECTION_POLICY.md
    ├── KEYCHAIN_POLICY.json
    ├── LOGGING_POLICY.json
    ├── LOGGING_POLICY.md
    ├── PERFORMANCE_MANIFEST.json
    ├── RECOVERY_JOURNAL_EVENT.schema.json
    ├── RENDER_MANIFEST.schema.json
    ├── SANITIZER_EVIDENCE.schema.json
    ├── REQUIREMENT_TRACEABILITY.json
    ├── REQUIREMENT_TRACEABILITY.schema.json
    ├── REQUIREMENT_TRACEABILITY.md
    ├── RELEASE_MANIFEST.schema.json
    ├── THEME_POLICY.schema.json
    └── extensions/
        ├── README.md
        ├── OVERVIEW.md
        ├── SYSTEM_DESIGN.md
        ├── PHASE_PROCESS_MATRIX.json
        ├── PHASE_PROCESS_MATRIX.md
        ├── IPC_TRUST_MATRIX.json
        ├── MARKET_BROKER_POLICY.json
        ├── TYPED_ADAPTER_POLICIES.json
        ├── AI_RUNTIME_MANIFEST.json
        ├── AI_RUNTIME_MANIFEST.md
        ├── EXTENSION_KEYCHAIN_PROJECTION.json
        ├── SYNTAX_EXTENSION_API.md
        └── schemas/
```
