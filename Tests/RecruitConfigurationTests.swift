import Foundation

func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, "Recruit configuration regression", file: file, line: line)
}

func decode(_ value: [String: Any]) throws -> RecruitConfiguration {
    try JSONDecoder().decode(RecruitConfiguration.self, from: JSONSerialization.data(withJSONObject: value))
}

func params(_ config: RecruitConfiguration) throws -> NSDictionary {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params)) as! NSDictionary
}

let robot = "支援机械"
let dps = "输出"
let healing = "治疗"
let defaults = RecruitConfiguration()
check(defaults.first_tags.isEmpty && !defaults.first_tags_enabled)
check(defaults.preserve_tags == [robot] && defaults.preserve_tags_enabled)
// R05/R06 defaults follow Core and WPF: force_refresh on, permit reserve off
// (the stored count of 8 only dispatches once explicitly enabled).
check(defaults.force_refresh)
check(!defaults.level3_recruitment_permit_reserve_enabled && defaults.level3_recruitment_permit_reserve == 8)
var count = 0
for oldFlag in [nil, false, true] as [Bool?] {
    for explicitTags in [nil, [], [healing, "", " \(dps) ", healing]] as [[String]?] {
        for firstEnabled in [nil, false, true] as [Bool?] {
            for preserveEnabled in [nil, false, true] as [Bool?] {
                var input: [String: Any] = ["first_tags": ["", " \(dps) ", healing, dps]]
                if let oldFlag { input["skip_robot"] = oldFlag }
                if let explicitTags { input["preserve_tags"] = explicitTags }
                if let firstEnabled { input["first_tags_enabled"] = firstEnabled }
                if let preserveEnabled { input["preserve_tags_enabled"] = preserveEnabled }
                let config = try decode(input)
                let expectedPreserve =
                    explicitTags.map(RecruitConfiguration.normalizedTags) ?? ((oldFlag ?? true) ? [robot] : [])
                check(config.first_tags == [dps, healing])
                check(config.first_tags_enabled == (firstEnabled ?? true))
                check(config.preserve_tags == expectedPreserve)
                check(config.preserve_tags_enabled == (preserveEnabled ?? !expectedPreserve.isEmpty))
                let actual = try params(config)
                check(actual["first_tags"] as! [String] == (config.first_tags_enabled ? [dps, healing] : []))
                check(actual["preserve_tags"] as! [String] == (config.preserve_tags_enabled ? expectedPreserve : []))
                check(
                    actual["first_tags_enabled"] == nil && actual["preserve_tags_enabled"] == nil
                        && actual["skip_robot"] == nil)
                check(actual.count == 18)
                check(actual["select"] as! [Int] == [4, 5])
                check(actual["confirm"] as! [Int] == [3, 4, 5])
                check(actual["times"] as! Int == 4 && actual["expedite"] as! Bool == false)
                check(actual["force_refresh"] as! Bool == true)
                check(actual["level3_recruitment_permit_reserve"] as! Int == 0)
                check(try JSONDecoder().decode(RecruitConfiguration.self, from: JSONEncoder().encode(config)) == config)
                check(
                    try PropertyListDecoder().decode(
                        RecruitConfiguration.self, from: PropertyListEncoder().encode(config)) == config)
                count += 1
            }
        }
    }
}

// Disabled selections persist without participating in effective parameters.
var config = defaults
config.first_tags = [dps, dps, "", " \(healing) "]
config.preserve_tags = [healing, dps, healing]
config.first_tags_enabled = false
config.preserve_tags_enabled = false
let disabled = try PropertyListDecoder().decode(RecruitConfiguration.self, from: PropertyListEncoder().encode(config))
check(disabled.first_tags == [dps, healing] && disabled.preserve_tags == [healing, dps])
check(try params(disabled)["preserve_tags"] as! [String] == [])
config.first_tags_enabled = true
config.preserve_tags_enabled = true
check(try params(config)["first_tags"] as! [String] == [dps, healing])
check(try params(config)["preserve_tags"] as! [String] == [healing, dps])

// The permit reserve dispatches only when enabled, mirroring the WPF
// Enabled ? count : 0 derivation against level3_recruitment_permit_reserve.
var reserveConfig = defaults
reserveConfig.level3_recruitment_permit_reserve_enabled = true
check(try params(reserveConfig)["level3_recruitment_permit_reserve"] as! Int == 8)
reserveConfig.level3_recruitment_permit_reserve = 3
check(try params(reserveConfig)["level3_recruitment_permit_reserve"] as! Int == 3)
reserveConfig.level3_recruitment_permit_reserve_enabled = false
check(try params(reserveConfig)["level3_recruitment_permit_reserve"] as! Int == 0)
var forceOff = defaults
forceOff.force_refresh = false
check(try params(forceOff)["force_refresh"] as! Bool == false)
// Non-default dispatch-relevant values must survive persistence round trips.
reserveConfig.level3_recruitment_permit_reserve_enabled = true
reserveConfig.level3_recruitment_permit_reserve = 3
forceOff.refresh = true
let reserveRoundtrip = try PropertyListDecoder().decode(
    RecruitConfiguration.self, from: PropertyListEncoder().encode(reserveConfig))
check(
    reserveRoundtrip.level3_recruitment_permit_reserve_enabled
        && reserveRoundtrip.level3_recruitment_permit_reserve == 3)
let forceRoundtrip = try PropertyListDecoder().decode(
    RecruitConfiguration.self, from: PropertyListEncoder().encode(forceOff))
check(!forceRoundtrip.force_refresh && forceRoundtrip.refresh)

// Dispatch clamps per-level minutes into Core's [60, 540]; the stored
// dictionary keeps legacy out-of-range values untouched for round-trips.
var legacyTimes = defaults
legacyTimes.recruitment_time = ["3": 30, "4": 600, "5": 460, "6": 540]
let dispatchedTimes = try params(legacyTimes)["recruitment_time"] as! [String: Int]
check(dispatchedTimes == ["3": 60, "4": 540, "5": 460, "6": 540])
check(legacyTimes.recruitment_time == ["3": 30, "4": 600, "5": 460, "6": 540])
for edge in [59, 0, -60] {
    check(RecruitConfiguration.clampedRecruitmentTime(edge) == 60)
}
check(RecruitConfiguration.clampedRecruitmentTime(60) == 60 && RecruitConfiguration.clampedRecruitmentTime(540) == 540)
check(RecruitConfiguration.clampedRecruitmentTime(541) == 540 && RecruitConfiguration.clampedRecruitmentTime(960) == 540)
let clampedRoundtrip = try PropertyListDecoder().decode(
    RecruitConfiguration.self, from: PropertyListEncoder().encode(legacyTimes))
check(clampedRoundtrip.recruitment_time == legacyTimes.recruitment_time)

for skipRobot in [false, true] {
    let old: [String: Any] = [
        "enable": true, "refresh": true, "select": [4, 5, 6], "confirm": [3], "times": 1, "set_time": false,
        "expedite": false, "skip_robot": skipRobot, "recruitment_time": ["3": 460],
    ]
    let legacy = try JSONDecoder().decode(
        LegacyRecruitConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
    let migrated = RecruitConfiguration(migrating: legacy)
    check(migrated.preserve_tags == (skipRobot ? [robot] : []))
    check(migrated.preserve_tags_enabled == skipRobot)
    check(migrated.refresh && migrated.select == [4, 5, 6] && migrated.confirm == [3])
    check(migrated.times == 1 && !migrated.set_time && !migrated.expedite && migrated.recruitment_time == ["3": 460])
    // Migration must not loosen the high-rarity confirmation guard or enable
    // permit reservation behind the user's back.
    check(migrated.force_refresh && !migrated.level3_recruitment_permit_reserve_enabled)
    check(!migrated.confirm.contains(6))
}
let recognition = RecruitConfiguration.recognition
check(recognition.select == [4, 5, 6] && recognition.confirm == [-1])
check(recognition.times == 0 && !recognition.refresh && !recognition.expedite && recognition.expedite_times == 0)
check(recognition.preserve_tags == [robot] && recognition.preserve_tags_enabled)
// Recognition mirrors the WPF toolbox assembly: force_refresh off, reserve
// disabled, and the full 18-key parameter set still dispatches.
check(!recognition.force_refresh && !recognition.level3_recruitment_permit_reserve_enabled)
let recognitionActual = try params(recognition)
check(recognitionActual.count == 18)
check(recognitionActual["force_refresh"] as! Bool == false)
check(recognitionActual["level3_recruitment_permit_reserve"] as! Int == 0)

// Both parameter paths (daily tasks and recognition) map first_tags through the
// effective tag names, while preserve_tags always stay canonical IDs.
var recognitionPreferred = recognition
recognitionPreferred.first_tags = [dps]
recognitionPreferred.first_tags_enabled = true
let recognitionParams = recognitionPreferred.params(tagNames: [dps: "DPS"])
check(recognitionParams.first_tags == ["DPS"])
check(recognitionParams.preserve_tags == [robot])
check(recognition.params(tagNames: [dps: "DPS"]).first_tags == [])

// Resource-derived translated labels never become stored protocol IDs.
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(
    at: temporary.appendingPathComponent("global/YoStarEN/resource"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
try JSONSerialization.data(withJSONObject: ["tags": [robot: robot, healing: healing]]).write(
    to: temporary.appendingPathComponent("recruitment.json"))
try JSONSerialization.data(withJSONObject: ["tags": [robot: "Robot", "unrecognized": "Ignored"]]).write(
    to: temporary.appendingPathComponent("global/YoStarEN/resource/recruitment.json"))
let english = RecruitTagCatalog.load(resourceDirectory: temporary, languageCode: "en")
check(english.tags == [robot, healing].sorted())
check(english.label(for: robot) == "Robot" && english.label(for: healing) == healing)
check(english.label(for: "future-tag") == "future-tag")
check(RecruitTagCatalog.load(resourceDirectory: nil, languageCode: "en").tags.isEmpty)
check(RecruitTagCatalog.load(resourceDirectory: temporary, languageCode: "ko").label(for: robot) == robot)
check(try params(recognition)["preserve_tags"] as! [String] == [robot])

// The catalog follows the effective resource directory instead of the bundle,
// so tags introduced by user/OTA resources stay selectable.
let newTag = "新手"
let bundledDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let updatedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer {
    try? FileManager.default.removeItem(at: bundledDirectory)
    try? FileManager.default.removeItem(at: updatedDirectory)
}
for directory in [bundledDirectory, updatedDirectory] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
try JSONSerialization.data(withJSONObject: ["tags": [robot: robot]]).write(
    to: bundledDirectory.appendingPathComponent("recruitment.json"))
try JSONSerialization.data(withJSONObject: ["tags": [robot: robot, newTag: newTag]]).write(
    to: updatedDirectory.appendingPathComponent("recruitment.json"))
check(RecruitTagCatalog.load(resourceDirectory: bundledDirectory, languageCode: "zh").tags == [robot])
check(
    RecruitTagCatalog.load(resourceDirectory: updatedDirectory, languageCode: "zh").tags == [
        robot, newTag
    ].sorted())
print(
    "PASS: \(count) migration/enablement combinations; retention, normalization, legacy, recognition and resource labels"
)

// Channel-specific tables become the catalog root on global servers, so tags
// only present there remain selectable.
let globalOnlyTag = "远程位"
let channelDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: channelDirectory) }
try FileManager.default.createDirectory(at: channelDirectory, withIntermediateDirectories: true)
try JSONSerialization.data(withJSONObject: ["tags": [robot: "Robot", globalOnlyTag: "Ranged"]]).write(
    to: channelDirectory.appendingPathComponent("recruitment.json"))
let channelCatalog = RecruitTagCatalog.load(resourceDirectory: channelDirectory, languageCode: "zh")
check(channelCatalog.tags == [robot, globalOnlyTag].sorted())
check(channelCatalog.label(for: robot) == "Robot" && channelCatalog.label(for: globalOnlyTag) == "Ranged")
print("PASS: channel-specific table as catalog root")

// The effective table file follows Core's custom-first order, so in-place
// updates are detectable through its modification date.
let tableDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: tableDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tableDirectory) }
check(RecruitTagCatalog.effectiveTableFile(resourceDirectory: tableDirectory) == nil)
let baseTable = tableDirectory.appendingPathComponent("recruitment.json")
try JSONSerialization.data(withJSONObject: ["tags": [robot: robot]]).write(to: baseTable)
check(RecruitTagCatalog.effectiveTableFile(resourceDirectory: tableDirectory) == baseTable)
let customTable = tableDirectory.appendingPathComponent("recruitment_custom.json")
try JSONSerialization.data(withJSONObject: ["tags": [dps: dps]]).write(to: customTable)
check(RecruitTagCatalog.effectiveTableFile(resourceDirectory: tableDirectory) == customTable)

// Same-path resource updates change the catalog, so reload tokens must not
// rely on the directory path alone.
try JSONSerialization.data(withJSONObject: ["tags": [robot: robot, newTag: newTag]]).write(to: baseTable)
check(RecruitTagCatalog.load(resourceDirectory: tableDirectory, languageCode: "zh").tags == [dps])
try FileManager.default.removeItem(at: customTable)
check(
    RecruitTagCatalog.load(resourceDirectory: tableDirectory, languageCode: "zh").tags == [
        robot, newTag
    ].sorted())
print("PASS: effective table file and same-path table updates")

if let resourcePath = CommandLine.arguments.dropFirst().first {
    let resourceURL = URL(fileURLWithPath: resourcePath)
    let canonical = RecruitTagCatalog.load(resourceDirectory: resourceURL, languageCode: "zh")
    check(!canonical.tags.isEmpty)
    for language in ["en", "ko", "ja"] {
        let catalog = RecruitTagCatalog.load(resourceDirectory: resourceURL, languageCode: language)
        check(catalog.tags == canonical.tags)
        check(catalog.label(for: robot) != robot)
        var preferred = RecruitConfiguration()
        preferred.first_tags_enabled = true
        preferred.first_tags = [dps, healing]
        check(
            preferred.params(tagNames: catalog.labels).first_tags == [
                catalog.label(for: dps), catalog.label(for: healing),
            ])
        check(preferred.params(tagNames: catalog.labels).preserve_tags == [robot])
        check(preferred.first_tags == [dps, healing])
    }
    print("PASS: actual Core resources, \(canonical.tags.count) canonical tags across zh/en/ko/ja")
}

let custom = temporary.appendingPathComponent("recruitment_custom.json")
try JSONSerialization.data(withJSONObject: ["tags": [dps: "Custom DPS"]]).write(to: custom)
check(RecruitTagCatalog.read(resourceDirectory: temporary)?.labels == [dps: "Custom DPS"])
try FileManager.default.removeItem(at: temporary.appendingPathComponent("recruitment.json"))
check(RecruitTagCatalog.read(resourceDirectory: temporary)?.labels == [dps: "Custom DPS"])
var customConfig = RecruitConfiguration()
customConfig.first_tags_enabled = true
customConfig.first_tags = [dps]
check(
    customConfig.params(tagNames: RecruitTagCatalog.read(resourceDirectory: temporary)!.labels).first_tags == [
        "Custom DPS"
    ])
print("PASS: Core custom replacement and custom-only resource overlays")

// MARK: - R10 公招结果显示已持有干员潜能

// showPotential is a GUI-only display switch (WPF Recruit.ShowPotential): it
// defaults to true, persists through round trips, and never reaches Core params.
check(defaults.showPotential)
check(try decode([:]).showPotential)
check(try decode(["showPotential": true]).showPotential)
check(!(try decode(["showPotential": false]).showPotential))
check(try params(defaults)["showPotential"] == nil)
let potentialPersisted = try PropertyListDecoder().decode(
    RecruitConfiguration.self, from: PropertyListEncoder().encode(forceOff))
check(potentialPersisted.showPotential)
var potentialOff = defaults
potentialOff.showPotential = false
check(
    !(try PropertyListDecoder().decode(
        RecruitConfiguration.self, from: PropertyListEncoder().encode(potentialOff)
    ).showPotential))
print("PASS: R10 showPotential defaults true, round trips, stays out of Core params")

// Core RecruitResult shape (AutoRecruitTask.cpp:583-598): every oper carries
// id/name/level; missing ids decode as nil and stay unannotated.
let recruitJSON: [String: Any] = [
    "tags": ["高级资深干员", "输出"],
    "level": 6,
    "result": [
        [
            "tags": ["输出", "群攻"],
            "level": 4,
            "opers": [
                ["name": "银灰", "id": "char_291_aglina", "level": 6],
                ["name": "幽灵鲨", "id": "char_143_ghost", "level": 5],
                ["name": "米格鲁", "level": 3],
            ],
        ]
    ],
]
let recruit = try JSONDecoder().decode(
    MAARecruit.self, from: JSONSerialization.data(withJSONObject: recruitJSON))
check(recruit.level == 6 && recruit.result.count == 1 && recruit.result[0].level == 4)
check(recruit.result[0].opers[0].id == "char_291_aglina")
check(recruit.result[0].opers[2].id == nil)
let minimalJSON: [String: Any] = [
    "tags": [], "level": 3,
    "result": [["tags": ["支援"], "level": 3, "opers": [["name": "夜刀", "id": "char_002_amiya", "level": 2]]]],
]
check(
    try JSONDecoder().decode(MAARecruit.self, from: JSONSerialization.data(withJSONObject: minimalJSON))
        .result[0].opers[0].id == "char_002_amiya")
print("PASS: R10 MAARecruit decodes per-oper ids, tolerating absent ids")

let potentialTable = [
    "char_291_aglina": 6,
    "char_143_ghost": 2,
    "char_002_amiya": 3,
]

func annotation(_ result: MAARecruit.Result, table: [String: Int]?, show: Bool) -> [RecruitPotentialAnnotation?] {
    result.annotatedOpers(potentialByID: table, showPotential: show).map(\.annotation)
}

func names(_ result: MAARecruit.Result, table: [String: Int]?, show: Bool) -> [String] {
    result.annotatedOpers(potentialByID: table, showPotential: show).map(\.oper.name)
}

let combo = recruit.result[0]

// Gate off: no annotations at all, order falls back to level-descending stability.
check(annotation(combo, table: potentialTable, show: false) == [nil, nil, nil])
check(names(combo, table: potentialTable, show: false) == ["银灰", "幽灵鲨", "米格鲁"])
// Gate on without owned data: WPF treats a nil map as "no annotation", never NEW.
check(annotation(combo, table: nil, show: true) == [nil, nil, nil])
check(annotation(combo, table: [:], show: true) == [.newOper, .newOper, nil])
// Owned: rank with the WPF-exact literals; pot 6 collapses to MAX.
check(combo.annotatedOpers(potentialByID: potentialTable, showPotential: true).map(\.annotation?.displayText)
    == [" ( MAX )", " ( 2 )", nil])
check(RecruitPotentialAnnotation.rank(5).displayText == " ( 5 )")
check(RecruitPotentialAnnotation.rank(1).displayText == " ( 1 )")
check(RecruitPotentialAnnotation.max.displayText == " ( MAX )")
check(RecruitPotentialAnnotation.newOper.displayText == " ( !!! NEW !!! )")
// Sort within the combination: level desc, then potential asc (-1 for NEW/nil);
// ties keep the original relative order.
check(names(combo, table: potentialTable, show: true) == ["银灰", "幽灵鲨", "米格鲁"])
// Potential tiebreak only orders same-level operators: NEW (-1) before rank 2.
let tieCombo = MAARecruit.Result(
    tags: ["输出"], level: 4,
    opers: [
        MAARecruit.Operator(id: "char_143_ghost", name: "幽灵鲨", level: 4),
        MAARecruit.Operator(id: "char_999_new", name: "新干员", level: 4),
    ])
check(names(tieCombo, table: potentialTable, show: true) == ["新干员", "幽灵鲨"])
check(annotation(tieCombo, table: potentialTable, show: true) == [.newOper, .rank(2)])

// Gate: combinations below 4★ only annotate 1★ operators; 4★+ annotate everyone.
let lowCombo = MAARecruit.Result(
    tags: ["近卫"], level: 3,
    opers: [
        MAARecruit.Operator(id: "char_143_ghost", name: "幽灵鲨", level: 5),
        MAARecruit.Operator(id: "char_002_amiya", name: "阿米娅", level: 5),
        MAARecruit.Operator(id: "char_512_wtstv", name: "温蒂", level: 4),
        MAARecruit.Operator(id: "char_103_angel", name: "能天使", level: 6),
    ])
check(annotation(lowCombo, table: potentialTable, show: true) == [nil, nil, nil, nil])
let oneStarInLowCombo = MAARecruit.Result(
    tags: ["支援"], level: 3,
    opers: [MAARecruit.Operator(id: "char_002_amiya", name: "阿米娅", level: 1)])
check(annotation(oneStarInLowCombo, table: potentialTable, show: true) == [.rank(3)])
let missingIDInFourStar = MAARecruit.Result(
    tags: ["输出"], level: 4,
    opers: [MAARecruit.Operator(id: nil, name: "无名", level: 3)])
check(annotation(missingIDInFourStar, table: potentialTable, show: true) == [nil])
print("PASS: R10 annotation gate, literals, ownership and sort order all WPF-isomorphic")
