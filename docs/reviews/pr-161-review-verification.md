# PR #161 评审核实与修复验证

日期：2026-10-29。基线：`3d3cc38d0d3406f66e551dca3ca8283fad86ed02`，对应 [PR #161](https://github.com/MaaAssistantArknights/MaaMacGui/pull/161)。本次修复针对该提交的四条评审意见；生产代码和回归测试的 SHA-256 记录在 [manifest.json](../../artifacts/pr-161-review/manifest.json)。

## 四条意见的结论

| 评审 | 核实 | 修复 |
| --- | --- | --- |
| [4409248943](https://github.com/MaaAssistantArknights/MaaMacGui/pull/161#discussion_r4409248943)：Copilot / 识别与运行中任务重叠 | 存在状态破坏，但“会直接追加并启动忙碌核心”描述过强。`ensureHandle()` 已检查 `running` 并抛错；此前调用方先设 pending，出错后又恢复 idle，所以核心继续运行、UI 却显示 idle。 | 在更改状态、访问 handle 前要求 idle；所有同一核心的启动入口使用同一准入检查。干员识别、寻访、小游戏也受保护，避免绕过进行中标记。 |
| [4409248947](https://github.com/MaaAssistantArknights/MaaMacGui/pull/161#discussion_r4409248947)：开始按钮可用但请求被拒 | 成立。核心回调可在异步调用返回前将 status 置为 idle，原菜单只观察 status。 | `isStartStopInFlight` 改为 Published；统一 `canStartTasks`，菜单、任务与工具按钮使用它；NewViewModel 观察 status 和操作标记两者，更新 Copilot 的可用状态。 |
| [4409248954](https://github.com/MaaAssistantArknights/MaaMacGui/pull/161#discussion_r4409248954)：Copilot 未启动却切至日志 | 成立。token 在配置校验和父级启动之前就已更新，父级忙碌时还正常返回。 | 拒绝请求时抛错；父级实际启动成功后才更新 token。配置无效、连接失败、核心启动失败均不发布成功信号。 |
| [4409248960](https://github.com/MaaAssistantArknights/MaaMacGui/pull/161#discussion_r4409248960)：启动期间请求被静默丢弃 | 成立。原 stop 和受保护的启动方法遇到进行中操作直接正常返回。 | 采用评审建议的“显式忙碌结果”方案：抛出 `taskOperationInProgress`，同时记录“当前正在启动或停止任务，请稍后重试。”；运行中启动则抛出 `taskAlreadyRunning`。不会把停止请求排队；原操作结束后可重试停止，回归用例验证重试真正调用核心停止。 |

## 可重跑的验证

运行：

```sh
python3 Tests/run-task-operation-tests.py
```

runner 从当前生产源码逐字提取状态声明、日常启动、停止、Copilot / 所有工具入口、菜单禁用条件及 Copilot 桥接方法和 Observation 订阅；编译执行 Swift 测试。替身仅用于核心 / 连接边界、与用例无关的配置及模型初始化。用 continuation Gate 精确暂停连接和停止，而非依赖休眠碰时序；不复制入口守卫实现。

- 原 PR 提交：82 项断言，27 项失败，退出码 1，见 [before.log](../../artifacts/pr-161-review/before.log)。runner 支持 `MAA_TEST_SOURCE_ROOT` 指向源码快照；对基线提取的源码跑同一 runner，可重复这些失败。
- 修复后：116 项断言全部通过，见 [after.log](../../artifacts/pr-161-review/after.log)。额外覆盖全部七类工具启动的跨 await 保护、仅操作标记释放时的 Observation 更新、启动 / 连接 / 停止失败后的释放、重复停止与停止重试。额外 Observation 用例在基线尚无此属性时不编译。
- `git diff --check` 通过。
- 完整 macOS Debug arm64 应用构建成功，见 [xcodebuild.log](../../artifacts/pr-161-review/xcodebuild.log)（仅去除行尾空白）。仍有工程既存的未消费 throwing Task 等警告；没有将此称为零警告构建。新增冲突拒绝在抛出前写入应用日志，不依赖调用者消费 Task 结果。

构建使用临时工程 `/tmp/maa-pr161-build-project/MeoAsstMac.xcodeproj`，源码目录符号链接指向本工作区。仅临时工程的外部 Core / 资源路径改成当前主机的绝对路径；未修改仓库工程文件。Swift 包使用本地主工程现有的忽略锁文件和已缓存依赖（JBird `c9d750d6ed069f37b4bd543327cffaa44280a594`、Sparkle 2.10.1、ZIPFoundation 0.9.20、swift-syntax 603.0.2）。

```sh
xcodebuild -project /tmp/maa-pr161-build-project/MeoAsstMac.xcodeproj \
  -scheme MAA -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/maa-pr161-derived \
  -clonedSourcePackagesDirPath /tmp/maa-pr163-20261029-derived/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

## 证据边界

这些测试复现并锁定 GUI 模型的准入、异步时序与通知行为，完整构建检查真实类型和 SwiftUI 调用点。未启动正式应用、连接游戏、实际执行识别 / 作业 / 寻访，未验证游戏端停止时延或真实 Core 回调次序，也未声称完成连接游戏后的 GUI 并发验收。没有修改真实偏好或任务文件；评审线程的 resolved 状态不能代替代码与测试核实。
