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

    /// 中5（P25-1-R3）：打包前缀的 WPF 色词表（UiLogBrush 同名 token，随历史条目
    /// 投递）。WPF TaskQueue 事件默认 Trace 色（NotificationService.cs:104）；
    /// 错误/停滞按语义映射 Error/Warning 色。
    var historyColorToken: String {
        switch self {
        case .complete, .scheduledStart: return "TraceLogBrush"
        case .error: return "ErrorLogBrush"
        case .stalled: return "WarningLogBrush"
        }
    }
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
        // 低8（P25-1-R3）：WPF 定时开始前通知不走 trigger——不入史（调用面）、
        // 不计数、不走计数/白名单分支（NotificationService.cs:98-106 "A scheduled
        // notification is not a new displayed log entry"），仅按策略开关门控。
        guard kind != .scheduledStart else { return selected }
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
        /// 中5（P25-1-R3）：打包前缀色词（WPF NotificationEvent.Color 对位，
        /// UiLogBrush token；缺省 Trace 色=TaskQueue 事件缺省）。
        var color: String = "TraceLogBrush"
    }

    private(set) var entries: [Entry] = []

    func add(_ entry: Entry) {
        entries.append(entry)
        while entries.count > Self.capacity {
            entries.removeFirst()
        }
    }

    /// 当前事件的正文 + （可选）时间窗内历史条目拼包（WPF NotificationHistory.cs:56-91
    /// 同构：历史 oldest-first、每条 [HH:mm:ss][color] 前缀、正文在最后——中5/P25-1-R3
    /// 原 Mac 实现方向相反且无前缀）。条数只计窗内未过滤条目；黑名单非法正则与
    /// 100ms 预算超时整体放弃历史仅发正文（中4/P25-1-R3 fail-safe 剔除方向与 WPF
    /// 一致——原 Mac 非法放行全部/超时保留部分，与白名单方向相反）。
    func bundle(current content: String, at now: Date, policy: ExternalNotificationDeliveryPolicy,
                filter: ExternalNotificationContentFilter = .init(),
                clock: () -> Date = Date.init) -> String {
        let maxEntries = max(0, min(policy.maxEntries, Self.capacity))
        guard policy.includePreviousLogs, maxEntries > 0 else { return content }
        let cutoff = policy.timeMinutes == 0 ? Date.distantPast : now.addingTimeInterval(-Double(policy.timeMinutes) * 60)
        var collected: [Entry] = []
        let deadline = clock().addingTimeInterval(0.1)
        for entry in entries.reversed() {
            if collected.count >= maxEntries { break }
            if entry.timestamp < cutoff { continue }
            // 当前事件本体不入附包（WPF ReferenceEquals(item, current) 同义；结构体
            // 以记账时刻+文本同值判定——旧的相同文案条目照附，低3 同步消除）。
            if entry.timestamp == now, entry.content == content { continue }
            if policy.filterPreviousLogs {
                if clock() > deadline { return content }
                switch filter.matches(patterns: policy.blacklist, content: entry.content) {
                case true: continue
                case nil: return content
                case false: break
                }
            }
            collected.append(entry)
        }
        if collected.isEmpty { return content }
        let formatter = Self.timeFormatter
        let lines = collected.reversed().map { "[\(formatter.string(from: $0.timestamp))][\($0.color)] \($0.content)" }
        return (lines + [content]).joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        // 固定 POSIX locale：避免用户日历/历法改写 HH:mm:ss 数字格式。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// 停滞检测（WPF RunningState.StallOccurred 同构）：运行中按超时分钟监控消息活动，
/// 活动复位计时；持续停滞到点发一次并按同间隔重复（accumulated 递增）。
@MainActor final class ExternalStallMonitor {
    private var monitorTask: Task<Void, Never>?
    private var lastActivityAt = Date()
    private(set) var accumulatedMinutes = 0
    /// 中6（P25-1-R3）：时钟与检查点步长可注入——真实路径默认 Date.init 与
    /// 超时同值步长；测试以假时钟+短步长驱动整条触发路径（原 60s 检查点在
    /// 测试内永不到达，「喂活防误报」断言恒真）。
    var now: () -> Date = Date.init
    var stepInterval: Duration?

    /// 消息泵喂活（WPF NotifyOutputActivity 同位）。
    func activity() { lastActivityAt = now() }

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
        lastActivityAt = now()
        guard timeoutMinutes > 0 else { return }
        let step = stepInterval ?? .seconds(TimeInterval(timeoutMinutes * 60))
        monitorTask = Task { [weak self] in
            var accumulated = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, let self else { return }
                let idle = self.now().timeIntervalSince(self.lastActivityAt)
                guard idle >= Double(timeoutMinutes * 60) - 5 else { continue }
                accumulated += timeoutMinutes
                self.accumulatedMinutes = accumulated
                onStalled(timeoutMinutes, accumulated)
            }
        }
    }
}
