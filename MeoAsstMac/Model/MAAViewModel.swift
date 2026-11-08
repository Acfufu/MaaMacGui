//
//  MAAViewModel.swift
//  MAA
//
//  Created by hguandl on 13/4/2023.
//

import Combine
import IOKit.pwr_mgt
import SwiftUI

@MainActor class MAAViewModel: ObservableObject {
    /// 追加队列的预备清理失败(队列内隔离已由内层完成);外层收口据此把
    /// cleanupSucceeded 记为 false。与 ForcedRecoveryCleanupFailure 同族。
    private struct PreparationCleanupFailure: Error {}
    /// 先置钩子超时(P04 结果四态):与用户取消(CancellationError)区分,
    /// 终态落账为 .timedOut 而非 .cancelled。
    private struct PreparationHookTimeout: Error {}
    /// 先置钩子脚本执行失败(exit≠0,非超时):记 .failed 而非 .cancelled,
    /// 使结果四态与任务卡"成功/失败/取消/超时"字面一致(A 审 Q1)。
    private struct PreparationHookFailure: Error {}
    /// 日常「更新资料」准入期 token 为空（I04-b）：与 WPF 同构地失败整跑，
    /// 与条目级失败（writeOnly/invalid/network/noData）的"条目 .failure 不中止跑"区分。
    private struct YituliuDailyTokenEmpty: Error {}

// MARK: - Core Status

    enum Status: Equatable {
        case busy
        case idle
        case pending
    }

    var medicineUsedTimes = 0
    var expiringMedicineUsedTimes = 0

    @Published private(set) var status = Status.idle
    @Published private(set) var isCoreInitialized = false
    @Published var secretFrontRun = SecretFrontRun()
    @Published private(set) var secretFrontUnavailableReason: String?
    /// 按加载产物推导的能力快照（P02.2）：series 上限挂点留给 P01.1 接线，
    /// secretFront/recycle 为门控布尔；刷新点与下方 SecretFront 缓存一致。
    @Published private(set) var coreCapabilities: CoreCapabilities = .conservativeDefault

    private var wakeupAssertionID: UInt32?
    private var awakeAssertionID: UInt32?
    private var handle: MAAHandle?
    private var cancellables = Set<AnyCancellable>()

    // 核心回调可能在异步操作返回前重置 status，独立标记防止入口重叠。
    @Published private(set) var isStartStopInFlight = false

    // G18 停止语义：肉鸽战斗中延迟停止。开关是全局运行时设置（WPF
    // Gui.RuntimeSettings.RoguelikeDelayAbortUntilCombatComplete 同位，不进任务参数）。
    @AppStorage("MAARoguelikeDelayAbortUntilCombatComplete") var roguelikeDelayAbortUntilCombatComplete = false
    /// 本轮运行是否下发了肉鸽任务：限定战斗态跟踪范围，防止 Copilot 的 StageInfo 误触发。
    /// （ setter 供 MaaMessage 扩展跨文件写入，与 taskStatus 同例。）
    @Published var activeRunHasRoguelike = false
    /// 肉鸽当前处于战斗节点（StageInfo/RoguelikeCombatEnd 消息对驱动）。
    @Published var roguelikeInCombat = false
    /// 停止请求正在等待当前战斗结束；再次请求停止时立即终止等待。
    @Published var roguelikeWaitingForCombat = false
    private var roguelikeCombatWaitAborted = false
    var forceRecovery: ForcedGameRecovery?
    var forceRecoveryInFlight = false
    private var forceRecoveryAbortRequested = false
    private var forceRecoveryCleanupPending = false
    private var forceRecoveryJournalFailureRunID: UUID? = nil
    private var taskCompletionGeneration = UInt64(0)
    private var dailyCompletionTask: Task<Void, Never>?
    private var dailyFinishAttemptedRunID: UUID?

    var achievementEvents = AchievementEventAdapter()
    // #178 启动取消通道:启动占用期 stop 只请求取消;越过最终检查点后锁定。
    private var startupCancellationRequested = false
    // #181 链错误标记:运行中由 markDailyRunFailed 置位,用户停止后结局存续
    // 为 .failed;启动期失败(未真正运行)不置位,停止时按「已取消」收口。
    private var dailyRunChainFailed = false
    private(set) var startupCancellationLocked = false
    let globalHotkeys = GlobalHotkeyService()
    let hookSettings = HookSettingsStore()
    private var runHookConfiguration = HookConfiguration()
    private var dailyStartCancelled = false
    private var activeHookTask: Task<HookResult, Error>?
    private var runTerminationDeadline: Date?
    @Published private(set) var hookTestResult: String?
    @Published private(set) var isTestingHook = false
    let dailyRunCoordinator = DailyRunCoordinator(journalURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("DailyRunJournal.json"))
    private var dailyRunOutcome = DailyRunOutcome.completed
    private(set) var dailyRunTasks: [DailyTask]?
    private(set) var isApplyingDailyCallbackPatch = false

    var canStartTasks: Bool {
        status == .idle && !isStartStopInFlight && dailyRunCoordinator.active == nil && !isTestingHook
    }

    private func reconcileDailyRunStatus() {
        if status == .idle, let phase = dailyRunCoordinator.active?.status {
            status = phase == .running ? .busy : .pending
        }
    }

    /// 启动路径的取消检查点:既响应任务树取消,也响应启动占用期 stop() 的取消
    /// 请求(含 #176 早段取消标记),任一命中即按「已取消」收口。
    private func checkStartupCancellation() throws {
        try Task.checkCancellation()
        if startupCancellationRequested || dailyStartCancelled { throw CancellationError() }
    }

    private func beginTaskOperation(requiresIdle: Bool = true, logsConflict: Bool = true) async throws {
        reconcileDailyRunStatus()
        guard !isStartStopInFlight else {
            if logsConflict { logError("当前正在启动或停止任务，请稍后重试。") }
            throw MAAError.taskOperationInProgress
        }
        guard !requiresIdle || (status == .idle && dailyRunCoordinator.active == nil && !isTestingHook) else {
            if logsConflict { logError("任务正在运行，请先停止当前任务。") }
            throw MAAError.taskAlreadyRunning
        }
        // Reserve before querying the core actor: the await must not admit
        // another start or stop even if a callback has exposed idle.
        isStartStopInFlight = true
        var accepted = false
        defer {
            if !accepted { isStartStopInFlight = false }
        }

        if requiresIdle {
            // Record the session boundary synchronously before the first await.
            // The previous session is only removed after the core reconcile
            // admits the start, so a stale-idle desync keeps it visible on
            // rejection, while entries appended by operations rejected during
            // the await are newer than the boundary and survive the new session.
            let sessionBaseline = logStore?.logCount ?? 0
            let coreIsRunning = await handle?.running == true
            guard !coreIsRunning, status == .idle else {
                if coreIsRunning { status = .busy }
                if logsConflict { logError("任务正在运行，请先停止当前任务。") }
                throw MAAError.taskAlreadyRunning
            }
            try Task.checkCancellation()
            logStore?.clearLogs(upTo: sessionBaseline)
        }
        accepted = true
    }

    // MARK: - Core Callback

    private var messageTask: Task<Void, Never>?
    weak var logStore: (any LogStore)?

    // MARK: - Daily Tasks

    @AppStorage("DailyTaskProfile") var dailyTaskProfile = "Default" {
        didSet { if dailyTaskProfile != oldValue { invalidateInventory() } }
    }

    enum DailyTasksDetailMode: Hashable {
        case taskConfig
        case log
        case timerConfig
    }

    @Published var tasks = [DailyTask]()
    // P03.2 档案注册表的 UI 投影；活跃档案 id 仍由 dailyTaskProfile 承载。
    @Published private(set) var profileIdentities: [ProfileIdentity] = []
    @Published var taskIDMap: [Int32: UUID] = [:]
    // Preserve the exact parameters submitted to Core for delayed medicine callbacks.
    var fightTaskParams: [Int32: FightConfiguration.Params] = [:]
    @Published var newTaskAdded = false
    @Published var inventory = InventorySnapshotAdapter()
    var inventoryDepotTaskID: Int32?
    var pendingInventoryDepot: MAADepot?
    var inventoryDepotScope: InventoryScope?
    var operBoxHistoryTaskID: Int32?
    var operBoxHistoryScope: InventoryScope?
    var pendingOperBoxHistory: OperBoxHistoryPayload?
    @Published var operBoxHistoryRevision = UUID()

    /// A local label explicitly bound by the user, never inferred from a task profile.
    @AppStorage("MAAUserDataAccount") var userDataAccount = "" {
        didSet { if userDataAccount != oldValue { invalidateInventory() } }
    }

    /// 一图流 OpenAPI token（I04 只读练度导入）。明文存 UserDefaults：WPF 为 DPAPI 加密，
    /// Keychain 迁移待正式签名环境（P28/P29 批次）；token 不进日志与支持包。
    @AppStorage("MAAYituliuOpenApiToken") var yituliuOpenApiToken = ""
    /// 日常「更新资料」组合任务的干员资料改用一图流拉取（I04-b，WPF
    /// EnableOperBoxYituliuApi 同位）；关闭时干员识别照常进 Core 队列。
    @AppStorage("MAAYituliuOperBoxForDaily") var yituliuOperBoxForDaily = false
    /// 生产为默认会话；隔离验证注入 URLProtocol 桩会话。
    var yituliuSession: URLSession = .shared
    @Published private(set) var yituliuImportInFlight = false
    @Published private(set) var yituliuImportMessage: String?

    var inventoryScope: InventoryScope {
        InventoryScope(connection: "\(connectionAddress)|\(touchMode.rawValue)|\(toolsMode.rawValue)|\(useGzip)|\(useAdbLite)",
                       server: clientChannel.rawValue, profile: dailyTaskProfile, account: userDataAccount)
    }

    var currentInventorySnapshot: InventorySnapshot? { inventory.usableSnapshot(scope: inventoryScope) }

    func invalidateInventory() {
        inventory.invalidate()
        inventoryDepotTaskID = nil
        inventoryDepotScope = nil
        pendingInventoryDepot = nil
        operBoxHistoryTaskID = nil
        operBoxHistoryScope = nil
        pendingOperBoxHistory = nil
        logStore?.setDepot(nil)
        logStore?.setOperBox(nil)
    }

    enum TaskStatus: Equatable {
        case cancel
        case failure
        case running
        case success
        case skipped
    }

    @Published var taskStatus: [UUID: TaskStatus] = [:]
    var userDataUpdateRun = UserDataUpdateRun()
    private var userDataCallbackDeadline: ContinuousClock.Instant?

    var tasksDirectory: URL {
        Self.userDirectory.appendingPathComponent("DailyTasks", isDirectory: true)
    }

    var tasksURL: URL {
        tasksDirectory.appendingPathComponent(dailyTaskProfile, isDirectory: false)
            .appendingPathExtension("plist")
    }

    @AppStorage("MAAScheduledDailyTaskTimer") var serializedScheduledDailyTaskTimers: String?

    typealias DailyTaskTimer = DailyTaskSchedule

    @Published var scheduledDailyTaskTimers: [DailyTaskTimer] = []

    @Published private(set) var blackflowStartAvailable = false

    // MARK: - OTA Resources

    @Published private var stageActivities = [String: MAAStageActivity]()

    var stageActivity: MAAStageActivity? {
        stageActivities[clientChannel.stageActivityKey]
    }

    // MARK: - Recognition

    @Published var recruitConfig = RecruitConfiguration.recognition
    @Published var recruit: MAARecruit?
    private var recruitTagNames = [String: String]()
    /// Effective base resource directory of recruit tags, bundled until user resources take over.
    @Published private(set) var recruitResourceDirectory = Bundle.main.resourceURL?.appendingPathComponent(
        "resource")
    /// Modification date of the effective tag table, changing on in-place resource updates.
    @Published private(set) var recruitResourceRevision: Date?

    // MARK: - Connection Settings

    @AppStorage("MAAConnectionAddress") var connectionAddress = "127.0.0.1:5555" {
        didSet { if connectionAddress != oldValue { invalidateInventory() } }
    }

    @AppStorage("MAAUseGzip") var useGzip = false {
        didSet { if useGzip != oldValue { invalidateInventory() } }
    }

    @AppStorage("MAAUseAdbLite") var useAdbLite = true {
        didSet { if useAdbLite != oldValue { invalidateInventory() } }
    }

    @AppStorage("MAAToolsMode") var toolsMode = MaaToolsMode.BGR {
        didSet { if toolsMode != oldValue { invalidateInventory() } }
    }

    @AppStorage("MAATouchMode") var touchMode = MaaTouchMode.maatouch {
        didSet {
            guard touchMode != oldValue else { return }
            invalidateInventory()
            if touchMode == .MacPlayTools || oldValue == .MacPlayTools {
                Task { try await loadResource(channel: clientChannel) }
            }
        }
    }

    // MARK: - Game Settings

    @AppStorage("MAAClientChannel") var clientChannel = MAAClientChannel.Official {
        didSet {
            if clientChannel != oldValue { invalidateInventory() }
            updateChannel(channel: clientChannel)
        }
    }

    // MARK: - Update Settings

    @AppStorage("AutoResourceUpdate") var autoResourceUpdate = false

    @AppStorage("ResourceUpdateChannel") var resourceChannel = MAAResourceChannel.github

    @Published var showResourceUpdate = false

    // MARK: - System Settings

    @AppStorage("MAAPreventSystemSleeping") var preventSystemSleeping = false {
        didSet {
            NotificationCenter.default.post(name: .MAAPreventSystemSleepingChanged, object: preventSystemSleeping)
        }
    }

    // MARK: - Initializer

    init() {
        // P03.2: 注册表的活跃指针在启动时是权威的（Q04 的 --config 在本类
        // 构造前已写入指针）；AppStorage 仅作 UI 侧缓存同步。
        if let active = try? profileStore.activeProfileID(), active != dailyTaskProfile {
            dailyTaskProfile = active
        }
        do {
            tasks = try DailyTaskProfileStore(profileURL: tasksURL).load()
        } catch {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: tasksDirectory.path, isDirectory: &isDirectory)
            switch (exists, isDirectory.boolValue) {
            case (true, true):
                break
            case (true, false):
                try? FileManager.default.removeItem(at: tasksDirectory)
                try? FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
            case (false, _):
                try? FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
            }

            do {
                tasks = try migrateLegacyConfigurations()
            } catch {
                tasks = defaultTaskConfigurations.map { .init(config: $0) }
            }
        }

        $tasks.sink(receiveValue: writeBack).store(in: &cancellables)
        $status.sink(receiveValue: switchAwakeGuard).store(in: &cancellables)
        reloadProfileIdentities()

        globalHotkeys.command = { [weak self] command in
            guard let self else { return false }
            switch command {
            case .start: return await self.startDailyTasks(origin: .hotkey) == .started
            case .stop:
                guard self.status != .idle || self.dailyRunCoordinator.active != nil else { return false }
                do { try await self.stop(); return true } catch { return false }
            }
        }
        dailyRunCoordinator.didChange = { [weak self] in self?.objectWillChange.send() }
        initScheduledDailyTaskTimer()
        AchievementStore.shared.recordLaunch()
    }

    deinit {
        messageTask?.cancel()
        Self.releaseAssertion(awakeAssertionID)
        Self.releaseAssertion(wakeupAssertionID)
    }
}

// MARK: - MaaCore

extension MAAViewModel {
    func initialize() async throws {
        status = .pending
        try await MAAProvider.shared.setUserDirectory(path: Self.userDirectory.path)
        try await loadResource(channel: clientChannel)
        status = .idle
        isCoreInitialized = true
    }

    func ensureHandle(requireConnect: Bool = true) async throws {
        // 与 beginTaskOperation 相同的会话基线契约：先于首个 await 记录边界，
        // 复核通过后仅清除边界之前的旧条目，探测期间新追加的日志得以保留。
        let sessionBaseline = logStore?.logCount ?? 0
        if handle == nil {
            let handle = try await MAAHandle(options: instanceOptions)
            self.handle = handle
            messageTask?.cancel()

            let messages = handle.messages
            messageTask = Task { [weak self, messages] in
                for await message in messages {
                    self?.processMessage(message)
                }
            }
        } else {
            // 实例已存在时重新应用选项（如触控模式），使设置变更在下次连接即生效，无需重启应用。
            try await handle?.apply(options: instanceOptions)
        }

        guard await handle?.running == false else {
            status = .busy
            logError("任务正在运行，请先停止当前任务。")
            throw MAAError.taskAlreadyRunning
        }

        secretFrontRun = SecretFrontRun()
        logStore?.clearLogs(upTo: sessionBaseline)
        taskIDMap.removeAll()
        userDataUpdateRun.reset()
        fightTaskParams.removeAll()
        taskStatus.removeAll()

        guard requireConnect else { return }
        achievementEvents.resetSession()
        invalidateInventory()

        logTrace("ConnectingToEmulator")
        if touchMode == .MacPlayTools {
            logTrace("如果长时间连接不上或出错，请尝试下载使用“文件” > “PlayCover链接…”中的最新版本")
            if toolsMode == .MacSCK && !CGPreflightScreenCaptureAccess() {
                logError("未开启屏幕录制权限，请前往“系统设置” > “隐私与安全性” > “录屏与系统录音”允许MAA访问")
            }
            if toolsMode == .MacSCK {
                logInfo("运行过程中，请勿将游戏设置为全屏幕、最小化，或移动窗口至其他显示器")
            }
        }

        let connectionProfile: String
        switch (touchMode, toolsMode, useGzip) {
        case (.MacPlayTools, .MacSCK, _):
            connectionProfile = "MacSCK"
        case (.MacPlayTools, .BGR, _):
            connectionProfile = "MacBGR"
        case (_, _, true):
            connectionProfile = "Compatible"
        default:
            connectionProfile = "CompatMac"
        }

        try await handle?.connect(adbPath: adbPath, address: connectionAddress, profile: connectionProfile)
        logTrace("Running")
    }

    private func startCoreTasks(recordDailyTaskStart: Bool = false) async throws {
        try await handle?.start()
        // Reconcile the actual core after start. A reset may belong to a prior
        // run; retry if a callback makes the awaited running snapshot stale.
        var observedGeneration: UInt64
        var coreIsRunning: Bool
        repeat {
            observedGeneration = taskCompletionGeneration
            coreIsRunning = await handle?.running == true
        } while observedGeneration != taskCompletionGeneration

        guard coreIsRunning else {
            resetStatus()
            return
        }
        if recordDailyTaskStart { logStore?.taskStartTime = .now }
        status = .busy
    }

    func stop(cancelScheduledStart: Bool = true, logsConflict: Bool = true, userRequested: Bool = true, waitForRoguelikeCombat: Bool = true) async throws {
        if cancelScheduledStart {
            NotificationCenter.default.post(name: .MAACancelPendingScheduledStart, object: nil)
        }
        if roguelikeWaitingForCombat {
            // G18：等待战斗结束期间再次请求停止 → 只终止等待；实际的 Core 停止
            // 由在途的首次停止流程在跳出等待后立即执行，此处不重复进入停止互斥。
            roguelikeCombatWaitAborted = true
            logInfo("已请求立即停止，不再等待当前战斗结束。")
            return
        }
        if forceRecoveryInFlight && isStartStopInFlight && !forceRecoveryCleanupPending {
            // 强制恢复最长约 5 分钟,且仅在 startDailyTasks 持有启动互斥期间运行;
            // 该窗口内保留停止途径:请求中止恢复,恢复循环会清理并释放 Core,
            // 随后本次运行按取消结束。cleanupPending 只在恢复循环抛出终止失败前
            // 置位,此后再无人观测中止请求,不得走此短路:互斥已释放时必须完整
            // 停止(陈旧标志不得短路卡死的 Core),互斥仍持有的尾声窗口则由
            // beginTaskOperation 如实抛出占用提示,而非静默吞掉本次停止。
            forceRecoveryAbortRequested = true
            logInfo("正在中止恢复中的强制开始任务，请稍候。")
            return
        }
        guard dailyRunCoordinator.active?.status != .postHook else {
            if logsConflict { logError("后置清理正在执行，请等待完成。") }
            throw MAAError.taskOperationInProgress
        }
        if forceRecoveryCleanupPending == false, let context = dailyRunCoordinator.active,
           [.preparing, .preHook, .connecting].contains(context.status) {
            // 启动早段(含 pre-hook 脚本)的停止请求:置取消标记并中止钩子,
            // 由 startDailyTasks 的检查点按「已取消」收口,无需抢占互斥。
            // cleanupPending 尾窗除外:该窗口必须完整停止卡死的 Core,
            // 不得被此短路吞掉(179 修复语义)。
            dailyStartCancelled = true
            startupCancellationRequested = true
            dailyRunOutcome = .cancelled
            activeHookTask?.cancel()
            return
        }
        try await beginTaskOperation(requiresIdle: false, logsConflict: logsConflict)
        defer { isStartStopInFlight = false }
        // Revoke recognition ownership before awaiting native stop: late complete
        // callbacks cannot publish or persist a refresh the user cancelled.
        invalidateInventory()
        cancelDailyUserDataUpdates()
        let achievementWasRunning = await handle?.running == true
        let achievementRunID = dailyRunCoordinator.active?.id

        status = .pending
        defer { handleEarlyReturn(backTo: .busy) }

        // 已在运行/停止相位记录的链错误必须存续为结局(#181);启动期(未真正
        // 运行)的失败被用户停止时按「已取消」收口(#179 清理失败回归)。
        if !(dailyRunOutcome == .failed && dailyRunChainFailed) { dailyRunOutcome = .cancelled }
        var abandonedRun = false
        if let id = dailyRunCoordinator.active?.id {
            do { try dailyRunCoordinator.transition(.stopping, for: id) }
            catch {
                // Journal 无法写入时仍允许用户停止:放弃本次落盘记录,仅推进内存状态。
                logError("每日运行日志：\(error.localizedDescription)")
                dailyRunCoordinator.abandon(id)
                abandonedRun = true
            }
        }
        // abandon 之后不再有空闲观察者兜底;若仍挂着清理失败的隔离 Core,
        // 停止尝试后必须就地消化隔离状态,避免标志跨运行残留污染下一次运行
        // 的消息路由与收尾过滤。
        let discardQuarantinedCore = abandonedRun && forceRecoveryCleanupPending
        // G18：肉鸽战斗中延迟停止——等待当前战斗结束（RoguelikeCombatEnd）后再停止，
        // 最长 10 分钟；等待期间 MainActor 挂起，消息循环持续更新战斗态。
        // 再次请求停止立即跳出；退出路径显式绕过等待，继续运行收尾。
        if waitForRoguelikeCombat, roguelikeDelayAbortUntilCombatComplete, activeRunHasRoguelike,
           roguelikeInCombat, await handle?.running == true {
            roguelikeWaitingForCombat = true
            logInfo("肉鸽战斗中：等待当前战斗结束后再停止（最长 10 分钟）。再次点击停止可立即停止。")
            let deadline = ContinuousClock.now.advanced(by: .seconds(600))
            while ContinuousClock.now < deadline, roguelikeInCombat, !roguelikeCombatWaitAborted, !Task.isCancelled,
                  await handle?.running == true {
                try? await Task.sleep(for: .seconds(1))
            }
            roguelikeWaitingForCombat = false
            if Task.isCancelled {
                logInfo("停止等待已取消，现在停止。")
            } else if roguelikeCombatWaitAborted {
                logInfo("已按请求立即停止。")
            } else if roguelikeInCombat, await handle?.running == true {
                logInfo("等待战斗结束超时，现在停止。")
            } else {
                // 战斗态清零（RoguelikeCombatEnd）或 Core 自然收口（running 已 false）。
                logInfo("战斗已结束或运行已收口，继续停止。")
            }
        }
        roguelikeCombatWaitAborted = false
        do { try await handle?.stop() }
        catch {
            guard discardQuarantinedCore else { throw error }
            // 丢弃隔离 Core 时,停止失败由句柄释放(AsstDestroy)兜底。
        }
        activeRunHasRoguelike = false
        roguelikeInCombat = false
        if userRequested, cancelScheduledStart, achievementWasRunning {
            AchievementStore.shared.record(.init(runID: achievementRunID, metric: .manualStop, operation: .maximum))
        }
        if let id = secretFrontRun.taskID { secretFrontRun.finish(taskID: id, result: .stopped) }
        status = .idle
        if discardQuarantinedCore {
            messageTask?.cancel()
            messageTask = nil
            handle = nil
            forceRecovery = nil
            forceRecoveryCleanupPending = false
            forceRecoveryInFlight = false
        }
        await finishDailyRunIfStopped(allowInFlight: true)
    }

    func resetStatus() {
        taskCompletionGeneration &+= 1
        // G18：本轮运行收口（自然完成或链停止），战斗态与等待标志随之清零。
        activeRunHasRoguelike = false
        roguelikeInCombat = false
        roguelikeWaitingForCombat = false
        roguelikeCombatWaitAborted = false
        if let runID = dailyRunCoordinator.active?.id, dailyFinishAttemptedRunID == runID {
            status = .pending
            return
        }
        secretFrontRun.release()
        status = .idle
        medicineUsedTimes = 0
        expiringMedicineUsedTimes = 0

        logStore?.screencapCost = nil
        logStore?.lastScreencapWarningLevel = 0
        logStore?.hasPrintedFPSHighTip = false
        logStore?.taskStartTime = nil
        logStore?.sanityReport = nil
        logStore?.fightReport = nil
        logStore?.stoneUsedTimes = 0
        logStore?.recruitConfirmTimes = 0
        // Core emits AllTasksCompleted before its worker clears the running flag.
        // Keep checking for this run until the native shutdown and any start/stop
        // operation have finished; never let an old waiter finish a later run.
        guard let runID = dailyRunCoordinator.active?.id else { return }
        waitForDailyRunCompletion(runID: runID)
    }

    private func waitForDailyRunCompletion(runID: UUID) {
        dailyCompletionTask?.cancel()
        dailyCompletionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.dailyRunCoordinator.active?.id == runID else { return }
                if await self.finishDailyRunIfStopped() { return }
                guard self.dailyRunCoordinator.active?.id == runID,
                      self.dailyRunCoordinator.active?.status != .postHook else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func markDailyRunFailed() {
        if dailyRunCoordinator.active != nil {
            dailyRunOutcome = .failed
            dailyRunChainFailed = true
        }
    }

    private func discardPreparedDailyTasks(for runID: UUID) async -> Bool {
        guard dailyRunCoordinator.active?.id == runID else { return false }
        do {
            try await handle?.stop()
            guard dailyRunCoordinator.active?.id == runID else { return false }
            guard await handle?.running != true else { throw MAAError.taskAlreadyRunning }
            taskIDMap.removeAll()
            taskStatus.removeAll()
            return true
        } catch {
            guard dailyRunCoordinator.active?.id == runID else { return false }
            messageTask?.cancel()
            messageTask = nil
            handle = nil
            taskIDMap.removeAll()
            taskStatus.removeAll()
            logError("每日准备清理：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func finishDailyRunIfStopped(allowInFlight: Bool = false) async -> Bool {
        guard allowInFlight || !isStartStopInFlight else { return false }
        guard let context = dailyRunCoordinator.active,
              [.running, .stopping].contains(context.status) || forceRecoveryCleanupPending else { return false }
        guard await handle?.running != true,
              (allowInFlight || !Task.isCancelled),
              (allowInFlight || !isStartStopInFlight),
              dailyRunCoordinator.active?.id == context.id,
              let currentStatus = dailyRunCoordinator.active?.status,
              [.running, .stopping].contains(currentStatus) || forceRecoveryCleanupPending else { return false }
        // A failed recovery retains Core and suppresses its callbacks until it is
        // observably idle. Only then may its queued work and handle be discarded.
        if forceRecoveryCleanupPending {
            messageTask?.cancel()
            messageTask = nil
            handle = nil
            forceRecovery = nil
            forceRecoveryCleanupPending = false
            forceRecoveryInFlight = false
            if forceRecoveryJournalFailureRunID == context.id {
                status = .pending
                return true
            }
        }
        // Native idle can become visible before MainActor drains the terminal
        // callback stream. Keep run ownership briefly; missing refresh callbacks
        // must end as failure rather than consume runOnce on a false success.
        if userDataUpdateRun.hasPending(runID: context.id) {
            if userDataCallbackDeadline == nil { userDataCallbackDeadline = ContinuousClock.now.advanced(by: .seconds(2)) }
            if let deadline = userDataCallbackDeadline, ContinuousClock.now < deadline { return false }
            failIncompleteDailyUserDataUpdates(runID: context.id)
        }
        userDataCallbackDeadline = nil
        // Failed journal writes keep ownership and must not spin on duplicate callbacks.
        guard dailyFinishAttemptedRunID != context.id else { return true }
        dailyFinishAttemptedRunID = context.id
        await finishDailyRun(context.id, outcome: dailyRunOutcome)
        return true
    }

    private func finishDailyRun(_ id: UUID, outcome: DailyRunOutcome, preparationCleanupSucceeded: Bool = true) async {
        guard let context = dailyRunCoordinator.active, context.id == id, context.status != .postHook else { return }
        do {
            try dailyRunCoordinator.transition(.postHook, for: id)
            status = .pending
            var cleanupSucceeded = preparationCleanupSucceeded
            if runHookConfiguration.enabled, let command = runHookConfiguration.after {
                do {
                    let result = try await executeHook(command, context: context, outcome: outcome, cancellable: false)
                    cleanupSucceeded = result.succeeded && cleanupSucceeded
                } catch {
                    cleanupSucceeded = false
                    logError(verbatim: "Post-run script: \(error.localizedDescription)")
                }
            }
            try dailyRunCoordinator.finish(id, outcome: outcome, cleanupSucceeded: cleanupSucceeded)
            // Q05 消费挂点：完整终态落账后才处理一次性开关；失败/取消与
            // 迟到回调在 consumeRunOnceSemantics 内被 runID/结局判别拒绝。
            if let terminal = dailyRunCoordinator.lastTerminal, terminal.id == id {
                consumeRunOnceSemantics(terminal: terminal)
            }
            dailyRunTasks = nil
            status = .idle
            if !cleanupSucceeded { logError("后置清理失败，请检查脚本输出并手动恢复设备设置") }
        } catch {
            status = .pending
            logError(verbatim: "Daily run journal: \(error.localizedDescription)")
            // Ownership is deliberately retained to avoid retry loops, so make
            // the resulting stuck state visible and actionable for the user.
            logError("运行日志写入失败，本次运行将保持未完成状态，重启应用后即可恢复。")
        }
    }

    /// Q05 一次性开关的消费：仅在运行已完整收口（该 run 已成为 lastTerminal
    /// 且无进行中的运行）且结局为成功时，把 once 语义落回运行所属档案。
    /// P03.3/N1：消费范围收敛到运行冻结快照中 enabled 的任务 id——运行中
    /// 新增/新武装的 once 任务从未执行，终态不被消费（快照缺失时范围为空，
    /// 保守不消费）。失败/取消保持 once 状态；携带旧 runID 的迟到终态因
    /// lastTerminal 已指向新运行而被拒绝，不会二次消费。
    func consumeRunOnceSemantics(terminal: RunContext) {
        guard terminal.outcome == .completed,
              dailyRunCoordinator.active == nil,
              dailyRunCoordinator.lastTerminal?.id == terminal.id else { return }
        // 冻结快照（dailyRunTasks）此刻仍指向刚收口的运行；其 enabled id
        // 集合即"本次真正执行过"的任务范围。
        let eligibleIDs = Set(dailyRunTasks?.filter(\.enabled).map(\.id) ?? [])
        let isCurrentProfile = terminal.profileID == dailyTaskProfile
        do {
            if let updated = try DailyRunOnceConsumption.apply(
                profileID: terminal.profileID,
                currentTasks: isCurrentProfile ? tasks : nil,
                directory: tasksDirectory,
                eligibleIDs: eligibleIDs) {
                if isCurrentProfile {
                    isApplyingDailyCallbackPatch = true
                    tasks = updated
                    isApplyingDailyCallbackPatch = false
                }
            }
        } catch {
            logError("一次性任务回写失败：\(error.localizedDescription)")
        }
    }

    private func executeHook(_ command: HookCommand, context: RunContext, outcome: DailyRunOutcome?,
                             cancellable: Bool = true) async throws -> HookResult {
        let directory = Self.userDirectory.appendingPathComponent("RunHooks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuredTimeout = TimeInterval(runHookConfiguration.timeoutSeconds)
        let timeout = runTerminationDeadline.map { min(configuredTimeout, $0.timeIntervalSinceNow) }
            ?? configuredTimeout
        guard timeout > 0 else { throw CancellationError() }
        let adb = adbPath
        let task = Task { try await HookRunner().run(command: command, context: context, outcome: outcome,
                                                     adbPath: adb, workingDirectory: directory, timeout: timeout) }
        activeHookTask = task
        defer { activeHookTask = nil }
        let result: HookResult
        if cancellable {
            result = try await withTaskCancellationHandler(operation: { try await task.value },
                                                           onCancel: { task.cancel() })
        } else {
            result = try await task.value
        }
        logInfo(verbatim: "Script run=\(context.id) result=\(outcome?.rawValue ?? "preparing")"
            + " exit=\(result.exitCode) timeout=\(result.timedOut) cancelled=\(result.cancelled)")
        if !result.stdout.isEmpty { logTrace(verbatim: result.stdout) }
        if !result.stderr.isEmpty { logWarn(verbatim: result.stderr) }
        if result.stdoutTruncated || result.stderrTruncated {
            logWarn("脚本输出未完整读取（每个输出流最多保留 32 KiB；若有后台进程仍持有输出管道，将在宽限后停止读取）")
        }
        return result
    }

    func testHook(_ command: HookCommand) async {
        guard canStartTasks, !isTestingHook else { return }
        isTestingHook = true
        defer { isTestingHook = false }
        runHookConfiguration = hookSettings.configuration
        let context = RunContext(id: UUID(), origin: .manual, profileID: dailyTaskProfile,
                                 status: .preHook, startedAt: .now)
        do {
            let result = try await executeHook(command, context: context, outcome: nil)
            hookTestResult = "Exit \(result.exitCode)\n\(result.stdout)\n\(result.stderr)"
        } catch { hookTestResult = error.localizedDescription }
    }

    func recoverInterruptedRun() async {
        guard canStartTasks, let context = dailyRunCoordinator.lastTerminal,
              let command = hookSettings.configuration.after else { return }
        isTestingHook = true
        defer { isTestingHook = false }
        runHookConfiguration = hookSettings.configuration
        do {
            let result = try await executeHook(command, context: context, outcome: .interrupted)
            try dailyRunCoordinator.recordRecovery(for: context.id, succeeded: result.succeeded)
            hookTestResult = "Exit \(result.exitCode)\n\(result.stdout)\n\(result.stderr)"
        } catch { hookTestResult = error.localizedDescription }
    }

    func prepareForTermination(timeout: TimeInterval = 65) async {
        let deadline = Date.now.addingTimeInterval(max(0, timeout))
        runTerminationDeadline = deadline
        if isTestingHook {
            activeHookTask?.cancel()
            if let task = activeHookTask { _ = try? await task.value }
        }
        guard dailyRunCoordinator.active != nil else { return }
        Task { try? await self.stop(waitForRoguelikeCombat: false) }
        while dailyRunCoordinator.active != nil, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if dailyRunCoordinator.active != nil {
            // An allowed 300-second hook must not survive a shorter app-exit
            // deadline. Cancellation waits for TERM/KILL and group reaping.
            activeHookTask?.cancel()
            if let task = activeHookTask { _ = try? await task.value }
            let settleDeadline = Date.now.addingTimeInterval(3)
            while dailyRunCoordinator.active != nil, Date.now < settleDeadline {
                activeHookTask?.cancel()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func screenshot() async throws -> NSImage {
        guard let image = try await handle?.getImage() else {
            throw MAAError.imageUnavailable
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func previewFrame(maxPixelSize: Int? = nil) async throws -> PreviewFrame {
        guard let handle else { throw PreviewError.disconnected }
        // Do not call ensureHandle: it clears logs, IDs and task states even for an existing handle.
        let (image, requested) = try await handle.previewImage(
            requestFresh: status == .idle, maxPixelSize: maxPixelSize)
        return PreviewFrame(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            readAt: Date(), requestedCapture: requested)
    }

    /// Reloads the resources from the documents directory after update.
    func reloadResources(channel: MAAClientChannel) async throws {
        defer { refreshCoreCapabilities() }
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try await loadResource(url: documentsDirectory, channel: channel)
    }

    /// Load base resources and channel-specific resources.
    ///
    /// Should be called by `loadResource(channel:)`.
    private func loadResource(url: URL, channel: MAAClientChannel) async throws {
        // Keep the UI tag catalog in sync with the resources actually loaded by Core.
        if let baseDirectory = try await loadResource(url: url) {
            publishRecruitResource(baseDirectory)
        }

        if channel.isGlobal {
            let extraResource = url.appendingPathComponent("resource")
                .appendingPathComponent("global")
                .appendingPathComponent(channel.rawValue)
            if FileManager.default.fileExists(atPath: extraResource.path),
                let globalDirectory = try await loadResource(url: extraResource)
            {
                // Core replaces the base recruit table with the channel-specific one.
                publishRecruitResource(globalDirectory)
            }
        }
    }

    /// Publishes the effective tag directory with a token that changes on in-place updates.
    private func publishRecruitResource(_ directory: URL) {
        recruitResourceDirectory = directory
        let tableFile = RecruitTagCatalog.effectiveTableFile(resourceDirectory: directory)
        let attributes = tableFile.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        recruitResourceRevision = attributes?[.modificationDate] as? Date
    }

    /// Core process to load resources at url.
    ///
    /// Should be called by `loadResource(url:channel:)`.
    private func loadResource(url: URL) async throws -> URL? {
        do {
            try await MAAProvider.shared.loadResource(path: url.path)
        } catch {
            blackflowStartAvailable = false
            throw error
        }
        if blackflowStartAvailable && !BlackflowStartSupport.permitsOverlay(at: url) {
            blackflowStartAvailable = false
        }
        var recruitDirectory = updateRecruitTags(resourceDirectory: url.appendingPathComponent("resource"))

        if touchMode == .MacPlayTools {
            let platformResource = url.appendingPathComponent("resource")
                .appendingPathComponent("platform_diff")
                .appendingPathComponent("iOS")
            if FileManager.default.fileExists(atPath: platformResource.path) {
                try await MAAProvider.shared.loadResource(path: platformResource.path)
                if let directory = updateRecruitTags(
                    resourceDirectory: platformResource.appendingPathComponent("resource"))
                {
                    recruitDirectory = directory
                }
            }
        }

        return recruitDirectory
    }

    /// Publishes the tag names Core matches against, reporting their resource directory when readable.
    private func updateRecruitTags(resourceDirectory: URL) -> URL? {
        guard let catalog = RecruitTagCatalog.read(resourceDirectory: resourceDirectory) else { return nil }
        recruitTagNames = catalog.labels
        return resourceDirectory
    }

    /// Fetches OTA resources for the specified channel.
    private func fetchOTAResource(channel: MAAClientChannel) async throws {
        let otaFetcher = OTAFetcher()
        var files = [
            (path: "resource/tasks.json", name: "resource/tasks/tasks.json"),
            (path: "gui/StageActivityV2.json", name: "gui/StageActivityV2.json"),
        ]
        if channel.isGlobal {
            files.append(
                (
                    path: "resource/global/\(channel.rawValue)/resource/tasks.json",
                    name: "resource/global/\(channel.rawValue)/resource/tasks/tasks.json"
                ))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (path, name) in files {
                group.addTask {
                    try await otaFetcher.download(path: path, name: name)
                }
            }
            try await group.waitForAll()
        }
        let data = try otaFetcher.data(name: "gui/StageActivityV2.json")
        let decoder = JSONDecoder()
        stageActivities = try decoder.decode([String: MAAStageActivity].self, from: data)
    }

    /// Load resources from bundled, user, and remote resources.
    ///
    /// Should be the outermost call to load resources.
    private func loadResource(channel: MAAClientChannel) async throws {
        defer { refreshCoreCapabilities() }
        blackflowStartAvailable = BlackflowStartSupport.matchesLoadedCore() && !channel.isGlobal
            && touchMode != .MacPlayTools && BlackflowStartSupport.matchesBundledResources(at: Bundle.main.resourceURL!)
        let (preferUser, currentResourceVersion) = try resourceChannel.version()
        try await loadResource(url: Bundle.main.resourceURL!, channel: channel)

        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if preferUser {
            try await reloadResources(channel: channel)
            logTrace(
                """
                外部资源版本：\(currentResourceVersion.title)
                更新时间：\(currentResourceVersion.last_updated)
                """)
        } else {
            logTrace(
                """
                内置资源版本：\(currentResourceVersion.title)
                更新时间：\(currentResourceVersion.last_updated)
                """)
            let url = documentsDirectory.appendingPathComponent("resource", isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }

        do {
            try await fetchOTAResource(channel: channel)
            let cachedBaseURL = documentsDirectory.appendingPathComponent("cache")
            try await loadResource(url: cachedBaseURL, channel: channel)
        } catch {
            logError("关卡数据获取失败: \(error.localizedDescription)")
            // 离线回退：上次成功下载的活动缓存仍可支撑今日提示与目录，
            // 已过期组由开放谓词排除。
            let cachedURL = documentsDirectory
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("gui/StageActivityV2.json")
            if let cached = StageActivityCache.loadActivities(from: cachedURL) {
                stageActivities = cached
                logInfo("已加载离线关卡活动缓存")
            }
        }

        #if DEBUG
        guard false else { return }
        #endif

        Task {
            do {
                let version = try await self.resourceChannel.latestVersion()
                if version > currentResourceVersion.last_updated {
                    logInfo("发现新资源版本：\(version)")
                    if autoResourceUpdate {
                        showResourceUpdate = true
                    }
                } else {
                    logInfo("资源已是最新版本")
                }
            } catch {
                logError("无法检查资源更新: \(error.localizedDescription)")
            }
        }
    }

    private func updateChannel(channel: MAAClientChannel) {
        // Refresh the cached availability gate synchronously so it already
        // reflects the new channel while the async resource reload below is
        // still running; the global-channel branch performs no IO. The reload
        // refreshes it again once the new resources are loaded.
        refreshCoreCapabilities()

        for (index, task) in tasks.enumerated() {
            guard case .startup(var config) = task.task else {
                continue
            }

            config.client_type = channel

            tasks[index] = .init(id: task.id, task: .startup(config), enabled: task.enabled,
                                 runOnce: task.runOnce)
        }

        Task {
            try await loadResource(channel: channel)
        }
    }

    private func handleEarlyReturn(backTo: Status) {
        if status == .pending {
            status = backTo
        }
    }

    private static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private var instanceOptions: MAAInstanceOptions {
        [
            .TouchMode: touchMode.rawValue,
            .AdbLiteEnabled: (touchMode != .MacPlayTools && useAdbLite) ? "1" : "0",
        ]
    }

    private var adbPath: String {
        Bundle.main.url(forAuxiliaryExecutable: "adb")!.path
    }
}

// MARK: Daily Tasks

extension MAAViewModel {
    @discardableResult
    func applyDailyTaskCallback(_ update: DailyTaskCallbackUpdate, coreID: Int32?) -> Bool {
        guard let coreID, let context = dailyRunCoordinator.active,
              [.running, .stopping].contains(context.status),
              let id = taskIDMap[coreID],
              let index = dailyRunTasks?.firstIndex(where: { $0.id == id }),
              let original = dailyRunTasks?[index].task else { return false }
        do {
            let isCurrentProfile = context.profileID == dailyTaskProfile
            guard let updated = try DailyRunProfilePatchStore.apply(
                update, taskID: id, expected: original, profileID: context.profileID,
                currentTasks: isCurrentProfile ? tasks : nil, directory: tasksDirectory) else {
                logWarn("运行中的配置已被编辑，保留用户修改，未自动更新任务记录。")
                return false
            }
            // Only the callback field changes the frozen run view. Other edits
            // in the latest saved profile must not rewrite the running snapshot.
            if let snapshotUpdate = update.applying(to: original, expecting: original),
               let old = dailyRunTasks?[index] {
                dailyRunTasks?[index] = DailyTask(id: old.id, task: snapshotUpdate,
                                                  enabled: old.enabled, runOnce: old.runOnce)
            }
            if isCurrentProfile {
                isApplyingDailyCallbackPatch = true
                tasks = updated
                isApplyingDailyCallbackPatch = false
            }
            return true
        } catch {
            logError("运行配置回调更新失败：\(error.localizedDescription)")
            return false
        }
    }

    enum TaskStartResult: Equatable {
        case started
        case skipped
        case failed
    }

    @discardableResult
    func tryStartTasks() async -> Bool {
        await startDailyTasks() == .started
    }

    func startDailyTasks(origin: DailyRunOrigin = .manual, snapshot: DailyRunSnapshot? = nil, recoverGame: Bool = false, recoveryCurrent: (@MainActor () -> Bool)? = nil) async -> TaskStartResult {
        reconcileDailyRunStatus()
        guard canStartTasks else {
            return .skipped
        }

        do {
            try await beginTaskOperation()
        } catch {
            return .skipped
        }
        defer { isStartStopInFlight = false }

        do {
            logStore?.setDailyTasksDetailMode(.log)
            let snapshot = snapshot ?? DailyRunSnapshot(profileID: dailyTaskProfile, tasks: tasks)
            guard let runID = try dailyRunCoordinator.begin(profileID: snapshot.profileID, origin: origin) else { return .skipped }
            if dailyRunCoordinator.journalDegraded {
                // 日志已降级为内存模式:运行照常执行,仅提示跟踪方式与重启后果。
                logWarn("运行日志写入失败，本次运行仅在内存中跟踪，重启后将按中断恢复处理。")
            }
            forceRecoveryJournalFailureRunID = nil
            forceRecoveryAbortRequested = false
            dailyRunOutcome = .completed
            dailyRunChainFailed = false
            dailyRunTasks = snapshot.tasks
            userDataCallbackDeadline = nil
            startupCancellationRequested = false
            startupCancellationLocked = false
            defer {
                startupCancellationRequested = false
                startupCancellationLocked = false
            }
            if recoverGame { forceRecoveryInFlight = true }
            defer { if recoverGame && !forceRecoveryCleanupPending { forceRecoveryInFlight = false } }
            dailyStartCancelled = false
            runHookConfiguration = hookSettings.configuration
            status = .pending
            do {
                if runHookConfiguration.enabled, let command = runHookConfiguration.before {
                    try dailyRunCoordinator.transition(.preHook, for: runID)
                    guard let activeRun = dailyRunCoordinator.active, activeRun.id == runID else {
                        throw CancellationError()
                    }
                    let result = try await executeHook(command, context: activeRun, outcome: nil)
                    guard result.succeeded else {
                        // R3:宿主任务树取消（定时取消/计划编辑杀钩子进程）须
                        // 回归基点的 CancellationError → .cancelled，否则与
                        // 定时台账的 .cancelled 口径冲突;用户停止仍由
                        // dailyStartCancelled 优先兜底。
                        if result.cancelled { throw CancellationError() }
                        if result.timedOut { throw PreparationHookTimeout() }
                        throw PreparationHookFailure()
                    }
                }
                if dailyStartCancelled { throw CancellationError() }
                try Task.checkCancellation()
                try dailyRunCoordinator.transition(.connecting, for: runID)
                try await startTasks(snapshot: snapshot, runID: runID, recoverGame: recoverGame, recoveryCurrent: recoveryCurrent)
                // Poll this exact owner even if a global completion callback is
                // lost. The refresh-specific drain gate below prevents premature success.
                waitForDailyRunCompletion(runID: runID)
                if origin == .schedule {
                    AchievementStore.shared.record(.init(runID: runID, metric: .scheduledStart))
                }
                await finishDailyRunIfStopped(allowInFlight: true)
                return .started
            } catch {
                let recoveryCleanupFailed = error is ForcedRecoveryCleanupFailure
                let coreRunning = await handle?.running == true
                if recoveryCleanupFailed {
                    dailyRunOutcome = .failed
                    status = .busy
                    do { try dailyRunCoordinator.transition(.running, for: runID) }
                    catch {
                        forceRecoveryJournalFailureRunID = runID
                        logError("每日运行日志：\(error.localizedDescription)")
                    }
                    // Even a journal failure must not prevent safe eventual Core release.
                    waitForDailyRunCompletion(runID: runID)
                } else if coreRunning {
                    dailyRunOutcome = .failed
                    try dailyRunCoordinator.transition(.running, for: runID)
                    status = .busy
                } else {
                    let cleaned = await discardPreparedDailyTasks(for: runID)
                        && !(error is ForcedRecoveryCleanupFailure) && !(error is PreparationCleanupFailure)
                    // P04 结果四态:用户取消/任务树取消记 .cancelled;准备期钩
                    // 子超时与强制恢复超时记 .timedOut;其余为 .failed。取消判
                    // 别优先——停止请求与超时同时发生时以用户意志为准。
                    if dailyStartCancelled || error is CancellationError {
                        await finishDailyRun(runID, outcome: .cancelled, preparationCleanupSucceeded: cleaned)
                    } else if error is PreparationHookTimeout {
                        await finishDailyRun(runID, outcome: .timedOut, preparationCleanupSucceeded: cleaned)
                    } else if case .timedOut = error as? ForcedRecoveryFailure {
                        await finishDailyRun(runID, outcome: .timedOut, preparationCleanupSucceeded: cleaned)
                    } else {
                        await finishDailyRun(runID, outcome: .failed, preparationCleanupSucceeded: cleaned)
                    }
                }
                throw error
            }
        } catch {
            logError("StartTasksFailed: \(String(describing: error))")
            logInfo("CheckSettings")
            return .failed
        }
    }

    private func startTasks(snapshot: DailyRunSnapshot, runID: UUID, recoverGame: Bool = false, recoveryCurrent: (@MainActor () -> Bool)? = nil) async throws {
        var runTasks = snapshot.tasks
        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        let scope = inventoryScope
        let targets = runTasks.indices.filter { index in
            guard runTasks[index].enabled, case .fight(let config) = runTasks[index].task else { return false }
            return config.inventoryTarget != nil
        }
        try InventoryTargetPlanner.validateQueue(targetIndices: targets, firstEnabledIndex: runTasks.firstIndex(where: \.enabled))
        var frozenPlan: InventoryTargetPlan?
        var reachedTaskID: UUID?
        var frozenItemID: String?
        if let targetIndex = targets.first, case .fight(let config) = runTasks[targetIndex].task,
           let target = config.inventoryTarget {
            guard await handle?.connected == true else {
                invalidateInventory()
                throw InventoryTargetError.recognitionRequired
            }
            // Starting/relaunching the client after recognition invalidates its account scope.
            guard !runTasks.contains(where: { task in
                if task.enabled, case .startup(let startup) = task.task { return startup.start_game_enabled }
                return false
            }) else { throw InventoryTargetError.unsafeOrder }
            try FightConfiguration.initDropItems("zh-cn")
            let plan = try InventoryTargetPlanner.plan(target: target, snapshot: currentInventorySnapshot,
                                                       knownItems: Set(FightConfiguration.inventoryDropItems.map(\.id)))
            frozenPlan = plan
            frozenItemID = target.itemID
            if plan.requiredDrops == 0 {
                runTasks[targetIndex].enabled = false
                reachedTaskID = runTasks[targetIndex].id
            } else {
                runTasks[targetIndex] = DailyTask(id: runTasks[targetIndex].id,
                    task: .fight(config.preparingInventoryTarget(plan)), enabled: true)
            }
        }

        var firstStart = true
        for (index, task) in runTasks.enumerated() {
            guard case .startup(var config) = task.task else {
                continue
            }

            config.client_type = clientChannel
            runTasks[index] = .init(id: task.id, task: .startup(config), enabled: task.enabled,
                                    runOnce: task.runOnce)

            if touchMode == .MacPlayTools, task.enabled, config.start_game_enabled, firstStart {
                // Do not launch or switch a PlayCover game before recovery proves
                // the current session is safe. This mode must be configured without
                // automatic game launch for forced handoff.
                if recoverGame { throw ForcedRecoveryFailure.notReady }
                guard await startGame(client: config.client_type) else {
                    throw MAAError.gameStartFailed
                }
                firstStart = false
            }
        }

        for (index, task) in runTasks.enumerated() {
            guard case .closedown(var config) = task.task else {
                continue
            }

            config.client_type = clientChannel
            runTasks[index] = .init(id: task.id, task: .closedown(config), enabled: task.enabled)
        }

        // 同一批次可能存在多个 Mall 任务：若都放行信用战/好友访问，第一个完成后第二个早已提交给
        // core，同一游戏日重复执行。这里按注入时刻的游戏日共享判定，每种每日任务只放行首个待执行
        // 的 Mall，其余回写当日日期；判定基准同时物化为 batchSnapshotDate，参数闸门与预标记共用
        // 同一时刻，append 前跨 04:00 也不会同批双放行（次日自愈）。
        //
        // 注入与 append 共用同一份任务快照：ensureHandle 的 await 窗口内新增的任务不进入本批次
        // （避免绕过渠道注入与同批去重），窗口内保存的陈旧草稿也无法回滚已物化进快照的预标记；
        // 两者均在下一轮生效。冻结快照(runTasks)承载预标记;活档按 id 位置对齐回写,不覆盖窗口内
        // 的新增编辑(161/179 族快照权威语义)。
        let mallSnapshotDate = Date.now
        let mallCalendar = clientChannel.calendar
        var mallIndices: [Int] = []
        var mallEntries: [(enabled: Bool, config: MallConfiguration)] = []
        for (index, task) in runTasks.enumerated() {
            guard case .mall(let config) = task.task else {
                continue
            }
            mallIndices.append(index)
            mallEntries.append((enabled: task.enabled, config: config))
        }

        let admissions = MallConfiguration.batchDailyAdmissions(
            of: mallEntries, snapshotDate: mallSnapshotDate, calendar: mallCalendar)

        var premarked = false
        for (index, admission) in zip(mallIndices, admissions) {
            guard case .mall(var config) = runTasks[index].task else {
                continue
            }

            config.clientChannel = clientChannel
            config.batchSnapshotDate = mallSnapshotDate

            if let markedDate = admission.creditFightMarkedDate {
                config.creditFightDate = markedDate
            }
            if let markedDate = admission.friendVisitMarkedDate {
                config.friendVisitDate = markedDate
            }

            runTasks[index] = .init(id: runTasks[index].id, task: .mall(config), enabled: runTasks[index].enabled)
            premarked = true
        }

        if premarked {
            var liveBatch = tasks
            for (index, admission) in zip(mallIndices, admissions) {
                guard index < liveBatch.count, liveBatch[index].id == runTasks[index].id,
                      case .mall(var config) = liveBatch[index].task else {
                    continue
                }
                config.clientChannel = clientChannel
                config.batchSnapshotDate = mallSnapshotDate
                if let markedDate = admission.creditFightMarkedDate {
                    config.creditFightDate = markedDate
                }
                if let markedDate = admission.friendVisitMarkedDate {
                    config.friendVisitDate = markedDate
                }
                liveBatch[index] = .init(id: liveBatch[index].id, task: .mall(config), enabled: liveBatch[index].enabled)
            }
            if liveBatch != tasks {
                tasks = liveBatch
            }
        }

        dailyRunTasks = runTasks
        try Task.checkCancellation()
        try await ensureHandle(requireConnect: frozenPlan == nil)
        try Task.checkCancellation()
        if let plan = frozenPlan {
            guard inventoryScope == scope, let frozenItemID,
                  await handle?.connected == true else { throw InventoryTargetError.stalePreparation }
            try InventoryTargetPlanner.validateFrozen(plan, itemID: frozenItemID, snapshot: currentInventorySnapshot)
        }
        if let reachedTaskID {
            taskStatus[reachedTaskID] = .success
            logInfo("Inventory.AlreadyReached")
        }
        if recoverGame {
            try await recoverGameToHome(runID: runID, isCurrent: recoveryCurrent ?? { true })
            forceRecoveryInFlight = false
        }
        try Task.checkCancellation()

        // 连接期间配置可能被编辑；连接完成后再归一化，保证存储值与下发参数一致。
        for (index, task) in runTasks.enumerated() {
            guard case .fight(var config) = task.task else {
                continue
            }

            let normalized = FightConfiguration.normalizedStage(config.stage)
            if normalized != config.stage {
                config.stage = normalized
                runTasks[index] = .init(id: task.id, task: .fight(config), enabled: task.enabled)
            }
        }

        // Validate the entire enabled queue before appending any task. A rejected
        // configuration must not leave earlier tasks queued on the reused handle.
        let supportsBlackflowStart = blackflowStartAvailable && touchMode != .MacPlayTools && !clientChannel.isGlobal
        for task in runTasks where task.enabled {
            if case .roguelike(let config) = task.task {
                try config.validateBlackflowStart(available: supportsBlackflowStart)
            }
        }

        try checkStartupCancellation()
        if recoverGame, recoveryCurrent?() == false { throw CancellationError() }
        startupCancellationLocked = true
        try dailyRunCoordinator.transition(.running, for: runID)

        let inventoryRunID = UUID()
        var inventoryFightIDs = Set<Int32>()
        var appendedAnyTask = false
        // G18：新运行开始前清残留战斗态（防上一轮异常收口后的陈旧标志）。
        activeRunHasRoguelike = false
        roguelikeInCombat = false
        do {
            for task in runTasks {
                try Task.checkCancellation()
                guard task.enabled else { continue }

                if case .userdataupdate(let config) = task.task {
                    let ids = try await appendDailyUserDataUpdate(task: task, config: config, runID: runID, scope: scope)
                    appendedAnyTask = appendedAnyTask || !ids.isEmpty
                    continue
                }
                let coreID: Int32?
                if case .fight(let config) = task.task {
                    let now = Date.now
                    // F06 每周执行日：按区服游戏日（HGCalendar 04:00 重置）判定，
                    // 未勾选的星期跳过本任务并记录（对齐 upstream SerializeTask 的
                    // SkippedWeeklySchedule；周计划不进 Core 参数）。
                    if let weeklyDays = config.weeklyDays,
                        !weeklyDays.contains(clientChannel.calendar.weekday(for: now)) {
                        logInfo("周计划今日未勾选，已跳过「\(config.subtitle)」")
                        continue
                    }
                    let context = StageActivityContext(channel: clientChannel, activities: stageActivity)
                    if context.medicineWindow(at: now, enabled: config.useActivityMedicine) == .unavailable {
                        logInfo("活动数据不可用，沿用原临期药设置")
                    }
                    let catalog = StageCatalog(context: context)
                    // F20 关卡重置策略：已轮换出目录的活动形主选按策略重置为
                    // 「当前/上次」（仅未启用备选时生效）。
                    let resetFrom = config.resetStageForDispatch(at: now, catalog: catalog)
                    if let resetFrom {
                        logInfo("已将过期活动关卡「\(resetFrom)」重置为当前/上次")
                    }
                    // F05 备选关卡：与可选目录同源解析，全部关闭时明确跳过本任务。
                    let resolution = config.resolvedStagePlan(at: now, catalog: catalog)
                    switch resolution.outcome {
                    case .skipAllClosed:
                        logInfo("备选关卡今日全部关闭，已跳过「\(config.subtitle)」")
                        continue
                    case .dispatch(let resolvedStage):
                        if let blocked = resolution.truncatedAfter {
                            logWarn(
                                blocked.isEmpty
                                    ? "「当前/上次」为常驻候选，其后的备选关卡不会被执行"
                                    : "「\(blocked)」为常驻关卡，其后的备选关卡不会被执行")
                        }
                        var dispatchConfig = config
                        dispatchConfig.stage = resetFrom != nil ? "" : resolvedStage
                        let params = dispatchConfig.params(at: now, stageActivity: context)
                        coreID = try await handle?.appendTask(type: .Fight, params: params.jsonString())
                        if let coreID {
                            fightTaskParams[coreID] = params
                            inventoryFightIDs.insert(coreID)
                        }
                    }
                } else if case .infrast(var dispatchConfig) = task.task {
                    // B13 每周执行日：与 F06 每周执行日同构（GUI 侧门控跳过并
                    // 记录，对齐 upstream SkippedWeeklySchedule；周计划不进
                    // Core 参数）。谓词与模型层 isScheduled(on:) 同源。
                    if !dispatchConfig.isScheduled(on: clientChannel.calendar.weekday(for: Date.now)) {
                        logInfo("周计划今日未勾选，已跳过「\(dispatchConfig.subtitle)」")
                        continue
                    }
                    // Only automatic selection resolves periods; fixed selection
                    // dispatches the saved plan_index without changing the profile.
                    if dispatchConfig.mode == .custom,
                        dispatchConfig.planSelection == .automatic,
                        let plan = try? MAAInfrast(path: dispatchConfig.filename) {
                        if plan.hasMixedPeriods {
                            logWarn("部分班次未设置时间段，自动选择时无匹配将使用第一个班次。")
                        }
                        if let rotated = dispatchConfig.resolvedPlanIndex(at: Date.now, plan: plan) {
                            let name = plan.plans[rotated].name ?? "\(rotated)"
                            logInfo("时间轮换 (\(name))")
                            dispatchConfig.plan_index = rotated
                        }
                    }
                    coreID = try await handle?.appendTask(.infrast(dispatchConfig),
                                                      recruitTagNames: recruitTagNames,
                                                      blackflowStartAvailable: supportsBlackflowStart,
                                                      supportsRoguelikeSeedInput: touchMode != .MacPlayTools)
                } else {
                    if case .roguelike = task.task { activeRunHasRoguelike = true }
                    coreID = try await handle?.appendTask(task.task, recruitTagNames: recruitTagNames,
                                                      blackflowStartAvailable: supportsBlackflowStart,
                                                      supportsRoguelikeSeedInput: touchMode != .MacPlayTools)
                }
                if let coreID {
                    appendedAnyTask = true
                    taskIDMap[coreID] = task.id
                    achievementEvents.register(taskID: coreID, runID: runID)
                }
            }
            // Appending crosses actors. Re-check only after the last suspension,
            // before submitting this frozen set to Core.
            if let plan = frozenPlan {
                let connected = await handle?.connected == true
                guard inventoryScope == scope, connected, let frozenItemID else {
                    throw InventoryTargetError.stalePreparation
                }
                try InventoryTargetPlanner.validateFrozen(plan, itemID: frozenItemID, snapshot: currentInventorySnapshot)
            }
            try Task.checkCancellation()
            inventory.beginRun(id: inventoryRunID, taskIDs: inventoryFightIDs)
            if let plan = frozenPlan {
                logTrace(verbatim: "Inventory generation=\(plan.generation) run=\(inventoryRunID) base=\(plan.startInventory) drops=\(plan.requiredDrops)")
            }
            if appendedAnyTask {
                userDataUpdateRun.beginExecution()
                try await startCoreTasks(recordDailyTaskStart: true)
            }
        } catch {
            cancelDailyUserDataUpdates()
            if await handle?.running == true {
                status = .busy
            } else if appendedAnyTask || !taskIDMap.isEmpty {
                // Assistant::stop clears m_tasks_list, including tasks appended
                // while idle. A rejected preparation must never leak into a later run.
                do { try await handle?.stop() }
                catch {
                    messageTask?.cancel()
                    messageTask = nil
                    handle = nil
                    // 原生停止失败已就地隔离句柄;抛出专用错误让外层收口把
                    // cleanupSucceeded 如实记为 false,而非视为已清理。
                    throw PreparationCleanupFailure()
                }
                taskIDMap.removeAll()
                taskStatus.removeAll()
                invalidateInventory()
            }
            throw error
        }
    }

    /// Freeze the target at the occurrence, not after the previous run stops.
    /// Reject unsupported PlayCover auto-launch before stopping the old run.
    func forceRecoveryEligibility(snapshot: DailyRunSnapshot) -> @MainActor () -> Bool {
        let channel = clientChannel
        let address = connectionAddress
        let adb = adbPath
        let touch = touchMode
        let tools = toolsMode
        let gzip = useGzip
        let adbLite = useAdbLite
        let supportsRecovery = !(touch == .MacPlayTools && snapshot.tasks.contains { task in
            guard task.enabled, case .startup(let config) = task.task else { return false }
            return config.start_game_enabled
        })
        return { [weak self] in
            guard let self else { return false }
            return supportsRecovery && self.dailyTaskProfile == snapshot.profileID &&
                self.clientChannel == channel && self.connectionAddress == address && self.adbPath == adb &&
                self.touchMode == touch && self.toolsMode == tools && self.useGzip == gzip && self.useAdbLite == adbLite
        }
    }

    /// After an interrupted run, Core can be idle while the game is still in battle.
    /// Recover in an isolated task and require a real home-template callback before
    /// any of the user's tasks may be queued.
    private func recoverGameToHome(runID: UUID, isCurrent: @escaping @MainActor () -> Bool, timeout: TimeInterval = 300, cleanupTimeout: TimeInterval = 5) async throws {
        guard let handle, dailyRunCoordinator.active?.id == runID else { throw CancellationError() }
        guard !forceRecoveryAbortRequested else { throw CancellationError() }
        let expires = Date().addingTimeInterval(timeout)
        do {
            // Native StartUp disables retries into a new fight, game launch and account switching.
            let startup = StartupConfiguration(client_type: clientChannel, start_game_enabled: false, account_name: "")
            let startupParams = try startup.params.jsonString()
            // The Home match is mandatory even when the navigation chain completes.
            let verify = try ["task_names": ["Home", "Home@QuickSwitch@ToHome@Entry", "Home@QuickSwitch@ToHome@Open"]].jsonString()
            func stopForRetry() async throws {
                try await handle.stop()
                let retryDeadline = min(expires, Date().addingTimeInterval(cleanupTimeout))
                while await handle.running {
                    try Task.checkCancellation()
                    guard Date() < retryDeadline, isCurrent(), dailyRunCoordinator.active?.id == runID else { throw ForcedRecoveryFailure.timedOut }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard Date() < expires, isCurrent(), dailyRunCoordinator.active?.id == runID else { throw CancellationError() }
                forceRecovery = nil
            }
            do {
                try await runRecoveryTask(handle: handle, runID: runID, type: .StartUp,
                                          params: startupParams, chain: "StartUp", requiresHome: false, expires: expires, isCurrent: isCurrent)
            } catch ForcedRecoveryFailure.resultStalled {
                // Core may have reached the stage screen without reporting further
                // progress. Stop it first, then attempt verified home navigation.
                try await stopForRetry()
                do {
                    try await runRecoveryTask(handle: handle, runID: runID, type: .Custom,
                                              params: verify, chain: "Custom", requiresHome: true, expires: expires, isCurrent: isCurrent)
                    return
                } catch ForcedRecoveryFailure.notReady {
                    // Still on a result screen: stop and retry StartUp once.
                    try await stopForRetry()
                    do {
                        try await runRecoveryTask(handle: handle, runID: runID, type: .StartUp,
                                                  params: startupParams, chain: "StartUp", requiresHome: false, expires: expires, isCurrent: isCurrent)
                    } catch ForcedRecoveryFailure.resultStalled {
                        // A second result screen can clear after its click without
                        // StartUp recognizing the stage. Make one final home check.
                        try await stopForRetry()
                    }
                }
            }
            try await runRecoveryTask(handle: handle, runID: runID, type: .Custom,
                                      params: verify, chain: "Custom", requiresHome: true, expires: expires, isCurrent: isCurrent)
        } catch {
            var cleaned = false
            do {
                try await handle.stop()
                let cleanupDeadline = Date().addingTimeInterval(cleanupTimeout)
                repeat {
                    if await handle.running == false { cleaned = true; break }
                    // Cleanup must continue even when the caller was cancelled.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                } while Date() < cleanupDeadline
            } catch { cleaned = false }
            guard cleaned else {
                // Keep Core and callback isolation until a later idle observation.
                forceRecoveryCleanupPending = true
                throw ForcedRecoveryCleanupFailure()
            }
            messageTask?.cancel()
            messageTask = nil
            self.handle = nil
            forceRecovery = nil
            throw error
        }
    }

    private func runRecoveryTask(handle: MAAHandle, runID: UUID, type: MAATaskType, params: String,
                                 chain: String, requiresHome: Bool, expires: Date, isCurrent: @escaping @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        guard !forceRecoveryAbortRequested else { throw CancellationError() }
        guard isCurrent(), dailyRunCoordinator.active?.id == runID else { throw CancellationError() }
        guard Date() <= expires else { throw ForcedRecoveryFailure.timedOut }
        let taskID = try await handle.appendTask(type: type, params: params)
        try Task.checkCancellation()
        guard !forceRecoveryAbortRequested else { throw CancellationError() }
        guard isCurrent(), dailyRunCoordinator.active?.id == runID else { throw CancellationError() }
        guard Date() <= expires else { throw ForcedRecoveryFailure.timedOut }
        forceRecovery = ForcedGameRecovery(taskID: taskID, chain: chain, requiresHome: requiresHome)
        try await handle.start()
        while Date() <= expires {
            try Task.checkCancellation()
            guard !forceRecoveryAbortRequested else { throw CancellationError() }
            guard isCurrent(), dailyRunCoordinator.active?.id == runID, let state = forceRecovery else { throw CancellationError() }
            if state.failed { throw ForcedRecoveryFailure.notReady }
            if chain == "StartUp", let resultSince = state.resultSince, !state.completed,
               Date().timeIntervalSince(resultSince) >= 20 { throw ForcedRecoveryFailure.resultStalled }
            if state.completed && state.allCompleted {
                guard state.verified else { throw ForcedRecoveryFailure.notReady }
                if await handle.running == false {
                    try Task.checkCancellation()
                    guard Date() <= expires, isCurrent(), dailyRunCoordinator.active?.id == runID, forceRecovery?.taskID == taskID else { throw CancellationError() }
                    forceRecovery = nil
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ForcedRecoveryFailure.timedOut
    }

    private func initScheduledDailyTaskTimer() {
        scheduledDailyTaskTimers = {
            guard let serializedString = serializedScheduledDailyTaskTimers else {
                return []
            }

            return JSONHelper.json(from: serializedString, of: [DailyTaskTimer].self) ?? []
        }()
        $scheduledDailyTaskTimers
            .sink { [weak self] value in
                guard let self else {
                    return
                }

                guard let jsonString = try? value.jsonString() else {
                    print("Skip saving $scheduledDailyTaskTimers. Failed to serialize daily task timer.")
                    return
                }

                guard jsonString != self.serializedScheduledDailyTaskTimers else {
                    return
                }

                self.serializedScheduledDailyTaskTimers = jsonString
            }
            .store(in: &cancellables)
    }

    func appendNewTaskTimer() {
        guard scheduledDailyTaskTimers.count < SchedulePublication.maxPlanCount else {
            logError("后台定时最多支持 \(SchedulePublication.maxPlanCount) 条计划，请先删除不需要的计划。")
            return
        }
        scheduledDailyTaskTimers.append(DailyTaskTimer(id: UUID(), hour: 9, minute: 0, isEnabled: false))
    }
}

// MARK: - Unified Run Entry Boundary (P04 · Q01/Q02)

extension MAAViewModel {
    /// 定时、热键、通知、远控共用的入口薄层：准入判别、runID 归属、终态判
    /// 别与停止路由的单一命名面。不引入新状态——占用互斥仍由 beginTaskOperation
    /// 承载，运行账目仍由 DailyRunCoordinator 承载；工具入口（作业/识别/小
    /// 游戏）经同一准入获得占用保证，但按既有语义不落协调器账、不触发运行
    /// 钩子与一次性消费。
    ///
    /// 当前有效运行的归属凭据；nil 表示无日常运行（工具运行按既有语义不落
    /// 协调器账，判断实例空闲请结合 status / canStartTasks）。同一实例同一
    /// 时刻至多一个；终态落账后即清空，迟到的停止/替换请求凭 runID 在协调
    /// 器内被拒绝。
    var activeRun: RunContext? { dailyRunCoordinator.active }

    /// 最近一次完整终态：completed/failed/cancelled/timedOut/interrupted。
    var lastRunOutcome: DailyRunOutcome? { dailyRunCoordinator.lastTerminal?.outcome }

    /// 停止入口可用性：与停止键（TaskButtons）同源。启动/停止互斥期与后置
    /// 清理期不可停止；肉鸽等待期仍可再次请求立即停止。
    /// 强制恢复中止窗口该谓词同为 false（按钮禁用），但 stop() 程序化路径
    /// 不经此谓词，保留中止恢复途径。
    var canStopTasks: Bool {
        (!isStartStopInFlight || roguelikeWaitingForCombat) && dailyRunCoordinator.active?.status != .postHook
    }

    /// 请求启动一次日常运行：准入冲突（已有运行/占用中）返回 nil，冲突由
    /// startDailyTasks 记日志；成功返回本次运行的 runID，供停止路由、通知
    /// 归属与迟到回调判别使用。极快收口时 active 已清空，此刻 lastTerminal
    /// 即本次运行（均在主 actor 上读取，无交错）。
    @discardableResult
    func requestDailyRun(origin: DailyRunOrigin, snapshot: DailyRunSnapshot? = nil) async -> UUID? {
        guard await startDailyTasks(origin: origin, snapshot: snapshot) == .started else { return nil }
        return dailyRunCoordinator.active?.id ?? dailyRunCoordinator.lastTerminal?.id
    }

    /// 请求停止当前运行。无可停对象（空闲且无运行）返回 false 且不触碰
    /// Core；占用/后置清理等拒绝情形由 stop 记日志，此处收敛为 Bool 供
    /// 热键/远控判别。准入门与热键停止路由一致：状态非空闲或存在运行即可尝试。
    @discardableResult
    func requestStopRun() async -> Bool {
        guard status != .idle || dailyRunCoordinator.active != nil else { return false }
        do { try await stop(); return true } catch { return false }
    }
}

// MARK: - Profile Management (P03.2 / Q03)

extension MAAViewModel {
    var profileStore: ProfileStore {
        ProfileStore(rootURL: tasksDirectory)
    }

    /// 切换活跃档案：先读取新档案任务、再落 active 指针与 UI 状态，读取
    /// 失败时保持原档案不动。P03.3：除 UI 禁用外这里对运行直接拒绝——
    /// 程序化调用与 UI 同受此限；运行占用之外，冻结快照尚存的收口窗口
    /// 同样拒绝，避免切换污染快照或令回写/一次性消费的 isCurrentProfile
    /// 判别错位（回写本身按 RunContext.profileID 路由，不随切换漂移）。
    func switchProfile(_ profileID: String) {
        guard profileID != dailyTaskProfile else { return }
        guard canStartTasks, dailyRunTasks == nil else {
            logError("任务正在运行，请先停止后再切换档案。")
            return
        }
        do {
            let reloaded = try profileStore.loadTasks(profileID: profileID)
            try profileStore.setActive(profileID)
            dailyTaskProfile = profileID
            tasks = reloaded
            reloadProfileIdentities()
        } catch {
            logError("切换档案失败：\(error.localizedDescription)")
        }
    }

    func createProfile(named name: String) {
        performProfileMutation { try $0.create(name: name) } onFailure: { "新建档案失败：\($0.localizedDescription)" }
    }

    func duplicateProfile(_ profileID: String) {
        performProfileMutation { try $0.duplicate(profileID) } onFailure: { "复制档案失败：\($0.localizedDescription)" }
    }

    func renameProfile(_ profileID: String, to name: String) {
        performProfileMutation { try $0.rename(profileID, to: name) } onFailure: { "重命名档案失败：\($0.localizedDescription)" }
    }

    func deleteProfile(_ profileID: String) {
        performProfileMutation { try $0.delete(profileID) } onFailure: { "删除档案失败：\($0.localizedDescription)" }
    }

    /// 每个调用点用字面量错误文案，使各失败消息拥有独立的本地化 key。
    private func performProfileMutation(_ body: (ProfileStore) throws -> Void,
                                        onFailure message: (Error) -> LocalizedStringResource) {
        do {
            try body(profileStore)
            reloadProfileIdentities()
        } catch {
            logError(message(error))
        }
    }

    private func reloadProfileIdentities() {
        profileIdentities = (try? profileStore.list()) ?? []
    }
}

// MARK: Copilot

extension MAAViewModel {

    /// Secret Front availability depends on the client channel and the loaded
    /// resource tree. The check reads and parses resource files synchronously,
    /// so cache the outcome instead of recomputing it in every view update;
    /// `loadResource`/`reloadResources` refresh it whenever resources change,
    /// and channel switches refresh it immediately in `updateChannel`.
    ///
    /// Generalized in P02.2: the same refresh points now also rederive the
    /// full `coreCapabilities` snapshot. `secretFrontUnavailableReason` keeps
    /// its original semantics for the startup gate copy (its bool equivalent
    /// is `coreCapabilities.secretFrontAvailable`). Core version source is
    /// nil for now: Maa.swift exposes no AsstGetVersion wrapper (the C symbol
    /// exists in MaaCore's AsstCaller.h); wire it there first to lift
    /// `minimumCoreVersionMet`/recycle gating.
    private func refreshCoreCapabilities() {
        let baseRoot = secretFrontResourceRoot()
        // R2-1：series/recycle 判据改用覆盖层感知根（与 FightSettingsView
        // 的 series 上限同口径）；SecretFront 保持 base 根历史语义。
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let preferUser = (try? resourceChannel.version())?.0 ?? false
        let tasksRoot = CoreCapabilities.effectiveResourceRoot(
            channel: clientChannel,
            cacheRoot: documents.appendingPathComponent("cache"),
            userRoot: preferUser ? documents : nil,
            bundleRoot: Bundle.main.resourceURL!
        )
        coreCapabilities = CoreCapabilities.derive(
            coreVersion: nil,
            resourceRoot: baseRoot,
            channel: clientChannel,
            tasksResourceRoot: tasksRoot
        )
        secretFrontUnavailableReason = SecretFrontConfiguration.unavailableReason(
            isGlobalChannel: clientChannel.isGlobal,
            resourceRoot: { baseRoot }
        )
    }

    private func secretFrontResourceRoot() -> URL? {
        guard let bundled = Bundle.main.resourceURL,
            let (preferUser, _) = try? resourceChannel.version() else {
            return nil
        }
        let root = preferUser
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            : bundled
        return root.appendingPathComponent("resource")
    }

    private func appendTrackedTask(type: MAATaskType, params: String) async throws {
        if let id = try await handle?.appendTask(type: type, params: params) {
            achievementEvents.register(taskID: id, type: type.rawValue)
        }
    }

    func startCopilot(type: MAATaskType, params: String) async throws {
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }

        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        try await ensureHandle()
        try await appendTrackedTask(type: type, params: params)
        try await startCoreTasks()
    }

    /// C16：作业列表批量入队——占用与启动各一次，列表逐项 append（与 Core
    /// 队列模型 AsstAppendTask × N + AsstStart × 1 对齐，日常任务即此模式）。
    /// 中途 append 失败：用 Core stop 清空已入队残留（Assistant::stop 清任务
    /// 列表），不把半个作业集留在队列里，再上抛由入口记日志。
    func startCopilot(tasks: [(type: MAATaskType, params: String)]) async throws {
        guard !tasks.isEmpty else { return }
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }

        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        try await ensureHandle()
        do {
            for task in tasks {
                try await appendTrackedTask(type: task.type, params: task.params)
            }
        } catch {
            do { try await handle?.stop() } catch {
                logError(verbatim: "作业队列清理失败：\(error.localizedDescription)")
            }
            throw error
        }
        try await startCoreTasks()
    }
}

// MARK: Utility

extension MAAViewModel {
    func recognizeRecruit() async throws {
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }

        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        guard let params = try? recruitConfig.params(tagNames: recruitTagNames).jsonString() else {
            return
        }

        try await ensureHandle()
        try await appendTrackedTask(type: .Recruit, params: params)
        try await startCoreTasks()
    }

    func recognizeDepot() async throws {
        try await recognizeUserData(includeDepot: true, includeOperators: false)
    }

    /// One reservation and one Core start for both read-only recognition chains.
    func refreshUserData() async throws {
        try await recognizeUserData(includeDepot: true, includeOperators: true)
    }

    private func recognizeUserData(includeDepot: Bool, includeOperators: Bool) async throws {
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }
        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        let scope = inventoryScope
        try await ensureHandle()
        try Task.checkCancellation()
        guard inventoryScope == scope else { throw InventoryTargetError.stalePreparation }
        invalidateInventory()
        var appended = false
        do {
            if includeDepot {
                guard let id = try await handle?.appendTask(type: .Depot, params: "") else {
                    throw MaaCoreError.appendTaskFailed
                }
                appended = true
                inventoryDepotScope = scope
                inventoryDepotTaskID = id
                achievementEvents.register(taskID: id, type: MAATaskType.Depot.rawValue)
            }
            if includeOperators {
                guard let id = try await handle?.appendTask(type: .OperBox, params: "") else {
                    throw MaaCoreError.appendTaskFailed
                }
                appended = true
                operBoxHistoryScope = scope
                operBoxHistoryTaskID = id
                achievementEvents.register(taskID: id, type: MAATaskType.OperBox.rawValue)
            }
            try Task.checkCancellation()
            guard inventoryScope == scope else { throw InventoryTargetError.stalePreparation }
            try await startCoreTasks()
        } catch {
            invalidateInventory()
            if appended {
                do { try await handle?.stop() }
                catch {
                    messageTask?.cancel()
                    messageTask = nil
                    handle = nil
                    throw PreparationCleanupFailure()
                }
            }
            throw error
        }
    }

    func recognizeVideo(video url: URL) async throws {
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }

        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        let config = VideoRecognitionConfiguration(filename: url.path)
        guard let params = config.params else {
            return
        }

        try await ensureHandle(requireConnect: false)
        try await appendTrackedTask(type: .VideoRecognition, params: params)
        try await startCoreTasks()
    }

    func recognizeOperBox() async throws {
        try await recognizeUserData(includeDepot: false, includeOperators: true)
    }

    func gachaPoll(once: Bool) async throws {
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }

        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        try await ensureHandle()

        let name = once ? "GachaOnce" : "GachaTenTimes"
        let params = ["task_names": [name]]
        let data = try JSONSerialization.data(withJSONObject: params)
        let string = String(data: data, encoding: .utf8)

        try await appendTrackedTask(type: .Custom, params: string ?? "")
        try await startCoreTasks()
    }

    func miniGame(name: String, params: Any? = nil, secretFront: SecretFrontConfiguration? = nil) async throws {
        // P04 入口边界:与日常/作业入口共用同一准入(互斥占用 + 空闲复核 +
        // 钩子测试占用判别),不再以静默 no-op 吞掉冲突。
        try await beginTaskOperation()
        defer { isStartStopInFlight = false }

        status = .pending
        defer { handleEarlyReturn(backTo: .idle) }

        var didAppend = false
        var beganRun = false
        do {
            if secretFront != nil, let reason = secretFrontUnavailableReason {
                throw NSError(domain: "SecretFront", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            try await ensureHandle()
            guard let handle else { throw MaaCoreError.appendTaskFailed }
            var payload: [String: Any]
            if let secretFront {
                payload = secretFront.params
            } else {
                payload = ["task_names": [name]]
                if let params { payload["params"] = params }
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            let string = String(decoding: data, as: UTF8.self)
            let id = try await handle.appendTask(type: .Custom, params: string)
            didAppend = true
            if let secretFront {
                secretFrontRun.begin(taskID: id, configuration: secretFront)
                beganRun = true
            }
            // Publish before yielding: a fast completion callback must remain idle.
            status = .busy
            try await handle.start()
        } catch {
            // Failures caught here are startup-phase errors (connect, append,
            // start); in-run failures arrive as callbacks instead, so report a
            // startup failure rather than an in-game task failure. Only a run
            // begun by this call may be finished: a taskID still owned by an
            // earlier run (possible under leftover status pollution) must not
            // be reported or released here.
            secretFrontRun.finishStartupFailureIfOwned(beganRun: beganRun)
            if didAppend {
                do {
                    try await handle?.stop()
                } catch {
                    logError("停止任务失败: \(error.localizedDescription)")
                }
            }
            status = .idle
            throw error
        }
    }


}

// MARK: - Prevent Sleep

extension MAAViewModel {
    func switchAwakeGuard(_ newValue: Status) {
        switch newValue {
        case .busy, .pending:
            wakeupSystem()
            enableAwake()
        case .idle:
            disableAwake()
        }
    }

    // wakes the system from asleep
    private func wakeupSystem() {
        guard wakeupAssertionID == nil else { return }
        var assertionID: IOPMAssertionID = 0
        let name = "MAA is starting up, waking up the system"
        let result = IOPMAssertionDeclareUserActivity(name as CFString, kIOPMUserActiveLocal, &assertionID)
        if result == kIOReturnSuccess {
            wakeupAssertionID = assertionID
        }
    }

    // keeps the system from sleeping during tasks
    private func enableAwake() {
        guard awakeAssertionID == nil else { return }
        var assertionID: IOPMAssertionID = 0
        let name = "MAA is running; sleep is diabled."
        let properties =
            [
                kIOPMAssertionTypeKey: kIOPMAssertionTypeNoDisplaySleep as CFString,
                kIOPMAssertionNameKey: name as CFString,
                kIOPMAssertionLevelKey: UInt32(kIOPMAssertionLevelOn),
            ] as [String: Any]
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertionID)
        if result == kIOReturnSuccess {
            awakeAssertionID = assertionID
        }
    }

    private nonisolated static func releaseAssertion(_ assertionID: IOPMAssertionID?) {
        if let assertionID {
            let result = IOPMAssertionRelease(assertionID)
            if result != kIOReturnSuccess {
                // TODO: Replace with OSLog
                print("Failed to release PM assertion (\(result))")
            }
        }
    }

    private func disableAwake() {
        Self.releaseAssertion(awakeAssertionID)
        Self.releaseAssertion(wakeupAssertionID)
        self.awakeAssertionID = nil
        self.wakeupAssertionID = nil
    }
}

// MARK: - MaaTools Client

extension MAAViewModel {
    nonisolated func startGame(client: MAAClientChannel) async -> Bool {
        let appBundle = URL(fileURLWithPath: "/Users")
            .appendingPathComponent(NSUserName())
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
            .appendingPathComponent("Applications")
            .appendingPathComponent(client.appBundleID)
            .appendingPathExtension("app")

        do {
            try await NSWorkspace.shared.openApplication(at: appBundle, configuration: .init())
            let client = await MaaToolClient(address: connectionAddress)
            return client != nil
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 260 {
                await logError("无法找到游戏文件: \(client.appBundleID)")
            }
            return false
        }
    }

    func stopGame() async throws {
        guard let client = await MaaToolClient(address: connectionAddress) else { return }
        try await client.terminate()
    }
}

private enum ForcedRecoveryFailure: Error { case notReady, timedOut, resultStalled }
private struct ForcedRecoveryCleanupFailure: Error {}

// MARK: - Depot history integration

extension MAAViewModel {
    var depotHistoryStore: DepotHistoryStore {
        .init(directory: Self.userDirectory.appendingPathComponent("UserData/DepotHistory", isDirectory: true))
    }

    func persistDepotHistory(items: [String: Int], scope: InventoryScope) {
        guard scope == inventoryScope, !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try depotHistoryStore.save(items: items, complete: true, scope: scope) }
        catch { logError("仓库历史快照保存失败。") }
    }
}


// MARK: - Operator history integration

extension MAAViewModel {
    var operBoxHistoryStore: OperBoxHistoryStore {
        .init(directory: Self.userDirectory.appendingPathComponent("UserData/OperBoxHistory", isDirectory: true))
    }

    func persistOperBoxHistory(_ payload: OperBoxHistoryPayload, scope: InventoryScope) {
        guard scope == inventoryScope, !scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try operBoxHistoryStore.save(payload, scope: scope)
            operBoxHistoryRevision = UUID()
        } catch { logError("干员历史快照保存失败。") }
    }

    /// I04 一图流只读练度导入：不发 Core 任务，不受任务运行互斥限制（WPF 同为免检路径）。
    /// 失败保留既有快照；空数据（未绑定/未导入/全部跳过）不落盘覆盖；成功按当前
    /// InventoryScope 落盘并广播 revision。token 不进任何日志。
    func importOperBoxFromYituliu(localeIdentifier: String) async {
        guard !yituliuImportInFlight else { return }
        let token = yituliuOpenApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            yituliuImportMessage = String(localized: "一图流 Token 为空")
            return
        }
        yituliuImportInFlight = true
        defer { yituliuImportInFlight = false }
        let (verdict, data) = await YituliuOperBoxService().fetchOperatorInfo(token: token)
        switch verdict {
        case .valid:
            let catalog = OperatorCatalog.load(
                resourceDirectory: recruitResourceDirectory, localeIdentifier: localeIdentifier)
            let payload = YituliuOperBoxService.convert(data ?? [], catalog: catalog)
            guard !payload.ownedOperators.isEmpty else {
                yituliuImportMessage = String(localized: "一图流账号未绑定或未导入练度，已保留本地数据")
                return
            }
            do {
                try operBoxHistoryStore.save(payload, scope: inventoryScope)
                operBoxHistoryRevision = UUID()
                yituliuImportMessage = String(localized: "已导入 \(payload.ownedOperators.count) 名干员练度")
            } catch {
                yituliuImportMessage = String(localized: "练度快照保存失败：\(error.localizedDescription)")
            }
        case .writeOnly:
            yituliuImportMessage = String(localized: "一图流 Token 只有写入权限，无法读取练度")
        case .invalid:
            yituliuImportMessage = String(localized: "一图流 Token 无效或已失效")
        case .networkError:
            yituliuImportMessage = String(localized: "一图流网络请求失败")
        }
    }
}

// MARK: - Daily user-data composite

extension MAAViewModel {
    func appendDailyUserDataUpdate(task: DailyTask, config: UserDataUpdateConfiguration,
                                   runID: UUID, scope: InventoryScope) async throws -> [Int32] {
        guard let context = dailyRunCoordinator.active, context.id == runID, inventoryScope == scope else { throw CancellationError() }
        let runScope = InventoryScope(connection: scope.connection, server: scope.server,
                                      profile: context.profileID, account: scope.account)
        var admission = config
        if config.triggerInterval != .everyTime {
            // A successful manual recognition counts too, but only in this
            // exact scope. Missing/corrupt caches force a repair refresh.
            for kind in UserDataKind.allCases where kind == .depot ? config.updateDepot : config.updateOperBox {
                let receipt: UserDataSyncReceipt?
                do { receipt = try successfulUserDataReceipt(kind, scope: runScope) }
                catch {
                    receipt = nil
                    logWarn("历史资料不可用，将重新识别。")
                }
                if kind == .depot { admission.lastDepotSync = receipt }
                else { admission.lastOperBoxSync = receipt }
            }
        }
        let due = admission.dueKinds(scope: runScope, calendar: clientChannel.calendar, at: .now)
        guard !due.isEmpty else {
            taskStatus[task.id] = .skipped
            // This entry did not execute; a successful surrounding run must not
            // consume its runOnce flag.
            if let index = dailyRunTasks?.firstIndex(where: { $0.id == task.id }), let frozen = dailyRunTasks?[index] {
                dailyRunTasks?[index] = DailyTask(id: frozen.id, task: frozen.task, enabled: false, runOnce: frozen.runOnce)
            }
            logInfo("更新资料未到执行间隔或未选择识别内容，已跳过。")
            return []
        }
        if scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logInfo("未绑定本地账号标识，资料识别仍会执行，但不会按历史成功时间跳过后续更新。")
        }
        var ids = [Int32]()
        for kind in due {
            try Task.checkCancellation()
            guard dailyRunCoordinator.active?.id == runID, inventoryScope == scope else { throw CancellationError() }
            if kind == .operBox, yituliuOperBoxForDaily {
                // I04-b：干员资料改用一图流拉取，不进 Core 队列（WPF 同构）。WPF 为
                // fire-and-forget，Mac 在追加期同步等待：条目终态确定、无未观察异常，
                // 代价是最长一个请求超时的启动延迟（差异入档）。
                try await syncDailyOperBoxFromYituliu(taskID: task.id, scope: runScope)
                continue
            }
            let type: MAATaskType = kind == .depot ? .Depot : .OperBox
            guard let id = try await handle?.appendTask(type: type, params: "{}") else { throw MaaCoreError.appendTaskFailed }
            taskIDMap[id] = task.id
            try userDataUpdateRun.register(id, owner: .init(runID: runID, taskID: task.id, scope: runScope, kind: kind, observedProfile: scope.profile))
            achievementEvents.register(taskID: id, runID: runID)
            ids.append(id)
        }
        return ids
    }

    /// 日常「更新资料」的一图流干员拉取（I04-b）。Token 为空与 WPF 同构：直接失败整跑
    /// （WPF 在准入即 return false）。其余失败按条目级 .failure 收口、不中止跑（WPF
    /// fire-and-forget 的条目 Error 同语义）；成功写 runScope 快照并广播 revision。
    func syncDailyOperBoxFromYituliu(taskID: UUID, scope: InventoryScope) async throws {
        let token = yituliuOpenApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            taskStatus[taskID] = .failure
            logError("一图流 Token 为空，干员练度拉取失败。")
            throw YituliuDailyTokenEmpty()
        }
        let (verdict, data) = await YituliuOperBoxService()
            .fetchOperatorInfo(token: token, session: yituliuSession)
        switch verdict {
        case .valid:
            let catalog = OperatorCatalog.load(
                resourceDirectory: recruitResourceDirectory,
                localeIdentifier: Locale.preferredLanguages.first ?? "zh-Hans")
            let payload = YituliuOperBoxService.convert(data ?? [], catalog: catalog)
            guard !payload.ownedOperators.isEmpty else {
                taskStatus[taskID] = .failure
                logError("一图流账号未绑定或未导入练度，本轮干员资料未更新。")
                return
            }
            do {
                try operBoxHistoryStore.save(payload, scope: scope)
                operBoxHistoryRevision = UUID()
                taskStatus[taskID] = .success
                logInfo("一图流干员练度已更新（\(payload.ownedOperators.count) 名）。")
            } catch {
                taskStatus[taskID] = .failure
                logError("练度快照保存失败：\(error.localizedDescription)")
            }
        case .writeOnly:
            taskStatus[taskID] = .failure
            logError("一图流 Token 只有写入权限，无法读取练度。")
        case .invalid:
            taskStatus[taskID] = .failure
            logError("一图流 Token 无效或已失效。")
        case .networkError:
            taskStatus[taskID] = .failure
            logError("一图流网络请求失败。")
        }
    }

    func successfulUserDataReceipt(_ kind: UserDataKind, scope: InventoryScope) throws -> UserDataSyncReceipt? {
        let date: Date?
        switch kind {
        case .depot: date = try depotHistoryStore.load(scope: scope)?.capturedAt
        case .operBox: date = try operBoxHistoryStore.load(scope: scope)?.capturedAt
        }
        return date.map { .init(scope: scope, completedAt: $0) }
    }

    private func acceptsDailyUserData(_ coreID: Int32, kind: UserDataKind) -> Bool {
        guard userDataUpdateRun.executionSubmitted,
              let entry = userDataUpdateRun.entries[coreID], entry.owner.kind == kind,
              entry.owner.runID == dailyRunCoordinator.active?.id,
              entry.owner.scope.connection == inventoryScope.connection,
              entry.owner.scope.server == inventoryScope.server,
              entry.owner.scope.account == inventoryScope.account,
              entry.owner.observedProfile == inventoryScope.profile,
              [.pending, .running].contains(entry.progress) else { return false }
        return true
    }

    func receiveDailyDepot(_ depot: MAADepot?, coreID: Int32?) -> Bool {
        guard let coreID, userDataUpdateRun.entries[coreID] != nil else { return false }
        guard acceptsDailyUserData(coreID, kind: .depot) else { return true }
        userDataUpdateRun.record(depot.map { .depot(items: $0.items, complete: $0.done) }, coreID: coreID)
        if userDataUpdateRun.entries[coreID]?.owner.scope.profile == inventoryScope.profile { logStore?.setDepot(depot) }
        if userDataUpdateRun.entries[coreID]?.completionObserved == true { processDailyUserDataTerminal(coreID: coreID, code: 10002, taskchain: "Depot") }
        return true
    }

    func receiveDailyOperators(_ operators: MAAOperBox?, coreID: Int32?) -> Bool {
        guard let coreID, userDataUpdateRun.entries[coreID] != nil else { return false }
        guard acceptsDailyUserData(coreID, kind: .operBox) else { return true }
        userDataUpdateRun.record(operators.map { .operators($0.historyPayload) }, coreID: coreID)
        if userDataUpdateRun.entries[coreID]?.owner.scope.profile == inventoryScope.profile { logStore?.setOperBox(operators) }
        if userDataUpdateRun.entries[coreID]?.completionObserved == true { processDailyUserDataTerminal(coreID: coreID, code: 10002, taskchain: "OperBox") }
        return true
    }

    func processDailyUserDataTerminal(coreID: Int32, code: Int, taskchain: String) {
        guard userDataUpdateRun.executionSubmitted,
              let entry = userDataUpdateRun.entries[coreID],
              entry.owner.runID == dailyRunCoordinator.active?.id,
              taskchain == (entry.owner.kind == .depot ? "Depot" : "OperBox"),
              [.pending, .running].contains(entry.progress) else { return }
        switch code {
        case 10001:
            userDataUpdateRun.finish(coreID, as: .running)
        case 10000:
            userDataUpdateRun.finish(coreID, as: .failed)
            markDailyRunFailed()
        case 10004:
            cancelDailyUserDataUpdates()
            if !dailyRunChainFailed { dailyRunOutcome = .cancelled }
        case 10002:
            do {
                guard acceptsDailyUserData(coreID, kind: entry.owner.kind) else { throw InventoryTargetError.recognitionRequired }
                userDataUpdateRun.observeCompletion(coreID)
                guard let payload = entry.payload, payload.isComplete else {
                    // A terminal callback and the final recognition payload can
                    // arrive on adjacent MainActor turns. The idle drain gate
                    // bounds this wait and fails it if no complete payload arrives.
                    userDataUpdateRun.finish(coreID, as: .running)
                    publishUserDataProgress(taskID: entry.owner.taskID)
                    return
                }
                let now = Date.now
                let bound = !entry.owner.scope.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                switch payload {
                case .depot(let items, let complete):
                    try inventory.capture(items: items, complete: complete, scope: entry.owner.scope, now: now)
                    if bound { try depotHistoryStore.save(items: items, complete: complete, scope: entry.owner.scope, now: now) }
                case .operators(let operators):
                    if bound {
                        try operBoxHistoryStore.save(operators, scope: entry.owner.scope, now: now)
                        operBoxHistoryRevision = UUID()
                    }
                }
                if bound {
                    guard applyDailyTaskCallback(.userDataSync(entry.owner.kind, .init(scope: entry.owner.scope, completedAt: now)),
                                                 coreID: coreID) else { throw CocoaError(.fileWriteUnknown) }
                }
                userDataUpdateRun.finish(coreID, as: .succeeded)
            } catch {
                userDataUpdateRun.finish(coreID, as: .failed)
                markDailyRunFailed()
                logError("更新资料未完整完成或保存失败：\(error.localizedDescription)")
            }
        default: return
        }
        publishUserDataProgress(taskID: entry.owner.taskID)
    }

    private func publishUserDataProgress(taskID: UUID) {
        switch userDataUpdateRun.aggregate(for: taskID) {
        case .failed: taskStatus[taskID] = .failure
        case .cancelled: taskStatus[taskID] = .cancel
        case .succeeded: taskStatus[taskID] = .success
        case .running: taskStatus[taskID] = .running
        case .pending, nil: break
        }
    }

    func failIncompleteDailyUserDataUpdates(runID: UUID) {
        let unfinished = userDataUpdateRun.entries.filter {
            $0.value.owner.runID == runID && [.pending, .running].contains($0.value.progress)
        }
        guard !unfinished.isEmpty else { return }
        for (id, entry) in unfinished {
            userDataUpdateRun.finish(id, as: .failed)
            publishUserDataProgress(taskID: entry.owner.taskID)
        }
        userDataUpdateRun.cancelPending()
        markDailyRunFailed()
        logError("资料更新缺少完整结束回调，本轮按失败收口。")
    }

    func cancelDailyUserDataUpdates() {
        userDataUpdateRun.cancelPending()
        for taskID in Set(userDataUpdateRun.entries.values.map { $0.owner.taskID }) { publishUserDataProgress(taskID: taskID) }
    }

    /// Composite progress is handled exclusively by the owned subtask tracker.
    func updateDailyTaskStatus(_ value: TaskStatus, coreID: Int32?) {
        guard let coreID, userDataUpdateRun.entries[coreID] == nil, let id = taskIDMap[coreID] else { return }
        taskStatus[id] = value
    }
}
