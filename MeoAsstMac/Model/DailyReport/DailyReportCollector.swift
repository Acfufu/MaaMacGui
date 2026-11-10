import Foundation
import os

// 作战日报采集器（WPF DailyReportCollector 同构）：把 Fight 链的执行期回调
//（掉落、用药、碎石、次数）聚合为 CombatSession，回调即写当日文件。
// 一条 Fight 链（独立理智作战或库存保持的单条计划）对应一条 session，
// 别传复刻一条链打多关时按关卡拆成多条；零场次的链不产生记录，session
// 在首个执行数据到达时才落盘。
// 调用方为 MAAViewModel.processMessage（MainActor），内部状态无需加锁。
@MainActor
enum DailyReportCollector {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MAA", category: "DailyReportCollector")

    private static var pendingSessions: [Int32: CombatSession] = [:]
    private static var persistedTaskIds: Set<Int32> = []

    /// 每局开始前 FightTimes 读到的代理倍率与理智消耗（已含倍率），供该局结算时累加。
    private static var pendingRounds: [Int32: (series: Int, sanityCost: Int)] = [:]

    /// 别传复刻进新关后、首个 StageDrops 之前发生的用药/碎石先挂账，随该关结算归属。
    private static var pendingConsumables: [Int32: (medicines: Int, expiring: Int, stones: Int)] = [:]

    private static var currentDay: Date?
    private static var currentData = DailyReportDayData()

    /// 当日文件无法读取且未能备份时置 false，暂停写入以免覆盖原文件；下次切换游戏日时重新判断。
    private static var currentWritable = true

    // MARK: - 生命周期（由 MaaMessage 的 TaskChain 面调用）

    /// Fight 链开始（TaskChainStart 且 taskchain == "Fight"）。
    static func fightChainStarted(taskID: Int32) {
        pendingSessions[taskID] = CombatSession(startTime: Date.now)
    }

    /// 单条 Fight 链终态（TaskChainCompleted/Error/Stopped）。
    static func fightChainFinished(taskID: Int32, endTime: Date = .now) {
        finalizeSession(taskID: taskID, endTime: endTime)
    }

    /// 任务队列停止（手动停止、掉线、强制定时启动统一走 TaskChainStopped /
    /// AllTasksCompleted）时，把所有未定稿 session 补结束时刻定稿（WPF OnQueueStopped 同构）。
    static func queueStopped() {
        for taskID in Array(pendingSessions.keys) {
            finalizeSession(taskID: taskID, endTime: .now)
        }
    }

    /// 按当前保留档位裁剪超期日文件。
    static func pruneNow(retention: DailyReportRetention, channel: MAAClientChannel, directory: URL) {
        DailyReportStore.prune(retention, today: .now, calendar: channel.calendar, directory: directory)
    }

    // MARK: - 回调面（由 MaaMessage 的 subTask 面调用；参数为已解析的裸值）

    static func stageDrops(taskID: Int32, stageCode: String?, curTimes: Int?, stats: [(itemId: String?, itemName: String?, quantity: Int)]) {
        guard var session = pendingSessions[taskID] else {
            return
        }

        // 别传复刻一条链依次打多个关卡，关卡变化时结束当前 session 另起一条，
        // 各关的场次、理智与掉落分开记录。
        // stageCode 为空是 OCR 完全没识别到（识别出错会上报错码，无掉落关会上报
        // _INVALID_），无归属信息，并入当前 session。
        if let stageCode, !stageCode.isEmpty {
            if !session.stage.isEmpty && stageCode != session.stage {
                session = startNextStageSession(taskID: taskID)
            }

            session.stage = stageCode
        }

        // cur_times 是结算画面识别的本局代理倍率（识别不到时缺省），不是累计场次；
        // 缺省时退回开局读到的倍率。
        let round = pendingRounds.removeValue(forKey: taskID)
        let series = curTimes ?? (round?.series ?? 1)
        session.times += series
        session.rounds += 1
        if let round {
            // 开局消耗按开局倍率计；结算倍率与之不同时（如次数上限截断）按单局消耗折算。
            session.sanity += round.series == series ? round.sanityCost : round.sanityCost / max(round.series, 1) * series
        }

        // 该关结算时把开局前挂账的用药/碎石并入本关。
        if let consumables = pendingConsumables.removeValue(forKey: taskID) {
            session.medicinesUsed += consumables.medicines
            session.expiringMedicinesUsed += consumables.expiring
            session.stonesUsed += consumables.stones
        }

        // stats 的 quantity 是本关卡内的累计值（别传复刻每关从零计），最后一次回调即终值快照。
        var drops: [String: Int] = [:]
        for item in stats {
            guard let itemId = item.itemId, !itemId.isEmpty else {
                continue
            }

            // 家具归一为统一 id，与掉落日志的既有处理一致。
            let normalized = item.itemName == "furni" ? "3401" : itemId
            drops[normalized] = item.quantity
        }

        if !drops.isEmpty {
            session.drops = drops
        }

        pendingSessions[taskID] = session
        persistIfNeeded(taskID: taskID, session: session)
    }

    static func useMedicine(taskID: Int32, isExpiring: Bool, count: Int) {
        guard pendingSessions[taskID] != nil else {
            return
        }

        var pending = pendingConsumables[taskID] ?? (0, 0, 0)
        if isExpiring {
            pending.expiring += count
        } else {
            pending.medicines += count
        }

        pendingConsumables[taskID] = pending
    }

    /// 只暂存本局倍率与消耗，等该局 StageDrops 结算再计入；达到次数上限时不再开局，不会有对应结算。
    static func fightTimes(taskID: Int32, series: Int?, sanityCost: Int?) {
        guard pendingSessions[taskID] != nil, let sanityCost else {
            return
        }

        pendingRounds[taskID] = (series: series ?? 1, sanityCost: sanityCost)
    }

    /// 碎石确认以通用 ProcessTask 子任务上报（SubTaskStart，task == "StoneConfirm"）。
    static func stoneConfirm(taskID: Int32) {
        guard pendingSessions[taskID] != nil else {
            return
        }

        var pending = pendingConsumables[taskID] ?? (0, 0, 0)
        pending.stones += 1
        pendingConsumables[taskID] = pending
    }

    // MARK: - 内部

    /// 结束任务当前的 session 并以同一任务 id 新开一条，起始时刻接上一条的结束时刻。
    /// 新关卡开局时暂存的倍率、理智与挂账的用药/碎石属于新 session，不随旧 session 结束而丢弃。
    private static func startNextStageSession(taskID: Int32) -> CombatSession {
        let now = Date.now
        let round = pendingRounds.removeValue(forKey: taskID)
        let consumables = pendingConsumables.removeValue(forKey: taskID)
        finalizeSession(taskID: taskID, endTime: now)
        if let round {
            pendingRounds[taskID] = round
        }

        if let consumables {
            // 挂账随新关归属，不并回已结束的旧 session。
            pendingConsumables[taskID] = consumables
        }

        let next = CombatSession(startTime: now)
        pendingSessions[taskID] = next
        return next
    }

    private static func persistIfNeeded(taskID: Int32, session: CombatSession) {
        // 零场次且无掉落、用药、碎石的链没有统计价值，有数据前不落盘。
        guard !session.isEmpty else {
            return
        }

        // WPF 靠 class 引用语义让已追加的 session 就地更新；struct 这里改为按 id 回写。
        if !persistedTaskIds.insert(taskID).inserted {
            if let index = currentData.sessions.firstIndex(where: { $0.id == session.id }) {
                currentData.sessions[index] = session
            }

            saveCurrent()
            return
        }

        ensureCurrentDay()
        currentData.sessions.append(session)
        saveCurrent()
    }

    private static func finalizeSession(taskID: Int32, endTime: Date) {
        pendingRounds.removeValue(forKey: taskID)

        // 链尾仍挂账的用药/碎石并回当前 session（吃药后未再开局、或结算未至即停止）。
        if let consumables = pendingConsumables.removeValue(forKey: taskID),
            var tail = pendingSessions[taskID],
            consumables.medicines + consumables.expiring + consumables.stones > 0
        {
            tail.medicinesUsed += consumables.medicines
            tail.expiringMedicinesUsed += consumables.expiring
            tail.stonesUsed += consumables.stones
            pendingSessions[taskID] = tail
        }

        guard let session = pendingSessions.removeValue(forKey: taskID) else {
            return
        }

        let persisted = persistedTaskIds.remove(taskID) != nil
        if session.isEmpty {
            // 落盘判断已拦下空记录，这里兜底清理任何已写入的空 session，避免文件残留无结束时刻的空行。
            if persisted, let index = currentData.sessions.firstIndex(where: { $0.id == session.id }) {
                currentData.sessions.remove(at: index)
                saveCurrent()
            }

            return
        }

        var finished = session
        finished.endTime = endTime
        if let index = currentData.sessions.firstIndex(where: { $0.id == session.id }) {
            currentData.sessions[index] = finished
        }
        if persisted {
            saveCurrent()
        }
    }

    /// 保证写入目标是当前游戏日；跨日时（正常不会发生，掉线或定时启动会先停止旧轮）
    /// 将旧数据留在原文件。
    private static func ensureCurrentDay() {
        ensureCurrentDay(now: .now, channel: currentChannel, directory: Self.directory)
    }

    /// 可注入时钟/频道/目录的版本（测试面）。
    static func ensureCurrentDay(now: Date, channel: MAAClientChannel, directory: URL) {
        let today = channel.calendar.startOfGameDay(for: now)
        if today == currentDay {
            return
        }

        currentDay = today
        let (data, writable) = DailyReportStore.load(today, calendar: channel.calendar, directory: directory)
        currentData = data ?? DailyReportDayData()
        currentWritable = writable

        // 游戏日切换顺手清超期，免长开不重启时旧文件一直留着。
        if let retention = retentionSetting {
            DailyReportStore.prune(retention, today: now, calendar: channel.calendar, directory: directory)
        }
    }

    private static func saveCurrent() {
        if currentDay == nil {
            ensureCurrentDay()
        }

        guard let currentDay, currentWritable else {
            return
        }

        DailyReportStore.save(currentDay, currentData, calendar: currentChannel.calendar, directory: directory)
    }

    // MARK: - 环境

    /// 当前服务器频道（与设置面 @AppStorage("MAAClientChannel") 同键）。
    static var currentChannel: MAAClientChannel {
        if let channelOverride {
            return channelOverride
        }

        if let raw = UserDefaults.standard.string(forKey: "MAAClientChannel") {
            return MAAClientChannel(rawValue: raw) ?? .Official
        }

        return .Official
    }

    /// 测试缝：注入后 currentChannel 固定返回该频道（P15.1 可注入 computed 同款）。
    nonisolated(unsafe) static var channelOverride: MAAClientChannel?

    static var directory: URL {
        if let directoryOverride {
            return directoryOverride
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DailyReport") ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DailyReport")
    }

    /// 测试缝：注入后存储目录指向临时目录，避免测试写真实 Application Support。
    nonisolated(unsafe) static var directoryOverride: URL?

    /// 保留档位设置读取面（UserDefaults；由设置面/VM 写入，键与视图层 @AppStorage 一致）。
    static var retentionSetting: DailyReportRetention? {
        guard let raw = UserDefaults.standard.string(forKey: "MAADailyReportRetention") else {
            return nil
        }

        return DailyReportRetention(rawValue: raw)
    }

    /// 测试面：清空全部聚合状态。
    static func resetForTesting() {
        pendingSessions = [:]
        persistedTaskIds = []
        pendingRounds = [:]
        pendingConsumables = [:]
        currentDay = nil
        currentData = DailyReportDayData()
        currentWritable = true
    }
}
