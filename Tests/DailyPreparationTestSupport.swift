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
enum MAATaskType { case Copilot, SSSCopilot, ParadoxCopilot, Recruit, Depot, VideoRecognition, OperBox, Custom, Fight }
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
    func appendTask(_ task: DailyTask.Kind, recruitTagNames: [String: String]) async throws -> Int32 {
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
    // 实现以满足协议;保留语义由 #161 自有套件(TaskOperationTests)验证。
    private var retained: [String] = []
    var logCount: Int { retained.count }
    func clearLogs(upTo index: Int) {
        guard index > 0, index <= retained.count else { return }
        retained.removeFirst(index)
    }
    func setDailyTasksDetailMode(_ mode: MAAViewModel.DailyTasksDetailMode) {}
}
enum ClientChannel { case official, bilibili
    /// 生产侧由 162 的游戏日历提供;夹具下 Mall 批次为空,日历不被消费。
    var calendar: Calendar { Calendar(identifier: .gregorian) }
}
struct MAAStageActivity {}
struct StageActivityContext {
    enum MedicineWindow: Equatable { case inactive, unavailable, extended(Int) }
    init(channel: ClientChannel, activities: MAAStageActivity?) {}
    func medicineWindow(at date: Date, enabled: Bool) -> MedicineWindow { .inactive }
}
struct FightConfiguration: Equatable {
    var stage: String = "1-7"
    var useActivityMedicine = false
    struct Params: Equatable {
        var stage: String = ""
        var medicine_expire_days: Int = 0
        func jsonString() throws -> String { "{}" }
    }
    func params(at date: Date, stageActivity: StageActivityContext) -> Params { Params() }
    static func normalizedStage(_ stage: String) -> String { stage }
}
struct MallConfiguration: Equatable {
    var clientChannel: ClientChannel = .official
    var batchSnapshotDate: Date?
    var creditFightDate: Date?
    var friendVisitDate: Date?
    struct Admission { var creditFightMarkedDate: Date?; var friendVisitMarkedDate: Date? }
    static func batchDailyAdmissions(of entries: [(enabled: Bool, config: MallConfiguration)],
                                     snapshotDate: Date, calendar: Calendar) -> [Admission] {
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
        case fixture
    }
    var id = UUID()
    var task: Kind
    var enabled = true
}
@MainActor final class MAAViewModel: ObservableObject {
    let dailyRunCoordinator: DailyRunCoordinator
    init(journalURL: URL? = nil) { dailyRunCoordinator = DailyRunCoordinator(journalURL: journalURL) }
    private var dailyRunOutcome = DailyRunOutcome.completed
    private(set) var dailyRunTasks: [DailyTask]?
    var dailyTaskProfile = "Fixture"
    func logError(verbatim value: String) { errors.append(value) }
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
    var taskStatus: [UUID: Int] = [:]
    var messageTask: Task<Void, Never>?
    var stageActivity: MAAStageActivity? = nil
    var fightTaskParams: [Int32: FightConfiguration.Params] = [:]
    var recruitTagNames: [String: String] = [:]
    var achievementEvents = AchievementEventAdapter()
    let hookSettings = HookSettingsStore()
    var runHookConfiguration = HookConfiguration()
    var dailyStartCancelled = false
    var activeHookTask: Task<HookResult, Error>?
    var runTerminationDeadline: Date?
    private(set) var hookTestResult: String?
    private(set) var isTestingHook = false
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
    func recoverGameToHome(runID: UUID, isCurrent: @escaping @MainActor () -> Bool) async throws {
        recoverCalled = true
        if let recoveryGate { await recoveryGate.wait() }
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
    func executeHook(_ command: HookCommand, context: RunContext, outcome: DailyRunOutcome?,
                      cancellable: Bool = true) async throws -> HookResult { HookResult() }
    func finishDailyRun(_ id: UUID, outcome: DailyRunOutcome, preparationCleanupSucceeded: Bool = true) async {
        try? dailyRunCoordinator.finish(id, outcome: outcome, cleanupSucceeded: preparationCleanupSucceeded)
        dailyRunTasks = nil
    }
    func reportIdleCallback() { resetStatus() }
    func reportBusyCallback() { status = .busy }
    func logError(_ text: String) { errors.append(text) }
    func logInfo(_ text: String) { infos.append(text) }
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
    func record(_ event: AchievementEvent) {}
    func recordLaunch() {}
}
