import Combine
import Foundation
import Observation

// Only the external core/connection and unrelated configuration are replaced.
// Entry-point bodies, state declarations, menu predicate and bridge come from production.
@MainActor final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

enum FixtureError: Error { case connection }
struct ForcedRecoveryCleanupFailure: Error {}
enum ForcedRecoveryFailure: Error { case notReady, timedOut }
enum MAATaskType { case Copilot, SSSCopilot, ParadoxCopilot, Recruit, Depot, VideoRecognition, OperBox, Custom, Fight, Infrast; var description: String { "Fight" } }
// P08.2 起编译真 InfrastConfiguration：协议与 init() 走生产同构缺省路径。
protocol MAATaskConfiguration: Codable, Hashable, Sendable {}
extension MAATaskConfiguration { init() { self = try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) } }
@MainActor final class Core {
    var isRunning = false
    var runningGate: Gate?
    var runningReturnsSnapshot = false
    var running: Bool {
        get async {
            let snapshot = isRunning
            let gate = runningGate
            runningGate = nil
            if let gate { await gate.wait() }
            return runningReturnsSnapshot ? snapshot : isRunning
        }
    }
    var queued = [UUID]()
    var failAppendAt: Int?
    var startCount = 0
    var appendCount = 0
    var stopCount = 0
    var preStartGate: Gate?
    var startGate: Gate?
    var stopGate: Gate?
    var failStart = false
    var failStop = false
    func appendTask(type: MAATaskType, params: String) async throws -> Int32 {
        appendCount += 1
        return Int32(appendCount)
    }
    var connected: Bool { true }
    func appendTask(_ task: DailyTask.Kind, recruitTagNames: [String: String],
                     blackflowStartAvailable: Bool = false,
                     supportsRoguelikeSeedInput: Bool = false) async throws -> Int32 {
        return try await appendTask(task)
    }
    func appendTask(_ task: DailyTask.Kind) async throws -> Int32 {
        appendCount += 1
        if appendCount == failAppendAt { throw FixtureError.connection }
        queued.append(UUID())
        return Int32(appendCount)
    }
    func start() async throws {
        startCount += 1
        if let preStartGate { await preStartGate.wait() }
        if failStart { throw FixtureError.connection }
        isRunning = true
        if let startGate { await startGate.wait() }
    }
    func stop() async throws {
        stopCount += 1
        if let stopGate { await stopGate.wait() }
        if failStop { throw FixtureError.connection }
        isRunning = false
        queued.removeAll()
    }
}
struct RecruitConfiguration {
    var params: Self { self }
    func jsonString() throws -> String { "{}" }
}
struct VideoRecognitionConfiguration {
    let filename: String
    var params: String? { "{}" }
}
@MainActor final class TestLogStore {
    var taskStartTime: Date?
    var screencapCost: Int?
    var lastScreencapWarningLevel = 0
    var hasPrintedFPSHighTip = false
    var sanityReport: Int?
    var fightReport: Int?
    var stoneUsedTimes = 0
    var recruitConfirmTimes = 0
    // LogStore 协议成员(161 会话基线日志保留):本夹具不覆盖日志行为,提供最小
    // 实现以满足协议;该保留语义在现行套件中断言真空,见 Tests/SKIP-SUCCESSION.md(TO-9)。
    private var retained: [String] = []
    var logCount: Int { retained.count }
    func clearLogs(upTo index: Int) {
        guard index > 0, index <= retained.count else { return }
        retained.removeFirst(index)
    }
    func setDailyTasksDetailMode(_ mode: MAAViewModel.DailyTasksDetailMode) {}
}
enum ClientChannel { case official, bilibili
    /// 生产侧为 HGCalendar(区服游戏日 04:00 重置);桩提供 weekday(for:) 供
    /// F06 周计划门控编译。夹具下 Mall 批次为空,日历不被消费。
    var calendar: GameDayCalendarStub { GameDayCalendarStub() }
    var isGlobal: Bool { false }
}
struct GameDayCalendarStub {
    func weekday(for date: Date) -> Int {
        Calendar(identifier: .gregorian).component(.weekday, from: date) - 1
    }
}
struct MAAStageActivity {}
struct PreparationCleanupFailure: Error {}
// P04:先置钩子超时/脚本失败判别;与生产 private 类型同名的边界桩。
struct PreparationHookTimeout: Error {}
struct PreparationHookFailure: Error {}
struct RoguelikeCfgStub: Equatable { func validateBlackflowStart(available: Bool) throws {} }
struct DropItemStub {}
struct InventoryTarget: Equatable { var itemID: String = ""; var quantity: Int = 0 }
struct InventoryTargetPlan { var generation = 0; var startInventory = 0; var requiredDrops = 0 }
enum InventoryTargetError: Error { case recognitionRequired, unsafeOrder, stalePreparation }
struct InventoryScope: Equatable { var connection: String }
struct InventorySnapshot {}
struct InventorySnapshotAdapter {
    var snapshot: InventorySnapshot? = nil
    var usableSnapshot: ((InventoryScope) -> InventorySnapshot?) = { _ in nil }
    func invalidate() {}
    func beginRun(id: UUID, taskIDs: Set<Int32>) {}
}
enum InventoryTargetPlanner {
    static func validateQueue(targetIndices: [Int], firstEnabledIndex: Int?) throws {}
    static func plan(target: InventoryTarget, snapshot: InventorySnapshot?, knownItems: Set<String>) throws -> InventoryTargetPlan { InventoryTargetPlan() }
    static func validateFrozen(_ plan: InventoryTargetPlan, itemID: String, snapshot: InventorySnapshot?) throws {}
}
struct StageActivityContext {
    enum MedicineWindow: Equatable { case inactive, unavailable, extended(Int) }
    init(channel: ClientChannel, activities: MAAStageActivity?) {}
    func medicineWindow(at date: Date, enabled: Bool) -> MedicineWindow { .inactive }
}
// P06.1/P06.2：提取的 startTasks 引用目录与备选/周计划/重置面。桩仅满足
// 编译（恒下发原 stage、不重置）；解析行为由 stage-plan 套件覆盖。
struct StageCatalog {
    init(context: StageActivityContext) {}
}
struct FightConfiguration: Equatable {
    var stage: String = "1-7"
    var subtitle: String { stage.isEmpty ? "当前/上次" : stage }
    var useActivityMedicine = false
    var inventoryTarget: InventoryTarget? = nil
    var weeklyDays: [Int]? = nil
    enum StagePlanOutcome: Equatable { case dispatch(stage: String); case skipAllClosed }
    struct StagePlanResolution: Equatable {
        var outcome: StagePlanOutcome
        var truncatedAfter: String?
    }
    func resolvedStagePlan(at date: Date, catalog: StageCatalog) -> StagePlanResolution {
        StagePlanResolution(outcome: .dispatch(stage: stage), truncatedAfter: nil)
    }
    func resetStageForDispatch(at date: Date, catalog: StageCatalog) -> String? { nil }
    struct Params: Equatable {
        var stage: String = ""
        var medicine_expire_days: Int = 0
        func jsonString() throws -> String { "{}" }
    }
    func params(at date: Date, stageActivity: StageActivityContext) -> Params { Params() }
    static func normalizedStage(_ stage: String) -> String { stage }
    @MainActor static func initDropItems(_ language: String) throws {}
    @MainActor static var inventoryDropItems: [(id: String, item: DropItemStub)] { [] }
    func preparingInventoryTarget(_ plan: InventoryTargetPlan) -> FightConfiguration { self }
}
struct MallConfiguration: Equatable {
    var clientChannel: ClientChannel = .official
    var batchSnapshotDate: Date?
    var creditFightDate: Date?
    var friendVisitDate: Date?
    struct Admission { var creditFightMarkedDate: Date?; var friendVisitMarkedDate: Date? }
    static func batchDailyAdmissions(of entries: [(enabled: Bool, config: MallConfiguration)],
                                     snapshotDate: Date, calendar: GameDayCalendarStub) -> [Admission] {
        entries.map { _ in Admission(creditFightMarkedDate: nil, friendVisitMarkedDate: nil) }
    }
}
enum TouchMode { case MacPlayTools, maatouch }
enum ToolsMode { case BGR, MacSCK }
struct GameConfiguration: Equatable {
    var client_type = ClientChannel.official
    var start_game_enabled = false
}
struct DailyTask: Equatable {
    enum Kind: Equatable {
        case startup(GameConfiguration)
        case closedown(GameConfiguration)
        case mall(MallConfiguration)
        case fight(FightConfiguration)
        case roguelike(RoguelikeCfgStub)
        // P08.2 起抽取面携带基建周计划门控与时间轮换；直接编译真
        // InfrastConfiguration（单一事实源，见 run-daily-preparation-tests.py swiftc 列表）。
        case infrast(InfrastConfiguration)
        case fixture
    }
    var id = UUID()
    var task: Kind
    var enabled = true
    // P03.3 起 startTasks 逐字抽取携带 runOnce;桩字段保持成员序一致。
    var runOnce = false
}
@MainActor final class MAAViewModel: ObservableObject {
    let dailyRunCoordinator: DailyRunCoordinator
    init(journalURL: URL? = nil) { dailyRunCoordinator = DailyRunCoordinator(journalURL: journalURL) }
    private var dailyRunOutcome = DailyRunOutcome.completed
    private(set) var dailyRunTasks: [DailyTask]?
    var dailyTaskProfile = "Fixture"
    func logError(verbatim value: String) { errors.append(value) }
    // G18 开关在桩世界以普通存储面替代（@AppStorage 属 SwiftUI，桩不引入）。
    var roguelikeDelayAbortUntilCombatComplete = false
    // PRODUCTION_MODEL_MEMBERS
    enum DailyTasksDetailMode { case log }
    struct DailyTaskTimer {
        var id = UUID()
        var uniqueKey: String { id.uuidString }
    }
    var medicineUsedTimes = 0
    var expiringMedicineUsedTimes = 0
    var forceRecoveryCleanupPending = false
    private var forceRecoveryJournalFailureRunID: UUID? = nil
    private var forceRecoveryAbortRequested = false
    var handle: Core? = Core()
    var logStore: TestLogStore? = TestLogStore()
    var tasks: [DailyTask] = []
    var clientChannel = ClientChannel.official
    var connectionAddress = "127.0.0.1:5555"
    var adbPath = "/test/adb"
    var toolsMode = ToolsMode.BGR
    var useGzip = false
    var useAdbLite = true
    var touchMode = TouchMode.maatouch
    var taskIDMap: [Int32: UUID] = [:]
    enum TaskStatusValue { case success }
    var taskStatus: [UUID: TaskStatusValue] = [:]
    var messageTask: Task<Void, Never>?
    var stageActivity: MAAStageActivity? = nil
    var inventory = InventorySnapshotAdapter()
    var inventoryScope = InventoryScope(connection: "adb")
    var currentInventorySnapshot: InventorySnapshot? { nil }
    var fightTaskParams: [Int32: FightConfiguration.Params] = [:]
    var recruitTagNames: [String: String] = [:]
    func invalidateInventory() { inventory.invalidate() }
    func checkStartupCancellation() throws {}
    var startupCancellationLocked = false
    enum SecretFrontResult { case stopped }
    struct SecretFrontRunStub { var taskID: Int32? = nil; func finish(taskID: Int32, result: SecretFrontResult) {} ; func release() {}
        mutating func begin(taskID: Int32, configuration: SecretFrontConfiguration?) {}
        func finishStartupFailureIfOwned(beganRun: Bool) {} }
    var secretFrontRun = SecretFrontRunStub()
    var secretFrontUnavailableReason: String? = nil
    var blackflowStartAvailable = false
    var achievementEvents = AchievementEventAdapter()
    let hookSettings = HookSettingsStore()
    var runHookConfiguration = HookConfiguration()
    var dailyStartCancelled = false
    var activeHookTask: Task<HookResult, Error>?
    var runTerminationDeadline: Date?
    private(set) var hookTestResult: String?
    // P04:工具入口在 isTestingHook 期必须被拒,测试需要直接置位该占用。
    var isTestingHook = false
    var startGameCount = 0
    func startGame(client: ClientChannel) async -> Bool { startGameCount += 1; return true }
    var recruitConfig = RecruitConfiguration()
    var connectionGate: Gate?
    var failConnection = false
    var makeCoreBusyDuringEnsure = false
    var ensureCount = 0
    var forceRecoveryInFlight = false
    var forceRecovery: Int?
    var failRecoveryCleanup = false
    var recoverCalled = false
    var recoveryGate: Gate?
    // P04:强制恢复可注入终态错误(如 ForcedRecoveryFailure.timedOut),
    // 供结果四态映射断言使用。
    var recoveryError: Error?
    func recoverGameToHome(runID: UUID, isCurrent: @escaping @MainActor () -> Bool) async throws {
        recoverCalled = true
        if let recoveryGate { await recoveryGate.wait() }
        if let recoveryError { throw recoveryError }
        if failRecoveryCleanup {
            handle?.isRunning = true
            forceRecoveryCleanupPending = true
            throw ForcedRecoveryCleanupFailure()
        }
        guard isCurrent() else { throw CancellationError() }
    }
    var errors = [String]()
    var infos = [String]()
    var operationInFlightForTest: Bool { isStartStopInFlight }
    // P04:先置钩子结果可注入 timedOut/普通失败,供结果四态映射断言使用。
    var hookResult = HookResult()
    func executeHook(_ command: HookCommand, context: RunContext, outcome: DailyRunOutcome?,
                      cancellable: Bool = true) async throws -> HookResult { hookResult }
    func finishDailyRun(_ id: UUID, outcome: DailyRunOutcome, preparationCleanupSucceeded: Bool = true) async {
        try? dailyRunCoordinator.finish(id, outcome: outcome, cleanupSucceeded: preparationCleanupSucceeded)
        dailyRunTasks = nil
        status = .idle
    }
    func reportIdleCallback() { resetStatus() }
    func reportBusyCallback() { status = .busy }
    func logError(_ text: String) { errors.append(text) }
    func logInfo(_ text: String) { infos.append(text) }
    func logTrace(verbatim text: String) {}
    func logWarn(_ text: String) {}
    var startupCancellationRequested = false
    var dailyRunChainFailed = false
    func ensureHandle(requireConnect: Bool = true) async throws {
        ensureCount += 1
        if handle == nil { handle = Core() }
        if makeCoreBusyDuringEnsure { handle?.isRunning = true }
        // PRODUCTION_CORE_RUNNING_GUARD
        if let connectionGate { await connectionGate.wait() }
        if failConnection { throw FixtureError.connection }
    }

}


typealias MAATask = DailyTask.Kind
// P04 工具入口(miniGame)逐字抽取所需的边界类型。
enum MaaCoreError: Error { case appendTaskFailed }
struct SecretFrontConfiguration {
    var params: [String: Any] = [:]
}
struct HookCommand: Codable, Equatable { var executable: String = "/bin/true" }
struct HookResult: Equatable {
    var succeeded: Bool = true
    var exitCode: Int32 = 0
    var stdout: String = ""
    var stderr: String = ""
    var timedOut: Bool = false
    var cancelled: Bool = false
    var stdoutTruncated: Bool = false
    var stderrTruncated: Bool = false
}
struct HookConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var before: HookCommand? = nil
    var after: HookCommand? = nil
    var timeoutSeconds: Int = 30
}
final class HookSettingsStore: ObservableObject { var configuration = HookConfiguration() }
struct HookRunner {
    func run(command: HookCommand, context: RunContext, outcome: DailyRunOutcome?,
             adbPath: String, workingDirectory: URL, timeout: TimeInterval) async throws -> HookResult { HookResult() }
}

struct AchievementEventAdapter {
    mutating func register(taskID: Int32, runID: UUID) {}
    mutating func register(taskID: Int32, type: String) {}
    mutating func resetSession() {}
}
struct AchievementEvent {
    enum Metric { case scheduledStart, manualStart, manualStop }
    enum Operation { case maximum }
    let runID: UUID?
    let metric: Metric
    var operation: Operation = .maximum
}
@MainActor final class AchievementStore {
    static let shared = AchievementStore()
    // AT-1 观察窗:startDailyTasks(origin: .schedule) 的 .scheduledStart 事件落账。
    private(set) var recordedEvents: [AchievementEvent] = []
    func record(_ event: AchievementEvent) { recordedEvents.append(event) }
    func recordLaunch() {}
}
