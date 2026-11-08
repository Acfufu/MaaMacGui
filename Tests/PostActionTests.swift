import Foundation

// P22: S17 收尾动作规划（顺序/抑制/幂等配置）与 S16 时长上限钳制。
// P22.2（P22-1-R3 评审债修复）：+尾部 exitSelf（中4）+ 触发门真值表（高2）。
@main struct PostActionTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- 配置缺省与持久化
        let suiteName = "MAAPostActionTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PostActionSettingsStore(defaults: defaults)
        check(store.configuration == PostActionConfiguration(), "default configuration all off")
        check(!store.configuration.anyEnabled, "default has no enabled actions")
        store.configuration.exitArknights = true
        store.configuration.skipOnError = true
        let reloaded = PostActionSettingsStore(defaults: defaults)
        check(reloaded.configuration.exitArknights && reloaded.configuration.skipOnError, "configuration persists across store instances")
        check(reloaded.configuration.anyEnabled, "anyEnabled reflects set actions")

        // --- 规划：门控与抑制（WPF RunPostActionsCoreAsync 同构）
        check(PostActionPlanner.plannedActions(config: PostActionConfiguration(), hasError: false, policyAllows: true).isEmpty,
              "no actions planned when all off")
        var full = PostActionConfiguration()
        full.backToAndroidHome = true
        full.exitArknights = true
        full.exitEmulator = true
        full.exitSelf = true
        full.lockScreen = true
        full.shutdown = true
        full.sleep = true
        // 中4（P22-1-R3）：exitSelf+系统动作组合延后到尾部（WPF :608-610 尾部
        // 无条件 ExitSelf——系统动作完成后应用仍退出，不再被 planner 剔除）。
        let ordered = PostActionPlanner.plannedActions(config: full, hasError: false, policyAllows: true)
        check(ordered == [.backToAndroidHome, .exitArknights, .exitEmulator, .lockScreen, .shutdown, .sleep, .exitSelf],
              "fixed WPF order with exitSelf deferred to tail after system actions")
        var withoutSystem = PostActionConfiguration()
        withoutSystem.exitSelf = true
        withoutSystem.exitArknights = true
        check(PostActionPlanner.plannedActions(config: withoutSystem, hasError: false, policyAllows: true)
              == [.exitArknights, .exitSelf], "exitSelf planned when no system actions follow")
        var lockOnly = PostActionConfiguration()
        lockOnly.exitSelf = true
        lockOnly.lockScreen = true
        check(PostActionPlanner.plannedActions(config: lockOnly, hasError: false, policyAllows: true)
              == [.lockScreen, .exitSelf], "exitSelf trails lock screen (WPF tail position)")
        var sleepShutdown = PostActionConfiguration()
        sleepShutdown.exitSelf = true
        sleepShutdown.shutdown = true
        sleepShutdown.sleep = true
        check(PostActionPlanner.plannedActions(config: sleepShutdown, hasError: false, policyAllows: true)
              == [.shutdown, .sleep, .exitSelf], "exitSelf trails shutdown/sleep pair")
        var exitSelfOnly = PostActionConfiguration()
        exitSelfOnly.exitSelf = true
        check(PostActionPlanner.plannedActions(config: exitSelfOnly, hasError: false, policyAllows: true)
              == [.exitSelf], "exitSelf alone planned once")
        full.skipOnError = true
        check(PostActionPlanner.plannedActions(config: full, hasError: true, policyAllows: true).isEmpty,
              "skipOnError suppresses all actions on error runs")
        check(!PostActionPlanner.plannedActions(config: full, hasError: false, policyAllows: true).isEmpty,
              "skipOnError keeps actions on clean runs")
        check(PostActionPlanner.plannedActions(config: full, hasError: false, policyAllows: false).isEmpty,
              "policy denial suppresses duration-limit opt-out")

        // --- 高2（P22-1-R3）：触发门真值表——WPF 仅自然完成回调与时长上限到点
        // 两路放行；手动语义停止（StopManuallyAsync 通吃）与启动失败路径不触发。
        // naturalCompletion = (.completed) 或 (.failed && chainFailed)（任务链曾
        // 失败后仍完成的运行，skipOnError 照常门控）。
        check(PostActionGate.shouldRunPostActions(naturalCompletion: true, isDurationLimitStop: false,
                                                  isManualStopFinish: false, durationLimitPolicyAllows: true),
              "natural completion runs post actions")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: false, isDurationLimitStop: false,
                                                  isManualStopFinish: false, durationLimitPolicyAllows: true) == false,
              "start-failure paths (no completion callback) do not run post actions")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: true, isDurationLimitStop: false,
                                                  isManualStopFinish: true, durationLimitPolicyAllows: true) == false,
              "manual stop never runs post actions")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: false, isDurationLimitStop: false,
                                                  isManualStopFinish: true, durationLimitPolicyAllows: true) == false,
              "manual stop suppresses regardless of outcome")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: true, isDurationLimitStop: true,
                                                  isManualStopFinish: false, durationLimitPolicyAllows: true),
              "duration-limit stop runs post actions by policy")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: true, isDurationLimitStop: true,
                                                  isManualStopFinish: false, durationLimitPolicyAllows: false) == false,
              "duration-limit opt-out policy honored")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: false, isDurationLimitStop: true,
                                                  isManualStopFinish: false, durationLimitPolicyAllows: true),
              "duration-limit stop runs regardless of completion outcome")
        check(PostActionGate.shouldRunPostActions(naturalCompletion: false, isDurationLimitStop: false,
                                                  isManualStopFinish: false, durationLimitPolicyAllows: true) == false,
              "non-completion outcomes without stop markers do not run")

        // --- S16 时长上限钳制（WPF TimeoutMaxMinutes=11451 同值）
        check(RunDurationLimit.maxMinutes == 11451, "max minutes mirrors WPF")
        check(RunDurationLimit.clampedMinutes(0) == 1, "zero clamps to 1")
        check(RunDurationLimit.clampedMinutes(-5) == 1, "negative clamps to 1")
        check(RunDurationLimit.clampedMinutes(240) == 240, "default value unchanged")
        check(RunDurationLimit.clampedMinutes(11452) == 11451, "over-max clamps down")

        print("PostActionTests: \(count) assertions passed")
    }
}
