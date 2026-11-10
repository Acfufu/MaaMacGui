import Foundation

/// S02: 启动自动运行策略（WPF RunDirectly / SkipStartupAutoRunAfterUpdate 同构）。
/// WPF 在重启链写入 --skip-startup-auto-run；Mac 的 Sparkle 重启不透传参数，
/// 改用一次性标记文件承担 SkipStartupAutoRunAfterUpdate 语义（差异已入档 divergence）。
enum StartupAutoRunPolicy {
    enum SkipReason: Equatable {
        /// 「打开应用即运行」未启用。
        case disabled
        /// 命令行携带 --skip-startup-auto-run（更新重启链或调试）。
        case cliArgument
        /// 读到更新后立即重启的一次性标记。
        case afterUpdateRelaunch
    }

    static let skipArgument = "--skip-startup-auto-run"
    static let skipAfterUpdateDefaultsKey = "MAASkipStartupAutoRunAfterUpdate"

    static var cliSkipRequested: Bool { CommandLine.arguments.contains(skipArgument) }

    /// UserDefaults.bool 的未设置缺省是 false，而该选项缺省应为 true（WPF 同构）。
    static func skipAfterUpdateEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: skipAfterUpdateDefaultsKey) as? Bool ?? true
    }

    static func decide(runDirectly: Bool, cliSkipRequested: Bool, updateRelaunchMarkerPresent: Bool) -> StartupAutoRunDecision {
        if !runDirectly { return .skip(.disabled) }
        if cliSkipRequested { return .skip(.cliArgument) }
        if updateRelaunchMarkerPresent { return .skip(.afterUpdateRelaunch) }
        return .run
    }
}

enum StartupAutoRunDecision: Equatable {
    case run
    case skip(StartupAutoRunPolicy.SkipReason)
}

/// 旧进程写、新进程读即删：标记只作用于紧接着的一次启动。
enum StartupAutoRunMarker {
    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MeoAsstMac", isDirectory: true)
            .appendingPathComponent("StartupAutoRunSkip.pending", isDirectory: false)
    }

    static func write(url: URL = defaultURL(), timestamp: Date = Date()) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = "relaunched-at \(timestamp.timeIntervalSince1970)"
        try Data(payload.utf8).write(to: url, options: .atomic)
    }

    /// 读到即删：即使新进程决定跳过，标记也不再生效第二次。
    @discardableResult
    static func consume(url: URL = defaultURL()) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}

/// S02: WPF ConfirmStartupAutoRunAsync 的反悔倒计时。归零未取消时执行 onProceed；
/// 取消/外部中止只清理回调，不触发执行。onTick(nil) 表示倒计时结束（无论何种原因）。
@MainActor final class StartupAutoRunCountdown {
    private(set) var isCounting = false
    private var task: Task<Void, Never>?
    private var tickHandler: ((Int?) -> Void)?
    private var proceedHandler: (() -> Void)?

    func begin(seconds: Int, tick: Duration,
               onTick: @escaping @MainActor (Int?) -> Void,
               onProceed: @escaping @MainActor () -> Void) {
        guard !isCounting, seconds > 0 else { return }
        isCounting = true
        tickHandler = onTick
        proceedHandler = onProceed
        task = Task { [weak self] in
            for step in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self?.tickHandler?(step)
                do { try await Task.sleep(for: tick) } catch { return }
            }
            guard let self, !Task.isCancelled, self.isCounting else { return }
            // complete() 会作废 proceedHandler；必须先取出再收口。
            let proceed = self.proceedHandler
            self.complete()
            proceed?()
        }
    }

    func cancel() {
        guard isCounting else { return }
        task?.cancel()
        complete()
    }

    /// 归零或取消共用的收口：先停计数（驱动 UI 撤弹窗），再作废回调。
    private func complete() {
        isCounting = false
        task = nil
        tickHandler?(nil)
        tickHandler = nil
        proceedHandler = nil
    }
}
