# MarkdownDialectManifest（P0 草案）

- 状态：Reopened，T0 解析 fixture 通过后锁定
- manifestVersion：1
- 产品决策：P0-D04

## 唯一事实来源

| 组件 | P0 基线 |
| --- | --- |
| Swift Markdown | 0.8.0；发布构建必须记录解析到的源码 commit 与包校验值 |
| swift-cmark | 0.8.0；发布构建必须记录源码 commit 与包校验值 |
| 底层方言 | cmark-gfm 0.29.0.gfm.13 |
| P0 用户契约 | cmark-gfm 0.29.0.gfm.13 及本文列出的 Inflow 数学/标题扩展 |
| 非阻断兼容报告 | CommonMark 0.31.2；不作为 P0 发布失败条件 |

Swift Markdown `ParseOptions` 不提供表格、删除线、任务列表和自动链接字面量的逐项开关；这些行为来自锁定的 cmark-gfm。P0 设置 `.disableSmartOpts = true`，不启用 block directives、symbol links 或其他 Swift Markdown 专有解析能力。T0 必须把实际 option raw value 与依赖 commit 输出到机器可读 manifest。数学节点由 Core 在代码、链接目的地和 raw HTML 排除后按 PRD 5.11 处理，不改变底层 Markdown 方言。

标题导航使用独立版本化 `github-compatible-heading-slug-v1`，不声称属于 GFM 规范。权威 oracle 是仓库内冻结的机器可读 `heading-slug-v1.json` 期望输出及其 SHA-256；初始期望值必须由 T0 在受控 GitHub.com 仓库实际渲染相同标题后捕获，记录捕获日期、页面响应/DOM 证据和 Git commit，并由独立测试实现复核。GitHub 后续行为变化只生成兼容报告，不静默改变 v1 oracle；变更契约必须提升版本。fixture 覆盖中文、Unicode、标点、重复标题和百分号解码；raw HTML `id` 在 P0 被转义，不参与导航。

## 偏差表与升级

T0 fixture 必须覆盖 cmark-gfm 0.29.0.gfm.13 的规范案例，并生成 `caseID / expected / actual / classification` 偏差表。声明支持的标题、强调、链接、图片、引用、列表、任务列表、代码、表格、删除线和自动链接字面量必须达到零“未解释偏差”：每个失败要么修复，要么在 PRD 中降级/移除对应能力；不能只记录失败后冻结。CommonMark 0.31.2 结果单独生成非阻断兼容报告。

退出条件：事实来源的 commit/校验值、`.disableSmartOpts`、全部声明语法的零未解释偏差、slug fixture 和兼容报告均已归档。依赖、commit、option 或契约偏差变化均视为方言变更，必须更新 manifestVersion、golden snapshot 和发布说明。
