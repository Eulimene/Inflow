# AI Runtime Manifest（E4 草案）

- manifestVersion：1
- 状态：Proposed；冻结前只允许官方内部原型

## 本地模型生命周期

Model Manager 将模型下载/导入到 content-addressed store，要求发布者签名、SHA-256、格式/架构、license、来源和扫描结果。默认总 quota 20 GiB，安装前显示体积；升级先并存验证，新版本健康检查失败自动回滚，未使用 30 天的旧版本可提示清理。用户删除模型时无活动 Worker 才移除最后引用。

Manager 只把已打开的只读 FD、期望 hash 和 manifest 交给禁网 Inference Worker；Worker 在 mmap/加载前二次计算 hash、核验 inode/size/seals，不按路径重开。每模型声明最大 RSS/CPU/context/output；Supervisor 默认单 Worker、RSS 8 GiB 上限，超限终止，不影响 Core。

## 远程费用与取消

请求必须设置实际 `max_tokens`，默认取模型/用户/Core 最小值且不超过 4,096；用户可设置单次费用硬上限和月度预算，预计或累计费用达到上限前停止/拒绝。价格未知时必须逐次确认，不能启用自动连续请求。取消由 Network Broker 关闭 upload/download、发送服务支持的 cancel endpoint，并忽略/不计入 UI 的晚到 token；供应商仍计费的可能性必须披露并进入审计。

## 分发与数据

E4 仅官方审核的 Companion、typed BYOK adapter 和 AI Action。第三方 Provider/Tool 到 E5；开发者模式只能用合成无敏感 fixture。Provider Host 无任意 State/Cache/自由日志，只得到 opaque request ID 和结构化结果元数据；正文只在 Core→Network Broker 或 Core→Inference Worker 数据面流动。

冻结要求覆盖模型替换竞态、FD 不可变性、hash mismatch、磁盘满、升级回滚、quota 清理、OOM/取消、服务端晚到响应、token/cost cap 和 prompt injection corpus。
