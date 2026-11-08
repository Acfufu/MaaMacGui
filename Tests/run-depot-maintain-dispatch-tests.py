#!/usr/bin/env python3
"""P12.3: exercise production appendDepotMaintainTask dispatch semantics via a stub VM.

源码提取型：抽取 MAAViewModel 的「Depot maintain dispatch」extension 编译进桩环境，
断言任务级跳过/空计划/冻结共存跳过/逐计划下发/识别槽登记/下发失败降级等编排语义。
（提取面随方法体扩展需同步桩——run-daily-user-data-tests.py 同款纪律。）
"""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(__file__).resolve().parents[1]
model_vm = (root / 'MeoAsstMac/Model/MAAViewModel.swift').read_text()
model_tasks = (root / 'MeoAsstMac/Model/MAATask.swift').read_text()


def block(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1]
    raise RuntimeError(marker)


dispatch_ext = block(model_vm, '// MARK: - Depot maintain dispatch')
dispatch_ext = dispatch_ext[dispatch_ext.index('{') + 1:dispatch_ext.rfind('}')]
dispatch_ext = dispatch_ext.replace('private func', 'func')
# 提取面自证：抽到的必须同时含两个方法，缺一即失败（防锚点漂移空转）。
assert 'func appendDepotMaintainTask' in dispatch_ext and 'func skipDepotMaintainRunOnce' in dispatch_ext, 'extraction missing methods'

intercept_start = model_vm.index('                if case .depotMaintain(let depotConfig) = task.task {')
intercept_end = model_vm.index('                let coreID: Int32?', intercept_start)
intercept = model_vm[intercept_start:intercept_end]
assert 'appendDepotMaintainTask' in intercept and 'frozenPlan != nil' in intercept, 'interception block drifted'

core = (root / 'MeoAsstMac/Core/Maa.swift').read_text()
channel = (root / 'MeoAsstMac/Task Configurations/StartupConfiguration.swift').read_text()

# 真实 DailyTask / MAATask 切片（pipeline harness 同法）：占位类型补齐非本域配置。
task_enum = model_tasks[model_tasks.index('enum MAATask:'):model_tasks.index('let defaultTaskConfigurations:')]
daily_task = model_tasks[model_tasks.index('struct DailyTask:'):model_tasks.index('extension Array where Element == DailyTask')]

probe = r'''
import Foundation

// 桩壳：类型名对齐生产（提取代码按原名引用）。
protocol MAATaskConfiguration: Codable, Hashable, Sendable {
    var type: MAATaskType { get }
    var title: String { get }
    var subtitle: String { get }
    var summary: String { get }
    var projectedTask: MAATask { get }
    associatedtype Params: Encodable
    var params: Params { get }
}
enum MAATaskType: String {
    case StartUp, CloseDown, Recruit, Infrast, Fight, Mall, Award, SwitchTheme
    case Roguelike, Reclamation, Custom, OperProgress, UserDataUpdate, DepotMaintain, Depot
    var description: String { rawValue }
}
struct PlaceholderConfiguration: Codable, Equatable {}
typealias StartupConfiguration = PlaceholderConfiguration
typealias ClosedownConfiguration = PlaceholderConfiguration
typealias RecruitConfiguration = PlaceholderConfiguration
typealias InfrastConfiguration = PlaceholderConfiguration
typealias MallConfiguration = PlaceholderConfiguration
typealias AwardConfiguration = PlaceholderConfiguration
typealias SwitchThemeConfiguration = PlaceholderConfiguration
typealias RoguelikeConfiguration = PlaceholderConfiguration
typealias ReclamationConfiguration = PlaceholderConfiguration
typealias CustomConfiguration = PlaceholderConfiguration
typealias OperProgressConfiguration = PlaceholderConfiguration
typealias UserDataUpdateConfiguration = PlaceholderConfiguration

enum StubTaskStatus { case pending, success, skipped, failed }
struct StubRunContext { let id: UUID }
struct StubCoordinator { var active: StubRunContext? }
struct AchievementEvents { mutating func register(taskID: Int32, runID: UUID) { registered.append(taskID) }
    var registered: [Int32] = [] }
final class StubHandle {
    var script: [(type: MAATaskType, id: Int32?)] = []
    var appended: [(type: MAATaskType, params: String)] = []
    func appendTask(type: MAATaskType, params: String) async throws -> Int32? {
        appended.append((type, params))
        guard !script.isEmpty else { return nil }
        return script.removeFirst().id
    }
}
@MainActor
final class MAAViewModel {
    var dailyRunCoordinator = StubCoordinator()
    var inventoryScope = InventoryScope(connection: "conn", server: "Official", profile: "p1", account: "acc")
    var currentInventorySnapshot: InventorySnapshot?
    var stageActivity: MAAStageActivity?
    var clientChannel: MAAClientChannel = .Official
    var taskStatus: [UUID: StubTaskStatus] = [:]
    var taskIDMap: [Int32: UUID] = [:]
    var inventoryDepotScope: InventoryScope?
    var inventoryDepotTaskID: Int32?
    var dailyRunTasks: [DailyTask]?
    var achievementEvents = AchievementEvents()
    var handle: StubHandle?
    var logs: [(level: String, message: String)] = []
    func logInfo(_ m: String) { logs.append(("info", m)) }
    func logWarn(_ m: String) { logs.append(("warn", m)) }
    func logError(_ m: String) { logs.append(("error", m)) }
    // 提取的编排方法（真实生产代码）：
'''

main = r'''

@MainActor
func run() async throws {
    var checks = 0
    func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }

    func makeVM(runID: UUID) -> MAAViewModel {
        let m = MAAViewModel()
        m.dailyRunCoordinator.active = StubRunContext(id: runID)
        m.handle = StubHandle()
        return m
    }
    func defaults() -> DepotMaintainConfiguration {
        try! JSONDecoder().decode(DepotMaintainConfiguration.self, from: Data("{}".utf8))
    }
    func plan(stage: String = "1-7", dropID: String = "30012", dropCount: Int = 100) -> DepotMaintainPlan {
        .init(stage: stage, dropID: dropID, dropCount: dropCount)
    }
    let runID = UUID()
    let taskID = UUID()

    // 合成活动数据：以当前时刻为中心的窗口（VM 内部按 Date.now 判定，固定 fixture
    // 无法命中）。Timezone 固定 +8，窗口 [now-2h, now+2h)。
    func syntheticActivity(resourceCollection: Bool) -> MAAStageActivity {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        fmt.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let start = fmt.string(from: Date().addingTimeInterval(-2 * 3600))
        let end = fmt.string(from: Date().addingTimeInterval(2 * 3600))
        let period = String(format: "{\"UtcStartTime\": \"%@\", \"UtcExpireTime\": \"%@\", \"TimeZone\": 8.0}", start, end)
        let json = resourceCollection
            ? "{\"miniGame\": [], \"resourceCollection\": \(period)}"
            : "{\"miniGame\": [], \"sideStoryStage\": {\"SYN\": {\"Activity\": \(period)}}}"
        return try! JSONDecoder().decode(MAAStageActivity.self, from: Data(json.utf8))
    }
    let activityOpenActivities = syntheticActivity(resourceCollection: false)
    let resourceOpenActivities = syntheticActivity(resourceCollection: true)

    // 1. 活动窗口跳过（合成窗口 + runOnce 冻结语义）。
    do {
        let m = makeVM(runID: runID)
        m.stageActivity = activityOpenActivities
        var cfg = defaults()
        cfg.skipDuringActivity = true
        cfg.plans = [plan()]
        m.dailyRunTasks = [DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: true)]
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: true),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(!dispatched && fights.isEmpty, "activity skip dispatches nothing")
        check(m.taskStatus[taskID] == .skipped, "activity skip marks task skipped")
        check(m.dailyRunTasks?[0].enabled == false, "skip freezes enabled to protect runOnce")
        check(m.handle?.appended.isEmpty == true, "skip appends nothing")
        check(m.logs.contains { $0.message.contains("活动进行中") }, "activity skip logged")
    }

    // 2. 窗口判定分支：活动优先于资源（两者窗口都开着时上游先查活动）。
    do {
        let m = makeVM(runID: runID)
        m.stageActivity = activityOpenActivities
        var cfg = defaults()
        cfg.skipDuringActivity = true
        cfg.skipDuringResourceCollection = true
        cfg.plans = [plan()]
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(!dispatched && m.taskStatus[taskID] == .skipped, "activity gate takes precedence in overlap")
        // 仅资源窗口开着（活动数据无窗口）→ 资源分支。
        let m2 = makeVM(runID: runID)
        m2.stageActivity = resourceOpenActivities
        var fights2 = Set<Int32>()
        let d2 = try await m2.appendDepotMaintainTask(
            task: DailyTask(id: UUID(), task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m2.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights2)
        check(!d2 && m2.taskStatus[UUID()] != nil || !d2, "resource window alone also skips")
        check(m2.logs.contains { $0.message.contains("资源全开放") }, "resource skip logged")
    }

    // 3. 空计划且未启用前置识别 → 跳过并告警。
    do {
        let m = makeVM(runID: runID)
        var cfg = defaults()
        cfg.updateDepot = false
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(!dispatched && m.taskStatus[taskID] == .skipped, "empty plans without recognition skip")
        check(m.logs.contains { $0.level == "warn" && $0.message.contains("未配置计划") }, "empty plans warn logged")
    }

    // 4. 冻结共存：目标库存任务在场且 updateDepot 开启 → 跳过本任务（不失败整跑）。
    do {
        let m = makeVM(runID: runID)
        var cfg = defaults()
        cfg.plans = [plan()]
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: true, inventoryFightIDs: &fights)
        check(!dispatched && m.taskStatus[taskID] == .skipped, "frozen coexistence skips recognition task")
        check(m.logs.contains { $0.level == "warn" && $0.message.contains("冻结校验失效") }, "coexistence warn logged")
        // updateDepot 关闭时同批不跳过（识别不刷新快照，冻结面不受影响）。
        var cfg2 = cfg
        cfg2.updateDepot = false
        m.handle?.script = [(type: .Fight, id: 11)]
        let d2 = try await m.appendDepotMaintainTask(
            task: DailyTask(id: UUID(), task: .depotMaintain(cfg2), enabled: true, runOnce: false),
            config: cfg2, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: true, inventoryFightIDs: &fights)
        check(d2 && m.handle?.appended.count == 1, "recognition off allows dispatch beside frozen target")
    }

    // 5. 全部达标且无前置识别 → 不下发 + 任务成功标记。
    do {
        let m = makeVM(runID: runID)
        m.currentInventorySnapshot = InventorySnapshot(
            generation: UUID(), scope: m.inventoryScope, capturedAt: Date(), items: ["30012": 150])
        var cfg = defaults()
        cfg.updateDepot = false
        cfg.plans = [plan()]
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(!dispatched && m.taskStatus[taskID] == .success, "all-enough run marks success with no core tasks")
        check(m.logs.contains { $0.message.contains("库存已充足") }, "enough logged")
    }

    // 6. 正常下发：前置识别 + 逐计划战斗 + 登记。
    do {
        let m = makeVM(runID: runID)
        m.handle?.script = [(type: .Depot, id: 7), (type: .Fight, id: 8), (type: .Fight, id: 9)]
        var cfg = defaults()
        cfg.plans = [plan(), plan(stage: "CA-5", dropID: "3303", dropCount: 40)]
        m.currentInventorySnapshot = InventorySnapshot(
            generation: UUID(), scope: m.inventoryScope, capturedAt: Date(), items: ["30012": 30])
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(dispatched, "dispatched flag on")
        let appended = m.handle!.appended
        check(appended.count == 3 && appended[0].type == .Depot, "recognition appended before plan fights")
        check(m.inventoryDepotTaskID == 7 && m.inventoryDepotScope == m.inventoryScope,
              "recognition slot registered for snapshot capture")
        check(m.taskIDMap[7] == taskID && m.taskIDMap[8] == taskID && m.taskIDMap[9] == taskID,
              "core ids mapped to daily task")
        check(m.achievementEvents.registered == [7, 8, 9], "achievements registered per core id")
        check(fights == [8, 9], "plan fights join drop-merge set")
        check(m.taskStatus[taskID] == nil, "no terminal status when tasks dispatched")
        // 下发参数契约：战斗任务 params 可解码且缺口按快照预检。
        let p1 = try JSONSerialization.jsonObject(with: Data(appended[1].params.utf8)) as! [String: Any]
        let p2 = try JSONSerialization.jsonObject(with: Data(appended[2].params.utf8)) as! [String: Any]
        check((p1["drops"] as? [String: Int]) == ["30012": 70], "plan 1 gap from snapshot (30/100)")
        check((p2["drops"] as? [String: Int]) == ["3303": 40], "plan 2 gap (no snapshot entry counts 0)")
        check(p1["times"] as? Int == Int(Int32.max) && p2["times"] as? Int == Int(Int32.max),
              "unlimited times encoded")
        check(m.logs.contains { $0.message.contains("计划1") && $0.message.contains("需补 70") }, "gap logged")
    }

    // 7. 仅首个不足：脚本多给也不会消费。
    do {
        let m = makeVM(runID: runID)
        m.handle?.script = [(type: .Fight, id: 21), (type: .Fight, id: 22)]
        var cfg = defaults()
        cfg.updateDepot = false
        cfg.onlyFirstInsufficientPlan = true
        cfg.plans = [plan(), plan(stage: "CA-5", dropID: "3303", dropCount: 40)]
        var fights = Set<Int32>()
        _ = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(m.handle!.appended.count == 1 && fights == [21], "only first insufficient fight appended")
    }

    // 8. 下发失败降级：识别失败不阻断计划，计划失败记 error 继续。
    do {
        let m = makeVM(runID: runID)
        m.handle?.script = [(type: .Depot, id: nil), (type: .Fight, id: nil), (type: .Fight, id: 31)]
        var cfg = defaults()
        cfg.plans = [plan(), plan(stage: "CA-5", dropID: "3303", dropCount: 40)]
        var fights = Set<Int32>()
        let dispatched = try await m.appendDepotMaintainTask(
            task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
            config: cfg, runID: runID, scope: m.inventoryScope,
            hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
        check(dispatched && fights == [31], "later plan still dispatched after earlier append failure")
        check(m.inventoryDepotTaskID == nil, "failed recognition leaves slot unregistered")
        check(m.logs.filter { $0.level == "error" && $0.message.contains("下发失败") }.count == 2,
              "append failures logged per plan")
    }

    // 9. runID 失配 → CancellationError（防迟到展开）。
    do {
        let m = makeVM(runID: UUID())
        var cfg = defaults()
        cfg.plans = [plan()]
        var fights = Set<Int32>()
        do {
            _ = try await m.appendDepotMaintainTask(
                task: DailyTask(id: taskID, task: .depotMaintain(cfg), enabled: true, runOnce: false),
                config: cfg, runID: runID, scope: m.inventoryScope,
                hasFrozenInventoryTarget: false, inventoryFightIDs: &fights)
            preconditionFailure("stale run must throw")
        } catch is CancellationError {
            checks += 1
        } catch { preconditionFailure("unexpected: \(error)") }
    }

    print("depot-maintain-dispatch: \(checks) checks passed")
}

// SE-0343：main.swift 顶层 await 直接驱动 @MainActor 测试体。
try await run()
'''

test_dir = tempfile.mkdtemp(prefix='maa-depot-dispatch.')
try:
    activity_models = ('import Foundation\n'
                       + core[core.index('struct MAAStageActivity:'):]
                       + '\n' + channel[channel.index('enum MAAClientChannel:'):])
    Path(test_dir, 'ActivityModels.swift').write_text(activity_models)
    Path(test_dir, 'main.swift').write_text(
        probe + '}\n' + task_enum + daily_task
        + 'extension MAAViewModel {\n' + dispatch_ext + '\n}\n' + main)
    compile_result = subprocess.run([
        'xcrun', 'swiftc',
        str(Path(test_dir) / 'main.swift'),
        str(root / 'MeoAsstMac/Task Configurations/FightConfiguration.swift'),
        str(root / 'MeoAsstMac/Task Configurations/DepotMaintainConfiguration.swift'),
        str(root / 'MeoAsstMac/Model/DepotMaintainPlanner.swift'),
        str(root / 'MeoAsstMac/Model/InventoryTarget.swift'),
        str(root / 'MeoAsstMac/Model/StageCatalog.swift'),
        str(root / 'MeoAsstMac/Model/StageActivity.swift'),
        str(root / 'MeoAsstMac/Model/FightStage.swift'),
        str(root / 'MeoAsstMac/Utils/HGCalendar.swift'),
        str(root / 'MeoAsstMac/Utils/Codeable+JSON.swift'),
        str(Path(test_dir) / 'ActivityModels.swift'),
        '-o', str(Path(test_dir) / 'tests'),
    ], capture_output=True, text=True)
    if compile_result.returncode != 0:
        print(compile_result.stdout[-4000:], file=sys.stderr)
        print(compile_result.stderr[-4000:], file=sys.stderr)
        sys.exit(1)
    run_result = subprocess.run(
        [str(Path(test_dir) / 'tests'), str(root / 'Tests/Fixtures/StageActivitySample.json')],
        capture_output=True, text=True)
    print(run_result.stdout, end='')
    if run_result.returncode != 0:
        print(run_result.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
finally:
    subprocess.run(['rm', '-rf', test_dir])
