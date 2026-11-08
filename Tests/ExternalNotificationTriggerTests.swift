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

        // --- 历史打包（WPF NotificationHistory.cs:56-91 同构：历史 oldest-first +
        // [HH:mm:ss][color] 前缀 + 正文在最后；中5/P25-1-R3 修复后格式）
        let history = ExternalNotificationHistory()
        var policy = ExternalNotificationDeliveryPolicy()
        let now = Date()
        policy.includePreviousLogs = true
        policy.maxEntries = 2
        policy.timeMinutes = 60
        history.add(.init(timestamp: now.addingTimeInterval(-3600 * 2), content: "太久", color: "InfoLogBrush"))
        history.add(.init(timestamp: now.addingTimeInterval(-300), content: "近事一", color: "ErrorLogBrush"))
        history.add(.init(timestamp: now.addingTimeInterval(-60), content: "近事二", color: "WarningLogBrush"))
        let bundled = history.bundle(current: "当前事件", at: now, policy: policy)
        let lines = bundled.split(separator: "\n").map(String.init)
        check(lines.count == 3, "bundle carries current plus two in-window entries")
        check(lines.last == "当前事件", "current payload is last (WPF context.Append(body))")
        check(lines[0].hasPrefix("[") && lines[0].contains("[ErrorLogBrush] ") && lines[0].hasSuffix(" 近事一"),
              "oldest-first ordering with [HH:mm:ss][color] prefix")
        check(lines[1].hasSuffix(" 近事二") && lines[1].contains("[WarningLogBrush] "), "second entry oldest-first with color")
        check(!bundled.contains("太久"), "outside cutoff excluded")
        // 当前事件本体不入附包（记账时刻+文本同值判定）；旧的相同文案条目照附
        //（低3/P25-1-R3：WPF 仅排除 current 本体，无 content 全等去重）。
        history.add(.init(timestamp: now.addingTimeInterval(-30), content: "当前事件", color: "TraceLogBrush"))
        let dedupBundled = history.bundle(current: "当前事件", at: now, policy: policy)
        check(dedupBundled.split(separator: "\n").filter { $0.contains("当前事件") }.count == 2,
              "older identical-text entry attaches while current itself excluded")
        var capped = policy
        capped.maxEntries = 0
        check(history.bundle(current: "当前", at: now, policy: capped) == "当前", "zero entries returns body only")
        var gated = policy
        gated.includePreviousLogs = false
        check(history.bundle(current: "当前", at: now, policy: gated) == "当前", "disabled bundling returns body only")

        // --- 中4（P25-1-R3）：黑名单 fail-safe 剔除方向（WPF matches null/超时
        // → 仅发正文；原 Mac 非法正则放行全部、超时保留部分）
        do {
            var hitPolicy = ExternalNotificationDeliveryPolicy()
            hitPolicy.includePreviousLogs = true
            hitPolicy.maxEntries = 5
            hitPolicy.filterPreviousLogs = true
            hitPolicy.blacklist = "噪音"
            let hitHistory = ExternalNotificationHistory()
            hitHistory.add(.init(timestamp: Date().addingTimeInterval(-300), content: "噪音行"))
            hitHistory.add(.init(timestamp: Date().addingTimeInterval(-200), content: "正常行"))
            let hitBundled = hitHistory.bundle(current: "当前", at: Date(), policy: hitPolicy)
            check(hitBundled.contains("正常行") && !hitBundled.contains("噪音行"),
                  "blacklist drops matching entries")
            var invalidPolicy = hitPolicy
            invalidPolicy.blacklist = "(["
            let invalidHistory = ExternalNotificationHistory()
            invalidHistory.add(.init(timestamp: Date().addingTimeInterval(-300), content: "秘密A"))
            check(invalidHistory.bundle(current: "当前", at: Date(), policy: invalidPolicy) == "当前",
                  "invalid blacklist regex fails closed (body only)")
            // 预算超时（WPF elapsed > 100ms → return body）
            let timeoutHistory = ExternalNotificationHistory()
            timeoutHistory.add(.init(timestamp: Date().addingTimeInterval(-300), content: "历史行"))
            let baseClock = Date()
            var calls = 0
            let timedOut = timeoutHistory.bundle(current: "当前", at: Date(), policy: hitPolicy, clock: {
                calls += 1
                return calls <= 1 ? baseClock : baseClock.addingTimeInterval(1)
            })
            check(timedOut == "当前", "blacklist budget timeout returns body only")
        }

        // --- 停滞监控（中6/P25-1-R3：注入假时钟+500ms 检查步长驱动真实触发路径——
        // 原「喂活防误报」断言在 60s 检查点永不到达下恒真，E05 运行面零覆盖；
        // 每相位窗 600ms 恰落一个检查点，断言确定性）
        do {
            let monitor = ExternalStallMonitor()
            var clockDate = Date(timeIntervalSince1970: 1_000)
            monitor.now = { clockDate }
            monitor.stepInterval = .milliseconds(500)
            var fires: [[Int]] = []
            monitor.arm(timeoutMinutes: 1) { initial, accumulated in fires.append([initial, accumulated]) }
            // 停滞 60s（阈值 55s）→ 真实检查点触发：initial=1、accumulated=1。
            clockDate = clockDate.addingTimeInterval(60)
            try? await Task.sleep(for: .milliseconds(600))
            check(fires == [[1, 1]], "stall checkpoint fires with initial and accumulated minutes")
            // 继续停滞 → 同间隔重复触发，accumulated 递增。
            clockDate = clockDate.addingTimeInterval(60)
            try? await Task.sleep(for: .milliseconds(600))
            check(fires == [[1, 1], [1, 2]], "repeated stalls accumulate minutes")
            // 喂活复位：活动后 10s（< 55s 阈值）检查点不触发。
            monitor.activity()
            clockDate = clockDate.addingTimeInterval(10)
            try? await Task.sleep(for: .milliseconds(600))
            check(fires.count == 2, "activity feed prevents stall fire at real checkpoints")
            // 喂活后再停滞 → 触发延续（Mac accumulated 跨 episode 累计，WPF
            // ResetStallTimer 清零——差异入台账 P25-[b]）。
            clockDate = clockDate.addingTimeInterval(60)
            try? await Task.sleep(for: .milliseconds(600))
            check(fires == [[1, 1], [1, 2], [1, 3]], "post-activity stall resumes firing with accumulated count")
            // stop 后不再触发且累计复位。
            monitor.stop()
            check(monitor.accumulatedMinutes == 0, "stop resets accumulated minutes")
            clockDate = clockDate.addingTimeInterval(120)
            try? await Task.sleep(for: .milliseconds(600))
            check(fires.count == 3, "stopped monitor never fires")
        }
        // 短超时（秒级换算）实测一次触发：1 分钟下限由 UI 钳制，模型层用负值拒绝。
        do {
            let monitor = ExternalStallMonitor()
            var firedOnce = 0
            monitor.arm(timeoutMinutes: 0) { _, _ in firedOnce += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            check(firedOnce == 0, "non-positive timeout not armed")
        }

        // --- 中3/低8（P25-1-R3）：scheduledStart 不入计数（WPF not-a-new-log-entry）
        do {
            var countPolicy = ExternalNotificationDeliveryPolicy()
            countPolicy.sendWhenComplete = false
            countPolicy.sendAfterLogCount = true
            countPolicy.newLogCount = 2
            let trigger = ExternalNotificationTrigger()
            _ = trigger.shouldSend(policy: countPolicy, kind: .scheduledStart, content: "定时1")
            _ = trigger.shouldSend(policy: countPolicy, kind: .scheduledStart, content: "定时2")
            check(!trigger.shouldSend(policy: countPolicy, kind: .complete, content: "1"),
                  "scheduled-start events do not count toward log threshold")
        }
        // --- 中2（P25-1-R3）：kind→事件开关映射（公招错误接线显式 .error——原
        // 缺省 .complete 使「错误时发送」管不到错误事件）
        do {
            var errorOnly = ExternalNotificationDeliveryPolicy()
            errorOnly.sendWhenComplete = false
            errorOnly.sendWhenError = true
            let trigger = ExternalNotificationTrigger()
            check(trigger.shouldSend(policy: errorOnly, kind: .error, content: "公招任务链出错"),
                  "error kind gated by sendWhenError")
            check(!trigger.shouldSend(policy: errorOnly, kind: .complete, content: "完成"),
                  "complete kind gated by sendWhenComplete only")
        }
        // --- 容量裁剪（10000 有界；中6 附带零覆盖面补齐）
        do {
            let capped = ExternalNotificationHistory()
            for index in 0..<(ExternalNotificationHistory.capacity + 5) {
                capped.add(.init(timestamp: Date(), content: "e\(index)"))
            }
            check(capped.entries.count == ExternalNotificationHistory.capacity,
                  "history capacity stays bounded")
            check(capped.entries.first?.content == "e5", "oldest entries evicted first")
        }

        print("ExternalNotificationTriggerTests: \(count) assertions passed")
    }
}
