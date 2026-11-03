//
//  NewViewModel.swift
//  MAA
//
//  Created by hguandl on 2026/8/8.
//

import Combine
import Foundation
import Observation

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
            // 一次性序列化全部任务后走批量入口：占用/启动各一次，避免逐项
            // start 让第二个任务撞上「任务正在运行」的 idle 守卫。
            var tasks = [(type: MAATaskType, params: String)]()
            for output in outputs {
                guard let params = try? output.config.jsonString() else {
                    appendLog(
                        .init(
                            date: .now,
                            content: String(localized: "作业参数序列化失败，请重试。"),
                            color: .error))
                    return
                }
                tasks.append((type: output.type, params: params))
            }

            try await parent.startCopilot(tasks: tasks)
            copilotStartToken = UUID()
        }
    }

    nonisolated(nonsending) func recognizeVideo(url: URL) async throws {
        try await parent.recognizeVideo(video: url)
    }
}

// MARK: - PRTS Copilot Downloader

extension NewViewModel {
    nonisolated(nonsending) func downloadCopilot(code: PRTSCode) async {
        let progress = Progress()
        copilotDownloadProgress = progress
        defer { copilotDownloadProgress = nil }

        do {
            switch code {
            case .copilot(let id):
                lastImportedCopilot = try await MAACopilot.download(id: id, toDirectory: .externalCopilotDirectory)
            case .set(let setID):
                lastImportedCopilot = try await CopilotSetData.download(id: setID, progress: progress)
            }
        } catch {
            print(error)
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
