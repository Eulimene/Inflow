# RenderHelperIsolation ADR（T0 草案）

- 状态：Proposed；T0 公开 API 原型通过后选择路径并 Accepted

## 候选路径

路径 B（优先验证）：每 job 独占 `RenderHelper.xpc`、WKProcessPool 和非持久 data store。Supervisor 必须用公开 API/可发布机制建立 job→XPC/WebContent/Networking 全 PID 映射，聚合进程树 RSS，超时/超限强杀全部 PID并等待退出。

路径 A（强制回退）：若 B 无法证明进程归属或完整终止，改为 Supervisor 直接拥有的一次性非 WebKit JS/DOM runtime 子进程；运行时、DOM shim、签名、公证、许可证和 sandbox 必须固定，且同样受 Sanitizer Manifest 限额。

## 决策测试

- 在同步死循环、内存膨胀、WebContent crash 和 XPC cancel 下记录所有 PID 生命周期。
- 强杀后 2 秒内所有关联进程退出、RSS 回收且下个 job 为干净 realm。
- Release sandbox entitlement 与 Archive matrix 一致，无网络/文件路径能力。
- 100 次并发/取消压力下不出现 orphan、跨 job cookie/cache/DOM 或 Main 卡顿。

只有一条路径全部通过才可 Accepted；否则 D05 保持 Reopened。
