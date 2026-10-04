# 文档加载性能与打点

## 加载链路与本次瓶颈

文件打开经过权限和编码预检、NSDocument 读取/解码、编辑器派生请求、Rust 处理与 JSON 桥接、原生属性应用和 TextKit 布局；Mermaid、数学公式等资源另行异步渲染。Rust 只负责其中一部分。后台解析很快，也不能抵消主线程上一秒以上的属性构建和排版。

2026-10-04 的固定样本测量确认了两个主线程热点：

- `NativeCSSStyles.value` 原先为每个文本片段的每个属性遍历全部规则，变量解析再次遍历规则。现在在不可变主题创建时编译层叠结果和变量，查询直接查表。主题重载产生新快照，不复用过期值，保留原有优先级、后声明覆盖与作用域行为。
- 标题的上下文间距原先为每个标题复制、裁剪和拆分全文前缀，随标题数量增长产生平方级工作。现在查找前一个非空段落，只提取必要文本，保留相邻标题和首标题的上下文选择器。

UTF-8/UTF-16 范围校验在 35,490 字节样本上约 10 毫秒，不是本次主要瓶颈，因此保留校验与版本保护，没有为缩短耗时跳过正确性检查。

## 本机测量

环境：Apple Silicon macOS、Xcode 26.6、Debug 构建；测量前后均开启打点。样本重复组合标题、中文、组合重音字符、emoji、粗体和链接，编辑视口为 1000 × 700。每轮使用新测试进程。

| 指标 | 优化前单次基线 | 优化后三次中位数 |
| --- | ---: | ---: |
| 100 段 / 8,790 字节，Rust 与桥接派生 | 14.74 ms | 14.03 ms |
| 100 段，原生展示与布局 | 331.57 ms | 101.10 ms |
| 400 段 / 35,490 字节，Rust 与桥接派生 | 56.60 ms | 56.61 ms |
| 400 段，原生展示与布局 | 1,331.20 ms | 259.77 ms |

优化后三次原生展示结果：100 段为 108.92 / 99.35 / 101.10 ms；400 段为 262.68 / 259.73 / 259.77 ms。400 段展示耗时减少约 80%。基线仅一次采样，结果是本机诊断证据，不是跨机器性能保证。

第三轮 400 段的内部 `editor.presentation` 为 227.66 ms，其中属性补丁 46.61 ms、覆盖层布局 68.47 ms。外层展示测量还包括展示切换前后工作；内外阶段不可直接相加。仍有超过一帧的同步主线程工作，不能据此宣称大文档完全无卡顿。后续应根据真实文件的记录定位增量属性应用、可见区域布局等剩余成本。

本样本是内存中的组件基准，不含磁盘读取、Finder 打开到首帧、启动恢复、大型表格或图表全部渲染完成的时间。不能将上表当作真实文件端到端打开延迟。

## 开启与读取日志

在 Xcode 的 Run 环境变量设置 `INFLOW_PERFORMANCE_TRACE=1`，或给应用添加启动参数 `-InflowPerformanceTracing YES`。重新启动后生效。移除环境变量和启动参数即可关闭；如果另行写入过同名 UserDefaults 键，也需要关闭该键。

```sh
log stream --level debug --predicate 'subsystem == "com.inflow.desktop" AND category == "Performance"'
```

Instruments 的 Points of Interest 可观察 `DocumentPipeline` signpost。日志包含阶段名、随机 span ID、父 span ID、毫秒数、字节数、开始时是否在主线程（`start_main`）和结果（`completed` / `failed` / `cancelled`）。不包含文档正文、文件路径或 JSON 数据。

| 阶段 | 边界 |
| --- | --- |
| `file.open` | 最近文档/文件打开控制器发起请求到其完成回调，不代表首帧已出现；其他系统打开入口不一定经过此阶段 |
| `file.preflight` | 权限/编码预检，包含后台等待 |
| `file.decode` | MarkdownDocument 数据解码 |
| `editor.derive` | 编辑器派生过程，包含等待后台引擎 |
| `bridge.dispatch` | 单次请求的编码、Rust 调用、结果复制与解码 |
| `bridge.encode` / `rust.dispatch` / `bridge.copy` / `bridge.decode` | JSON 编码、FFI 调用、返回数据复制、Swift DTO 解码 |
| `bridge.validate` | 返回数据与源文档及 UTF-16 范围的校验 |
| `editor.presentation` | 同步构建/应用原生呈现属性和布局 |
| `editor.attribute_patch` / `editor.overlay_layout` | 属性差异提交与覆盖层布局；属于 presentation 内部阶段 |
| `resource.queue.<kind>` | 未直接命中缓存的资源请求，从入队到返回，包含排队与渲染时间 |
| `resource.render.<kind>` | 实际调用离线 JavaScript 渲染器的时间，排队后缓存命中不会出现该阶段 |

`bytes=0` 表示该阶段没有采集字节数；Rust 调用阶段的字节数是请求包大小，不一定是全文大小。异步阶段的耗时包含等待，`start_main=true` 不代表全过程阻塞主线程；同步 `editor.presentation` 的耗时才直接反映这一段主线程占用。父子关系使用 TaskLocal 传播；AppKit 回调与独立生命周期任务可能形成新的根 span，因此不是覆盖全部打开流程的单一分布式 trace。

打点默认关闭；关闭时不生成 UUID、signpost 或日志，也不计算字节数等懒求值元数据。开启后使用系统统一日志，不在加载路径同步写文件。

## 重复验证

在仓库根目录执行：

```sh
code/scripts/profile-document-load.sh
# 可指定输出目录：
code/scripts/profile-document-load.sh /tmp/inflow-load-profile
```

脚本构建独立 Debug 测试产物，并以新进程重复三轮组件基准。默认产物在 `code/Build/LoadProfile`，其中 `build.log` 是构建日志，`run-1.log` 到 `run-3.log` 包含测试结果与完整阶段耗时。失败时脚本以非零状态退出，应检查对应日志。比较时保持机器、构建配置、样本和打点开关一致；性能数据不作为依赖 CPU 速度的硬性测试阈值。

本次 140 项定向 XCTest 全部通过，覆盖引擎派生、Unicode/版本保护、主题层叠与变量、原生编辑器、文档打开和离线资源渲染；三轮基准均验证标题数量与原文不变。新增检查确保关闭打点时不会计算日志元数据，以及主题重载不会复用旧结果。

## Rust 主题迁移后的复测（2026-10-04）

使用相同 Debug 组件样本与三轮新进程基准，迁移后的 400 段原生展示为 232.99 / 233.33 / 232.15 ms，中位数 232.99 ms；上一轮中位数为 259.77 ms，约再减少 10%。100 段展示中位数 97.21 ms，400 段 Rust 与桥接派生中位数 57.48 ms。测试仍不代表真实磁盘打开到首帧的端到端时间。

新增 `theme.compile` 覆盖 Rust 编译与快照桥接，`theme.catalog` 覆盖后台目录刷新。稳定主题复用 Rust 编译快照；原生属性查询不扫描规则。首次创建内置主题的同步启动入口仍存在，日志可用于后续把初始化继续前移，不能把后台定时刷新等同于所有启动工作都已离开主线程。
