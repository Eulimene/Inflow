# Typora 默认主题修复与验证（2026-10-03）

本次修复关闭了[原核对报告](theme-implementation-audit-2026-10-03.md)列出的实现问题与默认值测试失败。六套主题保留原名、本机字体回退、用户阅读宽度及系统窗口外观。验证针对原生 TextKit 构建，不是 HTML 模拟图。

## 逐项结果

| 原问题 | 修复 | 验证结果 |
| --- | --- | --- |
| 代码高亮绕过主题 | CodeMirror token 使用 keyword/tag/string/number/comment/type 语义色 | 六主题最终 NSTextStorage 颜色断言通过；Night 实际显示紫色关键字、红色字符串、橙色注释 |
| 表头及单元格中文加粗不一致 | 粗体和斜体转换保留并同步转换字体回退链；表头测量使用粗体字重 | CoreText 中英文字形 run 的粗体断言通过；六主题截图中中文表头加粗完整、无多余换行 |
| GitHub 标题缩小 | H1–H4 改为 2.25 / 1.75 / 1.5 / 1.25 em，恢复标题间距及表格边框、内边距 | 原生字号、光标及嵌套行内样式回归通过，截图确认 |
| Night 参数偏离 | 链接改为浅灰并加下划线；引用线 2px、左外距与内距；H5 粗体、H6 .93em 白色及各级标题行高；方形列表 | 链接颜色、下划线、引用缩进断言通过，代码、引用和各级标题截图确认 |
| Whitey 标题间距和列表标记简化 | 分别设置 H1/H2/H3 段前间距；桥接相邻标题规则；方形列表 | 原生 H1 段前间距、列表标记断言通过，实际界面确认 |
| Gothic 英文标题未大写 | H1/H2 通过 TextKit 字形转换显示大写，补齐标题行高、间距与内边距 | 实际大写字形、源文本不变、首标题间距断言通过；截图确认 |
| H6 被统一淡化 | 默认继承主题标题色，淡化仅由 GitHub 自身 CSS 声明 | 六主题最终文字颜色断言通过；Newsprint、Pixyll、Gothic 截图确认 |
| 表格几何没有进入原生布局 | Night/Pixyll 铺满可用宽度；各主题单元格内边距与行高进入测量、布局、追加行及公式预览；Pixyll 表头分隔线 2px | 六主题内边距断言；620pt 宽度与 240pt 窄宽度、双倍字号、单元格边界验证通过；实际表格截图确认 |
| 偏好测试期待旧宽度 1200 | 持久化失败测试读取 CSS 默认阅读宽度，仍验证保存失败时旧值保留、会话值和重试行为 | 测试通过 |

## 自动验证

- Debug `build-for-testing`：通过，macOS arm64，`CODE_SIGNING_ALLOWED=NO`。
- 从现有 `personal-xctest-scope.tsv` 选择 AppPreferencesTests、RenderedMarkdownEditorTests、MarkdownRendererTests、MarkdownHighlighterTests 的全部 current-direct 测试：**108 项，0 失败、0 跳过**。未改变测试分区或删除测试。
- 其中 AppPreferencesTests 为 25 项；扩展已有主题集成测试以验证实际字形、最终属性、窄表格及双倍字号。GitHub 标题变化涉及的旧断言已改为读取主题规则，同时保留光标、样式组合与字体大小关系的验证。
- 首次沙箱运行无法启动 WebKit，代码 token 保持普通文字色；允许本地 AppKit/WebKit 服务后重新执行完整相关范围，全部通过。最终[测试日志](assets/theme-fix-2026-10-03/editor-tests.log)为允许本地渲染服务后的结果。
- `git diff --check`：通过。

## 实际界面验证

运行 `/private/tmp/inflow-theme-fix/DerivedData/Build/Products/Debug/Inflow.app`，对相同中英混排样例依次切换全部六主题，检查顶部与下半部分。截图分辨率 2400 × 1520；下半截图是滚动视口，包含正常裁切，不是完整长图。保留原有 16 字号设置、100% 缩放、1080 阅读宽度、跟随系统外观。

六份仓库 CSS、构建内 CSS 和当前用户主题文件逐字节一致；样例与修复前文件逐字节一致。构建动态库、CSS、样例指纹见 [evidence.json](assets/theme-fix-2026-10-03/evidence.json)。

| 主题 | 顶部 | 下半部分 |
| --- | --- | --- |
| GitHub | [截图](assets/theme-fix-2026-10-03/github.png) | [截图](assets/theme-fix-2026-10-03/github-lower.png) |
| Whitey | [截图](assets/theme-fix-2026-10-03/whitey.png) | [截图](assets/theme-fix-2026-10-03/whitey-lower.png) |
| Night | [截图](assets/theme-fix-2026-10-03/night.png) | [截图](assets/theme-fix-2026-10-03/night-lower.png) |
| Newsprint | [截图](assets/theme-fix-2026-10-03/newsprint.png) | [截图](assets/theme-fix-2026-10-03/newsprint-lower.png) |
| Pixyll | [截图](assets/theme-fix-2026-10-03/pixyll.png) | [截图](assets/theme-fix-2026-10-03/pixyll-lower.png) |
| Gothic | [截图](assets/theme-fix-2026-10-03/gothic.png) | [截图](assets/theme-fix-2026-10-03/gothic-lower.png) |

## 验证边界

这是针对原报告问题的验收，并非全部产品发布门禁。窄宽度、双倍字号覆盖原生表格几何；没有把它表述为所有主题的整窗 200% 人工验收。Typora 本机仍在试用到期激活页，对齐基于其随附 CSS，不声称与 Typora 逐像素一致。Gothic 原生大写支持 ASCII 英文，Unicode 一对多大写扩展保持原样，以保留源字符映射。PDF 导出沿用已约定的固定浅色主题。
