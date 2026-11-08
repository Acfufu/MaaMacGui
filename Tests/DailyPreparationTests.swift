import Foundation
@main struct DailyPreparationTests {
 @MainActor static func main() async {
  var count=0
  func check(_ value: Bool,_ message: String) { precondition(value,message);count+=1 }
  if CommandLine.arguments.contains("--accelerated-combat-timeout") {
   let model=MAAViewModel(); let core=model.handle!
   try! await model.miniGame(name:"Fixture")
   model.activeRunHasRoguelike=true; model.roguelikeInCombat=true
   model.roguelikeDelayAbortUntilCombatComplete=true
   try! await model.stop()
   check(core.stopCount == 1 && model.infos.contains("等待战斗结束超时，现在停止。"), "accelerated production deadline stops once on timeout")
   check(!model.roguelikeWaitingForCombat && model.canStopTasks, "timeout releases stop admission")
   print("PASS: \(count) accelerated combat-timeout checks (600s production literal asserted by runner)")
   return
  }
  for failStop in [false,true] {
   let model=MAAViewModel();let core=model.handle!
   model.tasks=[.init(task:.fixture),.init(task:.fixture)];core.failAppendAt=2;core.failStop=failStop
   let result=await model.startDailyTasks()
   check(result == .failed && core.startCount == 0,"partial append must never start")
   check(model.taskIDMap.isEmpty,"failed preparation must clear ownership")
   check(model.dailyRunCoordinator.lastTerminal?.cleanupSucceeded == !failStop,"terminal must reflect native cleanup failure")
   if failStop { check(model.handle == nil,"failed cleanup must isolate handle") }
   else {
    check(core.queued.isEmpty,"stopped core must have an empty queue")
    core.failAppendAt=nil;model.tasks=[.init(task:.fixture)]
    check(await model.startDailyTasks() == .started && core.queued.count == 1,"next run must contain only newly appended tasks")
   }
  }
  let model=MAAViewModel();let gate=Gate();model.connectionGate=gate;model.dailyTaskProfile="A"
  let original=DailyTask(task:.fixture);model.tasks=[original]
  let pending=Task { await model.startDailyTasks() }
  for _ in 0..<10000 { if gate.entered { break };await Task.yield() }
  check(gate.entered,"connection suspension reached")
  model.dailyTaskProfile="B";model.tasks=[DailyTask(id:original.id,task:.startup(.init()),enabled:false)]
  gate.release();let result=await pending.value
  check(result == .started && model.handle?.queued.count == 1,"GUI clone switch cannot replace frozen tasks")
  check(model.dailyRunCoordinator.active?.profileID == "A" && model.dailyRunTasks?.first?.enabled == true,"frozen snapshot belongs to original profile")
  if case .fixture? = model.dailyTask(coreID:1) { count+=1 } else { fatalError("callback read must use frozen task, not clone") }
  let invalidated=MAAViewModel(); let recoveryGate=Gate(); invalidated.recoveryGate=recoveryGate
  invalidated.tasks=[.init(task:.fixture)]; var valid=true
  let interrupted=Task { await invalidated.startDailyTasks(recoverGame:true, recoveryCurrent:{ valid }) }
  for _ in 0..<10000 { if recoveryGate.entered { break }; await Task.yield() }
  check(recoveryGate.entered && invalidated.handle?.appendCount == 0, "recovery precedes every user append")
  valid=false; recoveryGate.release()
  check(await interrupted.value == .failed && invalidated.handle?.startCount == 0, "plan invalidation prevents user queue start")
  let quarantine=MAAViewModel(); let quarantineCore=quarantine.handle!
  quarantine.tasks=[.init(task:.fixture)]; quarantine.failRecoveryCleanup = true
  check(await quarantine.startDailyTasks(recoverGame:true) == .failed, "cleanup timeout reports failure")
  check(quarantine.handle === quarantineCore && quarantine.forceRecoveryInFlight && !quarantine.canStartTasks && quarantineCore.startCount == 0, "running recovery stays quarantined")
  quarantineCore.isRunning = false
  try? await Task.sleep(for:.milliseconds(350))
  check(quarantine.handle == nil && !quarantine.forceRecoveryInFlight && quarantine.dailyRunCoordinator.lastTerminal?.outcome == .failed, "idle observation releases quarantined handle and finishes failure")
  // Regression: a stale forceRecoveryInFlight after a failed recovery cleanup
  // (start/stop mutex already released) must not short-circuit a user stop.
  let stuckStop=MAAViewModel(); let stuckCore=stuckStop.handle!
  stuckStop.tasks=[.init(task:.fixture)]; stuckStop.failRecoveryCleanup = true
  check(await stuckStop.startDailyTasks(recoverGame:true) == .failed, "cleanup failure reports failure")
  check(stuckStop.forceRecoveryInFlight && !stuckStop.operationInFlightForTest && !stuckStop.canStartTasks && stuckCore.isRunning, "failed cleanup leaves stale recovery flag while the mutex is released")
  try? await stuckStop.stop()
  check(stuckCore.stopCount == 1 && !stuckCore.isRunning && stuckStop.handle == nil && !stuckStop.forceRecoveryInFlight, "stale recovery flag must not block a full stop of the stuck core")
  check(stuckStop.dailyRunCoordinator.active == nil && stuckStop.dailyRunCoordinator.lastTerminal?.outcome == .cancelled && stuckStop.canStartTasks, "stop finishes the cleanup-failure run as cancelled and unblocks start")
  // While recovery genuinely runs (inside startDailyTasks, mutex held), stop
  // must keep requesting an abort instead of stopping Core underneath it.
  let abortStop=MAAViewModel(); let abortCore=abortStop.handle!; let abortGate=Gate()
  abortStop.recoveryGate=abortGate; abortStop.tasks=[.init(task:.fixture)]; var abortValid=true
  let abortWork=Task { await abortStop.startDailyTasks(recoverGame:true, recoveryCurrent:{ abortValid }) }
  for _ in 0..<10000 { if abortGate.entered { break }; await Task.yield() }
  try? await abortStop.stop()
  check(abortCore.stopCount == 0 && abortStop.infos.contains("正在中止恢复中的强制开始任务，请稍候。") && abortStop.dailyRunCoordinator.active != nil, "stop during live recovery requests an abort instead of stopping Core")
  abortValid=false; abortGate.release()
  check(await abortWork.value == .failed && abortCore.stopCount == 1 && abortStop.dailyRunCoordinator.active == nil, "aborted recovery unwinds through cleanup and finishes like a cancellation")
  // Regression (r3 A-P2-1): in the tail window right after a failed recovery
  // cleanup (mutex still held, cleanupPending set, recovery loop already gone)
  // stop() must be refused honestly, never silently swallowed by the abort path.
  let tailStop=MAAViewModel(); let tailCore=tailStop.handle!
  let tailRecoveryGate=Gate(); let tailRunningGate=Gate()
  tailStop.tasks=[.init(task:.fixture)]; tailStop.failRecoveryCleanup = true
  tailStop.recoveryGate = tailRecoveryGate
  let tailWork=Task { await tailStop.startDailyTasks(recoverGame:true) }
  while !tailRecoveryGate.entered { await Task.yield() }
  // Suspend the catch path's `await handle?.running` query: the recovery loop
  // has thrown its terminal failure (cleanupPending set) while the start/stop
  // mutex is still held.
  tailCore.runningGate = tailRunningGate
  tailRecoveryGate.release()
  while !tailRunningGate.entered { await Task.yield() }
  var tailSwallowed=false
  do { try await tailStop.stop(); tailSwallowed=true } catch {}
  check(!tailSwallowed && tailCore.stopCount == 0 && !tailStop.infos.contains("正在中止恢复中的强制开始任务，请稍候。") && tailStop.forceRecoveryCleanupPending, "stop in the cleanup-failure tail window is refused honestly instead of being swallowed")
  tailRunningGate.release()
  check(await tailWork.value == .failed, "the refused stop leaves the failed recovery to unwind on its own")
  tailCore.isRunning = false
  try? await Task.sleep(for:.milliseconds(350))
  check(tailStop.handle == nil && !tailStop.forceRecoveryInFlight && tailStop.dailyRunCoordinator.active == nil, "idle observation still releases the quarantined core after the refused stop")
  // Regression (r3 A-P2-2): journal corruption + failed recovery cleanup + user
  // stop must digest the quarantine flags instead of leaking them into the next
  // run's message routing and completion filters.
  let abandonRoot=FileManager.default.temporaryDirectory.appendingPathComponent("maa-journal-abandon-\(UUID())")
  defer { try? FileManager.default.removeItem(at:abandonRoot) }
  let abandonModel=MAAViewModel(journalURL:abandonRoot.appendingPathComponent("run.json"))
  let abandonCore=abandonModel.handle!; let abandonGate=Gate()
  abandonModel.tasks=[.init(task:.fixture)]; abandonModel.failRecoveryCleanup = true; abandonModel.recoveryGate = abandonGate
  let abandonWork=Task { await abandonModel.startDailyTasks(recoverGame:true) }
  while !abandonGate.entered { await Task.yield() }
  try! FileManager.default.removeItem(at:abandonRoot)
  try! Data().write(to:abandonRoot)
  abandonGate.release()
  check(await abandonWork.value == .failed && abandonModel.forceRecoveryCleanupPending && abandonModel.forceRecoveryInFlight && abandonCore.isRunning, "compound journal+cleanup failure retains the quarantine flags")
  try? await abandonModel.stop()
  check(abandonCore.stopCount == 1 && abandonModel.handle == nil && !abandonModel.forceRecoveryCleanupPending && !abandonModel.forceRecoveryInFlight, "stop digests the quarantine flags after abandoning the run record")
  check(abandonModel.dailyRunCoordinator.active == nil && abandonModel.dailyRunCoordinator.lastTerminal?.outcome == .cancelled && abandonModel.canStartTasks, "the abandoned quarantine run finishes cancelled and unblocks start")
  let journalRoot=FileManager.default.temporaryDirectory.appendingPathComponent("maa-journal-fault-\(UUID())")
  defer { try? FileManager.default.removeItem(at:journalRoot) }
  let journalModel=MAAViewModel(journalURL:journalRoot.appendingPathComponent("run.json"))
  let journalCore=journalModel.handle!; let journalGate=Gate()
  journalModel.tasks=[.init(task:.fixture)]; journalModel.failRecoveryCleanup = true; journalModel.recoveryGate = journalGate
  let journalWork=Task { await journalModel.startDailyTasks(recoverGame:true) }
  while !journalGate.entered { await Task.yield() }
  try! FileManager.default.removeItem(at:journalRoot)
  try! Data().write(to:journalRoot)
  journalGate.release()
  check(await journalWork.value == .failed && journalModel.handle === journalCore && journalCore.isRunning && !journalModel.canStartTasks, "journal transition error retains live Core and blocks start")
  journalCore.isRunning = false
  try? await Task.sleep(for:.milliseconds(650))
  // #178 92ee14c 语义:写盘失败→降级内存模式,空闲观测照常收口并释放占用,
  // 不再「保留运行阻塞启动」;重启后由 interrupted 恢复兜底。
  check(journalModel.handle == nil && journalModel.dailyRunCoordinator.active == nil && journalModel.canStartTasks && !journalModel.forceRecoveryInFlight, "degraded journal still finishes the idle run in memory and unblocks start")
  check(journalModel.dailyRunCoordinator.journalDegraded, "journal degraded latch is set for the session")
  check(journalModel.errors.filter { $0.contains("每日运行日志：") }.count == 0, "degraded finish no longer errors nor retries")
  try! FileManager.default.removeItem(at:journalRoot)
  try! FileManager.default.createDirectory(at:journalRoot, withIntermediateDirectories:true)
  journalModel.resetStatus(); journalModel.handle = Core(); journalModel.recoveryGate = nil
  let nextJournalCore=journalModel.handle!
  check(await journalModel.startDailyTasks(recoverGame:true) == .failed && !journalModel.canStartTasks, "next run cleanup retains occupancy")
  nextJournalCore.isRunning = false
  try? await Task.sleep(for:.milliseconds(350))
  check(journalModel.dailyRunCoordinator.active == nil && journalModel.dailyRunCoordinator.lastTerminal?.outcome == .failed, "prior journal failure cannot poison next run")
  let playcover=MAAViewModel(); playcover.touchMode = .MacPlayTools
  playcover.tasks=[.init(task:.startup(.init(start_game_enabled:true)))]
  check(await playcover.startDailyTasks(recoverGame:true) == .failed && playcover.startGameCount == 0 && playcover.handle?.appendCount == 0, "forced PlayCover auto-launch must fail before any device action")
  let scoped=MAAViewModel(); let scopedSnapshot=DailyRunSnapshot(profileID:scoped.dailyTaskProfile,tasks:[.init(task:.fixture)])
  let eligible=scoped.forceRecoveryEligibility(snapshot:scopedSnapshot)
  check(eligible(), "unchanged occurrence scope allows recovery")
  scoped.connectionAddress="127.0.0.1:5556"; check(!eligible(), "connection change invalidates captured occurrence")
  scoped.connectionAddress="127.0.0.1:5555"; scoped.clientChannel = .bilibili; check(!eligible(), "channel change invalidates captured occurrence")
  scoped.clientChannel = .official; scoped.dailyTaskProfile = "Other"; check(!eligible(), "profile change invalidates captured occurrence")
  let unsafe=MAAViewModel(); unsafe.touchMode = .MacPlayTools
  let unsafeSnapshot=DailyRunSnapshot(profileID:unsafe.dailyTaskProfile,tasks:[.init(task:.startup(.init(start_game_enabled:true)))])
  check(!unsafe.forceRecoveryEligibility(snapshot:unsafeSnapshot)(), "PlayCover auto-start is rejected at occurrence")
  // AT-1:定时成就链——schedule 源的 startDailyTasks 成功路径必须恰好记录一次
  // .scheduledStart(MAAViewModel 的 origin == .schedule 分支),手动源不记录。
  let scheduledModel=MAAViewModel(); scheduledModel.tasks=[.init(task:.fixture)]
  check(await scheduledModel.startDailyTasks(origin:.schedule) == .started, "scheduled origin still starts the daily chain")
  let scheduledEvents=AchievementStore.shared.recordedEvents.filter { $0.metric == .scheduledStart }
  check(scheduledEvents.count == 1, "scheduled start records exactly one .scheduledStart achievement event")
  check(scheduledEvents.first?.runID == scheduledModel.dailyRunCoordinator.active?.id, "the achievement event carries the scheduled run's ID")
  // P04 入口边界:工具入口(miniGame)与日常入口共用 beginTaskOperation 准入——
  // 同一实例同一时刻至多一个有效运行,冲突即拒绝且互斥随之释放(TO-1 族)。
  let toolBusy=MAAViewModel(); let toolBusyCore=toolBusy.handle!
  toolBusy.tasks=[.init(task:.fixture)]
  check(await toolBusy.startDailyTasks() == .started && toolBusy.status == .busy, "daily run occupies the instance through the shared admission")
  var toolRejected=false
  do { try await toolBusy.miniGame(name:"Fixture") } catch { toolRejected=true }
  check(toolRejected && toolBusy.status == .busy && toolBusyCore.appendCount == 1, "tool entry is refused while a daily run owns the instance and appends nothing")
  check(!toolBusy.operationInFlightForTest && toolBusy.errors.contains("任务正在运行，请先停止当前任务。"), "refused tool entry releases the admission mutex and reports the conflict")
  // 互斥占用期的重复工具启动:独立报错,不触碰 Core(TO-3 族)。
  let toolInFlight=MAAViewModel(); let inFlightGate=Gate(); toolInFlight.connectionGate=inFlightGate
  let toolStart=Task { try await toolInFlight.miniGame(name:"Fixture") }
  for _ in 0..<10000 { if inFlightGate.entered { break }; await Task.yield() }
  var duplicateRejected=false
  do { try await toolInFlight.miniGame(name:"Fixture") } catch { duplicateRejected=true }
  check(duplicateRejected && toolInFlight.operationInFlightForTest && toolInFlight.errors.last == "当前正在启动或停止任务，请稍后重试。", "duplicate tool start is refused while the first holds the admission mutex")
  inFlightGate.release()
  check((try? await toolStart.value) != nil && toolInFlight.status == .busy && !toolInFlight.canStartTasks, "the first tool run still owns the instance after a refused duplicate")
  try? await toolInFlight.stop()
  check(toolInFlight.status == .idle && toolInFlight.canStartTasks, "stopping the tool run releases the instance")
  // 钩子测试占用期(isTestingHook):工具入口必须被拒,不得并发占用 Core。
  let hookTesting=MAAViewModel(); hookTesting.isTestingHook=true
  var hookTestRejected=false
  do { try await hookTesting.miniGame(name:"Fixture") } catch { hookTestRejected=true }
  check(hookTestRejected && hookTesting.handle?.appendCount == 0 && hookTesting.status == .idle, "tool entries cannot start while a hook test owns the boundary")
  // 工具运行成功路径:占用实例,停止后无协调器残留(工具运行不落协调器账)。
  let toolRun=MAAViewModel(); let toolCore=toolRun.handle!
  try! await toolRun.miniGame(name:"Fixture")
  check(toolRun.status == .busy && toolCore.startCount == 1 && toolCore.appendCount == 1 && !toolRun.canStartTasks, "a started tool run occupies the instance through the shared boundary")
  try? await toolRun.stop()
  check(toolRun.status == .idle && toolRun.canStartTasks && toolRun.dailyRunCoordinator.active == nil && toolCore.stopCount == 1, "stop clears a tool run and leaves no coordinator residue")
  // G18 延迟停止:miniGame 不经 startTasks 入队,战斗态标志手工置位以驱动共享的
  // stop() 边界;等待/放行语义归 daily 运行,此处只验证停止路径本身。
  let g18=MAAViewModel(); let g18Core=g18.handle!
  try! await g18.miniGame(name:"Fixture")
  g18.activeRunHasRoguelike=true; g18.roguelikeInCombat=true
  g18.roguelikeDelayAbortUntilCombatComplete=true
  let g18Stop=Task { try? await g18.stop() }
  try! await Task.sleep(for:.milliseconds(1200))
  check(g18Core.stopCount == 0 && g18.roguelikeWaitingForCombat && g18.infos.contains("肉鸽战斗中：等待当前战斗结束后再停止（最长 10 分钟）。再次点击停止可立即停止。"), "delayed abort holds the stop until combat completes instead of touching Core")
  check(g18.canStopTasks, "button and hotkey remain enabled while waiting")
  try? await g18.stop()
  check(g18.infos.contains("已请求立即停止，不再等待当前战斗结束。"), "second stop request aborts the combat wait")
  for _ in 0..<50 { if g18Core.stopCount == 1 { break }; try! await Task.sleep(for:.milliseconds(100)) }
  check(g18Core.stopCount == 1 && !g18.roguelikeWaitingForCombat && g18.status == .idle, "bypassed wait releases the pending stop immediately")
  check(await g18Stop.value != nil, "the first stop flow returns after the bypass")
  let g18wait=MAAViewModel(); let g18waitCore=g18wait.handle!
  try! await g18wait.miniGame(name:"Fixture")
  g18wait.activeRunHasRoguelike=true; g18wait.roguelikeInCombat=true
  g18wait.roguelikeDelayAbortUntilCombatComplete=true
  let waitStop=Task { try? await g18wait.stop() }
  try! await Task.sleep(for:.milliseconds(300))
  check(g18wait.roguelikeWaitingForCombat && g18waitCore.stopCount == 0, "wait holds while combat is live")
  g18wait.roguelikeInCombat=false
  for _ in 0..<50 { if g18waitCore.stopCount == 1 { break }; try! await Task.sleep(for:.milliseconds(100)) }
  check(g18waitCore.stopCount == 1 && g18wait.status == .idle && !g18wait.roguelikeWaitingForCombat, "combat completion releases the pending stop")
  check(await waitStop.value != nil, "combat-release wait flow returns normally")
  // Exercise current task ownership independently of message decoding.
  let events=MAAViewModel()
  let current=DailyTask(task:.roguelike(.init()))
  events.tasks=[current]; events.taskIDMap=[42:current.id]; events.activeRunHasRoguelike=true
  events.updateRoguelikeCombat(taskchain:"Roguelike",taskID:41,inCombat:true)
  events.updateRoguelikeCombat(taskchain:"Copilot",taskID:42,inCombat:true)
  events.updateRoguelikeCombat(taskchain:"Roguelike",taskID:nil,inCombat:true)
  check(!events.roguelikeInCombat, "foreign, missing and old task IDs cannot enter combat")
  events.updateRoguelikeCombat(taskchain:"Roguelike",taskID:42,inCombat:true)
  check(events.roguelikeInCombat, "current roguelike task enters combat")
  events.updateRoguelikeCombat(taskchain:"Roguelike",taskID:41,inCombat:false)
  check(events.roguelikeInCombat, "late combat end cannot release a current battle")
  events.updateRoguelikeCombat(taskchain:"Roguelike",taskID:42,inCombat:false)
  check(!events.roguelikeInCombat, "current combat end clears state")
  events.activeRunHasRoguelike=false
  events.updateRoguelikeCombat(taskchain:"Roguelike",taskID:42,inCombat:true)
  check(!events.roguelikeInCombat, "completed run rejects late combat start")
  for mode in ["cancel", "natural", "nonroguelike", "exit"] {
   let model=MAAViewModel(); let core=model.handle!
   model.tasks=[DailyTask(task:.fixture)]
   check(await model.startDailyTasks() == .started, "boundary fixture starts")
   model.activeRunHasRoguelike = mode != "nonroguelike"
   model.roguelikeInCombat=true; model.roguelikeDelayAbortUntilCombatComplete=true
   if mode == "exit" {
    await model.prepareForTermination(timeout:1)
    check(core.stopCount == 1 && !model.roguelikeWaitingForCombat && model.dailyRunCoordinator.active == nil, "exit bypasses combat wait and finishes daily cleanup")
   } else {
    let work=Task { try? await model.stop() }
    try! await Task.sleep(for:.milliseconds(50))
    if mode == "cancel" { work.cancel() }
    if mode == "natural" { core.isRunning=false; model.resetStatus() }
    check(await work.value != nil, "stop boundary returns")
    check(core.stopCount == 1 && !model.roguelikeWaitingForCombat && !model.activeRunHasRoguelike && !model.roguelikeInCombat, "stop clears combat scope exactly once")
    check(!model.infos.contains("等待战斗结束超时，现在停止。"), "cancel, natural and foreign paths never claim timeout")
    if mode == "cancel" { check(model.infos.contains("停止等待已取消，现在停止。"), "cancel has accurate stop message") }
   }
  }
  let g18off=MAAViewModel(); let g18offCore=g18off.handle!
  try! await g18off.miniGame(name:"Fixture")
  g18off.activeRunHasRoguelike=true; g18off.roguelikeInCombat=true
  try? await g18off.stop()
  check(g18offCore.stopCount == 1 && !g18off.roguelikeWaitingForCombat && g18off.status == .idle, "disabled switch stops immediately even in combat")
  // P04 结果四态:准备期钩子超时按 .timedOut 落账;钩子脚本执行失败按 .failed
  // 落账(A 审 Q1:与"成功/失败/取消/超时"字面一致,不再混入 .cancelled)。
  // startDailyTasks 每次从 hookSettings 重载钩子配置,须在 store 上注入。
  let hookTimeout=MAAViewModel()
  hookTimeout.hookSettings.configuration=HookConfiguration(enabled:true,before:HookCommand())
  hookTimeout.hookResult=HookResult(succeeded:false,exitCode:-9,timedOut:true)
  check(await hookTimeout.startDailyTasks() == .failed && hookTimeout.dailyRunCoordinator.lastTerminal?.outcome == .timedOut && hookTimeout.canStartTasks, "timed-out preparation hook records a timedOut terminal and releases the instance")
  let hookFailed=MAAViewModel()
  hookFailed.hookSettings.configuration=HookConfiguration(enabled:true,before:HookCommand())
  hookFailed.hookResult=HookResult(succeeded:false,exitCode:1)
  check(await hookFailed.startDailyTasks() == .failed && hookFailed.dailyRunCoordinator.lastTerminal?.outcome == .failed && hookFailed.canStartTasks, "failing preparation hook records a failed terminal and releases the instance")
  // R3 回归:任务树取消（定时取消/计划编辑）杀钩子进程 → HookResult.cancelled
  // 须回归基点的 .cancelled,不得因 PreparationHookFailure 误记 .failed。
  let hookTreeCancelled=MAAViewModel()
  hookTreeCancelled.hookSettings.configuration=HookConfiguration(enabled:true,before:HookCommand())
  hookTreeCancelled.hookResult=HookResult(succeeded:false,exitCode:-9,cancelled:true)
  check(await hookTreeCancelled.startDailyTasks() == .failed && hookTreeCancelled.dailyRunCoordinator.lastTerminal?.outcome == .cancelled && hookTreeCancelled.canStartTasks, "tree-cancelled preparation hook records a cancelled terminal")
  // 强制恢复超时同样按 .timedOut 落账(此前混入 .failed)。
  let recoveryTimeout=MAAViewModel(); recoveryTimeout.tasks=[.init(task:.fixture)]
  recoveryTimeout.recoveryError=ForcedRecoveryFailure.timedOut
  check(await recoveryTimeout.startDailyTasks(recoverGame:true) == .failed && recoveryTimeout.dailyRunCoordinator.lastTerminal?.outcome == .timedOut, "forced recovery timeout records a timedOut terminal")
  // P04 停止路由:无可停对象不触碰 Core;后置清理期拒绝;运行中正常收口。
  let idleStop=MAAViewModel(); let idleStopCore=idleStop.handle!
  check(await idleStop.requestStopRun() == false && idleStopCore.stopCount == 0, "stop routing with no run reports false and never touches the core")
  let postStop=MAAViewModel(); let postStopCore=postStop.handle!
  let postID=try! postStop.dailyRunCoordinator.begin(profileID:"A",origin:.manual)!
  try! postStop.dailyRunCoordinator.transition(.postHook, for: postID)
  check(await postStop.requestStopRun() == false && postStopCore.stopCount == 0 && postStop.dailyRunCoordinator.active?.id == postID, "stop routing refuses during post-run cleanup without touching the core")
  _=try! postStop.dailyRunCoordinator.finish(postID,outcome:.cancelled,cleanupSucceeded:true)
  let routeStop=MAAViewModel(); let routeCore=routeStop.handle!
  routeStop.tasks=[.init(task:.fixture)]
  check(await routeStop.startDailyTasks() == .started, "routing fixture starts a daily run")
  check(await routeStop.requestStopRun() == true && routeCore.stopCount == 1 && routeStop.dailyRunCoordinator.active == nil && routeStop.dailyRunCoordinator.lastTerminal?.outcome == .cancelled, "stop routing finishes the owned run as cancelled")
  // P04 准入 + runID 归属:被拒返回 nil,成功返回的 runID 与终态记录一致。
  let busyEntry=MAAViewModel(); busyEntry.tasks=[.init(task:.fixture)]
  check(await busyEntry.startDailyTasks() == .started, "entry fixture run started")
  check(await busyEntry.requestDailyRun(origin:.schedule) == nil && busyEntry.dailyRunCoordinator.active != nil, "requestDailyRun is refused while a run owns the instance")
  check(await busyEntry.requestStopRun() == true, "the owned run remains stoppable through the boundary")
  let freshEntry=MAAViewModel(); freshEntry.tasks=[.init(task:.fixture)]
  let admittedID=await freshEntry.requestDailyRun(origin:.schedule)
  check(admittedID != nil && freshEntry.dailyRunCoordinator.active?.id == admittedID, "admitted entry returns the coordinator run ID")
  check(await freshEntry.requestStopRun() == true && freshEntry.dailyRunCoordinator.lastTerminal?.id == admittedID, "the admitted run ID tracks stop routing into the terminal record")
  print("DailyPreparationTests: \(count) production async assertions passed")
 }
}
