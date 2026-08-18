# SanitizerManifest（P0 冻结契约）

- 契约状态：Frozen
- P0-D05 证据状态：OPEN；T0 安全测试、机器 allowlist、负面 corpus 与最终 Archive 证据尚未生成
- manifestVersion：1
- 产品决策：P0-D05
- 证据格式：[`SANITIZER_EVIDENCE.schema.json`](./SANITIZER_EVIDENCE.schema.json)

## P0 输入边界

P0 raw HTML 全部转义为可见源码，不进入 DOM；raw `id` 不参与导航。Markdown 远程图片在预览、HTML 和 PDF 中只显示占位，不发起网络请求。raw HTML allowlist 与隔离 ImageFetcher 属于 P1 新决策，不是本 Manifest 的 P0 能力。

P0 主应用及渲染 helper 均不授予 outgoing-network entitlement。预览、HTML 和 PDF 共用以下两项版本化策略，任何调用方不得绕过。

## URLPolicy v1

- `URLPolicy` 是 percent-decode 与 NFC 的唯一所有者；调用方只能传 raw bytes/string，不得预解码。策略先拒绝无效 UTF-8，执行一次且仅一次 percent-decode 与 Unicode NFC，再次拒绝 NUL、C0/C1 control、bidi control、非法 scalar 和路径分隔混淆；若剩余 `%xx` 再解码会改变分类则降级纯文本。
- 允许同文档 fragment、经安全作用域验证的本地相对 Markdown/附件链接，以及由用户单击后交系统浏览器的 `http`/`https`。未知 scheme、`javascript:`、`data:`、`blob:`、绝对 `file:`、带凭据 URL 和可执行目标均降级为纯文本，不产生可点击 DOM。
- Markdown 图片 `src` 只允许经 `ResourceResolver` 验证的授权本地相对路径；远程、绝对 file、data URI 和越权路径统一占位。
- 标题与 fragment 是两个不可互调的接口：`makeHeadingID(headingText, occurrenceIndex) → DOMID` 只运行版本化 slugger 且不做 URL decode；`resolveFragment(rawFragment, domIDSet) → exact DOMID | notFound | blocked` 只运行 URLPolicy 的一次 decode/NFC，再与已生成的 DOM ID 做 **区分大小写、逐 Unicode scalar 精确匹配**。fragment 不 lowercase、不删标点、不替换空白、不追加重复序号，也绝不进入 slugger。
- fragment 输入中的 `#` 只由 URL parser 去除一次；`%252F`、解码后 `%2F`、非法 UTF-8、组合字符/NFC、大小写差异、重复 heading 与 raw HTML `id` 必须进入负面 corpus。调用链需以不同 Swift 类型表示 `HeadingText`、`RawFragment` 与 `DOMID`，禁止用裸 `String` 重载绕过接口。
- 本地资源从已授权根目录的打开目录句柄开始，以逐段 no-follow 语义解析；验证结果是 `VerifiedLocalHandle { fd, resourceIdentity, byteLength, contentType, contentHash, authorizationRootIdentity }`，不是可复用路径。symlink、alias、mount 或 resource identity 变化即拒绝。

### 本地链接消费规则

- Markdown：DocumentSession 直接从已验证只读 FD 读取首次 exact bytes，并把原目标的 canonical URL/resource identity 绑定到 `DocumentRegistry`；`NSDocumentController` 不得在校验后自行按路径重读。后续保存仍走 SaveRecovery 的 revision guard。
- PNG/JPEG/PDF：应用内预览/解码直接消费 FD。若用户明确选择外部应用而系统 API 只接受 URL，只能从该 FD 创建 `DataProtectionPolicy` 定义的 app-owned immutable clone，再打开 clone；不得传原路径。
- 其他文件类型：P0 **只允许 Finder reveal**，不提供“仍要打开”分支，不按原路径交给 `NSWorkspace`/其他应用，也不从 verified FD 生成 immutable clone。未来放开新类型必须先提升机器 Policy，冻结 content sniff/资源预算/消费者，并在当次用户确认后从重新验证的 FD 消费；不得复用 P0 的旧校验结果。
- Finder reveal 只用于帮助用户定位，不等同于安全打开。reveal 前仍校验父目录 scope；操作完成后不得据此扩大 bookmark 权限。

## ImageDecodePolicy v1

- P0 只解码静态 PNG 与 JPEG；本地 SVG、GIF、APNG、动画 WebP、PDF 伪装图片和其他格式均显示占位。文件扩展名、声明 MIME 与 magic bytes 必须一致，否则拒绝。
- 单文件最大 25 MiB、单边最大 16,384 px、总像素最大 40 MP、解码后内存最大 160 MiB；每文档图片解码内存总预算 320 MiB，同时最多 2 个解码任务。超过任一限制立即停止解码并占位。
- 解码在可销毁的无网络 ImageDecodeHelper 中进行；禁止增量无限流、嵌套容器、多帧和颜色配置文件触发外部资源。helper 崩溃或越限只影响对应图片。
- 全应用 `ImageDecodeSupervisor` 最多运行 2 个一次性 worker、排队 32 项，单任务硬截止 2 秒；worker 单进程 RSS 192 MiB、整棵关联进程树合计 384 MiB。超出队列立即背压，超时/超 RSS 强制终止整棵 job 进程树。多窗口共享同一预算，不按文档倍增。

## ExportResourcePolicy v1

- `URLPolicy` 继续拒绝 Markdown 源码、raw HTML 和扩展输出提供的所有 `data:` URI；导出器不得把它们当作已验证资源。
- 只有 Core 从 `ImageDecodePolicy` 已通过的本地 PNG/JPEG 重新编码得到的字节，以及应用包内按固定 hash 登记的字体，才能由导出器生成 `data:image/png`、`data:image/jpeg` 或对应字体 MIME URI。生成记录携带 Core-owned provenance，普通字符串不能伪造。
- 生成 URI 只写入最终自包含 HTML staging，不回流 AST、预览 DOM、剪贴板或文档源码；仍计入单资源、文档解码预算和 100 MiB HTML 输出上限。公式与 Mermaid 以已清洗的内联标记/SVG 写入，不开放任意 data/blob 资源。

## ExportHTMLPolicy v1

完整 HTML 只允许 UTF-8，自身不含脚本、表单、frame、object/embed、`base`、刷新跳转或运行时资源。固定 CSP 必须同时出现在最前部 `<meta http-equiv>` 和导出 postflight 的期望值中，规范化后精确为：

```text
default-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:
```

同时输出 `Referrer-Policy: no-referrer` 等价 meta。外部 `http/https` 只可存在于经过 URLPolicy 规范化的用户点击链接，固定 `rel="noopener noreferrer"`，不放宽 `connect-src` 或导航能力；绝对本地路径、`file:`、source map、bookmark、query 中的私密 canary 与生成器临时目录必须在 postflight 为零。任一 CSP/meta 缺失、重复冲突或被模板覆盖都使导出失败，不生成弱化版本。

## Mermaid SVG

- Mermaid 11.15.0 固定 `securityLevel: strict`、`htmlLabels: false`，不接受文档内覆盖安全配置。
- 单块源码不超过 256 KiB，单块硬截止时间 2 秒，单文档同时最多 2 个渲染任务。
- 最终 SVG 不超过 2 MiB、5,000 个元素、10,000 CSS px × 10,000 CSS px；超限按错误占位。
- 清洗最终 SVG，只允许几何、文本、分组、marker、受限 presentation attributes 和内部 fragment 引用。渲染器先把已审核的 Mermaid 样式展平为 presentation attributes，再删除 `foreignObject`、`script`、`style`、事件属性、动画、滤镜、外部 URL、CSS URL、字体和任意导航。禁止 SVG 触发网络、文件或 data/blob 资源。

## KaTeX Markup

- KaTeX 0.18.1 固定 `trust: false`、`strict: error`、`throwOnError: false`、`maxExpand: 1000`、`maxSize: 100`，不接受文档覆盖。
- 单公式输入不超过 64 KiB、10,000 token、嵌套深度 128，硬截止时间 1 秒；输出不超过 1 MiB、10,000 个 HTML/MathML 节点及 10,000 CSS px × 10,000 CSS px。
- 输出只允许 KaTeX 固定模板需要的 HTML/MathML 标签、属性和内置 class token。生成器拥有的 `style` 只允许尺寸/间距/垂直对齐属性与有限十进制 `em/ex/px/%` 值；禁止 `url()`、自定义属性、颜色、定位、变换和非数值表达式。删除 URL、事件属性、SVG `foreignObject` 及未知命名空间。公式错误或超限显示转义源码与非阻断错误。

## CSS 与文档预算

P0 生成内容不能贡献任意 CSS；只使用应用内置、带版本 hash 的主题和 KaTeX CSS。单文档生成内容总预算为 20 MiB DOM/SVG 序列化结果、20,000 个生成节点和最多 2 个并发渲染任务；达到预算后其余块显示占位，编辑与保存不受影响。

## 可终止渲染边界

Mermaid 与 KaTeX 不在长期存活的 Preview WebView 中执行。唯一实现是 `RenderHelperIsolation` ADR 选择的 Path A：`RenderSupervisor` 为每个 job 启动一次性非 WebKit JS/DOM worker，worker 返回候选序列化结果后退出，Core 再按本 Manifest 清洗。`WKProcessPool`、website data store 或 WebContent PID 不再是隔离边界，相关 Path B 为 Rejected。

Supervisor 本地上限仍为最多 2 个 running worker、32 个排队 job、单 worker 192 MiB RSS、Render 进程树合计 384 MiB；单文档最多占一个 running token。实际可用值还必须取得统一 `ResourceGovernor` 授予，Render 与 Image/Export helper 的 RSS/CPU/队列不可分别满额叠加。达到截止、RSS、CPU、输出、节点或 generation 取消边界时强杀 job process group，`waitpid` 并确认关联进程退出后才释放预算；只取消 IPC/Promise 或只杀 direct PID 不算硬终止。

worker 请求/响应只在有界内存或写前已 unlink 的受限 FD 中传输，禁止命名 scratch 和系统 temp。进程归属、短命 PID 聚合、强杀、sandbox/Archive entitlement、runtime/DOM/resource hash 和干净 realm 必须按 ADR 的 Release fixture 生成机器证据；缺失时 P0-D05 保持 OPEN。

## PreviewBridgePolicy v1

- 预览脚本只安装在隔离 `WKContentWorld`；每次顶层加载生成 256-bit capability nonce，消息必须携带 nonce、documentID、documentVersion、navigationGeneration 和枚举 message type。
- 每条消息使用机器可验证 JSON Schema，最大 64 KiB；未知字段/type、过期 nonce/version/generation、重复序号或非预期 frame 一律拒绝。导航开始即撤销旧 handler/nonce，页面销毁时移除 handler，禁止 handler 跨加载复用。
- Core 优先把 typed render tree 编码为静态 DOM；必须兼容 HTML/SVG 的部分使用随 manifest 版本提交的机器可读 tag/attribute/class/CSS-property allowlist 和负面 corpus，不以自然语言列表作为唯一实现规范。

## EntitlementMatrix v1

P0 Release Archive 必须逐 executable 校验签名 entitlements：Main、RenderSupervisor、RenderWorker、ImageDecodeHelper、`PDFPostflightHelper` 与 Preview WebView 配置均无 outgoing/incoming network；helper 无用户文件路径、打印或 Data Protection/Keychain key 权限，只接收已验证 FD/内存对象；只有 Main 持有用户选择文件的 security scope。CI 从最终 Archive 导出实际 entitlements 与 expected matrix 做归一化精确 diff，且主动运行 socket/DNS/path 探针；Debug 配置和源码 entitlement 文件不能作为证据。

## 机器 allowlist、corpus 与冻结门槛

Release 构建必须从 **实际编译进产品的 policy tables** 导出 canonical JSON allowlist；禁止维护一份不会被运行时代码读取的“文档 allowlist”。同一构建还要索引版本化负面 corpus 与每个 case 的期望分类，执行后生成符合 `SANITIZER_EVIDENCE.schema.json` 的证据，其中记录 allowlist、corpus、测试二进制、`PDFPostflightHelper` 二进制与 corpus 结果、最终 Archive、Render manifest 和 golden index 的真实 SHA-256。Schema 对每个 case 机器强制 `expectedClassification == actualClassification`、`passed=true` 且所有 SHA-256 非全零；summary 不保存无法与 array 关联验证的 declared/executed/passed 冗余计数，只能是 `result=all-cases-passed` 与三个零失败/跳过/未知计数，因此不存在自相矛盾 summary。generator 对缺文件、零 case、重复 case ID、placeholder hash、未执行 case、未知分类或失败 case 一律非零退出。

测试至少覆盖 URL 双解码/解码后 control、fragment exact-match/大小写/组合字符、symlink/alias/mount swap、验证后路径替换、raw HTML 转义、远程图片零请求、本地 SVG/data URI/伪造 MIME/像素炸弹、ExportResource provenance、HTML CSP、PreviewBridge nonce/schema/lifecycle、Mermaid/KaTeX 注入与炸弹、Render/Image worker 整棵树强制终止、PDFPostflightHelper 的 strip/rebuild/残留 active-content 全件拒绝、队列背压、全应用 RSS 和错误降级。

仓库当前没有 Release runtime/资源、最终 allowlist 导出、完整负面 corpus 执行结果或 Archive，因此不得在本文件填伪 hash。契约已经冻结，但上述机器证据、golden diff 与 `RenderHelperIsolation` fixture 全部为 OPEN；它们是 P0-D05 转 Accepted 和 T0 退出的强制门槛。
