//
//  InfrastConfiguration.swift
//  MAA
//
//  Created by hguandl on 16/4/2023.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.hguandl.MeoAsstMac", category: "InfrastConfiguration")

struct InfrastConfiguration: MAATaskConfiguration {
    var type: MAATaskType { .Infrast }

    enum Mode: Int, Codable {
        case `default` = 0
        case custom = 10000
        case rotation = 20000
    }

    enum Facility: String, CaseIterable, Codable {
        case Mfg
        case Trade
        case Power
        case Control
        case Reception
        case Office
        case Dorm
        case Processing
        case Training
        case Recycle
        case AssistantChange
    }

    enum DroneUsage: String, CaseIterable, Codable {
        case NotUse = "_NotUse"
        case Money
        case SyntheticJade
        case CombatRecord
        case PureGold
        case OriginStone
        case Chip
    }

    var mode: Mode

    var facility: [Facility]
    var drones: DroneUsage
    var threshold: Double
    var replenish: Bool

    var dorm_notstationed_enabled: Bool
    var dorm_trust_enabled: Bool

    var continue_training: Bool
    var reception_message_board: Bool
    // B08 线索交流/赠送独立开关：Core 缺省双 true（InfrastTask.cpp:264-268），
    // WPF 配置层同 true；false 才会关闭对应会客室行为。
    var reception_clue_exchange: Bool
    var reception_send_clue: Bool
    // B07 跨设施编组开关：Core 缺省全 false 且仅常规模式消费
    // （InfrastTask.cpp:250-253 `default_mode &&` 门控）；WPF 恒编码四键。
    var use_pinus_sylvestris: Bool
    var use_perception_information: Bool
    var use_worldly_plight: Bool
    var use_abyssal_hunter: Bool
    // B13 每周执行日（upstream InfrastTask.UseWeeklySchedule/WeeklySchedule，
    // 调度层不进 Core 参数）：nil=每天；游戏日星期 0=周日…6=周六，与
    // FightConfiguration.weeklyDays（F06）同构同源。
    var weeklyDays: [Int]?
    var fiammetta_recovery_enabled: Bool
    var fiammetta_targets: [String]

    // Shared by inline settings and downgrade backups. Nil means the key was
    // absent; malformed explicit values become false/[] so backups cannot
    // accidentally turn recovery back on or expand its target list.
    struct FiammettaPreferences: Codable {
        var recoveryEnabled: Bool?
        var targets: [String]?

        private enum CodingKeys: String, CodingKey {
            case recoveryEnabled = "fiammetta_recovery_enabled"
            case targets = "fiammetta_targets"
        }
    }

    var filename: String
    var plan_index: Int

    var title: String {
        type.description
    }

    var subtitle: String {
        if mode != .custom {
            return String(localized: "默认换班")
        }

        if let plan = try? MAAInfrast(path: filename) {
            return plan.title ?? filename
        } else {
            return String(localized: "无法识别配置")
        }
    }

    var summary: String {
        if mode != .custom {
            return String(localized: "单设施最优解")
        }

        if let plan = try? MAAInfrast(path: filename), plan_index < plan.plans.count {
            return plan.plans[plan_index].name ?? "\(plan_index)"
        } else {
            return String(localized: "未知排班")
        }
    }

    var projectedTask: MAATask {
        .infrast(self)
    }

    struct Params: Encodable {
        var mode: Mode
        var facility: [Facility]
        var drones: DroneUsage
        var threshold: Double
        var replenish: Bool
        var dorm_notstationed_enabled: Bool
        var dorm_trust_enabled: Bool
        var continue_training: Bool
        var reception_message_board: Bool
        var reception_clue_exchange: Bool
        var reception_send_clue: Bool
        var use_pinus_sylvestris: Bool
        var use_perception_information: Bool
        var use_worldly_plight: Bool
        var use_abyssal_hunter: Bool
        var filename: String
        var plan_index: Int
        var fiammetta_recovery_enabled: Bool
        var fiammetta_targets: [String]
    }

    /// B13 每周执行日门控（GUI 侧跳过，不下发 Core）。
    func isScheduled(on weekday: Int) -> Bool {
        weeklyDays?.contains(weekday) ?? true
    }

    var params: Params {
        let targets = Self.normalizedFiammettaTargets(fiammetta_targets)
        let enabled = mode == .default && fiammetta_recovery_enabled && !targets.isEmpty
        return .init(
            mode: mode, facility: facility, drones: drones, threshold: threshold,
            replenish: replenish, dorm_notstationed_enabled: dorm_notstationed_enabled,
            dorm_trust_enabled: dorm_trust_enabled, continue_training: continue_training,
            reception_message_board: reception_message_board,
            reception_clue_exchange: reception_clue_exchange, reception_send_clue: reception_send_clue,
            use_pinus_sylvestris: use_pinus_sylvestris,
            use_perception_information: use_perception_information,
            use_worldly_plight: use_worldly_plight, use_abyssal_hunter: use_abyssal_hunter,
            filename: filename, plan_index: plan_index,
            fiammetta_recovery_enabled: enabled, fiammetta_targets: enabled ? targets : [])
    }

    // The v6.20.1 Core contract permits these six names and at most three targets.
    // Keep empty/invalid selections empty: Core would otherwise expand them to defaults.
    enum FiammettaTarget: String, CaseIterable, Identifiable {
        case purestream = "清流"
        case closure = "可露希尔"
        case proviso = "但书"
        case shamare = "巫恋"
        case tequila = "龙舌兰"
        case gladiia = "歌蕾蒂娅"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .purestream: String(localized: "清流")
            case .closure: String(localized: "可露希尔")
            case .proviso: String(localized: "但书")
            case .shamare: String(localized: "巫恋")
            case .tequila: String(localized: "龙舌兰")
            case .gladiia: String(localized: "歌蕾蒂娅")
            }
        }
    }

    static let defaultFiammettaTargets = [FiammettaTarget.purestream, .closure, .proviso].map(\.rawValue)

    static func normalizedFiammettaTargets(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return Array(
            values.compactMap { value -> String? in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard FiammettaTarget(rawValue: name) != nil, seen.insert(name).inserted else { return nil }
                return name
            }.prefix(3))
    }

    private var customPlan: MAAInfrast? {
        guard mode == .custom else { return nil }
        return try? MAAInfrast(path: filename)
    }
}

extension InfrastConfiguration.Facility: CustomStringConvertible, Identifiable {
    var id: String { rawValue }

    var description: String {
        switch self {
        case .Mfg:
            return String(localized: "制造站")
        case .Trade:
            return String(localized: "贸易站")
        case .Power:
            return String(localized: "发电站")
        case .Control:
            return String(localized: "控制中枢")
        case .Reception:
            return String(localized: "会客室")
        case .Office:
            return String(localized: "办公室")
        case .Dorm:
            return String(localized: "宿舍")
        case .Processing:
            return String(localized: "加工站")
        case .Training:
            return String(localized: "训练室")
        case .Recycle:
            return String(localized: "回收站")
        case .AssistantChange:
            return String(localized: "副手换人")
        }
    }
}

extension InfrastConfiguration.DroneUsage: CustomStringConvertible {
    var description: String {
        switch self {
        case .NotUse:
            return String(localized: "不使用无人机")
        case .Money:
            return String(localized: "贸易站-龙门币")
        case .SyntheticJade:
            return String(localized: "贸易站-合成玉")
        case .CombatRecord:
            return String(localized: "制造站-经验书")
        case .PureGold:
            return String(localized: "制造站-赤金")
        case .OriginStone:
            return String(localized: "制造站-源石碎片")
        case .Chip:
            return String(localized: "制造站-芯片组")
        }
    }
}

extension InfrastConfiguration {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decodeIfPresent(InfrastConfiguration.Mode.self, forKey: .mode) ?? .default
        self.facility =
            try container.decodeIfPresent([InfrastConfiguration.Facility].self, forKey: .facility) ?? [
                .Mfg, .Trade, .Control, .Power, .Reception, .Office, .Dorm, .Processing, .Training,
            ]
        self.drones = try container.decodeIfPresent(InfrastConfiguration.DroneUsage.self, forKey: .drones) ?? .NotUse
        self.threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.3
        self.replenish = try container.decodeIfPresent(Bool.self, forKey: .replenish) ?? false
        self.dorm_notstationed_enabled =
            try container.decodeIfPresent(Bool.self, forKey: .dorm_notstationed_enabled) ?? false
        self.dorm_trust_enabled = try container.decodeIfPresent(Bool.self, forKey: .dorm_trust_enabled) ?? false
        self.filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        self.plan_index = try container.decodeIfPresent(Int.self, forKey: .plan_index) ?? 0
        self.continue_training = try container.decodeIfPresent(Bool.self, forKey: .continue_training) ?? true
        self.reception_message_board =
            try container.decodeIfPresent(Bool.self, forKey: .reception_message_board) ?? true
        self.reception_clue_exchange =
            try container.decodeIfPresent(Bool.self, forKey: .reception_clue_exchange) ?? true
        self.reception_send_clue = try container.decodeIfPresent(Bool.self, forKey: .reception_send_clue) ?? true
        self.use_pinus_sylvestris =
            try container.decodeIfPresent(Bool.self, forKey: .use_pinus_sylvestris) ?? false
        self.use_perception_information =
            try container.decodeIfPresent(Bool.self, forKey: .use_perception_information) ?? false
        self.use_worldly_plight = try container.decodeIfPresent(Bool.self, forKey: .use_worldly_plight) ?? false
        self.use_abyssal_hunter = try container.decodeIfPresent(Bool.self, forKey: .use_abyssal_hunter) ?? false
        self.weeklyDays = try container.decodeIfPresent([Int].self, forKey: .weeklyDays)
        let preferences = try FiammettaPreferences(from: decoder)
        self.fiammetta_targets = Self.normalizedFiammettaTargets(
            preferences.targets ?? Self.defaultFiammettaTargets)
        self.fiammetta_recovery_enabled =
            (preferences.recoveryEnabled ?? false) && !fiammetta_targets.isEmpty
    }
}

extension InfrastConfiguration.FiammettaPreferences {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recoveryEnabled =
            container.contains(.recoveryEnabled)
            ? Self.safelyDecoded(Bool.self, .recoveryEnabled, from: container, fallback: false) : nil
        targets =
            container.contains(.targets)
            ? Self.safelyDecoded([String].self, .targets, from: container, fallback: []) : nil
    }

    // Malformed explicit values fall back to false/[] so a damaged backup cannot
    // turn recovery back on; logging them keeps hand-edited type errors visible.
    private static func safelyDecoded<Value: Decodable>(
        _ type: Value.Type, _ key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>,
        fallback: Value
    ) -> Value {
        do {
            return try container.decode(Value.self, forKey: key)
        } catch {
            logger.warning("Ignoring malformed Fiammetta preference \(key.stringValue): \(error, privacy: .public)")
            return fallback
        }
    }
}
