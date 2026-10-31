import Foundation

/// Typed names so renames cannot silently break the observer/post pairs.
extension Notification.Name {
    static let MAACancelPendingScheduledStart = Notification.Name("MAACancelPendingScheduledStart")
    static let MAADailyRunFinished = Notification.Name("MAADailyRunFinished")
}

/// Shared identity and terminal contract for daily automation entry points.
enum DailyRunOrigin: String, Codable { case manual, schedule, hotkey }
enum DailyRunPhase: String, Codable { case preparing, preHook, connecting, running, stopping, postHook, finished }
enum DailyRunOutcome: String, Codable { case completed, cancelled, failed, interrupted }

struct RunContext: Codable, Equatable, Identifiable {
    let id: UUID
    let origin: DailyRunOrigin
    let profileID: String
    var status: DailyRunPhase
    let startedAt: Date
    var finishedAt: Date?
    var outcome: DailyRunOutcome?
    var cleanupSucceeded: Bool?
}

struct DailyRunSnapshot {
    let profileID: String
    let tasks: [DailyTask]
}

/// One owner for a daily run, retained through post-run cleanup.
@MainActor
final class DailyRunCoordinator {
    private(set) var active: RunContext?
    private(set) var lastTerminal: RunContext?
    /// 首次写盘失败后置位:本次会话其余生命周期仅在内存中跟踪运行。日志
    /// 故障绝不楔死运行——占用必须仍可释放、stop 必须仍可执行;磁盘上停
    /// 留的过期内容由 init 的 interrupted 恢复语义兜底(#178 92ee14c)。
    private(set) var journalDegraded = false
    private let journalURL: URL?
    var didChange: (() -> Void)?

    init(journalURL: URL? = nil) {
        self.journalURL = journalURL
        guard let journalURL, let data = try? Data(contentsOf: journalURL),
              var previous = try? JSONDecoder().decode(RunContext.self, from: data) else { return }
        if previous.status != .finished {
            previous.status = .finished
            previous.outcome = .interrupted
            previous.finishedAt = .now
            previous.cleanupSucceeded = nil
        }
        lastTerminal = previous
        // Recovery is reported, never replayed: the script may already have run.
    }

    @discardableResult
    func begin(profileID: String, origin: DailyRunOrigin) throws -> UUID? {
        guard active == nil else { return nil }
        let context = RunContext(id: UUID(), origin: origin, profileID: profileID,
                                 status: .preparing, startedAt: .now)
        do { try persist(context) } catch {}
        active = context
        didChange?()
        return context.id
    }

    func transition(_ phase: DailyRunPhase, for id: UUID) throws {
        guard var context = active, context.id == id, context.status != .postHook else { return }
        context.status = phase
        do { try persist(context) } catch {}
        active = context
        didChange?()
    }

    @discardableResult
    func finish(_ id: UUID, outcome: DailyRunOutcome, cleanupSucceeded: Bool?) throws -> Bool {
        guard var context = active, context.id == id else { return false }
        context.status = .finished
        context.finishedAt = .now
        context.outcome = outcome
        context.cleanupSucceeded = cleanupSucceeded
        do { try persist(context) } catch {}
        lastTerminal = context
        active = nil
        didChange?()
        NotificationCenter.default.post(name: .MAADailyRunFinished, object: context)
        return true
    }

    /// User escape hatch while the journal cannot be written: finish the run in
    /// memory only so stop/start are not refused until an app restart. The stale
    /// on-disk record is still marked interrupted by the next launch.
    @discardableResult
    func abandon(_ id: UUID, outcome: DailyRunOutcome = .cancelled) -> Bool {
        guard var context = active, context.id == id else { return false }
        journalDegraded = true
        context.status = .finished
        context.finishedAt = .now
        context.outcome = outcome
        context.cleanupSucceeded = nil
        lastTerminal = context
        active = nil
        didChange?()
        NotificationCenter.default.post(name: .MAADailyRunFinished, object: context)
        return true
    }

    func recordRecovery(for id: UUID, succeeded: Bool) throws {
        guard active == nil, var context = lastTerminal, context.id == id else { return }
        context.cleanupSucceeded = succeeded
        try persist(context)
        lastTerminal = context
        didChange?()
    }

    private func persist(_ context: RunContext) throws {
        guard let journalURL, !journalDegraded else { return }
        do {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(context).write(to: journalURL, options: .atomic)
        } catch {
            // 降级为内存模式并记一次诊断:后续写不再重试,调用方继续收口。
            journalDegraded = true
            print("Daily run journal degraded to memory mode: \(error)")
            throw error
        }
    }
}
