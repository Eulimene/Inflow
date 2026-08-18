# 产品文档入口

本目录回答“为谁做、做什么、为什么做、哪些暂时不做”。一般产品讨论只需读取本页和 PRD。

## 产品摘要

Inflow 是原生、离线优先的专业 macOS Markdown 编辑器。Core 聚焦写作、阅读、本地文件、可靠保存和单篇交付；生态通过可选扩展提供专业语法、AI、GitHub 和云同步。

## 阅读顺序

1. [PRD](./PRD.md)：产品范围、交互、设置、验收和已确认发布决策。所有产品任务优先读取。
2. [P0 决策记录](./P0_DECISIONS.md)：开发前冻结事项及其规范位置。
3. [Typora 对标与差异化路线](./TYPORA_BENCHMARK.md)：需要判断能力差距、版本优先级或竞争策略时读取。
4. [Typora Capability Inventory JSON](./TYPORA_CAPABILITY_INVENTORY.json)：具体对标证据、PRD 封闭世界覆盖、requirement ID、corpus/操作样本登记、owner、状态与 exception ledger 的机器权威源；[JSON Schema](./TYPORA_CAPABILITY_INVENTORY.schema.json) 冻结结构约束，[Markdown 视图](./TYPORA_CAPABILITY_INVENTORY.md) 仅由生成器产出、用于人工阅读。
5. [扩展生态战略](./ECOSYSTEM_STRATEGY.md)：讨论插件市场、AI、连接器、商业和生态治理时读取。

不要为了普通编辑器需求读取完整扩展系统设计；扩展的产品边界和技术实现位于 [扩展文档入口](../engineering/extensions/README.md)。

## 文档权威关系

- PRD 是产品语义、稳定 requirement ID、P0–P3 范围和 DoD 的最高基线。
- 对标路线解释为什么以及分阶段顺序，不能自动扩大 PRD 的当前版本范围。
- Inventory JSON 是 Typora 能力证据和对齐状态的机器权威源，但只能引用 PRD requirement ID，不能定义产品阶段。
- 生态战略描述长期平台方向，不代表进入首发版本。
- 实现可行性和工程顺序以 [产品技术方案](../engineering/TECHNICAL_DESIGN.md) 为准。

## Typora Inventory 维护

只编辑 JSON 权威源，不直接编辑 Markdown 阅读视图。更新后在仓库根目录执行：

```sh
python3 scripts/generate_typora_inventory_view.py
python3 scripts/generate_typora_inventory_view.py --check
python3 scripts/generate_typora_inventory_view.py --self-test
python3 scripts/validate_docs.py
```

三层门禁职责分开：生成器校验 PRD 与 Benchmark 闭集、双向引用、状态/证据和 schema 派生的顶层/category 约束；`--self-test` 以纯内存负例确认 shape、category、coverage、过早 `frozen` 和 OS/architecture 不一致会失败；仓库统一 `validate_docs.py` 实际执行 JSON Schema、跨权威引用、生成视图和链接校验。`aligned` 只能引用 Registry 中 OS、architecture、build 和 settings profile 一致且结果为 `passed` 的非全零 SHA-256 corpus/操作样本。当前 `evidence_baseline` 没有伪造 corpus 或 `aligned` 状态。
