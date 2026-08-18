# RenderManifest（T0 草案）

- 状态：Reopened；T0 golden 与隔离 ADR 通过后冻结
- manifestVersion：1

## 固定输入

| 组件 | 版本/事实来源 |
| --- | --- |
| Swift Markdown / cmark | 见 `MarkdownDialectManifest` 的精确 commit/options/hash |
| Mermaid | 11.15.0，应用内资源 SHA-256 在 T0 填入 |
| KaTeX | 0.18.1，JS/CSS/font SHA-256 在 T0 填入 |
| Sanitizer | `SanitizerManifest` manifestVersion 及机器可读 allowlist hash |
| 主题/字体 | 内置资源 ID、版本、逐文件 SHA-256 |

## Golden 环境

每次截图/PDF golden 记录 macOS build、WebKit build、设备 scale、locale/timezone、ColorSync profile、所有字体 PostScript name/version/hash、Render/Sanitizer manifest hash 和 fixture hash。环境不匹配时只可生成候选 diff，不得覆盖权威 golden。

## 输出一致性

同一 `MarkdownSnapshot + RenderProfile` 必须为预览、HTML、PDF 共享 typed render tree、slug、URL/Image/Export policy。golden 包含 AST、SourceMap、安全 DOM、桥消息、浅/深截图、HTML 与 PDF 页面；依赖或策略变化必须提升 manifestVersion 并人工审核。

## 冻结门槛

Parser/SourceMap、Editor/Preview 定位、DOM patch、PreviewBridge、Mermaid/KaTeX 隔离、HTML privacy 与 PDF ADR 对应 fixture 全部通过；精确资源 hash 不得留空。
