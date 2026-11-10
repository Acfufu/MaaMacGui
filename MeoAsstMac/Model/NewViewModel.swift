//
//  NewViewModel.swift
//  MAA
//
//  Created by hguandl on 2026/8/8.
//

import Combine
import Foundation
import Observation
import os

// TODO: Mirgrate all bridges
@Observable final class NewViewModel {
    private(set) var copilot = CopilotContext()

    /// A unique token that changes whenever a copilot task starts.
    ///
    /// Observe changes to this value to detect the start of a copilot task.
    private(set) var copilotStartToken: UUID?

    /// The progress of the current copilot download.
    ///
    /// A `nil` value indicates that no download is in progress.
    /// Progress is updated only for copilot sets, based on the number of copilots downloaded.
    ///
    /// Cancellation is not currently supported.
    private(set) var copilotDownloadProgress: Progress?

    /// The URL of the most recently imported copilot.
    ///
    /// Observe this value to update and select the corresponding list entry after an import.
    var lastImportedCopilot: URL?

    // MARK: - Log

    struct SanityReport: Sendable {
        let current: Int
        let maximum: Int
        let reportedAt: Date?
    }

    struct FightReport: Sendable {
        let sanityCost: Int?
        let series: Int?
        let timesFinished: Int?
        let finished: Bool?
    }

    private(set) var logs = [MAALog]()
    var trackTail = false
    @ObservationIgnored private var logStoreContinuation: AsyncStream<MAALog>.Continuation?
    @ObservationIgnored private var logStoreTask: Task<Void, Never>?

    var screencapCost: (min: Int, max: Int, avg: Int)?
    @ObservationIgnored var lastScreencapWarningLevel = 0
    @ObservationIgnored var hasPrintedFPSHighTip = false
    @ObservationIgnored var taskStartTime: Date?
    @ObservationIgnored var sanityReport: SanityReport?
    @ObservationIgnored var fightReport: FightReport?
    @ObservationIgnored var stoneUsedTimes = 0
    @ObservationIgnored var recruitConfirmTimes = 0
    /// C12 会话内已评价的作业站 id（WPF _recentlyRatedCopilotId 同构）。
    @ObservationIgnored private var recentlyRatedCopilotIDsBacking =
        OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    private var recentlyRatedCopilotIDs: Set<Int> {
        get { recentlyRatedCopilotIDsBacking.withLock { $0 } }
        set { recentlyRatedCopilotIDsBacking.withLock { $0 = newValue } }
    }

    // MARK: - Recognition

    private(set) var depot: MAADepot?
    private(set) var operBox: MAAOperBox?

    // MARK: - Bridges to Old View Model

    private let parent: MAAViewModel

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    @MainActor var status: MAAViewModel.Status {
        access(keyPath: \.status)
        return parent.status
    }

    @MainActor var canStartTasks: Bool {
        access(keyPath: \.canStartTasks)
        return parent.canStartTasks
    }

    var dailyTasksDetailMode = MAAViewModel.DailyTasksDetailMode.log

    @MainActor init(parent: MAAViewModel) {
        self.parent = parent
        parent.logStore = self
        parent.objectWillChange.sink { [weak self] _ in
            self?.withMutation(keyPath: \.canStartTasks) {}
        }
        .store(in: &cancellables)


        do {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appending(path: "debug/")
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            let fileLogger = try FileLogger(url: dir.appending(path: "gui.log"))

            let (stream, continuation) = AsyncStream<MAALog>.makeStream()
            logStoreContinuation = continuation

            logStoreTask = Task.detached(name: "LogStore") {
                for await entry in stream {
                    fileLogger.write(entry)
                }
            }
        } catch {
            let content = String(localized: "日志文件出错: \(error.localizedDescription)")
            logs.append(.init(date: .now, content: content, color: .error))
        }

        parent.objectWillChange.sink { [weak self] _ in
            self?.withMutation(keyPath: \.canStartTasks) {}
        }
        .store(in: &cancellables)

        parent.$status.sink { [weak self] _ in
            self?.withMutation(keyPath: \.status) {}
            self?.withMutation(keyPath: \.canStartTasks) {}
        }
        .store(in: &cancellables)

        parent.$isStartStopInFlight.sink { [weak self] _ in
            self?.withMutation(keyPath: \.canStartTasks) {}
        }
        .store(in: &cancellables)
    }

    deinit {
        logStoreContinuation?.finish()
    }

    nonisolated(nonsending) func waitLogStoreToFinish() async {
        logStoreContinuation?.finish()
        logStoreContinuation = nil
        await logStoreTask?.value
    }
}

// MARK: - Copilot Bridges

extension NewViewModel {
    nonisolated(nonsending) func stop() async throws {
        try await parent.stop()
    }

    nonisolated(nonsending) func startCopilot() async throws {
        // Compile and validate the copilot parameters before anything is queued
        // (C16); rejections are user-visible instead of silent no-ops. A list
        // compiles to one append per task (SSS sets expand to ordered
        // single-filename tasks); a failed append stops queueing the rest.
        switch CopilotCompiler.compile(.init(context: copilot)) {
        case .failure(let error):
            appendLog(.init(date: .now, content: error.logMessage, color: .error))
            return
        case .success(let outputs):
            // C11 资料辅助：仅普通作业任务消费 operbox_data_path；开关开启而
            // 当前作用域无可用快照时按 WPF ValidateStartAsync 同构阻断启动。
            var configs = outputs.map(\.config)
            if copilot.enableOperBoxAssist, outputs.contains(where: { $0.type == .Copilot }) {
                guard let assistPath = await prepareOperBoxAssistFile() else {
                    return
                }
                for index in configs.indices {
                    configs[index].operbox_data_path = assistPath
                }
            }

            // 一次性序列化全部任务后走批量入口：占用/启动各一次，避免逐项
            // start 让第二个任务撞上「任务正在运行」的 idle 守卫。
            var tasks = [(type: MAATaskType, params: String)]()
            for index in outputs.indices {
                if outputs[index].type != .Copilot {
                    // SSS/悖论任务不消费该参数，不随行下发。
                    configs[index].operbox_data_path = nil
                }
                guard let params = try? configs[index].jsonString() else {
                    appendLog(
                        .init(
                            date: .now,
                            content: String(localized: "作业参数序列化失败，请重试。"),
                            color: .error))
                    return
                }
                tasks.append((type: outputs[index].type, params: params))
            }

            try await parent.startCopilot(tasks: tasks)
            copilotStartToken = UUID()
        }
    }

    /// C11：把当前作用域的最新干员快照落盘为 Core 可读文件，返回路径。
    /// 不可用（无快照/无技能数据）按 WPF ValidateStartAsync 记错误并 nil。
    @MainActor private func prepareOperBoxAssistFile() -> String? {
        let scope = parent.inventoryScope
        guard let snapshot = try? parent.operBoxHistoryStore.load(scope: scope),
            OperBoxAssistExport.isAssistUsable(snapshot.operators)
        else {
            appendLog(
                .init(
                    date: .now,
                    content: String(
                        localized:
                            "当前没有可用的一图流干员数据，无法辅助编队。请先从一图流获取干员数据，或关闭「使用一图流数据辅助编队」。"
                    ),
                    color: .error))
            return nil
        }
        do {
            let url = try OperBoxAssistExport.write(
                snapshot.operators,
                source: snapshot.source ?? "recognition",
                syncTime: snapshot.capturedAt)
            return url.path(percentEncoded: false)
        } catch {
            appendLog(
                .init(
                    date: .now,
                    content: String(localized: "干员资料写盘失败：\(error.localizedDescription)"),
                    color: .error))
            return nil
        }
    }

    nonisolated(nonsending) func recognizeVideo(url: URL) async throws {
        try await parent.recognizeVideo(video: url)
    }

    /// C09 跨启动恢复入口（作业页首次出现时调用）：完整恢复静默，部分成员
    /// 跳过告警，集合不可用报错。
    nonisolated(nonsending) func restoreCopilotList() async {
        switch await copilot.restorePersistedList() {
        case .none:
            break
        case .restored(_, let skipped):
            guard !skipped.isEmpty else { return }
            appendLog(
                .init(
                    date: .now,
                    content: String(
                        localized: "作业集已恢复，部分成员无法加载：\(skipped.joined(separator: "、"))"),
                    color: .warning))
        case .failed(let failure):
            appendLog(.init(date: .now, content: failure.logMessage, color: .error))
        }
    }
}

// MARK: - PRTS Copilot Downloader

extension NewViewModel {
    /// C12 作业站点赞/点踩：POST {id, rating: Like|Dislike}，HTTP 2xx 即成功
    /// （WPF RateWebJsonAsync 同构；响应体不做状态解析）。成功后会话内去重。
    nonisolated(nonsending) func rateCopilot(_ isLike: Bool) async {
        guard let id = copilot.currentRateableCopilotID, id > 0 else { return }
        guard !recentlyRatedCopilotIDs.contains(id) else { return }

        var request = URLRequest(url: URL(string: "https://prts.maa.plus/copilot/rating")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["id": id, "rating": isLike ? "Like" : "Dislike"])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            recentlyRatedCopilotIDs.insert(id)
            appendLog(
                .init(
                    date: .now,
                    content: String(
                        localized: "感谢评价！\n网页已经开放评论区，欢迎前往留下你的评论！"),
                    color: .info))
        } catch {
            appendLog(
                .init(
                    date: .now,
                    content: String(localized: "出现错误，评价失败 : <"),
                    color: .error))
        }
    }

    nonisolated(nonsending) func downloadCopilot(code: PRTSCode) async {
        let progress = Progress()
        copilotDownloadProgress = progress
        defer { copilotDownloadProgress = nil }

        do {
            switch code {
            case .copilot(let id):
                lastImportedCopilot = try await MAACopilot.download(id: id, toDirectory: .externalCopilotDirectory)
            case .set(let setID):
                do {
                    lastImportedCopilot = try await CopilotSetData.download(id: setID, progress: progress)
                } catch {
                    // C02 半成品清理：中断/失败后残留的集合目录不再误导重试。
                    try? FileManager.default.removeItem(
                        at: URL.externalCopilotDirectory.appending(path: "s\(setID)/"))
                    throw error
                }
            }
        } catch {
            // C02：下载失败给可见日志（此前只有 print，用户无从得知）。
            appendLog(
                .init(
                    date: .now,
                    content: String(localized: "作业下载失败：\(error.localizedDescription)"),
                    color: .error))
        }
    }
}

// MARK: - Log Store

protocol LogStore: AnyObject {
    func appendLog(_ entry: MAALog)
    func clearLogs(upTo index: Int)
    func setLastImportedCopilot(_ url: URL)
    func setDepot(_ depot: MAADepot?)
    func setOperBox(_ operBox: MAAOperBox?)
    func setDailyTasksDetailMode(_ mode: MAAViewModel.DailyTasksDetailMode)

    var logCount: Int { get }
    var lastLogID: UUID? { get }
    var screencapCost: (min: Int, max: Int, avg: Int)? { get set }
    var lastScreencapWarningLevel: Int { get set }
    var hasPrintedFPSHighTip: Bool { get set }
    var recruitConfirmTimes: Int { get set }
    var stoneUsedTimes: Int { get set }
    var taskStartTime: Date? { get set }
    var sanityReport: NewViewModel.SanityReport? { get set }
    var fightReport: NewViewModel.FightReport? { get set }
}

extension NewViewModel: LogStore {
    func appendLog(_ entry: MAALog) {
        logs.append(entry)
        logStoreContinuation?.yield(entry)
    }

    var logCount: Int {
        logs.count
    }

    /// U11: 卡片缩略图挂载的锚点（最新日志 id；空流返回 nil）。
    var lastLogID: UUID? {
        logs.last?.id
    }

    func clearLogs(upTo index: Int) {
        guard index > 0, !logs.isEmpty else { return }
        logs.removeFirst(min(index, logs.count))
    }

    func setLastImportedCopilot(_ url: URL) {
        lastImportedCopilot = url
    }

    func setDepot(_ depot: MAADepot?) {
        self.depot = depot
    }

    func setOperBox(_ operBox: MAAOperBox?) {
        self.operBox = operBox
    }

    func setDailyTasksDetailMode(_ mode: MAAViewModel.DailyTasksDetailMode) {
        dailyTasksDetailMode = mode
    }
}
