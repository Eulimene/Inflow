# JavaScript 渲染适配层

Rust Core 负责 CommonMark/GFM 解析、源码范围和开关。`NativeRenderPlan.render_requests` 输出只读请求（类型、语言、原始内容、UTF-8 完整范围和内容范围），不再使用 `mermaid-rs-renderer`，也不再用 Rust 子集解析器解释 TeX 或代码语言。

| 输入 | 适配器 | 离线版本 |
| --- | --- | --- |
| `mermaid` 围栏 | MermaidAdapter → mermaid.js | 11.12.2 |
| `flow` 围栏 | FlowchartAdapter → flowchart.js | 1.18.0 发布文件 |
| `sequence` 围栏 | SequenceAdapter → js-sequence-diagrams | 2.0.1 |
| 普通代码围栏及图表源码 | CodeMirrorAdapter → CodeMirror runMode | 5.65.20 |
| `$…$` 和 `$$…$$` | MathJaxAdapter → TeX SVG | 3.2.2 |

CodeMirror 仅提供语法模式和 token 范围，保留原生 NSTextView 的输入法、选区和撤销链路。内置 JavaScript/TypeScript、JSON、Python、Rust、Swift、C/C++/Java/C#、Shell、SQL、CSS、XML/HTML、YAML、Markdown、TeX、Go、Properties 模式，以及图表 DSL 模式。未知语言保留纯文本。

## 执行与回填

`JavaScriptRenderService` 串行调度一个非持久 WKWebView，避免第三方库的全局状态互相覆盖。成功结果按类型、语言、正文和显示方式缓存，最多 64 项；错误不进入共享缓存。单次调用有 15 秒超时，WebContent 进程退出或超时时重建宿主。

图表先生成独立 SVG，再由 WebKit 生成矢量 PDF 图像回填同一个 TextKit 表面，避免 AppKit SVG 解码丢失箭头；公式以模板 SVG 图像回填。文档 PDF 仍打印这个原生表面。CodeMirror 的 UTF-16 token 范围只设置显示属性。每次异步回填都验证原始文档快照、任务取消状态和输入法状态，不改写 Markdown，不登记展示层 undo。进入公式或图表时显示可编辑源码。

图表使用经典浅色配色和独立白底，避免深色页面上的透明背景导致文字或连线不可见；原生公式使用模板图像，颜色随正文变化。SVG 中的 CSS 在 WebKit 内解析为显式属性，tspan 转换为带坐标的 text，以兼容 AppKit SVG 解码。

HTML 预览和 HTML 导出包含相同的离线适配器，以 nonce 限定可信内联脚本。导出文件无需 CDN，保留未解析源码，在打开后完成渲染；不再声称导出时已经生成静态 SVG 或 MathML。PDF 等待原生异步资源完成后生成。

## 标签换行

换行兼容放在 JS 图表适配器内，原始 Markdown、源码范围和 CodeMirror token 均不做替换。交给图表解析器前统一 CRLF/CR 为 LF；不会把整段源码中的字面量 `\n` 全局展开为语法行。

- Mermaid flowchart/graph 的节点、引号标签及 `|边标签|` 支持 `\n` 和实际换行，转换为 `<br/>`；Markdown 字符串保留原生换行。已有 `<br/>` 继续有效。注释、配置、样式和链接指令保持原样。
- Mermaid sequenceDiagram 的消息和 note 支持 `\n`，转换为 `<br/>`。
- flow 在解析后只对 symbol.text 展开 `\n` 和 `<br/>`，不改变节点标识、连线或链接。
- sequence 由 js-sequence-diagrams 原生解释消息和注释里的 `\n`。

例如 `A[第一行\n第二行]`、`st=>start: 第一行\n第二行` 和 `甲->乙: 第一行\n第二行` 均可生成两行文字。其他 Mermaid 图表类型遵循各自的原生语法。

## 边界与故障

Mermaid 使用 strict 安全级别和 SVG 标签；MathJax 只启用已打包的 TeX 扩展，不动态加载扩展或字体。宿主 CSP 禁止网络连接、外部脚本、框架和表单。SVG 回填去除脚本、事件、外部资源引用、foreignObject 和动画，且不安装 Mermaid 的链接回调。输入、SVG 尺寸和执行时间均有上限。

语法错误只影响对应块。图表退回可编辑源码，公式保留 TeX 和定界符；HTML 中保留原内容并标注错误。图表的底层 DTO 仍沿用 `mermaid_diagrams` 命名以保持现有协议结构；它现在覆盖三种图表语言，Core 仅返回占位，最终解析与 SVG 生成属于 JS 宿主。

## 依赖与验证

资源位于 `macos/Inflow/Resources/JavaScript/`。`dependencies.json` 记录固定发布 URL、版本和 SHA-256，`Licenses/` 保留许可证。flowchart.js 的 1.18.0 CDNJS 发布文件内部头注释仍写 1.17.1，完整文件按 SHA-256 固定。

执行 `python3 scripts/verify-js-resources.py` 检查离线资源。实际 JS 渲染测试使用 macOS 应用宿主（`xcodebuild test`），因为 WKWebView 依赖 WebContent 系统服务；普通 Rust 和不依赖 WebKit 的 XCTest 仍可独立运行。
