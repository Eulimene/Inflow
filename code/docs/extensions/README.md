# Inflow 扩展架构总览

> 状态：设计草案，尚未实现
>
> 适用阶段：专业版与成熟版；不属于当前个人首版
>
> 更新日期：2026-08-30

本目录定义 Inflow 扩展能力进入实现前必须满足的运行时、语法、联网、市场和数据生命周期合同。它不扩大产品版本范围，也不把设计文档当成构建证据；产品范围仍以 `文档/01-产品设计/` 为准。

## 1. 分阶段路线

| 阶段 | 可用能力 | 明确不开放 | 进入条件 |
| --- | --- | --- | --- |
| E0 首发版 | 无扩展运行时 | 插件安装、第三方代码、联网能力 | 首发基础产品独立闭环 |
| E1 专业版能力中心 | 官方签名、免费、低风险能力；外观、只读诊断和用户确认后的单次文本建议 | 公开上架、插件间依赖、直接文件/网络访问、付费 | 包验证、受限运行时、权限与失败降级证据 |
| E2 领域能力 | 命名空间 directive/fenced block、受限内容树、官方 Academic Pack | 任意 HTML/SVG/CSS、任意 parser 注入、完整 `.tex` 工程 | Syntax API v1 与正反语料冻结 |
| E3 免费公开市场 | 第三方免费插件、发布者提交、审核、签名撤回 | Inflow 收款、订阅、评价和恢复购买 | 发布者身份、包供应链、撤回与投诉闭环 |
| E4 高信任能力 | 用户主动的 AI 文本建议、单向发布或获取候选副本 | AI 工具调用、后台双向同步、无法封顶的付费请求 | 独立高信任宿主、费用协议与数据矩阵通过 |
| E5 商业与双向服务 | 可选生态账号、交易/评价、经验证的同步协议 | 以账号或联网作为基础编辑前提 | 独立商业、同步和合规评审 |

后续阶段不得让早期插件自动获得新权限。任何阶段失败时，Markdown 编辑、保存、恢复和本地交付必须继续可用。

## 2. 架构选择

- 普通插件使用随应用锁定版本的 WebAssembly 运行时和 Core 定义的声明式界面/内容树；不提供 WASI、POSIX、动态库加载、直接文件或直接网络能力。
- 每个插件在独立、可终止的宿主进程中运行。宿主无用户文件、网络、Keychain、打印、相机、麦克风或通讯录权限。
- Core 持有 Markdown 字节、文档生命周期、撤销、保存和冲突裁决。插件只接收任务所需的不可变快照或选区，并返回受限结果。
- 文件、网络、账号、费用和外部副作用只能通过 Core 管理的能力代理；首个普通插件版本不开放这些代理。
- 官方高信任 AI/连接器使用独立签名 XPC 宿主，不与普通插件宿主共享进程、凭据或明文正文。
- v1 不支持插件之间的运行时依赖。领域包由市场发布记录固定每个组件的精确版本和摘要。

## 3. 文档索引

- [包、运行时与能力代理](./包与运行时.md)
- [语法扩展 API](./语法扩展接口.md)
- [人工智能与连接器](./人工智能与连接器.md)
- [市场、账号与安全撤回](./市场与撤回.md)
- [生态数据生命周期矩阵](./数据生命周期矩阵.md)
- [扩展验证门禁](./验证门禁.md)
- [扩展清单 v1 机器 Schema](../../quality/extensions/extension-manifest-v1.schema.json)（机器校验文件，与本目录的人读设计分开管理）
- [清单能力集 v1 机器 Schema](../../quality/extensions/manifest-capability-set-v1.schema.json)
- [市场发布记录 v1 机器 Schema](../../quality/extensions/market-release-record-v1.schema.json)
- [领域包发布记录 v1 机器 Schema](../../quality/extensions/domain-pack-release-record-v1.schema.json)
- [声明式内容树 v1 机器 Schema](../../quality/extensions/extension-content-tree-v1.schema.json)
- [语法 API v1 机器 Schema](../../quality/extensions/syntax-api-v1.schema.json)
- [语法属性策略 v1 机器 Schema](../../quality/extensions/syntax-attribute-policy-v1.schema.json)
- [语法 EBNF 与正反语料](../../quality/extensions/syntax-extension-v1.ebnf)、[语法语料清单](../../quality/extensions/syntax-extension-corpus-v1.json)
- [撤回清单 v1 机器 Schema](../../quality/extensions/revocation-manifest-v1.schema.json)
- [扩展合同负面语料 v1](../../quality/extensions/extension-contract-negative-corpus-v1.json)

八份 JSON Schema 与配套 EBNF/corpus 都位于 `code/quality/extensions/`，不作为人读设计正文。机器合同只能冻结结构与预期语义；签名、摘要、单调序列、发布者身份、精确组件解析和真实运行结果仍须由发布验证器与阶段门禁证明。

## 4. 不可越过的边界

1. 插件不能成为 Markdown 内容事实或保存状态所有者。
2. 安装不等于授权，登录不等于文件访问，购买不等于启用。
3. 插件输出必须在应用前可预览；文本修改进入 Core 的单次撤销事务。
4. 任意 HTML、SVG、CSS、脚本、二进制附件或系统路径都不能作为普通插件的直接渲染输出。
5. 未安装、停用、撤回或运行失败时，源 Markdown 必须保留且可读。
6. 只有真实构建、负面语料、进程归属和故障注入通过后，设计状态才能转为实现证据。

## 5. 当前证据状态

本目录全部证据状态为 `OPEN`。当前代码库没有扩展目标、SDK、市场服务、AI 提供方或连接器实现，因此不得在首发验收矩阵中标记为已完成。

可执行的设计合同回归使用 `code/scripts/verify-extension-contracts.sh`。它验证 JCS 预映像、反向域名标识、完整 SemVer 2.0.0 与仅允许三段发布版的 host compatibility version、跨数组集合相等、属性策略绑定和撤回替代记录的正负 fixture；通过只证明冻结合同与 oracle 自洽，不会把任何 E1–E5 实现门禁改为 `PASSED`。
