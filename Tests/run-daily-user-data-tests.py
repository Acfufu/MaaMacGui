#!/usr/bin/env python3
"""Exercise production composite preparation/callbacks and original-profile receipts."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
model=(root/'MeoAsstMac/Model/MAAViewModel.swift').read_text()
def block(source,marker):
 start=source.index(marker);brace=source.index('{',start);depth=0
 for end in range(brace,len(source)):
  if source[end]=='{':depth+=1
  elif source[end]=='}':
   depth-=1
   if depth==0:return source[start:end+1]
 raise RuntimeError(marker)
marker='// MARK: - Daily user-data composite'
composite=block(model[model.index(marker):],'extension MAAViewModel {')
composite=composite[composite.index('{')+1:composite.rfind('}')]
extra='\n'.join(block(model,signature).replace('private func','func',1) for signature in ['    func applyDailyTaskCallback(','    func markDailyRunFailed()'])
tasks=(root/'MeoAsstMac/Model/MAATask.swift').read_text();daily=block(tasks,'struct DailyTask:')
start=model.index('                if case .userdataupdate(let config) = task.task {',model.index('private func startTasks(snapshot:'))
end=model.index('                if case .depotMaintain(let depotConfig) = task.task {',start);enqueue_branch=model[start:end]
start=model.index('            if appendedAnyTask {',end);submit=block(model[start:],'            if appendedAnyTask {')
catch_start=model.index('        } catch {',start);catch_end=model.index('\n    }\n\n    /// Freeze the target',catch_start);catch_block=model[catch_start:catch_end]
messages=(root/'MeoAsstMac/Core/MaaMessage.swift').read_text()
raw_start=messages.index('        case "Depot":',messages.index('    private func processSubTaskExtraInfo('))
raw_end=messages.index('        default:',raw_start)
raw_cases=messages[raw_start:raw_end]
probe=r'''
import Foundation
protocol MAATaskConfiguration:Codable,Hashable,Sendable {associatedtype Params:Encodable;var params:Params{get}}
extension MAATaskConfiguration {init(){self=try! JSONDecoder().decode(Self.self,from:Data("{}".utf8))}}
enum MAATaskType:String {case UserDataUpdate,Depot,OperBox}
enum MAAClientChannel:CaseIterable {case Official,Bilibili,txwy,YoStarEN,YoStarJP,YoStarKR}
struct InfrastConfiguration:Codable,Hashable,Sendable {
 enum Mode:String,Codable {case custom};enum Selection:String,Codable{case automatic,fixed}
 var mode=Mode.custom;var planSelection=Selection.automatic;var filename="";var plan_index=0
}
struct MallConfiguration:Codable,Hashable,Sendable {var creditFightDate=Date();var friendVisitDate=Date()}
struct FightConfiguration:Codable,Hashable,Sendable {var medicineOnce=false;var stoneOnce=false;var medicine:Int?;var stone:Int?}
enum MAATask:Codable,Equatable {case userdataupdate(UserDataUpdateConfiguration),infrast(InfrastConfiguration),mall(MallConfiguration),fight(FightConfiguration)}
struct MAADepot {
 let done:Bool;let items:[String:Int]
 init(done:Bool,items:[String:Int]){self.done=done;self.items=items}
 init?(json:RawDetails,context:String){guard let value=json.depot else{return nil};self=value}
}
struct MAAOperBox {
 let historyPayload:OperBoxHistoryPayload
 init(historyPayload:OperBoxHistoryPayload){self.historyPayload=historyPayload}
 init?(json:RawDetails,context:String){guard let value=json.operators else{return nil};self=MAAOperBox(historyPayload:value)}
}
struct RawDetails {var depot:MAADepot?;var operators:OperBoxHistoryPayload?}
struct RawInfo {let taskchain:String;let taskid:Int32?;let what:String;let details:RawDetails}
@MainActor final class RecognitionPresentation {
 var depot:MAADepot?;var operators:MAAOperBox?
 func setDepot(_ value:MAADepot?){depot=value};func setOperBox(_ value:MAAOperBox?){operators=value}
}
enum MaaCoreError:Error {case appendTaskFailed}
enum FixtureError:Error {case append,stop}
struct PreparationCleanupFailure:Error {}
struct Events {mutating func register(taskID:Int32,runID:UUID){}}
@MainActor final class Core {
 var nativeTypes=[MAATaskType]();var starts=0;var stops=0;var failAppendAt:Int?;var failStop=false
 var onAppend:(()->Void)?
 var running:Bool {get async{false}}
 func appendTask(type:MAATaskType,params:String) async throws->Int32 {
  nativeTypes.append(type);onAppend?()
  if nativeTypes.count==failAppendAt{throw FixtureError.append}
  return Int32(nativeTypes.count)
 }
 func stop() async throws{stops+=1;if failStop{throw FixtureError.stop}}
}
''' + daily + r'''
@MainActor final class MAAViewModel {
 enum TaskStatus:Equatable{case success,failure,cancel,running,skipped}
 enum Status{case idle,busy}
 let dailyRunCoordinator=DailyRunCoordinator()
 var dailyRunOutcome=DailyRunOutcome.completed;var dailyRunChainFailed=false
 var userDataUpdateRun=UserDataUpdateRun();var dailyRunTasks:[DailyTask]?
 var taskIDMap:[Int32:UUID]=[:];var taskStatus:[UUID:TaskStatus]=[:]
 var tasks=[DailyTask]();var dailyTaskProfile="A";let tasksDirectory:URL
 var isApplyingDailyCallbackPatch=false;var achievementEvents=Events()
 var handle:Core?=Core();var messageTask:Task<Void,Never>?;var status=Status.idle
 var inventory=InventorySnapshotAdapter();var operBoxHistoryRevision=UUID()
 var inventoryDepotTaskID:Int32?;var inventoryDepotScope:InventoryScope?;var pendingInventoryDepot:MAADepot?
 var operBoxHistoryTaskID:Int32?;var operBoxHistoryScope:InventoryScope?;var pendingOperBoxHistory:OperBoxHistoryPayload?
 var logStore:RecognitionPresentation?=RecognitionPresentation();var logs=[String]()
 var userDataAccount="account";var connection="adb";var server="CN";var clientChannel=MAAClientChannel.Official
 var yituliuOpenApiToken="";var yituliuOperBoxForDaily=false
 var yituliuSession=URLSession(configuration:.ephemeral);var recruitResourceDirectory:URL?
 struct YituliuDailyTokenEmpty: Error {}
 var inventoryScope:InventoryScope{.init(connection:connection,server:server,profile:dailyTaskProfile,account:userDataAccount)}
 var depotHistoryStore:DepotHistoryStore{.init(directory:tasksDirectory.appendingPathComponent("depot"))}
 var operBoxHistoryStore:OperBoxHistoryStore{.init(directory:tasksDirectory.appendingPathComponent("operators"))}
 init(directory:URL){tasksDirectory=directory}
 func logInfo(_ text:LocalizedStringResource){logs.append(String(localized:text))}
 func logWarn(_ text:LocalizedStringResource){logs.append(String(localized:text))}
 func logError(_ text:LocalizedStringResource){logs.append(String(localized:text))}
 func invalidateInventory(){inventory.invalidate();logStore?.setDepot(nil);logStore?.setOperBox(nil)}
 func startCoreTasks(recordDailyTaskStart:Bool) async throws {handle!.starts+=1}
 // P12.4 识别回填复查钩子（processDailyUserDataTerminal .depot 分支引用）；
 // 真实复查行为由 run-depot-maintain-dispatch-tests.py 专责，此处 no-op 存根。
 func reviewDepotMaintainSkippedPlans(){}
''' + composite + extra + r'''
 func processExtra(_ info:RawInfo){switch info.taskchain{
''' + raw_cases + r'''
 default:break
 }}
 func enqueue(_ runTasks:[DailyTask],runID:UUID) async throws {
  let scope=inventoryScope;var appendedAnyTask=false
  do{
   for task in runTasks {
    try Task.checkCancellation();guard task.enabled else{continue}
''' + enqueue_branch + r'''
   }
''' + submit + catch_block + r'''
 }
}
@main struct Main {
 @MainActor static func main() async throws {
  var checks=0
  func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  func factory(_ config:UserDataUpdateConfiguration=UserDataUpdateConfiguration(),target:String="A",current:String="A",account:String="account") throws ->(MAAViewModel,DailyTask,UUID){
   let folder=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   let m=MAAViewModel(directory:folder);m.dailyTaskProfile=current;m.userDataAccount=account
   let task=DailyTask(task:.userdataupdate(config),enabled:true,runOnce:true)
   m.tasks=[task];m.dailyRunTasks=[task]
   try PropertyListEncoder().encode([task]).write(to:folder.appendingPathComponent(target+".plist"))
   let run=try m.dailyRunCoordinator.begin(profileID:target,origin:.schedule)!
   try m.dailyRunCoordinator.transition(.running,for:run)
   return(m,task,run)
  }
  func saved(_ m:MAAViewModel,_ profile:String="A") throws ->UserDataUpdateConfiguration{
   let list=try PropertyListDecoder().decode([DailyTask].self,from:Data(contentsOf:m.tasksDirectory.appendingPathComponent(profile+".plist")))
   guard case .userdataupdate(let c)=list[0].task else{fatalError()};return c
  }
  let payload=OperBoxHistoryPayload(done:true,allOperators:[.init(id:"amiya",own:true,name:"阿米娅",rarity:5)],ownedOperators:[.init(id:"amiya",own:true,name:"阿米娅",rarity:5,elite:1,level:50,potential:2)])
  func complete(_ m:MAAViewModel,_ id:Int32,_ kind:UserDataKind){
   m.processDailyUserDataTerminal(coreID:id,code:10001,taskchain:kind == .operBox ? "OperBox":"Depot")
   if kind == .operBox{m.processExtra(.init(taskchain:"OperBox",taskid:id,what:"OperBoxInfo",details:.init(operators:payload)))}
   else{m.processExtra(.init(taskchain:"Depot",taskid:id,what:"DepotInfo",details:.init(depot:.init(done:true,items:["30012":7]))))}
   m.processDailyUserDataTerminal(coreID:id,code:10002,taskchain:kind == .operBox ? "OperBox":"Depot")
  }
  let (prepared,preparedTask,preparedRun)=try factory()
  _ = try await prepared.appendDailyUserDataUpdate(task:preparedTask,config:UserDataUpdateConfiguration(),runID:preparedRun,scope:prepared.inventoryScope)
  complete(prepared,1,.operBox)
  check(try saved(prepared).lastOperBoxSync==nil,"Prepared but never submitted chain cannot save a callback receipt")
  check(prepared.logStore?.operators==nil,"Prepared callback cannot update current recognition UI before native submission")

  let (good,task,run)=try factory();try await good.enqueue([task],runID:run)
  check(good.handle!.nativeTypes == [.OperBox,.Depot] && good.handle!.starts==1,"Composite uses two registered chains in reference order and one start")
  complete(good,1,.operBox)
  check(good.taskStatus[task.id] == .running,"First subtask success never turns entire row green")
  let one=try saved(good);check(one.lastOperBoxSync != nil && one.lastDepotSync==nil,"Receipt written only for complete successful kind")
  complete(good,2,.depot)
  check(good.taskStatus[task.id] == .success && good.dailyRunOutcome == .completed,"Both complete subtasks produce success")
  let both=try saved(good);check(both.lastDepotSync?.scope.profile=="A" && both.lastOperBoxSync?.scope.account=="account","Saved receipts retain source profile and account")
  let originalStamp=both.lastDepotSync
  good.processDailyUserDataTerminal(coreID:2,code:10002,taskchain:"Depot")
  check(try saved(good).lastDepotSync==originalStamp,"Duplicate completion cannot rewrite sync time")

  let (foreign,foreignTask,foreignRun)=try factory();try await foreign.enqueue([foreignTask],runID:foreignRun)
  foreign.processExtra(.init(taskchain:"OperBox",taskid:1,what:"UnknownInfo",details:.init(operators:payload)))
  check(foreign.logStore?.operators==nil,"Unrelated extra-info cannot publish recognition data")
  foreign.processExtra(.init(taskchain:"OperBox",taskid:1,what:"OperBoxInfo",details:.init(operators:payload)))
  foreign.processDailyUserDataTerminal(coreID:1,code:10002,taskchain:"Fight")
  check(try saved(foreign).lastOperBoxSync==nil,"Wrong taskchain cannot complete an owned operator ID")
  foreign.processDailyUserDataTerminal(coreID:1,code:10002,taskchain:"OperBox")
  check(try saved(foreign).lastOperBoxSync != nil,"Matching taskchain completes owned recognition")

  let (reordered,reorderTask,reorderRun)=try factory();try await reordered.enqueue([reorderTask],runID:reorderRun)
  reordered.processDailyUserDataTerminal(coreID:1,code:10002,taskchain:"OperBox")
  check(try saved(reordered).lastOperBoxSync==nil,"Terminal callback cannot fabricate missing recognition data")
  reordered.processExtra(.init(taskchain:"OperBox",taskid:1,what:"OperBoxInfo",details:.init(operators:payload)))
  check(try saved(reordered).lastOperBoxSync != nil,"Final payload arriving after terminal joins the same owned completion")
  check(reordered.taskStatus[reorderTask.id] == .running,"Reordered first subtask still waits for the second")
  complete(reordered,2,.depot)
  check(reordered.taskStatus[reorderTask.id] == .success,"Reordered but complete selected subtasks finish successfully")

  let (failed,failedTask,failedRun)=try factory();try await failed.enqueue([failedTask],runID:failedRun)
  complete(failed,1,.operBox);failed.processDailyUserDataTerminal(coreID:2,code:10000,taskchain:"Depot")
  check(failed.taskStatus[failedTask.id] == .failure && failed.dailyRunOutcome == .failed,"Native subtask error fails composite and entire run")
  check(try saved(failed).lastDepotSync==nil,"Failed kind is not premarked")
  failed.updateDailyTaskStatus(.success,coreID:2);failed.processDailyUserDataTerminal(coreID:2,code:10002,taskchain:"Depot")
  check(failed.taskStatus[failedTask.id] == .failure,"Generic or duplicate success cannot erase composite failure")

  let (missing,missingTask,missingRun)=try factory();try await missing.enqueue([missingTask],runID:missingRun)
  _ = missing.receiveDailyDepot(.init(done:false,items:["x":1]),coreID:2)
  missing.processDailyUserDataTerminal(coreID:2,code:10002,taskchain:"Depot")
  check(try missing.taskStatus[missingTask.id] == .running && saved(missing).lastDepotSync==nil,"Native terminal alone does not mark a partial payload successful")
  missing.failIncompleteDailyUserDataUpdates(runID:missingRun)
  check(missing.taskStatus[missingTask.id] == .failure && missing.dailyRunOutcome == .failed,"Incomplete terminal payload fails when callback drain expires")

  let (cancelled,cancelTask,cancelRun)=try factory();try await cancelled.enqueue([cancelTask],runID:cancelRun)
  cancelled.cancelDailyUserDataUpdates();complete(cancelled,1,.operBox);complete(cancelled,2,.depot)
  check(cancelled.taskStatus[cancelTask.id] == .cancel,"Cancelled composite cannot revive from late terminal")
  check(try saved(cancelled).lastOperBoxSync==nil,"Cancelled callback cannot write receipt")

  let (nativeStopped,stopTask,stopRun)=try factory();try await nativeStopped.enqueue([stopTask],runID:stopRun)
  nativeStopped.processDailyUserDataTerminal(coreID:1,code:10004,taskchain:"OperBox")
  check(nativeStopped.taskStatus[stopTask.id] == .cancel && nativeStopped.dailyRunOutcome == .cancelled,"Native stop cancels the composite run")
  check(!nativeStopped.userDataUpdateRun.hasPending(runID:stopRun),"Native stop cancels later unstarted subtasks without timeout-as-failure")
  complete(nativeStopped,2,.depot)
  check(try saved(nativeStopped).lastDepotSync==nil,"Late native completion after stop cannot write receipt")

  let (changed,changeTask,changeRun)=try factory();try await changed.enqueue([changeTask],runID:changeRun);changed.userDataAccount="other"
  complete(changed,1,.operBox)
  check(changed.taskStatus[changeTask.id] == .failure && changed.logStore?.operators==nil,"Changed identity rejects stale raw data and completed chain")
  check(try saved(changed).lastOperBoxSync==nil,"Changed identity cannot advance frequency")

  var due=UserDataUpdateConfiguration();due.triggerInterval = .daily
  let same=InventoryScope(connection:"adb",server:"CN",profile:"A",account:"account")
  due.lastDepotSync = .init(scope:same,completedAt:.now);due.lastOperBoxSync = .init(scope:same,completedAt:.now)
  let (skip,skipTask,skipRun)=try factory(due)
  try skip.depotHistoryStore.save(items:["30012":7],complete:true,scope:same)
  try skip.operBoxHistoryStore.save(payload,scope:same)
  try await skip.enqueue([skipTask],runID:skipRun)
  check(skip.handle!.nativeTypes.isEmpty && skip.handle!.starts==0 && skip.taskStatus[skipTask.id] == .skipped,"Not-due-only queue skips native start entirely")
  let eligible=Set(skip.dailyRunTasks!.filter(\.enabled).map(\.id))
  let afterOnce=DailyRunOnceSemantics.consumeOnceTasks(tasks:[skipTask],outcome:.completed,eligibleIDs:eligible)
  check(afterOnce[0].enabled && afterOnce[0].runOnce,"Interval-skipped task retains runOnce for actual execution")

  var manualPolicy=UserDataUpdateConfiguration();manualPolicy.triggerInterval = .daily
  let (manual,manualTask,manualRun)=try factory(manualPolicy)
  try manual.depotHistoryStore.save(items:["30012":7],complete:true,scope:manual.inventoryScope)
  try await manual.enqueue([manualTask],runID:manualRun)
  check(manual.handle!.nativeTypes == [.OperBox],"Successful same-scope manual Depot recognition counts toward daily interval")
  complete(manual,1,.operBox)
  check(manual.taskStatus[manualTask.id] == .success,"Only due selected kind needs a new native completion")

  var repairPolicy=due;repairPolicy.updateOperBox=false
  let (repair,repairTask,repairRun)=try factory(repairPolicy)
  let repairFile=try repair.depotHistoryStore.fileURL(scope:repair.inventoryScope)
  try FileManager.default.createDirectory(at:repairFile.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data("corrupt".utf8).write(to:repairFile)
  try await repair.enqueue([repairTask],runID:repairRun)
  check(repair.handle!.nativeTypes == [.Depot],"Corrupt cache forces refresh despite a current profile success receipt")
  complete(repair,1,.depot)
  check(try repair.depotHistoryStore.load(scope:repair.inventoryScope)?.items==["30012":7],"Successful repair replaces corrupt history only after completion")

  let (noncurrent,otherTask,otherRun)=try factory(target:"B",current:"A")
  let uiBefore=noncurrent.tasks;try await noncurrent.enqueue([otherTask],runID:otherRun);complete(noncurrent,1,.operBox);complete(noncurrent,2,.depot)
  check(try saved(noncurrent,"B").lastDepotSync?.scope.profile=="B","Scheduled noncurrent profile receipt goes to run journal profile")
  check(noncurrent.tasks==uiBefore && noncurrent.logStore?.depot==nil && noncurrent.logStore?.operators==nil,"Selected same-ID clone and its recognition UI remain untouched")

  let (anonymous,anonTask,anonRun)=try factory(account:"");try await anonymous.enqueue([anonTask],runID:anonRun);complete(anonymous,1,.operBox);complete(anonymous,2,.depot)
  check(anonymous.taskStatus[anonTask.id] == .success && (try saved(anonymous)).lastDepotSync==nil,"Unbound read succeeds without creating reusable account receipt")

  let (partial,partialTask,partialRun)=try factory();let partialCore=partial.handle!;partialCore.failAppendAt=2
  do{try await partial.enqueue([partialTask],runID:partialRun);preconditionFailure("Partial append accepted")}catch{checks+=1}
  check(partialCore.stops==1 && partialCore.starts==0 && partial.taskIDMap.isEmpty,"Second append failure cleans first queued chain even before helper returns")
  complete(partial,1,.operBox)
  check(try saved(partial).lastOperBoxSync==nil,"Never-submitted recognition cannot commit receipt after preparation failure")

  let (drain,drainTask,drainRun)=try factory();try await drain.enqueue([drainTask],runID:drainRun)
  drain.failIncompleteDailyUserDataUpdates(runID:drainRun)
  check(drain.dailyRunOutcome == .failed && drain.taskStatus[drainTask.id] == .failure,"Missing terminal callbacks explicitly fail instead of false completion")
  complete(drain,1,.operBox);check(try saved(drain).lastOperBoxSync==nil,"Missing-callback terminal revokes later writes")

  // MARK: I04-b 日常更新资料一图流源分支

  final class StubYituliuProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:((URLRequest)->(Int,Data))?
    override class func canInit(with request:URLRequest)->Bool{true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
    override func startLoading(){
      let (status,data)=Self.handler!(request)
      let http=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!
      client?.urlProtocol(self,didReceive:http,cacheStoragePolicy:.notAllowed)
      client?.urlProtocol(self,didLoad:data)
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
  }
  func yituliuFactory(config:UserDataUpdateConfiguration,daily:Bool,token:String)->(MAAViewModel,DailyTask,UUID){
    let (m,task,run)=try! factory(config)
    m.yituliuOperBoxForDaily=daily
    m.yituliuOpenApiToken=token
    let res=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
    try! FileManager.default.createDirectory(at:res,withIntermediateDirectories:true)
    try! JSONSerialization.data(withJSONObject:["chars":["char_002_amiya":["name":"阿米娅","rarity":5]]]).write(to:res.appendingPathComponent("battle_data.json"))
    m.recruitResourceDirectory=res
    let stub=URLSessionConfiguration.ephemeral
    stub.protocolClasses=[StubYituliuProtocol.self]
    m.yituliuSession=URLSession(configuration:stub)
    return (m,task,run)
  }
  func yituliuBody(_ code:Int,_ data:[[String:Any]])->Data{
    try! JSONSerialization.data(withJSONObject:["code":code,"msg":"","data":data])
  }
  let operRows:[[String:Any]] = [["id":"char_002_amiya","level":60,"evolvePhase":2,"mainSkillLevel":7,"potentialRank":3] as [String:Any]]

  // token 为空：准入即失败整跑（WPF 同构），不启动 Core。
  do {
    let (m,task,run)=yituliuFactory(config:UserDataUpdateConfiguration(),daily:true,token:"  ")
    do { _ = try await m.appendDailyUserDataUpdate(task:task,config:UserDataUpdateConfiguration(),runID:run,scope:m.inventoryScope); preconditionFailure("Empty token must fail the run") }
    catch is MAAViewModel.YituliuDailyTokenEmpty {}
    catch { preconditionFailure("unexpected \(error)") }
    check(m.handle!.starts==0 && m.taskStatus[task.id] == .failure,"Empty token fails the run without core start")
  }

  // 有效拉取：干员部分不进 Core 队列，快照按 runScope 落盘，条目成功。
  do {
    StubYituliuProtocol.handler={ _ in (200, yituliuBody(200, operRows)) }
    var cfg=UserDataUpdateConfiguration();cfg.updateOperBox=true;cfg.updateDepot=false
    let (m,task,run)=yituliuFactory(config:cfg,daily:true,token:"tok")
    let ids=try await m.appendDailyUserDataUpdate(task:task,config:cfg,runID:run,scope:m.inventoryScope)
    check(ids.isEmpty && m.handle!.starts==0,"Yituliu operbox due appends no core task and starts nothing")
    check(m.taskStatus[task.id] == .success,"Valid yituliu sync marks the entry successful")
    let snapshot=try m.operBoxHistoryStore.load(scope:m.inventoryScope)
    check(snapshot?.operators.ownedOperators.count==1 && snapshot?.operators.ownedOperators[0].potential==3,"Yituliu snapshot persisted under run scope")
    check(try saved(m).lastOperBoxSync==nil,"No core chain means no callback receipt machinery")
  }

  // 未绑定/空数据：条目失败但不中止跑，不写快照。
  do {
    StubYituliuProtocol.handler={ _ in (200, yituliuBody(200, [])) }
    let (m,task,run)=yituliuFactory(config:UserDataUpdateConfiguration(),daily:true,token:"tok")
    _ = try await m.appendDailyUserDataUpdate(task:task,config:UserDataUpdateConfiguration(),runID:run,scope:m.inventoryScope)
    check(m.taskStatus[task.id] == .failure,"NoData marks entry failure without failing the run")
    check(try m.operBoxHistoryStore.load(scope:m.inventoryScope)==nil,"NoData writes no snapshot")
  }

  // token 无效：条目失败不中止跑；writeOnly 同路径。
  do {
    StubYituliuProtocol.handler={ _ in (200, yituliuBody(20027, [])) }
    let (m,task,run)=yituliuFactory(config:UserDataUpdateConfiguration(),daily:true,token:"tok")
    _ = try await m.appendDailyUserDataUpdate(task:task,config:UserDataUpdateConfiguration(),runID:run,scope:m.inventoryScope)
    check(m.taskStatus[task.id] == .failure,"Invalid token marks entry failure without failing the run")
  }

  // 关闭开关：干员识别照常进 Core 队列（回归）。
  do {
    let (m,task,run)=yituliuFactory(config:UserDataUpdateConfiguration(),daily:false,token:"tok")
    let ids=try await m.appendDailyUserDataUpdate(task:task,config:UserDataUpdateConfiguration(),runID:run,scope:m.inventoryScope)
    check(ids.count==2 && m.handle!.nativeTypes==[.OperBox,.Depot],"Mode off keeps core recognition path")
  }

  print("PASS I04-b daily yituliu branch: admission failure, no-core persistence, entry-level failures and mode-off regression")
  print("PASS \(checks) production daily user-data preparation/callback/profile assertions")
 }
}
'''
# Evaluate throwing values outside boolean RHS autoclosures.
probe=probe.replace('check(anonymous.taskStatus[anonTask.id] == .success && (try saved(anonymous)).lastDepotSync==nil,','check(try anonymous.taskStatus[anonTask.id] == .success && saved(anonymous).lastDepotSync==nil,')
with tempfile.TemporaryDirectory(prefix='maa-daily-user-data-') as d:
 p=Path(d);(p/'Probe.swift').write_text(probe)
 cmd=['xcrun','swiftc','-parse-as-library']+[str(root/f) for f in ['MeoAsstMac/Model/InventoryTarget.swift','MeoAsstMac/Utils/HGCalendar.swift','MeoAsstMac/Model/DepotHistoryStore.swift','MeoAsstMac/Model/OperBoxHistoryStore.swift','MeoAsstMac/Model/OperBoxHistoryPayload.swift','MeoAsstMac/Model/YituliuOperBoxService.swift','MeoAsstMac/Model/UserDataUpdateRun.swift','MeoAsstMac/Task Configurations/UserDataUpdateConfiguration.swift','MeoAsstMac/RunHooks/RunContext.swift','MeoAsstMac/RunHooks/DailyRunProfilePatch.swift']]+[str(p/'Probe.swift'),'-o',str(p/'tests')]
 subprocess.run(cmd,check=True);subprocess.run([str(p/'tests')],check=True,timeout=30)
