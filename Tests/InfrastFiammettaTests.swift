import Foundation

func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, "Fiammetta configuration regression", file: file, line: line)
}
let defaults = InfrastConfiguration.defaultFiammettaTargets
check(defaults == ["清流", "可露希尔", "但书"])
let samples: [([String]?, [String])] = [
    (nil, defaults), ([], []), (["", "  "], []), (["unknown", "Purestream"], []),
    (["清流"], ["清流"]), ([" 但书 ", "清流", "但书", ""], ["但书", "清流"]),
    (["巫恋", "龙舌兰", "歌蕾蒂娅", "清流"], ["巫恋", "龙舌兰", "歌蕾蒂娅"]),
    (["unknown", "可露希尔"], ["可露希尔"]),
]
var count = 0
for mode in [0, 10000, 20000] {
    for enabled in [nil, false, true] as [Bool?] {
        for (inputTargets, normalized) in samples {
            let old: [String: Any] = [
                "mode": mode, "facility": ["Dorm", "Mfg"], "drones": "Money", "threshold": 0.6, "replenish": true,
                "dorm_notstationed_enabled": true, "dorm_trust_enabled": true, "continue_training": false,
                "reception_message_board": false,
                "reception_clue_exchange": false, "reception_send_clue": true,
                "use_pinus_sylvestris": true, "use_perception_information": false,
                "use_worldly_plight": true, "use_abyssal_hunter": false,
                "filename": "plan.json", "plan_index": 3,
            ]
            var input = old
            if let enabled { input["fiammetta_recovery_enabled"] = enabled }
            if let inputTargets { input["fiammetta_targets"] = inputTargets }
            let config = try JSONDecoder().decode(
                InfrastConfiguration.self, from: JSONSerialization.data(withJSONObject: input))
            let effective = mode == 0 && (enabled ?? false) && !normalized.isEmpty
            check(config.fiammetta_targets == normalized)
            check(config.fiammetta_recovery_enabled == ((enabled ?? false) && !normalized.isEmpty))
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params)) as! NSDictionary
            var expected = old
            expected["fiammetta_recovery_enabled"] = effective
            expected["fiammetta_targets"] = effective ? normalized : []
            check(actual == expected as NSDictionary)
            check(
                try PropertyListDecoder().decode(InfrastConfiguration.self, from: PropertyListEncoder().encode(config))
                    == config)
            check(try JSONDecoder().decode(InfrastConfiguration.self, from: JSONEncoder().encode(config)) == config)
            count += 1
        }
    }
}
var config = InfrastConfiguration()
check(!config.fiammetta_recovery_enabled && config.fiammetta_targets == defaults)
config.fiammetta_recovery_enabled = true
for mode in [InfrastConfiguration.Mode.default, .custom, .rotation, .default] {
    config.mode = mode
    check(config.params.fiammetta_recovery_enabled == (mode == .default))
    check(config.params.fiammetta_targets == (mode == .default ? defaults : []))
    check(config.fiammetta_recovery_enabled && config.fiammetta_targets == defaults)
}
config.fiammetta_targets = []
check(!config.params.fiammetta_recovery_enabled && config.params.fiammetta_targets.isEmpty)
for mode in [0, 10000, 20000] {
    let old: [String: Any] = [
        "enable": true, "mode": mode, "facility": ["Dorm"], "drones": "_NotUse", "threshold": 0.3, "replenish": false,
        "dorm_notstationed_enabled": false, "dorm_trust_enabled": true, "filename": "plan.json", "plan_index": 1,
    ]
    let legacy = try JSONDecoder().decode(
        LegacyInfrastConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    let migrated = InfrastConfiguration(migrating: legacy)
    check(!migrated.fiammetta_recovery_enabled && migrated.fiammetta_targets == defaults)
    check(migrated.planSelection == .automatic)
    check(migrated.mode.rawValue == mode && migrated.facility == [.Dorm] && migrated.dorm_trust_enabled)
    // Legacy migration must not silently turn on grouping, mute clues, or
    // constrain the weekly schedule.
    check(migrated.reception_clue_exchange && migrated.reception_send_clue)
    check(!migrated.use_pinus_sylvestris && !migrated.use_perception_information)
    check(!migrated.use_worldly_plight && !migrated.use_abyssal_hunter && migrated.weeklyDays == nil)
}
// B07/B08/B13 defaults follow the Core and WPF consensus for absent keys:
// clue exchange/send stay on, all cross-facility groups stay off, no weekly
// restriction means every game-day weekday schedules the task.
let absentInput: [String: Any] = ["mode": 0, "facility": ["Mfg"], "drones": "_NotUse"]
let absentConfig = try JSONDecoder().decode(
    InfrastConfiguration.self, from: JSONSerialization.data(withJSONObject: absentInput))
check(absentConfig.reception_clue_exchange && absentConfig.reception_send_clue)
check(
    !absentConfig.use_pinus_sylvestris && !absentConfig.use_perception_information
        && !absentConfig.use_worldly_plight && !absentConfig.use_abyssal_hunter)
check(absentConfig.weeklyDays == nil && absentConfig.isScheduled(on: 0) && absentConfig.isScheduled(on: 6))
let absentParams =
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(absentConfig.params)) as! NSDictionary
check(absentParams.count == 19)
check(absentParams["reception_clue_exchange"] as! Bool && absentParams["reception_send_clue"] as! Bool)
check(absentParams["use_pinus_sylvestris"] as! Bool == false)
// B13 weekly gating mirrors F06: an explicit day list skips other weekdays,
// and the restriction survives persistence round trips.
var gated = absentConfig
gated.weeklyDays = [1]
check(gated.isScheduled(on: 1) && !gated.isScheduled(on: 2))
let gatedRoundtrip = try PropertyListDecoder().decode(
    InfrastConfiguration.self, from: PropertyListEncoder().encode(gated))
check(gatedRoundtrip == gated && gatedRoundtrip.weeklyDays == [1])
// §5-19（S5.2，双类型登记的 infrast 残余侧）：解码值域 0...6——手编脏值剔除
// （8/-1 丢弃）、合法端点 0/6 直通、空集语义保持。
let junkDays = try JSONDecoder().decode(
    InfrastConfiguration.self, from: JSONSerialization.data(withJSONObject: ["mode": 0, "facility": ["Mfg"], "drones": "_NotUse", "weeklyDays": [8, -1, 5]]))
check(junkDays.weeklyDays == [5])
let endpointDays = try JSONDecoder().decode(
    InfrastConfiguration.self, from: JSONSerialization.data(withJSONObject: ["mode": 0, "facility": ["Mfg"], "drones": "_NotUse", "weeklyDays": [0, 6]]))
check(endpointDays.weeklyDays == [0, 6])
let emptyDays = try JSONDecoder().decode(
    InfrastConfiguration.self, from: JSONSerialization.data(withJSONObject: ["mode": 0, "facility": ["Mfg"], "drones": "_NotUse", "weeklyDays": []]))
check(emptyDays.weeklyDays == [] && !emptyDays.isScheduled(on: 0) && !emptyDays.isScheduled(on: 6))
// B02: the WPF room domain extends the facility list with Recycle and
// AssistantChange, and both dispatch verbatim through the facility array.
var expanded = absentConfig
expanded.facility = [.Recycle, .AssistantChange]
let expandedParams = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expanded.params)) as! NSDictionary
check(expandedParams["facility"] as! [String] == ["Recycle", "AssistantChange"])
let expandedRoundtrip = try PropertyListDecoder().decode(
    InfrastConfiguration.self, from: PropertyListEncoder().encode(expanded))
check(expandedRoundtrip == expanded)

// B06: the candidate grid follows Core's SupportedFiammettaTargets exactly
// (12 names), while dispatch still caps at three targets.
check(InfrastConfiguration.FiammettaTarget.allCases.count == 12)
check(InfrastConfiguration.FiammettaTarget.allCases.map(\.rawValue).contains("琴柳"))
check(InfrastConfiguration.normalizedFiammettaTargets(["清流", "琴柳", "旅骨", "可露希尔"]).count == 3)

// B11 time rotation mirrors WPF RefreshCustomInfrastPlanList: endpoints are
// inclusive, unmatched instants fall back to the first plan, non-custom and
// period-free files keep the hand-picked index, and malformed or overnight
// windows (p0 > p1) never match — same as the upstream TimeOnly comparison.
func plan(_ periods: [[String]]...) -> MAAInfrast {
    MAAInfrast(
        title: nil, description: nil,
        plans: periods.map { InfrastConfigurationTestsPlan($0) })
}
func InfrastConfigurationTestsPlan(_ period: [[String]]) -> MAAInfrast.Plan {
    MAAInfrast.Plan(name: "P\(period.first?.first ?? "-")", description: nil, description_post: nil, period: period)
}
func at(_ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents()
    components.year = 2026; components.month = 11; components.day = 5
    components.hour = hour; components.minute = minute
    return Calendar.current.date(from: components)!
}
var rotation = InfrastConfiguration()
rotation.mode = .custom
check(rotation.resolvedPlanIndex(at: at(9, 0), plan: nil) == nil)
// 9:00 misses the only window; time rotation still engages and falls back
// to the first plan (upstream `??= FirstOrDefault()`), not the hand-picked index.
check(rotation.resolvedPlanIndex(at: at(9, 0), plan: plan([["10:00", "12:00"]])) == 0)
var noPeriod = rotation
noPeriod.filename = "plan.json"
check(noPeriod.resolvedPlanIndex(at: at(9, 0), plan: plan([])) == nil)
// [[]] carries one malformed window: rotation still engages (Count > 0, like
// upstream) but the unparseable window never matches, so the fallback applies.
check(noPeriod.resolvedPlanIndex(at: at(9, 0), plan: plan([[]])) == 0)
// Inclusive endpoints on both sides.
let twoWindows = plan([["10:00", "12:00"]], [["14:00", "16:00"]])
check(rotation.resolvedPlanIndex(at: at(10, 0), plan: twoWindows) == 0)
check(rotation.resolvedPlanIndex(at: at(12, 0), plan: twoWindows) == 0)
check(rotation.resolvedPlanIndex(at: at(12, 1), plan: twoWindows) == 0)
check(rotation.resolvedPlanIndex(at: at(14, 0), plan: twoWindows) == 1)
check(rotation.resolvedPlanIndex(at: at(16, 0), plan: twoWindows) == 1)
// One minute past the end misses the window and falls back to the first plan.
check(rotation.resolvedPlanIndex(at: at(16, 1), plan: twoWindows) == 0)
check(rotation.resolvedPlanIndex(at: at(9, 0), plan: twoWindows) == 0)
// Malformed windows are skipped entirely; overnight (p0 > p1) never matches.
let broken = plan([["bad", "times"]], [["14:00", "16:00"]])
check(rotation.resolvedPlanIndex(at: at(15, 0), plan: broken) == 1)
check(rotation.resolvedPlanIndex(at: at(9, 0), plan: broken) == 0)
check(rotation.resolvedPlanIndex(at: at(23, 0), plan: plan([["22:00", "02:00"]])) == 0)
// Non-custom modes never rotate, even with period-bearing plans.
var nonCustom = InfrastConfiguration()
nonCustom.mode = .default
check(nonCustom.resolvedPlanIndex(at: at(11, 0), plan: twoWindows) == nil)
if let sourcePath = CommandLine.arguments.dropFirst().first {
    let source = try String(contentsOfFile: sourcePath, encoding: .utf8)
    func coreNames(_ name: String) throws -> [String] {
        let declaration = try NSRegularExpression(pattern: "\(name) = \\{([^}]+)\\}")
        let match = declaration.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))!
        let body = String(source[Range(match.range(at: 1), in: source)!])
        return try NSRegularExpression(pattern: "\"([^\"]+)\"").matches(
            in: body, range: NSRange(body.startIndex..., in: body)
        ).map {
            String(body[Range($0.range(at: 1), in: body)!])
        }
    }
    check(try coreNames("SupportedFiammettaTargets") == InfrastConfiguration.FiammettaTarget.allCases.map(\.rawValue))
    check(try coreNames("DefaultFiammettaTargets") == defaults)
    print("PASS: allowed/default target lists match supplied Core source")
}
print(
    "PASS: \(count) mode/enablement/missing-empty-invalid target combinations; JSON/plist, mode restoration and actual legacy migration"
)

// P08.3: old profiles preserve automatic rotation; fixed selection survives
// storage and ignores every period, including mixed files and fallback gaps.
do {
    let legacy = try JSONDecoder().decode(InfrastConfiguration.self, from: Data("{}".utf8))
    check(legacy.planSelection == .automatic)
    let mixed = plan([], [["00:00", "23:59"]])
    check(mixed.hasPeriods && mixed.hasMixedPeriods)
    check(!twoWindows.hasMixedPeriods && !plan([]).hasPeriods && !plan([]).hasMixedPeriods)
    var selected = legacy
    selected.mode = .custom
    selected.plan_index = 1
    selected.planSelection = .fixed
    for date in [at(0, 0), at(9, 0), at(14, 0), at(23, 59)] {
        for file in [twoWindows, mixed, plan([]), broken] {
            check(selected.resolvedPlanIndex(at: date, plan: file) == nil)
            check(selected.params.plan_index == 1)
        }
    }
    for selection in InfrastConfiguration.PlanSelection.allCases {
        selected.planSelection = selection
        let json = try JSONEncoder().encode(selected)
        check(try JSONDecoder().decode(InfrastConfiguration.self, from: json) == selected)
        check(try PropertyListDecoder().decode(InfrastConfiguration.self,
              from: PropertyListEncoder().encode(selected)) == selected)
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected.params)) as! [String: Any]
        check(payload["planSelection"] == nil && payload["plan_index"] as? Int == 1)
    }
    selected.planSelection = .automatic
    check(selected.resolvedPlanIndex(at: at(15, 0), plan: twoWindows) == 1)
    check(selected.resolvedPlanIndex(at: at(9, 0), plan: twoWindows) == 0)
    check(selected.resolvedPlanIndex(at: at(9, 0), plan: mixed) == 1)
    print("PASS: P08.3 selection migration, JSON/plist, mixed periods, fixed/automatic matrix and Core field isolation")
}
