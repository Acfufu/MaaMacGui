import Foundation
protocol MAATaskConfiguration: Codable, Hashable, Sendable {
    var type: MAATaskType { get }
    var projectedTask: MAATask { get }
    associatedtype Params: Encodable
    var params: Params { get }
}
extension MAATaskConfiguration {
    init() { self = try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
enum MAATaskType { case Custom, OperProgress, Roguelike, Reclamation, UserDataUpdate, DepotMaintain; var description: String { "pipeline" } }

enum MAAClientChannel { case Official, Bilibili, txwy, YoStarEN, YoStarJP, YoStarKR }
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1; precondition(condition(), message)
}
func rejected(_ source: String) -> Bool {
    var c = OperProgressConfiguration(); c.plansJSON = source
    do { _ = try c.validatedPlans(); return false } catch { return true }
}
var custom = CustomConfiguration()
expect(custom.taskList.isEmpty, "Legacy empty payload defaults to blank editor")
do { try custom.validate(); preconditionFailure("Empty Custom accepted") } catch { checks += 1 }
custom.taskList = " A， B\r\n C\r D, , \n"
expect(custom.parsedTaskNames == ["A","B","C","D"], "All supported separators and trimming")
try custom.validate()
let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(custom.params)) as! [String:Any]
expect(payload["task_names"] as? [String] == ["A","B","C","D"], "Core key and ordered fallback list")
expect(payload.count == 1, "No UI-only fields reach Core")
for text in ["", "a\"b", "a\\b", "任务甲,任务乙"] {
    custom.taskList = text
    expect(try! JSONDecoder().decode(CustomConfiguration.self, from: JSONEncoder().encode(custom)) == custom, "Custom JSON roundtrip")
    expect(try! PropertyListDecoder().decode(CustomConfiguration.self, from: PropertyListEncoder().encode(custom)) == custom, "Custom plist roundtrip")
}
for input in ["[]", "{}", "null", "[{\"name\":\"  \" ,\"elite\":1}]", "[{\"name\":\"阿米娅\"}]", "[{\"name\":\"阿米娅\",\"elite\":null}]", "[{\"name\":\"阿米娅\",\"elite\":true}]", "[{\"name\":\"阿米娅\",\"elite\":0}]", "[{\"name\":\"阿米娅\",\"elite\":3}]", "[{\"name\":\"阿米娅\",\"skill_level\":1}]", "[{\"name\":\"阿米娅\",\"skill_level\":8}]", "[{\"name\":\"阿米娅\",\"skills\":7}]", "[{\"name\":\"阿米娅\",\"skill_mastery\":[0,1]}]", "[{\"name\":\"阿米娅\",\"skill_mastery\":[0,1,4]}]", "[{\"name\":\"阿米娅\",\"skill_mastery\":[-1,0,3]}]", "[{\"name\":\"阿米娅\",\"elite\":1,\"role\":\"Drone\"}]", "[{\"name\":\"阿米娅\",\"elite\":1,\"typo\":0}]"] {
    expect(rejected(input), "Invalid plans rejected: \(input)")
}
for role in ["Pioneer","Warrior","Tank","Sniper","Caster","Medic","Support","Special"] {
    expect(!rejected("[{\"name\":\"阿米娅\",\"role\":\"\(role)\",\"elite\":1}]"), "Core roles accepted")
}
for action in ["\"elite\":1", "\"elite\":2", "\"skill_level\":2", "\"skill_level\":7", "\"skill_mastery\":[0,0,3]", "\"skill_mastery\":[3,3,3]"] {
    var c = OperProgressConfiguration(); c.plansJSON = "[{\"name\":\" 阿米娅 \",\(action)}]"
    let plans = try c.validatedPlans()
    expect(plans.count == 1 && plans[0].name == "阿米娅", "Valid range edges and trimmed name")
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c.params)) as! [String:Any]
    let first = (json["plans"] as! [[String:Any]])[0]
    expect(Set(first.keys).isSubset(of: ["name","role","elite","skill_level","skill_mastery"]), "Only protocol keys encoded")
    expect(try! JSONDecoder().decode(OperProgressConfiguration.self, from: JSONEncoder().encode(c)) == c, "OperProgress JSON roundtrip")
    expect(try! PropertyListDecoder().decode(OperProgressConfiguration.self, from: PropertyListEncoder().encode(c)) == c, "OperProgress plist roundtrip")
}
var broken = OperProgressConfiguration();broken.plansJSON = "unfinished edit"
expect(try! JSONDecoder().decode(OperProgressConfiguration.self, from: JSONEncoder().encode(broken)) == broken, "Invalid edits remain recoverable after save")
do { _ = try JSONEncoder().encode(broken.params);preconditionFailure("Invalid params encoded") } catch { checks += 1 }
for task in [DailyTask(config: custom), DailyTask(config: broken), DailyTask(config: UserDataUpdateConfiguration()), DailyTask(config: DepotMaintainConfiguration())] {
    expect(!task.enabled, "Advanced pipelines are disabled when added")
    var once = task; once.enabled = true; once.runOnce = true
    expect(try! JSONDecoder().decode(DailyTask.self, from: JSONEncoder().encode(once)) == once, "Production DailyTask enum JSON preserves config, ID and runOnce")
    expect(try! PropertyListDecoder().decode(DailyTask.self, from: PropertyListEncoder().encode(once)) == once, "Production DailyTask enum plist preserves config, ID and runOnce")
}
print("PASS \(checks) pipeline configuration assertions")
