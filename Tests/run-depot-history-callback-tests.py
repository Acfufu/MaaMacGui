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
# P15 边界外剥离：VideoRecognition 清理块引用本套件不编译的
# VideoRecognitionImport——存在性 fail-loudly 后从探针剥离。
video_anchor='if info.taskchain == "VideoRecognition" {'
assert video_anchor in branch,'P15 video cleanup block missing from MaaMessage.swift'
v_start=branch.index('        '+video_anchor)
v_end=branch.index('\n        }\n',v_start)+len('\n        }\n')
branch=branch[:v_start]+branch[v_end:]
extra_start=source.index('    private func processSubTaskExtraInfo(')
a_extra=source.index('        case "Depot":',extra_start)
b_extra=source.index('        default:',a_extra)
extra_branch=source[a_extra:b_extra]
model=(root/'MeoAsstMac/Model/MAAViewModel.swift').read_text()
start=model.index('    func invalidateInventory()');brace=model.index('{',start);depth=0
for end in range(brace,len(model)):
 if model[end]=='{':depth+=1
 elif model[end]=='}':
  depth-=1
  if depth==0:break
invalidate=model[start:end+1]
probe=r'''
import Foundation
struct MAADepot {
 let done:Bool;let items:[String:Int]
 init(done:Bool,items:[String:Int]){self.done=done;self.items=items}
 init?(json:ExtraDetails,context:String){guard let value=json.depot else{return nil};self=value}
}
struct MAAOperBox {
 let historyPayload:OperBoxHistoryPayload
 init(_ value:OperBoxHistoryPayload){historyPayload=value}
 init?(json:ExtraDetails,context:String){guard let value=json.operators else{return nil};self=MAAOperBox(value)}
}
struct ExtraDetails {var depot:MAADepot?;var operators:OperBoxHistoryPayload?}
struct ExtraInfo {let taskchain:String;let taskid:Int32?;let what:String;let details:ExtraDetails}
final class TestRecognitionStore {
 var depot:MAADepot?;var operators:MAAOperBox?
 func setDepot(_ value:MAADepot?){depot=value}
 func setOperBox(_ value:MAAOperBox?){operators=value}
}
struct Info { let taskchain:String;let taskid:Int32 }
struct Message { enum Code { case TaskChainCompleted,TaskChainError,TaskChainStopped };let code:Code }
final class MAAViewModel {
 static let userDirectory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 var inventory=InventorySnapshotAdapter()
 var inventoryScope=InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"A")
 var operBoxHistoryTaskID:Int32?
 var operBoxHistoryScope:InventoryScope?
 var pendingOperBoxHistory:OperBoxHistoryPayload?
 var operBoxHistoryRevision=UUID()
 var inventoryDepotTaskID:Int32?=42
 var inventoryDepotScope:InventoryScope?
 var pendingInventoryDepot:MAADepot?
 var yituliuOpenApiToken=""
 var yituliuImportInFlight=false
 var yituliuImportMessage:String?
 var recruitResourceDirectory:URL?
 var errors=[String]()
 var logStore:TestRecognitionStore?=TestRecognitionStore()
 func receiveDailyDepot(_ value:MAADepot?,coreID:Int32?) -> Bool {false}
 func receiveDailyOperators(_ value:MAAOperBox?,coreID:Int32?) -> Bool {false}
 // P12.4 识别回填复查钩子（processDailyUserDataTerminal .depot 分支引用）；
 // 真实复查行为由 run-depot-maintain-dispatch-tests.py 专责，此处 no-op 存根。
 func reviewDepotMaintainSkippedPlans(){}
 func logError(_ text:String) { errors.append(text) }
''' + invalidate + r'''
 func process(_ message:Message,_ info:Info) {
''' + branch + r'''
 }
 func processExtra(_ info:ExtraInfo) {switch info.taskchain {
''' + extra_branch + r'''
 default:break
 }}
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

let payload=OperBoxHistoryPayload(done:true,allOperators:[.init(id:"amiya",own:true,name:"阿米娅",rarity:5)],ownedOperators:[.init(id:"amiya",own:true,name:"阿米娅",rarity:5,elite:1,level:50,potential:2)])
func opModel(_ value:OperBoxHistoryPayload=payload) -> MAAViewModel {
 let m=MAAViewModel();m.operBoxHistoryTaskID=77;m.operBoxHistoryScope=m.inventoryScope;m.pendingOperBoxHistory=value;return m
}
let opInfo=Info(taskchain:"OperBox",taskid:77)
let opGood=opModel();opGood.process(Message(code:.TaskChainCompleted),opInfo)
let opSaved=try opGood.operBoxHistoryStore.load(scope:opGood.inventoryScope)
check(opSaved?.operators == payload,"Owned completed operator result saved")
check(opGood.pendingOperBoxHistory == nil && opGood.operBoxHistoryTaskID == nil,"Operator ownership consumed on completion")
for terminal in [Message.Code.TaskChainError,.TaskChainStopped] {
 let failed=opModel();failed.process(Message(code:terminal),opInfo)
 check(try! failed.operBoxHistoryStore.load(scope:failed.inventoryScope) == opSaved,"Failed/stopped operator refresh preserves history")
}
let opPartial=opModel(.init(done:false,allOperators:payload.allOperators,ownedOperators:payload.ownedOperators));opPartial.process(Message(code:.TaskChainCompleted),opInfo)
check(try! opPartial.operBoxHistoryStore.load(scope:opPartial.inventoryScope) == opSaved,"Partial operator result rejected even on terminal completion")
check(!opPartial.errors.isEmpty,"Invalid operator data reports persistence rejection")
let opWrong=opModel();opWrong.process(Message(code:.TaskChainCompleted),Info(taskchain:"OperBox",taskid:78))
check(try! opWrong.operBoxHistoryStore.load(scope:opWrong.inventoryScope) == opSaved,"Wrong operator task ID cannot overwrite history")
let opSwitched=opModel();opSwitched.inventoryScope=InventoryScope(connection:"adb",server:"US",profile:"Default",account:"A");opSwitched.process(Message(code:.TaskChainCompleted),opInfo)
check(try! opSwitched.operBoxHistoryStore.load(scope:opSwitched.inventoryScope) == nil,"Operator callback scoped to frozen server/account")

let live=opModel()
live.processExtra(ExtraInfo(taskchain:"OperBox",taskid:77,what:"OperBoxInfo",details:ExtraDetails(operators:payload)))
check(live.logStore?.operators?.historyPayload==payload,"Owned operator partial/final data reaches current UI")
live.invalidateInventory()
check(live.logStore?.operators==nil,"Revoking recognition ownership clears current operator presentation")
live.processExtra(ExtraInfo(taskchain:"OperBox",taskid:77,what:"OperBoxInfo",details:ExtraDetails(operators:payload)))
check(live.logStore?.operators==nil && live.pendingOperBoxHistory==nil,"Late cancelled operator data cannot reappear in current UI")
let rawWrong=opModel()
rawWrong.processExtra(ExtraInfo(taskchain:"OperBox",taskid:78,what:"OperBoxInfo",details:ExtraDetails(operators:payload)))
check(rawWrong.logStore?.operators==nil,"Wrong operator task ID cannot update current UI")
let rawScope=opModel();rawScope.inventoryScope=InventoryScope(connection:"other",server:"CN",profile:"Default",account:"A")
rawScope.processExtra(ExtraInfo(taskchain:"OperBox",taskid:77,what:"OperBoxInfo",details:ExtraDetails(operators:payload)))
check(rawScope.logStore?.operators==nil,"Changed identity rejects old operator data before UI update")
let depotLive=make(["30012":5])
depotLive.processExtra(ExtraInfo(taskchain:"Depot",taskid:42,what:"DepotInfo",details:ExtraDetails(depot:MAADepot(done:true,items:["30012":8]))))
check(depotLive.logStore?.depot?.items==["30012":8],"Owned Depot data reaches current UI")
depotLive.invalidateInventory()
depotLive.processExtra(ExtraInfo(taskchain:"Depot",taskid:42,what:"DepotInfo",details:ExtraDetails(depot:MAADepot(done:true,items:["30012":999]))))
check(depotLive.logStore?.depot==nil && depotLive.pendingInventoryDepot==nil,"Late cancelled Depot data cannot reappear in UI")
try? FileManager.default.removeItem(at:MAAViewModel.userDirectory)
print("PASS \(checks) production Depot history callback assertions")
'''
with tempfile.TemporaryDirectory(prefix='maa-depot-history-callback-') as d:
 p=Path(d);(p/'main.swift').write_text(probe)
 model=(root/'MeoAsstMac/Model/MAAViewModel.swift').read_text();marker='// MARK: - Depot history integration'
 assert model.count(marker)==1
 def extension_at(marker):
  start=model.index('extension MAAViewModel {',model.index(marker));body=model.index('{',start);depth=0
  for end in range(body,len(model)):
   if model[end]=='{':depth+=1
   elif model[end]=='}':
    depth-=1
    if depth==0:return model[start:end+1]
  raise RuntimeError(marker)
 (p/'Integration.swift').write_text('import Foundation\n'+extension_at('// MARK: - Depot history integration')+'\n'+extension_at('// MARK: - Operator history integration'))
 subprocess.run(['xcrun','swiftc',str(root/'MeoAsstMac/Model/InventoryTarget.swift'),str(root/'MeoAsstMac/Model/DepotHistoryStore.swift'),str(root/'MeoAsstMac/Model/OperBoxHistoryStore.swift'),str(root/'MeoAsstMac/Model/OperBoxHistoryPayload.swift'),str(root/'MeoAsstMac/Model/YituliuOperBoxService.swift'),str(p/'Integration.swift'),str(p/'main.swift'),'-o',str(p/'tests')],check=True)
 subprocess.run([str(p/'tests')],check=True)
