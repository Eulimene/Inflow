# Inflow 前置产品复审处置台账

- 台账版本：v1.1-final
- 定稿日期：2026-08-19
- 复审基线：Git HEAD `93b065a849e2288d9d03d94211cbc1b64dd9d122`
- 结论：30 项前置意见均已选择唯一方案并写入规范；T0 构建/运行证据仍开放，T1 未授权

## 1. 状态口径

- **契约已闭环**：产品语义、唯一执行路径、失败分支、权威源和阶段 gate 已无待选方案。它不等于实现或测试已经完成。
- **OPEN — T0 evidence**：必须由真实原型、Release 构建、fixture/corpus、PID/entitlement 或 hash 产物关闭；文档或 placeholder 不能代替。
- **OPEN — delivery evidence**：契约已定稿，但要到 P0/P1/P2/P3 或 E1–E4 对应候选版才能验收。
- **Rejected**：不得作为普通 fallback；重新提出必须新建 ADR 并给出推翻当前决策的新证据。

产品范围与 DoD 只由带 `INF-*` requirement ID 的 [PRD](./product/PRD.md) 定义；机器 key/schema/manifest 定义可执行格式；[技术方案](./engineering/TECHNICAL_DESIGN.md) 与专项 ADR 只定义实现和证据映射。

## 2. T0 退出前意见（1–16）

| # | 最终处置 | 规范落点 | 证据状态 |
| --- | --- | --- | --- |
| 1 | 采用 A：`NSDocument.save(to:ofType:for:completionHandler:)` 是唯一外层入口；one-shot、线程安全 `CommitContext` + re-entry token；磁盘成功而 journal fsync 失败进入 `diskCommittedJournalPending`，不得混入自管 writer | [Technical Design §11.2](./engineering/TECHNICAL_DESIGN.md)、[Save/Recovery ADR](./engineering/SAVE_RECOVERY_ADR.md) | OPEN — T0 evidence |
| 2 | 采用 A：Recovery head/pending-save 保护槽不计历史配额；Keychain 锁定/丢失、store 损坏或 ENOSPC 时显式降级，旧 key 密文隔离并在可用时轮换新 key；用户 `.md` 保存永不被 Recovery 反向阻断 | [Technical Design §11.2/11.4](./engineering/TECHNICAL_DESIGN.md)、[Data Protection Policy](./engineering/DATA_PROTECTION_POLICY.md) | OPEN — T0 fault matrix |
| 3 | 采用 A：固定 `sessions/<documentID>/<epoch>.journal`，epoch 内 segment/checkpoint，discriminated event schema；handoff 为新 epoch `pending → active`、旧 epoch `active → consumed`，`activate` 是唯一资格切换点 | [Technical Design §11.4](./engineering/TECHNICAL_DESIGN.md)、[Recovery Journal schema](./engineering/RECOVERY_JOURNAL_EVENT.schema.json) | OPEN — crash-point replay |
| 4 | 采用 A：PRD 只管设置语义，Schema 管 key/type/default/range/migration；首次 `split`，随后新窗口用 `app.lastUsedMode`；补齐文件打开方式、字号 12–28、语法高亮/滚动同步/标题点击独立开关 | [PRD §6](./product/PRD.md)、[Settings machine source](./engineering/SETTINGS_SCHEMA.json)、[Settings guide](./engineering/SETTINGS_SCHEMA.md) | OPEN — implementation/migration tests |
| 5 | 采用 A：`headingText → DOM ID` 与 `rawFragment → decode once/NFC → exact existing ID` 为两个接口，fragment 永不再 slug 或二次解码 | [PRD §5.14](./product/PRD.md)、[Technical Design §14.1](./engineering/TECHNICAL_DESIGN.md)、[Sanitizer Manifest](./engineering/SANITIZER_MANIFEST.md) | OPEN — slug/fragment oracle |
| 6 | 采用 A：RenderSupervisor 启动一次性、非 WebKit JS runtime + 最小 DOM shim worker，每 job 独占进程并整树计量/强杀；具体 runtime 由 T0 真版本/hash 证据冻结，依赖 `WKProcessPool` 的路径 B 为 Rejected | [Technical Design §9.3](./engineering/TECHNICAL_DESIGN.md)、[Render Helper Isolation ADR](./engineering/RENDER_HELPER_ISOLATION_ADR.md) | OPEN — D05 Reopened |
| 7 | 采用 A：P0 渲染正文/中间结果不进入命名 temp，只能在内存或创建后立即 unlink 的受限 FD；最终导出 staging 与 render scratch 分离 | [Technical Design §4.3](./engineering/TECHNICAL_DESIGN.md)、[Data Protection Policy](./engineering/DATA_PROTECTION_POLICY.md) | OPEN — plaintext canary |
| 8 | 采用 A：Markdown/PNG/JPEG/PDF 只消费已验证 FD，或从该 FD 建 app-owned immutable clone；其他类型 P0 只 Finder reveal。未来新增类型须有新版机器 Policy，并在再次确认后从重新验证的 FD 生成 clone | [PRD §5.14](./product/PRD.md)、[Technical Design §14.1](./engineering/TECHNICAL_DESIGN.md)、[Sanitizer Manifest](./engineering/SANITIZER_MANIFEST.md) | OPEN — TOCTOU corpus |
| 9 | 采用 A：在 coordinated target guard/原生写入前建立 `pendingSaveNonce` 与 `SelfWriteGuard`；通知先缓冲，postflight 后只精确消费 identity/revision/hash 全匹配事件 | [Technical Design §11.2/11.5](./engineering/TECHNICAL_DESIGN.md)、[Save/Recovery ADR](./engineering/SAVE_RECOVERY_ADR.md) | OPEN — presenter race fixture |
| 10 | 采用 A：全局 DocumentRegistry 同时锁 canonical URL/resource identity；alias 明确 active/retired；Save As 计划绑定 source version、源/目标目录和每条相关引用的存在性/resource identity/revision expectation，guard 前逐项重验，任一相关文件变化即重新分析确认 | [PRD §5.1.3](./product/PRD.md)、[Technical Design §6.2/11.2](./engineering/TECHNICAL_DESIGN.md) | OPEN — Save As race matrix |
| 11 | 采用 A：只有 named、writable、目标存在且无冲突/元数据待修复时才能 file autosave；未命名文档只进 Recovery，直到用户主动首次保存 | [PRD §5.8](./product/PRD.md)、[Technical Design §11.3](./engineering/TECHNICAL_DESIGN.md) | OPEN — close/autosave matrix |
| 12 | 采用 A：open/save/reload/revert 统一 `adoptCommittedBase`；reload/revert 替换正文后清空 Undo、range cache、diagnostics 并换 generation，普通 save 不清 Undo | [PRD §5.1.5](./product/PRD.md)、[Technical Design §11.5](./engineering/TECHNICAL_DESIGN.md) | OPEN — reload/revert tests |
| 13 | 采用 A：Release 构建生成版本化 manifest、资源/allowlist/golden/corpus hash，CI 从源重算并拒绝 placeholder、空集合和 hash 漂移；CodeResources 仅第二层 | [Technical Design T0 matrix](./engineering/TECHNICAL_DESIGN.md)、[Render Manifest](./engineering/RENDER_MANIFEST.md)、[Sanitizer evidence schema](./engineering/SANITIZER_EVIDENCE.schema.json) | OPEN — build-derived hashes absent |
| 14 | 采用 A：P0 首选 `WKWebView.createPDF` 并强制 PDF postflight；Core 中的 `NSPrintOperation` fallback 被移除，只有新隔离 Print-helper ADR 可重新提出 | [PRD §5.12](./product/PRD.md)、[Technical Design §15.3](./engineering/TECHNICAL_DESIGN.md)、[PDF Path ADR](./engineering/PDF_PATH_ADR.md) | OPEN — D07 Conditional |
| 15 | 采用 A：统一 ResourceGovernor 为 Render/Image/Export/AI helper 发全局 lease，整树汇总 RSS/CPU/时间/输出；每文档 token bucket、公平轮转、generation 取消与 memory-pressure headroom | [Technical Design §9.3/19/23.5](./engineering/TECHNICAL_DESIGN.md)、[Performance Manifest](./engineering/PERFORMANCE_MANIFEST.json) | OPEN — T0 performance evidence |
| 16 | 采用 A：P0 签名单调 ReleaseManifest、漏洞 gate、SBOM、build provenance、最低安全版本与不可覆盖撤回；手动下载不豁免供应链校验 | [Technical Design §24](./engineering/TECHNICAL_DESIGN.md)、[Release Manifest schema](./engineering/RELEASE_MANIFEST.schema.json) | OPEN — P0 release evidence |

## 3. 后续产品阶段意见（17–20）

| # | 最终处置 | 规范落点 | 证据状态 |
| --- | --- | --- | --- |
| 17 | 采用 A：导出捕获 `ExportEnvelope { exactSource, documentVersion, sourceHash, profile }` 并独立解析；目标 expectation 为 `absent | exactRevision`，变化后废弃 staging 并重新确认 | [PRD §5.12](./product/PRD.md)、[Technical Design §15](./engineering/TECHNICAL_DESIGN.md) | OPEN — delivery evidence |
| 18 | 采用 A：PRD 新增稳定 `INF-P0-*`…`INF-P3-*` requirement/DoD ID 和 P1–P3 累积 DoD；技术文档仅映射证据，closed-world 追踪表覆盖全部 68 个 feature/DoD ID 且当前均为 OPEN | [PRD §11–12](./product/PRD.md)、[Requirement Traceability](./engineering/REQUIREMENT_TRACEABILITY.json)、[Traceability schema](./engineering/REQUIREMENT_TRACEABILITY.schema.json)、[Technical Design §25](./engineering/TECHNICAL_DESIGN.md) | 契约已闭环；按各候选版验收 |
| 19 | 采用 A：P1/E1 只允许 design token；P2 才允许机器 ThemePolicy 约束的声明式主题包，字体走隔离解码；任意 CSS/URL/`@import` 为公开 exception | [PRD P1/P2](./product/PRD.md)、[Typora Benchmark](./product/TYPORA_BENCHMARK.md)、[Theme Policy schema](./engineering/THEME_POLICY.schema.json) | OPEN — P2 evidence |
| 20 | 采用 A：Inventory JSON + JSON Schema 是机器事实源，Markdown 为确定性生成视图；29 个 PRD feature 由 23 条 mapping + 6 条显式 exclusion 闭集覆盖，40 个 Benchmark capability 全部反向入表；条目绑定 requirement ID、Typora build/platform、证据 URL/日期、owner、状态与 exception | [Inventory JSON](./product/TYPORA_CAPABILITY_INVENTORY.json)、[Inventory schema](./product/TYPORA_CAPABILITY_INVENTORY.schema.json)、[Inventory generated view](./product/TYPORA_CAPABILITY_INVENTORY.md) | evidence baseline 已建立；registry 仍为 0/0、`aligned` 为 0，测量证据保持 OPEN |

## 4. 扩展生态意见（21–30）

| # | 最终处置 | 规范落点 | 证据状态 |
| --- | --- | --- | --- |
| 21 | 采用 A：每扩展独立 launcher/client 与 Host realm；全部 XPC listener 校验 designated requirement、audit token、UID/session、nonce、request hash、expiry、counter/replay；payload 禁止自报 `extensionID` 等身份字段，只使用 connection-bound opaque handle | [Extension System Design](./engineering/extensions/SYSTEM_DESIGN.md)、[IPC Trust Matrix](./engineering/extensions/IPC_TRUST_MATRIX.json) | OPEN — E1 process/IPC evidence |
| 22 | 采用 A：一次性 PackageVerifier 无 key/Trust Store/安装目录写权，从私有 FD/CAS 验证；Manager 移动前再次 hash | [Extension System Design §3.2.1/9.1](./engineering/extensions/SYSTEM_DESIGN.md)、[Verification receipt schema](./engineering/extensions/schemas/package-verification-receipt-v1.schema.json) | OPEN — E1 adversarial packages |
| 23 | 短期采用 B：E2 stable v1 只开放 fenced/block directive；inline/完整 academic syntax 进入 v2；v1 已冻结 delimiter、缩进、嵌套、escape、属性、错误恢复与 CommonMark 优先级，schema 对齐 reference/semantic 字段 | [Syntax Extension API](./engineering/extensions/SYNTAX_EXTENSION_API.md)、[Syntax schema](./engineering/extensions/schemas/syntax-contribution-v1.schema.json) | OPEN — E2 parser corpus；v2 另设 gate |
| 24 | 采用 A：E2 扩展只返回 Core `ExtensionContentTree`，拒绝任意 HTML/SVG/CSS；受控 SVG 只能作为 PackReleaseRecord 精确 hash asset，经 Core sanitizer 后引用 | [Syntax Extension API §6](./engineering/extensions/SYNTAX_EXTENSION_API.md)、[Content Tree schema](./engineering/extensions/schemas/extension-content-tree-v1.schema.json) | OPEN — E2 negative corpus |
| 25 | 采用 B：市场签名 PackReleaseRecord 固定 pack/publisher/release sequence、精确组件/依赖解算 hash；E2 LaTeX 只产受控 SVG asset，PDF 由 Core 消费同一资产 | [Pack Release schema](./engineering/extensions/schemas/pack-release-record-v1.schema.json)、[Extension System Design](./engineering/extensions/SYSTEM_DESIGN.md) | OPEN — E2/E3 reproducibility evidence |
| 26 | 采用 A：E3 增加固定 origin `MarketBroker.xpc`；机器 Policy 冻结 endpoint/DNS/TLS/零跳转/预算，市场记录绑定包/开发者/审计/channel/单调序列；`Revoked` 为不可覆盖终态，与用户可解除 quarantine 分离 | [Market Broker Policy](./engineering/extensions/MARKET_BROKER_POLICY.json)、[Phase Process Matrix JSON](./engineering/extensions/PHASE_PROCESS_MATRIX.json)、[Market record schema](./engineering/extensions/schemas/market-release-record-v1.schema.json) | OPEN — E3 evidence |
| 27 | 采用 A：Core/store owner 解密，经认证且有预算的一次性流交给 Network Broker；mutation 完整覆盖 put/delete/move/oldPath/newPath/condition，逐资源 ACK 返回幂等 receipt，磁盘压力保留 durable dirty intent | [Extension System Design §12](./engineering/extensions/SYSTEM_DESIGN.md)、[Sync protocol schema](./engineering/extensions/schemas/sync-protocol-v1.schema.json) | OPEN — E4 crash/ACK matrix |
| 28 | 采用 A：每 typed adapter 冻结 endpoint graph、端口、逐跳 redirect、跨域凭据清除、DNS/IP/TLS、上传/响应/解压预算 | [Typed Adapter Policies](./engineering/extensions/TYPED_ADAPTER_POLICIES.json)、[Typed Adapter schema](./engineering/extensions/schemas/typed-adapter-policy-v1.schema.json) | OPEN — E4 network corpus |
| 29 | 以 A 为主并保留设备准入：immutable ModelStore versioned CAS；Core 持有响应/解析/diff；跨窗口 ledger 原子 reserve/settle；内存按物理比例且保留 Core/system headroom，M1/8 GB 按模型准入 | [AI Runtime Manifest](./engineering/extensions/AI_RUNTIME_MANIFEST.json)、[Extension System Design §12A](./engineering/extensions/SYSTEM_DESIGN.md) | OPEN — E4 AI evidence |
| 30 | 采用 A：机器 KeychainPolicy 将 Recovery/Workspace/Sync/AI 分域 KEK 与 wrapped DEK；target 最小 access group；journal/state 加密；E1/E2 state 默认仅 schema scalar，权限撤销/卸载/终态 Revoked 时 crypto-erase，普通 disable 只撤销运行 capability | [Data Protection Policy](./engineering/DATA_PROTECTION_POLICY.md)、[Keychain Policy](./engineering/KEYCHAIN_POLICY.json)、[Extension System Design §11](./engineering/extensions/SYSTEM_DESIGN.md) | OPEN — target entitlement/state evidence |

## 5. 一并清理项

| 清理项 | 最终处置 |
| --- | --- |
| HTML CSP | 预览/导出均补 `base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'` |
| 数据保护格式 | AEAD authenticated header 固定 HKDF purpose label、header/总长度/chunk count、final marker 与抗截断规则 |
| 日志 | 新增机器 LoggingPolicy、容量/TTL、字段敏感度和 seeded canary scanner；命中阻断 Release |
| P1 工作区索引 | workspace-domain DEK 加密；只存 opaque path ID/HMAC token 与加密 path/title，不落明文路径 |
| PRD 冻结清单 | `INF-P0-DOD-020` 明确包含 Save/Recovery ADR |
| 性能 | PerformanceManifest 固定采样窗口、短命 helper PID 聚合、designated-requirement/audit-token 归属及本地图片 fixture |
| Xcode 前置状态 | 删除“license 未接受”旧结论；本机 `xcodebuild -checkFirstLaunchStatus` 已成功，CI 仍归档 preflight |
| Phase Matrix | JSON 为机器权威，Markdown 仅作可读投影视图 |
| payload 身份/包字段 | body 禁止自报 `extensionID`/PID/UID/audit token，业务引用只用 connection-bound opaque handle；未知 ZIP entry 与安全/运行字段全部 fail closed，唯一前向兼容区只允许 schema 明示、被签名且不影响权限/路径/hash 的展示 metadata |

## 6. 当前 gate 判定

1. **允许继续 T0 原型验证。** 前置方案选择已完成，工程可以按单一路径产出证据。
2. **T0 尚未完成。** D04/D05/D07、Save/Recovery fault matrix、Render/Sanitizer 真 hash/PID/entitlement、Performance 与 PDF postflight 证据仍是 OPEN。
3. **不得进入 T1。** 只有 [Technical Design T0 退出矩阵](./engineering/TECHNICAL_DESIGN.md) 全部通过且状态由真实 CI/Release 产物驱动为 Accepted/Frozen 才可授权。
4. **“定稿”仅指前置产品和执行契约。** 本台账禁止把 schema、模板、Markdown 声明或应用 CodeResources 当作原型/Release 证据。

## 7. 最终复验

- 正向门禁：`python3 scripts/validate_docs.py`（31 个 JSON contract）、Inventory `--check` / `--self-test`、全部 Markdown 本地链接、脚本语法解析和 `git diff --check` 均通过。
- 闭集结果：PRD/Requirement Traceability 为 68/68；29 个 feature 由 23 条 Inventory mapping + 6 条 exclusion 覆盖；40/40 Benchmark capability 均有反向引用。Traceability 仍全部 `OPEN`，Inventory registry 仍为 0/0、`aligned` 为 0。
- 负向门禁：Recovery event 夹带未知 `extensionID`、远程 `$schema` 替换、typed adapter graph 缺项/凭据错绑、Sanitizer 期望与实际分类不一致、Render runtime role 缺失、全零 hash、Inventory 非法 category/coverage/环境及过早 frozen 均被拒绝。
- 最终判定：原始 1–30 项与清理项在**产品/执行契约层**无剩余阻断，可以定稿；T0 evidence 仍 OPEN、T0 未完成、T1 未授权。
