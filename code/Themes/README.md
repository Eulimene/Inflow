# Inflow CSS 主题

将 UTF-8 编码的 `.css` 文件放在此目录，一份文件对应一个主题。主题名来自文件名，例如 `my-paper.css` 显示为 **My Paper**。应用约每两秒刷新一次，也可选择“主题 → 重新加载主题”。切换后会保存选择，修改文件会更新已打开的文档。

目录通常位于 `~/Library/Application Support/Inflow/Themes`；沙盒构建请以“主题 → 打开主题目录”打开的位置为准。

## 内置主题

GitHub、Whitey、Night、Newsprint、Pixyll、Gothic 均来自同目录下的 CSS 文件，可直接复制修改。它们参考 [Typora 官方默认主题 CSS](https://github.com/typora/typora-default-themes/tree/master/themes) 的字体、标题层级、对齐、配色与区块样式，为原生编辑器实现对应风格；并非逐像素复刻，也不要求额外安装字体。

### 产品设计基准

2026-10-03 确定：Inflow 直接借鉴上述六套 Typora 默认主题，保留原名与各自的视觉特征。本轮讨论中的“清流”“纸笺”“静夜”概念不作为实施依据。主题设计以对应的官方 CSS 为基准，不以概念图重新解释其配色、字体或布局。

- **默认体验**：继续使用 GitHub；六套主题都提供浅色和深色配色，并保留各自的字体与排版偏好，不新增首次启动选择步骤。
- **完整的排版差异**：每套主题同时定义正文与标题字体、字号比例、字重、对齐、段落节奏，以及链接、引用、代码、表格样式；不能只换背景色，也不统一套用新的品牌强调色。
- **中文适配**：无衬线主题使用合适的系统中文字体回退，衬线主题使用 Songti SC 等本机字体回退；代码保持等宽。以中英混排、粗体、标点与多行内容检查效果，不要求用户安装字体才能写作。
- **交互稳定**：主题切换不改变目录树和大纲的位置、显隐、分栏、写作视图或文档内容，保留用户独立设置的字号、行高与阅读宽度。侧栏显隐不是主题的一部分。
- **原生适配边界**：窗口、菜单与侧栏继续使用 macOS 原生控件；正文尽量忠实保留来源主题特征。不得将原生 CSS 桥接描述为任意 Typora 主题的完整兼容，也不得将 HTML 与 PDF 的导出效果混为一谈。

视觉验收应在同一份中英混排样例上逐套对照对应主题，覆盖 H1–H6、正文、粗斜体、链接、引用、列表、行内代码、代码块、表格和选区；同时检查窄窗口、放大字号与用户自定义行高。以下说明记录设计方向，不代表已经完成逐像素一致性或本轮视觉验收。

首次运行会从应用资源安装六份主题；升级时自动更新未修改的内置 CSS，保留用户修改过的版本和所有自定义主题。安装记录只保存文件指纹，更新后不会反复重写文件。删除内置文件后，下次扫描会重新安装默认版本。删除正在使用的自定义主题会回到 GitHub。无效文件会提示，原文件保留；已有主题继续使用上一份有效快照，首次加载的无效内置主题使用应用内副本。目录读取与主题编译在后台执行。

| 主题 | 主要特征 |
| --- | --- |
| GitHub | 无衬线正文、粗标题、一级和二级标题分隔线、完整表格边框 |
| Whitey | 衬线正文、居中大标题、二级标题短横线、斜体三级标题、细引用线 |
| Night | 灰蓝配色、独立标题字体、紧凑标题层级；浅色为冷灰纸面，深色为深灰背景 |
| Newsprint | 灰暖纸色、报刊衬线字体、较小标题层级、斜体引用与灰色代码底 |
| Pixyll | 大字号衬线正文、醒目的无衬线粗标题、宽松段落、带下划线的链接 |
| Gothic | 几何无衬线字体、居中轻标题、标题字距、红色链接与横线表格 |

中文衬线字体通过 CSS 的 `Songti SC` 回退链参与排版；加粗会同时作用于回退字体。未安装 Typora 使用的专用字体时，使用 CSS 中的本机替代字体。阅读宽度继续遵从用户设置，主题不把宽屏重新限制为窄栏。

## 自动外观与手动切换

在“设置 → 外观与预览 → 浅色与深色模式”选择 **跟随系统 / 浅色 / 深色**。默认跟随系统，操作系统外观变化时自动更新；手动选择会立即覆盖当前窗口和设置窗口的外观并保存偏好。切换只更新呈现，不修改正文、选择或撤销历史。

所有内置主题均有两套配色，保留相同的字体、字号、间距和表格结构。SCSS 的 `theme.foundation` 接收 `$palette` 和 `$dark-palette`，共用一次排版定义；共享模块生成标准的 `@media (prefers-color-scheme: dark)`。切换模式时只选择已经编译的不可变主题快照，不读取文件或重新解析 CSS。系统变化通过原生外观通知同步正文、表格、代码颜色及图表。

Rust 的 `compile_theme` 命令接受可选 `dark` 布尔值（缺省为浅色），缓存键同时包含 CSS 内容与模式。编译结果的 `resolved_css` 保留供 HTML 使用的规则，浅深色媒体条件在 Rust 层按请求展开。Windows/Linux 宿主只需提供实际模式，消费相同快照；无需复制 CSS 解释逻辑。HTML 导出在手动模式下固定配色，在跟随系统模式下保留标准媒体查询，由查看者的系统选择配色。个人版 PDF 继续使用固定浅色的导出配置。

自定义 CSS 可使用 `@media (prefers-color-scheme: light)` 和 `@media (prefers-color-scheme: dark)` 提供两套配色；只有固定颜色的旧主题仍按作者的颜色显示。升级不会覆盖用户修改过的主题，需要自适应时可复制新版内置主题或补充媒体规则。

## 使用 SCSS 集中维护内置样式

仓库内的样式源码统一放在 `code/ThemeSources`，`code/Themes` 中的 CSS 是生成产物，随源码一起提交。修改内置样式时只编辑 SCSS，不手改生成的 CSS，也不在 Swift 中按主题名增加颜色、字体或布局分支。用户主题目录中的自定义 CSS 仍可直接编辑，不受此构建流程影响。

源码和产物保持相同的相对路径，例如 `ThemeSources/github.scss` 生成 `Themes/github.css`。维护时优先选择最小的修改范围：

- `shared/_fonts.scss`：集中维护正文、代码和各主题的字体回退链。
- `shared/_theme.scss`：共享正文、链接、代码、表格基础规则及标题字号生成逻辑。主题通过 `foundation` 传入两套配色，通过 `headings` 和 `row-table` 传入排版差异。
- `shared/_palettes.scss`：共享浅色、深色默认配色；原生基础样式和 HTML 基础样式引用同一份定义。
- 根目录六份 `.scss`：只维护各主题的配色、字号参数和独有规则。标题色默认跟随正文，引用线默认跟随边框，代码和表格背景默认跟随表面色；只有不同的值才需覆盖。
- `Base/*.scss`：公共基础、HTML 布局、辅助功能与兼容规则。

例如修改所有主题的代码字体，只需改 `shared/_fonts.scss` 中的 `$code`；调整 GitHub 的配色，只需改 `github.scss` 传给 `theme.foundation` 的 `$palette`。主题特有规则放在 mixin 调用之后，以保持覆盖顺序。共享模块用下划线开头，不会独立生成 CSS。新增内置菜单选项仍需注册主题，新增 SCSS 文件本身不会改变菜单。

在 `code` 目录执行：

```sh
cargo xtask themes         # 编译所有入口，只写入有变化的 CSS
cargo xtask verify-themes  # 检查生成物是否最新，不修改文件
```

Xcode 构建会在资源复制前自动执行编译；`cargo xtask test` 和三平台 CI 会校验生成物，并运行构建工具测试。请将 SCSS 和生成的 CSS 一起提交。编译器会先编译全部入口，语法错误时不写入任何输出；删除入口后需明确删除对应的旧 CSS，校验会报告遗漏。

预处理使用锁定版本的纯 Rust [grass](https://docs.rs/grass/0.13.4/grass/) 构建工具，不需要 Node.js 或 Dart 环境。源码采用 Sass 的 [`@use`](https://sass-lang.com/documentation/at-rules/use/) 模块和 [mixin](https://sass-lang.com/documentation/at-rules/mixin/)；引入其他 Sass 语法时以锁定编译器的实际支持为准。SCSS 仅在构建时编译，不打包进应用，也不参与打开文件或切换主题的运行时路径。macOS、Windows、Linux 共用生成的标准 CSS 和 Rust 解析合同，字体与原生绘制仍由各宿主适配。

以下是生成资源的职责：

- 根目录的六份 CSS：主题各自的视觉差异，也用于用户主题目录和 HTML 导出。
- `Base/default.css`：共同的字体、标题、间距、圆角、代码、引用、表格等默认值。原生渲染和 HTML 导出共同加载。
- `Base/light.css`、`Base/dark.css`：默认配色及语法颜色。
- `Base/html.css`：HTML 的布局、交互与导出辅助规则。
- `Base/contrast-*.css`、`Base/html-contrast.css`、`Base/reduced-motion.css`：高对比度和减少动态效果的样式。
- `Base/legacy-code.css`：旧版“代码优先”设置的兼容样式。

`Base` 是应用自带的公共资源，不单独出现在主题菜单。自定义主题覆盖公共默认规则；Rust 负责 CSS 解析、兼容层叠、变量展开、颜色/长度解析及表格列宽策略；Swift 只消费编译快照，执行 TextKit 属性映射、字体测量与绘制。操作系统原生窗口和菜单仍由 AppKit 绘制。

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
- 表格 `width: 100%`、单元格四侧 `padding`、`line-height` 和表头下分隔线；宽度会随可用阅读宽度重新计算，正文与表头使用同一中文字体回退链。
- `ul { list-style-type: square; }`；标题 `text-transform: uppercase` 在原生视图中转换 ASCII 英文字形，保持 Markdown 原文、选择与复制的字符映射。多字符 Unicode 大写扩展不转换。
- 标题间距支持受限的 `h1+h2`、`h2+h3`、`h1:first-child`、`h2:first-child`；标题的 `em` 以标题字号计算，`rem` 以正文基准字号计算。
- 正文最大宽度（不超过设置中的上限）及对称水平留白。设置中的字号／缩放会作用于主题字号；自定义行高设置优先于主题的默认行高。

`--bg-color`、`--text-color`、`--primary-color` 与 Typora 常用变量对齐。更多可用的 `--md-*` 变量可参考内置主题，如 `--md-heading`、`--md-secondary`、`--md-quote-bar`、`--md-table-stripe`，以及代码配色的 `--md-keyword`、`--md-string`、`--md-comment` 等。

上述浅深色媒体条件以外的媒体查询、伪元素、复杂选择器、Flex/Grid、动画、`calc()`、局部变量作用域、外部 `@import`、字体文件和 Typora 专有 DOM 不在原生兼容范围内。字体使用本机已安装字体。原生窗口、菜单和侧栏仍使用系统界面。

HTML 导出会嵌入选中主题的 CSS，并提供 `body#write`；浏览器可处理更多标准规则，但仍没有 Typora 专有 DOM，外部样式和字体不在当前导出资源支持范围内。导出开始时固定 CSS 内容，随后修改主题文件不会改变已开始的导出。个人版 PDF 仍使用固定浅色主题，不跟随自定义主题。

为保持读取简单，单份 CSS 最大 256 KiB。主题目录读取错误不会阻断编辑。

## Rust 迁移合同

`profile.json` 当前声明 `inflow-native-legacy` 版本 0。这是现有主题的兼容合同，不是设计中的完整 v1 语义树支持。Rust 编译结果通过 ABI 3.1 的 `portable_presentation` capability 输出；规则、值和诊断的含义由所有宿主共享。`pt` 按 96/72 转为逻辑像素，`em/rem/%` 保留单位类型，供宿主提供最终度量；版本 0 的百分比仍沿用现有调用处的基准，不承诺完整 Web 百分比布局。

样式源码只维护 `ThemeSources` 中的一份 SCSS，构建后生成此目录的 CSS。macOS 从此目录打包名为 Themes 的资源目录；Windows/Linux 应使用相同资源和 Rust 合同，不能重新实现解析器。三 OS 的 CI 工作流已配置，本机 Windows/Linux Rust 目标交叉编译检查通过，目标 OS 的测试执行及原生呈现尚未验收。共享核心测试通过不能替代字体、输入法与实际画面的验收。
