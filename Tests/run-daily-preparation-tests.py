#!/usr/bin/env python3
"""Exercise production preparation/lifecycle across async Core boundaries; no game or app container."""
from pathlib import Path
import os,re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source_root=Path(os.environ.get('MAA_TEST_SOURCE_ROOT',root))
model=(source_root/'MeoAsstMac/Model/MAAViewModel.swift').read_text()
# P12.3 库存保持拦截块由 run-depot-maintain-dispatch-tests.py 专责覆盖，本套件剥离
#（提取面纪律：剥离必须有断言，防锚点漂移后静默空转）。
_strip_pattern = r'\n *if case \.depotMaintain\(let depotConfig\) = task\.task \{\n(?:.*?\n)*? *\}\n'
assert len(re.findall(_strip_pattern, model, re.M)) == 1, 'depotMaintain interception block drifted'
model = re.sub(_strip_pattern, '\n', model, count=1)
# P22/S16 时长上限武装（armDurationLimit）属收尾动作域，由 post-action 套件覆盖；
# 本套件生命周期面不含该调用，剥离并 fail-loudly。
_p22_arm = r'\n *// P22/S16: 启动成功后武装运行时长上限计时。\n *armDurationLimit\(runID: runID\)\n'
assert len(re.findall(_p22_arm, model, re.M)) == 1, 'P22 armDurationLimit call drifted'
model = re.sub(_p22_arm, '\n', model, count=1)
# P25 停滞武装（externalStallMonitor.arm）属通知域，由 trigger 套件覆盖；剥离并 fail-loudly。
_p25_arm = r'\n *// P25/E05: 停滞检测武装（开关关或分钟为 0 时不监控）。\n *if notifyStallTimeoutEnabled \{\n(?:.*?\n)*? *(?:self\?\.)?notifyExternalStalled\(initialMinutes: initial, accumulatedMinutes: accumulated\)\n *\}\n *\}\n'
assert len(re.findall(_p25_arm, model, re.M)) == 1, 'P25 stall arm block drifted'
model = re.sub(_p25_arm, '\n', model, count=1)

message=(source_root/'MeoAsstMac/Core/MaaMessage.swift').read_text()
def declaration(source,pattern):
 match=re.search(pattern,source,re.M);assert match,pattern
 start=source.index('{',match.start());depth=1;end=start+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[match.start():end]
parts=[declaration(model,r'^    enum Status:'),declaration(model,r'^    enum TaskStartResult:')]
for pattern in [r'^    private var dailyCompletionTask: .*$', r'^    private var dailyFinishAttemptedRunID: .*$', r'^    @Published private\(set\) var status = .*$',r'^    @Published private\(set\) var isStartStopInFlight = .*$',r'^    private var taskCompletionGeneration = .*$', r'^    @Published var activeRunHasRoguelike = .*$',
 r'^    @Published var roguelikeInCombat = .*$', r'^    @Published var roguelikeWaitingForCombat = .*$',
 r'^    private var roguelikeCombatWaitAborted = .*$']:
 parts.append(re.search(pattern,model,re.M)[0])
for name in ['canStartTasks','canStopTasks','beginTaskOperation','handleEarlyReturn','startCoreTasks','startDailyTasks','startTasks','stop','finishDailyRunIfStopped','reconcileDailyRunStatus','discardPreparedDailyTasks','resetStatus','waitForDailyRunCompletion','forceRecoveryEligibility','requestStopRun','requestDailyRun','miniGame','prepareForTermination']:
 pattern=rf'^    (?:private )?(?:func|var) {name}\b'
 if re.search(pattern,model,re.M):parts.append(declaration(model,pattern))
# P04 入口边界成员是本套件的断言对象,缺失即红,不允许静默跳过。
for name in ['requestStopRun','requestDailyRun','miniGame']:
 assert re.search(rf'^    (?:private )?(?:func|var) {name}\b',model,re.M), f'P04 entry boundary member {name} missing from MAAViewModel.swift'
for name in ['dailyTask','taskID','updateRoguelikeCombat']:parts.append(declaration(message,rf'^    (?:private )?func {name}\('))
support=(root/'Tests/DailyPreparationTestSupport.swift').read_text().replace('// PRODUCTION_MODEL_MEMBERS','\n'.join(parts)).replace('// PRODUCTION_CORE_RUNNING_GUARD',declaration(model,r'^        guard await handle\?\.running == false else'))
tasks=(source_root/'MeoAsstMac/Model/MAATask.swift').read_text()
support+='\nextension Array where Element == DailyTask {\n'+declaration(tasks,r'^    subscript\(_ id: UUID\)')+'\n'+declaration(tasks,r'^    func firstIndex\(id: UUID\)')+'\n}\n'
with tempfile.TemporaryDirectory(prefix='maa-daily-preparation-') as directory:
 path=Path(directory);(path/'Support.swift').write_text(support)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(path/'Support.swift'),str(source_root/'MeoAsstMac/RunHooks/RunContext.swift'),str(source_root/'MeoAsstMac/Model/MAAError.swift'),str(source_root/'MeoAsstMac/Task Configurations/InfrastConfiguration.swift'),str(source_root/'MeoAsstMac/Model/MAAInfrast.swift'),str(root/'Tests/DailyPreparationTests.swift'),'-o',str(path/'tests')],check=True)
 subprocess.run([str(path/'tests')],check=True,timeout=30)
 deadline = 'ContinuousClock.now.advanced(by: .seconds(600))'
 assert support.count(deadline) == 1, 'production combat timeout extraction drifted'
 (path/'Support.swift').write_text(support.replace(deadline, 'ContinuousClock.now.advanced(by: .milliseconds(50))'))
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(path/'Support.swift'),str(source_root/'MeoAsstMac/RunHooks/RunContext.swift'),str(source_root/'MeoAsstMac/Model/MAAError.swift'),str(source_root/'MeoAsstMac/Task Configurations/InfrastConfiguration.swift'),str(source_root/'MeoAsstMac/Model/MAAInfrast.swift'),str(root/'Tests/DailyPreparationTests.swift'),'-o',str(path/'timeout-tests')],check=True)
 subprocess.run([str(path/'timeout-tests'),'--accelerated-combat-timeout'],check=True,timeout=5)
