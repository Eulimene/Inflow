# Typora Capability Inventory（机器生成阅读视图）

> 请勿手工编辑本文件。权威数据来自 [`Typora能力清单.json`](./Typora能力清单.json)；运行 `python3 脚本/生成Typora能力清单视图.py` 重新生成。

## 基线

| 字段 | 值 |
| --- | --- |
| Inventory 版本 | `1.2.0` |
| 数据状态 | `evidence_baseline` |
| 基准产品 | Typora `1.14.6` / `stable` |
| 平台 | macOS 14 or later / `arm64` |
| 证据捕获日 | `2026-08-18` |
| 生成时间 | `2026-08-18T00:00:00+08:00` |

`evidence_captured` 只表示 build/平台标签、settings profile 标识、官方 URL/日期和 owner 已登记；不表示可复现设置工件已冻结、行为已验证、corpus 已通过或能力已 `aligned`。

## PRD 封闭世界覆盖

已映射 `23` 条 requirement，显式排除 `6` 条；两者必须恰好覆盖 PRD 第 11 节所有非 DoD `INF-P0`–`INF-P3` feature ID。

### 能力映射

| Requirement ID | Capability refs | 状态 |
| --- | --- | --- |
| `INF-P0-FILE-001` | `file.document-lifecycle` | `evidence_captured` |
| `INF-P0-MODE-001` | `editing.source-mode` | `evidence_captured` |
| `INF-P0-MARKDOWN-001` | `markdown.gfm-core` | `evidence_captured` |
| `INF-P0-THEME-001` | `theme.builtin-appearance` | `evidence_captured` |
| `INF-P0-SETTINGS-001` | `settings.editor-preferences` | `evidence_captured` |
| `INF-P0-EDIT-001` | `editing.core-commands`<br>`editing.search-replace`<br>`writing.spell-language` | `evidence_captured` |
| `INF-P0-RECOVERY-001` | `recovery.autosave-versioning` | `evidence_captured` |
| `INF-P0-NAV-001` | `navigation.links-outline` | `evidence_captured` |
| `INF-P0-EXPORT-001` | `export.native-single-document` | `evidence_captured` |
| `INF-P0-DIAGRAM-001` | `diagram.mermaid`<br>`math.inline-block` | `evidence_captured` |
| `INF-P1-MODE-001` | `editing.instant-rendered` | `evidence_captured` |
| `INF-P1-WORKSPACE-001` | `workspace.file-management` | `evidence_captured` |
| `INF-P1-EDIT-001` | `editing.clickable-task-list`<br>`editing.code-fence-tools`<br>`editing.interactive-structures`<br>`editing.smart-paste`<br>`editing.syntax-highlighting` | `evidence_captured` |
| `INF-P1-MARKDOWN-001` | `markdown.extended-writing` | `evidence_captured` |
| `INF-P1-RESOURCE-001` | `resource.image-operations`<br>`resource.image-workflow` | `evidence_captured` |
| `INF-P1-CONTENT-001` | `content.scripted-network-html`<br>`content.structured-html`<br>`resource.remote-image-loading` | `evidence_captured`, `exception` |
| `INF-P1-WRITING-001` | `writing.focus-typewriter`<br>`writing.statistics` | `evidence_captured` |
| `INF-P1-EXPORT-001` | `export.print-long-image` | `evidence_captured` |
| `INF-P1-THEME-001` | `theme.builtin-six` | `evidence_captured` |
| `INF-P2-EXPORT-001` | `export.advanced-single-document` | `evidence_captured` |
| `INF-P2-DIALECT-001` | `diagram.legacy-sequence-flow`<br>`markdown.emoji`<br>`markdown.highlight`<br>`markdown.subscript`<br>`markdown.superscript`<br>`math.advanced-academic` | `evidence_captured` |
| `INF-P2-THEME-001` | `theme.arbitrary-css` | `exception` |
| `INF-P2-PARITY-001` | `export.pandoc-formats`<br>`resource.image-upload` | `exception` |

### 覆盖排除

| Requirement ID | 排除理由 | Owner |
| --- | --- | --- |
| `INF-P0-PLATFORM-001` | Sandboxing, distribution provenance, vulnerability gates, accessibility and resource budgets are Inflow release controls rather than a Typora user-capability benchmark. | Release PM |
| `INF-P3-HEALTH-001` | The document health center is an Inflow differentiation target, not a Typora migration-parity claim. | Quality PM |
| `INF-P3-PROFILE-001` | A shared semantic rendering profile across preview, diagnostics and export is an Inflow differentiation target, not a Typora migration-parity claim. | Rendering PM |
| `INF-P3-HISTORY-001` | Inflow's Recovery-isolated local version timeline is a differentiated lifecycle contract and is not claimed as direct Typora parity. | Reliability PM |
| `INF-P3-MERGE-001` | Interactive block-level three-way merge is an Inflow differentiation target, not a Typora migration-parity claim. | Collaboration PM |
| `INF-P3-RESOURCE-001` | Resource governance and previewed structural batch edits are Inflow differentiation targets, not Typora migration-parity claims. | Resource PM |

## 能力证据记录

| Capability ID | Requirement ID | 状态 | 官方证据 | Owner |
| --- | --- | --- | --- | --- |
| `diagram.mermaid` | `INF-P0-DIAGRAM-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Draw-Diagrams-With-Markdown/) | Rendering PM |
| `math.inline-block` | `INF-P0-DIAGRAM-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Rendering PM |
| `editing.core-commands` | `INF-P0-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Shortcut-Keys/) | Editor PM |
| `editing.search-replace` | `INF-P0-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Search/) | Editor PM |
| `writing.spell-language` | `INF-P0-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Spellcheck/) | Editor PM |
| `export.native-single-document` | `INF-P0-EXPORT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Export/) | Export PM |
| `file.document-lifecycle` | `INF-P0-FILE-001` | `evidence_captured` | [Typora Support](https://support.typora.io/File-Management/) | Document PM |
| `markdown.gfm-core` | `INF-P0-MARKDOWN-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Markdown PM |
| `editing.source-mode` | `INF-P0-MODE-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Shortcut-Keys/) | Editor PM |
| `navigation.links-outline` | `INF-P0-NAV-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Links/) | Navigation PM |
| `recovery.autosave-versioning` | `INF-P0-RECOVERY-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Auto-Save/) | Reliability PM |
| `settings.editor-preferences` | `INF-P0-SETTINGS-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Quick-Start/) | Settings PM |
| `theme.builtin-appearance` | `INF-P0-THEME-001` | `evidence_captured` | [Typora Support](https://support.typora.io/About-Themes/) | Theme PM |
| `content.scripted-network-html` | `INF-P1-CONTENT-001` | `exception` | [Typora Support](https://support.typora.io/HTML/) | Security PM |
| `content.structured-html` | `INF-P1-CONTENT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/HTML/) | Security PM |
| `resource.remote-image-loading` | `INF-P1-CONTENT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Images/) | Security PM |
| `editing.clickable-task-list` | `INF-P1-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Task-List/) | Editor PM |
| `editing.code-fence-tools` | `INF-P1-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Code-Fences/) | Editor PM |
| `editing.interactive-structures` | `INF-P1-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Table-Editing/) | Editor PM |
| `editing.smart-paste` | `INF-P1-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Copy-and-Paste/) | Editor PM |
| `editing.syntax-highlighting` | `INF-P1-EDIT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Editor PM |
| `export.print-long-image` | `INF-P1-EXPORT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Export/) | Export PM |
| `markdown.extended-writing` | `INF-P1-MARKDOWN-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Markdown PM |
| `editing.instant-rendered` | `INF-P1-MODE-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Quick-Start/) | Editor PM |
| `resource.image-operations` | `INF-P1-RESOURCE-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Images/) | Resource PM |
| `resource.image-workflow` | `INF-P1-RESOURCE-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Images/) | Resource PM |
| `theme.builtin-six` | `INF-P1-THEME-001` | `evidence_captured` | [Typora Support](https://support.typora.io/About-Themes/) | Theme PM |
| `workspace.file-management` | `INF-P1-WORKSPACE-001` | `evidence_captured` | [Typora Support](https://support.typora.io/File-Management/) | Workspace PM |
| `writing.focus-typewriter` | `INF-P1-WRITING-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Focus-and-Typewriter-Mode/) | Editor PM |
| `writing.statistics` | `INF-P1-WRITING-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Word-Count/) | Editor PM |
| `diagram.legacy-sequence-flow` | `INF-P2-DIALECT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Draw-Diagrams-With-Markdown/) | Compatibility PM |
| `markdown.emoji` | `INF-P2-DIALECT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Compatibility PM |
| `markdown.highlight` | `INF-P2-DIALECT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Compatibility PM |
| `markdown.subscript` | `INF-P2-DIALECT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Compatibility PM |
| `markdown.superscript` | `INF-P2-DIALECT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Markdown-Reference/) | Compatibility PM |
| `math.advanced-academic` | `INF-P2-DIALECT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Math/) | Compatibility PM |
| `export.advanced-single-document` | `INF-P2-EXPORT-001` | `evidence_captured` | [Typora Support](https://support.typora.io/Export/) | Export PM |
| `export.pandoc-formats` | `INF-P2-PARITY-001` | `exception` | [Typora Support](https://support.typora.io/Export/) | Export PM |
| `resource.image-upload` | `INF-P2-PARITY-001` | `exception` | [Typora Support](https://support.typora.io/Upload-Image/) | Resource PM |
| `theme.arbitrary-css` | `INF-P2-THEME-001` | `exception` | [Typora Support](https://support.typora.io/About-Themes/) | Theme PM |

## Corpus / 操作样本登记

- Corpus：`0` 条
- Operation sample：`0` 条

当前没有冻结 corpus 或操作样本，因此 Inventory 不宣称任何能力已 `aligned`。新增证据时必须登记非全零 SHA-256、完整环境与 `passed | failed | pending` 结果。

## 公开 Exception Ledger

| Exception ID | Capability ID | Requirement ID | 状态 | 理由 |
| --- | --- | --- | --- | --- |
| `TYP-EXC-001` | `content.scripted-network-html` | `INF-P1-CONTENT-001` | `active` | Arbitrary document scripts, iframes, and implicit network media conflict with the Core offline and content-safety boundary. |
| `TYP-EXC-002` | `theme.arbitrary-css` | `INF-P2-THEME-001` | `active` | Unrestricted CSS, imports, URLs, and untrusted fonts would bypass deterministic rendering and resource policy. |
| `TYP-EXC-003` | `export.pandoc-formats` | `INF-P2-PARITY-001` | `active` | Broad import, export, CLI, and external executable discovery are outside the single-document Core boundary. |
| `TYP-EXC-004` | `resource.image-upload` | `INF-P2-PARITY-001` | `active` | Passing user file paths to arbitrary uploader applications, scripts or cloud services conflicts with the Core offline and process-trust boundary. |

## 机器门禁

生成器会强制校验：

- PRD 非 DoD feature ID 必须恰好出现在一条 capability mapping 或一条带 reason/owner 的 coverage exclusion 中。
- Benchmark 机器覆盖区与 capability ID 必须双向闭集，高亮/上标/下标/Emoji 等明列能力不得被宽泛 parity 项隐藏。
- capability、requirement、exception 和 evidence ID 必须唯一且双向引用一致。
- `evidence_captured` 不得引用 corpus/sample；`testing` 必须引用已登记证据。
- `aligned` 必须引用 Registry 中环境一致且结果全为 `passed` 的 corpus/sample。
- Registry 拒绝全零 SHA-256、不完整环境、无效结果和无人引用的孤儿证据。

从仓库根目录执行生成视图、内存负例和全局 JSON Schema/引用校验：

```sh
python3 脚本/生成Typora能力清单视图.py --check
python3 脚本/生成Typora能力清单视图.py --self-test
python3 脚本/校验文档.py
```

P1–P3 范围和 DoD 仍只由 [PRD](./产品需求文档.md) 定义；Inventory 不扩大产品范围。
