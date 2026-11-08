import Combine
import Foundation
// App 目标内 IOKit 电源断言符号由模块继承可见;单文件编译下用同模块再导出垫片
// 补齐,生产 TaskTimerManager.swift 保持逐字编译。
@_exported import IOKit
@_exported import IOKit.pwr_mgt

// AT-3: 生产 TaskTimerManager(#179 handoff 架构)原文件编译并驱动:
// 定时回调经 startDailyTasks(origin: .schedule) 正常路由;weak viewModel
// 失效后同一触发路径不得产生任何启动调用。仅替换外部依赖 MAAViewModel 与
// DailyTask;调度、occurrence 账本、handoff、run 协调器均为生产实现。

struct DailyTask {
    var id = UUID()
    var enabled = true
}

// P21 提取桩：TaskTimerManager 的提前通知面引用本服务；此处仅收口签名。
@MainActor final class LocalNotificationService {
    func cancelPending(id: String) {}
    func schedule(id: String, title: String, body: String, fireDate: Date, at now: Date = Date()) async {}
}

extension Notification.Name {
    static let MAAPreventSystemSleepingChanged = Notification.Name("MAAPreventSystemSleepingChanged")
}

@MainActor final class MAAViewModel: ObservableObject {
    enum Status { case idle, pending, busy }
    enum TaskStartResult { case started, skipped, failed }
    @Published var scheduledDailyTaskTimers: [DailyTaskSchedule] = []
    @Published private(set) var status: Status = .idle
    var isStartStopInFlight = false
    var startupCancellationLocked = false
    var isCoreInitialized = true
    var preventSystemSleeping = false
    var dailyTaskProfile = "Fixture"
    var tasks = [DailyTask]()
    let dailyRunCoordinator = DailyRunCoordinator()
    var canStartTasks: Bool { status == .idle && !isStartStopInFlight && dailyRunCoordinator.active == nil }
    // P21/S07+S08 提取桩：触发前切档与提前通知面（真实服务由 local-notification 套件覆盖）。
    var notifyBeforeScheduledStart = false
    var scheduledStartNotificationMinutes = 5
    let localNotifications = LocalNotificationService()
    var switchedProfiles: [String] = []
    func switchProfile(_ profileID: String) { switchedProfiles.append(profileID) }
    // 全局探针:任何实例的启动调用都会落账,weak 失效窗口内必须保持静默。
    static var startOrigins: [DailyRunOrigin] = []

    func startDailyTasks(origin: DailyRunOrigin = .manual, snapshot: DailyRunSnapshot? = nil,
                         recoverGame: Bool = false, recoveryCurrent: (@MainActor () -> Bool)? = nil) async -> TaskStartResult {
        Self.startOrigins.append(origin)
        guard (try? dailyRunCoordinator.begin(profileID: snapshot?.profileID ?? dailyTaskProfile, origin: origin)) != nil else {
            return .skipped
        }
        status = .busy
        return .started
    }

    func stop(cancelScheduledStart: Bool = true) async throws {
        if let active = dailyRunCoordinator.active {
            _ = try dailyRunCoordinator.finish(active.id, outcome: .cancelled, cleanupSucceeded: true)
        }
        status = .idle
    }

    func forceRecoveryEligibility(snapshot: DailyRunSnapshot) -> @MainActor () -> Bool { { true } }
}

@main struct ScheduleTimerManagerTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            assertions += 1
            precondition(value, message)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maa-timer-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TaskTimerManager(directory: directory.appendingPathComponent("legacy"))
        try manager.configureSharedDirectory(directory)
        manager.setBackgroundSchedulingEnabled(true) // grace 300:过去几分钟内的到期计划保持可领取
        let calendar = Calendar.current
        func plan(minutesAgo: Int) -> DailyTaskSchedule {
            let earlier = calendar.dateComponents([.hour, .minute],
                                                  from: calendar.date(byAdding: .minute, value: -minutesAgo, to: Date())!)
            return DailyTaskSchedule(id: UUID(), hour: earlier.hour!, minute: earlier.minute!, isEnabled: true)
        }
        let plans = [plan(minutesAgo: 1), plan(minutesAgo: 0)]
        // 1. viewModel 存在:连接即触发一次定时回调,必须经 schedule 源路由启动。
        var live: MAAViewModel? = MAAViewModel()
        live?.scheduledDailyTaskTimers = plans
        manager.connectToModel(viewModel: live!)
        for _ in 0..<10000 {
            if MAAViewModel.startOrigins.count == 1, !manager.recentOccurrences.isEmpty { break }
            await Task.yield()
        }
        check(MAAViewModel.startOrigins == [.schedule],
              "a live weak reference routes the timer fire through startDailyTasks(origin: .schedule)")
        check(manager.recentOccurrences.first?.result == .started,
              "the routed run is recorded as started in the occurrence ledger")
        check(manager.recentOccurrences.first?.runID == live?.dailyRunCoordinator.active?.id,
              "the ledger runID matches the run the routed start created")
        // 2. weak 失效:释放模型后,同一触发路径不得产生任何启动调用或新领取。
        let recorded = manager.recentOccurrences.count
        live = nil
        manager.refreshRunningTimersIfNecessary()
        for _ in 0..<200 { await Task.yield() }
        check(MAAViewModel.startOrigins.count == 1,
              "a dead weak reference routes no start on the next timer fire")
        check(manager.recentOccurrences.count == recorded && manager.failure == nil,
              "the dead window claims no occurrence and reports no failure")
        // 3. 重连:仍在到期窗口内的新计划经同一触发路径启动,证明失效窗口阻断的
        //    是 weak 引用本身,而非管道残留状态。
        let revived = MAAViewModel()
        revived.scheduledDailyTaskTimers = plans + [plan(minutesAgo: 2)]
        manager.connectToModel(viewModel: revived)
        for _ in 0..<10000 {
            if MAAViewModel.startOrigins.count == 2 { break }
            await Task.yield()
        }
        check(MAAViewModel.startOrigins == [.schedule, .schedule],
              "a reconnected live model resumes routing scheduled starts")
        check(manager.recentOccurrences.first?.result == .started
              && manager.recentOccurrences.first?.runID == revived.dailyRunCoordinator.active?.id,
              "the post-reconnect fire starts and records exactly one new run")
        print("PASS: \(assertions) timer-manager weak-reference assertions")
    }
}
