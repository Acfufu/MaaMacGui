//
//  StagePlanTests.swift
//  MAA
//
//  P06.1: 备选关卡（F05）—— resolvedStagePlan 的选关/跳过/截断语义，固定样本
//  （真实 StageActivityV2 裁剪）驱动，与可选目录同源判定（StageCatalog）。
//

import Foundation

// 单文件编译桩：真实实现见 MAATaskConfiguration.swift / MAATask.swift。
typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Fight
    var description: String { rawValue }
}

enum MAATask {
    case fight(FightConfiguration)
}

@main
struct StagePlanTests {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fatalError("usage: stage-plan-tests <StageActivitySample.json>")
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])

        let formatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date { formatter.date(from: value)! }

        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        guard let activities = StageActivityCache.loadActivities(from: fixtureURL),
            let official = activities["Official"]
        else {
            fatalError("fixture decode failed: \(fixtureURL.path)")
        }
        checks += 1

        // 构造走 {} 解码（与 App 内 init() 同路径），再赋值目标字段。
        func fight(_ stage: String, optional: Bool = false, alternatives: [String] = []) -> FightConfiguration {
            var config = try! JSONDecoder().decode(FightConfiguration.self, from: Data("{}".utf8))
            config.stage = stage
            config.useOptionalStage = optional
            config.optionalStages = alternatives
            return config
        }

        // 2026-11-04 为周三（游戏日 weekday 3，0=周日）。
        // 资源表：CE-6{2,4,6,0}/AP-5{1,4,6,0} 周三关闭；CA-5{2,3,5,0}/LS-6(常开)/SK-5{1,3,5,6} 周三开放。
        let wednesday = date("2026-11-04T12:00:00+08:00")
        // 2026-10-21 亦为周三，落在 YW 活动窗口内且在 fixture 资源全开放窗口
        // （09-29→10-19 UTC）之外——活动关与星期表语义可同时观察。
        let octoberWednesday = date("2026-10-21T12:00:00+08:00")
        let thursday = date("2026-10-15T12:00:00+08:00")  // 资源全开放窗口内，游戏日 weekday 4

        func catalog(_ version: String? = "v6.21.2") -> StageCatalog {
            StageCatalog(
                context: .init(channel: .Official, activities: official),
                appVersion: version)
        }

        func dispatch(_ resolution: FightConfiguration.StagePlanResolution) -> String? {
            if case .dispatch(let stage) = resolution.outcome { return stage }
            return nil
        }

        // MARK: 未启用备选——行为不变（存量档案零迁移保证）

        do {
            let r = fight("CE-6").resolvedStagePlan(at: wednesday, catalog: catalog())
            check(dispatch(r) == "CE-6", "optional disabled must dispatch stage as-is")
            check(r.truncatedAfter == nil, "optional disabled must not truncate")
        }
        do {
            // 目录外手输/特殊导航与空串（当前/上次）不受当日开放性影响
            check(dispatch(fight("JT8-2").resolvedStagePlan(at: wednesday, catalog: catalog())) == "JT8-2",
                  "unknown manual stage must pass through when optional disabled")
            check(dispatch(fight("").resolvedStagePlan(at: wednesday, catalog: catalog())) == "",
                  "current/last must pass through when optional disabled")
        }

        // MARK: 首个开放候选胜出

        do {
            // CE-6 周三关闭 → 回退到开放的 CA-5
            let r = fight("CE-6", optional: true, alternatives: ["CA-5", "AP-5"])
                .resolvedStagePlan(at: wednesday, catalog: catalog())
            check(dispatch(r) == "CA-5", "first open candidate must win (CE-6 closed on Wed)")
            check(r.truncatedAfter == nil, "periodic stage must not truncate")
        }
        do {
            // 首选已开放则不回退
            check(
                dispatch(fight("CA-5", optional: true, alternatives: ["AP-5"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog())) == "CA-5",
                "open primary must not fall through")
        }

        // MARK: 全部关闭 → 明确跳过

        do {
            // 周三 CE-6 与 AP-5 均关闭
            let r = fight("CE-6", optional: true, alternatives: ["AP-5"])
                .resolvedStagePlan(at: wednesday, catalog: catalog())
            check(r.outcome == .skipAllClosed, "all-closed candidates must skip the task")
        }
        do {
            // 启用备选但列表为空：首选今日关闭 → 跳过（启用即进入计划语义）
            check(
                fight("CE-6", optional: true).resolvedStagePlan(at: wednesday, catalog: catalog()).outcome
                    == .skipAllClosed,
                "optional enabled with closed primary and empty list must skip")
        }
        do {
            // 活动关卡跨窗口：AP-5 在活动期内周三关闭，YW-8 开放可作回退；
            // 活动结束后与 AP-5 一起全关。
            let inWindow = fight("AP-5", optional: true, alternatives: ["YW-8"])
            check(dispatch(inWindow.resolvedStagePlan(at: octoberWednesday, catalog: catalog())) == "YW-8",
                  "open activity stage must be reachable as alternative")
            check(
                inWindow.resolvedStagePlan(at: wednesday, catalog: catalog()).outcome == .skipAllClosed,
                "expired activity stage must not rescue all-closed plan")
        }

        // MARK: 目录外 fail-open 与过期活动形码（评审 A #2 收敛后口径）

        do {
            check(
                dispatch(fight("CE-6", optional: true, alternatives: ["JT8-2", "AP-5"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog())) == "JT8-2",
                "unknown candidate must fail open over closed known candidates")
        }
        do {
            // 目录外活动形码（如已轮换出 OTA 的 YW-8/ZZ-9）按过期活动判关，
            // 不得当作回退候选下发死关卡（upstream StageManager 默认态）
            check(
                fight("CE-6", optional: true, alternatives: ["ZZ-9"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).outcome == .skipAllClosed,
                "expired-activity-shaped external code must not rescue all-closed plan")
        }
        do {
            // SSReopen-*/AveMujica-8 等特殊名不匹配活动形，保持 fail-open
            check(
                dispatch(fight("CE-6", optional: true, alternatives: ["AveMujica-8"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog())) == "AveMujica-8",
                "special stage names stay fail-open (F19)")
        }

        // MARK: 归一化——候选先归一再匹配，下发归一结果

        do {
            check(
                dispatch(fight(" ap-5 ", optional: true, alternatives: ["ca-5"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog())) == "CA-5",
                "candidates must be normalized before matching and dispatch")
        }

        // MARK: 常驻截断（upstream PermanentStageBlocksStages）

        do {
            let r = fight("", optional: true, alternatives: ["LS-6"])
                .resolvedStagePlan(at: wednesday, catalog: catalog())
            check(dispatch(r) == "", "current/last is always open")
            check(r.truncatedAfter == "", "current/last must truncate later alternatives")
        }
        do {
            check(
                fight("Annihilation", optional: true, alternatives: ["LS-6"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).truncatedAfter == "Annihilation",
                "annihilation must truncate later alternatives")
        }
        do {
            check(
                fight("1-7", optional: true, alternatives: ["LS-6"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).truncatedAfter == "1-7",
                "permanent mainline must truncate later alternatives")
        }
        do {
            // 常驻候选位于末位：不截断
            let r = fight("CE-6", optional: true, alternatives: [""])
                .resolvedStagePlan(at: wednesday, catalog: catalog())
            check(dispatch(r) == "" && r.truncatedAfter == nil,
                  "current/last as last candidate must not warn")
        }
        do {
            // 今日开放但属星期表限定的资源关：非常驻，不截断
            check(
                fight("CA-5", optional: true, alternatives: ["LS-6"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).truncatedAfter == nil,
                "open resource stage is periodic, not permanent")
        }
        do {
            // 目录外未知码按上游口径视作常驻（无星期表、无活动窗口）
            check(
                fight("JT8-2", optional: true, alternatives: ["LS-6"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).truncatedAfter == "JT8-2",
                "unknown manual stage counts as permanent (upstream stage-DB口径)")
        }
        do {
            // LS-6 类常开资源关（无星期表）：上游 OpenDaysOfWeek 为空 → 常驻（评审 A #3）
            check(
                fight("LS-6", optional: true, alternatives: ["CE-6"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).truncatedAfter == "LS-6",
                "always-open resource stage must truncate later alternatives")
            check(FightStage.isAlwaysOpenResource("LS-6"), "LS-6 is always-open resource")
            check(!FightStage.isAlwaysOpenResource("CE-6"), "weekday-limited resource is not always-open")
        }
        do {
            // 重复常驻候选：首个之后的同值候选同样不可达
            check(
                fight("", optional: true, alternatives: ["", "LS-6"])
                    .resolvedStagePlan(at: wednesday, catalog: catalog()).truncatedAfter == "",
                "duplicate permanent candidates must truncate")
        }

        // MARK: isPermanentStage 判定面

        do {
            let c = catalog()
            check(FightConfiguration.isPermanentStage("", catalog: c, at: wednesday), "empty is permanent")
            check(FightConfiguration.isPermanentStage("Annihilation", catalog: c, at: wednesday), "annihilation is permanent")
            check(FightConfiguration.isPermanentStage("1-7", catalog: c, at: wednesday), "1-7 is permanent")
            check(FightConfiguration.isPermanentStage("JT8-2", catalog: c, at: wednesday), "unknown is permanent")
            check(FightConfiguration.isPermanentStage("LS-6", catalog: c, at: wednesday),
                  "always-open resource is permanent (upstream LS-6口径)")
            check(!FightConfiguration.isPermanentStage("CA-5", catalog: c, at: wednesday),
                  "resource stage is periodic even when open today")
            check(!FightConfiguration.isPermanentStage("YW-8", catalog: c, at: thursday),
                  "activity stage is never permanent")
        }

        // MARK: 过期活动形码判定面

        do {
            check(FightConfiguration.isExpiredActivityShape("YW-8"), "activity shape matches")
            check(FightConfiguration.isExpiredActivityShape("AT-10"), "two-digit activity shape matches")
            check(!FightConfiguration.isExpiredActivityShape("1-7"), "mainline is not activity shape")
            check(!FightConfiguration.isExpiredActivityShape("JT8-2"), "three-char prefix is not activity shape")
            check(!FightConfiguration.isExpiredActivityShape("AveMujica-8"), "special name is not activity shape")
            check(!FightConfiguration.isExpiredActivityShape(""), "empty is not activity shape")
        }

        // MARK: 版本门槛滤除的备选面（P05.1 MinimumRequired 语义延伸）

        do {
            // 低于门槛的活动组不入目录 → YW-8 变目录外活动形码 → 按过期活动
            // 判关（评审 A #2：不得把死关卡当作回退候选下发）
            let legacy = StageCatalog(
                context: .init(channel: .Official, activities: official), appVersion: "v6.16.0")
            let plan = fight("AP-5", optional: true, alternatives: ["YW-8"])
            check(plan.resolvedStagePlan(at: octoberWednesday, catalog: legacy).outcome == .skipAllClosed,
                  "below-minimum activity stage must be judged closed, not dispatched")
            // 同一形码在常驻判定上不视作常驻（过期活动非常驻，upstream Activity != null）
            check(!FightConfiguration.isPermanentStage("YW-8", catalog: legacy, at: octoberWednesday),
                  "below-minimum activity shape is not permanent")
        }

        // MARK: F06 每周执行日——门控判定与游戏日星期口径

        do {
            // nil=不启用=每天执行（存量档案缺键语义）
            let unscheduled = fight("CE-6")
            for day in 0...6 {
                check(unscheduled.isScheduled(on: day), "nil weeklyDays must run every day (\(day))")
            }
        }
        do {
            // 启用后仅勾选星期执行；空数组=每周全跳（上游 WeeklySchedule 全 false 等价）
            var config = fight("CE-6")
            config.weeklyDays = [3]
            check(config.isScheduled(on: 3), "selected weekday must run")
            check(!config.isScheduled(on: 4), "unselected weekday must skip")
            config.weeklyDays = []
            for day in 0...6 {
                check(!config.isScheduled(on: day), "empty weeklyDays must skip every day (\(day))")
            }
        }
        do {
            // 游戏日边界：04:00 重置前仍属前一游戏日（Official=UTC+8）
            let calendar = MAAClientChannel.Official.calendar
            check(calendar.weekday(for: date("2026-11-05T03:59:00+08:00")) == 3,
                  "before 04:00 reset must still count as previous game day (Wed)")
            check(calendar.weekday(for: date("2026-11-05T04:01:00+08:00")) == 4,
                  "after 04:00 reset must enter new game day (Thu)")
            // 同一时刻不同区服游戏日：EN（UTC-7）比 Official（UTC+8）早一天
            let enCalendar = MAAClientChannel.YoStarEN.calendar
            let instant = date("2026-11-04T12:00:00+08:00")
            check(calendar.weekday(for: instant) == 3, "Official game day must be Wednesday")
            check(enCalendar.weekday(for: instant) == 2, "EN game day must be Tuesday at the same instant")
        }

        // MARK: F20 关卡重置策略——目录外活动形的重置面

        do {
            // .current + 目录外活动形 → 重置（返回原码供日志）；大小写先归一
            var config = fight("ZX-3")
            config.stageResetMode = .current
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == "ZX-3",
                  "out-of-catalog activity shape must reset under .current")
            config.stage = "zx-3"
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == "ZX-3",
                  "reset must judge the normalized stage code")
        }
        do {
            // .ignore（缺省）保留原值——Mac 历史行为
            check(fight("ZX-3").resetStageForDispatch(at: wednesday, catalog: catalog()) == nil,
                  "legacy default .ignore must keep the stored stage")
        }
        do {
            // 目录内今日关闭（YW 窗口 10-22 已过，关卡仍在目录）不重置——关闭面
            // 由备选解析/跳过处理，重置只面向已轮换出目录的关卡
            var config = fight("YW-8")
            config.stageResetMode = .current
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == nil,
                  "in-catalog closed activity stage must not reset")
        }
        do {
            // 主线/特殊名/当前上次不触发（非活动形）
            var config = fight("1-7")
            config.stageResetMode = .current
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == nil,
                  "mainline must not reset")
            config.stage = "JT8-2"
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == nil,
                  "special stage name must not reset")
            config.stage = ""
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == nil,
                  "current/last must not reset")
        }
        do {
            // 启用备选时由 resolvedStagePlan 接管，重置不生效（休眠备选数据不改写）
            var config = fight("ZX-3", optional: true, alternatives: ["CA-5"])
            config.stageResetMode = .current
            check(config.resetStageForDispatch(at: wednesday, catalog: catalog()) == nil,
                  "optional plan must own stage resolution instead of reset")
        }

        // MARK: 持久化——旧档案缺键解码缺省，新字段 plist 往返一致

        do {
            let legacy = try! JSONDecoder().decode(FightConfiguration.self, from: Data("{}".utf8))
            check(!legacy.useOptionalStage, "legacy profile must default optional off")
            check(legacy.optionalStages.isEmpty, "legacy profile must default empty alternatives")
            check(legacy.weeklyDays == nil, "legacy profile must default weekly schedule off")
            check(legacy.stageResetMode == .ignore, "legacy profile must default stage reset to keep")
        }
        do {
            var full = fight("CE-6", optional: true, alternatives: ["CA-5", ""])
            full.weeklyDays = [1, 3, 5]
            full.stageResetMode = .current
            let data = try! PropertyListEncoder().encode(full)
            let back = try! PropertyListDecoder().decode(FightConfiguration.self, from: data)
            check(back == full, "weekly schedule and reset mode must round-trip through plist")
            check(back.weeklyDays == [1, 3, 5], "weekly days must survive plist round-trip")
        }

        print("stage-plan-tests: \(checks) checks passed")
    }
}
