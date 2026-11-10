import Foundation

// 作战日报数据模型（WPF CombatSession/DailyReportDayData/DailyReportRetention 同构，
// JSON 键名与 WPF data/DailyReport/<yyyy-MM-dd>.json 完全一致，文件互相可读）。

/// 一条 Fight 链的作战事实记录，对应一场理智作战或库存保持的单条计划。
/// 只记录发生过的量，不记录结束原因、任务来源等叙事信息；零场次的链不产生记录。
struct CombatSession: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 关卡编号，如 1-7、PR-A-1。
    var stage: String = ""
    /// 链开始时刻，按游戏日归档。
    var startTime: Date = Date()
    /// 链结束时刻。运行中的记录与崩溃遗留的记录为 nil，加载时不补齐。
    var endTime: Date?
    /// 本链总场次：每局结算按该局代理倍率累加，即实际作战数。
    var times: Int = 0
    /// 本链代理作战的局数（不含倍率折算）；平均耗时按局数分母，不按 times。
    var rounds: Int = 0
    /// 本链理智总消耗：每局结算累加开始前读到的消耗（已含代理倍率）。
    var sanity: Int = 0
    /// 常规理智药使用数。
    var medicinesUsed: Int = 0
    /// 临期理智药使用数。
    var expiringMedicinesUsed: Int = 0
    /// 源石使用数。
    var stonesUsed: Int = 0
    /// 掉落合计（itemId 到本链累计数量），取最后一次 StageDrops 上报的任务内累计值。
    var drops: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case stage, startTime, endTime, times, rounds, sanity
        case medicinesUsed, expiringMedicinesUsed, stonesUsed, drops
    }

    /// 等值只看持久化字段（id 是会话内标识，解码侧重新生成）。
    static func == (lhs: CombatSession, rhs: CombatSession) -> Bool {
        lhs.stage == rhs.stage && lhs.startTime == rhs.startTime && lhs.endTime == rhs.endTime
            && lhs.times == rhs.times && lhs.rounds == rhs.rounds && lhs.sanity == rhs.sanity
            && lhs.medicinesUsed == rhs.medicinesUsed && lhs.expiringMedicinesUsed == rhs.expiringMedicinesUsed
            && lhs.stonesUsed == rhs.stonesUsed && lhs.drops == rhs.drops
    }

    init() {}

    init(startTime: Date) {
        self.startTime = startTime
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? ""
        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime) ?? Date()
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        times = try container.decodeIfPresent(Int.self, forKey: .times) ?? 0
        rounds = try container.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
        sanity = try container.decodeIfPresent(Int.self, forKey: .sanity) ?? 0
        medicinesUsed = try container.decodeIfPresent(Int.self, forKey: .medicinesUsed) ?? 0
        expiringMedicinesUsed = try container.decodeIfPresent(Int.self, forKey: .expiringMedicinesUsed) ?? 0
        stonesUsed = try container.decodeIfPresent(Int.self, forKey: .stonesUsed) ?? 0
        drops = try container.decodeIfPresent([String: Int].self, forKey: .drops) ?? [:]
    }

    /// 零场次且无掉落、用药、碎石的链没有统计价值（WPF CombatSession.IsEmpty 同构）。
    var isEmpty: Bool {
        times == 0 && drops.isEmpty && medicinesUsed == 0 && expiringMedicinesUsed == 0 && stonesUsed == 0
    }
}

/// 单日作战日报数据，对应 DailyReport/<yyyy-MM-dd>.json。
/// 文件名即游戏日日期 key，日文件是唯一事实源，周/月/年视图由展示层现场聚合。
struct DailyReportDayData: Codable, Equatable {
    /// 数据结构版本。
    var version: Int = 1
    /// 当日全部作战记录。
    var sessions: [CombatSession] = []

    enum CodingKeys: String, CodingKey {
        case version, sessions
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sessions = try container.decodeIfPresent([CombatSession].self, forKey: .sessions) ?? []
    }
}

/// 作战日报数据保留档位，按游戏日文件裁剪（WPF DailyReportRetention 同构）。
enum DailyReportRetention: String, Codable, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case unlimited

    var id: String { rawValue }

    /// 保留的最近游戏日数（含今日）；不限制返回 nil。
    var keepDays: Int? {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 31
        case .year: 366
        case .unlimited: nil
        }
    }
}
