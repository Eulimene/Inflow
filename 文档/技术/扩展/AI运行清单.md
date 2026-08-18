# AI Runtime Manifest（E4）

- 文档版本：v2
- 更新日期：2026-08-18
- 契约状态：Accepted
- 运行证据：OPEN（不表示 E4 已授权）
- 机器权威：[AI运行清单.json](./AI运行清单.json)
- Schema：[AI运行清单第二版模式.json](./数据模式/AI运行清单第二版模式.json)

本页是机器权威的可读说明。Release CI 必须验证 Companion targets、entitlements、内存常量、
ModelStore ownership、成本 ledger 和 IPC edge；实现与 JSON 不一致即阻断 E4。

## 1. Immutable ModelStore

`AI Model Manager` 只拥有下载 staging 和固定模型源网络策略，不拥有已发布 store。独立、禁网且
无 Keychain 的 `AIModelStore.xpc` 才是 versioned SHA-256 CAS owner。发布事务为：Manager 提交
只读 staging FD、签名 metadata 和 expected hash；Store 不按路径重开，独立校验 publisher signature、
license、format/architecture、size 与全量 hash，复制进 store-owned private staging，fsync 文件与父
目录后按 `{modelID, version, sha256}` 原子发布。发布完成后 Manager 对 inode、目录和 namespace 均无
写权；仅设置 0444 不是不可变性证据。

Worker 只取得有 expiry 的只读 FD lease、manifest hash、resource identity、size 和 store generation，
在 mmap 前复核，绝不按路径重开。升级先并存验证，健康检查失败回滚到上一已发布 generation；GC
仅在无 lease/reference 时删除。模型替换、FD identity mismatch 或 hash mismatch 均 fail closed。

## 2. 明文结果所有权

本地 Worker 和远程 `NetworkCredentialBroker` 只通过 authenticated、bounded、one-shot response
stream 把 token/bytes 写入 Core-owned sink。Inflow Core 是唯一 AI response plaintext owner，负责
增量大小/编码校验、结构化解析、Prompt Injection 标记、`Suggestion/TextPatch/NewDraft/Diagnostics/
ToolProposal` 判别、diff 生成和用户确认。Provider Host、Broker、Model Manager 与 ModelStore 不得
持久化 response、prompt 或 diff，也不能把“已解析 patch”作为受信结果交给 Core。

## 3. 全局费用事务

Core-owned `AICostLedger` 是跨窗口、跨文档、跨本地/远程请求的单一 actor。每个 request 必须先用
`requestID` 原子 `reserve(worstCaseTokens, worstCaseCost, budgetGeneration)`；余额不足时不发送任何
字节。完成后按供应商 receipt/实际 token `settle`，取消或启动失败 `release`；重复 settle/release
幂等，进程崩溃后从 durable reservation 恢复并对账。Provider 报价、用户预算或模型变化提升
`budgetGeneration`，旧 reservation 不得转用。价格未知时逐次确认且禁用自动连续请求。

请求仍必须设置实际 `max_tokens`，取模型、用户和 Core 最小值且默认不超过 4,096。取消会关闭
upload/download、调用已声明 cancel endpoint，并忽略晚到 UI token；供应商仍可能计费的事实进入
settlement 和审计，不以“用户已取消”伪造零费用。

## 4. 内存与设备准入

固定 8 GiB Worker 上限已删除。单 Worker hard ceiling 同时受以下三项约束：物理内存 30%、绝对
6 GiB、以及 AI 全进程不超过物理内存 35%；Core/system 至少保留 4 GiB。模型 manifest 必须给出
weights、KV cache、runtime scratch 和输出 buffer 的 peak estimate，乘 1.25 safety factor 后全部
满足才可启用；不满足时模型显示“此设备不可用”，不能尝试后 OOM。8 GB 设备因此不会获得 8 GiB
Worker，较大模型可以另外声明最低 16 GB 设备。

默认最多一个 active Worker。memory pressure 依次取消请求、卸载模型、拒绝新请求；任何阶段都不
挤占 Core save/recovery headroom。Supervisor 按整棵进程树统计 RSS/CPU，越界强杀并保留结构化原因。

## 5. 分发、网络与测试门槛

E4 只允许官方审核的 Companion、AI Action 和已有
[Typed Adapter Policy](./类型化适配器策略.json) 的远程 adapter；未在 catalog 声明的 adapter
默认 disabled。第三方 Provider/Tool 到 E5，开发者模式只使用合成无敏感 fixture。Keychain 与 AI
session/state 执行 [全局 Keychain Policy](../核心/钥匙串策略.json) 及其
[生态 target 投影](./扩展钥匙串映射.json)。

E4 corpus 必须覆盖：CAS 发布后替换、FD/inode 重用、hash mismatch、磁盘满、升级回滚、lease/GC
竞态、8/16/32 GB 设备准入、OOM/pressure、跨窗口预算竞争、reserve 后崩溃、重复 receipt、取消与
晚到响应、token/cost cap，以及文档/远端/模型响应中的 Prompt Injection。任何一项缺机器证据即不
开放对应 AI 能力。
