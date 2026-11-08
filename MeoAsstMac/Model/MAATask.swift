//
//  MAATask.swift
//  MAA
//
//  Created by hguandl on 15/4/2023.
//

import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.hguandl.MeoAsstMac", category: "MAATask")

enum MAATask: Codable, Equatable {
    case startup(StartupConfiguration)
    case closedown(ClosedownConfiguration)
    case recruit(RecruitConfiguration)
    case infrast(InfrastConfiguration)
    case fight(FightConfiguration)
    case mall(MallConfiguration)
    case award(AwardConfiguration)
    case switchTheme(SwitchThemeConfiguration)
    case roguelike(RoguelikeConfiguration)
    case reclamation(ReclamationConfiguration)
    case custom(CustomConfiguration)
    case operProgress(OperProgressConfiguration)
    case userdataupdate(UserDataUpdateConfiguration)
}

let defaultTaskConfigurations: [any MAATaskConfiguration] = [
    StartupConfiguration(),
    RecruitConfiguration(),
    InfrastConfiguration(),
    FightConfiguration(),
    MallConfiguration(),
    AwardConfiguration(),
    SwitchThemeConfiguration(),
    RoguelikeConfiguration(),
    ReclamationConfiguration(),
    CustomConfiguration(),
    OperProgressConfiguration(),
    UserDataUpdateConfiguration(),
    ClosedownConfiguration(),
]

extension MAATaskType: Codable, CustomStringConvertible {
    var description: String {
        switch self {
        case .StartUp:
            return String(localized: "开始唤醒")
        case .CloseDown:
            return String(localized: "关闭游戏")
        case .Recruit:
            return String(localized: "自动公招")
        case .Infrast:
            return String(localized: "基建换班")
        case .Fight:
            return String(localized: "刷理智")
        case .Mall:
            return String(localized: "收取信用及购物")
        case .Award:
            return String(localized: "领取奖励")
        case .SwitchTheme:
            return String(localized: "更换主题")
        case .Roguelike:
            return String(localized: "自动肉鸽")
        case .Copilot:
            return String(localized: "自动抄作业")
        case .SSSCopilot:
            return String(localized: "自动抄保全作业")
        case .ParadoxCopilot:
            return String(localized: "自动抄悖论模拟作业")
        case .Depot:
            return String(localized: "仓库识别")
        case .Reclamation:
            return String(localized: "生息演算")
        case .VideoRecognition:
            return String(localized: "视频识别")
        case .OperBox:
            return String(localized: "干员识别")
        case .Custom:
            return String(localized: "自定任务")
        case .UserDataUpdate:
            return String(localized: "更新资料")
        case .OperProgress:
            return String(localized: "干员养成计划")
        }
    }
}

// MARK: Task Persistance

struct DailyTask: Codable, Equatable, Identifiable {
    let id: UUID
    let task: MAATask
    var enabled: Bool
    /// Q05 仅执行一次：下一次完整成功的运行结束后自动停用（消费见
    /// DailyRunOnceSemantics）。旧档案缺少该键，解码为 false。
    var runOnce: Bool = false

    init(id: UUID = UUID(), task: MAATask, enabled: Bool, runOnce: Bool = false) {
        self.id = id
        self.task = task
        self.enabled = enabled
        self.runOnce = runOnce
    }

    enum CodingKeys: String, CodingKey { case id, task, enabled, runOnce }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        task = try container.decode(MAATask.self, forKey: .task)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        runOnce = try container.decodeIfPresent(Bool.self, forKey: .runOnce) ?? false
    }
}

extension DailyTask {
    init<T: MAATaskConfiguration>(config: T) {
        switch config.type {
        case .Roguelike, .Reclamation, .Custom, .OperProgress, .UserDataUpdate:
            self.init(id: UUID(), task: config.projectedTask, enabled: false)
        default:
            self.init(id: UUID(), task: config.projectedTask, enabled: true)
        }
    }
}

extension Array where Element == DailyTask {
    subscript(_ id: UUID) -> MAATask? {
        get {
            first { $0.id == id }?.task
        }
        set {
            if let newValue, let index = firstIndex(id: id) {
                self[index] = .init(id: id, task: newValue, enabled: self[index].enabled,
                                    runOnce: self[index].runOnce)
            }
        }
    }

    func firstIndex(id: UUID) -> Int? {
        firstIndex { $0.id == id }
    }

    mutating func append<T: MAATaskConfiguration>(config: T) {
        append(.init(config: config))
    }

    mutating func remove(id: UUID) {
        removeAll { $0.id == id }
    }
}

extension MAAViewModel {
    private static let taskProfileLogger = Logger(subsystem: "com.hguandl.MeoAsstMac", category: "TaskProfile")

    // 写盘失败（磁盘满、权限等）会让去重日期停留在上次保存的值，重启后可能重复提交子任务，必须留痕。
    func writeBack(_ newValue: [DailyTask]) {
        guard !isApplyingDailyCallbackPatch else { return }
        do {
            try DailyTaskProfileStore(profileURL: tasksURL).save(newValue)
        } catch {
            // A persistently failing write (e.g. the sidecar directory blocked by
            // a file) must remain visible in the log instead of stdout only;
            // default privacy keeps the user's home-directory path redacted.
            logger.warning("Failed to save daily task profile: \(error)")
        }
    }
}
