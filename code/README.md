# Inflow 开发基线

Inflow 是一款本地优先的 Markdown 写作工作台。首发客户端支持 macOS 14 及更高版本，并仅支持 Apple Silicon。

应用无参数启动时先显示 Inflow 自己的主窗口，不自动新建文档，也不弹出 Finder 文件选择器。像 Typora 与原生 macOS 文档应用一样，新建、打开文件、打开文件夹和打开最近文档都收敛在顶部“文件”菜单，不在工作区重复放置操作按钮。只有用户明确选择打开操作时才出现系统面板。

## 目录

- `core/`：平台无关的 Rust 核心，通过稳定 C ABI 对外提供能力。
- `macos/`：SwiftUI/AppKit 客户端，负责文件授权、窗口、菜单与原生交互。
- `scripts/`：Xcode 调用的可重复构建脚本。
- `docs/`：代码侧架构决策与开发约束。

## 当前能力

- 应用包含适配 16–1,024 像素的原生 macOS App Icon，Finder、Dock 和应用信息使用同一份品牌资产；
- 无参数启动直接显示标题为 Inflow 的应用主窗口；文档框架只在显式新建或打开后介入。“打开文件夹…”使用 app-scoped 安全书签记住精确目录，递归列出可见的 `.md` / `.markdown`，忽略隐藏项和符号链接。
- 使用 macOS 原生文档生命周期新建、打开和保存 `.md` / `.markdown`；周期自动保存默认开启，可选 0.5 / 1 / 2 / 5 秒延迟，关闭后 ⌘S 与异常恢复保护仍可用；
- 已命名文档执行手动保存时，状态栏短暂显示“正在保存…”；保存失败不清除当前编辑或伪报成功，并提供重试、另存为和继续编辑三条退路；
- 文件无写入权限时保持可阅读与复制，明确提供“另存为… / 在 Finder 中显示 / 关闭”；另存成功后当前文档改在新位置继续编辑。
- 在单一 Markdown 源文本中进行系统原生撤销、重做与文本编辑；
- 默认由 Rust 核心识别标题、强调、链接、列表、代码、表格、脚注、公式等 Markdown 语法，macOS 在精确 UTF-8 快照匹配后分批高亮；可在设置中独立关闭，不修改正文或撤销历史。
- 可独立开关自动换行和物理行号；关闭换行后使用水平滚动，行号不会把同一物理行的视觉折行计为新行。
- “显示 > 专注模式”会弱化非当前段落，“打字机模式”会让光标行保持在编辑区中部；两者都只改变当前文档场景的注意力呈现。
- 由 Rust 核心验证 UTF-8，并保留已有文件的 UTF-8 BOM 与 LF/CRLF 风格；
- 从“打开…”、“打开最近”、Finder 或其他应用交给 Inflow 的非 UTF-8 Markdown 不进入编辑、不覆盖原文件，只提供 Finder 定位、原始字节复制或取消；复制使用目标指纹与原子写入。混合 LF/CRLF 或包含单独 CR 的 UTF-8 文件可先以规范化文本只读打开，用户明确选择 LF 或 CRLF 前所有修改和写回保持禁用。
- 混合换行横幅明确提供“使用 LF / 使用 CRLF / 关闭文档”；关闭不会作出隐式换行决定或写回原文件。
- 在源码编辑、实时分栏预览和纯预览间切换，三种视图共用同一份当前源文本；
- 实时预览新窗口默认 50% / 50%，拖动分隔线时限制在 25%–75%，并由每个文档窗口独立保存当前比例；
- 通过“显示 > 放大 / 缩小 / 实际大小”或 `⌘+` / `⌘-` / `⌘0` 以 10% 步长调整 50%–200% 的阅读缩放；
- 通过“显示”菜单或 `⌘1`、`⌘2`、`⌘3` 切换三种视图，命令只作用于当前文档窗口；
- 由 Rust 渲染 CommonMark、表格、脚注、删除线和任务列表，并为 Swift、Rust、JavaScript/TypeScript、Python、Shell、C/C++、JVM、Go、JSON、SQL、CSS 与 HTML/XML 等常见代码围栏提供无脚本基础配色；未知语言保持可读原文。预览默认禁止脚本与网络请求。数学公式和 Mermaid 默认呈现，可分别关闭并降级为普通文本或代码块；预览与导出使用同一份发起时配置。
- 本地静态 PNG/JPEG 在读取后校验实际类型、帧数、尺寸与扩展名，再以内联 data URL 交给预览；远程、缺失、未授权、动画、伪装或过大图片只显示可读占位，WebKit 不获得文件路径或网络权限。缺失或不可用的本地图片可在占位处选择替代文件、精确定位引用或忽略；远程图片可定位引用、复制原地址或关闭提示。
- 打开含相对图片或本地链接的既有文档时，可明确授权文档所在目录；安全作用域书签只在精确路径一致时跨启动恢复，移动或替换目录会使旧授权失效。
- 由 Rust 生成 H1–H6 文档大纲与可呈现内容的字数/字符数，重复标题按源码范围精确定位；状态栏可切换统计口径或隐藏统计。
- 默认开启“编辑器到预览滚动同步”和“点击预览标题定位源码”；两项可在设置中独立关闭。手动滚动预览会暂停跟随，直到再次滚动源码编辑器。
- 预览链接默认不直接执行：文档内锚点仅定位当前源码，外部网页与邮件链接在明确确认后才交给系统，本地 Markdown 、静态图片与 PDF 会复核普通文件、内容和文件快照；其他附件只在 Finder 中显示。目标缺失或权限失效时只允许重新授权同一精确路径，不会静默改写 Markdown。
- 在当前文档中执行 Unicode 字面查找、多行查询/替换、大小写条件、环绕导航、逐项替换和全部替换；全部替换先展示完整影响，并可用一次撤销恢复。
- 从源码、实时预览或纯预览均可通过“⌘F”查找；纯预览会进入可定位源文本的实时预览，“⌥⌘F”“⌘G”与“⇧⌘G”分别用于查找替换、下一个和上一个匹配。
- 通过“格式 > 粗体/斜体/删除线”对当前选区添加或移除 Markdown 标记，粗体与斜体支持 `⌘B` / `⌘I`；空选区会插入可继续输入的模板，模糊的局部标记不会被猜测性改写。
- 通过“格式 > 标题 > 一级至六级标题”转换当前行或多行选区；混合级别统一为目标级别，全部已是目标级别时取消标题，Setext 标题会作为完整块安全转换。
- 通过“格式 > 引用”对当前行或多行选区添加/移除一层 `>`；连续引用作为完整语义块处理，嵌套层级、空行、代码围栏与撤销边界均保留。
- 通过“格式 > 列表 > 有序/无序/任务”统一或取消完整行的列表结构；混合标记会规范为目标类型，任务完成状态、缩进、空行、Unicode 光标与一次撤销均保留。
- 通过“格式 > 行内代码”添加或移除 CommonMark 代码跨度；核心会选择避开内容的反引号长度，并保留边界空格、Unicode 选区和可继续输入的空模板。
- 通过“格式 > 代码块”包裹或取消完整行的 CommonMark 围栏；反引号围栏至少为 3 个，且总是比内容中最长连续反引号多 1 个，空光标会插入可继续输入的块模板。
- 通过“格式 > 清除格式标记”一次移除选区内完整、受支持的行内与块级标记；链接地址、普通符号及代码内容保持原样，没有完整语义标记时命令不可用。
- 通过“插入 > 链接…”或 `⌘K` 为当前选区插入链接；空选区会保留可继续编辑的链接文字，完整既有链接可安全更新目标，部分重叠、失效目标或过期正文快照不会被写回。
- 通过“插入 > 图片…”选择经内容验证的静态 PNG/JPEG：可明确授权后复制到文档同级 `assets`，或选择文档目录及其真实子目录作为相对资源目录，也可保留原文件位置；目录外位置、`..` 与符号链接会被拒绝。原位引用优先使用编码后的相对路径，必须使用绝对本地地址时会先说明可移植性与隐私影响。复制模式下同名必须明确选择覆盖、递增名称或改为保留原位置，正文和资源文件共享一次撤销/重做。
- 未命名文档发起选择、粘贴或拖入图片时，会先要求“保存并继续”；首次保存成功后只恢复该次冻结操作，取消、检查失败或保存失败不会创建资源。
- 资源设置默认让选择或拖入的既有图片复制到同级 `assets`；也可改为每次选择文档内相对目录、保留原位置或每次询问。粘贴和新建资源不允许保留临时原位置，但可按该偏好写入用户授权的相对目录。
- 在源码编辑器中粘贴图片时，只接管真实图片剪贴板内容，普通文本仍走 AppKit 原生粘贴；PNG/JPEG 经内容验证，TIFF 去除元数据后安全转为 PNG，再以 `image-001` 起的递增名称写入已授权相对目录，不静默覆盖。
- 向源码编辑器拖入单个 PNG/JPEG 文件时，以鼠标落点作为图片引用位置，并复用“复制到 assets / 选择相对目录 / 保留原位置”的同一验证与授权流程；不支持类型和多文件拖放不会被误写为 Markdown。
- 通过“插入 > 表格”生成 3 列×3 行（1 行表头、2 行数据）的可编辑表格；当前选区会安全放入首个表头，管道符、反斜杠与换行不会破坏表格结构，插入后首格保持选中。
- 通过“插入 > 分隔线”在当前选区之后插入真实的 CommonMark 分隔线；选中文本不会丢失，核心会自动补足块级空行并把光标放到分隔线后的可编辑空行。
- 通过“插入 > 脚注”为当前选区或光标位置追加唯一的 `note-N` 引用，并在文档末尾生成匹配定义；既有脚注名不会被复用，插入后定义内容保持选中。
- 通过“插入 > 公式”将单行选区转换为 `$...$` 行内公式，空选区或多行选区转换为定界符独占行的 `$$` 公式块；预览和 HTML 导出使用离线、安全的 MathML 呈现常用上下标、分式、根式、希腊字母与运算符。
- 通过“插入 > 图表”生成可编辑的 Mermaid 流程图模板；首发流程图、时序图、类图与状态图由 Rust 离线转换为无脚本 SVG，单个无效图表会在原位置展示源码与局部错误，不影响其他内容。
- 通过“文件 > 导出… > 导出 HTML…”将发起时的精确 UTF-8 快照生成不超过 100 MiB 的自包含 HTML；公式以 MathML、受支持 Mermaid 以 SVG、经验证的本地 PNG/JPEG 以 data URL 内联。缺失/未授权图片、本地链接或异常协议会在选择目标前说明；用户可返回修正，或明确继续生成带可读占位与不可点击链接文字的安全降级交付物。
- 通过“文件 > 导出… > 导出 PDF…”将同一份自包含交付快照排版为 A4 纵向 PDF，固定 20 mm 页边距；长文自动分页，本地图片、公式与图表不需要网络或源文件路径。
- HTML 与 PDF 共用导出发起时的源文快照、资源预检、安全作用域授权、目标指纹复核与原子写入；覆盖确认后目标若发生变化，本次交付会停止而不留下残缺文件。
- HTML 和 PDF 中内联的 PNG/JPEG 会在交付快照内重新栅格化，不复制 EXIF/GPS、设备、作者、注释或原始文件容器元数据；无法可靠移除时作为交付问题处理，不直接内联原图字节。
- PDF 组装后会原位清空 Quartz 自动生成的 Info 对象，不交付主机 macOS 版本、系统构建号或生成时间；容器结构不符合本地生成契约时失败关闭，不写入未校验 PDF。
- PDF 打印专用样式会将超宽代码行安全换行、把表格固定在可打印宽度并取消 Mermaid 的预览最小宽度，不把横向滚动区域直接裁到页边距之外。
- 超宽块级公式会在禁用页面脚本的排版容器中测量 MathML 固有宽度，只对超出可打印范围的公式按比例缩放；容器或缩放边界无法校验时停止交付。
- 导出预检与 PDF 排版期间显示精确 UTF-8 文档版本并可取消；取消后过期任务不会再打开目标面板或写入文件。已进入短暂的原子提交阶段时不伪装成可安全中断。
- HTML/PDF 成功写入后明示交付物名称与同一文档版本，并可立即打开、在 Finder 中显示或完成返回写作。
- 导出超限、检查失败、普通失败与目标变化分别提供冻结文案和安全下一步；重试、更换格式、另选位置或重新确认覆盖始终复用发起时的 UTF-8 快照，目标在确认后再次变化仍会停止写入。
- 每个打开的文档最迟每 5 秒向应用沙箱的 Application Support 原子更新一份恢复快照，包含源文、原文件授权、光标/选区、视图和滚动位置；正常关闭即清理，异常中断后只展示与最新磁盘字节不同的项目。
- “文件 > 恢复未保存的文档…”可对比恢复源文与当前磁盘内容，将单项或全部恢复为未命名文档，或经目标指纹复核后原子另存；恢复绝不直接覆盖原文件，未命名孤立项保留 30 天。
- 若原文件在恢复期间已变化，恢复中心会先明示差异入口，只允许将恢复内容作为未命名文档打开或另存，不会将它写回原文件。
- 恢复保护不可用时仍保留手动保存，用户可“重试保护”或明确“继续写作”；继续后同一故障不会被周期任务反复提示，主动重试失败才重新显示。
- 每份已命名文档持续比对“最近成功保存 / 当前编辑 / 当前磁盘”三份精确字节；外部修改、删除或只读会在任何写回前停止自动保存，不覆盖、不自动重建。
- 仅磁盘版本变化时可查看后直接重载或稍后处理；当前编辑也变化时则明示完整三方对比和覆盖前确认。文件被删除时只能另存、明确在原位置重建或稍后处理。
- 冲突面板可三方对比、另存副本、放弃本地编辑并重载，或先为磁盘新版本创建永久冲突副本再原子覆盖；确认后源文或磁盘再次变化时，旧决定立即失效。
- 冲突副本或删除后原位重建需要相邻文件写入时，会先请求 Markdown 所在的精确目录授权；取消或目录不匹配都不执行文件操作，磁盘事实变化后旧的暂不决定不会被沿用。
- “文件 > 另存为…”与“保存副本…”会先由 Rust 解析真实 Markdown 链接/图片，再按原目录和目标目录列出每项相对引用的保持、改变或不可用状态；确认绑定精确正文、源位置、目标指纹和相关资源快照，任一变化都会停止保存。
- 另存为成功后由原生文档生命周期把当前窗口重绑定到新位置，保存副本则继续编辑原位置；目标若已在另一个 Inflow 窗口打开会切换到该窗口并拒绝接管，目标确认后被占用或修改也不会被静默覆盖。
- “Inflow > 设置…”可即时调整 12–28 磅编辑器字号、1.2–2.0 行高和连续拼写检查，以及 600–1200 像素预览宽度、50%–200% 阅读缩放、浅色/深色/系统外观、四种阅读主题、数学公式与 Mermaid 呈现；设置只保存在本机且不改动 Markdown 正文。
- 预览、HTML 与 PDF 使用同一份发起时外观快照；增强对比度和减少动态效果可跟随系统或明确覆盖。“恢复默认”可选择当前分组或全部首发偏好，不删除文档、最近文档记录、恢复内容或匿名数据待发送记录。
- 本机设置写入失败时会保留当前会话中的选择，明示重新启动后可能恢复旧值，并提供重试或继续使用；重试会一次复核并写入完整首发偏好快照。
- 预览核心暂时失败时，源码编辑、手动保存和恢复保护保持可用；预览区域提供“重试预览”和“隐藏预览”，失败页不回显正文或本地路径。
- 单个公式或 Mermaid 图表无法呈现时会在原位置保留可读源码与原因，并提供“定位源文本”和“重试”；定位只接受与当前正文精确一致的 Rust UTF-8 源偏移，过期预览不会移动光标。导出中的降级结果不携带编辑偏移或无效按钮。
- “设置 > 隐私”中的匿名产品使用数据默认关闭，只有查看完整字段、用途、保留和退出说明后才能主动开启；文档内容、文件名/路径、链接、查询、选区和剪贴板永不进入记录。未配置可信 HTTPS 接收端时该功能保持关闭且不可开启。
- “帮助 > Inflow 帮助”始终打开内置写作、文件安全、本地资源、交付与恢复指南；帮助内容不依赖网络。
- 首次新窗口使用实时预览；用户主动切换后，后续新窗口从最近视图开始，恢复的旧窗口仍优先使用自己的视图状态。
- “设置 > 通用”可在始终新窗口与复用当前未编辑空白窗口之间选择，并将最近文档容量设为 5–50（默认 20）。最近记录可逐项移除或全部清空；原位置缺失时保留记录但不搜索替代文件。
- 通过“打开最近”或系统外部入口恢复的安全作用域访问会随对应文档生命周期保留，保证跨启动后的读取与保存；文档另存到新位置或关闭后立即释放旧位置授权。

## 构建

需要 Xcode 26 或兼容版本，以及 `rust-toolchain.toml` 指定的 Rust 工具链。

### 发布工作流助手

首选入口是 `scripts/release-workflow.sh`。它不会接收或保存 Apple 密码，也不会覆盖已有 Archive 或输出目录：

```sh
# 查看所有命令
scripts/release-workflow.sh help

# 只跑完整仓库门禁；临时 Archive 会在结束后清理
scripts/release-workflow.sh check

# 完整门禁 + 保留无签名 Archive、ZIP 与 SHA-256
scripts/release-workflow.sh candidate

# 打开某个 Archive 内的 App 做人工验收
scripts/release-workflow.sh open-archive \
  /absolute/path/to/Inflow.xcarchive

# 拷贝到另一台机器后复核 Archive 和 ZIP
scripts/release-workflow.sh verify-local-archive \
  /absolute/path/to/Inflow.xcarchive
scripts/release-workflow.sh verify-zip \
  /absolute/path/to/Inflow.xcarchive.zip
```

`candidate` 默认在 `build/releases/Inflow-local-<UTC 时间>/` 生成全新的候选目录；它先执行 Rust、XCTest、Analyze、Release 性能和 Archive 校验，再压缩并执行 `unzip -t`。无签名候选只供本地验收，不能分发。

直接分发需要钥匙串中存在匹配 Team ID 的 `Developer ID Application` 证书：

```sh
scripts/release-workflow.sh developer-id-archive YOUR_TEAM_ID
```

该命令显式要求 Developer ID、secure timestamp 与 hardened runtime，并对生成的 Archive 再跑完整严格门禁。工程使用自动签名但不检入 `DEVELOPMENT_TEAM`；Team ID 和证书属于发布环境。

Apple 公证凭据只存入钥匙串 profile：

```sh
xcrun notarytool store-credentials inflow-notary \
  --apple-id 'your-apple-id@example.com' \
  --team-id YOUR_TEAM_ID

scripts/release-workflow.sh notarize \
  /absolute/path/to/Inflow.xcarchive \
  inflow-notary
```

省略 `--password` 后 `notarytool` 会使用安全提示读取 App 专用密码，避免凭据进入 shell 历史。

公证命令会重新执行严格 Archive 门禁、保存 Apple 返回的结果与日志、装订 ticket、执行 Gatekeeper 评估，再生成最终 `Inflow-notarized.zip` 和 `.sha256`。可独立复核已导出的 App：

```sh
scripts/release-workflow.sh verify-notarized-app \
  /absolute/path/to/Inflow.app
```

以上签名与公证命令面向 Developer ID 直接分发。通过 Mac App Store 发布时，应在 Xcode Organizer 选择 App Store Connect，并仍先执行 `check`；不要对商店包运行 Developer ID 公证命令。

### 开发构建

```sh
xcodebuild \
  -project Inflow.xcodeproj \
  -scheme Inflow \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Rust 核心的独立验证：

```sh
cargo fmt --manifest-path core/Cargo.toml --check
cargo clippy --manifest-path core/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path core/Cargo.toml --locked
```

1 MiB / 10,000 行完整预览的 300 ms 预算必须使用与交付物一致的 Release 优化代码验证（Debug 构建中的 Rust 不代表发布性能）：

```sh
xcodebuild \
  -project Inflow.xcodeproj \
  -scheme Inflow \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .derivedData-performance \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:InflowTests/MarkdownRendererTests/testMegabyteDocumentDerivesCompletePreviewWithinUpdateBudget \
  test
```

该门禁同时复核预览尾部、最后标题与超过 1 MiB 位置的语法结果，不允许用截断或降级换取时间。冷启动、视图切换和输入停顿仍需在附录 A 的 8 GB、最低支持 macOS 目标机上执行发布验收。

可交付主程序必须从 Xcode Archive 获取，不能把未后处理的 Release 测试宿主当作交付物。归档会先保留 dSYM，再剥离主程序中的调试路径；验证脚本同时检查 arm64、macOS 14 最低版本、版本字段、开发机私有路径，以及 app 与 dSYM 的 UUID 一致性：

```sh
xcodebuild \
  -project Inflow.xcodeproj \
  -scheme Inflow \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -archivePath build/Inflow.xcarchive \
  archive
scripts/verify-release-archive.sh build/Inflow.xcarchive
```

脚本默认只接受带 hardened runtime、完整沙箱/文件/书签/网络权限、可解析且与匿名使用数据合同一致的隐私清单、macOS 14 arm64 Mach-O、纯系统动态依赖且无测试/模块/静态库污染的 App，且不是 ad-hoc 的有效分发签名。开发机没有发布证书时，可对 `CODE_SIGNING_ALLOWED=NO` 生成的临时归档使用 `scripts/verify-release-archive.sh --local …`；该模式只验证源码 entitlement 与其他归档事实，不代表签名、公证或分发验收通过。

完整自动化首发门禁使用 `scripts/verify-launch.sh --local`；取得真实签名归档后使用 `scripts/verify-launch.sh --signed-archive /path/to/Inflow.xcarchive`。自动化证据与仍需目标机、辅助技术、服务端或产品负责人完成的项目统一记录在 [`docs/launch-acceptance.md`](docs/launch-acceptance.md)。

匿名使用数据接收地址不检入仓库。只有在发布构建中将 `INFLOW_ANONYMOUS_USAGE_ENDPOINT` 注入为受控的 HTTPS URL，并验证服务端不超过披露的用途与保留期后，客户端才会提供开启操作。

## 提交规则

每个功能只在对应的 Rust 检查、单元测试与 macOS 构建通过后单独提交。
