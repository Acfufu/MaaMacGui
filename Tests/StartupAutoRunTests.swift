import AppKit

// P20: S02 启动自动运行（策略/一次性标记/反悔倒计时）+ S13/S18 主窗口显隐
// 的模型层套件。MainWindowVisibility 以真实 NSWindow 驱动（无头进程）。
@main struct StartupAutoRunTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- StartupAutoRunPolicy.decide 决策矩阵
        check(StartupAutoRunPolicy.decide(runDirectly: false, cliSkipRequested: false, updateRelaunchMarkerPresent: false) == .skip(.disabled), "disabled when RunDirectly off")
        check(StartupAutoRunPolicy.decide(runDirectly: true, cliSkipRequested: false, updateRelaunchMarkerPresent: false) == .run, "run when only RunDirectly on")
        check(StartupAutoRunPolicy.decide(runDirectly: true, cliSkipRequested: true, updateRelaunchMarkerPresent: false) == .skip(.cliArgument), "cli argument wins over run")
        check(StartupAutoRunPolicy.decide(runDirectly: true, cliSkipRequested: false, updateRelaunchMarkerPresent: true) == .skip(.afterUpdateRelaunch), "update relaunch marker wins over run")
        check(StartupAutoRunPolicy.decide(runDirectly: false, cliSkipRequested: true, updateRelaunchMarkerPresent: true) == .skip(.disabled), "disabled dominates other skips")
        check(StartupAutoRunPolicy.skipArgument == "--skip-startup-auto-run", "skip argument literal")

        // --- skipAfterUpdateEnabled：UserDefaults.bool 未设置缺省 false，本选项必须缺省 true
        let suite = "MAAStartupAutoRunTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(StartupAutoRunPolicy.skipAfterUpdateEnabled(defaults: defaults) == true, "skip-after-update defaults to true")
        defaults.set(false, forKey: StartupAutoRunPolicy.skipAfterUpdateDefaultsKey)
        check(StartupAutoRunPolicy.skipAfterUpdateEnabled(defaults: defaults) == false, "explicit false respected")
        defaults.set(true, forKey: StartupAutoRunPolicy.skipAfterUpdateDefaultsKey)
        check(StartupAutoRunPolicy.skipAfterUpdateEnabled(defaults: defaults) == true, "explicit true respected")

        // --- Marker：写/消费一次性
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MAAStartupAutoRunTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = dir.appendingPathComponent("StartupAutoRunSkip.pending")
        check(!StartupAutoRunMarker.consume(url: markerURL), "absent marker consumes false")
        try StartupAutoRunMarker.write(url: markerURL)
        check(FileManager.default.fileExists(atPath: markerURL.path), "marker written")
        check(StartupAutoRunMarker.consume(url: markerURL), "marker consumed once")
        check(!StartupAutoRunMarker.consume(url: markerURL), "second consume false: one-launch scope")
        // 默认路径写入会建目录（Application Support/MeoAsstMac 不依赖预存在目录）
        let nestedURL = dir.appendingPathComponent("nested/deeper/Marker.pending")
        try StartupAutoRunMarker.write(url: nestedURL)
        check(StartupAutoRunMarker.consume(url: nestedURL), "write creates missing intermediate directories")

        // --- Countdown：归零触发 / 终止 nil tick / 取消不触发 / 重复 begin 拒绝 / cancel 幂等
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let countdown = StartupAutoRunCountdown()
        // 用字符串记录 tick：[Int?] 的 .last 是 Int??，.some(nil) 与 nil 的比较是测试陷阱。
        var ticks: [String] = []
        var proceeded = 0
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            countdown.begin(seconds: 2, tick: .milliseconds(20),
                            onTick: { ticks.append($0.map(String.init) ?? "end") },
                            onProceed: { proceeded += 1; cont.resume() })
        }
        check(proceeded == 1, "countdown proceeds after expiry")
        check(ticks.first == "2" && ticks.count >= 2, "countdown ticks down from seconds")
        check(ticks.last == "end", "terminal nil tick clears UI state")
        check(!countdown.isCounting, "counting flag cleared after expiry")
        countdown.cancel()
        check(proceeded == 1, "cancel after expiry is a no-op")

        var cancelledTicks: [String] = []
        var cancelledProceeded = 0
        countdown.begin(seconds: 5, tick: .milliseconds(30),
                        onTick: { cancelledTicks.append($0.map(String.init) ?? "end") },
                        onProceed: { cancelledProceeded += 1 })
        countdown.cancel()
        try? await Task.sleep(for: .milliseconds(120))
        check(cancelledProceeded == 0, "cancel prevents proceed")
        check(cancelledTicks.last == "end", "cancel emits terminal nil tick")
        check(!countdown.isCounting, "cancel clears counting")

        countdown.begin(seconds: 0, tick: .milliseconds(5), onTick: { _ in }, onProceed: { cancelledProceeded += 1 })
        check(!countdown.isCounting, "non-positive seconds rejected")
        countdown.begin(seconds: 3, tick: .milliseconds(30), onTick: { _ in }, onProceed: { cancelledProceeded += 1 })
        countdown.begin(seconds: 3, tick: .milliseconds(30), onTick: { _ in }, onProceed: { cancelledProceeded += 1 })
        check(countdown.isCounting, "second begin while counting rejected")
        countdown.cancel()
        try? await Task.sleep(for: .milliseconds(80))
        check(cancelledProceeded == 0, "no stray proceeds from rejected or cancelled attempts")

        // --- S13/S18: 主窗口显隐（真实 NSWindow）与 tracker 兜底
        let tracker = MainWindowTracker()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFrontRegardless()
        tracker.window = window
        check(window.isVisible, "window visible after creation")
        MainWindowVisibility.toggle(tracker: tracker)
        check(!window.isVisible, "toggle hides visible window")
        MainWindowVisibility.toggle(tracker: tracker)
        check(window.isVisible, "toggle shows hidden window")
        var reopened = 0
        tracker.reopenHandler = { reopened += 1 }
        tracker.window = nil
        MainWindowVisibility.reopen(tracker: tracker)
        // 高1（P20-1-R3）：openWindow 只能寻址显式声明 id 的 scene——生产
        // reopenHandler 的窗口真实重建经 bundle 探针验证（P1=1→关窗 0→toggle
        // 重建 1，无显式 id 对照 0→0；证据 p20-2-fix/probe-*），本断言只钉
        // 兜底链被走到。
        check(reopened == 1, "reopen falls back to SwiftUI openWindow when window released")
        check(MainWindowScene.id == "main", "main scene id is the single openWindow source")
        MainWindowVisibility.toggle(tracker: tracker)
        check(reopened == 2, "toggle falls back to reopen handler without window")
        tracker.window = window
        window.orderOut(nil)
        MainWindowVisibility.reopen(tracker: tracker)
        check(window.isVisible, "reopen fronts existing hidden window")

        print("StartupAutoRunTests: \(count) assertions passed")
    }
}
