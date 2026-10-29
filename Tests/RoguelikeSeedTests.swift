import Foundation
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(value(), message) }
func params(_ config: RoguelikeConfiguration, input: Bool) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params(supportsSeedInput: input))) as! [String: Any]
}
var config = RoguelikeConfiguration()
expect(!config.seedEnabled && config.seed.isEmpty, "Migration disabled")
for theme in RoguelikeConfiguration.Theme.allCases {
 for mode in theme.modes {
  for squad in theme.squads {
   config.theme = theme; config.mode = mode; config.squad = squad
   config.seedEnabled = true; config.seed = "  aBcD1234\n"
   for input in [true, false] {
    let expected = input && theme == .Sarkaz && mode == .investment && ["点刺成锭分队", "后勤分队"].contains(squad)
    expect((try! params(config, input: input))["start_with_seed"] as? String == (expected ? "aBcD1234" : nil), "Applicability matrix")
    expect(config.seed == "  aBcD1234\n" && config.seedEnabled, "Preferences preserved")
   }
  }
 }
}
config.theme = .Sarkaz; config.mode = .investment; config.squad = "后勤分队"
for text in ["", "  \n\t"] { config.seed = text; expect((try! params(config, input: true))["start_with_seed"] == nil, "Empty seed omitted") }
config.seed = "AbCd12"; config.seedEnabled = false
expect((try! params(config, input: true))["start_with_seed"] == nil, "Disabled seed omitted")
config.seedEnabled = true
config.seedEnabled = false
expect((try! params(config, input: false))["start_with_seed"] == nil, "Can disable after transport change")
config.seedEnabled = true
expect((try! JSONSerialization.jsonObject(with: JSONEncoder().encode(config.params)) as! [String: Any])["start_with_seed"] == nil, "Unknown transport fails closed")
let data = try PropertyListEncoder().encode(config)
expect(try! PropertyListDecoder().decode(RoguelikeConfiguration.self, from: data) == config, "Persistence")
print("PASS \(checks) seed checks")
