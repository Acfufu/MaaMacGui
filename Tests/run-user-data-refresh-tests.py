#!/usr/bin/env python3
"""Run production recognition entry points with a gated Core boundary."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'MeoAsstMac/Model/MAAViewModel.swift').read_text()
def method(signature):
 start=s.index(signature);body=s.index('{',start);depth=0
 for end in range(body,len(s)):
  if s[end]=='{':depth+=1
  elif s[end]=='}':
   depth-=1
   if depth==0:return s[start:end+1].replace('private func','func',1)
 raise RuntimeError(signature)
methods='\n'.join(method('    '+sig) for sig in ['func recognizeDepot()','func refreshUserData()','private func recognizeUserData(','func recognizeOperBox()','func invalidateInventory()'])
probe=r'''
import Foundation
@MainActor final class Gate {
 var entered=false
 var continuation:CheckedContinuation<Void,Never>?
 func wait() async {entered=true;await withCheckedContinuation {continuation=$0}}
 func release(){continuation?.resume();continuation=nil}
}
enum MAATaskType:String {case Depot,OperBox}
enum MaaCoreError:Error {case appendTaskFailed}
enum FixtureError:Error {case busy,append,start,stop}
struct PreparationCleanupFailure:Error {}
struct Events {mutating func register(taskID:Int32,type:String){}}
struct RecognitionStore {func setDepot(_ value:Int?){};func setOperBox(_ value:Int?){}}
@MainActor final class Core {
 var types=[MAATaskType]();var starts=0;var stops=0
 var failAppend:Int?;var failStart=false;var failStop=false
 var appendGate:Gate?;var onAppend:(() -> Void)?
 func appendTask(type:MAATaskType,params:String) async throws -> Int32 {
  types.append(type)
  if let gate=appendGate {appendGate=nil;await gate.wait()}
  onAppend?()
  if types.count==failAppend {throw FixtureError.append}
  return Int32(types.count)
 }
 func stop() async throws {stops+=1;if failStop {throw FixtureError.stop}}
}
@MainActor final class MAAViewModel {
 enum Status {case idle,pending,busy}
 var status=Status.idle;var isStartStopInFlight=false
 var handle:Core?=Core();var messageTask:Task<Void,Never>?
 var inventory=InventorySnapshotAdapter()
 var inventoryScope=InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"A")
 var inventoryDepotTaskID:Int32?;var inventoryDepotScope:InventoryScope?;var pendingInventoryDepot:Int?
 var operBoxHistoryTaskID:Int32?;var operBoxHistoryScope:InventoryScope?;var pendingOperBoxHistory:Int?
 var logStore:RecognitionStore?
 var achievementEvents=Events();var ensureGate:Gate?
 func beginTaskOperation() async throws {
  guard status == .idle && !isStartStopInFlight else {throw FixtureError.busy}
  isStartStopInFlight=true
 }
 func ensureHandle() async throws {if let gate=ensureGate {await gate.wait()}}
 func handleEarlyReturn(backTo value:Status){if status == .pending {status=value}}
 func startCoreTasks() async throws {
  guard let handle else {throw MaaCoreError.appendTaskFailed}
  if handle.failStart {throw FixtureError.start}
  handle.starts+=1;status = .busy
 }
''' + methods + r'''
}
@main struct Main {
 @MainActor static func main() async throws {
  var checks=0
  func check(_ value:Bool,_ message:String){checks+=1;precondition(value,message)}
  func entered(_ gate:Gate) async {
   for _ in 0..<10000 {if gate.entered{return};await Task.yield()}
   fatalError("gate not reached")
  }
  let good=MAAViewModel();try await good.refreshUserData()
  check(good.handle!.types == [.Depot,.OperBox],"Refresh order uses registered Core names")
  check(good.handle!.starts==1 && good.status == .busy,"Two chains start once")
  check(!good.isStartStopInFlight,"Successful refresh releases reservation")
  check(good.inventoryDepotTaskID==1 && good.operBoxHistoryTaskID==2,"Both recognition tasks owned")
  check(good.inventoryDepotScope==good.inventoryScope && good.operBoxHistoryScope==good.inventoryScope,"Both scopes frozen to same identity")
  for includeDepot in [true,false] {
   let model=MAAViewModel()
   if includeDepot {try await model.recognizeDepot()}else{try await model.recognizeOperBox()}
   check(model.handle!.types == (includeDepot ? [.Depot]:[.OperBox]),"Single recognition preserves standalone entry")
   check(model.handle!.starts==1,"Standalone starts once")
  }
  let fail=MAAViewModel();let failCore=fail.handle!;failCore.failAppend=2
  do{try await fail.refreshUserData();preconditionFailure("append failure accepted")}catch{checks+=1}
  check(failCore.starts==0 && failCore.stops==1,"Failed second append clears queued first task without starting")
  check(fail.inventoryDepotTaskID==nil && fail.operBoxHistoryTaskID==nil,"Failed preparation drops both task owners")
  check(!fail.isStartStopInFlight && fail.status == .idle,"Failed preparation releases UI")
  let startFail=MAAViewModel();let startCore=startFail.handle!;startCore.failStart=true
  do{try await startFail.refreshUserData();preconditionFailure("start failure accepted")}catch{checks+=1}
  check(startCore.stops==1 && startFail.status == .idle,"Failed native start cleans queued recognition")
  let quarantine=MAAViewModel();let quarantined=quarantine.handle!;quarantined.failAppend=2;quarantined.failStop=true
  do{try await quarantine.refreshUserData();preconditionFailure("cleanup failure accepted")}catch is PreparationCleanupFailure{checks+=1}
  check(quarantine.handle==nil,"Failed cleanup quarantines Core")
  let switched=MAAViewModel();let switchedCore=switched.handle!
  switchedCore.onAppend={switched.inventoryScope=InventoryScope(connection:"other",server:"CN",profile:"Default",account:"B")}
  do{try await switched.refreshUserData();preconditionFailure("scope switch accepted")}catch InventoryTargetError.stalePreparation{checks+=1}
  check(switchedCore.starts==0 && switchedCore.stops==1,"Scope switch before start clears staged tasks")
  let cancelled=MAAViewModel();let cancelledCore=cancelled.handle!;let gate=Gate();cancelledCore.appendGate=gate
  let task=Task{try await cancelled.refreshUserData()};await entered(gate);task.cancel();gate.release()
  do{try await task.value;preconditionFailure("cancelled refresh accepted")}catch is CancellationError{checks+=1}
  check(cancelledCore.starts==0 && cancelledCore.stops==1,"Cancellation after append cannot start staged chain")
  check(!cancelled.isStartStopInFlight,"Cancellation releases reservation")
  let duplicate=MAAViewModel();let duplicateGate=Gate();duplicate.handle!.appendGate=duplicateGate
  let first=Task{try await duplicate.refreshUserData()};await entered(duplicateGate)
  do{try await duplicate.refreshUserData();preconditionFailure("duplicate accepted")}catch FixtureError.busy{checks+=1}
  duplicateGate.release();try await first.value
  check(duplicate.handle!.starts==1 && duplicate.handle!.types.count==2,"Duplicate request cannot double append or start")
  let missing=MAAViewModel();missing.handle=nil
  do{try await missing.refreshUserData();preconditionFailure("missing core accepted")}catch MaaCoreError.appendTaskFailed{checks+=1}
  check(missing.status == .idle && !missing.isStartStopInFlight,"Missing Core reports failure and releases UI")
  let connecting=MAAViewModel();let connectionGate=Gate();connecting.ensureGate=connectionGate
  let connectionTask=Task{try await connecting.refreshUserData()};await entered(connectionGate)
  connecting.inventoryScope=InventoryScope(connection:"adb",server:"US",profile:"Default",account:"A");connectionGate.release()
  do{try await connectionTask.value;preconditionFailure("connection scope changed")}catch InventoryTargetError.stalePreparation{checks+=1}
  check(connecting.handle!.types.isEmpty,"Identity change during connection refuses before any append")
  print("PASS \(checks) production user-data refresh assertions")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='maa-data-refresh-') as d:
 p=Path(d);(p/'Probe.swift').write_text(probe)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'MeoAsstMac/Model/InventoryTarget.swift'),str(p/'Probe.swift'),'-o',str(p/'tests')],check=True)
 subprocess.run([str(p/'tests')],check=True,timeout=30)
