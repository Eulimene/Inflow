# Typora Capability Inventory

- inventoryVersion：1
- 状态：Draft；P1/P2 排期前冻结具体 build 与 corpus hash
- 用途：对标证据的机器可读事实来源；版本归属仍只在 PRD

每条能力必须导出为 JSON/CSV，字段固定为：`capabilityID, category, typoraPlatform, typoraBuild, settingsProfile, officialEvidenceURL, corpusIDs, operationSampleIDs, expectedBehavior, inflowPath, owner, status, exceptionID`。测试平台固定 Apple Silicon 与 PRD 支持的 macOS；Typora build、设置导出和测试日期不得留空。

## 必须覆盖的差距

| Capability | Typora 证据/行为 | Inflow 等价路径或例外 |
| --- | --- | --- |
| Mermaid/sequence/flow 围栏 | Typora 官方 diagram 文档与冻结 fixture | Mermaid 由 Core；`sequence`/`flow` 由迁移兼容 renderer 或公开 exception，不能默认为已对齐 |
| 普通 HTML/媒体/iframe | Typora HTML 文档与安全设置 profile | P1 结构化 allowlist；脚本、任意 iframe/媒体网络能力列入安全 exception ledger |
| Pandoc 导入/多格式导出 | Typora Export/Markdown Reference | 独立签名 Converter Companion/生态工具提供可发现的迁移路径；不打包进 Core，CLI 是明确 exception |
| 编辑/文件/工作区/主题 | 官方文档 + Top 30 操作样本 | 对应 Core 路径与版本验收 |

## 语料与比较方法

- Migration Corpus 至少包含官方规范样例、真实 README/技术文档/中文长文、公式/图表/HTML、资源路径与恶意负例；每个 fixture 记录来源许可和 SHA-256。
- “无需修改”指原 Markdown 字节不变即可完成目标阅读/编辑任务；允许视觉抗锯齿差异，不允许结构、文本、链接目标、公式或图表语义差异。
- 渲染比较使用 DOM/语义树断言加固定环境截图；操作比较使用录制任务步骤、成功条件与耗时。Top 30 来源必须记录匿名研究样本、样本数、统计期和选择方法，不能由团队主观挑选。
- Exception Ledger 公开记录能力、原因（安全/平台/产品边界）、替代路径、用户影响和是否永久。任意脚本、CLI、完整 Git 工作台等不能计作已对齐。

P2 DoD：Inventory 无无主/无证据条目；非 exception 能力全部通过，95% corpus 无需修改，Top 30 任务完成率 ≥90%。
