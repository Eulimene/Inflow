# Extension Phase / Process Matrix

- matrixVersion：1
- 事实来源：生态阶段与进程/entitlement 的唯一机器可读基线；其他扩展文档只引用

## 阶段

| 阶段 | 可用能力 | 分发边界 |
| --- | --- | --- |
| E0 | Manager、Host、LaunchCapability、Local Broker、包/权限验证 | 仅内部 fixture |
| E1 | 主题、只读诊断、开发者模式、本地自签 Trust Store | 离线、无账号、低权限 |
| E2 | 编辑命令、fenced/block directive、单篇导出、声明式侧栏、官方 WASM 原型 | 本地签名/审核；无网络 |
| E3 | curated 免费市场、Domain Pack metadata、双签名/透明日志 | 官方/邀请制；第三方开放另有门槛 |
| E4 | 官方 typed 连接器、NetworkCredentialBroker、官方 AI Companion/adapter | 高信任人工审核 |
| E5 | 通用 NetworkServicePolicy、第三方 Provider/Tool、付费/企业 | 完整 SSRF/市场治理通过后 |

## 进程与权限

| Target | 首次阶段 | 正文 | 文件 | 网络 | Keychain | 责任 |
| --- | --- | --- | --- | --- | --- | --- |
| Main App | Core | 是 | 用户 scope | 否 | 仅 Core 数据域 key | UI、文档、Save/Recovery、typed tree |
| ExtensionManager.xpc | E0 | 否 | 插件目录 | 否 | Trust Store key | 安装、签名、Host lifecycle |
| LocalCapabilityBroker.xpc | E0 | 仅 opaque/批准片段 | 受限 FD | 否 | 可代用本地 credential ID | peer auth、权限、事务 |
| ExtensionHost.xpc | E0 | 仅低权限 snapshot；高信任数据面不可见 | 否 | 否 | 否 | JS/WASM 计算 |
| NetworkCredentialBroker.xpc | E4 | 仅 approved 流 | 否 | 是，唯一联网 target | 指定服务凭据 | typed adapter、上传/响应 sink |
| Render/Image helpers | Core | 单 job 内容 | 只读 FD | 否 | 否 | 一次性处理与强资源边界 |
| AI Model Manager | E4 | 否 | model store | 是 | 模型源凭据 | 下载/升级/清理模型 |
| AI Inference Worker | E4 | approved Envelope | 只读 model FD | 否 | 否 | 本地推理 |

每次 Release/生态里程碑由 CI 校验实际 target、签名、entitlement 和 IPC edge 与本矩阵一致。阶段/进程变化必须提升 matrixVersion，禁止在概念图中另行使用 E 编号表达扩展类型。
