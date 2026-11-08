import Foundation

/// S17: 运行后收尾动作配置（WPF PostActionSetting 同位，Mac 平台等价面）。
/// 平台映射：Hibernate 无 macOS 等价不提供（差异入档）；lockScreen→pmset
/// displaysleepnow、sleep→pmset sleepnow、shutdown→osascript System Events；
/// IfNoOtherMaa 多开检测归 P22 backlog。动作失败逐项记录并继续（skipOnError
/// 只作用于「有失败任务时整体跳过」，与 WPF 同构）。
struct PostActionConfiguration: Codable, Equatable {
    var skipOnError = false
    var backToAndroidHome = false
    var exitArknights = false
    var exitEmulator = false
    var exitSelf = false
    var lockScreen = false
    var sleep = false
    var shutdown = false

    var anyEnabled: Bool {
        backToAndroidHome || exitArknights || exitEmulator || exitSelf || lockScreen || sleep || shutdown
    }
}

/// 执行规划：顺序与抑制规则保持纯函数以便测试（执行面在 MAAViewModel）。
enum PostActionPlanner {
    enum Action: Equatable {
        case backToAndroidHome
        case exitArknights
        case exitEmulator
        case exitSelf
        case lockScreen
        case sleep
        case shutdown
    }

    /// WPF RunPostActionsCoreAsync 同构：回首页 → 关游戏 → 退模拟器 →
    /// 退 MAA（仅当不执行锁屏/睡眠/关机）→ 锁屏 → 关机 → 睡眠。
    static func plannedActions(config: PostActionConfiguration, hasError: Bool, policyAllows: Bool) -> [Action] {
        guard config.anyEnabled, policyAllows else { return [] }
        if config.skipOnError, hasError { return [] }
        var actions: [Action] = []
        if config.backToAndroidHome { actions.append(.backToAndroidHome) }
        if config.exitArknights { actions.append(.exitArknights) }
        if config.exitEmulator { actions.append(.exitEmulator) }
        if config.exitSelf, !(config.lockScreen || config.sleep || config.shutdown) {
            actions.append(.exitSelf)
        }
        if config.lockScreen { actions.append(.lockScreen) }
        if config.shutdown { actions.append(.shutdown) }
        if config.sleep { actions.append(.sleep) }
        return actions
    }
}

/// S16: 运行时长上限（WPF RuntimeSettings.RunDurationLimit* 同位）。
enum RunDurationLimit {
    /// WPF GameSettingsUserControlModel.TimeoutMaxMinutes 同值。
    static let maxMinutes = 11451

    static func clampedMinutes(_ value: Int) -> Int {
        min(max(value, 1), maxMinutes)
    }
}

/// 收尾动作外部命令的非零退出。
struct PostActionCommandError: LocalizedError {
    let path: String
    let code: Int32
    var errorDescription: String? { "\(path) exit \(code)" }
}

@MainActor
final class PostActionSettingsStore: ObservableObject {
    @Published var configuration: PostActionConfiguration {
        didSet {
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "MAAPostActions") }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: "MAAPostActions")
            .flatMap { try? JSONDecoder().decode(PostActionConfiguration.self, from: $0) } ?? PostActionConfiguration()
    }
}
