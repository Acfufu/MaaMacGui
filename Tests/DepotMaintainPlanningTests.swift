//
//  DepotMaintainPlanningTests.swift
//  MAA
//
//  P12.1: 库存保持规划核心（DepotMaintainPlanner）——预检结论/排序稳定序/
//  双芯片折算/下发参数契约/任务级跳过，语义对齐 upstream
//  DepotMaintainTaskUserControlModel.SerializeTask（dev-v2 d75bf9a）。
//

import Foundation

// 单文件编译桩：真实实现见 MAATaskConfiguration.swift / MAATask.swift。
typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Fight, Depot, DepotMaintain
    var description: String { rawValue }
}

enum MAATask {
    case fight(FightConfiguration)
    case depotMaintain(DepotMaintainConfiguration)
}

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}

let formatter = ISO8601DateFormatter()
func date(_ value: String) -> Date { formatter.date(from: value)! }

func config(_ plans: [DepotMaintainPlan],
            updateDepot: Bool = true,
            skipDuringActivity: Bool = false,
            skipDuringResourceCollection: Bool = false,
            onlyFirstInsufficientPlan: Bool = false,
            sortByProgress: Bool = false,
            countDualChipAsChipPack: Bool = false,
            useAutoSeries: Bool = false,
            useMedicine: Bool = true,
            useStone: Bool = true,
            useExpiringMedicine: Bool = false) -> DepotMaintainConfiguration {
    var c = try! JSONDecoder().decode(DepotMaintainConfiguration.self, from: Data("{}".utf8))
    c.plans = plans
    c.updateDepot = updateDepot
    c.skipDuringActivity = skipDuringActivity
    c.skipDuringResourceCollection = skipDuringResourceCollection
    c.onlyFirstInsufficientPlan = onlyFirstInsufficientPlan
    c.sortByProgress = sortByProgress
    c.countDualChipAsChipPack = countDualChipAsChipPack
    c.useAutoSeries = useAutoSeries
    c.useMedicine = useMedicine
    c.useStone = useStone
    c.useExpiringMedicine = useExpiringMedicine
    return c
}

func plan(stage: String = "", dropID: String = "", dropCount: Int = 0,
          useMedicine: Bool = false, medicineCount: Int = 0,
          useStone: Bool = false, stoneCount: Int = 0) -> DepotMaintainPlan {
    .init(stage: stage, dropID: dropID, dropCount: dropCount,
          useMedicine: useMedicine, medicineCount: medicineCount,
          useStone: useStone, stoneCount: stoneCount)
}

// 与 item_index.json 实测一致的配方样本（双芯片含芯片助剂 32001 + 对应芯片组×2）。
let formulas: [String: [String: Int]] = [
    "3223": ["32001": 1, "3222": 2],   // 近卫双芯片：2× 近卫芯片组
    "30012": ["30011": 3],             // 固源岩（非双芯片，普通合成配方）
]

// MARK: - 缺省与 Codable

do {
    let c = try JSONDecoder().decode(DepotMaintainConfiguration.self, from: Data("{}".utf8))
    check(c.updateDepot && c.useMedicine && c.useStone, "WPF defaults: updateDepot/useMedicine/useStone on")
    check(!c.isStageManually && !c.skipDuringActivity && !c.skipDuringResourceCollection &&
          !c.onlyFirstInsufficientPlan && !c.sortByProgress && !c.countDualChipAsChipPack &&
          !c.useAutoSeries && !c.useExpiringMedicine, "WPF defaults: strategy switches off")
    check(c.plans.isEmpty && c.server == "CN" && c.penguin_id.isEmpty, "WPF defaults: empty plans, CN server")
    check(DepotMaintainConfiguration.expiringMedicineDays == 2, "expiring medicine threshold fixed at 2 days")

    var c2 = c
    c2.plans = [plan(stage: "1-7", dropID: "30012", dropCount: 100, useMedicine: true, medicineCount: 5)]
    c2.onlyFirstInsufficientPlan = true
    c2.penguin_id = "pid"
    let data = try JSONEncoder().encode(c2)
    let back = try JSONDecoder().decode(DepotMaintainConfiguration.self, from: data)
    check(back == c2, "non-default config round-trips")

    let partial = try JSONDecoder().decode([DepotMaintainPlan].self, from: Data(#"[{"stage":"1-7"}]"#.utf8))
    check(partial[0].dropID.isEmpty && partial[0].dropCount == 0 && !partial[0].useMedicine,
          "plan missing keys decode as WPF plan defaults")
}

// MARK: - 预检结论（顺序对齐 upstream：材料 → 目标 → 已达标 → 关卡）

do {
    let target = plan(stage: "1-7", dropID: "30012", dropCount: 100)
    var c = config([target])

    var outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["30012": 150])
    check(outcomes == [.init(index: 0, plan: target, outcome: .enough(current: 150))],
          "inventory above target: enough with current")

    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["30012": 30])
    check(outcomes == [.init(index: 0, plan: target, outcome: .dispatched(need: 70, current: 30))],
          "insufficient inventory dispatches exact gap")

    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: [:])
    check(outcomes[0].outcome == .dispatched(need: 100, current: 0),
          "precheck with no depot data counts 0 (corrected later by recompute)")

    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["30012": -5])
    check(outcomes[0].outcome == .dispatched(need: 100, current: 0), "negative inventory clamps to 0")

    c = config([plan(stage: "1-7", dropID: "", dropCount: 100)])
    check(DepotMaintainPlanner.evaluate(config: c, inventory: [:]).map(\.outcome) == [.invalidDrop],
          "empty drop id is invalid before other checks")

    c = config([plan(stage: "1-7", dropID: "30012", dropCount: 0)])
    check(DepotMaintainPlanner.evaluate(config: c, inventory: [:]).map(\.outcome) == [.zeroDropCount],
          "zero target is skipped")

    c = config([plan(stage: "", dropID: "30012", dropCount: 100)])
    check(DepotMaintainPlanner.evaluate(config: c, inventory: [:]).map(\.outcome) == [.noStage],
          "empty stage with insufficient inventory: noStage")

    c = config([plan(stage: "AP-5", dropID: "30012", dropCount: 100)])
    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: [:], isStageOpen: { _ in false })
    check(outcomes.map(\.outcome) == [.stageClosed], "closed stage with insufficient inventory: stageClosed")

    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["30012": 100], isStageOpen: { _ in false })
    check(outcomes.map(\.outcome) == [.enough(current: 100)],
          "enough precedes stage-open check (upstream order)")
}

// MARK: - 多计划顺序与 OnlyFirstInsufficientPlan

do {
    let enough = plan(stage: "1-7", dropID: "30011", dropCount: 10)
    let lacking = plan(stage: "AP-5", dropID: "30012", dropCount: 100)
    let closed = plan(stage: "CA-5", dropID: "3303", dropCount: 50)
    let c = config([enough, lacking, closed])
    let inventory = ["30011": 20]

    let outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: inventory,
                                                 isStageOpen: { $0 != "CA-5" })
    check(outcomes.map(\.index) == [0, 1, 2] && outcomes.count == 3, "all plans evaluated in list order")
    check(outcomes[0].outcome == .enough(current: 20), "first plan enough")
    check(outcomes[1].outcome == .dispatched(need: 100, current: 0), "second plan dispatched")
    check(outcomes[2].outcome == .stageClosed, "third plan stage closed")

    let firstOnly = DepotMaintainPlanner.evaluate(
        config: config([enough, lacking, closed], onlyFirstInsufficientPlan: true), inventory: inventory)
    check(firstOnly.map(\.index) == [0, 1] &&
          firstOnly[1].outcome == .dispatched(need: 100, current: 0),
          "only-first-insufficient stops after first dispatch; enough plans still evaluated")
}

// MARK: - SortByProgress（达成率升序、稳定、无效置末尾）

do {
    let a = plan(stage: "1-7", dropID: "30011", dropCount: 100)   // 50/100 = 0.5
    let b = plan(stage: "AP-5", dropID: "30012", dropCount: 100)  // 20/100 = 0.2
    let e = plan(stage: "CA-5", dropID: "3303", dropCount: 100)   // 80/100 = 0.8
    let inventory = ["30011": 50, "30012": 20, "3303": 80]

    var c = config([a, b, e], sortByProgress: true)
    var outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: inventory)
    check(outcomes.map(\.index) == [1, 0, 2], "ascending progress reorders dispatch only")
    check(outcomes.map(\.plan) == [b, a, e], "evaluations carry their original plans")

    c = config([b, a, e], sortByProgress: false)
    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: inventory)
    check(outcomes.map(\.index) == [0, 1, 2], "flag off keeps list order")

    let tie1 = plan(stage: "1-7", dropID: "30011", dropCount: 100)
    let tie2 = plan(stage: "AP-5", dropID: "30012", dropCount: 100)
    outcomes = DepotMaintainPlanner.evaluate(
        config: config([tie1, tie2], sortByProgress: true), inventory: ["30011": 50, "30012": 50])
    check(outcomes.map(\.index) == [0, 1], "equal progress keeps list order (stable sort)")

    let invalid = plan(stage: "1-7", dropID: "", dropCount: 100)
    outcomes = DepotMaintainPlanner.evaluate(
        config: config([invalid, tie2], sortByProgress: true), inventory: ["30012": 50])
    check(outcomes.map(\.outcome) == [.dispatched(need: 50, current: 50), .invalidDrop],
          "invalid plan sorts last but is still evaluated")

    outcomes = DepotMaintainPlanner.evaluate(
        config: config([tie2], sortByProgress: true), inventory: ["30012": 50])
    check(outcomes.map(\.index) == [0], "single plan never reordered (upstream count > 1)")

    outcomes = DepotMaintainPlanner.evaluate(
        config: config([a, b, e], onlyFirstInsufficientPlan: true, sortByProgress: true),
        inventory: inventory)
    check(outcomes.map(\.index) == [1], "sorted order then break at first insufficient")
}

// MARK: - 双芯片折算（I10）

do {
    let chip = plan(stage: "PR-D-2", dropID: "3222", dropCount: 100)  // 近卫芯片组

    check(DepotMaintainPlanner.dualChipConversion(for: "3222", inventory: ["3223": 5], formulas: formulas) == 10,
          "each dual chip converts to 2 chip packs via formula")
    check(DepotMaintainPlanner.dualChipConversion(for: "3222", inventory: ["3223": 5], formulas: [:]) == 0,
          "no formula data: no conversion")
    check(DepotMaintainPlanner.dualChipConversion(for: "30011", inventory: ["30012": 9], formulas: formulas) == 0,
          "ordinary crafting recipes are not dual-chip sources")
    check(DepotMaintainPlanner.isDualChip(formula: formulas["3223"]) &&
          !DepotMaintainPlanner.isDualChip(formula: formulas["30012"]),
          "dual chip identified by chip-assistant 32001 in formula")

    var c = config([chip], countDualChipAsChipPack: true)
    var outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["3222": 90, "3223": 5], formulas: formulas)
    check(outcomes[0].outcome == .enough(current: 100), "conversion adds to raw count for threshold")

    c = config([chip])
    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["3222": 30, "3223": 5], formulas: formulas)
    check(outcomes[0].outcome == .dispatched(need: 70, current: 30), "conversion off uses raw count only")

    c = config([chip], countDualChipAsChipPack: true)
    outcomes = DepotMaintainPlanner.evaluate(config: c, inventory: ["3223": 5], formulas: formulas)
    check(outcomes[0].outcome == .dispatched(need: 90, current: 10), "conversion-only inventory counts toward gap")

    check(DepotMaintainPlanner.progress(of: chip, inventory: ["3223": 5], formulas: formulas, chipConversion: true) == 0.1,
          "progress uses converted count")
    check(DepotMaintainPlanner.progress(of: plan(dropID: ""), inventory: [:], formulas: [:], chipConversion: false) == nil,
          "invalid plan has no progress (sorts last)")
}

// MARK: - 下发参数契约（upstream AsstFightTask 同构）

do {
    var c = config([plan(stage: " ap-5 ", dropID: "30012", dropCount: 70,
                         useMedicine: true, medicineCount: 5, useStone: true, stoneCount: 1)],
                   useAutoSeries: true, useExpiringMedicine: true)
    c.report_to_penguin = true
    c.penguin_id = "p-id"
    c.report_to_yituliu = true
    c.yituliu_id = "y-id"
    c.server = "YoStarEN"
    c.client_type = "en"

    guard case .dispatched(let need, _) = DepotMaintainPlanner.evaluate(config: c, inventory: [:])[0].outcome else {
        preconditionFailure("expected dispatch")
    }
    let fight = DepotMaintainPlanner.dispatchFight(for: c.plans[0], config: c, need: need)
    check(fight.stage == "AP-5" && fight.drops == ["30012": 70], "normalized stage and exact drop gap")
    check(fight.times == Int(Int32.max), "unlimited times until drops reached (upstream int.MaxValue)")
    check(fight.medicine == 5 && fight.stone == 1, "per-plan budget honored when global switches on")
    check(fight.medicine_expire_days == 2, "expiring window fixed 2 days when enabled")
    check(fight.series == 0, "AUTO series when enabled")
    check(fight.report_to_penguin && fight.penguin_id == "p-id" &&
          fight.report_to_yituliu && fight.yituliu_id == "y-id" &&
          fight.server == "YoStarEN" && fight.client_type == "en" && !fight.DrGrandet,
          "task-level report/server fields pass through")

    c = config([c.plans[0]], useMedicine: false, useStone: false)
    let gated = DepotMaintainPlanner.dispatchFight(for: c.plans[0], config: c, need: 70)
    check(gated.medicine == 0 && gated.stone == 0, "global switches gate per-plan budgets to 0")

    c = config([c.plans[0]])
    let plain = DepotMaintainPlanner.dispatchFight(for: c.plans[0], config: c, need: 70)
    check(plain.medicine_expire_days == 0 && plain.series == 1, "defaults: no expiring window, single series")

    // Core 编码面：drops/times/series/medicine_expire_days 与上报字段真实下发。
    let json = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(plain.params)) as! [String: Any]
    check(json["stage"] as? String == "AP-5", "params encode normalized stage")
    check((json["drops"] as? [String: Int]) == ["30012": 70], "params encode drops map")
    check(json["times"] as? Int == Int(Int32.max), "params encode unlimited times")
    check(json["series"] as? Int == 1 && json["medicine_expire_days"] as? Int == 0,
          "params encode series and expiring window")
    check(json["medicine"] as? Int == 5 && json["stone"] as? Int == 1, "params encode plan budgets explicitly")
    let gatedJson = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(gated.params)) as! [String: Any]
    check(gatedJson["medicine"] as? Int == 0 && gatedJson["stone"] as? Int == 0,
          "gated budgets encoded as explicit zeros (upstream Medicine=0)")
    check(json["report_to_penguin"] as? Bool == false && json["report_to_yituliu"] as? Bool == false,
          "params encode report switches")
    check(json["inventoryTarget"] == nil, "composite state never reaches Core params")
}

// MARK: - 任务级跳过（fixture 活动窗口）

do {
    guard CommandLine.arguments.count > 1 else {
        fatalError("usage: depot-maintain-planning-tests <StageActivitySample.json>")
    }
    let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let activities = StageActivityCache.loadActivities(from: fixtureURL),
        let official = activities["Official"]
    else {
        fatalError("fixture decode failed: \(fixtureURL.path)")
    }
    checks += 1

    // YW 窗口 2026-10-09 12:00 → 10-23 03:59:59（+8）；资源全开放 09-29 16:00 → 10-20 03:59:59。
    let activityOnly = date("2026-10-21T12:00:00+08:00")
    let resourceOnly = date("2026-10-01T12:00:00+08:00")
    let both = date("2026-10-15T12:00:00+08:00")
    let neither = date("2026-11-04T12:00:00+08:00")

    var c = config([], skipDuringActivity: true, skipDuringResourceCollection: true)
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: both, activities: official) == .activityOpen,
          "activity skip takes precedence (upstream check order)")
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: activityOnly, activities: official) == .activityOpen,
          "activity window active: skip")
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: resourceOnly, activities: official) == .resourceCollectionOpen,
          "resource all-open window active: skip")
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: neither, activities: official) == nil,
          "outside both windows: run (always-open LS-6 does not count)")

    c = config([], skipDuringActivity: true)
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: resourceOnly, activities: official) == nil,
          "activity flag alone ignores resource window")
    c = config([], skipDuringResourceCollection: true)
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: activityOnly, activities: official) == nil,
          "resource flag alone ignores activity window")
    c = config([])
    check(DepotMaintainPlanner.taskLevelSkip(config: c, at: both, activities: official) == nil,
          "flags off never skip")
}

print("depot-maintain-planning: \(checks) checks passed")
