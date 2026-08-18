# 扩展文档入口

本目录采用三层披露。先读能力边界，再根据问题进入系统设计或语法设计。

## 最小共识

- 没有任何扩展时，Inflow 必须完整可用。
- 扩展不能替换本地保存、撤销、恢复、冲突处理或 Core Parser。
- 第三方可执行代码不进入主进程。
- 普通扩展默认无网络；高权限连接器和远程 AI Provider 仅可限域联网。
- 所有文档修改都通过版本化、原子、可撤销文本事务。
- CLI、Shell、任意进程执行和完整 Git 客户端不属于扩展系统。

## 逐层阅读

### 第一层：能力边界

[扩展能力规范](./OVERVIEW.md)，用于回答：

- 哪些能力可以插件化？
- 哪些能力永不开放？
- 普通扩展和连接器有什么区别？
- 基本权限与开放顺序是什么？

大多数产品与插件需求评审读到这里即可。

### 第二层：平台实现

[扩展系统总体设计](./SYSTEM_DESIGN.md)，仅在涉及以下问题时读取：

- Extension Host、JavaScriptCore、XPC 和 Capability Broker。
- 包格式、Manifest、API、生命周期、配额和状态存储。
- 插件市场、签名、审核、撤回和更新。
- GitHub/云同步状态机、AI Provider 和 Prompt Injection 防护。
- SDK、DevKit、测试、安全和实施路线。

机器权威：

- 阶段/target：[PHASE_PROCESS_MATRIX.json](./PHASE_PROCESS_MATRIX.json)（[可读投影](./PHASE_PROCESS_MATRIX.md)）。
- listener/peer：[IPC_TRUST_MATRIX.json](./IPC_TRUST_MATRIX.json)。
- E3 市场固定端点、DNS/TLS 与预算：[MARKET_BROKER_POLICY.json](./MARKET_BROKER_POLICY.json)。
- E4 endpoint graph：[TYPED_ADAPTER_POLICIES.json](./TYPED_ADAPTER_POLICIES.json)。
- AI 模型/费用/内存：[AI_RUNTIME_MANIFEST.json](./AI_RUNTIME_MANIFEST.json)（[可读说明](./AI_RUNTIME_MANIFEST.md)）。
- 全局密钥权威：[../KEYCHAIN_POLICY.json](../KEYCHAIN_POLICY.json)；生态 target 映射：[EXTENSION_KEYCHAIN_PROJECTION.json](./EXTENSION_KEYCHAIN_PROJECTION.json)。
- Syntax/Content Tree/Market/Pack 等 closed schemas：[schemas/](./schemas/)；规则解释见对应设计章节。

### 第三层：Markdown 语法

[Markdown 语法扩展设计](./SYNTAX_EXTENSION_API.md)，只在涉及以下问题时读取：

- 围栏、块级指令、标准扩展节点或行内语法。
- AST、源码范围、渲染、降级和冲突。
- 即时渲染编辑的 round-trip。
- LaTeX、Academic Writing 或其他 Domain Pack。

## 产品方向

插件市场、AI、连接器和生态治理的产品理由与阶段见 [扩展生态战略](../../product/ECOSYSTEM_STRATEGY.md)。该文档不替代本目录中的安全和运行规则。

## 权威关系

1. `OVERVIEW.md` 决定能否开放某类能力。
2. `SYSTEM_DESIGN.md` 决定扩展如何安全运行。
3. `SYNTAX_EXTENSION_API.md` 决定新增 Markdown 语法如何解析和降级。
4. 上列 Markdown 解释机制；同一工程字段冲突时，以本页列出的 machine authority/schema 为准，Markdown 必须修正，不能手工覆盖 JSON。
5. 如与 Core 产品范围冲突，以 [PRD](../../product/PRD.md) 为准；PRD 不替代工程安全 Schema。
