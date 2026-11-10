import Foundation

// P22: S17 收尾动作规划（顺序/抑制/幂等配置）与 S16 时长上限钳制。
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
        let ordered = PostActionPlanner.plannedActions(config: full, hasError: false, policyAllows: true)
        check(ordered == [.backToAndroidHome, .exitArknights, .exitEmulator, .lockScreen, .shutdown, .sleep],
              "fixed WPF order with exitSelf suppressed by system actions")
        var withoutSystem = PostActionConfiguration()
        withoutSystem.exitSelf = true
        withoutSystem.exitArknights = true
        check(PostActionPlanner.plannedActions(config: withoutSystem, hasError: false, policyAllows: true)
              == [.exitArknights, .exitSelf], "exitSelf planned when no system actions follow")
        full.skipOnError = true
        check(PostActionPlanner.plannedActions(config: full, hasError: true, policyAllows: true).isEmpty,
              "skipOnError suppresses all actions on error runs")
        check(!PostActionPlanner.plannedActions(config: full, hasError: false, policyAllows: true).isEmpty,
              "skipOnError keeps actions on clean runs")
        check(PostActionPlanner.plannedActions(config: full, hasError: false, policyAllows: false).isEmpty,
              "policy denial suppresses duration-limit opt-out")

        // --- S16 时长上限钳制（WPF TimeoutMaxMinutes=11451 同值）
        check(RunDurationLimit.maxMinutes == 11451, "max minutes mirrors WPF")
        check(RunDurationLimit.clampedMinutes(0) == 1, "zero clamps to 1")
        check(RunDurationLimit.clampedMinutes(-5) == 1, "negative clamps to 1")
        check(RunDurationLimit.clampedMinutes(240) == 240, "default value unchanged")
        check(RunDurationLimit.clampedMinutes(11452) == 11451, "over-max clamps down")

        print("PostActionTests: \(count) assertions passed")
    }
}
