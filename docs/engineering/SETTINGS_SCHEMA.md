# Settings Schema

- schemaVersion：1
- 事实来源：PRD §6；本文给出机器实现所需 scope/迁移

| Key | 类型/默认 | Scope 与继承 | Reset/迁移 |
| --- | --- | --- | --- |
| autosave.enabled | Bool / true | global | reset true |
| autosave.delaySeconds | Enum / 1 | global | 旧值夹到 0.5/1/2/5 |
| editor.fontSize | Double / 15 | global → workspace | reset global；workspace 删除覆盖 |
| editor.spellcheck | Bool / true | global → workspace | 同上 |
| editor.wrap | Bool / true | global → workspace | 同上 |
| preview.contentWidth | Double / 760 | global → workspace | 夹到 600…1200 |
| preview.theme | Enum / system | global → workspace | 未知值回 system |
| rendering.mermaid | Bool / true | global → workspace | 从旧 `extensions.mermaid` 迁移 |
| rendering.math | Bool / true | global → workspace | 从旧 `extensions.math` 迁移 |
| window.mode | Enum / preview | window restoration | 不参与偏好 reset |
| window.splitRatio | Double / global initial 0.5 | global 仅决定新窗口初值；每窗口保存当前值 | 夹到 0.25…0.75 |
| window.sidebar/scroll/focus | state | window restoration | 不参与继承 |
| document.encoding/BOM/lineEnding | document property | document only | 不随 reset 改写 |
| versionStore.enabled | Bool / true | global → workspace | P3 生效 |
| versionStore.retentionDays | Int / 30 | global → workspace | P3，1…3650 |
| versionStore.maxBytes | Int / 500 MiB | global → workspace | P3，最小 100 MiB |

继承只允许 document property > workspace > global；窗口状态不进入该链。Schema 迁移在事务中完成，失败保留旧数据并回退默认，不修改文档或 Recovery。新增/删除 key 必须提升 schemaVersion 并提供迁移 fixture。
