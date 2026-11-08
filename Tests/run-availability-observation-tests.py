#!/usr/bin/env python3
"""Observe production availability getters/subscriptions and the real run coordinator."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
model=(root/'MeoAsstMac/Model/MAAViewModel.swift').read_text()
bridge=(root/'MeoAsstMac/Model/NewViewModel.swift').read_text()
menu=(root/'MeoAsstMac/Views/TaskButtons.swift').read_text()
def block(source,pattern):
 m=re.search(pattern,source,re.M);assert m,pattern
 a=source.index('{',m.start());d=1;b=a+1
 while d:d+=(source[b]=='{')-(source[b]=='}');b+=1
 return source[m.start():b]
# TO-2: read the real SwiftUI menu predicates (start/stop buttons), not a copy.
disabled=re.findall(r'\.disabled\(([^\n]+)\)',menu)
assert len(disabled)==2,'expected start/stop .disabled predicates in TaskButtons.swift'
menu_predicates='\n'.join(
 ' var menu%sDisabled: Bool { %s }'%(side,predicate.strip().replace('viewModel.',''))
 for side,predicate in zip(('Start','Stop'),disabled))
subscriptions='\n'.join(re.findall(r'        parent\.(?:\$\w+|objectWillChange)\.sink.*?        \.store\(in: &cancellables\)',bridge,re.S))
wiring=re.search(r'^        dailyRunCoordinator\.didChange = .*$',model,re.M)[0]
# TO-4: the production startCopilot bridge verbatim; token semantics preserved.
copilot_bridge=block(bridge,r'^    nonisolated\(nonsending\) func startCopilot\(')
# P14.2: the production dispatch condition matrix verbatim (bridge references it).
copilot_policy=block((root/'MeoAsstMac/Task Configurations/CopilotConfiguration.swift').read_text(),r'^enum CopilotDispatchPolicy')
# P14.2 B3 收编（P14-1-R3 §6 残余记录）：真实 prepareOperBoxAssistFile verbatim
# 注入——assist-ON 桥路径（D1-D5）的断言自本套件起由项目承担，不再独靠复验探针。
assist_prepare=block(bridge,r'^    @MainActor private func prepareOperBoxAssistFile')
support='''import Foundation
import Combine
import Observation
struct DailyTask {}
enum FixtureError: Error { case connection }
@MainActor final class Gate {
 private var continuation: CheckedContinuation<Void, Never>?
 private(set) var entered = false
 func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
 func release() { continuation?.resume(); continuation = nil }
}
enum MAATaskType { case Copilot, SSSCopilot, ParadoxCopilot }
enum CopilotCategory { case bundled, list }
enum CopilotKind { case regular, sss, paradox }
struct CopilotSet { var kind = CopilotKind.regular }
struct CopilotItem { var isOn = true; var url = URL(filePath: "/fixture.json"); var isRaid: Bool? }
enum CopilotContent { case copilot(URL, CopilotKind, Bool); case invalid; case mixedRegularAndSSS }
struct CopilotConfiguration: Encodable {
 struct Item: Codable { var filename: String; var nav_name_override: String?; var is_raid: Bool }
 var filename: String?
 var copilot_list: [Item] = []
 // C11 边界面：P14.1 起 startCopilot 桥按任务类型清写该参数。
 var operbox_data_path: String?
 // P14.2 边界面：条件矩阵读取面（真实 CopilotDispatchPolicy verbatim 注入）。
 var formation = true
 var use_sanity_potion = false
 // B3 收编：桥面 jsonString 编码真实参数面（JSONEncoder 对 nil 可选键整体
 // 省略——「无路径」断言=键不存在；生产键名即属性名，Core 消费面同名）。
 func jsonString() throws -> String { String(data: try JSONEncoder().encode(self), encoding: .utf8)! }
}
struct CopilotContext {
 var config = CopilotConfiguration()
 var category = CopilotCategory.bundled
 // C11 边界面：开关仅作 startCopilot 桥读取面。
 var enableOperBoxAssist = false
 var copilotSet: CopilotSet? = CopilotSet()
 var copilotList = [CopilotItem]()
 var content = CopilotContent.copilot(URL(filePath:"/fixture.json"), .regular, false)
}
// P01.2 起生产桥经 CopilotCompiler 编译后才入队;本夹具按同一边界形态提供
// 纯编译器:invalid 编译失败;.copilot 按成员类型产出单追加项(config 直传);
// .mixedRegularAndSSS 产出 Copilot+SSS 两成员(B3-D2 混合列表面)。
struct MAALog {
 enum LogColor { case error }
 var date: Date; var content: String; var color: LogColor
 init(date: Date, content: String, color: LogColor) { self.date=date; self.content=content; self.color=color }
}
enum CopilotCompiler {
 struct Input { var context: CopilotContext; init(context: CopilotContext) { self.context=context } }
 struct Output { var type: MAATaskType; var config: CopilotConfiguration }
 struct CompileError: Error { var logMessage: String }
 static func compile(_ input: Input) -> Result<[Output], CompileError> {
  switch input.context.content {
  case .invalid: return .failure(CompileError(logMessage: "invalid"))
  case .copilot(_, let kind, _):
   switch kind {
   case .regular: return .success([Output(type: .Copilot, config: input.context.config)])
   case .sss: return .success([Output(type: .SSSCopilot, config: input.context.config)])
   case .paradox: return .success([Output(type: .ParadoxCopilot, config: input.context.config)])
   }
  case .mixedRegularAndSSS:
   return .success([Output(type: .Copilot, config: input.context.config),
                    Output(type: .SSSCopilot, config: input.context.config)])
  }
 }
}
@MainActor final class MAAViewModel: ObservableObject {
 enum Status { case idle, busy, pending }
 @Published var status = Status.idle
 @Published var roguelikeWaitingForCombat = false
 var isTestingHook = false
 var blackflowStartAvailable = false
 @Published var isStartStopInFlight = false
 let dailyRunCoordinator = DailyRunCoordinator()
'''+block(model,r'^    var canStartTasks:')+'\n'+block(model,r'^    var canStopTasks:')+'\n'+block(model,r'^    var activeRun:')+'\n'+block(model,r'^    var lastRunOutcome:')+'\n'+menu_predicates+'''
 var copilotStartCount = 0
 // B3 收编：真实 Store/Export 注入面——scope 为普通存储面（生产为计算属性，
 // 桩世界按 user-data 套件先例直存）；store 按用例注入临时目录。
 var inventoryScope = InventoryScope(connection:"adb",server:"CN",profile:"Default",account:"A")
 var operBoxHistoryStore = OperBoxHistoryStore(directory: URL(fileURLWithPath:"/tmp/maa-availability-fixture"))
 // B3 收编：桥面下发任务捕获面（type/params 供 D/E 断言逐成员核对）。
 var startedTypes: [MAATaskType] = []
 var startedParams: [String] = []
 var failCopilotStart = false
 var copilotGate: Gate?
 func startCopilot(tasks: [(type: MAATaskType, params: String)]) async throws {
  copilotStartCount += 1
  startedTypes = tasks.map(\.type)
  startedParams = tasks.map(\.params)
  if let copilotGate { await copilotGate.wait() }
  if failCopilotStart { throw FixtureError.connection }
 }
 init() {
'''+wiring+'\n}\n}\n'+'''
@Observable final class NewModel {
 private let parent: MAAViewModel
 var copilot = CopilotContext()
 private(set) var copilotStartToken: UUID?
 var logs=[MAALog]()
 func appendLog(_ entry: MAALog) { logs.append(entry) }
 @ObservationIgnored private var cancellables = Set<AnyCancellable>()
'''+block(bridge,r'^    @MainActor var status:')+'\n'+block(bridge,r'^    @MainActor var canStartTasks:')+'\n'+assist_prepare+'''
 @MainActor init(parent: MAAViewModel) {
  self.parent=parent
'''+subscriptions+'''
 }
'''+copilot_bridge+'''
}
'''+copilot_policy+'''
final class Flag: @unchecked Sendable {
 private let lock=NSLock();private var changed=false
 func set() { lock.lock();defer { lock.unlock() };changed=true }
 var value: Bool { lock.lock();defer { lock.unlock() };return changed }
}
@main struct Probe {
 @MainActor static func main() async throws {
  let parent=MAAViewModel();let bridge=NewModel(parent:parent)
  let run=try parent.dailyRunCoordinator.begin(profileID:"A",origin:.manual)!
  precondition(!bridge.canStartTasks)
  precondition(parent.menuStartDisabled,"start menu predicate disables start while a run is active")
  parent.isStartStopInFlight=true
  precondition(parent.menuStopDisabled,"stop menu predicate disables stop while the operation flag is set")
  precondition(!parent.canStopTasks,"stop boundary predicate refuses while the operation flag is set")
  parent.roguelikeWaitingForCombat=true
  precondition(parent.canStopTasks && !parent.menuStopDisabled, "combat wait keeps button and menu stop reachable under admission lock")
  parent.roguelikeWaitingForCombat=false
  parent.isStartStopInFlight=false
  let flag=Flag()
  withObservationTracking { _=bridge.canStartTasks } onChange: { flag.set() }
  _=try parent.dailyRunCoordinator.finish(run,outcome:.completed,cleanupSucceeded:true)
  precondition(bridge.canStartTasks && flag.value)
  precondition(parent.status == .idle && !parent.isStartStopInFlight)
  // P04 入口薄层:runID 归属与终态判别只读转发到协调器。
  precondition(parent.activeRun == nil,"activeRun clears once the terminal is recorded")
  precondition(parent.lastRunOutcome == .completed,"lastRunOutcome exposes the finished run's outcome")
  // P04 Q02:停止键与 stop 路由同源——后置清理期禁停(此刻 stop 只会报错),
  // 运行中(未互斥)可停。谓词文本逐字取自 TaskButtons 的 .disabled。
  let postRun=try parent.dailyRunCoordinator.begin(profileID:"A",origin:.manual)!
  try parent.dailyRunCoordinator.transition(.postHook, for: postRun)
  precondition(!parent.canStopTasks,"stop boundary predicate refuses during post-run cleanup")
  precondition(parent.menuStopDisabled,"stop menu predicate disables stop during post-run cleanup")
  _=try parent.dailyRunCoordinator.finish(postRun,outcome:.cancelled,cleanupSucceeded:true)
  let stopping=try parent.dailyRunCoordinator.begin(profileID:"A",origin:.manual)!
  try parent.dailyRunCoordinator.transition(.running, for: stopping)
  precondition(parent.canStopTasks,"stop boundary predicate allows stopping a running run")
  precondition(!parent.menuStopDisabled,"stop menu predicate allows stop while a run is running")
  _=try parent.dailyRunCoordinator.finish(stopping,outcome:.cancelled,cleanupSucceeded:true)
  // TO-4: invalid/failed/pending emit no token; only success announces one.
  let copilotParent=MAAViewModel();let copilotBridge=NewModel(parent:copilotParent)
  copilotBridge.copilot.content = .invalid
  try! await copilotBridge.startCopilot()
  precondition(copilotBridge.copilotStartToken == nil,"invalid Copilot selection emits no token")
  precondition(copilotParent.copilotStartCount == 0,"invalid Copilot selection never reaches the core boundary")
  copilotBridge.copilot.content = .copilot(URL(filePath:"/fixture.json"), .regular, false)
  copilotParent.failCopilotStart = true
  do { try await copilotBridge.startCopilot() } catch {}
  precondition(copilotBridge.copilotStartToken == nil,"failed Copilot start emits no token")
  copilotParent.failCopilotStart = false
  let copilotGate=Gate(); copilotParent.copilotGate = copilotGate
  let copilotTask = Task { try await copilotBridge.startCopilot() }
  while !copilotGate.entered { await Task.yield() }
  precondition(copilotBridge.copilotStartToken == nil,"pending Copilot start does not announce success")
  copilotGate.release()
  try! await copilotTask.value
  precondition(copilotBridge.copilotStartToken != nil,"successful Copilot start emits a token")
  // P14.2 B3 收编（P14-1-R3 §6 残余记录）：assist-ON 桥路径 D1-D5/E1-E3 直测。
  // 真实桥（verbatim）+真实 CopilotDispatchPolicy（verbatim）+真实
  // prepareOperBoxAssistFile（verbatim）+真实 OperBoxHistoryStore/OperBoxAssistExport
  // （生产文件编译）；M3 类桥接线回归（policy 对而桥回退 P14.1 门控）自此由
  // 项目套件当场捕获，红线不再独靠复验探针。
  func b3Fixture(_ tag: String) -> (MAAViewModel, NewModel, URL, URL) {
   let storeDir = FileManager.default.temporaryDirectory.appending(path: "maa-b3-store-\(tag)-\(UUID().uuidString)")
   let exportDir = FileManager.default.temporaryDirectory.appending(path: "maa-b3-export-\(tag)-\(UUID().uuidString)")
   let parent = MAAViewModel()
   parent.operBoxHistoryStore = OperBoxHistoryStore(directory: storeDir)
   OperBoxAssistExport.overrideDirectory = exportDir
   return (parent, NewModel(parent: parent), storeDir, exportDir)
  }
  func b3Teardown(_ dirs: [URL]) {
   OperBoxAssistExport.overrideDirectory = nil
   for dir in dirs { try? FileManager.default.removeItem(at: dir) }
  }
  func b3SeedUsable(_ parent: MAAViewModel) throws {
   let skilled = OperBoxHistoryPayload.OwnedOperator(
    id: "char_002_amiya", own: true, name: "阿米娅", rarity: 5, elite: 2, level: 80,
    potential: 5, mainSkillLevel: 7, skills: [.init(id: "skchr_amiya_1", level: 3)])
   try parent.operBoxHistoryStore.save(
    OperBoxHistoryPayload(
     done: true,
     allOperators: [.init(id: "char_002_amiya", own: true, name: "阿米娅", rarity: 5)],
     ownedOperators: [skilled]),
    scope: parent.inventoryScope, source: "yituliu")
  }
  // D5（assist 关→无路径）：开关关即全量不写盘不预检,即便快照可用。
  do {
   let (parent, bridge, storeDir, exportDir) = b3Fixture("d5")
   defer { b3Teardown([storeDir, exportDir]) }
   try b3SeedUsable(parent)
   try await bridge.startCopilot()
   precondition(bridge.copilotStartToken != nil,"D5: assist off still starts the copilot")
   precondition(bridge.logs.isEmpty,"D5: assist off reports no error")
   let params = try JSONSerialization.jsonObject(with: Data(parent.startedParams[0].utf8)) as! [String: Any]
   precondition(params["operbox_data_path"] == nil,"D5: assist off carries no assist path")
   precondition(!FileManager.default.fileExists(atPath: exportDir.appending(path: "OperBoxData.json").path),"D5: assist off never writes the assist file")
  }
  // D1（formation 关+可用快照→不阻断无路径）：WPF 同态不预检——桥面即
  // prepare 不被触达（无写盘）。
  do {
   let (parent, bridge, storeDir, exportDir) = b3Fixture("d1")
   defer { b3Teardown([storeDir, exportDir]) }
   try b3SeedUsable(parent)
   bridge.copilot.enableOperBoxAssist = true
   bridge.copilot.config.formation = false
   try await bridge.startCopilot()
   precondition(bridge.copilotStartToken != nil && bridge.logs.isEmpty,"D1: formation off does not block or report")
   let params = try JSONSerialization.jsonObject(with: Data(parent.startedParams[0].utf8)) as! [String: Any]
   precondition(params["operbox_data_path"] == nil,"D1: formation off carries no assist path")
   precondition(!FileManager.default.fileExists(atPath: exportDir.appending(path: "OperBoxData.json").path),"D1: formation off never reaches the real export")
  }
  // D3（formation 关+不可用快照→不阻断不报错）：空 store 不可用,WPF 同态可跑。
  do {
   let (parent, bridge, storeDir, exportDir) = b3Fixture("d3")
   defer { b3Teardown([storeDir, exportDir]) }
   bridge.copilot.enableOperBoxAssist = true
   bridge.copilot.config.formation = false
   try await bridge.startCopilot()
   precondition(bridge.copilotStartToken != nil && bridge.logs.isEmpty,"D3: unusable snapshot with formation off runs without block or error")
   let params = try JSONSerialization.jsonObject(with: Data(parent.startedParams[0].utf8)) as! [String: Any]
   precondition(params["operbox_data_path"] == nil,"D3: unusable snapshot carries no assist path")
  }
  // D4（formation 开+不可用→阻断+真实错误日志）：WPF ValidateStartAsync 同构——
  // 不到 Core 边界、无 token、真实错误文案。
  do {
   let (parent, bridge, storeDir, exportDir) = b3Fixture("d4")
   defer { b3Teardown([storeDir, exportDir]) }
   bridge.copilot.enableOperBoxAssist = true
   try await bridge.startCopilot()
   precondition(
    parent.copilotStartCount == 0 && bridge.copilotStartToken == nil
     && bridge.logs.contains(where: { $0.color == .error && $0.content.contains("一图流干员数据") }),
    "D4: unusable snapshot blocks start with the real error log")
  }
  // D2（formation 开→Copilot 携带、SSS 成员不携带）：真实落盘文件路径逐字下发。
  do {
   let (parent, bridge, storeDir, exportDir) = b3Fixture("d2")
   defer { b3Teardown([storeDir, exportDir]) }
   try b3SeedUsable(parent)
   bridge.copilot.enableOperBoxAssist = true
   bridge.copilot.content = .mixedRegularAndSSS
   try await bridge.startCopilot()
   let assistFile = exportDir.appending(path: "OperBoxData.json")
   precondition(parent.copilotStartCount == 1 && bridge.copilotStartToken != nil,"D2: usable snapshot starts without blocking")
   precondition(parent.startedTypes == [.Copilot, .SSSCopilot],"D2: mixed list keeps member order")
   precondition(FileManager.default.fileExists(atPath: assistFile.path),"D2: real export wrote the assist file")
   let copilotParams = try JSONSerialization.jsonObject(with: Data(parent.startedParams[0].utf8)) as! [String: Any]
   precondition(copilotParams["operbox_data_path"] as? String == assistFile.path(percentEncoded: false),"D2: formation-on Copilot member carries the written assist path")
   let sssParams = try JSONSerialization.jsonObject(with: Data(parent.startedParams[1].utf8)) as! [String: Any]
   precondition(sssParams["operbox_data_path"] == nil,"D2: SSS member never carries the assist path")
  }
  // E1/E2/E3（C06 吃药参数面）：单文件强制 false/列表逐项直传/单文件 SSS 亦强制 false。
  do {
   let (parent, bridge, storeDir, exportDir) = b3Fixture("e1")
   defer { b3Teardown([storeDir, exportDir]) }
   bridge.copilot.config.use_sanity_potion = true
   try await bridge.startCopilot()
   let single = try JSONSerialization.jsonObject(with: Data(parent.startedParams[0].utf8)) as! [String: Any]
   precondition((single["use_sanity_potion"] as? NSNumber)?.boolValue == false,"E1: single-file mode forces use_sanity_potion false")
   let (listParent, listBridge, listStore, listExport) = b3Fixture("e2")
   defer { b3Teardown([listStore, listExport]) }
   listBridge.copilot.category = .list
   listBridge.copilot.config.use_sanity_potion = true
   try await listBridge.startCopilot()
   let list = try JSONSerialization.jsonObject(with: Data(listParent.startedParams[0].utf8)) as! [String: Any]
   precondition((list["use_sanity_potion"] as? NSNumber)?.boolValue == true,"E2: list mode passes the configured use_sanity_potion")
   let (sssParent, sssBridge, sssStore, sssExport) = b3Fixture("e3")
   defer { b3Teardown([sssStore, sssExport]) }
   sssBridge.copilot.content = .copilot(URL(filePath: "/fixture.json"), .sss, false)
   sssBridge.copilot.config.use_sanity_potion = true
   try await sssBridge.startCopilot()
   precondition(sssParent.startedTypes == [.SSSCopilot],"E3: single SSS file compiles to one SSS member")
   let sss = try JSONSerialization.jsonObject(with: Data(sssParent.startedParams[0].utf8)) as! [String: Any]
   precondition((sss["use_sanity_potion"] as? NSNumber)?.boolValue == false,"E3: single-file SSS also forces use_sanity_potion false")
  }
  // TEST-1-R3 low-1 erratum: actual count 37 = legacy 18 + new 19
  // (D5:4/D1:3/D3:2/D4:1/D2:5/E1:1/E2:1/E3:2); the previous hardcoded 40
  // had no consistent basis.
  print("RunAvailabilityObservationTests: 37 production assertions passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='maa-run-observation-') as directory:
 p=Path(directory);(p/'Probe.swift').write_text(support)
 # B3 收编编译面：真实 Store/Export verbatim（与 run-operbox-history-tests.sh/
 # run-copilot-persistence-tests.sh 同款生产文件）。
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',
                 str(root/'MeoAsstMac/Model/InventoryTarget.swift'),
                 str(root/'MeoAsstMac/Model/DepotHistoryStore.swift'),
                 str(root/'MeoAsstMac/Model/OperBoxHistoryStore.swift'),
                 str(root/'MeoAsstMac/Model/OperBoxHistoryPayload.swift'),
                 str(root/'MeoAsstMac/Model/YituliuOperBoxService.swift'),
                 str(root/'MeoAsstMac/Task Configurations/OperBoxAssistExport.swift'),
                 str(root/'MeoAsstMac/RunHooks/RunContext.swift'),str(p/'Probe.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
