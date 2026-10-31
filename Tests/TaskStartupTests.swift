import Combine
import Foundation

// 单文件编译桩:params(at:stageActivity:) 的活动上下文;真实实现见
// MeoAsstMac/Model/StageActivity.swift。
struct MAAStageActivity {}
struct StageActivityContext {
    enum MedicineWindow: Equatable { case inactive, unavailable, extended(Int) }
    init(channel: String, activities: MAAStageActivity?) {}
    func medicineWindow(at date: Date, enabled: Bool) -> MedicineWindow { .inactive }
}

// Only the core and unrelated app dependencies are replaced. The runner compiles
// the unchanged production startTasks() body and FightConfiguration.swift.
typealias MAATaskConfiguration = Codable & Hashable & Sendable

enum MAATaskType: String {
    case Fight
    var description: String { rawValue }
}

struct ClientConfiguration: Codable, Equatable {
    var client_type = "Official"
    var start_game_enabled = false
}

enum MAATask: Equatable {
    static func == (l: MAATask, r: MAATask) -> Bool {
        switch (l, r) {
        case (.fight(let a), .fight(let b)): return a == b
        case (.mall(let a), .mall(let b)): return a == b
        case (.roguelike(let a), .roguelike(let b)): return a == b
        case (.other, .other): return true
        case (.startup, .startup), (.closedown, .closedown): return true
        default: return false
        }
    }

    case fight(FightConfiguration)
    case startup(ClientConfiguration)
    case closedown(ClientConfiguration)
 case mall(MallConfiguration), roguelike(RoguelikeCfgStub), other }

struct DailyTask: Equatable, Codable {
    enum CodingKeys: String, CodingKey { case id, enabled }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(enabled, forKey: .enabled)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        task = .other
    }
    init(id: UUID = UUID(), task: MAATask, enabled: Bool = true) {
        self.id = id; self.task = task; self.enabled = enabled
    }

    let id: UUID
    var task: MAATask
    var enabled: Bool
}

enum MAAError: Error { case gameStartFailed }
struct DailyRunSnapshot { let profileID: String; let tasks: [DailyTask] }
struct PreparationCleanupFailure: Error {}
enum ForcedRecoveryFailure: Error { case notReady, timedOut }
enum DailyRunPhase { case running }
struct RunContext { let id: UUID; var status: DailyRunPhase }
final class DailyRunCoordinator { var active: RunContext?; func transition(_ phase: DailyRunPhase, for id: UUID) throws {} }
struct DropItemStub {}
struct MallConfiguration: Equatable {
    var clientChannel: String = "Official"
    var batchSnapshotDate: Date? = nil
    var creditFightDate: Date? = nil
    var friendVisitDate: Date? = nil
    struct Admission { var creditFightMarkedDate: Date?; var friendVisitMarkedDate: Date? }
    static func batchDailyAdmissions(of entries: [(enabled: Bool, config: MallConfiguration)],
                                     snapshotDate: Date, calendar: Calendar) -> [Admission] {
        entries.map { _ in Admission(creditFightMarkedDate: nil, friendVisitMarkedDate: nil) }
    }
}
struct AchievementEventAdapter { mutating func register(taskID: Int32, runID: UUID) {} }
struct RoguelikeCfgStub: Equatable { func validateBlackflowStart(available: Bool) throws {} }
struct HookResultX {}
extension String { var calendar: Calendar { Calendar(identifier: .gregorian) } }
extension FightConfiguration.Params { func jsonString() throws -> String {
    let data = try JSONEncoder().encode(self); return String(decoding: data, as: UTF8.self)
} }
extension String { var isGlobal: Bool { false } }

@MainActor final class TestHandle {
    var stages = [String]()
    var started = false

    var connected = true
    var isRunning = false
    var running: Bool { isRunning }

    func appendTask(_ task: MAATask) async throws -> Int32 {
        guard case .fight(let config) = task else { return 0 }
        stages.append(config.stage)
        return Int32(stages.count)
    }
    func appendTask(_ task: MAATask, recruitTagNames: [String: String],
                    blackflowStartAvailable: Bool = false,
                    supportsRoguelikeSeedInput: Bool = false) async throws -> Int32 {
        try await appendTask(task)
    }
    struct CoreFightPayload: Decodable { var stage: String }
    func appendTask(type: MAATaskType, params: String) async throws -> Int32 {
        if let data = params.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CoreFightPayload.self, from: data) {
            stages.append(payload.stage)
            return Int32(stages.count)
        }
        return 0
    }
    func stop() async throws {}

    func start() async throws { started = true; isRunning = true }
}

@MainActor final class MAAViewModel {
    enum Status { case idle, pending, busy }
    enum TouchMode { case adb, MacPlayTools }

    @Published var tasks = [DailyTask]()
    var status = Status.idle
    var touchMode = TouchMode.adb
    var clientChannel = "Official"
    var taskIDMap = [Int32: UUID]()
    var handle: TestHandle? = TestHandle()
    var stageActivity: MAAStageActivity? = nil
    var recruitTagNames: [String: String] = [:]
    var blackflowStartAvailable = false
    var inventory = InventorySnapshotAdapter()
    var inventoryScope = InventoryScope(connection: "adb", server: "Official", profile: "Default")
    var currentInventorySnapshot: InventorySnapshot? { nil }
    var fightTaskParams: [Int32: FightConfiguration.Params] = [:]
    var achievementEvents = AchievementEventAdapter()
    let dailyRunCoordinator = DailyRunCoordinator()
    var dailyRunTasks: [DailyTask]? = nil
    enum TaskStatusValue { case success }
    var taskStatus: [UUID: TaskStatusValue] = [:]
    var messageTask: Task<Void, Never>? = nil
    var forceRecoveryInFlight = false
    var startupCancellationLocked = false
    var dailyStartCancelled = false
    func checkStartupCancellation() throws {}
    func runStartTasksX() async throws {
        try await startTasks(snapshot: DailyRunSnapshot(profileID: "Default", tasks: tasks), runID: UUID())
    }
    func invalidateInventory() { inventory.invalidate() }
    func recoverGameToHome(runID: UUID, isCurrent: @escaping @MainActor () -> Bool) async throws {}
    func logInfo(_ text: String) {}
    func logTrace(verbatim text: String) {}
    func startCoreTasks(recordDailyTaskStart: Bool = false) async throws {
        try await handle?.start()
        status = .busy
    }
    var logStore: TestLogStore?
    var connection: CheckedContinuation<Void, Never>?

    func ensureHandle(requireConnect: Bool = true) async throws {
        await withCheckedContinuation { connection = $0 }
    }

    func startGame(client: String) async -> Bool { true }
    func handleEarlyReturn(backTo: Status) { if status == .pending { status = backTo } }
}

@MainActor final class TestLogStore { var taskStartTime: Date? }

@main struct TaskStartupTests {
    @MainActor static func main() async throws {
        let cases = [(" ap-5 ", "AP-5"), (" \tAnNiHiLaTiOn\n", "Annihilation")]
        var failures = [String]()
        for (input, expected) in cases {
            let model = MAAViewModel()
            let id = UUID()
            let disabledID = UUID()
            let otherID = UUID()
            let config = try JSONDecoder().decode(FightConfiguration.self, from: Data("{\"stage\":\"1-7\"}".utf8))
            model.tasks = [
                .init(id: id, task: .fight(config), enabled: true),
                .init(id: disabledID, task: .fight(config), enabled: false),
                .init(id: otherID, task: .closedown(.init()), enabled: false),
            ]

            // Observe the same @Published emission used by the app's writeBack
            // subscription. This verifies serialized values, not real app I/O.
            var persisted = Data()
            let subscription = model.$tasks.sink { persisted = try! PropertyListEncoder().encode($0) }
            let startup = Task { try await model.runStartupTest() }
            while model.connection == nil { await Task.yield() }

            var edited = config
            edited.stage = input
            model.tasks[0].task = .fight(edited)
            model.tasks[1].task = .fight(edited)
            model.connection?.resume()
            model.connection = nil
            try await startup.value

            let restored = try PropertyListDecoder().decode([DailyTask].self, from: persisted)
            for (label, tasks) in [("UI", model.tasks), ("plist", restored)] {
                for index in 0...1 {
                    guard case .fight(let stored) = tasks[index].task, stored.stage == expected else {
                        failures.append("\(label) stage after connection: \(input.debugDescription), index \(index)")
                        continue
                    }
                }
                if tasks.map(\.id) != [id, disabledID, otherID] || tasks.map(\.enabled) != [true, false, false] {
                    failures.append("\(label) changed task identity or enablement")
                }
                if case .closedown = tasks[2].task {} else { failures.append("\(label) changed non-fight task") }
            }
            if model.handle?.stages != [expected] || model.taskIDMap[1] != id || model.handle?.started != true {
                failures.append("incorrect core payload, task mapping or startup")
            }
            withExtendedLifetime(subscription) {}
        }
        for failure in failures { print("FAIL: \(failure)") }
        guard failures.isEmpty else { exit(1) }
        print("PASS: edits during ensureHandle; UI/plist stages, core payload, task identity and disabled tasks")
    }
}
