# Inflow P0 决策记录

- 状态：Partially Accepted；P0-D04、P0-D05 为 Reopened，P0-D07 为 Conditional
- 决策日期：2026-08-17
- 适用范围：P0 首个可发布版本
- 规范来源：[PRD](./PRD.md)；本记录只汇总已冻结决策，不另行定义范围

当前只授权进入 T0 风险原型。P0-D04、P0-D05 和 P0-D07 达到各自退出条件前，不得把全部 P0 标记为 Frozen，也不得据此启动无回退路径的全面实施。

## 决策摘要

| ID | 决策 | 规范位置 |
| --- | --- | --- |
| P0-D01 | 产品版本统一为 P0–P3，工程阶段为 T0–T6，生态阶段为 E0–E5；PRD 是产品范围唯一来源 | PRD §11 |
| P0-D02 | 自动保存关闭时所有 dirty 文档关闭均询问；开启时等待保存，失败再询问；未命名非空始终询问；“不保存”清除会话快照 | PRD §5.1.4 |
| P0-D03 | 外部双修改暂停自动保存并展示三方差异；覆盖前创建冲突副本并二次确认；磁盘删除不自动重建 | PRD §5.1.5 |
| P0-D04 | **Reopened**：以 cmark-gfm 0.29.0.gfm.13 为用户契约，声明语法零未解释偏差并冻结 `.disableSmartOpts`、commit、slug fixture 后接受 | PRD §5.3 |
| P0-D05 | **Reopened**：P0 raw HTML 转义、远程图片占位；URL/Image/Export/Bridge/Entitlement policy、完整进程树可强制终止和全局资源预算通过 `SanitizerManifest`、[RenderHelperIsolation ADR](../engineering/RENDER_HELPER_ISOLATION_ADR.md) 后接受 | PRD §10.3 |
| P0-D06 | 单文件授权不足时首次请求包含目录并保存安全作用域书签；拒绝后不重复弹窗；标题 slug 固定 | PRD §5.14 |
| P0-D07 | **Conditional**：PDF 冻结 A4/20 mm/主题/深色/无内容丢失与宽度上限；T0 [PDF Path ADR](../engineering/PDF_PATH_ADR.md) 在三条实现路径中条件选择 | PRD §5.12 |
| P0-D08 | P0 支持 UTF-8/UTF-8 BOM；新文档无 BOM + LF；已有文档保留 BOM 和主换行；其他编码禁止直接覆盖 | PRD §5.1.2 |
| P0-D09 | Undo 属于文档实例；设置分层；纯预览查找切分栏；Save As 检测相对引用；恢复使用 clean shutdown、TTL 和稳定 document ID | PRD §5.1–§6 |
| P0-D10 | P0 使用官网手动更新；自动更新器在首次启用前另立 ADR | PRD §9.1 |

## 变更规则

任何修改上述决策的变更必须同时更新 PRD、技术方案、验收 fixture 与本记录，并在合并说明中标注受影响的决策 ID。技术文档和对标路线不得单独改变 P0–P3 版本归属。
