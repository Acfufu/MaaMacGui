#!/usr/bin/env python3
"""Exercise the real owned Depot terminal branch and app persistence method."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'MeoAsstMac/Core/MaaMessage.swift').read_text()
a='        if message.code == .TaskChainError || message.code == .TaskChainStopped {'
b='        if message.code == .TaskChainStart, info.taskchain'
assert source.count(a)==1 and source.count(b)==1
branch=source[source.index(a):source.index(b)]
probe=r'''
import Foundation
struct MAADepot { let done: Bool;let items:[String:Int] }
struct Info { let taskchain:String;let taskid:Int32 }
struct Message { enum Code { case TaskChainCompleted,TaskChainError,TaskChainStopped };let code:Code }
final class MAAViewModel {
 static let userDirectory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 var inventory=InventorySnapshotAdapter()
 var inventoryScope=InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"A")
 var inventoryDepotTaskID:Int32?=42
 var inventoryDepotScope:InventoryScope?
 var pendingInventoryDepot:MAADepot?
 var errors=[String]()
 func logError(_ text:String) { errors.append(text) }
 func invalidateInventory() { inventory.invalidate();inventoryDepotTaskID=nil;inventoryDepotScope=nil;pendingInventoryDepot=nil }
 func process(_ message:Message,_ info:Info) {
''' + branch + r'''
 }
}
var checks=0
func check(_ value:@autoclosure () -> Bool,_ message:String) {checks+=1;precondition(value(),message)}
func make(_ items:[String:Int],done:Bool=true) -> MAAViewModel {
 let m=MAAViewModel();m.inventoryDepotScope=m.inventoryScope;m.pendingInventoryDepot=MAADepot(done:done,items:items);return m
}
let info=Info(taskchain:"Depot",taskid:42)
let good=make(["30012":5]);good.process(Message(code:.TaskChainCompleted),info)
let saved=try good.depotHistoryStore.load(scope:good.inventoryScope)
check(saved?.items == ["30012":5],"Owned successful complete result saved")
check(good.inventory.snapshot?.items == ["30012":5],"Existing live capture remains unchanged")
check(good.inventoryDepotTaskID == nil && good.pendingInventoryDepot == nil,"Completion consumes ownership")
good.process(Message(code:.TaskChainCompleted),info)
check(try! good.depotHistoryStore.load(scope:good.inventoryScope) == saved,"Duplicate terminal does not rewrite history")
for terminal in [Message.Code.TaskChainError,.TaskChainStopped] {
 let failed=make(["30012":999]);failed.process(Message(code:terminal),info)
 check(try! failed.depotHistoryStore.load(scope:failed.inventoryScope) == saved,"Failed or stopped refresh preserves successful history")
 check(failed.inventory.snapshot == nil,"Failed refresh cannot publish fresh inventory")
}
let partial=make(["30012":999],done:false);partial.process(Message(code:.TaskChainCompleted),info)
check(try! partial.depotHistoryStore.load(scope:partial.inventoryScope) == saved,"Incomplete result cannot replace history even on chain completion")
check(!partial.errors.isEmpty,"Incomplete completion reports recognition error")
let wrong=make(["30012":999]);wrong.process(Message(code:.TaskChainCompleted),Info(taskchain:"Depot",taskid:43))
check(try! wrong.depotHistoryStore.load(scope:wrong.inventoryScope) == saved,"Wrong task ID cannot write history")
let switched=make(["30012":999]);switched.inventoryScope=InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"B");switched.process(Message(code:.TaskChainCompleted),info)
check(try! switched.depotHistoryStore.load(scope:switched.inventoryScope) == nil,"Scope switch rejects late completion")
let unbound=make(["30012":3]);unbound.inventoryScope=InventoryScope(connection:"adb",server:"CN",profile:"Default");unbound.inventoryDepotScope=unbound.inventoryScope;unbound.process(Message(code:.TaskChainCompleted),info)
check(try! unbound.depotHistoryStore.load(scope:unbound.inventoryScope) == nil,"Unbound recognition never creates account history")
try? FileManager.default.removeItem(at:MAAViewModel.userDirectory)
print("PASS \(checks) production Depot history callback assertions")
'''
with tempfile.TemporaryDirectory(prefix='maa-depot-history-callback-') as d:
 p=Path(d);(p/'main.swift').write_text(probe)
 model=(root/'MeoAsstMac/Model/MAAViewModel.swift').read_text();marker='// MARK: - Depot history integration'
 assert model.count(marker)==1
 (p/'Integration.swift').write_text(model[model.index(marker):])
 subprocess.run(['xcrun','swiftc',str(root/'MeoAsstMac/Model/InventoryTarget.swift'),str(root/'MeoAsstMac/Model/DepotHistoryStore.swift'),str(p/'Integration.swift'),str(p/'main.swift'),'-o',str(p/'tests')],check=True)
 subprocess.run([str(p/'tests')],check=True)
