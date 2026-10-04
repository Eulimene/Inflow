# 原生窗口菜单的所有权与回归验证

## 实现约定

应用使用 SwiftUI `App` / `DocumentGroup`，标准窗口菜单由 Scene 创建，动态窗口排列命令由 AppKit 管理。沿用 macOS 原生菜单、响应链与系统校验，不自行实现居中、填充、平铺或窗口列表。

原有 `NativeWindowMenuController` 监听主菜单通知和 `mainMenu` / `windowsMenu` 的 KVO，再通过异步任务重新挂接手工创建的子菜单。这让 SwiftUI 的命令更新与应用自己的替换逻辑争用同一个菜单入口，也会丢弃 `Window` Scene 自动提供的入口。其测试仅插入无 action 的“填充”“居中”占位项，不能证明系统动态菜单在实际跟踪期间稳定。

现在删除该控制器及启动挂接逻辑，保留框架生成的完整菜单。不要在窗口菜单更新、打开或失去焦点后重新赋值 `NSApp.windowsMenu`、清空菜单或重新插入系统命令。后续应用自定义命令应通过 SwiftUI `Commands` 的公开扩展点声明。

`DocumentWindowControls` 仅负责文档窗口能力配置；重复刷新不写入相同的 `styleMask` / `collectionBehavior`，不干预系统窗口命令。进程服务继续由应用代理持有，视图和各自的 Commands 按需观察服务。

参考：[Apple：构建和定制 SwiftUI 菜单栏](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)、[NSApplication.windowsMenu](https://developer.apple.com/documentation/appkit/nsapplication/windowsmenu)。

## 2026-10-04 验证

- Debug `build-for-testing` 通过。
- 真实 App 宿主定向 XCTest：`RecentDocumentsTests` 全部 28 项，加上帮助菜单与视图菜单两项，共 30 项，零失败。
- 帮助菜单测试现在同时检查原生窗口菜单保留 `Inflow 帮助` Scene 命令，以及唯一的最小化、缩放和前置全部窗口命令。该检查能发现旧控制器丢弃 Scene 命令的问题。
- 保留窗口策略重复刷新不写入系统属性的回归检查；移除只验证手工占位菜单项的测试。
- 实际界面检查：菜单持续打开后仍有“居中”和“填充”；两项均可执行；填充后切换源码/即时编辑，重新打开菜单仍保留这些命令；输入正文后立即打开菜单并等待后台统计和恢复更新，命令仍保留，随后撤销测试输入。

直接执行整个 `RecentDocumentsTests` 时，缺少真实应用菜单和系统窗口服务的进程出现失败，因此以上通过结果采用 `xcodebuild test` 的真实 App 宿主。直接测试不能替代此处的宿主测试或实际菜单跟踪验证。
