# Inflow CSS 主题

将 UTF-8 编码的 `.css` 文件放在此目录，一份文件对应一个主题。主题名来自文件名，例如 `my-paper.css` 显示为 **My Paper**。应用约每两秒刷新一次，也可选择“主题 → 重新加载主题”。切换后会保存选择，修改文件会更新已打开的文档。

目录通常位于 `~/Library/Application Support/Inflow/Themes`；沙盒构建请以“主题 → 打开主题目录”打开的位置为准。

## 内置主题

GitHub、Whitey、Night、Newsprint、Pixyll、Gothic 均来自同目录下的 CSS 文件，可直接复制修改。它们参考 [Typora 官方默认主题 CSS](https://github.com/typora/typora-default-themes/tree/master/themes) 的字体、标题层级、对齐、配色与区块样式，为原生编辑器实现对应风格；并非逐像素复刻，也不要求额外安装字体。

### 产品设计基准

2026-10-03 确定：Inflow 直接借鉴上述六套 Typora 默认主题，保留原名与各自的视觉特征。本轮讨论中的“清流”“纸笺”“静夜”概念不作为实施依据。主题设计以对应的官方 CSS 为基准，不以概念图重新解释其配色、字体或布局。

- **默认体验**：继续使用 GitHub；Night 提供深色写作选择。其余四套作为不同排版偏好并列提供，不新增首次启动选择步骤。
- **完整的排版差异**：每套主题同时定义正文与标题字体、字号比例、字重、对齐、段落节奏，以及链接、引用、代码、表格样式；不能只换背景色，也不统一套用新的品牌强调色。
- **中文适配**：无衬线主题使用合适的系统中文字体回退，衬线主题使用 Songti SC 等本机字体回退；代码保持等宽。以中英混排、粗体、标点与多行内容检查效果，不要求用户安装字体才能写作。
- **交互稳定**：主题切换不改变目录树和大纲的位置、显隐、分栏、写作视图或文档内容，保留用户独立设置的字号、行高与阅读宽度。侧栏显隐不是主题的一部分。
- **原生适配边界**：窗口、菜单与侧栏继续使用 macOS 原生控件；正文尽量忠实保留来源主题特征。不得将原生 CSS 桥接描述为任意 Typora 主题的完整兼容，也不得将 HTML 与 PDF 的导出效果混为一谈。

视觉验收应在同一份中英混排样例上逐套对照对应主题，覆盖 H1–H6、正文、粗斜体、链接、引用、列表、行内代码、代码块、表格和选区；同时检查窄窗口、放大字号与用户自定义行高。以下说明记录设计方向，不代表已经完成逐像素一致性或本轮视觉验收。

首次运行会从应用资源安装六份主题；升级时自动更新未修改的内置 CSS，保留用户修改过的版本和所有自定义主题。安装记录只保存文件指纹，更新后不会反复重写文件。删除内置文件后，下次扫描会重新安装默认版本。删除正在使用的自定义主题会回到 GitHub。无效文件会提示并跳过，原文件保留；无效内置主题使用应用内的默认副本。

| 主题 | 主要特征 |
| --- | --- |
| GitHub | 无衬线正文、粗标题、一级和二级标题分隔线、完整表格边框 |
| Whitey | 衬线正文、居中大标题、二级标题短横线、斜体三级标题、细引用线 |
| Night | 深灰背景、灰蓝正文、独立标题字体、紧凑标题层级与深色代码块 |
| Newsprint | 灰暖纸色、报刊衬线字体、较小标题层级、斜体引用与灰色代码底 |
| Pixyll | 大字号衬线正文、醒目的无衬线粗标题、宽松段落、带下划线的链接 |
| Gothic | 几何无衬线字体、居中轻标题、标题字距、红色链接与横线表格 |

中文衬线字体通过 CSS 的 `Songti SC` 回退链参与排版；加粗会同时作用于回退字体。未安装 Typora 使用的专用字体时，使用 CSS 中的本机替代字体。阅读宽度继续遵从用户设置，主题不把宽屏重新限制为窄栏。

## 样式集中维护

项目中所有主题与正文渲染的样式资源放在 `Resources/Themes`，新增视觉样式应修改这里的 CSS，不应在 Swift 中按主题名增加颜色、字体或布局分支：

- 根目录的六份 CSS：主题各自的视觉差异，也用于用户主题目录和 HTML 导出。
- `Base/default.css`：共同的字体、标题、间距、圆角、代码、引用、表格等默认值。原生渲染和 HTML 导出共同加载。
- `Base/light.css`、`Base/dark.css`：默认配色及语法颜色。
- `Base/html.css`：HTML 的布局、交互与导出辅助规则。
- `Base/contrast-*.css`、`Base/html-contrast.css`、`Base/reduced-motion.css`：高对比度和减少动态效果的样式。
- `Base/legacy-code.css`：旧版“代码优先”设置的兼容样式。

`Base` 是应用自带的公共资源，不单独出现在主题菜单。自定义主题覆盖公共默认规则；Swift 中保留 CSS 解析、TextKit 属性映射、几何计算及长度安全范围。操作系统原生窗口和菜单仍由 AppKit 绘制。

选区配色也从 CSS 读取：`--md-selection-background` 控制正文与表格的选中背景，`--md-selection-text` 控制选中文字，`--md-selection-overlay` 控制图片和图表的半透明选中遮罩。自定义主题可使用 `::selection`、`#write::selection` 或 `#write ::selection` 的 `background-color`／`color` 覆盖文字选区颜色；源码编辑保留系统选区配色。整段选择会同步标记其中的表格和图片，表格内多格选择则覆盖完整单元格。

## 一个可以直接使用的例子

创建 `my-paper.css`：

```css
:root {
  --bg-color: #f7f3e8;
  --text-color: #36332d;
  --primary-color: #9a5935;
  --md-border: #d5cdbc;
  --md-surface: #eee7d8;
  --md-inline-code: #e8e0d1;
}
body {
  background-color: var(--bg-color);
  color: var(--text-color);
  font-family: Georgia, "Songti SC", serif;
  line-height: 1.8;
  color-scheme: light;
}
#write h1 {
  color: #29251e;
  font-size: 2.2em;
  margin-bottom: .8em;
}
a { color: var(--primary-color); }
blockquote { color: #787167; border-left-color: #c6bba7; }
pre { background-color: var(--md-surface); }
code { background-color: var(--md-inline-code); }
th, td { border-color: var(--md-border); }
```

## 与 CSS / Typora 生态的兼容范围

Inflow 即时编辑和预览使用原生 TextKit，并非浏览器。CSS 文件可扩展主题，但不能保证任意 Typora 或网页主题直接兼容。参考：[Typora 自定义主题](https://theme.typora.io/doc/Write-Custom-Theme/)。

当前原生桥接支持：

- `:root`、`html`、`body`、`#write`；`p`、`h1`–`h6`、`a`、`blockquote`、`pre`、`code`、`th`、`td`、`tr:nth-child(even)` / `tr:nth-child(2n)`、`strong`、`em`、`li`，以及 `#write h1` 这样的后代选择器。
- 全局 CSS 变量、`var(--name, fallback)`、逗号分组、常用选择器优先级、同优先级后写覆盖和 `!important`。变量循环会停止解析。
- 正文背景、文字、标题、引用、链接、代码背景、表格边框与条纹颜色；十六进制颜色（含透明度）、逗号形式 `rgb()` / `rgba()` 和少量基础命名色。
- 正文字体及中文回退链、字号、行高；标题和段落等文本块的字体、字号、字重、斜体、颜色、字距、行高、上下间距与对齐，以及链接下划线。常用长度支持 `px`、`pt`、`em`、`rem`、`%`，不是完整浏览器单位运算。
- 标题下边线的宽度和颜色、引用左边线宽度与缩进、代码块边框和圆角、表格完整网格或横线。`--md-divider-width` / `--md-divider-height` / `--md-divider-color` 提供居中短分隔线；`table { --md-table-grid: rows; }` 选择原生横线表格，HTML 对应规则见 Whitey、Pixyll、Gothic。
- 正文最大宽度（不超过设置中的上限）及对称水平留白。设置中的字号／缩放会作用于主题字号；自定义行高设置优先于主题的默认行高。

`--bg-color`、`--text-color`、`--primary-color` 与 Typora 常用变量对齐。更多可用的 `--md-*` 变量可参考内置主题，如 `--md-heading`、`--md-secondary`、`--md-quote-bar`、`--md-table-stripe`，以及代码配色的 `--md-keyword`、`--md-string`、`--md-comment` 等。

伪元素、复杂选择器、媒体查询、Flex/Grid、动画、`calc()`、局部变量作用域、外部 `@import`、字体文件和 Typora 专有 DOM 不在原生兼容范围内。字体使用本机已安装字体。原生窗口、菜单和侧栏仍使用系统界面。

HTML 导出会嵌入选中主题的 CSS，并提供 `body#write`；浏览器可处理更多标准规则，但仍没有 Typora 专有 DOM，外部样式和字体不在当前导出资源支持范围内。导出开始时固定 CSS 内容，随后修改主题文件不会改变已开始的导出。个人版 PDF 仍使用固定浅色主题，不跟随自定义主题。

为保持读取简单，单份 CSS 最大 256 KiB。主题目录读取错误不会阻断编辑。
