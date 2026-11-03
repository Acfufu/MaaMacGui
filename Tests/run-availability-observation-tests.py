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
enum CopilotContent { case copilot(URL, CopilotKind, Bool); case invalid }
struct CopilotConfiguration {
 struct Item { var filename: String; var nav_name_override: String?; var is_raid: Bool }
 var filename: String?
 var copilot_list: [Item] = []
 func jsonString() throws -> String { "{}" }
}
struct CopilotContext {
 var config = CopilotConfiguration()
 var category = CopilotCategory.bundled
 var copilotSet: CopilotSet? = CopilotSet()
 var copilotList = [CopilotItem]()
 var content = CopilotContent.copilot(URL(filePath:"/fixture.json"), .regular, false)
}
// P01.2 起生产桥经 CopilotCompiler 编译后才入队;本夹具按同一边界形态
// 提供纯编译器:invalid 内容编译失败,其余产出单个 Copilot 追加项。
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
  case .copilot: return .success([Output(type: .Copilot, config: CopilotConfiguration())])
  }
 }
}
@MainActor final class MAAViewModel: ObservableObject {
 enum Status { case idle, busy, pending }
 @Published var status = Status.idle
 var isTestingHook = false
 var blackflowStartAvailable = false
 @Published var isStartStopInFlight = false
 let dailyRunCoordinator = DailyRunCoordinator()
'''+block(model,r'^    var canStartTasks:')+'\n'+block(model,r'^    var canStopTasks:')+'\n'+block(model,r'^    var activeRun:')+'\n'+block(model,r'^    var lastRunOutcome:')+'\n'+menu_predicates+'''
 var copilotStartCount = 0
 var failCopilotStart = false
 var copilotGate: Gate?
 func startCopilot(tasks: [(type: MAATaskType, params: String)]) async throws {
  copilotStartCount += 1
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
'''+block(bridge,r'^    @MainActor var status:')+'\n'+block(bridge,r'^    @MainActor var canStartTasks:')+'''
 @MainActor init(parent: MAAViewModel) {
  self.parent=parent
'''+subscriptions+'''
 }
'''+copilot_bridge+'''
}
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
  print("RunAvailabilityObservationTests: 17 production assertions passed")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='maa-run-observation-') as directory:
 p=Path(directory);(p/'Probe.swift').write_text(support)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(p/'Probe.swift'),str(root/'MeoAsstMac/RunHooks/RunContext.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
