import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}
func params(_ config: RoguelikeConfiguration, supported: Bool = false) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params(blackflowStartAvailable: supported)))
        as! [String: Any]
}
func startList(_ json: [String: Any]) -> [[String: Any]] {
    (json["core_char_list"] as? [[String: Any]]) ?? []
}

// MARK: 缺省与迁移（显式缺省零暗改）

let empty = try JSONDecoder().decode(RoguelikeConfiguration.self, from: Data("{}".utf8))
expect(empty.startingOpers == [.init()], "Empty config defaults to one blank slot")
expect(empty.useAdditionalStartingOpers == false, "Additional slots off by default")
expect(try! params(empty)["core_char_list"] == nil, "Blank slots are not dispatched")

let legacy = try JSONDecoder().decode(
    RoguelikeConfiguration.self,
    from: Data(#"{"core_char":"丰川祥子","use_support":true}"#.utf8))
expect(legacy.startingOpers == [.init(name: "丰川祥子", useSupport: true)], "Legacy single operator migrates to slot 1")
expect(legacy.core_char == "丰川祥子" && legacy.use_support, "Legacy bridge reads slot 1")
let legacyParams = try params(legacy)
expect(startList(legacyParams).count == 1
    && startList(legacyParams)[0]["name"] as? String == "丰川祥子"
    && (startList(legacyParams)[0]["use_support"] as? Bool) == true, "Legacy operator dispatches as slot 1")
expect(legacyParams["core_char"] == nil && legacyParams["use_support"] == nil, "Retired single-operator keys")

let modern = try JSONDecoder().decode(
    RoguelikeConfiguration.self,
    from: Data(#"{"startingOpers":[{"name":"棘刺"},{"name":"维什戴尔","use_support":true}],"useAdditionalStartingOpers":true}"#.utf8))
expect(modern.startingOpers.count == 2, "Modern list decodes in order")
expect(modern.startingOpers[0].name == "棘刺" && !modern.startingOpers[0].useSupport, "Slot 1 without support")
expect(modern.startingOpers[1].name == "维什戴尔" && modern.startingOpers[1].useSupport, "Slot 2 with support")

let filled = try JSONDecoder().decode(
    RoguelikeConfiguration.self,
    from: Data(#"{"startingOpers":[]}"#.utf8))
expect(filled.startingOpers == [.init()], "Empty stored list defensively fills one blank slot")

// MARK: 三顺位下发（G03）

var config = modern
var list = startList(try params(config))
expect(list.count == 2, "Both slots dispatch when additional starting opers enabled")
expect(list[1]["use_support"] != nil, "Per-slot support flag encoded with Core key")

config.useAdditionalStartingOpers = false
list = startList(try params(config))
expect(list.count == 1 && list[0]["name"] as? String == "棘刺", "Slot 1 only when additional starting opers disabled")
expect(try! params(config)["use_nonfriend_support"] == nil, "No nonfriend flag without any support slot")

config.useAdditionalStartingOpers = true
config.startingOpers[1].useSupport = true
config.use_nonfriend_support = true
expect(try! params(config)["use_nonfriend_support"] as? Bool == true, "Nonfriend flag dispatches with any support slot")

config.startingOpers = [
    .init(name: "  ", useSupport: false),
    .init(name: "维什戴尔", useSupport: false),
]
list = startList(try params(config))
expect(list.count == 1 && list[0]["name"] as? String == "维什戴尔", "Blank slot names are dropped, later slots kept")
expect(try! params(config)["use_nonfriend_support"] == nil, "Blank slot support preference does not enable nonfriend flag")

config.startingOpers = [.init(name: "  "), .init(name: " ")]
expect(try! params(config)["core_char_list"] == nil, "All-blank slots dispatch nothing")

// MARK: 顺位 1 互斥（G04）

config.startingOpers = [.init(name: "丰川祥子")]
config.start_with_elite_two = true
config.use_support = true
expect(config.start_with_elite_two == false, "Slot 1 support clears elite-two start")
config.use_support = false
config.start_with_elite_two = true
expect(config.start_with_elite_two == true, "Elite-two start survives non-support slots")

// MARK: 黑流准备局与实托邦目标局

config = modern
config.theme = .BlackFlow
config.mode = .blackflowStart
config.blackflowStart.preparationOperator = " 机械师 "
list = startList(try params(config))
expect(list.count == 1 && list[0]["name"] as? String == "机械师"
    && (list[0]["use_support"] as? Bool) == false, "Preparation operator dispatches trimmed without support")
config.blackflowStart.preparationOperator = ""
expect(try! params(config)["core_char_list"] == nil, "Empty preparation operator dispatches nothing")
config.blackflowStart.utopia = true
list = startList(try params(config, supported: true))
expect(list.count == 2 && list[0]["name"] as? String == "棘刺", "Utopia target run keeps regular opening list")

// MARK: 推荐配置说明（G17 数据层）

var tipConfig = RoguelikeConfiguration()
for theme in RoguelikeConfiguration.Theme.allCases {
    tipConfig.theme = theme
    expect(tipConfig.tip?.isEmpty == false, "Tip present for \(theme.rawValue)")
}
tipConfig.theme = .Phantom
expect(tipConfig.tip?.contains("丰川祥子") == true, "Phantom tip names recommended operator")
tipConfig.theme = .BlackFlow
expect(tipConfig.tip?.contains("机械师") == true, "BlackFlow tip names mechanic")

// MARK: 持久化往返与旧键退役

config = modern
let encoded = try JSONEncoder().encode(config)
let encodedObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
expect(encodedObject["startingOpers"] != nil && encodedObject["useAdditionalStartingOpers"] != nil, "New keys persist")
expect(encodedObject["core_char"] == nil && encodedObject["use_support"] == nil, "Legacy keys no longer persisted")
expect(try! JSONDecoder().decode(RoguelikeConfiguration.self, from: encoded) == config, "JSON roundtrip")
let plist = try PropertyListEncoder().encode(config)
expect(try! PropertyListDecoder().decode(RoguelikeConfiguration.self, from: plist) == config, "Plist roundtrip")

let partialOper = try JSONDecoder().decode(
    RoguelikeConfiguration.self,
    from: Data(#"{"startingOpers":[{"name":"棘刺"}]}"#.utf8))
expect(partialOper.startingOpers[0].name == "棘刺" && !partialOper.startingOpers[0].useSupport,
       "Operator entry tolerates missing use_support")

// P09.2: production editor accessors preserve old profiles until actual edits.
var editor = legacy
let beforeRead = editor
expect(editor.startingOper(at: 2) == .init(), "Missing third slot reads as blank")
expect(editor == beforeRead, "Displaying slots never rewrites a legacy profile")
editor.setStartingOper(.init(name: "克洛丝", useSupport: true), at: 2)
expect(editor.startingOpers.count == 3 && editor.startingOpers[1] == .init(), "Editing third slot pads missing second slot")
expect(editor.startingOpers[0] == legacy.startingOpers[0], "Editing third slot preserves first")
editor.useAdditionalStartingOpers = true
expect(editor.hasStartingSupport, "Additional support controls nonfriend UI")
editor.useAdditionalStartingOpers = false
editor.use_support = false
expect(!editor.hasStartingSupport, "Hidden additional support cannot expose nonfriend UI")
editor.useAdditionalStartingOpers = true
expect(editor.startingOper(at: 2).name == "克洛丝", "Toggling additional slots preserves names")
editor.start_with_elite_two = true
editor.setStartingOper(.init(name: "棘刺", useSupport: true), at: 0)
expect(!editor.start_with_elite_two && editor.use_support, "First-slot editor honors elite-two exclusion")
editor.start_with_elite_two = true
expect(!editor.use_support && editor.startingOper(at: 2).useSupport, "Elite-two only excludes first-slot support")
let beforeInvalid = editor
editor.setStartingOper(.init(name: "invalid"), at: -1)
editor.setStartingOper(.init(name: "invalid"), at: 3)
expect(editor == beforeInvalid, "Invalid editor slots ignored")
editor.startingOpers = [.init(name: " ", useSupport: true)]
expect(!editor.hasStartingSupport, "Blank-name support does not expose nonfriend UI")
editor.setStartingOper(.init(name: "维什戴尔", useSupport: true), at: 1)
let editorPayload = startList(try params(editor))
expect(editorPayload.count == 1 && editorPayload[0]["name"] as? String == "维什戴尔", "Blank first editor slot compacts consistently with visible hint")
expect(try! JSONDecoder().decode(RoguelikeConfiguration.self, from: JSONEncoder().encode(editor)) == editor, "Edited slots JSON roundtrip")
expect(try! PropertyListDecoder().decode(RoguelikeConfiguration.self, from: PropertyListEncoder().encode(editor)) == editor, "Edited slots plist roundtrip")

let catalog = RoguelikeConfiguration.OperatorCatalog(data: Data(#"{"chars":{"char_1":{"name":"棘刺","name_en":"Thorns","name_jp":"ソーンズ","name_kr":"쏜즈","name_tw":"棘刺","profession":"WARRIOR"},"char_2":{"name":"山","name_en":"Mountain","profession":"WARRIOR"},"char_3":{"name":"克洛丝","name_en":"Kroos","profession":"SNIPER"}}}"#.utf8))
for name in ["棘刺", " thorns ", "THORNS", "ソーンズ", "쏜즈"] {
    expect(catalog.entry(for: name)?.name == "棘刺", "Official server name resolves: \(name)")
}
expect(catalog.entry(for: "unknown") == nil, "Unknown names are not guessed")
expect(RoguelikeConfiguration.OperatorCatalog(data: Data("broken".utf8)).entry(for: "Thorns") == nil, "Corrupt catalog fails open without crashing")
editor.startingOpers = [.init(name: " thorns ", useSupport: true), .init(name: "Mountain"), .init(name: "unknown")]
editor.useAdditionalStartingOpers = true
expect(editor.hasDuplicateStartingProfession(in: catalog), "Localized aliases reveal duplicate classes")
let normalizedParams = RoguelikeConfiguration.Params(config: editor, operatorCatalog: catalog)
let normalized = startList(try JSONSerialization.jsonObject(with: JSONEncoder().encode(normalizedParams)) as! [String: Any])
expect(normalized.map { $0["name"] as! String } == ["棘刺", "山", "unknown"], "Dispatch canonical names and preserve unknown input")
expect(normalized[0]["use_support"] as? Bool == true, "Canonical dispatch preserves per-slot support")
expect(editor.startingOpers[0].name == " thorns ", "Normalization does not rewrite saved user input")
editor.useAdditionalStartingOpers = false
expect(!editor.hasDuplicateStartingProfession(in: catalog), "Hidden slots do not produce duplicate warning")
editor.useAdditionalStartingOpers = true
editor.setStartingOper(.init(name: "Kroos"), at: 1)
expect(!editor.hasDuplicateStartingProfession(in: catalog), "Different classes and unknown names do not produce false warning")
editor.theme = .BlackFlow; editor.mode = .exp; editor.blackflowFastFlight = true
expect(!editor.hasDuplicateStartingProfession(in: catalog), "Fast flight does not validate inactive user list")
editor.blackflowFastFlight = false; editor.mode = .blackflowStart
editor.blackflowStart.preparationOperator = " Thorns "
let prepParams = RoguelikeConfiguration.Params(config: editor, operatorCatalog: catalog)
expect(prepParams.core_char_list?.first?.name == "棘刺", "Preparation aliases normalize too")
editor.blackflowStart.utopia = true
let utopiaParams = RoguelikeConfiguration.Params(config: editor, blackflowStartAvailable: true, operatorCatalog: catalog)
expect(utopiaParams.collectible_mode_core_char_list?.first?.name == "棘刺", "Utopia preparation aliases normalize consistently")

print("PASS \(checks) starting-oper checks")
