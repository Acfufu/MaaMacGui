import Foundation
var checks=0
func check(_ value:@autoclosure () -> Bool,_ message:String){checks+=1;precondition(value(),message)}
let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer{try? FileManager.default.removeItem(at:directory)}
let store=OperBoxHistoryStore(directory:directory)
let scope=InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"A/../x")
let own=OperBoxHistoryPayload.OwnedOperator(id:"amiya",own:true,name:"阿米娅\"\\\n",rarity:5,elite:1,level:50,potential:2)
let all=OperBoxHistoryPayload.Operator(id:"amiya",own:true,name:own.name,rarity:5)
let valid=OperBoxHistoryPayload(done:true,allOperators:[all],ownedOperators:[own])
let fixed=Date(timeIntervalSince1970:1700000000)
try store.save(valid,scope:scope,now:fixed)
let saved=try store.load(scope:scope)!
check(saved.operators==valid && saved.capturedAt==fixed && saved.scope==scope,"Exact received fields and capture identity persisted")
check(try! OperBoxHistoryStore(directory:directory).load(scope:scope)==saved,"Independent instance restores operator history")
let encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(saved.operators.ownedOperators[0])) as! [String:Any]
check(Set(encoded.keys)==Set(["id","own","name","rarity","elite","level","potential"]),"Absent skill/mastery/module data not fabricated")
for other in [InventoryScope(connection:"other",server:"CN",profile:"Default",account:scope.account),InventoryScope(connection:"adb",server:"US",profile:"Default",account:scope.account),InventoryScope(connection:"adb",server:"CN",profile:"Other",account:scope.account),InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"B")] {
 check(try! store.load(scope:other)==nil,"Account/server/connection/profile cannot share record")
}
let negative=OperBoxHistoryPayload.OwnedOperator(id:"amiya",own:true,name:"阿米娅",rarity:5,elite:1,level:-1,potential:2)
for bad in [OperBoxHistoryPayload(done:false,allOperators:[all],ownedOperators:[own]),.init(done:true,allOperators:[],ownedOperators:[]),.init(done:true,allOperators:[all,all],ownedOperators:[own]),.init(done:true,allOperators:[all],ownedOperators:[own,own]),.init(done:true,allOperators:[all],ownedOperators:[negative])] {
 do{try store.save(bad,scope:scope);preconditionFailure("Invalid/partial history accepted")}catch{checks+=1}
 check(try! store.load(scope:scope)==saved,"Rejected refresh preserves last complete snapshot")
}
let unbound=InventoryScope(connection:"adb",server:"CN",profile:"Default")
check(try! store.load(scope:unbound)==nil,"Unbound account never loads historical data")
do{try store.save(valid,scope:unbound);preconditionFailure("Unbound account saved")}catch{checks+=1}
let file=try HistoryFileIO.fileURL(scope:scope,directory:directory)
check(file.deletingLastPathComponent().path==directory.path,"Manual account label cannot escape directory")
var json=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];json["schemaVersion"]=2
try JSONSerialization.data(withJSONObject:json).write(to:file)
do{_ = try store.load(scope:scope);preconditionFailure("Future schema accepted")}catch{checks+=1}
json["schemaVersion"]=1;var altered=json["scope"] as! [String:Any];altered["account"]="B";json["scope"]=altered
try JSONSerialization.data(withJSONObject:json).write(to:file)
do{_ = try store.load(scope:scope);preconditionFailure("Mismatched envelope accepted")}catch{checks+=1}
try Data("broken".utf8).write(to:file)
do{_ = try store.load(scope:scope);preconditionFailure("Corrupt data accepted")}catch{checks+=1}
let blocked=directory.appendingPathComponent("blocked");try Data().write(to:blocked)
do{try OperBoxHistoryStore(directory:blocked).save(valid,scope:scope);preconditionFailure("Write failure ignored")}catch{checks+=1}
print("PASS \(checks) historical operator storage assertions")
