# 平台项与等价语义处置记录（P34 · 2026-11-01）

基线：Mac 3f2cf2d / 上游 dev-v2 51dac87（本 run 只读复核 head 未漂移）。本文档为 P34 决策记录：对 8 个"平台/开发接口"条目逐项给出处置与依据，重开 7 个历史"平台不适用"成就的评估路由，并拆出 U15 可迁移部分。**范围缩减/不适用均不记录为实现成功**；等价能力是否满足由对应验收包（P29/P30）实测决定。

来源核对方法：上游引用在 pin 检出（MaaAssistantArknights@4d94832，含 51dac87 内容）逐条读取；Mac 引用在 3f2cf2d 树逐条读取。核对中发现 checklist 两处引用偏移，已在对应条目标注更正。

## 1. 逐项处置

### T04 · 已关闭的沙中之火 Fire
- 上游依据：`src/MaaCore/Task/Interface/ReclamationTask.cpp:39-43` —— `theme == ReclamationTheme::Fire` 时打日志 "is no longer available" 并 `set_tasks({ "Stop" })` 直接返回。
- Mac 现状：`ReclamationConfiguration.swift:150` 仍保留 `case fire = "Fire"` 枚举与 UI 入口；下发后 Core 执行 Stop。
- 处置：**保留"不适用/已退役"**。不重新制作停服内容；Mac 侧在 P17（工具箱）处置 Tales/锚点语义时同步保证 Fire 入口不误导用户以为可游玩（过期资源不可执行原则）。
- 完成边界：不计实现成功；用户可见说明归 P17 验收。

### C14 · 开发者 SingleStep 单步战斗 API
- 上游依据：`src/MaaCore/Task/Interface/SingleStepTask.cpp:14`（`set_params` 存在，随 Core 分发）。
- Mac 现状：`Maa.swift` MAATaskType 与 `MAATask.swift` 均无 singleStep case（grep 证实为 0 处）。
- 处置：**开发接口保留在 Core 侧，不作为 GUI 缺陷**。不为普通用户加入口；若未来调试工具需要，走独立开发面板任务，不并入日常任务列表。
- 完成边界：GUI 范围明确=19 个公开任务类型；接口本身不宣称"Mac 已封装"。

### N10 · Windows 原生 PC 窗口绑定与输入/截图模式
- 上游依据：`ConnectSettingsUserControlModel.cs:969-976`（Win32Extra：SendMessageWithWindowPos / PostMessageWithWindowPos 等 Win32 专属输入法）。
- Mac 现状：`ConnectionSettingsView.swift` 只有 ADB/MacPlayTools(PlayCover)/MaaToolClient 类通路，无 Win32。
- 处置：**Win32 后端不移植**。Mac"原生游戏"能力由 X06（Mac App Store 游戏）探索；X06 未通过前不得宣称 Mac 原生游戏已支持。
- 完成边界：不以"枚举了后端名"替代运行证据（呼应 P02/P19）。

### N11 · LDPlayer/MuMu12 Windows 增强与 DirectML GPU
- 上游依据（核对更正）：checklist 主 2 链接 `PerformanceUserControlModel.cs#L29` 指向"性能设置/GPU 选项"类；MumuExtras 实际位于 `Models/EmulatorConnectionExtra/MuMu12Extra.cs:216-222` 与 `ConnectSettingsUserControlModel.cs`（TouchMode=MumuExtras）；GPU 选择在 `PerformanceUserControlModel`（RefreshGpuOptions）。
- Mac 现状：无对应增强通路；Mac 可用后端由 P02（能力矩阵）与 P19（连接验收）逐一验证。
- 处置：**Windows 专属组件保留不适用**。不以 MaaFwAdb/MumuExtras 枚举代替 Mac 侧运行证据。
- 完成边界：P02/P19 的 Mac 后端矩阵各自闭合，本条不产生实现工作。

### U07 · Windows 完整包/增量包拖入及恢复安装
- 上游依据：上游文档 `docs/zh-cn/manual/introduction/others.md`（zip 包恢复安装说明）。
- Mac 现状：`UpdaterSettingsView.swift` / `ResourceUpdateView.swift` 资源侧已有 GitHub/Mirror 渠道；主程序侧为 fork 单版本发布（release.yml，无 SUFeedURL 守卫保留）。
- 处置：**Windows 包格式不移植**；Mac 的"安装/升级/恢复"等价流程由 P28 定义并实测（本地包校验、旧包升级、失败回退）。
- 完成边界：Mac 更新链必须真实通过（P28），本条自身不计实现成功。

### U15 · WPF 自定义背景、Monet、托盘标题/动效皮肤
- 上游依据：`BackgroundSettingsUserControlModel.cs:41`（自定义背景）；`GuiSettingsUserControlModel.cs:98`（SetUseTrayIcon）、:119（标题滚动 title scrollable）。
- Mac 现状：`MeoAsstMacApp.swift`/`LogView.swift` 无背景/托盘动效等价物。
- 处置：**不能整行豁免**。拆出可迁移交互 → P29（Mac 等价界面）：
  - 背景/配色（Monet 风格系统取色）→ P29 的界面外观区；
  - 标题展示（等价：窗口标题自定义/菜单栏标题）→ P29；
  - 托盘（Mac 等价：菜单栏常驻图标，衔接 P20 的 S18 关窗保留）→ P29 呈现、P20 承载生命周期；
  - 动效皮肤 → P29 按 macOS 界面惯侢单独定语义，确实不适用处单独给依据。
- 完成边界：P29 实测闭合前，U15 维持"部分等价已拆出、未交付"状态。

### Z07 · C/Python/Java/Rust/Go 等绑定与 CLI
- 上游依据：`src/MaaCore/Assistant.cpp:333` 起（append task 字符串分发，开发集成面的根）。
- 处置：**沿用主 Core 开发生态，不在 GUI 仓库复制 SDK**。GUI 只承诺自身 Swift 封装的兼容性（P02 兼容矩阵）。
- 完成边界：若未来扩大 GUI 之外范围，新开独立任务与兼容矩阵，不并入本计划。

### Z08 · Debug 任务与底层 pipeline 全部节点
- 上游依据：同 Z07（Assistant.cpp 的完整 task 分发表包含内部/调试节点）。
- 处置：**维持开发工具范围**。生产任务能力以 19 个公开任务 + 165 参数字段的迁移与验收为准（P32）；不以"支持 Custom pipeline"宣称全部节点已验收。
- 完成边界：checklist 以公开任务/参数/用户入口为边界，本条为边界声明而非功能缺口。

## 2. 历史平台成就重开评估（转 P30）

以下 7 个成就原表标"平台不适用"，全部重开，由 P30 逐 ID 给出 Mac 等价语义或明确阻塞，不得自动排除：

| 成就 ID | 上游语义 | Mac 等价方向 |
|---|---|---|
| CustomizationMaster | 自定义背景触发 | P29 背景方案落地后触发 |
| DisappearTrick | 隐藏/恢复窗口 | 窗口隐藏/显示（衔接 P20 S13 热键） |
| TitleTweaker | 自定义标题 | P29 标题自定义 |
| AllChannelBroadcast | 全渠道类型配置齐全触发（非真实发送） | 按"配置齐全"语义单独判定（P24 多配置） |
| Rules | 读规则/关于页 | Mac 等价：查看使用说明/关于页交互 |
| VersionClick | 版本号点击彩蛋 | 关于页版本点击等价交互 |
| PallasCheers | 特定交互彩蛋 | 读上游实际触发点后定 Mac 等价 |

注：AllChannelBroadcast 上游实际由"所有渠道类型配置齐全"触发（`ExternalNotificationSettingsUserControlModel.cs#L116`），非 Windows 固有障碍，也不得改写为"九渠道全部发送成功"。

## 3. 与下游包的衔接清单

- P17：Fire/Tales/锚点语义与过期资源门槛。
- P02/P19：Mac 后端能力矩阵与如实标注（N10/N11 边界）。
- P28：Mac 更新链等价（U07 边界）。
- P29：U15 可迁移项（背景/配色/标题/动效）+ 菜单栏呈现。
- P30：7 成就逐 ID 闭合。
- P32：19 任务/165 字段边界声明（Z08）。

## 4. 结论

8 项全部给出处置与依据（其中 Z07/Z08 的 Mac 现状核对：Maa.swift/MAATask.swift 仅暴露公开任务类型、无绑定/CLI 代码，与"开发范围"结论一致）：6 项保留不适用/开发范围（T04/C14/N10/N11/Z07/Z08，均有上游代码级依据；Z07/Z08 的 Mac 现状=仅经 Swift 封装层消费 Core 生态，仓库内无 SDK/CLI 复制物，grep 佐证）、1 项等价流程转 P28（U07）、1 项拆分迁移转 P29（U15）。7 成就重开转 P30。本记录为范围处置，**不计作任何实现成功**。
