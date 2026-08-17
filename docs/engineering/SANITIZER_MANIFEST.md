# SanitizerManifest（P0 草案）

- 状态：Reopened，T0 安全测试与快照通过后锁定
- manifestVersion：1
- 产品决策：P0-D05

## P0 输入边界

P0 raw HTML 全部转义为可见源码，不进入 DOM；raw `id` 不参与导航。Markdown 远程图片在预览、HTML 和 PDF 中只显示占位，不发起网络请求。raw HTML allowlist 与隔离 ImageFetcher 属于 P1 新决策，不是本 Manifest 的 P0 能力。

P0 主应用及渲染 helper 均不授予 outgoing-network entitlement。预览、HTML 和 PDF 共用以下两项版本化策略，任何调用方不得绕过。

## URLPolicy v1

- URL 先拒绝控制字符和无效 UTF-8，再执行一次且仅一次 UTF-8 百分号解码、Unicode NFC 和 scheme/host 小写标准化；若剩余 `%xx` 再次解码会改变 scheme、host 或路径安全分类，目标降级为纯文本。
- 允许同文档 fragment、经安全作用域验证的本地相对 Markdown/附件链接，以及由用户单击后交系统浏览器的 `http`/`https`。未知 scheme、`javascript:`、`data:`、`blob:`、绝对 `file:`、带凭据 URL 和可执行目标均降级为纯文本，不产生可点击 DOM。
- Markdown 图片 `src` 只允许经 `ResourceResolver` 验证的授权本地相对路径；远程、绝对 file、data URI 和越权路径统一占位。

## ImageDecodePolicy v1

- P0 只解码静态 PNG 与 JPEG；本地 SVG、GIF、APNG、动画 WebP、PDF 伪装图片和其他格式均显示占位。文件扩展名、声明 MIME 与 magic bytes 必须一致，否则拒绝。
- 单文件最大 25 MiB、单边最大 16,384 px、总像素最大 40 MP、解码后内存最大 160 MiB；每文档图片解码内存总预算 320 MiB，同时最多 2 个解码任务。超过任一限制立即停止解码并占位。
- 解码在可销毁的无网络 ImageDecodeHelper 中进行；禁止增量无限流、嵌套容器、多帧和颜色配置文件触发外部资源。helper 崩溃或越限只影响对应图片。

## ExportResourcePolicy v1

- `URLPolicy` 继续拒绝 Markdown 源码、raw HTML 和扩展输出提供的所有 `data:` URI；导出器不得把它们当作已验证资源。
- 只有 Core 从 `ImageDecodePolicy` 已通过的本地 PNG/JPEG 重新编码得到的字节，以及应用包内按固定 hash 登记的字体，才能由导出器生成 `data:image/png`、`data:image/jpeg` 或对应字体 MIME URI。生成记录携带 Core-owned provenance，普通字符串不能伪造。
- 生成 URI 只写入最终自包含 HTML staging，不回流 AST、预览 DOM、剪贴板或文档源码；仍计入单资源、文档解码预算和 100 MiB HTML 输出上限。公式与 Mermaid 以已清洗的内联标记/SVG 写入，不开放任意 data/blob 资源。

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

Mermaid 与 KaTeX 不在长期存活的预览 WebView 中直接执行同步 JavaScript。实现固定为一任务一进程的 `RenderHelper.xpc`：helper 内使用随应用锁定的 WebKit JavaScript/DOM realm，禁止导航、网络、文件和持久化数据存储；进程只接收一个 job，返回序列化结果后退出，不复用 realm。

主应用外的 `RenderSupervisor` 维护全应用最多 2 个运行 worker、最多 32 个排队 job 和 256 MiB worker RSS 总上限；超过队列上限立即背压并显示占位。Supervisor 从 XPC audit token 校验并记录专属 worker PID，使用独立 watchdog 计时；达到截止时间、单进程 128 MiB RSS、全局 RSS 或输出上限时，通过平台允许的进程终止 API 对该 PID 执行强制终止，等待退出确认后丢弃结果。仅取消 XPC connection、JavaScript Promise 或 WKWebView navigation 不算硬终止。

上述 PID 获取、强制终止、sandbox entitlement、WebKit 子进程归属及 RSS 统计必须由 T0 `RenderHelperIsolation` ADR 和可重复 fixture 在 macOS 14+ Release sandbox 中证明；证明失败时 P0-D05 保持 Reopened，不得以软截止时间替代“硬超时”。

## 冻结门槛

测试至少覆盖 URL 多重编码/危险 scheme、raw HTML 转义、远程图片零请求、本地 SVG/data URI/伪造 MIME/像素炸弹、ExportResource provenance 伪造、Mermaid 脚本/事件/CSS/`foreignObject`/外部资源、KaTeX trust 命令/宏炸弹/`maxSize`、worker 强制终止、队列背压、节点/尺寸/RSS/文档预算和错误降级。T0 必须证明无 outgoing-network entitlement、网络请求计数为零、超时后 worker 及其 WebKit 子进程已退出，并审核 golden diff 与 `RenderHelperIsolation` ADR。这些条件是 P0-D05 转 Accepted 的强制门槛；任何规则、限额或依赖变化必须提升 manifestVersion。
