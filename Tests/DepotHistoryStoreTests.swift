import Foundation
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    checks += 1;precondition(ok(), message)
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = DepotHistoryStore(directory: directory)
let scope = InventoryScope(connection: "adb:1", server: "CN", profile: "Default", account: "account/../A")
let time = Date(timeIntervalSince1970: 1700000000)
check(try! store.load(scope: scope) == nil, "No history before recognition")
try store.save(items: ["30012":7], complete: true, scope: scope, now: time)
let saved = try store.load(scope: scope)!
check(saved.items == ["30012":7] && saved.scope == scope && saved.capturedAt == time, "Exact metadata and data persisted")
check(try! store.fileURL(scope: scope).deletingLastPathComponent().path == directory.path, "Account cannot escape the data directory")
for other in [InventoryScope(connection:"adb:2",server:"CN",profile:"Default",account:scope.account),InventoryScope(connection:"adb:1",server:"US",profile:"Default",account:scope.account),InventoryScope(connection:"adb:1",server:"CN",profile:"Other",account:scope.account),InventoryScope(connection:"adb:1",server:"CN",profile:"Default",account:"B")] {
    check(try! store.load(scope: other) == nil, "Connection/server/profile/account isolated")
}
for complete in [true,false] {
    do { try store.save(items:["30012":-1],complete:complete,scope:scope);preconditionFailure("negative accepted") } catch {checks += 1}
    check(try! store.load(scope: scope) == saved, "Invalid refresh preserves last known history")
}
do {try store.save(items:[:],complete:false,scope:scope);preconditionFailure("partial accepted")} catch {checks += 1}
check(try! store.load(scope: scope) == saved, "Partial refresh never overwrites good data")
let unbound = InventoryScope(connection:"adb:1",server:"CN",profile:"Default")
check(try! store.load(scope: unbound) == nil, "Unbound account never reads a cache")
do {try store.save(items:[:],complete:true,scope:unbound);preconditionFailure("unbound saved")} catch {checks += 1}
let restarted = DepotHistoryStore(directory: directory)
check(try! restarted.load(scope: scope) == saved, "Independent store instance restores historical record")
let file = try store.fileURL(scope: scope)
var object = try JSONSerialization.jsonObject(with: Data(contentsOf:file)) as! [String:Any]
object["schemaVersion"] = 2
try JSONSerialization.data(withJSONObject:object).write(to:file)
do {_ = try store.load(scope:scope);preconditionFailure("future schema accepted")} catch {checks += 1}
object["schemaVersion"] = 1
var storedScope = object["scope"] as! [String:Any];storedScope["account"] = "B";object["scope"] = storedScope
try JSONSerialization.data(withJSONObject:object).write(to:file)
do {_ = try store.load(scope:scope);preconditionFailure("mismatched envelope accepted")} catch {checks += 1}
try Data("corrupt".utf8).write(to:file)
do {_ = try store.load(scope:scope);preconditionFailure("corrupt record accepted")} catch {checks += 1}
// A failed disk write must be observable to the caller.
let blocked = directory.appendingPathComponent("blocked")
try Data().write(to:blocked)
do {try DepotHistoryStore(directory:blocked).save(items:[:],complete:true,scope:scope);preconditionFailure("write failure swallowed")} catch {checks += 1}
print("PASS \(checks) historical Depot storage assertions")
