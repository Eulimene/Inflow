# PDF Path ADR（T0 Conditional）

- 状态：Conditional；T0 golden 后选择唯一 P0 路径

## 输出契约

A4、四边 20 mm、当前主题、深色背景、正文宽度上限和无内容丢失；高级分页不属于 P0。

## 决策顺序

1. 优先验证 `WKWebView.createPDF`。
2. 若不能满足同一 golden，验证 MainActor 异步编排的 `NSPrintOperation`。
3. 两者失败才评估独立分页管线。

解析、清洗、图片重编码和 IO 在后台；WebKit/AppKit API 只由 MainActor 异步编排，不同步阻塞。每条候选路径使用完全相同的 fixture、macOS/WebKit/font manifest，记录失败证据、页面截图、文本抽取和文件结构。选定后删除运行时二选一；未选路径不进入 P0 代码。
