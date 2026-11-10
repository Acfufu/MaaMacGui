import Foundation

// P25/E03-E05: 外部通知触发过滤、历史打包与停滞检测（WPF NotificationTrigger/
// NotificationFilter/NotificationHistory + RunningState.StallOccurred 同构）。

/// 触发策略（WPF ExternalNotification DeliverySettings 同构，缺省值逐字段对齐）。
struct ExternalNotificationDeliveryPolicy: Codable, Equatable {
    var sendWhenComplete = true
    var sendWhenError = true
    var sendWhenStalled = false
    var sendBeforeScheduledStart = false
    var sendAfterLogCount = false
    var newLogCount = 10
    var sendWhenContentMatches = false
    var whitelist = ""
    var includePreviousLogs = false
    var maxEntries = 2
    var timeMinutes = 60
    var filterPreviousLogs = false
    var blacklist = ""

    private enum CodingKeys: String, CodingKey {
        case sendWhenComplete, sendWhenError, sendWhenStalled, sendBeforeScheduledStart
        case sendAfterLogCount, newLogCount, sendWhenContentMatches, whitelist
        case includePreviousLogs, maxEntries, timeMinutes, filterPreviousLogs, blacklist
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sendWhenComplete = try c.decodeIfPresent(Bool.self, forKey: .sendWhenComplete) ?? true
        sendWhenError = try c.decodeIfPresent(Bool.self, forKey: .sendWhenError) ?? true
        sendWhenStalled = try c.decodeIfPresent(Bool.self, forKey: .sendWhenStalled) ?? false
        sendBeforeScheduledStart = try c.decodeIfPresent(Bool.self, forKey: .sendBeforeScheduledStart) ?? false
        sendAfterLogCount = try c.decodeIfPresent(Bool.self, forKey: .sendAfterLogCount) ?? false
        newLogCount = try c.decodeIfPresent(Int.self, forKey: .newLogCount) ?? 10
        sendWhenContentMatches = try c.decodeIfPresent(Bool.self, forKey: .sendWhenContentMatches) ?? false
        whitelist = try c.decodeIfPresent(String.self, forKey: .whitelist) ?? ""
        includePreviousLogs = try c.decodeIfPresent(Bool.self, forKey: .includePreviousLogs) ?? false
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 2
        timeMinutes = try c.decodeIfPresent(Int.self, forKey: .timeMinutes) ?? 60
        filterPreviousLogs = try c.decodeIfPresent(Bool.self, forKey: .filterPreviousLogs) ?? false
        blacklist = try c.decodeIfPresent(String.self, forKey: .blacklist) ?? ""
    }
}

@MainActor final class ExternalNotificationDeliveryPolicyStore: ObservableObject {
    @Published var policy: ExternalNotificationDeliveryPolicy {
        didSet {
            if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: "MAAExternalNotificationPolicy") }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        policy = defaults.data(forKey: "MAAExternalNotificationPolicy")
            .flatMap { try? JSONDecoder().decode(ExternalNotificationDeliveryPolicy.self, from: $0) }
            ?? ExternalNotificationDeliveryPolicy()
    }
}

enum ExternalNotificationEventKind {
    case complete, error, stalled, scheduledStart
}

/// 触发判定（WPF NotificationTrigger 同构）：事件类开关 ∨ 日志计数 ∨ 白名单匹配。
@MainActor final class ExternalNotificationTrigger: ObservableObject {
    private var newLogs = 0

    func shouldSend(policy: ExternalNotificationDeliveryPolicy, kind: ExternalNotificationEventKind,
                    content: String, filter: ExternalNotificationContentFilter = .init()) -> Bool {
        let selected: Bool
        switch kind {
        case .complete: selected = policy.sendWhenComplete
        case .error: selected = policy.sendWhenError
        case .stalled: selected = policy.sendWhenStalled
        case .scheduledStart: selected = policy.sendBeforeScheduledStart
        }
        newLogs += 1
        return selected
            || (policy.sendAfterLogCount && newLogs >= policy.newLogCount)
            || (policy.sendWhenContentMatches && filter.matches(patterns: policy.whitelist, content: content) == true)
    }

    /// 停止/禁用/无渠道时清零（WPF Reset 同位）。
    func reset() { newLogs = 0 }
}

/// 行分隔正则白/黑名单匹配（WPF NotificationFilter 同构：非法模式→nil 不发送，
/// 50ms 匹配预算超时→nil）。
struct ExternalNotificationContentFilter {
    func matches(patterns: String, content: String, budget: (Int) -> Date = { Date().addingTimeInterval(Double($0) / 1000) },
                 now: () -> Date = Date.init) -> Bool? {
        let lines = patterns.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        var regexes: [NSRegularExpression] = []
        for line in lines {
            guard let regex = try? NSRegularExpression(pattern: line) else { return nil }
            regexes.append(regex)
        }
        let start = now()
        let deadline = budget(50)
        for regex in regexes {
            if now() > deadline { return nil }
            let range = NSRange(content.startIndex..., in: content)
            if regex.firstMatch(in: content, range: range) != nil {
                _ = start
                return true
            }
        }
        return false
    }
}

/// 日志历史与打包（WPF NotificationHistory 同构：10000 容量、时间窗、条数上限、
/// 黑名单过滤、100ms 预算）。
@MainActor final class ExternalNotificationHistory: ObservableObject {
    static let capacity = 10000
    struct Entry: Equatable {
        let timestamp: Date
        let content: String
    }

    private(set) var entries: [Entry] = []

    func add(_ entry: Entry) {
        entries.append(entry)
        while entries.count > Self.capacity {
            entries.removeFirst()
        }
    }

    /// 当前事件的正文 + （可选）时间窗内历史条目拼包；条数钳制与黑名单同 WPF。
    func bundle(current content: String, at now: Date, policy: ExternalNotificationDeliveryPolicy,
                filter: ExternalNotificationContentFilter = .init(),
                clock: () -> Date = Date.init) -> String {
        let maxEntries = max(0, min(policy.maxEntries, Self.capacity))
        guard policy.includePreviousLogs, maxEntries > 0 else { return content }
        let cutoff = policy.timeMinutes == 0 ? Date.distantPast : now.addingTimeInterval(-Double(policy.timeMinutes) * 60)
        var collected: [String] = []
        let deadline = clock().addingTimeInterval(0.1)
        for entry in entries.reversed() {
            if clock() > deadline { break }
            if collected.count >= maxEntries { break }
            if entry.timestamp < cutoff || entry.content == content { continue }
            if policy.filterPreviousLogs,
               filter.matches(patterns: policy.blacklist, content: entry.content) == true {
                continue
            }
            collected.append(entry.content)
        }
        if collected.isEmpty { return content }
        // WPF 按 _events.Reverse() 迭代拼包：正文后先最近事件（newest-first）。
        return ([content] + collected).joined(separator: "\n")
    }
}

/// 停滞检测（WPF RunningState.StallOccurred 同构）：运行中按超时分钟监控消息活动，
/// 活动复位计时；持续停滞到点发一次并按同间隔重复（accumulated 递增）。
@MainActor final class ExternalStallMonitor {
    private var monitorTask: Task<Void, Never>?
    private var lastActivityAt = Date()
    private(set) var accumulatedMinutes = 0

    /// 消息泵喂活（WPF NotifyOutputActivity 同位）。
    func activity() { lastActivityAt = Date() }

    /// 运行结束时取消并复位累计。
    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        accumulatedMinutes = 0
    }

    /// 运行开始武装。onStalled(initialMinutes:accumulatedMinutes:) 仅在持续停滞
    /// （距上次活动 ≥ 超时）时回调；重复间隔与超时同值。
    func arm(timeoutMinutes: Int, onStalled: @escaping @MainActor (Int, Int) -> Void) {
        stop()
        lastActivityAt = Date()
        guard timeoutMinutes > 0 else { return }
        monitorTask = Task { [weak self] in
            var accumulated = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TimeInterval(timeoutMinutes * 60)))
                guard !Task.isCancelled, let self else { return }
                let idle = Date().timeIntervalSince(self.lastActivityAt)
                guard idle >= Double(timeoutMinutes * 60) - 5 else { continue }
                accumulated += timeoutMinutes
                self.accumulatedMinutes = accumulated
                onStalled(timeoutMinutes, accumulated)
            }
        }
    }
}
