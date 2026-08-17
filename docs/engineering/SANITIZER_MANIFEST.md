# SanitizerManifest（P0 草案）

- 状态：Reopened，T0 安全测试与快照通过后锁定
- manifestVersion：1
- 产品决策：P0-D05

## P0 输入边界

P0 raw HTML 全部转义为可见源码，不进入 DOM；raw `id` 不参与导航。Markdown 远程图片在预览、HTML 和 PDF 中只显示占位，不发起网络请求。raw HTML allowlist 与隔离 ImageFetcher 属于 P1 新决策，不是本 Manifest 的 P0 能力。

## Mermaid SVG

- Mermaid 11.15.0 固定 `securityLevel: strict`、`htmlLabels: false`，不接受文档内覆盖安全配置。
- 单块源码不超过 256 KiB，单块渲染 2 秒超时，单文档同时最多 2 个渲染任务。
- 最终 SVG 不超过 2 MiB、5,000 个元素、10,000 CSS px × 10,000 CSS px；超限按错误占位。
- 清洗最终 SVG，只允许几何、文本、分组、marker、受限 presentation attributes 和内部 fragment 引用。渲染器先把已审核的 Mermaid 样式展平为 presentation attributes，再删除 `foreignObject`、`script`、`style`、事件属性、动画、滤镜、外部 URL、CSS URL、字体和任意导航。禁止 SVG 触发网络、文件或 data/blob 资源。

## KaTeX Markup

- KaTeX 0.18.1 固定 `trust: false`、`strict: error`、`throwOnError: false`、`maxExpand: 1000`，不接受文档覆盖。
- 单公式输入不超过 64 KiB，渲染 1 秒超时，输出不超过 1 MiB、10,000 个 HTML/MathML 节点及 10,000 CSS px × 10,000 CSS px。
- 输出只允许 KaTeX 固定模板需要的 HTML/MathML 标签、属性和内置 class token。生成器拥有的 `style` 只允许尺寸/间距/垂直对齐属性与有限十进制 `em/ex/px/%` 值；禁止 `url()`、自定义属性、颜色、定位、变换和非数值表达式。删除 URL、事件属性、SVG `foreignObject` 及未知命名空间。公式错误或超限显示转义源码与非阻断错误。

## CSS 与文档预算

P0 生成内容不能贡献任意 CSS；只使用应用内置、带版本 hash 的主题和 KaTeX CSS。单文档生成内容总预算为 20 MiB DOM/SVG 序列化结果、20,000 个生成节点和最多 2 个并发渲染任务；达到预算后其余块显示占位，编辑与保存不受影响。

## 冻结门槛

测试至少覆盖 raw HTML 转义、远程图片零请求、Mermaid 脚本/事件/CSS/`foreignObject`/外部资源、KaTeX trust 命令/宏炸弹、超时、节点/尺寸/文档预算和错误降级。T0 必须证明 WebView 网络请求计数为零并审核 golden diff。任何规则、限额或 sanitizer 依赖变化必须提升 manifestVersion。
