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

print("PASS \(checks) starting-oper checks")
