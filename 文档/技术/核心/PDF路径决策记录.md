# PDF Path ADR（P0 冻结候选）

- ADR 状态：Conditional
- 选择：Path A — `WKWebView.createPDF` + `PDFPostflight v1`
- 证据状态：OPEN；D07 在 golden、结构 postflight 与 Archive 隐私证据通过前保持 Conditional
- P0 Rejected：Main 进程 `NSPrintOperation` 自动 fallback

## 输出契约

P0 固定 A4、四边 20 mm、当前主题/深色背景、正文宽度上限且无内容丢失；高级分页不属于 P0。输入是绑定 exact source version、RenderProfile 和 RenderManifestHash 的完成 HTML，已通过 `ExportHTMLPolicy v1`，不含脚本、表单、frame/object、远程资源或绝对路径。

## 唯一路径

MainActor 异步创建专用、非持久、无导航能力的离屏 WKWebView，加载静态完成 HTML，等待字体、已验证图片、公式和 Mermaid readiness barrier 后调用 `WKWebView.createPDF`。解析、清洗、图片重编码、HTML 构建与 IO 在后台 actor/helper 完成；PDF postflight 只在独立签名、每 job 一次性的 `PDFPostflightHelper` 中执行，该 target 必须出现在 Keychain/Performance/Sanitizer/Phase/IPC 机器权威中。MainActor 不同步等待，也不执行重 CPU/IO。

P0 不调用 `NSPrintOperation`，不打开 print panel、不查询/选择默认打印机、不创建 print job 或 spool，也不请求打印 entitlement。若 `createPDF` 无法满足输出契约，D07 继续 Conditional 并停止 PDF 发布；不得静默切换到打印路径。未来若确需打印 helper，必须另立 ADR、独立签名 target 和 entitlement/spool 证据。

## PDFPostflight v1

`createPDF` 的原始字节只是候选。唯一算法固定为 **parse → strip → allowlist rebuild → independent second parse**：受限 postflight parser 先完整解析对象图并检查长度/xref/object stream/递归/解压预算，再生成清洗后的单一 revision；未知或损坏结构 fail-closed，不把原始 PDF 直接交付。第一 pass 看到 URI/action/attachment/metadata 时执行下述确定性 strip，不将它们保留为 exception；重建后第二 pass 仍发现任何一项时才拒绝整份输出。

清洗固定执行：

- 删除 Catalog/Page/Annotation/Name tree 中所有 JavaScript、`OpenAction`、`AA`、`Launch`、`SubmitForm`、`ImportData`、`GoToR`、`URI` 等 action；P0 PDF 不保留可点击外链。
- 删除 `EmbeddedFiles`、FileSpec、attachment annotation、AcroForm/XFA、RichMedia、3D、movie/sound、collection/portfolio、optional-content 脚本与未知 active content。
- 删除 XMP、source URL、document ID、增量历史和原始 Info metadata；只允许重建固定 `Producer=Inflow` 与非用户特定的 format version。标题、作者、用户名、主机名、打印机名、创建/修改时间默认不写。
- 删除或拒绝任何 `file:` URI、绝对 POSIX/Windows 路径、security bookmark、replacement/temp 路径、网页缓存路径与 fixture privacy canary。
- 只从已验证的 page/content/font/image/color resource 重建单一 revision；未引用 object、trailing bytes 与增量更新全部丢弃。图片必须来自 `ImageDecodePolicy` 的重编码结果；字体必须匹配 RenderManifest 中的固定 hash。

清洗后用第二个独立解析 pass 验证：xref/对象引用闭合，page count 与 MediaBox/CropBox 为预期，内容可抽取，零 URI/JavaScript/OpenAction/AA/Launch/SubmitForm/ImportData/GoToR action、零 annotation action、零 attachment/embedded file、零表单/脚本、零绝对路径/隐私 canary，且总页/对象/解压后字节在预算内。任一残留或后验失败则拒绝整份 PDF、删除 staging 并报告失败，不生成半成品目标。

## 隐私与进程边界

离屏 WebView 和 `PDFPostflightHelper` 均无 outgoing/incoming network；helper 只接收完成 PDF 的有界内存或写前已 unlink 的受限 FD，不接收用户路径、bookmark、Recovery/Workspace/Sync/AI key 或默认打印机信息。PDF staging 只使用系统为用户已选目标返回的同卷 replacement directory；验证完成前不触碰目标。

Release Archive 需证明没有打印 entitlement/print helper，网络探针为零请求，系统 spool/默认打印机状态在 fixture 前后不变；日志和 crash fixture 不含 HTML/PDF 正文或路径。

## Conditional 退出条件

同一版本化 fixture 在最低与当前支持 macOS/WebKit、浅/深主题、中文/Unicode、表格/代码、分页边界、Mermaid/KaTeX、本地 PNG/JPEG、超限/失败占位上生成：页面截图、文本抽取、结构报告、postflight 报告和真实 hash。必须证明 A4/20 mm、背景与内容完整，且所有主动内容和隐私字段后验为零。

这些运行/构建产物当前不存在，不得手填通过结论或 hash。全部证据通过后 D07 才可由 Conditional 转 Accepted；失败时保持阻断并另行评估独立分页管线，而不是恢复 `NSPrintOperation` fallback。
