# Inflow CSS 主题

将 UTF-8 编码的 `.css` 文件放在此目录，一份文件对应一个主题。主题名来自文件名，例如 `my-paper.css` 显示为 **My Paper**。应用约每两秒刷新一次，也可选择“主题 → 重新加载主题”。切换后会保存选择，修改文件会更新已打开的文档。

目录通常位于 `~/Library/Application Support/Inflow/Themes`；沙盒构建请以“主题 → 打开主题目录”打开的位置为准。

## 内置主题

GitHub、Whitey、Night、Newsprint、Pixyll、Gothic 均来自同目录下的 CSS 文件，可直接复制修改。它们是 Inflow 为原生编辑器实现的对应风格，并非 Typora 原版主题文件或逐像素复刻。

首次运行会从应用资源安装六份主题；已有文件不会被覆盖。删除内置文件后，下次扫描会重新安装默认版本。删除正在使用的自定义主题会回到 GitHub。无效文件会提示并跳过，原文件保留；无效内置主题使用应用内的默认副本。

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
- 正文字体、字号、行高；标题和段落等文本块的字体、字号、字重、颜色、字距、行高、上下间距与对齐。常用长度支持 `px`、`pt`、`em`、`rem`、`%`，不是完整浏览器单位运算。
- 正文最大宽度（不超过设置中的上限）及对称水平留白。设置中的字号／缩放会作用于主题字号；自定义行高设置优先于主题的默认行高。

`--bg-color`、`--text-color`、`--primary-color` 与 Typora 常用变量对齐。更多可用的 `--md-*` 变量可参考内置主题，如 `--md-heading`、`--md-secondary`、`--md-quote-bar`、`--md-table-stripe`，以及代码配色的 `--md-keyword`、`--md-string`、`--md-comment` 等。

伪元素、复杂选择器、媒体查询、Flex/Grid、动画、`calc()`、局部变量作用域、外部 `@import`、字体文件和 Typora 专有 DOM 不在原生兼容范围内。字体使用本机已安装字体。原生窗口、菜单和侧栏仍使用系统界面。

HTML 导出会嵌入选中主题的 CSS，并提供 `body#write`；浏览器可处理更多标准规则，但仍没有 Typora 专有 DOM，外部样式和字体不在当前导出资源支持范围内。导出开始时固定 CSS 内容，随后修改主题文件不会改变已开始的导出。个人版 PDF 仍使用固定浅色主题，不跟随自定义主题。

为保持读取简单，单份 CSS 最大 256 KiB。主题目录读取错误不会阻断编辑。
