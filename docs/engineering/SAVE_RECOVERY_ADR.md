# SaveRecovery ADR（T0 草案）

- 状态：Proposed；T0 故障矩阵通过后 Accepted
- 适用：P0 保存、自动保存、关闭、Save As、外部修改与 Recovery

## 决策

AppKit 自动保存、draft 和 Versions 全部关闭。所有保存入口由唯一 `SaveCoordinator` 创建 `SaveEnvelope(saveNonce, documentID, version, exactData, hash, targetExpectation)`；`NSDocument.writeSafely` 是唯一物理 writer，`data(ofType:)` 只能消费 active envelope。自动保存是 Coordinator 防抖后显式发起的普通 safe-save。

保存顺序固定为：capture envelope → durable Recovery blob/index/head → `savePrepared(blobID)` fsync → target guard → `super.writeSafely` → 协调读取并校验 actual hash → `saveCommitted` fsync → 更新 committed base/dirty。self-write token 绑定 nonce、target、hash、revision。

documentID 是 app-owned UUID。Save As 通过 `SaveAsIntent` 原子迁移 bookmark、URL/resource aliases 和 revision；成功前保留旧 scope，原路径未来的新文件不复用该 ID。

Recovery 每 epoch 使用带 magic/schema/minReaderVersion 的 journal，恢复 handoff 必须先 durable 新 epoch head 再 consume 旧 epoch。正文按 `DataProtectionPolicy` 加密，配额与回收不得阻塞用户文件保存。

## T0 必过故障矩阵

- 所有 `NSSaveOperationType`、菜单/关闭/自动保存/Save As 均无法绕过 envelope。
- capture、blob、prepared、替换、完成校验、committed 每个边界强杀并正确恢复。
- guard 后外部写、替换后校验前外部写、FilePresenter 乱序均不清 dirty、不误认 self-write。
- retire/discard、恢复新 head、consume、journal rotate、SQLite 重建每个边界强杀。
- Save As 目标从 absent→created、revision 改变、bookmark 失败、scope 释放失败均保持身份一致。

任一 fixture 出现静默覆盖、正文不可恢复、重复恢复或错误清除 dirty，本 ADR 不得 Accepted，T1 不得开始。
