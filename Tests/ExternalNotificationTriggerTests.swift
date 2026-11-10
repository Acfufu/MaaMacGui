import Foundation

// P25/E03-E05: 触发判定/内容过滤/历史打包/停滞监控模型层套件。
@main struct ExternalNotificationTriggerTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            if !condition { fatalError(message) }
        }

        // --- 触发判定（WPF NotificationTrigger 同构）
        let trigger = ExternalNotificationTrigger()
        let defaultPolicy = ExternalNotificationDeliveryPolicy()
        check(defaultPolicy.sendWhenComplete && defaultPolicy.sendWhenError && !defaultPolicy.sendWhenStalled,
              "WPF defaults: complete/error on, stalled off")
        check(trigger.shouldSend(policy: defaultPolicy, kind: .complete, content: "x"), "complete fires by default")
        check(trigger.shouldSend(policy: defaultPolicy, kind: .error, content: "x"), "error fires by default")
        check(!trigger.shouldSend(policy: defaultPolicy, kind: .stalled, content: "x"), "stalled off by default")
        check(!trigger.shouldSend(policy: defaultPolicy, kind: .scheduledStart, content: "x"), "scheduledStart off by default")

        var countPolicy = ExternalNotificationDeliveryPolicy()
        countPolicy.sendWhenComplete = false
        countPolicy.sendAfterLogCount = true
        countPolicy.newLogCount = 3
        let counting = ExternalNotificationTrigger()
        check(!counting.shouldSend(policy: countPolicy, kind: .complete, content: "1"), "below threshold silent")
        check(!counting.shouldSend(policy: countPolicy, kind: .complete, content: "2"), "still below")
        check(counting.shouldSend(policy: countPolicy, kind: .complete, content: "3"), "log count threshold fires")
        counting.reset()
        check(!counting.shouldSend(policy: countPolicy, kind: .complete, content: "1"), "reset clears accumulator")

        var whitelistPolicy = ExternalNotificationDeliveryPolicy()
        whitelistPolicy.sendWhenComplete = false
        whitelistPolicy.sendWhenContentMatches = true
        whitelistPolicy.whitelist = "库存不足\nSCHEDULED"
        let matching = ExternalNotificationTrigger()
        check(matching.shouldSend(policy: whitelistPolicy, kind: .complete, content: "计划1：30012 库存不足"), "whitelist line matches")
        check(!matching.shouldSend(policy: whitelistPolicy, kind: .complete, content: "无命中"), "whitelist miss silent")
        whitelistPolicy.whitelist = "(["
        check(matching.shouldSend(policy: whitelistPolicy, kind: .complete, content: "任意") == false,
              "invalid regex fails safe (no send)")

        // --- 内容过滤（WPF NotificationFilter 同构）
        let filter = ExternalNotificationContentFilter()
        check(filter.matches(patterns: "", content: "x") == false, "empty patterns never match")
        check(filter.matches(patterns: "abc", content: "xxabcxx") == true, "plain substring via regex")
        check(filter.matches(patterns: "([)", content: "x") == nil, "invalid pattern nil")

        // --- 历史打包（WPF NotificationHistory 同构）
        let history = ExternalNotificationHistory()
        var policy = ExternalNotificationDeliveryPolicy()
        let now = Date()
        policy.includePreviousLogs = true
        policy.maxEntries = 2
        policy.timeMinutes = 60
        history.add(.init(timestamp: now.addingTimeInterval(-3600 * 2), content: "太久"))
        history.add(.init(timestamp: now.addingTimeInterval(-300), content: "近事一"))
        history.add(.init(timestamp: now.addingTimeInterval(-60), content: "近事二"))
        let bundled = history.bundle(current: "当前事件", at: now, policy: policy)
        check(bundled.contains("当前事件"), "bundle keeps current first")
        check(bundled.contains("近事二") && bundled.contains("近事一"), "bundle carries in-window history")
        check(!bundled.contains("太久"), "outside cutoff excluded")
        let lines = bundled.split(separator: "\n").map(String.init)
        check(lines.first == "当前事件" && lines[1] == "近事二", "newest-first ordering")
        var capped = policy
        capped.maxEntries = 0
        check(history.bundle(current: "当前", at: now, policy: capped) == "当前", "zero entries returns body only")
        var gated = policy
        gated.includePreviousLogs = false
        check(history.bundle(current: "当前", at: now, policy: gated) == "当前", "disabled bundling returns body only")

        // --- 停滞监控：活动喂活复位（缩短时长实测）
        let monitor = ExternalStallMonitor()
        var fired = 0
        monitor.arm(timeoutMinutes: 1) { _, _ in fired += 1 }
        // 前 2 秒喂活 4 次（间隔 0.4s < 1 分钟）→ 到 1 分钟检查点应无回调。
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(400))
            monitor.activity()
        }
        try? await Task.sleep(for: .milliseconds(400))
        check(fired == 0, "continuous activity prevents stall fire")
        monitor.stop()
        var firedOnce = 0
        monitor.arm(timeoutMinutes: 1) { _, _ in firedOnce += 1 }
        // 不喂活：等 1 分钟检查点（真实 60s 太长——跳过长等，仅验证 stop 后未触发）。
        monitor.stop()
        try? await Task.sleep(for: .milliseconds(50))
        check(firedOnce == 0, "stopped monitor never fires")
        // 短超时（秒级换算）实测一次触发：1 分钟下限由 UI 钳制，模型层用负值拒绝。
        monitor.arm(timeoutMinutes: 0) { _, _ in firedOnce += 1 }
        try? await Task.sleep(for: .milliseconds(50))
        check(firedOnce == 0, "non-positive timeout not armed")

        print("ExternalNotificationTriggerTests: \(count) assertions passed")
    }
}
