import Foundation

// 作战日报测试：存储往返（含 WPF 小数秒日期互通）、游戏日边界、保留裁剪、
// 采集器聚合（倍率折算/挂账/别传拆关/空链抑制/队列停止定稿）、排名误差数学。
// 语义源：WPF DailyReportStore/DailyReportCollector/DailyReportRankRowViewModel。

@main struct DailyReportTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) rethrows {
            checks += 1
            let result = try value()
            precondition(result, label)
        }

        let calendar = MAAClientChannel.Official.calendar
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-report-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        DailyReportCollector.directoryOverride = tempRoot
        DailyReportCollector.channelOverride = .Official
        defer {
            DailyReportCollector.directoryOverride = nil
            DailyReportCollector.channelOverride = nil
        }

        // MARK: 游戏日锚点与文件名（Official: UTC+8，04:00 界）

        func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, utcOffsetHours: Int = 0) -> Date {
            var components = DateComponents()
            components.timeZone = TimeZone(secondsFromGMT: utcOffsetHours * 3600)
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            components.minute = minute
            return Calendar(identifier: .gregorian).date(from: components)!
        }

        // 2026-11-11 03:59 UTC+8 = 2026-11-10 19:59 UTC，仍属游戏日 11-10。
        let beforeReset = utcDate(2026, 11, 11, 3, 59, utcOffsetHours: 8)
        let afterReset = utcDate(2026, 11, 11, 4, 0, utcOffsetHours: 8)
        check(DailyReportStore.dayString(for: beforeReset, calendar: calendar) == "2026-11-10", "game day before 04:00 rolls back")
        check(DailyReportStore.dayString(for: afterReset, calendar: calendar) == "2026-11-11", "game day at 04:00 rolls forward")
        check(calendar.startOfGameDay(for: beforeReset) == calendar.startOfGameDay(for: utcDate(2026, 11, 10, 23, 59, utcOffsetHours: 8)), "same game day anchor across reset boundary days")

        // EN 服 UTC-7：04:00 当地 = 11:00 UTC 翻日；03:59 当地 = 10:59 UTC 仍是前一日。
        let enCalendar = MAAClientChannel.YoStarEN.calendar
        check(
            DailyReportStore.dayString(for: utcDate(2026, 11, 11, 11, 0), calendar: enCalendar) == "2026-11-11",
            "EN server resets at local 04:00 (= 11:00 UTC)")
        check(
            DailyReportStore.dayString(for: utcDate(2026, 11, 11, 10, 59), calendar: enCalendar) == "2026-11-10",
            "EN server one minute before reset stays on previous game day")

        // MARK: 存储往返（WPF Newtonsoft 小数秒日期互通）

        let dayAnchor = calendar.startOfGameDay(for: afterReset)
        var session = CombatSession(startTime: beforeReset)
        session.stage = "1-7"
        session.endTime = afterReset
        session.times = 24
        session.rounds = 12
        session.sanity = 72
        session.medicinesUsed = 1
        session.expiringMedicinesUsed = 2
        session.stonesUsed = 3
        session.drops = ["30012": 5, "3401": 1]
        var dayData = DailyReportDayData()
        dayData.sessions = [session]
        DailyReportStore.save(dayAnchor, dayData, calendar: calendar, directory: tempRoot)

        let (loaded, writable) = DailyReportStore.load(dayAnchor, calendar: calendar, directory: tempRoot)
        check(writable, "roundtrip keeps file writable")
        check(loaded?.sessions.count == 1, "roundtrip session count")
        check(loaded?.sessions.first == session, "roundtrip session equality (fractional ISO dates)")

        // WPF Newtonsoft 形态（7 位小数秒 + +00:00 偏移）可解码。
        let wpfJSON = """
        {"version":1,"sessions":[{"stage":"1-7","startTime":"2026-11-10T19:59:30.1234567+00:00","endTime":"2026-11-10T20:10:00+00:00","times":2,"rounds":1,"sanity":12,"medicinesUsed":0,"expiringMedicinesUsed":0,"stonesUsed":0,"drops":{"30012":3}}]}
        """
        let wpfFile = tempRoot.appendingPathComponent("2026-11-10.json")
        try wpfJSON.data(using: .utf8)!.write(to: wpfFile)
        let wpfDay = DailyReportStore.dayFromString("2026-11-10")!
        let (wpfLoaded, wpfWritable) = DailyReportStore.load(wpfDay, calendar: calendar, directory: tempRoot)
        check(wpfWritable, "wpf-style file loads writable")
        check(wpfLoaded?.sessions.first?.times == 2, "wpf-style fractional seconds parse")

        // 损坏文件转 .bak 且 writable（后续保存不会覆盖原内容）。
        try Data("not json".utf8).write(to: tempRoot.appendingPathComponent("2026-11-09.json"))
        let (corruptData, corruptWritable) = DailyReportStore.load(
            DailyReportStore.dayFromString("2026-11-09")!, calendar: calendar, directory: tempRoot)
        check(corruptData == nil && corruptWritable, "corrupt file backed up and writable")
        check(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("2026-11-09.json.bak").path), "corrupt backup exists")

        // MARK: 保留裁剪

        for offset in [40, 10, 3, 0] {
            let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: -offset, to: dayAnchor)!
            DailyReportStore.save(day, DailyReportDayData(), calendar: calendar, directory: tempRoot)
        }

        let prunableMonth = DailyReportStore.listPrunableDays(.month, today: afterReset, calendar: calendar, directory: tempRoot)
        check(prunableMonth?.count == 1, "month retention prunes only 40-day-old file")
        DailyReportStore.prune(.month, today: afterReset, calendar: calendar, directory: tempRoot)
        check(DailyReportStore.listDays(directory: tempRoot).count == 4, "prune keeps recent files")
        check(DailyReportStore.listPrunableDays(.unlimited, today: afterReset, calendar: calendar, directory: tempRoot) == nil, "unlimited retention never prunes")

        // MARK: 采集器聚合（独立目录，不与存储往返测试的文件混读）

        var collectorDir = tempRoot.appendingPathComponent("collector")
        // 每个用例段独立子目录：同游戏日的日文件会跨段累积，读回断言必须段内隔离。
        func beginCollectorSection() {
            collectorDir = collectorDir.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: collectorDir, withIntermediateDirectories: true)
            DailyReportCollector.directoryOverride = collectorDir
        }

        defer { DailyReportCollector.directoryOverride = tempRoot }

        func collectedDays() -> [String: DailyReportDayData] {
            let days = DailyReportStore.listDays(directory: collectorDir)
            var result: [String: DailyReportDayData] = [:]
            for day in days {
                let (data, _) = DailyReportStore.load(day, calendar: calendar, directory: collectorDir)
                result[DailyReportStore.dayString(for: day, calendar: calendar)] = data
            }

            return result
        }

        // 空链（只有启动，无结算数据）不落盘。
        DailyReportCollector.resetForTesting()
        beginCollectorSection()
        DailyReportCollector.ensureCurrentDay(now: afterReset, channel: .Official, directory: collectorDir)
        DailyReportCollector.fightChainStarted(taskID: 1)
        DailyReportCollector.fightChainFinished(taskID: 2)
        check(collectedDays().values.allSatisfy { $0.sessions.isEmpty }, "empty chain produces no record")

        // 单链：用药/碎石挂账 + FightTimes 倍率折算 + StageDrops 结算归属。
        DailyReportCollector.resetForTesting()
        beginCollectorSection()
        DailyReportCollector.ensureCurrentDay(now: afterReset, channel: .Official, directory: collectorDir)
        DailyReportCollector.fightChainStarted(taskID: 1)
        DailyReportCollector.useMedicine(taskID: 1, isExpiring: false, count: 2)
        DailyReportCollector.useMedicine(taskID: 1, isExpiring: true, count: 1)
        DailyReportCollector.stoneConfirm(taskID: 1)
        DailyReportCollector.fightTimes(taskID: 1, series: 2, sanityCost: 12)
        DailyReportCollector.stageDrops(
            taskID: 1, stageCode: "1-7", curTimes: 2,
            stats: [(itemId: "30012", itemName: "固源岩", quantity: 10), (itemId: "furni_stage_id", itemName: "furni", quantity: 1)])
        DailyReportCollector.queueStopped()
        let single = collectedDays().values.flatMap { $0.sessions }
        check(single.count == 1, "single chain produces one session")
        check(single.first?.stage == "1-7", "stage recorded")
        check(single.first?.times == 2, "times accumulate by settlement multiplier")
        check(single.first?.rounds == 1, "rounds count one settlement")
        check(single.first?.sanity == 12, "sanity uses pre-battle multiplier cost")
        check(single.first?.medicinesUsed == 2 && single.first?.expiringMedicinesUsed == 1, "pending medicines merged at settlement")
        check(single.first?.stonesUsed == 1, "pending stones merged at settlement")
        check(single.first?.drops == ["30012": 10, "3401": 1], "drops cumulative snapshot with furni normalization")
        check(single.first?.endTime != nil, "queue stop finalizes end time")

        // 结算倍率与开局倍率不同（次数上限截断）：按单局消耗折算。
        DailyReportCollector.resetForTesting()
        beginCollectorSection()
        DailyReportCollector.ensureCurrentDay(now: afterReset, channel: .Official, directory: collectorDir)
        DailyReportCollector.fightChainStarted(taskID: 1)
        DailyReportCollector.fightTimes(taskID: 1, series: 4, sanityCost: 24)
        DailyReportCollector.stageDrops(taskID: 1, stageCode: "1-7", curTimes: 1, stats: [])
        DailyReportCollector.queueStopped()
        let prorated = collectedDays().values.flatMap { $0.sessions }
        check(prorated.first?.sanity == 6, "truncated multiplier prorates sanity per round (24/4*1)")
        check(prorated.first?.times == 1, "truncated multiplier records settlement series")

        // 别传复刻一条链打多关：关卡变化拆 session，倍率与挂账随新关归属。
        DailyReportCollector.resetForTesting()
        beginCollectorSection()
        DailyReportCollector.ensureCurrentDay(now: afterReset, channel: .Official, directory: collectorDir)
        DailyReportCollector.fightChainStarted(taskID: 1)
        DailyReportCollector.stageDrops(taskID: 1, stageCode: "CB-1", curTimes: 1, stats: [(itemId: "a", itemName: "a", quantity: 1)])
        DailyReportCollector.useMedicine(taskID: 1, isExpiring: false, count: 1)
        DailyReportCollector.fightTimes(taskID: 1, series: 1, sanityCost: 10)
        DailyReportCollector.stageDrops(taskID: 1, stageCode: "CB-2", curTimes: 1, stats: [(itemId: "b", itemName: "b", quantity: 2)])
        DailyReportCollector.queueStopped()
        let split = collectedDays().values.flatMap { $0.sessions }.sorted { $0.stage < $1.stage }
        check(split.count == 2, "stage change splits sessions")
        check(split[0].stage == "CB-1" && split[0].drops == ["a": 1], "first stage keeps own drops")
        check(split[1].stage == "CB-2" && split[1].drops == ["b": 2], "second stage starts fresh drops")
        check(split[1].medicinesUsed == 1 && split[1].sanity == 10, "consumables and rounds carry into next stage session")
        check(split[1].endTime != nil && split[0].endTime != nil, "both sessions finalized")

        // 非 Fight 链的用药不产生记录。
        DailyReportCollector.resetForTesting()
        beginCollectorSection()
        DailyReportCollector.ensureCurrentDay(now: afterReset, channel: .Official, directory: collectorDir)
        DailyReportCollector.useMedicine(taskID: 9, isExpiring: false, count: 5)
        DailyReportCollector.queueStopped()
        check(collectedDays().values.allSatisfy { $0.sessions.isEmpty }, "orphan callbacks create nothing")

        // MARK: 排名数学（WPF DailyReportRankRowViewModel 同构）

        check(DailyReportMath.niceAxisMax(1) == 1, "axis max floor 1")
        check(DailyReportMath.niceAxisMax(2) == 2 && DailyReportMath.niceAxisMax(5) == 5, "axis max exact values stick")
        check(DailyReportMath.niceAxisMax(3) == 5 && DailyReportMath.niceAxisMax(9) == 10, "axis max 1/2/5 ladder")
        check(DailyReportMath.niceAxisMax(11) == 20 && DailyReportMath.niceAxisMax(999) == 1000, "axis max magnitude steps")
        check(DailyReportMath.niceAxisMax(1001) == 2000, "axis max next magnitude")

        check(DailyReportMath.RankRow.rateText(1234.0) == DailyReportMath.RankRow.grouped(1234), "rate >=100 grouped")
        check(DailyReportMath.RankRow.rateText(12.34) == "12.3", "rate >=10 one decimal")
        check(DailyReportMath.RankRow.rateText(5.0) == "5.00", "rate >=1 two decimals")
        check(DailyReportMath.RankRow.rateText(0.05) == "0.0500", "rate <1 keeps ~3 significant digits")

        // 完全一致的记录：偏差为 0，误差为 0。
        var uniform = DailyReportMath.RankRow.DropStats()
        for _ in 0..<6 {
            uniform.add(times: 10, count: 10)
        }

        check(DailyReportMath.RankRow.estimateRelativeError(uniform) == 0, "zero deviation gives zero error")

        // 记录间波动：times 全 10，counts [5,15,5,15,5,15] → dev=150，t(5)=2.571。
        var varied = DailyReportMath.RankRow.DropStats()
        for count in [5, 15, 5, 15, 5, 15] {
            varied.add(times: 10, count: count)
        }

        let variedError = DailyReportMath.RankRow.estimateRelativeError(varied)
        check(abs(variedError - 2.571 * (150 * 6.0 / 5.0).squareRoot() / 60) < 1e-9, "variance path matches hand computation")

        // 记录不足退回泊松近似：样本取掉落数与场次较小者。
        var sparse = DailyReportMath.RankRow.DropStats()
        sparse.add(times: 100, count: 100)
        sparse.add(times: 100, count: 0)
        check(abs(DailyReportMath.RankRow.estimateRelativeError(sparse) - 1.96 / 10) < 1e-9, "poisson fallback uses min(count, times)")

        // 可靠性阈值：掉落 9 个不足、10 个且误差小才可靠。
        var lowCount = DailyReportMath.RankRow.DropStats()
        for _ in 0..<6 {
            lowCount.add(times: 10, count: 1)
        }

        let lowRow = DailyReportMath.RankRow(stage: "1-7", stats: lowCount, sanity: 600)
        check(lowRow.count == 6 && !lowRow.isReliable, "count below 10 is unreliable")
        let uniformRow = DailyReportMath.RankRow(stage: "1-7", stats: uniform, sanity: 600)
        check(uniformRow.isReliable, "uniform samples reliable")
        check(abs(uniformRow.sanityPerItem - 10.0) < 1e-9, "sanity per item uses double division (600/60)")

        // 横条几何：基准行占满；误差 >=100%（泊松：样本 sqrt≤3.8）时上界钳到满长。
        var scaled = uniformRow
        scaled.setBarScale(baseline: uniformRow.sanityPerItem, scale: 1)
        check(abs(scaled.barLower - 1) < 1e-9 && abs(scaled.barUpper - 1) < 1e-9, "baseline row fills full bar")
        var tiny = DailyReportMath.RankRow.DropStats()
        tiny.add(times: 2, count: 2)
        let tinyRow = DailyReportMath.RankRow(stage: "x", stats: tiny, sanity: 4)
        check(tinyRow.relativeError >= 1, "two-round sample exceeds 100% error")
        var worst = tinyRow
        worst.setBarScale(baseline: 1, scale: 1)
        check(worst.barUpper <= 1 && worst.barLower >= 0.01, "infinite upper bound clamps to full bar")

        print("PASS: daily report \(checks) checks")
    }
}
