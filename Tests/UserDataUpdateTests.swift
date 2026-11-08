import Foundation
protocol MAATaskConfiguration: Codable, Hashable, Sendable { associatedtype Params: Encodable; var params: Params { get } }
extension MAATaskConfiguration { init() {self=try! JSONDecoder().decode(Self.self,from:Data("{}".utf8))} }
enum MAATaskType:String {case UserDataUpdate,DepotMaintain,Depot,OperBox}
enum MAATask {case userdataupdate(UserDataUpdateConfiguration)}
enum MAAClientChannel:CaseIterable {case Official,Bilibili,txwy,YoStarEN,YoStarJP,YoStarKR}
enum MaaCoreError:Error {case appendTaskFailed}
var nativeCalls=[String]()
func AsstAppendTask(_ handle:Int,_ name:String,_ params:String)->Int32{nativeCalls.append(name);return 1}
struct NativeProbe {let handle=1
// NATIVE_APPEND
}
var checks=0
func check(_ value:@autoclosure () -> Bool,_ message:String){checks+=1;precondition(value(),message)}
let config=UserDataUpdateConfiguration()
check(config.updateDepot && config.updateOperBox && config.triggerInterval == .everyTime,"Defaults match reference configuration")
check(config.lastDepotSync==nil && config.lastOperBoxSync==nil,"No fabricated migration timestamps")
let old=try JSONDecoder().decode(UserDataUpdateConfiguration.self,from:Data(#"{"updateDepot":false,"updateOperBox":true,"triggerInterval":"daily"}"#.utf8))
check(!old.updateDepot && old.updateOperBox && old.triggerInterval == .daily,"Reference field names migrate unchanged")
let scope=InventoryScope(connection:"adb",server:"CN",profile:"A",account:"account")
func local(_ year:Int,_ month:Int,_ day:Int,_ hour:Int,_ minute:Int,_ offset:Int)->Date{
 var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:offset*3600)!
 return calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute))!
}
let channels:[(MAAClientChannel,Int)]=[(.Official,8),(.Bilibili,8),(.txwy,8),(.YoStarEN,-7),(.YoStarJP,9),(.YoStarKR,9)]
for (channel,offset) in channels{
 let calendar=channel.calendar
 let saturday=local(2026,10,31,12,0,offset)
 let sundayBefore=local(2026,11,1,3,59,offset)
 let sundayAfter=local(2026,11,1,4,0,offset)
 let receipt=UserDataSyncReceipt(scope:scope,completedAt:saturday)
 check(!UserDataUpdateTriggerInterval.daily.isDue(receipt:receipt,scope:scope,calendar:calendar,at:sundayBefore),"Before 04:00 remains previous server game day")
 check(UserDataUpdateTriggerInterval.daily.isDue(receipt:receipt,scope:scope,calendar:calendar,at:sundayAfter),"04:00 boundary begins new server game day")
 let sunday=local(2026,11,1,12,0,offset)
 let mondayBefore=local(2026,11,2,3,59,offset)
 let mondayAfter=local(2026,11,2,4,0,offset)
 let weekly=UserDataSyncReceipt(scope:scope,completedAt:sunday)
 check(!UserDataUpdateTriggerInterval.weekly.isDue(receipt:weekly,scope:scope,calendar:calendar,at:mondayBefore),"Week does not reset at local midnight")
 check(UserDataUpdateTriggerInterval.weekly.isDue(receipt:weekly,scope:scope,calendar:calendar,at:mondayAfter),"ISO game week resets Monday 04:00")
 let yearReceipt=UserDataSyncReceipt(scope:scope,completedAt:local(2026,12,31,12,0,offset))
 check(!UserDataUpdateTriggerInterval.weekly.isDue(receipt:yearReceipt,scope:scope,calendar:calendar,at:local(2027,1,1,12,0,offset)),"Calendar year change within same ISO week does not refresh")
 check(UserDataUpdateTriggerInterval.weekly.isDue(receipt:yearReceipt,scope:scope,calendar:calendar,at:local(2027,1,4,4,0,offset)),"ISO week-year rollover refreshes")
 for interval in UserDataUpdateTriggerInterval.allCases{
  check(interval.isDue(receipt:nil,scope:scope,calendar:calendar,at:sundayAfter),"No receipt always due")
  check(interval.isDue(receipt:.init(scope:scope,completedAt:sundayAfter.addingTimeInterval(60)),scope:scope,calendar:calendar,at:sundayAfter),"Future receipt cannot suppress refresh after clock rollback")
  check(interval.isDue(receipt:.init(scope:scope,completedAt:Date(timeIntervalSince1970:-1e100)),scope:scope,calendar:calendar,at:sundayAfter),"Malformed extreme timestamps cannot crash calendar math")
  for different in [InventoryScope(connection:"other",server:"CN",profile:"A",account:"account"),InventoryScope(connection:"adb",server:"US",profile:"A",account:"account"),InventoryScope(connection:"adb",server:"CN",profile:"B",account:"account"),InventoryScope(connection:"adb",server:"CN",profile:"A",account:"other")]{
   check(interval.isDue(receipt:receipt,scope:different,calendar:calendar,at:sundayAfter),"Different account/server/connection/profile cannot suppress refresh")
  }
  let unbound=InventoryScope(connection:"adb",server:"CN",profile:"A")
  check(interval.isDue(receipt:.init(scope:unbound,completedAt:sundayAfter),scope:unbound,calendar:calendar,at:sundayAfter),"Unbound identity always refreshes")
 }
 for depot in [false,true]{for operators in [false,true]{
  var selected=config;selected.updateDepot=depot;selected.updateOperBox=operators
  check(selected.dueKinds(scope:scope,calendar:calendar,at:sundayAfter)==(operators ? [.operBox]:[])+(depot ? [.depot]:[]),"Independent selection preserves WPF operator-before-depot order")
  selected.triggerInterval = .daily;selected.lastDepotSync = .init(scope:scope,completedAt:sundayAfter)
  check(selected.dueKinds(scope:scope,calendar:calendar,at:sundayAfter)==(operators ? [.operBox]:[]),"Per-kind success does not suppress other data refresh")
  check(try! JSONDecoder().decode(UserDataUpdateConfiguration.self,from:JSONEncoder().encode(selected))==selected,"JSON roundtrip preserves receipts, scope and preferences")
  check(try! PropertyListDecoder().decode(UserDataUpdateConfiguration.self,from:PropertyListEncoder().encode(selected))==selected,"Plist roundtrip preserves receipts, scope and preferences")
 }}
}
let probe=NativeProbe()
do{_ = try probe.appendTask(type:.UserDataUpdate,params:"{}");preconditionFailure("Composite sent to native")}catch{checks+=1}
check(nativeCalls.isEmpty,"GUI pseudo type never reaches AsstAppendTask")
_ = try probe.appendTask(type:.Depot,params:"{}")
check(nativeCalls==["Depot"],"Registered native task still dispatched")
let run=UUID(),task=UUID()
let owner=UserDataUpdateRun.Owner(runID:run,taskID:task,scope:scope,kind:.operBox)
var tracker=UserDataUpdateRun()
try tracker.register(1,owner:owner);try tracker.register(2,owner:.init(runID:run,taskID:task,scope:scope,kind:.depot))
check(tracker.aggregate(for:task) == .pending,"Composite initially pending")
tracker.finish(1,as:.running);tracker.finish(1,as:.succeeded)
check(tracker.aggregate(for:task) == .running,"First subtask completion does not show whole task success")
tracker.finish(1,as:.running)
check(tracker.entries[1]?.progress == .succeeded,"Late start cannot undo a terminal result")
tracker.finish(2,as:.failed)
check(tracker.aggregate(for:task) == .failed,"Any subtask failure dominates composite")
tracker.finish(2,as:.succeeded)
check(tracker.aggregate(for:task) == .failed,"Late success cannot erase subtask failure")
do{try tracker.register(1,owner:owner);preconditionFailure("Duplicate core ID accepted")}catch{checks+=1}
do{try tracker.register(0,owner:owner);preconditionFailure("Zero core ID accepted")}catch{checks+=1}
do{try tracker.register(3,owner:.init(runID:UUID(),taskID:task,scope:scope,kind:.depot));preconditionFailure("Mixed run registration accepted")}catch{checks+=1}
tracker.reset();try tracker.register(1,owner:owner)
tracker.record(.depot(items:["x":1],complete:true),coreID:1)
check(tracker.entries[1]?.payload == nil,"Wrong data kind cannot poison an owned recognition slot")
tracker.cancelPending();tracker.finish(1,as:.succeeded)
check(tracker.aggregate(for:task) == .cancelled,"Cancelled owner cannot be revived by late success")
tracker.reset();try tracker.register(1,owner:owner);try tracker.register(2,owner:.init(runID:run,taskID:task,scope:scope,kind:.depot));tracker.finish(1,as:.succeeded);tracker.finish(2,as:.succeeded)
check(tracker.aggregate(for:task) == .succeeded,"All selected subtasks must succeed")
check(tracker.hasPending(runID:run)==false,"Completed tracker has no outstanding receipt work")
tracker.reset();try tracker.register(1,owner:owner)
check(!tracker.executionSubmitted && tracker.hasPending(runID:run),"Prepared entries cannot consume callbacks before native submission")
tracker.beginExecution();check(tracker.executionSubmitted,"Submission explicitly opens callback acceptance")
tracker.cancelPending();check(!tracker.executionSubmitted && !tracker.hasPending(runID:run),"Cancellation closes callback acceptance and pending drain")
print("PASS \(checks) user-data configuration/calendar/native-gate/composite assertions")
