# SKIP 脚本承接记录（P00.1）

三个测试脚本因生产架构演进（#161×#178×#179 合并树）打印 SKIP 并 exit 0。本记录
给出原不变量到现行承接套件的映射，以及机器可验证的承接自证。

## 核对方法

- 机器自证：三个 SKIP 脚本在打印 SKIP 前验证每个自称承接者的 runner 脚本存在、
  承接测试源文件存在、且含「断言意图」级标记（文件级 grep）。任一缺失 → 退出码 1
  并打印缺失项；全部通过 → 打印 `succession verified: <承接者清单>` 后 exit 0。
- 人工核对：下表中的 file:line 为本次任务逐条对照的现行断言位置；
  covered = 不变量有直接断言；partial = 主干有断言、存在未覆盖子态；
  uncovered = 无现行断言。

## 运行结果（2026-11-01，分支 task/P00.1）

```
run-schedule-tests.sh:              PASS: 38 scheduling assertions
                                    PASS: 32 real processes race for one occurrence; exactly one claim
                                    PASS: 7 timer-manager weak-reference assertions        [本次新增]
run-background-schedule-tests.sh:   PASS: 49 background scheduling assertions
                                    PASS: 32 real agent checks publish exactly one intent for the stable batch winner
                                    PASS: 32 real GUI consumers transfer the helper claim exactly once
run-fight-configuration-tests.sh:   PASS: 35 stage cases; normalization, idempotence, payload fields, value semantics and plist round trips
run-daily-preparation-tests.py:     DailyPreparationTests: 45 production async assertions passed  [42→45]
run-achievement-tests.sh:           Achievements: 235 assertions passed
run-availability-observation-tests.py: RunAvailabilityObservationTests: 10 production assertions passed  [3→10]
run-completion-lifecycle-tests.py:  Completion lifecycle: 10 production-path assertions passed
run-task-startup-tests.sh:          SKIP … / succession verified: run-fight-configuration-tests.sh, run-daily-preparation-tests.py (exit 0)
run-achievement-timer-tests.py:     SKIP … / succession verified: run-achievement-tests.sh, run-schedule-tests.sh, run-background-schedule-tests.sh, run-daily-preparation-tests.py (exit 0)
run-task-operation-tests.py:        SKIP … / succession verified: run-schedule-tests.sh, run-background-schedule-tests.sh, run-completion-lifecycle-tests.py, run-daily-preparation-tests.py, run-availability-observation-tests.py (exit 0)
```

## 1. Tests/run-task-startup-tests.sh（原锚定 163 无参 startTasks）

原不变量（TaskStartupTests.swift）：

| # | 不变量 | 承接位置 | 状态 |
|---|--------|----------|------|
| TS-1 | 连接挂起期间的 UI 编辑不进入冻结核心载荷（关卡按归一化值进入载荷） | FightConfigurationTests.swift:43-51（normalizedStage 38 例+幂等）；DailyPreparationTests.swift:27 | covered |
| TS-2 | UI 与 plist 序列化双侧一致（归一化、往返不变形） | FightConfigurationTests.swift:62-74（payload 字段+plist 往返） | covered |
| TS-3 | 任务身份/启用态不被改写（禁用任务、非 fight 任务保持原样） | DailyPreparationTests.swift:25-28（克隆禁用不改冻结启用态、快照属原 profile） | covered |
| TS-4 | taskIDMap：核心任务号→任务 UUID 映射 | DailyPreparationTests.swift:29（回调按冻结任务读取） | covered |
| TS-5 | startCoreTasks 真正启动（started 标志） | DailyPreparationTests.swift:17（queued 仅含新附任务） | covered |
| TS-6 | 半途失败绝不启动核心 | DailyPreparationTests.swift:10-11（partial append must never start） | covered |

uncovered：无。

## 2. Tests/run-achievement-timer-tests.py（原锚定 startDailyTaskIfNeeded）

原不变量（脚本内嵌 probe）：

| # | 不变量 | 承接位置 | 状态 |
|---|--------|----------|------|
| AT-1 | 定时触发以 schedule 源路由（started/skipped/failed 三种结果均如此）并发射 .scheduledStart 成就事件 | ScheduleTimerManagerTests.swift:87（origin:.schedule 路由）+ DailyPreparationTests.swift:144-147（.scheduledStart 恰好一次、携带 runID，本次新增）；结果落账矩阵 ScheduleTests.swift:155/161 | covered |
| AT-2 | busy（每日运行占用/工具占用）时定时器不得启动 | ScheduleTests.swift:98（utilityTaskBusy）、:105（dailyTaskBusy） | covered |
| AT-3 | weak viewModel 失效后不得产生任何启动调用 | ScheduleTimerManagerTests.swift:98-100（本次新增：失效窗口零启动、零领取、无故障） | covered |

uncovered：无（AT-1 原「三结果枚举」由 handoff 落账矩阵 + 路由断言合并承接）。

## 3. Tests/run-task-operation-tests.py（原锚定旧 timer 入口 + 七工具入口）

原不变量（TaskOperationTests.swift）：

| # | 不变量 | 承接位置 | 状态 |
|---|--------|----------|------|
| TO-1 | 七个工具入口（Copilot/Recruit/Depot/Video/OperBox/Gacha/MiniGame）对 busy core 的拒绝矩阵：保持 busy UI、不碰 handle、不 append、错后可重试 | — | uncovered |
| TO-2 | 菜单 .disabled 谓词与生产 TaskButtons.swift 同源（忙时 start 谓词真、占用期 stop 谓词真） | run-availability-observation-tests.py:94-96（本次新增：正则提取两个生产谓词注入） | covered |
| TO-3 | 启动/停止挂起期重复入口的互斥拒绝（stop 拒绝时追加自身 busy 日志） | DailyPreparationTests.swift:80（tail 窗口拒绝不被吞）、:60（活恢复期 stop 改为中止请求） | partial |
| TO-4 | Copilot token：invalid/failed/pending 不发 token、成功发 token | run-availability-observation-tests.py:107-120（本次新增：生产 nonisolated(nonsending) 桥逐字编译） | covered* |
| TO-5 | 每个抛错路径释放占用并可重试 | DailyPreparationTests.swift:102、:118、:128（取消收口、降级收口、不毒化下次运行） | covered |
| TO-6 | stop 挂起/重入/失败/重复的完整语义 | DailyPreparationTests.swift:51、:60、:80、:101（stale 标志不阻塞全停、活恢复中止、tail 拒绝、abandon 消化） | covered** |
| TO-7 | 桥接观察：canStartTasks 变化触发 Observation 失效通知 | run-availability-observation-tests.py:101-103（原有 3 断言） | covered |
| TO-8 | coreIsRunning 复核分支：预留占用跨 core-state await、探针期间状态变化、取消不泄漏占用 | run-completion-lifecycle-tests.py:108-111（占用保留/重试）；预留顺序类断言 — | partial |
| TO-9 | 会话基线日志保留：拒绝时保留上一会话日志、冲突日志可见、启动后清除基线 | —（DailyPreparationTestSupport.swift:95 注释已改指本条） | uncovered |
| TO-10 | 完成回调与启动返回竞态：旧 waiter 不误收新 run、同 run 恰好收口一次 | run-completion-lifecycle-tests.py:105、:136 | covered |
| TO-11 | 定时触发 Started/Skip/Failed 分支的区分落账 | ScheduleTests.swift:155/:161（startFailed/stopFailed 落账）+ ScheduleTimerManagerTests.swift:89（started 落账） | covered |

\* TO-4 说明：四态（invalid/failed/pending/success）现行签名下均可达并已断言；原第 5
子态「busy 时保留旧 token」未再断言——其可达性依赖生产模型 busy 拒绝（TO-1 残余）。
\*\* TO-6 说明：恢复/检疫交织面已覆盖；纯 stopGate 挂起期重入 stop 的子态并入 TO-8 残余。

## 剩余 uncovered 清单（后续任务承接）

1. TO-1 工具入口 busy 拒绝：七个工具入口逐个编译并断言拒绝矩阵（入口级，量最大）。
2. TO-8 coreIsRunning 复核分支：预留占用跨 core-state await 的顺序断言、取消泄漏探针。
3. TO-9 会话基线日志保留：拒绝路径保留上一会话日志、冲突日志可见性、启动后清除。
4. TO-3 子态：stop 挂起期重复 stop 的冲突日志子态。
5. TO-4 子态：busy 时 Copilot 保留旧 token（依赖 TO-1）。
